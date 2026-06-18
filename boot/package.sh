#!/usr/bin/env bash
# novadeck boot-stage packager — Phase 5.
#
# Pluggable boot stage. Interface:  (kernel, DTB, initramfs, cmdline) -> artifact.
# Reads the staged kernel from out/<soc>/ (produced by kernel/build.sh) and emits
# one flashable artifact per board DTB via a selectable backend. Swapping backend
# changes only the artifact format — never the image content fed in.
#
# Backend resolution order:  $2 arg  >  $BOOT_BACKEND  >  device.yaml boot.backend
# >  android-bootimg.
#
#   boot/package.sh <soc> [backend]
#
# Run inside the build image (needs the backend's tooling, e.g. mkbootimg):
#   docker run --rm -v "$PWD":/src -w /src novadeck-kbuild boot/package.sh sm8650
set -euo pipefail
shopt -s nullglob

SOC="${1:-sm8650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$SOC"
DEV="$ROOT/devices/$SOC"
YAML="$DEV/device.yaml"

[ -f "$OUT/Image.gz" ] || { echo "no kernel: $OUT/Image.gz (run kernel/build.sh first)" >&2; exit 1; }
[ -d "$OUT/dtbs" ]     || { echo "no dtbs: $OUT/dtbs (run kernel/build.sh first)" >&2; exit 1; }

# Pull a top-level scalar from device.yaml (strips indentation, inline comment, quotes).
yaml_scalar() {
  [ -f "$YAML" ] || return 0
  sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$YAML" | head -1 \
    | sed 's/[[:space:]]*#.*//; s/^"//; s/"$//'
}

BACKEND="${2:-${BOOT_BACKEND:-$(yaml_scalar backend)}}"
BACKEND="${BACKEND:-android-bootimg}"
BACKEND_SH="$ROOT/boot/backends/$BACKEND.sh"
[ -f "$BACKEND_SH" ] || { echo "unknown boot backend '$BACKEND' (no $BACKEND_SH)" >&2; exit 2; }

CMDLINE_FILE="$DEV/cmdline"
CMDLINE=""
[ -f "$CMDLINE_FILE" ] && CMDLINE="$(tr -d '\n' <"$CMDLINE_FILE")"

# page_size: '4k' -> 4096 (mkbootimg and the bootloader want bytes).
PAGESIZE="$(yaml_scalar page_size)"; PAGESIZE="${PAGESIZE:-4k}"
case "$PAGESIZE" in *k|*K) PAGESIZE=$(( ${PAGESIZE%[kK]} * 1024 )) ;; esac

KERNEL="$OUT/Image.gz"
INITRAMFS="${INITRAMFS:-$OUT/initramfs.cpio.gz}"   # optional; supplied by Phase 4
BOOTDIR="$OUT/boot"; mkdir -p "$BOOTDIR"

echo "[novadeck] boot package: soc=$SOC backend=$BACKEND pagesize=$PAGESIZE"
[ -f "$INITRAMFS" ] || echo "  (no initramfs at ${INITRAMFS#"$ROOT"/} — packaging kernel+dtb only)"

# Backend contract: defines backend_package <kernel> <dtb> <cmdline> <pagesize> <initramfs> <out>
# shellcheck source=/dev/null
. "$BACKEND_SH"

n=0
for dtb in "$OUT"/dtbs/*.dtb; do
  board="$(basename "${dtb%.dtb}")"
  artifact="$BOOTDIR/${board}-boot.img"
  backend_package "$KERNEL" "$dtb" "$CMDLINE" "$PAGESIZE" "$INITRAMFS" "$artifact"
  echo "  ok   $board -> ${artifact#"$ROOT"/}"
  n=$((n + 1))
done

echo "Done. Packaged $n board artifact(s) in ${BOOTDIR#"$ROOT"/}/ via '$BACKEND'."
