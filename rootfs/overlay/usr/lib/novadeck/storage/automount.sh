#!/bin/bash
# Mount an inserted card for the Steam shell — the other half of Settings > Storage.
#
# CALLED BY TWO THINGS AND FILTERS FOR NEITHER: block-event.sh (the udev entry point, which has
# already decided this event deserves a mount) and format-device.sh (which has just made the
# filesystem on purpose). Every "should this event be acted on" question — the lock, udevadm settle,
# was-the-media-just-inserted — lives in block-event.sh, so nothing here can misapply one to a
# caller it was not meant for. That separation is not stylistic: holding those checks in this file
# refused the formatter's own post-format mount and left the card unmounted, twice in one afternoon.
#
#   /usr/lib/novadeck/storage/automount.sh add|remove <partition kernel name>
#
# WHY THE OS HAS TO DO THIS AT ALL. The client enumerates drives over UDisks2 — it carries generated
# bindings for the whole API and a CUDisksDrive::ThreadedAdopt — and on this hardware it does notice
# a card: the status bar shows one. What it does NOT do is mount it. Measured 2026-09-02 on an
# internally-installed device: card in, udisksd answering, nothing under /run/media and nothing in
# Settings > Storage.
#
# IT MOUNTS THROUGH UDISKS2 RATHER THAN CALLING mount(8), and that is not ceremony. udisks owns the
# mountpoint namespace the client reads (/run/media/<user>/<label>), applies the filesystem-specific
# option whitelist, and — via as-user — makes the mount belong to the session user rather than to
# root. A hand-rolled mount lands somewhere the client is not looking, with the wrong owner.
#
# THE SESSION USER IS RESOLVED FROM uid 1000, not from `id -u deck`. The name is ours to choose and
# the id is pinned in sysusers.d; a udev-triggered unit that dies because a name changed is a card
# that silently stops mounting.
set -euo pipefail

. /usr/lib/novadeck/storage/lib-storage.sh

PROG="${0##*/}"
ACTION="${1:-}"
DEVBASE="${2:-}"
DEVICE="/dev/$DEVBASE"

DECK_UID=1000
DECK_USER="$(id -nu "$DECK_UID" 2>/dev/null || echo deck)"

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

[ -n "$ACTION" ] && [ -n "$DEVBASE" ] || { log "usage: $PROG add|remove <partition>"; exit 22; }

# --- remove: let udisks tidy up, then drop our compatibility symlink ------------------------------
if [ "$ACTION" = remove ]; then
    for link in /run/media/"$DEVBASE" /run/media/novadeck-*; do
        [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link"
    done
    exit 0
fi

[ "$ACTION" = add ] || { log "unknown action: $ACTION"; exit 22; }
[ -b "$DEVICE" ] || { log "not a block device: $DEVICE"; exit 0; }

DISK="$(storage_disk_of "$DEVICE")" || exit 0

# THE SAME PREDICATES THE FORMATTER USES, for the same reason and in the same order. Mounting is not
# destructive, but adopting a partition off the disk we booted from — or off the vendor's internal
# storage — puts a filesystem the system depends on under the client's management, where the next
# thing offered is a format.
storage_is_sd "$DISK"          || { log "skipping $DEVICE: not a removable SD card"; exit 0; }
storage_is_system_disk "$DISK" && { log "skipping $DEVICE: this system runs from it"; exit 0; }

if findmnt -rn -o SOURCE 2>/dev/null | grep -Fxq "$DEVICE"; then
    log "skipping $DEVICE: already mounted"
    exit 0
fi

# EXT4 ONLY, as upstream does, and for upstream's stated reason: "We need symlinks for Steam for
# now, so only automount ext4 as that's what Steam will format". A library needs symlinks and
# case-folding; vfat and exfat have neither, so a card carrying one cannot host games no matter how
# cleanly it mounts.
#
# The reason this is a REFUSAL and not a convenience: a mounted card with no Steam library on it is
# what the client turns into a drive row that OFFERS to be formatted. Mounting a foreign card gives
# the user a mount they cannot use for the one purpose this whole path exists for, in the place
# where the client is trying to tell them the card needs formatting.
#
# EXIT 0, where upstream exits 2. Inserting a card from another system is a normal thing for a
# person to do, not a fault, and this runs as a templated systemd unit — a non-zero exit leaves a
# failed unit sitting in `systemctl --failed` for the rest of the boot. That distinction cost this
# branch three rounds of chasing failed units that meant nothing.
FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
if [ "$FSTYPE" != ext4 ]; then
    log "skipping $DEVICE: ${FSTYPE:-no filesystem}, not ext4 — a Steam library needs symlinks and casefolding"
    exit 0
fi

# udisks answers on the system bus and is D-Bus activated, so this call is what starts it — ONCE
# THERE IS A BUS. The unit is ordered After=dbus.socket for that reason; see its header.
# as-user is what puts the mount under /run/media/$DECK_USER/ and gives the session ownership of it;
# auth.no_user_interaction because there is no one to ask — this runs from udev, with no session.
#
# STDERR IS KEPT, and that is not a detail. This used to fold stderr into the stdout pipe and then
# sed away everything that was not a mountpoint, so EVERY failure — no bus, no such object, a polkit
# refusal — arrived in the journal as the single line "udisks refused to mount", which named the
# wrong culprit for the one failure that actually happened: at cold boot with a card already in the
# slot, this ran ~8s before dbus-broker was ready and busctl never reached udisks at all
# (HW-caught 2026-09-03). A reason collected and discarded is worse than no reason.
# REPAIR BEFORE MOUNTING, and mount read-only if the repair could not finish. `fsck.ext4 -y` returns
# 0 when the filesystem was clean and 1 when it corrected errors; anything else means it could not
# be made consistent, and mounting such a card read-write is how a card with a damaged journal
# becomes a card with damaged games. Upstream does this and reports the failure to the client with
# a code it calls ABI (steam://system/devicemountresult, FSCK_ERROR=1) — we do not send that URL;
# see the note at the end of this file.
OPTS="noatime"
fsck_rc=0
fsck.ext4 -y "$DEVICE" || fsck_rc=$?
if [ "$fsck_rc" != 0 ] && [ "$fsck_rc" != 1 ]; then
    log "fsck.ext4 could not repair $DEVICE (status $fsck_rc); mounting READ-ONLY"
    OPTS="$OPTS,ro"
else
    [ "$fsck_rc" = 0 ] || log "fsck.ext4 corrected errors on $DEVICE"
    OPTS="$OPTS,rw"
fi

OBJ="/org/freedesktop/UDisks2/block_devices/$DEVBASE"
err="$(mktemp)"

# ONE CALL, NO RETRY. There was a retry loop here for two days, for failures whose cause I had not
# looked for: after a format the unit came back "Object does not exist at path …", and once that was
# retried, "No such interface org.freedesktop.UDisks2.Filesystem on object …". Both were f3probe's
# doing — it writes across the whole device, and what it leaves behind reads to blkid as a
# filesystem, so udev starts this unit for a partition that has none. The fix belongs in the
# formatter, which now zeroes those sectors the moment the probe finishes, exactly as upstream does
# and for the reason upstream gives. A retry here would only have made that quieter.
#
# If a genuine lag ever turns up, it will arrive as a failed unit naming its own reason, which is
# the point of the message below.
mountpoint="$(busctl call --timeout=120 \
    org.freedesktop.UDisks2 "$OBJ" \
    org.freedesktop.UDisks2.Filesystem Mount 'a{sv}' 3 \
    as-user s "$DECK_USER" \
    auth.no_user_interaction b true \
    options s "$OPTS" \
    2>"$err" | sed -n 's/^s "\(.*\)"$/\1/p')" || true
reason="$(tr -d '\r' < "$err" | tr '\n' ' ')"; rm -f "$err"

if [ -z "$mountpoint" ]; then
    log "could not mount $DEVICE: ${reason:-no mountpoint returned and no error text}"
    exit 1
fi
log "mounted $DEVICE at $mountpoint ($OPTS)"

# THE MOUNTPOINT MUST BE WRITABLE BY deck, or the card mounts and then nothing can install to it.
# root_owner= at mkfs time covers cards WE formatted; this covers everything else — a card formatted
# by another system whose root directory belongs to some other uid. Tested as deck rather than
# assumed from the mode bits, because the answer depends on ownership, mode and the filesystem.
if ! setpriv --clear-groups --reuid "$DECK_UID" --regid "$DECK_UID" test -w "$mountpoint" 2>/dev/null; then
    log "$mountpoint is not writable by $DECK_USER; opening it up"
    chmod 777 "$mountpoint" 2>/dev/null || log "could not chmod $mountpoint — installs to this card will fail"
fi

# A COMPATIBILITY SYMLINK UNDER /run/media, which the reference platform also creates and which
# exists because older tooling and user scripts hardcode the older mount point. Named after the
# MOUNTPOINT when the filesystem has a label and after the device otherwise, which is upstream's
# rule; a link named after the device would otherwise shadow the labelled name people actually see.
if [ -n "$FSTYPE" ] && [ -n "${mountpoint##*/}" ] && [ "$(lsblk -no LABEL "$DEVICE" 2>/dev/null | head -n1)" != "" ]; then
    link="/run/media/${mountpoint##*/}"
else
    link="/run/media/$DEVBASE"
fi
[ -d "$link" ] || ln -sfn "$mountpoint" "$link" 2>/dev/null || true

# --- WE DO NOT TELL THE CLIENT, and that is a decision, not an omission ---------------------------
#
# This used to hand the client `steam://addlibraryfolder/<percent-encoded mountpoint>` after every
# successful mount. It worked — HW-proven 2026-09-03, the folder landed in libraryfolders.vdf within
# seconds — and it is gone anyway, for two reasons.
#
# It is not needed. The client enumerates drives over UDisks2 itself; `GetPotentialFolders()`
# returns this card with its path, capacity and removable flag unaided, and the format path adopts
# it through the client's own "Creating steam library for storage mount". Every step of the
# Settings > Storage story was exercised on hardware with this code not running (it is skipped at
# boot, when the client is not up yet) and none of it needed the announce.
#
# And it does more than announce: adding a library folder CREATES a SteamLibrary directory on the
# card. That made every card ever inserted into a Steam library, including cards that belong to
# another system entirely. Upstream does not do this — a mounted card without a library is supposed
# to show up as a drive that OFFERS to be formatted, which is exactly the surface this branch went
# looking for. Announcing it silently converted that case into the other one.
#
# It was added while the missing Format action was still unexplained, as one more thing to try. The
# explanation turned out to be two environment variables (usr/bin/novadeck-steam), and this was left
# behind — along with the `systemd-escape` bug it carried, which spent an evening making the client
# look guilty. Recorded here rather than quietly deleted, because "the client already knows" is the
# claim a future reader will want the evidence for.
#
# THE FAILED-FSCK REPORT IS NOT PORTED BECAUSE THIS CLIENT DOES NOT HAVE IT. Upstream tells the
# client about an unrepairable card with steam://system/devicemountresult/<dev>/1 and calls that
# code ABI. Measured in the baked seed:
#
#   steamrtarm64/steamui.so   addlibraryfolder = 1   devicemountresult = 0
#   linuxarm64/steamclient.so addlibraryfolder = 0   devicemountresult = 0
#   grep -rl devicemount <whole seed>  ->  nothing
#
# addlibraryfolder is the control: a steam:// URL this client demonstrably acts on (HW-proven), and
# it appears exactly once, in steamui.so. devicemountresult appears nowhere. Sending it would be a
# no-op, so the read-only mount and the journal line above are the whole answer: the card is usable,
# the reason is findable, and the user is not told in the UI.
#
# If a future client build gains the handler — check it the same way, the control matters — this is
# where the call goes.
