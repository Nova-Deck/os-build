#!/usr/bin/env bash
# novadeck internal-install target selection — Phase 3 of .claude/plans/internal-install.plan.md
#
#   install/select-target.sh              # scan every internal disk, pick the one
#   install/select-target.sh /dev/sda     # examine exactly this disk
#
# PURE: reads sysfs and the GPT, writes nothing, opens no partition for anything but a read. It is
# a separate script with its own exit codes precisely so the destructive half has one input it can
# be reasoned about independently.
#
# On success, prints key=value lines on stdout and exits 0:
#
#   TARGET=/dev/sda        the disk to install to
#   MODE=fresh|reinstall   reinstall means the novadeck eight are already there
#   SECTOR=4096            logical sector size, because MiB->sectors depends on it
#   UD_INDEX=11            the userdata partition number
#   UD_START=..  UD_END=.. its extent, in sectors
#   UD_TYPE=<guid>         its type GUID, which the carve must restore verbatim
#   CEIL=..                last sector our partitions may occupy: the sector before whatever
#                          follows userdata, or the last usable sector when it is last
#
# The FLOOR is deliberately NOT emitted: it is UD_START plus the size the user chooses on the
# confirm screen, so it does not exist until after this script has run. CEIL does not depend on
# that choice, which is why it does.
#
# THE VICTIM RULE, and there is only one (2026-08-10): a partition named exactly `userdata`, of at
# least 33 GiB. No name match, or not enough room, and this refuses -- it does not offer another
# partition, fall back to a size heuristic, or proceed in a reduced mode. Every Phase 0 capture
# agrees on the spelling, and a board that disagrees is refused rather than carved wrongly.
set -euo pipefail

# 32 GiB for novadeck plus 1 GiB kept for Android. This is the POLICY minimum -- below 32 an install
# is not worth having. It is not `genpart.sh --min` (15489 MiB), which is the MECHANICAL one, the
# point below which the eight partitions do not physically fit. Both exist; do not conflate them.
NOVADECK_MIN_GIB="${NOVADECK_MIN_GIB:-32}"
ANDROID_FLOOR_GIB="${ANDROID_FLOOR_GIB:-1}"
UD_MIN_GIB=$(( NOVADECK_MIN_GIB + ANDROID_FLOOR_GIB ))

ESP_TYPE_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'select-target: %s\n' "$*" >&2; exit 1; }

command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found"

# mdir is REQUIRED, and refusing here rather than degrading is the whole point. rule 3b answers
# "would ABL boot this ESP?" by reading its content with mtools, and `mdir` reports a missing file
# and a missing BINARY the same way -- non-zero. So without it the rule cannot distinguish "checked,
# clean" from "could not check", and it silently returns "not bootable" for every ESP on the disk.
#
# MEASURED, on the Pocket FIT, 2026-08-21: mtools is not in the shipped image (it is an installer
# package, exactly like gptfdisk), so 3b never fired and the FIT's sda -- carrying ROCKNIX on a
# genuine EF00 ESP at p12 -- came back TARGET=/dev/sda MODE=fresh. The 66 offline cases were green
# throughout, because the build container has mtools on its PATH. An offline suite cannot see the
# image's tool inventory, so a gate that degrades quietly when a tool is absent is one the tests
# structurally cannot catch. Fail closed.
command -v mdir  >/dev/null 2>&1 || die "mdir not found (mtools) -- rule 3b cannot run without it"

# --- which disk is the running system on? ---------------------------------------------------------
# Never a candidate. On the installer this is the SD card, and rule 2 exists because writing the
# medium you booted from is the one mistake that takes the recovery path with it.
running_disk() {
  local src parent
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [ -n "$src" ] || return 0
  # A loop/squashfs root has no PKNAME; fall back to whatever /run/novadeck/boot recorded.
  parent="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  if [ -z "$parent" ] && [ -r /run/novadeck/boot ]; then
    src="$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /run/novadeck/boot | head -1)"
    [ -n "$src" ] && parent="$(lsblk -no PKNAME "$(blkid -o device -t "$src" 2>/dev/null || echo "$src")" 2>/dev/null | head -1 || true)"
  fi
  [ -n "$parent" ] && printf '/dev/%s\n' "$parent"
}

# --- the GPT, read once per disk ------------------------------------------------------------------
# `sgdisk -p` gives index/start/end/code/name in one shot. Names in every capture are single words,
# so the last field is the name; a name with spaces would need -i per partition and none exists.
gpt_rows() { sgdisk -p "$1" 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {print $1, $2, $3, $(NF-1), $NF}'; }

sector_size() {
  sgdisk -p "$1" 2>/dev/null | sed -n 's/^Sector size (logical[^)]*): \([0-9]*\).*/\1/p'
}

last_usable() {
  sgdisk -p "$1" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p' | head -1
}

# Is this ESP one ABL would boot? Its own test, and it is on CONTENT: an ESP holding neither file is
# invisible to the firmware and is not a reason to refuse. Read-only via mtools at a byte offset --
# no mount, so this stays side-effect-free like the rest of the script.
esp_is_bootable() {  # <disk> <start-sector> <sector-size>
  local img="$1@@$(( $2 * $3 ))"
  mdir -i "$img" ::/EFI/BOOT/bootaa64.efi >/dev/null 2>&1 && return 0
  mdir -i "$img" ::/KERNEL               >/dev/null 2>&1 && return 0
  return 1
}

# --- examine one disk -----------------------------------------------------------------------------
# Prints the key=value block on success. On refusal, says why and returns 1 -- the caller decides
# whether that is fatal (an explicit target) or merely disqualifying (a scan).
examine() {
  local disk="$1" base ss rows ud_idx="" ud_start ud_end ud_type next_start ceil mode=fresh
  base="${disk#/dev/}"

  # NOVADECK_SELECT_FIXTURE lets the suite drive a GPT in an image file. It relaxes the three sysfs
  # checks and NOTHING else -- every rule that decides what gets carved still runs. The scan path
  # globs /dev/*, so this cannot widen a real selection; and since this script writes nothing, the
  # seam cannot turn into a write path. Without it the rules below are untestable off a device,
  # which is the trade genpart.sh's table seam already makes for the same reason.
  if [ -f "$disk" ] && [ -n "${NOVADECK_SELECT_FIXTURE:-}" ]; then
    :
  else
    [ -b "$disk" ] || { say "  $disk: not a block device"; return 1; }
    # THIS IS NOT WHAT PROTECTS THE BOOT MEDIUM, despite reading like it. Measured across all five
    # captures 2026-08-21: the boot SD card reports `removable=0` on every board -- the SD host
    # controller is not marked removable -- so this check never fires for the card, and rule 1 (the
    # running disk) is the SOLE thing keeping the installer off the medium it booted from. What this
    # does catch is USB media, which is worth having and is not the same guarantee.
    [ "$(cat "/sys/block/$base/removable" 2>/dev/null || echo 1)" = 0 ] \
      || { say "  $disk: removable media is never an install target"; return 1; }
    [ "$(cat "/sys/block/$base/ro" 2>/dev/null || echo 1)" = 0 ] \
      || { say "  $disk: read-only"; return 1; }
  fi

  # A damaged backup header is refused rather than repaired: we cannot tell "damaged" apart from
  # "not the disk we think this is", and the second reading is the one that ends a device.
  #
  # AND THE SUMMARY LINE IS NOT THE VERDICT. Measured 2026-08-10, which is what the test case for
  # this rule turned up: `sgdisk -v` prints "No problems found" on a disk whose BACKUP GPT has been
  # zeroed, on one whose MAIN GPT has been zeroed, and on a disk carrying no GPT at all -- it
  # regenerates the missing half in memory first and then verifies what it invented. Grepping only
  # for that line accepted every one of them. So the whole output is read, and the offending line
  # goes in the message -- a board refused in the field is only useful if we can see what it said.
  #
  # THE PATTERN NAMES DAMAGE, not severity, and the fixtures are why. Refusing on any Caution or
  # Warning refused every captured board: stock Android tables are not 2048-sector aligned
  # (`sda1` is two sectors at LBA 6), so every one of them draws "Partition 1 doesn't end on a
  # 2048-sector boundary". That is a remark about tidiness on a disk we did not lay out and never
  # will. What we refuse on is a header or table gdisk could not read and substituted for.
  local vfy bad_line
  vfy="$(sgdisk -v "$disk" 2>&1 || true)"
  printf '%s\n' "$vfy" | grep -qi "No problems found" \
    || { say "  $disk: sgdisk reports GPT problems -- refusing"; return 1; }
  bad_line="$(printf '%s\n' "$vfy" \
    | grep -Eim1 "One or more CRCs|invalid main GPT|invalid backup GPT|header: ERROR|partition table: ERROR|Creating new GPT entries|corrupt GPT" || true)"
  [ -z "$bad_line" ] \
    || { say "  $disk: the GPT is damaged or absent -- sgdisk said: $bad_line"; return 1; }

  ss="$(sector_size "$disk")"
  [ -n "$ss" ] || { say "  $disk: cannot read the logical sector size"; return 1; }
  rows="$(gpt_rows "$disk")"
  [ -n "$rows" ] || { say "  $disk: no partitions"; return 1; }

  # Already ours? Settled BEFORE anything looks at sizes. On a reinstall the biggest partition is
  # our own /home, so any size test reached first carves the user's game library.
  if printf '%s\n' "$rows" | awk '{print $5}' | grep -qx "novadeck-root-A"; then
    mode=reinstall
  fi

  # Rule 3b: a FOREIGN bootable ESP means two installs ABL cannot choose between, so one of them is
  # unreachable whichever it picks. Ours is exempt by name.
  local idx start end code name
  while read -r idx start end code name; do
    [ "$code" = "EF00" ] || continue
    [ "$name" = "NOVADECK-ESP" ] && continue
    if esp_is_bootable "$disk" "$start" "$ss"; then
      say "  $disk: partition $idx ($name) is a bootable ESP that is not ours -- remove the other OS first"
      return 1
    fi
  done <<<"$rows"

  # THE VICTIM RULE. Exact name, then size. Nothing else is eligible and there is no fallback.
  while read -r idx start end code name; do
    [ "$name" = "userdata" ] || continue
    ud_idx="$idx"; ud_start="$start"; ud_end="$end"
  done <<<"$rows"
  [ -n "$ud_idx" ] \
    || { say "  $disk: no partition named 'userdata' -- this board is not supported yet"; return 1; }

  # The size test is a FRESH-INSTALL question and only ever meant "is there room to make a NovaDeck
  # install here". On a reinstall that has been answered -- and answered by a carve that was allowed
  # to leave userdata as small as ANDROID_FLOOR_GIB, so applying it here refuses to reinstall exactly
  # the devices whose owners gave Android the least. Rule 8's "skip 4-6 on a disk that is already
  # ours" is what this is; the name check above still runs, because the carve needs the extent.
  local ud_gib=$(( (ud_end - ud_start + 1) * ss / 1073741824 ))
  if [ "$mode" = fresh ]; then
    [ "$ud_gib" -ge "$UD_MIN_GIB" ] \
      || { say "  $disk: userdata is ${ud_gib} GiB, and ${UD_MIN_GIB} is the minimum (${NOVADECK_MIN_GIB} for NovaDeck + ${ANDROID_FLOOR_GIB} kept for Android)"; return 1; }
  fi

  # The type GUID has to come back byte-identical on the recreated partition: stock userdata is a
  # vendor type, and the Pocket FIT shows what a Linux type does to a board that expects its own.
  ud_type="$(sgdisk -i "$ud_idx" "$disk" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
  [ -n "$ud_type" ] || { say "  $disk: cannot read userdata's type GUID"; return 1; }

  # CEIL: the last sector our eight may occupy. The sector before whatever starts after userdata,
  # or the last usable sector when nothing does -- which is what lets home absorb trailing free
  # space. Computed here because this script can see the whole table and genpart cannot.
  next_start="$(printf '%s\n' "$rows" | awk -v e="$ud_end" '$2 > e {print $2}' | sort -n | head -1)"
  if [ -n "$next_start" ]; then ceil=$(( next_start - 1 )); else ceil="$(last_usable "$disk")"; fi
  [ -n "$ceil" ] || { say "  $disk: cannot determine the last usable sector"; return 1; }

  printf 'TARGET=%s\nMODE=%s\nSECTOR=%s\nUD_INDEX=%s\nUD_START=%s\nUD_END=%s\nUD_TYPE=%s\nCEIL=%s\n' \
    "$disk" "$mode" "$ss" "$ud_idx" "$ud_start" "$ud_end" "$ud_type" "$ceil"
}

# --- drive ----------------------------------------------------------------------------------------
RUNNING="$(running_disk || true)"

if [ $# -ge 1 ]; then
  [ "$1" != "$RUNNING" ] || die "$1 is the disk the running system is on"
  examine "$1" || die "$1 is not a valid target"
  exit 0
fi

# Scan. Exactly one disk must pass: zero says what was rejected and why, two or more refuses and
# lists them rather than picking, because picking is the decision this script exists not to guess at.
#
# NOVADECK_SELECT_DISKS stands in for the glob so the suite can drive this loop. Rule 9 is the only
# rule the explicit-target path cannot reach, and it is the one that decides WHICH disk every
# geometric guarantee below is about -- untested, "never pick" is an intention rather than a
# property. It is the same seam as NOVADECK_SELECT_FIXTURE and no wider: examine() still refuses
# anything that is not a block device unless the fixture flag is ALSO set, so a list on its own
# cannot introduce a candidate a bare scan would have skipped.
found=0; result=""; names=""
for d in ${NOVADECK_SELECT_DISKS:-/dev/sd? /dev/nvme?n? /dev/mmcblk?}; do
  # -e, not -b: an unmatched glob leaves the pattern itself, and examine() is where "not a block
  # device" is decided -- with a message, which the scan owes the user when zero disks qualify.
  [ -e "$d" ] || continue
  [ "$d" != "$RUNNING" ] || continue
  if out="$(examine "$d")"; then
    found=$(( found + 1 )); result="$out"; names="$names $d"
  fi
done

case "$found" in
  1) printf '%s\n' "$result" ;;
  0) die "no disk qualifies -- see the reasons above" ;;
  *) die "more than one disk qualifies ($names) -- refusing to choose" ;;
esac
