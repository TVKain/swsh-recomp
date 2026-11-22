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

// ------------------------------------------------------------------ keyboard
// The game's actions with the key bound to each. Click one, then press the new key (Esc or 5 s cancels; a key already
// in use swaps over). Controllers keep their buttons: nothing to set for them.
static const struct { int slot; const char *en, *pt; } k_actions[] = {
    {BIND_LS_UP, "Walk up", "Andar para cima"},             {BIND_A, "A  ·  Confirm", "A  ·  Confirmar"},
    {BIND_LS_DOWN, "Walk down", "Andar para baixo"},         {BIND_B, "B  ·  Back", "B  ·  Voltar"},
    {BIND_LS_LEFT, "Walk left", "Andar para a esquerda"},    {BIND_X, "X  ·  Menu", "X  ·  Menu"},
    {BIND_LS_RIGHT, "Walk right", "Andar para a direita"},   {BIND_Y, "Y  ·  Y-Comm", "Y  ·  Y-Comm"},
    {BIND_UP, "D-pad up", "Direcional cima"},                {BIND_L, "L  ·  Camera", "L  ·  Câmera"},
    {BIND_DOWN, "D-pad down", "Direcional baixo"},           {BIND_R, "R  ·  Bike", "R  ·  Bicicleta"},
    {BIND_LEFT, "D-pad left", "Direcional esquerda"},        {BIND_PLUS, "+  ·  Bike", "+  ·  Bicicleta"},
    {BIND_RIGHT, "D-pad right", "Direcional direita"},       {BIND_MINUS, "-  ·  Menu", "-  ·  Menu"},
};

static const char *key_name(int sc) {
    switch (sc) {
    case SDL_SCANCODE_SPACE: return T("Space", "Espaço");
    case SDL_SCANCODE_RETURN: return "Enter";
    case SDL_SCANCODE_UP: return T("Up arrow", "Seta cima");
    case SDL_SCANCODE_DOWN: return T("Down arrow", "Seta baixo");
    case SDL_SCANCODE_LEFT: return T("Left arrow", "Seta esquerda");
    case SDL_SCANCODE_RIGHT: return T("Right arrow", "Seta direita");
    case 0: return T("(none)", "(nenhuma)");
    default: return bind_key_label(sc);
    }
}

static void keys_section(void) {
    int cap_dev, cap_slot, ms_left;
    bind_capture_active(&cap_dev, &cap_slot, &ms_left);
    const size_t n = sizeof k_actions / sizeof k_actions[0];
    const char *sl[] = {T("Mouse sensitivity", "Sensibilidade do mouse"), T("Stick dead zone", "Zona morta do analógico"),
                        T("Mouse camera", "Câmera com o mouse"), T("Controller layout", "Layout do controle")};
    const char *labels[sizeof k_actions / sizeof k_actions[0] + 4];  // (one values' column for every row)
    for (size_t i = 0; i < n; i++) labels[i] = T(k_actions[i].en, k_actions[i].pt);
    for (int i = 0; i < 4; i++) labels[n + i] = sl[i];
    float x = ui_label_x(labels, (int)n + 4);
    ui_heading(T("Controller", "Controle"));
    ui_layout_combo(x);
    ui_row(sl[1], x);
    ui_slider("##dead", &g_settings.stick_deadzone, 0.0f, 0.40f, "%.2f", 0.01f);
    ui_heading(T("Mouse", "Mouse"));
    {
        const char *mc[] = {T("Off", "Desligada"), T("Right button", "Botão direito"), T("Always", "Sempre")};
        int v = g_settings.mouse_cam < 0 || g_settings.mouse_cam > 2 ? 2 : g_settings.mouse_cam;
        ui_row(sl[2], x);
        if (ui_combo("##mousecam", &v, mc, 3)) g_settings.mouse_cam = v;
        ui_tip(T("Left click A, right click B, middle X", "Clique esquerdo A, direito B, meio X"));
    }
    ui_row(sl[0], x);
    ui_slider("##mouse", &g_settings.mouse_sens, 0.02f, 0.30f, "%.2f", 0.01f);
    ui_heading(T("Keyboard", "Teclado"));
    for (size_t k = 0; k < n; k++) {
        size_t i = k < n / 2 ? k * 2 : (k - n / 2) * 2 + 1;  // (in pairs in the table: the moves, then the buttons)
        int slot = k_actions[i].slot;
        bool waiting = cap_dev == BIND_DEV_KEY && cap_slot == slot;
        char txt[96];
        if (waiting) snprintf(txt, sizeof txt, "%s %d", T("Press a key", "Aperte uma tecla"), (ms_left + 999) / 1000);
        else snprintf(txt, sizeof txt, "%s", key_name(g_bind_key[slot]));
        // (waiting: green; a key changed from the default: the accent)
        ImU32 col = waiting ? ImGui::GetColorU32(UI_GREEN_TEXT) : !bind_is_default_slot(BIND_DEV_KEY, slot) ? ImGui::GetColorU32(UI_ACCENT) : 0;
        ui_row(labels[i], x);
        ImGui::PushID(slot);
        if (ui_value_button("##key", txt, col)) {
            if (waiting) bind_capture_cancel();
            else bind_capture_begin(BIND_DEV_KEY, slot);
        }
        ui_tip(T("Click, then press a key", "Clique e aperte uma tecla"));
        ImGui::PopID();
    }
    if (!bind_is_default(BIND_DEV_KEY)) {
        ui_group_gap();
        if (ui_button(T("Reset keys", "Restaurar teclas"))) bind_reset(BIND_DEV_KEY);
    }
}

// ------------------------------------------------------------------ file dialogs (SDL calls back on any thread)
static pthread_mutex_t g_pick_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_pick_game[MAX_PICK], g_pick_mod[1024];
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
    static const SDL_DialogFileFilter f[] = {{"Switch game files (.xci, .nsp)", "xci;nsp"}};
    SDL_ShowOpenFileDialog(picked_game, NULL, win, f, 1, NULL, true);
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

// ------------------------------------------------------------------ the game files section
// One card: the game and its state (ready / working / a problem), one main action and a quiet alternative.
static const ImVec4 &k_green = UI_GREEN_TEXT, &k_red = UI_RED_TEXT;

// a white card from the current position, h tall (full width of the page)
static void card(float h) {
    ImGuiWindow *w = ImGui::GetCurrentWindow();
    ImVec2 p = ImGui::GetCursorScreenPos();
    float in = ui_inset();
    w->DrawList->AddRectFilled(ImVec2(p.x - in, p.y), ImVec2(w->WorkRect.Max.x, p.y + h), IM_COL32_WHITE, 14 * g_scale);
}
// a small status dot then text
static void status(const ImVec4 &col, const char *text) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float r = 6 * g_scale, h = ImGui::GetTextLineHeight();
    ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(p.x + r, p.y + h * 0.5f), r, ImGui::GetColorU32(col));
    ImGui::SetCursorScreenPos(ImVec2(p.x + r * 2 + 10 * g_scale, p.y));
    ImGui::TextColored(col, "%s", text);
}

static void game_files_section(SDL_Window *win) {
    int st = setup_state();
    float pad = 22 * g_scale, line = ImGui::GetTextLineHeightWithSpacing(), fh = ImGui::GetFrameHeight();
    if (setup_running()) {
        static const char *const en[] = {"", "Looking for files", "Copying", "Building game data", "Reading game code",
                                         "Recompiling", "Finishing", "Unpacking"};
        static const char *const pt[] = {"", "Procurando arquivos", "Copiando", "Montando dados do jogo", "Lendo o código",
                                         "Recompilando", "Finalizando", "Desempacotando"};
        card(pad * 2 + line * 2 + 10 * g_scale);
        ImGui::Dummy(ImVec2(0, pad - ImGui::GetStyle().ItemSpacing.y));
        char l[96];
        snprintf(l, sizeof l, "%s  ·  %.0f%%", st >= 1 && st <= SETUP_UNPACKING ? T(en[st], pt[st]) : "...", setup_progress() * 100);
        ImGui::TextUnformatted(l);
        ImGui::ProgressBar(setup_progress(), ImVec2(-ui_inset(), 6 * g_scale), "");
        ImGui::TextDisabled("%s", T("One-time setup", "Configuração única"));
        ImGui::Dummy(ImVec2(0, pad * 0.5f));
        return;
    }
    if (setup_ready()) {
        const char *title = game_title("extracted/exefs");
        card(pad * 2 + line * 2);
        ImGui::Dummy(ImVec2(0, pad - ImGui::GetStyle().ItemSpacing.y));
        ImGui::SetWindowFontScale(1.15f);
        ImGui::TextUnformatted(title ? title : "Pokémon");
        ImGui::SetWindowFontScale(1);
        status(k_green, T("Ready", "Pronto"));
        ImGui::Dummy(ImVec2(0, pad * 0.5f));
        ui_group_gap();
        if (ui_button(T("Replace game files", "Trocar arquivos do jogo"))) pick_packages(win);
        return;
    }
    // not set up (or the last try failed): what to pick, in one line
    card(pad * 2 + line * 2);
    ImGui::Dummy(ImVec2(0, pad - ImGui::GetStyle().ItemSpacing.y));
    ImGui::SetWindowFontScale(1.15f);
    ImGui::TextUnformatted(T("Add your game", "Adicione seu jogo"));
    ImGui::SetWindowFontScale(1);
    if (st >= SETUP_FAIL_NOT_FOUND) {
        static const char *const en[] = {"No game files found", "Compressed files (.nsz / .xcz) aren't supported", "Not Pokémon Sword or Shield",
                                         "Copy failed: about 45 GB free needed", "Build failed: see lasrecomp.log", "Build tools missing: reinstall",
                                         "Game data incomplete", "prod.keys not found", "Unpack failed: see unpack.log", "Add the base game too"};
        static const char *const pt[] = {"Nenhum arquivo do jogo", "Arquivos comprimidos (.nsz / .xcz) não funcionam", "Não é Pokémon Sword ou Shield",
                                         "Falha ao copiar: precisa de uns 45 GB livres", "Falha ao compilar: veja lasrecomp.log", "Faltam ferramentas: reinstale",
                                         "Dados do jogo incompletos", "prod.keys não encontrado", "Falha ao desempacotar: veja unpack.log", "Adicione o jogo base também"};
        status(k_red, T(en[st - SETUP_FAIL_NOT_FOUND], pt[st - SETUP_FAIL_NOT_FOUND]));
    } else {
        ImGui::TextDisabled("%s", T("Game, update and DLC (.xci / .nsp)", "Jogo, atualização e DLC (.xci / .nsp)"));
    }
    ImGui::Dummy(ImVec2(0, pad * 0.5f));
    ui_group_gap();
    if (ui_button_primary(T("Choose files", "Escolher arquivos"), -1)) pick_packages(win);
    ui_tip(T("Select them all at once (Ctrl+click)", "Selecione todos de uma vez (Ctrl+clique)"));
    ImGui::Dummy(ImVec2(0, 4 * g_scale));
    if (ui_button(T("Use an extracted folder", "Usar uma pasta extraída"), -1)) SDL_ShowOpenFolderDialog(picked_game, NULL, win, NULL, false);
    (void)fh;
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
    ImGui::TextDisabled("%s", T("romfs mods only. Higher in the list wins.", "Só mods de romfs. O de cima tem prioridade."));
    ui_group_gap();
    // each mod a row: its name (cut short with "..." when long: the whole of it in the tip), an on / off switch and the
    // arrows that move it up / down at the row's right end (bare on the pill; a circle under the mouse)
    int move = -1, dir = 0;
    ImGui::PushStyleColor(ImGuiCol_Button, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0);
    for (int i = 0; i < g_nmods; i++) {
        ImGui::PushID(i);
        ui_pill_row();
        ImGuiWindow *w = ImGui::GetCurrentWindow();
        ImDrawList *dl = w->DrawList;
        float h = ImGui::GetFrameHeight(), sp = ImGui::GetStyle().ItemSpacing.x, gap = sp * 0.5f, sw = h * 0.91f;
        ImVec2 p = ImGui::GetCursorScreenPos();
        float end = w->WorkRect.Max.x - ui_inset() * 0.6f, ax = end - h * 2 - gap, sx = ax - sp - sw, nmax = sx - sp * 1.5f;
        ImVec2 ts = ImGui::CalcTextSize(g_mods[i]);
        float ty = p.y + (h - ts.y) * 0.5f;
        ImGui::RenderTextEllipsis(dl, ImVec2(p.x, ty), ImVec2(nmax, ty + ts.y), nmax, nmax, g_mods[i], NULL, &ts);
        // the switch: green with the knob at the right when on
        ImGui::SetCursorScreenPos(ImVec2(sx, p.y));
        if (ImGui::InvisibleButton("##on", ImVec2(sw, h))) g_mod_on[i] = !g_mod_on[i];
        const char *lang = mod_language(g_mods[i]);
        char tip[320];
        if (lang) snprintf(tip, sizeof tip, g_pt ? "%s: troca os textos em %s." : "%s: replaces the %s texts.", g_mods[i], lang_name(lang));
        else snprintf(tip, sizeof tip, "%s", g_mods[i]);
        ui_tip(tip);
        float th = h * 0.52f, cy = p.y + h * 0.5f, kr = th * 0.5f - 3 * g_scale, kx = g_mod_on[i] ? sx + sw - th * 0.5f : sx + th * 0.5f;
        dl->AddRectFilled(ImVec2(sx, cy - th * 0.5f), ImVec2(sx + sw, cy + th * 0.5f),
                          g_mod_on[i] ? ImGui::GetColorU32(UI_ACCENT) : ImGui::GetColorU32(IM_COL32(214, 219, 227, 255)), th * 0.5f);
        dl->AddCircleFilled(ImVec2(kx, cy), kr, ImGui::GetColorU32(IM_COL32_WHITE));
        ImGui::SetCursorScreenPos(ImVec2(ax, p.y));
        ImGui::BeginDisabled(i == 0);
        if (ImGui::ArrowButton("##up", ImGuiDir_Up)) move = i, dir = -1;
        ImGui::EndDisabled();
        ImGui::SameLine(0, gap);
        ImGui::BeginDisabled(i == g_nmods - 1);
        if (ImGui::ArrowButton("##down", ImGuiDir_Down)) move = i, dir = 1;
        ImGui::EndDisabled();
        ImGui::PopID();
    }
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    if (move >= 0) {  // (swapped with the one above / below it)
        int j = move + dir;
        char name[128];
        bool on = g_mod_on[move];
        memcpy(name, g_mods[move], sizeof name), memcpy(g_mods[move], g_mods[j], sizeof name), memcpy(g_mods[j], name, sizeof name);
        g_mod_on[move] = g_mod_on[j], g_mod_on[j] = on;
    }
    if (!g_nmods) ImGui::TextDisabled("%s", T("No mods installed", "Nenhum mod instalado"));
    ui_group_gap();
    if (inst == MOD_INSTALL_RUNNING) ImGui::TextDisabled("%s", T("Installing...", "Instalando..."));
    else if (ui_button_primary(T("Install mod", "Instalar mod"))) SDL_ShowOpenFileDialog(picked_mod, NULL, win, filters, 1, NULL, false);
    ImGui::SameLine();
    if (ui_button(T("Open folder", "Abrir pasta"))) {
        char url[1200];
        snprintf(url, sizeof url, "file:///%s", mods_dir_abs());
        for (char *c = url; *c; c++) if (*c == '\\') *c = '/';
        SDL_OpenURL(url);
    }
    if (inst == MOD_INSTALL_FAIL_UNPACK || inst == MOD_INSTALL_FAIL_NOT_MOD)
        ImGui::TextColored(k_red, "%s", inst == MOD_INSTALL_FAIL_UNPACK ? T("Couldn't open that file", "Não deu para abrir o arquivo")
                                                                        : T("No romfs mod in that file", "Nenhum mod de romfs no arquivo"));
}

// ------------------------------------------------------------------ the launcher's window
// A launcher's own window while the start screen is up: no system frame (dragged by its top strip; its own minimize and
// close buttons), taller than wide, in the middle of the screen. Play gives the game its window back: the frame, the
// size and place it was last left in and its window mode (larecomp.ini; LARECOMP_WINDOW: a window that size).
static float g_drag_h, g_buttons_w;  // (logical pixels: the strip that drags the window, the buttons at its right end)
static SDL_HitTestResult SDLCALL launcher_hit(SDL_Window *win, const SDL_Point *pt, void *) {
    int w = 0, h = 0;
    SDL_GetWindowSize(win, &w, &h);
    return pt->y < g_drag_h && pt->x < w - g_buttons_w ? SDL_HITTEST_DRAGGABLE : SDL_HITTEST_NORMAL;
}
// (the game's window: its mode, size and place from larecomp.ini - runtime/nvn/vulkan/device.c window_*)
static void window_as_launcher(SDL_Window *win) {
    if (!getenv("LARECOMP_LAUNCHER_SHOT")) window_remember(win);  // (back here from the game: as it was left)
    SDL_SetWindowFullscreen(win, false);
    if (SDL_GetWindowFlags(win) & SDL_WINDOW_MAXIMIZED) SDL_RestoreWindow(win);
    SDL_Rect usable = {0, 0, 1920, 1040};
    SDL_GetDisplayUsableBounds(SDL_GetDisplayForWindow(win), &usable);
    // landscape, 16:11, at most 80% of the display
    int lh = usable.h * 80 / 100 < 820 ? usable.h * 80 / 100 : 820, lw = lh * 16 / 11;
    if (lw > usable.w * 90 / 100) lw = usable.w * 90 / 100, lh = lw * 11 / 16;
    SDL_SetWindowBordered(win, false);
    SDL_SetWindowResizable(win, false);
    SDL_SetWindowSize(win, lw, lh);
    SDL_SetWindowPosition(win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
    SDL_SetWindowHitTest(win, launcher_hit, NULL);
}
static void window_as_game(SDL_Window *win) {
    SDL_SetWindowHitTest(win, NULL, NULL);
    SDL_SetWindowBordered(win, true);
    SDL_SetWindowResizable(win, true);
    window_restore_geometry(win);
    window_apply_mode(win);
    // black at the new size until the game draws (else the launcher's last image stayed in a corner while it loads);
    // vk_frame_begin makes the swapchain again for the new size
    SDL_SyncWindow(win);
    SDL_PumpEvents();
    static const float black[4] = {0, 0, 0, 1};
    for (int i = 0; i < 3; i++)
        if (vk_frame_begin(black)) vk_frame_end(NULL);
}

// The mark (docs/icon, tools/make_icon.py draws the same): a white ball outline on an accent rounded tile, as vectors
// so it stays sharp at any size
static void logo_mark(ImDrawList *dl, ImVec2 p, float size) {
    float c = size * 0.5f, t = size * 0.075f;  // (a little bolder than the big icon: it is drawn small)
    ImVec2 o(p.x + c, p.y + c);
    dl->AddRectFilled(ImVec2(p.x + size * 0.04f, p.y + size * 0.04f), ImVec2(p.x + size * 0.96f, p.y + size * 0.96f),
                      ImGui::GetColorU32(UI_ACCENT), size * 0.22f);
    ImU32 w = IM_COL32_WHITE;
    dl->AddCircle(o, size * 0.30f, w, 48, t);
    dl->AddCircle(o, size * 0.075f, w, 24, t);
    dl->AddRectFilled(ImVec2(o.x - size * 0.30f, o.y - t * 0.5f), ImVec2(o.x - size * 0.14f, o.y + t * 0.5f), w);
    dl->AddRectFilled(ImVec2(o.x + size * 0.14f, o.y - t * 0.5f), ImVec2(o.x + size * 0.30f, o.y + t * 0.5f), w);
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
    io.IniFilename = NULL;
    UiFonts fonts = ui_load_fonts();
    ui_style();
    UiScaler scaler;
    ImGui_ImplSDL3_InitForVulkan(win);
    vk_imgui_backend_init();

    static const char *const res_en[] = {"Automatic", "720p", "1080p", "1440p", "4K"};
    static const char *const res_pt[] = {"Automática", "720p", "1080p", "1440p", "4K"};
    static const int res_lines[] = {0, 720, 1080, 1440, 2160};
    int res = 0;
    for (int i = 0; i < 5; i++) if (res_lines[i] == g_settings.res_height) res = i;
    int wmode = g_settings.window_mode;
    bool wildb = g_settings.wild_battle, skipc = g_settings.skip_controller;
    mods_reload(g_settings.mod);  // (the folders under mods/: runtime/mods.h)
    long shot_at = getenv("LARECOMP_LAUNCHER_SHOT") ? atol(getenv("LARECOMP_LAUNCHER_SHOT")) : 0, frame = 0;
    bool autoplay = getenv("LARECOMP_LAUNCHER_AUTOPLAY") != NULL, play = false;
    const char *keys_test = getenv("LARECOMP_LAUNCHER_KEYS");
    enum { TAB_GAME, TAB_GRAPHICS, TAB_IMAGE, TAB_CONTROLS, TAB_MODS, NTABS };
    int tab = getenv("LARECOMP_LAUNCHER_TAB") ? atoi(getenv("LARECOMP_LAUNCHER_TAB")) : keys_test ? TAB_CONTROLS : TAB_GAME;
    if (keys_test && atoi(keys_test) > 0) bind_capture_begin(BIND_DEV_KEY, atoi(keys_test));
    if (getenv("LARECOMP_SETUP_DIR")) {  // (a folder, or package files with '|' between them)
        static char list[MAX_PICK];
        snprintf(list, sizeof list, "%s", getenv("LARECOMP_SETUP_DIR"));
        for (char *c = list; *c; c++) if (*c == '|') *c = '\n';
        setup_start(list);
    }
    if (getenv("LARECOMP_MOD_INSTALL")) mod_install_start(getenv("LARECOMP_MOD_INSTALL"));
    static const float bg[4] = {0.953f, 0.961f, 0.976f, 1};  // (the page's flat background: ui_backdrop)
    const ImVec4 side_bg(0.918f, 0.929f, 0.949f, 1);

    while (!play) {
        menu_apply_window_requests(win);
        SDL_Event e;
        bool focus_back = false;
        while (SDL_PollEvent(&e)) {
            if (bind_capture_event(&e)) continue;  // (waiting for a new key: the press is the binding's)
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
        if (take(g_pick_game, path, sizeof path)) setup_start(path);
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
        ImGui_ImplVulkan_NewFrame();
        ImGui_ImplSDL3_NewFrame();
        g_scale = ui_scale(scaler, io.DisplaySize.y * 1.08f);
        ImGui::NewFrame();
        float s = g_scale;
        // (the 60 fps mode: runtime/hle/swsh60.c knows the build; before the game files are set up, offered)
        bool known = !setup_ready() || swsh60_supported("extracted/exefs");
        const char *names[NTABS] = {T("Game", "Jogo"), T("Graphics", "Gráficos"), T("Image & sound", "Imagem e som"),
                                    T("Controls", "Controles"), "Mods"};
        ui_tabs_begin(&tab, NTABS);  // (L1 / R1 on a controller: the page before / after)

        ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
        ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
        ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                             ImGuiWindowFlags_NoBringToFrontOnFocus);
        ImGui::PopStyleVar(2);
        ui_window_backdrop();
        float pad = 24 * s, side_w = 240 * s;
        g_drag_h = 64 * s, g_buttons_w = 110 * s;

        // ---- the sidebar: the name, the pages, Play
        ImGui::PushStyleColor(ImGuiCol_ChildBg, side_bg);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad * 0.75f, pad));
        ImGui::BeginChild("##side", ImVec2(side_w, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                          ImGuiWindowFlags_NoScrollbar);
        {
            {   // the mark and the game's name on one line, the version under the name
                float block = 40 * s;
                ImVec2 p = ImGui::GetCursorScreenPos();
                ImDrawList *dl = ImGui::GetWindowDrawList();
                logo_mark(dl, p, block);
                const char *gt = setup_ready() ? game_title("extracted/exefs") : NULL;
                ImGui::PushFont(fonts.title);
                float fs = ImGui::GetFontSize() * 0.6f;
                dl->AddText(ImGui::GetFont(), fs, ImVec2(p.x + block + 12 * s, p.y + block * 0.5f - fs * 0.95f), ImGui::GetColorU32(UI_TEXT),
                            gt ? gt : "Pokémon Sword");
                ImGui::PopFont();
                float vs = ImGui::GetFontSize() * 0.75f;
                dl->AddText(ImGui::GetFont(), vs, ImVec2(p.x + block + 12 * s, p.y + block * 0.5f + 6 * s), ImGui::GetColorU32(UI_MUTED), "v" RT_APP_VERSION);
                ImGui::Dummy(ImVec2(side_w - pad * 1.5f, block + 22 * s));
            }
            // the pages: the current one white with the accent bar, the one under the cursor tinted
            float row_h = ImGui::GetFrameHeight(), in = ui_inset() * 0.9f;
            for (int t = 0; t < NTABS; t++) {
                ImVec2 a = ImGui::GetCursorScreenPos(), b(a.x + ImGui::GetContentRegionAvail().x, a.y + row_h);
                ImGui::PushID(t);
                if (ImGui::InvisibleButton("##nav", ImVec2(b.x - a.x, row_h))) tab = t;
                ImGui::PopID();
                ImDrawList *dl = ImGui::GetWindowDrawList();
                bool hot = ui_hot(a, b), cur = tab == t;
                if (cur || hot) ui_pill(dl, a, b, hot || cur);
                ImVec2 ts = ImGui::CalcTextSize(names[t]);
                dl->AddText(ImVec2(a.x + in, a.y + (row_h - ts.y) * 0.5f), ImGui::GetColorU32(cur ? UI_ACCENT : UI_TEXT), names[t]);
            }
            float play_h = 56 * s;
            // the shader preparation, above Play: one line and a thin bar (nvn/vulkan/prep.c)
            int prep = ready ? shader_prep_state() : 0;
            float prep_frac = 0;
            bool preparing = prep == 1 && shader_prep_progress(&prep_frac) == 1;
            float card_h = preparing ? ImGui::GetTextLineHeightWithSpacing() + 22 * s : 0;
            ImGui::SetCursorPosY(fmaxf(ImGui::GetCursorPosY(), ImGui::GetWindowHeight() - pad - play_h - card_h));
            if (preparing) {
                float eta = shader_prep_eta();
                char line[64];
                if (eta < 0 || eta >= 90) snprintf(line, sizeof line, g_pt ? "Shaders  %.0f%%" : "Shaders  %.0f%%", prep_frac * 100);
                if (eta >= 90) snprintf(line, sizeof line, "Shaders  %.0f%%  ·  %.0f min", prep_frac * 100, ceilf(eta / 60));
                else if (eta >= 0) snprintf(line, sizeof line, "Shaders  %.0f%%  ·  %.0f s", prep_frac * 100, eta);
                ImGui::TextDisabled("%s", line);
                ImGui::ProgressBar(prep_frac, ImVec2(-FLT_MIN, 4 * s), "");
                ui_tip(T("One-time shader build for your GPU", "Compilação única de shaders para a sua GPU"));
                ImGui::Dummy(ImVec2(0, 8 * s));
            }
            ImGui::BeginDisabled(!ready);
            if (frame == 0 && ready) ImGui::SetKeyboardFocusHere();
            {   // Play: the accent, rounded like the rows, a bigger semibold label
                ImVec2 a = ImGui::GetCursorScreenPos();
                float w = ImGui::GetContentRegionAvail().x;
                if (ImGui::InvisibleButton("##play", ImVec2(w, play_h))) {
                    if (preparing) ImGui::OpenPopup("##prepwarn");
                    else play = true;
                }
                bool hot = ready && (ui_hot(a, ImVec2(a.x + w, a.y + play_h)) || ImGui::IsItemActive());
                ImDrawList *dl = ImGui::GetWindowDrawList();
                ImVec4 c = !ready ? ImVec4(0.78f, 0.81f, 0.86f, 1) : hot ? ImVec4(0.11f, 0.31f, 0.80f, 1) : UI_ACCENT;
                dl->AddRectFilled(a, ImVec2(a.x + w, a.y + play_h), ImGui::GetColorU32(c), 12 * s);
                ImGui::PushFont(fonts.title);
                float fs = ImGui::GetFontSize() * 0.66f;
                const char *pl = T("Play", "Jogar");
                ImVec2 ts = ImGui::GetFont()->CalcTextSizeA(fs, FLT_MAX, 0, pl);
                dl->AddText(ImGui::GetFont(), fs, ImVec2(a.x + (w - ts.x) * 0.5f, a.y + (play_h - ts.y) * 0.5f), IM_COL32_WHITE, pl);
                ImGui::PopFont();
            }
            ImGui::EndDisabled();
            if (!ready && ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
                ImGui::SetTooltip("%s", T("Add your game first", "Adicione seu jogo antes"));
            // Play while the shaders are being prepared: one line, two answers
            ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
            ImGui::SetNextWindowSize(ImVec2(400 * s, 0));
            ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad, pad));
            if (ImGui::BeginPopupModal("##prepwarn", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize)) {
                ImGui::Text(g_pt ? "Shaders %.0f%% prontos" : "Shaders %.0f%% ready", prep_frac * 100);
                ImGui::TextDisabled("%s", T("The game may stutter until done.", "O jogo pode engasgar até terminar."));
                ImGui::Dummy(ImVec2(0, 10 * s));
                float bw = (ImGui::GetContentRegionAvail().x - ImGui::GetStyle().ItemSpacing.x) * 0.5f;
                ImGui::Indent(ui_inset());
                if (ui_button(T("Wait", "Esperar"), bw) || ImGui::IsKeyPressed(ImGuiKey_Escape)) ImGui::CloseCurrentPopup();
                ImGui::SameLine();
                if (ui_button_primary(T("Play anyway", "Jogar assim"), bw)) { play = true; ImGui::CloseCurrentPopup(); }
                ImGui::Unindent(ui_inset());
                ImGui::EndPopup();
            }
            ImGui::PopStyleVar();
        }
        ImGui::EndChild();
        ImGui::PopStyleVar();
        ImGui::PopStyleColor();

        // ---- the page
        ImGui::SameLine(0, 0);
        float cpad = 32 * s;
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(cpad, pad));
        ImGui::BeginChild("##content", ImVec2(0, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                          ImGuiWindowFlags_NoScrollbar);
        {
            ImGui::PushFont(fonts.title);
            ImGui::SetWindowFontScale(0.86f);
            ImGui::TextUnformatted(names[tab]);
            ImGui::SetWindowFontScale(1);
            ImGui::PopFont();
            {   // the window's buttons in its top right corner (placed, not flowed after the title)
                ImVec2 back = ImGui::GetCursorScreenPos(), wp = ImGui::GetWindowPos();
                float bsz = 36 * s, gap = 4 * s, x = wp.x + ImGui::GetWindowWidth() - cpad * 0.5f - bsz * 2 - gap, y = wp.y + pad * 0.5f;
                ImGui::SetCursorScreenPos(ImVec2(x, y));
                if (window_button("##min", false, bsz)) SDL_MinimizeWindow(win);
                ImGui::SetCursorScreenPos(ImVec2(x + bsz + gap, y));
                if (window_button("##close", true, bsz)) exit(0);
                ImGui::SetCursorScreenPos(back);
            }
            ImGui::Dummy(ImVec2(0, 12 * s));
            ui_page_begin("##page", ImVec2(0, 0));
            if (tab == TAB_GAME) {
                game_files_section(win);
            } else if (tab == TAB_GRAPHICS) {
                const char *extra[] = {T("Resolution", "Resolução"), ui_window_mode_label()};
                float x = ui_graphics_x(extra, 2);
                ui_heading(T("Display", "Tela"));
                ui_window_mode_row(x, &wmode);
                ui_row(extra[0], x);
                ui_combo("##res", &res, g_pt ? res_pt : res_en, 5);
                ui_heading(T("Quality", "Qualidade"));
                ui_page_graphics(x, known);
            } else if (tab == TAB_IMAGE) {
                ui_page_image_sound();
            } else if (tab == TAB_CONTROLS) {
                keys_section();
            } else {
                mods_section(win, inst);
            }
            ui_page_end();
        }
        ImGui::EndChild();
        ImGui::PopStyleVar();
        ImGui::End();

        ui_frame_end();
        ImGui::Render();
        ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)vk_frame_cmd());
        bool shot = shot_at && ++frame == shot_at;
        if (!shot_at) frame++;
        vk_frame_end(shot ? (getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png") : NULL);
        if (shot) exit(0);
    }
    g_settings.res_height = res_lines[res];
    g_settings.window_mode = wmode;
    g_settings.fullscreen = wmode != WINDOW_WINDOWED;
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
