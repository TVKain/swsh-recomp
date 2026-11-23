// The look, the layout and the settings pages shared by the start screen (runtime/ui/launcher_lg.mm) and the in-game
// settings (runtime/ui/menu.mm), so both look and work alike. Each screen has its own Dear ImGui context; these act on
// the current one. The pages edit g_settings directly (in game they apply at once); the caller saves them.
//
// The layout (2026-11-22 redesign, one system for both screens):
//   a sidebar (the mark and name, the pages, the main action + a quiet second one at its foot) | the page: its title,
//   then sections - a small muted heading over a white rounded card whose rows are split by hairlines - and a footer
//   line (the focused row's one-line note at the left, the controller / key prompts at the right).
// Rows: the label at the left, the value right-aligned. A changes it: lists and numbers open a small popup (B cancels),
// switches flip. Left / right never change a value; they only move the cursor (player 2026-11-22).
// The cursor: a pale accent tint inset in the row; with the controller / keyboard also a 2 px accent ring.
#pragma once
#include "imgui.h"

// The language: 0 English, 1 Portuguese, 2 Russian (LARECOMP_LANG=en|pt|ru, else the system's)
extern int g_ui_lang;
void ui_pick_language(void);
#define UI_T(en, pt, ru) (g_ui_lang == 2 ? (ru) : g_ui_lang == 1 ? (pt) : (en))

// Fonts into the current context's atlas, built for a 1080 px tall window (ui_scale scales them): Segoe UI for the text,
// Segoe UI Semibold for titles and the bigger text (DejaVu on Linux)
struct UiFonts { ImFont *body, *big, *title; };
UiFonts ui_load_fonts(void);
void ui_style(void);
// The window's height over 1080 as the scale of the fonts and of the style's sizes (from the unscaled style, kept here)
struct UiScaler { ImGuiStyle base; float scale = -1; };
float ui_scale(UiScaler &s, float window_h);
float ui_px(void);  // 1 at 1080 px

extern const ImVec4 UI_GOLD, UI_GREEN_TEXT, UI_RED_TEXT, UI_TEXT, UI_HEADING, UI_MUTED, UI_ACCENT;
extern const ImU32 UI_COL_BG, UI_COL_SIDE, UI_COL_CARD, UI_COL_LINE;
void ui_window_backdrop(void);  // the flat page background behind the current window (right after its Begin)
bool ui_nav_cursor(void);       // the controller / keyboard cursor is showing (not the mouse)
bool ui_hot(ImVec2 a, ImVec2 b);  // whether a rect drawn by the caller has the cursor
// The cursor's look on a rect: the pale tint (+ the ring for the controller / keyboard)
void ui_highlight(ImDrawList *dl, ImVec2 a, ImVec2 b, float rounding);
// Once per frame after the windows, before ImGui::Render: the notes and the move sound
void ui_frame_end(void);

// ---- the shell
void ui_logo_mark(ImDrawList *dl, ImVec2 p, float size);
// The sidebar's top: the mark, `name` and `sub` (muted) under it
void ui_sidebar_brand(ImFont *title, const char *name, const char *sub);
// A page in the sidebar: the current one white with accent text. focus: give it the cursor now. Returns clicked.
bool ui_nav_item(const char *label, bool current, bool focus);
// The page's title (semibold, at the top of the page)
void ui_page_title(ImFont *title, const char *text);
// The footer: a hairline at a.y, the focused row's note at the left, the prompts at the right (controller: A Select,
// B Back, L R Pages; keyboard / mouse: Esc + back_label). Between a and b (b.y the footer's bottom).
void ui_footer(ImVec2 a, ImVec2 b, const char *back_label, bool pages);
// The height a footer takes
float ui_footer_h(void);

// ---- the page and its sections
float ui_inset(void);  // the text's inset in a row
void ui_page_begin(const char *id, ImVec2 size);  // a scrolling child holding the sections (pad navigation flattened)
void ui_page_end(void);
void ui_section(const char *title);  // a heading (NULL: none) and a card; rows follow until ui_section_end
void ui_section_end(void);
void ui_row(const char *label, float x = -1);  // a row: the label, then the next widget fills the row's right part
bool ui_row_hot(void);  // the row being drawn has the cursor
// A row that does something: label, an optional muted value, a chevron. Returns clicked.
bool ui_action_row(const char *label, const char *value = 0, ImU32 value_col = 0);
// Values in a ui_row: a list (A opens it: the current one checked, the cursor's row solid accent; B closes),
// a switch, a number (A opens a popup with the slider: left / right live, A keeps, B restores), a text value clicked
bool ui_combo(const char *id, int *v, const char *const *items, int n);
bool ui_toggle(const char *id, const char *label, float x, bool *v);
bool ui_slider(const char *id, float *v, float lo, float hi, const char *fmt, float step);
bool ui_value_button(const char *id, const char *text, ImU32 col);
// B / Esc went down this frame (each screen sets it from its own input): a popup closed by it restores the value
extern bool g_ui_cancel;
// Buttons outside the cards (the sidebar's foot, dialogs): primary = accent, secondary = white outlined,
// ghost = text only. width 0: the text's, -1: the whole line
bool ui_button(const char *label, float width = 0);
bool ui_button_primary(const char *label, float width = 0, float height = 0);
bool ui_button_ghost(const char *label, float width = 0);

// The last item's note: shown in the footer while that item has the cursor (keep them one short line)
void ui_tip(const char *text);
const char *ui_tip_last(void);
// L1 / R1 on a controller: the page before / after, once per frame (with the page sound)
void ui_tabs_begin(int *current, int count);

// ---- the pages (both screens). known: the build has the 60 fps mode's tables (runtime/hle/swsh60.c).
// apply_window: called when the window mode row changes (the screens apply it on the main thread).
void ui_page_display(bool known, void (*apply_window)(void));
void ui_page_graphics(bool known);
void ui_page_audio(void);
void ui_page_controls(void);
