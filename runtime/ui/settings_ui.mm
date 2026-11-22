// The look and the settings pages shared by the start screen and the F12 menu (runtime/ui/settings_ui.h). From Let's Go
// Recomp 0.6.0, in Sword's colours, with the pages cut to what this port has.
#define IMGUI_DEFINE_MATH_OPERATORS
#include "../nvn/vulkan/dlss.h"  // (dlss_available: the DLAA choice)
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "settings_ui.h"
#include "imgui_internal.h"

extern "C" {
#include "../paths.h"
#include "../settings.h"
#include "../input_bind.h"
}

// ------------------------------------------------------------------ language
int g_ui_lang;
void ui_pick_language(void) {
    const char *e = getenv("LARECOMP_LANG"), *lang = e && *e ? e : "";
    SDL_Locale **l = NULL;
    int n = 0;
    if (!*lang && (l = SDL_GetPreferredLocales(&n)) && n > 0 && l[0]->language) lang = l[0]->language;
    g_ui_lang = !strncmp(lang, "pt", 2) ? 1 : !strncmp(lang, "ru", 2) ? 2 : 0;
    SDL_free(l);
}

// ------------------------------------------------------------------ look
// Flat and quiet: a light grey-blue background, white rows with rounded corners, one accent blue. The row under the
// cursor (mouse, keyboard or controller) is tinted with an accent bar at its left; values sit at the row's right end,
// muted, with < > beside them when the row has the cursor; on / off settings are switches.
const ImVec4 UI_GOLD(0.15f, 0.39f, 0.92f, 1), UI_GREEN_TEXT(0.09f, 0.55f, 0.32f, 1), UI_RED_TEXT(0.82f, 0.18f, 0.16f, 1),
    UI_TEXT(0.10f, 0.12f, 0.16f, 1), UI_HEADING(0.42f, 0.45f, 0.51f, 1), UI_MUTED(0.42f, 0.45f, 0.51f, 1),
    UI_ACCENT(0.15f, 0.39f, 0.92f, 1);
static const ImU32 COL_BG = IM_COL32(243, 245, 249, 255), COL_ROW = IM_COL32(255, 255, 255, 255),
                   COL_HOT = IM_COL32(234, 241, 254, 255), COL_LINE = IM_COL32(226, 230, 236, 255),
                   COL_TRACK = IM_COL32(214, 219, 227, 255);

UiFonts ui_load_fonts(void) {
    ImGuiIO &io = ImGui::GetIO();
    ImFontConfig cfg;
    cfg.OversampleH = 2;
    static const ImWchar ranges[] = {0x20, 0xFF, 0x2022, 0x2022, 0x2039, 0x203A, 0x400, 0x45F, 0};  // (Latin-1, bullet, ‹ ›, Cyrillic)
    UiFonts f = {};
    // Segoe UI for the text, its semibold for titles and the big text (DejaVu on Linux)
    const char *body[] = {"C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                          "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"};
    const char *bold[] = {"C:/Windows/Fonts/seguisb.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                          "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf"};
    for (const char *p : body) {
        if (FILE *fp = fopen(p, "rb")) fclose(fp);  // (a missing file is an assertion in ImGui, not a NULL return)
        else continue;
        f.body = io.Fonts->AddFontFromFileTTF(p, 30, &cfg, ranges);
        break;
    }
    for (const char *p : bold) {
        if (FILE *fp = fopen(p, "rb")) fclose(fp);
        else continue;
        f.title = io.Fonts->AddFontFromFileTTF(p, 46, &cfg, ranges);
        f.big = io.Fonts->AddFontFromFileTTF(p, 56, &cfg, ranges);
        break;
    }
    if (!f.body) f.body = io.Fonts->AddFontDefault();
    if (!f.big) f.big = f.body;
    if (!f.title) f.title = f.body;
    return f;
}

void ui_style(void) {
    ImGuiStyle &s = ImGui::GetStyle();
    ImGui::StyleColorsLight();
    s.WindowRounding = 18, s.ChildRounding = 12, s.PopupRounding = 12, s.FrameRounding = 10, s.GrabRounding = 10;
    s.TabRounding = 10, s.ScrollbarRounding = 10;
    s.WindowPadding = ImVec2(32, 26), s.FramePadding = ImVec2(18, 12), s.ItemSpacing = ImVec2(12, 6);
    s.ItemInnerSpacing = ImVec2(10, 8), s.ScrollbarSize = 10, s.GrabMinSize = 24;
    s.WindowBorderSize = 0, s.ChildBorderSize = 0, s.FrameBorderSize = 0, s.PopupBorderSize = 1, s.TabBarBorderSize = 0;
    ImVec4 *c = s.Colors;
    ImVec4 white(1, 1, 1, 1), hot(0.918f, 0.945f, 0.996f, 1), hot2(0.85f, 0.90f, 0.99f, 1);
    c[ImGuiCol_Text] = UI_TEXT;
    c[ImGuiCol_TextDisabled] = UI_MUTED;
    c[ImGuiCol_WindowBg] = ImVec4(0.953f, 0.961f, 0.976f, 1);
    c[ImGuiCol_ChildBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg] = white;
    c[ImGuiCol_Border] = ImVec4(0.886f, 0.902f, 0.925f, 1);
    c[ImGuiCol_BorderShadow] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_FrameBg] = white;
    c[ImGuiCol_FrameBgHovered] = hot;
    c[ImGuiCol_FrameBgActive] = hot2;
    c[ImGuiCol_Button] = white;
    c[ImGuiCol_ButtonHovered] = hot;
    c[ImGuiCol_ButtonActive] = hot2;
    c[ImGuiCol_Header] = hot;
    c[ImGuiCol_HeaderHovered] = hot;
    c[ImGuiCol_HeaderActive] = hot2;
    c[ImGuiCol_CheckMark] = UI_ACCENT;
    c[ImGuiCol_SliderGrab] = UI_ACCENT;
    c[ImGuiCol_SliderGrabActive] = UI_ACCENT;
    c[ImGuiCol_Tab] = white;
    c[ImGuiCol_TabHovered] = hot;
    c[ImGuiCol_TabSelected] = hot2;
    c[ImGuiCol_TabSelectedOverline] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_TabDimmed] = c[ImGuiCol_Tab];
    c[ImGuiCol_TabDimmedSelected] = c[ImGuiCol_TabSelected];
    c[ImGuiCol_Separator] = c[ImGuiCol_SeparatorHovered] = c[ImGuiCol_SeparatorActive] = c[ImGuiCol_Border];
    c[ImGuiCol_ScrollbarBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ScrollbarGrab] = ImVec4(0.78f, 0.81f, 0.85f, 1);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.66f, 0.70f, 0.76f, 1);
    c[ImGuiCol_ScrollbarGrabActive] = ImVec4(0.55f, 0.60f, 0.67f, 1);
    c[ImGuiCol_PlotHistogram] = UI_ACCENT;
    c[ImGuiCol_TableHeaderBg] = white;
    c[ImGuiCol_TableBorderStrong] = c[ImGuiCol_TableBorderLight] = c[ImGuiCol_Border];
    c[ImGuiCol_TableRowBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_TableRowBgAlt] = ImVec4(0, 0, 0, 0.02f);
    c[ImGuiCol_TextSelectedBg] = ImVec4(0.15f, 0.39f, 0.92f, 0.25f);
    c[ImGuiCol_ModalWindowDimBg] = ImVec4(0.06f, 0.08f, 0.12f, 0.35f);
    c[ImGuiCol_NavCursor] = ImVec4(0, 0, 0, 0);  // (the focus: the tinted row or button)
}

float ui_scale(UiScaler &s, float window_h) {
    float scale = window_h / 1080.0f;
    if (scale < 0.45f) scale = 0.45f;
    ImGui::GetIO().FontGlobalScale = scale;
    if (s.scale < 0) s.base = ImGui::GetStyle();
    if (fabsf(s.scale - scale) > 0.01f) {
        ImGui::GetStyle() = s.base;
        ImGui::GetStyle().ScaleAllSizes(scale);
        s.scale = scale;
    }
    return scale;
}

// ---- drawing
static float ui_px(void) { return ImGui::GetIO().FontGlobalScale; }  // 1 at 1080 px
static float row_round(void) { return 10 * ui_px(); }

void ui_backdrop(ImDrawList *dl, ImVec2 a, ImVec2 b, float rounding) { dl->AddRectFilled(a, b, COL_BG, rounding); }

void ui_window_backdrop(void) {
    ImGuiWindow *w = ImGui::GetCurrentWindow();
    w->DrawList->PushClipRect(w->Pos, w->Pos + w->Size, false);
    ui_backdrop(w->DrawList, w->Pos, w->Pos + w->Size, ImGui::GetStyle().WindowRounding);
    w->DrawList->PopClipRect();
}

void ui_info_box(ImDrawList *dl, ImVec2 a, ImVec2 b) { dl->AddRectFilled(a, b, COL_ROW, row_round()); }

// A row: white, or the cursor's: tinted with the accent bar at its left
void ui_pill(ImDrawList *dl, ImVec2 a, ImVec2 b, bool hot) {
    float r = row_round(), s = ui_px();
    dl->AddRectFilled(a, b, ImGui::GetColorU32(hot ? COL_HOT : COL_ROW), r);
    if (hot) dl->AddRectFilled(ImVec2(a.x + 6 * s, a.y + (b.y - a.y) * 0.28f), ImVec2(a.x + 10 * s, b.y - (b.y - a.y) * 0.28f),
                               ImGui::GetColorU32(UI_ACCENT), 2 * s);
}

// ---- the cursor: the row under it (keyboard / controller focus, or the mouse)
static bool g_row_hot;  // the row being drawn has it
static bool nav_rect(ImRect *out) {
    ImGuiContext &g = *GImGui;
    if (!g.NavCursorVisible || !g.NavId || !g.NavWindow) return false;
    *out = ImGui::WindowRectRelToAbs(g.NavWindow, g.NavWindow->NavRectRel[g.NavLayer]);
    return true;
}
static bool rect_hot(const ImRect &r) {
    ImGuiContext &g = *GImGui;
    ImRect n;
    if (nav_rect(&n) && g.NavWindow->RootWindowForNav == ImGui::GetCurrentWindow()->RootWindowForNav && r.Contains(n.GetCenter()))
        return true;
    return !g.NavHighlightItemUnderNav && ImGui::IsWindowHovered() && ImGui::IsMouseHoveringRect(r.Min, r.Max);
}

// ---- descriptions
static const char *g_tip_now, *g_tip_last;
bool g_ui_tips_in_box;
void ui_tip(const char *text) {
    bool hov = ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled | ImGuiHoveredFlags_DelayNormal);
    if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled) || ImGui::IsItemFocused()) g_tip_now = text;
    if (hov && !g_ui_tips_in_box) ImGui::SetTooltip("%s", text);
}
const char *ui_tip_last(void) { return g_tip_last; }

void ui_frame_end(void) { g_tip_last = g_tip_now, g_tip_now = NULL; }

void ui_title(ImFont *title, const char *text) {
    ImGui::PushFont(title);
    ImGui::TextColored(UI_TEXT, "%s", text);
    ImGui::PopFont();
}

// a group's heading: small, muted, a gap above it (not at the top of a page)
void ui_heading(const char *text) {
    if (ImGui::GetCursorPosY() > ImGui::GetCursorStartPos().y + 1) ImGui::Dummy(ImVec2(0, 14 * ui_px()));
    ImGui::SetWindowFontScale(0.82f);
    ImGui::TextColored(UI_HEADING, "%s", text);
    ImGui::SetWindowFontScale(1);
}

// ---- the grid (settings_ui.h)
float ui_inset(void) { return roundf(ImGui::GetFrameHeight() * 0.5f); }

void ui_page_begin(const char *id, ImVec2 size) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 2 * ui_px()));
    ImGui::BeginChild(id, size, ImGuiChildFlags_NavFlattened | ImGuiChildFlags_AlwaysUseWindowPadding);
    ImGui::PopStyleVar();
    ImGui::Indent(ui_inset());
}
void ui_page_end(void) {
    ImGui::Unindent(ui_inset());
    ImGui::EndChild();
}

void ui_group_gap(void) { ImGui::Dummy(ImVec2(0, 10 * ui_px())); }

// The row on the current line: from the page's left edge (the text column less the inset) to its right one
static ImRect row_rect(void) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    return ImRect(ImVec2(p.x - ui_inset(), p.y), ImVec2(ImGui::GetCurrentWindow()->WorkRect.Max.x, p.y + ImGui::GetFrameHeight()));
}

bool ui_hot(ImVec2 a, ImVec2 b) { return rect_hot(ImRect(a, b)); }

bool ui_pill_row(void) {
    ImRect r = row_rect();
    g_row_hot = ui_hot(r.Min, r.Max);
    ui_pill(ImGui::GetWindowDrawList(), r.Min, r.Max, g_row_hot);
    return g_row_hot;
}

// The values' column: the row's right half (the values are drawn at its right end)
float ui_label_x(const char *const *labels, int n) {
    float w = 0;
    for (int i = 0; i < n; i++) w = fmaxf(w, ImGui::CalcTextSize(labels[i]).x);
    ImGuiWindow *win = ImGui::GetCurrentWindow();
    float in = ui_inset(), x0 = ImGui::GetCursorScreenPos().x - in;
    float half = x0 + (win->WorkRect.Max.x - x0) * 0.45f, fit = x0 + in + w + ImGui::GetStyle().ItemSpacing.x * 2;
    return fmaxf(half, fit) - win->Pos.x;
}

void ui_row(const char *label, float x) {
    ui_pill_row();
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(label);
    ImGui::SameLine(x);
    ImGui::SetNextItemWidth(-ui_inset() * 0.5f);
}

// A button: white (secondary) or accent-filled (primary), the text centred when it spans the row, else inset
static bool button(const char *label, float width, bool primary) {
    ImGuiWindow *win = ImGui::GetCurrentWindow();
    float in = ui_inset(), h = ImGui::GetFrameHeight();
    const char *end = ImGui::FindRenderedTextEnd(label);
    ImVec2 ts = ImGui::CalcTextSize(label, end), p = ImGui::GetCursorScreenPos();
    float x0 = win->DC.IsSameLine ? p.x : p.x - in;  // (beside another item: where it ends, plus the spacing)
    float w = width < 0 ? win->WorkRect.Max.x - x0 : width > 0 ? width : ts.x + in * 2;
    ImGui::SetCursorScreenPos(ImVec2(x0, p.y));
    bool hit = ImGui::InvisibleButton(label, ImVec2(w, h));
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    bool hot = ui_hot(a, b) || ImGui::IsItemActive(), off = (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled) != 0;
    ImU32 bg = primary ? ImGui::GetColorU32(hot ? ImVec4(0.11f, 0.31f, 0.80f, 1) : UI_ACCENT) : ImGui::GetColorU32(hot ? COL_HOT : COL_ROW);
    win->DrawList->AddRectFilled(a, b, bg, row_round());
    if (!primary) win->DrawList->AddRect(a, b, ImGui::GetColorU32(hot ? ImGui::GetColorU32(UI_ACCENT) : COL_LINE), row_round(), 0, 1.5f * ui_px());
    float tx = w > ts.x + in * 3 && width != 0 ? a.x + (w - ts.x) * 0.5f : a.x + in;
    ImU32 tc = primary ? IM_COL32_WHITE : ImGui::GetColorU32(off ? UI_MUTED : hot ? UI_ACCENT : UI_TEXT);
    win->DrawList->AddText(ImVec2(tx, a.y + (h - ts.y) * 0.5f), tc, label, end);
    return hit;
}
bool ui_button(const char *label, float width) { return button(label, width, false); }
bool ui_button_primary(const char *label, float width) { return button(label, width, true); }

// (left / right on a focused item, not being dragged: a step of its value instead of a move to another item)
static int lr_step(void) {
    if (!ImGui::IsItemFocused() || ImGui::IsItemActive() || (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled)) return 0;
    bool l = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow);
    bool r = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow);
    if (l || r) ImGui::NavMoveRequestCancel();
    return l == r ? 0 : l ? -1 : 1;
}

bool ui_slider(const char *id, float *v, float lo, float hi, const char *fmt, float step) {
    ImGuiWindow *win = ImGui::GetCurrentWindow();
    float old = *v, h = ImGui::GetFrameHeight(), in = ui_inset();
    ImVec2 p = ImGui::GetCursorScreenPos();
    char txt[32], widest[32];
    snprintf(txt, sizeof txt, fmt, *v);
    snprintf(widest, sizeof widest, fmt, fabsf(hi) > fabsf(lo) ? hi : lo);
    float vw = fmaxf(fmaxf(ImGui::CalcTextSize(widest).x, ImGui::CalcTextSize(txt).x), ImGui::CalcTextSize("000%").x);
    float end = win->WorkRect.Max.x - in;
    ImGui::PushStyleColor(ImGuiCol_FrameBg, 0);
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, 0);
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, 0);
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, 0);
    ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, 0);
    ImGui::SetNextItemWidth(fmaxf(end - vw - in - p.x, h * 2));
    ImGui::SliderFloat(id, v, lo, hi, "", ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_NoInput);
    ImGui::PopStyleColor(5);
    if (int s = lr_step()) *v = fminf(hi, fmaxf(lo, *v + s * step));
    ImDrawList *dl = win->DrawList;
    ImRect bb(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    float grab = ImGui::GetStyle().GrabMinSize, x0 = bb.Min.x + 2 + grab * 0.5f, x1 = bb.Max.x - 2 - grab * 0.5f;
    float t = hi > lo ? (*v - lo) / (hi - lo) : 0, kx = x0 + (x1 - x0) * t, cy = bb.GetCenter().y, th = h * 0.10f, kr = h * 0.22f;
    dl->AddRectFilled(ImVec2(x0, cy - th * 0.5f), ImVec2(x1, cy + th * 0.5f), COL_TRACK, th);
    dl->AddRectFilled(ImVec2(x0, cy - th * 0.5f), ImVec2(kx, cy + th * 0.5f), ImGui::GetColorU32(UI_ACCENT), th);
    dl->AddCircleFilled(ImVec2(kx, cy), kr, ImGui::GetColorU32(UI_ACCENT));
    dl->AddCircleFilled(ImVec2(kx, cy), kr * 0.45f, IM_COL32_WHITE);
    snprintf(txt, sizeof txt, fmt, *v);
    ImVec2 ts = ImGui::CalcTextSize(txt);
    dl->AddText(ImVec2(end - ts.x, cy - ts.y * 0.5f), ImGui::GetColorU32(UI_MUTED), txt);
    return *v != old;
}

bool ui_value_button(const char *id, const char *text, ImU32 col) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::CalcItemWidth(), h = ImGui::GetFrameHeight();
    bool hit = ImGui::InvisibleButton(id, ImVec2(w, h));
    ImVec2 ts = ImGui::CalcTextSize(text);
    ImGui::GetWindowDrawList()->AddText(ImVec2(p.x + w - ts.x, p.y + (h - ts.y) * 0.5f), col ? col : ImGui::GetColorU32(UI_MUTED), text);
    return hit;
}

// A choice: its value at the row's right end (muted; accent with ‹ › around it when the row has the cursor). Left /
// right (d-pad, stick, arrow keys) or a click on ‹ › step through the choices; A / Enter / a click opens the list.
bool ui_combo(const char *id, int *v, const char *const *items, int n) {
    ImGuiContext &g = *GImGui;
    int old = *v;
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::CalcItemWidth(), h = ImGui::GetFrameHeight(), cw = h * 0.7f;
    ImRect fr(p, ImVec2(p.x + w, p.y + h));
    bool disabled = (g.CurrentItemFlags & ImGuiItemFlags_Disabled) != 0, hot = g_row_hot;
    const char *txt = *v >= 0 && *v < n ? items[*v] : "";
    ImVec2 ts = ImGui::CalcTextSize(txt);
    float tx = fr.Max.x - cw - ts.x;  // (the value right-aligned, room for › after it)
    ImRect left(ImVec2(tx - cw, p.y), ImVec2(tx, p.y + h)), right(ImVec2(fr.Max.x - cw, p.y), fr.Max);
    int step = 0;
    if (!disabled && hot && ImGui::IsWindowHovered() && ImGui::IsMouseClicked(0))
        step = ImGui::IsMouseHoveringRect(left.Min, left.Max) ? -1 : ImGui::IsMouseHoveringRect(right.Min, right.Max) ? 1 : 0;
    ImGui::SetNextItemWidth(w);
    ImGui::PushStyleColor(ImGuiCol_FrameBg, 0);
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, 0);
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, 0);
    bool open = step == 0 && ImGui::BeginCombo(id, "", ImGuiComboFlags_NoArrowButton | ImGuiComboFlags_HeightLarge);
    if (step) ImGui::ItemSize(fr), ImGui::ItemAdd(fr, ImGui::GetID(id));  // (the click was on ‹ ›: no list)
    ImGui::PopStyleColor(3);
    if (open) {
        for (int i = 0; i < n; i++) {
            bool sel = i == *v;
            if (ImGui::Selectable(items[i], sel)) *v = i;
            if (sel) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    } else if (!disabled && ImGui::IsItemFocused()) {
        bool l = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow);
        bool r = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow);
        if (l != r) step = l ? -1 : 1;
        if (l || r) ImGui::NavMoveRequestCancel();  // (a change of the value, not a move to another item)
    }
    if (step && n > 0) *v = (*v + step + n) % n;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    txt = *v >= 0 && *v < n ? items[*v] : "";
    ts = ImGui::CalcTextSize(txt);
    tx = fr.Max.x - cw - ts.x;
    float cy = fr.GetCenter().y;
    ImU32 col = ImGui::GetColorU32(disabled ? ImVec4(UI_MUTED.x, UI_MUTED.y, UI_MUTED.z, 0.5f) : hot ? UI_ACCENT : UI_MUTED);
    dl->AddText(ImVec2(tx, cy - ts.y * 0.5f), col, txt);
    if (hot && !disabled) {  // thin chevrons either side of the value
        float ch = h * 0.13f, t = 2.0f * ui_px();
        float lx = tx - cw * 0.5f, rx = fr.Max.x - cw * 0.5f;
        ImVec2 l3[3] = {ImVec2(lx + ch * 0.5f, cy - ch), ImVec2(lx - ch * 0.5f, cy), ImVec2(lx + ch * 0.5f, cy + ch)};
        ImVec2 r3[3] = {ImVec2(rx - ch * 0.5f, cy - ch), ImVec2(rx + ch * 0.5f, cy), ImVec2(rx - ch * 0.5f, cy + ch)};
        dl->AddPolyline(l3, 3, col, 0, t);
        dl->AddPolyline(r3, 3, col, 0, t);
    }
    return *v != old;
}

// An on / off setting: a switch at the row's right end (A / click / left / right flip it)
bool ui_toggle(const char *id, const char *label, float x, bool *v) {
    ui_row(label, x);
    bool old = *v, disabled = (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled) != 0;
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::CalcItemWidth(), h = ImGui::GetFrameHeight();
    if (ImGui::InvisibleButton(id, ImVec2(w, h))) *v = !*v;
    if (int s = lr_step()) *v = s > 0;
    float sh = h * 0.52f, sw = sh * 1.75f, x1 = p.x + w - h * 0.15f, cy = p.y + h * 0.5f;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 on = ImGui::GetColorU32(disabled ? ImVec4(UI_ACCENT.x, UI_ACCENT.y, UI_ACCENT.z, 0.4f) : UI_ACCENT);
    dl->AddRectFilled(ImVec2(x1 - sw, cy - sh * 0.5f), ImVec2(x1, cy + sh * 0.5f), *v ? on : COL_TRACK, sh * 0.5f);
    float kr = sh * 0.5f - 3 * ui_px(), kx = *v ? x1 - sh * 0.5f : x1 - sw + sh * 0.5f;
    dl->AddCircleFilled(ImVec2(kx, cy), kr, IM_COL32_WHITE);
    return *v != old;
}

// ------------------------------------------------------------------ tabs
void ui_tabs_begin(int *current, int count) {
    int step = ImGui::IsKeyPressed(ImGuiKey_GamepadL1, false) ? -1 : ImGui::IsKeyPressed(ImGuiKey_GamepadR1, false) ? 1 : 0;
    if (step && count > 0) *current = (*current + step + count) % count;
}

// ------------------------------------------------------------------ the graphics page
// (Let's Go Recomp's page also has GI, the shadow filter, TAA, FSR 3.1 and frame generation: they read that game's
// scene passes and motion vectors, not ported to Sword's renderer; its SSAO is: runtime/nvn/vulkan/exec.c ssao_run)
static const char *const *graphics_labels(int *n) {
    static const char *l[7];
    l[6] = UI_T("Outlines", "Contornos", "Контуры");
    l[0] = UI_T("Frame rate", "Taxa de quadros", "Частота кадров");
    l[1] = UI_T("Anti-aliasing", "Antisserrilhado", "Сглаживание");
    l[2] = UI_T("Anisotropic filtering", "Filtro anisotrópico", "Анизотропная фильтрация");
    l[3] = UI_T("Show FPS", "Mostrar FPS", "Показывать FPS");
    l[4] = UI_T("Shadow resolution", "Resolução das sombras", "Разрешение теней");
    l[5] = UI_T("Ambient occlusion", "Oclusão de ambiente", "Затенение окружения");
    *n = 7;
    return l;
}

float ui_graphics_x(const char *const *extra, int n_extra) {
    int n;
    const char *const *l = graphics_labels(&n);
    float x = ui_label_x(l, n);
    return extra && n_extra ? fmaxf(x, ui_label_x(extra, n_extra)) : x;
}

// known: the build is one runtime/hle/swsh60.c has the frame time table of (Sword 1.0.0 and 1.3.2)
void ui_page_graphics(float x, bool known) {
    int n;
    const char *const *l = graphics_labels(&n);
    {   // the whole game at 30 (the game's own) or 60 (runtime/hle/swsh60.c, from the next start: the F12 menu's change
        // waits for it). No "unlimited": the game advances a fixed step a frame, so above 60 it runs fast.
        const char *fr[] = {UI_T("30 fps (original)", "30 fps (original)", "30 fps (оригинал)"), "60 fps"};
        int f = known && g_settings.fps == 60 ? 1 : 0;
        ui_row(l[0], x);
        ImGui::BeginDisabled(!known);
        if (ui_combo("##fps", &f, fr, 2)) g_settings.fps = f ? 60 : 30;
        ImGui::EndDisabled();
        ui_tip(!known ? UI_T("Sword 1.3.2 or 1.0.0 only.", "Só Sword 1.3.2 ou 1.0.0.", "Только Sword 1.3.2 или 1.0.0.")
                      : UI_T("Applies on next start.", "Vale no próximo início.", "После перезапуска."));
    }
    {
        // (DLAA only where NGX came up at start: an NVIDIA RTX driver and nvngx_dlss.dll next to the executable)
        bool dl = dlss_available();
        const char *aa[] = {UI_T("Off", "Desligado", "Выкл."), "SMAA", "TAA", "DLAA (NVIDIA)"};
        static const int mode[] = {AA_OFF, AA_SMAA, AA_TAA, AA_DLAA};
        int v = 0;
        for (int i = 0; i < 4; i++) if (mode[i] == g_settings.antialias) v = i;
        if (v == 3 && !dl) v = 2;  // (DLAA chosen, not available here: TAA runs)
        ui_row(l[1], x);
        if (ui_combo("##aa", &v, aa, dl ? 4 : 3)) g_settings.antialias = mode[v];
        ui_tip(UI_T("TAA: cleanest edges. DLAA: NVIDIA RTX only.", "TAA: bordas mais limpas. DLAA: só NVIDIA RTX.", "TAA: самые чистые края. DLAA: только RTX."));
    }
    {   // (runtime/nvn/vulkan/textures.c: read once, the samplers are kept)
        const char *af[] = {UI_T("The game's", "Do jogo", "Как в игре"), "2x", "4x", "8x", "16x"};
        static const int lv[] = {0, 2, 4, 8, 16};
        int v = 0;
        for (int i = 0; i < 5; i++) if (lv[i] == g_settings.aniso) v = i;
        ui_row(l[2], x);
        if (ui_combo("##aniso", &v, af, 5)) g_settings.aniso = lv[v];
        ui_tip(UI_T("Sharper ground textures. Applies on next start.", "Texturas do chão mais nítidas. Vale no próximo início.", "Чётче текстуры. После перезапуска."));
    }
    {   // (runtime/nvn/vulkan/exec.c outline_smooth / the outline draw skipped: live)
        const char *ol[] = {UI_T("Off", "Desligados", "Выкл."), UI_T("The game's", "Do jogo", "Как в игре"),
                            UI_T("Smooth", "Suaves", "Сглаженные")};
        int v = g_settings.outlines;
        if (v < 0 || v > 2) v = 2;
        ui_row(l[6], x);
        if (ui_combo("##outlines", &v, ol, 3)) g_settings.outlines = v;
        ui_tip(UI_T("Lines around characters. Smooth removes jaggies.", "Linhas em volta dos personagens. Suaves tira o serrilhado.", "Линии вокруг персонажей."));
    }
    {   // (runtime/nvn/vulkan/textures.c shadow_k: the map is reallocated at once)
        const char *sr[] = {UI_T("The game's", "Do jogo", "Как в игре"), "2x", "4x"};
        static const int lv[] = {1, 2, 4};
        int v = g_settings.shadow_res >= 4 ? 2 : g_settings.shadow_res >= 2 ? 1 : 0;
        ui_row(l[4], x);
        if (ui_combo("##shadowres", &v, sr, 3)) g_settings.shadow_res = lv[v];
        ui_tip(UI_T("Sharper shadows. 4x uses more video memory.", "Sombras mais nítidas. 4x usa mais memória de vídeo.", "Чётче тени. 4x - больше видеопамяти."));
    }
    {   // (runtime/nvn/vulkan/exec.c ssao_run, live; settings_apply_levels: the samples per level)
        const char *ao[] = {UI_T("Off", "Desligado", "Выкл."), UI_T("Low", "Baixa", "Низкое"), UI_T("Medium", "Média", "Среднее"),
                            UI_T("High", "Alta", "Высокое")};
        int v = g_settings.ssao_level < FX_OFF || g_settings.ssao_level > FX_HIGH ? FX_HIGH : g_settings.ssao_level;
        ui_row(l[5], x);
        if (ui_combo("##ssao", &v, ao, 4)) g_settings.ssao_level = v;
        ui_tip(UI_T("Soft shading in corners.", "Sombreado suave nos cantos.", "Мягкое затенение в углах."));
    }
    ui_toggle("##showfps", l[3], x, &g_settings.show_fps);
    ui_tip(UI_T("Frame rate in the corner.", "Taxa de quadros no canto.", "Частота кадров в углу."));
    settings_apply_levels();
}

// ------------------------------------------------------------------ image and sound
// Volume and the game image's colour, applied live in game (runtime/services/audio.c apply_gain,
// runtime/nvn/vulkan/exec.c post_process, color.frag), and the TAA sharpening at the present
void ui_page_image_sound(void) {
    const char *l_vol = UI_T("Volume", "Volume", "Громкость"), *l_bri = UI_T("Brightness", "Brilho", "Яркость"),
               *l_con = UI_T("Contrast", "Contraste", "Контраст"), *l_sat = UI_T("Saturation", "Saturação", "Насыщенность");
    const char *labels[] = {l_vol, l_bri, l_con, l_sat};
    float x = ui_label_x(labels, 4);
    struct Row { const char *label; float *v, lo, hi; } rows[] = {
        {l_vol, &g_settings.volume, 0.0f, 2.0f}, {l_bri, &g_settings.brightness, 0.5f, 1.5f},
        {l_con, &g_settings.contrast, 0.5f, 1.5f}, {l_sat, &g_settings.saturation, 0.0f, 2.0f}};
    for (int i = 0; i < 4; i++) {
        float pct = *rows[i].v * 100;
        ui_row(rows[i].label, x);
        ImGui::PushID(100 + i);
        if (ui_slider("##v", &pct, rows[i].lo * 100, rows[i].hi * 100, "%.0f%%", 5)) *rows[i].v = pct / 100;
        ImGui::PopID();
    }
    ui_group_gap();
    if (ui_button(UI_T("Reset to defaults", "Restaurar padrão", "Сбросить"))) {
        g_settings.volume = g_settings.brightness = g_settings.contrast = g_settings.saturation = 1.0f;
    }
    settings_clamp_color();
}

// Which controller buttons are A / B and X / Y (runtime/hle/bindings.c): Automatic follows the controller in use
void ui_layout_combo(float x) {
    char autol[96];
    int now = bind_layout();
    snprintf(autol, sizeof autol, "%s (%s)", UI_T("Automatic", "Automático", "Авто"), now == BIND_LAYOUT_XBOX ? "Xbox" : now == BIND_LAYOUT_WESTERN ? UI_T("Western", "Ocidental", "Западная") : "Nintendo");
    const char *lay[] = {autol, "Nintendo", "Xbox", UI_T("Western", "Ocidental", "Западная")};
    static const int val[] = {BIND_LAYOUT_AUTO, BIND_LAYOUT_NINTENDO, BIND_LAYOUT_XBOX, BIND_LAYOUT_WESTERN};
    int pref = bind_layout_pref(), v = 0;
    for (int i = 0; i < 4; i++) if (val[i] == pref) v = i;
    ui_row(UI_T("Controller layout", "Layout do controle", "Раскладка контроллера"), x);
    if (ui_combo("##padlayout", &v, lay, 4)) bind_set_layout(val[v]);
    ui_tip(UI_T("Automatic: Switch controllers use Nintendo's, others Xbox's.", "Automático: controles de Switch usam o da Nintendo, os outros o do Xbox.",
                "Авто: контроллеры Switch - Nintendo, остальные - Xbox."));
}

// ------------------------------------------------------------------ advanced
// (Let's Go Recomp's page: its motion vectors and SSAO / GI debug views; nothing of that here)
void ui_page_advanced(void) {}

// ------------------------------------------------------------------ the window mode
const char *ui_window_mode_label(void) { return UI_T("Window", "Janela", "Окно"); }
bool ui_window_mode_row(float x, int *mode) {
    const char *items[] = {UI_T("Windowed", "Em janela", "В окне"), UI_T("Borderless", "Sem borda", "Без рамки"),
                           UI_T("Full screen", "Tela cheia", "Полный экран")};
    if (*mode < 0 || *mode > 2) *mode = 0;
    ui_row(ui_window_mode_label(), x);
    bool ch = ui_combo("##wmode", mode, items, 3);
    ui_tip(UI_T("F11 or Alt+Enter switches. Remembered.", "F11 ou Alt+Enter troca. Fica salvo.", "F11 или Alt+Enter. Запоминается."));
    return ch;
}
