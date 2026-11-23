// The menus' sounds (runtime/ui/ui_sound.mm): played by the shared widgets (settings_ui.mm) and the screens
#pragma once
enum { UI_SND_MOVE, UI_SND_SELECT, UI_SND_BACK, UI_SND_ON, UI_SND_OFF, UI_SND_PAGE, UI_SND_PLAY, UI_SND_COUNT };
void ui_sound(int which);  // (any thread; nothing when the menu sounds are off)
