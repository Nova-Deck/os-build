#!/bin/bash
# Format a removable card as a Steam library — the privileged half of the Settings > Storage
# button. Ported from the reference platform's usr/lib/hwsupport/format-device.sh; the filesystem
# recipe is theirs verbatim because the client and Proton depend on it, the refusals are ours.
#
#   /usr/lib/novadeck/storage/format-device.sh --device /dev/mmcblk0 [--label L] [--owner uid:gid]
#
# THE RECIPE, and why each part of it is not a preference:
#
#   GPT, one partition spanning the disk   what the client expects to find; anything else reads as
#                                          "unformatted" forever.
#   mkfs.ext4 -m 0                         no reserved blocks. This is a game library, not a root
#                                          filesystem that must stay writable when full; 5% of a
#                                          512G card is 25G of nothing.
#   -O casefold                            case-insensitive lookup. Windows titles ship mixed-case
#                                          paths and Proton resolves them literally, so without it
#                                          games install and then fail to find their own files.
#                                          Needs CONFIG_UNICODE, which kernel/kernel.config carries.
#   chown 1000:1000                        deck owns the mountpoint. A root-owned card mounts fine
#                                          and then cannot be written to, which presents as "the
#                                          library was added but nothing installs".
#
# THE COUNTERFEIT PROBE IS PORTED; THE RESCUE IS NOT. f3probe runs before the format ON EVERY RUN —
# the caller opts OUT with --force/--skip-validation, which is the contract the client is written
# against ("Run validation tests" ticked = no flag at all). A card that fails is refused with the
# same exit code upstream returns for it; upstream instead RESCUES it to exFAT, and we do not. See
# the block that runs the probe.
#
# PRIVILEGE: this runs as root. It is reached through /usr/bin/steamos-polkit-helpers/, whose
# wrappers pkexec into here under an action a member of wheel in an ACTIVE session may take
# (usr/share/polkit-1/actions/org.novadeck.policykit.storage.policy). The refusals below are the
# only thing standing between that grant and an erased device, so they run before anything writes.
set -euo pipefail

. /usr/lib/novadeck/storage/lib-storage.sh

PROG="${0##*/}"
DEVICE=""; LABEL=""; OWNER="1000:1000"
F3PROBE="${NOVADECK_F3PROBE:-/usr/bin/f3probe}"
# VALIDATION IS ON BY DEFAULT, because that is the contract the client is written against: it does
# not ask for the test, it asks to SKIP it (--force / --skip-validation). Default it off and a
# ticked "Run validation tests" checkbox silently tests nothing, which is the state this script
# shipped in until the upstream helper's getopt was actually read.
VALIDATE=1
DISCARD="nodiscard"
# Bumped whenever an option is added here — the caller-visible way to tell what this understands.
VERSION_NUMBER=1

# TO THE JOURNAL AND TO STDERR, one line at a time, synchronously.
#
# This script is exec'd by the CLIENT through pkexec, so its stderr belongs to steamui: it lands in
# ~/.local/share/Steam/logs/steamui_system.txt prefixed "adopt-drive:", which is a file you must
# already know about, on a machine where Steam is running. Everything this script says is a refusal
# or a verdict on a card — what someone goes looking for after something went wrong, i.e. exactly
# when the journal is where they look. So each line goes to both.
#
# NOT upstream's `exec &> >(tee /dev/fd/8 | logger)`. That was tried here and MEASURED WORSE: under
# pkexec it produced not one journal line for an entire format, and over ssh it delayed output past
# the process that wrote it, so a --version answer surfaced during the NEXT invocation. Nothing
# waits for that pipeline. Why it fails under pkexec specifically was never established — which is
# the other reason not to ship it. Command output worth keeping (f3probe, mkfs) is captured and
# logged line by line instead, which is ordered, synchronous, and leaves the caller's stdout — where
# the client reads `stage=` — untouched.
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; logger -t "$PROG" -p user.notice -- "$*" 2>/dev/null || true; }
# $1, NOT $*. die is called as `die "reason" 13`, so logging $* put the exit code on the end of
# every refusal the user could ever read: "must run as root (…) 13".
die()  { log "$1"; exit "${2:-1}"; }

# THE OPTION SET IS UPSTREAM'S, verbatim from jupiter-hw-support's format-device.sh getopt:
#   version, force, skip-validation, full, quick, owner:, device:, label:
# Nothing is added to it. A helper whose CLI matches the one it was ported from can be diffed
# against it in one glance, which is what this file needed and did not have while its contract was
# being guessed from client strings. --auto used to live here and now does not: resolving WHICH
# card is a divergence our hardware forces (the slot is not always mmcblk0, and a device can be
# running from a card), so it belongs in our own wrapper rather than in a copied contract.
while [ $# -gt 0 ]; do
    case "$1" in
        --device)  DEVICE="${2:-}"; shift 2 ;;
        --label)   LABEL="${2:-}"; shift 2 ;;
        --owner)   OWNER="${2:-}"; shift 2 ;;
        # --force DISABLES VALIDATION. It does not mean "format anyway", and reading it that way is
        # what made the client's ticked "Run validation tests" checkbox do nothing here for a day:
        # validation is ON BY DEFAULT in the contract, the client passes --force to turn it OFF, so
        # a ticked box sends NO flag at all. We had it exactly inverted — opt-in via a flag the
        # client never sends. Verified against the upstream helper's own getopt.
        --force|--skip-validation) VALIDATE=0; shift ;;
        # (No positive form for validation, deliberately: upstream has none, and a --validate
        # meaning "do the thing you already do by default" is a flag for a caller that does not
        # exist.)
        # mkfs -E discard vs nodiscard. nodiscard is the default because the disk was just wiped.
        --full)    DISCARD="discard"; shift ;;
        --quick)   DISCARD="nodiscard"; shift ;;
        # "Increase the version number every time a new option is added" — the upstream helper's
        # own words. It is how a caller can tell which options this script understands, and it costs
        # one line to answer honestly.
        --version) printf '%s\n' "$VERSION_NUMBER"; exit 0 ;;
        # NO --enable/--supports-duplicate-detection. Those two strings sit in steamui.so right
        # after this helper's --device/--label/--force strings, so they read like one argument list
        # and I implemented them as ours. They are not: the upstream helper's getopt has no such
        # option, and the strings immediately after them are steamos-update's path and
        # "steamos-update: using duplicate detection: %d" — duplicate BLOCK detection, the
        # adaptive-OTA feature. Adjacency in .rodata is not a call site.
        -h|--help) printf 'usage: %s --device <dev> [--label L] [--owner uid:gid] [--force|--skip-validation] [--full|--quick]\n' "$PROG"; exit 0 ;;
        *)         die "unknown argument: $1" 22 ;;
    esac
done


[ "$(id -u)" = 0 ] || die "must run as root (reach it through /usr/bin/steamos-polkit-helpers/)" 13

[ -n "$DEVICE" ] || die "--device is required" 22
[ -b "$DEVICE" ] || die "not a block device: $DEVICE" 19

DISK="$(storage_disk_of "$DEVICE")" || die "cannot resolve a disk for $DEVICE" 19
[ "/dev/$DISK" = "$DEVICE" ] || die "refusing a partition; pass the whole disk (/dev/$DISK)" 22

# ---- the refusals, in the order that costs least to answer ---------------------------------------
storage_is_sd "$DISK"          || die "refusing to format $DEVICE: not a removable SD card" 19
storage_is_system_disk "$DISK" && die "refusing to format $DEVICE: this system runs from it" 16

# TAKE THE LOCK BEFORE ANYTHING TOUCHES THE DEVICE, and hold it to the end. Every step from here —
# unmounting, f3probe, wipefs, sfdisk, mkfs — emits udev events on this disk, each of which starts
# the automount unit on the partition we are in the middle of creating. Measured on hardware: the
# mounter reached udisks while mkfs was writing ("fsconfig() failed: Can't open blockdev"), which is
# a mount of a half-made filesystem away from being worse than noise.
#
# The post-format mount below calls automount.sh directly, which takes no lock of its own — the
# udev path's lock is in block-event.sh — so there is nothing here to hand it or to work around.
PARTBASE="${DISK}p1"
storage_lock "$PARTBASE" || die "refusing to format $DEVICE: something else is already working on $PARTBASE" 16

# UNMOUNT, DO NOT MERELY REFUSE. A card that reached this point is a removable SD we are not running
# from, and it is almost certainly mounted — by our OWN automount, under /run/media/deck. Refusing
# on that basis makes formatting impossible in the only state the card is ever in, which is how the
# original "refuse if mounted" check managed to be both useless and unsafe: it never fired, and
# nothing else stopped wipefs from erasing signatures beneath live mounts (2026-09-02).
#
# Deepest first, and a failure here is fatal: umount refusing means something is still using the
# filesystem, and erasing it anyway is precisely the damage this replaces.
while read -r mnt; do
    [ -n "$mnt" ] || continue
    log "unmounting $mnt before formatting"
    umount "$mnt" || die "cannot unmount $mnt — refusing to erase a filesystem still in use" 16
done < <(storage_mountpoints_of "$DISK")

# Belt to that brace: if anything on the disk is STILL mounted, stop. The loop above can only see
# what findmnt reported when it ran, and a format is not a thing to attempt on a maybe.
storage_is_mounted "$DISK" && die "refusing to format $DEVICE: something on it is still mounted" 16

# ---- the counterfeit test, if the caller asked for it --------------------------------------------
# Runs HERE: after the unmount pass, because it writes to the whole device, and before the format,
# because the point is to refuse a card rather than to discover afterwards that the library sits on
# one. On SD media the client ticks this by default.
#
# f3probe's EXIT CODE is the verdict: `return fake_type == FKTY_GOOD ? 0 : 100 + fake_type`, so 0
# means the card stores what it claims and 100+N names the kind of lie. (An earlier version of this
# block parsed stdout for "Good news:" on my claim that f3probe always exits 0 — it does not; I read
# its printf switch and stopped before the return. The output still goes to the journal, because a
# refusal the user cannot explain is worth less than one they can.)
#
# EXIT 14 (EFAULT) ON A BAD CARD, and that number is not ours to choose: it is the code the upstream
# helper returns for exactly this case, which is how the client knows to show its specific bad-card
# error rather than a generic one.
#
# NOT PORTED, deliberately: upstream's rescue. On a failed probe it repartitions the card to its
# real size and lays down exFAT so the card stays usable in OTHER devices — that is the only exFAT
# path upstream has, and it needs parted and exfatprogs. We refuse instead: the exit code is the
# same, so the user gets the same error, and a card that lies is not one we want to hand back as
# half-working. If the rescue is ever wanted, it arrives with those two packages and a decision
# about what a rescued card is allowed to be.
if [ "$VALIDATE" = 1 ]; then
    [ -x "$F3PROBE" ] || die "validation is on but $F3PROBE is not on this image" 2
    # The client reads stage= from our stdout to drive the format dialog's progress.
    echo "stage=testing"
    log "validating $DEVICE with f3probe — destructive, and minutes rather than seconds"
    probe_rc=0
    probe_out="$("$F3PROBE" --destructive --time-ops "$DEVICE" 2>&1)" || probe_rc=$?
    printf '%s\n' "$probe_out" | while IFS= read -r l; do log "f3probe: $l"; done
    [ "$probe_rc" = 0 ] \
        || die "refusing to format $DEVICE: it failed the counterfeit test (f3probe $probe_rc) — the card does not store what it claims, and a library on it would lose data" 14

    # ZERO WHAT THE PROBE LEFT, IMMEDIATELY. Upstream does this and says why: "Clear out the garbage
    # bits generated by f3probe from the partition table sectors / Otherwise parted may think we
    # have existing partitions in a bogus state". f3probe --destructive writes across the device,
    # and what it leaves in the first sectors reads to blkid as a filesystem — so when it closes the
    # device, udev reprobes, our automount rule matches on a stale ID_FS_USAGE and starts a unit for
    # a partition that has no filesystem. That unit then fails against udisks ("No such interface
    # org.freedesktop.UDisks2.Filesystem"), and every validated format left a failed unit behind.
    #
    # I ported the probe and not the four lines after it, then spent two rounds widening a retry in
    # automount.sh to make the symptom quieter. The failed unit appeared for the first time in the
    # first format that ran f3probe, which said plainly where to look.
    dd if=/dev/zero of="$DEVICE" bs=512 count=1024 status=none
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi
echo "stage=formatting"

PART="/dev/$PARTBASE"
[ -n "$LABEL" ] || LABEL="SDCARD"

log "formatting $DEVICE (label '$LABEL', owner $OWNER)"

# WIPE THE OLD SIGNATURES FIRST. A card that carried our own image still has a GPT naming
# novadeck-root-A and friends; leaving those in place gives the device two disks answering to one
# partition label, which usr/lib/novadeck/on-boot-disk exists because of. wipefs on the disk and on
# every partition it currently has, because a stale superblock inside a partition survives a new
# partition table that happens to land in the same place.
for p in "/dev/${DISK}"p*; do [ -b "$p" ] && wipefs --all --force "$p" >/dev/null 2>&1 || true; done
wipefs --all --force "$DEVICE" >/dev/null 2>&1 || true

# sfdisk, not sgdisk: sgdisk is not on this image (it is one of the four binaries the installer
# stager has to push), sfdisk comes with util-linux and is always there.
printf 'label: gpt\nname=novadeck-library, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' \
    | sfdisk --quiet --wipe always "$DEVICE" >/dev/null

partprobe "$DEVICE" >/dev/null 2>&1 || true
udevadm settle --timeout=10 >/dev/null 2>&1 || true
[ -b "$PART" ] || die "the partition did not appear: $PART" 19

# -F because the device was just repartitioned and mkfs would otherwise ask; -m 0 and -O casefold
# per the header. -E nodiscard keeps the format bounded on a card whose controller is slow at
# discard — the partition was wiped above, so there is nothing to gain by trimming it again.
#
# OWNERSHIP IS SET BY mkfs, via root_owner=, exactly as upstream does it. It used to be a
# mount/chown/chmod/umount cycle here — which works, and costs a mount and an unmount of a device
# this script is in the middle of formatting, each emitting its own udev events on the partition
# the automounter is watching. One mkfs option replaces all of it and cannot race anything, because
# the filesystem does not exist yet when the option is read.
mkfs_rc=0
mkfs_out="$(mkfs.ext4 -m 0 -O casefold -E "$DISCARD,root_owner=$OWNER" -L "$LABEL" -F "$PART" 2>&1)" || mkfs_rc=$?
printf '%s\n' "$mkfs_out" | while IFS= read -r l; do [ -n "$l" ] && log "mkfs: $l"; done
[ "$mkfs_rc" = 0 ] || die "mkfs.ext4 failed on $PART (status $mkfs_rc)" 1

log "formatted $PART as ext4+casefold, label '$LABEL', owned by $OWNER"

# MOUNT IT FROM HERE, because this is the only place that knows a filesystem was just created.
# The udev rule matches add|remove and nothing else: a formatted-in-place card emits its signature
# as a `change`, but so does every unmount (the kernel sends one on close of a writable block
# device), so a rule that acts on `change` remounts a card the moment anyone releases it and the
# client's Unmount cannot work. See the rule's header for both halves of that.
#
# AND A FAILURE HERE IS FATAL, exit 5. I had this best-effort, on the reasoning that a format which
# succeeded should not report failure because the mount after it did not. Upstream disagrees, and
# the client settles it: there is a string for exactly this outcome —
#   "The microSD card formatted correctly, but it failed to mount with the system running.
#    A reboot is required to complete the operation."
# (Settings_System_FormatSD_Error_NotMounted). A card the user cannot use until they reboot is not a
# success, and swallowing the exit code is what stops that sentence from ever being shown.
if ! /usr/lib/novadeck/storage/automount.sh add "${PART#/dev/}"; then
    die "formatted $PART, but it could not be mounted" 5
fi

printf '%s\n' "$PART"
