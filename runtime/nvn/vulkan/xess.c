// Intel XeSS (anti-aliasing "XeSS" on the Display / Graphics page): XeSS-SR at 1x ("AA" quality) in place of TAA, on
// Sword's HDR scene before its bloom (exec.c taa_run) - the inputs DLAA gets (dlss.c). libxess.dll (Intel's XeSS SDK,
// github.com/intel/xess, redistributable under the Intel Simplified Software License: third_party/xess/LICENSE.txt) is
// loaded at run time from the executable's folder; without it nothing of this runs and the entry is not offered.
// Only the SDK's headers are compiled in (third_party/xess/inc), the functions are fetched by name.
//
// What Savage Wind Recomp's XeSS port (github.com/Revivedx/SavageWindRecomp 22d36c9c, docs/XESS.md) taught:
//  - the instance's and the device's extensions and the device's feature chain must come from XeSS before they are
//    made (xessVKGetRequired*), so the library is looked for at start;
//  - xessVKInit wants the device idle and is slow: it runs once per size, never per frame (a per-frame wait cost them
//    most of XeSS's gain: 66-73 fps against 116-123);
//  - the inputs must be in SHADER_READ_ONLY_OPTIMAL, the output in GENERAL; the game's images live in GENERAL, so they
//    are transitioned around the library's commands and back;
//  - the velocity scale turns the game's vectors into XeSS's pixels (this frame to the previous one);
//  - TAA / SMAA stand down while it runs (it anti-aliases itself).
// XeSS frame generation and low latency are D3D12-only in Intel's SDK: nothing of them can run over Vulkan.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif
#include <SDL3/SDL_timer.h>

#include "vk.h"
#include "xess.h"
#include "../../rt.h"
#include "../../paths.h"
#include "../../settings.h"

#define XESS_TYPES_ONLY
#include "../../../third_party/xess/inc/xess/xess_vk.h"

typedef xess_result_t (*PFN_GetVersion)(xess_version_t *);
typedef xess_result_t (*PFN_InstExt)(uint32_t *, const char *const **, uint32_t *);
typedef xess_result_t (*PFN_DevExt)(VkInstance, VkPhysicalDevice, uint32_t *, const char *const **);
typedef xess_result_t (*PFN_DevFeat)(VkInstance, VkPhysicalDevice, void **);
typedef xess_result_t (*PFN_Create)(VkInstance, VkPhysicalDevice, VkDevice, xess_context_handle_t *);
typedef xess_result_t (*PFN_Init)(xess_context_handle_t, const xess_vk_init_params_t *);
typedef xess_result_t (*PFN_Execute)(xess_context_handle_t, VkCommandBuffer, const xess_vk_execute_params_t *);
typedef xess_result_t (*PFN_Destroy)(xess_context_handle_t);
typedef xess_result_t (*PFN_SetLog)(xess_context_handle_t, xess_logging_level_t, xess_app_log_callback_t);
typedef xess_result_t (*PFN_SetVel)(xess_context_handle_t, float, float);
typedef xess_result_t (*PFN_SetMaxMask)(xess_context_handle_t, float);

static struct {
    void *lib;
    int tried;
    PFN_GetVersion version;
    PFN_InstExt inst_ext;
    PFN_DevExt dev_ext;
    PFN_DevFeat dev_feat;
    PFN_Create create;
    PFN_Init init;
    PFN_Execute execute;
    PFN_Destroy destroy;
    PFN_SetLog set_log;
    PFN_SetVel set_vel;
    PFN_SetMaxMask set_max_mask;
    xess_context_handle_t ctx;
    bool dev_ok;   // the device was made with what XeSS asked for
    bool failed;   // a failure this run: TAA from then on
    uint32_t w, h; // the output size xessVKInit last ran for (0: none)
    int q;         // and its mode (XESS_Q_*) and input kind
    bool ldr;
    bool mask;     // made with a responsive mask
} X;

static const char *result_name(xess_result_t r) {
    switch (r) {
    case XESS_RESULT_SUCCESS: return "success";
    case XESS_RESULT_WARNING_OLD_DRIVER: return "old driver";
    case XESS_RESULT_ERROR_UNSUPPORTED_DEVICE: return "unsupported device";
    case XESS_RESULT_ERROR_UNSUPPORTED_DRIVER: return "unsupported driver";
    case XESS_RESULT_ERROR_UNINITIALIZED: return "uninitialized";
    case XESS_RESULT_ERROR_INVALID_ARGUMENT: return "invalid argument";
    case XESS_RESULT_ERROR_DEVICE_OUT_OF_MEMORY: return "out of GPU memory";
    case XESS_RESULT_ERROR_DEVICE: return "device error";
    case XESS_RESULT_ERROR_UNSUPPORTED: return "unsupported";
    case XESS_RESULT_ERROR_CANT_LOAD_LIBRARY: return "can't load library";
    default: return "error";
    }
}

static void log_cb(const char *msg, xess_logging_level_t level) {
    static int n;
    if (msg && n++ < 200) LOG("[xess] %s: %s\n", level >= XESS_LOGGING_LEVEL_ERROR ? "error" : "warning", msg);
}

static bool lib_load(void) {
    if (X.tried) return X.lib != NULL;
    X.tried = 1;
#ifdef _WIN32
    if (getenv("LARECOMP_XESS") && atoi(getenv("LARECOMP_XESS")) == 0) return false;  // (off for a test)
    wchar_t path[MAX_PATH + 16];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return false;
    wchar_t *slash = wcsrchr(path, L'\\');
    if (!slash) return false;
    wcscpy(slash + 1, L"libxess.dll");  // (its full path only: not from the DLL search path)
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) return false;
    uint64_t t0 = SDL_GetTicksNS();
    HMODULE m = LoadLibraryW(path);
    if (!m) { LOG("[xess] libxess.dll did not load (%lu): XeSS off\n", (unsigned long)GetLastError()); return false; }
#define FN(f, name) X.f = (void *)GetProcAddress(m, name)
    FN(version, "xessGetVersion");
    FN(inst_ext, "xessVKGetRequiredInstanceExtensions");
    FN(dev_ext, "xessVKGetRequiredDeviceExtensions");
    FN(dev_feat, "xessVKGetRequiredDeviceFeatures");
    FN(create, "xessVKCreateContext");
    FN(init, "xessVKInit");
    FN(execute, "xessVKExecute");
    FN(destroy, "xessDestroyContext");
    FN(set_log, "xessSetLoggingCallback");
    FN(set_vel, "xessSetVelocityScale");
    FN(set_max_mask, "xessSetMaxResponsiveMaskValue");
#undef FN
    if (!X.version || !X.inst_ext || !X.dev_ext || !X.dev_feat || !X.create || !X.init || !X.execute || !X.set_vel) {
        LOG("[xess] libxess.dll lacks the Vulkan entry points: XeSS off\n");
        FreeLibrary(m);
        return false;
    }
    X.lib = m;
    xess_version_t v = {0};
    X.version(&v);
    LOG("[xess] libxess.dll %u.%u.%u loaded (%.0f ms)\n", v.major, v.minor, v.patch, (SDL_GetTicksNS() - t0) / 1e6);
    return true;
#else
    return false;
#endif
}

static bool listed(const char *const *list, uint32_t n, const char *s) {
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(list[i], s)) return true;
    return false;
}

void xess_instance_exts(const char **ext, uint32_t *n, uint32_t max, uint32_t *min_api) {
    uint32_t ni = 0, api = 0;
    const char *const *ie = NULL;
    if (!lib_load() || X.inst_ext(&ni, &ie, &api) != XESS_RESULT_SUCCESS) return;
    for (uint32_t i = 0; i < ni; i++)
        if (!listed(ext, *n, ie[i]) && *n < max) ext[(*n)++] = ie[i];
    if (min_api && api > *min_api) *min_api = api;
}

void *xess_device_setup(const VkExtensionProperties *have, uint32_t nhave, const char **ext, uint32_t *n, uint32_t max, void *chain) {
    if (!X.lib) return chain;
    uint32_t nd = 0;
    const char *const *de = NULL;
    if (X.dev_ext(g_vk.inst, g_vk.phys, &nd, &de) != XESS_RESULT_SUCCESS) { LOG("[xess] no device extension list: XeSS off\n"); return chain; }
    for (uint32_t i = 0; i < nd; i++) {
        bool ok = false;
        for (uint32_t k = 0; k < nhave && !ok; k++) ok = !strcmp(have[k].extensionName, de[i]);
        if (!ok) { LOG("[xess] the device lacks %s: XeSS off\n", de[i]); return chain; }
    }
    for (uint32_t i = 0; i < nd; i++) LOG("[xess] needs device extension %s\n", de[i]);
    for (uint32_t i = 0; i < nd; i++)
        if (!listed(ext, *n, de[i]) && *n < max) ext[(*n)++] = de[i];
    void *head = chain;  // (XeSS patches its features into the chain the device is made with)
    if (X.dev_feat(g_vk.inst, g_vk.phys, &head) != XESS_RESULT_SUCCESS) { LOG("[xess] no device features: XeSS off\n"); return chain; }
    X.dev_ok = true;
    return head;
}

void xess_init(void) {
    if (!X.lib || !X.dev_ok) return;
    xess_result_t r = X.create(g_vk.inst, g_vk.phys, g_vk.dev, &X.ctx);
    if (r == XESS_RESULT_WARNING_OLD_DRIVER) LOG("[xess] the driver is older than XeSS wants (it still runs)\n");
    else if (r != XESS_RESULT_SUCCESS) {
        LOG("[xess] context: %s (%d): XeSS off\n", result_name(r), (int)r);
        X.ctx = NULL;
        return;
    }
    // (research) LARECOMP_XESS_DEBUGLOG=1: XeSS's own debug messages too
    if (X.set_log) X.set_log(X.ctx, getenv("LARECOMP_XESS_DEBUGLOG") ? XESS_LOGGING_LEVEL_DEBUG : XESS_LOGGING_LEVEL_WARNING, log_cb);
    // which network runs: the Intel XeFX library (XMX matrix engines, Intel's bigger model) or none (DP4a fallback)
    typedef xess_result_t (*PFN_XeFX)(xess_context_handle_t, xess_version_t *);
#ifdef _WIN32
    PFN_XeFX xefx = (PFN_XeFX)(void *)GetProcAddress((HMODULE)X.lib, "xessGetIntelXeFXVersion");
#else
    PFN_XeFX xefx = NULL;
#endif
    xess_version_t fx = {0};
    if (xefx) xefx(X.ctx, &fx);
    LOG("[xess] context made: XeSS available; Intel XeFX %u.%u.%u; driver XeSS hook vkCmdPushXeSSDescriptorsINTEL %s\n",
        fx.major, fx.minor, fx.patch, vkGetDeviceProcAddr(g_vk.dev, "vkCmdPushXeSSDescriptorsINTEL") ? "present" : "absent");
}

bool xess_available(void) { return X.ctx && !X.failed; }

// Intel's ratios since XeSS 1.3 (output / input on each side), by XESS_Q_*
static const float ratios[XESS_Q_COUNT] = {1.0f, 1.3f, 1.5f, 1.7f, 2.0f, 2.3f, 1.0f};
static const xess_quality_settings_t presets[XESS_Q_COUNT] = {
    XESS_QUALITY_SETTING_AA, XESS_QUALITY_SETTING_ULTRA_QUALITY_PLUS, XESS_QUALITY_SETTING_ULTRA_QUALITY,
    XESS_QUALITY_SETTING_QUALITY, XESS_QUALITY_SETTING_BALANCED, XESS_QUALITY_SETTING_PERFORMANCE, XESS_QUALITY_SETTING_AA};
float xess_upscale_ratio(void) {
    int q = g_settings.xess_quality;
    if (g_settings.antialias != AA_XESS || q <= 0 || q >= XESS_Q_COUNT || !xess_available()) return 1.0f;
    return ratios[q];
}
extern bool dlss_available(void);
float xess_mip_bias(void) {
    float r = xess_upscale_ratio();
    // (Native: XeSS rebuilds the full image from the game's 80% scene - textures as sharp as for 1.25x)
    // (Native full size: the scene is drawn at the output's size, XeSS at 1x - no bias)
    if (r <= 1.0f && g_settings.antialias == AA_XESS && xess_available() && !getenv("LARECOMP_XESS_MODE_A") &&
        g_settings.xess_quality != XESS_Q_FULL) r = 1.25f;
    // TAA (and DLAA) resolve over frames too: textures one step sharper than the scene's size asks, the accumulation
    // taking out the shimmer a lower mip level would have averaged away (Savage Wind Recomp: -1 at the scene's size;
    // AMD's guidance for temporal resolves). Sword's outdoor scene is drawn at 80% and stretched: -0.75 in all.
    if (r <= 1.0f && (g_settings.antialias == AA_TAA || (g_settings.antialias == AA_DLAA && dlss_available()))) return -0.75f;
    return r > 1.0f ? -log2f(r) : 0.0f;
}

// XeSS builds its pipelines in xessVKInit: about 4 s the first time on the Arc 140V. Through a pipeline cache of its
// own (<cache dir>/xess_pipelines.bin, saved after an init that added to it) that is paid once per driver.
static VkPipelineCache xcache;
static size_t xcache_size;
static void cache_path(char *out, size_t n) { snprintf(out, n, "%s/xess_pipelines.bin", rt_cache_dir()); }
static void cache_load(void) {
    char path[600];
    cache_path(path, sizeof path);
    void *data = NULL;
    size_t sz = 0;
    FILE *fp = fopen(path, "rb");
    if (fp) {
        fseek(fp, 0, SEEK_END);
        sz = (size_t)ftell(fp);
        fseek(fp, 0, SEEK_SET);
        data = malloc(sz);
        if (data && fread(data, 1, sz, fp) != sz) sz = 0;
        fclose(fp);
    }
    VkPipelineCacheCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO, .initialDataSize = data ? sz : 0, .pInitialData = data};
    if (vkCreatePipelineCache(g_vk.dev, &ci, NULL, &xcache) != VK_SUCCESS) {
        ci.initialDataSize = 0;
        if (vkCreatePipelineCache(g_vk.dev, &ci, NULL, &xcache) != VK_SUCCESS) xcache = VK_NULL_HANDLE;
    }
    xcache_size = data ? sz : 0;
    free(data);
}
static void cache_save(void) {
    size_t sz = 0;
    if (!xcache || vkGetPipelineCacheData(g_vk.dev, xcache, &sz, NULL) != VK_SUCCESS || sz <= xcache_size) return;
    void *data = malloc(sz);
    if (!data || vkGetPipelineCacheData(g_vk.dev, xcache, &sz, data) != VK_SUCCESS) { free(data); return; }
    char path[600], tmp[620];
    cache_path(path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *fp = fopen(tmp, "wb");
    if (fp) {
        bool ok = fwrite(data, 1, sz, fp) == sz;
        fclose(fp);
        if (ok) { remove(path); rename(tmp, path); xcache_size = sz; }
    }
    free(data);
}

static void fail(const char *what, xess_result_t r) {
    LOG("[xess] %s: %s (%d): XeSS off for this run (TAA instead)\n", what, result_name(r), (int)r);
    X.failed = true;
}

// image views for the library, kept for a few frames (destroyed when their slot comes round again: by then the GPU
// is done with them)
static VkImageView views[4][4];
static int view_slot;
static VkImageView make_view(VkImage img, VkFormat f) {
    VkImageViewCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
                                .format = f, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkImageView v = VK_NULL_HANDLE;
    vkCreateImageView(g_vk.dev, &ci, NULL, &v);
    return v;
}
static xess_vk_image_view_info info(VkImageView v, VkImage img, VkFormat f, uint32_t w, uint32_t h) {
    xess_vk_image_view_info i = {v, img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}, f, w, h};
    return i;
}
static void layouts(VkCommandBuffer cb, const VkImage *imgs, int n, VkImageLayout from, VkImageLayout to) {
    VkImageMemoryBarrier2 b[4];
    for (int i = 0; i < n; i++)
        b[i] = (VkImageMemoryBarrier2){.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                                       .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                       .srcAccessMask = VK_ACCESS_2_MEMORY_WRITE_BIT | VK_ACCESS_2_MEMORY_READ_BIT,
                                       .dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                       .dstAccessMask = VK_ACCESS_2_MEMORY_READ_BIT | VK_ACCESS_2_MEMORY_WRITE_BIT,
                                       .oldLayout = from, .newLayout = to, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                       .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = imgs[i],
                                       .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    VkDependencyInfo di = {.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = (uint32_t)n, .pImageMemoryBarriers = b};
    vkCmdPipelineBarrier2(cb, &di);
}

bool xess_dispatch(VkCommandBuffer cb, const DlssInput *d) {
    if (!xess_available() || !d->color || !d->depth || !d->mv || !d->output) return false;
    bool reset = d->reset;
    int q = d->xq > 0 && d->xq < XESS_Q_COUNT ? d->xq : 0;
    bool mask = d->mask != VK_NULL_HANDLE;
    if (X.w != d->ow || X.h != d->oh || X.q != q || X.ldr != d->ldr || X.mask != mask) {
        // a new output size or mode: xessVKInit (the device idle first: the API asks for it)
        uint64_t t0 = SDL_GetTicksNS();
        if (X.w) vkDeviceWaitIdle(g_vk.dev);
        // native AA: HDR (the scene before the game's bloom and tone mapping), exposure measured by XeSS itself.
        // Upscaling: the tone-mapped image (LDR, no exposure). The vectors at the render size (XeSS dilates them with
        // the depth); the depth not inverted (near small).
        xess_vk_init_params_t ip = {.outputResolution = {d->ow, d->oh}, .qualitySetting = presets[q],
                                    .initFlags = (d->ldr ? XESS_INIT_FLAG_LDR_INPUT_COLOR : XESS_INIT_FLAG_ENABLE_AUTOEXPOSURE) |
                                                 (mask ? XESS_INIT_FLAG_RESPONSIVE_PIXEL_MASK : 0)};
        if (!xcache) cache_load();
        ip.pipelineCache = xcache;
        xess_result_t r = X.init(X.ctx, &ip);
        if (r != XESS_RESULT_SUCCESS) { fail("init", r); return false; }
        X.w = d->ow, X.h = d->oh, X.q = q, X.ldr = d->ldr, X.mask = mask;
        if (mask && X.set_max_mask) X.set_max_mask(X.ctx, 1.0f);  // (the mask's own values carry the strength)
        cache_save();
        // the game's vectors (exec.c taa_mv.frag) are current - previous in UV: XeSS wants previous - current in pixels
        X.set_vel(X.ctx, d->mv_scale_x, d->mv_scale_y);
        reset = true;
        static const char *const names[XESS_Q_COUNT] = {"native AA", "ultra quality plus", "ultra quality", "quality", "balanced", "performance", "native AA"};
        LOG("[xess] initialized for %ux%u output (%s, %s) in %.0f ms; input now %ux%u\n", d->ow, d->oh, names[q],
            d->ldr ? "tone-mapped input" : "HDR, auto exposure", (SDL_GetTicksNS() - t0) / 1e6, d->rw, d->rh);
    }
    view_slot = (view_slot + 1) & 3;
    for (int i = 0; i < 4; i++)
        if (views[view_slot][i]) vkDestroyImageView(g_vk.dev, views[view_slot][i], NULL), views[view_slot][i] = VK_NULL_HANDLE;
    VkImageView *v = views[view_slot];
    static VkImageView mviews[4];
    if (mviews[view_slot]) vkDestroyImageView(g_vk.dev, mviews[view_slot], NULL), mviews[view_slot] = VK_NULL_HANDLE;
    if (mask) mviews[view_slot] = make_view(d->mask, VK_FORMAT_R8_UNORM);
    v[0] = make_view(d->color, d->color_fmt);
    v[1] = make_view(d->depth, VK_FORMAT_R32_SFLOAT);
    v[2] = make_view(d->mv, VK_FORMAT_R16G16B16A16_SFLOAT);
    v[3] = make_view(d->output, VK_FORMAT_R16G16B16A16_SFLOAT);
    if (!v[0] || !v[1] || !v[2] || !v[3]) return false;
    uint32_t iw = d->iw ? d->iw : d->rw, ih = d->ih ? d->ih : d->rh;
    // XeSS's jitter is the content's sub-pixel move (right, down): what the scene's viewport was moved by.
    // LARECOMP_XESS_JITTER_SX / _SY: other signs (a test)
    static float sx, sy;
    if (!sx) {
        sx = getenv("LARECOMP_XESS_JITTER_SX") ? (float)atof(getenv("LARECOMP_XESS_JITTER_SX")) : 1.0f;
        sy = getenv("LARECOMP_XESS_JITTER_SY") ? (float)atof(getenv("LARECOMP_XESS_JITTER_SY")) : 1.0f;
    }
    xess_vk_execute_params_t ep;
    memset(&ep, 0, sizeof ep);
    ep.colorTexture = info(v[0], d->color, d->color_fmt, iw, ih);
    ep.depthTexture = info(v[1], d->depth, VK_FORMAT_R32_SFLOAT, iw, ih);
    ep.velocityTexture = info(v[2], d->mv, VK_FORMAT_R16G16B16A16_SFLOAT, iw, ih);
    ep.outputTexture = info(v[3], d->output, VK_FORMAT_R16G16B16A16_SFLOAT, d->ow, d->oh);
    if (mask) ep.responsivePixelMaskTexture = info(mviews[view_slot], d->mask, VK_FORMAT_R8_UNORM, iw, ih);
    ep.jitterOffsetX = d->jx * sx;
    ep.jitterOffsetY = d->jy * sy;
    ep.exposureScale = 1.0f;
    ep.resetHistory = reset;
    ep.inputWidth = d->rw;  // (the scene: the images' top-left rw x rh)
    ep.inputHeight = d->rh;
    vk_full_barrier(cb);
    VkImage ins[4] = {d->color, d->depth, d->mv, d->mask};
    int nin = mask ? 4 : 3;
    layouts(cb, ins, nin, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    xess_result_t r = X.execute(X.ctx, cb, &ep);
    layouts(cb, ins, nin, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL);
    if (r != XESS_RESULT_SUCCESS) { fail("execute", r); return false; }
    vk_full_barrier(cb);
    return true;
}
