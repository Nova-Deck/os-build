#!/usr/bin/env bash
# Build the aarch64/bionic Mesa payload for the Android guest (see builder.pin for why).
#
#   packages/mesa-android/build.sh      # host side: cache check + docker run
#
# Runs container-build.sh in the pinned x86 Arch image (Google publishes NDK host binaries for
# linux-x86_64 only, so this cross-compiles aarch64-android FROM x86_64 — it does not run in the
# arm64 build image the rest of the tree uses). Output is a plain payload tree:
#
#   work/mesa-android/out/vendor/lib64/hw/vulkan.freedreno.so     Turnip, as Android names it
#   work/mesa-android/out/vendor/lib64/egl/libEGL_mesa.so         the trio ro.hardware.egl=mesa
#   work/mesa-android/out/vendor/lib64/egl/libGLESv2_mesa.so        makes Android's loader open
#   work/mesa-android/out/vendor/lib64/egl/libGLESv1_CM_mesa.so
#   work/mesa-android/out/vendor/lib64/libgallium_dri.so          freedreno + zink gallium
#   work/mesa-android/out/vendor/lib64/libgbm_mesa.so             gbm, and its dri backend,
#   work/mesa-android/out/vendor/lib64/dri_gbm.so                   at the baked-in backends path
#
# SELF-CACHING, like mesa-x86 and customize-base.sh: work/mesa-android/.inputs.sha256 records the
# digest of the committed inputs; a matching marker with all artifacts present is a no-op. That
# marker check is pure host-side shell, which is what lets CI hand the payload to the arm64 image
# job as an artifact — the downloaded tree satisfies the check and the job never touches docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/mesa-android"
MESADIR="$ROOT/packages/mesa"
WORKDIR="$ROOT/work/mesa-android"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

IMAGE="$(pin_field "$PKGDIR/builder.pin" image)"
SNAPSHOT="$(pin_field "$PKGDIR/builder.pin" snapshot)"
ANDROID_API="$(pin_field "$PKGDIR/builder.pin" android_api)"
NDK_VERSION="$(pin_field "$PKGDIR/builder.pin" ndk_version)"
NDK_SHA256="$(pin_field "$PKGDIR/builder.pin" ndk_sha256)"
: "${IMAGE:?builder.pin: missing image}"; : "${SNAPSHOT:?builder.pin: missing snapshot}"
: "${ANDROID_API:?builder.pin: missing android_api}"
: "${NDK_VERSION:?builder.pin: missing ndk_version}"; : "${NDK_SHA256:?builder.pin: missing ndk_sha256}"

# Patch list comes from the mesa source.pin, in declared order — the same list, in the same
# order, that build-overlay.sh applies to the host mesa and mesa-x86 applies to the guest one.
# Missing files fail here, before docker.
PATCHES="$(pin_field "$MESADIR/source.pin" patches)"
for p in $PATCHES; do
  [ -f "$MESADIR/patches/$p" ] || { echo "ERROR: mesa-android: missing patch $MESADIR/patches/$p (declared in packages/mesa/source.pin)" >&2; exit 1; }
done

# Input digest, inputhash.sh-style: committed inputs only, patches in declared order. The mesa
# PKGBUILD is in the list because it names the source tarball + sha.
inputs=("$PKGDIR/build.sh" "$PKGDIR/container-build.sh" "$PKGDIR/builder.pin"
        "$MESADIR/PKGBUILD" "$MESADIR/source.pin")
for p in $PATCHES; do inputs+=("$MESADIR/patches/$p"); done
HASH="$(cat "${inputs[@]}" | sha256sum | cut -d' ' -f1)"

ARTIFACTS=(
  vendor/lib64/hw/vulkan.freedreno.so
  vendor/lib64/egl/libEGL_mesa.so
  vendor/lib64/egl/libGLESv2_mesa.so
  vendor/lib64/egl/libGLESv1_CM_mesa.so
  vendor/lib64/libgallium_dri.so
  vendor/lib64/libgbm_mesa.so
  vendor/lib64/dri_gbm.so
)
complete() {
  local f
  for f in "${ARTIFACTS[@]}"; do [ -s "$WORKDIR/out/$f" ] || return 1; done
}

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && complete; then
  echo "[novadeck] mesa-android: cached (inputs unchanged)" >&2
  exit 0
fi

echo "[novadeck] mesa-android: building in $IMAGE (NDK $NDK_VERSION, API $ANDROID_API)" >&2
rm -rf "$WORKDIR/out" "$MARKER"
mkdir -p "$WORKDIR/out"

docker run --rm --platform linux/amd64 \
  -v "$ROOT":/repo \
  -e SNAPSHOT="$SNAPSHOT" \
  -e PATCHES="$PATCHES" \
  -e ANDROID_API="$ANDROID_API" \
  -e NDK_VERSION="$NDK_VERSION" -e NDK_SHA256="$NDK_SHA256" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash /repo/packages/mesa-android/container-build.sh

complete || { echo "ERROR: mesa-android: container reported success but the payload is incomplete" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] mesa-android: built -> $WORKDIR/out" >&2
