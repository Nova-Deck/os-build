#!/usr/bin/env bash
# novadeck internal-install RAUC post-install handler — Phase 4a of
# .claude/plans/internal-install.plan.md.
#
# Named in the config installer/rauc-session.sh synthesizes, so it runs inside that session, after
# RAUC has written and unmounted the one slot it knows about. It is a DISTINCT handler from
# /usr/lib/rauc/post-install.sh rather than a mode of it: that one needs /esp, /efi,
# `steamos-bootconf this-image` and a running /var to rsync, and on a disk with no novadeck on it
# none of those exist. What the two do share is lib-slotwrite.sh, sourced below, which is where the
# reasoning for each primitive lives.
#
# THE DIVISION OF LABOUR WITH THE SPINE, because it is not obvious and it is the thing to keep:
# this handler owns the SLOT, novadeck-install owns the DISK. So the fsid and the per-slot /var are
# here -- they are true of the bytes RAUC just wrote, whatever disk they landed on -- while the efi
# partitions, the shared ESP, the partsets, /home and A.conf are the spine's, because they describe
# a layout RAUC knows nothing about.
#
# WHY THE fsid IS RANDOMISED ON A *FRESH* INSTALL, where there is no second slot to alias against.
# mkfs.btrfs bakes an fsid into the superblock and every image we build also has devid=1, which is
# exactly the pair btrfs keys its in-kernel device list on: the second filesystem scanned carrying
# that pair is treated as the first one having MOVED, and its path silently replaces it. On an OTA
# the collision is A against B. Here it is the internal root against ANY OTHER DISK carrying the
# same release -- and the user installing internally has one in their hand, since a novadeck SD
# card is how they got here. Leave the baked fsid in place and the day they boot internally with
# that card still in the slot, a mount of one can hand them the other. The label is separately
# correct on this path (the image is built as novadeck-root-A and slot A is what a fresh install
# writes), and it is set anyway so `blkid` is honest about a filesystem whose fsid just changed.
set -euo pipefail

PROG=${0##*/}
log() { printf '[%s] %s\n' "$PROG" "$1"; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

# A fresh install writes slot A and only slot A. B is left empty with no B.conf, matching the
# release card's shape so steamcl sees one image and retries A rather than switching into a slot
# that has no kernel; the first OTA fills it. So this is a constant, not a decision.
SLOT=A

MNT=${MNT:-/run/novadeck/install/root}
VARMNT=${VARMNT:-/run/novadeck/install/var}
BTRFSTUNE=${BTRFSTUNE:-btrfstune}
BTRFS=${BTRFS:-btrfs}
VAR_SEED_REL=${VAR_SEED_REL:-usr/lib/novadeck/var-seed.tar.zst}
DEVTEST=${DEVTEST:--b}

# The spine tells us where /var goes. It cannot be derived here: RAUC's config names exactly one
# slot and it is the root, deliberately (see rauc-session.sh), so this process has no view of the
# partition table at all. Missing is fatal rather than skippable -- a slot with no /var does not
# boot, and discovering that is a reflash.
VAR_DEV=${NOVADECK_TARGET_VAR_A:-}
[ -n "$VAR_DEV" ] || die "NOVADECK_TARGET_VAR_A is unset -- the spine must name the slot's /var partition"

# lib-slotwrite.sh, resolved by search for the same reason carve.sh resolves genpart.sh that way:
# on the installer image it is installed beside this file, and in the repo it lives under
# rootfs/overlay/ because the OTA path ships it. Both are right; neither is a repo-relative constant.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
SLOTWRITE="${NOVADECK_SLOTWRITE:-}"
if [ -z "$SLOTWRITE" ]; then
  for c in "$SELFDIR/lib-slotwrite.sh" \
           /usr/lib/novadeck/install/lib-slotwrite.sh \
           "$SELFDIR/../rootfs/overlay/usr/lib/novadeck/install/lib-slotwrite.sh"; do
    [ -r "$c" ] && { SLOTWRITE="$c"; break; }
  done
fi
[ -n "$SLOTWRITE" ] && [ -r "$SLOTWRITE" ] \
  || die "cannot find lib-slotwrite.sh (set NOVADECK_SLOTWRITE)"
# shellcheck source=../rootfs/overlay/usr/lib/novadeck/install/lib-slotwrite.sh
. "$SLOTWRITE"

# --- which device did RAUC just write? ----------------------------------------------------------
# RAUC_TARGET_SLOTS is an ITERATOR OF INTEGERS, not of names -- `for i in $RAUC_TARGET_SLOTS` then
# RAUC_SLOT_DEVICE_$i, as reference.rst:1745 spells it and as install.c builds it ("%i", slotcnt).
# It reads like a name list and is not one, which is worth stating because matching it against a
# slot name is a comparison that can never be true and therefore never fires.
[ -n "${RAUC_TARGET_SLOTS:-}" ] \
  || die "RAUC_TARGET_SLOTS is unset -- this handler must be run by rauc, not by hand"
ROOT_DEV=""; n_targets=0
for i in $RAUC_TARGET_SLOTS; do
  n_targets=$(( n_targets + 1 ))
  eval "ROOT_DEV=\${RAUC_SLOT_DEVICE_$i:-}"
done
[ "$n_targets" -eq 1 ] \
  || die "rauc wrote $n_targets slots; the installer config declares exactly one and this handler assumes it"
[ -n "$ROOT_DEV" ] || die "rauc named a target slot but no device for it"
# shellcheck disable=SC2086  # DEVTEST is a predicate, not a path
[ $DEVTEST "$ROOT_DEV" ] || die "$ROOT_DEV is not a block device"
# shellcheck disable=SC2086
[ $DEVTEST "$VAR_DEV" ] || die "$VAR_DEV is not a block device"

# Every tool, asserted together and before the first destructive call. btrfstune runs at step 1 and
# mkfs.ext4 at step 2, and a handler that died between them would leave a slot whose fsid is
# randomised and whose /var is gone -- unbootable, and not obviously so. The installer image is a
# different root from the shipped one, so "it was there yesterday" is not an argument here.
for t in "$BTRFSTUNE" "$BTRFS" mkfs.ext4 tar mount umount; do
  command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH -- the installer image is missing it"
done

log "slot $SLOT: root $ROOT_DEV, var $VAR_DEV"

# --- 1. fsid + label ------------------------------------------------------------------------------
# MUST come before anything mounts the target, which is why it is step 1 and why step 2 is below it
# rather than beside it. -f because the filesystem is a byte copy of one that was mounted when it
# was imaged, which btrfstune otherwise refuses.
"$BTRFSTUNE" -f -U "$(cat /proc/sys/kernel/random/uuid)" "$ROOT_DEV" >/dev/null \
  || die "btrfstune could not re-randomise the fsid of $ROOT_DEV"
"$BTRFS" filesystem label "$ROOT_DEV" "novadeck-root-$SLOT" >/dev/null \
  || die "cannot label $ROOT_DEV as novadeck-root-$SLOT"
log "fsid randomised, label set to novadeck-root-$SLOT"

# --- 2. per-slot /var -------------------------------------------------------------------------------
# The source is a TARBALL here, and that is what makes this the installer case: the OTA path passes
# the RUNNING /var because there is a live system whose state describes the device, and here the
# running system is the installer image, whose /var describes the INSTALLER. So the seed comes out
# of the root that was just written -- rootfs/assemble-rootfs.sh packs $varstage into it for exactly
# this. Safe to mount now: step 1 re-randomised the fsid, so this cannot alias another disk's root.
mkdir -p "$MNT" || die "cannot create $MNT"
mount -o ro "$ROOT_DEV" "$MNT" || die "cannot mount the freshly written root to read its /var seed"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

seed_var "$VAR_DEV" "$SLOT" "$VARMNT" "$MNT/$VAR_SEED_REL"

umount "$MNT"; trap - EXIT
log "slot $SLOT prepared; the spine owns the disk from here"
