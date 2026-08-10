#!/usr/bin/env bash
# Offline tests for select-target.sh, driven off the REAL captured GPTs — Phase 3 of
# .claude/plans/internal-install.plan.md.
#
#   install/test-select-target.sh          # needs sgdisk + mtools + dosfstools
#
# WHAT MAKES THESE DIFFERENT from synthetic fixtures. docs/internal-storage.md holds four boards
# captured off hardware, and every partition table here is rebuilt from those rows -- real names,
# real sizes, real order, including the six names the Odin 2 has that no AYANEO board does and the
# third-party install on the Pocket FIT. A rule tightened for one board and silently broken for
# another is the failure this suite exists to catch, so it runs against EVERY captured disk rather
# than a representative one.
#
# The images are sparse: a 479 GiB fixture costs a GPT's worth of bytes, and sgdisk writes nothing
# else. Nothing here needs root and nothing is mounted -- select-target.sh reads FAT through mtools
# at a byte offset, which is the same path it takes on a device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECT="$ROOT/install/select-target.sh"
CAPTURES="$ROOT/docs/internal-storage.md"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$SELECT" "$CAPTURES"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

for t in sgdisk mkfs.vfat mcopy; do
  command -v "$t" >/dev/null 2>&1 || {
    CASE="prerequisites"
    skip "$t is not installed -- run this inside novadeck-build"
    printf '\ntest-select-target.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 0
  }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export NOVADECK_SELECT_FIXTURE=1

# --- rebuild a captured disk as a real GPT --------------------------------------------------------
# Rows come out of the markdown as board|disk|index|name|bytes. Partitions are laid in capture order
# at their captured sizes, so indices and neighbours match the hardware -- which matters because
# CEIL is "the sector before whatever follows userdata" and the Odin 2 puts userdata at 17.
rows_for() {  # <board> <disk> -> "index name bytes" lines
  awk -v want_b="$1" -v want_d="$2" '
    /^# Internal storage capture/ { b=$0; sub(/^# Internal storage capture — /,"",b) }
    /^## `\/dev\// { d=$0; gsub(/[#` ]/,"",d) }
    /^\| *[0-9]+ \| `/ {
      if (b != want_b || d != want_d) next
      gsub(/`/,""); split($0,f,"|")
      gsub(/ /,"",f[2]); gsub(/ /,"",f[3]); gsub(/ /,"",f[5])
      if (f[5] ~ /^[0-9]+$/) print f[2], f[3], f[5]
    }' "$CAPTURES"
}

build() {  # <img> <rows...> on stdin; echoes nothing, exits non-zero on failure
  local img="$1" idx name bytes sectors start=2048 total=0
  local -a specs=()
  while read -r idx name bytes; do
    [ -n "$idx" ] || continue
    sectors=$(( bytes / 512 )); [ "$sectors" -gt 0 ] || sectors=1
    specs+=("$idx:$name:$sectors")
    total=$(( total + sectors ))
  done
  truncate -s $(( (total + 65536) * 512 )) "$img" || return 1
  sgdisk -Z "$img" >/dev/null 2>&1
  local spec
  for spec in "${specs[@]}"; do
    idx="${spec%%:*}"; name="${spec#*:}"; sectors="${name##*:}"; name="${name%%:*}"
    sgdisk -n "$idx:$start:+$sectors" -c "$idx:$name" "$img" >/dev/null 2>&1 || return 1
    start=$(( start + sectors ))
    start=$(( (start + 2047) / 2048 * 2048 ))   # 1 MiB alignment, as on the captures
  done
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

BOARDS=("AYANEO Pocket S2" "AYANEO Pocket ACE" "AYN Odin 2" "KONKR Pocket FIT")

# --- 1. every captured data LUN is accepted -------------------------------------------------------
# The headline claim: all four boards install. A rule that refused one of them would be caught here
# rather than by an owner with a device we cannot debug remotely.
CASE="every captured data LUN is accepted"
for board in "${BOARDS[@]}"; do
  img="$T/$(printf '%s' "$board" | tr -c 'A-Za-z0-9' '_').img"
  if ! rows_for "$board" /dev/sda | build "$img"; then
    bad "$board: could not rebuild the captured GPT"; continue
  fi
  if out=$(bash "$SELECT" "$img" 2>&1); then
    ok "$board: accepted"
    # The victim is the partition the capture calls userdata, not merely something plausible.
    ud_idx="$(field "$out" UD_INDEX)"
    want_idx="$(rows_for "$board" /dev/sda | awk '$2=="userdata" {print $1}')"
    [ "$ud_idx" = "$want_idx" ] \
      && ok "$board: picked p$ud_idx, the captured userdata" \
      || bad "$board: picked p$ud_idx but the capture puts userdata at p$want_idx"
    # CEIL must stop before the next partition, or reach the last usable sector if userdata is last.
    ud_end="$(field "$out" UD_END)"; ceil="$(field "$out" CEIL)"
    next="$(sgdisk -p "$img" 2>/dev/null | awk -v e="$ud_end" '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ && $2 > e {print $2}' | sort -n | head -1)"
    if [ -n "$next" ]; then
      [ "$ceil" = "$(( next - 1 ))" ] \
        && ok "$board: ceiling stops one sector before p$(sgdisk -p "$img" | awk -v s="$next" '$2==s {print $1}')" \
        || bad "$board: ceiling $ceil does not stop before the next partition at $next"
    else
      [ "$ceil" -ge "$ud_end" ] \
        && ok "$board: userdata is last, ceiling reaches the trailing free space" \
        || bad "$board: ceiling $ceil is below userdata's end $ud_end"
    fi
    # The type GUID has to be carried out for the carve to restore it.
    [ -n "$(field "$out" UD_TYPE)" ] \
      && ok "$board: carries userdata's type GUID out" \
      || bad "$board: emitted no UD_TYPE -- the carve would recreate under a Linux type"
  else
    bad "$board: refused, but the capture shows an installable disk: $out"
  fi
done

# --- 2. the non-data LUNs are refused -------------------------------------------------------------
# Each board exposes 6-8 UFS LUNs. Only sda carries userdata; picking any other is the wrong-LUN
# case, and sdb/sdc/sde carry xbl and abl on some boards -- the partitions that end a device.
CASE="a LUN with no userdata is refused"
for board in "${BOARDS[@]}"; do
  for lun in /dev/sdb /dev/sde; do
    img="$T/$(printf '%s%s' "$board" "$lun" | tr -c 'A-Za-z0-9' '_').img"
    rows_for "$board" "$lun" | build "$img" || continue
    out=$(bash "$SELECT" "$img" 2>&1)
    printf '%s\n' "$out" | grep -q "not supported yet" \
      && ok "$board $lun: refused, no userdata" \
      || bad "$board $lun: was not refused for lacking userdata: $out"
  done
done

# --- 3. the victim rule has no fallback -----------------------------------------------------------
# The 2026-08-10 decision: exact name, 33 GiB, refuse otherwise. These are the two ways to fail it,
# and both must stop the run rather than select something else.
CASE="the victim rule has no fallback"
base="$T/S2.img"; rows_for "AYANEO Pocket S2" /dev/sda | build "$base"
ud="$(rows_for "AYANEO Pocket S2" /dev/sda | awk '$2=="userdata" {print $1}')"

cp --sparse=always "$base" "$T/renamed.img"
sgdisk -c "$ud:mydata" "$T/renamed.img" >/dev/null 2>&1
out=$(bash "$SELECT" "$T/renamed.img" 2>&1)
printf '%s\n' "$out" | grep -q "not supported yet" \
  && ok "userdata renamed to mydata -> refused, not substituted" \
  || bad "a disk with no userdata was not refused: $out"

# Shrink it under the floor. super is the largest remaining partition on this board, so this is
# also the case that proves no size heuristic picks a second candidate.
cp --sparse=always "$base" "$T/small.img"
s="$(sgdisk -i "$ud" "$T/small.img" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
sgdisk -d "$ud" "$T/small.img" >/dev/null 2>&1
sgdisk -n "$ud:$s:+20G" -c "$ud:userdata" "$T/small.img" >/dev/null 2>&1
out=$(bash "$SELECT" "$T/small.img" 2>&1)
{ printf '%s\n' "$out" | grep -q "20 GiB" && printf '%s\n' "$out" | grep -q "33 is the minimum"; } \
  && ok "a 20 GiB userdata -> refused, naming both numbers" \
  || bad "a userdata below the 33 GiB floor was not refused clearly: $out"

# One sector under, to prove the boundary is where it is claimed rather than roughly there.
cp --sparse=always "$base" "$T/edge.img"
sgdisk -d "$ud" "$T/edge.img" >/dev/null 2>&1
sgdisk -n "$ud:$s:+$(( 33 * 1024 * 1024 * 1024 / 512 - 1 ))" -c "$ud:userdata" "$T/edge.img" >/dev/null 2>&1
out=$(bash "$SELECT" "$T/edge.img" 2>&1)
printf '%s\n' "$out" | grep -q "is the minimum" \
  && ok "one sector under 33 GiB -> refused" \
  || bad "a userdata one sector below the floor was accepted: $out"

# --- 4. rule 3b, on the board that actually carries another distribution ---------------------------
# The Pocket FIT has an internal ROCKNIX install. ABL's test is on CONTENT, so the fixture needs a
# real FAT holding the file rather than a partition of the right type.
CASE="a foreign bootable ESP is refused"
fit="$T/fit.img"; rows_for "KONKR Pocket FIT" /dev/sda | build "$fit"
esp_idx="$(sgdisk -p "$fit" | awk '/ROCKNIX/ {print $1}' | head -1)"
if [ -n "$esp_idx" ]; then
  esp_s="$(sgdisk -i "$esp_idx" "$fit" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
  esp_e="$(sgdisk -i "$esp_idx" "$fit" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
  sgdisk -t "$esp_idx:ef00" "$fit" >/dev/null 2>&1
  fat="$T/esp.fat"
  dd if=/dev/zero of="$fat" bs=512 count=$(( esp_e - esp_s + 1 )) status=none
  mkfs.vfat "$fat" >/dev/null 2>&1
  : >"$T/KERNEL"; mcopy -i "$fat" "$T/KERNEL" ::/KERNEL >/dev/null 2>&1
  dd if="$fat" of="$fit" bs=512 seek="$esp_s" conv=notrunc status=none
  out=$(bash "$SELECT" "$fit" 2>&1)
  printf '%s\n' "$out" | grep -q "bootable ESP that is not ours" \
    && ok "the FIT's ROCKNIX ESP carrying /KERNEL -> refused" \
    || bad "a second bootable ESP did not refuse the install: $out"

  # bootaa64.efi independently: ABL accepts either, so a check that knew one would miss half.
  mdel -i "$fat" ::/KERNEL >/dev/null 2>&1
  mmd -i "$fat" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
  : >"$T/bootaa64.efi"; mcopy -i "$fat" "$T/bootaa64.efi" ::/EFI/BOOT/bootaa64.efi >/dev/null 2>&1
  dd if="$fat" of="$fit" bs=512 seek="$esp_s" conv=notrunc status=none
  out=$(bash "$SELECT" "$fit" 2>&1)
  printf '%s\n' "$out" | grep -q "bootable ESP that is not ours" \
    && ok "the same ESP carrying /EFI/BOOT/bootaa64.efi -> refused" \
    || bad "bootaa64.efi alone did not trigger rule 3b: $out"

  # An ESP holding NEITHER file is invisible to ABL and must not block an install.
  mdel -i "$fat" ::/EFI/BOOT/bootaa64.efi >/dev/null 2>&1
  dd if="$fat" of="$fit" bs=512 seek="$esp_s" conv=notrunc status=none
  bash "$SELECT" "$fit" >/dev/null 2>&1 \
    && ok "an empty ESP of the right type -> accepted" \
    || bad "an ESP holding neither file blocked the install"

  # Ours is exempt, or a reinstall refuses itself as foreign.
  sgdisk -c "$esp_idx:NOVADECK-ESP" "$fit" >/dev/null 2>&1
  mmd -i "$fat" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
  mcopy -i "$fat" "$T/bootaa64.efi" ::/EFI/BOOT/bootaa64.efi >/dev/null 2>&1
  dd if="$fat" of="$fit" bs=512 seek="$esp_s" conv=notrunc status=none
  bash "$SELECT" "$fit" >/dev/null 2>&1 \
    && ok "our own NOVADECK-ESP carrying bootaa64.efi -> accepted" \
    || bad "a reinstall refused its own ESP as foreign"
else
  skip "the FIT capture has no ROCKNIX partition to retype"
fi

# --- 5. reinstall ordering ------------------------------------------------------------------------
# The case that destroys a game library if rule ordering regresses: on a NovaDeck disk the largest
# partition is our own /home, so identity must be settled before size is consulted.
CASE="an already-NovaDeck disk is a reinstall"
cp --sparse=always "$base" "$T/re.img"
sgdisk -c "1:novadeck-root-A" "$T/re.img" >/dev/null 2>&1
out=$(bash "$SELECT" "$T/re.img" 2>&1)
[ "$(field "$out" MODE)" = reinstall ] \
  && ok "MODE=reinstall when novadeck-root-A is present" \
  || bad "an already-NovaDeck disk reported MODE=$(field "$out" MODE)"

printf '\ntest-select-target.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
