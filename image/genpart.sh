#!/usr/bin/env bash
# novadeck partition-script generator — Phase 4, extended for internal install in Phase 2 of
# .claude/plans/internal-install.plan.md.
#
# Turns partition-table.txt into a runnable sgdisk script that lays down the A/B GPT on a
# target disk/image. Prints the script to stdout; with a target it also applies it.
# Side-effect-free unless a target is given.
#
#   image/genpart.sh                  # print sgdisk script (zap + create p1..p8)
#   image/genpart.sh --min            # print only the minimum target size in MiB
#   image/genpart.sh <target>         # also apply to <target> (disk or image file)
#   image/genpart.sh --append         # print the APPEND script (no zap; indices discovered)
#   NOVADECK_APPEND_FLOOR=<sector> image/genpart.sh --append <target>
#                                      # also apply it, and print the name=index map. The floor is
#                                      # REQUIRED to apply -- see "THE FLOOR IS MANDATORY" below.
#
# THIS FILE IS SHIPPED VERBATIM into /usr/lib/novadeck/install/ of the built root, alongside
# partition-table.txt, and a host test asserts the two copies are byte-identical. That is why the
# table is resolved NEXT TO THIS SCRIPT rather than through a repo-relative path: the same file has
# to work from image/ in the repo and from /usr/lib/novadeck/install/ on a device.
set -euo pipefail

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
TABLE="${NOVADECK_PARTITION_TABLE:-$SELFDIR/partition-table.txt}"
[ -f "$TABLE" ] || { echo "no partition table: $TABLE" >&2; exit 1; }

# lib-gpt.sh ships beside this script and beside the table, and is resolved the same way for the
# same reason. It is not sourced HERE: the containment check that needs it lives in the script this
# one emits, which runs in a bare `bash -c` with nothing but the environment. So the path travels
# as an environment variable and the emitted TEXT stays identical whichever copy generated it --
# which is what tests/test-install.sh case 9 asserts, and what would break if the resolved path
# were baked into the output.
LIBGPT="${NOVADECK_LIB_GPT:-}"
if [ -z "$LIBGPT" ]; then
  for c in "$SELFDIR/lib-gpt.sh" /usr/lib/novadeck/install/lib-gpt.sh "$SELFDIR/../image/lib-gpt.sh"; do
    [ -r "$c" ] && { LIBGPT="$c"; break; }
  done
fi

MODE=create
if [ "${1:-}" = "--append" ]; then MODE=append; shift; fi
TARGET="${1:-}"

# Sum the fixed partition sizes (MiB) for a minimum-target-size hint; 'rest' is 0.
minmib="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
    if (u=="G") m+=v*1024; else if (u=="M") m+=v }
  END { print m+1 }' "$TABLE")"   # +1 MiB GPT/alignment slack

# make-sdcard.sh sizes its image file off this, so the fixed layout stays defined in one place.
if [ "$TARGET" = "--min" ]; then
  echo "$minmib"
  exit 0
fi

# --- create mode: our 8 partitions ARE the disk -------------------------------------------------
# One sgdisk -n/-t/-c per row; 'rest' -> 0:0 (fills the disk). A row's 'attrs' column adds one
# --attributes per GPT bit, applied after the partition exists. Indices are the row order, which is
# true here and ONLY here -- see the append mode below.
partlines="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { n++
    spec = ($2 == "rest") ? "0:0" : "0:+" $2
    printf "sgdisk -n %d:%s -t %d:%s -c %d:%s \"$DISK\"\n", n, spec, n, $3, n, $5
    if ($6 != "" && $6 != "-") {
      k = split($6, bits, ",")
      for (i = 1; i <= k; i++) printf "sgdisk --attributes=%d:set:%s \"$DISK\"\n", n, bits[i]
    }
  }' "$TABLE")"

emit() {
  echo "# novadeck A/B GPT — generated from partition-table.txt"
  echo "# minimum target size: ${minmib} MiB ('home' expands to fill the rest)"
  echo 'DISK="${DISK:?set DISK to the target disk or image}"'
  echo 'sgdisk -Z "$DISK"   # zap any existing GPT/MBR'
  echo "$partlines"
  echo 'sgdisk -p "$DISK"   # print resulting table'
}

# --- append mode: our 8 join an EXISTING GPT ----------------------------------------------------
# For the dual-boot internal install, the OEM's partitions stay and ours are added after them. Three
# things differ from create mode, and each was verified against sgdisk rather than assumed:
#
#   NO -Z.            Zapping is the whole thing we are avoiding.
#
#   INDICES ARE NOT ROW ORDER, and are not even contiguous. `sgdisk -n 0:...` uses the first free
#   partition NUMBER, while start sector 0 uses the first sector of the LARGEST FREE BLOCK -- two
#   different rules. On a GPT with a hole at index 2, a partition created with 0 becomes p2 while
#   sitting physically last. So the index of each of our eight is DISCOVERED after creation, by GPT
#   name, and the name=index map is this mode's output. That map is what write_parts_env turns into
#   the /EFI/steamos/parts.env stage 2 reads (phase 1b) -- on this disk stage 2 cannot assume 1..8.
#
#   ATTRIBUTES CANNOT USE INDEX 0. `sgdisk --attributes=0:set:63` in its own invocation exits 4 and
#   sets nothing: 0 resolves to the first free number again, which after creation is the NEXT one.
#   Create mode gets away with a separate --attributes call only because it knows the literal index.
#   Here the attrs are applied after the lookup, against the real number.
#
# CONTAINMENT IS NOT THIS SCRIPT'S JOB, with one exception. Phase 3 owns the rule that every sector
# written lies inside the old userdata span; it deletes userdata and recreates it smaller, which is
# what makes the freed tail the largest free block and so the one start sector 0 selects. Because
# that is an inference about a disk this script cannot see, NOVADECK_APPEND_FLOOR exists: set it to
# the first sector our partitions may occupy -- the sector the shrunk userdata stops at, plus one --
# and the run refuses unless sgdisk agrees that is where it is about to start.
#
# THE FLOOR IS MANDATORY, not an option (Phase 3, was opt-in through Phase 2). Unset, sgdisk takes
# whatever the largest free block happens to be, and the containment rule then holds only because
# the carve happened to leave the freed tail as that block -- true by luck rather than by
# construction, which is not what a geometric bound is for. The asymmetry settles it: over-requiring
# the floor costs one relaxed line, forgetting it costs a device whose only recovery is EDL with a
# vendor firehose. So the emitted script refuses without one, and it refuses on a floor that is not
# a plain sector number: `[ x -lt abc ]` returns 2, which an `if` reads as false, so a typo'd floor
# would otherwise disable the check while looking set.
appendrows="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { attrs = ($6 == "" ? "-" : $6)
    printf "nd_newpart %s %s %s %s\n", $2, $3, $5, attrs }' "$TABLE")"

emit_append() {
  echo "# novadeck A/B GPT, APPENDED to an existing table — generated from partition-table.txt"
  echo "nd_min_mib=$minmib   # the fixed rows plus slack; home needs whatever is left over"
  cat <<'PREAMBLE'
DISK="${DISK:?set DISK to the target disk or image}"

# Where our partitions may begin. Required: this script cannot see the disk the carve freed, so the
# caller asserts it, and no assertion means no append. Checked FIRST, ahead of even reading the
# disk, so a missing floor is refused identically whatever state the target is in.
# No apostrophe in that message: bash opens a quote on a ' inside ${var:?...} even within double
# quotes, and the parse error it causes surfaces dozens of lines later.
: "${NOVADECK_APPEND_FLOOR:?required -- set it to the first sector our partitions may occupy}"
: "${NOVADECK_APPEND_CEIL:?required -- set it to the last sector our partitions may occupy}"
for nd_v in NOVADECK_APPEND_FLOOR NOVADECK_APPEND_CEIL; do
  case "${!nd_v}" in
    *[!0-9]*|'') echo "genpart: $nd_v must be a sector number, got '${!nd_v}'" >&2; exit 1 ;;
  esac
done
[ "$NOVADECK_APPEND_CEIL" -gt "$NOVADECK_APPEND_FLOOR" ] \
  || { echo "genpart: ceiling $NOVADECK_APPEND_CEIL is not above floor $NOVADECK_APPEND_FLOOR" >&2; exit 1; }

sgdisk -p "$DISK" >/dev/null 2>&1 \
  || { echo "genpart: $DISK has no readable GPT -- append needs one (use create mode)" >&2; exit 1; }

# Sizes are read in MiB but placement is in SECTORS, and a real UFS LUN reports 4096-byte logical
# sectors where an image file reports 512. Ask the disk rather than assuming either.
# Two spellings, and a device prints the one an image file never does:
#   Sector size (logical): 512 bytes            <- image file
#   Sector size (logical/physical): 4096/4096 bytes  <- a UFS LUN
nd_ss="$(sgdisk -p "$DISK" | sed -n 's/^Sector size (logical[^)]*): \([0-9]*\).*/\1/p')"
[ -n "$nd_ss" ] \
  || { echo "genpart: cannot read the logical sector size of $DISK" >&2; exit 1; }
nd_per_mib=$(( 1048576 / nd_ss ))

# Does what we are about to lay down actually fit between the floor and the ceiling? Asked BEFORE
# the first sgdisk -n, because the alternative is what a too-small window used to produce: three
# partitions created, the fourth refused, and a half-appended GPT on a disk the user cannot boot.
nd_window=$(( NOVADECK_APPEND_CEIL - NOVADECK_APPEND_FLOOR + 1 ))
if [ "$nd_window" -lt "$(( nd_min_mib * nd_per_mib ))" ]; then
  echo "genpart: the window is $(( nd_window / nd_per_mib )) MiB, and the layout needs ${nd_min_mib} MiB -- refusing" >&2
  echo "genpart: nothing has been written to $DISK" >&2
  exit 1
fi

# The rows below are read through lib-gpt.sh, not straight out of `sgdisk -p`, and that is the
# whole of issue #56. `sgdisk -p` renders a row for every GPT entry that still carries LBAs,
# INCLUDING the ones a third-party uninstaller zeroed the type GUID of -- entries the spec calls
# unused, the kernel does not enumerate, and sgdisk itself will allocate straight over. Read raw,
# those rows are indistinguishable from partitions that are really in the way, and the containment
# check below then refuses forever on a disk with nothing in it.
#
# die() first, so the library's refusals carry this script's prefix rather than its own. It does
# NOT claim nothing was written: the same reader is used again by nd_index_of, after partitions
# exist, and a refusal there that promised an untouched disk would be a lie at the worst moment.
# The containment check below prints that line itself, where it is true.
die() { echo "genpart: $1" >&2; exit 1; }
nd_libgpt="${NOVADECK_LIB_GPT:-/usr/lib/novadeck/install/lib-gpt.sh}"
[ -r "$nd_libgpt" ] || die "cannot read $nd_libgpt -- the containment check cannot run without it"
# shellcheck source=lib-gpt.sh
. "$nd_libgpt"

# CONTAINMENT, asserted here rather than inferred. Every sector we are about to write lies in
# [floor, ceil], so the one thing that can still make that unsafe is an existing partition inside
# the window. Refuse if any row overlaps it -- this is the check that means no pre-existing
# partition is ever written, and it holds whatever the caller got wrong.
while read -r nd_idx nd_start nd_end _; do
  [ -n "$nd_idx" ] || continue
  if [ "$nd_start" -le "$NOVADECK_APPEND_CEIL" ] && [ "$nd_end" -ge "$NOVADECK_APPEND_FLOOR" ]; then
    echo "genpart: partition $nd_idx occupies $nd_start..$nd_end, inside the window $NOVADECK_APPEND_FLOOR..$NOVADECK_APPEND_CEIL -- refusing" >&2
    echo "genpart: nothing has been written to $DISK" >&2
    exit 1
  fi
done < <(gpt_rows "$DISK")

# Which index did a just-created partition get? Asked by GPT name, which is unique across our eight.
# Through gpt_rows for the same reason as the containment check: a residue row carries no name at
# all, so a positional read of `sgdisk -p` would take the wrong field on it. It also answers in one
# process rather than one `sgdisk -i` per partition per lookup.
nd_index_of() {  # <gpt-name> -> index on stdout
  local idx
  idx="$(gpt_rows "$DISK" | awk -v want="$1" '$5 == want {print $1; exit}')"
  [ -n "$idx" ] || return 1
  printf '%s\n' "$idx"
}

# The running start sector. Every partition is placed EXPLICITLY from here, because `-n 0:0:+size`
# re-resolves the largest free block on every call: measured 2026-08-10, once the two 7 GiB roots
# had consumed the freed tail, var-A/var-B/home jumped to a bigger hole elsewhere on the disk and
# the run reported success. A floor check cannot catch that -- it only ever sees the first call.
nd_cursor="$NOVADECK_APPEND_FLOOR"

nd_newpart() {  # <size> <typecode> <gpt-name> <attrs>
  local size="$1" type="$2" name="$3" attrs="$4" spec idx bit
  # 'rest' ends at the ceiling, not at `0`: with an explicit START, sgdisk reads end 0 as the last
  # sector of the DISK and refuses the moment that span crosses a partition (measured, same run).
  if [ "$size" = rest ]; then spec="0:$nd_cursor:$NOVADECK_APPEND_CEIL"; else spec="0:$nd_cursor:+$size"; fi
  sgdisk -n "$spec" -t "0:$type" -c "0:$name" "$DISK" >/dev/null \
    || { echo "genpart: cannot create $name" >&2; exit 1; }
  idx="$(nd_index_of "$name")" \
    || { echo "genpart: created $name but cannot find it again by name" >&2; exit 1; }
  # Advance the cursor from what sgdisk ACTUALLY did, not from what we asked for, and re-assert the
  # ceiling per partition. The window check above proves the layout fits; this proves each row
  # landed where it was put, so the containment claim rests on the resulting GPT rather than on
  # arithmetic done before any of it existed.
  local last
  last="$(sgdisk -i "$idx" "$DISK" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
  [ -n "$last" ] \
    || { echo "genpart: cannot read the end sector of $name (p$idx)" >&2; exit 1; }
  [ "$last" -le "$NOVADECK_APPEND_CEIL" ] \
    || { echo "genpart: $name ends at $last, past the ceiling $NOVADECK_APPEND_CEIL" >&2; exit 1; }
  nd_cursor=$(( last + 1 ))
  if [ "$attrs" != "-" ]; then
    local IFS=,
    for bit in $attrs; do
      sgdisk "--attributes=$idx:set:$bit" "$DISK" >/dev/null \
        || { echo "genpart: cannot set GPT attribute $bit on $name (p$idx)" >&2; exit 1; }
    done
  fi
  printf '%s=%s\n' "$name" "$idx"
}
PREAMBLE
  echo "$appendrows"
}

# --- drive --------------------------------------------------------------------------------------
if [ "$MODE" = append ]; then
  if [ -z "$TARGET" ]; then emit_append; exit 0; fi
  command -v sgdisk >/dev/null 2>&1 || { echo "sgdisk not found (run inside novadeck-build)" >&2; exit 1; }
  command -v sfdisk >/dev/null 2>&1 \
    || { echo "sfdisk not found -- the containment check reads type GUIDs with it" >&2; exit 1; }
  [ -n "$LIBGPT" ] && [ -r "$LIBGPT" ] || { echo "genpart: cannot find lib-gpt.sh (set NOVADECK_LIB_GPT)" >&2; exit 1; }
  echo "[novadeck] appending the A/B GPT to $TARGET (min ${minmib} MiB of free space)" >&2
  DISK="$TARGET" NOVADECK_LIB_GPT="$LIBGPT" bash -euo pipefail -c "$(emit_append)"
  exit 0
fi

if [ -z "$TARGET" ]; then
  emit
  exit 0
fi

command -v sgdisk >/dev/null 2>&1 || { echo "sgdisk not found (run inside novadeck-build)" >&2; exit 1; }
# "A/B" is not said here on purpose: NOVADECK_PARTITION_TABLE also serves installer/medium-table.txt,
# a two-partition installer medium with no slots at all, and a build log announcing an A/B layout
# for it describes something that is not happening. The table names itself in the line instead.
echo "[novadeck] applying the GPT from ${TABLE##*/} to $TARGET (min ${minmib} MiB)" >&2
DISK="$TARGET" bash -euo pipefail -c "$(emit)"
