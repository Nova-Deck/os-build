#!/usr/bin/env bash
# Build the x86_64 + i686 lsfg-vk layer payload for the FEX guest rootfs (see builder.pin for why).
#
#   packages/lsfg-vk-x86/build.sh      # host side: cache check + docker run
#
# Runs container-build.sh in the pinned x86 Arch image — native on an x86_64 host, the same
# arrangement as packages/mesa-x86. Output is a plain payload tree:
#
#   work/lsfg-vk-x86/out/usr/lib/liblsfg-vk-layer.so         x86_64 Vulkan layer
#   work/lsfg-vk-x86/out/usr/lib/liblsfg-vk-layer.x86.so     i686 Vulkan layer (in lib, ON PURPOSE)
#   work/lsfg-vk-x86/out/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation{,.x86}.json
#   work/lsfg-vk-x86/out/usr/bin/lsfg-vk-cli                 on-device diagnostic
#
# SELF-CACHING, like packages/mesa-x86/build.sh: work/lsfg-vk-x86/.inputs.sha256 records the digest
# of the committed inputs; a matching marker with every artifact present is a no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/lsfg-vk-x86"
HOSTPKG="$ROOT/packages/lsfg-vk"
FEXPIN="$ROOT/packages/fex-rootfs/prebuilt.pin"
WORKDIR="$ROOT/work/lsfg-vk-x86"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

IMAGE="$(pin_field "$PKGDIR/builder.pin" image)"
SNAPSHOT="$(pin_field "$PKGDIR/builder.pin" snapshot)"
: "${IMAGE:?builder.pin: missing image}"; : "${SNAPSHOT:?builder.pin: missing snapshot}"

# ONE upstream version for both arches. The tag comes from the HOST package's PKGBUILD rather than
# being repeated here, so the aarch64 layer and the x86 layer cannot drift to different releases --
# which would be invisible until a user with one kind of game saw different behaviour from a user
# with the other.
LSFG_TAG="$(sed -n 's/^_tag=//p' "$HOSTPKG/PKGBUILD" | head -1)"
: "${LSFG_TAG:?packages/lsfg-vk/PKGBUILD yielded no _tag}"

# The snapshot pin and the guest rootfs pin are one decision (builder.pin). Refuse drift loudly
# rather than building a layer against the wrong glibc generation: it would load here and fail
# inside the guest, where the only symptom is that frame generation quietly does nothing.
ROOTFS_VER="$(pin_field "$FEXPIN" version)"
if [ "$SNAPSHOT" != "${ROOTFS_VER//-//}" ]; then
  echo "ERROR: lsfg-vk-x86 snapshot '$SNAPSHOT' does not match the fex-rootfs pin's version" >&2
  echo "       '$ROOTFS_VER' (expected snapshot '${ROOTFS_VER//-//}')." >&2
  echo "       Bump packages/lsfg-vk-x86/builder.pin (snapshot AND image) together with" >&2
  echo "       packages/fex-rootfs/prebuilt.pin." >&2
  exit 1
fi

inputs=("$PKGDIR/build.sh" "$PKGDIR/container-build.sh" "$PKGDIR/builder.pin"
        "$HOSTPKG/PKGBUILD" "$FEXPIN")
HASH="$(cat "${inputs[@]}" | sha256sum | cut -d' ' -f1)"

ARTIFACTS=(
  usr/lib/liblsfg-vk-layer.so
  usr/lib/liblsfg-vk-layer.x86.so
  usr/bin/lsfg-vk-cli
  usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json
  usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.x86.json
)
complete() {
  local f
  for f in "${ARTIFACTS[@]}"; do [ -s "$WORKDIR/out/$f" ] || return 1; done
}

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && complete; then
  echo "[novadeck] lsfg-vk-x86: cached (inputs unchanged)" >&2
  exit 0
fi

echo "[novadeck] lsfg-vk-x86: building $LSFG_TAG in $IMAGE (snapshot $SNAPSHOT)" >&2
rm -rf "$WORKDIR/out" "$MARKER"
mkdir -p "$WORKDIR/out"

docker run --rm --platform linux/amd64 \
  -v "$ROOT":/repo \
  -e SNAPSHOT="$SNAPSHOT" \
  -e LSFG_TAG="$LSFG_TAG" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash /repo/packages/lsfg-vk-x86/container-build.sh

complete || { echo "ERROR: lsfg-vk-x86: container reported success but the payload is incomplete" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] lsfg-vk-x86: built -> $WORKDIR/out" >&2
