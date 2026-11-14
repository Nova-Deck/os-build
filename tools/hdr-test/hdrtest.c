// hdrtest -- a minimal Vulkan HDR10 swapchain test for gamescope on the device.
//
// WHY. Testing HDR scanout needs a client that really presents an HDR10 (PQ, BT.2020) swapchain.
// Games are a poor instrument: their HDR switch is hidden, renderer-dependent and not repeatable.
// This draws a fixed test pattern into the swapchain and nothing else, so the only variables are
// the swapchain format/colour space it gets and what gamescope + the DPU do with it.
//
// HOW. No shaders: the pattern is computed on the CPU, already encoded for the chosen swapchain
// format (PQ for HDR10, sRGB for SDR), and copied into each swapchain image once. Every frame
// just re-presents those images. Vulkan and Xlib are dlopen()ed, so the binary has no link-time
// dependency beyond libc and builds with nothing but the Vulkan headers.
//
// It is an X11 client on purpose: under gamescope that is the path games take (Xwayland), and the
// gamescope WSI layer (ENABLE_GAMESCOPE_WSI=1, which Steam exports) is what turns an X11 surface
// into a gamescope swapchain able to carry HDR10.
//
// Usage:  hdrtest [hdr|sdr|sdr10] [seconds]   (defaults: hdr, 0 = run until killed)
//         sdr10 = the 10-bit swapchain format with sRGB: separates the 10-bit path from PQ.
// Log:    $HDRTEST_LOG, default /tmp/hdrtest.log, plus stderr.
//
// Pattern (1920x1080, four bands top to bottom):
//   1. PQ grey ramp, signal 0..1 left to right, ticks at 100 / 203 / 650 / 1000 nits.
//   2. White patches: 50, 100, 203, 400, 650, 1000, 4000 nits.
//   3. BT.2020 primaries R G B, then BT.709 primaries R G B, each at 203 nits.
//   4. Near-black ramp 0..5 nits, then a 0..1 nit staircase in 10 steps.
// In sdr mode the same layout is drawn in sRGB with 203 nits as white (brighter patches clip).

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 1920
#define H 1080
#define MAX_IMAGES 8
#define SDR_WHITE_NITS 203.0

// ---- minimal Xlib, resolved at runtime --------------------------------------------------------
typedef struct _XDisplay Display;
typedef unsigned long XWindow;
static Display *(*pXOpenDisplay)(const char *);
static int (*pXDefaultScreen)(Display *);
static XWindow (*pXRootWindow)(Display *, int);
static XWindow (*pXCreateSimpleWindow)(Display *, XWindow, int, int, unsigned, unsigned, unsigned,
                                       unsigned long, unsigned long);
static int (*pXStoreName)(Display *, XWindow, const char *);
static int (*pXMapWindow)(Display *, XWindow);
static int (*pXFlush)(Display *);

typedef struct {
    VkStructureType sType;
    const void *pNext;
    VkFlags flags;
    Display *dpy;
    XWindow window;
} XlibSurfaceCreateInfo;
typedef VkResult (*PFN_CreateXlibSurface)(VkInstance, const XlibSurfaceCreateInfo *,
                                          const VkAllocationCallbacks *, VkSurfaceKHR *);
#define STYPE_XLIB_SURFACE_CREATE_INFO ((VkStructureType)1000004000)

// ---- logging -----------------------------------------------------------------------------------
static FILE *g_log;

static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (g_log) {
        va_start(ap, fmt);
        vfprintf(g_log, fmt, ap);
        va_end(ap);
        fflush(g_log);
    }
}

static void die(const char *what, VkResult r)
{
    say("hdrtest: FAIL %s (VkResult %d)\n", what, (int)r);
    exit(1);
}

#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) die(#call, r_); } while (0)

static volatile sig_atomic_t g_stop;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

// ---- colour ------------------------------------------------------------------------------------
static double pq_encode(double nits)
{
    const double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 4096.0 * 128.0;
    const double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 4096.0 * 32.0, c3 = 2392.0 / 4096.0 * 32.0;
    double l = nits / 10000.0;
    if (l < 0.0) l = 0.0;
    if (l > 1.0) l = 1.0;
    double p = pow(l, m1);
    return pow((c1 + c2 * p) / (1.0 + c3 * p), m2);
}

static double srgb_encode(double nits)
{
    double l = nits / SDR_WHITE_NITS;
    if (l <= 0.0) return 0.0;
    if (l >= 1.0) return 1.0;
    return l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1.0 / 2.4) - 0.055;
}

// A colour in linear nits per channel, in the swapchain's primaries.
typedef struct { double r, g, b; } nits3;

static nits3 grey(double n) { return (nits3){ n, n, n }; }

// BT.709 -> BT.2020, linear.
static nits3 bt709_to_2020(nits3 c)
{
    return (nits3){
        0.6274 * c.r + 0.3293 * c.g + 0.0433 * c.b,
        0.0691 * c.r + 0.9195 * c.g + 0.0114 * c.b,
        0.0164 * c.r + 0.0880 * c.g + 0.8956 * c.b,
    };
}

typedef struct {
    VkFormat format;
    VkColorSpaceKHR space;
    int hdr;
} target_t;

static int is_10bit(VkFormat f)
{
    return f == VK_FORMAT_A2B10G10R10_UNORM_PACK32 || f == VK_FORMAT_A2R10G10B10_UNORM_PACK32;
}

static uint32_t pack(const target_t *t, nits3 c)
{
    if (is_10bit(t->format)) {
        double (*enc)(double) = t->hdr ? pq_encode : srgb_encode;
        uint32_t r = (uint32_t)lround(enc(c.r) * 1023.0);
        uint32_t g = (uint32_t)lround(enc(c.g) * 1023.0);
        uint32_t b = (uint32_t)lround(enc(c.b) * 1023.0);
        if (t->format == VK_FORMAT_A2B10G10R10_UNORM_PACK32)
            return 3u << 30 | b << 20 | g << 10 | r;
        return 3u << 30 | r << 20 | g << 10 | b;   // A2R10G10B10
    }
    uint32_t r = (uint32_t)lround(srgb_encode(c.r) * 255.0);
    uint32_t g = (uint32_t)lround(srgb_encode(c.g) * 255.0);
    uint32_t b = (uint32_t)lround(srgb_encode(c.b) * 255.0);
    if (t->format == VK_FORMAT_R8G8B8A8_UNORM)
        return 0xffu << 24 | b << 16 | g << 8 | r;
    return 0xffu << 24 | r << 16 | g << 8 | b;     // B8G8R8A8
}

static double pq_decode_to_nits(double e)
{
    const double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 4096.0 * 128.0;
    const double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 4096.0 * 32.0, c3 = 2392.0 / 4096.0 * 32.0;
    double p = pow(e, 1.0 / m2);
    double num = p - c1 > 0.0 ? p - c1 : 0.0;
    return 10000.0 * pow(num / (c2 - c3 * p), 1.0 / m1);
}

static void fill_pattern(const target_t *t, uint32_t *px)
{
    const int band = H / 4;
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            nits3 c = grey(0.0);
            double fx = (double)x / (W - 1);
            if (y < band) {
                // 1. ramp, uniform in PQ signal; in SDR the same signal is shown as nits so the
                //    two modes line up position for position.
                double nits = pq_decode_to_nits(fx);
                c = grey(nits);
                if (y > band * 3 / 4) {
                    static const double ticks[] = { 100, 203, 650, 1000 };
                    for (unsigned i = 0; i < sizeof ticks / sizeof ticks[0]; i++)
                        if (abs(x - (int)lround(pq_encode(ticks[i]) * (W - 1))) <= 1)
                            c = grey(0.0);
                }
            } else if (y < 2 * band) {
                static const double whites[] = { 50, 100, 203, 400, 650, 1000, 4000 };
                int n = sizeof whites / sizeof whites[0];
                c = grey(whites[x * n / W]);
            } else if (y < 3 * band) {
                int i = x * 6 / W;
                nits3 prim[6] = {
                    { SDR_WHITE_NITS, 0, 0 }, { 0, SDR_WHITE_NITS, 0 }, { 0, 0, SDR_WHITE_NITS },
                    { SDR_WHITE_NITS, 0, 0 }, { 0, SDR_WHITE_NITS, 0 }, { 0, 0, SDR_WHITE_NITS },
                };
                c = prim[i];
                // The last three are BT.709 primaries. In HDR10 they must be expressed in BT.2020;
                // in SDR the swapchain is BT.709 and the first three are out of its gamut, so they
                // clip to the same 709 primaries -- which is itself the expected SDR result.
                if (i >= 3 && t->hdr)
                    c = bt709_to_2020(c);
            } else {
                if (x < W / 2) {
                    c = grey(5.0 * x / (W / 2 - 1));
                } else {
                    int step = (x - W / 2) * 10 / (W / 2);
                    c = grey(step / 9.0);
                }
            }
            px[y * W + x] = pack(t, c);
        }
    }
}

// ---- Vulkan ------------------------------------------------------------------------------------
#define VKF(name) static PFN_##name name
VKF(vkGetInstanceProcAddr); VKF(vkCreateInstance); VKF(vkEnumerateInstanceExtensionProperties);
VKF(vkEnumeratePhysicalDevices); VKF(vkGetPhysicalDeviceQueueFamilyProperties);
VKF(vkGetPhysicalDeviceSurfaceSupportKHR); VKF(vkGetPhysicalDeviceSurfaceFormatsKHR);
VKF(vkGetPhysicalDeviceSurfaceCapabilitiesKHR); VKF(vkEnumerateDeviceExtensionProperties);
VKF(vkGetPhysicalDeviceMemoryProperties); VKF(vkCreateDevice); VKF(vkGetDeviceProcAddr);
VKF(vkGetPhysicalDeviceProperties);
VKF(vkGetDeviceQueue); VKF(vkCreateSwapchainKHR); VKF(vkGetSwapchainImagesKHR);
VKF(vkCreateBuffer); VKF(vkGetBufferMemoryRequirements); VKF(vkAllocateMemory);
VKF(vkBindBufferMemory); VKF(vkMapMemory); VKF(vkCreateCommandPool); VKF(vkAllocateCommandBuffers);
VKF(vkBeginCommandBuffer); VKF(vkEndCommandBuffer); VKF(vkCmdPipelineBarrier);
VKF(vkCmdCopyBufferToImage); VKF(vkCreateSemaphore); VKF(vkAcquireNextImageKHR);
VKF(vkQueueSubmit); VKF(vkQueuePresentKHR); VKF(vkQueueWaitIdle); VKF(vkDeviceWaitIdle);
static PFN_vkSetHdrMetadataEXT vkSetHdrMetadataEXT;

#define LOAD_I(inst, name) do { name = (PFN_##name)vkGetInstanceProcAddr(inst, #name); \
    if (!name) { say("hdrtest: FAIL missing %s\n", #name); exit(1); } } while (0)
#define LOAD_D(dev, name) do { name = (PFN_##name)vkGetDeviceProcAddr(dev, #name); \
    if (!name) { say("hdrtest: FAIL missing %s\n", #name); exit(1); } } while (0)

static int has_ext(const VkExtensionProperties *e, uint32_t n, const char *name)
{
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(e[i].extensionName, name))
            return 1;
    return 0;
}

static void *must_dlopen(const char *lib)
{
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        say("hdrtest: FAIL dlopen %s: %s\n", lib, dlerror());
        exit(1);
    }
    return h;
}

static void *must_dlsym(void *h, const char *sym)
{
    void *p = dlsym(h, sym);
    if (!p) {
        say("hdrtest: FAIL dlsym %s\n", sym);
        exit(1);
    }
    return p;
}

static const char *space_name(VkColorSpaceKHR s)
{
    switch (s) {
    case VK_COLOR_SPACE_SRGB_NONLINEAR_KHR: return "SRGB_NONLINEAR";
    case VK_COLOR_SPACE_HDR10_ST2084_EXT: return "HDR10_ST2084";
    case VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT: return "EXTENDED_SRGB_LINEAR";
    default: return "other";
    }
}

/* want_hdr: 1 = HDR10, 0 = 8-bit sRGB, 2 = 10-bit sRGB (isolates the 10-bit format from PQ) */
static int pick_target(const VkSurfaceFormatKHR *f, uint32_t n, int want_hdr, target_t *out)
{
    static const VkFormat hdr_order[] = { VK_FORMAT_A2B10G10R10_UNORM_PACK32,
                                          VK_FORMAT_A2R10G10B10_UNORM_PACK32 };
    static const VkFormat sdr_order[] = { VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM };
    const VkFormat *order = want_hdr ? hdr_order : sdr_order;
    VkColorSpaceKHR space = want_hdr == 1 ? VK_COLOR_SPACE_HDR10_ST2084_EXT
                                          : VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    int hdr = want_hdr == 1;
    for (int o = 0; o < 2; o++)
        for (uint32_t i = 0; i < n; i++)
            if (f[i].format == order[o] && f[i].colorSpace == space) {
                *out = (target_t){ order[o], space, hdr };
                return 1;
            }
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "hdr";
    int want_hdr = !strcmp(mode, "sdr") ? 0 : !strcmp(mode, "sdr10") ? 2 : 1;
    double seconds = argc > 2 ? atof(argv[2]) : 0.0;
    const char *log_path = getenv("HDRTEST_LOG") ? getenv("HDRTEST_LOG") : "/tmp/hdrtest.log";
    g_log = fopen(log_path, "w");
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    say("hdrtest: mode %s, DISPLAY=%s ENABLE_GAMESCOPE_WSI=%s\n",
        want_hdr == 1 ? "hdr" : want_hdr == 2 ? "sdr10" : "sdr",
        getenv("DISPLAY") ? getenv("DISPLAY") : "(unset)",
        getenv("ENABLE_GAMESCOPE_WSI") ? getenv("ENABLE_GAMESCOPE_WSI") : "(unset)");

    // X11 window.
    void *x11 = must_dlopen("libX11.so.6");
    pXOpenDisplay = must_dlsym(x11, "XOpenDisplay");
    pXDefaultScreen = must_dlsym(x11, "XDefaultScreen");
    pXRootWindow = must_dlsym(x11, "XRootWindow");
    pXCreateSimpleWindow = must_dlsym(x11, "XCreateSimpleWindow");
    pXStoreName = must_dlsym(x11, "XStoreName");
    pXMapWindow = must_dlsym(x11, "XMapWindow");
    pXFlush = must_dlsym(x11, "XFlush");
    Display *dpy = pXOpenDisplay(NULL);
    if (!dpy) {
        say("hdrtest: FAIL XOpenDisplay\n");
        return 1;
    }
    XWindow win = pXCreateSimpleWindow(dpy, pXRootWindow(dpy, pXDefaultScreen(dpy)), 0, 0, W, H,
                                       0, 0, 0);
    pXStoreName(dpy, win, "hdrtest");
    pXMapWindow(dpy, win);
    pXFlush(dpy);

    // Instance.
    void *vk = must_dlopen("libvulkan.so.1");
    vkGetInstanceProcAddr = must_dlsym(vk, "vkGetInstanceProcAddr");
    LOAD_I(NULL, vkCreateInstance);
    LOAD_I(NULL, vkEnumerateInstanceExtensionProperties);
    uint32_t n_iext = 0;
    vkEnumerateInstanceExtensionProperties(NULL, &n_iext, NULL);
    VkExtensionProperties *iext = calloc(n_iext, sizeof *iext);
    vkEnumerateInstanceExtensionProperties(NULL, &n_iext, iext);
    const char *inst_exts[3] = { "VK_KHR_surface", "VK_KHR_xlib_surface" };
    uint32_t n_inst_exts = 2;
    int colorspace_ext = has_ext(iext, n_iext, "VK_EXT_swapchain_colorspace");
    if (colorspace_ext)
        inst_exts[n_inst_exts++] = "VK_EXT_swapchain_colorspace";
    say("hdrtest: VK_EXT_swapchain_colorspace %s\n", colorspace_ext ? "present" : "ABSENT");
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "hdrtest", .apiVersion = VK_API_VERSION_1_1 };
    VkInstance inst;
    CHECK(vkCreateInstance(&(VkInstanceCreateInfo){
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app,
        .enabledExtensionCount = n_inst_exts, .ppEnabledExtensionNames = inst_exts }, NULL, &inst));
    LOAD_I(inst, vkEnumeratePhysicalDevices); LOAD_I(inst, vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_I(inst, vkGetPhysicalDeviceSurfaceSupportKHR); LOAD_I(inst, vkGetPhysicalDeviceSurfaceFormatsKHR);
    LOAD_I(inst, vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    LOAD_I(inst, vkEnumerateDeviceExtensionProperties); LOAD_I(inst, vkGetPhysicalDeviceMemoryProperties);
    LOAD_I(inst, vkCreateDevice); LOAD_I(inst, vkGetDeviceProcAddr); LOAD_I(inst, vkGetPhysicalDeviceProperties);
    PFN_CreateXlibSurface create_xlib =
        (PFN_CreateXlibSurface)vkGetInstanceProcAddr(inst, "vkCreateXlibSurfaceKHR");
    if (!create_xlib) {
        say("hdrtest: FAIL missing vkCreateXlibSurfaceKHR\n");
        return 1;
    }
    VkSurfaceKHR surface;
    CHECK(create_xlib(inst, &(XlibSurfaceCreateInfo){ .sType = STYPE_XLIB_SURFACE_CREATE_INFO,
                                                       .dpy = dpy, .window = win }, NULL, &surface));

    // Physical device and queue.
    uint32_t n_pd = 1;
    VkPhysicalDevice pd;
    VkResult enum_r = vkEnumeratePhysicalDevices(inst, &n_pd, &pd);
    if ((enum_r != VK_SUCCESS && enum_r != VK_INCOMPLETE) || n_pd == 0)
        die("vkEnumeratePhysicalDevices", enum_r);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    say("hdrtest: device %s\n", props.deviceName);
    uint32_t n_qf = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &n_qf, NULL);
    VkQueueFamilyProperties *qf = calloc(n_qf, sizeof *qf);
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &n_qf, qf);
    uint32_t qfi = UINT32_MAX;
    for (uint32_t i = 0; i < n_qf && qfi == UINT32_MAX; i++) {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(pd, i, surface, &present);
        if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present)
            qfi = i;
    }
    if (qfi == UINT32_MAX) {
        say("hdrtest: FAIL no graphics queue that can present\n");
        return 1;
    }

    // Surface formats: logged in full, because which ones the gamescope layer offers is itself
    // a result.
    uint32_t n_fmt = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &n_fmt, NULL);
    VkSurfaceFormatKHR *fmts = calloc(n_fmt, sizeof *fmts);
    vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &n_fmt, fmts);
    for (uint32_t i = 0; i < n_fmt; i++)
        say("hdrtest: surface format %u: VkFormat %d, colour space %s (%d)\n", i,
            (int)fmts[i].format, space_name(fmts[i].colorSpace), (int)fmts[i].colorSpace);
    target_t tgt;
    if (!pick_target(fmts, n_fmt, want_hdr, &tgt)) {
        say("hdrtest: FAIL the surface offers no %s format\n",
            want_hdr == 1 ? "10-bit HDR10_ST2084" :
            want_hdr == 2 ? "10-bit SRGB_NONLINEAR" : "8-bit SRGB_NONLINEAR");
        return 1;
    }
    say("hdrtest: using VkFormat %d, colour space %s\n", (int)tgt.format, space_name(tgt.space));

    // Device.
    uint32_t n_dext = 0;
    vkEnumerateDeviceExtensionProperties(pd, NULL, &n_dext, NULL);
    VkExtensionProperties *dext = calloc(n_dext, sizeof *dext);
    vkEnumerateDeviceExtensionProperties(pd, NULL, &n_dext, dext);
    const char *dev_exts[2] = { "VK_KHR_swapchain" };
    uint32_t n_dev_exts = 1;
    int hdr_meta = tgt.hdr && has_ext(dext, n_dext, "VK_EXT_hdr_metadata");
    if (hdr_meta)
        dev_exts[n_dev_exts++] = "VK_EXT_hdr_metadata";
    float prio = 1.0f;
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &(VkDeviceCreateInfo){
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &(VkDeviceQueueCreateInfo){
            .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qfi,
            .queueCount = 1, .pQueuePriorities = &prio },
        .enabledExtensionCount = n_dev_exts, .ppEnabledExtensionNames = dev_exts }, NULL, &dev));
    LOAD_D(dev, vkGetDeviceQueue); LOAD_D(dev, vkCreateSwapchainKHR); LOAD_D(dev, vkGetSwapchainImagesKHR);
    LOAD_D(dev, vkCreateBuffer); LOAD_D(dev, vkGetBufferMemoryRequirements); LOAD_D(dev, vkAllocateMemory);
    LOAD_D(dev, vkBindBufferMemory); LOAD_D(dev, vkMapMemory); LOAD_D(dev, vkCreateCommandPool);
    LOAD_D(dev, vkAllocateCommandBuffers); LOAD_D(dev, vkBeginCommandBuffer); LOAD_D(dev, vkEndCommandBuffer);
    LOAD_D(dev, vkCmdPipelineBarrier); LOAD_D(dev, vkCmdCopyBufferToImage); LOAD_D(dev, vkCreateSemaphore);
    LOAD_D(dev, vkAcquireNextImageKHR); LOAD_D(dev, vkQueueSubmit); LOAD_D(dev, vkQueuePresentKHR);
    LOAD_D(dev, vkQueueWaitIdle); LOAD_D(dev, vkDeviceWaitIdle);
    if (hdr_meta)
        LOAD_D(dev, vkSetHdrMetadataEXT);
    say("hdrtest: VK_EXT_hdr_metadata %s\n", hdr_meta ? "enabled" : "not used");
    VkQueue queue;
    vkGetDeviceQueue(dev, qfi, 0, &queue);

    // Swapchain. The pattern is copied in, so the images must take TRANSFER_DST.
    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, &caps));
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) {
        say("hdrtest: FAIL swapchain images cannot be a transfer destination\n");
        return 1;
    }
    VkExtent2D extent = caps.currentExtent.width != UINT32_MAX ? caps.currentExtent
                                                               : (VkExtent2D){ W, H };
    if (extent.width != W || extent.height != H) {
        say("hdrtest: FAIL surface extent %ux%u, pattern is %ux%u\n", extent.width, extent.height,
            W, H);
        return 1;
    }
    uint32_t min_images = caps.minImageCount + 1;
    if (caps.maxImageCount && min_images > caps.maxImageCount)
        min_images = caps.maxImageCount;
    VkSwapchainKHR sc;
    CHECK(vkCreateSwapchainKHR(dev, &(VkSwapchainCreateInfoKHR){
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surface,
        .minImageCount = min_images, .imageFormat = tgt.format, .imageColorSpace = tgt.space,
        .imageExtent = extent, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE }, NULL, &sc));
    uint32_t n_img = MAX_IMAGES;
    VkImage imgs[MAX_IMAGES];
    VkResult img_r = vkGetSwapchainImagesKHR(dev, sc, &n_img, imgs);
    if (img_r != VK_SUCCESS)
        die("vkGetSwapchainImagesKHR", img_r);

    if (hdr_meta) {
        // BT.2020 primaries, D65, mastered for 1000 nits -- what a typical HDR10 game declares.
        VkHdrMetadataEXT md = {
            .sType = VK_STRUCTURE_TYPE_HDR_METADATA_EXT,
            .displayPrimaryRed = { 0.708f, 0.292f }, .displayPrimaryGreen = { 0.170f, 0.797f },
            .displayPrimaryBlue = { 0.131f, 0.046f }, .whitePoint = { 0.3127f, 0.3290f },
            .maxLuminance = 1000.0f, .minLuminance = 0.005f,
            .maxContentLightLevel = 1000.0f, .maxFrameAverageLightLevel = 400.0f,
        };
        vkSetHdrMetadataEXT(dev, 1, &sc, &md);
    }

    // Staging buffer holding the encoded pattern.
    VkDeviceSize size = (VkDeviceSize)W * H * 4;
    VkBuffer buf;
    CHECK(vkCreateBuffer(dev, &(VkBufferCreateInfo){
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT }, NULL, &buf));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(dev, buf, &req);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    uint32_t mt = UINT32_MAX;
    const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < mp.memoryTypeCount && mt == UINT32_MAX; i++)
        if ((req.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
            mt = i;
    if (mt == UINT32_MAX) {
        say("hdrtest: FAIL no host-visible coherent memory\n");
        return 1;
    }
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &(VkMemoryAllocateInfo){
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
        .memoryTypeIndex = mt }, NULL, &mem));
    CHECK(vkBindBufferMemory(dev, buf, mem, 0));
    void *map;
    CHECK(vkMapMemory(dev, mem, 0, size, 0, &map));
    fill_pattern(&tgt, map);

    // One command buffer per swapchain image: copy the pattern in, hand it to present.
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &(VkCommandPoolCreateInfo){
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qfi }, NULL, &pool));
    VkCommandBuffer cmd[MAX_IMAGES];
    CHECK(vkAllocateCommandBuffers(dev, &(VkCommandBufferAllocateInfo){
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = n_img }, cmd));
    const VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    for (uint32_t i = 0; i < n_img; i++) {
        CHECK(vkBeginCommandBuffer(cmd[i], &(VkCommandBufferBeginInfo){
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO }));
        vkCmdPipelineBarrier(cmd[i], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &(VkImageMemoryBarrier){
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = imgs[i], .subresourceRange = range });
        vkCmdCopyBufferToImage(cmd[i], buf, imgs[i], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
            &(VkBufferImageCopy){ .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                                  .imageExtent = { W, H, 1 } });
        vkCmdPipelineBarrier(cmd[i], VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &(VkImageMemoryBarrier){
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = imgs[i], .subresourceRange = range });
        CHECK(vkEndCommandBuffer(cmd[i]));
    }

    VkSemaphore acquired, done;
    CHECK(vkCreateSemaphore(dev, &(VkSemaphoreCreateInfo){
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, NULL, &acquired));
    CHECK(vkCreateSemaphore(dev, &(VkSemaphoreCreateInfo){
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, NULL, &done));

    say("hdrtest: presenting %u images %ux%u, %s\n", n_img, extent.width, extent.height,
        seconds > 0 ? "timed" : "until killed");
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    unsigned long frames = 0;
    while (!g_stop) {
        uint32_t idx;
        VkResult r = vkAcquireNextImageKHR(dev, sc, UINT64_MAX, acquired, VK_NULL_HANDLE, &idx);
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR)
            die("vkAcquireNextImageKHR", r);
        const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        CHECK(vkQueueSubmit(queue, 1, &(VkSubmitInfo){
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1,
            .pWaitSemaphores = &acquired, .pWaitDstStageMask = &stage, .commandBufferCount = 1,
            .pCommandBuffers = &cmd[idx], .signalSemaphoreCount = 1, .pSignalSemaphores = &done },
            VK_NULL_HANDLE));
        r = vkQueuePresentKHR(queue, &(VkPresentInfoKHR){
            .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1,
            .pWaitSemaphores = &done, .swapchainCount = 1, .pSwapchains = &sc,
            .pImageIndices = &idx });
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR)
            die("vkQueuePresentKHR", r);
        CHECK(vkQueueWaitIdle(queue));
        frames++;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        if (frames == 1 || frames % 600 == 0)
            say("hdrtest: %lu frames, %.1f s\n", frames, elapsed);
        if (seconds > 0 && elapsed >= seconds)
            break;
    }
    vkDeviceWaitIdle(dev);
    say("hdrtest: done, %lu frames\n", frames);
    return 0;
}
