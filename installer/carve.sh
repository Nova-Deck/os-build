#!/usr/bin/env bash
# novadeck internal-install carve — the DESTRUCTIVE half, Phase 3/4 of
# .claude/plans/internal-install.plan.md.
#
#   installer/carve.sh fresh     <disk> <userdata-gib>   # shrink userdata, append our eight
#   installer/carve.sh plan      <disk> <userdata-gib>   # writes NOTHING; what `fresh` WOULD do
#   installer/carve.sh reinstall <disk>                  # writes NOTHING; reports where the eight are
#   installer/carve.sh uninstall <disk>                  # remove our eight, give userdata its span back
#
# `plan` is `fresh` up to but not including the first delete. It answers the two questions the
# consent screen cannot answer for itself -- how much space NovaDeck ends up with, and whether an
# existing novadeck install (and its /home) is about to be replaced -- and it answers them from THIS
# script's arithmetic, which is the only one that is right. See the block at the mode itself.
#
# On success it prints the name=index map on stdout and exits 0 -- the same shape genpart.sh emits,
# because that map is what `write_parts_env` turns into /EFI/steamos/parts.env, and stage 2 on this
# disk cannot assume 1..8. Every mode produces it, so the caller does not branch to find its
# partitions; `uninstall` prints `userdata=<index>` instead, there being no eight left to name.
#
# THE MODE IS THE USER'S INTENT AND IT IS AN ARGUMENT, never inferred. The disk only distinguishes
# "ours" from "not ours" (select-target.sh's MODE=), and all three operations below are reachable
# from a disk that is already ours: reinstalling it, resizing its Android share, or removing us. A
# script that read intent off the disk would have to guess which, and two of the three guesses erase
# something the user wanted to keep.
#
# WHAT EACH MODE DESTROYS, so this is legible without the plan:
#   fresh      Android's data (userdata is recreated at a new size) AND /home, because every
#              partition is chained from a floor that has moved. This is also the mode for "I want a
#              different split" on a disk we already own -- there is no in-place resize.
#   reinstall  nothing. It opens no partition table at all. The eight are already where they belong,
#              so a repair rewrites filesystems, not the GPT.
#   uninstall  our eight, and Android's data a second time -- userdata changes size, so its
#              filesystem cannot survive it.
set -euo pipefail

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
SELECT="${NOVADECK_SELECT_TARGET:-$SELFDIR/select-target.sh}"

# lib-slotwrite.sh, for `part_dev` alone. It is a shipped library and this script is installer-only,
# so it is resolved by search, exactly as genpart.sh is below. Sourced rather than reimplemented
# because "turn an index into a device path" is the one rule every write in the install depends on
# (the `p` infix we cannot test), and a private second copy of it here is how the two halves of the
# installer end up disagreeing about which partition they are addressing.
SLOTWRITE="${NOVADECK_SLOTWRITE:-}"
if [ -z "$SLOTWRITE" ]; then
  for c in "$SELFDIR/lib-slotwrite.sh" \
           /usr/lib/novadeck/install/lib-slotwrite.sh \
           "$SELFDIR/../rootfs/overlay/usr/lib/novadeck/install/lib-slotwrite.sh"; do
    [ -r "$c" ] && { SLOTWRITE="$c"; break; }
  done
fi

# genpart.sh is SHIPPED (into /usr/lib/novadeck/install/) while this script is installer-only, so
# the two do not always sit together. Resolved by search rather than by a repo-relative path, for
# the same reason genpart resolves its table next to itself.
GENPART="${NOVADECK_GENPART:-}"
if [ -z "$GENPART" ]; then
  for c in "$SELFDIR/genpart.sh" /usr/lib/novadeck/install/genpart.sh "$SELFDIR/../image/genpart.sh"; do
    [ -x "$c" ] && { GENPART="$c"; break; }
  done
fi

# lib-gpt.sh, shipped beside genpart.sh and resolved the same way.
LIBGPT="${NOVADECK_LIB_GPT:-}"
if [ -z "$LIBGPT" ]; then
  for c in "$SELFDIR/lib-gpt.sh" /usr/lib/novadeck/install/lib-gpt.sh "$SELFDIR/../image/lib-gpt.sh"; do
    [ -r "$c" ] && { LIBGPT="$c"; break; }
  done
fi

# The GPT names of our eight, in layout order. Deletion is BY NAME and only by name: an index is
# never trusted from a caller or from arithmetic, because the difference between deleting p9 and
# deleting p8 is the difference between our ESP and somebody's `abl`.
OUR_NAMES=(NOVADECK-ESP novadeck-efi-A novadeck-efi-B novadeck-root-A novadeck-root-B \
           novadeck-var-A novadeck-var-B novadeck-home)

ANDROID_FLOOR_GIB="${ANDROID_FLOOR_GIB:-1}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'carve: %s\n' "$*" >&2; exit 1; }

usage() {
  say "usage: carve.sh fresh <disk> <userdata-gib>"
  say "       carve.sh plan  <disk> <userdata-gib>   (writes nothing)"
  say "       carve.sh reinstall <disk>"
  say "       carve.sh uninstall <disk>"
  exit 2
}

[ $# -ge 2 ] || usage
INTENT="$1"; DISK="$2"
command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found"
command -v sfdisk >/dev/null 2>&1 || die "sfdisk not found -- the table cannot be read without it"
[ -n "$GENPART" ] && [ -x "$GENPART" ] || die "cannot find genpart.sh (set NOVADECK_GENPART)"
[ -n "$LIBGPT" ] && [ -r "$LIBGPT" ] || die "cannot find lib-gpt.sh (set NOVADECK_LIB_GPT)"
[ -x "$SELECT" ] || die "cannot find select-target.sh (set NOVADECK_SELECT_TARGET)"
[ -n "$SLOTWRITE" ] && [ -r "$SLOTWRITE" ] \
  || die "cannot find lib-slotwrite.sh (set NOVADECK_SLOTWRITE)"
# Sourced AFTER die() and say() exist: the library only defines its own fallbacks when the caller
# has none, and this script's `carve: ` prefix is what its suite asserts.
# shellcheck source=../rootfs/overlay/usr/lib/novadeck/install/lib-slotwrite.sh
. "$SLOTWRITE"
# shellcheck source=../image/lib-gpt.sh
. "$LIBGPT"

# --- reading the disk -----------------------------------------------------------------------------
# gpt_rows() comes from lib-gpt.sh -- the same function select-target.sh reads the table through,
# which is the point: `genpart` decides what is in the way, this script decides what belongs to us,
# and select-target decides the ceiling. Three scans of one table, and issue #56 is what happened
# when one of them counted rows the GPT no longer uses. A private copy here is how the halves
# disagree, so there is not one.
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

is_ours() {  # <gpt-name>
  local n
  for n in "${OUR_NAMES[@]}"; do [ "$1" = "$n" ] && return 0; done
  return 1
}

index_of() {  # <gpt-name> -> index, or nothing
  gpt_rows "$DISK" | awk -v want="$1" '$5 == want {print $1; exit}'
}

# The last sector our partitions may occupy, and it is NOT always select-target's CEIL. That one
# stops at whatever follows userdata -- which on a disk we already own is our own ESP, giving a
# window of zero sectors for a resize. So the ceiling here skips anything that is ours: it is the
# sector before the first FOREIGN partition starting after userdata, or the last usable sector when
# none does. On a stock disk no partition is ours and the two agree, which is asserted below.
effective_ceiling() {  # <ud_end> -> sector
  local ud_end="$1" next
  next="$(gpt_rows "$DISK" | awk -v e="$ud_end" '$2 > e {print $2, $5}' | sort -n | while read -r s n; do
            is_ours "$n" || { printf '%s\n' "$s"; break; }
          done)"
  if [ -n "$next" ]; then
    printf '%s\n' "$(( next - 1 ))"
  else
    sgdisk -p "$DISK" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p' | head -1
  fi
}

# --- writing ----------------------------------------------------------------------------------------
# Residue from a foreign uninstaller, cleared before the first write of the carve -- issue #56.
#
# It is not enough to have taught the scans to ignore these entries. sgdisk disowns them when asked
# (`-i N` says the partition does not exist) and STILL refuses to allocate their sectors, so the
# append would die on its first `sgdisk -n` with userdata already shrunk. See the measurement in
# lib-gpt.sh; this is the step that makes such a disk installable at all.
#
# FIRST, ahead of delete_ours and the resize, so a disk that cannot be cleaned is left exactly as
# it was found rather than mid-carve. Silent and free on every disk that has no residue, which is
# every stock board we have captured.
drop_residue() {
  local n
  gpt_has_dead_entries "$DISK" || return 0
  say "  $DISK carries GPT entries the table itself no longer uses -- a foreign uninstaller left them"
  n="$(gpt_drop_dead_entries "$DISK")"
  say "  unused GPT entries removed: ${n:-0}; every live partition is unchanged"
  settle
}

# A GPT ENTRY IS NOT A FILESYSTEM. A newly appended partition inherits whatever bytes were already
# under it, and on any disk that has carried a layout before, those sectors were somebody else's --
# our own previous ESP, efi-B or root-A, one layout ago.
#
# MEASURED on the Pocket ACE, 2026-08-22, re-installing after the ESP went 512M -> 256M and the efi
# partitions 64M -> 128M: the new efi-B (p14) came up carrying a stale vfat superblock at 0x0 AND a
# stale btrfs one at 0x10040. libblkid's safeprobe calls two conflicting signatures ambiguous and
# refuses to answer, systemd-udevd's blkid builtin then fails with EPERM, and so udev never
# publishes ID_PART_ENTRY_* or /dev/disk/by-partuuid/<uuid> for that partition AT ALL. The install
# died resolving a partition that was present, correct in the GPT and readable with dd. Nothing in
# the error pointed at a filesystem signature, and no amount of settling or re-triggering helps --
# udev is not late, it is refusing.
#
# 1 MiB at the head covers every superblock that matters (vfat and xfs at 0, ext at 0x400, btrfs at
# 0x10000), and it is addressed BY DISK OFFSET rather than through a partition node. That is the
# point and not an incidental choice: the node is exactly what the stale signature prevents from
# existing, so anything that needed /dev/disk/by-partuuid here could never run.
WIPE_HEAD_MIB="${NOVADECK_WIPE_HEAD_MIB:-1}"
wipe_our_heads() {
  local name idx start count
  count=$(( WIPE_HEAD_MIB * 1048576 / SECTOR ))
  for name in "${OUR_NAMES[@]}"; do
    idx="$(index_of "$name")"
    [ -n "$idx" ] || die "cannot find $name after the append -- refusing to leave stale signatures"
    start="$(sgdisk -i "$idx" "$DISK" 2>/dev/null | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
    [ -n "$start" ] || die "cannot read the start sector of $name (p$idx)"
    dd if=/dev/zero of="$DISK" bs="$SECTOR" seek="$start" count="$count" \
       conv=notrunc,fsync status=none \
      || die "could not clear the head of $name (p$idx)"
  done
  say "  stale filesystem signatures cleared from the head of all eight (${WIPE_HEAD_MIB} MiB each)"
}

delete_ours() {  # deletes every partition of ours that exists, by name; prints what it removed
  local name idx removed=0
  for name in "${OUR_NAMES[@]}"; do
    idx="$(index_of "$name")"
    [ -n "$idx" ] || continue
    sgdisk -d "$idx" "$DISK" >/dev/null || die "cannot delete $name (p$idx)"
    say "  removed p$idx $name"
    removed=$(( removed + 1 ))
  done
  say "  ${removed} novadeck partition(s) removed"
}

# Delete userdata and put it back at <end>, at its ORIGINAL start, index and type GUID. The type is
# the part that is easy to lose and expensive to notice: stock userdata is a vendor type, and the
# Pocket FIT capture shows a carve that handed it back as Linux filesystem data. Android surviving
# factory-reset-but-working is the entire justification for destroying it, so this is verified by
# reading the result back rather than by trusting sgdisk's exit status.
recreate_userdata() {  # <index> <start> <end> <type-guid>
  local idx="$1" start="$2" end="$3" type="$4" got_start got_end got_type got_name info
  sgdisk -d "$idx" "$DISK" >/dev/null || die "cannot delete userdata (p$idx)"
  sgdisk -n "$idx:$start:$end" -t "$idx:$type" -c "$idx:userdata" "$DISK" >/dev/null \
    || die "cannot recreate userdata (p$idx) at $start..$end"

  info="$(sgdisk -i "$idx" "$DISK" 2>/dev/null)"
  got_start="$(printf '%s\n' "$info" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
  got_end="$(  printf '%s\n' "$info" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
  got_type="$( printf '%s\n' "$info" | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
  got_name="$( printf '%s\n' "$info" | sed -n "s/^Partition name: '\(.*\)'$/\1/p")"

  [ "$got_start" = "$start" ] && [ "$got_end" = "$end" ] \
    || die "userdata came back at $got_start..$got_end, asked for $start..$end -- STOPPING before anything else is written"
  [ "${got_type^^}" = "${type^^}" ] \
    || die "userdata came back typed $got_type, the original was $type -- Android would not recognise its own data partition"
  [ "$got_name" = userdata ] \
    || die "userdata came back named '$got_name'"
  say "  userdata recreated: p$idx $start..$end, type $got_type"
}

# THE OTHER OS MUST NOT BE ABLE TO MOUNT WHAT WAS THERE BEFORE THE RESIZE, and this exists because it
# could. MEASURED on the Pocket ACE 2026-08-21: after a carve from 96.72 GiB to 16, Android booted,
# mounted the OLD superblock without complaint and reported 92 GB free -- every one of those "free"
# sectors past the new end being our ESP, both roots, both vars and /home. It did not re-run
# setup-wizard, which is how we know it never reformatted: it simply believed the stale geometry.
#
# So a carve that rewrites only the GPT hands the user a device where one large download corrupts the
# install, silently, days later. Zeroing the head of the partition is enough and is the whole fix: the
# PRIMARY superblock is what mount reads (ext4 at 1 KiB, f2fs at 0 and 4 KiB), and with it gone
# Android's fs_mgr formats userdata at its true size -- which is the factory reset the consent screen
# already promises, arriving without the user being sent to recovery.
#
# AND IT MUST BE UNCONDITIONAL `dd`, NOT `wipefs -a`, which is what this would otherwise obviously be.
# Measured on the same board: `blkid /dev/sda11` reports a PARTLABEL and PARTUUID and NO filesystem
# type at all, because Android holds userdata under metadata encryption (dm-default-key) -- the
# partition carries ciphertext with no discoverable signature, while `metadata` beside it is plain
# f2fs. wipefs would find nothing to erase and exit 0, doing precisely nothing, which is the most
# expensive kind of success. Zeroing works regardless because dm-default-key is a 1:1 offset-
# preserving mapping: the inner superblock's ciphertext lives where a plaintext one would.
#
# It is also why the stale mount succeeded rather than failing loudly. The inner filesystem is f2fs,
# and f2fs does not check its superblock's size against the device at mount time -- ext4 does, and
# would have refused. Do not assume a future Android will be as forgiving, and do not rely on it.
#
# It writes INSIDE userdata only, before a single one of our partitions exists, and its length is
# clamped to the partition. Destroying that filesystem is not a new blast radius: it is the one thing
# every mode here already destroys by design.
# 8 MiB, where roughly one would do: the superblocks sit in the first few KiB, but the margin is free
# inside a partition being destroyed anyway, and it covers f2fs's checkpoint area as well as the
# superblock pair rather than only what mount happens to read first. Independent implementations of
# this same shrink settle on the same figure, which is weak evidence but not none.
WIPE_MIB="${NOVADECK_WIPE_MIB:-8}"
invalidate_userdata_fs() {  # <index> <start-sector> <end-sector>
  local idx="$1" start="$2" end="$3" count dev
  count=$(( WIPE_MIB * 1048576 / SECTOR ))
  [ "$count" -le "$(( end - start + 1 ))" ] || count=$(( end - start + 1 ))

  settle
  if dev="$(part_dev "$DISK" "$idx")" && [ -b "$dev" ]; then
    dd if=/dev/zero of="$dev" bs="$SECTOR" count="$count" conv=fsync status=none \
      || die "could not invalidate the old filesystem on $dev"
  elif [ -b "$DISK" ]; then
    # A block device whose partition node did not appear is NOT a case to write around: the fallback
    # would have to be name arithmetic, and guessing a device node to dd zeros onto is precisely the
    # guess this project refuses to make.
    die "cannot resolve the partition node for p$idx by partuuid -- refusing to guess a device name"
  else
    dd if=/dev/zero of="$DISK" bs="$SECTOR" seek="$start" count="$count" conv=notrunc,fsync status=none \
      || die "could not invalidate the old filesystem in $DISK at sector $start"
  fi
  say "  old userdata filesystem invalidated (${WIPE_MIB} MiB zeroed at sector $start)"
}

# A block device needs the kernel to re-read the table before anyone can mkfs /dev/sdaN. sgdisk asks
# for that itself, but the device nodes appear asynchronously, so the next step in the spine can
# otherwise race a node that does not exist yet. Image files have no such problem and no such tools.
settle() {
  [ -b "$DISK" ] || return 0
  command -v partprobe   >/dev/null 2>&1 && partprobe "$DISK" >/dev/null 2>&1 || true
  command -v udevadm     >/dev/null 2>&1 && udevadm settle    >/dev/null 2>&1 || true
}

# --- the target, re-validated here rather than trusted from the caller -------------------------------
# select-target.sh is pure and cheap, so the destructive half runs it AGAIN instead of accepting an
# extent on the command line. The geometry a carve acts on is then the geometry of the disk as it is
# now, and every refusal in that script -- the running disk, a damaged GPT, a foreign bootable ESP,
# a board whose data partition is not called userdata -- stands between the caller and a write.
SEL="$("$SELECT" "$DISK")" || die "$DISK did not pass target selection -- nothing has been written"

STATE="$(field "$SEL" MODE)"
SECTOR="$(field "$SEL" SECTOR)"
UD_INDEX="$(field "$SEL" UD_INDEX)"
UD_START="$(field "$SEL" UD_START)"
UD_END="$(field "$SEL" UD_END)"
UD_TYPE="$(field "$SEL" UD_TYPE)"
SEL_CEIL="$(field "$SEL" CEIL)"
for v in STATE SECTOR UD_INDEX UD_START UD_END UD_TYPE SEL_CEIL; do
  [ -n "${!v}" ] || die "select-target.sh emitted no $v"
done

CEIL="$(effective_ceiling "$UD_END")"
[ -n "$CEIL" ] || die "cannot determine the last sector available to us"
# On a stock disk the two ceilings are the same statement, so a disagreement means one of the two
# read the table wrongly and the carve is about to act on the wrong span.
if [ "$STATE" = fresh ] && [ "$CEIL" != "$SEL_CEIL" ]; then
  die "ceiling disagreement on a disk with none of ours: $CEIL here, $SEL_CEIL from select-target"
fi

PER_GIB=$(( 1073741824 / SECTOR ))
PER_MIB=$(( 1048576 / SECTOR ))
MIN_MIB="$("$GENPART" --min)"

# --- the three modes --------------------------------------------------------------------------------
case "$INTENT" in
  reinstall)
    # Writes nothing. Its job is to hand the caller the map and to refuse loudly if the eight are not
    # all there -- a partial set is an interrupted install, which cannot be repaired in place because
    # the missing ones would have to be re-laid, which moves the floor and takes /home with it.
    missing=""
    for name in "${OUR_NAMES[@]}"; do
      [ -n "$(index_of "$name")" ] || missing="$missing $name"
    done
    [ -z "$missing" ] \
      || die "not a complete novadeck install, missing:$missing -- run a fresh install instead"
    say "[carve] reinstall: the eight are present, no partition table is written"
    for name in "${OUR_NAMES[@]}"; do printf '%s=%s\n' "$name" "$(index_of "$name")"; done
    ;;

  fresh|plan)
    [ $# -ge 3 ] || usage
    GIB="$3"
    case "$GIB" in *[!0-9]*|'') die "userdata size must be a whole number of GiB, got '$GIB'" ;; esac

    # Everything is checked before the first delete. The alternative is a disk whose userdata is
    # already gone when we discover our eight will not fit after it.
    [ "$GIB" -ge "$ANDROID_FLOOR_GIB" ] \
      || die "userdata must keep at least ${ANDROID_FLOOR_GIB} GiB for Android, asked for ${GIB}"
    NEW_END=$(( UD_START + GIB * PER_GIB - 1 ))
    [ "$NEW_END" -lt "$CEIL" ] \
      || die "a ${GIB} GiB userdata reaches $NEW_END, past the ceiling $CEIL -- nothing left for NovaDeck"
    WINDOW=$(( CEIL - NEW_END ))
    [ "$WINDOW" -ge "$(( MIN_MIB * PER_MIB ))" ] \
      || die "a ${GIB} GiB userdata leaves $(( WINDOW / PER_MIB )) MiB, and the layout needs ${MIN_MIB} MiB"

    # `plan` STOPS HERE, having written nothing. It exists because the consent screen has to quote
    # the resulting free space (plan §4d) and that number is only correct if it comes from this
    # arithmetic: NOVADECK_MIB is derived from effective_ceiling, and select-target's CEIL is the
    # WRONG input for it on a disk we already own -- it stops at our own ESP and yields zero.
    #
    # MEASURED, not theorised: on the Pocket ACE 2026-08-21 the consent screen told the operator
    # "NovaDeck will use the remaining 0 GiB" while this code went on to give it 90853 MiB. The
    # screen was deriving from CEIL. That is what this mode exists to stop, and it is why the number
    # is fetched from here rather than recomputed in the spine -- a second copy of the ceiling rule
    # is exactly how the two halves end up disagreeing again.
    #
    # REPLACES_OURS is the other half of the same finding: `fresh` on a disk we already own destroys
    # the existing /home, and the screen has to say so. carve.sh has always PRINTED that line; it
    # printed it after consent had been taken, where nobody could act on it.
    if [ "$INTENT" = plan ]; then
      printf 'CEIL=%s\nNEW_END=%s\nNOVADECK_MIB=%s\nNOVADECK_GIB=%s\nREPLACES_OURS=%s\n' \
        "$CEIL" "$NEW_END" "$(( WINDOW / PER_MIB ))" "$(( WINDOW / PER_GIB ))" \
        "$([ "$STATE" = fresh ] && printf 0 || printf 1)"
      # ONE `DESTROY=` LINE PER PARTITION THIS CARVE WILL DESTROY, for §5's pre-flight screen, which
      # has to show "the full list of partitions about to be destroyed" before anything is written.
      # It is emitted HERE, by the mode that will perform the carve, for the same reason NOVADECK_GIB
      # is: the alternative is the UI reading the table and applying its own idea of which partitions
      # are ours, which is a second copy of a rule that has already drifted once and cost a hardware
      # run. The list is exactly what the two destructive calls below touch -- recreate_userdata's
      # target, then everything delete_ours finds.
      #
      # Not listed: drop_residue's dead GPT entries. They name no live partition and hold nobody's
      # data, so putting them on a consent-adjacent screen would pad the list with entries a user
      # cannot act on.
      printf 'DESTROY=%s userdata data-erased\n' "$UD_INDEX"
      # An `if`, not `[ -n "$_idx" ] && printf`: under `set -e` an AND-list whose left side fails is
      # a failing command, and on a stock disk (where none of our eight exists) every iteration
      # would take that branch and kill the plan on the first one.
      for _name in "${OUR_NAMES[@]}"; do
        _idx="$(index_of "$_name")"
        if [ -n "$_idx" ]; then
          printf 'DESTROY=%s %s replaced\n' "$_idx" "$_name"
        fi
      done
      exit 0
    fi

    say "[carve] fresh install on $DISK"
    say "  userdata p$UD_INDEX: $(( (UD_END - UD_START + 1) / PER_GIB )) GiB -> ${GIB} GiB (Android is factory reset)"
    say "  novadeck gets $(( WINDOW / PER_MIB )) MiB, sectors $(( NEW_END + 1 ))..$CEIL"
    [ "$STATE" = fresh ] || say "  this disk already carries a novadeck install; it is being replaced, /home included"

    drop_residue
    delete_ours
    recreate_userdata "$UD_INDEX" "$UD_START" "$NEW_END" "$UD_TYPE"
    invalidate_userdata_fs "$UD_INDEX" "$UD_START" "$NEW_END"
    settle
    NOVADECK_APPEND_FLOOR=$(( NEW_END + 1 )) NOVADECK_APPEND_CEIL="$CEIL" "$GENPART" --append "$DISK"
    # Before the settle, not after: the settle is what gives udev its chance to probe these
    # partitions, and it must not find a stale signature when it does.
    wipe_our_heads
    settle
    ;;

  uninstall)
    # Give userdata the whole span back. No stored pre-state is consulted and none is needed: the
    # ceiling is by construction the last sector before whatever followed userdata, so on a board
    # where something does follow, the restored partition is byte-identical to the factory one, and
    # on a board where nothing does it additionally absorbs space that was unallocated to begin with.
    [ "$STATE" = reinstall ] \
      || die "$DISK carries no novadeck install -- nothing to uninstall"
    say "[carve] uninstall on $DISK"
    say "  userdata p$UD_INDEX: $(( (UD_END - UD_START + 1) / PER_GIB )) GiB -> $(( (CEIL - UD_START + 1) / PER_GIB )) GiB (Android is factory reset again)"

    drop_residue
    delete_ours
    recreate_userdata "$UD_INDEX" "$UD_START" "$CEIL" "$UD_TYPE"
    # Also here, for the opposite reason: the filesystem left behind describes the SHRUNK userdata,
    # so Android would mount a 16 GiB volume on a 96 GiB partition and silently keep the difference
    # from its owner. Uninstall says "Android is factory reset again"; this is what makes that true.
    invalidate_userdata_fs "$UD_INDEX" "$UD_START" "$CEIL"
    settle
    printf 'userdata=%s\n' "$UD_INDEX"
    ;;

  *) usage ;;
esac
