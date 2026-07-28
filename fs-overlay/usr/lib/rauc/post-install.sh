#!/usr/bin/env bash
# novadeck RAUC post-install handler — Phase 4b pass 2.
#
# Runs after RAUC has written and unmounted the target slot. A freshly written slot is NOT usable
# until this has run: the bytes are an exact copy of the running slot, so it shares an fsid, it has
# no per-slot identity in /var, and it carries a kernel nothing has installed yet.
#
# Order is load-bearing:
#
#   1. fsid       -- MUST come before anything mounts the target. Until btrfstune has run, the
#                    target and the running root share an fsid AND devid=1, which is the pair
#                    btrfs keys its in-kernel device list on: the second one scanned is treated as
#                    the first having MOVED, so mounting the target can silently hand you the
#                    RUNNING root. Every later step here mounts the target, so this is step 1.
#   2. /var       -- per-slot identity. Without it the updated slot boots as a different device.
#   3. /KERNEL    -- rotate the ESP boot image, keeping the previous one as KERNEL.BAK.
#
# WHY THE KERNEL COMES OUT OF THE NEW ROOT AND NOT THE BUNDLE: /lib/modules/<ver> lives in the
# rootfs, so the kernel that matches it is the one that root shipped with. Taking it from the root
# makes the pairing true by construction -- there is no bundle layout to keep in sync, and no way
# to install a root whose modules do not match the kernel that will boot it. (CFG80211/ATH12K are
# =m, so a mismatch here means a device with no Wi-Fi and no serial console.)
#
# Slot naming is the lowercase letter used everywhere: ESP state, initramfs, novadeck-bootctl,
# and `bootname=` in /etc/rauc/system.conf. No mapping layer.
set -euo pipefail

PROG=${0##*/}
log()  { printf '[%s] %s\n' "$PROG" "$1"; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

ESP=/efi                      # systemd gpt-auto automount; touching it is what triggers the mount
KERNEL_IN_ROOT=usr/lib/novadeck/boot.img
MNT=/run/novadeck/rauc-target

# --- which slot did we just write? ------------------------------------------------------------
# RAUC exports the target slot(s), but this must not DEPEND on that: the whole update is worthless
# if we touch the wrong slot, and we have our own authoritative answer -- the slot this system
# booted, from the initramfs handoff. The target is simply the other one. RAUC's value is used only
# to cross-check, and a disagreement is fatal rather than resolved by preference.
booted=$(sed -n 's/^slot=//p' /run/novadeck/boot 2>/dev/null || true)
case "$booted" in
  a) target=b ;;
  b) target=a ;;
  *) die "this system did not boot from a slot (slot='$booted') -- refusing to guess a target" ;;
esac

if [ -n "${RAUC_TARGET_SLOTS:-}" ]; then
  # RAUC names slots as they appear in system.conf ("rootfs.0"/"rootfs.1"); map to our letters.
  case "${RAUC_TARGET_SLOTS}" in
    *rootfs.0*) rauc_target=a ;;
    *rootfs.1*) rauc_target=b ;;
    *)          rauc_target='' ;;
  esac
  if [ -n "$rauc_target" ] && [ "$rauc_target" != "$target" ]; then
    die "RAUC says it wrote slot '$rauc_target' but this system booted '$booted' (target '$target') -- refusing"
  fi
fi

case "$target" in
  a) dev_root=/dev/disk/by-partlabel/novadeck-root-A; dev_var=/dev/disk/by-partlabel/novadeck-var-A ;;
  b) dev_root=/dev/disk/by-partlabel/novadeck-root-B; dev_var=/dev/disk/by-partlabel/novadeck-var-B ;;
esac
[ -b "$dev_root" ] || die "no block device at $dev_root"
[ -b "$dev_var" ]  || die "no block device at $dev_var"
log "target slot $target ($dev_root)"

# --- 1. fsid ------------------------------------------------------------------------------------
# -f because the filesystem is a byte copy of a mounted one, which btrfstune otherwise refuses.
btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$dev_root" >/dev/null \
  || die "btrfstune could not re-randomise the fsid of $dev_root"
log "fsid randomised"

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
rsync -aHAX --numeric-ids --one-file-system /var/ "$MNT/" \
  || die "cannot copy /var to the target slot"
log "copied /var wholesale ($(du -sh -x /var 2>/dev/null | cut -f1), offload bind mounts skipped)"

# The overlay dirs must exist before the target boots -- the initramfs mounts /etc from them, so a
# slot missing them does not come up. They are copied from the running /var above; this is a guard
# against the one case that would be unrecoverable, not an expectation that the copy failed.
upper="$MNT/lib/overlays/etc/upper"
mkdir -p "$upper" "$MNT/lib/overlays/etc/work" "$MNT/lib/novadeck"

# THE ONE FILE THAT MUST NOT SURVIVE THE COPY VERBATIM. Everything else in /var describes the
# DEVICE and is correct on either slot; this describes WHICH SLOT it is. It is the independent
# witness `novadeck-bootctl status` cross-checks the initramfs's choice against, so a copy that
# left the source slot's letter here would make the target agree with a lie. Written last,
# deliberately after the wholesale copy that would otherwise clobber it.
printf '%s\n' "$target" >"$MNT/lib/novadeck/slot"

# NOT excluded, and this reverses an earlier decision worth stating: /var/lib/novadeck/mac-wifi.
# The old whitelist called it a trap -- write-once, and takes precedence over the machine-id-derived
# seed, so copying it "pins the old MAC forever regardless of machine-id". That only bites if the
# seed and machine-id can disagree, which required copying one without the other. A full copy takes
# both, they agree by construction, and the MAC stays stable across the update -- which was the
# actual requirement all along. Copying it is now the correct behaviour, not the hazard.

# The independent slot witness make-sdcard.sh writes, so `novadeck-bootctl status` can still
# cross-check the initramfs's choice against a filesystem that carries its own letter.
printf '%s\n' "$target" >"$MNT/lib/novadeck/slot"

umount "$MNT"; trap - EXIT

# --- 3. /KERNEL rotation ------------------------------------------------------------------------
# Safe to mount now: the fsid was re-randomised in step 1, so this cannot alias the running root.
mount -o ro "$dev_root" "$MNT" || die "cannot mount the target root to read its kernel"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

src_kernel="$MNT/$KERNEL_IN_ROOT"
[ -f "$src_kernel" ] || die "the installed root carries no boot image at /$KERNEL_IN_ROOT"

ls "$ESP" >/dev/null 2>&1 || true         # trigger the automount
mountpoint -q "$ESP" || die "the ESP is not mounted at $ESP"

# Copy in, then rotate: a torn copy must never be able to land on /KERNEL. cp to a temp name on the
# same filesystem, sync it, and only then move the old one aside and put the new one in place.
cp "$src_kernel" "$ESP/KERNEL.NEW" || die "cannot stage the new kernel onto the ESP"
sync "$ESP/KERNEL.NEW" 2>/dev/null || sync
if [ -f "$ESP/KERNEL" ]; then
  cp "$ESP/KERNEL" "$ESP/KERNEL.BAK" || die "cannot save the current kernel as KERNEL.BAK"
  sync "$ESP/KERNEL.BAK" 2>/dev/null || sync
fi
mv -f "$ESP/KERNEL.NEW" "$ESP/KERNEL" || die "cannot install the new kernel"
sync

umount "$MNT"; trap - EXIT

# Record the backup in the slot state so the initramfs knows a restore is available on rollback.
# novadeck-bootctl owns every write to that file (generation scheme, unknown-key preservation);
# hand-writing it here would be a second writer with none of those properties.
novadeck-bootctl set-bak KERNEL.BAK || die "cannot record the kernel backup in the slot state"

log "kernel rotated (previous kept as KERNEL.BAK); slot $target is ready to be tried"
