#!/usr/bin/env bash
# novadeck partition-script generator — Phase 4, extended for internal install in Phase 2 of
# .claude/plans/internal-install.plan.md.
#
# Turns partition-table.txt into a runnable sgdisk script that lays down the A/B GPT on a
# target disk/image. Prints the script to stdout; with a target it also applies it.
# Side-effect-free unless a target is given.
#
#   images/genpart.sh                  # print sgdisk script (zap + create p1..p8)
#   images/genpart.sh --min            # print only the minimum target size in MiB
#   images/genpart.sh <target>         # also apply to <target> (disk or image file)
#   images/genpart.sh --append         # print the APPEND script (no zap; indices discovered)
#   NOVADECK_APPEND_FLOOR=<sector> images/genpart.sh --append <target>
#                                      # also apply it, and print the name=index map. The floor is
#                                      # REQUIRED to apply -- see "THE FLOOR IS MANDATORY" below.
#
# THIS FILE IS SHIPPED VERBATIM into /usr/lib/novadeck/install/ of the built root, alongside
# partition-table.txt, and a host test asserts the two copies are byte-identical. That is why the
# table is resolved NEXT TO THIS SCRIPT rather than through a repo-relative path: the same file has
# to work from images/ in the repo and from /usr/lib/novadeck/install/ on a device.
set -euo pipefail

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
TABLE="${NOVADECK_PARTITION_TABLE:-$SELFDIR/partition-table.txt}"
[ -f "$TABLE" ] || { echo "no partition table: $TABLE" >&2; exit 1; }

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
  cat <<'PREAMBLE'
# novadeck A/B GPT, APPENDED to an existing table — generated from partition-table.txt
DISK="${DISK:?set DISK to the target disk or image}"

# Where our partitions may begin. Required: this script cannot see the disk the carve freed, so the
# caller asserts it, and no assertion means no append. Checked FIRST, ahead of even reading the
# disk, so a missing floor is refused identically whatever state the target is in.
# No apostrophe in that message: bash opens a quote on a ' inside ${var:?...} even within double
# quotes, and the parse error it causes surfaces dozens of lines later.
: "${NOVADECK_APPEND_FLOOR:?required -- set it to the first sector our partitions may occupy}"
case "$NOVADECK_APPEND_FLOOR" in
  *[!0-9]*|'')
    echo "genpart: NOVADECK_APPEND_FLOOR must be a sector number, got '$NOVADECK_APPEND_FLOOR'" >&2
    exit 1 ;;
esac

sgdisk -p "$DISK" >/dev/null 2>&1 \
  || { echo "genpart: $DISK has no readable GPT -- append needs one (use create mode)" >&2; exit 1; }

# The first aligned sector of the largest free block: what `-n 0:0:...` is about to pick. It has to
# be the sector the caller named, not merely at-or-after it -- MEASURED 2026-08-10: a disk with a
# bigger unallocated region elsewhere makes sgdisk -F return a sector ABOVE the floor, and a
# lower-bound test then accepts a run that lays all eight outside the space the carve freed. Not a
# brick, since that region holds nothing, but the user gave up Android's data for room we would then
# not use, and home would be sized by an unrelated hole. So the floor is an EXPECTATION, and the
# window is one 1 MiB alignment grain wide because that is sgdisk's own rounding.
nd_first_free="$(sgdisk -F "$DISK")"
if [ "$nd_first_free" -lt "$NOVADECK_APPEND_FLOOR" ] \
   || [ "$nd_first_free" -gt "$((NOVADECK_APPEND_FLOOR + 2047))" ]; then
  echo "genpart: sgdisk would start at sector $nd_first_free, but the carve freed sector $NOVADECK_APPEND_FLOOR -- refusing" >&2
  echo "genpart: the largest free block on $DISK is not the space the carve freed" >&2
  exit 1
fi

# Which index did a just-created partition get? Asked by GPT name, which is unique across our eight.
nd_index_of() {  # <gpt-name> -> index on stdout
  local n want="$1" got
  for n in $(sgdisk -p "$DISK" | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {print $1}'); do
    got="$(sgdisk -i "$n" "$DISK" | sed -n "s/^Partition name: '\(.*\)'$/\1/p")"
    [ "$got" = "$want" ] && { printf '%s\n' "$n"; return 0; }
  done
  return 1
}

nd_newpart() {  # <size> <typecode> <gpt-name> <attrs>
  local size="$1" type="$2" name="$3" attrs="$4" spec idx bit
  if [ "$size" = rest ]; then spec="0:0:0"; else spec="0:0:+$size"; fi
  sgdisk -n "$spec" -t "0:$type" -c "0:$name" "$DISK" >/dev/null \
    || { echo "genpart: cannot create $name" >&2; exit 1; }
  idx="$(nd_index_of "$name")" \
    || { echo "genpart: created $name but cannot find it again by name" >&2; exit 1; }
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
  echo "[novadeck] appending the A/B GPT to $TARGET (min ${minmib} MiB of free space)" >&2
  DISK="$TARGET" bash -euo pipefail -c "$(emit_append)"
  exit 0
fi

if [ -z "$TARGET" ]; then
  emit
  exit 0
fi

command -v sgdisk >/dev/null 2>&1 || { echo "sgdisk not found (run inside novadeck-build)" >&2; exit 1; }
echo "[novadeck] applying A/B GPT to $TARGET (min ${minmib} MiB)" >&2
DISK="$TARGET" bash -euo pipefail -c "$(emit)"
