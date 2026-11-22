// Game file setup (runtime/gamesetup.h). The picked folder is searched a few levels deep (dump tools nest the files):
// exefs/ is the folder with main and main.npdm, the RomFS either a romfs.bin image or the folder with bin/message.
// exefs/ is copied into <data root>/extracted (hard links where the file system allows), the RomFS image is copied
// or built (runtime/romfs_build.c), then the game code is recompiled from exefs/ (runtime/gamebuild.c).
#include "gamesetup.h"

#include <SDL3/SDL.h>
#include <ctype.h>
#include <dirent.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "gamebuild.h"
#include "gamelib.h"
#include "hle.h"
#include "paths.h"
#include "platform.h"
#include "romfs_build.h"

#define ROOT "extracted"  // (in the data root, the working directory)
// The games (program ids, main.npdm's ACI0), any version. The 60 fps and wild battles options and the generator's
// instruction patches are addresses in Let's Go's main: only the builds with address tables get them (game_build);
// Sword and Shield are GAME_BUILD_OTHER, so those stay off for them.
#define TITLE_EEVEE 0x0100187003A36000ull
#define TITLE_PIKACHU 0x010003F003A34000ull
#define TITLE_SWORD 0x0100ABF008968000ull
#define TITLE_SHIELD 0x01008DB008C2C000ull
static const uint8_t EEVEE_100[8] = {0x0a, 0x3f, 0x0d, 0x21, 0xe6, 0x7d, 0xad, 0x80};    // Let's Go, Eevee! v1.0.0 main
static const uint8_t PIKACHU_100[8] = {0x1c, 0x37, 0x56, 0x92, 0xde, 0x4f, 0x4b, 0x87};  // Let's Go, Pikachu! v1.0.0

static _Atomic int g_state;
static _Atomic float g_progress;
static _Atomic bool g_running;
static char g_folder[MAX_PICK];

static bool image_ok(void);
static bool is_file(const char *p);
int setup_state(void) {  // (idle with a romfs.bin set up before that can't be read: say so, the setup is to be done again)
    if (g_state == SETUP_IDLE && !g_running && is_file(ROOT "/romfs.bin") && !image_ok()) return SETUP_FAIL_IMAGE;
    return g_state;
}
float setup_progress(void) { return g_progress; }
bool setup_running(void) { return g_running; }

static bool is_dir(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}
static bool is_file(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static uint64_t program_id(const char *exefs) {
    char p[1100];
    snprintf(p, sizeof p, "%s/main.npdm", exefs);
    FILE *f = fopen(p, "rb");
    if (!f) return 0;
    uint64_t id = 0;
    uint8_t meta[0x80], aci[0x18];  // ACI0 (offset at META+0x70): the program id at +0x10
    if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4) &&
        !fseek(f, *(uint32_t *)(meta + 0x70), SEEK_SET) && fread(aci, 1, sizeof aci, f) == sizeof aci &&
        !memcmp(aci, "ACI0", 4))
        id = *(uint64_t *)(aci + 0x10);
    fclose(f);
    return id;
}

static bool game_ok(const char *exefs) {
    uint64_t id = program_id(exefs);
    return id == TITLE_EEVEE || id == TITLE_PIKACHU || id == TITLE_SWORD || id == TITLE_SHIELD;
}

int game_build(const char *exefs) {
    char p[1100];
    snprintf(p, sizeof p, "%s/main", exefs);
    FILE *f = fopen(p, "rb");
    if (!f) return GAME_BUILD_OTHER;
    uint8_t id[8] = {0};
    fseek(f, 0x40, SEEK_SET);  // (NSO header: the module id)
    size_t n = fread(id, 1, 8, f);
    fclose(f);
    uint64_t pid = program_id(exefs);
    if (n == 8 && !memcmp(id, EEVEE_100, 8) && pid == TITLE_EEVEE) return GAME_BUILD_EEVEE_100;
    if (n == 8 && !memcmp(id, PIKACHU_100, 8) && pid == TITLE_PIKACHU) return GAME_BUILD_PIKACHU_100;
    return GAME_BUILD_OTHER;
}

const char *game_version(const char *exefs) {
    static const struct { uint8_t id[8]; const char *v; } k[] = {
        {{0x0a, 0x3f, 0x0d, 0x21, 0xe6, 0x7d, 0xad, 0x80}, "1.0.0"},  // Eevee
        {{0x1c, 0x37, 0x56, 0x92, 0xde, 0x4f, 0x4b, 0x87}, "1.0.0"},  // Pikachu
        {{0xc2, 0x08, 0xdb, 0x6a, 0x4e, 0xf4, 0x36, 0x1f}, "1.0.2"},  // Pikachu (issue #1's log)
        {{0x8d, 0xaf, 0xed, 0xbb, 0x5b, 0xe8, 0x1c, 0x2c}, "1.0.0"},  // Sword (docs/DIAGNOSTICO-SWSH.md)
    };
    char p[1100];
    snprintf(p, sizeof p, "%s/main", exefs);
    uint8_t id[8] = {0};
    FILE *f = fopen(p, "rb");
    if (f) {
        fseek(f, 0x40, SEEK_SET);
        if (fread(id, 1, 8, f) != 8) memset(id, 0, 8);
        fclose(f);
    }
    for (size_t i = 0; i < sizeof k / sizeof *k; i++)
        if (!memcmp(id, k[i].id, 8)) return k[i].v;
    return "1.0.0";  // (a build not listed here)
}

const char *game_name(const char *exefs) {
    uint64_t id = program_id(exefs);
    return id == TITLE_EEVEE ? "Eevee" : id == TITLE_PIKACHU ? "Pikachu" : id == TITLE_SWORD ? "Sword"
         : id == TITLE_SHIELD ? "Shield" : NULL;
}

const char *game_title(const char *exefs) {
    uint64_t id = program_id(exefs);
    return id == TITLE_EEVEE ? "Pokémon: Let's Go, Eevee!" : id == TITLE_PIKACHU ? "Pokémon: Let's Go, Pikachu!"
         : id == TITLE_SWORD ? "Pokémon Sword" : id == TITLE_SHIELD ? "Pokémon Shield" : NULL;
}

const char *game_title_id(const char *exefs) {
    uint64_t id = program_id(exefs);
    return id == TITLE_EEVEE ? "0100187003A36000" : id == TITLE_PIKACHU ? "010003F003A34000"
         : id == TITLE_SWORD ? "0100ABF008968000" : id == TITLE_SHIELD ? "01008DB008C2C000" : NULL;
}

const char *game_pair_title_id(const char *exefs) {
    uint64_t id = program_id(exefs);
    return id == TITLE_EEVEE ? "010003F003A34000" : id == TITLE_PIKACHU ? "0100187003A36000"
         : id == TITLE_SWORD ? "01008DB008C2C000" : id == TITLE_SHIELD ? "0100ABF008968000" : NULL;
}

// (a romfs.bin that isn't a whole, readable RomFS: set up again; romfs_build.c romfs_image_ok). It reads the file
// table, so it runs once per image size and time, not on every frame of the start screen.
static bool image_ok(void) {
    static long long checked_size = -1, checked_time = -1;
    static bool ok;
    struct stat st;
    if (stat(ROOT "/romfs.bin", &st) != 0) return false;
    if ((long long)st.st_size != checked_size || (long long)st.st_mtime != checked_time) {
        char why[128];
        ok = romfs_image_ok(ROOT "/romfs.bin", why, sizeof why);
        if (!ok) LOG("[setup] the game data image: %s\n", why);
        checked_size = (long long)st.st_size, checked_time = (long long)st.st_mtime;
    }
    return ok;
}

// (not while a setup runs: its romfs.bin is still being written - checking it each frame read and logged a half image)
bool setup_ready(void) {
    return !g_running && game_ok(ROOT "/exefs") && image_ok() && gamelib_present(ROOT);
}

bool setup_needs_build(void) {
    return !g_running && game_ok(ROOT "/exefs") && image_ok() && !gamelib_present(ROOT);
}

#define MAX_PKGS 16
typedef struct {
    char exefs[1024], romfs[1024], romfs_bin[1024];
    bool package;                  // .xci / .nsp / .nsz ... found
    char pkgs[MAX_PKGS][1024];     // the .xci / .nsp ones (unpacked with nstool: unpack_packages)
    int npkgs;
} Found;

static bool has_ext(const char *n, const char *ext) {  // (ignoring case)
    size_t a = strlen(n), b = strlen(ext);
    if (a < b) return false;
    for (size_t i = 0; i < b; i++)
        if (tolower((unsigned char)n[a - b + i]) != tolower((unsigned char)ext[i])) return false;
    return true;
}

static void find_game(const char *dir, int depth, Found *f) {
    if (depth > 5 || (f->exefs[0] && (f->romfs[0] || f->romfs_bin[0]))) return;
    char p[1100];
    snprintf(p, sizeof p, "%s/main.npdm", dir);
    if (!f->exefs[0] && is_file(p)) {
        snprintf(p, sizeof p, "%s/main", dir);
        if (is_file(p)) snprintf(f->exefs, sizeof f->exefs, "%s", dir);
    }
    snprintf(p, sizeof p, "%s/bin/message", dir);
    if (!f->romfs[0] && is_dir(p)) snprintf(f->romfs, sizeof f->romfs, "%s", dir);
    snprintf(p, sizeof p, "%s/romfs.bin", dir);
    if (!f->romfs_bin[0] && is_file(p)) snprintf(f->romfs_bin, sizeof f->romfs_bin, "%s", p);
    DIR *d = opendir(dir);
    if (!d) return;
    char sub[64][256];
    int nsub = 0;
    for (struct dirent *e; (e = readdir(d));) {
        const char *n = e->d_name;
        if (n[0] == '.') continue;
        snprintf(p, sizeof p, "%s/%s", dir, n);
        if (has_ext(n, ".xci") || has_ext(n, ".nsp") || has_ext(n, ".nca") || has_ext(n, ".nsz") || has_ext(n, ".xcz"))
            f->package = true;
        if ((has_ext(n, ".xci") || has_ext(n, ".nsp")) && f->npkgs < MAX_PKGS && is_file(p))
            snprintf(f->pkgs[f->npkgs++], sizeof f->pkgs[0], "%s", p);
        if (nsub < 64 && strcmp(n, "bin") && is_dir(p)) snprintf(sub[nsub++], sizeof sub[0], "%s", n);
    }
    closedir(d);
    for (int i = 0; i < nsub; i++) {
        snprintf(p, sizeof p, "%s/%s", dir, sub[i]);
        find_game(p, depth + 1, f);
    }
}

// progress: copying + the image are the first 15%, the game code the rest
static float g_phase0, g_phase1;
static void copy_progress(uint64_t done, uint64_t total) {
    if (total) g_progress = g_phase0 + (g_phase1 - g_phase0) * (float)((double)done / (double)total);
}
static void build_progress(double f, const char *step) {
    g_progress = 0.15f + 0.85f * (float)f;
    g_state = !strncmp(step, "Reading", 7) ? SETUP_READING : !strncmp(step, "Finishing", 9) ? SETUP_FINISHING
                                                                                           : SETUP_COMPILING;
}

static bool build_code(void) {
    if (!gamebuild_available()) { g_state = SETUP_FAIL_TOOLS; return false; }
    int cores = SDL_GetNumLogicalCPUCores(), ram_gb = SDL_GetSystemRAM() / 1024;
    GameBuildOpts o = {build_progress, cores < ram_gb - 2 ? cores : ram_gb - 2 > 1 ? ram_gb - 2 : 1};
    char why[256] = "";
    g_state = SETUP_READING;
    if (!gamebuild_run(ROOT, &o, why, sizeof why)) {
        LOG("[setup] game code: %s\n", why);
        g_state = SETUP_FAIL_BUILD;
        return false;
    }
    return true;
}

// ------------------------------------------------------------------ packed game files (.xci / .nsp)
// Unpacked here with nstool (https://github.com/jakcron/nstool, MIT: shipped next to the exe, third_party/nstool in the
// source tree) and the console's keys (prod.keys: shipped the same way, LARECOMP_KEYS, or an emulator's). The game
// (an .xci, or the base game's .nsp), its update (.nsp, title id ...800) and DLC (.nsp, the Expansion Pass' ownership
// keyfiles: services/fs.c reads extracted/aoc/<id>/romfs) are told apart by their Meta NCA's program id. The base
// program NCA patched by the update's (--basenca) gives exefs/ and romfs/ in UNPACK/game, which the setup then takes as
// a picked extracted folder (exefs copied, the romfs.bin image built from romfs/); UNPACK is deleted after.
#define UNPACK "unpack-tmp"  // (in the data root)
static _Atomic PlatProc g_unpack_proc;
static void unpack_kill(void) {
    PlatProc p = g_unpack_proc;
    if (p) plat_proc_kill(p);
}

static bool find_nstool(char *out, size_t n) {
    return rt_resource("nstool" PLAT_EXE_SUFFIX, "third_party/nstool/nstool" PLAT_EXE_SUFFIX, out, n);
}
static bool find_keys(char *out, size_t n) {
    const char *e = getenv("LARECOMP_KEYS");
    if (e && is_file(e)) return (size_t)snprintf(out, n, "%s", e) < n;
    if (rt_resource("prod.keys", "third_party/nstool/prod.keys", out, n)) return true;
    const char *app = getenv("APPDATA"), *home = getenv("USERPROFILE");
    if (!home) home = getenv("HOME");
    static const char *const emus[] = {"eden", "yuzu", "suyu", "sudachi", "citron", "torzu"};
    char p[1100];
    for (size_t i = 0; app && i < sizeof emus / sizeof *emus; i++) {
        snprintf(p, sizeof p, "%s/%s/keys/prod.keys", app, emus[i]);
        if (is_file(p)) return (size_t)snprintf(out, n, "%s", p) < n;
    }
    if (app && (snprintf(p, sizeof p, "%s/Ryujinx/system/prod.keys", app), is_file(p))) return (size_t)snprintf(out, n, "%s", p) < n;
    for (size_t i = 0; home && i < sizeof emus / sizeof *emus; i++) {  // (Linux: ~/.local/share/<emu>/keys)
        snprintf(p, sizeof p, "%s/.local/share/%s/keys/prod.keys", home, emus[i]);
        if (is_file(p)) return (size_t)snprintf(out, n, "%s", p) < n;
    }
    if (home && (snprintf(p, sizeof p, "%s/.switch/prod.keys", home), is_file(p))) return (size_t)snprintf(out, n, "%s", p) < n;
    return false;
}

// nstool refuses a path with both '/' and '\\' in it: one kind per argument
static void norm_path(char *p) {
#ifdef _WIN32
    for (; *p; p++) if (*p == '/') *p = '\\';
#else
    (void)p;
#endif
}

static unsigned long long dir_size(const char *p) {
    struct stat st;
    if (stat(p, &st) != 0) return 0;
    if (!S_ISDIR(st.st_mode)) return (unsigned long long)st.st_size;
    unsigned long long n = 0;
    DIR *d = opendir(p);
    if (!d) return 0;
    for (struct dirent *e; (e = readdir(d));) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char c[2048];
        snprintf(c, sizeof c, "%s/%s", p, e->d_name);
        n += dir_size(c);
    }
    closedir(d);
    return n;
}

// nstool -k <keys> <args...>, its output in log. While it runs the progress goes from p0 to p1 as watch (a folder it
// writes) grows towards expect bytes. Its exit code (-1: didn't start).
static char g_nstool[1100], g_keys[1100];
static int nstool(const char *const *args, const char *log, const char *watch, unsigned long long expect, float p0, float p1) {
    const char *argv[24];
    char arg[20][1100];
    int n = 0;
    argv[n++] = g_nstool, argv[n++] = "-k", argv[n++] = g_keys;
    for (int i = 0; args[i] && n < 22; i++) {
        snprintf(arg[i], sizeof arg[i], "%s", args[i]);
        if (args[i][0] != '-' && args[i][0] != '/') norm_path(arg[i]);  // (not the options or the inner paths: "/secure")
        argv[n++] = arg[i];
    }
    argv[n] = NULL;
    PlatProc p = plat_spawn(argv, log, false);
    if (!p) return -1;
    g_unpack_proc = p;
    int r;
    while ((r = plat_proc_wait(p, false)) < 0) {
        SDL_Delay(250);
        if (watch && expect) {
            double f = (double)dir_size(watch) / (double)expect;
            g_progress = p0 + (p1 - p0) * (float)(f < 1 ? f : 1);
        }
    }
    g_unpack_proc = 0;
    g_progress = p1;
    return r;
}

static bool read_text(const char *path, char *buf, size_t n) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    size_t got = fread(buf, 1, n - 1, f);
    buf[got] = 0;
    fclose(f);
    return true;
}

typedef struct { char path[1100]; char type[24]; uint64_t id; unsigned long long size; } Nca;

// an NCA's content type ("Program", "Meta", "PublicData", ...) and program id, from nstool's header print
static bool nca_header(Nca *c, const char *tik) {
    const char *args[] = {c->path, NULL}, *targs[] = {"--tik", tik, c->path, NULL};
    if (nstool(tik ? targs : args, UNPACK "/header.log", NULL, 0, g_progress, g_progress) != 0) return false;
    static char txt[65536];
    if (!read_text(UNPACK "/header.log", txt, sizeof txt)) return false;
    const char *t = strstr(txt, "Content Type:"), *i = strstr(txt, "ProgID:");
    if (!t || !i) return false;
    sscanf(t + 13, " %23s", c->type);
    c->id = strtoull(i + 7, NULL, 16);
    return true;
}

// The files in one unpacked package folder: its NCAs (headers read) and ticket
typedef struct { Nca nca[64]; int n; char tik[1100]; uint64_t meta_id; bool has_meta; } Pkg;

static void scan_pkg(const char *dir, Pkg *k) {
    memset(k, 0, sizeof *k);
    DIR *d = opendir(dir);
    if (!d) return;
    for (struct dirent *e; (e = readdir(d));) {
        char p[1100];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        if (has_ext(e->d_name, ".tik") && !k->tik[0]) snprintf(k->tik, sizeof k->tik, "%s", p);
        else if (has_ext(e->d_name, ".nca") && k->n < 64) {
            snprintf(k->nca[k->n].path, sizeof k->nca[0].path, "%s", p);
            k->nca[k->n].size = dir_size(p);
            k->n++;
        }
    }
    closedir(d);
    for (int i = 0; i < k->n; i++) {
        Nca *c = &k->nca[i];
        if (!nca_header(c, k->tik[0] ? k->tik : NULL)) { LOG("[setup] %s: header not read\n", c->path); continue; }
        if (!strcmp(c->type, "Meta")) k->meta_id = c->id, k->has_meta = true;
    }
}

static Nca *pick(Pkg *k, const char *type) {  // (the biggest of that type)
    Nca *best = NULL;
    for (int i = 0; i < k->n; i++)
        if (!strcmp(k->nca[i].type, type) && (!best || k->nca[i].size > best->size)) best = &k->nca[i];
    return best;
}

// -> f->exefs / f->romfs in UNPACK/game, the DLC keyfiles in extracted/aoc. false: g_state says why.
static bool unpack_packages(Found *f) {
    if (!find_nstool(g_nstool, sizeof g_nstool)) { LOG("[setup] nstool missing\n"); g_state = SETUP_FAIL_UNPACK; return false; }
    if (!find_keys(g_keys, sizeof g_keys)) { LOG("[setup] no prod.keys\n"); g_state = SETUP_FAIL_KEYS; return false; }
    norm_path(g_nstool), norm_path(g_keys);
    static bool once;
    if (!once) once = true, atexit(unpack_kill);
    LOG("[setup] unpacking %d package(s) with %s, keys %s\n", f->npkgs, g_nstool, g_keys);
    g_state = SETUP_UNPACKING;
    plat_remove_tree(UNPACK);
    mkdir(UNPACK, 0755);
    unsigned long long total = 0;
    for (int i = 0; i < f->npkgs; i++) total += dir_size(f->pkgs[i]);
    // 1. each package's files (an .xci: its secure partition) into UNPACK/p<i>: 0..5%
    static Pkg k[MAX_PKGS];
    Nca *base = NULL, *upd = NULL;
    const char *base_tik = NULL, *upd_tik = NULL;
    unsigned long long done = 0;
    for (int i = 0; i < f->npkgs; i++) {
        char dir[64];
        snprintf(dir, sizeof dir, UNPACK "/p%d", i);
        unsigned long long sz = dir_size(f->pkgs[i]);
        float p0 = 0.05f * (float)((double)done / (double)(total ? total : 1)), p1 = 0.05f * (float)((double)(done + sz) / (double)(total ? total : 1));
        const char *xa[] = {"-x", "/secure", dir, f->pkgs[i], NULL}, *na[] = {"-x", "/", dir, f->pkgs[i], NULL};
        int r = nstool(has_ext(f->pkgs[i], ".xci") ? xa : na, "unpack.log", dir, sz, p0, p1);
        done += sz;
        if (r != 0) {
            LOG("[setup] %s: nstool %d (see unpack.log)\n", f->pkgs[i], r);
            g_state = SETUP_FAIL_UNPACK;
            return false;
        }
        scan_pkg(dir, &k[i]);
        uint64_t kind = k[i].meta_id & 0xfff;
        LOG("[setup] %s: %d NCAs, meta %016llx%s\n", f->pkgs[i], k[i].n, (unsigned long long)k[i].meta_id, k[i].tik[0] ? ", ticket" : "");
        if (!k[i].has_meta) continue;
        Nca *prog = pick(&k[i], "Program");
        if (kind == 0 && prog && (!base || prog->size > base->size)) base = prog, base_tik = k[i].tik[0] ? k[i].tik : NULL;
        else if (kind == 0x800 && prog) upd = prog, upd_tik = k[i].tik[0] ? k[i].tik : NULL;
    }
    if (!base) { g_state = upd ? SETUP_FAIL_NO_BASE : SETUP_FAIL_NOT_FOUND; return false; }
    LOG("[setup] base %s%s%s\n", base->path, upd ? ", update " : "", upd ? upd->path : "");
    // 2. exefs and romfs of the program (with the update: the base patched by it): 5..10%
    const char *src = upd ? upd->path : base->path, *tik = upd ? upd_tik : base_tik;
    mkdir(UNPACK "/game", 0755);
    const char *a[12];
    for (int part = 0; part < 2; part++) {
        const char *out = part ? UNPACK "/game/romfs" : UNPACK "/game/exefs", *in = part ? "/1" : "/0";
        int n = 0;
        if (tik) a[n++] = "--tik", a[n++] = tik;
        if (upd) a[n++] = "--basenca", a[n++] = base->path;
        a[n++] = "-x", a[n++] = in, a[n++] = out, a[n++] = src, a[n] = NULL;
        int r = nstool(a, "unpack.log", part ? out : NULL, base->size, part ? 0.05f : g_progress, part ? 0.10f : g_progress);
        if (r != 0) {
            LOG("[setup] %s of %s: nstool %d (see unpack.log)\n", in, src, r);
            g_state = SETUP_FAIL_UNPACK;
            return false;
        }
    }
    // 3. the DLC: each PublicData NCA's files to extracted/aoc/<id>/romfs (the packed aoc/<id>.bin made again from it)
    mkdir(ROOT, 0755);
    for (int i = 0; i < f->npkgs; i++) {
        uint64_t kind = k[i].meta_id & 0xfff;
        Nca *c = k[i].has_meta && kind != 0 && kind != 0x800 ? pick(&k[i], "PublicData") : NULL;
        if (!c) continue;
        char out[256], bin[256];
        snprintf(out, sizeof out, ROOT "/aoc/%016llx", (unsigned long long)c->id);
        snprintf(bin, sizeof bin, ROOT "/aoc/%016llx.bin", (unsigned long long)c->id);
        mkdir(ROOT "/aoc", 0755);
        plat_remove_tree(out);
        remove(bin);
        mkdir(out, 0755);  // (nstool makes only the last folder of a path)
        strncat(out, "/romfs", sizeof out - strlen(out) - 1);
        const char *da[] = {"--tik", k[i].tik, "-x", "/0", out, c->path, NULL}, *db[] = {"-x", "/0", out, c->path, NULL};
        int r = nstool(k[i].tik[0] ? da : db, "unpack.log", NULL, 0, g_progress, g_progress);
        LOG("[setup] DLC %016llx: %s\n", (unsigned long long)c->id, r == 0 ? "ok" : "failed");
    }
    // the NCAs aren't needed any more (room for the romfs.bin image)
    for (int i = 0; i < f->npkgs; i++) {
        char dir[64];
        snprintf(dir, sizeof dir, UNPACK "/p%d", i);
        plat_remove_tree(dir);
    }
    snprintf(f->exefs, sizeof f->exefs, UNPACK "/game/exefs");
    snprintf(f->romfs, sizeof f->romfs, UNPACK "/game/romfs");
    f->romfs_bin[0] = 0;
    return true;
}

static void *setup_thread(void *arg) {
    (void)arg;
    g_progress = 0;
    if (!g_folder[0]) {  // only the game code (files set up already, e.g. a new version of the app)
        LOG("[setup] the game files are set up, the game code is from another version: rebuilding it\n");
        if (build_code()) g_state = setup_ready() ? SETUP_DONE : SETUP_FAIL_BUILD;
        g_running = false;
        return NULL;
    }
    g_state = SETUP_LOOKING;
    static Found f;
    memset(&f, 0, sizeof f);
    if (strchr(g_folder, '\n') || (is_file(g_folder) && (has_ext(g_folder, ".xci") || has_ext(g_folder, ".nsp")))) {
        // picked package files (one per line)
        for (char *save = NULL, *p = strtok_r(g_folder, "\n", &save); p && f.npkgs < MAX_PKGS; p = strtok_r(NULL, "\n", &save))
            if (is_file(p)) snprintf(f.pkgs[f.npkgs++], sizeof f.pkgs[0], "%s", p);
        f.package = true;
    } else
        find_game(g_folder, 0, &f);
    LOG("[setup] %s: exefs %s, romfs %s, romfs.bin %s, %d package(s)\n", g_folder, f.exefs[0] ? f.exefs : "-",
        f.romfs[0] ? f.romfs : "-", f.romfs_bin[0] ? f.romfs_bin : "-", f.npkgs);
    bool unpacked = false;
    if ((!f.exefs[0] || (!f.romfs[0] && !f.romfs_bin[0])) && f.npkgs) {  // (no extracted files: the packages)
        f.exefs[0] = f.romfs[0] = f.romfs_bin[0] = 0;
        unpacked = unpack_packages(&f);
        if (!unpacked) { plat_remove_tree(UNPACK); g_running = false; return NULL; }
    }
    if (!f.exefs[0] || (!f.romfs[0] && !f.romfs_bin[0])) g_state = f.package ? SETUP_FAIL_PACKAGE : SETUP_FAIL_NOT_FOUND;
    else if (!game_ok(f.exefs)) g_state = SETUP_FAIL_VERSION;
    else {
        // (the picked folder can't be our own copy: setting up again deletes that first)
        char a[4096], b[4096];
        mkdir(ROOT, 0755);
        if (realpath(f.exefs, a) && realpath(ROOT, b) && !strncmp(a, b, strlen(b)))
            snprintf(f.exefs, sizeof f.exefs, "%s", ""), g_state = SETUP_FAIL_NOT_FOUND;
    }
    if (g_state >= SETUP_FAIL_NOT_FOUND) { if (unpacked) plat_remove_tree(UNPACK); g_running = false; return NULL; }

    rt_remove_game_files(ROOT);  // (an earlier or interrupted setup's)
    mkdir(ROOT, 0755);
    g_state = SETUP_COPYING;
    g_phase0 = unpacked ? 0.10f : 0, g_phase1 = unpacked ? 0.105f : 0.01f;
    bool ok = true;
    if (!strcmp(f.exefs, f.romfs)) {  // (a flat dump, main next to bin/: only the six code files, not the whole RomFS)
        static const char *const code[] = {"main", "main.npdm", "rtld", "sdk", "subsdk0", "subsdk1"};
        mkdir(ROOT "/exefs", 0755);
        for (size_t i = 0; ok && i < sizeof code / sizeof *code; i++) {
            char src[1100], dst[1100];
            snprintf(src, sizeof src, "%s/%s", f.exefs, code[i]);
            snprintf(dst, sizeof dst, ROOT "/exefs/%s", code[i]);
            ok = is_file(src) && romfs_copy_file(src, dst, copy_progress);
        }
    } else
        ok = romfs_copy_tree(f.exefs, ROOT "/exefs", copy_progress);
    if (ok && f.romfs_bin[0]) {
        g_phase0 = 0.01f, g_phase1 = 0.15f;
        ok = romfs_copy_file(f.romfs_bin, ROOT "/romfs.bin", copy_progress);
    } else if (ok) {
        g_state = SETUP_IMAGE;
        g_phase0 = unpacked ? 0.105f : 0.01f, g_phase1 = 0.15f;
        char why[256] = "";
        ok = romfs_build(f.romfs, ROOT "/romfs.bin", copy_progress, why, sizeof why);
        if (!ok) LOG("[setup] romfs image: %s\n", why);
    }
    if (unpacked) plat_remove_tree(UNPACK);  // (exefs copied, the image built: the unpacked files not needed)
    char why[128];
    if (!ok) g_state = SETUP_FAIL_COPY;
    else if (!romfs_image_ok(ROOT "/romfs.bin", why, sizeof why)) {
        LOG("[setup] the game data image %s: %s\n", f.romfs_bin[0] ? f.romfs_bin : "(built)", why);
        g_state = SETUP_FAIL_IMAGE;
    } else if (getenv("LARECOMP_SETUP_NO_BUILD")) g_state = SETUP_DONE;  // (tests: the files only, no game code)
    else if (build_code()) g_state = setup_ready() ? SETUP_DONE : SETUP_FAIL_BUILD;
    LOG("[setup] %s\n", g_state == SETUP_DONE ? "ready" : "failed");
    g_running = false;
    return NULL;
}

void setup_start(const char *folder) {
    if (g_running) return;
    snprintf(g_folder, sizeof g_folder, "%s", folder ? folder : "");
    for (char *c = g_folder; *c; c++) if (*c == '\\') *c = '/';
    g_running = true;
    g_state = SETUP_LOOKING;
    pthread_t t;
    pthread_create(&t, NULL, setup_thread, NULL);
    pthread_detach(t);
}
