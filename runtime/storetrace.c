// Store tracing (research): LARECOMP_TRACE_STORES="<first>-<last>" with a game library built by `gen.py --trace-stores`
// (make TRACE=1, docs/DEPURACAO.md). Every store the game makes reports (instruction address, address, old, new value)
// here; during those presents each instruction is tallied: in how many presents it stored, how often by +1 / -1, how
// often by the same step as its previous store. At the last present the instructions that store in nearly every
// present with a steady step are listed: those are the game's frame counters and per-frame steps.
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hle.h"

uint64_t renderer_present_count(void);
uint64_t renderer_game_frame(void);

typedef struct {
    uint64_t pc;
    uint64_t frames, last_frame;  // presents it stored in
    uint64_t hits, inc1, dec1, same;
    int64_t last_delta;
    float fdelta; uint64_t fsame;  // (size 4 as float: the same non-zero float step as the previous store)
    uint64_t addr, old, nw;
    int size;
} Site;

#define SITES (1u << 16)
static Site g_sites[SITES];
static atomic_flag g_lock = ATOMIC_FLAG_INIT;
static long g_from = -2, g_to;
static bool g_printed;

static char g_env[64];
static char g_undo_env[512];
__attribute__((constructor)) static void trace_env(void) {
    const char *e = getenv("LARECOMP_TRACE_STORES");
    if (e) snprintf(g_env, sizeof g_env, "%s", e);
    e = getenv("LARECOMP_TRACE_UNDO");
    if (e) snprintf(g_undo_env, sizeof g_undo_env, "%s", e);
}

static void init(void) {
    const char *e = g_env[0] ? g_env : NULL;
    g_from = -1;
    if (e && atol(e) > 0) {
        g_from = atol(e);
        g_to = strchr(e, '-') ? atol(strchr(e, '-') + 1) : g_from;
    }
}

static int cmp_site(const void *a, const void *b) {
    const Site *x = a, *y = b;
    return x->frames < y->frames ? 1 : x->frames > y->frames ? -1 : 0;
}

static void report(void) {
    static Site out[SITES];
    int n = 0;
    long window = g_to - g_from + 1;
    // LARECOMP_TRACE_MIN_PCT=<n>: report sites storing in >= n% of the presents (default 80); with a low n, only
    // sites that step by +1 or a steady step most of the time (a counter running for part of the window)
    int pct = getenv("LARECOMP_TRACE_MIN_PCT") ? atoi(getenv("LARECOMP_TRACE_MIN_PCT")) : 80;
    for (unsigned i = 0; i < SITES; i++) {
        const Site *s = &g_sites[i];
        if (!s->pc || s->frames * 100 < (uint64_t)window * (uint64_t)pct) continue;
        if (pct < 80 && !(s->inc1 * 2 >= s->hits || s->same * 2 >= s->hits)) continue;
        if (pct < 80 && s->hits > s->frames * 4) continue;
        out[n++] = *s;
    }
    qsort(out, (size_t)n, sizeof out[0], cmp_site);
    LOG("[trace] %d store sites in >= %d%% of the %ld presents\n", n, pct, window);
    for (int i = 0; i < n && i < 6000; i++) {
        const Site *s = &out[i];
        LOG("[trace] pc %llx presents %llu hits %llu +1 %llu -1 %llu same-step %llu fsame %llu fstep %g size %d addr %llx %llx -> %llx\n", (unsigned long long)s->pc,
            (unsigned long long)s->frames, (unsigned long long)s->hits, (unsigned long long)s->inc1, (unsigned long long)s->dec1,
            (unsigned long long)s->same, (unsigned long long)s->fsame, (double)s->fdelta, s->size, (unsigned long long)s->addr, (unsigned long long)s->old, (unsigned long long)s->nw);
    }
}

// Experiment (LARECOMP_TRACE_UNDO="<pc>[,<pc>...]", hex): the stores of those instructions are undone on odd presents,
// so a counter stepping once per update steps once per two presents: tests whether a counter is what a scene's speed
// comes from, without regenerating the game code.
static uint64_t g_undo[32];
static int g_nundo = -1;
static void undo_init(void) {
    g_nundo = 0;
    char buf[512];
    if (!g_undo_env[0]) return;
    snprintf(buf, sizeof buf, "%s", g_undo_env);
    for (char *t = strtok(buf, ","); t && g_nundo < 32; t = strtok(NULL, ",")) g_undo[g_nundo++] = strtoull(t, NULL, 16);
}

void rt_trace_store(uint64_t pc, uint64_t addr, uint64_t old, uint64_t nw, int size) {
    if (g_nundo < 0) undo_init();
    static long undo_from = -1;  // LARECOMP_TRACE_UNDO_FROM=<present>: undo only from there on (from boot it breaks init)
    if (undo_from < 0) undo_from = getenv("LARECOMP_TRACE_UNDO_FROM") ? atol(getenv("LARECOMP_TRACE_UNDO_FROM")) : 0;
    if (g_nundo && (renderer_present_count() & 1) && (long)renderer_present_count() >= undo_from)
        for (int i = 0; i < g_nundo; i++)
            if (g_undo[i] == pc) {
                static _Atomic long nund; long k = ++nund;
                if (k == 1 || k == 1000 || k == 100000) LOG("[trace] undo #%ld pc %llx at present %llu (game frame %llu)\n", k, (unsigned long long)pc,
                    (unsigned long long)renderer_present_count(), (unsigned long long)renderer_game_frame());
                if (size == 4) *(uint32_t *)(uintptr_t)addr = (uint32_t)old;
                else if (size == 1) *(uint8_t *)(uintptr_t)addr = (uint8_t)old;
                else if (size == 8) *(uint64_t *)(uintptr_t)addr = old;
                break;
            }
    if (g_from == -2) {
        init();
        const char *e = getenv("LARECOMP_TRACE_STORES");
        LOG("[trace] first store: env \"%s\" window %ld-%ld present %llu\n", e ? e : "(null)", g_from, g_to, (unsigned long long)renderer_present_count());
    }
    if (g_from < 0) return;
    long f = (long)renderer_present_count();
    if (f < g_from) return;
    if (f > g_to) {
        if (!g_printed) {
            g_printed = true;
            while (atomic_flag_test_and_set(&g_lock)) {}
            report();
            atomic_flag_clear(&g_lock);
        }
        return;
    }
    while (atomic_flag_test_and_set(&g_lock)) {}
    uint32_t i = (uint32_t)((pc >> 2) * 0x9E3779B1u) & (SITES - 1);
    while (g_sites[i].pc && g_sites[i].pc != pc) i = (i + 1) & (SITES - 1);
    Site *s = &g_sites[i];
    s->pc = pc;
    if (s->last_frame != (uint64_t)f + 1) s->frames++, s->last_frame = (uint64_t)f + 1;
    s->hits++;
    int64_t d = (int64_t)(nw - old);
    if (size == 4) d = (int32_t)(uint32_t)(nw - old);
    if (d == 1) s->inc1++;
    if (d == -1) s->dec1++;
    if (d == s->last_delta) s->same++;
    s->last_delta = d;
    if (size == 4) {
        float fo, fn; uint32_t uo = (uint32_t)old, un = (uint32_t)nw; memcpy(&fo, &uo, 4); memcpy(&fn, &un, 4);
        float fd = fn - fo;
        if (fd == fd && fd != 0.0f && fd > -1e6f && fd < 1e6f && fd == s->fdelta) s->fsame++;
        s->fdelta = fd;
    }
    s->addr = addr, s->old = old, s->nw = nw, s->size = size;
    atomic_flag_clear(&g_lock);
}
