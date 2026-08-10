#!/usr/bin/env bash
# Offline tests for carve.sh, the DESTRUCTIVE half — Phase 3 of
# .claude/plans/internal-install.plan.md.
#
#   install/test-carve.sh          # needs sgdisk; run inside novadeck-build
#
# THIS IS THE SCRIPT THAT DELETES PARTITIONS, so the assertion budget goes on the two claims that
# stand between a user and an EDL recovery, and both are checked against the RESULTING GPT rather
# than against the arithmetic that produced it:
#
#   CONTAINMENT   every sector we wrote lies inside the span userdata gave up, so no pre-existing
#                 partition is ever written. Attacked directly below: each fixture's foreign rows
#                 are compared before and after, byte for byte.
#   REFUSAL IS FREE  a carve that refuses must leave the disk EXACTLY as it found it. A run that
#                 deleted userdata and then discovered our eight would not fit is the failure this
#                 suite exists to prevent, so every refusal case asserts the table is unchanged.
#
# Like test-select-target.sh this hangs off the installer image, not `make test` -- carve.sh is
# never shipped into the rootfs. Fixtures are sparse image files; nothing is mounted, nothing needs
# root, and a carve on an image file exercises exactly the code a carve on a device does.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARVE="$ROOT/install/carve.sh"
CAPTURES="$ROOT/docs/internal-storage.md"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$CARVE" "$CAPTURES" "$ROOT/install/select-target.sh" "$ROOT/images/genpart.sh"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v sgdisk >/dev/null 2>&1 || {
  CASE="prerequisites"; skip "sgdisk is not installed -- run this inside novadeck-build"
  printf '\ntest-carve.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"; exit 0
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export NOVADECK_SELECT_FIXTURE=1
. "$ROOT/install/lib-gptfixture.sh"

OUR_NAMES=(NOVADECK-ESP novadeck-efi-A novadeck-efi-B novadeck-root-A novadeck-root-B \
           novadeck-var-A novadeck-var-B novadeck-home)
BOARDS=("AYANEO Pocket S2" "AYANEO Pocket ACE" "AYN Odin 2" "KONKR Pocket FIT")

carve()  { bash "$CARVE" "$@" 2>&1; }
rows()   { sgdisk -p "$1" 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {print $1, $2, $3, $NF}'; }
# The foreign rows -- everything that is not ours and not userdata. This is the containment claim in
# executable form: whatever a carve does, these lines must come out identical.
foreign() { rows "$1" | grep -vE " (userdata|$(IFS='|'; echo "${OUR_NAMES[*]}"))$"; }
ours()   { rows "$1" | grep -cE " ($(IFS='|'; echo "${OUR_NAMES[*]}"))$"; }
udrow()  { sgdisk -i "$(rows "$1" | awk '$4=="userdata" {print $1}')" "$1" 2>/dev/null; }
udfield(){ udrow "$1" | sed -n "s/^$2: \([0-9A-Fa-f-]*\).*/\1/p"; }

board_img() {  # <board> -> path to a freshly rebuilt sda fixture
  local img="$T/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_').img"
  rows_for "$1" /dev/sda | build "$img" || return 1
  printf '%s\n' "$img"
}

# --- 1. a fresh carve on every captured board -------------------------------------------------------
# The headline claim, on real geometry rather than a synthetic disk: all four boards carve, our eight
# land after the shrunk userdata, and NOTHING ELSE ON THE DISK MOVES. The Odin 2 earns its place --
# userdata is p17 there, with sixteen partitions in front of it that must come out untouched.
CASE="a fresh carve lands the eight and moves nothing else"
for board in "${BOARDS[@]}"; do
  img="$(board_img "$board")" || { bad "$board: could not rebuild the captured GPT"; continue; }
  before="$(foreign "$img")"; ud_type_before="$(udfield "$img" 'Partition GUID code')"
  ud_start_before="$(udfield "$img" 'First sector')"

  if out="$(carve fresh "$img" 33)"; then
    ok "$board: carved"
  else
    bad "$board: refused a disk select-target accepts: $out"; continue
  fi

  [ "$(ours "$img")" = 8 ] \
    && ok "$board: all eight created" \
    || bad "$board: $(ours "$img") of our partitions exist, expected 8"
  [ "$(foreign "$img")" = "$before" ] \
    && ok "$board: every foreign partition is byte-identical after the carve" \
    || bad "$board: a partition outside userdata's span MOVED -- containment is broken"
  [ "$(udfield "$img" 'Partition GUID code')" = "$ud_type_before" ] \
    && ok "$board: userdata kept its vendor type GUID" \
    || bad "$board: userdata came back typed $(udfield "$img" 'Partition GUID code'), was $ud_type_before"
  [ "$(udfield "$img" 'First sector')" = "$ud_start_before" ] \
    && ok "$board: userdata still starts where it did" \
    || bad "$board: userdata moved to $(udfield "$img" 'First sector'), was $ud_start_before"
  # The map is the output contract: eight name=index lines the spine turns into parts.env.
  [ "$(printf '%s\n' "$out" | grep -cE '^(NOVADECK-ESP|novadeck-[a-z]+-?[AB]?)=[0-9]+$')" = 8 ] \
    && ok "$board: emitted eight name=index lines" \
    || bad "$board: the name=index map is not eight lines"
done

# --- 2. our eight are inside the freed span, on the board where something FOLLOWS userdata -----------
# The Pocket FIT is the only capture with a partition after userdata, so it is the one that can catch
# a home that runs past the ceiling into a neighbour. On the other three the ceiling is the end of the
# disk and this case cannot fail.
CASE="the eight stay inside the window"
fit="$(board_img "KONKR Pocket FIT")"
# Two passes, and deliberately so: read userdata's end FIRST and hand it to awk as a number. Done in
# one pass the variable is still unset while the earlier rows stream past, and `$2 > ""` is a STRING
# comparison that is true for every row -- which reports the whole layout as escaped and reads like
# a containment failure.
ud_end_before="$(udfield "$fit" 'Last sector')"
next_start="$(rows "$fit" | awk -v e="$ud_end_before" '$2 > e {print $2}' | sort -n | head -1)"
[ -n "$next_start" ] || bad "the FIT capture has nothing after userdata -- this case cannot bind"
carve fresh "$fit" 33 >/dev/null 2>&1
ud_end="$(udfield "$fit" 'Last sector')"
outside="$(rows "$fit" | grep -E " ($(IFS='|'; echo "${OUR_NAMES[*]}"))$" \
           | awk -v lo="$ud_end" -v hi="$next_start" '$2 <= lo || $3 >= hi {print}')"
[ -z "$outside" ] \
  && ok "every one of the eight lies strictly between userdata and the next partition" \
  || bad "a partition escaped the window: $outside"

# --- 3. a refusal costs nothing -----------------------------------------------------------------------
# Each of these must leave the table EXACTLY as it was. The order matters: the size checks run before
# the first delete precisely so a disk cannot be left with its userdata gone and nowhere to put ours.
CASE="a refusal leaves the disk untouched"
s2="$(board_img "AYANEO Pocket S2")"
snap="$(rows "$s2")"
for arg in 470 0 33G -1 ""; do
  out="$(carve fresh "$s2" "$arg")"
  if [ "$(rows "$s2")" = "$snap" ]; then
    ok "fresh '$arg' -> refused, table unchanged"
  else
    bad "fresh '$arg' modified the table before refusing"
  fi
done
# One sector too small for the layout, computed rather than guessed: the largest userdata that still
# leaves room, plus one GiB, must refuse -- and the boundary below it must succeed.
minmib="$(bash "$ROOT/images/genpart.sh" --min)"
span_gib=$(( ( $(udfield "$s2" 'Last sector') - $(udfield "$s2" 'First sector') + 1 ) / 2097152 ))
fits=$(( span_gib - (minmib + 1023) / 1024 ))
out="$(carve fresh "$s2" $(( fits + 1 )))"
{ [ "$(rows "$s2")" = "$snap" ] && printf '%s\n' "$out" | grep -q "the layout needs"; } \
  && ok "one GiB past what fits -> refused, naming both sizes, table unchanged" \
  || bad "a userdata one GiB too large was not refused cleanly: $out"
carve fresh "$s2" "$fits" >/dev/null 2>&1 \
  && ok "the largest userdata that fits -> carved" \
  || bad "the boundary that should fit was refused"

# --- 4. carve refuses whatever select-target refuses ---------------------------------------------------
# carve.sh re-runs selection itself rather than trusting a caller's extent, so every refusal in that
# script is also a refusal here. If this regresses, a caller could hand carve a disk that never
# passed the victim rule -- which is the wrong-LUN case, and the wrong LUN carries abl.
CASE="selection is re-run, not trusted"
lun="$T/lun.img"; rows_for "AYANEO Pocket S2" /dev/sdb | build "$lun"
snap="$(rows "$lun")"
out="$(carve fresh "$lun" 33)"
{ [ "$(rows "$lun")" = "$snap" ] && printf '%s\n' "$out" | grep -q "did not pass target selection"; } \
  && ok "a LUN with no userdata -> refused before any write" \
  || bad "carve wrote to a disk selection rejects: $out"

# --- 5. reinstall writes nothing ------------------------------------------------------------------------
# Not "delete and recreate at an identical extent" -- nothing at all. The assertion is the whole point
# of the mode, since this is the path whose entire purpose is that /home survives it.
CASE="reinstall opens no partition table"
re="$(board_img "AYANEO Pocket ACE")"
carve fresh "$re" 33 >/dev/null 2>&1
snap="$(rows "$re")"
out="$(carve reinstall "$re")"
[ "$(rows "$re")" = "$snap" ] \
  && ok "the table is byte-identical after a reinstall" \
  || bad "reinstall modified the partition table"
[ "$(printf '%s\n' "$out" | grep -cE '=[0-9]+$')" = 8 ] \
  && ok "reinstall still reports where the eight are" \
  || bad "reinstall did not emit the eight-line map"
# A partial set is an interrupted install: it cannot be repaired in place, because re-laying the
# missing ones moves the floor and takes /home with it. Refuse and say so.
part="$T/partial.img"; cp --sparse=always "$re" "$part"
sgdisk -d "$(rows "$part" | awk '$4=="novadeck-var-B" {print $1}')" "$part" >/dev/null 2>&1
snap="$(rows "$part")"
out="$(carve reinstall "$part")"
{ [ "$(rows "$part")" = "$snap" ] && printf '%s\n' "$out" | grep -q "run a fresh install instead"; } \
  && ok "a partial set -> refused, pointing at a fresh install" \
  || bad "an incomplete install was accepted as a reinstall: $out"

# --- 6. resizing a disk we already own ------------------------------------------------------------------
# THE CASE THE EFFECTIVE CEILING EXISTS FOR. select-target's CEIL stops at whatever follows userdata,
# which on a disk we own is our own ESP -- a window of zero sectors. carve computes its own ceiling by
# skipping anything of ours, so without this the "I want a different split" path cannot run at all.
CASE="a resize on a disk that is already ours"
rz="$(board_img "AYN Odin 2")"
before="$(foreign "$rz")"
carve fresh "$rz" 33 >/dev/null 2>&1
home_before="$(rows "$rz" | awk '$4=="novadeck-home" {print $3}')"
if out="$(carve fresh "$rz" 64)"; then
  ok "a 33 -> 64 GiB resize carves"
else
  bad "a resize on our own disk was refused: $out"
fi
[ "$(( ( $(udfield "$rz" 'Last sector') - $(udfield "$rz" 'First sector') + 1 ) / 2097152 ))" = 64 ] \
  && ok "userdata is 64 GiB afterwards" \
  || bad "userdata is $(( ( $(udfield "$rz" 'Last sector') - $(udfield "$rz" 'First sector') + 1 ) / 2097152 )) GiB, expected 64"
[ "$(ours "$rz")" = 8 ] \
  && ok "still exactly eight of ours, not sixteen" \
  || bad "$(ours "$rz") of our partitions exist after a resize"
[ "$(foreign "$rz")" = "$before" ] \
  && ok "the resize moved no foreign partition either" \
  || bad "a resize moved something outside the span"
[ "$(rows "$rz" | awk '$4=="novadeck-home" {print $3}')" = "$home_before" ] \
  && ok "home still ends at the ceiling" \
  || bad "home ends somewhere new after a resize"

# --- 7. an interrupted carve is completed by re-running --------------------------------------------------
# There is no undo and no backup (rule 10), so "re-run it" is the entire recovery story for a carve
# that died halfway. Simulate the state a SIGPIPE or a pulled card leaves -- some of ours deleted,
# userdata already shrunk -- and assert a second run lands all eight.
CASE="re-running completes an interrupted carve"
ip="$T/interrupted.img"; cp --sparse=always "$(board_img "AYANEO Pocket S2")" "$ip"
carve fresh "$ip" 33 >/dev/null 2>&1
for n in novadeck-home novadeck-var-B novadeck-root-B; do
  sgdisk -d "$(rows "$ip" | awk -v w="$n" '$4==w {print $1}')" "$ip" >/dev/null 2>&1
done
[ "$(ours "$ip")" = 5 ] || bad "the interrupted fixture is not in the state the case assumes"
if carve fresh "$ip" 33 >/dev/null 2>&1; then
  [ "$(ours "$ip")" = 8 ] \
    && ok "a second run lays all eight over a half-carved disk" \
    || bad "re-running left $(ours "$ip") of our partitions"
else
  bad "a half-carved disk could not be carved again -- there is no other recovery"
fi

# --- 8. uninstall gives the span back ---------------------------------------------------------------------
CASE="uninstall restores userdata"
un="$(board_img "AYANEO Pocket S2")"
span_before="$(( $(udfield "$un" 'Last sector') - $(udfield "$un" 'First sector') + 1 ))"
type_before="$(udfield "$un" 'Partition GUID code')"
foreign_before="$(foreign "$un")"
carve fresh "$un" 33 >/dev/null 2>&1
carve uninstall "$un" >/dev/null 2>&1
[ "$(ours "$un")" = 0 ] \
  && ok "none of our eight remain" \
  || bad "$(ours "$un") of our partitions survived an uninstall"
[ "$(( $(udfield "$un" 'Last sector') - $(udfield "$un" 'First sector') + 1 ))" -ge "$span_before" ] \
  && ok "userdata is at least as large as it was before the install" \
  || bad "userdata came back smaller than the factory partition"
[ "$(udfield "$un" 'Partition GUID code')" = "$type_before" ] \
  && ok "and still carries its vendor type GUID" \
  || bad "uninstall handed userdata back under the wrong type"
[ "$(foreign "$un")" = "$foreign_before" ] \
  && ok "uninstall moved no foreign partition" \
  || bad "uninstall touched something outside the span"
# Refused on a disk that was never ours -- there is nothing to remove, and growing userdata over
# unallocated space is not a thing to do to a stranger's disk by accident.
stock="$(board_img "AYANEO Pocket ACE")"
snap="$(rows "$stock")"
out="$(carve uninstall "$stock")"
{ [ "$(rows "$stock")" = "$snap" ] && printf '%s\n' "$out" | grep -q "nothing to uninstall"; } \
  && ok "uninstall on a stock disk -> refused, table unchanged" \
  || bad "uninstall acted on a disk that carries no install: $out"

# --- 9. the verb is required and is not guessed --------------------------------------------------------
CASE="the mode is an argument, never inferred"
inv="$(board_img "AYANEO Pocket S2")"
snap="$(rows "$inv")"
for verb in "" install wipe FRESH; do
  carve $verb "$inv" 33 >/dev/null 2>&1
  [ "$(rows "$inv")" = "$snap" ] \
    && ok "verb '$verb' -> no write" \
    || bad "verb '$verb' was accepted and modified the table"
done

printf '\ntest-carve.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
