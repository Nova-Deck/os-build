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
# Reformat rather than rsync-over: the target's /var is whatever the PREVIOUS install left there,
# and stale state is exactly what makes a slot behave differently from the one that was tested.
mkfs.ext4 -q -F -L "novadeck-var-${target^^}" "$dev_var" || die "cannot reformat $dev_var"

mkdir -p "$MNT"
mount "$dev_var" "$MNT" || die "cannot mount the target /var ($dev_var)"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

upper="$MNT/lib/overlays/etc/upper"
mkdir -p "$upper" "$MNT/lib/overlays/etc/work" "$MNT/lib/novadeck"

# machine-id ONLY -- deliberately NOT a blanket copy of /var.
#
# TRAP (recorded in TODO.md): /var/lib/novadeck/mac-wifi is write-once and takes PRECEDENCE over
# the seed (gen-mac.sh), so copying it would pin the old MAC forever regardless of machine-id --
# the original machine-id bug relocated, not fixed. Migrating machine-id alone is the smaller and
# more correct primitive: the MAC then re-derives from it on its own, and the two slots cannot
# disagree about which is the source of truth.
if [ -r /etc/machine-id ]; then
  install -m0444 /etc/machine-id "$upper/machine-id"
  log "machine-id migrated (MAC will re-derive from it)"
else
  log "WARNING: no /etc/machine-id to migrate -- the updated slot will mint its own identity"
fi

# Network configuration. On a RELEASE image this is the difference between an updated device that
# is reachable and one that is not: this is Wi-Fi-only and has no serial console, so a slot with no
# saved connections has no way back in. SteamOS copies these explicitly too, for the same reason.
src_nm=/etc/NetworkManager/system-connections
if [ -d "$src_nm" ] && [ -n "$(ls -A "$src_nm" 2>/dev/null)" ]; then
  mkdir -p "$upper/NetworkManager/system-connections"
  cp -a "$src_nm/." "$upper/NetworkManager/system-connections/"
  chmod 0700 "$upper/NetworkManager/system-connections"
  log "copied $(ls -1 "$src_nm" | wc -l) network connection(s)"
else
  log "WARNING: no saved network connections to copy -- the updated slot may come up offline"
fi

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
