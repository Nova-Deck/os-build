#!/bin/bash
# The UDEV ENTRY POINT for removable storage: decides whether a block-device event deserves a mount
# at all, and hands the work to automount.sh if it does.
#
#   /usr/lib/novadeck/storage/block-event.sh add|remove <partition kernel name>
#
# WHY THIS FILE EXISTS AS A SEPARATE FILE, which is the whole point of it. There are two different
# questions here:
#
#   "should this udev event be acted on?"   lock, settle, was-the-media-just-inserted   <- HERE
#   "mount this partition"                  fstype, fsck, mount, ownership, symlink     <- automount.sh
#
# and there are two callers who need different answers. udev fires on events that are not
# insertions — a partition table rewrite emits `add` too — so its path has to filter. The FORMATTER
# has just made a filesystem on purpose and must never be filtered: it calls automount.sh directly.
#
# Both questions used to live in automount.sh behind a "was I called by the formatter" guard, and
# forgetting that guard broke this feature twice on hardware in one afternoon:
#
#   - the lock would have refused the formatter's own post-format mount (caught by reading);
#   - the recency check DID refuse it — "skipping /dev/mmcblk0p1: its media was not inserted
#     recently" logged immediately after "formatted /dev/mmcblk0p1 as ext4+casefold" — leaving the
#     card unmounted and the client still offering to format it.
#
# The guard worked once it was written. This shape means there is nothing to remember: the mounter
# contains no event-filtering code, so it cannot misapply any. It is the split the reference
# platform has (block-device-event.sh vs holo-automount.sh), adopted after paying for its absence.
set -euo pipefail

. /usr/lib/novadeck/storage/lib-storage.sh

PROG="${0##*/}"
ACTION="${1:-}"
DEVBASE="${2:-}"
DEVICE="/dev/$DEVBASE"
MOUNTER=/usr/lib/novadeck/storage/automount.sh

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

[ -n "$ACTION" ] && [ -n "$DEVBASE" ] || { log "usage: $PROG add|remove <partition>"; exit 22; }

# Removal is not filtered: there is nothing to decide, and tidying up after a device that is already
# gone must not depend on how recently anything was inserted.
[ "$ACTION" = remove ] && exec "$MOUNTER" remove "$DEVBASE"
[ "$ACTION" = add ] || { log "unknown action: $ACTION"; exit 22; }

# THE LOCK, held from here to the end of the mount. The formatter holds the same lock for its whole
# run, so while a card is being formatted this exits quietly instead of racing it: rewriting a
# partition table and running mkfs both emit udev events on the very device being formatted, and one
# of them previously got as far as asking udisks to mount a partition mkfs was still writing
# ("fsconfig() failed: Can't open blockdev").
#
# EXIT 0: a format in progress is a reason not to mount, not a failure to report. The formatter
# mounts the card itself when it is done.
#
# The lock is held on fd 9 and survives the exec below, so automount.sh runs inside it and needs no
# lock logic of its own.
if ! storage_lock "$DEVBASE"; then
    log "skipping $DEVICE: a format is in progress"
    exit 0
fi

# LET UDEV FINISH BEFORE ANYTHING TALKS TO UDISKS. Upstream's reason, in its own words: "Prior to
# talking to udisks, we need all udev hooks (we were started by one) to finish, so we know it has
# knowledge of the drive." Safe to wait here because the rule hands us to systemd through
# SYSTEMD_WANTS rather than RUN+=, so udev is not blocked on this unit and cannot deadlock with it.
udevadm settle --timeout=10 >/dev/null 2>&1 \
    || log "udevadm settle timed out; continuing anyway"

# WAS THIS MEDIA ACTUALLY JUST INSERTED? `add` also arrives when a device is REPARTITIONED, by us or
# by anything else, and Drive.TimeMediaDetected is how upstream tells the two apart. 30 seconds
# rather than upstream's 5, following the reference platform, which widened it for ARM handhelds
# where this whole path is slower.
#
# SKIPPED BEFORE multi-user.target, exactly as upstream does: at cold boot the events for a card
# already in the slot can arrive long after the media was detected, and refusing those is the boot
# case this branch has already fixed once.
#
# FAILS OPEN. This is a second guard for a case the lock already covers; a card that does not mount
# because a D-Bus property could not be read is a worse outcome than a spurious mount.
if systemctl -q check multi-user.target 2>/dev/null; then
    drive="$(busctl get-property org.freedesktop.UDisks2 \
                "/org/freedesktop/UDisks2/block_devices/$DEVBASE" \
                org.freedesktop.UDisks2.Block Drive 2>/dev/null | sed -n 's/^o "\(.*\)"$/\1/p')"
    detected_us=""
    [ -n "$drive" ] && detected_us="$(busctl get-property org.freedesktop.UDisks2 "$drive" \
                org.freedesktop.UDisks2.Drive TimeMediaDetected 2>/dev/null | sed -n 's/^t \([0-9]*\)$/\1/p')"
    if [ -n "${detected_us:-}" ] && [ "$detected_us" -gt 0 ] 2>/dev/null; then
        if [ $(( detected_us / 1000000 + 30 )) -lt "${EPOCHSECONDS:-0}" ]; then
            log "skipping $DEVICE: its media was not inserted recently (this event is a repartition, not an insert)"
            exit 0
        fi
    else
        log "could not read Drive.TimeMediaDetected for $DEVICE; continuing without the recency check"
    fi
fi

exec "$MOUNTER" add "$DEVBASE"
