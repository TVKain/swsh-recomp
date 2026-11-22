// Output resolution, shared by the Metal and Vulkan backends (each calls output_scale() once per presented frame).
// Render targets the game sizes for the Switch's 1920x1080 screen are allocated at (sx, sy) times their size; the
// image is then drawn into (vx, vy, vw, vh) of the window. Video tab "Internal resolution" (g_settings.res_mode):
//   Match display  render at the window's own pixel size (default)
//   1x .. 4x       N times the Switch's docked image: 1080 lines x N (wide windows keep their shape: 32:9 at 2x =
//                  7680 x 2160); capped to the GPU's 16384-pixel texture limit
//   .75x / .50x / .25x  of Match display (scaled up to the window - with MetalFX on macOS when chosen)
//   Dynamic        Match display, lowered in steps while the GPU can't hold 60 fps and raised again when it can
//                  (each change reallocates the render targets: a short hitch, so it changes rarely, with hysteresis)
// Test overrides: LARECOMP_SCALE=<f> (render height = 1080 x f), LARECOMP_WIDE_TEST=<f> (forced shape).
#include <math.h>
#include <stdlib.h>

#include "../hle.h"
#include "../settings.h"
#include "output_scale.h"

#define MAX_TEX 16384.0

// Dynamic resolution: a factor on the Match display scale, 0.5 .. 1 in 0.05 steps, then 1 .. 1.5 in 0.25 steps.
static double g_dyn = 1.0;
static double g_dyn_gpu_sum, g_dyn_dt_sum, g_last_t;
static int g_dyn_n, g_dyn_gpu_n, g_dyn_good;
static double g_dyn_cool_until, g_dyn_probe_wait = 5.0, g_dyn_probe_at;
static double g_dyn_last_raise = -100;
static double g_dyn_target_ms;

static void dyn_update(double now, double gpu_ms, double target_ms) {
    // Do not mix 30 Hz scene samples with 60 Hz world/menu samples.
    if (g_dyn_target_ms != target_ms) {
        g_dyn_target_ms = target_ms;
        g_last_t = now;
        g_dyn_dt_sum = g_dyn_gpu_sum = 0;
        g_dyn_n = g_dyn_gpu_n = g_dyn_good = 0;
        return;
    }
    double dt = g_last_t > 0 ? (now - g_last_t) * 1000.0 : target_ms;
    g_last_t = now;
    if (dt > 250) return;  // (loading, menus, a stall: not the GPU's steady state)
    g_dyn_dt_sum += dt;
    g_dyn_n++;
    if (gpu_ms >= 0) { g_dyn_gpu_sum += gpu_ms; g_dyn_gpu_n++; }
    if (g_dyn_n < 30) return;  // decide every ~half second
    double avg_dt = g_dyn_dt_sum / g_dyn_n, avg_gpu = g_dyn_gpu_n ? g_dyn_gpu_sum / g_dyn_gpu_n : -1;
    g_dyn_dt_sum = g_dyn_gpu_sum = 0;
    g_dyn_n = g_dyn_gpu_n = 0;
    if (now < g_dyn_cool_until) return;
    double prev = g_dyn;
    double load = avg_gpu >= 0 ? avg_gpu : avg_dt;  // (how far over: the GPU's time when known)
    // with a GPU timer only the GPU's time counts: a slow frame with an idle GPU is the CPU (loading, shader builds) and
    // a smaller image would not help it
    bool slow = avg_gpu >= 0 ? avg_gpu > target_ms * (14.5 / 16.666667) : avg_dt > target_ms * (17.4 / 16.666667);
    // Above 1: supersampling (render larger than the display, scaled down at the present: smooth edges and outlines,
    // which SMAA / TAA can't reach - Sword draws its outlines after them). Only with a GPU timer, in 0.25 steps, raised
    // when the next step's predicted GPU time (pixels grow with the square) stays well under the frame; any sign of
    // strain drops it first, before the scale goes below 1. LARECOMP_DYN_MAX=<f> (default 1.5; 1: never above).
    static double dyn_max = -1;
    if (dyn_max < 0) dyn_max = getenv("LARECOMP_DYN_MAX") ? fmax(1.0, fmin(2.0, atof(getenv("LARECOMP_DYN_MAX")))) : 1.5;
    // A step above 1 that failed: the GPU time (at the step below) it was raised from, and when. It is tried again only
    // once the scene is clearly lighter than that, or two minutes later (each try is a hitch: the targets reallocate).
    static double fail_gpu[8], fail_t[8], raised_from_gpu[8];
    if (slow && g_dyn > 1.0) {
        int k = (int)lround((g_dyn - 1.0) / 0.25);
        if (k > 0 && k < 8) { fail_gpu[k] = raised_from_gpu[k]; fail_t[k] = now; }
        g_dyn = load > target_ms * (17.0 / 16.666667) ? 1.0 : fmax(1.0, g_dyn - 0.25);
        g_dyn_good = 0;
        if (now - g_dyn_last_raise < 5.0) g_dyn_probe_wait = fmin(g_dyn_probe_wait * 2, 120.0);  // raised too eagerly
    } else if (slow) {
        g_dyn = fmax(0.5, g_dyn - (load > target_ms * (22.0 / 16.666667) ? 0.1 : 0.05));
        g_dyn_good = 0;
        if (now - g_dyn_last_raise < 3.0) g_dyn_probe_wait = fmin(g_dyn_probe_wait * 2, 60.0);  // raised too eagerly
    } else if (g_dyn >= 1.0) {
        if (avg_gpu >= 0 && g_dyn < dyn_max) {
            g_dyn_good++;
            double next = fmin(dyn_max, g_dyn + 0.25), predicted = avg_gpu * (next / g_dyn) * (next / g_dyn);
            int k = (int)lround((next - 1.0) / 0.25);
            bool failed_here = k > 0 && k < 8 && fail_t[k] > 0 && now - fail_t[k] < 120.0 && avg_gpu > 0.75 * fail_gpu[k];
            if (predicted < target_ms * (12.0 / 16.666667) && g_dyn_good >= 6 && now >= g_dyn_probe_at && !failed_here) {
                if (k > 0 && k < 8) raised_from_gpu[k] = avg_gpu;
                g_dyn = next; g_dyn_good = 0; g_dyn_last_raise = now; g_dyn_probe_at = now + g_dyn_probe_wait;
            }
        }
    } else if (g_dyn < 1.0) {
        g_dyn_good++;
        // with GPU timing: raise when there is clear headroom; without (Vulkan): probe upwards now and then
        bool room = avg_gpu >= 0 ? avg_gpu < target_ms * (10.5 / 16.666667) && g_dyn_good >= 4 :
                                   now >= g_dyn_probe_at && g_dyn_good >= 2 * (int)g_dyn_probe_wait;
        if (room) { g_dyn = fmin(1.0, g_dyn + 0.05); g_dyn_good = 0; g_dyn_last_raise = now; g_dyn_probe_at = now + g_dyn_probe_wait; }
    }
    g_dyn = round(g_dyn * 20) / 20;
    if (g_dyn != prev) {
        g_dyn_cool_until = now + 1.5;
        LOG("[dynres] %.2f -> %.2f (frame %.1f ms, gpu %.1f ms)\n", prev, g_dyn, avg_dt, avg_gpu);
    }
}

double output_scale_dynamic_factor(void) { return g_dyn; }

void output_scale(double dw, double dh, bool reshape_allowed, double now, double gpu_ms, OutScale *o) {
    double fit = fmin(dw / 1920.0, dh / 1080.0);
    static double forced = -1, wide_test = -1;
    if (forced < 0) forced = getenv("LARECOMP_SCALE") ? atof(getenv("LARECOMP_SCALE")) : 0;
    if (wide_test < 0) wide_test = getenv("LARECOMP_WIDE_TEST") ? atof(getenv("LARECOMP_WIDE_TEST")) : 0;
    double shape = wide_test > 0 ? wide_test : (dw / dh) / (16.0 / 9.0);
    bool reshape = reshape_allowed && fabs(shape - 1.0) > 0.005;
    if (!reshape) shape = 1.0;
    // render height in units of the Switch's 1080 lines
    double h;
    int mode = g_settings.res_mode;
    if (forced > 0) h = forced;
    else if (g_settings.res_height > 0) h = g_settings.res_height / 1080.0;  // (the launcher's choice)
    else if (mode >= 1 && mode <= 8) h = mode;
    else {
        h = reshape ? dh / 1080.0 : fit;  // Match display
        if (mode == RES_DYNAMIC) {
            extern bool fps60_enabled(void), fps60_world(void), fps60_menu(void), swsh60_enabled(void);
            // (Sword's 60 fps mode, hle/swsh60.c, presents every frame at 60; fps60_* is Let's Go's and never fires on
            // Sword - before 2026-11-21 Sword's dynamic resolution budgeted 33 ms a frame at 60 fps)
            bool at_60 = swsh60_enabled() || (fps60_enabled() && (fps60_world() || fps60_menu()));
            dyn_update(now, gpu_ms, at_60 ? 16.666667 : 33.333333);
            h *= g_dyn;
        }
        else if (mode == RES_Q75) h *= 0.75;
        else if (mode == RES_Q25) h *= 0.25;
        else if (mode == RES_Q50) h *= 0.5;
    }
    h = fmax(h, 0.1);  // (.25x of a small window)
    double sx = h * shape, sy = h;
    double cap = fmin(MAX_TEX / (1920.0 * sx), MAX_TEX / (1080.0 * sy));
    if (cap < 1.0) { sx *= cap; sy *= cap; }
    // Whole pixels: a target is allocated at round(size * s) but the game's draws are scaled by s itself; 1080 * 0.8875
    // = 958.5 -> a 959-row image whose top row no draw covered (it kept the boot quad's blue: a thin blue line at the
    // top whenever dynamic resolution sat at 0.95, player report 2026-11-22). With 1920 * sx and 1080 * sy whole, the
    // draws cover every row of the full-size targets. Off: LARECOMP_NO_SCALE_SNAP=1.
    if (!getenv("LARECOMP_NO_SCALE_SNAP")) {
        double qx = 1920.0 * sx, qy = 1080.0 * sy;
        qx = cap < 1.0 ? floor(qx) : round(qx), qy = cap < 1.0 ? floor(qy) : round(qy);
        if (qx >= 1 && qy >= 1) sx = qx / 1920.0, sy = qy / 1080.0;
    }
    o->sx = sx; o->sy = sy; o->shape = shape;
    // where the image goes in the window: fills it when reshaped, else a fitted 16:9 box
    if (reshape) { o->vw = dw; o->vh = dh; }
    else { o->vw = 1920.0 * fit; o->vh = 1080.0 * fit; }
    if (wide_test > 0) {
        double f2 = fmin(dw / (1920.0 * wide_test), dh / 1080.0);
        o->vw = 1920.0 * wide_test * f2; o->vh = 1080.0 * f2;
    }
    o->vx = (dw - o->vw) / 2; o->vy = (dh - o->vh) / 2;
}
