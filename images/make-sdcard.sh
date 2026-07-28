#!/usr/bin/env bash
# novadeck SD-card image builder.
#
# Lays the FULL SteamOS-style 8-partition GPT from images/partition-table.txt and populates
# BOTH slots: ESP + rootfs-a/-b + var-a/-b + home. efi-a/efi-b are created, formatted, and left
# empty — under Phase 4b design C the boot image is slot-agnostic and lives only at /KERNEL on
# the shared ESP, so nothing needs a per-slot bootloader partition yet.
#
# Laying the final table now — rather than a minimal ESP+root+home and migrating later — means
# adding A/B never costs a reflash.
#
# WHY B IS POPULATED RATHER THAN LEFT EMPTY (Phase 4b): the deliverable of the boot-path pass is
# that a slot switch and a rollback are provable by hand, and you cannot prove a switch to a slot
# that does not boot — an empty B can only ever exercise the failure path. It is also the state a
# device is never in again after its first real update, so testing against it tests a fiction.
# Flash time is unchanged (the dd already writes the whole full-size image including its zeros);
# the cost is build time and out/ disk. Set NOVADECK_SLOT_B=0 to skip it for a faster local loop.
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
VARIMG_B="$IMGDIR/var-b.img"
ROOTFS_B="$IMGDIR/rootfs-b.img"   # built here from $ROOTFS with a fresh fsid; see section 1b
IMG="$IMGDIR/sdcard.img"
TABLE="$ROOT/images/partition-table.txt"

# Populate the B slot too (default on). See the header for why.
SLOT_B="${NOVADECK_SLOT_B:-1}"

MIB=$((1024 * 1024))
END_SLACK_MIB=2   # tail room for the backup GPT (well over its ~17 KiB)

# /home (ext4) is PRE-SEEDED at image-build time with the native arm64 Steam client (see below):
# the flashed image already carries a ready-to-run /home/deck, so there is NO ~1GB first-boot copy
# (and none of its old grow-race ENOSPC trap). The partition is sized to just fit the seed; on first
# boot novadeck-grow-home extends the partition + its ext4 to fill the card.
SEED="$ROOT/work/steam-seed"

for t in sgdisk mkfs.vfat mcopy mmd mkfs.ext4; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done
[ "$SLOT_B" = 1 ] && { command -v btrfstune >/dev/null 2>&1 || {
  echo "btrfstune not found — run inside novadeck-build (or set NOVADECK_SLOT_B=0)" >&2; exit 1; }; }
[ -f "$KERNEL" ] || { echo "no boot image: ${KERNEL#"$ROOT"/} (run boot/package.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
[ -f "$VARIMG" ] || { echo "no var image: ${VARIMG#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
[ -x "$SEED/steamrtarm64/steam" ] || {
  echo "no Steam seed at ${SEED#"$ROOT"/} (run steam-seed/fetch-steam-seed.sh)" >&2; exit 1; }

# Partition number and size (MiB) for a row of the table, so the two files can never drift.
part_num()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_mib()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next}
  $1==n { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
          if (u=="G") print v*1024; else if (u=="M") print v; else print 0; exit }' "$TABLE"; }

P_ESP=$(part_num esp);    P_EFIA=$(part_num efi-a); P_EFIB=$(part_num efi-b)
P_ROOTA=$(part_num rootfs-a); P_VARA=$(part_num var-a)
P_ROOTB=$(part_num rootfs-b); P_VARB=$(part_num var-b)
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
if [ "$SLOT_B" = 1 ]; then
  [ -f "$VARIMG_B" ] || { echo "no var-b image: ${VARIMG_B#"$ROOT"/} (run images/build-image.sh)" >&2; exit 1; }
  fits "$ROOTFS"   "$(part_mib rootfs-b)" "rootfs.img (slot B)"
  fits "$VARIMG_B" "$(part_mib var-b)"    "var-b.img"
fi

# Stage the /home tree to pre-seed: the deck user's Steam client baked into .local/share/Steam, plus
# the HOME-relative ~/.steam compat symlinks (mirror SteamOS's layout). Owned by deck (uid/gid 1000,
# baked into the base) so Steam can write its home immediately — mkfs.ext4 -d preserves this. This is
# the OFFLINE analog of steamos-create-homedir, done at build time instead of first boot.
DECK_UID=1000; DECK_GID=1000
esp=""; efi=""; home=""; state=""; homestage="$(mktemp -d)"
trap 'rm -f "$esp" "$efi" "$home" "$state" "$ROOTFS_B"; rm -rf "$homestage"' EXIT
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

echo "[novadeck] SD image: ${fixed_mib}MiB fixed layout ($([ "$SLOT_B" = 1 ] && echo 'A+B populated' || echo 'A populated, B empty')) + home ${HOME_SIZE_MIB}MiB -> ${total_mib}MiB"

# 1. ESP filesystem (FAT32) with the KERNEL boot image at its root.
esp="$(mktemp)"; efi="$(mktemp)"; home="$(mktemp)"
truncate -s "${ESP_SIZE_MIB}M" "$esp"
# FAT volume label: max 11 chars (the GPT partition name stays NOVADECK-ESP).
# ABL locates the ESP by type GUID (ef00), not this label, so it is cosmetic.
mkfs.vfat -F 32 -n NOVADECK "$esp" >/dev/null
mcopy -i "$esp" "$KERNEL" ::/KERNEL
echo "  esp  $(du -h "$KERNEL" | cut -f1) KERNEL -> ::/KERNEL"

# 1b. Seed the A/B slot state the initramfs reads (images/initramfs/init documents the format).
# A fresh card is slot A, known good, with nothing on trial.
#
# STATE.1 is deliberately NOT written. The writer alternates between the two files and only ever
# overwrites the one that is already stale, so leaving the second absent means the device's first
# write lands on the free file and this seeded copy survives even if that write is torn.
#
# Under /NOVADECK/ rather than at the ESP root: ABL scans p1 for its boot artifact, and /KERNEL is
# the only thing it must find there. Keeping our namespace in a subdirectory removes any question
# about what the firmware might enumerate. 8.3-clean names, so the kernel's vfat driver and mtools
# never have to agree about long-filename directory entries.
#
# `kernel=` is seeded EMPTY, which is not the same as forgetting it. It names the slot whose boot
# image sits at /KERNEL, and it exists so a boot can tell that the running kernel's /lib/modules
# live in the OTHER root. On a fresh card that cannot be true: both slots are the same rootfs.img
# (differing only in fsid), so /KERNEL matches either one and no letter is more correct than the
# other. Writing `a` here would make the ordinary `novadeck-bootctl try b` slot test warn about a
# mismatch that does not exist -- and a warning that cries wolf on the happy path is worse than no
# warning at all. Only a /KERNEL rotation can make the two roots differ, and the RAUC post-install
# hook records the slot when it does one.
state="$(mktemp)"
cat >"$state" <<'EOF'
# novadeck A/B slot state -- images/initramfs/init, /usr/bin/novadeck-bootctl
gen=1
active=a
pending=
tries=0
kernel=
bak=
broken=
end
EOF
mmd -i "$esp" ::/NOVADECK
mcopy -i "$esp" "$state" ::/NOVADECK/STATE.0
echo "  esp  slot state -> ::/NOVADECK/STATE.0 (gen=1 active=a)"

# 2. efi-a / efi-b: formatted but EMPTY. ABL reads /KERNEL off the ESP above, and design C keeps
# the boot image slot-agnostic, so there is nothing to put here. Formatted so a later pass can
# just write them.
truncate -s "${EFI_SIZE_MIB}M" "$efi"
mkfs.vfat -F 32 -n NOVADECKEFI "$efi" >/dev/null   # FAT labels max 11 chars; same blank fs for A and B

# 2b. Slot B's root: the SAME content, but it MUST NOT be the same bytes.
#
# mkfs.btrfs bakes an fsid into the superblock, and every btrfs image we build also has devid=1.
# Writing rootfs.img verbatim to both p4 and p5 would put two filesystems on one disk sharing
# exactly the pair btrfs keys its in-kernel device list on: the second one scanned is treated as
# the first one having MOVED, and its path silently replaces it. The failure mode is that mounting
# p5 hands you p4's filesystem — on the one test whose entire purpose is proving which slot booted.
# btrfstune -U rewrites the fsid in the superblocks and in every metadata block header, which is
# why it needs its own copy of the file rather than an in-place round trip.
#
# (RAUC will hit this too: every `rauc install` writes identical bytes to the inactive slot. Its
# post-install hook will need the same treatment — tracked in TODO.md.)
if [ "$SLOT_B" = 1 ]; then
  rm -f "$ROOTFS_B"
  cp --reflink=auto "$ROOTFS" "$ROOTFS_B"
  btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$ROOTFS_B" >/dev/null
  echo "  slotB rootfs-b.img: fresh btrfs fsid (content identical to slot A)"
fi

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
# efi-a/efi-b get a blank formatted fs; with NOVADECK_SLOT_B=0 the B root/var stay zeros.
write_part() {  # <partnum> <file> <label>
  local start; start=$(sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  [ -n "$start" ] || { echo "cannot read start sector of partition $1" >&2; exit 1; }
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  echo "  p$1  $3"
}
write_part "$P_ESP"   "$esp"    "NOVADECK-ESP (KERNEL + slot state)"
write_part "$P_EFIA"  "$efi"    "novadeck-efi-A (empty, reserved)"
write_part "$P_EFIB"  "$efi"    "novadeck-efi-B (empty, reserved)"
write_part "$P_ROOTA" "$ROOTFS" "novadeck-root-A (btrfs, ro)"
write_part "$P_VARA"  "$VARIMG" "novadeck-var-A (ext4)"
if [ "$SLOT_B" = 1 ]; then
  write_part "$P_ROOTB" "$ROOTFS_B" "novadeck-root-B (btrfs, ro, distinct fsid)"
  write_part "$P_VARB"  "$VARIMG_B" "novadeck-var-B (ext4)"
fi
write_part "$P_HOME"  "$home"   "novadeck-home (ext4, grows on first boot)"

echo "  ok   $(du -h "$IMG" | cut -f1) -> ${IMG#"$ROOT"/}"

# 6. No compression here. The image compresses hard (most of the card is empty — B slots plus the
# unallocated tail), but single-threaded gzip over ~19GiB dominates the wall time of an otherwise
# incremental rebuild, and every local consumer of this image dd's the raw .img anyway. Compression
# is a release/CI concern: do it there, where it runs once per artifact instead of once per edit.

cat <<EOF
Done. Write it to the card (replace sdX with your device, ALL DATA LOST):
  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress
ABL boots /KERNEL off the ESP; its DTB picker selects the board. The initramfs reads the slot
state at ::/NOVADECK/STATE.0 (gen=1 active=a), mounts that slot's root read-only and its var,
stacks the /etc overlay on it, then switch_roots into systemd. /home (last partition) is
pre-seeded with the deck user's Steam client and grows to fill the card on first boot.
$([ "$SLOT_B" = 1 ] \
  && echo "Both slots carry a full system, so a switch is testable: novadeck-bootctl try b" \
  || echo "The B slots are empty (NOVADECK_SLOT_B=0) — a slot switch will fail over back to A.")
Both efi-* partitions are present but empty (design C keeps the boot image slot-agnostic).
EOF
