#!/usr/bin/env bash
# novadeck boot-stage packager — Phase 5.
#
# Pluggable boot stage. Interface:  (kernel, DTBs, initramfs, cmdline) -> artifact.
# Reads the staged unified kernel from out/ (produced by kernel/build.sh) and emits a
# single flashable artifact holding EVERY board DTB (all SoCs) via a selectable backend
# (ABL's DTB picker selects the board at boot). Swapping backend changes only the artifact
# format — never the image content fed in.
#
# Backend resolution order:  $1 arg  >  $BOOT_BACKEND  >  device.yaml boot.backend
# >  android-bootimg.
#
#   boot/package.sh [backend]
#
# Run inside the build image (needs the backend's tooling, e.g. mkbootimg):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"

[ -f "$OUT/Image.gz" ] || { echo "no kernel: $OUT/Image.gz (run kernel/build.sh first)" >&2; exit 1; }
[ -d "$OUT/dtbs" ]     || { echo "no dtbs: $OUT/dtbs (run kernel/build.sh first)" >&2; exit 1; }

# Boot backend + page size are platform-wide constants now the build is unified: page_size is
# 4k (REQUIRED for FEX-Emu) and android-bootimg is the default ABL artifact. Override with the
# $1 backend arg / $BOOT_BACKEND / $BOOT_PAGESIZE if a board ever needs otherwise.
BACKEND="${1:-${BOOT_BACKEND:-android-bootimg}}"
BACKEND_SH="$ROOT/boot/backends/$BACKEND.sh"
[ -f "$BACKEND_SH" ] || { echo "unknown boot backend '$BACKEND' (no $BACKEND_SH)" >&2; exit 2; }

# Common kernel cmdline; board-specific args live in each board's DTS /chosen/bootargs and
# ABL appends this common set to them at boot.
CMDLINE_FILE="$ROOT/boot/cmdline"
CMDLINE=""
[ -f "$CMDLINE_FILE" ] && CMDLINE="$(tr -d '\n' <"$CMDLINE_FILE")"

# page_size: '4k' -> 4096 (mkbootimg and the bootloader want bytes).
PAGESIZE="${BOOT_PAGESIZE:-4k}"
case "$PAGESIZE" in *k|*K) PAGESIZE=$(( ${PAGESIZE%[kK]} * 1024 )) ;; esac

KERNEL="$OUT/Image.gz"
INITRAMFS="${INITRAMFS:-$OUT/initramfs.cpio.gz}"   # optional; supplied by Phase 4
BOOTDIR="$OUT/boot"; mkdir -p "$BOOTDIR"

echo "[novadeck] boot package: backend=$BACKEND pagesize=$PAGESIZE"
[ -f "$INITRAMFS" ] || echo "  (no initramfs at ${INITRAMFS#"$ROOT"/} — packaging kernel+dtb only)"

# Backend contract: defines backend_package <kernel> <dtbdir> <cmdline> <pagesize> <initramfs> <out>
# shellcheck source=/dev/null
. "$BACKEND_SH"

# One unified artifact: the backend bundles every board DTB in out/dtbs/ (all SoCs) into it.
boards=()
for dtb in "$OUT"/dtbs/*.dtb; do boards+=( "$(basename "${dtb%.dtb}")" ); done
[ "${#boards[@]}" -gt 0 ] || { echo "no dtbs in ${OUT#"$ROOT"/}/dtbs (run kernel/build.sh)" >&2; exit 1; }

artifact="$BOOTDIR/novadeck-boot.img"
echo "  boards: ${boards[*]}"
backend_package "$KERNEL" "$OUT/dtbs" "$CMDLINE" "$PAGESIZE" "$INITRAMFS" "$artifact"

echo "  ok   ${#boards[@]} board DTB(s) -> ${artifact#"$ROOT"/}"
echo "Done. One '$BACKEND' image holds all boards; ABL's DTB picker selects at boot."
