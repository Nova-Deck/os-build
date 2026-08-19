#!/usr/bin/env bash
# Build the x86_64 + i686 Turnip payload for the FEX guest rootfs (see builder.pin for why).
#
#   packages/mesa-x86/build.sh          # host side: cache check + docker run
#
# Runs container-build.sh in the pinned x86 Arch image (native on an x86_64 host — this is the
# one build here that does NOT cross-compile; CI runs it as its own native x86_64 job). Output
# is a plain payload tree:
#
#   work/mesa-x86/out/usr/lib/libvulkan_freedreno.so            x86_64 Turnip
#   work/mesa-x86/out/usr/lib32/libvulkan_freedreno.so          i686 Turnip
#   work/mesa-x86/out/usr/share/vulkan/icd.d/freedreno_icd.{x86_64,i686}.json
#   work/mesa-x86/out/usr/lib{,32}/libxcb-keysyms.so.1          see container-build.sh
#
# SELF-CACHING, like customize-base.sh: work/mesa-x86/.inputs.sha256 records the digest of the
# committed inputs; a matching marker with all artifacts present is a no-op. That marker check is
# pure host-side shell, which is what lets CI hand the payload to the arm64 image job as an
# artifact: the downloaded tree satisfies the check and the job never touches docker/qemu for it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKGDIR="$ROOT/packages/mesa-x86"
MESADIR="$ROOT/packages/mesa"
FEXPIN="$ROOT/packages/fex-rootfs/prebuilt.pin"
WORKDIR="$ROOT/work/mesa-x86"
MARKER="$WORKDIR/.inputs.sha256"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

IMAGE="$(pin_field "$PKGDIR/builder.pin" image)"
SNAPSHOT="$(pin_field "$PKGDIR/builder.pin" snapshot)"
: "${IMAGE:?builder.pin: missing image}"; : "${SNAPSHOT:?builder.pin: missing snapshot}"

# The snapshot pin and the guest rootfs pin are one decision (see builder.pin). Refuse drift
# loudly rather than building a driver against the wrong glibc generation.
ROOTFS_VER="$(pin_field "$FEXPIN" version)"
if [ "$SNAPSHOT" != "${ROOTFS_VER//-//}" ]; then
  echo "ERROR: mesa-x86 snapshot '$SNAPSHOT' does not match the fex-rootfs pin's version" >&2
  echo "       '$ROOTFS_VER' (expected snapshot '${ROOTFS_VER//-//}')." >&2
  echo "       Bump packages/mesa-x86/builder.pin (snapshot AND image) together with" >&2
  echo "       packages/fex-rootfs/prebuilt.pin." >&2
  exit 1
fi

# Patch list comes from the mesa source.pin, in declared order — the same list, in the same
# order, that build-overlay.sh applies to the host mesa. Missing files fail here, before docker.
PATCHES="$(pin_field "$MESADIR/source.pin" patches)"
for p in $PATCHES; do
  [ -f "$MESADIR/patches/$p" ] || { echo "ERROR: mesa-x86: missing patch $MESADIR/patches/$p (declared in packages/mesa/source.pin)" >&2; exit 1; }
done

# Input digest, inputhash.sh-style: committed inputs only, patches in declared order. The mesa
# PKGBUILD is in the list because it names the source tarball + sha; the fex-rootfs pin because
# the snapshot assertion above couples us to it.
inputs=("$PKGDIR/build.sh" "$PKGDIR/container-build.sh" "$PKGDIR/builder.pin"
        "$MESADIR/PKGBUILD" "$MESADIR/source.pin" "$FEXPIN")
for p in $PATCHES; do inputs+=("$MESADIR/patches/$p"); done
HASH="$(cat "${inputs[@]}" | sha256sum | cut -d' ' -f1)"

ARTIFACTS=(
  usr/lib/libvulkan_freedreno.so
  usr/lib32/libvulkan_freedreno.so
  usr/share/vulkan/icd.d/freedreno_icd.x86_64.json
  usr/share/vulkan/icd.d/freedreno_icd.i686.json
  usr/lib/libxcb-keysyms.so.1
  usr/lib32/libxcb-keysyms.so.1
)
complete() {
  local f
  for f in "${ARTIFACTS[@]}"; do [ -s "$WORKDIR/out/$f" ] || return 1; done
}

if [ "$(cat "$MARKER" 2>/dev/null)" = "$HASH" ] && complete; then
  echo "[novadeck] mesa-x86: cached (inputs unchanged)" >&2
  exit 0
fi

echo "[novadeck] mesa-x86: building in $IMAGE (snapshot $SNAPSHOT)" >&2
rm -rf "$WORKDIR/out" "$MARKER"
mkdir -p "$WORKDIR/out"

docker run --rm --platform linux/amd64 \
  -v "$ROOT":/repo \
  -e SNAPSHOT="$SNAPSHOT" \
  -e PATCHES="$PATCHES" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash /repo/packages/mesa-x86/container-build.sh

complete || { echo "ERROR: mesa-x86: container reported success but the payload is incomplete" >&2; exit 1; }
printf '%s\n' "$HASH" >"$MARKER"
echo "[novadeck] mesa-x86: built -> $WORKDIR/out" >&2
