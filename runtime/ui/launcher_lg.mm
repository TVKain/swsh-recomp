// Pokémon Sword start screen (SwSh Recomp; from Let's Go Recomp 0.6.0's): a launcher's window (no system frame, taller than wide) with a sidebar - the project's
// icon, the pages, Play - and the page beside it: Game (the game files - picked once, set up and recompiled here:
// runtime/gamesetup.c - and the game options), Graphics (the window, then the F12 menu's graphics page:
// runtime/ui/settings_ui.mm), Image and sound (the same as the F12 menu's), Controls (keyboard / mouse) and Mods
// (mods/: game files replaced, a translation for one; installed from a downloaded file: runtime/mods.c). The look is
// the F12 menu's. In English, or in Portuguese when the system's language is (LARECOMP_LANG=en|pt
// chooses; the shared pages speak Russian too). The choices go to larecomp.ini (settings.c; bind_key_* from
// runtime/hle/bindings.c).
// Tests: LARECOMP_LAUNCHER_SHOT=<frame> saves build/launcher.png (or LARECOMP_SHOT_PATH) and exits;
// LARECOMP_LAUNCHER_TAB=<n> opens that page; LARECOMP_LAUNCHER_AUTOPLAY=1 plays as soon as the game files are ready; LARECOMP_SETUP_DIR=<folder> sets them up
// from that folder at once; LARECOMP_MOD_INSTALL=<file or folder> installs a mod at once;
// LARECOMP_LAUNCHER_KEYS=1 opens the Controls page, =<slot> also waits for a new key for that input
// (runtime/input_bind.h BIND_*), and <slot>:<key name> presses that key for it.
#include <SDL3/SDL.h>
#include <float.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_vulkan.h"
#include "imgui_impl_sdl3.h"
#include "settings_ui.h"
#include "ui_sound.h"

extern "C" {
#include "gamesetup.h"
#include "input_bind.h"
#include "mods.h"
#include "paths.h"
#include "settings.h"
void settings_save(void);
void ui_window_init(void);
SDL_Window *ui_window(void);
void menu_apply_window_requests(void *sdl_window);
bool menu_pad_to_imgui(const SDL_Event *e);
extern "C" bool menu_is_cancel_event(const SDL_Event *e);
bool vk_frame_begin(const float clear[4]);
void vk_frame_end(const char *shot_path);
void *vk_frame_cmd(void);
bool vk_imgui_backend_init(void);
bool shader_prep_start_image(const char *romfs_bin);  // runtime/nvn/vulkan/prep.c
int shader_prep_state(void);
int shader_prep_progress(float *frac);
float shader_prep_eta(void);
void vk_imgui_backend_shutdown(void);
bool swsh60_supported(const char *exefs);  // runtime/hle/swsh60.c
}

// ------------------------------------------------------------------ language
// (runtime/ui/settings_ui.h picks it; this screen's own strings are English or Portuguese)
static bool g_pt;
#define T(en, pt) (g_pt ? (pt) : (en))
static float g_scale = 1;  // the window's height over 1080 (ui_scale): fixed sizes below are for 1080 px

// ------------------------------------------------------------------ file dialogs (SDL calls back on any thread)
static pthread_mutex_t g_pick_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_pick_game[MAX_PICK], g_pick_mod[1024], g_pick_keys[1024];
static char g_last_pick[MAX_PICK];  // the last game files picked: set up again once the keys are added
static int g_keys_msg;              // 1 = keys added, 2 = that file wasn't a prod.keys
static void SDLCALL picked_game(void *, const char *const *files, int) {  // (a folder, or package files: one per line)
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_pick_lock);
    g_pick_game[0] = 0;
    for (int i = 0; files[i]; i++) {
        if (i) strncat(g_pick_game, "\n", sizeof g_pick_game - strlen(g_pick_game) - 1);
        strncat(g_pick_game, files[i], sizeof g_pick_game - strlen(g_pick_game) - 1);
    }
    pthread_mutex_unlock(&g_pick_lock);
}
static void pick_packages(SDL_Window *win) {
    static const SDL_DialogFileFilter f[] = {{"Switch game files and keys (.xci, .nsp, prod.keys)", "xci;nsp;keys"}};
    SDL_ShowOpenFileDialog(picked_game, NULL, win, f, 1, NULL, true);
}
static void SDLCALL picked_keys(void *, const char *const *files, int) {
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_pick_lock);
    snprintf(g_pick_keys, sizeof g_pick_keys, "%s", files[0]);
    pthread_mutex_unlock(&g_pick_lock);
}
static void pick_keys(SDL_Window *win) {
    static const SDL_DialogFileFilter f[] = {{"Console keys (prod.keys)", "keys"}};
    SDL_ShowOpenFileDialog(picked_keys, NULL, win, f, 1, NULL, false);
}
static void SDLCALL picked_mod(void *, const char *const *files, int) {
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_pick_lock);
    snprintf(g_pick_mod, sizeof g_pick_mod, "%s", files[0]);
    pthread_mutex_unlock(&g_pick_lock);
}
static bool take(char *slot, char *out, size_t n) {
    pthread_mutex_lock(&g_pick_lock);
    bool got = slot[0] != 0;
    if (got) snprintf(out, n, "%s", slot), slot[0] = 0;
    pthread_mutex_unlock(&g_pick_lock);
    return got;
}

// ------------------------------------------------------------------ the Game page
// A card with the game and its state (ready / setting up / a problem), then the game files' actions and the shaders'
// state as rows
static const ImVec4 &k_green = UI_GREEN_TEXT, &k_red = UI_RED_TEXT;

// a small status dot then text
static void status(const ImVec4 &col, const char *text) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float r = 5 * g_scale, h = ImGui::GetTextLineHeight();
    ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(p.x + r, p.y + h * 0.5f), r, ImGui::GetColorU32(col));
    ImGui::SetCursorScreenPos(ImVec2(p.x + r * 2 + 10 * g_scale, p.y));
    ImGui::TextColored(col, "%s", text);
}

static void game_page(SDL_Window *win, ImFont *title_font) {
    int st = setup_state();
    float s = g_scale, in = ui_inset();
    ui_section(NULL);
    ImGui::Dummy(ImVec2(0, 20 * s));
    ImGui::Indent(in);
    auto title = [&](const char *t) {
        ImGui::PushFont(title_font);
        ImGui::SetWindowFontScale(0.66f);
        ImGui::TextUnformatted(t);
        ImGui::SetWindowFontScale(1);
        ImGui::PopFont();
    };
    if (setup_running()) {
        static const char *const en[] = {"", "Looking for files", "Copying", "Building game data", "Reading game code",
                                         "Recompiling", "Finishing", "Unpacking"};
        static const char *const pt[] = {"", "Procurando arquivos", "Copiando", "Montando dados do jogo", "Lendo o código",
                                         "Recompilando", "Finalizando", "Desempacotando"};
        title(T("Setting up your game", "Preparando seu jogo"));
        char l[96];
        snprintf(l, sizeof l, "%s  ·  %.0f%%", st >= 1 && st <= SETUP_UNPACKING ? T(en[st], pt[st]) : "...", setup_progress() * 100);
        ImGui::TextDisabled("%s", l);
        ImGui::Dummy(ImVec2(0, 4 * s));
        ImGui::ProgressBar(setup_progress(), ImVec2(ImGui::GetContentRegionAvail().x - in, 6 * s), "");
    } else if (setup_ready()) {
        const char *t = game_title("extracted/exefs");
        title(t ? t : "Pokémon");
        status(k_green, T("Ready to play", "Pronto para jogar"));
    } else {
        title(T("Add your game", "Adicione seu jogo"));
        if (st >= SETUP_FAIL_NOT_FOUND) {
            static const char *const en[] = {"No game files found", "Compressed files (.nsz / .xcz) aren't supported", "Not Pokémon Sword or Shield",
                                             "Copy failed: about 45 GB free needed", "Build failed: see lasrecomp.log", "Build tools missing: reinstall",
                                             "Game data incomplete", "Add your prod.keys below", "Unpack failed: see unpack.log", "Add the base game too"};
            static const char *const pt[] = {"Nenhum arquivo do jogo", "Arquivos comprimidos (.nsz / .xcz) não funcionam", "Não é Pokémon Sword ou Shield",
                                             "Falha ao copiar: precisa de uns 45 GB livres", "Falha ao compilar: veja lasrecomp.log", "Faltam ferramentas: reinstale",
                                             "Dados do jogo incompletos", "Adicione seu prod.keys abaixo", "Falha ao desempacotar: veja unpack.log", "Adicione o jogo base também"};
            status(k_red, T(en[st - SETUP_FAIL_NOT_FOUND], pt[st - SETUP_FAIL_NOT_FOUND]));
        } else {
            ImGui::TextDisabled("%s", T("Your game, update, DLC (.xci / .nsp) and prod.keys", "Seu jogo, atualização, DLC (.xci / .nsp) e prod.keys"));
        }
    }
    ImGui::Unindent(in);
    ImGui::Dummy(ImVec2(0, 20 * s));
    ui_section_end();
    if (setup_running()) return;

    ui_section(T("Game files", "Arquivos do jogo"));
    bool have = setup_ready();
    if (ui_action_row(have ? T("Replace game files", "Trocar arquivos do jogo") : T("Choose game files", "Escolher arquivos do jogo"), ".xci / .nsp",
                      have ? 0 : ImGui::GetColorU32(UI_ACCENT)))
        pick_packages(win);
    ui_tip(T("Select the game, update, DLC and prod.keys at once (Ctrl+click)",
             "Selecione jogo, atualização, DLC e prod.keys de uma vez (Ctrl+clique)"));
    if (ui_action_row(T("Use an extracted folder", "Usar uma pasta extraída"))) SDL_ShowOpenFolderDialog(picked_game, NULL, win, NULL, false);
    ui_tip(T("A folder with exefs and romfs, or with your .xci / .nsp files", "Uma pasta com exefs e romfs, ou com seus .xci / .nsp"));
    if (!have) {  // the console keys: only needed to unpack .xci / .nsp
        static double next_check;
        static bool found;
        static char where[1100];
        if (ImGui::GetTime() >= next_check) found = setup_keys_found(where, sizeof where), next_check = ImGui::GetTime() + 1;
        const char *v = g_keys_msg == 2 ? T("Not a prod.keys file", "Não é um prod.keys")
                        : found          ? T("Found", "Encontradas")
                                         : T("Choose prod.keys", "Escolher prod.keys");
        ImU32 c = g_keys_msg == 2 ? ImGui::GetColorU32(k_red) : found ? ImGui::GetColorU32(k_green) : ImGui::GetColorU32(UI_ACCENT);
        if (ui_action_row(T("Console keys", "Chaves do console"), v, c)) pick_keys(win);
        ui_tip(found ? T("Kept for unpacking .xci / .nsp. Click to use another file", "Guardadas para .xci / .nsp. Clique para trocar")
                     : T("prod.keys from your own Switch (Lockpick_RCM). Needed for .xci / .nsp only",
                         "prod.keys do seu próprio Switch (Lockpick_RCM). Só para .xci / .nsp"));
    }
    ui_section_end();

    if (have) {  // (the shaders are prepared here while the settings are looked at: nvn/vulkan/prep.c)
        ui_section(T("Shaders", "Shaders"));
        float frac = 0;
        int prep = shader_prep_state(), pr = shader_prep_progress(&frac);
        char v[64];
        if (prep == 1 && pr == 1) snprintf(v, sizeof v, "%s  %.0f%%", T("Preparing", "Preparando"), frac * 100);
        else snprintf(v, sizeof v, "%s", T("Ready", "Prontos"));
        ui_row(T("Shader cache", "Cache de shaders"));
        ui_value_button("##prep", v, prep == 1 && pr == 1 ? ImGui::GetColorU32(UI_ACCENT) : ImGui::GetColorU32(k_green));
        ui_tip(T("Built once for your GPU", "Feito uma vez para a sua GPU"));
        ui_section_end();
    }
}

// ------------------------------------------------------------------ the Mods tab
// The folders under mods/ that hold a romfs/ (runtime/mods.h): one active at a time, or none (the game as it is)
static const char *lang_name(const char *code) {
    static const struct { const char *code, *en, *pt; } k[] = {
        {"en-US", "English", "inglês"}, {"es", "Spanish", "espanhol"}, {"fr", "French", "francês"}, {"de", "German", "alemão"},
        {"it", "Italian", "italiano"}, {"ja", "Japanese", "japonês"}, {"ko", "Korean", "coreano"},
        {"zh-CN", "Simplified Chinese", "chinês simplificado"}, {"zh-TW", "Traditional Chinese", "chinês tradicional"}};
    for (size_t i = 0; i < sizeof k / sizeof k[0]; i++) if (!strcmp(k[i].code, code)) return T(k[i].en, k[i].pt);
    return code;
}

// The mods in their order (the active ones first, as larecomp.ini lists them: "<name>|<name>..."), and which are on
static char g_mods[MODS_MAX][128];
static bool g_mod_on[MODS_MAX];
static int g_nmods;
// Reads mods/ again: the names in `active` ('|' between them) on and first, in that order; the rest after, off
static void mods_reload(const char *active) {
    char found[MODS_MAX][128];
    int n = mods_list(found, MODS_MAX);
    bool used[MODS_MAX] = {};
    g_nmods = 0;
    char list[sizeof g_settings.mod];
    snprintf(list, sizeof list, "%s", active);
    for (char *save = NULL, *name = strtok_r(list, "|", &save); name; name = strtok_r(NULL, "|", &save))
        for (int i = 0; i < n; i++)
            if (!used[i] && !strcmp(found[i], name)) {
                used[i] = true;
                snprintf(g_mods[g_nmods], sizeof g_mods[0], "%s", found[i]);
                g_mod_on[g_nmods++] = true;
            }
    for (int i = 0; i < n; i++)
        if (!used[i]) snprintf(g_mods[g_nmods], sizeof g_mods[0], "%s", found[i]), g_mod_on[g_nmods++] = false;
}
// The active ones, in order, as larecomp.ini keeps them
static void mods_active(char *out, size_t cap) {
    out[0] = 0;
    for (int i = 0; i < g_nmods; i++)
        if (g_mod_on[i]) {
            if (out[0]) strncat(out, "|", cap - strlen(out) - 1);
            strncat(out, g_mods[i], cap - strlen(out) - 1);
        }
}

static void mods_section(SDL_Window *win, int inst) {
    static const SDL_DialogFileFilter filters[] = {{"Mod (.zip, .rar, .7z)", "zip;rar;7z"}};
    // each mod a row with its switch (A / a click). X / Y on a controller (Page Up / Down on the keyboard), or the
    // arrows beside the switch, move it up / down: higher wins.
    ui_section(T("Installed  ·  higher wins", "Instalados  ·  o de cima vence"));
    int move = -1, dir = 0;
    float s = g_scale;
    for (int i = 0; i < g_nmods; i++) {
        ImGui::PushID(i);
        char name[64];
        if (strlen(g_mods[i]) > 40) snprintf(name, sizeof name, "%.37s...", g_mods[i]);
        else snprintf(name, sizeof name, "%s", g_mods[i]);
        ui_toggle("##on", name, 0, &g_mod_on[i]);
        ImRect bb(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
        bool focused = ImGui::IsItemFocused();
        const char *lang = mod_language(g_mods[i]);
        char tip[320];
        if (lang) snprintf(tip, sizeof tip, g_pt ? "Troca os textos em %s  ·  X / Y move" : "Replaces the %s texts  ·  X / Y moves it", lang_name(lang));
        else snprintf(tip, sizeof tip, "%s", g_pt ? "X / Y move para cima / baixo" : "X / Y move it up / down");
        ui_tip(tip);
        if (focused && i > 0 && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceUp, false) || ImGui::IsKeyPressed(ImGuiKey_PageUp, false))) move = i, dir = -1;
        if (focused && i < g_nmods - 1 && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceLeft, false) || ImGui::IsKeyPressed(ImGuiKey_PageDown, false))) move = i, dir = 1;
        // the mouse's arrows, left of the switch (drawn, not items: the row is one button)
        float h = bb.GetHeight(), sw = h * 0.9f, ax = bb.Max.x - ui_inset() - sw - h * 1.6f, cy = bb.GetCenter().y;
        ImDrawList *dl = ImGui::GetWindowDrawList();
        for (int k = 0; k < 2; k++) {
            bool en = k == 0 ? i > 0 : i < g_nmods - 1;
            ImVec2 c(ax + k * h * 0.75f, cy);
            ImRect hr(ImVec2(c.x - h * 0.33f, cy - h * 0.38f), ImVec2(c.x + h * 0.33f, cy + h * 0.38f));
            bool hov = en && ImGui::IsMouseHoveringRect(hr.Min, hr.Max);
            if (hov) dl->AddRectFilled(hr.Min, hr.Max, IM_COL32(0, 0, 0, 16), 6 * s);
            float a = h * 0.12f, up = k == 0 ? -1.0f : 1.0f;
            ImVec2 pts[3] = {ImVec2(c.x - a, cy - up * a * 0.5f), ImVec2(c.x, cy + up * a * 0.5f), ImVec2(c.x + a, cy - up * a * 0.5f)};
            dl->AddPolyline(pts, 3, ImGui::GetColorU32(en ? UI_MUTED : ImVec4(UI_MUTED.x, UI_MUTED.y, UI_MUTED.z, 0.3f)), 0, 2 * s);
            if (hov && ImGui::IsMouseClicked(0)) move = i, dir = k == 0 ? -1 : 1;
        }
        ImGui::PopID();
    }
    if (move >= 0) {  // (swapped with the one above / below it)
        int j = move + dir;
        char name[128];
        bool on = g_mod_on[move];
        memcpy(name, g_mods[move], sizeof name), memcpy(g_mods[move], g_mods[j], sizeof name), memcpy(g_mods[j], name, sizeof name);
        g_mod_on[move] = g_mod_on[j], g_mod_on[j] = on;
    }
    if (!g_nmods) {
        ImGui::BeginDisabled();
        ui_row(T("No mods installed", "Nenhum mod instalado"));
        ImGui::Dummy(ImVec2(0, ImGui::GetFrameHeight()));
        ImGui::EndDisabled();
    }
    ui_section_end();
    ui_section(NULL);
    if (inst == MOD_INSTALL_RUNNING) {
        ImGui::BeginDisabled();
        ui_action_row(T("Installing...", "Instalando..."));
        ImGui::EndDisabled();
    } else if (ui_action_row(T("Install a mod", "Instalar um mod"), ".zip / .rar / .7z")) {
        SDL_ShowOpenFileDialog(picked_mod, NULL, win, filters, 1, NULL, false);
    }
    ui_tip(T("romfs mods only", "Só mods de romfs"));
    if (ui_action_row(T("Open mods folder", "Abrir pasta de mods"))) {
        char url[1200];
        snprintf(url, sizeof url, "file:///%s", mods_dir_abs());
        for (char *c = url; *c; c++) if (*c == '\\') *c = '/';
        SDL_OpenURL(url);
    }
    ui_section_end();
    if (inst == MOD_INSTALL_FAIL_UNPACK || inst == MOD_INSTALL_FAIL_NOT_MOD)
        ImGui::TextColored(k_red, "%s", inst == MOD_INSTALL_FAIL_UNPACK ? T("Couldn't open that file", "Não deu para abrir o arquivo")
                                                                        : T("No romfs mod in that file", "Nenhum mod de romfs no arquivo"));
}

// ------------------------------------------------------------------ the launcher's window
// The start screen uses the game's own window as larecomp.ini has it (2026-11-22, player: "the launcher should follow the
// window settings"): windowed (its size and place, maximized or not), borderless or exclusive full screen. Its Window
// row and F11 / Alt+Enter change it live, moving / resizing it is remembered like in game. Its own minimize / close
// buttons show only when there is no system frame (full screen). LARECOMP_WINDOW: a test window that size.
void menu_request_window_apply(void);
bool menu_window_key(const SDL_Event *e);
static void window_as_launcher(SDL_Window *win) {
    SDL_SetWindowHitTest(win, NULL, NULL);
    SDL_SetWindowBordered(win, true);
    SDL_SetWindowResizable(win, true);
}
static void window_as_game(SDL_Window *win) {
    if (!getenv("LARECOMP_LAUNCHER_SHOT")) window_remember(win);  // (as the start screen left it)
    window_apply_mode(win);
    // black at the new size until the game draws (else the launcher's last image stayed in a corner while it loads);
    // vk_frame_begin makes the swapchain again for the new size
    SDL_SyncWindow(win);
    SDL_PumpEvents();
    static const float black[4] = {0, 0, 0, 1};
    for (int i = 0; i < 3; i++)
        if (vk_frame_begin(black)) vk_frame_end(NULL);
}

// A window button in the top right corner (minimize: a line, close: an X), drawn so no font is needed
static bool window_button(const char *id, bool close, float size) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    bool hit = ImGui::InvisibleButton(id, ImVec2(size, size));
    ImDrawList *dl = ImGui::GetWindowDrawList();
    if (ImGui::IsItemHovered())
        dl->AddRectFilled(p, ImVec2(p.x + size, p.y + size), close ? IM_COL32(220, 50, 40, 255) : IM_COL32(0, 0, 0, 18), size * 0.25f);
    ImU32 col = close && ImGui::IsItemHovered() ? IM_COL32(255, 255, 255, 255) : IM_COL32(100, 106, 116, 255);
    float m = size * 0.36f, t = size * 0.045f > 1 ? size * 0.045f : 1;
    if (close) {
        dl->AddLine(ImVec2(p.x + m, p.y + m), ImVec2(p.x + size - m, p.y + size - m), col, t);
        dl->AddLine(ImVec2(p.x + size - m, p.y + m), ImVec2(p.x + m, p.y + size - m), col, t);
    } else {
        dl->AddLine(ImVec2(p.x + m, p.y + size * 0.5f), ImVec2(p.x + size - m, p.y + size * 0.5f), col, t);
    }
    return hit;
}

// ------------------------------------------------------------------ the start screen
extern "C" void launcher_lg_run(const char *root) {
    ui_pick_language();
    g_pt = g_ui_lang == 1;
    ui_window_init();
    SDL_Window *win = ui_window();
    window_as_launcher(win);
    ImGuiContext *prev_ctx = ImGui::GetCurrentContext();  // (the in-game menu's, when back here after a reboot)
    ImGuiContext *ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.ConfigNavEscapeClearFocusItem = false;  // (B is handled by us: ImGui's own cancel cleared the cursor a frame later
    io.ConfigNavEscapeClearFocusWindow = false; //  and then put it back on the page's last row)
    io.IniFilename = NULL;
    UiFonts fonts = ui_load_fonts();
    ui_style();
    UiScaler scaler;
    ImGui_ImplSDL3_InitForVulkan(win);
    // the controller from SDL's events (menu_pad_to_imgui: every pad, A / B by the layout), not the backend's polling of
    // the first pad only (on the MSI Claw it gave the start screen no controller at all)
    ImGui_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode_Manual, NULL, 0);
    {
        int n = 0;
        SDL_JoystickID *ids = SDL_GetGamepads(&n);
        for (int i = 0; i < n; i++) {
            SDL_Gamepad *g = SDL_OpenGamepad(ids[i]);
            if (getenv("LARECOMP_LAUNCHER_PADLOG")) fprintf(stderr, "[launcher] pad %d: %s\n", i, g ? SDL_GetGamepadName(g) : SDL_GetError());
        }
        SDL_free(ids);
    }
    vk_imgui_backend_init();

    bool wildb = g_settings.wild_battle, skipc = g_settings.skip_controller;
    mods_reload(g_settings.mod);  // (the folders under mods/: runtime/mods.h)
    long shot_at = getenv("LARECOMP_LAUNCHER_SHOT") ? atol(getenv("LARECOMP_LAUNCHER_SHOT")) : 0, frame = 0;
    bool autoplay = getenv("LARECOMP_LAUNCHER_AUTOPLAY") != NULL, play = false;
    const char *keys_test = getenv("LARECOMP_LAUNCHER_KEYS");
    enum { TAB_GAME, TAB_DISPLAY, TAB_GRAPHICS, TAB_AUDIO, TAB_CONTROLS, TAB_MODS, NTABS };
    int tab = getenv("LARECOMP_LAUNCHER_TAB") ? atoi(getenv("LARECOMP_LAUNCHER_TAB")) : keys_test ? TAB_CONTROLS : TAB_GAME;
    if (keys_test && atoi(keys_test) > 0) bind_capture_begin(BIND_DEV_KEY, atoi(keys_test));
    if (getenv("LARECOMP_SETUP_DIR")) {  // (a folder, or package files with '|' between them)
        static char list[MAX_PICK];
        snprintf(list, sizeof list, "%s", getenv("LARECOMP_SETUP_DIR"));
        for (char *c = list; *c; c++) if (*c == '|') *c = '\n';
        setup_start(list);
    }
    if (getenv("LARECOMP_MOD_INSTALL")) mod_install_start(getenv("LARECOMP_MOD_INSTALL"));
    static const float bg[4] = {0.953f, 0.961f, 0.976f, 1};  // (the page's flat background: UI_COL_BG)

    while (!play) {
        menu_apply_window_requests(win);
        SDL_Event e;
        bool focus_back = false, cancel_ev = false;
        while (SDL_PollEvent(&e)) {
            if (bind_capture_event(&e)) continue;  // (waiting for a new key: the press is the binding's)
            if (menu_is_cancel_event(&e)) cancel_ev = true;
            if (e.type == SDL_EVENT_GAMEPAD_ADDED) SDL_OpenGamepad(e.gdevice.which);  // (events come from opened pads only)
            if (getenv("LARECOMP_LAUNCHER_PADLOG") && (e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || e.type == SDL_EVENT_GAMEPAD_ADDED))
                fprintf(stderr, "[launcher] frame %ld pad event %x button %d  nav %s %08x visible %d\n", frame, e.type, e.gbutton.button,
                        GImGui->NavWindow ? GImGui->NavWindow->Name : "-", GImGui->NavId, GImGui->NavCursorVisible);
            if (menu_pad_to_imgui(&e)) continue;
            if (menu_window_key(&e)) continue;  // F11 / Alt+Enter
            if (e.type == SDL_EVENT_WINDOW_MOVED || e.type == SDL_EVENT_WINDOW_RESIZED || e.type == SDL_EVENT_WINDOW_MAXIMIZED ||
                e.type == SDL_EVENT_WINDOW_RESTORED)
                window_remember(win);
            ImGui_ImplSDL3_ProcessEvent(&e);
            if (e.type == SDL_EVENT_QUIT) exit(0);
            if (e.type == SDL_EVENT_WINDOW_FOCUS_GAINED) focus_back = true;
        }
        {   // the Automatic controller layout follows the first controller here too (in game: runtime/hle/input.c)
            int n = 0;
            SDL_JoystickID *ids = SDL_GetGamepads(&n);
            if (n > 0) {
                SDL_GamepadType t = SDL_GetGamepadTypeForID(ids[0]);
                bind_pad_kind(t == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO || t == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT ||
                              t == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT || t == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR);
            }
            SDL_free(ids);
        }
        static char path[MAX_PICK];
        if (take(g_pick_game, path, sizeof path)) {
            snprintf(g_last_pick, sizeof g_last_pick, "%s", path);
            setup_start(path);
        }
        if (take(g_pick_keys, path, sizeof path)) {  // keys added: the game files waiting for them are set up now
            g_keys_msg = setup_import_keys(path) ? 1 : 2;
            if (g_keys_msg == 1 && !setup_running() && setup_state() == SETUP_FAIL_KEYS && g_last_pick[0]) setup_start(g_last_pick);
        }
        {   // a new version over set-up game files: its game code is rebuilt by itself (once: a failure shows and waits).
            // From Let's Go Recomp (db1b439): the library id follows the generator, so an update asked for the folder again.
            static bool rebuilt;
            if (!rebuilt && !setup_running() && setup_needs_build()) {
                rebuilt = true;
                setup_start(NULL);
            }
        }
        if (take(g_pick_mod, path, sizeof path)) mod_install_start(path);
        static int last_install;
        int inst = mod_install_state();
        if ((inst != last_install && inst == MOD_INSTALL_DONE) || focus_back) {  // a new mod (installed, or copied by hand)
            char was[sizeof g_settings.mod], want[sizeof g_settings.mod + 130];
            mods_active(was, sizeof was);
            if (inst != last_install && inst == MOD_INSTALL_DONE) snprintf(want, sizeof want, "%s%s%s", mod_install_name(), was[0] ? "|" : "", was);
            else snprintf(want, sizeof want, "%s", was);  // (a new one installed: on, and first)
            mods_reload(want);
        }
        last_install = inst;
        bool ready = !setup_running() && setup_ready();
        if (ready && !shader_prep_state()) {  // (shaders prepared here, while the options are looked at: nvn/vulkan/prep.c)
            char img[1100];
            snprintf(img, sizeof img, "%s/romfs.bin", root && *root ? root : "extracted");
            shader_prep_start_image(img);
        }
        if (autoplay && ready && inst != MOD_INSTALL_RUNNING) play = true;
        if (!vk_frame_begin(bg)) { SDL_Delay(16); continue; }
        if (keys_test && strchr(keys_test, ':') && frame == 5) {  // "<slot>:<key name>": the key pressed for the test
            SDL_Event k = {};
            k.type = SDL_EVENT_KEY_DOWN;
            k.key.scancode = SDL_GetScancodeFromName(strchr(keys_test, ':') + 1);
            k.key.down = true;
            SDL_PushEvent(&k);
        }
        if (getenv("LARECOMP_LAUNCHER_PAD")) {  // (test) "<frame>:<button>,...": a controller press there (up the next frame: a long one repeats while frames are slow)
            char spec[400];
            snprintf(spec, sizeof spec, "%s", getenv("LARECOMP_LAUNCHER_PAD"));
            for (char *tok = strtok(spec, ","); tok; tok = strtok(NULL, ",")) {
                long at = atol(tok);
                const char *c = strchr(tok, ':');
                if (c && c[1] == '~' && (frame == at || frame == at + 1)) {  // "~lx+" / "~ly-": the left stick pushed that way
                    SDL_Event p = {};
                    p.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
                    p.gaxis.axis = c[3] == 'x' ? SDL_GAMEPAD_AXIS_LEFTX : SDL_GAMEPAD_AXIS_LEFTY;
                    p.gaxis.value = frame == at ? (c[4] == '-' ? -30000 : 30000) : 0;
                    SDL_PushEvent(&p);
                    continue;
                }
                int b = c ? bind_pad_from_name(c + 1) : -1;
                if (b < 0 || (frame != at && frame != at + 1)) continue;
                SDL_Event p = {};
                p.type = frame == at ? SDL_EVENT_GAMEPAD_BUTTON_DOWN : SDL_EVENT_GAMEPAD_BUTTON_UP;
                p.gbutton.button = (Uint8)b;
                p.gbutton.down = frame == at;
                SDL_PushEvent(&p);
            }
        }
        ImGui_ImplVulkan_NewFrame();
        ImGui_ImplSDL3_NewFrame();
        io.BackendFlags |= ImGuiBackendFlags_HasGamepad;  // (the backend clears it with no pad of its own: ImGui would drop ours)
        g_scale = ui_scale(scaler, io.DisplaySize.y * 1.08f);
        g_ui_cancel = cancel_ev;  // (settings_ui.mm: a slider popup closed by B restores its value)
        ImGui::NewFrame();
        // The sidebar (pages, Play, Quit): moving onto a page shows it, B (or Esc) in a page goes back to that page's row.
        static ImGuiID side_ids[NTABS + 2];  // (the pages, Play, Quit)
        int focus_side = -1;
        bool focus_page = false;  // (right from the sidebar: the page's first row)
        bool popup;
        int cur = -1;
        {
            ImGuiContext &g = *GImGui;
            for (int i = 0; i <= NTABS + 1; i++) if (g.NavId && g.NavId == side_ids[i]) cur = i;
            // (a list open last frame: B closed it in NewFrame - that B must not also leave the page)
            static bool popup_prev;
            bool popup_now = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId | ImGuiPopupFlags_AnyPopupLevel);
            popup = popup_now || popup_prev;
            popup_prev = popup_now;
            if (cancel_ev && popup_now) ImGui::ClosePopupsExceptModals();  // (B closes a list itself: see menu.mm cfg_draw)
            // ImGui moves the cursor itself (up / down in the sidebar, right into the page); a page's row under it shows
            // that page
            if (cur >= 0 && cur < NTABS && cur != tab) tab = cur;
            static int cur_logged = -2;
            if (cur != cur_logged && getenv("LARECOMP_LAUNCHER_PADLOG")) fprintf(stderr, "[launcher] frame %ld cursor on sidebar row %d, page %d\n", frame, cur, tab);
            cur_logged = cur;
            bool right = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
                         ImGui::IsKeyPressed(ImGuiKey_RightArrow);
            if (cur >= 0 && cur < NTABS && right && !popup) {  // (right from a page's row: its first row)
                ImGui::NavMoveRequestCancel();
                focus_page = true;
            } else
            if (cur < 0 && side_ids[tab] && !popup && (cancel_ev || ((ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                                                                             ImGui::IsKeyPressed(ImGuiKey_Escape, false)) && !g.ActiveId))) {
                // (B on the event itself: after a slider was stepped ImGui's cancel took the key and B had to go twice)
                if (g.ActiveId) ImGui::ClearActiveID();
                focus_side = tab;
            } else if (cur < 0 && g.NavId && side_ids[tab] && !popup && !g.ActiveId &&
                       (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft, false) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow, false))) {
                // left from a page's row: that page's row (as in game, menu.mm cfg_draw - ImGui's own move took the row
                // level with it, another page)
                ImGui::NavMoveRequestCancel();
                focus_side = tab;
            }
            if (focus_side >= 0) ImGui::NavMoveRequestCancel();
        }
        float s = g_scale;
        // (the 60 fps mode: runtime/hle/swsh60.c knows the build; before the game files are set up, offered)
        bool known = !setup_ready() || swsh60_supported("extracted/exefs");
        const char *names[NTABS] = {T("Game", "Jogo"), T("Display", "Tela"), T("Graphics", "Gráficos"), T("Audio", "Áudio"),
                                    T("Controls", "Controles"), "Mods"};
        if (!popup) {  // (L1 / R1 on a controller: the page before / after; the cursor follows it in the sidebar)
            int before = tab;
            ui_tabs_begin(&tab, NTABS);
            if (tab != before && cur >= 0 && cur < NTABS) focus_side = tab;
        }

        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
        ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                             ImGuiWindowFlags_NoBringToFrontOnFocus);
        ImGui::PopStyleVar(2);
        ui_window_backdrop();
        float pad = 24 * s, side_w = 280 * s;
        ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(0, 0), ImVec2(side_w, io.DisplaySize.y), UI_COL_SIDE);

        // ---- the sidebar: the mark and the name, the pages, Play and Quit at its foot
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 0.7f, pad));
        ImGui::BeginChild("##side", ImVec2(side_w, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                          ImGuiWindowFlags_NoScrollbar);
        ImGui::PopStyleVar();
        {
            const char *gt = setup_ready() ? game_title("extracted/exefs") : NULL;
            ui_sidebar_brand(fonts.title, gt ? gt : "Pokémon Sword", "v" RT_APP_VERSION);
            for (int t = 0; t < NTABS; t++) {
                if (ui_nav_item(names[t], tab == t, focus_side == t)) tab = t;
                side_ids[t] = ImGui::GetItemID();
            }
            if (focus_side >= 0 && focus_side < NTABS && side_ids[focus_side]) {  // (FocusItem's request was cancelled by the page's rows)
                ImGui::SetFocusID(side_ids[focus_side], ImGui::GetCurrentWindow());
                ImGui::SetNavCursorVisible(true);
            }
            float play_h = 56 * s;
            // the shader preparation, above Play: one line and a thin bar (nvn/vulkan/prep.c)
            int prep = ready ? shader_prep_state() : 0;
            float prep_frac = 0;
            bool preparing = prep == 1 && shader_prep_progress(&prep_frac) == 1;
            float card_h = preparing ? ImGui::GetTextLineHeightWithSpacing() + 22 * s : 0;
            float quit_h = ImGui::GetFrameHeight() + ImGui::GetStyle().ItemSpacing.y;
            ImGui::SetCursorPosY(fmaxf(ImGui::GetCursorPosY(), ImGui::GetWindowHeight() - pad - play_h - quit_h - card_h));
            if (preparing) {
                float eta = shader_prep_eta();
                char line[64];
                snprintf(line, sizeof line, "Shaders  %.0f%%", prep_frac * 100);
                if (eta >= 90) snprintf(line, sizeof line, "Shaders  %.0f%%  ·  %.0f min", prep_frac * 100, ceilf(eta / 60));
                else if (eta >= 0) snprintf(line, sizeof line, "Shaders  %.0f%%  ·  %.0f s", prep_frac * 100, eta);
                ImGui::TextDisabled("%s", line);
                ImGui::ProgressBar(prep_frac, ImVec2(-FLT_MIN, 4 * s), "");
                ImGui::Dummy(ImVec2(0, 8 * s));
            }
            // the cursor starts on Play (and comes back to it when nothing has it)
            bool focus_play = ready && focus_side < 0 && !focus_page && (frame < 3 || GImGui->NavId == 0);
            ImGui::BeginDisabled(!ready);
            if (ui_button_primary(T("Play", "Jogar"), -1, play_h)) {
                if (preparing) ImGui::OpenPopup("##prepwarn");
                else play = true;
            }
            ImGui::EndDisabled();
            side_ids[NTABS] = ImGui::GetItemID();
            if (focus_play) { ImGui::FocusItem(); if (frame < 3) ImGui::SetNavCursorVisible(true); }
            if (focus_side == NTABS) { ImGui::FocusItem(); ImGui::SetNavCursorVisible(true); }
            if (!ready && ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
                ImGui::SetTooltip("%s", T("Add your game first", "Adicione seu jogo antes"));
            if (ui_button_ghost(T("Quit", "Sair"), -1)) {
                settings_save();
                exit(0);
            }
            side_ids[NTABS + 1] = ImGui::GetItemID();
            if (focus_side == NTABS + 1) { ImGui::FocusItem(); ImGui::SetNavCursorVisible(true); }
            // Play while the shaders are being prepared: one line, two answers
            ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
            ImGui::SetNextWindowSize(ImVec2(480 * s, 0));
            ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 1.2f, pad));
            if (ImGui::BeginPopupModal("##prepwarn", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize)) {
                ui_page_title(fonts.title, g_pt ? "Shaders ainda preparando" : "Shaders still preparing");
                ImGui::TextDisabled(g_pt ? "%.0f%% prontos. O jogo pode engasgar até terminar." : "%.0f%% ready. The game may stutter until done.",
                                    prep_frac * 100);
                ImGui::Dummy(ImVec2(0, 12 * s));
                float bw = (ImGui::GetContentRegionAvail().x - ImGui::GetStyle().ItemSpacing.x) * 0.5f;
                if (ui_button(T("Wait", "Esperar"), bw) || ImGui::IsKeyPressed(ImGuiKey_Escape) || cancel_ev) ImGui::CloseCurrentPopup();
                ImGui::SameLine();
                if (ui_button_primary(T("Play anyway", "Jogar assim"), bw)) { play = true; ImGui::CloseCurrentPopup(); }
                ImGui::EndPopup();
            }
            ImGui::PopStyleVar();
        }
        ImGui::EndChild();

        // ---- the page: one centred column (the same width as the in-game settings' page), the title, the sections,
        // the footer
        ImGui::SameLine(0, 0);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 1.5f, pad));
        ImGui::BeginChild("##content", ImVec2(0, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                          ImGuiWindowFlags_NoScrollbar);
        ImGui::PopStyleVar();
        {
            if (SDL_GetWindowFlags(win) & SDL_WINDOW_FULLSCREEN) {  // (full screen: no system frame - its own buttons)
                ImVec2 back = ImGui::GetCursorScreenPos(), wp = ImGui::GetWindowPos();
                float bsz = 36 * s, gap = 4 * s, x = wp.x + ImGui::GetWindowWidth() - pad * 0.5f - bsz * 2 - gap, y = wp.y + pad * 0.5f;
                ImGui::SetCursorScreenPos(ImVec2(x, y));
                if (window_button("##min", false, bsz)) SDL_MinimizeWindow(win);
                ImGui::SetCursorScreenPos(ImVec2(x + bsz + gap, y));
                if (window_button("##close", true, bsz)) exit(0);
                ImGui::SetCursorScreenPos(back);
            }
            float avail = ImGui::GetContentRegionAvail().x, col = fminf(avail, 1000 * s), x0 = ImGui::GetCursorPosX() + (avail - col) * 0.5f;
            ImGui::SetCursorPosX(x0);
            ui_page_title(fonts.title, names[tab]);
            ImGui::Dummy(ImVec2(0, 4 * s));
            float foot = ui_footer_h(), page_h = ImGui::GetContentRegionAvail().y - foot - 8 * s;
            ImGui::SetCursorPosX(x0);
            ImGui::PushID(tab);
            ui_page_begin("##page", ImVec2(col, page_h));
            if (focus_page) ImGui::SetKeyboardFocusHere();
            if (tab == TAB_GAME) game_page(win, fonts.title);
            else if (tab == TAB_DISPLAY) ui_page_display(known, menu_request_window_apply);
            else if (tab == TAB_GRAPHICS) ui_page_graphics(known);
            else if (tab == TAB_AUDIO) ui_page_audio();
            else if (tab == TAB_CONTROLS) ui_page_controls();
            else mods_section(win, inst);
            ui_page_end();
            ImGui::PopID();
            ImVec2 a = ImGui::GetCursorScreenPos();
            a.x = ImGui::GetWindowPos().x + x0;
            a.y += 8 * s - ImGui::GetStyle().ItemSpacing.y;
            ui_footer(a, ImVec2(a.x + col, a.y + foot), T("Back", "Voltar"), true);
        }
        ImGui::EndChild();
        ImGui::End();

        ui_frame_end();
        ImGui::Render();
        ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)vk_frame_cmd());
        bool shot = shot_at && ++frame == shot_at;
        if (shot && getenv("LARECOMP_LAUNCHER_PADLOG"))
            fprintf(stderr, "[launcher] end: tab %d nav %s %08x visible %d rect %.0f,%.0f-%.0f,%.0f\n", tab,
                    GImGui->NavWindow ? GImGui->NavWindow->Name : "-", GImGui->NavId, GImGui->NavCursorVisible,
                    GImGui->NavWindow ? GImGui->NavWindow->NavRectRel[0].Min.x + GImGui->NavWindow->Pos.x : 0,
                    GImGui->NavWindow ? GImGui->NavWindow->NavRectRel[0].Min.y + GImGui->NavWindow->Pos.y : 0,
                    GImGui->NavWindow ? GImGui->NavWindow->NavRectRel[0].Max.x + GImGui->NavWindow->Pos.x : 0,
                    GImGui->NavWindow ? GImGui->NavWindow->NavRectRel[0].Max.y + GImGui->NavWindow->Pos.y : 0);
        if (!shot_at) frame++;
        vk_frame_end(shot ? (getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png") : NULL);
        if (shot) exit(0);
    }
    g_settings.fullscreen = g_settings.window_mode != WINDOW_WINDOWED;  // (the row and F11 already set it)
    ui_sound(UI_SND_PLAY);
    settings_apply_levels();  // (the upscaler follows the anti-aliasing)
    g_settings.wild_battle = wildb;
    g_settings.skip_controller = skipc;
    mods_active(g_settings.mod, sizeof g_settings.mod);
    settings_save();
    vk_imgui_backend_shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext(ctx);
    ImGui::SetCurrentContext(prev_ctx);
    window_as_game(win);
}
