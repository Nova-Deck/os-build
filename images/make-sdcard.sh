#!/usr/bin/env bash
# novadeck SD-card image builder.
#
# Lays the FULL SteamOS-style 8-partition GPT from images/partition-table.txt and populates
# BOTH slots: ESP + rootfs-a/-b + var-a/-b + home, and each slot's efi-a/efi-b partition with
# that slot's STAGE-2 GRUB (Phase 5; docs/phase5.md).
#
# The boot chain this card boots is SteamOS's three-stage one:
#
#   ABL -> /EFI/BOOT/bootaa64.efi (steamcl, stage 1, shared ESP)
#       -> \EFI\steamos\grubaa64.efi on the SLOT's efi partition (stage 2)
#       -> kernel in the slot's root /boot
#
# The ESP carries the stage-1 software + the boot state (SteamOS/conf/A.conf|B.conf + the
# grubenv); each efi partition carries its own stage-2 GRUB + identity partsets. There is no
# /KERNEL and no /NOVADECK/STATE.0 — that was design C; the slot state IS the confs now.
#
# WHY B IS POPULATED ON A DEV CARD AND EMPTY ON A RELEASE CARD. The default follows NOVADECK_DEV;
# NOVADECK_SLOT_B=0|1 overrides it in either direction.
#
# Dev (Phase 4b): the deliverable of the boot-path pass is that a slot switch and a rollback are
# provable by hand, and you cannot prove a switch to a slot that does not boot — an empty B can only
# ever exercise the failure path. It is also the state a device is never in again after its first
# real update, so testing against it tests a fiction.
#
# Release: B WOULD BE a byte-identical copy of a root that is ALREADY zstd-compressed inside btrfs,
# so it would survive the release compression whole. Nothing dedupes it: the flash instruction is
# `gzip -dc` (32 KiB window), and even zstd --long tops out at a 2 GiB window against a ~4 GiB gap
# between the two copies. That was ~4 of the ~9 GiB a release card compressed to until 2026-08-04
# (images/publish-card.sh) — ~44% of every download — bought to cover a failover window that closes
# the first time RAUC writes the slot, which it writes in FULL and reads nothing prior out of. A
# user never hand-tests a slot switch, and a fresh-card A failure is media failure, which will not
# politely spare B. With B left empty a card compresses to ~5 GiB instead.
#
# Flash time is unchanged either way: the dd writes the whole full-size image including its zeros.
#
# Unprivileged: builds each filesystem in a plain file (mtools / mkfs.ext4 -d / mksquashfs),
# lays the GPT with sgdisk via images/genpart.sh, and dd's each filesystem into its partition
# byte offset — no loop mounts, no root.
#
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools + mkfs.ext4 + grub-editenv):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh
#
# Prereqs: boot/steamcl.sh + boot/grub.sh (-> out/boot/{steamcl.efi,steamcl-version,holo-bootconf,
# fonts/default.pf2, grubaa64.efi, grub-a.cfg, grub-b.cfg, fonts/dejavu-mono.pf2}) and
# images/build-image.sh (-> out/images/{rootfs,var}.img) have run.
set -euo pipefail
export MTOOLS_SKIP_CHECK=1   # mtools on a file image has no geometry; silence the warning

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
BOOT="$OUT/boot"
IMGDIR="$OUT/images"
ROOTFS="$IMGDIR/rootfs.img"
VARIMG="$IMGDIR/var.img"
VARIMG_B="$IMGDIR/var-b.img"
ROOTFS_B="$IMGDIR/rootfs-b.img"   # built here from $ROOTFS with a fresh fsid; see section 1b
IMG="$IMGDIR/sdcard.img"
TABLE="$ROOT/images/partition-table.txt"

# Phase 5 boot-stage artifacts, all staged to out/boot by boot/steamcl.sh + boot/grub.sh:
STEAMCL="$BOOT/steamcl.efi"
STEAMCL_VER="$BOOT/steamcl-version"
BOOTCONF="$BOOT/holo-bootconf"          # installed on the ESP as steamos-bootconf
STAGE_FONT="$BOOT/fonts/default.pf2"    # steamcl's boot menu font
GRUB_EFI="$BOOT/grubaa64.efi"
GRUB_CFG_A="$BOOT/grub-a.cfg"           # per-slot grub.cfg (stage 2, A)
GRUB_CFG_B="$BOOT/grub-b.cfg"
GRUB_FONT="$BOOT/fonts/dejavu-mono.pf2" # stage-2 boot font ($prefix/fonts/ in grub.cfg)
GRUBENV="$BOOT/grubenv"                 # pristine stage-2 env block (saved_entry lives here)

# Populate the B slot too: on for a dev card, off for a release card. See the header for why.
# Read the mode rather than defaulting to 1, so that forgetting to forward NOVADECK_DEV produces a
# release-shaped card (small, one bootable slot) rather than silently shipping the 4 GiB copy.
SLOT_B="${NOVADECK_SLOT_B:-$([ "${NOVADECK_DEV:-}" = 1 ] && echo 1 || echo 0)}"

MIB=$((1024 * 1024))
END_SLACK_MIB=2   # tail room for the backup GPT (well over its ~17 KiB)

# /home (ext4) is PRE-SEEDED at image-build time with the native arm64 Steam client (see below):
# the flashed image already carries a ready-to-run /home/deck, so there is NO ~1GB first-boot copy
# (and none of its old grow-race ENOSPC trap). The partition is sized to just fit the seed; on first
# boot novadeck-grow-home extends the partition + its ext4 to fill the card.
SEED="$ROOT/work/steam-seed"

for t in sgdisk mkfs.vfat mcopy mmd mkfs.ext4 grub-editenv; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside novadeck-build" >&2; exit 1; }
done
[ "$SLOT_B" = 1 ] && { command -v btrfstune >/dev/null 2>&1 || {
  echo "btrfstune not found — run inside novadeck-build (or set NOVADECK_SLOT_B=0)" >&2; exit 1; }; }
for f in "$STEAMCL" "$STEAMCL_VER" "$BOOTCONF" "$STAGE_FONT" \
         "$GRUB_EFI" "$GRUB_CFG_A" "$GRUB_CFG_B" "$GRUB_FONT" "$GRUBENV"; do
  [ -f "$f" ] || { echo "no boot artifact: ${f#"$ROOT"/} (run boot/steamcl.sh + boot/grub.sh)" >&2; exit 1; }
done
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
homestage="$(mktemp -d)"
# Every name here is ${x:-} because the trap is armed BEFORE most of them exist: under `set -u` an
# early exit (a `fits` check failing, say) would otherwise die inside the trap on an unset variable
# and mask the real error. The previous fix for that was a block of empty pre-assignments carrying
# a comment pointing at a line number, which is a trap of its own.
trap 'rm -f "${esp:-}" "${efi_a:-}" "${efi_b:-}" "${home:-}" "${ROOTFS_B:-}" "${conf_a:-}" "${conf_b:-}" "${partsenv:-}" "${flag:-}"; rm -rf "${homestage:-}"' EXIT
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

# 1b. Slot B's root: the SAME content, but it MUST NOT be the same bytes.
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
# post-install hook needs the same treatment — tracked in TODO.md.)
if [ "$SLOT_B" = 1 ]; then
  rm -f "$ROOTFS_B"
  cp --reflink=auto "$ROOTFS" "$ROOTFS_B"
  btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$ROOTFS_B" >/dev/null
  btrfs filesystem label "$ROOTFS_B" novadeck-root-B >/dev/null
  echo "  slotB rootfs-b.img: fresh btrfs fsid + label novadeck-root-B (content identical to A)"
fi
# Slot A needs no copy at all: images/assemble-rootfs.sh already labels rootfs.img novadeck-root-A,
# and section 5 writes it straight into p4. This used to `cp --reflink=auto` the whole multi-GiB
# image to a rootfs-a.img purely to run `btrfs filesystem label` on it -- an extra full-size write
# per build, and one that happened even with NOVADECK_SLOT_B=0.

# 3. /home filesystem (ext4, label novadeck-home) PRE-SEEDED with the deck home via mkfs.ext4 -d,
# which populates the fs from $homestage at creation — unprivileged, no loop mount. -m0: no reserved
# blocks (it's a data partition). -d preserves the staged deck:deck ownership so Steam can write its
# home right away. The offload directories under /home/.novadeck are created on first boot by
# novadeck-offload-prepare.service, not here — it seeds them from the read-only root's content.
home="$(mktemp)"
truncate -s "${HOME_SIZE_MIB}M" "$home"
mkfs.ext4 -q -F -L novadeck-home -m0 -d "$homestage" "$home"
echo "  home ${HOME_SIZE_MIB}MiB ext4 — pre-seeded Steam client (${seed_mib}MiB), grows to fill the card on first boot"

# 4. blank disk image + the full GPT from the table (single source of truth for offsets/types).
mkdir -p "$IMGDIR"; rm -f "$IMG"
truncate -s "${total_mib}M" "$IMG"
"$ROOT/images/genpart.sh" "$IMG" >/dev/null
sgdisk -p "$IMG"

# 4b. Partition uuids (Phase 5). sgdisk assigns these at GPT-lay time; the ESP confs and the efi
# partsets are keyed by them (steamcl matches a partset's `efi` value against the uuid of the
# partition it was loaded from, and reads partsets/all for the ESP; bootconf reads partsets/self).
# Stage 2 reads none of them: novadeck_bootattempts takes the image name as an ARGUMENT, which is
# what let its ~2000-line predecessor go. Lowercased — PARTUUID= on the kernel cmdline and the EFI
# guid strings are lowercase.
part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }
ESP_UUID="$(part_uuid "$P_ESP")"
EFIA_UUID="$(part_uuid "$P_EFIA")"
EFIB_UUID="$(part_uuid "$P_EFIB")"
[ -n "$ESP_UUID" ] && [ -n "$EFIA_UUID" ] && [ -n "$EFIB_UUID" ] || {
  echo "cannot read esp/efi-a/efi-b partition uuids from ${IMG#"$ROOT"/}" >&2; exit 1; }
echo "  esp  $ESP_UUID"
echo "  efi-a $EFIA_UUID"
echo "  efi-b $EFIB_UUID"

# 4c. ESP filesystem (FAT32) — the stage-1 home:
#
# mtools has no mkdir -p: create each directory level (an existing dir is fine to re-touch).
fatdir() {  # <img> <msdos path, no leading '::'>
  local img="$1" path="$2" p="" part
  for part in ${path//\// }; do
    p="$p/$part"
    mmd -i "$img" "::$p" >/dev/null 2>&1 || true
  done
}
#
#   /EFI/BOOT/bootaa64.efi           ABL chainloads this (steamcl); with /KERNEL gone it is the
#                                    only way onto the card
#   /EFI/BOOT/{steamcl-version,      companion files resolved by steamcl's resolve_path() relative
#     steamcl-restricted,            to the chainloader location
#     fonts/default.pf2}
#   /EFI/steamos/grubenv             stage-2 env block (saved_entry), seeded on ESP so the
#                                    user's board choice survives slot updates
#   /SteamOS/conf/A.conf[|B.conf]    the per-image boot state (bootconf's home). A is seeded with
#                                    the newest boot-requested-at so the FIRST boot picks A. B.conf
#                                    exists only when slot B is populated -- see the seeding site
#
# NOTHING RESOLVES THE ESP BY THIS LABEL. ABL finds it by type GUID (ef00), the OS mounts it by
# PARTLABEL from /etc/fstab, and the stage-2 grub.cfg addresses it by partition index (falling back
# to a search for /SteamOS/conf/<slot>.conf, i.e. by content). The label is a human convenience on
# a mounted card, and it is deliberately NOT the GPT name: a FAT label caps at 11 characters and
# NOVADECK-ESP is twelve. An earlier version of this script had grub.cfg searching for a FAT label
# this line had stopped writing, and nothing failed -- the saved board choice just never persisted.
esp="$(mktemp)"
truncate -s "${ESP_SIZE_MIB}M" "$esp"
mkfs.vfat -F 32 -n NOVADECK "$esp" >/dev/null
fatdir "$esp" /EFI/BOOT
fatdir "$esp" /EFI/BOOT/fonts
fatdir "$esp" /EFI/steamos
fatdir "$esp" /SteamOS/conf
mcopy -i "$esp" "$STEAMCL" ::/EFI/BOOT/bootaa64.efi
mcopy -i "$esp" "$STEAMCL_VER" ::/EFI/BOOT/steamcl-version
flag="$(mktemp)"; : >"$flag"
mcopy -i "$esp" "$flag" ::/EFI/BOOT/steamcl-restricted
mcopy -i "$esp" "$STAGE_FONT" ::/EFI/BOOT/fonts/default.pf2
# The pristine env block comes from out/boot, not from a `grub-editenv create` here. It used to be
# minted on the spot, which was fine while a card was the only thing that had one -- but the internal
# installer writes an ESP too and cannot run grub-editenv (not on the shipped image), so it ships as
# a build artifact and gets copied. Two writers of the same constant is how a card and an install end
# up carrying subtly different objects; one writer, two copies, cannot.
mcopy -i "$esp" "$GRUBENV" ::/EFI/steamos/grubenv

# The confs: key: value lines (bootconf's format). boot-requested-at is a YYYYmmDDHHMMSS UTC
# datestamp; the chainloader picks the image with the newest one as the default. A gets now,
# B gets 0, so a fresh card's first boot lands on A.
mkconf() {  # <outfile> <ident> <stamp>
  cat >"$1" <<EOF
title: novadeck $2
boot-requested-at: $3
boot-other: 0
boot-other-disabled: 0
boot-attempts: 0
boot-count: 0
boot-time: 0
image-invalid: 0
verbose: 0
update: 0
update-disabled: 1
update-window-start: 0
update-window-end: 0
loader:
partitions:
comment: seeded by images/make-sdcard.sh
EOF
}
conf_a="$(mktemp)"; conf_b="$(mktemp)"
mkconf "$conf_a" A "$(date -u +%Y%m%d%H%M%S)"
mcopy -i "$esp" "$conf_a" ::/SteamOS/conf/A.conf

# NO B.conf WHEN B IS EMPTY, and this is load-bearing rather than tidiness. steamcl honours
# image-invalid only as a SORT DEMOTION -- chainloader/bootload.c reads it into found[].disabled and
# earlier_entry_is_newer() sorts disabled below enabled, but the steamos-efi README says it outright:
# "This does not disable booting, it lowers this image's priority". A marked-invalid B is still a
# candidate. Worse, set_menu_conf() deliberately picks the OTHER entry once the selected one passes
# SUPERMAX_BOOT_FAILURES (6), and that pick is guarded ONLY by `found[alt_opt].tries <= tries` -- it
# never consults the disabled flag, and a slot nothing has ever booted reports boot-attempts 0, so it
# passes every time. Marking B invalid would not have closed that path.
#
# Omitting the conf closes it at the source. steamcl builds its candidate list by walking the EFI
# partition handles (skipping the ESP), resolving each one's partsets/self to an image name, and then
# requiring a config for that name: <esp>\SteamOS\conf\<name>.conf, falling back to SteamOS\bootconf
# on the efi partition itself. With NEITHER present it does `continue` and the partition never enters
# found[] at all. So efi-b can keep its full stage-2 GRUB and partsets (mkefi below runs
# unconditionally, and nothing here writes the legacy SteamOS\bootconf) and B is still not a
# candidate. found_cfg_count is then 1, def_opt is 0, and BOTH branches of the alt pick are false
# (`def_opt > 0`, and `def_opt < found_cfg_count - 1` = `0 < 0`) -- so alt_opt stays def_opt and
# nothing is switched. A is retried behind the failsafe menu, which is the right answer for a device
# that genuinely has one populated slot, instead of being handed a slot with no kernel.
#
# It returns on its own the first time B becomes real: novadeck-bootctl's ensure_exists() runs
# `bc config --image B || bc create --image B`, bootconf's create_missing defaults to on, RAUC's
# set-primary goes through it, and post-install.sh then clears image-invalid on the slot it wrote.
if [ "$SLOT_B" = 1 ]; then
  mkconf "$conf_b" B 0
  mcopy -i "$esp" "$conf_b" ::/SteamOS/conf/B.conf
fi

# 4d. efi-a / efi-b (p2/p3): each slot's STAGE-2 home. Per docs/phase5.md and the post-install
# hook's refresh shape, both carry the same /EFI/steamos/{grubaa64.efi, grub.cfg, fonts, parts.env}
# and the same /SteamOS/partsets/{A,B,all,shared}; only self/other differ, naming THIS partition and
# the other one. steamcl chainloads \EFI\steamos\grubaa64.efi; the module's grub.cfg is the A or B
# variant; the partsets are the identity steamcl matches the booted efi uuid against.
#
# parts.env is where our eight partitions ARE on this medium. The stage-2 grub.cfg carries the same
# numbers as build-time defaults, so on a card the file changes nothing — it is seeded anyway, and
# that is deliberate: it makes the card exercise the same lookup an internal install depends on, on
# every boot, instead of shipping that path untested until the installer exists. On an internal
# install our eight are APPENDED to the OEM's GPT and land at per-vendor indices, and the installer
# writes this file with the real ones. It is the one map of the layout, so it goes on both slots
# identically; the reader picks the keys for the slot it is.
partsenv="$(mktemp)"
grub-editenv "$partsenv" create
grub-editenv "$partsenv" set \
  "nd_esp=$P_ESP" "nd_efi_a=$P_EFIA" "nd_efi_b=$P_EFIB" \
  "nd_root_a=$P_ROOTA" "nd_root_b=$P_ROOTB" \
  "nd_var_a=$P_VARA" "nd_var_b=$P_VARB" "nd_home=$P_HOME"
mkpartset() {  # <img> <name> <token...>
  local img="$1" name="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$*" >"$tmp"
  mcopy -i "$img" "$tmp" "::/SteamOS/partsets/$name"
  rm -f "$tmp"
}
mkefi() {  # <img> <grub.cfg> <self-efi-uuid> <other-efi-uuid> <label-suffix>
  local img="$1" cfg="$2" self="$3" other="$4" label_suffix="$5"
  truncate -s "${EFI_SIZE_MIB}M" "$img"
  mkfs.vfat -F 32 -n "GRUB-${label_suffix}" "$img" >/dev/null
  fatdir "$img" /EFI/steamos/fonts
  fatdir "$img" /SteamOS/partsets
  mcopy -i "$img" "$GRUB_EFI" ::/EFI/steamos/grubaa64.efi
  mcopy -i "$img" "$cfg" ::/EFI/steamos/grub.cfg
  mcopy -i "$img" "$GRUB_FONT" ::/EFI/steamos/fonts/dejavu-mono.pf2
  mcopy -i "$img" "$partsenv" ::/EFI/steamos/parts.env
  mkpartset "$img" A      "efi $EFIA_UUID"
  mkpartset "$img" B      "efi $EFIB_UUID"
  mkpartset "$img" all    "esp $ESP_UUID"
  mkpartset "$img" shared "esp $ESP_UUID"
  mkpartset "$img" self   "efi $self"
  mkpartset "$img" other  "efi $other"
}
efi_a="$(mktemp)"; efi_b="$(mktemp)"
mkefi "$efi_a" "$GRUB_CFG_A" "$EFIA_UUID" "$EFIB_UUID" "A"
echo "  efi-a  grubaa64.efi + grub.cfg(A) + parts.env + partsets (self=A)"
mkefi "$efi_b" "$GRUB_CFG_B" "$EFIB_UUID" "$EFIA_UUID" "B"
echo "  efi-b  grubaa64.efi + grub.cfg(B) + parts.env + partsets (self=B)"

# 5. write each filesystem into its partition's byte offset (notrunc; no loop device).
write_part() {  # <partnum> <file> <label>
  local start; start=$(sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  [ -n "$start" ] || { echo "cannot read start sector of partition $1" >&2; exit 1; }
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  echo "  p$1  $3"
}
write_part "$P_ESP"   "$esp"    "NOVADECK-ESP (steamcl + boot confs + grubenv)"
write_part "$P_EFIA"  "$efi_a"  "novadeck-efi-A (stage-2 GRUB A + partsets)"
write_part "$P_EFIB"  "$efi_b"  "novadeck-efi-B (stage-2 GRUB B + partsets)"
write_part "$P_ROOTA" "$ROOTFS"   "novadeck-root-A (btrfs, ro)"
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
ABL chainloads /EFI/BOOT/bootaa64.efi (steamcl, stage 1) off the ESP; steamcl reads the boot state
at /SteamOS/conf/{A,B}.conf, then chainloads \EFI\steamos\grubaa64.efi on the SLOT's efi-A/B
partition (stage 2, per-slot grub.cfg + partsets), which boots the kernel in the slot root's /boot.
/home (last partition) is pre-seeded with the deck user's Steam client and grows to fill the card.
$([ "$SLOT_B" = 1 ] \
  && echo "Both slots carry a full system, so a switch is testable: novadeck-bootctl set-primary B" \
  || echo "The B slots are empty and there is no B.conf, so steamcl sees ONE image and retries A
rather than switching. The first update writes B in full and creates its conf.")

The FIRST boot stops at the stage-2 board menu and waits: one image serves every board, so the DTB
is the one thing the card cannot know. The choice is written to /EFI/steamos/grubenv on the ESP and
every boot after that takes it automatically (3s visible menu), including across a slot switch.

ESP layout: /EFI/BOOT/{bootaa64.efi, steamcl-version, steamcl-restricted, fonts/default.pf2}
            /EFI/steamos/grubenv (shared stage-2 env — the saved board choice)
            /SteamOS/conf/$([ "$SLOT_B" = 1 ] && echo '{A,B}' || echo 'A').conf (the per-image boot state)
Filesystem labels: ESP NOVADECK | efi-A GRUB-A | efi-B GRUB-B (cosmetic; nothing resolves by them)
EOF
