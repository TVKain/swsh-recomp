// Intel XeSS super resolution as the anti-aliasing "XeSS" (runtime/nvn/vulkan/xess.c), at TAA's place on Sword's HDR
// scene before its bloom (exec.c taa_run): the same inputs DLAA gets (dlss.h DlssInput: the scene's colour, its depth as
// R32F, the camera motion vectors, the jitter), run at 1x (XeSS's "AA" quality: native anti-aliasing).
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#include "dlss.h"

#ifdef __cplusplus
extern "C" {
#endif

// Before the instance: the extensions XeSS asks for and the lowest Vulkan version it wants (when libxess.dll is next
// to the executable; else nothing)
void xess_instance_exts(const char **ext, uint32_t *n, uint32_t max, uint32_t *min_api);
// Before the device: its extensions, and its feature structs patched into the device's chain (`chain` = the
// VkDeviceCreateInfo's pNext head; the head to use is returned)
void *xess_device_setup(const VkExtensionProperties *have, uint32_t nhave, const char **ext, uint32_t *n, uint32_t max, void *chain);
void xess_init(void);       // after the device is made: the context
bool xess_available(void);  // the context is up (and no failure so far)
// records XeSS into cb (outside any rendering); false: not done (TAA takes over)
bool xess_dispatch(VkCommandBuffer cb, const DlssInput *d);
// XeSS upscaling (settings: aa = xess, xess_quality not native) and the library up: its output / input ratio (1: off)
float xess_upscale_ratio(void);
float xess_mip_bias(void);  // log2(1 / ratio): the scene's textures as sharp as at the output's size (0: off)

#ifdef __cplusplus
}
#endif
