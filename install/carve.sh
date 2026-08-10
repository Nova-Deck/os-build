#!/usr/bin/env bash
# novadeck internal-install carve — the DESTRUCTIVE half, Phase 3/4 of
# .claude/plans/internal-install.plan.md.
#
#   install/carve.sh fresh     <disk> <userdata-gib>   # shrink userdata, append our eight
#   install/carve.sh reinstall <disk>                  # writes NOTHING; reports where the eight are
#   install/carve.sh uninstall <disk>                  # remove our eight, give userdata its span back
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

# genpart.sh is SHIPPED (into /usr/lib/novadeck/install/) while this script is installer-only, so
# the two do not always sit together. Resolved by search rather than by a repo-relative path, for
# the same reason genpart resolves its table next to itself.
GENPART="${NOVADECK_GENPART:-}"
if [ -z "$GENPART" ]; then
  for c in "$SELFDIR/genpart.sh" /usr/lib/novadeck/install/genpart.sh "$SELFDIR/../images/genpart.sh"; do
    [ -x "$c" ] && { GENPART="$c"; break; }
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
  say "       carve.sh reinstall <disk>"
  say "       carve.sh uninstall <disk>"
  exit 2
}

[ $# -ge 2 ] || usage
INTENT="$1"; DISK="$2"
command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found"
[ -n "$GENPART" ] && [ -x "$GENPART" ] || die "cannot find genpart.sh (set NOVADECK_GENPART)"
[ -x "$SELECT" ] || die "cannot find select-target.sh (set NOVADECK_SELECT_TARGET)"

# --- reading the disk -----------------------------------------------------------------------------
gpt_rows() { sgdisk -p "$DISK" 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {print $1, $2, $3, $(NF-1), $NF}'; }
field()    { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

is_ours() {  # <gpt-name>
  local n
  for n in "${OUR_NAMES[@]}"; do [ "$1" = "$n" ] && return 0; done
  return 1
}

index_of() {  # <gpt-name> -> index, or nothing
  gpt_rows | awk -v want="$1" '$5 == want {print $1; exit}'
}

# The last sector our partitions may occupy, and it is NOT always select-target's CEIL. That one
# stops at whatever follows userdata -- which on a disk we already own is our own ESP, giving a
# window of zero sectors for a resize. So the ceiling here skips anything that is ours: it is the
# sector before the first FOREIGN partition starting after userdata, or the last usable sector when
# none does. On a stock disk no partition is ours and the two agree, which is asserted below.
effective_ceiling() {  # <ud_end> -> sector
  local ud_end="$1" next
  next="$(gpt_rows | awk -v e="$ud_end" '$2 > e {print $2, $5}' | sort -n | while read -r s n; do
            is_ours "$n" || { printf '%s\n' "$s"; break; }
          done)"
  if [ -n "$next" ]; then
    printf '%s\n' "$(( next - 1 ))"
  else
    sgdisk -p "$DISK" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p' | head -1
  fi
}

# --- writing ----------------------------------------------------------------------------------------
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

  fresh)
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

    say "[carve] fresh install on $DISK"
    say "  userdata p$UD_INDEX: $(( (UD_END - UD_START + 1) / PER_GIB )) GiB -> ${GIB} GiB (Android is factory reset)"
    say "  novadeck gets $(( WINDOW / PER_MIB )) MiB, sectors $(( NEW_END + 1 ))..$CEIL"
    [ "$STATE" = fresh ] || say "  this disk already carries a novadeck install; it is being replaced, /home included"

    delete_ours
    recreate_userdata "$UD_INDEX" "$UD_START" "$NEW_END" "$UD_TYPE"
    settle
    NOVADECK_APPEND_FLOOR=$(( NEW_END + 1 )) NOVADECK_APPEND_CEIL="$CEIL" "$GENPART" --append "$DISK"
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

    delete_ours
    recreate_userdata "$UD_INDEX" "$UD_START" "$CEIL" "$UD_TYPE"
    settle
    printf 'userdata=%s\n' "$UD_INDEX"
    ;;

  *) usage ;;
esac
