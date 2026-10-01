#!/usr/bin/env bash
# Build the aarch64/bionic fossilize vulkan layer for the Android guest (see builder.pin).
#
#   packages/fossilize-android/build.sh     # host side: cache check + docker run
#
# Output is a plain payload tree, staged into the guestos slot by rootfs/assemble-rootfs.sh:
#
#   work/fossilize-android/out/vendor/vulkan_layers/libVkLayer_fossilize.so
#
# SELF-CACHING, the same shape as mesa-x86 and mesa-android: work/.../.inputs.sha256 records the
# digest of the committed inputs, and a matching marker with the artifact present is a no-op. That
# check is pure host-side shell, which is what lets CI hand the payload to the arm64 image job as an
# artifact — the downloaded tree satisfies the check and the job never touches docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/fossilize-android"
WORKDIR="$ROOT/work/fossilize-android"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

IMAGE="$(pin_field "$PKGDIR/builder.pin" image)"
SNAPSHOT="$(pin_field "$PKGDIR/builder.pin" snapshot)"
ANDROID_API="$(pin_field "$PKGDIR/builder.pin" android_api)"
NDK_VERSION="$(pin_field "$PKGDIR/builder.pin" ndk_version)"
NDK_SHA256="$(pin_field "$PKGDIR/builder.pin" ndk_sha256)"
FOSSILIZE_REPO="$(pin_field "$PKGDIR/builder.pin" fossilize_repo)"
FOSSILIZE_COMMIT="$(pin_field "$PKGDIR/builder.pin" fossilize_commit)"
: "${IMAGE:?builder.pin: missing image}"; : "${SNAPSHOT:?builder.pin: missing snapshot}"
: "${ANDROID_API:?builder.pin: missing android_api}"
: "${NDK_VERSION:?builder.pin: missing ndk_version}"; : "${NDK_SHA256:?builder.pin: missing ndk_sha256}"
: "${FOSSILIZE_REPO:?builder.pin: missing fossilize_repo}"
: "${FOSSILIZE_COMMIT:?builder.pin: missing fossilize_commit}"

# Input digest over committed inputs only, inputhash.sh-style. layer.json is in the list because it
# is staged from this package and its layer name has to keep matching the .so we build.
inputs=("$PKGDIR/build.sh" "$PKGDIR/container-build.sh" "$PKGDIR/builder.pin" "$PKGDIR/layer.json")
HASH="$(cat "${inputs[@]}" | sha256sum | cut -d' ' -f1)"

ARTIFACT=vendor/vulkan_layers/libVkLayer_fossilize.so

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && [ -s "$WORKDIR/out/$ARTIFACT" ]; then
  echo "[novadeck] fossilize-android: cached (inputs unchanged)" >&2
  exit 0
fi

echo "[novadeck] fossilize-android: building ${FOSSILIZE_COMMIT:0:12} in $IMAGE (NDK $NDK_VERSION, API $ANDROID_API)" >&2
rm -rf "$WORKDIR/out" "$MARKER"
mkdir -p "$WORKDIR/out"

docker run --rm --platform linux/amd64 \
  -v "$ROOT":/repo \
  -v "$WORKDIR/out":/out \
  -e SNAPSHOT="$SNAPSHOT" \
  -e ANDROID_API="$ANDROID_API" \
  -e NDK_VERSION="$NDK_VERSION" -e NDK_SHA256="$NDK_SHA256" \
  -e FOSSILIZE_REPO="$FOSSILIZE_REPO" -e FOSSILIZE_COMMIT="$FOSSILIZE_COMMIT" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash /repo/packages/fossilize-android/container-build.sh

[ -s "$WORKDIR/out/$ARTIFACT" ] \
  || { echo "ERROR: fossilize-android: container reported success but $ARTIFACT is missing" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] fossilize-android: built -> $WORKDIR/out" >&2
