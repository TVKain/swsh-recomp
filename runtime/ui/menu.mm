// In-game overlay (Dear ImGui on the Vulkan renderer; input fed from SDL events): the "close the game?" question
// (Esc, F1 or Minus + Plus on a controller), the F12 settings (tabs: graphics, image and sound - the same pages as the
// start screen's, runtime/ui/settings_ui.mm; from Let's Go Recomp 0.6.0), the name entry the game asks for
// (runtime/hle/swkbd.c), the FPS counter, the controller's finger on the touch screen (runtime/hle/input.c) and the shader
// preparation's progress (runtime/nvn/vulkan/prep.c).
// LARECOMP_MENU_KEY=<SDL scancode name> ("F10", "Insert"...): another key for the F12 settings (Steam takes F12 for
// screenshots by default).
//
// Threads: SDL events arrive on the main thread and are queued; the overlay is laid out and drawn on the render
// thread inside backend_present, after the game image, into the same window image.
#include <SDL3/SDL.h>
#include <float.h>
#include <math.h>
#include <pthread.h>
#include <atomic>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_vulkan.h"
#include "osk.h"
#include "settings_ui.h"
extern "C" bool vk_imgui_backend_init(void);  // runtime/nvn/vulkan/imgui_glue.cpp

extern "C" {
#include "../hle.h"
#include "../input_bind.h"
#include "../settings.h"
#include "menu.h"
#include "../paths.h"
void input_reset(void);
bool swsh60_known(void);  // runtime/hle/swsh60.c: the running build has the 60 fps mode
int shader_prep_progress(float *frac);  // runtime/nvn/vulkan/prep.c
bool input_finger_cursor(float *x, float *y, bool *down);  // runtime/hle/input.c
}

// ------------------------------------------------------------------ language
// English, Portuguese or Russian (issue #1), from the system's language (runtime/ui/settings_ui.h)
#define M UI_T

// ------------------------------------------------------------------ state shared with the main thread
static std::atomic<bool> g_open{false};  // the "close the game?" question is up
static std::atomic<bool> g_cfg{false};   // the F12 settings are up
static int g_cfg_tab;                    // the settings' page: display, graphics, audio, controls (render thread)
static bool g_cfg_fresh;                 // the settings just opened: the cursor goes to the page's sidebar row
static std::atomic<bool> g_want_fullscreen_apply{false};
bool menu_window_key(const SDL_Event *e);

struct QEvent {
    enum { KEY, ANALOG, MOUSE_POS, MOUSE_BUTTON, WHEEL, TEXT } kind;
    ImGuiKey key;
    bool down;
    float value, x, y;
    int button;
    char text[32];
};
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<QEvent> q_events;
static float g_pixel_density = 1;

static void push(const QEvent &e) {
    pthread_mutex_lock(&q_lock);
    q_events.push_back(e);
    pthread_mutex_unlock(&q_lock);
}

bool menu_is_open(void) { return g_open.load(); }
static void set_open(bool open) {
    if (open == g_open.load()) return;
    g_open.store(open);
    input_reset();  // nothing held while the question had focus leaks into the game
    if (!open) settings_save();
}
static void set_cfg(bool open) {
    if (open == g_cfg.load()) return;
    if (open) set_open(false), g_cfg_fresh = true;
    g_cfg.store(open);
    input_reset();
    if (!open) settings_save();
}
// (LARECOMP_MENU_AT: runtime/nvn/vulkan/device.c; LARECOMP_MENU_PAGE=cfg / <tab number>: the F12 settings on that
// tab instead - cfg the first)
extern "C" void menu_test_open(void) {
    const char *pg = getenv("LARECOMP_MENU_PAGE");
    if (!pg) { set_open(true); return; }
    g_cfg_tab = atoi(pg) >= 0 && atoi(pg) < 4 ? atoi(pg) : 0;
    set_cfg(true);
}

static ImGuiKey key_from_scancode(SDL_Scancode sc) {
    switch (sc) {
    case SDL_SCANCODE_UP: return ImGuiKey_UpArrow;
    case SDL_SCANCODE_DOWN: return ImGuiKey_DownArrow;
    case SDL_SCANCODE_LEFT: return ImGuiKey_LeftArrow;
    case SDL_SCANCODE_RIGHT: return ImGuiKey_RightArrow;
    case SDL_SCANCODE_RETURN: return ImGuiKey_Enter;
    case SDL_SCANCODE_KP_ENTER: return ImGuiKey_KeypadEnter;
    case SDL_SCANCODE_SPACE: return ImGuiKey_Space;
    case SDL_SCANCODE_TAB: return ImGuiKey_Tab;
    case SDL_SCANCODE_BACKSPACE: return ImGuiKey_Backspace;
    case SDL_SCANCODE_DELETE: return ImGuiKey_Delete;
    case SDL_SCANCODE_HOME: return ImGuiKey_Home;
    case SDL_SCANCODE_END: return ImGuiKey_End;
    case SDL_SCANCODE_LSHIFT: return ImGuiKey_LeftShift;
    case SDL_SCANCODE_RSHIFT: return ImGuiKey_RightShift;
    case SDL_SCANCODE_LCTRL: return ImGuiKey_LeftCtrl;
    case SDL_SCANCODE_RCTRL: return ImGuiKey_RightCtrl;
    case SDL_SCANCODE_A: return ImGuiKey_A;
    case SDL_SCANCODE_C: return ImGuiKey_C;
    case SDL_SCANCODE_V: return ImGuiKey_V;
    case SDL_SCANCODE_X: return ImGuiKey_X;
    case SDL_SCANCODE_Z: return ImGuiKey_Z;
    default: return ImGuiKey_None;
    }
}

// A confirms, B goes back, as in the game: by the controller layout (runtime/hle/bindings.c) - Nintendo: A the right
// face button, B the bottom one; Xbox: A the bottom one, B the right one.
static ImGuiKey key_from_pad(Uint8 b) {
    bool xbox = bind_layout() != BIND_LAYOUT_NINTENDO;  // (Xbox and Western: A the bottom button, B the right one)
    switch (b) {
    case SDL_GAMEPAD_BUTTON_EAST: return xbox ? ImGuiKey_GamepadFaceRight : ImGuiKey_GamepadFaceDown;   // activate (Nintendo)
    case SDL_GAMEPAD_BUTTON_SOUTH: return xbox ? ImGuiKey_GamepadFaceDown : ImGuiKey_GamepadFaceRight;  // cancel / back (Nintendo)
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    case SDL_GAMEPAD_BUTTON_START: return ImGuiKey_GamepadStart;
    case SDL_GAMEPAD_BUTTON_BACK: return ImGuiKey_GamepadBack;
    default: return ImGuiKey_None;
    }
}

// The left stick as the d-pad in the menus (ImGui moves the cursor with the d-pad only; the stick would scroll): each
// direction "pressed" past half way, let go under 35% (no flicker at the edge). Fills up to 2 changes, returns the count.
struct StickKey { ImGuiKey key; bool down; };
static int stick_to_dpad(Uint8 axis, float v, StickKey out[2]) {
    static bool held[4];  // left, right, up, down
    int lo;
    ImGuiKey klo, khi;
    if (axis == SDL_GAMEPAD_AXIS_LEFTX) lo = 0, klo = ImGuiKey_GamepadDpadLeft, khi = ImGuiKey_GamepadDpadRight;
    else if (axis == SDL_GAMEPAD_AXIS_LEFTY) lo = 2, klo = ImGuiKey_GamepadDpadUp, khi = ImGuiKey_GamepadDpadDown;
    else return 0;
    int n = 0;
    bool want_lo = held[lo] ? v < -0.35f : v < -0.5f, want_hi = held[lo + 1] ? v > 0.35f : v > 0.5f;
    if (want_lo != held[lo]) held[lo] = want_lo, out[n++] = {klo, want_lo};
    if (want_hi != held[lo + 1]) held[lo + 1] = want_hi, out[n++] = {khi, want_hi};
    return n;
}

// ---- software keyboard (runtime/hle/swkbd.c: the game's name entry) ------------------------------------------
// The game thread waits in menu_keyboard_run (re-presenting the last frame); this dialog takes the text: typed
// directly when the player last used a keyboard, an on-screen keyboard (d-pad + A, B deletes, Start / + OK) when
// they last used a controller.
static std::atomic<int> g_kbd{0};  // 1 open, 2 confirmed, 3 cancelled
static std::atomic<bool> g_last_pad{false};
static char g_kbd_text[96];
static int g_kbd_max = 8;
static bool capturing() { return g_open.load() || g_cfg.load() || g_kbd.load() == 1; }
// The game gets no input while this is true (runtime/hle/input.c): the question, the settings or the name entry is up.
extern "C" bool menu_input_captured(void) { return capturing(); }

static SDL_Scancode cfg_key(void) {
    static SDL_Scancode k = SDL_SCANCODE_UNKNOWN;
    if (k == SDL_SCANCODE_UNKNOWN) {
        const char *e = getenv("LARECOMP_MENU_KEY");
        k = e && *e ? SDL_GetScancodeFromName(e) : SDL_SCANCODE_UNKNOWN;
        if (k == SDL_SCANCODE_UNKNOWN) k = SDL_SCANCODE_F12;
    }
    return k;
}

// Holding View / Minus (SDL's BACK) HOLD_MS opens the F12 settings, or closes them (menu_apply_window_requests checks
// the time each frame); with Plus also down it is the "close the game?" combination instead. A short press is the
// game's Minus as before.
#define HOLD_MS 800
static std::atomic<uint64_t> g_back_since{0};  // (SDL_GetTicks when View went down; 0: up)
static std::atomic<bool> g_back_fired{false};
static std::atomic<uint64_t> g_hint_at{0};  // (the first controller button of this run: the hint shows for a while)
static bool back_down, start_down;

bool menu_handle_event(const SDL_Event *e) {
    if (e->type == SDL_EVENT_KEY_DOWN) g_last_pad = false;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) {
        g_last_pad = true;
        uint64_t zero = 0;
        g_hint_at.compare_exchange_strong(zero, SDL_GetTicks() ? SDL_GetTicks() : 1);
    }
    bool typing = g_kbd.load() == 1;  // (the name entry: keys are text, not shortcuts)
    if (typing && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat) {  // Enter confirms, Esc cancels
        if (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER) { g_kbd = 2; return true; }
        if (e->key.scancode == SDL_SCANCODE_ESCAPE) { g_kbd = 3; return true; }
    }
    if (typing && e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e->gbutton.button == SDL_GAMEPAD_BUTTON_START) {
        g_kbd = 2;
        return true;
    }
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN:
        if (!e->key.repeat && !typing && (e->key.scancode == cfg_key() || (e->key.scancode == SDL_SCANCODE_ESCAPE && g_cfg.load()))) {
            set_cfg(e->key.scancode == SDL_SCANCODE_ESCAPE ? false : !g_cfg.load());  // (Esc closes the settings)
            return true;
        }
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F1 ||
                               (e->key.scancode == SDL_SCANCODE_ESCAPE && !g_open.load()))) {
            if (!typing) { set_cfg(false); set_open(!g_open.load()); }  // (Esc with the question up goes to it below: "Não")
            return true;
        }
        if (menu_window_key(e)) return true;  // F11 / Alt+Enter: a window <-> the last full screen kind
        /* fallthrough */
    case SDL_EVENT_KEY_UP: {
        if (!capturing()) return false;
        bool down = e->type == SDL_EVENT_KEY_DOWN;
        if (down && e->key.scancode == SDL_SCANCODE_ESCAPE) {
            QEvent q = {};
            q.kind = QEvent::KEY; q.key = ImGuiKey_Escape; q.down = true; push(q);
            q.down = false; push(q);
            return true;
        }
        ImGuiKey k = key_from_scancode(e->key.scancode);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_TEXT_INPUT:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::TEXT; strlcpy(q.text, e->text.text, sizeof q.text); push(q); }
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        bool down = e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_BACK) {
            back_down = down;
            g_back_since = down ? (SDL_GetTicks() ? SDL_GetTicks() : 1) : 0;
            if (down) g_back_fired = false;
            else if (g_back_fired.exchange(false)) return true;  // (the release of a hold that opened / closed the settings)
        }
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_START) start_down = down;
        if (down && !typing && ((back_down && start_down) || e->gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE)) {
            g_back_fired = back_down;  // (not a hold any more)
            set_cfg(false);
            set_open(!g_open.load());
            return true;
        }
        if (!capturing()) return false;
        ImGuiKey k = key_from_pad(e->gbutton.button);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        if (!capturing()) return false;
        StickKey ch[2];
        int n = stick_to_dpad(e->gaxis.axis, e->gaxis.value / 32767.0f, ch);
        static int padlog = -1;
        if (padlog < 0) padlog = getenv("LARECOMP_MENU_PADLOG") != NULL;
        if (padlog) fprintf(stderr, "[menu] dev %u (%s) t %llu axis %d = %d -> %d key change(s)%s\n", (unsigned)e->gaxis.which, SDL_GetGamepadNameForID(e->gaxis.which) ? SDL_GetGamepadNameForID(e->gaxis.which) : "?", (unsigned long long)(e->gaxis.timestamp / 1000000), e->gaxis.axis, e->gaxis.value, n,
                            n ? (ch[0].down ? " down" : " up") : "");
        for (int i = 0; i < n; i++) { QEvent q = {}; q.kind = QEvent::KEY; q.key = ch[i].key; q.down = ch[i].down; push(q); }
        return true;
    }
    case SDL_EVENT_MOUSE_MOTION:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::MOUSE_POS; q.x = e->motion.x * g_pixel_density; q.y = e->motion.y * g_pixel_density; push(q); }
        return true;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!capturing()) return false;
        {
            QEvent q = {};
            q.kind = QEvent::MOUSE_BUTTON;
            q.button = e->button.button == SDL_BUTTON_LEFT ? 0 : e->button.button == SDL_BUTTON_RIGHT ? 1 : 2;
            q.down = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
            push(q);
        }
        return true;
    case SDL_EVENT_MOUSE_WHEEL:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::WHEEL; q.x = e->wheel.x; q.y = e->wheel.y; push(q); }
        return true;
    default:
        return false;
    }
}

bool menu_pad_to_imgui(const SDL_Event *e) {
    ImGuiIO &io = ImGui::GetIO();
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || e->type == SDL_EVENT_GAMEPAD_BUTTON_UP) {
        ImGuiKey k = key_from_pad(e->gbutton.button);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        return true;
    }
    if (e->type == SDL_EVENT_GAMEPAD_AXIS_MOTION) {
        StickKey ch[2];
        int n = stick_to_dpad(e->gaxis.axis, e->gaxis.value / 32767.0f, ch);
        for (int i = 0; i < n; i++) io.AddKeyEvent(ch[i].key, ch[i].down);
        return true;
    }
    return false;
}

// B (by the layout) or Esc going down: the start screen acts on the event itself (see g_cancel_now)
bool menu_is_cancel_event(const SDL_Event *e) {
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) return key_from_pad(e->gbutton.button) == ImGuiKey_GamepadFaceRight;
    return e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat && e->key.scancode == SDL_SCANCODE_ESCAPE;
}

// (the start screen: its Window row and F11 / Alt+Enter change the window the same way as in game)
void menu_request_window_apply(void) { g_want_fullscreen_apply.store(true); }
bool menu_window_key(const SDL_Event *e) {
    if (e->type != SDL_EVENT_KEY_DOWN || e->key.repeat) return false;
    if (e->key.scancode != SDL_SCANCODE_F11 && !(e->key.scancode == SDL_SCANCODE_RETURN && (e->key.mod & (SDL_KMOD_ALT | SDL_KMOD_GUI))))
        return false;
    static int last_full = WINDOW_BORDERLESS;
    if (g_settings.window_mode != WINDOW_WINDOWED) last_full = g_settings.window_mode, g_settings.window_mode = WINDOW_WINDOWED;
    else g_settings.window_mode = last_full;
    g_want_fullscreen_apply.store(true);
    settings_save();
    return true;
}

void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
    g_pixel_density = SDL_GetWindowPixelDensity(w);
    static bool text_input;
    bool want_text = capturing();
    if (want_text != text_input) {
        if (want_text) SDL_StartTextInput(w);
        else SDL_StopTextInput(w);
        text_input = want_text;
    }
    // F11 / Alt+Enter only: the setting itself is applied where the window is made (ui_window_init) and handed to the game
    // (runtime/ui/launcher_lg.mm window_as_game) - applied here on the first call too, the start screen (which calls this
    // each frame) went back to full screen right after taking its own size
    if (g_want_fullscreen_apply.exchange(false)) {
        window_apply_mode(w);
        if (g_settings.window_mode == WINDOW_WINDOWED) window_restore_geometry(w);  // (the size and place it was left at)
    }
    // View / Minus held: the settings open (or close)
    uint64_t since = g_back_since.load();
    if (since && !g_back_fired.load() && !start_down && g_kbd.load() != 1 && SDL_GetTicks() - since >= HOLD_MS) {
        g_back_fired = true;
        set_cfg(!g_cfg.load());
    }
}

// ------------------------------------------------------------------ render thread
static bool g_inited;
static ImGuiContext *g_ctx;  // ours: the start screen has its own context
extern "C" volatile int g_out_w, g_out_h;  // (runtime/nvn/output_scale.c: the render size, shown by the FPS counter)
static ImFont *g_font, *g_font_big;  // the FPS counter and the name entry
static ImFont *g_menu_font;          // the "close the game?" question (Baloo 2, as on the start screen)

static void init(void) {
    IMGUI_CHECKVERSION();
    ui_pick_language();
    g_ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    // B is ours (cfg_draw): ImGui's own cancel cleared the cursor - one frame or more after ours, its event queue
    // trickles one change per key per frame - and its nav then put it back on the page's last row ("B jumps left, then
    // right back")
    io.ConfigNavEscapeClearFocusItem = false;
    io.ConfigNavEscapeClearFocusWindow = false;
    io.IniFilename = NULL;
    UiFonts f = ui_load_fonts();
    g_font = f.body, g_font_big = f.big, g_menu_font = f.title;
    ui_style();
    vk_imgui_backend_init();
    g_inited = true;
}

// B went down among this frame's events. The settings close on it directly: ImGui's own IsKeyPressed missed the first
// B after a slider was stepped (the nav's cancel took the key to end the slider's tweak), so B had to be pressed twice.
static bool g_cancel_now;
static void drain_events(ImGuiIO &io) {
    pthread_mutex_lock(&q_lock);
    std::vector<QEvent> ev;
    ev.swap(q_events);
    pthread_mutex_unlock(&q_lock);
    g_cancel_now = false;
    for (const QEvent &q : ev) {
        switch (q.kind) {
        case QEvent::KEY:
            if (q.down && (q.key == ImGuiKey_GamepadFaceRight || q.key == ImGuiKey_Escape)) g_cancel_now = true;
            io.AddKeyEvent(q.key, q.down);
            break;
        case QEvent::ANALOG: io.AddKeyAnalogEvent(q.key, q.value > 0.1f, q.value); break;
        case QEvent::MOUSE_POS: io.AddMousePosEvent(q.x, q.y); break;
        case QEvent::MOUSE_BUTTON: io.AddMouseButtonEvent(q.button, q.down); break;
        case QEvent::WHEEL: io.AddMouseWheelEvent(q.x, q.y); break;
        case QEvent::TEXT: io.AddInputCharactersUTF8(q.text); break;
        }
    }
}

// Reboot (runtime/main.c): the game is gone - the question and the name entry close; the ImGui context stays.
RT_ON_RESET(menu_reset) {
    set_open(false);
    set_cfg(false);
    g_kbd = 0;
    osk_cancel();
    pthread_mutex_lock(&q_lock);
    q_events.clear();
    pthread_mutex_unlock(&q_lock);
}

static void keyboard_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 120));
    float w = fminf(io.DisplaySize.x * 0.9f, 1100 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, 0);
    ImGui::Begin("##kbd", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                    ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ui_window_backdrop();
    ImGui::PushFont(g_font_big);
    ImGui::TextColored(UI_TEXT, "%s", M("Enter a name", "Digite o nome", "Введите имя"));
    ImGui::PopFont();
    static bool was_open, was_pad;
    bool pad = g_last_pad.load(), appearing = !was_open || pad != was_pad;  // (switching device: focus the new one)
    was_open = true, was_pad = pad;
    if (!pad) {  // keyboard: type straight into the field
        if (appearing) ImGui::SetKeyboardFocusHere();
        ImGui::SetNextItemWidth(-1);
        ImGui::PushFont(g_font_big);
        ImGui::InputText("##name", g_kbd_text, (size_t)(g_kbd_max * 4 + 1 < (int)sizeof g_kbd_text ? g_kbd_max * 4 + 1 : sizeof g_kbd_text),
                         ImGuiInputTextFlags_CallbackCharFilter,
                         [](ImGuiInputTextCallbackData *d) -> int { return d->EventChar < 0x20 ? 1 : 0; });
        ImGui::PopFont();
        if ((int)strlen(g_kbd_text) > g_kbd_max) g_kbd_text[g_kbd_max] = 0;
        ImGui::TextDisabled("%s      (%d / %d)", M("Enter  confirms      Esc  cancels", "Enter  confirma      Esc  cancela",
                                                   "Enter  готово      Esc  отмена"),
                            (int)strlen(g_kbd_text), g_kbd_max);
    } else {  // controller: on-screen keyboard (osk.mm)
        int r = osk_keys(g_kbd_text, sizeof g_kbd_text, g_kbd_max, appearing, scale, g_font_big);
        if (r) g_kbd = r > 0 ? 2 : 3;  // (Start / + confirms in menu_handle_event too)
    }
    ImGui::End();
    if (g_kbd.load() != 1) was_open = false;
}

// Game thread (runtime/hle/swkbd.c): show the dialog, re-present the last frame until it's answered.
// Returns 1 confirmed (out = text, UTF-8), 0 cancelled.
extern "C" int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    extern void backend_represent(void);
    snprintf(g_kbd_text, sizeof g_kbd_text, "%s", initial ? initial : "");
    g_kbd_max = max_len > 0 && max_len < (int)sizeof g_kbd_text / 4 ? max_len : 8;
    input_reset();
    g_kbd = 1;
    // (test) LARECOMP_KBD_AUTO=<text>: answer at once
    if (getenv("LARECOMP_KBD_AUTO")) { snprintf(g_kbd_text, sizeof g_kbd_text, "%s", getenv("LARECOMP_KBD_AUTO")); g_kbd = 2; }
    while (g_kbd.load() == 1 && !g_rt_unwind) {  // ~60 Hz (a reboot cancels)
        uint64_t t0 = SDL_GetTicks();
        backend_represent();
        uint64_t dt = SDL_GetTicks() - t0;
        if (dt < 16) SDL_Delay((uint32_t)(16 - dt));
    }
    bool ok = g_kbd.load() == 2 && g_kbd_text[0];
    if (ok) snprintf(out, cap, "%s", g_kbd_text);
    g_kbd = 0;
    input_reset();
    return ok;
}

// "Close the game?" - Keep playing has the focus first (A by reflex keeps playing); B / Esc answer it too.
static void quit_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(10, 14, 22, 130));
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(560 * scale, 0), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(32 * scale, 28 * scale));
    ImGui::Begin("##quit", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                     ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    ui_window_backdrop();
    ui_page_title(g_menu_font, M("Close the game?", "Fechar o jogo?", "Закрыть игру?"));
    ImGui::TextDisabled("%s", M("Unsaved progress will be lost.", "O progresso não salvo será perdido.", "Несохранённый прогресс будет потерян."));
    ImGui::Dummy(ImVec2(0, 16 * scale));
    float sp = ImGui::GetStyle().ItemSpacing.x, w = ImGui::GetContentRegionAvail().x, bw = (w - sp) / 2;
    static bool focus_no;
    if (!focus_no) { ImGui::SetKeyboardFocusHere(1); focus_no = true; }
    if (ui_button(M("Quit", "Sair", "Выйти"), bw)) {
        settings_save();
        SDL_Event q = {};
        q.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&q);
    }
    ImGui::SameLine();
    bool no = ui_button_primary(M("Keep playing", "Continuar", "Продолжить"), bw);
    ImGui::Dummy(ImVec2(0, 2 * scale));
    if (ui_button_ghost(M("Settings", "Configurações", "Настройки"), w)) {
        focus_no = false;
        set_cfg(true);  // (closes the question: the way in from a controller)
    } else if (no || g_cancel_now) {
        set_open(false);
        focus_no = false;
    }
    ImGui::End();
}

// The settings (hold View / Minus, F12), applied live; saved to larecomp.ini on closing. The start screen's layout
// (runtime/ui/settings_ui.h) in a centred panel: the sidebar with the pages and Resume / Quit game at its foot, the
// page, the footer. B in a page goes back to its sidebar row, B there closes; L / R change the page.
static void cfg_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(10, 14, 22, 120));
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    float ww = fminf(io.DisplaySize.x * 0.94f, 1340 * scale), wh = fminf(io.DisplaySize.y * 0.90f, 820 * scale);
    ImGui::SetNextWindowSize(ImVec2(ww, wh), ImGuiCond_Always);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##cfg", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse |
                                    ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    ui_window_backdrop();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 wp = ImGui::GetWindowPos();
    float pad = 24 * scale, side_w = 280 * scale, r = ImGui::GetStyle().WindowRounding;
    dl->AddRectFilled(wp, ImVec2(wp.x + side_w, wp.y + wh), UI_COL_SIDE, r, ImDrawFlags_RoundCornersLeft);

    // a list was open last frame too: B then only closes the list (ImGui shuts it in NewFrame, before this)
    static bool popup_prev;
    bool popup_now = ImGui::IsPopupOpen((const char *)NULL, ImGuiPopupFlags_AnyPopupId), popup = popup_now || popup_prev;
    if (g_cancel_now && popup_now) ImGui::ClosePopupsExceptModals();
    enum { NTAB = 4 };
    const char *names[NTAB] = {M("Display", "Tela", "Экран"), M("Graphics", "Gráficos", "Графика"), M("Audio", "Áudio", "Звук"),
                               M("Controls", "Controles", "Управление")};
    // where the cursor is: a sidebar row or the page
    static ImGuiID side_ids[NTAB];
    ImGuiContext &g = *GImGui;
    int on_side = -1;
    for (int t = 0; t < NTAB; t++) if (g.NavId && g.NavId == side_ids[t]) on_side = t;
    int focus_side = -1;
    bool close = false;
    if (g_cfg_fresh) focus_side = g_cfg_tab;  // (just opened: the cursor on the page's row)
    // Where the cursor was at the end of LAST frame (player 2026-11-22: "B jumps back left then right back to the right",
    // "going to the left menu doesn't work sometimes"): ImGui's own cancel / moves run in NewFrame, before this, and could
    // already have moved or cleared the cursor - so the decision uses last frame's place, not this frame's.
    static bool was_in_page;
    if (g_cfg_fresh) was_in_page = false;
    if (!popup) {
        int before = g_cfg_tab;
        ui_tabs_begin(&g_cfg_tab, NTAB);
        if (g_cfg_tab != before && on_side >= 0) focus_side = g_cfg_tab;
        bool left = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft, false) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow, false);
        if (g_cancel_now && !g.ActiveId) {
            if (was_in_page) focus_side = g_cfg_tab;  // (B in a page: back to its row)
            else close = true;
        } else if (left && was_in_page && !g.ActiveId) {
            // left from any row of a page: that page's row (ImGui's own move took the sidebar row level with it - another
            // page - or found nothing below the last one)
            ImGui::NavMoveRequestCancel();
            focus_side = g_cfg_tab;
        }
        if (focus_side >= 0) ImGui::NavMoveRequestCancel();
        if ((g_cancel_now || left) && getenv("LARECOMP_MENU_PADLOG"))
            fprintf(stderr, "[menu] %s: was_in_page %d nav %08x on_side %d active %08x navwin %s -> focus_side %d close %d\n",
                    g_cancel_now ? "B" : "left", was_in_page, g.NavId, on_side, g.ActiveId, g.NavWindow ? g.NavWindow->Name : "-",
                    focus_side, close);
    } else if (g_cancel_now && getenv("LARECOMP_MENU_PADLOG"))
        fprintf(stderr, "[menu] B with a popup (now %d prev %d)\n", popup_now, popup_prev);
    if (on_side >= 0 && on_side != g_cfg_tab && focus_side < 0) g_cfg_tab = on_side;  // (moving through the pages shows them)
    // right from a page's row: its first row (ImGui's own move found nothing on some pages - the Display page's rows sit
    // below the sidebar row, so the move went nowhere)
    bool focus_page = false;
    if (on_side >= 0 && !popup && focus_side < 0 &&
        (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
         ImGui::IsKeyPressed(ImGuiKey_RightArrow))) {
        ImGui::NavMoveRequestCancel();
        focus_page = true;
    }
    g_cfg_fresh = false;

    // ---- the sidebar
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 0.7f, pad));
    ImGui::BeginChild("##side", ImVec2(side_w, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                      ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    static ImGuiWindow *side_win;
    side_win = ImGui::GetCurrentWindow();
    ui_sidebar_brand(g_menu_font, M("Settings", "Configurações", "Настройки"), "Pokémon Sword");
    for (int t = 0; t < NTAB; t++) {
        if (ui_nav_item(names[t], t == g_cfg_tab, focus_side == t)) g_cfg_tab = t;
        side_ids[t] = ImGui::GetItemID();
    }
    // (FocusItem's move request was cancelled by ImGui while the page's rows were drawn - B / left in a page did nothing:
    // the cursor goes straight to the row instead)
    if (focus_side >= 0 && side_ids[focus_side]) {
        ImGui::SetFocusID(side_ids[focus_side], ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        ImGui::NavMoveRequestCancel();
    }
    {   // the foot: Resume (the main action) and Quit game (asks first)
        float bh = 56 * scale, gh = ImGui::GetFrameHeight();
        ImGui::SetCursorPosY(fmaxf(ImGui::GetCursorPosY(), ImGui::GetWindowHeight() - pad - bh - gh - ImGui::GetStyle().ItemSpacing.y));
        if (ui_button_primary(M("Resume", "Continuar", "Продолжить"), -1, bh)) close = true;
        if (ui_button_ghost(M("Quit game", "Sair do jogo", "Выйти из игры"), -1)) {
            set_cfg(false);
            set_open(true);
        }
        ui_tip(M("Save in the game first", "Salve no jogo antes", "Сначала сохраните игру"));
    }
    ImGui::EndChild();

    // ---- the page
    ImGui::SameLine(0, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 1.5f, pad));
    ImGui::BeginChild("##content", ImVec2(0, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                      ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    ui_page_title(g_menu_font, names[g_cfg_tab]);
    ImGui::Dummy(ImVec2(0, 4 * scale));
    float foot = ui_footer_h(), page_h = ImGui::GetContentRegionAvail().y - foot - 8 * scale;
    bool known = swsh60_known();
    ImGui::PushID(g_cfg_tab);  // (each page its own scroll)
    ui_page_begin("##page", ImVec2(0, page_h));
    static int shown = -1;  // (another page by L / R while in a page: the cursor on its first row)
    if ((shown != g_cfg_tab && shown >= 0 && on_side < 0 && focus_side < 0 && GImGui->NavCursorVisible) || focus_page)
        ImGui::SetKeyboardFocusHere();
    shown = g_cfg_tab;
    if (g_cfg_tab == 0) ui_page_display(known, menu_request_window_apply);
    else if (g_cfg_tab == 1) ui_page_graphics(known);
    else if (g_cfg_tab == 2) ui_page_audio();
    else ui_page_controls();
    ui_page_end();
    ImGui::PopID();
    {
        ImVec2 a = ImGui::GetCursorScreenPos(), wpc = ImGui::GetWindowPos();
        a.y += 8 * scale - ImGui::GetStyle().ItemSpacing.y;
        ImVec2 b(wpc.x + ImGui::GetWindowWidth() - pad * 1.5f, a.y + foot);
        ui_footer(a, b, M("Back", "Voltar", "Назад"), true);
    }
    ImGui::EndChild();
    popup_prev = ImGui::IsPopupOpen((const char *)NULL, ImGuiPopupFlags_AnyPopupId);
    {   // (for next frame's B / left: the cursor on a page row = not in the sidebar, with a cursor at all)
        ImGuiWindow *nw = g.NavWindow;
        bool in_side = nw && (nw == side_win || ImGui::IsWindowChildOf(nw, side_win, false));
        bool side_row = false;
        for (int t = 0; t < NTAB; t++) if (g.NavId && g.NavId == side_ids[t]) side_row = true;
        if (focus_side >= 0) was_in_page = false;           // (sent to the sidebar this frame)
        else if (focus_page) was_in_page = true;            // (sent into the page this frame)
        else if (g.NavId && !popup_prev) was_in_page = !in_side && !side_row;
    }
    ImGui::End();
    if (close) {
        set_cfg(false);
    }
}

// The shader preparation's notice (a corner of the screen, no input): progress while the game's shaders are prepared
// for this GPU on the first start, then "ready" for a few seconds.
static void prep_draw(ImGuiIO &io, float scale, int state, float frac) {
    ImGui::SetNextWindowPos(ImVec2(16 * scale, io.DisplaySize.y - 16 * scale), 0, ImVec2(0, 1));
    ImGui::SetNextWindowBgAlpha(0.85f);
    ImGui::Begin("##prep", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs |
                                     ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
    if (state == 1) {
        ImGui::Text(M("Preparing shaders: %d%%", "Preparando shaders: %d%%", "Подготовка шейдеров: %d%%"), (int)(frac * 100));
        ImGui::ProgressBar(frac, ImVec2(380 * scale, 10 * scale), "");
        ImGui::TextDisabled("%s", M("Only on the first start. The game may run slower meanwhile.",
                                    "Só na primeira vez. O jogo pode ficar mais lento enquanto isso.",
                                    "Только при первом запуске. Пока игра может работать медленнее."));
    } else {
        ImGui::TextUnformatted(M("Shaders ready", "Shaders prontos", "Шейдеры готовы"));
    }
    ImGui::End();
}

void menu_render(void *cmd, uint32_t target_w, uint32_t target_h) {
    bool open = g_open.load(), cfg = g_cfg.load(), kbd = g_kbd.load() == 1;
    float fx, fy;
    bool fdown, finger = !open && !cfg && input_finger_cursor(&fx, &fy, &fdown);
    // At the first frame, not when the name entry first opens: by then the game has taken its memory, and on the small
    // integrated GPU of issue #53 the fonts' texture crashed the driver there, in vkBindImageMemory.
    if (!g_inited) {
        init();
        ImGui_ImplVulkan_CreateFontsTexture();
    }
    float prep_frac = 0;
    int prep = shader_prep_progress(&prep_frac);
    // the View / Minus hold: a hint the first time a controller is used, a bar while it is held
    uint64_t t = SDL_GetTicks(), hint_at = g_hint_at.load(), since = g_back_since.load();
    bool hint = hint_at && t - hint_at < 7000 && !open && !cfg && !kbd;
    float hold = since && !g_back_fired.load() && !start_down && !kbd && t - since > 150 ? (float)(t - since) / HOLD_MS : 0;
    if (!open && !cfg && !kbd && !g_settings.show_fps && !finger && !prep && !hint && !hold) {
        if (g_inited) { pthread_mutex_lock(&q_lock); q_events.clear(); pthread_mutex_unlock(&q_lock); }
        return;
    }
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)target_w, (float)target_h);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    static double last;
    double now = SDL_GetTicks() / 1000.0;
    io.DeltaTime = last > 0 && now > last ? (float)(now - last) : 1.0f / 60;
    last = now;
    drain_events(io);
    g_ui_cancel = g_cancel_now && (open || cfg);  // (settings_ui.mm: a popup closed by B restores its value; the back sound)
    // fonts are built for a ~1080 px tall output; scale to the window (spacing / rounding too)
    static UiScaler scaler;
    float scale = ui_scale(scaler, (float)target_h);
    ImGui_ImplVulkan_NewFrame();
    ImGui::NewFrame();

    if (g_settings.show_fps) {
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 16 * scale, 16 * scale), 0, ImVec2(1, 0));
        ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0.5f));  // (dark: over the game, not the menus' look)
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1, 1, 1, 1));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 10 * scale);
        ImGui::Begin("##fps", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                        ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
        if (g_out_w > 0) ImGui::Text("%.0f fps  %dx%d", io.Framerate, g_out_w, g_out_h);
        else ImGui::Text("%.0f fps", io.Framerate);
        ImGui::End();
        ImGui::PopStyleVar();
        ImGui::PopStyleColor(2);
    }
    if (finger) {  // the controller's finger on the touch screen (right stick moves it, ZR touches)
        ImDrawList *dl = ImGui::GetForegroundDrawList();
        float r = 26 * scale;
        dl->AddCircleFilled(ImVec2(fx, fy), r, fdown ? IM_COL32(255, 255, 255, 170) : IM_COL32(255, 255, 255, 60));
        dl->AddCircle(ImVec2(fx, fy), r, IM_COL32(255, 255, 255, 235), 0, 4 * scale);
    }
    if (prep && !open && !cfg) prep_draw(io, scale, prep, prep_frac);
    if (hint || hold) {
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y - 24 * scale), 0, ImVec2(0.5f, 1));
        ImGui::SetNextWindowBgAlpha(0.88f);
        ImGui::Begin("##holdhint", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs |
                                             ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
        const char *txt = cfg ? M("Hold  -  / View: close the settings", "Segure  -  / View: fechar as configurações", "Удерживайте  -  / View: закрыть настройки")
                              : M("Hold  -  / View: settings", "Segure  -  / View: configurações", "Удерживайте  -  / View: настройки");
        ImGui::TextUnformatted(txt);
        if (hold) ImGui::ProgressBar(hold < 1 ? hold : 1, ImVec2(ImGui::CalcTextSize(txt).x, 8 * scale), "");
        ImGui::End();
    }
    if (open) quit_draw(io, scale);
    else if (cfg && !kbd) cfg_draw(io, scale);
    if (kbd) keyboard_draw(io, scale);
    ui_frame_end();
    ImGui::Render();
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)cmd);  // inside the window image's rendering
}
