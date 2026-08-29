// A do-nothing Vulkan layer that exists solely to satisfy Lepton's UNCONDITIONAL fossilize lookup.
//
// WHY THIS FILE EXISTS. Valve's Lepton compat tool enables the fossilize shader-cache layer on
// every launch, with no guard and no opt-out:
//
//     liblepton/vulkan_layers.sh:171  if [[ "${ENABLE_VULKAN_RPO_LAYER:-0}" != "0" ]]; then …
//     liblepton/vulkan_layers.sh:175  if [[ "${ENABLE_VULKAN_FDM_INJECTION_LAYER:-0}" != "0" ]]; then …
//     liblepton/vulkan_layers.sh:181  enable_vulkan_layer "${FOSSILIZE_LAYER_NAME}"   <-- no guard
//
// The neighbouring layers are env-gated; this one is not. `find_vulkan_layer` looks for the .so in
// /usr/share/guestos/android/vendor/vulkan_layers/ -- the DISTRO's slot, ours to fill -- returns
// empty when it is absent, `enable_vulkan_layer` returns 1, and lepton runs under
// `set -euo pipefail`. So a missing fossilize layer is a fatal launch failure for EVERY Android
// title, ~5s in, with no output on the session log. Measured on a Pocket ACE 2026-08-29 with
// Lepton v2.8.9 (issue #58); there is no environment variable that skips it.
//
// WHY A STUB AND NOT FOSSILIZE. Fossilize is a shader-cache layer: it contributes nothing to
// getting a title on screen, and porting it to Android/bionic is an NDK cross-build of a
// substantial CMake project. What Lepton actually requires is that a layer by that FILENAME exists
// and loads. So this is a correct, complete, no-op passthrough layer: it chains every call straight
// to the next layer and records nothing. If we ever want real shader caching in the guest, this is
// replaced by a genuine port and nothing else in the tree has to change.
//
// It is NOT a fake in the sense that matters: it is a valid layer that does what it says (nothing).
// The one thing it must never do is fail to load -- Android's Vulkan loader gives no useful
// diagnostic, and the abort takes the process that would have logged it (the same failure shape as
// the zink/SurfaceFlinger abort in this same slot).
//
// LOADER CONTRACT, implemented to interface version 2:
//   vkNegotiateLoaderLayerInterfaceVersion  the modern entry point; the loader calls this first.
//   vkCreateInstance / vkCreateDevice       must ADVANCE the chain link before calling down, or the
//                                           next layer is called with our own link and recurses.
//   vkGetInstanceProcAddr / …DeviceProcAddr resolve our own names, else chain down.
//
// The layer structs below are declared here rather than included from vk_layer.h, which the NDK
// does not ship (it lives in Vulkan-Loader, not the platform headers). They are ABI, fixed by the
// loader interface, and this keeps the build a single clang invocation with no vendored headers.
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

// Also from vk_layer.h. The build compiles with -fvisibility=hidden precisely so that this is the
// ONLY thing that marks a symbol as exported. Android's loader resolves a layer's entry points with
// dlsym under their STANDARD names before it tries vkNegotiateLoaderLayerInterfaceVersion, so the
// four vkEnumerate* functions and the two proc-address entry points must all leave the .so under
// those names -- answering only through our own symbols gets the layer reported as "missing some
// instance enumeration functions" and partly rejected. Nothing else should be exported.
#define VK_LAYER_EXPORT __attribute__((visibility("default")))

typedef enum VkLayerFunction_ {
    VK_LAYER_LINK_INFO = 0,
    VK_LOADER_DATA_CALLBACK = 1,
    VK_LOADER_LAYER_CREATE_DEVICE_CALLBACK = 2,
    VK_LOADER_FEATURES = 3,
} VkLayerFunction;

typedef PFN_vkVoidFunction(VKAPI_PTR *PFN_vkGetPhysicalDeviceProcAddr)(VkInstance, const char *);

typedef struct VkLayerInstanceLink_ {
    struct VkLayerInstanceLink_ *pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_vkGetPhysicalDeviceProcAddr pfnNextGetPhysicalDeviceProcAddr;
} VkLayerInstanceLink;

typedef struct VkLayerInstanceCreateInfo_ {
    VkStructureType sType;
    const void *pNext;
    VkLayerFunction function;
    union {
        VkLayerInstanceLink *pLayerInfo;
        void *pfnSetInstanceLoaderData;
        void *layerDevice;
        VkFlags loaderFeatures;
    } u;
} VkLayerInstanceCreateInfo;

typedef struct VkLayerDeviceLink_ {
    struct VkLayerDeviceLink_ *pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnNextGetDeviceProcAddr;
} VkLayerDeviceLink;

typedef struct VkLayerDeviceCreateInfo_ {
    VkStructureType sType;
    const void *pNext;
    VkLayerFunction function;
    union {
        VkLayerDeviceLink *pLayerInfo;
        void *pfnSetDeviceLoaderData;
    } u;
} VkLayerDeviceCreateInfo;

typedef struct VkNegotiateLayerInterface_ {
    VkStructureType sType;
    void *pNext;
    uint32_t loaderLayerInterfaceVersion;
    PFN_vkGetInstanceProcAddr pfnGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnGetDeviceProcAddr;
    PFN_vkGetPhysicalDeviceProcAddr pfnGetPhysicalDeviceProcAddr;
} VkNegotiateLayerInterface;

#define LAYER_NAME "VK_LAYER_novadeck_fossilize_stub"

// THE NEXT LINK IN THE CHAIN, kept as file-scope state.
//
// A layer that intercepted real calls would need a dispatch table keyed on the instance/device, so
// that two instances cannot read each other's chain. This one intercepts NOTHING after creation --
// every entry point it answers for is a creation or a proc-address lookup -- so the only thing it
// has to remember is where "down" is. An app that creates a second instance overwrites this with an
// identical value, because the layer stack below us is the same one. That is the whole reason this
// is safe here and would not be in a layer that did any work.
static PFN_vkGetInstanceProcAddr g_next_gipa = NULL;
static PFN_vkGetDeviceProcAddr g_next_gdpa = NULL;

static VKAPI_ATTR VkResult VKAPI_CALL
novadeck_CreateInstance(const VkInstanceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAlloc,
                        VkInstance *pInstance)
{
    VkLayerInstanceCreateInfo *chain = (VkLayerInstanceCreateInfo *)pCreateInfo->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                      chain->function == VK_LAYER_LINK_INFO))
        chain = (VkLayerInstanceCreateInfo *)chain->pNext;

    if (!chain || !chain->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;

    // ADVANCE THE CHAIN before calling down. Skipping this hands the next layer our own link, and
    // it calls us again -- an infinite recursion that presents as a hang inside vkCreateInstance.
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    PFN_vkCreateInstance create = (PFN_vkCreateInstance)next(NULL, "vkCreateInstance");
    if (!create)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkResult r = create(pCreateInfo, pAlloc, pInstance);
    if (r == VK_SUCCESS)
        g_next_gipa = next;
    return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL
novadeck_CreateDevice(VkPhysicalDevice gpu, const VkDeviceCreateInfo *pCreateInfo,
                      const VkAllocationCallbacks *pAlloc, VkDevice *pDevice)
{
    VkLayerDeviceCreateInfo *chain = (VkLayerDeviceCreateInfo *)pCreateInfo->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                      chain->function == VK_LAYER_LINK_INFO))
        chain = (VkLayerDeviceCreateInfo *)chain->pNext;

    if (!chain || !chain->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr next_gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;

    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;   // same advance-or-recurse rule as above

    PFN_vkCreateDevice create = (PFN_vkCreateDevice)next_gipa(NULL, "vkCreateDevice");
    if (!create)
        return VK_ERROR_INITIALIZATION_FAILED;

    VkResult r = create(gpu, pCreateInfo, pAlloc, pDevice);
    if (r == VK_SUCCESS)
        g_next_gdpa = next_gdpa;
    return r;
}

// The loader asks a layer to enumerate itself BEFORE any instance exists, so these cannot chain.
VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceLayerProperties(uint32_t *pCount, VkLayerProperties *pProps)
{
    if (!pProps) { *pCount = 1; return VK_SUCCESS; }
    if (*pCount < 1) { *pCount = 0; return VK_INCOMPLETE; }
    *pCount = 1;
    memset(pProps, 0, sizeof(*pProps));
    strcpy(pProps->layerName, LAYER_NAME);
    pProps->specVersion = VK_MAKE_VERSION(1, 1, 0);
    pProps->implementationVersion = 1;
    strcpy(pProps->description, "novadeck no-op stand-in for libVkLayer_fossilize.so");
    return VK_SUCCESS;
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateDeviceLayerProperties(VkPhysicalDevice gpu, uint32_t *pCount,
                                        VkLayerProperties *pProps)
{
    (void)gpu;
    return vkEnumerateInstanceLayerProperties(pCount, pProps);
}

// We implement no extensions. Answering 0 for our OWN layer name is required; for any other layer
// name the loader must be told we cannot answer, so it asks the next one down.
VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceExtensionProperties(const char *pLayerName, uint32_t *pCount,
                                              VkExtensionProperties *pProps)
{
    (void)pProps;
    if (pLayerName && strcmp(pLayerName, LAYER_NAME) == 0) { *pCount = 0; return VK_SUCCESS; }
    return VK_ERROR_LAYER_NOT_PRESENT;
}

VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateDeviceExtensionProperties(VkPhysicalDevice gpu, const char *pLayerName,
                                            uint32_t *pCount, VkExtensionProperties *pProps)
{
    if (pLayerName && strcmp(pLayerName, LAYER_NAME) == 0) { *pCount = 0; return VK_SUCCESS; }
    if (!g_next_gipa) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkEnumerateDeviceExtensionProperties down =
        (PFN_vkEnumerateDeviceExtensionProperties)g_next_gipa(NULL, "vkEnumerateDeviceExtensionProperties");
    if (!down) return VK_ERROR_INITIALIZATION_FAILED;
    return down(gpu, pLayerName, pCount, pProps);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
novadeck_GetInstanceProcAddr(VkInstance instance, const char *pName)
{
#define OURS(n, f) if (strcmp(pName, n) == 0) return (PFN_vkVoidFunction)(f)
    OURS("vkGetInstanceProcAddr", novadeck_GetInstanceProcAddr);
    OURS("vkCreateInstance", novadeck_CreateInstance);
    OURS("vkCreateDevice", novadeck_CreateDevice);
    OURS("vkEnumerateInstanceLayerProperties", vkEnumerateInstanceLayerProperties);
    OURS("vkEnumerateInstanceExtensionProperties", vkEnumerateInstanceExtensionProperties);
    OURS("vkEnumerateDeviceLayerProperties", vkEnumerateDeviceLayerProperties);
    OURS("vkEnumerateDeviceExtensionProperties", vkEnumerateDeviceExtensionProperties);
#undef OURS
    if (!g_next_gipa) return NULL;
    return g_next_gipa(instance, pName);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
novadeck_GetDeviceProcAddr(VkDevice device, const char *pName)
{
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0)
        return (PFN_vkVoidFunction)novadeck_GetDeviceProcAddr;
    if (!g_next_gdpa) return NULL;
    return g_next_gdpa(device, pName);
}

// Standard-named aliases, exported for the loader's legacy dlsym path. Android's loader looks these
// up by name before it tries the negotiate function, and a layer that answers only through its own
// symbols is reported as "missing some instance enumeration functions" and partly rejected --
// measured on a Pocket ACE 2026-08-29, which is how this was found.
VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char *pName)
{
    return novadeck_GetInstanceProcAddr(instance, pName);
}

VK_LAYER_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(VkDevice device, const char *pName)
{
    return novadeck_GetDeviceProcAddr(device, pName);
}

// Loader interface v2 entry point. The loader calls this before anything else; answering it is what
// lets the loader find our GIPA/GDPA without dlsym'ing the legacy vk* symbol names.
VK_LAYER_EXPORT VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *pVersionStruct)
{
    if (!pVersionStruct || pVersionStruct->sType != VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO)
        return VK_ERROR_INITIALIZATION_FAILED;

    if (pVersionStruct->loaderLayerInterfaceVersion > 2)
        pVersionStruct->loaderLayerInterfaceVersion = 2;

    pVersionStruct->pfnGetInstanceProcAddr = novadeck_GetInstanceProcAddr;
    pVersionStruct->pfnGetDeviceProcAddr = novadeck_GetDeviceProcAddr;
    pVersionStruct->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
