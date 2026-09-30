#!/usr/bin/env bash
# mesa-android container half — runs INSIDE the pinned x86 Arch image (see build.sh /
# builder.pin). Expects: SNAPSHOT (Arch Archive date), PATCHES (mesa patch list, may be empty),
# ANDROID_API, NDK_VERSION, NDK_SHA256, HOST_UID/HOST_GID, the repo mounted at /repo.
set -euxo pipefail

: "${SNAPSHOT:?}" "${ANDROID_API:?}" "${NDK_VERSION:?}" "${NDK_SHA256:?}" "${HOST_UID:?}" "${HOST_GID:?}"
OUT=/repo/work/mesa-android/out

# HAND THE OUTPUT TREE BACK TO THE BUILD USER ON *ANY* EXIT, not just success. The gates below run
# AFTER `install`, so a gate that fires leaves a populated, root-owned out/ behind -- and the host
# half's `rm -rf "$WORKDIR/out"` on the next run then dies with "Permission denied" on every file,
# turning one honest gate failure into a build that cannot be retried without a container to clean
# up after it. Measured 2026-08-23, on the first failure this gate ever caught.
trap 'chown -R "$HOST_UID:$HOST_GID" /repo/work/mesa-android 2>/dev/null || true' EXIT

# Host build tools only — NOTHING from this container ends up in the payload, because the NDK
# below supplies the entire target toolchain and sysroot. The snapshot pin is here for a
# reproducible meson/ninja/python generation, not for any ABI reason (contrast mesa-x86, whose
# snapshot IS the guest's glibc generation).
echo "Server=https://archive.archlinux.org/repos/${SNAPSHOT}/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
pacman -Syyuu --noconfirm
pacman -S --noconfirm --needed \
  meson ninja python-mako python-yaml python-packaging python-ply \
  bison flex cmake glslang unzip

cd /tmp
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
curl --fail --location --retry 3 --remote-name "https://dl.google.com/android/repository/${NDK_ZIP}"
printf '%s  %s\n' "$NDK_SHA256" "$NDK_ZIP" | sha256sum --check --strict
unzip -q "$NDK_ZIP"

# The mesa source is whatever the HOST mesa builds, fetched through the one helper every mesa
# build shares: it reads the URL + sha256 out of packages/mesa/PKGBUILD, tries upstream, falls
# back to the verified mirror, and refuses anything that does not match the pinned hash. One
# source of truth; a host mesa bump is an Android mesa bump with nothing else to edit.
/repo/packages/mesa/fetch-source.sh /tmp
SOURCE_TARBALL="$(bash -c 'source /repo/packages/mesa/PKGBUILD >/dev/null 2>&1; echo "${source[0]##*/}"')"
: "${SOURCE_TARBALL:?packages/mesa/PKGBUILD yielded no source url}"

tar xf "$SOURCE_TARBALL"
cd "$(tar tf "$SOURCE_TARBALL" | head -1 | cut -d/ -f1)"

# Same patches, same order, as the host mesa build (declared in packages/mesa/source.pin).
for p in ${PATCHES:-}; do
  patch -p1 <"/repo/packages/mesa/patches/$p"
done

# The API level lands in the COMPILER TRIPLE as well as the meson option, and that is what makes
# the toolchain enforce the guest's SDK level for us: aarch64-linux-android<API>-clang links
# against the versioned bionic stubs for exactly that level, so a symbol the guest's libc does
# not export is a LINK error here rather than a "cannot locate symbol" at load time in Android.
TOOL="/tmp/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "${TOOL}/aarch64-linux-android${ANDROID_API}-clang" ] \
  || { echo "ERROR: mesa-android: the NDK ships no aarch64-linux-android${ANDROID_API} toolchain wrapper (android_api out of range for NDK ${NDK_VERSION}?)" >&2; exit 1; }

cat >/tmp/cross-android <<EOF
[binaries]
c = '${TOOL}/aarch64-linux-android${ANDROID_API}-clang'
cpp = '${TOOL}/aarch64-linux-android${ANDROID_API}-clang++'
ar = '${TOOL}/llvm-ar'
strip = '${TOOL}/llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'

[built-in options]
cpp_args = ['-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
cpp_link_args = ['-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# ZINK IS NOT OPTIONAL HERE, and this is the one place this recipe departs from the peer distro's
# equivalent. Lepton's liblepton/properties.sh sets `mesa.loader.driver.override=zink` alongside
# ro.hardware.egl=mesa, so GLES in the guest is zink-over-Turnip, not the freedreno gallium
# driver. A libgallium_dri.so built without zink loads and then fails to find the overridden
# driver — the same dark screen as shipping nothing. freedreno stays in for the case where the
# override is off (LEPTON_USE_QCOM_DRIVER, or a future Lepton that drops it).
#
# -Dgbm-backends-path is baked in at build time and its default (/usr/local/lib/gbm) does not
# exist in Android; gralloc then fails to initialise. It must name the vendor libdir the payload
# is mounted at.
#
# LIBDRM IS LINKED STATICALLY, and that is a deliberate choice over the two alternatives. Android
# ships no platform libdrm, so -Dallow-fallback-for=libdrm builds it as a meson subproject; left
# at its default that subproject is a SHARED library, and mesa's objects come out with a dangling
# NEEDED on libdrm.so that nothing in the payload provides. (The peer distro's recipe has exactly
# this gap -- same fallback flag, no libdrm installed -- it just has no closure gate to notice.)
#
# The obvious fix, shipping our libdrm.so alongside the drivers, is the WORST of the three:
# Lepton bind-mounts our files over the guest's one by one, so a /vendor/lib64/libdrm.so of ours
# SHADOWS the guest's -- and the guest's own gralloc.minigbm_msm.so links libdrm as well. We would
# be swapping the DRM library out from under a component we do not build and cannot test here.
#
# Widening the gate to call libdrm guest-provided was the other option, and it rests on an
# assumption about Lepton's rootfs that nothing in this build can check. Static linking deletes
# the question: no NEEDED, no shadowing, nothing to assume. The cost is that libgallium_dri.so and
# libEGL_mesa.so each carry their own copy -- acceptable because libdrm is a thin ioctl wrapper
# whose state is per-fd, and buffers cross to the guest's gralloc as fds and handles, never as
# shared libdrm globals.
meson setup build-android \
  --cross-file /tmp/cross-android \
  --buildtype release \
  -Db_ndebug=true \
  -Dplatforms=android \
  -Dplatform-sdk-version="${ANDROID_API}" \
  -Dandroid-stub=true \
  -Dandroid-libbacktrace=disabled \
  -Dgallium-drivers=freedreno,zink \
  -Dvulkan-drivers=freedreno \
  -Dfreedreno-kmds=msm \
  -Degl=enabled \
  -Dgbm=enabled \
  -Dgbm-backends-path=/vendor/lib64 \
  -Dllvm=disabled \
  -Dallow-fallback-for=libdrm \
  -Dlibdrm:default_library=static

ninja -C build-android

# Android's EGL and Vulkan loaders match on FILENAME, not soname: libEGL_${ro.hardware.egl}.so
# and hw/vulkan.${ro.hardware.vulkan}.so. So the install step renames rather than symlinks.
B=build-android
install -Dm0644 "$B/src/freedreno/vulkan/libvulkan_freedreno.so" "$OUT/vendor/lib64/hw/vulkan.freedreno.so"
install -Dm0644 "$B/src/gallium/targets/dri/libgallium_dri.so"    "$OUT/vendor/lib64/libgallium_dri.so"
install -Dm0644 "$B/src/gbm/libgbm_mesa.so"                       "$OUT/vendor/lib64/libgbm_mesa.so"
install -Dm0644 "$B/src/gbm/backends/dri/dri_gbm.so"              "$OUT/vendor/lib64/dri_gbm.so"
install -Dm0644 "$B/src/egl/libEGL.so"                            "$OUT/vendor/lib64/egl/libEGL_mesa.so"
install -Dm0644 "$B/src/mesa/glapi/es2api/libGLESv2.so"           "$OUT/vendor/lib64/egl/libGLESv2_mesa.so"
install -Dm0644 "$B/src/mesa/glapi/es1api/libGLESv1_CM.so"        "$OUT/vendor/lib64/egl/libGLESv1_CM_mesa.so"

# ---------------------------------------------------------------------------------------------
# Gates. Everything below answers, at build time, a question that otherwise reaches a player as
# a black screen: the guest gives no useful diagnostic for a driver it cannot load, and the
# abort takes surfaceflinger with it, so there is nothing left to read a log off.

# 1. BIONIC, NOT GLIBC. This is the whole reason the package exists — the host packages/mesa
#    driver is glibc-linked and cannot load in an Android process. A payload that NEEDs libc.so.6
#    means the cross file was ignored and we just rebuilt the host driver under a new name.
for so in $(find "$OUT" -name '*.so'); do
  # Counting grep again -- readelf -h's output is small enough that -q has always survived here,
  # but that is the same reasoning that was wrong at the zink gate, so do not rely on it.
  [ "$(readelf -h "$so" | grep -c 'AArch64' || true)" -ge 1 ] \
    || { echo "ERROR: mesa-android: $so is not an AArch64 object" >&2; exit 1; }
  needed="$(readelf -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')"
  case "$needed" in
    *libc.so.6*|*ld-linux*)
      echo "ERROR: mesa-android: $so links glibc ($needed) -- it cannot load in the bionic guest" >&2
      exit 1 ;;
  esac
  # grep -c rather than -q, for the pipefail/SIGPIPE reason spelled out at the zink gate below.
  # This producer is a builtin writing a few bytes so it would almost certainly survive, but
  # "almost certainly" is how the other one looked too.
  [ "$(printf '%s\n' "$needed" | grep -cx 'libc.so' || true)" -ge 1 ] \
    || { echo "ERROR: mesa-android: $so does not link bionic libc.so; NEEDED = $needed" >&2; exit 1; }
done

# 2. NEEDED CLOSURE. Every DT_NEEDED must be satisfiable inside the guest. An unresolvable one is
#    not an error the loader reports usefully; it is a driver that silently never loads.
#
#    THREE things can satisfy it, and the third is not obvious. The NDK sysroot models the public
#    platform libraries at our API level, and the payload provides its own -- but mesa also links
#    against a handful of Android libraries that are NOT public NDK API (libhardware above all).
#    That is exactly what -Dandroid-stub=true is for: mesa builds STUB .so files to link against,
#    and the REAL ones come from the guest's /system/lib64 at runtime. Those cannot be checked
#    here and must not be treated as missing.
#
#    The allowlist is mesa's OWN list, not a guess: src/android_stub/meson.build names the libs it
#    stubs. Hardcoding it would rot silently the first time mesa adds one, so assert the two agree
#    and fail loudly on drift -- a new stub lib is a decision to make, not a check to widen.
STUB_MESON=src/android_stub/meson.build
[ -f "$STUB_MESON" ] || { echo "ERROR: mesa-android: $STUB_MESON is gone -- mesa restructured its android stubs; re-derive the platform-library allowlist" >&2; exit 1; }
stub_names="$(sed -n "s/^[[:space:]]*lib_names = \[\(.*\)\].*/\1/p" "$STUB_MESON" | tr -d "' " | tr ',' ' ')"
expected="hardware log nativewindow sync"
[ "$(echo $stub_names)" = "$expected" ] || {
  echo "ERROR: mesa-android: mesa's android stub list changed: got '$stub_names', expected '$expected'." >&2
  echo "       Each name is a library the GUEST must provide at runtime. Confirm the new one is" >&2
  echo "       present in Lepton's rootfs before widening this." >&2
  exit 1; }
PLATFORM_LIBS=""
for n in $stub_names; do PLATFORM_LIBS="$PLATFORM_LIBS lib${n}.so"; done

SYSROOT="${TOOL}/../sysroot/usr/lib/aarch64-linux-android"
for so in $(find "$OUT" -name '*.so'); do
  for need in $(readelf -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
    [ -e "${SYSROOT}/${ANDROID_API}/${need}" ] && continue
    [ -e "${SYSROOT}/${need}" ] && continue
    [ -n "$(find "$OUT" -name "$need" -print -quit)" ] && continue
    case " $PLATFORM_LIBS " in *" $need "*) continue ;; esac
    echo "ERROR: mesa-android: ${so#"$OUT"/} NEEDs $need, which is neither an Android platform library at API ${ANDROID_API}, nor stubbed by mesa for the guest to provide, nor shipped in the payload" >&2
    exit 1
  done
done

# 3. ZINK IS ACTUALLY IN THE MEGADRIVER. See the meson note above: Lepton overrides the loader to
#    zink, and a libgallium_dri.so that quietly lost it (a mesa option rename, a bump that moves
#    zink behind another flag) is a black screen with no other symptom.
#
#    NOT A SYMBOL CHECK, though that is the obvious instinct and it was the first thing tried here.
#    The megadriver exports NO driver-specific dynamic symbols at all -- zink_create_screen and
#    friends have internal linkage, the drivers are reached through an internal table, and the
#    342 dynamic symbols in the .so are essentially all libc imports. An `llvm-nm -D` gate on any
#    driver entry point therefore fails on a PERFECTLY GOOD build, which is exactly what it did.
#
#    So check the two things that are actually true of a real zink build: the driver got compiled
#    (its static archive exists in the build tree), and its NAME made it into the shipped
#    megadriver. That bare "zink" string IS the loader table's entry -- the literal name
#    mesa.loader.driver.override is matched against -- so its presence is the same fact the guest
#    will rely on at runtime, rather than a proxy for it.
[ -f "$B/src/gallium/drivers/zink/libzink.a" ] \
  || { echo "ERROR: mesa-android: zink was not compiled (no libzink.a) despite -Dgallium-drivers naming it" >&2; exit 1; }
#
#    `grep -c`, NOT `grep -q`, AND THAT IS LOAD-BEARING. This script runs under `set -o pipefail`.
#    `grep -q` exits the instant it matches, `strings` on a 26 MB object then dies of SIGPIPE, and
#    pipefail propagates its 141 -- so the pipeline FAILS EXACTLY WHEN THE STRING IS PRESENT. It
#    cost a build to find, and it read as "zink is missing" while zink was demonstrably there.
#    A counting grep consumes the whole stream, so there is no early close and no signal.
zink_names="$(strings -a "$OUT/vendor/lib64/libgallium_dri.so" | grep -cx 'zink' || true)"
[ "$zink_names" -ge 1 ] \
  || { echo "ERROR: mesa-android: the shipped libgallium_dri.so carries no 'zink' loader-table entry -- Lepton sets mesa.loader.driver.override=zink and would find nothing" >&2; exit 1; }

