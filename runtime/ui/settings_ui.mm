// The look, the layout and the settings pages shared by the start screen and the in-game settings
// (runtime/ui/settings_ui.h has the layout). From Let's Go Recomp 0.6.0's, redesigned 2026-11-22 (player: "make the UI
// consistent, modern, sleek, minimal"): one sidebar + sections-of-cards system for both screens.
#define IMGUI_DEFINE_MATH_OPERATORS
#include "../nvn/vulkan/dlss.h"  // (dlss_available: the DLAA choice)
#include "../nvn/vulkan/xess.h"  // (xess_available: the XeSS choice)
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "settings_ui.h"
#include "ui_sound.h"
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

// ------------------------------------------------------------------ tokens
// Flat and quiet: a light grey-blue page, white cards, one accent blue. Sizes are for a 1080 px tall window.
const ImVec4 UI_GOLD(0.15f, 0.39f, 0.92f, 1), UI_GREEN_TEXT(0.09f, 0.55f, 0.32f, 1), UI_RED_TEXT(0.82f, 0.18f, 0.16f, 1),
    UI_TEXT(0.10f, 0.12f, 0.16f, 1), UI_HEADING(0.40f, 0.44f, 0.51f, 1), UI_MUTED(0.40f, 0.44f, 0.51f, 1),
    UI_ACCENT(0.15f, 0.39f, 0.92f, 1);
const ImU32 UI_COL_BG = IM_COL32(243, 245, 249, 255), UI_COL_SIDE = IM_COL32(233, 237, 243, 255),
            UI_COL_CARD = IM_COL32(255, 255, 255, 255), UI_COL_LINE = IM_COL32(228, 232, 238, 255);
static const ImU32 COL_HOVER = IM_COL32(238, 243, 254, 255),  // the mouse's row
                   COL_FOCUS = IM_COL32(222, 233, 253, 255),  // the controller / keyboard cursor's row
                   COL_TRACK = IM_COL32(214, 219, 227, 255), COL_KEYCHIP = IM_COL32(58, 64, 76, 255);
static const float R_CARD = 14, R_ROW = 10;  // corner radii (1080 px)

UiFonts ui_load_fonts(void) {
    ImGuiIO &io = ImGui::GetIO();
    ImFontConfig cfg;
    cfg.OversampleH = 2;
    static const ImWchar ranges[] = {0x20, 0xFF, 0x2022, 0x2022, 0x2039, 0x203A, 0x400, 0x45F, 0};  // (Latin-1, bullet, ‹ ›, Cyrillic)
    UiFonts f = {};
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
    s.WindowPadding = ImVec2(32, 26), s.FramePadding = ImVec2(18, 13), s.ItemSpacing = ImVec2(12, 8);
    s.ItemInnerSpacing = ImVec2(10, 8), s.ScrollbarSize = 8, s.GrabMinSize = 24;
    s.WindowBorderSize = 0, s.ChildBorderSize = 0, s.FrameBorderSize = 0, s.PopupBorderSize = 1, s.TabBarBorderSize = 0;
    ImVec4 *c = s.Colors;
    ImVec4 white(1, 1, 1, 1), hot(0.933f, 0.953f, 0.996f, 1), none(0, 0, 0, 0);
    c[ImGuiCol_Text] = UI_TEXT;
    c[ImGuiCol_TextDisabled] = UI_MUTED;
    c[ImGuiCol_WindowBg] = ImVec4(0.953f, 0.961f, 0.976f, 1);
    c[ImGuiCol_ChildBg] = none;
    c[ImGuiCol_PopupBg] = white;
    c[ImGuiCol_Border] = ImVec4(0.878f, 0.894f, 0.918f, 1);
    c[ImGuiCol_BorderShadow] = none;
    c[ImGuiCol_FrameBg] = white;
    c[ImGuiCol_FrameBgHovered] = hot;
    c[ImGuiCol_FrameBgActive] = hot;
    c[ImGuiCol_Button] = white;
    c[ImGuiCol_ButtonHovered] = hot;
    c[ImGuiCol_ButtonActive] = hot;
    c[ImGuiCol_Header] = c[ImGuiCol_HeaderHovered] = c[ImGuiCol_HeaderActive] = none;  // (lists draw their own)
    c[ImGuiCol_CheckMark] = UI_ACCENT;
    c[ImGuiCol_SliderGrab] = UI_ACCENT;
    c[ImGuiCol_SliderGrabActive] = UI_ACCENT;
    c[ImGuiCol_Separator] = c[ImGuiCol_SeparatorHovered] = c[ImGuiCol_SeparatorActive] = c[ImGuiCol_Border];
    c[ImGuiCol_ScrollbarBg] = none;
    c[ImGuiCol_ScrollbarGrab] = ImVec4(0.78f, 0.81f, 0.85f, 1);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(0.66f, 0.70f, 0.76f, 1);
    c[ImGuiCol_ScrollbarGrabActive] = ImVec4(0.55f, 0.60f, 0.67f, 1);
    c[ImGuiCol_PlotHistogram] = UI_ACCENT;
    c[ImGuiCol_FrameBg] = ImVec4(0.84f, 0.86f, 0.89f, 1);  // (the progress bars' track)
    c[ImGuiCol_TextSelectedBg] = ImVec4(0.15f, 0.39f, 0.92f, 0.25f);
    c[ImGuiCol_ModalWindowDimBg] = ImVec4(0.06f, 0.08f, 0.12f, 0.40f);
    c[ImGuiCol_NavCursor] = none;  // (the cursor: ui_highlight)
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
float ui_px(void) { return ImGui::GetIO().FontGlobalScale; }

void ui_window_backdrop(void) {
    ImGuiWindow *w = ImGui::GetCurrentWindow();
    w->DrawList->PushClipRect(w->Pos, w->Pos + w->Size, false);
    w->DrawList->AddRectFilled(w->Pos, w->Pos + w->Size, UI_COL_BG, ImGui::GetStyle().WindowRounding);
    w->DrawList->PopClipRect();
}

// ------------------------------------------------------------------ the cursor
bool ui_nav_cursor(void) { return GImGui->NavCursorVisible && GImGui->NavId != 0; }
static bool nav_rect(ImRect *out) {
    ImGuiContext &g = *GImGui;
    if (!g.NavCursorVisible || !g.NavId || !g.NavWindow) return false;
    *out = ImGui::WindowRectRelToAbs(g.NavWindow, g.NavWindow->NavRectRel[g.NavLayer]);
    return true;
}
static bool rect_hot(const ImRect &r) {
    ImGuiContext &g = *GImGui;
    ImRect n;
    if (nav_rect(&n)) return g.NavWindow->RootWindowForNav == ImGui::GetCurrentWindow()->RootWindowForNav && r.Contains(n.GetCenter());
    return ImGui::IsWindowHovered() && ImGui::IsMouseHoveringRect(r.Min, r.Max);
}
bool ui_hot(ImVec2 a, ImVec2 b) { return rect_hot(ImRect(a, b)); }

void ui_highlight(ImDrawList *dl, ImVec2 a, ImVec2 b, float r) {
    bool nav = ui_nav_cursor();
    dl->AddRectFilled(a, b, nav ? COL_FOCUS : COL_HOVER, r);
    if (nav) {
        float t = 2.0f * ui_px(), o = t * 0.5f;
        dl->AddRect(ImVec2(a.x + o, a.y + o), ImVec2(b.x - o, b.y - o), ImGui::GetColorU32(UI_ACCENT), r, 0, t);
    }
}

// ------------------------------------------------------------------ notes and sounds
static const char *g_tip_now, *g_tip_last;
static int g_sound_frame = -1;
static void sound(int which) {
    ui_sound(which);
    g_sound_frame = ImGui::GetFrameCount();
}
void ui_tip(const char *text) {
    if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled) || ImGui::IsItemFocused()) g_tip_now = text;
}
const char *ui_tip_last(void) { return g_tip_last; }

void ui_frame_end(void) {
    g_tip_last = g_tip_now, g_tip_now = NULL;
    // the cursor moved (controller / keyboard): a tick; B / Esc: the back sound - unless a widget played one this frame
    static ImGuiID last_nav;
    ImGuiContext &g = *GImGui;
    int f = ImGui::GetFrameCount();
    if (g_sound_frame != f) {
        if (g_ui_cancel) ui_sound(UI_SND_BACK);
        else if (g.NavId && g.NavId != last_nav && last_nav && g.NavCursorVisible) ui_sound(UI_SND_MOVE);
    }
    last_nav = g.NavId;
}

// ------------------------------------------------------------------ the shell
void ui_logo_mark(ImDrawList *dl, ImVec2 p, float size) {  // (docs/icon, tools/make_icon.py: the same mark)
    float c = size * 0.5f, t = size * 0.075f;
    ImVec2 o(p.x + c, p.y + c);
    dl->AddRectFilled(ImVec2(p.x + size * 0.04f, p.y + size * 0.04f), ImVec2(p.x + size * 0.96f, p.y + size * 0.96f),
                      ImGui::GetColorU32(UI_ACCENT), size * 0.22f);
    ImU32 w = IM_COL32_WHITE;
    dl->AddCircle(o, size * 0.30f, w, 48, t);
    dl->AddCircle(o, size * 0.075f, w, 24, t);
    dl->AddRectFilled(ImVec2(o.x - size * 0.30f, o.y - t * 0.5f), ImVec2(o.x - size * 0.14f, o.y + t * 0.5f), w);
    dl->AddRectFilled(ImVec2(o.x + size * 0.14f, o.y - t * 0.5f), ImVec2(o.x + size * 0.30f, o.y + t * 0.5f), w);
}

void ui_sidebar_brand(ImFont *title, const char *name, const char *sub) {
    float s = ui_px(), block = 44 * s;
    ImVec2 p = ImGui::GetCursorScreenPos();
    p.x += 6 * s;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ui_logo_mark(dl, p, block);
    ImGui::PushFont(title);
    float fs = ImGui::GetFontSize() * 0.56f;
    dl->AddText(ImGui::GetFont(), fs, ImVec2(p.x + block + 12 * s, p.y + block * 0.5f - fs * 0.98f), ImGui::GetColorU32(UI_TEXT), name);
    ImGui::PopFont();
    float vs = ImGui::GetFontSize() * 0.72f;
    dl->AddText(ImGui::GetFont(), vs, ImVec2(p.x + block + 12 * s, p.y + block * 0.5f + 4 * s), ImGui::GetColorU32(UI_MUTED), sub);
    ImGui::Dummy(ImVec2(0, block + 28 * s));
}

bool ui_nav_item(const char *label, bool current, bool focus) {
    float h = ImGui::GetFrameHeight(), s = ui_px();
    ImVec2 a = ImGui::GetCursorScreenPos(), b(a.x + ImGui::GetContentRegionAvail().x, a.y + h);
    ImGui::PushID(label);
    bool hit = ImGui::InvisibleButton("##nav", b - a, ImGuiButtonFlags_EnableNav);
    ImGui::PopID();
    if (focus) { ImGui::FocusItem(); ImGui::SetNavCursorVisible(true); }
    ImDrawList *dl = ImGui::GetWindowDrawList();
    bool hot = ui_hot(a, b);
    if (current) dl->AddRectFilled(a, b, UI_COL_CARD, R_ROW * s);
    if (hot) ui_highlight(dl, a, b, R_ROW * s);
    if (current)  // (a short accent bar at the left: the page shown, even when the cursor is in it)
        dl->AddRectFilled(ImVec2(a.x + 7 * s, a.y + h * 0.3f), ImVec2(a.x + 10.5f * s, b.y - h * 0.3f), ImGui::GetColorU32(UI_ACCENT), 2 * s);
    ImVec2 ts = ImGui::CalcTextSize(label);
    dl->AddText(ImVec2(a.x + 22 * s, a.y + (h - ts.y) * 0.5f), ImGui::GetColorU32(current ? UI_ACCENT : UI_TEXT), label);
    if (hit && !current) sound(UI_SND_PAGE);  // (the button stays the last item: the caller takes its id)
    return hit;
}

void ui_page_title(ImFont *title, const char *text) {
    ImGui::PushFont(title);
    ImGui::SetWindowFontScale(0.74f);
    ImGui::TextColored(UI_TEXT, "%s", text);
    ImGui::SetWindowFontScale(1);
    ImGui::PopFont();
}

// A button prompt: a dark chip with the key (a circle for one letter) and what it does after it, muted
static float prompt(ImDrawList *dl, float x, float y, const char *key, const char *text, bool draw) {
    ImFont *f = ImGui::GetFont();
    float fs = ImGui::GetFontSize() * 0.82f, h = fs * 1.3f, gap = h * 0.35f;
    ImVec2 ks = f->CalcTextSizeA(fs * 0.86f, FLT_MAX, 0, key), ts = f->CalcTextSizeA(fs, FLT_MAX, 0, text);
    float kw = strlen(key) == 1 ? h : ks.x + h * 0.7f;
    if (draw) {
        dl->AddRectFilled(ImVec2(x, y - h * 0.5f), ImVec2(x + kw, y + h * 0.5f), COL_KEYCHIP, h * 0.5f);
        dl->AddText(f, fs * 0.86f, ImVec2(x + (kw - ks.x) * 0.5f, y - ks.y * 0.5f), IM_COL32_WHITE, key);
        dl->AddText(f, fs, ImVec2(x + kw + gap, y - ts.y * 0.5f), ImGui::GetColorU32(UI_MUTED), text);
    }
    return kw + gap + ts.x;
}

float ui_footer_h(void) { return ImGui::GetFrameHeight() * 1.1f; }

void ui_footer(ImVec2 a, ImVec2 b, const char *back_label, bool pages) {
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float s = ui_px(), y = (a.y + b.y) * 0.5f, x = b.x, gap = 22 * s;
    dl->AddLine(a, ImVec2(b.x, a.y), UI_COL_LINE, 1.5f * s);
    bool pad = GImGui->NavInputSource == ImGuiInputSource_Gamepad;
    struct { const char *k, *t; } p[3];
    int n = 0;
    if (pad) {
        p[n++] = {"A", UI_T("Select", "Escolher", "Выбор")};
        p[n++] = {"B", back_label};
        if (pages) p[n++] = {"L  R", UI_T("Pages", "Páginas", "Страницы")};
    } else {
        p[n++] = {"Esc", back_label};
    }
    for (int i = n - 1; i >= 0; i--) {
        float w = prompt(dl, 0, 0, p[i].k, p[i].t, false);
        x -= w;
        prompt(dl, x, y, p[i].k, p[i].t, true);
        x -= gap;
    }
    const char *d = ui_tip_last();
    if (d) {
        float maxw = x - a.x - 16 * s;
        ImFont *f = ImGui::GetFont();
        float fs = ImGui::GetFontSize() * 0.86f;
        ImVec2 ts = f->CalcTextSizeA(fs, FLT_MAX, 0, d);
        dl->PushClipRect(ImVec2(a.x, a.y), ImVec2(a.x + maxw, b.y), true);
        dl->AddText(f, fs, ImVec2(a.x, y - ts.y * 0.5f), ImGui::GetColorU32(UI_MUTED), d);
        dl->PopClipRect();
    }
}

// ------------------------------------------------------------------ pages and sections
float ui_inset(void) { return roundf(ImGui::GetFrameHeight() * 0.42f); }

void ui_page_begin(const char *id, ImVec2 size) {
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 2 * ui_px()));
    ImGui::BeginChild(id, size, ImGuiChildFlags_NavFlattened | ImGuiChildFlags_AlwaysUseWindowPadding);
    ImGui::PopStyleVar();
}
void ui_page_end(void) {
    ImGui::Dummy(ImVec2(0, 8 * ui_px()));
    ImGui::EndChild();
}

// The card is drawn when the section ends (its height known then): channel 0 the card, 1 the row highlights and
// hairlines, 2 the rows' contents
static ImDrawListSplitter g_split;
static bool g_in_section, g_row_hot;
static float g_sec_y0;
static int g_sec_rows;
static void layer(int ch) { if (g_in_section) g_split.SetCurrentChannel(ImGui::GetWindowDrawList(), ch); }

void ui_section(const char *title) {
    float s = ui_px();
    if (ImGui::GetCursorPosY() > ImGui::GetCursorStartPos().y + 1) ImGui::Dummy(ImVec2(0, 14 * s));
    if (title) {
        ImGui::SetCursorPosX(ImGui::GetCursorPosX() + ui_inset() * 0.5f);
        ImGui::SetWindowFontScale(0.80f);
        ImGui::TextColored(UI_HEADING, "%s", title);
        ImGui::SetWindowFontScale(1);
        ImGui::Dummy(ImVec2(0, 2 * s));
    }
    g_split.Split(ImGui::GetWindowDrawList(), 3);
    g_in_section = true;
    layer(2);
    g_sec_y0 = ImGui::GetCursorScreenPos().y;
    g_sec_rows = 0;
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, 0));
}

void ui_section_end(void) {
    ImGui::PopStyleVar();
    ImGuiWindow *w = ImGui::GetCurrentWindow();
    float y1 = ImGui::GetCursorScreenPos().y, s = ui_px();
    layer(0);
    w->DrawList->AddRectFilled(ImVec2(w->WorkRect.Min.x, g_sec_y0), ImVec2(w->WorkRect.Max.x, y1), UI_COL_CARD, R_CARD * s);
    g_split.Merge(w->DrawList);
    g_in_section = false;
}

bool ui_row_hot(void) { return g_row_hot; }

// A row: the full width of the card; the label drawn, the cursor left at the row's start with the row's width set for
// the value widget (which spans the row, so a click anywhere on it works)
void ui_row(const char *label, float) {
    ImGuiWindow *w = ImGui::GetCurrentWindow();
    float h = ImGui::GetFrameHeight(), in = ui_inset(), s = ui_px();
    ImVec2 p = ImGui::GetCursorScreenPos();
    ImRect r(ImVec2(w->WorkRect.Min.x, p.y), ImVec2(w->WorkRect.Max.x, p.y + h));
    g_row_hot = rect_hot(r);
    bool off = (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled) != 0;
    layer(1);
    if (g_in_section && g_sec_rows > 0) w->DrawList->AddLine(ImVec2(r.Min.x + in, r.Min.y), ImVec2(r.Max.x - in, r.Min.y), UI_COL_LINE, 1.0f * s);
    if (g_row_hot && !off) ui_highlight(w->DrawList, ImVec2(r.Min.x + 4 * s, r.Min.y + 3 * s), ImVec2(r.Max.x - 4 * s, r.Max.y - 3 * s), R_ROW * s);
    layer(2);
    ImVec2 ts = ImGui::CalcTextSize(label, NULL, true);
    w->DrawList->AddText(ImVec2(r.Min.x + in, r.Min.y + (h - ts.y) * 0.5f), ImGui::GetColorU32(off ? UI_MUTED : UI_TEXT), label,
                         ImGui::FindRenderedTextEnd(label));
    g_sec_rows++;
    ImGui::SetCursorScreenPos(r.Min);
    ImGui::SetNextItemWidth(r.GetWidth());
}

static bool disabled_now(void) { return (GImGui->CurrentItemFlags & ImGuiItemFlags_Disabled) != 0; }
static ImU32 value_col(bool off) {
    return ImGui::GetColorU32(off ? ImVec4(UI_MUTED.x, UI_MUTED.y, UI_MUTED.z, 0.55f) : g_row_hot ? UI_ACCENT : UI_MUTED);
}
// a chevron at (cx, cy): down (a list) or right (an action)
static void chevron(ImDrawList *dl, float cx, float cy, bool down, ImU32 col) {
    float c = ImGui::GetFrameHeight() * 0.10f, t = 2.0f * ui_px();
    ImVec2 pts[3];
    if (down) pts[0] = ImVec2(cx - c, cy - c * 0.5f), pts[1] = ImVec2(cx, cy + c * 0.5f), pts[2] = ImVec2(cx + c, cy - c * 0.5f);
    else pts[0] = ImVec2(cx - c * 0.5f, cy - c), pts[1] = ImVec2(cx + c * 0.5f, cy), pts[2] = ImVec2(cx - c * 0.5f, cy + c);
    dl->AddPolyline(pts, 3, col, 0, t);
}

// the row's button: the whole row; returns clicked (never while disabled)
static bool row_button(const char *id, ImRect *bb) {
    float w = ImGui::CalcItemWidth(), h = ImGui::GetFrameHeight();
    bool hit = ImGui::InvisibleButton(id, ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    *bb = ImRect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
    return hit && !disabled_now();
}

bool ui_action_row(const char *label, const char *value, ImU32 vcol) {
    ui_row(label);
    ImRect bb;
    ImGui::PushID(label);
    bool hit = row_button("##act", &bb);
    ImGui::PopID();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float in = ui_inset(), cw = ImGui::GetFrameHeight() * 0.5f, cy = bb.GetCenter().y;
    chevron(dl, bb.Max.x - in - cw * 0.3f, cy, false, value_col(disabled_now()));
    if (value) {
        ImVec2 ts = ImGui::CalcTextSize(value);
        dl->AddText(ImVec2(bb.Max.x - in - cw - ts.x, cy - ts.y * 0.5f), vcol ? vcol : value_col(disabled_now()), value);
    }
    if (hit) sound(UI_SND_SELECT);
    return hit;
}

bool ui_value_button(const char *id, const char *text, ImU32 col) {
    ImRect bb;
    bool hit = row_button(id, &bb);
    ImVec2 ts = ImGui::CalcTextSize(text);
    ImGui::GetWindowDrawList()->AddText(ImVec2(bb.Max.x - ui_inset() - ts.x, bb.GetCenter().y - ts.y * 0.5f),
                                        col ? col : value_col(disabled_now()), text);
    if (hit) sound(UI_SND_SELECT);
    return hit;
}

// Lists: the value at the row's right end with a down chevron. A / click opens a list beside it: the current choice
// checked, the cursor's choice filled with the accent (player 2026-11-22: the old pale highlight could not be seen).
bool ui_combo(const char *id, int *v, const char *const *items, int n) {
    int old = *v;
    ImGui::PushID(id);
    ImRect bb;
    bool off = disabled_now();
    if (row_button("##row", &bb)) {
        ImGui::OpenPopup("##list");
        sound(UI_SND_SELECT);
    }
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float in = ui_inset(), h = ImGui::GetFrameHeight(), cw = h * 0.5f, cy = bb.GetCenter().y, s = ui_px();
    const char *txt = *v >= 0 && *v < n ? items[*v] : "";
    ImVec2 ts = ImGui::CalcTextSize(txt);
    ImU32 col = value_col(off);
    dl->AddText(ImVec2(bb.Max.x - in - cw - ts.x, cy - ts.y * 0.5f), col, txt);
    if (!off) chevron(dl, bb.Max.x - in - cw * 0.3f, cy, true, col);

    // the list: under the row, its right edge on the value's; above the row when it would not fit below
    float iw = 0, ih = h * 0.92f, pad = 6 * s;
    for (int i = 0; i < n; i++) iw = fmaxf(iw, ImGui::CalcTextSize(items[i]).x);
    float lw = fmaxf(iw + in * 2 + h * 0.8f, bb.GetWidth() * 0.34f), lh = n * ih + pad * 2;
    bool above = bb.Max.y + lh + 8 * s > ImGui::GetMainViewport()->Size.y;
    ImGui::SetNextWindowPos(ImVec2(bb.Max.x - 6 * s, above ? bb.Min.y - 2 * s : bb.Max.y + 2 * s), ImGuiCond_Always, ImVec2(1, above ? 1 : 0));
    ImGui::SetNextWindowSize(ImVec2(lw, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(pad, pad));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
    if (ImGui::BeginPopup("##list", ImGuiWindowFlags_NoMove)) {
        ImDrawList *pd = ImGui::GetWindowDrawList();
        bool nav = ui_nav_cursor();
        for (int i = 0; i < n; i++) {
            ImGui::PushID(i);
            bool sel = i == *v;
            if (ImGui::Selectable("##it", false, 0, ImVec2(0, ih))) { *v = i; sound(UI_SND_SELECT); }
            if (sel) ImGui::SetItemDefaultFocus();
            ImRect ib(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
            bool hot = nav ? ImGui::IsItemFocused() : ImGui::IsItemHovered();
            if (hot) pd->AddRectFilled(ib.Min, ib.Max, ImGui::GetColorU32(UI_ACCENT), 8 * s);
            ImU32 tc = hot ? IM_COL32_WHITE : sel ? ImGui::GetColorU32(UI_ACCENT) : ImGui::GetColorU32(UI_TEXT);
            ImVec2 its = ImGui::CalcTextSize(items[i]);
            pd->AddText(ImVec2(ib.Min.x + in * 0.7f, ib.GetCenter().y - its.y * 0.5f), tc, items[i]);
            if (sel) {  // a check mark at the right
                float cx = ib.Max.x - in * 0.7f - h * 0.18f, ccy = ib.GetCenter().y, c = h * 0.11f;
                ImVec2 ck[3] = {ImVec2(cx - c, ccy), ImVec2(cx - c * 0.3f, ccy + c * 0.7f), ImVec2(cx + c, ccy - c * 0.8f)};
                pd->AddPolyline(ck, 3, tc, 0, 2.2f * s);
            }
            ImGui::PopID();
        }
        ImGui::EndPopup();
    }
    ImGui::PopStyleVar(2);
    ImGui::PopID();
    return *v != old;
}

// A switch at the row's right end (A / a click flip it)
bool ui_toggle(const char *id, const char *label, float x, bool *v) {
    (void)x;
    ui_row(label);
    bool old = *v, off = disabled_now();
    ImRect bb;
    if (row_button(id, &bb)) {
        *v = !*v;
        sound(*v ? UI_SND_ON : UI_SND_OFF);
    }
    float h = ImGui::GetFrameHeight(), sh = h * 0.50f, sw = sh * 1.8f, x1 = bb.Max.x - ui_inset(), cy = bb.GetCenter().y;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 on = ImGui::GetColorU32(off ? ImVec4(UI_ACCENT.x, UI_ACCENT.y, UI_ACCENT.z, 0.4f) : UI_ACCENT);
    dl->AddRectFilled(ImVec2(x1 - sw, cy - sh * 0.5f), ImVec2(x1, cy + sh * 0.5f), *v ? on : COL_TRACK, sh * 0.5f);
    float kr = sh * 0.5f - 3 * ui_px(), kx = *v ? x1 - sh * 0.5f : x1 - sw + sh * 0.5f;
    dl->AddCircleFilled(ImVec2(kx, cy), kr, IM_COL32_WHITE);
    return *v != old;
}

bool g_ui_cancel;

// A number: the value and a short track at the row's right end. A / click opens a popup with the slider: left / right
// step it live, A / Enter keeps it, B / Esc puts the old value back.
bool ui_slider(const char *id, float *v, float lo, float hi, const char *fmt, float step) {
    static ImGuiID editing;
    static float orig;
    static int opened_frame;
    float old = *v, h = ImGui::GetFrameHeight(), in = ui_inset(), s = ui_px();
    ImGui::PushID(id);
    ImGuiID me = ImGui::GetID("##pop");
    ImRect bb;
    bool off = disabled_now();
    if (row_button("##row", &bb)) {
        ImGui::OpenPopup(me);
        editing = me, orig = *v, opened_frame = ImGui::GetFrameCount();
        sound(UI_SND_SELECT);
    }
    char txt[32];
    snprintf(txt, sizeof txt, fmt, *v);
    ImVec2 ts = ImGui::CalcTextSize(txt);
    float end = bb.Max.x - in, cy = bb.GetCenter().y;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float vw = ImGui::CalcTextSize("000%").x;  // (a fixed column, so the tracks line up)
    float x1 = end - fmaxf(vw, ts.x) - in * 0.7f, x0 = x1 - h * 2.6f, th = h * 0.09f, t = hi > lo ? (*v - lo) / (hi - lo) : 0;
    if (x0 > bb.Min.x + bb.GetWidth() * 0.45f) {
        dl->AddRectFilled(ImVec2(x0, cy - th * 0.5f), ImVec2(x1, cy + th * 0.5f), COL_TRACK, th);
        dl->AddRectFilled(ImVec2(x0, cy - th * 0.5f), ImVec2(x0 + (x1 - x0) * t, cy + th * 0.5f),
                          ImGui::GetColorU32(off ? UI_MUTED : UI_ACCENT), th);
    }
    dl->AddText(ImVec2(end - ts.x, cy - ts.y * 0.5f), value_col(off), txt);

    ImGui::SetNextWindowPos(ImVec2(bb.Max.x - 6 * s, bb.Max.y + 2 * s), ImGuiCond_Appearing, ImVec2(1, 0));
    ImGui::SetNextWindowSize(ImVec2(fmaxf(bb.GetWidth() * 0.55f, h * 8), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(in, in * 0.6f));
    if (ImGui::BeginPopup("##pop", ImGuiWindowFlags_NoMove)) {
        float pw = ImGui::GetContentRegionAvail().x;
        snprintf(txt, sizeof txt, fmt, *v);
        ImVec2 vs = ImGui::CalcTextSize("000%");
        ImGui::PushStyleColor(ImGuiCol_FrameBg, 0);
        ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, 0);
        ImGui::PushStyleColor(ImGuiCol_FrameBgActive, 0);
        ImGui::PushStyleColor(ImGuiCol_SliderGrab, 0);
        ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, 0);
        ImGui::SetNextItemWidth(fmaxf(pw - vs.x - in, h * 2));
        if (ImGui::IsWindowAppearing()) ImGui::SetKeyboardFocusHere();
        float before = *v;
        ImGui::SliderFloat("##s", v, lo, hi, "", ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_NoInput);
        ImGui::PopStyleColor(5);
        ImRect sb(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
        bool l = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow);
        bool r = ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow);
        if (l || r) ImGui::NavMoveRequestCancel();
        if (l != r) *v = fminf(hi, fmaxf(lo, *v + (l ? -1 : 1) * step));
        if (*v != before && (l || r)) sound(UI_SND_MOVE);
        float grab = ImGui::GetStyle().GrabMinSize, a0 = sb.Min.x + 2 + grab * 0.5f, a1 = sb.Max.x - 2 - grab * 0.5f;
        float tt = hi > lo ? (*v - lo) / (hi - lo) : 0, kx = a0 + (a1 - a0) * tt, scy = sb.GetCenter().y, sth = h * 0.11f, kr = h * 0.25f;
        ImDrawList *pd = ImGui::GetWindowDrawList();
        pd->AddRectFilled(ImVec2(a0, scy - sth * 0.5f), ImVec2(a1, scy + sth * 0.5f), COL_TRACK, sth);
        pd->AddRectFilled(ImVec2(a0, scy - sth * 0.5f), ImVec2(kx, scy + sth * 0.5f), ImGui::GetColorU32(UI_ACCENT), sth);
        pd->AddCircleFilled(ImVec2(kx, scy), kr, ImGui::GetColorU32(UI_ACCENT));
        pd->AddCircleFilled(ImVec2(kx, scy), kr * 0.42f, IM_COL32_WHITE);
        snprintf(txt, sizeof txt, fmt, *v);
        ImVec2 tv = ImGui::CalcTextSize(txt);
        pd->AddText(ImVec2(sb.Max.x + in * 0.5f + vs.x - tv.x, scy - tv.y * 0.5f), ImGui::GetColorU32(UI_ACCENT), txt);
        bool ok = ImGui::GetFrameCount() > opened_frame + 1 &&
                  (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) || ImGui::IsKeyPressed(ImGuiKey_Enter, false) ||
                   ImGui::IsKeyPressed(ImGuiKey_KeypadEnter, false));
        if (ok) { editing = 0; ImGui::CloseCurrentPopup(); sound(UI_SND_SELECT); }
        ImGui::EndPopup();
    } else if (editing == me) {  // closed: by B / Esc (the old value back) or a click elsewhere (kept)
        if (g_ui_cancel) *v = orig;
        editing = 0;
    }
    ImGui::PopStyleVar();
    ImGui::PopID();
    return *v != old;
}

// ------------------------------------------------------------------ buttons (outside the cards)
enum { BTN_SECONDARY, BTN_PRIMARY, BTN_GHOST };
static bool button(const char *label, float width, float height, int kind) {
    ImGuiWindow *win = ImGui::GetCurrentWindow();
    float in = ui_inset(), h = height > 0 ? height : ImGui::GetFrameHeight(), s = ui_px(), r = R_ROW * s;
    const char *end = ImGui::FindRenderedTextEnd(label);
    ImVec2 ts = ImGui::CalcTextSize(label, end);
    float w = width < 0 ? ImGui::GetContentRegionAvail().x : width > 0 ? width : ts.x + in * 2;
    bool hit = ImGui::InvisibleButton(label, ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    bool off = disabled_now(), nav = ImGui::IsItemFocused() && ui_nav_cursor();
    bool hot = !off && (nav || (!ui_nav_cursor() && ImGui::IsItemHovered()) || ImGui::IsItemActive());
    ImDrawList *dl = win->DrawList;
    ImU32 acc = ImGui::GetColorU32(UI_ACCENT), tc;
    if (kind == BTN_PRIMARY) {
        // idle: a pale accent tint, accent outline and text; under the cursor solid accent with white text, a soft
        // shadow and (controller / keyboard) a ring around it - two looks far apart, so the cursor can't be missed
        if (hot) dl->AddRectFilled(ImVec2(a.x + 2 * s, a.y + 4 * s), ImVec2(b.x - 2 * s, b.y + 4 * s), IM_COL32(20, 60, 160, 55), r);
        dl->AddRectFilled(a, b, off ? IM_COL32(226, 230, 236, 255) : hot ? acc : COL_FOCUS, r);
        if (!hot && !off) dl->AddRect(a, b, acc, r, 0, 1.5f * s);
        if (nav) {
            float g = 4 * s, pulse = 0.55f + 0.45f * (0.5f + 0.5f * sinf((float)ImGui::GetTime() * 4.0f));
            ImVec4 rc = UI_ACCENT;
            rc.w = pulse;
            dl->AddRect(ImVec2(a.x - g, a.y - g), ImVec2(b.x + g, b.y + g), ImGui::GetColorU32(rc), r + g, 0, 2.5f * s);
        }
        tc = off ? ImGui::GetColorU32(UI_MUTED) : hot ? IM_COL32_WHITE : acc;
    } else if (kind == BTN_SECONDARY) {
        dl->AddRectFilled(a, b, UI_COL_CARD, r);
        if (hot) ui_highlight(dl, a, b, r);
        else dl->AddRect(a, b, UI_COL_LINE, r, 0, 1.5f * s);
        tc = ImGui::GetColorU32(off ? UI_MUTED : hot ? UI_ACCENT : UI_TEXT);
    } else {
        if (hot) ui_highlight(dl, a, b, r);
        tc = ImGui::GetColorU32(off ? UI_MUTED : hot ? UI_ACCENT : UI_MUTED);
    }
    dl->AddText(ImVec2(a.x + (w - ts.x) * 0.5f, a.y + (h - ts.y) * 0.5f), tc, label, end);
    if (hit) sound(UI_SND_SELECT);
    return hit;
}
bool ui_button(const char *label, float width) { return button(label, width, 0, BTN_SECONDARY); }
bool ui_button_primary(const char *label, float width, float height) { return button(label, width, height, BTN_PRIMARY); }
bool ui_button_ghost(const char *label, float width) { return button(label, width, 0, BTN_GHOST); }

void ui_tabs_begin(int *current, int count) {
    int step = ImGui::IsKeyPressed(ImGuiKey_GamepadL1, false) ? -1 : ImGui::IsKeyPressed(ImGuiKey_GamepadR1, false) ? 1 : 0;
    if (step && count > 0) {
        *current = (*current + step + count) % count;
        sound(UI_SND_PAGE);
    }
}

// ------------------------------------------------------------------ the pages
// Display: the window, then what sets the frame rate and the sharpness
void ui_page_display(bool known, void (*apply_window)(void)) {
    ui_section(UI_T("Window", "Janela", "Окно"));
    {
        const char *items[] = {UI_T("Windowed", "Em janela", "В окне"), UI_T("Borderless", "Sem borda", "Без рамки"),
                               UI_T("Full screen", "Tela cheia", "Полный экран")};
        int m = g_settings.window_mode < 0 || g_settings.window_mode > 2 ? 0 : g_settings.window_mode;
        ui_row(UI_T("Mode", "Modo", "Режим"));
        if (ui_combo("##wmode", &m, items, 3)) {
            g_settings.window_mode = m;
            if (apply_window) apply_window();
        }
        ui_tip(UI_T("F11 or Alt+Enter switches", "F11 ou Alt+Enter troca", "F11 или Alt+Enter"));
    }
    ui_toggle("##vsync", "VSync", 0, &g_settings.vsync);
    ui_tip(UI_T("Smoothest; uses VRR in full screen", "Mais suave; usa VRR em tela cheia", "Плавнее; VRR в полноэкранном"));
    ui_section_end();

    ui_section(UI_T("Performance", "Desempenho", "Производительность"));
    {   // the whole game at 30 (the game's own) or 60 (runtime/hle/swsh60.c, from the next start)
        const char *fr[] = {UI_T("30 fps (original)", "30 fps (original)", "30 fps (оригинал)"), "60 fps"};
        int f = known && g_settings.fps == 60 ? 1 : 0;
        ImGui::BeginDisabled(!known);
        ui_row(UI_T("Frame rate", "Taxa de quadros", "Частота кадров"));
        if (ui_combo("##fps", &f, fr, 2)) g_settings.fps = f ? 60 : 30;
        ImGui::EndDisabled();
        ui_tip(!known ? UI_T("Sword 1.3.2 or 1.0.0 only", "Só Sword 1.3.2 ou 1.0.0", "Только Sword 1.3.2 или 1.0.0")
                      : UI_T("Applies on next start", "Vale no próximo início", "После перезапуска"));
    }
    {   // (runtime/nvn/output_scale.c reads it every frame)
        // a fixed render height only (player 2026-11-22: no Automatic - dynamic resolution blurred the picture)
        static const int lines[] = {720, 900, 1080, 1440, 2160};
        const char *items[] = {"720p", "900p", "1080p", "1440p", "4K"};
        int cur = 2;
        for (int i = 0; i < 5; i++) if (lines[i] == g_settings.res_height) cur = i;
        ui_row(UI_T("Resolution", "Resolução", "Разрешение"));
        if (ui_combo("##res", &cur, items, 5)) g_settings.res_height = lines[cur];
        ui_tip(UI_T("The game's render size", "Tamanho em que o jogo é desenhado", "Размер отрисовки игры"));
    }
    ui_toggle("##showfps", UI_T("Show FPS", "Mostrar FPS", "Показывать FPS"), 0, &g_settings.show_fps);
    ui_section_end();
}

// Graphics presets (player 2026-11-22: "so many settings, confusing what to turn on"): one row picks a measured set of
// the detail settings (texture filtering, shadows, ambient occlusion, outlines); the single ones stay under "Show
// details". Anti-aliasing (TAA / XeSS / DLAA) is NOT part of a preset: it stays its own row (player: "XeSS, DLAA we
// should expose").
typedef struct { int aniso, shadow, ssao, outlines; } GfxPreset;
static GfxPreset preset_value(int i) {
    switch (i) {
    case 0: return (GfxPreset){8, 1, FX_MEDIUM, OUTLINE_OFF};   // Balanced
    case 1: return (GfxPreset){16, 2, FX_HIGH, OUTLINE_OFF};    // High
    default: return (GfxPreset){16, 4, FX_HIGH, OUTLINE_OFF};   // Max
    }
}
static int preset_current(void) {
    for (int i = 0; i < 3; i++) {
        GfxPreset p = preset_value(i);
        if (g_settings.aniso == p.aniso && g_settings.shadow_res == p.shadow && g_settings.ssao_level == p.ssao &&
            g_settings.outlines == p.outlines)
            return i;
    }
    return 3;  // (Custom)
}

// Graphics: quality, then the picture's colour
void ui_page_graphics(bool known) {
    (void)known;
    static bool details;
    ui_section(UI_T("Quality", "Qualidade", "Качество"));
    {
        const char *items[] = {UI_T("Balanced", "Equilibrado", "Сбалансированно"), UI_T("High (recommended)", "Alto (recomendado)", "Высокое (рекомендуется)"),
                               UI_T("Max", "Máximo", "Максимум"), UI_T("Custom", "Personalizado", "Своё")};
        int cur = preset_current(), v = cur;
        ui_row(UI_T("Detail", "Detalhes", "Детализация"));
        if (ui_combo("##preset", &v, items, cur == 3 ? 4 : 3) && v < 3) {
            GfxPreset p = preset_value(v);
            g_settings.aniso = p.aniso;
            g_settings.shadow_res = p.shadow;
            g_settings.ssao_level = p.ssao;
            g_settings.outlines = p.outlines;
        }
        ui_tip(v == 0 ? UI_T("Steadiest frame rate in busy scenes", "Taxa de quadros mais estável em cenas cheias", "Стабильнее в сложных сценах")
             : v == 1 ? UI_T("Textures, shadows, shading: sharp at 60 fps", "Texturas, sombras, sombreamento: nítido a 60 fps", "Чётко на 60 fps")
             : v == 2 ? UI_T("Sharpest shadows: heaviest", "Sombras mais nítidas: mais pesado", "Самые чёткие тени: тяжелее всего")
                      : UI_T("Your own choices under details", "Suas escolhas nos detalhes", "Ваши настройки в подробностях"));
    }
    {   // (XeSS only where libxess.dll came up at start, DLAA where NGX did: else TAA runs for them)
        const char *aa[5];
        int mode[5], n = 0, v = 0;
        aa[n] = UI_T("Off", "Desligado", "Выкл."), mode[n++] = AA_OFF;
        aa[n] = "SMAA", mode[n++] = AA_SMAA;
        aa[n] = "TAA + SMAA", mode[n++] = AA_TAA;  // (exec.c post_process: SMAA runs after TAA / DLAA, not after XeSS)
        if (xess_available()) aa[n] = "XeSS (Intel)", mode[n++] = AA_XESS;
        if (dlss_available()) aa[n] = "DLAA (NVIDIA)", mode[n++] = AA_DLAA;
        int cur = g_settings.antialias == AA_XESS && !xess_available() ? AA_TAA
                : g_settings.antialias == AA_DLAA && !dlss_available() ? AA_TAA : g_settings.antialias;
        for (int i = 0; i < n; i++) if (mode[i] == cur) v = i;
        ui_row(UI_T("Anti-aliasing", "Antisserrilhado", "Сглаживание"));
        if (ui_combo("##aa", &v, aa, n)) g_settings.antialias = mode[v];
        ui_tip(mode[v] == AA_XESS ? UI_T("Intel's AI anti-aliasing: smoothest image, ~1 ms more than TAA", "IA da Intel: imagem mais suave, ~1 ms a mais que TAA", "ИИ-сглаживание Intel: ~1 мс больше TAA")
             : mode[v] == AA_DLAA ? UI_T("NVIDIA's AI anti-aliasing", "IA da NVIDIA", "ИИ-сглаживание NVIDIA")
             : mode[v] == AA_TAA  ? UI_T("Sharpest and lightest: TAA with an SMAA edge pass", "O mais nítido e leve: TAA com SMAA nas bordas", "Чётко и легко: TAA + SMAA")
                                  : UI_T("TAA or XeSS give the cleanest edges", "TAA ou XeSS dão as bordas mais limpas", "TAA или XeSS - самые чистые края"));
    }
    if (g_settings.antialias == AA_XESS && xess_available()) {  // (exec.c xess_upscale: live; the texture sharpness at next start)
        // (list order: full size first; the setting's values stay as they were in larecomp.ini)
        static const int order[XESS_Q_COUNT] = {XESS_Q_FULL, XESS_Q_NATIVE, XESS_Q_ULTRA_PLUS, XESS_Q_ULTRA, XESS_Q_QUALITY,
                                                XESS_Q_BALANCED, XESS_Q_PERFORMANCE};
        const char *xq[XESS_Q_COUNT] = {UI_T("Native AA (full size)", "AA nativo (tamanho cheio)", "Нативное AA (полный размер)"),
                                        UI_T("Native (game's 80%)", "Nativo (80% do jogo)", "Нативный (80% игры)"),
                                        "Ultra Quality+ (1.3x)", "Ultra Quality (1.5x)", "Quality (1.7x)", "Balanced (2x)", "Performance (2.3x)"};
        int v = 1;
        for (int i = 0; i < XESS_Q_COUNT; i++)
            if (order[i] == g_settings.xess_quality) v = i;
        ui_row(UI_T("XeSS mode", "Modo XeSS", "Режим XeSS"));
        if (ui_combo("##xessq", &v, xq, XESS_Q_COUNT)) g_settings.xess_quality = order[v];
        ui_tip(order[v] == XESS_Q_FULL ? UI_T("Scene at full size, XeSS only smooths edges: sharpest, costs most", "Cena em tamanho cheio, o XeSS só suaviza bordas: o mais nítido, custa mais", "Полный размер, только сглаживание: чётче всего, дороже всего")
             : order[v] == XESS_Q_NATIVE ? UI_T("The game's own 80% scene, XeSS rebuilds full size", "A cena de 80% do jogo, o XeSS reconstrói o tamanho cheio", "Сцена игры 80%, XeSS восстанавливает")
                                         : UI_T("Scene drawn smaller, XeSS rebuilds it: more fps", "Cena menor, o XeSS a reconstrói: mais fps", "Сцена меньше, XeSS её восстанавливает"));
    }
    ui_toggle("##gfxdetails", UI_T("Show details", "Mostrar detalhes", "Подробнее"), 0, &details);
    ui_tip(UI_T("Each detail setting on its own", "Cada ajuste de detalhe separado", "Каждая настройка отдельно"));
    if (!details) {
        ui_section_end();
        settings_apply_levels();
        goto picture;
    }
    {   // (runtime/nvn/vulkan/textures.c: read once, the samplers are kept)
        const char *af[] = {UI_T("The game's", "Do jogo", "Как в игре"), "2x", "4x", "8x", "16x"};
        static const int lv[] = {0, 2, 4, 8, 16};
        int v = 0;
        for (int i = 0; i < 5; i++) if (lv[i] == g_settings.aniso) v = i;
        ui_row(UI_T("Texture filtering", "Filtro de texturas", "Фильтрация текстур"));
        if (ui_combo("##aniso", &v, af, 5)) g_settings.aniso = lv[v];
        ui_tip(UI_T("Applies on next start", "Vale no próximo início", "После перезапуска"));
    }
    {   // (runtime/nvn/vulkan/textures.c shadow_k: the map is reallocated at once)
        const char *sr[] = {UI_T("The game's", "Do jogo", "Как в игре"), "2x", "4x"};
        static const int lv[] = {1, 2, 4};
        int v = g_settings.shadow_res >= 4 ? 2 : g_settings.shadow_res >= 2 ? 1 : 0;
        ui_row(UI_T("Shadows", "Sombras", "Тени"));
        if (ui_combo("##shadowres", &v, sr, 3)) g_settings.shadow_res = lv[v];
        ui_tip(UI_T("4x uses more video memory", "4x usa mais memória de vídeo", "4x - больше видеопамяти"));
    }
    {   // (runtime/nvn/vulkan/exec.c ssao_run, live)
        const char *ao[] = {UI_T("Off", "Desligado", "Выкл."), UI_T("Low", "Baixa", "Низкое"), UI_T("Medium", "Média", "Среднее"),
                            UI_T("High", "Alta", "Высокое")};
        int v = g_settings.ssao_level < FX_OFF || g_settings.ssao_level > FX_HIGH ? FX_HIGH : g_settings.ssao_level;
        ui_row(UI_T("Ambient occlusion", "Oclusão de ambiente", "Затенение окружения"));
        if (ui_combo("##ssao", &v, ao, 4)) g_settings.ssao_level = v;
    }
    {   // (runtime/nvn/vulkan/exec.c outline_smooth / the outline draw skipped: live)
        const char *ol[] = {UI_T("Off", "Desligados", "Выкл."), UI_T("The game's", "Do jogo", "Как в игре"),
                            UI_T("Smooth", "Suaves", "Сглаженные")};
        int v = g_settings.outlines < 0 || g_settings.outlines > 2 ? 2 : g_settings.outlines;
        ui_row(UI_T("Outlines", "Contornos", "Контуры"));
        if (ui_combo("##outlines", &v, ol, 3)) g_settings.outlines = v;
        ui_tip(UI_T("Smooth removes jagged edges", "Suaves tira o serrilhado", "Сглаженные - без лесенки"));
    }
    ui_section_end();
    settings_apply_levels();

picture:
    // the picture (live: runtime/nvn/vulkan/exec.c post_process, color.frag)
    ui_section(UI_T("Picture", "Imagem", "Изображение"));
    struct Row { const char *label; float *v, lo, hi; } rows[] = {
        {UI_T("Brightness", "Brilho", "Яркость"), &g_settings.brightness, 0.5f, 1.5f},
        {UI_T("Contrast", "Contraste", "Контраст"), &g_settings.contrast, 0.5f, 1.5f},
        {UI_T("Saturation", "Saturação", "Насыщенность"), &g_settings.saturation, 0.0f, 2.0f}};
    for (int i = 0; i < 3; i++) {
        float pct = *rows[i].v * 100;
        ui_row(rows[i].label);
        ImGui::PushID(100 + i);
        if (ui_slider("##v", &pct, rows[i].lo * 100, rows[i].hi * 100, "%.0f%%", 5)) *rows[i].v = pct / 100;
        ImGui::PopID();
    }
    bool def = g_settings.brightness == 1 && g_settings.contrast == 1 && g_settings.saturation == 1;
    ImGui::BeginDisabled(def);
    if (ui_action_row(UI_T("Reset picture", "Restaurar imagem", "Сбросить изображение")))
        g_settings.brightness = g_settings.contrast = g_settings.saturation = 1.0f;
    ImGui::EndDisabled();
    ui_section_end();
    settings_clamp_color();
}

// Audio: the game's volume, the menus' sounds
void ui_page_audio(void) {
    ui_section(UI_T("Game", "Jogo", "Игра"));
    {   // (runtime/services/audio.c apply_gain, live)
        float pct = g_settings.volume * 100;
        ui_row(UI_T("Volume", "Volume", "Громкость"));
        if (ui_slider("##vol", &pct, 0, 200, "%.0f%%", 5)) g_settings.volume = pct / 100;
    }
    ui_section_end();
    ui_section(UI_T("Menus", "Menus", "Меню"));
    ui_toggle("##uisnd", UI_T("Menu sounds", "Sons dos menus", "Звуки меню"), 0, &g_settings.ui_sounds);
    ui_tip(UI_T("Clicks when moving and choosing", "Cliques ao mover e escolher", "Щелчки при выборе"));
    ImGui::BeginDisabled(!g_settings.ui_sounds);
    {
        float pct = g_settings.ui_volume * 100;
        ui_row(UI_T("Menu volume", "Volume dos menus", "Громкость меню"));
        if (ui_slider("##uivol", &pct, 0, 100, "%.0f%%", 10)) {
            g_settings.ui_volume = pct / 100;
            sound(UI_SND_SELECT);  // (a preview at the new level)
        }
    }
    ImGui::EndDisabled();
    ui_section_end();
}

// Controls: the controller, the mouse, the keyboard's keys (click a key's row, then press the new key: Esc or 5 s
// cancel; a key already in use swaps over)
static const struct { int slot; const char *en, *pt; } k_actions[] = {
    {BIND_LS_UP, "Walk up", "Andar para cima"},            {BIND_LS_DOWN, "Walk down", "Andar para baixo"},
    {BIND_LS_LEFT, "Walk left", "Andar para a esquerda"},  {BIND_LS_RIGHT, "Walk right", "Andar para a direita"},
    {BIND_UP, "D-pad up", "Direcional cima"},              {BIND_DOWN, "D-pad down", "Direcional baixo"},
    {BIND_LEFT, "D-pad left", "Direcional esquerda"},      {BIND_RIGHT, "D-pad right", "Direcional direita"},
    {BIND_A, "A  ·  Confirm", "A  ·  Confirmar"},          {BIND_B, "B  ·  Back", "B  ·  Voltar"},
    {BIND_X, "X  ·  Menu", "X  ·  Menu"},                  {BIND_Y, "Y  ·  Y-Comm", "Y  ·  Y-Comm"},
    {BIND_L, "L  ·  Camera", "L  ·  Câmera"},              {BIND_R, "R  ·  Bike", "R  ·  Bicicleta"},
    {BIND_PLUS, "+  ·  Bike", "+  ·  Bicicleta"},          {BIND_MINUS, "-  ·  Menu", "-  ·  Menu"},
};
static const char *key_name(int sc) {
    switch (sc) {
    case SDL_SCANCODE_SPACE: return UI_T("Space", "Espaço", "Пробел");
    case SDL_SCANCODE_RETURN: return "Enter";
    case SDL_SCANCODE_UP: return UI_T("Up arrow", "Seta cima", "Стрелка вверх");
    case SDL_SCANCODE_DOWN: return UI_T("Down arrow", "Seta baixo", "Стрелка вниз");
    case SDL_SCANCODE_LEFT: return UI_T("Left arrow", "Seta esquerda", "Стрелка влево");
    case SDL_SCANCODE_RIGHT: return UI_T("Right arrow", "Seta direita", "Стрелка вправо");
    case 0: return UI_T("(none)", "(nenhuma)", "(нет)");
    default: return bind_key_label(sc);
    }
}

void ui_page_controls(void) {
    ui_section(UI_T("Controller", "Controle", "Контроллер"));
    {   // which buttons are A / B and X / Y (runtime/hle/bindings.c): Automatic follows the controller in use
        char autol[96];
        int now = bind_layout();
        snprintf(autol, sizeof autol, "%s (%s)", UI_T("Automatic", "Automático", "Авто"),
                 now == BIND_LAYOUT_XBOX ? "Xbox" : now == BIND_LAYOUT_WESTERN ? UI_T("Western", "Ocidental", "Западная") : "Nintendo");
        const char *lay[] = {autol, "Nintendo", "Xbox", UI_T("Western", "Ocidental", "Западная")};
        static const int val[] = {BIND_LAYOUT_AUTO, BIND_LAYOUT_NINTENDO, BIND_LAYOUT_XBOX, BIND_LAYOUT_WESTERN};
        int pref = bind_layout_pref(), v = 0;
        for (int i = 0; i < 4; i++) if (val[i] == pref) v = i;
        ui_row(UI_T("Button layout", "Layout dos botões", "Раскладка кнопок"));
        if (ui_combo("##padlayout", &v, lay, 4)) bind_set_layout(val[v]);
        ui_tip(UI_T("Switch controllers: Nintendo; others: Xbox", "Controles de Switch: Nintendo; outros: Xbox", "Switch - Nintendo, остальные - Xbox"));
    }
    ui_row(UI_T("Stick dead zone", "Zona morta do analógico", "Мёртвая зона стика"));
    ui_slider("##dead", &g_settings.stick_deadzone, 0.0f, 0.40f, "%.2f", 0.01f);
    ui_section_end();

    ui_section(UI_T("Mouse", "Mouse", "Мышь"));
    {
        const char *mc[] = {UI_T("Off", "Desligada", "Выкл."), UI_T("Right button", "Botão direito", "Правая кнопка"),
                            UI_T("Always", "Sempre", "Всегда")};
        int v = g_settings.mouse_cam < 0 || g_settings.mouse_cam > 2 ? 2 : g_settings.mouse_cam;
        ui_row(UI_T("Mouse camera", "Câmera com o mouse", "Камера мышью"));
        if (ui_combo("##mousecam", &v, mc, 3)) g_settings.mouse_cam = v;
        ui_tip(UI_T("Left click A, right click B, middle X", "Clique esquerdo A, direito B, meio X", "ЛКМ - A, ПКМ - B, средняя - X"));
    }
    ui_row(UI_T("Sensitivity", "Sensibilidade", "Чувствительность"));
    ui_slider("##mouse", &g_settings.mouse_sens, 0.02f, 0.30f, "%.2f", 0.01f);
    ui_section_end();

    ui_section(UI_T("Keyboard", "Teclado", "Клавиатура"));
    int cap_dev, cap_slot, ms_left;
    bind_capture_active(&cap_dev, &cap_slot, &ms_left);
    for (size_t i = 0; i < sizeof k_actions / sizeof k_actions[0]; i++) {
        int slot = k_actions[i].slot;
        bool waiting = cap_dev == BIND_DEV_KEY && cap_slot == slot;
        char txt[96];
        if (waiting) snprintf(txt, sizeof txt, "%s  %d", UI_T("Press a key", "Aperte uma tecla", "Нажмите клавишу"), (ms_left + 999) / 1000);
        else snprintf(txt, sizeof txt, "%s", key_name(g_bind_key[slot]));
        // (waiting: green; a key changed from the default: the accent)
        ImU32 col = waiting ? ImGui::GetColorU32(UI_GREEN_TEXT) : !bind_is_default_slot(BIND_DEV_KEY, slot) ? ImGui::GetColorU32(UI_ACCENT) : 0;
        ui_row(UI_T(k_actions[i].en, k_actions[i].pt, k_actions[i].en));
        ImGui::PushID(slot);
        if (ui_value_button("##key", txt, col)) {
            if (waiting) bind_capture_cancel();
            else bind_capture_begin(BIND_DEV_KEY, slot);
        }
        ui_tip(UI_T("Select, then press the new key", "Escolha e aperte a nova tecla", "Выберите и нажмите клавишу"));
        ImGui::PopID();
    }
    ImGui::BeginDisabled(bind_is_default(BIND_DEV_KEY));
    if (ui_action_row(UI_T("Reset keys", "Restaurar teclas", "Сбросить клавиши"))) bind_reset(BIND_DEV_KEY);
    ImGui::EndDisabled();
    ui_section_end();
}
