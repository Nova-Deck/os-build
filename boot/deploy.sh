#!/usr/bin/env bash
# novadeck Phase 1 deploy — install a board boot image onto an ESP as /KERNEL.
#
# Targets the ROCKNIX custom ABL boot flow: ABL boots /EFI/BOOT/bootaa64.efi when
# present, else falls back to the ESP-root file `KERNEL`, an Android boot image.
# novadeck's android-bootimg artifact (kernel + embedded board DTB + cmdline) is
# exactly that — so deploy is a plain file copy: no fastboot, no partition flash.
# The ESP may live on SD or internal storage; mount it, then point this at it.
#
#   boot/deploy.sh <soc> <board> <esp-mountpoint>
#
# e.g. (host side, ESP already mounted):
#   boot/deploy.sh sm8650 sm8650-ayaneo-ps2 /run/media/$USER/NOVADECK-ESP
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOC="${1:-}"
BOARD="${2:-}"
ESP="${3:-}"
OUT="$ROOT/out/$SOC/boot"

[ -n "$SOC" ] && [ -n "$BOARD" ] && [ -n "$ESP" ] \
  || { echo "usage: boot/deploy.sh <soc> <board> <esp-mountpoint>" >&2; exit 2; }

IMG="$OUT/${BOARD}-boot.img"
if [ ! -f "$IMG" ]; then
  echo "no boot image: ${IMG#"$ROOT"/} (run boot/package.sh $SOC first)" >&2
  echo "available boards in ${OUT#"$ROOT"/}:" >&2
  for f in "$OUT"/*-boot.img; do echo "  - $(basename "${f%-boot.img}")" >&2; done
  exit 1
fi

[ -d "$ESP" ] || { echo "ESP mountpoint is not a directory: $ESP" >&2; exit 2; }
mountpoint -q "$ESP" 2>/dev/null \
  || echo "warning: $ESP is not a mountpoint — is the ESP actually mounted there?" >&2

# Atomic install: write a temp file on the ESP, fsync, then rename over KERNEL so a
# yanked card never leaves a half-written boot image.
DEST="$ESP/KERNEL"
TMP="$ESP/.KERNEL.tmp.$$"
trap 'rm -f "$TMP"' EXIT
echo "[novadeck] deploy $(basename "$IMG") -> $DEST"
cp "$IMG" "$TMP"
sync "$TMP" 2>/dev/null || sync
mv -f "$TMP" "$DEST"
sync "$ESP" 2>/dev/null || sync

echo "  ok   $(du -h "$DEST" | cut -f1) written. ABL boots it via the KERNEL fallback."
