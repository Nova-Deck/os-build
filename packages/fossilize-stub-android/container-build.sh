#!/usr/bin/env bash
# Container side of the fossilize stub layer build. Runs in the pinned x86 Arch image; env carries
# SNAPSHOT, ANDROID_API, NDK_VERSION, NDK_SHA256, HOST_UID/HOST_GID, the repo mounted at /repo.
#
# The whole target toolchain and sysroot come from Google's NDK, exactly as packages/mesa-android
# does — nothing from this container ends up in the payload. Google publishes NDK host binaries for
# linux-x86_64 ONLY, which is why this is an x86 job and not part of the arm64 build image.
#
# One translation unit, one clang invocation: the layer has no dependencies beyond the NDK's own
# vulkan headers, and vk_layer.h (which the NDK does not ship) is declared inline in layer.c.
set -euo pipefail
: "${SNAPSHOT:?}" "${ANDROID_API:?}" "${NDK_VERSION:?}" "${NDK_SHA256:?}" "${HOST_UID:?}" "${HOST_GID:?}"

# Hand /out back to the build user ON EVERY EXIT, not just success. The container runs as root, so
# anything it creates is root-owned; if a failing build leaves it that way, the host's own
# `rm -rf work/.../out` on the NEXT run fails with EPERM and the package can never rebuild without
# docker or sudo. Measured the first time this build failed to compile. The trap runs before the
# shell exits with the original status, so it does not mask a failure.
trap 'chown -R "${HOST_UID}:${HOST_GID}" /out 2>/dev/null || true' EXIT

pacman -Sy --noconfirm --needed curl unzip >/dev/null

cd /tmp
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
curl --fail --location --retry 3 --remote-name "https://dl.google.com/android/repository/${NDK_ZIP}"
printf '%s  %s\n' "$NDK_SHA256" "$NDK_ZIP" | sha256sum --check --strict
unzip -q "$NDK_ZIP"

# The API-versioned wrapper is what pins the guest's SDK level into the binary: it sets the target
# triple AND the sysroot's __ANDROID_API__, so a symbol newer than the guest cannot link by accident.
TOOL="/tmp/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="${TOOL}/aarch64-linux-android${ANDROID_API}-clang"
[ -x "$CC" ] \
  || { echo "ERROR: fossilize-stub-android: the NDK ships no aarch64-linux-android${ANDROID_API} toolchain wrapper (android_api out of range for NDK ${NDK_VERSION}?)" >&2; exit 1; }

OUT=/out/vendor/vulkan_layers
mkdir -p "$OUT"

# -Wl,--no-undefined: an unresolved symbol in a Vulkan layer is a load-time abort inside the app's
# process, where Android's loader reports nothing useful. Fail here instead, at build time.
# -fvisibility=hidden: only the VK_LAYER_EXPORT entry points leave the .so, so the loader cannot
# bind to an internal name by accident.
"$CC" -shared -fPIC -O2 -std=c11 \
      -fvisibility=hidden -Wall -Wextra -Werror \
      -Wl,--no-undefined -Wl,-soname,libVkLayer_fossilize.so \
      -o "$OUT/libVkLayer_fossilize.so" \
      /repo/packages/fossilize-stub-android/layer.c

# GATES. Each of these is a way the payload can be silently wrong on the device, where the only
# symptom is an app that dies with no diagnostic.
READELF="${TOOL}/llvm-readelf"

#  1. It must be an aarch64 shared object. A host-arch build would simply not load.
"$READELF" -h "$OUT/libVkLayer_fossilize.so" | grep -q 'AArch64' \
  || { echo "ERROR: the layer is not aarch64" >&2; exit 1; }

#  2. It must NOT link glibc. The guest is bionic; a glibc-linked .so cannot load there, which is
#     the same trap packages/mesa-android gates against.
if "$READELF" -d "$OUT/libVkLayer_fossilize.so" | grep -qE 'libc\.so\.6|ld-linux'; then
  echo "ERROR: the layer links glibc -- it can never load in the bionic guest" >&2; exit 1
fi

#  3. The loader entry point must be exported under its exact name, or the loader falls back to
#     legacy dlsym of vkGetInstanceProcAddr and, finding nothing, treats the layer as broken.
"$READELF" --dyn-syms "$OUT/libVkLayer_fossilize.so" \
  | grep -q 'vkNegotiateLoaderLayerInterfaceVersion' \
  || { echo "ERROR: vkNegotiateLoaderLayerInterfaceVersion is not exported" >&2; exit 1; }

chown -R "${HOST_UID}:${HOST_GID}" /out
echo "fossilize-stub-android: built $(stat -c %s "$OUT/libVkLayer_fossilize.so") bytes"
