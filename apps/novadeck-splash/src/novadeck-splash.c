// novadeck-splash — the boot / shutdown splash drawer.
//
// One process paints the panel from the initramfs until the session takes the display, and
// again on the way down. It renders a logo plus a single line of live status text read from a
// file, so every phase of boot can say what it is doing without any of them linking against
// this program.
//
// WHY THIS IS A STATIC BINARY WITH NO LIBRARY DEPENDENCIES AT ALL.
//
// Two independent reasons, both of which have already cost this project a hardware cycle:
//
//   1. The build container's cross toolchain is glibc 2.43; the image ships 2.42. Anything
//      dynamically linked here references GLIBC_2.43 symbols the device cannot resolve, so the
//      binary fails to load — and a splash that fails to load is indistinguishable from a
//      splash that ran and drew nothing. That is exactly how the first splash attempt died.
//   2. This process must survive switch_root. The initramfs is freed underneath it, taking every
//      .so with it. Already-mapped pages stay valid, but there is no margin for a late dlopen
//      and no way to reopen anything by path. A static binary has nothing to lose.
//
// So: no libdrm (KMS is driven through raw ioctls against the uapi headers, which is all libdrm
// does for the calls we make), no PNG decoder (the asset is pre-flattened to raw BGRA on the
// x86_64 build host), and no fontconfig (the font file path is passed in). The only library is
// stb_truetype.h, which is a header.
//
// Everything the program will ever need from the filesystem is read BEFORE the main loop, with
// the single exception of the status and takeover files.
//
// THOSE TWO ARE REACHED THROUGH A DIRECTORY FD, NEVER A PATH. An earlier version of this comment
// claimed "/run is moved into the new root, so those paths stay valid across the pivot" — which
// is true of the MOUNT and false of this process. switch_root chroots itself and its children
// and then deletes the old root's contents; a process forked before the pivot keeps that now
// empty root, so every path-based open() fails afterwards. On hardware that produced a splash
// that painted correctly, ticked forever, and never yielded the display, with nothing in any log.
// See the note above read_line_at() for the full account.
//
// Backends:
//   drm    KMS dumb buffer on a chosen connector. Holds DRM master for as long as it owns the
//          screen (masterless, the kernel's own fbdev console steals scanout on any fb write).
//   fbdev  /dev/fb0. The fallback for a device or a boot phase where KMS is unavailable.
//   ppm    Writes one frame to a file and exits. This is what makes the layout testable offline,
//          on the build host, at every panel geometry in the device registry — which matters a
//          great deal on a board with no serial console, where the alternative feedback loop is
//          "reflash the card and look at it".

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

// Vendored verbatim (stb_truetype.h v1.26, public domain, Sean Barrett). We use a handful of its
// entry points, so the rest are unused statics; that is expected for a single-header library and
// is not a signal worth keeping in the build output.
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb_truetype.h"
#pragma GCC diagnostic pop

// ============================================================================================
// Shared state
// ============================================================================================

// The canvas is always in LOGICAL orientation — the way the user holds the device. Rotation is
// applied once, at present time, when copying into the panel's scanout buffer. Keeping the
// compositing code rotation-free is what lets the ppm backend prove the layout without having to
// model any particular panel's mounting.
static uint32_t *canvas;        // SW*SH, 0xAARRGGBB
static int SW, SH;
static uint32_t bg = 0xFF000000u;

static volatile sig_atomic_t running = 1;
static void on_signal(int s) { (void)s; running = 0; }

// ONE write() per message, deliberately. In the initramfs this program's stderr is /dev/kmsg,
// where every write becomes its own kernel log record — so the obvious
// fprintf(prefix) + vfprintf(body) + fputc('\n') split one message into three records, and what
// landed in the journal was three EMPTY "novadeck-splash:" lines with the actual text lost.
// On a board with no serial console this program's own stderr is the entire debugging channel
// ([[sm8650-no-uart]]), so shredding it turns any failure here into a black screen with no
// account of itself.
static void note(const char *fmt, ...) {
    char buf[512];
    int n = snprintf(buf, sizeof buf, "novadeck-splash: ");
    va_list ap;
    va_start(ap, fmt);
    int m = vsnprintf(buf + n, sizeof buf - n - 1, fmt, ap);
    va_end(ap);
    if (m < 0) return;
    n += m;
    if (n > (int)sizeof buf - 2) n = (int)sizeof buf - 2;   // vsnprintf truncated; keep room for \n
    buf[n++] = '\n';
    ssize_t w = write(STDERR_FILENO, buf, (size_t)n);
    (void)w;
}

static void *xalloc(size_t n) {
    void *p = calloc(1, n);
    if (!p) { note("out of memory (%zu bytes)", n); exit(1); }
    return p;
}

// Read a whole file into memory. Used for the font and the logo, both of which MUST be resident
// before the main loop starts (see the header note about switch_root).
static void *slurp(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) || st.st_size <= 0) { close(fd); return NULL; }
    size_t n = (size_t)st.st_size;
    uint8_t *buf = malloc(n);
    if (!buf) { close(fd); return NULL; }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    if (got != n) { free(buf); return NULL; }
    if (len) *len = n;
    return buf;
}

// ============================================================================================
// Asset: the "NDS1" container
// ============================================================================================
//
// "NDS1" | u32 width LE | u32 height LE | width*height*4 bytes BGRA, straight (not premultiplied).
//
// A raw container rather than PNG because decoding PNG here would mean either linking zlib (a
// dynamic dependency, see the header) or vendoring a decoder, to save a few hundred KB on an
// asset that is generated by our own build. image/mksplash.sh writes it from the SVG using
// host-native rsvg-convert, so nothing about the logo is cross-compiled or decoded on device.

static uint32_t *logo_src;          // as loaded, straight BGRA -> ARGB
static int logo_src_w, logo_src_h;
static uint32_t *logo;              // scaled to the panel
static int logo_w, logo_h;

static int load_logo(const char *path) {
    size_t n = 0;
    uint8_t *raw = slurp(path, &n);
    if (!raw) { note("cannot read logo %s: %s", path, strerror(errno)); return 0; }
    if (n < 12 || memcmp(raw, "NDS1", 4)) {
        note("%s is not an NDS1 asset", path);
        free(raw);
        return 0;
    }
    uint32_t w, h;
    memcpy(&w, raw + 4, 4);
    memcpy(&h, raw + 8, 4);
    // Guard the multiply before trusting it: a truncated or corrupt asset must fail loudly here
    // rather than by walking off the end of the buffer three frames into boot.
    if (!w || !h || w > 8192 || h > 8192 || n != 12 + (size_t)w * h * 4) {
        note("%s has a bad NDS1 header (%ux%u, %zu bytes)", path, w, h, n);
        free(raw);
        return 0;
    }
    logo_src_w = (int)w;
    logo_src_h = (int)h;
    logo_src = xalloc((size_t)w * h * 4);
    const uint8_t *p = raw + 12;
    for (size_t i = 0; i < (size_t)w * h; i++, p += 4)
        logo_src[i] = ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
    free(raw);
    return 1;
}

// Box-filter downscale. The asset is rendered at the largest short edge in the device registry
// and only ever scaled DOWN, so this never has to interpolate upwards — a nearest-neighbour
// upscale of a logo with thin highlights looks obviously wrong, and a box filter of a downscale
// looks right, which is the whole reason the asset is oversized.
static void scale_logo(int target) {
    if (!logo_src) return;
    int ref = logo_src_w > logo_src_h ? logo_src_w : logo_src_h;
    if (target < 1) target = 1;
    // Upscaling is not an error, but it does mean the asset was rendered too small for this
    // panel and the logo will look soft — which nobody will report as a bug, they will just
    // think the splash looks cheap. Say so loudly enough that tests/test-splash.sh can fail on
    // it across the whole device registry, where it is cheap to catch.
    if (target > ref)
        note("logo upscaled %d -> %d; raise RENDER_PX in image/mksplash.sh", ref, target);
    int nw = (int)((int64_t)logo_src_w * target / ref);
    int nh = (int)((int64_t)logo_src_h * target / ref);
    if (nw < 1) nw = 1;
    if (nh < 1) nh = 1;
    free(logo);
    logo = xalloc((size_t)nw * nh * 4);
    logo_w = nw;
    logo_h = nh;
    for (int y = 0; y < nh; y++) {
        int sy0 = (int)((int64_t)y * logo_src_h / nh);
        int sy1 = (int)((int64_t)(y + 1) * logo_src_h / nh);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        for (int x = 0; x < nw; x++) {
            int sx0 = (int)((int64_t)x * logo_src_w / nw);
            int sx1 = (int)((int64_t)(x + 1) * logo_src_w / nw);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            uint64_t a = 0, r = 0, g = 0, b = 0, n = 0;
            for (int sy = sy0; sy < sy1 && sy < logo_src_h; sy++)
                for (int sx = sx0; sx < sx1 && sx < logo_src_w; sx++) {
                    uint32_t c = logo_src[sy * logo_src_w + sx];
                    uint32_t ca = c >> 24;
                    // Weight colour by alpha so transparent pixels do not drag the edges of the
                    // glow toward black.
                    a += ca;
                    r += ((c >> 16) & 0xFF) * ca;
                    g += ((c >> 8) & 0xFF) * ca;
                    b += (c & 0xFF) * ca;
                    n++;
                }
            if (!n) { logo[y * nw + x] = 0; continue; }
            uint32_t oa = (uint32_t)(a / n);
            uint32_t orr = a ? (uint32_t)(r / a) : 0;
            uint32_t og = a ? (uint32_t)(g / a) : 0;
            uint32_t ob = a ? (uint32_t)(b / a) : 0;
            logo[y * nw + x] = (oa << 24) | (orr << 16) | (og << 8) | ob;
        }
    }
}

// ============================================================================================
// Text
// ============================================================================================

static stbtt_fontinfo font;
static uint8_t *font_data;
static int font_ok;
static float font_scale;
static int font_ascent, font_descent, font_linegap;
static int text_px;

static int load_font(const char *path, int px) {
    size_t n = 0;
    font_data = slurp(path, &n);
    if (!font_data) { note("cannot read font %s: %s", path, strerror(errno)); return 0; }
    if (!stbtt_InitFont(&font, font_data, stbtt_GetFontOffsetForIndex(font_data, 0))) {
        note("%s is not a usable TrueType font", path);
        free(font_data);
        font_data = NULL;
        return 0;
    }
    text_px = px;
    font_scale = stbtt_ScaleForPixelHeight(&font, (float)px);
    stbtt_GetFontVMetrics(&font, &font_ascent, &font_descent, &font_linegap);
    font_ok = 1;
    return 1;
}

// Minimal UTF-8 decode. Status lines come from our own scripts, but "our own scripts" includes
// text forwarded verbatim out of the Steam bootstrapper, so this has to not fall over on a
// multi-byte sequence. Malformed input degrades to U+FFFD rather than desynchronising.
static int utf8_next(const char *s, int *i) {
    unsigned char c = (unsigned char)s[*i];
    if (c < 0x80) { (*i)++; return c; }
    int extra, cp;
    if ((c & 0xE0) == 0xC0) { extra = 1; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { extra = 2; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { extra = 3; cp = c & 0x07; }
    else { (*i)++; return 0xFFFD; }
    for (int k = 1; k <= extra; k++) {
        unsigned char cc = (unsigned char)s[*i + k];
        if ((cc & 0xC0) != 0x80) { (*i)++; return 0xFFFD; }
        cp = (cp << 6) | (cc & 0x3F);
    }
    *i += extra + 1;
    return cp;
}

static int text_width(const char *s, int len) {
    if (!font_ok) return 0;
    float w = 0;
    int i = 0, prev = 0;
    while (i < len) {
        int start = i;
        int cp = utf8_next(s, &i);
        if (i > len) { i = start; break; }
        int adv, lsb;
        stbtt_GetCodepointHMetrics(&font, cp, &adv, &lsb);
        if (prev) w += stbtt_GetCodepointKernAdvance(&font, prev, cp) * font_scale;
        w += adv * font_scale;
        prev = cp;
    }
    return (int)(w + 0.5f);
}

static void blend_px(int x, int y, uint32_t rgb, int cov) {
    if (cov <= 0 || x < 0 || y < 0 || x >= SW || y >= SH) return;
    if (cov > 255) cov = 255;
    uint32_t d = canvas[y * SW + x];
    uint32_t dr = (d >> 16) & 0xFF, dg = (d >> 8) & 0xFF, db = d & 0xFF;
    uint32_t sr = (rgb >> 16) & 0xFF, sg = (rgb >> 8) & 0xFF, sb = rgb & 0xFF;
    uint32_t r = (sr * (uint32_t)cov + dr * (255 - (uint32_t)cov)) / 255;
    uint32_t g = (sg * (uint32_t)cov + dg * (255 - (uint32_t)cov)) / 255;
    uint32_t b = (sb * (uint32_t)cov + db * (255 - (uint32_t)cov)) / 255;
    canvas[y * SW + x] = 0xFF000000u | (r << 16) | (g << 8) | b;
}

// Draw one line centred horizontally, with `baseline` in canvas coordinates.
static void draw_line(const char *s, int len, int baseline, uint32_t rgb) {
    if (!font_ok || len <= 0) return;
    float x = (float)(SW - text_width(s, len)) / 2.0f;
    int i = 0, prev = 0;
    while (i < len) {
        int start = i;
        int cp = utf8_next(s, &i);
        if (i > len) { i = start; break; }
        if (prev) x += stbtt_GetCodepointKernAdvance(&font, prev, cp) * font_scale;
        int gx0, gy0, gx1, gy1;
        int ix = (int)x;
        float frac = x - (float)ix;
        stbtt_GetCodepointBitmapBoxSubpixel(&font, cp, font_scale, font_scale, frac, 0,
                                            &gx0, &gy0, &gx1, &gy1);
        int gw = gx1 - gx0, gh = gy1 - gy0;
        if (gw > 0 && gh > 0) {
            uint8_t *bmp = malloc((size_t)gw * gh);
            if (bmp) {
                stbtt_MakeCodepointBitmapSubpixel(&font, bmp, gw, gh, gw, font_scale, font_scale,
                                                  frac, 0, cp);
                for (int yy = 0; yy < gh; yy++)
                    for (int xx = 0; xx < gw; xx++)
                        blend_px(ix + gx0 + xx, baseline + gy0 + yy, rgb, bmp[yy * gw + xx]);
                free(bmp);
            }
        }
        int adv, lsb;
        stbtt_GetCodepointHMetrics(&font, cp, &adv, &lsb);
        x += adv * font_scale;
        prev = cp;
    }
}

// ============================================================================================
// Compositing
// ============================================================================================

#define MAX_LINES 6

static int logo_px_req, text_px_req, gap_req;
static uint32_t fg = 0xFFE8EEF2u;   // near-white, matches the logo's cool cast
static uint32_t err_fg = 0xFFFF5C5Cu;

// Sizes are derived from the SHORT axis so that text is the same physical height whether the
// canvas is portrait or landscape. The ratios are against a 1080px reference.
static int auto_logo_px(int ref) { return ref * 360 / 1080; }
static int auto_text_px(int ref) { return ref * 44 / 1080; }
static int auto_gap_px(int ref)  { return ref * 56 / 1080; }

// Greedy word wrap. Returns the number of lines, with each line's [start,len) in `off`/`len`.
static int wrap(const char *s, int maxw, int *off, int *len) {
    int n = 0, i = 0, slen = (int)strlen(s);
    while (i < slen && n < MAX_LINES) {
        int line_start = i, last_break = -1, cut = -1;
        while (i <= slen) {
            if (i == slen || s[i] == ' ') {
                if (text_width(s + line_start, i - line_start) <= maxw) {
                    last_break = i;
                } else if (last_break < 0) {
                    // A single word wider than the canvas: hard-cut it rather than overflow.
                    cut = line_start;
                    while (cut < i && text_width(s + line_start, cut + 1 - line_start) <= maxw) cut++;
                    if (cut == line_start) cut = line_start + 1;
                    last_break = cut;
                    break;
                } else {
                    break;
                }
                if (i == slen) break;
            }
            i++;
        }
        if (last_break < 0) last_break = slen;
        off[n] = line_start;
        len[n] = last_break - line_start;
        n++;
        i = last_break;
        while (i < slen && s[i] == ' ') i++;
    }
    return n;
}

// Paint the whole canvas for a given status string. Called only when the status actually
// changes, which is what keeps the DRM path down to one commit per state change.
static void compose(const char *status) {
    for (int i = 0; i < SW * SH; i++) canvas[i] = bg;

    int ref = SW < SH ? SW : SH;
    int gap = gap_req > 0 ? gap_req : auto_gap_px(ref);

    // A leading '!' marks an error line; it is a marker, not content, so it is stripped before
    // measuring or drawing.
    int is_err = status[0] == '!';
    const char *msg = status + (is_err ? 1 : 0);
    uint32_t colour = is_err ? err_fg : fg;

    int off[MAX_LINES], len[MAX_LINES], nlines = 0;
    int line_h = 0;
    if (font_ok && *msg) {
        nlines = wrap(msg, SW * 82 / 100, off, len);
        line_h = (int)((font_ascent - font_descent + font_linegap) * font_scale + 0.5f);
    }

    int text_block = nlines ? nlines * line_h : 0;
    int total = logo_h + (text_block ? gap + text_block : 0);
    int top = (SH - total) / 2;
    if (top < 0) top = 0;

    // Logo, centred, straight alpha over the background.
    if (logo) {
        int lx0 = (SW - logo_w) / 2;
        for (int y = 0; y < logo_h; y++) {
            int dy = top + y;
            if (dy < 0 || dy >= SH) continue;
            for (int x = 0; x < logo_w; x++) {
                uint32_t c = logo[y * logo_w + x];
                blend_px(lx0 + x, dy, c & 0x00FFFFFFu, (int)(c >> 24));
            }
        }
    }

    if (nlines) {
        int baseline = top + logo_h + gap + (int)(font_ascent * font_scale + 0.5f);
        for (int i = 0; i < nlines; i++)
            draw_line(msg + off[i], len[i], baseline + i * line_h, colour);
    }
}

// ============================================================================================
// Status file
// ============================================================================================
//
// One line, read fresh each tick. Writers replace the file by rename, so a reader either sees the
// whole old line or the whole new one — never half of either.

// THESE FILES ARE REACHED THROUGH A DIRECTORY FD, NEVER A PATH, AND THAT IS THE WHOLE POINT.
//
// This process is started from the initramfs and keeps running across switch_root. switch_root
// chroots ITSELF and its children (systemd) into the new root and then DELETES the old root's
// contents to free the memory. A process forked before the pivot keeps its old root directory —
// which is now an empty tree. So every path-based open() fails afterwards, silently: the drawer
// goes on ticking, the logo stays on screen because the framebuffer was already composed, and
// the status and takeover files simply read as empty forever. The splash never yields, gamescope
// never gets DRM master, and the panel is black for the rest of the session with nothing in any
// log to say why. Measured on hardware 2026-09-08.
//
// A directory fd does not go through the process's root at all. /run is a tmpfs that switch_root
// MOVES rather than recreates, so a dirfd opened on it before the pivot still names the same
// live directory afterwards, whatever the process's root looks like. openat() from there works
// in every phase — the pre-pivot drawer, the session, and the shutdown screens — so this is not
// a special case bolted on for the initramfs, it is just the correct way to hold the reference.
//
// (Same shape as the reason plymouth's client/daemon channel is an ABSTRACT unix socket: an
// identifier that survives the pivot because it never goes through the old root's paths.)

// Split a path into a dirfd on its parent plus the file's basename. Returns -1 when the parent
// cannot be opened, which the caller reports; a missing directory here is a real error, not a
// condition to paper over.
static int open_parent_dir(const char *path, char *name, size_t n) {
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    if (!*base) return -1;
    if (snprintf(name, n, "%s", base) >= (int)n) return -1;
    char dir[512];
    if (!slash) { snprintf(dir, sizeof dir, "."); }
    else if (slash == path) { snprintf(dir, sizeof dir, "/"); }
    else {
        size_t len = (size_t)(slash - path);
        if (len >= sizeof dir) return -1;
        memcpy(dir, path, len);
        dir[len] = 0;
    }
    return open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
}

static void read_line_at(int dirfd, const char *name, char *out, size_t n) {
    out[0] = 0;
    if (dirfd < 0 || !name) return;
    int fd = openat(dirfd, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t r = read(fd, out, n - 1);
    close(fd);
    if (r <= 0) { out[0] = 0; return; }
    out[r] = 0;
    char *nl = strchr(out, '\n');
    if (nl) *nl = 0;
}

// ============================================================================================
// VT
// ============================================================================================
//
// KD_GRAPHICS stops the kernel console painting text over the splash. It is restored on the way
// out unless we handed the display to a successor, which then owns the VT — restoring KD_TEXT in
// that case would let fbcon repaint over whatever the successor just put on screen.

static int vt_fd = -1;

static void vt_graphics(void) {
    vt_fd = open("/dev/tty0", O_RDWR | O_CLOEXEC);
    if (vt_fd < 0) return;
    // Hide the cursor and clear anything already buffered, so a later repaint draws blank rather
    // than stale console text.
    const char clear[] = "\033[?25l\033[H\033[2J\033[3J";
    ssize_t w = write(vt_fd, clear, sizeof clear - 1);
    (void)w;
    if (ioctl(vt_fd, KDSETMODE, KD_GRAPHICS)) note("KDSETMODE: %s", strerror(errno));
}

static void vt_restore(void) {
    if (vt_fd < 0) return;
    ioctl(vt_fd, KDSETMODE, KD_TEXT);
    close(vt_fd);
    vt_fd = -1;
}

// ============================================================================================
// fbdev backend
// ============================================================================================

static struct {
    int fd;
    uint8_t *map;
    size_t size;
    uint32_t w, h, pitch, bpp;
    struct fb_var_screeninfo var;
    int angle;
} fb = { .fd = -1 };

static int fb_open(const char *dev, int angle) {
    fb.fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fb.fd < 0) { note("open %s: %s", dev, strerror(errno)); return 0; }
    struct fb_fix_screeninfo fix;
    if (ioctl(fb.fd, FBIOGET_VSCREENINFO, &fb.var) || ioctl(fb.fd, FBIOGET_FSCREENINFO, &fix)) {
        note("fbdev ioctl: %s", strerror(errno));
        close(fb.fd);
        fb.fd = -1;
        return 0;
    }
    fb.w = fb.var.xres;
    fb.h = fb.var.yres;
    fb.pitch = fix.line_length;
    fb.bpp = fb.var.bits_per_pixel;
    fb.size = (size_t)fb.pitch * fb.h;
    fb.angle = angle;
    if (fb.bpp != 16 && fb.bpp != 32) {
        note("unsupported fbdev depth %u", fb.bpp);
        close(fb.fd);
        fb.fd = -1;
        return 0;
    }
    fb.map = mmap(NULL, fb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
    if (fb.map == MAP_FAILED) {
        note("mmap %s: %s", dev, strerror(errno));
        close(fb.fd);
        fb.fd = -1;
        fb.map = NULL;
        return 0;
    }
    SW = (angle == 90 || angle == 270) ? (int)fb.h : (int)fb.w;
    SH = (angle == 90 || angle == 270) ? (int)fb.w : (int)fb.h;
    return 1;
}

// Map an 8-bit channel into a field described by an fb_bitfield.
static inline uint32_t fb_chan(uint32_t v8, struct fb_bitfield f) {
    return ((v8 >> (8 - f.length)) << f.offset);
}

// Rotate a panel-space pixel back to canvas space. The four cases are the inverse of the
// DRM `panel orientation` property (see rotate_for_orientation).
static inline uint32_t sample(int px, int py, int pw, int ph, int angle) {
    int lx, ly;
    switch (angle) {
        case 90:  lx = py;              ly = pw - 1 - px;   break;
        case 180: lx = pw - 1 - px;     ly = ph - 1 - py;   break;
        case 270: lx = ph - 1 - py;     ly = px;            break;
        default:  lx = px;              ly = py;            break;
    }
    if (lx < 0 || ly < 0 || lx >= SW || ly >= SH) return 0xFF000000u;
    return canvas[ly * SW + lx];
}

static void fb_present(void) {
    if (!fb.map) return;
    for (uint32_t py = 0; py < fb.h; py++) {
        uint8_t *row = fb.map + (size_t)py * fb.pitch;
        for (uint32_t px = 0; px < fb.w; px++) {
            uint32_t c = sample((int)px, (int)py, (int)fb.w, (int)fb.h, fb.angle);
            uint32_t v = fb_chan((c >> 16) & 0xFF, fb.var.red)
                       | fb_chan((c >> 8) & 0xFF, fb.var.green)
                       | fb_chan(c & 0xFF, fb.var.blue);
            if (fb.bpp == 32) ((uint32_t *)row)[px] = v;
            else ((uint16_t *)row)[px] = (uint16_t)v;
        }
    }
}

// ============================================================================================
// DRM backend (raw ioctls — see the header for why there is no libdrm here)
// ============================================================================================

static struct {
    int fd;
    uint32_t conn_id, crtc_id, fb_id, handle;
    uint32_t w, h, pitch;
    uint64_t size;
    uint8_t *map;
    struct drm_mode_modeinfo mode;
    int angle;
    int crtc_on;
    int dirty_ok;
    int setcrtc_logged;
    uint32_t saved_crtc_fb;
} dr = { .fd = -1, .dirty_ok = 1 };

static const char *conn_type_name(uint32_t t) {
    switch (t) {
        case DRM_MODE_CONNECTOR_VGA:         return "VGA";
        case DRM_MODE_CONNECTOR_DVII:        return "DVI-I";
        case DRM_MODE_CONNECTOR_DVID:        return "DVI-D";
        case DRM_MODE_CONNECTOR_DVIA:        return "DVI-A";
        case DRM_MODE_CONNECTOR_Composite:   return "Composite";
        case DRM_MODE_CONNECTOR_SVIDEO:      return "SVIDEO";
        case DRM_MODE_CONNECTOR_LVDS:        return "LVDS";
        case DRM_MODE_CONNECTOR_Component:   return "Component";
        case DRM_MODE_CONNECTOR_9PinDIN:     return "DIN";
        case DRM_MODE_CONNECTOR_DisplayPort: return "DP";
        case DRM_MODE_CONNECTOR_HDMIA:       return "HDMI-A";
        case DRM_MODE_CONNECTOR_HDMIB:       return "HDMI-B";
        case DRM_MODE_CONNECTOR_TV:          return "TV";
        case DRM_MODE_CONNECTOR_eDP:         return "eDP";
        case DRM_MODE_CONNECTOR_VIRTUAL:     return "Virtual";
        case DRM_MODE_CONNECTOR_DSI:         return "DSI";
        case DRM_MODE_CONNECTOR_DPI:         return "DPI";
        case DRM_MODE_CONNECTOR_WRITEBACK:   return "Writeback";
        case DRM_MODE_CONNECTOR_SPI:         return "SPI";
        case DRM_MODE_CONNECTOR_USB:         return "USB";
        default:                             return "Unknown";
    }
}

// The DRM "panel orientation" enum says where the panel's edges sit relative to the device's
// casing; we need the rotation to APPLY to make content look upright to the user, which is the
// inverse. Reading this from the connector rather than a per-board config file means the fact
// lives in exactly one place — the panel's devicetree `rotation` property, which the kernel
// already translates into this enum — instead of being duplicated across every device conf.
static int rotate_for_orientation(uint64_t v) {
    switch (v) {
        case 1:  return 180;   // BOTTOM_UP
        case 2:  return 270;   // LEFT_UP:  panel's left edge is the casing's top
        case 3:  return 90;    // RIGHT_UP: panel's right edge is the casing's top
        default: return 0;     // NORMAL
    }
}

// Read the connector's "panel orientation" property. Returns -1 when the panel does not publish
// one, which is the signal to fall back to whatever the caller was told on the command line.
static int drm_panel_orientation(int fd, uint32_t conn_id) {
    struct drm_mode_get_connector c;
    memset(&c, 0, sizeof c);
    c.connector_id = conn_id;
    if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c) || !c.count_props) return -1;

    uint32_t nprops = c.count_props;
    uint32_t *ids = xalloc((size_t)nprops * sizeof *ids);
    uint64_t *vals = xalloc((size_t)nprops * sizeof *vals);
    memset(&c, 0, sizeof c);
    c.connector_id = conn_id;
    c.count_props = nprops;
    c.props_ptr = (uint64_t)(uintptr_t)ids;
    c.prop_values_ptr = (uint64_t)(uintptr_t)vals;
    int found = -1;
    if (!ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) {
        for (uint32_t i = 0; i < c.count_props && found < 0; i++) {
            struct drm_mode_get_property p;
            memset(&p, 0, sizeof p);
            p.prop_id = ids[i];
            if (ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &p)) continue;
            if (!strncmp(p.name, "panel orientation", sizeof p.name)) found = rotate_for_orientation(vals[i]);
        }
    }
    free(ids);
    free(vals);
    return found;
}

// Pick a CRTC for a connector: its current encoder's CRTC when it already has one, otherwise the
// first CRTC any of its encoders can drive.
static uint32_t drm_pick_crtc(int fd, struct drm_mode_get_connector *c, struct drm_mode_card_res *res,
                              uint32_t *crtc_ids) {
    struct drm_mode_get_encoder e;
    if (c->encoder_id) {
        memset(&e, 0, sizeof e);
        e.encoder_id = c->encoder_id;
        if (!ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e) && e.crtc_id) return e.crtc_id;
    }
    uint32_t nenc = c->count_encoders;
    if (!nenc) return 0;
    uint32_t *encs = xalloc((size_t)nenc * sizeof *encs);
    struct drm_mode_get_connector q;
    memset(&q, 0, sizeof q);
    q.connector_id = c->connector_id;
    q.count_encoders = nenc;
    q.encoders_ptr = (uint64_t)(uintptr_t)encs;
    uint32_t chosen = 0;
    if (!ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &q)) {
        for (uint32_t i = 0; i < q.count_encoders && !chosen; i++) {
            memset(&e, 0, sizeof e);
            e.encoder_id = encs[i];
            if (ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &e)) continue;
            for (uint32_t k = 0; k < res->count_crtcs; k++)
                if (e.possible_crtcs & (1u << k)) { chosen = crtc_ids[k]; break; }
        }
    }
    free(encs);
    return chosen;
}

// Open a card and set up a dumb-buffer framebuffer on the requested connector (or the first
// connected one). `angle` is the caller's rotation; when it is < 0 the panel's own orientation
// property decides.
static int drm_open(const char *card, const char *want, int angle) {
    dr.fd = open(card, O_RDWR | O_CLOEXEC);
    if (dr.fd < 0) { note("open %s: %s", card, strerror(errno)); return 0; }

    // Take master up front. Without it the kernel's fbdev emulation owns scanout and will
    // repaint the console over anything we put in the buffer.
    if (ioctl(dr.fd, DRM_IOCTL_SET_MASTER, 0))
        note("SET_MASTER on %s: %s (continuing)", card, strerror(errno));

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof res);
    if (ioctl(dr.fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) goto fail;
    if (!res.count_connectors || !res.count_crtcs) goto fail;

    uint32_t nconn = res.count_connectors, ncrtc = res.count_crtcs;
    uint32_t *conns = xalloc((size_t)nconn * sizeof *conns);
    uint32_t *crtcs = xalloc((size_t)ncrtc * sizeof *crtcs);
    memset(&res, 0, sizeof res);
    res.count_connectors = nconn;
    res.count_crtcs = ncrtc;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
    res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
    if (ioctl(dr.fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { free(conns); free(crtcs); goto fail; }

    int chosen = 0;
    for (uint32_t i = 0; i < res.count_connectors && !chosen; i++) {
        struct drm_mode_get_connector c;
        memset(&c, 0, sizeof c);
        c.connector_id = conns[i];
        if (ioctl(dr.fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) continue;
        if (c.connection != 1 || !c.count_modes) continue;   // 1 == connected

        char name[64];
        snprintf(name, sizeof name, "%s-%u", conn_type_name(c.connector_type), c.connector_type_id);
        if (want && *want && strcmp(want, name)) continue;

        uint32_t nmodes = c.count_modes;
        struct drm_mode_modeinfo *modes = xalloc((size_t)nmodes * sizeof *modes);
        struct drm_mode_get_connector full;
        memset(&full, 0, sizeof full);
        full.connector_id = conns[i];
        full.count_modes = nmodes;
        full.modes_ptr = (uint64_t)(uintptr_t)modes;
        if (ioctl(dr.fd, DRM_IOCTL_MODE_GETCONNECTOR, &full) || !full.count_modes) { free(modes); continue; }

        // Mode 0 is the driver's preferred mode; on a fixed internal panel it is the only one
        // that matters and is always the native timing.
        dr.mode = modes[0];
        free(modes);

        dr.conn_id = conns[i];
        dr.crtc_id = drm_pick_crtc(dr.fd, &full, &res, crtcs);
        if (!dr.crtc_id) { dr.conn_id = 0; continue; }
        chosen = 1;
        note("using connector %s (%ux%u@%u) crtc %u", name, dr.mode.hdisplay, dr.mode.vdisplay,
             dr.mode.vrefresh, dr.crtc_id);
    }
    free(conns);
    free(crtcs);
    if (!chosen) { note("no usable connector%s%s", want ? " matching " : "", want ? want : ""); goto fail; }

    if (angle < 0) {
        int o = drm_panel_orientation(dr.fd, dr.conn_id);
        angle = o < 0 ? 0 : o;
        note("panel orientation -> rotate %d", angle);
    }
    dr.angle = angle;
    dr.w = dr.mode.hdisplay;
    dr.h = dr.mode.vdisplay;

    struct drm_mode_create_dumb cd;
    memset(&cd, 0, sizeof cd);
    cd.width = dr.w;
    cd.height = dr.h;
    cd.bpp = 32;
    if (ioctl(dr.fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { note("CREATE_DUMB: %s", strerror(errno)); goto fail; }
    dr.handle = cd.handle;
    dr.pitch = cd.pitch;
    dr.size = cd.size;

    struct drm_mode_fb_cmd fbc;
    memset(&fbc, 0, sizeof fbc);
    fbc.width = dr.w;
    fbc.height = dr.h;
    fbc.pitch = dr.pitch;
    fbc.bpp = 32;
    fbc.depth = 24;
    fbc.handle = dr.handle;
    if (ioctl(dr.fd, DRM_IOCTL_MODE_ADDFB, &fbc)) { note("ADDFB: %s", strerror(errno)); goto fail; }
    dr.fb_id = fbc.fb_id;

    struct drm_mode_map_dumb md;
    memset(&md, 0, sizeof md);
    md.handle = dr.handle;
    if (ioctl(dr.fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) { note("MAP_DUMB: %s", strerror(errno)); goto fail; }
    dr.map = mmap(NULL, dr.size, PROT_READ | PROT_WRITE, MAP_SHARED, dr.fd, (off_t)md.offset);
    if (dr.map == MAP_FAILED) { note("mmap dumb: %s", strerror(errno)); dr.map = NULL; goto fail; }

    SW = (dr.angle == 90 || dr.angle == 270) ? (int)dr.h : (int)dr.w;
    SH = (dr.angle == 90 || dr.angle == 270) ? (int)dr.w : (int)dr.h;
    return 1;

fail:
    if (dr.fd >= 0) { close(dr.fd); dr.fd = -1; }
    return 0;
}

static void drm_present(void) {
    if (!dr.map) return;
    for (uint32_t py = 0; py < dr.h; py++) {
        uint32_t *row = (uint32_t *)(dr.map + (size_t)py * dr.pitch);
        for (uint32_t px = 0; px < dr.w; px++)
            row[px] = sample((int)px, (int)py, (int)dr.w, (int)dr.h, dr.angle);
    }

    if (!dr.crtc_on) {
        struct drm_mode_crtc set;
        memset(&set, 0, sizeof set);
        set.crtc_id = dr.crtc_id;
        set.fb_id = dr.fb_id;
        set.count_connectors = 1;
        set.set_connectors_ptr = (uint64_t)(uintptr_t)&dr.conn_id;
        set.mode = dr.mode;
        set.mode_valid = 1;
        // A predecessor may still hold master (or be in the middle of yielding it). Re-assert
        // rather than give up: this is retried every tick until it lands.
        ioctl(dr.fd, DRM_IOCTL_SET_MASTER, 0);
        if (ioctl(dr.fd, DRM_IOCTL_MODE_SETCRTC, &set)) {
            if (!dr.setcrtc_logged) {
                dr.setcrtc_logged = 1;
                note("SETCRTC: %s (retrying every tick)", strerror(errno));
            }
            return;
        }
        note("modeset ok: %ux%u on crtc %u (pid %d)", dr.w, dr.h, dr.crtc_id, (int)getpid());
        dr.crtc_on = 1;
        return;
    }

    // Command-mode DSI panels latch one frame per commit — writing the buffer alone never reaches
    // glass. DirtyFB is the cheap way to say "this changed"; where the driver does not implement
    // it, fall back to re-running the modeset, which always commits.
    if (dr.dirty_ok) {
        struct drm_mode_fb_dirty_cmd d;
        memset(&d, 0, sizeof d);
        d.fb_id = dr.fb_id;
        if (ioctl(dr.fd, DRM_IOCTL_MODE_DIRTYFB, &d)) {
            dr.dirty_ok = 0;
            note("DIRTYFB unsupported; re-committing per update");
        }
    }
    if (!dr.dirty_ok) {
        struct drm_mode_crtc set;
        memset(&set, 0, sizeof set);
        set.crtc_id = dr.crtc_id;
        set.fb_id = dr.fb_id;
        set.count_connectors = 1;
        set.set_connectors_ptr = (uint64_t)(uintptr_t)&dr.conn_id;
        set.mode = dr.mode;
        set.mode_valid = 1;
        ioctl(dr.fd, DRM_IOCTL_MODE_SETCRTC, &set);
    }
}

// Hand the display over. Dropping master is not enough on its own: closing our fd (and with it
// the framebuffer) while the CRTC is still scanning out of it produces a black panel, which is
// precisely the symptom that ended the previous splash attempt. So drop master, then wait until
// the CRTC provably names a DIFFERENT framebuffer before letting go. GETCRTC needs no master.
//
// The wait is bounded because an unbounded one turns "the successor crashed" into "the device
// hangs on a logo with no way out".
static void drm_yield(int timeout_ms) {
    if (dr.fd < 0 || !dr.crtc_on) return;
    if (ioctl(dr.fd, DRM_IOCTL_DROP_MASTER, 0)) note("DROP_MASTER: %s", strerror(errno));
    for (int waited = 0; waited < timeout_ms; waited += 100) {
        struct drm_mode_crtc c;
        memset(&c, 0, sizeof c);
        c.crtc_id = dr.crtc_id;
        // A failed query says nothing about what is on screen; only a readable CRTC naming
        // another framebuffer proves the handoff actually happened.
        if (!ioctl(dr.fd, DRM_IOCTL_MODE_GETCRTC, &c) && c.fb_id && c.fb_id != dr.fb_id) {
            note("display handed over (crtc %u now on fb %u)", dr.crtc_id, c.fb_id);
            return;
        }
        usleep(100000);
    }
    note("successor never took the display within %dms; releasing anyway", timeout_ms);
}

// ============================================================================================
// ppm backend — the offline render used by the test suite
// ============================================================================================

// Writes PANEL-space pixels, not canvas-space, sampling through exactly the same rotation the
// fbdev and DRM backends use. That is the whole point: rotation is the riskiest arithmetic in
// this program and the only place it can be checked cheaply is here, on the build host, against
// every geometry in the device registry. A ppm backend that dumped the canvas would test the
// layout and silently skip the part most likely to be wrong.
static int write_ppm(const char *path, int pw, int ph, int angle) {
    FILE *f = fopen(path, "wb");
    if (!f) { note("cannot write %s: %s", path, strerror(errno)); return 0; }
    fprintf(f, "P6\n%d %d\n255\n", pw, ph);
    for (int py = 0; py < ph; py++)
        for (int px = 0; px < pw; px++) {
            uint32_t c = sample(px, py, pw, ph, angle);
            uint8_t out[3] = { (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c };
            fwrite(out, 1, 3, f);
        }
    int ok = !ferror(f);
    fclose(f);
    return ok;
}

// ============================================================================================
// main
// ============================================================================================

static const char *arg(int argc, char **argv, const char *k, const char *def) {
    for (int i = 1; i < argc - 1; i++)
        if (!strcmp(argv[i], k)) return argv[i + 1];
    return def;
}

static int flag(int argc, char **argv, const char *k) {
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], k)) return 1;
    return 0;
}

static void usage(void) {
    fputs(
        "usage: novadeck-splash [options]\n"
        "  --backend drm|fbdev|ppm|null|auto  default auto (drm if a card is present, else fbdev)\n"
        "                                 null = run the control loop, present nowhere (tests)\n"
        "  --card PATH                    DRM device (default /dev/dri/card0)\n"
        "  --connector NAME               e.g. DSI-1; default is the first connected one\n"
        "  --fbdev PATH                   default /dev/fb0\n"
        "  --image PATH                   NDS1 logo asset\n"
        "  --font PATH                    TrueType font for the status line\n"
        "  --status PATH                  status file, re-read every tick\n"
        "  --takeover PATH                handover handshake file (drm only)\n"
        "  --rotate auto|0|90|180|270     default auto (the panel's own orientation property)\n"
        "  --bg 0xRRGGBB                  background colour\n"
        "  --logo-height PX / --text-height PX / --gap PX   layout overrides\n"
        "  --width N --height N           force the canvas size (ppm, or a forced fbdev size)\n"
        "  --out PATH                     ppm output (default /tmp/novadeck-splash.ppm)\n"
        "  --keep-vt                      do not put the console into graphics mode\n",
        stderr);
}

int main(int argc, char **argv) {
    if (flag(argc, argv, "--help") || flag(argc, argv, "-h")) { usage(); return 0; }

    const char *backend  = arg(argc, argv, "--backend", "auto");
    const char *card     = arg(argc, argv, "--card", "/dev/dri/card0");
    const char *connector= arg(argc, argv, "--connector", NULL);
    const char *fbdev    = arg(argc, argv, "--fbdev", "/dev/fb0");
    const char *image    = arg(argc, argv, "--image", NULL);
    const char *fontpath = arg(argc, argv, "--font", NULL);
    const char *status   = arg(argc, argv, "--status", NULL);
    const char *takeover = arg(argc, argv, "--takeover", NULL);
    const char *rotate   = arg(argc, argv, "--rotate", "auto");
    const char *bgs      = arg(argc, argv, "--bg", NULL);
    const char *out      = arg(argc, argv, "--out", "/tmp/novadeck-splash.ppm");
    int keep_vt          = flag(argc, argv, "--keep-vt");
    int req_w            = atoi(arg(argc, argv, "--width", "0"));
    int req_h            = atoi(arg(argc, argv, "--height", "0"));
    logo_px_req          = atoi(arg(argc, argv, "--logo-height", "0"));
    text_px_req          = atoi(arg(argc, argv, "--text-height", "0"));
    gap_req              = atoi(arg(argc, argv, "--gap", "0"));

    // -1 means "ask the panel", which is only answerable on the DRM path.
    int angle = -1;
    if (strcmp(rotate, "auto")) {
        angle = atoi(rotate);
        if (angle != 0 && angle != 90 && angle != 180 && angle != 270) {
            note("invalid --rotate %s", rotate);
            return 2;
        }
    }
    if (bgs) bg = 0xFF000000u | (uint32_t)(strtoul(bgs, NULL, 0) & 0xFFFFFFu);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    int use_ppm = !strcmp(backend, "ppm");
    int use_drm = !strcmp(backend, "drm");
    int use_fb  = !strcmp(backend, "fbdev");
    // `null` runs the full control loop -- status polling, the takeover handshake, the yield --
    // and presents nowhere. It exists because the loop is otherwise only reachable with a real
    // display, which is what let the switch_root path bug (see read_line_at) reach hardware
    // unseen. It is never selected by `auto`; a caller has to ask for it by name.
    int use_null = !strcmp(backend, "null");
    if (!use_ppm && !use_drm && !use_fb && !use_null) {          // auto
        if (!access(card, R_OK | W_OK)) use_drm = 1;
        else use_fb = 1;
    }

    // In ppm mode --width/--height are the PANEL's dimensions, exactly as the DRM backend would
    // report them, so a test can name a real panel from the device registry and get back what
    // that panel would scan out.
    int ppm_w = req_w > 0 ? req_w : 1920, ppm_h = req_h > 0 ? req_h : 1080;
    if (use_ppm) {
        if (angle < 0) angle = 0;
        SW = (angle == 90 || angle == 270) ? ppm_h : ppm_w;
        SH = (angle == 90 || angle == 270) ? ppm_w : ppm_h;
    } else if (use_null) {
        if (angle < 0) angle = 0;
        SW = ppm_w;
        SH = ppm_h;
        // Take the DRM control path: it is the one that owns the display and therefore the one
        // that has to honour the handshake. dr.fd stays -1, so drm_present and drm_yield both
        // short-circuit into no-ops, and crtc_on suppresses the modeset retry.
        use_drm = 1;
        dr.crtc_on = 1;
    } else if (use_drm) {
        if (!drm_open(card, connector, angle)) {
            note("DRM unavailable; falling back to %s", fbdev);
            use_drm = 0;
            use_fb = 1;
            if (angle < 0) angle = 0;
        }
    }
    if (use_fb) {
        if (angle < 0) angle = 0;
        if (!fb_open(fbdev, angle)) return 1;
    }
    if (!use_ppm && !use_null && !keep_vt) vt_graphics();

    canvas = xalloc((size_t)SW * SH * 4);

    // Everything below is loaded ONCE, before the loop, and never reopened — see the header.
    int ref = SW < SH ? SW : SH;
    if (fontpath && !load_font(fontpath, text_px_req > 0 ? text_px_req : auto_text_px(ref)))
        note("continuing without status text");
    if (image && load_logo(image))
        scale_logo(logo_px_req > 0 ? logo_px_req : auto_logo_px(ref));
    else if (image)
        note("continuing without a logo");

    // Resolve both runtime files to (dirfd, name) NOW, while our root still resolves paths --
    // see the long note on read_line_at() for why a path is useless to us after switch_root.
    int status_fd = -1, takeover_fd = -1;
    char status_name[128] = { 0 }, takeover_name[128] = { 0 };
    if (status) {
        status_fd = open_parent_dir(status, status_name, sizeof status_name);
        if (status_fd < 0) note("cannot open the directory holding %s: %s", status, strerror(errno));
    }
    if (takeover) {
        takeover_fd = open_parent_dir(takeover, takeover_name, sizeof takeover_name);
        if (takeover_fd < 0) note("cannot open the directory holding %s: %s", takeover, strerror(errno));
    }

    char cur[512] = { 0 }, shown[512] = { 0 };
    read_line_at(status_fd, status_name, cur, sizeof cur);
    compose(cur);
    memcpy(shown, cur, sizeof shown);

    if (use_ppm) return write_ppm(out, ppm_w, ppm_h, angle) ? 0 : 1;

    void (*present)(void) = use_drm ? drm_present : fb_present;
    present();

    // The takeover file is this process announcing "I own the display". A successor writes its
    // own name into it before stopping us; seeing a value that is not ours is the signal to yield
    // rather than die with the panel. Announcing BEFORE the loop means the window in which a
    // successor could write an unclaimed file is closed.
    char mine[32], tk[32];
    snprintf(mine, sizeof mine, "%d", (int)getpid());
    if (use_drm && takeover_fd >= 0) {
        int fd = openat(takeover_fd, takeover_name, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) { ssize_t w = write(fd, mine, strlen(mine)); (void)w; close(fd); }
        else note("cannot announce ownership in %s: %s", takeover, strerror(errno));
    }

    int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    struct itimerspec its = { { 0, 250000000 }, { 0, 250000000 } };
    timerfd_settime(tfd, 0, &its, NULL);

    int yielded = 0;
    while (running) {
        struct pollfd p = { tfd, POLLIN, 0 };
        if (poll(&p, 1, -1) < 0) { if (errno == EINTR) continue; break; }
        uint64_t ticks;
        ssize_t r = read(tfd, &ticks, sizeof ticks);
        (void)r;

        // Keep retrying the first modeset: on the initramfs path the DPU may still be binding.
        if (use_drm && !dr.crtc_on) present();

        if (use_drm && takeover_fd >= 0) {
            read_line_at(takeover_fd, takeover_name, tk, sizeof tk);
            if (tk[0] && strcmp(tk, mine)) { note("yielding display to '%s'", tk); yielded = 1; break; }
        }

        read_line_at(status_fd, status_name, cur, sizeof cur);
        if (strcmp(cur, shown)) {
            compose(cur);
            memcpy(shown, cur, sizeof shown);
            present();
        }
    }

    // SIGTERM can land between two takeover polls. The successor always announces itself before
    // stopping us, so one final read decides whether this is a handover or a shutdown. No
    // announcement means nobody is waiting for the display and we should just go.
    if (use_drm && takeover_fd >= 0 && !yielded) {
        read_line_at(takeover_fd, takeover_name, tk, sizeof tk);
        yielded = tk[0] && strcmp(tk, mine);
    }
    if (use_drm && yielded) drm_yield(60000);
    if (!yielded) vt_restore();
    return 0;
}
