#!/usr/bin/env bash
# Build the aarch64/bionic fossilize STUB vulkan layer for the Android guest (see builder.pin).
#
#   packages/fossilize-stub-android/build.sh     # host side: cache check + docker run
#
# Output is a plain payload tree, staged into the guestos slot by rootfs/assemble-rootfs.sh:
#
#   work/fossilize-stub-android/out/vendor/vulkan_layers/libVkLayer_fossilize.so
#
# SELF-CACHING, the same shape as mesa-x86 and mesa-android: work/.../.inputs.sha256 records the
# digest of the committed inputs, and a matching marker with the artifact present is a no-op. That
# check is pure host-side shell, which is what lets CI hand the payload to the arm64 image job as an
# artifact — the downloaded tree satisfies the check and the job never touches docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/fossilize-stub-android"
WORKDIR="$ROOT/work/fossilize-stub-android"
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

# Input digest over committed inputs only, inputhash.sh-style. layer.json is in the list because it
# is staged from this package and its library_path has to keep matching the .so we build.
inputs=("$PKGDIR/build.sh" "$PKGDIR/container-build.sh" "$PKGDIR/builder.pin"
        "$PKGDIR/layer.c" "$PKGDIR/layer.json")
HASH="$(cat "${inputs[@]}" | sha256sum | cut -d' ' -f1)"

ARTIFACT=vendor/vulkan_layers/libVkLayer_fossilize.so

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && [ -s "$WORKDIR/out/$ARTIFACT" ]; then
  echo "[novadeck] fossilize-stub-android: cached (inputs unchanged)" >&2
  exit 0
fi

echo "[novadeck] fossilize-stub-android: building in $IMAGE (NDK $NDK_VERSION, API $ANDROID_API)" >&2
rm -rf "$WORKDIR/out" "$MARKER"
mkdir -p "$WORKDIR/out"

docker run --rm --platform linux/amd64 \
  -v "$ROOT":/repo \
  -v "$WORKDIR/out":/out \
  -e SNAPSHOT="$SNAPSHOT" \
  -e ANDROID_API="$ANDROID_API" \
  -e NDK_VERSION="$NDK_VERSION" -e NDK_SHA256="$NDK_SHA256" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash /repo/packages/fossilize-stub-android/container-build.sh

[ -s "$WORKDIR/out/$ARTIFACT" ] \
  || { echo "ERROR: fossilize-stub-android: container reported success but $ARTIFACT is missing" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] fossilize-stub-android: built -> $WORKDIR/out" >&2
