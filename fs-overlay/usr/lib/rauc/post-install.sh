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
# (images/test-post-install.sh) executes THIS file -- not a copy -- so what it asserts is the
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
DEVDIR=${DEVDIR:-/dev/disk/by-partlabel}
DEVTEST=${DEVTEST:--b}
BC=${BC:-steamos-bootconf}
BC_ARGS=(--conf-dir "$ESP/SteamOS/conf" --efi-dir "$EFI")
bc() { "$BC" "${BC_ARGS[@]}" "$@"; }

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

# The LABEL is the other identity the byte copy got wrong. images/assemble-rootfs.sh bakes
# novadeck-root-A into the image, RAUC writes that image verbatim to whichever slot it targets,
# and nothing else corrects it -- so without this, both partitions answer to novadeck-root-A.
# Stage 2 normally addresses the root by partition index, so this is not what makes the slot boot;
# it is what makes `blkid` honest and what keeps stage 2's documented fallback (search --label)
# from resolving to the wrong slot. Cheap, and the window where it is wrong is this hook's own.
btrfs filesystem label "$dev_root" "novadeck-root-${target^^}" >/dev/null \
  || die "cannot label $dev_root as novadeck-root-${target^^}"
log "fsid randomised, label set to novadeck-root-${target^^}"

# --- 2. per-slot /var ---------------------------------------------------------------------------
# Reformat, then copy the RUNNING /var over wholesale. This used to be a hand-picked whitelist
# (machine-id, then NetworkManager connections, then SSH host keys...) and that shape was wrong:
# every new piece of per-device state has to be REMEMBERED here, and forgetting one fails SILENTLY
# -- the update succeeds, the slot boots, and something is subtly a different device. On hardware
# with no serial console that is the worst failure shape available. A full copy inverts it: state
# survives by default, and anything we do NOT want has to be excluded on purpose, in writing, here.
# (SteamOS reaches the same conclusion; cf. _reference/steamos-teardown/docs/system-updates.md §4,
# which rsyncs the whole partition after reformatting it.)
#
# The reformat stays: the target's /var is whatever the PREVIOUS install left there, and stale
# state is what makes a slot behave differently from the one that was tested. Reformat + full copy
# means the target ends up with exactly the running slot's state and nothing else.
mkfs.ext4 -q -F -L "novadeck-var-${target^^}" "$dev_var" || die "cannot reformat $dev_var"

mkdir -p "$MNT"
mount "$dev_var" "$MNT" || die "cannot mount the target /var ($dev_var)"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

# rsync, added to the image for exactly this (images/customize-base.sh PKGS). -aHAX preserves
# modes, owners, hard links, ACLs and xattrs. Modes matter more than they look: sshd refuses to
# start if a private host key is group/world-readable, so a mode-losing copy would take SSH down on
# the updated slot and nowhere else. --numeric-ids because we are copying between two roots rather
# than resolving names through THIS one's passwd.
#
# --one-file-system is LOAD-BEARING. /var/log, /var/tmp, /var/cache/pacman, /var/lib/flatpak and
# /var/lib/systemd/coredump are bind mounts from the SHARED /home offload tree, i.e. not in this
# partition at all. Without it we would copy shared data into a 256M partition -- /var/log alone
# can exceed it -- and duplicate what both slots already share. The mount points themselves need no
# special handling: systemd creates a .mount unit's target directory if it is missing.
#
# Source is `/var/` with the trailing slash: copy the CONTENTS of /var into $MNT, not a /var/var.
rsync -aHAX --numeric-ids --one-file-system "$VAR/" "$MNT/" \
  || die "cannot copy /var to the target slot"
log "copied /var wholesale ($(du -sh -x "$VAR" 2>/dev/null | cut -f1), offload bind mounts skipped)"

# The overlay dirs must exist before the target boots -- the initramfs mounts /etc from them, so a
# slot missing them does not come up. They are copied from the running /var above; this is a guard
# against the one case that would be unrecoverable, not an expectation that the copy failed.
upper="$MNT/lib/overlays/etc/upper"
mkdir -p "$upper" "$MNT/lib/overlays/etc/work" "$MNT/lib/novadeck"

# THE ONE FILE THAT MUST NOT SURVIVE THE COPY VERBATIM. Everything else in /var describes the
# DEVICE and is correct on either slot; this describes WHICH SLOT it is. Written last, deliberately
# after the wholesale copy that would otherwise clobber it.
printf '%s\n' "$target" >"$MNT/lib/novadeck/slot"

# THE SECOND THING THE COPY MUST NOT KEEP: /var/lib/novadeck/mac-wifi, the write-once record of
# this device's derived Wi-Fi MAC. Deleted so the target re-derives it from the machine-id that the
# copy above just carried over (gen-mac.sh: sha256(machine-id)).
#
# On a healthy device this is a no-op in effect -- same machine-id in, same MAC out, so the address
# is stable across the update, which is the requirement. It matters for the devices where it is NOT
# a no-op: a unit flashed before the MAC-collision fix has a COLLIDING address persisted here, and
# because the file is write-once and outranks the derivation, that unit keeps the bad MAC forever.
rm -f "$MNT/lib/novadeck/mac-wifi"

umount "$MNT"; trap - EXIT

# --- 3. stage 2: the target's efi partition + the shared ESP ------------------------------------
# Safe to mount the root now: the fsid was re-randomised in step 1, so this cannot alias the
# running root. The efi partition is mounted so the partsets can be written after the boot files
# from the same mounted tree.
mount -o ro "$dev_root" "$MNT" || die "cannot mount the target root to read its boot files"
trap 'umount "$MNT" 2>/dev/null || true; umount "$EFIMNT" 2>/dev/null || true' EXIT

mkdir -p "$EFIMNT"
mount "$dev_efi" "$EFIMNT" || die "cannot mount the target efi partition ($dev_efi)"

# Stage 2: this build's GRUB + its per-slot grub.cfg + the boot font (grub.cfg references it via
# $prefix/fonts/). All three come out of the installed root, so they are the pairing with the
# kernel the root carries.
grub_efi="$MNT/usr/lib/novadeck/boot/grubaa64.efi"
grub_cfg="$MNT/usr/lib/novadeck/boot/grub-${target,,}.cfg"
grub_font="$MNT/usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
[ -f "$grub_efi" ] || die "the installed root carries no stage-2 GRUB at /usr/lib/novadeck/boot/grubaa64.efi"
[ -f "$grub_cfg" ] || die "the installed root carries no /usr/lib/novadeck/boot/grub-${target,,}.cfg"
[ -f "$grub_font" ] || die "the installed root carries no boot font at /usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
mkdir -p "$EFIMNT/EFI/steamos/fonts"
cp "$grub_efi"  "$EFIMNT/EFI/steamos/grubaa64.efi" || die "cannot install grubaa64.efi on the target efi"
cp "$grub_cfg"  "$EFIMNT/EFI/steamos/grub.cfg"      || die "cannot install grub.cfg on the target efi"
cp "$grub_font" "$EFIMNT/EFI/steamos/fonts/dejavu-mono.pf2" || die "cannot install the boot font"
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

# The shared ESP's steamcl (stage 1) is refreshed from the installed root too. ABL chainloads
# /EFI/BOOT/bootaa64.efi, so that is the copy that matters. Companion files in /EFI/BOOT/ are
# resolved by steamcl's resolve_path() relative to the chainloader location. Content-identical
# when unchanged -- skip rather than rewrite the ESP's live boot files on every update.
ls "$ESP" >/dev/null 2>&1 || true         # trigger the fstab automount if it is not up
mountpoint -q "$ESP" || die "the ESP is not mounted at $ESP"
refresh_if_diff() {  # <src> <dst>
  if ! cmp -s "$1" "$2"; then
    cp -f "$1" "$2" || die "cannot refresh $2"
    sync
    log "refreshed $2"
  fi
}
steamcl="$MNT/usr/lib/novadeck/boot/steamcl.efi"
steamcl_ver="$MNT/usr/lib/novadeck/boot/steamcl-version"
stage_font="$MNT/usr/lib/novadeck/boot/fonts/default.pf2"
[ -f "$steamcl" ] || die "the installed root carries no /usr/lib/novadeck/boot/steamcl.efi"
mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/BOOT/fonts"
refresh_if_diff "$steamcl" "$ESP/EFI/BOOT/bootaa64.efi"
refresh_if_diff "$steamcl_ver" "$ESP/EFI/BOOT/steamcl-version"
refresh_if_diff "$stage_font" "$ESP/EFI/BOOT/fonts/default.pf2"
# steamcl-restricted is an empty flag file; ensure it exists
: >"$ESP/EFI/BOOT/steamcl-restricted"
sync

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
#   set-mode reboot          -- the re-arm, the direct inverse of step 0: the target gets the
#                              highest boot-requested-at so the next boot goes there.
conf="$ESP/SteamOS/conf/$target.conf"
if [ ! -f "$conf" ]; then
  mkdir -p "$ESP/SteamOS/conf"
  bc create --image "$target" --set title "$target" || die "cannot create the bootconf for $target"
  log "created $conf"
fi
bc --image "$target" config --set image-invalid 0 || die "cannot clear the invalid mark on $target"
bc --image "$target" set-mode reboot || die "cannot re-arm slot $target for its trial boot"

log "slot $target re-armed for a trial boot; reboot to try it"
