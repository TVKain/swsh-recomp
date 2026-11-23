// Sword / Shield at 60 fps (the launcher's 60 fps option). What the community's 60 fps patch does (Fl4sh9174's
// "60FPS v1.3.2" pchtxt), mapped to each build, done by the runtime instead of patching the executable:
//  - the game asks for a present interval of 2 (30 fps) through a small wrapper (1.0.0: main+0x178e098, 1.3.2:
//    main+0x18a2c88, `mov w1, w21` before the call); the patch passes 1. Here nvnWindowSetPresentInterval gets 1.
//  - the game keeps a table of frame durations in ns by interval (16666667, 33333334, 50000000, ...), read with the
//    measured time to scale animations (main+0x686908 in 1.0.0); the patch makes the interval-2 entry 1/60 s.
// The game measures real frame times itself (main+0x5dfee4), so the rest follows; verified against the patch's own
// addresses in 1.3.2 (docs/DIAGNOSTICO-SWSH.md).
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../settings.h"

typedef struct { uint8_t build[8]; uint64_t table2; const char *name; } Swsh60Build;
static const Swsh60Build k_builds[] = {
    {{0x8d, 0xaf, 0xed, 0xbb, 0x5b, 0xe8, 0x1c, 0x2c}, 0x7001f07578ull, "Sword 1.0.0"},
    {{0xa3, 0xb7, 0x5b, 0xcd, 0x33, 0x11, 0x38, 0x5a}, 0x700203eeb8ull, "Sword 1.3.2"},
};

static const Swsh60Build *g_build;  // the running build, when it is in the table
static bool g_on, g_applied;

static const Swsh60Build *build_of(const char *exefs) {
    char p[1100];
    snprintf(p, sizeof p, "%s/main", exefs);
    FILE *f = fopen(p, "rb");
    if (!f) return NULL;
    uint8_t id[8] = {0};
    fseek(f, 0x40, SEEK_SET);  // (NSO header: the module id)
    size_t n = fread(id, 1, 8, f);
    fclose(f);
    for (size_t i = 0; n == 8 && i < sizeof k_builds / sizeof *k_builds; i++)
        if (!memcmp(id, k_builds[i].build, 8)) return &k_builds[i];
    return NULL;
}

bool swsh60_supported(const char *exefs) { return build_of(exefs) != NULL; }

// runtime/main.c, before each boot: the option and the build
void swsh60_configure(const char *exefs) {
    extern void settings_load(void);
    settings_load();  // (read once; with --play nothing has read larecomp.ini yet)
    g_build = build_of(exefs);
    g_on = g_build && g_settings.fps == 60;
    g_applied = false;
    if (g_build) LOG("[swsh60] %s: 60 fps %s\n", g_build->name, g_on ? "on" : "off");
    extern void uimouse_configure(bool sword132);  // (runtime/hle/uimouse.c: the mouse in the menus)
    uimouse_configure(g_build == &k_builds[1]);
}

bool swsh60_enabled(void) { return g_on; }
bool swsh60_known(void) { return g_build != NULL; }  // (the F12 menu: the 60 fps choice is offered)

// Why the table entry is not simply rewritten for everyone (what the community patch does, kept as
// LARECOMP_SWSH60_GLOBAL=1): Sword 1.3.2 reads the frame duration table G (main+0x203eeb0, through the pointer at
// main+0x26154c8; found from its R_AARCH64_RELATIVE entry) in exactly three places:
//  - f_70005df580(timers, i, idx): timers.step[i] = G[idx], called once per update with i = 1, idx = 1 (from
//    main+0x5df32c): the time one update stands for;
//  - f_7000680f20 / f_7000687f80: animation and timeline players advance by step[1] / (G[idx] - 1) frames
//    (idx = the player's own +0x68, or the frame-rate setting object's +0x88: 1).
// With G[1] = 1/60 s for every reader a player advances step / G[1] = one 30 fps frame per 60 fps update: twice the
// speed (the opening cutscene ran ahead of its dialogue; Charizard and the crowd jumped, the starter cutscene
// "teleported"). G[1] = 1/60 s only while the step setter runs: step = 1/60 s, the players advance half a frame per
// update - the game's own speed, at 60 (the same split runtime/hle/fps60.c does for Let's Go).
#define SWSH132_STEP_SETTER 0x70005df580ull
void rt_register_fnhook_abs(uint64_t addr, int (*fn)(Cpu *c, uint64_t addr));  // runtime/fnhook.c
void rt_call_original(Cpu *c, uint64_t addr);
// Research (LARECOMP_DOF_LOG=1): f_70004a7e70 turns each depth-of-field layer's distance range [a, b] into the shader
// pair (1/(b-a), -a/(b-a)). Logs its inputs (per-layer data, global scales) and outputs whenever they change.
static int dof_hook(Cpu *c, uint64_t addr) {
    uint64_t o = c->x[0];
    static int watched;
    if (!watched && getenv("LARECOMP_DOF_WATCH")) {  // (who writes the per-frame scale +0x1e4)
        extern void memwatch_add(uint64_t addr);
        watched = 1;
        memwatch_add(o + 0x1e4);
    }
    rt_call_original(c, addr);
    const float *g = NULL;
    float gl[5];
    uint64_t ga[5] = {0x7001c4bac8ull, 0x7001c4c70cull, 0x7001c4c094ull, 0x7001c4c7a8ull, 0x7001c4bbf8ull};
    for (int i = 0; i < 5; i++) memcpy(&gl[i], (const void *)(uintptr_t)ga[i], 4);
    (void)g;
    int n = *(const int32_t *)(uintptr_t)(o + 0xd0);
    uint64_t base = *(const uint64_t *)(uintptr_t)(o + 0x4a8);
    char line[2048];
    int k = snprintf(line, sizeof line, "g %g %g %g %g %g | flags %x +16c %d +1e4 %g +1f0 %g +1f4 %g | base+30 %g | n %d", gl[0], gl[1], gl[2], gl[3], gl[4],
                     *(const uint32_t *)(uintptr_t)(o + 0x154), *(const int32_t *)(uintptr_t)(o + 0x16c), *(const float *)(uintptr_t)(o + 0x1e4),
                     *(const float *)(uintptr_t)(o + 0x1f0), *(const float *)(uintptr_t)(o + 0x1f4), base ? *(const float *)(uintptr_t)(base + 0x30) : 0.f, n);
    for (int i = 0; i < n && i < 6 && base; i++) {
        uint64_t l = base + 0x20 + 0x108ull * i;
        const float *f = (const float *)(uintptr_t)l;
        k += snprintf(line + k, sizeof line - k, " || L%d in %g %g (-248 %g) out %g %g %g %g %g %g %g %g %g %g %g %g", i, f[0], f[4], *(const float *)(uintptr_t)(l - 248),
                      f[40], f[41], f[42], f[43], f[44], f[45], f[46], f[47], f[50], f[51], f[52], f[53]);
    }
    static char last[2048];
    if (strcmp(last, line)) {
        extern uint64_t renderer_game_frame(void);
        strcpy(last, line);
        LOG("[dof] f%llu obj %llx %s\n", (unsigned long long)renderer_game_frame(), (unsigned long long)o, line);
    }
    return 1;
}

static int step_setter_hook(Cpu *c, uint64_t addr) {
    if (!g_on || (uint32_t)c->x[2] != 1) return 0;
    volatile uint64_t *e = (volatile uint64_t *)(uintptr_t)g_build->table2;
    uint64_t old = *e;
    *e = 16666667ull;
    uint64_t timers = c->x[0];
    rt_call_original(c, addr);
    *e = old;
    static int step0 = -1;
    if (step0 < 0) step0 = getenv("LARECOMP_SWSH60_STEP0") != NULL;
    if (step0 && *(uint64_t *)(uintptr_t)(timers + 0x10) == 33333334ull) *(uint64_t *)(uintptr_t)(timers + 0x10) = 16666667ull;
    // Research: the timer object's entries (f_70005df5a0 writes entry i at +0x10 + 16 i): step 0 is written elsewhere
    static int logged;
    if (getenv("LARECOMP_SWSH60_PROBE") && logged < 3) {
        logged++;
        const uint64_t *t = (const uint64_t *)(uintptr_t)timers;
        LOG("[swsh60] timers %llx: +0x10 %llu +0x18 %llu +0x20 %llu +0x28 %llu +0x30 %llu +0x38 %llu\n", (unsigned long long)timers,
            (unsigned long long)t[2], (unsigned long long)t[3], (unsigned long long)t[4], (unsigned long long)t[5],
            (unsigned long long)t[6], (unsigned long long)t[7]);
    }
    return 1;
}

// Research (LARECOMP_SWSH60_PROBE=1): at the animation players' entry, the step they will read (the timer object's
// first virtual method with argument 1, field +8) and their divisor G[idx], per caller, once per 120 presents.
uint64_t renderer_game_frame(void);
static int probe_hook(Cpu *c, uint64_t addr) {
    static _Thread_local int depth;
    if (depth) return 0;
    uint64_t f = renderer_game_frame();
    static uint64_t last[2];
    int k = addr == 0x7000687f80ull;
    if (f - last[k] < 120) return 0;
    last[k] = f;
    uint64_t saved[32], obj = *(uint64_t *)(uintptr_t)c->x[0], tm = c->x[1] ? *(uint64_t *)(uintptr_t)c->x[1] : 0;
    memcpy(saved, c->x, sizeof saved);
    int idx = -1;
    if (k) {
        uint64_t s = *(uint64_t *)(uintptr_t)0x7002610470ull, o = s ? *(uint64_t *)(uintptr_t)s : 0;
        idx = o ? *(int32_t *)(uintptr_t)(o + 0x88) : -1;
    } else idx = *(int32_t *)(uintptr_t)(obj + 0x68);
    long long step = -1;
    if (tm >= 0x7000000000ull) {
        uint64_t vt = *(uint64_t *)(uintptr_t)tm, fn = *(uint64_t *)(uintptr_t)vt;
        c->x[0] = tm, c->x[1] = 1;
        depth++; guest_call(c, fn); depth--;
        if (c->x[0] >= 0x7000000000ull) step = *(int64_t *)(uintptr_t)(c->x[0] + 8);
    }
    memcpy(c->x, saved, sizeof saved);
    const uint64_t *G = (const uint64_t *)(uintptr_t)0x700203eeb0ull;
    LOG("[swsh60] probe f%llu f_%llx lr %llx: step %lld ns, idx %d, G[idx] %llu -> %.3f frames\n", (unsigned long long)f,
        (unsigned long long)addr, (unsigned long long)c->x[30], step, idx, idx >= 0 && idx < 6 ? (unsigned long long)G[idx] : 0ull,
        idx >= 0 && idx < 6 ? (double)step / (double)(G[idx] - 1) : 0.0);
    return 0;
}

// Cutscenes (the "demo" player: task f_7000c10140, playing state f_7000c15240) keep their own clock in 1/60 s units:
// f_7000c679f0 adds 2 to the demo object's counter (+0x7a4) each update unless one of five pause slots (+0x7a8..+0x7c8,
// empty = the FNV-1a offset basis) is held; a negative counter is reset to 0. At 60 updates a second that was 120 ticks
// a second: every cutscene at double speed while the models' animations ran at their own (Charizard "teleporting",
// the crowd and the starter cutscene skipping). Found by bisecting the per-update tasks (LARECOMP_FNSKIP: skipping
// f_7000c10140 on odd frames halved the cutscene's pace) and reading the playing state's callees. At 60 the step is 1.
#define SWSH132_DEMO_TICK 0x7000c679f0ull
static int demo_tick_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    uint8_t *d = (uint8_t *)(uintptr_t)c->x[0];
    const uint64_t empty = 0xcbf29ce484222645ull;
    for (int i = 0; i < 5; i++)
        if (*(uint64_t *)(d + 0x7a8 + 8 * i) != empty) return 1;  // paused: the game's function does nothing either
    int32_t *t = (int32_t *)(d + 0x7a4);
    *t = *t < 0 ? 0 : *t + 1;
    return 1;
}

// Message text (player report: text prints twice as fast at 60). f_700067f370(msg) runs once per update and steps the
// printer (f_700067f740) up to msg+0xa4 counted steps; a step prints the next character once the wait counter msg+0x9e
// passes the limit msg+0x9d (0 at Normal speed), which the function then reloads from msg+0xa5. Counted per update =
// per 1/30 s on the Switch. Fix: at 60 the limit is 2 * wait + 1 for each update, so every character takes twice the
// steps. Verified with tests/scenarios/npc_talk.json (the window's visible-character count, LARECOMP_PEEK): 30 fps
// +4/frame for 16 characters then +2/frame = 12 frames; 60 fps unfixed +4/present = 8 presents (3x too fast); fixed
// +2/present then +1 = 24 presents = the same 0.4 s. (Skipping odd updates does NOT work: the next update catches
// up.) Writer of the count found with LARECOMP_WATCH_FROM; off: LARECOMP_SWSH60_NO_TEXT=1.
#define SWSH132_MSG_UPDATE 0x700067f370ull
static int msg_update_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    uint8_t *m = (uint8_t *)(uintptr_t)c->x[0];
    m[0x9d] = (uint8_t)(m[0xa5] * 2 + 1);
    return 0;  // (the game's function runs with the doubled wait)
}

// Battle main task. The task dispatcher calls f_700098f310(task) (a member-function thunk: object = task+0, here the
// battle main, vtable 0x70025303f0) once per update; the battle's sequencing (messages' waits, move animations' lead-in,
// HP drain, the pause between messages) counts those updates. At 60 it runs on even updates only = the Switch's 30 a
// second; models, camera, effects and the UI keep updating at 60. Verified grass_battle_atk60w against 30 fps: message
// box 12 = 12 shots, pause to the next message 16 vs 17, message close -> HP drain 7 = 7, drain 8 = 8 (battle text
// itself prints within one update, as at 30). Found by bisecting the per-update tasks with LARECOMP_FNSKIP: the
// message's own waits (printer f_700067f3f0 +0xa3 up to +0xa2; message process f_700095aa90 +0x630 down from 35) and
// the view's state machine f_700096dd30 all run inside this task, so compensating them separately is not needed.
// Off: LARECOMP_SWSH60_NO_BTLTASK=1.
#define SWSH132_TASK_THUNK 0x700098f310ull
#define SWSH132_BATTLE_MAIN_VT 0x70025303f0ull
// The game's input (pressed-this-update edges) updates every update, outside this task: a press first seen on an odd
// update was gone (held, not "new") by the even one the battle runs on - about half the presses / touches in a battle
// needed a second try. So while a battle runs (swsh60_battle_paced) hle/input.c reports on odd updates the same
// controller / touch state as on the even update before: every change reaches the game on an even update.
static _Atomic uint64_t g_battle_frame;  // (last update the battle main task was dispatched, + 1)
bool swsh60_battle_paced(void) {
    extern uint64_t renderer_game_frame(void);
    static int off = -1;  // LARECOMP_SWSH60_NO_INPUTHOLD=1: off (A/B)
    if (off < 0) off = getenv("LARECOMP_SWSH60_NO_INPUTHOLD") != NULL;
    uint64_t b = g_battle_frame;
    extern bool swsh60_menu_paced(void);  // (paced menus too: same lost-press problem)
    return !off && ((b && renderer_game_frame() + 1 - b < 4) || swsh60_menu_paced());
}
static int btltask_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    uint64_t obj = *(uint64_t *)(uintptr_t)c->x[0];
    if (obj < 0x7000000000ull || obj >= 0x7800000000ull) return 0;
    static int tasklog = -1;  // (research) LARECOMP_SWSH60_TASKLOG=1: each task object kind (vtable) the first time it runs
    if (tasklog < 0) tasklog = getenv("LARECOMP_SWSH60_TASKLOG") != NULL;
    if (tasklog) {
        static uint64_t seen[1024];
        static int n;
        uint64_t vt = *(uint64_t *)(uintptr_t)obj;
        bool found = false;
        for (int i = 0; i < n && !found; i++) found = seen[i] == vt;
        if (!found && n < 1024) {
            seen[n++] = vt;
            LOG("[tasklog] frame %llu: new task vtable %llx (obj %llx)\n", (unsigned long long)renderer_game_frame(),
                (unsigned long long)vt, (unsigned long long)obj);
        }
    }
    if (*(uint64_t *)(uintptr_t)obj != SWSH132_BATTLE_MAIN_VT) return 0;
    uint64_t f = renderer_game_frame();
    if (!g_battle_frame) {  // (research) LARECOMP_DEBUG_AT_BATTLE=<n>: debug frame (F9) n presents after the first battle update
        const char *e = getenv("LARECOMP_DEBUG_AT_BATTLE");
        if (e) {
            extern void renderer_debug_frame_at(long at);
            renderer_debug_frame_at((long)f + atol(e));
            LOG("[swsh60] first battle update at present %llu\n", (unsigned long long)f);
        }
    }
    g_battle_frame = f + 1;
    return (f & 1) ? 1 : 0;
}

// Menu / UI layout animations (MENU60, player report 2026-11-22: X menu, party icons, map cursor twice as fast at 60).
// f_70006513d0(anim, ..., s0 = frames to advance) is the UI animation system's update; its three top-level callers
// (lr 700064f9b8, 7000650858, 7000650304) pass a fixed 1.0 frame per update at 30 AND at 60 (logged with
// LARECOMP_SWSH60_ANIMLOG=1) = 60 animation frames a second at 60. At 60 they pass 0.5: every update animates, at the
// game's speed. The fourth caller (lr 7000650948) passes cross-fade weights that already follow the time (1/6 steps at
// 30, 1/12 at 60) - left alone. Verified with tests/scenarios/menu_party.json (party icon hop: 14 samples a cycle at
// 30, 7 at 60 unfixed). Off: LARECOMP_SWSH60_NO_UIANIM=1.
#define SWSH132_UIANIM 0x70006513d0ull
static int uianim_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    uint64_t lr = c->x[30];
    if (lr != 0x700064f9b8ull && lr != 0x7000650858ull && lr != 0x7000650304ull) return 0;
    float s0;
    memcpy(&s0, &c->v[0], 4);
    if (s0 == 1.0f) {
        s0 = 0.5f;
        memcpy(&c->v[0], &s0, 4);
    }
    return 0;
}
// (research) LARECOMP_SWSH60_FRAMELOG=1: f_700059a680(frame object, s0 = time step): frame += speed (+8) x fps (+4) x
// s0 - each caller with each (s0, fps) once
#define SWSH132_UIFRAME 0x700059a680ull
static int framelog_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    float s0, speed;
    memcpy(&s0, &c->v[0], 4);
    int32_t fps = *(int32_t *)(uintptr_t)(c->x[0] + 4);
    memcpy(&speed, (void *)(uintptr_t)(c->x[0] + 8), 4);
    static uint64_t seen[512];
    static int ns;
    uint32_t bits;
    memcpy(&bits, &s0, 4);
    uint64_t key = (c->x[30] & 0xffffffffull) ^ ((uint64_t)bits << 32) ^ ((uint64_t)fps << 20);
    for (int i = 0; i < ns; i++) if (seen[i] == key) return 0;
    if (ns < 512) seen[ns++] = key;
    LOG("[framelog] f%llu s0 %g fps %d speed %g lr %llx\n", (unsigned long long)renderer_game_frame(), (double)s0, fps,
        (double)speed, (unsigned long long)c->x[30]);
    return 0;
}
// Party / box Pokémon icons (MENU60, player report 2026-11-22: "Scorbunny jumping fast" in the X menu's Pokémon list).
// f_7001371210(list) animates the 7 icon slots from ONE integer counter list+0x610: for each slot f_700136bc50(slot,
// counter) sets its layout animation (hop + sprite flip) to frame counter % length (f_700157bdb0 -> f_7000686fd0
// stores anim+0x20), then counter += 1 - a whole animation frame per update = twice the speed at 60. At 60 each slot gets
// counter / 2 and the half frame left over (+0.5) is added to the frame it sets: the keyframe curves are interpolated,
// so the hop moves every update at the Switch's speed. Found with LARECOMP_SWSH60_LYTLOG / LARECOMP_TRACE_FVAL /
// LARECOMP_WATCH_AT (menu_party.json: icon y offset, vertex cbuf word 23, loops in 14 updates at 30 and at 60 before).
// Off: LARECOMP_SWSH60_NO_ICONS=1.
#define SWSH132_ICON_SLOT 0x700136bc50ull   // (slot, counter)
#define SWSH132_ANIM_SETFRAME 0x700157bdb0ull  // (layout, anim id, s0 = frame); f_700136bc50 tail-calls it
static __thread int t_icon_half = -1;
// (inside a battle the battle main task - and the UI it drives - already runs 30 updates a second: leave it alone)
static bool battle_now(void) {
    extern uint64_t renderer_game_frame(void);
    uint64_t b = g_battle_frame;
    return b && renderer_game_frame() + 1 - b < 4;
}
static bool icon_lr(uint64_t lr) { return lr >= 0x700137122cull && lr <= 0x700137128cull && (lr & 0xf) == 0xc; }
static int icon_slot_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    if (!icon_lr(c->x[30]) || battle_now()) return 0;
    uint32_t n = (uint32_t)c->x[1];
    t_icon_half = (int)(n & 1);
    c->x[1] = n >> 1;
    return 0;
}
static int anim_setframe_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    if (t_icon_half < 0 || !icon_lr(c->x[30])) return 0;
    if (t_icon_half) {
        float s0;
        memcpy(&s0, &c->v[0], 4);
        s0 += 0.5f;
        memcpy(&c->v[0], &s0, 4);
    }
    t_icon_half = -1;
    return 0;
}

// Town Map cursor (MENU60, player report: "try moving the cursor, it's fast"). f_700150f0d0(cursor, boost flag, s0/s1 =
// stick x/y) moves it by stick x speed (+0x28, x boost +0x2c) pixels per update - 55 px a frame at full tilt, i.e. twice
// as far a second at 60 (measured tests/scenarios/menu_map.json: 110 px per 4 frames at 30, 215 at 60). At 60 the stick
// is halved: the cursor moves every update at the Switch's speed. Off: LARECOMP_SWSH60_NO_MAPCURSOR=1.
#define SWSH132_MAP_CURSOR 0x700150f0d0ull
static int map_cursor_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    float x, y;
    memcpy(&x, &c->v[0], 4);
    memcpy(&y, &c->v[1], 4);
    x *= 0.5f, y *= 0.5f;
    memcpy(&c->v[0], &x, 4);
    memcpy(&c->v[1], &y, 4);
    return 0;
}

// Held-button repeat in menus (MENU60: holding the d-pad in Options / lists scrolled twice as fast at 60, measured
// tests/scenarios/menu_options.json). The pad object's update f_7000f203f0 keeps a repeat timer at pad+8: +0x8 first
// delay, +0xc interval, +0x10 countdown in UPDATES; on a new button set f_7000f21890 reloads the countdown from the
// delay (lr 7000f206a0), f_7000f218b0 counts down one per update (reloading interval - 1), the repeat bit is set while
// it is 0. At 60 the delay and interval are doubled (2d - 1 keeps the first repeat on the same 1/30 s) right before the
// reload; the originals are remembered so a value the game writes again is picked up. Off: LARECOMP_SWSH60_NO_REPEAT=1.
#define SWSH132_REPEAT_RESET 0x7000f21890ull
static int repeat_reset_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    if (c->x[30] != 0x7000f206a0ull) return 0;
    static struct { uint64_t t; uint32_t d, i, d2, i2; } seen[8];
    static int n;
    uint32_t *f = (uint32_t *)(uintptr_t)(c->x[0] + 8);  // f[0] delay, f[1] interval
    int k = 0;
    while (k < n && seen[k].t != c->x[0]) k++;
    if (k == n) {
        if (n == 8) return 0;
        n++, seen[k].t = c->x[0], seen[k].d2 = seen[k].i2 = ~0u;
    }
    if (battle_now()) {  // (battle input is read on even updates only: the game's own counts, as before)
        if (f[0] == seen[k].d2 && f[1] == seen[k].i2) f[0] = seen[k].d, f[1] = seen[k].i, seen[k].d2 = seen[k].i2 = ~0u;
        return 0;
    }
    if (f[0] != seen[k].d2 || f[1] != seen[k].i2) {  // (first time, or the game set new values)
        seen[k].d = f[0], seen[k].i = f[1];
        seen[k].d2 = f[0] ? f[0] * 2 - 1 : 0, seen[k].i2 = f[1] * 2;
        LOG("[swsh60] button repeat %llx: delay %u interval %u updates -> %u %u\n", (unsigned long long)c->x[0], f[0], f[1],
            seen[k].d2, seen[k].i2);
        f[0] = seen[k].d2, f[1] = seen[k].i2;
    }
    return 0;
}

// Smooth-scrolling lists (MENU60: Options / bag lists; with the repeat fixed the cursor still ran ahead at 60 because
// the list scroll it waits for finished twice as fast). f_70015c99d0(scroller) once per update: pos (+0x1d4) += vel
// (+0x1d8) until it crosses the target (+0x1e0, when +0x1dc is set) and calls the list's move callback; without a
// target, every +0x1c0 updates (counter +0x1bc) vel += accel (+0x1d0), clamped to the signed max (+0x1cc). At 60 the
// original runs with vel / 2 and the accel interval doubled; afterwards vel is put back to full speed (plus the
// acceleration if it happened). Off: LARECOMP_SWSH60_NO_SCROLL=1.
#define SWSH132_SCROLLER 0x70015c99d0ull
static int scroller_hook(Cpu *c, uint64_t addr) {
    uint64_t o = c->x[0];
    if (battle_now()) { rt_call_original(c, addr); return 1; }
    float *vel = (float *)(uintptr_t)(o + 0x1d8);
    uint32_t *lim = (uint32_t *)(uintptr_t)(o + 0x1c0);
    static struct { uint64_t o; uint32_t orig, doubled; } seen[32];
    static int n;
    int k = 0;
    while (k < n && seen[k].o != o) k++;
    if (k == n && n < 32) n++, seen[k].o = o, seen[k].doubled = ~0u;
    if (k < 32 && *lim != seen[k].doubled) seen[k].orig = *lim, seen[k].doubled = *lim * 2, *lim = seen[k].doubled;
    float v = *vel, half = v * 0.5f;
    uint32_t cnt0 = *(uint32_t *)(uintptr_t)(o + 0x1bc);
    *vel = half;
    rt_call_original(c, addr);
    float after = *vel;
    if (after == half) *vel = v;  // (plain step)
    else if (after != 0.0f && cnt0 + 1 >= *lim && *(uint32_t *)(uintptr_t)(o + 0x1bc) == 0) {  // (accelerated)
        float mx, nv = v + (after - half);
        memcpy(&mx, (void *)(uintptr_t)(o + 0x1cc), 4);
        bool over = mx > 0 ? nv > mx : nv < mx;
        *vel = over ? mx : nv;
    }  // (else arrived / stopped: the game's own value)
    return 1;
}

// (research, MENU60) LARECOMP_SWSH60_LYTLOG=<from present>: f_70018aa300(anim transform, pane, ...) applies a layout
// animation (bflan FLPA / FLTP / FLVC ... tags) at the frame anim+0x20 - each call for 3 presents: object, frame, lr
#define SWSH132_LYT_ANIMATE 0x70018aa300ull
static int lytlog_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    static long from = -1;
    if (from < 0) from = atol(getenv("LARECOMP_SWSH60_LYTLOG"));
    long f = (long)renderer_game_frame();
    if (f < from || f > from + 2) return 0;
    float fr;
    memcpy(&fr, (void *)(uintptr_t)(c->x[0] + 0x20), 4);
    LOG("[lytlog] f%ld anim %llx frame %g vt %llx pane %llx lr %llx\n", f, (unsigned long long)c->x[0], (double)fr,
        (unsigned long long)*(uint64_t *)(uintptr_t)c->x[0], (unsigned long long)c->x[1], (unsigned long long)c->x[30]);
    return 0;
}
// (research) LARECOMP_SWSH60_ANIMLOG=1: each caller of f_70006513d0 with each non-zero s0, once
static int animlog_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    static uint64_t last = 0;
    static int n;
    uint64_t f = renderer_game_frame();
    if (f / 60 != last) { last = f / 60; n = 0; }
    float s0;
    memcpy(&s0, &c->v[0], 4);
    static uint64_t seen[256];  // (each caller with each non-zero step once)
    static int ns;
    if (s0 != 0) {
        uint32_t bits;
        memcpy(&bits, &s0, 4);
        uint64_t key = c->x[30] ^ ((uint64_t)bits << 40);
        bool found = false;
        for (int i = 0; i < ns && !found; i++) found = seen[i] == key;
        if (!found && ns < 256) {
            seen[ns++] = key;
            LOG("[animlog] new: f%llu step %g from lr %llx\n", (unsigned long long)f, (double)s0, (unsigned long long)c->x[30]);
        }
    }
    if (n++ < 0) {
        LOG("[animlog] f%llu s0 %g x4 %llx x0 %llx lr %llx\n", (unsigned long long)f, (double)s0, (unsigned long long)c->x[4],
            (unsigned long long)c->x[0], (unsigned long long)c->x[30]);
    }
    return 0;
}

// (research, MENU60) LARECOMP_SWSH60_VIEWLOG=1: each UI view kind (vtable of x0 at the per-view update f_7000efac20)
// the first time it updates, with the game frame.
#define SWSH132_VIEW_UPDATE 0x7000efac20ull
static int viewlog_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    uint64_t obj = c->x[0];
    if (obj < 0x7000000000ull || obj >= 0x7800000000ull) return 0;
    static uint64_t seen[512];
    static int n;
    uint64_t vt = *(uint64_t *)(uintptr_t)obj;
    for (int i = 0; i < n; i++) if (seen[i] == vt) return 0;
    if (n < 512) seen[n++] = vt;
    LOG("[viewlog] frame %llu: view vtable %llx obj %llx lr %llx\n", (unsigned long long)renderer_game_frame(),
        (unsigned long long)vt, (unsigned long long)obj, (unsigned long long)c->x[30]);
    return 0;
}

// X menu and the screens under it (MENU60). UI views update through f_7000efac20(view) once per update, children
// recursively; the menus count updates for their own animations (party icon hop, cursor moves: 2x at 60, player
// report 2026-11-22, measured: party icon cycle 14 samples at 30 fps, 7 at 60). These view kinds update on even
// updates only at 60 = the Switch's 30 a second; the field HUD, the message windows and the rest keep 60. View kinds
// found with LARECOMP_SWSH60_VIEWLOG (grass save: X menu 4 kinds at X, party screen 2 more). RESULT 2026-11-22: pacing
// them (LARECOMP_SWSH60_MENU=1) left the party icon hop at 2x - not the right place; kept as a research switch.
static const uint64_t k_menu_views[] = {
    0x7002566200ull, 0x7002566360ull, 0x700256a398ull, 0x700256a498ull,  // X menu
    0x70025a31e8ull, 0x70025a3478ull,                                    // Pokemon (party)
};
static _Atomic uint64_t g_menu_frame;  // (last update a paced menu view ran, + 1)
static int menuview_hook(Cpu *c, uint64_t addr) {
    (void)addr;
    extern uint64_t renderer_game_frame(void);
    uint64_t obj = c->x[0];
    if (obj < 0x7000000000ull || obj >= 0x7800000000ull) return 0;
    uint64_t vt = *(uint64_t *)(uintptr_t)obj;
    for (size_t i = 0; i < sizeof k_menu_views / sizeof *k_menu_views; i++)
        if (vt == k_menu_views[i]) {
            uint64_t f = renderer_game_frame();
            g_menu_frame = f + 1;
            return (f & 1) ? 1 : 0;
        }
    return 0;
}
bool swsh60_menu_paced(void) {
    extern uint64_t renderer_game_frame(void);
    uint64_t m = g_menu_frame;
    return m && renderer_game_frame() + 1 - m < 4;
}

// nvnWindowSetPresentInterval (runtime/nvn/objects.c): the interval the game asked for -> the one to use. The table
// entry is written (or the step setter hooked) here the first time: the game's main is loaded by then.
int swsh60_interval(int asked) {
    static bool probed;
    if (!probed && getenv("LARECOMP_SWSH60_PROBE") && g_build == &k_builds[1]) {
        probed = true;
        rt_register_fnhook_abs(0x7000680f20ull, probe_hook);
        rt_register_fnhook_abs(0x7000687f80ull, probe_hook);
    }
    static bool dof_hooked;
    static bool frame_hooked;
    if (!frame_hooked && getenv("LARECOMP_SWSH60_FRAMELOG") && g_build == &k_builds[1]) { frame_hooked = true; rt_register_fnhook_abs(SWSH132_UIFRAME, framelog_hook); }
    static bool anim_hooked;
    if (!anim_hooked && getenv("LARECOMP_SWSH60_ANIMLOG") && g_build == &k_builds[1]) { anim_hooked = true; rt_register_fnhook_abs(SWSH132_UIANIM, animlog_hook); }
    static bool view_hooked;
    if (!view_hooked && getenv("LARECOMP_SWSH60_VIEWLOG") && g_build == &k_builds[1]) { view_hooked = true; rt_register_fnhook_abs(SWSH132_VIEW_UPDATE, viewlog_hook); }
    static bool lyt_hooked;
    if (!lyt_hooked && getenv("LARECOMP_SWSH60_LYTLOG") && g_build == &k_builds[1]) { lyt_hooked = true; rt_register_fnhook_abs(SWSH132_LYT_ANIMATE, lytlog_hook); }
    if (!dof_hooked && getenv("LARECOMP_DOF_LOG") && g_build == &k_builds[1]) { dof_hooked = true; rt_register_fnhook_abs(0x70004a7e70ull, dof_hook); LOG("[dof] hook on\n"); }
    if (!g_on) return asked;
    if (!g_applied) {
        g_applied = true;
        uint64_t *e = (uint64_t *)(uintptr_t)g_build->table2;
        bool global = getenv("LARECOMP_SWSH60_GLOBAL") != NULL || g_build != &k_builds[1];  // (1.0.0: setter not mapped)
        if (*e != 33333334ull)
            LOG("[swsh60] unexpected table value %llu at %llx: left alone\n", (unsigned long long)*e, (unsigned long long)g_build->table2);
        else if (global) { *e = 16666667ull; LOG("[swsh60] frame time of interval 2: 1/60 s (every reader)\n"); }
        else { rt_register_fnhook_abs(SWSH132_STEP_SETTER, step_setter_hook); LOG("[swsh60] update step 1/60 s (step setter only)\n"); }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_DEMO")) {
            rt_register_fnhook_abs(SWSH132_DEMO_TICK, demo_tick_hook);
            LOG("[swsh60] cutscene clock: 1 tick (1/60 s) per update\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_TEXT")) {
            rt_register_fnhook_abs(SWSH132_MSG_UPDATE, msg_update_hook);
            LOG("[swsh60] message text: doubled character wait (30 fps pace)\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_BTLTASK")) {
            rt_register_fnhook_abs(SWSH132_TASK_THUNK, btltask_hook);
            LOG("[swsh60] battle main task: 30 updates a second\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_ICONS")) {
            rt_register_fnhook_abs(SWSH132_ICON_SLOT, icon_slot_hook);
            rt_register_fnhook_abs(SWSH132_ANIM_SETFRAME, anim_setframe_hook);
            LOG("[swsh60] Pokemon icons: half an animation frame per update\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_MAPCURSOR")) {
            rt_register_fnhook_abs(SWSH132_MAP_CURSOR, map_cursor_hook);
            LOG("[swsh60] Town Map cursor: half a step per update\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_REPEAT")) {
            rt_register_fnhook_abs(SWSH132_REPEAT_RESET, repeat_reset_hook);
            LOG("[swsh60] held-button repeat: 30 fps timing\n");
        }
        if (g_build == &k_builds[1] && !getenv("LARECOMP_SWSH60_NO_SCROLL")) {
            rt_register_fnhook_abs(SWSH132_SCROLLER, scroller_hook);
            LOG("[swsh60] list scrolling: half a step per update\n");
        }
        // (research only: these callers are 3D model animations; halving them did not change the menu - MENU60)
        if (g_build == &k_builds[1] && getenv("LARECOMP_SWSH60_UIANIM") && !getenv("LARECOMP_SWSH60_ANIMLOG")) {
            rt_register_fnhook_abs(SWSH132_UIANIM, uianim_hook);
            LOG("[swsh60] f_70006513d0 callers: half a frame per update (research)\n");
        }
        // (research, off by default: pacing these views did NOT slow the party icon hop - its counter is elsewhere)
        if (g_build == &k_builds[1] && getenv("LARECOMP_SWSH60_MENU") && !getenv("LARECOMP_SWSH60_VIEWLOG")) {
            rt_register_fnhook_abs(SWSH132_VIEW_UPDATE, menuview_hook);
            LOG("[swsh60] X menu views: 30 updates a second (research)\n");
        }
    }
    return asked == 2 ? 1 : asked;
}
