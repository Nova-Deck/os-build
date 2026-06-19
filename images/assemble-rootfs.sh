#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 4.
#
# Builds the Btrfs root image RAUC writes to a slot: stages a base rootfs, injects
# the novadeck kernel + dtbs (from kernel/build.sh) and the extracted device firmware
# (from firmware/extract.sh), then bakes a single-subvolume Btrfs image with
# `mkfs.btrfs --rootdir` — no root, no loop mount.
#
# The image content is read-only by construction; the subvolume's ro *property* is
# set by RAUC at deploy time (needs a mount), so it is not applied here.
#
#   images/assemble-rootfs.sh <soc> <base-rootfs-dir>
#   BASE_ROOTFS=<dir> images/assemble-rootfs.sh <soc>
#
# Run inside the build image (needs btrfs-progs + rsync):
#   docker run --rm -v "$PWD":/src -w /src novadeck-kbuild images/assemble-rootfs.sh sm8650 /path/to/base
set -euo pipefail
shopt -s nullglob

SOC="${1:-sm8650}"
BASE="${2:-${BASE_ROOTFS:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$SOC"
FW="$ROOT/firmware/extracted/$SOC"
LFW="$ROOT/firmware/linux-fw/$SOC"
IMGDIR="$OUT/images"
IMG="$IMGDIR/rootfs.img"
SIZE="${ROOTFS_SIZE:-5G}"   # matches rootfs-a/-b in partition-table.txt; --shrink trims it

[ -n "$BASE" ]        || { echo "usage: assemble-rootfs.sh <soc> <base-rootfs-dir>" >&2; exit 2; }
[ -d "$BASE" ]        || { echo "no base rootfs dir: $BASE" >&2; exit 2; }
[ -f "$OUT/Image.gz" ] || { echo "no kernel: $OUT/Image.gz (run kernel/build.sh first)" >&2; exit 1; }
command -v mkfs.btrfs >/dev/null 2>&1 || { echo "mkfs.btrfs not found (run inside novadeck-kbuild)" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
echo "[novadeck] assembling $SOC read-only root (base=$BASE)"

# 1. base userspace (the Holo aarch64 preview rootfs)
if command -v rsync >/dev/null 2>&1; then rsync -aHAX --numeric-ids "$BASE"/ "$stage"/
else cp -a "$BASE"/. "$stage"/; fi

# 2. novadeck kernel + dtbs under /boot
install -Dm0644 "$OUT/Image.gz" "$stage/boot/Image.gz"
for dtb in "$OUT"/dtbs/*.dtb; do install -Dm0644 "$dtb" "$stage/boot/dtbs/$(basename "$dtb")"; done

# 2b. loadable kernel modules under /lib/modules (from kernel/build.sh modules_install).
# The =m drivers (e.g. handheld panels) live here; without them display won't probe.
MODROOT="$OUT/modroot"
if [ -d "$MODROOT/lib/modules" ]; then
  mkdir -p "$stage/lib"
  cp -a "$MODROOT/lib/modules" "$stage/lib/"
else
  echo "  (no staged modules at ${MODROOT#"$ROOT"/} — run kernel/build.sh; built-in drivers only)"
fi

# 3. extracted device firmware under /lib/firmware (paths are already /lib/firmware-relative)
if [ -d "$FW" ]; then
  while IFS= read -r f; do
    rel="${f#"$FW"/}"
    install -Dm0644 "$f" "$stage/lib/firmware/$rel"
  done < <(find "$FW" -type f ! -name sha256sums.txt 2>/dev/null)
else
  echo "  (no extracted firmware at ${FW#"$ROOT"/} — run firmware/extract.sh; continuing)"
fi

# 3b. open linux-firmware blobs (Adreno GPU, WCN7850 Wi-Fi/BT, Iris VPU) under
# /lib/firmware. The upstream base ships no /lib/firmware, so without this the GPU/BT/VPU
# firmware is absent at runtime. Staged by firmware/fetch-linux-fw.sh from the pin.
if [ -d "$LFW" ]; then
  while IFS= read -r f; do
    rel="${f#"$LFW"/}"
    install -Dm0644 "$f" "$stage/lib/firmware/$rel"
  done < <(find "$LFW" -type f 2>/dev/null)
else
  echo "  (no linux-firmware at ${LFW#"$ROOT"/} — run firmware/fetch-linux-fw.sh $SOC; GPU/BT/VPU firmware will be missing)"
fi

# 4. novadeck marker so the running system can identify the slot's provenance
mkdir -p "$stage/etc"
{ echo "NOVADECK_SOC=$SOC"; echo "NOVADECK_BUILD=$(date -u +%Y%m%dT%H%M%SZ)"; } >"$stage/etc/novadeck-release"

# 5. bake the Btrfs image (populate without mounting), then shrink to fit
mkdir -p "$IMGDIR"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.btrfs --rootdir "$stage" --shrink -L novadeck-root -f "$IMG" >/dev/null

echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h "$IMG" | cut -f1), from $(du -sh "$stage" | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
