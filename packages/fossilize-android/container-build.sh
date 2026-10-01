#!/usr/bin/env bash
# Container side of the fossilize layer build. Runs in the pinned x86 Arch image; env carries
# SNAPSHOT, ANDROID_API, NDK_VERSION, NDK_SHA256, FOSSILIZE_REPO, FOSSILIZE_COMMIT,
# HOST_UID/HOST_GID, the repo mounted at /repo.
#
# The whole target toolchain and sysroot come from Google's NDK, exactly as packages/mesa-android
# does — nothing from this container ends up in the payload. Google publishes NDK host binaries for
# linux-x86_64 ONLY, which is why this is an x86 job and not part of the arm64 build image.
#
# The cmake invocation is upstream's android_build.sh, minus -DFOSSILIZE_LAYER_APK=ON: Lepton
# wants the bare .so in the slot, not an APK wrapping it.
set -euo pipefail
: "${SNAPSHOT:?}" "${ANDROID_API:?}" "${NDK_VERSION:?}" "${NDK_SHA256:?}" "${HOST_UID:?}" "${HOST_GID:?}"
: "${FOSSILIZE_REPO:?}" "${FOSSILIZE_COMMIT:?}"

# Hand /out back to the build user ON EVERY EXIT, not just success. The container runs as root, so
# anything it creates is root-owned; if a failing build leaves it that way, the host's own
# `rm -rf work/.../out` on the NEXT run fails with EPERM and the package can never rebuild without
# docker or sudo. The trap runs before the shell exits with the original status, so it does not
# mask a failure.
trap 'chown -R "${HOST_UID}:${HOST_GID}" /out 2>/dev/null || true' EXIT

pacman -Sy --noconfirm --needed curl unzip git cmake ninja >/dev/null

cd /tmp
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
curl --fail --location --retry 3 --remote-name "https://dl.google.com/android/repository/${NDK_ZIP}"
printf '%s  %s\n' "$NDK_SHA256" "$NDK_ZIP" | sha256sum --check --strict
unzip -q "$NDK_ZIP"
NDK="/tmp/android-ndk-${NDK_VERSION}"

# Fetch exactly the pinned commit, then only the rapidjson submodule: the rest (SPIRV-*, volk,
# dirent) feed the CLI, which is off.
git init -q fossilize
git -C fossilize remote add origin "$FOSSILIZE_REPO"
git -C fossilize fetch -q --depth 1 origin "$FOSSILIZE_COMMIT"
git -C fossilize checkout -q FETCH_HEAD
[ "$(git -C fossilize rev-parse HEAD)" = "$FOSSILIZE_COMMIT" ] \
  || { echo "ERROR: fossilize-android: fetched $(git -C fossilize rev-parse HEAD), pinned $FOSSILIZE_COMMIT" >&2; exit 1; }
git -C fossilize submodule update -q --init --depth 1 rapidjson

# ANDROID_PLATFORM pins the guest's SDK level into the binary, so a symbol newer than the guest
# cannot link by accident. c++_static keeps libc++_shared.so out of NEEDED: the guest has no copy
# in the vendor namespace this layer loads from.
cmake -S fossilize -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM="$ANDROID_API" \
  -DANDROID_STL=c++_static \
  -DANDROID_TOOLCHAIN=clang \
  -DANDROID_CPP_FEATURES=exceptions \
  -DANDROID_ARM_MODE=arm \
  -DCMAKE_BUILD_TYPE=Release \
  -DFOSSILIZE_VULKAN_LAYER=ON \
  -DFOSSILIZE_CLI=OFF \
  -DFOSSILIZE_TESTS=OFF
ninja -C build VkLayer_fossilize

SO="build/layer/libVkLayer_fossilize.so"
[ -s "$SO" ] || { echo "ERROR: fossilize-android: ninja succeeded but $SO is missing" >&2; exit 1; }

OUT=/out/vendor/vulkan_layers
mkdir -p "$OUT"
install -m0644 "$SO" "$OUT/libVkLayer_fossilize.so"
LAYER="$OUT/libVkLayer_fossilize.so"

# GATES. Each of these is a way the payload can be silently wrong on the device, where the only
# symptom is an app that dies with no diagnostic. Counting greps, not `grep -q`: under pipefail a
# `readelf | grep -q` fails EXACTLY when it matches, once grep exits early and readelf takes SIGPIPE.
READELF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
"$READELF" -h "$LAYER" >/tmp/elf-header
"$READELF" -d "$LAYER" >/tmp/elf-dynamic
"$READELF" --dyn-syms "$LAYER" >/tmp/elf-syms

#  1. It must be an aarch64 shared object. A host-arch build would simply not load.
[ "$(grep -c 'AArch64' /tmp/elf-header)" -ge 1 ] \
  || { echo "ERROR: the layer is not aarch64" >&2; exit 1; }

#  2. It must NOT link glibc (the guest is bionic) nor libc++_shared.so (not in the namespace).
if [ "$(grep -cE 'libc\.so\.6|ld-linux|libc\+\+_shared' /tmp/elf-dynamic)" -ne 0 ]; then
  echo "ERROR: the layer NEEDs a library the bionic guest cannot provide:" >&2
  grep NEEDED /tmp/elf-dynamic >&2
  exit 1
fi

#  3. Android's loader binds a layer by dlsym of these exact names (dispatch.cpp maps
#     VK_LAYER_fossilize_GetInstanceProcAddr onto vkGetInstanceProcAddr under ANDROID).
for sym in vkGetInstanceProcAddr vkGetDeviceProcAddr vkEnumerateInstanceLayerProperties \
           vkEnumerateDeviceExtensionProperties; do
  [ "$(grep -cw "$sym" /tmp/elf-syms)" -ge 1 ] \
    || { echo "ERROR: $sym is not exported -- Android's loader cannot bind the layer" >&2; exit 1; }
done

chown -R "${HOST_UID}:${HOST_GID}" /out
echo "fossilize-android: built ${FOSSILIZE_COMMIT:0:12}, $(stat -c %s "$LAYER") bytes"
