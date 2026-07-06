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
#   images/make-sdcard.sh
#
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh sm8650
#
# Prereqs: boot/package.sh (-> out/boot/novadeck-boot.img) and images/build-image.sh
# (-> out/images/rootfs.img) have run.
set -euo pipefail
export MTOOLS_SKIP_CHECK=1   # mtools on a file image has no geometry; silence the warning

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
KERNEL="$OUT/boot/novadeck-boot.img"
ROOTFS="$OUT/images/rootfs.img"
IMGDIR="$OUT/images"
IMG="$IMGDIR/sdcard.img"

ESP_SIZE_MIB="${ESP_SIZE_MIB:-256}"   # FAT32 ESP; matches the A/B table's esp size
ALIGN_MIB=1                            # 1 MiB partition alignment + GPT primary slack
END_SLACK_MIB=2                        # tail room for the backup GPT (well over its ~17 KiB)
# /home (ext4) is PRE-SEEDED at image-build time with the native arm64 Steam client (see step 2):
# the flashed image already carries a ready-to-run /home/deck, so there is NO ~1GB first-boot copy
# (and none of its old grow-race ENOSPC trap). The partition is sized to just fit the seed; on first
# boot novadeck-grow-home extends the partition + its ext4 to fill the card. HOME_SIZE_MIB is
# computed from the staged seed below (override to force a floor).
SEED="$ROOT/work/steam-seed"

for t in sgdisk mkfs.vfat mcopy mkfs.ext4; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done
[ -f "$KERNEL" ] || { echo "no boot image: ${KERNEL#"$ROOT"/} (run boot/package.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
[ -x "$SEED/steamrtarm64/steam" ] || {
  echo "no Steam seed at ${SEED#"$ROOT"/} (run steam/fetch-steam-seed.sh)" >&2; exit 1; }

# Stage the /home tree to pre-seed: the deck user's Steam client baked into .local/share/Steam, plus
# the HOME-relative ~/.steam compat symlinks (mirror SteamOS's layout). Owned by deck (uid/gid 1000,
# baked into the base) so Steam can write its home immediately — mkfs.ext4 -d preserves this. This is
# the OFFLINE analog of steamos-create-homedir, done at build time instead of first boot.
DECK_UID=1000; DECK_GID=1000
esp=""; home=""; homestage="$(mktemp -d)"
trap 'rm -f "$esp" "$home"; rm -rf "$homestage"' EXIT
deckhome="$homestage/deck"
install -d "$deckhome/.local/share" "$deckhome/.steam"
cp -a "$SEED" "$deckhome/.local/share/Steam"
ln -sfn ../.local/share/Steam            "$deckhome/.steam/steam"
ln -sfn ../.local/share/Steam            "$deckhome/.steam/root"
ln -sfn ../.local/share/Steam/linuxarm64 "$deckhome/.steam/sdkarm64"
# novadeck self-chaining Proton 11 ARM64 compat tool (proton11sc): a user-selectable
# compat tool that runs Valve's Proton 11 ARM64 + bundled WoW64 FEX for x86 Windows
# games, chaining the SLR 4.0 Arm64 container itself so the client never resolves
# Proton's platform-gated require_tool 4185400 (AppError_51 on a non-Deckard client).
# Our code, not Valve content — the Proton/SLR4 runtimes are client-fetched by the
# user post-OOBE. Pre-seeded into the deck home so it's live on a healthy first boot.
CTOOLS="$ROOT/steam/compatibilitytools.d"
if [ -d "$CTOOLS" ]; then
  install -d "$deckhome/.local/share/Steam/compatibilitytools.d"
  cp -a "$CTOOLS"/. "$deckhome/.local/share/Steam/compatibilitytools.d/"
  chmod 0755 "$deckhome/.local/share/Steam/compatibilitytools.d/proton11sc/novadeck-chain"
fi
chown -R "$DECK_UID:$DECK_GID" "$deckhome"

# Size /home to the seed + headroom (ext4 metadata + a little slack so mkfs.ext4 -d has room), unless
# forced. novadeck-grow-home grows it to fill the card on first boot, so this is only the flash-time
# floor. du -sm rounds each file up to a whole MiB, so this already over-counts slightly.
seed_mib=$(du -sm "$homestage" | cut -f1)
HOME_SIZE_MIB="${HOME_SIZE_MIB:-$(( seed_mib + seed_mib / 5 + 128 ))}"

MIB=$((1024 * 1024))
rootfs_bytes=$(stat -c %s "$ROOTFS")
rootfs_mib=$(( (rootfs_bytes + MIB - 1) / MIB ))                       # round up to MiB
total_mib=$(( ALIGN_MIB + ESP_SIZE_MIB + rootfs_mib + HOME_SIZE_MIB + END_SLACK_MIB ))

echo "[novadeck] SD image: ESP ${ESP_SIZE_MIB}MiB + root ${rootfs_mib}MiB + home ${HOME_SIZE_MIB}MiB -> ${total_mib}MiB"

# 1. ESP filesystem (FAT32) with the KERNEL boot image at its root.
esp="$(mktemp)"; home="$(mktemp)"
truncate -s "${ESP_SIZE_MIB}M" "$esp"
# FAT volume label: max 11 chars (the GPT partition name below keeps NOVADECK-ESP).
# ABL locates the ESP by type GUID (ef00), not this label, so it is cosmetic.
mkfs.vfat -F 32 -n NOVADECK "$esp" >/dev/null
mcopy -i "$esp" "$KERNEL" ::/KERNEL
echo "  esp  $(du -h "$KERNEL" | cut -f1) KERNEL -> ::/KERNEL"

# 2. /home filesystem (ext4, label novadeck-home) PRE-SEEDED with the deck home via mkfs.ext4 -d,
# which populates the fs from $homestage at creation — unprivileged, no loop mount. -m0: no reserved
# blocks (it's a data partition). Sized to the seed; novadeck-grow-home grows it to fill the card on
# first boot. -d preserves the staged deck:deck ownership so Steam can write its home right away.
truncate -s "${HOME_SIZE_MIB}M" "$home"
mkfs.ext4 -q -F -L novadeck-home -m0 -d "$homestage" "$home"
echo "  home ${HOME_SIZE_MIB}MiB ext4 (novadeck-home) — pre-seeded Steam client (${seed_mib}MiB), grows to fill the card on first boot"

# 3. blank disk image + GPT: p1 ESP (aligned), p2 rootfs (content-sized), p3 home filling the rest.
# p3 uses typecode 8302 (Linux /home discoverable GUID) so systemd-repart can match + grow ONLY it.
mkdir -p "$IMGDIR"; rm -f "$IMG"
truncate -s "${total_mib}M" "$IMG"
sgdisk -Z "$IMG" >/dev/null
sgdisk -a $(( MIB / 512 )) \
  -n "1:0:+${ESP_SIZE_MIB}M" -t 1:ef00 -c 1:NOVADECK-ESP \
  -n "2:0:+${rootfs_mib}M"   -t 2:8300 -c 2:novadeck-root \
  -n "3:0:0"                 -t 3:8302 -c 3:novadeck-home \
  "$IMG" >/dev/null
sgdisk -p "$IMG"

# 4. write each filesystem into its partition byte offset (notrunc; no loop device).
p1_start=$(sgdisk -i 1 "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
p2_start=$(sgdisk -i 2 "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
p3_start=$(sgdisk -i 3 "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
dd if="$esp"    of="$IMG" bs=512 seek="$p1_start" conv=notrunc status=none
dd if="$ROOTFS" of="$IMG" bs=512 seek="$p2_start" conv=notrunc status=none
dd if="$home"   of="$IMG" bs=512 seek="$p3_start" conv=notrunc status=none

echo "  ok   $(du -h "$IMG" | cut -f1) -> ${IMG#"$ROOT"/}"
cat <<EOF
Done. Write it to the card (replace sdX with your device, ALL DATA LOST):
  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress
ABL boots /KERNEL off the ESP; its DTB picker selects the board; the kernel mounts
root=LABEL=novadeck-root (partition 2). /home is partition 3 (LABEL=novadeck-home),
PRE-SEEDED with the deck user's Steam client; novadeck-grow-home extends it + its ext4
to fill the card on first boot. (The btrfs root stays at its built size — it's read-only.)
EOF
