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
# partition, fall back to a size heuristic, or proceed in a reduced mode. All four Phase 0 captures
# agree on the spelling, and a board that disagrees is refused rather than carved wrongly.
set -euo pipefail

# 32 GiB for novadeck plus 1 GiB kept for Android. This is the POLICY minimum -- below 32 an install
# is not worth having. It is not `genpart.sh --min` (15233 MiB), which is the MECHANICAL one, the
# point below which the eight partitions do not physically fit. Both exist; do not conflate them.
NOVADECK_MIN_GIB="${NOVADECK_MIN_GIB:-32}"
ANDROID_FLOOR_GIB="${ANDROID_FLOOR_GIB:-1}"
UD_MIN_GIB=$(( NOVADECK_MIN_GIB + ANDROID_FLOOR_GIB ))

ESP_TYPE_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'select-target: %s\n' "$*" >&2; exit 1; }

command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found"

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
    [ "$(cat "/sys/block/$base/removable" 2>/dev/null || echo 1)" = 0 ] \
      || { say "  $disk: removable -- the installer never writes the medium it booted from"; return 1; }
    [ "$(cat "/sys/block/$base/ro" 2>/dev/null || echo 1)" = 0 ] \
      || { say "  $disk: read-only"; return 1; }
  fi

  # A damaged backup header is refused rather than repaired: we cannot tell "damaged" apart from
  # "not the disk we think this is", and the second reading is the one that ends a device.
  sgdisk -v "$disk" 2>/dev/null | grep -qi "No problems found" \
    || { say "  $disk: sgdisk reports GPT problems -- refusing"; return 1; }

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

  local ud_gib=$(( (ud_end - ud_start + 1) * ss / 1073741824 ))
  [ "$ud_gib" -ge "$UD_MIN_GIB" ] \
    || { say "  $disk: userdata is ${ud_gib} GiB, and ${UD_MIN_GIB} is the minimum (${NOVADECK_MIN_GIB} for NovaDeck + ${ANDROID_FLOOR_GIB} kept for Android)"; return 1; }

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
found=0; result=""; names=""
for d in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
  [ -b "$d" ] || continue
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
