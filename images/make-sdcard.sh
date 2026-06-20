#!/usr/bin/env bash
# novadeck SD-card image builder — Phase 1 on-device test path.
#
# Builds one flashable SD image with the minimal layout the ROCKNIX ABL needs to boot
# off a card: a GPT with an EFI System Partition (FAT32) holding the all-boards KERNEL
# boot image at its root, plus the read-only Btrfs root (label novadeck-root, which the
# kernel cmdline mounts). No A/B, no RAUC — that is the Phase 4 internal layout
# (images/partition-table.txt); this is the throwaway "boot it off an SD card first"
# image for bring-up.
#
# Unprivileged: builds the ESP filesystem in a plain file with mtools, lays the GPT with
# sgdisk, and dd's both filesystem images into their partition byte offsets — no loop
# mounts, no root.
#
#   images/make-sdcard.sh [soc]
#
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh sm8650
#
# Prereqs: boot/package.sh (-> out/<soc>/boot/<soc>-boot.img) and images/build-image.sh
# (-> out/<soc>/images/rootfs.img) have run.
set -euo pipefail
export MTOOLS_SKIP_CHECK=1   # mtools on a file image has no geometry; silence the warning

SOC="${1:-sm8650}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$SOC"
KERNEL="$OUT/boot/${SOC}-boot.img"
ROOTFS="$OUT/images/rootfs.img"
IMGDIR="$OUT/images"
IMG="$IMGDIR/sdcard.img"

ESP_SIZE_MIB="${ESP_SIZE_MIB:-256}"   # FAT32 ESP; matches the A/B table's esp size
ALIGN_MIB=1                            # 1 MiB partition alignment + GPT primary slack
END_SLACK_MIB=2                        # tail room for the backup GPT (well over its ~17 KiB)

for t in sgdisk mkfs.vfat mcopy; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done
[ -f "$KERNEL" ] || { echo "no boot image: ${KERNEL#"$ROOT"/} (run boot/package.sh $SOC)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run images/build-image.sh $SOC)" >&2; exit 1; }

MIB=$((1024 * 1024))
rootfs_bytes=$(stat -c %s "$ROOTFS")
rootfs_mib=$(( (rootfs_bytes + MIB - 1) / MIB ))                       # round up to MiB
total_mib=$(( ALIGN_MIB + ESP_SIZE_MIB + rootfs_mib + END_SLACK_MIB ))

echo "[novadeck] SD image $SOC: ESP ${ESP_SIZE_MIB}MiB + root ${rootfs_mib}MiB -> ${total_mib}MiB"

# 1. ESP filesystem (FAT32) with the KERNEL boot image at its root.
esp="$(mktemp)"; trap 'rm -f "$esp"' EXIT
truncate -s "${ESP_SIZE_MIB}M" "$esp"
# FAT volume label: max 11 chars (the GPT partition name below keeps NOVADECK-ESP).
# ABL locates the ESP by type GUID (ef00), not this label, so it is cosmetic.
mkfs.vfat -F 32 -n NOVADECK "$esp" >/dev/null
mcopy -i "$esp" "$KERNEL" ::/KERNEL
echo "  esp  $(du -h "$KERNEL" | cut -f1) KERNEL -> ::/KERNEL"

# 2. blank disk image + GPT: p1 ESP (aligned), p2 rootfs filling the rest.
mkdir -p "$IMGDIR"; rm -f "$IMG"
truncate -s "${total_mib}M" "$IMG"
sgdisk -Z "$IMG" >/dev/null
sgdisk -a $(( MIB / 512 )) \
  -n "1:0:+${ESP_SIZE_MIB}M" -t 1:ef00 -c 1:NOVADECK-ESP \
  -n "2:0:0"                 -t 2:8300 -c 2:novadeck-root \
  "$IMG" >/dev/null
sgdisk -p "$IMG"

# 3. write each filesystem into its partition byte offset (notrunc; no loop device).
p1_start=$(sgdisk -i 1 "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
p2_start=$(sgdisk -i 2 "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
dd if="$esp"    of="$IMG" bs=512 seek="$p1_start" conv=notrunc status=none
dd if="$ROOTFS" of="$IMG" bs=512 seek="$p2_start" conv=notrunc status=none

echo "  ok   $(du -h "$IMG" | cut -f1) -> ${IMG#"$ROOT"/}"
cat <<EOF
Done. Write it to the card (replace sdX with your device, ALL DATA LOST):
  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress
ABL boots /KERNEL off the ESP; its DTB picker selects the board; the kernel mounts
root=LABEL=novadeck-root (partition 2). The root fs is smaller than its partition —
after first boot, claim the space with:  btrfs filesystem resize max /
EOF
