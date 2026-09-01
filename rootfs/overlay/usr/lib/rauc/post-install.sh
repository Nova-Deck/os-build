#!/usr/bin/env bash
# novadeck RAUC post-install handler — Phase 5 (SteamDeck-style boot; docs/phase5.md).
#
# Runs after RAUC has written and unmounted the target slot. A freshly written slot is NOT usable
# until this has run: the bytes are an exact copy of the running slot, so it shares an fsid, it has
# no per-slot identity in /var, and its efi partition still carries the OLD build's stage 2.
#
# Order is load-bearing:
#
#   0. disarm     -- RAUC armed the target BEFORE calling us; take that back until it is real.
#   1. fsid       -- MUST come before anything mounts the target. Until btrfstune has run, the
#                    target and the running root share an fsid AND devid=1, which is the pair
#                    btrfs keys its in-kernel device list on: the second one scanned is treated as
#                    the first having MOVED, so mounting the target can silently hand you the
#                    RUNNING root. Every later step here mounts the target, so this is step 1.
#   2. /var       -- per-slot identity. Without it the updated slot boots as a different device.
#   3. stage 2    -- the target's efi partition gets this build's grubaa64.efi + grub.cfg + boot
#                    font and the partsets (self/other re-pointed at the target), and the shared
#                    ESP gets this build's steamcl (content-identical when unchanged).
#   4. bootconf   -- the target image's conf exists and is unmarked; the ESP points at it (re-arm).
#
# WHY THE STAGE-2 FILES COME OUT OF THE NEW ROOT AND NOT THE BUNDLE: /EFI/steamos/grubaa64.efi and
# grub-<slot>.cfg are boot software owned by the same build that ships /boot/Image and
# /lib/modules/<ver> inside the rootfs. Taking them from the root makes the pairing true by
# construction -- there is no bundle layout to keep in sync, and no way to install a root whose
# stage 2 does not boot it.
#
# WHO AM I: slot identity is the SteamOS image name now, not a handoff letter. The booted image is
# `steamos-bootconf this-image` (holo-bootconf reading /efi/SteamOS/partsets/self), and the target
# is the other one. RAUC's exported slot names are used only to cross-check, and a disagreement is
# fatal rather than resolved by preference.
#
# PREREQUISITE (landed with the phase-5 initramfs rework): /esp (the shared ESP, with
# SteamOS/conf) and /efi (the RUNNING slot's efi partition, with SteamOS/partsets) must be
# mounted when this runs. steamos-bootconf needs both, and the partsets this hook copies out of
# /efi are the disk-derived ones -- there is no way to rebuild them from nothing here, which is
# why a card that somehow lost /efi's partsets is a reflash, not an update.
set -euo pipefail

PROG=${0##*/}
log()  { printf '[%s] %s\n' "$PROG" "$1"; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

# Test seams, documented exactly as novadeck-bootctl documents its own. The offline suite
# (tests/test-post-install.sh) executes THIS file -- not a copy -- so what it asserts is the
# artifact that ships; overriding them points it at a sandbox ESP/efi/var and fake slot devices.
# Nothing here is otherwise conditional on being under test, and the defaults are what every real
# invocation uses. DEVTEST is the one assertion the sandbox cannot keep: an unprivileged test has
# no block devices to offer, so it relaxes -b to -e. Everything a wrong answer here would destroy
# lives behind DEVDIR, so treat both as the pair they are.
ESP=${ESP:-/esp}              # the shared ESP (SteamOS/conf + steamcl); mounted by fstab
EFI=${EFI:-/efi}              # the RUNNING slot's efi partition (SteamOS/partsets); initramfs mount
MNT=${MNT:-/run/novadeck/rauc-target}
EFIMNT=${EFIMNT:-/run/novadeck/rauc-efi}
VAR=${VAR:-/var}
# /dev/novadeck/, NOT /dev/disk/by-partlabel/: the same GPT names exist on every novadeck medium, so
# by-partlabel would let this hook reformat the /var and rewrite the efi partition of the OTHER disk
# when two are attached. The links here are scoped to the disk we booted from
# (/usr/lib/udev/rules.d/69-novadeck-bootdisk.rules), which is the disk rauc just wrote a slot on --
# etc/rauc/system.conf names its slot devices through the same links, so the two cannot disagree.
DEVDIR=${DEVDIR:-/dev/novadeck}
DEVTEST=${DEVTEST:--b}
BC=${BC:-steamos-bootconf}
BC_ARGS=(--conf-dir "$ESP/SteamOS/conf" --efi-dir "$EFI")
bc() { "$BC" "${BC_ARGS[@]}" "$@"; }
# The hasher, a seam for the same reason BC is one: the suite runs this script with the HOST's PATH
# appended, so it cannot make a tool absent, and the assertion below would be untestable as a bare
# command name. Overriding it with a name that does not exist is how the offline suite reaches the
# die() -- there is no other way in, and an assertion nothing can exercise is what put a dead `cmp`
# in this file for three releases.
SHA256=${SHA256:-sha256sum}

# The shared half of this hook. Everything a RAUC bundle does not carry has to be written twice --
# once here and once by the internal installer, onto a disk with no novadeck on it -- and two copies
# of that logic drift in the direction "the installed system boots, the updated one does not", which
# is discoverable only on hardware. So they live in one file and this sources it.
#
# Resolved RELATIVE TO THIS SCRIPT, with no seam, because rootfs/overlay/ mirrors the device layout
# exactly: /usr/lib/rauc/../novadeck/install/ and rootfs/overlay/usr/lib/rauc/../novadeck/install/ are
# both right, so the offline suite exercises the shipped path rather than a test-only one. Sourced
# AFTER the seams above so the library picks up an overridden $SHA256 rather than its own default.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
SLOTWRITE="$SELFDIR/../novadeck/install/lib-slotwrite.sh"
[ -r "$SLOTWRITE" ] || die "cannot read $SLOTWRITE -- this root is missing the slot-write primitives"
# shellcheck source=../novadeck/install/lib-slotwrite.sh
. "$SLOTWRITE"

# --- which slot did we just write? --------------------------------------------------------------
# The booted image comes from bootconf (partsets/self), NOT from RAUC: RAUC names slots as they
# appear in system.conf, and this must not depend on a value that could be misnamed. The target is
# simply the other image. RAUC's value is used only to cross-check.
booted=$(bc this-image 2>/dev/null) \
  || die "cannot identify the booted image (is the booted slot's efi partition mounted at $EFI?)"
case "$booted" in
  A) target=B ;;
  B) target=A ;;
  *) die "booted image '$booted' has no counterpart slot -- refusing to guess a target" ;;
esac

if [ -n "${RAUC_TARGET_SLOTS:-}" ]; then
  # RAUC names slots as they appear in system.conf ("rootfs.0"/"rootfs.1"); map to our images.
  case "${RAUC_TARGET_SLOTS}" in
    *rootfs.0*) rauc_target=A ;;
    *rootfs.1*) rauc_target=B ;;
    *)          rauc_target='' ;;
  esac
  if [ -n "$rauc_target" ] && [ "$rauc_target" != "$target" ]; then
    die "RAUC says it wrote slot '$rauc_target' but the booted image is '$booted' (target '$target') -- refusing"
  fi
fi

case "$target" in
  A) dev_root=$DEVDIR/novadeck-root-A; dev_var=$DEVDIR/novadeck-var-A; dev_efi=$DEVDIR/novadeck-efi-A ;;
  B) dev_root=$DEVDIR/novadeck-root-B; dev_var=$DEVDIR/novadeck-var-B; dev_efi=$DEVDIR/novadeck-efi-B ;;
esac
# shellcheck disable=SC2086  # DEVTEST is a predicate, not a path
[ $DEVTEST "$dev_root" ] || die "no block device at $dev_root"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_var" ]  || die "no block device at $dev_var"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_efi" ]  || die "no block device at $dev_efi"
log "target slot $target ($dev_root, $dev_efi)"

# The one external tool this script asserts, and it is asserted HERE -- before step 0, ahead of
# everything destructive -- rather than at its use site down in step 3. A comparator that is merely
# ABSENT does not announce itself: `cmp -s` was used until 2026-08-05, diffutils has never been in
# PKGS, and "command not found" is a non-zero exit that reads exactly like "the files differ". The
# ESP refresh below degraded to unconditional copy for three releases without a single failed
# install. Dying at the use site would be worse than useless: by then the target's fsid is
# randomised and its /var reformatted, so the slot is already unbootable and the run cannot be
# retried cleanly. Fail while nothing has been touched.
command -v "$SHA256" >/dev/null || die "$SHA256 is missing -- cannot compare the ESP boot files"

# --- 0. DISARM ----------------------------------------------------------------------------------
# RAUC has ALREADY armed this slot by the time we run. Its order is fixed and not ours to change:
# it calls the bootloader backend's set-primary (-> `--image <target> set-mode reboot`, making the
# target the highest-priority image) and only THEN starts the post-install handler. So on entry the
# ESP says "boot the target next" while the target is not yet bootable -- its /var is the previous
# install's or freshly mkfs'd, and its efi partition still holds the other build's stage 2.
#
# So: take the arming back for the duration of the work, and re-arm at the very end once the slot
# is genuinely bootable. An interrupted post-install then leaves nothing pointing at a
# half-prepared slot, and the failure mode becomes "the install failed, run it again" instead of
# "one bad boot, hope the failsafe fires".
#
# Making the BOOTED image the highest-priority one is precisely this operation. (There is no
# concept of "clearing a trial" in the SteamOS model -- a trial IS a priority bump, enforced by the
# stage-2 boot-attempts counter and stock steamcl's failsafe, so this is the closest equivalent.)
bc --image "$booted" set-mode reboot >/dev/null \
  || die "cannot disarm the target slot before preparing it"
log "disarmed slot $target for the duration of the install (re-armed at the end)"

# --- 1. fsid ------------------------------------------------------------------------------------
# -f because the filesystem is a byte copy of a mounted one, which btrfstune otherwise refuses.
btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$dev_root" >/dev/null \
  || die "btrfstune could not re-randomise the fsid of $dev_root"

# The LABEL is the other identity the byte copy got wrong. rootfs/assemble-rootfs.sh bakes
# novadeck-root-A into the image, RAUC writes that image verbatim to whichever slot it targets,
# and nothing else corrects it -- so without this, both partitions answer to novadeck-root-A.
# Stage 2 normally addresses the root by partition index, so this is not what makes the slot boot;
# it is what makes `blkid` honest and what keeps stage 2's documented fallback (search --label)
# from resolving to the wrong slot. Cheap, and the window where it is wrong is this hook's own.
btrfs filesystem label "$dev_root" "novadeck-root-${target^^}" >/dev/null \
  || die "cannot label $dev_root as novadeck-root-${target^^}"
log "fsid randomised, label set to novadeck-root-${target^^}"

# --- 2. per-slot /var ---------------------------------------------------------------------------
# Reformat, then copy the RUNNING /var over wholesale, then stamp the slot's own identity onto it.
# seed_var mounts and unmounts $MNT itself and carries the reasoning for all three; the source is a
# DIRECTORY here, which is what makes this the OTA case (the installer passes a seed tarball,
# because on a fresh disk there is no running system whose /var describes the device).
seed_var "$dev_var" "$target" "$MNT" "$VAR"

# --- 3. stage 2: the target's efi partition + the shared ESP ------------------------------------
# Safe to mount the root now: the fsid was re-randomised in step 1, so this cannot alias the
# running root. The efi partition is mounted so the partsets can be written after the boot files
# from the same mounted tree.
mount -o ro "$dev_root" "$MNT" || die "cannot mount the target root to read its boot files"
trap 'umount "$MNT" 2>/dev/null || true; umount "$EFIMNT" 2>/dev/null || true' EXIT

mkdir -p "$EFIMNT"
mount "$dev_efi" "$EFIMNT" || die "cannot mount the target efi partition ($dev_efi)"

# The efi partitions are not RAUC slots (etc/rauc/system.conf declares only rootfs.0/rootfs.1, and
# the bundle carries only rootfs.img), so the only thing that ever writes them on an update is this
# block. write_efi_partition carries the rest of the reasoning, including why it copies onto the
# partition rather than wiping it -- parts.env lives there and an update cannot rebuild it.
BOOTDIR="$MNT/usr/lib/novadeck/boot"
write_efi_partition "$EFIMNT" "$target" "$BOOTDIR"
log "stage-2 GRUB + grub.cfg + font installed on $dev_efi"

# Partsets: copied from the RUNNING efi partition -- they are disk-derived (partition uuids), so
# both efi partitions carry the same A/B/all/shared files and only self/other change, re-pointed at
# the target so steamcl identifies this partition as its own image. This is Valve's
# configure_other_efi shape (cp all/shared verbatim, swap self/other), always run rather than only
# on a missing dir: an install must leave the target efi naming the RIGHT image.
partsets="$EFI/SteamOS/partsets"
[ -d "$partsets" ] || die "the booted slot's efi partition has no $EFI/SteamOS/partsets -- this card needs a reflash"
mkdir -p "$EFIMNT/SteamOS/partsets"
for f in all shared A B; do
  cp "$partsets/$f" "$EFIMNT/SteamOS/partsets/$f" || die "cannot copy partsets/$f"
done
cp "$partsets/$target" "$EFIMNT/SteamOS/partsets/self"  || die "cannot write partsets/self"
cp "$partsets/$booted" "$EFIMNT/SteamOS/partsets/other" || die "cannot write partsets/other"
if [ -e "$partsets/dev" ]; then cp "$partsets/dev" "$EFIMNT/SteamOS/partsets/dev"; fi
log "partsets refreshed on $dev_efi (self=$target other=$booted)"

umount "$EFIMNT"; rm -rf "$EFIMNT"; trap 'umount "$MNT" 2>/dev/null || true' EXIT

# The shared ESP's steamcl (stage 1) is refreshed from the installed root too, so it is the same
# build that owns the stage 2 written above. The mountpoint check is the OTA path's own: the ESP
# comes up through an fstab automount here, whereas the installer mounts it itself.
ls "$ESP" >/dev/null 2>&1 || true         # trigger the fstab automount if it is not up
mountpoint -q "$ESP" || die "the ESP is not mounted at $ESP"
refresh_esp_stage1 "$ESP" "$BOOTDIR"

umount "$MNT"; trap - EXIT

# --- 4. bootconf write + re-arm -----------------------------------------------------------------
# The ESP must name the target image: it is the highest-priority, unmarked image on the next boot.
# Two statements, in this order:
#
#   create/ensure the conf   -- the target's conf exists (RAUC's backend set-primary already
#                              created it via ensure_exists, but a handler that ran outside RAUC
#                              may be the first writer).
#   set image-invalid 0      -- RAUC's pre-write `set-state <target> bad` marked it invalid; only
#                              a COMPLETED install may take that back, and this is the only place
#                              that knows the install completed. Miss it and the slot stays
#                              disabled and never boots.
#   set boot-attempts 0      -- the counter measures attempts at THE TRIAL WE ARE ARMING, so it has
#                              to start at zero. `set-mode reboot` does not clear it (only
#                              `set-mode booted`, i.e. mark-good, does), and nothing else ever
#                              clears a slot that is not booting -- so whatever the target
#                              accumulated while it sat idle is still there, and the trial inherits
#                              it. Observed on HW 2026-09-01: a healthy internal slot A sat at 2
#                              from counts landing on it under issue #84, which would put its next
#                              trial boot at 3 -- steamcl's failsafe menu threshold -- and a slot
#                              at 5 would reach 6 and be auto-rejected in favour of the other one.
#                              A perfect install, rolled back on its first boot, for history.
#   set-mode reboot          -- the re-arm, the direct inverse of step 0: the target gets the
#                              highest boot-requested-at so the next boot goes there.
conf="$ESP/SteamOS/conf/$target.conf"
if [ ! -f "$conf" ]; then
  mkdir -p "$ESP/SteamOS/conf"
  bc create --image "$target" --set title "$target" || die "cannot create the bootconf for $target"
  log "created $conf"
fi
bc --image "$target" config --set image-invalid 0 || die "cannot clear the invalid mark on $target"
bc --image "$target" config --set boot-attempts 0 || die "cannot reset the attempt counter on $target"
bc --image "$target" set-mode reboot || die "cannot re-arm slot $target for its trial boot"

log "slot $target re-armed for a trial boot; reboot to try it"
