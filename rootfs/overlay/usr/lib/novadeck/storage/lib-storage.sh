#!/bin/bash
# Shared predicates for the removable-storage path — sourced by format-device.sh (which erases a
# disk) and automount.sh (which mounts one). One file because the two must agree about what a card
# IS: a formatter that refuses a disk the mounter would have adopted, or worse the reverse, is two
# answers to one question.
#
# THE SHAPE IS AN ALLOWLIST, and that is the whole design. The obvious predicate — "is this the
# system disk?" — is not enough on this hardware. A device booted from an SD card has an internal
# UFS carrying the vendor's own partitions (super, vbmeta, xbl, userdata), and that disk is NOT the
# system disk from the running root's point of view: nothing of ours is mounted from it. A denylist
# would happily format it and take the firmware with it. So nothing is eligible unless it is
# positively identified as a removable SD card that we are not running from.
#
# Every predicate REFUSES WHEN IT CANNOT TELL. The cost of a false "no" is a card that does not
# auto-mount; the cost of a false "yes" is an erased device.

# ONE LOCK, TAKEN BY BOTH SIDES, so a format and an automount cannot run over each other. Ported
# from the reference platform's create_lock_file, which both its automounter and its format script
# call, with the reason stated there: "to ensure we're not double-triggering nor automounting while
# formatting or vice-versa".
#
# WHY IT IS NOT OPTIONAL HERE, measured 2026-09-03 on a validated format:
#   11:22:31 format-device.sh: formatting /dev/mmcblk0
#   11:22:31 automount.sh: could not mount …: Object does not exist at path …/mmcblk0p1
#   11:22:32 automount.sh: could not mount …: fsconfig() failed: /dev/mmcblk0p1: Can't open blockdev
#   11:22:35 format-device.sh: formatted /dev/mmcblk0p1
# Rewriting a partition table and running mkfs both emit udev events, so the automounter starts
# while the formatter is still working on the same device. The first line is noise; the SECOND is
# udisks getting far enough to attempt a mount of a partition mkfs was writing at that moment.
#
# Everything before this was aimed at the symptom: a retry loop for the first message, then a wider
# retry for the second, then zeroing f3probe's leftovers. None of them addressed two processes
# owning one device at once, because none of them was looking for that.
#
# Contract: the two callers are the FORMATTER (holds it for its whole run) and block-event.sh (the
# udev entry point, which gives up quietly when it cannot have it — "a format is in progress" is a
# reason not to mount, not a failure to report; the formatter mounts the card itself when done).
# automount.sh takes NO lock: it is only ever reached through one of those two, and block-event.sh
# holds the lock across its exec into it.
storage_lock() { # <partition kernel name> -> 0 if we now hold the lock, 1 if someone else does
    local base="$1"
    case "$base" in
        *[!a-zA-Z0-9]*|"") return 1 ;;   # never let a caller name a path into /run
    esac
    mkdir -p /run/novadeck 2>/dev/null || true
    # fd 9 stays open for the life of the process, which is what holds the lock; it is released when
    # the script exits, however it exits, with no cleanup path to forget.
    exec 9<>"/run/novadeck/storage-${base}.lock" || return 1
    flock -n 9
}

# The whole-disk kernel name behind any block device: mmcblk0p1 -> mmcblk0, sda3 -> sda.
# lsblk PKNAME is empty for a disk and set for a partition, which is exactly the distinction.
storage_disk_of() { # <dev path or kernel name> -> disk kernel name, or empty
    local dev="$1" real parent
    [ -n "$dev" ] || return 1
    case "$dev" in /*) : ;; *) dev="/dev/$dev" ;; esac
    real="$(readlink -f "$dev" 2>/dev/null)" || return 1
    [ -b "$real" ] || return 1
    parent="$(lsblk -no PKNAME "$real" 2>/dev/null | head -n1)"
    if [ -n "$parent" ]; then basename "$parent"; else basename "$real"; fi
}

# The disk this system booted from, as a kernel name.
#
# /run/novadeck/boot is written by the initramfs before switch_root and is the same source
# usr/lib/novadeck/on-boot-disk reads — see its header for why a device that carries the same eight
# GPT names on two disks cannot resolve this by label. EMPTY MEANS UNKNOWN, and every caller treats
# unknown as "this could be the boot disk". on-boot-disk fails OPEN for the opposite reason (a
# missing handoff must not stop a single-disk device mounting /home); here the same absence has to
# fail CLOSED, which is why this reads the file rather than calling that helper.
#
# IT IS A key=value FILE, NOT A DEVICE NODE. `slot=`, `source=`, `root=`, `var=`, `efi=` — the
# resolved node is the `root=` line, written by the initramfs as findfs output. Reading the whole
# file and treating it as a path is what the first version of this did, and the result was not a
# crash: storage_disk_of simply failed, storage_boot_disk answered "unknown", and every card on an
# internally-installed device was refused as system storage. HW-caught 2026-09-02.
#
# The parse is the same sed usr/lib/novadeck/on-boot-disk uses, and NOVADECK_BOOTINFO is the same
# seam name, so the two cannot drift into disagreeing about where the boot disk is written down.
storage_boot_disk() { # -> disk kernel name, or empty
    local node bootfile="${NOVADECK_BOOTINFO:-/run/novadeck/boot}"
    [ -r "$bootfile" ] || return 0
    node="$(sed -n 's/^root=//p' "$bootfile" 2>/dev/null | head -1)"
    [ -n "$node" ] || return 0
    storage_disk_of "$node"
}

# True when the disk is a real removable SD/MMC card.
#
# The /sys type file is the authority, not the name: mmcblk numbering is not stable across boots
# and an eMMC enumerates as mmcblk too, reporting MMC where a card reports SD. A device with no
# type file is not identified, so it is not eligible.
storage_is_sd() { # <disk kernel name>
    local disk="$1" type_file="/sys/block/$1/device/type"
    case "$disk" in mmcblk[0-9]*) : ;; *) return 1 ;; esac
    [ -r "$type_file" ] || return 1
    [ "$(cat "$type_file" 2>/dev/null)" = "SD" ]
}

# True when anything this system depends on lives on the disk.
#
# The mount list is checked by SOURCE DISK rather than by device name so a bind mount or a
# by-partlabel path cannot hide the relationship. /esp and /home are ours; / and /var are the pair
# an A/B slot occupies; /boot is there for completeness on a layout that grows one.
storage_is_system_disk() { # <disk kernel name>
    local disk="$1" boot target src resolved=0
    [ -n "$disk" ] || return 0                    # no answer -> treat as system

    boot="$(storage_boot_disk)"
    [ -n "$boot" ] && [ "$disk" = "$boot" ] && return 0

    # THE MOUNT TABLE IS THE AUTHORITY, and an unknown boot disk does NOT short-circuit to "system".
    # That is what the first version did, and it was wrong in the expensive direction: it refused
    # every card whenever the handoff could not be read, which on an internally-installed device is
    # the normal case if anything about that file changes. `/` is always resolvable and always names
    # the disk this system runs from, so the honest rule is "refuse when NOTHING here resolves",
    # not "refuse when one optional hint is missing".
    for target in / /var /etc /esp /home; do
        src="$(findmnt -rn -o SOURCE --target "$target" 2>/dev/null | head -n1)"
        case "$src" in /dev/*) : ;; *) continue ;; esac
        resolved=1
        [ "$(storage_disk_of "${src%%[*}")" = "$disk" ] && return 0
    done

    [ "$resolved" = 1 ] || return 0               # nothing resolved at all -> assume system
    return 1
}

# True when any partition of the disk is currently mounted. Formatting one is refused outright;
# automounting one is a no-op rather than a second mount of the same filesystem.
#
# NO PIPELINE, and that is the whole point of the shape. This was written as
# `findmnt | while read …; do echo x; done | grep -q x` and it REPORTED THE OPPOSITE OF THE TRUTH:
# under `set -euo pipefail`, `grep -q` exits at the first match and closes the pipe, the while
# subshell dies of SIGPIPE, pipefail turns that into a non-zero pipeline, and the function answers
# "not mounted" — but only in the case where something IS mounted, which is the case that matters.
# It cost a card on 2026-09-02: format-device.sh sailed past its refusal and wiped the signatures
# out from under two live mounts. Process substitution keeps the loop in this shell, so a `return 0`
# is a real return and no pipeline status can invert it.
storage_is_mounted() { # <disk kernel name>
    local disk="$1" src
    while read -r src; do
        case "$src" in /dev/*) : ;; *) continue ;; esac
        [ "$(storage_disk_of "${src%%[*}")" = "$disk" ] && return 0
    done < <(findmnt -rn -o SOURCE 2>/dev/null)
    return 1
}

# Every mountpoint currently served by the disk, deepest first so nested mounts unwind cleanly.
storage_mountpoints_of() { # <disk kernel name>
    local disk="$1" target src
    while read -r target src; do
        case "$src" in /dev/*) : ;; *) continue ;; esac
        [ "$(storage_disk_of "${src%%[*}")" = "$disk" ] && printf '%s\n' "$target"
    done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null) | sort -r
}

# The single card this system may write to, or nothing. Deliberately returns NOTHING when more than
# one candidate exists: "the SD card" is a phrase with one referent on a handheld, and a formatter
# that picks for you when there are two is a formatter that erases the wrong one.
storage_target_sd() { # -> /dev/<disk>, or empty
    local disk found="" n=0
    for disk in /sys/block/mmcblk*; do
        [ -e "$disk" ] || continue
        disk="${disk##*/}"
        storage_is_sd "$disk" || continue
        storage_is_system_disk "$disk" && continue
        found="/dev/$disk"; n=$((n + 1))
    done
    [ "$n" = 1 ] && printf '%s\n' "$found"
}
