// The menus' own sounds (the start screen and the in-game settings): short tones made here at start, no sound files.
// One SDL audio stream of its own on the default output (SDL mixes it with the game's); a new sound cuts the one still
// playing, so holding the d-pad gives a tick per step, not a queue. g_settings.ui_sounds / ui_volume (larecomp.ini).
// LARECOMP_NO_AUDIO=1 (tests) keeps it silent. LARECOMP_UI_SOUND_LOG=1 logs each sound played.
#include <SDL3/SDL.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#include "ui_sound.h"

extern "C" {
#include "../settings.h"
}

static SDL_AudioStream *g_stream;
static int g_state;  // 0 not tried, 1 ready, -1 no audio
static std::vector<float> g_snd[UI_SND_COUNT];
static const int RATE = 48000;

// A tone gliding from f0 to f1 over `ms`, a quick attack and an exponential fade; a quiet octave above for some body
static void tone(std::vector<float> &out, float f0, float f1, float ms, float amp, float start_ms = 0) {
    size_t at = (size_t)(start_ms * RATE / 1000), n = (size_t)(ms * RATE / 1000);
    if (out.size() < at + n) out.resize(at + n, 0.0f);
    double ph = 0;
    for (size_t i = 0; i < n; i++) {
        float t = (float)i / n, f = f0 + (f1 - f0) * t;
        float env = fminf(1.0f, i / (RATE * 0.003f)) * expf(-4.5f * t);
        ph += 2 * 3.14159265358979 * f / RATE;
        out[at + i] += amp * env * (float)(sin(ph) + 0.18 * sin(2 * ph));
    }
}

static void build(void) {
    tone(g_snd[UI_SND_MOVE], 1480, 1420, 26, 0.16f);
    tone(g_snd[UI_SND_SELECT], 880, 900, 45, 0.22f);
    tone(g_snd[UI_SND_SELECT], 1320, 1330, 60, 0.20f, 35);
    tone(g_snd[UI_SND_BACK], 1180, 760, 80, 0.20f);
    tone(g_snd[UI_SND_ON], 990, 1000, 35, 0.18f);
    tone(g_snd[UI_SND_ON], 1480, 1490, 50, 0.18f, 30);
    tone(g_snd[UI_SND_OFF], 1480, 1470, 35, 0.18f);
    tone(g_snd[UI_SND_OFF], 990, 980, 50, 0.18f, 30);
    tone(g_snd[UI_SND_PAGE], 700, 1050, 70, 0.14f);
    tone(g_snd[UI_SND_PLAY], 1047, 1047, 90, 0.20f);         // C6 E6 G6 C7
    tone(g_snd[UI_SND_PLAY], 1319, 1319, 90, 0.20f, 70);
    tone(g_snd[UI_SND_PLAY], 1568, 1568, 100, 0.20f, 140);
    tone(g_snd[UI_SND_PLAY], 2093, 2093, 220, 0.18f, 210);
}

static bool ready(void) {
    if (g_state) return g_state > 0;
    g_state = -1;
    const char *na = getenv("LARECOMP_NO_AUDIO");
    if (na && strcmp(na, "0")) return false;
    if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) return false;
    SDL_AudioSpec spec = {SDL_AUDIO_F32, 1, RATE};
    g_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
    if (!g_stream) return false;
    SDL_ResumeAudioStreamDevice(g_stream);
    build();
    g_state = 1;
    return true;
}

void ui_sound(int which) {
    if (which < 0 || which >= UI_SND_COUNT || !g_settings.ui_sounds || g_settings.ui_volume <= 0.001f) return;
    if (getenv("LARECOMP_UI_SOUND_LOG")) SDL_Log("[uisound] %d", which);
    if (!ready()) return;
    const std::vector<float> &s = g_snd[which];
    std::vector<float> buf(s.size());
    float v = g_settings.ui_volume;
    for (size_t i = 0; i < s.size(); i++) buf[i] = s[i] * v;
    SDL_ClearAudioStream(g_stream);  // (the one still playing stops: a fresh sound each step)
    SDL_PutAudioStreamData(g_stream, buf.data(), (int)(buf.size() * sizeof(float)));
}
