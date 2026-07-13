#!/usr/bin/env bash
# novadeck SD-card image builder.
#
# Lays the FULL SteamOS-style 8-partition GPT from images/partition-table.txt and populates
# only the A side: ESP + rootfs-a + var-a + home. rootfs-b/var-b are created and left
# empty for RAUC to fill; efi-a/efi-b are created, formatted, and left empty until there is a
# per-slot bootloader (see the table's header for what eventually lands there).
#
# Laying the final table now — rather than a minimal ESP+root+home and migrating later — means
# adding A/B never costs a reflash. The price is ~6.3G of card sitting empty in the B slots.
#
# Unprivileged: builds each filesystem in a plain file (mtools / mkfs.ext4 -d / mksquashfs),
# lays the GPT with sgdisk via images/genpart.sh, and dd's each filesystem into its partition
# byte offset — no loop mounts, no root.
#
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools + mkfs.ext4):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh
#
# Prereqs: boot/package.sh (-> out/boot/novadeck-boot.img) and images/build-image.sh
# (-> out/images/{rootfs,var}.img) have run.
set -euo pipefail
export MTOOLS_SKIP_CHECK=1   # mtools on a file image has no geometry; silence the warning

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
KERNEL="$OUT/boot/novadeck-boot.img"
IMGDIR="$OUT/images"
ROOTFS="$IMGDIR/rootfs.img"
VARIMG="$IMGDIR/var.img"
IMG="$IMGDIR/sdcard.img"
TABLE="$ROOT/images/partition-table.txt"

MIB=$((1024 * 1024))
END_SLACK_MIB=2   # tail room for the backup GPT (well over its ~17 KiB)

# /home (ext4) is PRE-SEEDED at image-build time with the native arm64 Steam client (see below):
# the flashed image already carries a ready-to-run /home/deck, so there is NO ~1GB first-boot copy
# (and none of its old grow-race ENOSPC trap). The partition is sized to just fit the seed; on first
# boot novadeck-grow-home extends the partition + its ext4 to fill the card.
SEED="$ROOT/work/steam-seed"

for t in sgdisk mkfs.vfat mcopy mkfs.ext4 gzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done
[ -f "$KERNEL" ] || { echo "no boot image: ${KERNEL#"$ROOT"/} (run boot/package.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
[ -f "$VARIMG" ] || { echo "no var image: ${VARIMG#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
[ -x "$SEED/steamrtarm64/steam" ] || {
  echo "no Steam seed at ${SEED#"$ROOT"/} (run steam/fetch-steam-seed.sh)" >&2; exit 1; }

# Partition number and size (MiB) for a row of the table, so the two files can never drift.
part_num()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_mib()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next}
  $1==n { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
          if (u=="G") print v*1024; else if (u=="M") print v; else print 0; exit }' "$TABLE"; }

P_ESP=$(part_num esp);    P_EFIA=$(part_num efi-a); P_EFIB=$(part_num efi-b)
P_ROOTA=$(part_num rootfs-a); P_VARA=$(part_num var-a)
P_HOME=$(part_num home)

ESP_SIZE_MIB=$(part_mib esp)
EFI_SIZE_MIB=$(part_mib efi-a)

# Every populated filesystem must fit the slot the table declares for it. A silently truncated
# dd would produce a card that boots into a corrupt filesystem, so fail loudly here instead.
fits() {  # <file> <slot-mib> <what>
  local bytes slot_bytes; bytes=$(stat -c %s "$1"); slot_bytes=$(( $2 * MIB ))
  [ "$bytes" -le "$slot_bytes" ] || {
    echo "$3 is $(( bytes / MIB ))MiB but its partition is only ${2}MiB — raise it in ${TABLE#"$ROOT"/}" >&2
    exit 1; }
}
fits "$ROOTFS" "$(part_mib rootfs-a)" "rootfs.img"
fits "$VARIMG" "$(part_mib var-a)"    "var.img"

# Stage the /home tree to pre-seed: the deck user's Steam client baked into .local/share/Steam, plus
# the HOME-relative ~/.steam compat symlinks (mirror SteamOS's layout). Owned by deck (uid/gid 1000,
# baked into the base) so Steam can write its home immediately — mkfs.ext4 -d preserves this. This is
# the OFFLINE analog of steamos-create-homedir, done at build time instead of first boot.
DECK_UID=1000; DECK_GID=1000
esp=""; efi=""; home=""; homestage="$(mktemp -d)"
trap 'rm -f "$esp" "$efi" "$home"; rm -rf "$homestage"' EXIT
deckhome="$homestage/deck"
install -d "$deckhome/.local/share" "$deckhome/.steam"
cp -a "$SEED" "$deckhome/.local/share/Steam"
ln -sfn ../.local/share/Steam            "$deckhome/.steam/steam"
ln -sfn ../.local/share/Steam            "$deckhome/.steam/root"
ln -sfn ../.local/share/Steam/linuxarm64 "$deckhome/.steam/sdkarm64"
# x86 Steam SDK/runtime compat symlinks. A native x86-64 Linux game under system-FEX dlopen()s
# ~/.steam/sdk64/steamclient.so (32-bit -> sdk32); Steam's reaper also resolves ubuntu12_{32,64}
# via bin{32,64}. Without these the game's SteamAPI_Init() fails ("cannot open sdk64/steamclient.so")
# and it exits/crashes. The link targets (linux{32,64}, ubuntu12_{32,64}) are populated by the arm64
# client on demand when it first runs an x86 title; the symlinks must pre-exist so it can.
ln -sfn ../.local/share/Steam/linux32     "$deckhome/.steam/sdk32"
ln -sfn ../.local/share/Steam/linux64     "$deckhome/.steam/sdk64"
ln -sfn ../.local/share/Steam/ubuntu12_32 "$deckhome/.steam/bin32"
ln -sfn ../.local/share/Steam/ubuntu12_64 "$deckhome/.steam/bin64"
# No compat tool is seeded into the deck home. The arm64 Proton that runs x86 Windows
# games lives in the root slot at /usr/share/steam/compatibilitytools.d, added to the
# client's search set via STEAM_EXTRA_COMPAT_TOOLS_PATHS (exported by novadeck-steam) —
# so it is available on first boot without being copied into (and then going stale in)
# the user's Steam directory, and it is replaced atomically with the OS slot.
chown -R "$DECK_UID:$DECK_GID" "$deckhome"

# Size /home to the seed + headroom (ext4 metadata + a little slack so mkfs.ext4 -d has room), unless
# forced. novadeck-grow-home grows it to fill the card on first boot, so this is only the flash-time
# floor. du -sm rounds each file up to a whole MiB, so this already over-counts slightly.
seed_mib=$(du -sm "$homestage" | cut -f1)
HOME_SIZE_MIB="${HOME_SIZE_MIB:-$(( seed_mib + seed_mib / 5 + 128 ))}"

fixed_mib=$("$ROOT/images/genpart.sh" --min)
total_mib=$(( fixed_mib + HOME_SIZE_MIB + END_SLACK_MIB ))

echo "[novadeck] SD image: ${fixed_mib}MiB fixed layout (A populated, B empty) + home ${HOME_SIZE_MIB}MiB -> ${total_mib}MiB"

# 1. ESP filesystem (FAT32) with the KERNEL boot image at its root.
esp="$(mktemp)"; efi="$(mktemp)"; home="$(mktemp)"
truncate -s "${ESP_SIZE_MIB}M" "$esp"
# FAT volume label: max 11 chars (the GPT partition name stays NOVADECK-ESP).
# ABL locates the ESP by type GUID (ef00), not this label, so it is cosmetic.
mkfs.vfat -F 32 -n NOVADECK "$esp" >/dev/null
mcopy -i "$esp" "$KERNEL" ::/KERNEL
echo "  esp  $(du -h "$KERNEL" | cut -f1) KERNEL -> ::/KERNEL"

# 2. efi-a / efi-b: formatted but EMPTY. ABL reads /KERNEL off the ESP above, so there is nothing
# to put here until a per-slot bootloader exists. Formatting them now means RAUC can just write.
truncate -s "${EFI_SIZE_MIB}M" "$efi"
mkfs.vfat -F 32 -n NOVADECKEFI "$efi" >/dev/null   # FAT labels max 11 chars; same blank fs for A and B

# 3. /home filesystem (ext4, label novadeck-home) PRE-SEEDED with the deck home via mkfs.ext4 -d,
# which populates the fs from $homestage at creation — unprivileged, no loop mount. -m0: no reserved
# blocks (it's a data partition). -d preserves the staged deck:deck ownership so Steam can write its
# home right away. The offload directories under /home/.novadeck are created on first boot by
# novadeck-offload-prepare.service, not here — it seeds them from the read-only root's content.
truncate -s "${HOME_SIZE_MIB}M" "$home"
mkfs.ext4 -q -F -L novadeck-home -m0 -d "$homestage" "$home"
echo "  home ${HOME_SIZE_MIB}MiB ext4 — pre-seeded Steam client (${seed_mib}MiB), grows to fill the card on first boot"

# 4. blank disk image + the full GPT from the table (single source of truth for offsets/types).
mkdir -p "$IMGDIR"; rm -f "$IMG"
truncate -s "${total_mib}M" "$IMG"
"$ROOT/images/genpart.sh" "$IMG" >/dev/null
sgdisk -p "$IMG"

# 5. write each filesystem into its partition's byte offset (notrunc; no loop device).
# Partitions with no `write_part` call below (rootfs-b, var-b) are intentionally left as zeros.
write_part() {  # <partnum> <file> <label>
  local start; start=$(sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  [ -n "$start" ] || { echo "cannot read start sector of partition $1" >&2; exit 1; }
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  echo "  p$1  $3"
}
write_part "$P_ESP"   "$esp"    "NOVADECK-ESP (KERNEL)"
write_part "$P_EFIA"  "$efi"    "novadeck-efi-A (empty, reserved)"
write_part "$P_EFIB"  "$efi"    "novadeck-efi-B (empty, reserved)"
write_part "$P_ROOTA" "$ROOTFS" "novadeck-root-A (btrfs, ro)"
write_part "$P_VARA"  "$VARIMG" "novadeck-var-A (ext4)"
write_part "$P_HOME"  "$home"   "novadeck-home (ext4, grows on first boot)"

echo "  ok   $(du -h "$IMG" | cut -f1) -> ${IMG#"$ROOT"/}"

# 6. Compress for distribution. Keep the raw .img (so a local `dd` still works) and produce a
# sdcard.img.gz alongside it — most of the card is empty (B slots + unallocated tail), so the
# image compresses hard. -f overwrites a stale .gz from a previous run.
gzip -kf "$IMG"
echo "  ok   $(du -h "$IMG.gz" | cut -f1) -> ${IMG#"$ROOT"/}.gz"

cat <<EOF
Done. Write it to the card (replace sdX with your device, ALL DATA LOST):
  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress
  # …or straight from the compressed image:
  gunzip -c ${IMG#"$ROOT"/}.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
ABL boots /KERNEL off the ESP; its DTB picker selects the board. The initramfs then mounts
root=PARTLABEL=novadeck-root-A read-only, mounts novadeck-var-A, stacks the /etc overlay on it,
then switch_roots into systemd. /home (last partition) is pre-seeded with the deck user's Steam
client and grows to fill the card on first boot.
The B slots (rootfs-b, var-b) and both efi-* partitions are present but empty.
EOF
