#!/usr/bin/env bash
# Offline tests for select-target.sh, driven off the REAL captured GPTs — Phase 3 of
# .claude/plans/internal-install.plan.md.
#
#   install/test-select-target.sh          # needs sgdisk + mtools + dosfstools
#
# WHAT MAKES THESE DIFFERENT from synthetic fixtures. docs/internal-storage.md holds five boards
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
# Shared with install/test-carve.sh, which needs the same five boards as REAL GPTs. A second copy of
# that awk would be the obvious place for the two suites to drift apart.
. "$ROOT/install/lib-gptfixture.sh"
# lib-gpt.sh too: the residue case below asserts against the same live-index reader the script
# under test uses, and against the Android type GUID it names.
. "$ROOT/images/lib-gpt.sh"

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

BOARDS=("AYANEO Pocket S2" "AYANEO Pocket ACE" "AYN Odin 2" "KONKR Pocket FIT" "MANGMI Pocket Max")

# --- 1. every captured data LUN is accepted -------------------------------------------------------
# The headline claim: all five boards install. A rule that refused one of them would be caught here
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
    # The type GUID, against the CAPTURE rather than merely against non-empty. This is the one
    # output the carve copies verbatim, and the failure it prevents -- Android not recognising its
    # own data partition -- is invisible until the user boots the other OS.
    want_type="$(rows_for "$board" /dev/sda | awk '$2=="userdata" {print $4}')"
    got_type="$(field "$out" UD_TYPE)"
    { [ -n "$want_type" ] && [ "${got_type^^}" = "${want_type^^}" ]; } \
      && ok "$board: UD_TYPE is the captured $want_type" \
      || bad "$board: UD_TYPE is '$got_type', the capture says '$want_type'"
    # The extent, read back off the GPT rather than trusted from the emitter's own arithmetic: it is
    # the input the carve turns into sector arguments, so an off-by-one here is written to a disk.
    gpt_i="$(sgdisk -i "$ud_idx" "$img")"
    gpt_start="$(printf '%s\n' "$gpt_i" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
    gpt_end="$(printf '%s\n' "$gpt_i" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
    { [ "$(field "$out" UD_START)" = "$gpt_start" ] && [ "$(field "$out" UD_END)" = "$gpt_end" ]; } \
      && ok "$board: extent $gpt_start..$gpt_end matches the GPT" \
      || bad "$board: emitted $(field "$out" UD_START)..$(field "$out" UD_END), the GPT says $gpt_start..$gpt_end"
    # A captured board is a FRESH install. The reinstall path skips nothing today, but it is the
    # branch that decides whether /home survives, so it must never be reached by accident.
    [ "$(field "$out" MODE)" = fresh ] \
      && ok "$board: MODE=fresh on a stock Android disk" \
      || bad "$board: a stock Android disk reported MODE=$(field "$out" MODE)"
    # SECTOR is what turns the user's GiB choice into sectors. Asserted against the image, which is
    # 512 -- these boards are really 4096, but sgdisk assumes 512 for a FILE and only asks the
    # kernel on a block device, so the fixture cannot reach the 4096 path. What is testable is that
    # the emitted value is the one sgdisk read, not a constant.
    [ "$(field "$out" SECTOR)" = "$(sgdisk -p "$img" | sed -n 's/^Sector size (logical[^)]*): \([0-9]*\).*/\1/p')" ] \
      && ok "$board: SECTOR is the size sgdisk read off the disk" \
      || bad "$board: SECTOR=$(field "$out" SECTOR) is not what sgdisk reports"
  else
    bad "$board: refused, but the capture shows an installable disk: $out"
  fi
done

# --- 2. the non-data LUNs are refused -------------------------------------------------------------
# Each board exposes 6-8 UFS LUNs. Only sda carries userdata; picking any other is the wrong-LUN
# case, and sdb/sdc/sde carry xbl and abl on some boards -- the partitions that end a device.
# EVERY captured LUN, not a sample: they are cheap (20-4096 MiB of sparse file against sda's 479
# GiB) and the one that gets skipped is the one that turns out to be shaped like a data LUN.
CASE="a LUN with no userdata is refused"
for board in "${BOARDS[@]}"; do
  for lun in $(luns_for "$board"); do
    img="$T/$(printf '%s%s' "$board" "$lun" | tr -c 'A-Za-z0-9' '_').img"
    rows_for "$board" "$lun" | build "$img" || continue
    if out=$(bash "$SELECT" "$img" 2>&1); then
      bad "$board $lun: ACCEPTED a LUN that carries no userdata: $out"
    else
      # Either refusal is correct and which one fires is a property of the LUN, not of the rule:
      # sdd on some boards is one `last_parti` row and never reaches the victim rule at all.
      printf '%s\n' "$out" | grep -Eq "not supported yet|no partitions" \
        && ok "$board $lun: refused, no userdata" \
        || bad "$board $lun: refused for the wrong reason: $out"
    fi
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
#
# THE FILLER IS LOAD-BEARING. The floor is a question about the ROOM AVAILABLE -- ud_start..CEIL --
# and not about userdata's own extent; on a stock device those are the same number because userdata
# runs to the end of the disk. Shrinking userdata inside a full-size capture and stopping there
# would leave hundreds of GiB of free space behind it, which is genuinely enough room, and refusing
# would then be the bug. So each fixture below puts a partition immediately after userdata, which is
# what a board where userdata is followed by something actually looks like.
fill_after() {  # <img> <ud-index> -- occupy everything after userdata so CEIL == its end
  local img="$1" idx="$2" e
  e="$(sgdisk -i "$idx" "$img" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
  # No -c: sgdisk does not resolve "0" to the just-created partition for a name, and the failure
  # aborts the whole invocation, silently leaving the free space it was meant to occupy.
  # -a 1: without it sgdisk aligns the start to 2048 sectors, so the filler begins up to ~1 MiB past
  # userdata's end and CEIL -- which is filler_start - 1 -- reaches into that gap. On the
  # one-sector-under-the-floor fixture that gap is the difference between 32 and 33 GiB.
  sgdisk -a 1 -n "0:$(( e + 1 )):0" "$img" >/dev/null 2>&1
  sgdisk -p "$img" | awk -v e="$e" '"'"'$1 ~ /^[0-9]+$/ && $2 == e+1'"'"' | grep -q . \
    || bad "fixture setup: nothing was created after userdata, so the room is still free"
}

cp --sparse=always "$base" "$T/small.img"
s="$(sgdisk -i "$ud" "$T/small.img" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
sgdisk -d "$ud" "$T/small.img" >/dev/null 2>&1
sgdisk -n "$ud:$s:+20G" -c "$ud:userdata" "$T/small.img" >/dev/null 2>&1
fill_after "$T/small.img" "$ud"
out=$(bash "$SELECT" "$T/small.img" 2>&1)
{ printf '%s\n' "$out" | grep -q "20 GiB" && printf '%s\n' "$out" | grep -q "33 is the minimum"; } \
  && ok "a 20 GiB userdata with nothing free after it -> refused, naming both numbers" \
  || bad "a userdata below the 33 GiB floor was not refused clearly: $out"

# One sector under, to prove the boundary is where it is claimed rather than roughly there.
cp --sparse=always "$base" "$T/edge.img"
sgdisk -d "$ud" "$T/edge.img" >/dev/null 2>&1
sgdisk -n "$ud:$s:+$(( 33 * 1024 * 1024 * 1024 / 512 - 1 ))" -c "$ud:userdata" "$T/edge.img" >/dev/null 2>&1
fill_after "$T/edge.img" "$ud"
out=$(bash "$SELECT" "$T/edge.img" 2>&1)
printf '%s\n' "$out" | grep -q "is the minimum" \
  && ok "one sector under 33 GiB -> refused" \
  || bad "a userdata one sector below the floor was accepted: $out"

CASE="the floor measures the ROOM, not userdata's own extent"
# THE RETRY-AFTER-INTERRUPTION CASE, and it is the reason the distinction matters. An install that
# dies between the carve and genpart leaves userdata already shrunk with all the room still free
# behind it -- the exact state an AYANEO Pocket ACE was in on 2026-08-21 when genpart refused
# mid-carve. Measuring userdata alone reported "userdata is 8 GiB, and 33 is the minimum" while 88
# GiB sat unallocated immediately after it, which made the re-run impossible. Plan §3 rule 10 keeps
# no backups precisely because re-running IS the recovery story, so this refusal had no way out.
cp --sparse=always "$base" "$T/shrunk.img"
sgdisk -d "$ud" "$T/shrunk.img" >/dev/null 2>&1
sgdisk -n "$ud:$s:+8G" -c "$ud:userdata" "$T/shrunk.img" >/dev/null 2>&1
out=$(bash "$SELECT" "$T/shrunk.img" 2>&1)
printf '%s\n' "$out" | grep -q '^TARGET=' \
  && ok "an 8 GiB userdata with the room still free behind it -> accepted, so an interrupted install can be re-run" \
  || bad "a shrunk userdata with free space after it was refused: $out"
ud_end_s="$(printf '%s\n' "$out" | sed -n 's/^UD_END=//p')"
ceil_s="$(printf '%s\n' "$out" | sed -n 's/^CEIL=//p')"
[ -n "$ceil_s" ] && [ "$ceil_s" -gt "$ud_end_s" ] \
  && ok "and CEIL reaches past userdata into that free space, which is what the carve will use" \
  || bad "CEIL ($ceil_s) does not extend past userdata ($ud_end_s)"

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
  # --- rule 3b must not be SKIPPABLE by a missing tool ---------------------------------------
  # THE DEFECT THIS CASE EXISTS FOR, found on the Pocket FIT 2026-08-21 and invisible to every
  # case above it. mtools is not in the shipped image, `mdir` reports a missing FILE and a missing
  # BINARY identically (non-zero), so esp_is_bootable answered "not bootable" for every ESP and the
  # FIT's sda -- with ROCKNIX on a genuine EF00 ESP -- came back TARGET=/dev/sda MODE=fresh. This
  # suite stayed green throughout, because the build container has mtools on its PATH: a suite
  # cannot see the image's tool inventory, so the property has to be asserted as its own case.
  #
  # PATH is rebuilt from the commands the script actually calls, minus mdir, rather than shimmed --
  # a shim would prove a stub was consulted, and what needs proving is that ABSENCE refuses.
  CASE="a missing mdir refuses rather than skipping rule 3b"
  mmd -i "$fat" ::/EFI ::/EFI/BOOT >/dev/null 2>&1
  mcopy -i "$fat" "$T/bootaa64.efi" ::/EFI/BOOT/bootaa64.efi >/dev/null 2>&1
  sgdisk -c "$esp_idx:ROCKNIX" "$fit" >/dev/null 2>&1
  dd if="$fat" of="$fit" bs=512 seek="$esp_s" conv=notrunc status=none
  mkdir -p "$T/nomdir"
  for c in awk blkid cat findmnt grep head lsblk sed sgdisk sort; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$T/nomdir/$c"
  done
  # The interpreter goes in by ABSOLUTE path: a `PATH=… bash …` prefix resolves `bash` itself
  # through the stripped PATH, so the case dies rc=127 before reaching the script and asserts
  # nothing. Measured -- that is exactly how this case failed when it was first written.
  out=$(PATH="$T/nomdir" "$(command -v bash)" "$SELECT" "$fit" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi "mdir not found" \
    && ok "mdir absent -> refused, naming the tool, not silently accepted" \
    || bad "with mdir absent the script did not refuse (rc=$rc): $out"

  # And the same disk with mdir back on PATH still refuses -- so the case above proves the tool
  # gate, not a fixture that had stopped being refusable.
  out=$(bash "$SELECT" "$fit" 2>&1)
  printf '%s\n' "$out" | grep -q "bootable ESP that is not ours" \
    && ok "the same fixture with mdir present -> still refused by 3b itself" \
    || bad "the no-mdir fixture is not refusable by 3b, so that case proved nothing: $out"
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

# --- 6. a damaged or absent GPT ---------------------------------------------------------------------
# `sgdisk -v` REGENERATES a missing header in memory and then reports "No problems found" about what
# it invented -- measured 2026-08-10, and all three disks below were ACCEPTED before rule 3 was
# changed to read the whole output. Each would have been carved on the strength of a table gdisk made
# up, which is the one situation where "we cannot tell damaged from not-the-disk-we-think" stops
# being a slogan. The rule must also stay quiet about ALIGNMENT: stock Android tables are not
# 2048-aligned, and a first attempt that refused on any Caution refused every captured board.
CASE="a damaged or absent GPT is refused"
sz="$(stat -c %s "$base")"

cp --sparse=always "$base" "$T/nobackup.img"
dd if=/dev/zero of="$T/nobackup.img" bs=512 seek=$(( sz / 512 - 1 )) count=1 conv=notrunc status=none
out=$(bash "$SELECT" "$T/nobackup.img" 2>&1)
printf '%s\n' "$out" | grep -q "damaged or absent" \
  && ok "a zeroed BACKUP GPT header -> refused" \
  || bad "a disk with no backup GPT was not refused as damaged: $out"

cp --sparse=always "$base" "$T/nomain.img"
dd if=/dev/zero of="$T/nomain.img" bs=512 seek=1 count=1 conv=notrunc status=none
out=$(bash "$SELECT" "$T/nomain.img" 2>&1)
printf '%s\n' "$out" | grep -q "damaged or absent" \
  && ok "a zeroed MAIN GPT header -> refused" \
  || bad "a disk with no main GPT was not refused as damaged: $out"

truncate -s "$sz" "$T/blank.img"
out=$(bash "$SELECT" "$T/blank.img" 2>&1)
printf '%s\n' "$out" | grep -q "damaged or absent" \
  && ok "a disk with no GPT at all -> refused" \
  || bad "a blank disk was not refused as damaged: $out"

# --- 7. rule 1 -- the disk the running system is on -------------------------------------------------
# select-target.sh finds it through findmnt+lsblk, so shims are the only way to reach the rule
# offline. On the installer this is the SD card, and writing the medium you booted from takes the
# recovery path with it.
CASE="the running disk is never a target"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho /dev/nvme0n1p2\n' >"$T/bin/findmnt"
# lsblk is asked for the PARENT of that source, and the script prints "/dev/$parent". The fixtures
# live in $T, so the shim answers with a path RELATIVE to /dev -- "/dev/../tmp/…" is both a real path
# to the fixture and, more to the point, the same STRING the scan list below holds. That is what lets
# a temp file be the running disk without writing anything into /dev.
printf '#!/bin/sh\necho ..%s\n' "$T/running.img" >"$T/bin/lsblk"
chmod +x "$T/bin/findmnt" "$T/bin/lsblk"
cp --sparse=always "$base" "$T/running.img"
RUN_PATH="/dev/..$T/running.img"
out=$(PATH="$T/bin:$PATH" bash "$SELECT" "$RUN_PATH" 2>&1)
printf '%s\n' "$out" | grep -q "running system is on" \
  && ok "an explicit target that is the running disk -> refused" \
  || bad "the running disk was accepted as an explicit target: $out"

CASE="a running disk that cannot be resolved refuses EVERYTHING"
# FAIL CLOSED, and this case is the whole reason it does. The check that READS like the boot medium's
# protection is not: an SD card reports removable=0 on every board we have captured, so rule 1 is the
# one keeping the installer off the card it booted from -- and until 2026-08-25 an unresolvable root
# printed nothing, which excluded nothing, which quietly removed the rule instead of stopping.
#
# What saved it in practice was the victim rule wanting a partition named `userdata`, which no boot
# medium of ours carries. That is a second rule's side effect, not a design, and "I cannot tell which
# disk I am running from" is a fine reason to refuse an install outright.
#
# RUN WITH THE FIXTURE FLAG UNSET, which is the only way to reach the refusal: the flag relaxes it,
# because the build container's root is an overlay with no block parent and every case here would
# otherwise refuse. What the disk list holds does not matter -- the refusal happens before the first
# disk is examined, which is the property.
printf '#!/bin/sh\nexit 1\n' >"$T/bin/findmnt"       # findmnt answers nothing at all
chmod +x "$T/bin/findmnt"
out=$(PATH="$T/bin:$PATH" NOVADECK_SELECT_FIXTURE= NOVADECK_SELECT_DISKS="$T/running.img" \
      bash "$SELECT" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "the scan refuses (exit $rc) rather than proceeding with one fewer rule" \
               || bad "an unresolvable running disk still selected something: $out"
printf '%s\n' "$out" | grep -q "cannot determine which disk" \
  && ok "and says which question it could not answer" \
  || bad "the refusal does not name the cause: $out"
[ -z "$(field "$out" TARGET)" ] \
  && ok "with no TARGET emitted for a caller to act on" \
  || bad "it emitted a target anyway: $out"
# The same must hold for an explicit target, which is the path install/hw-install.sh drives.
out=$(PATH="$T/bin:$PATH" NOVADECK_SELECT_FIXTURE= bash "$SELECT" "$T/running.img" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "an explicit target is refused too -- naming a disk does not answer the question" \
               || bad "an explicit target bypassed the refusal: $out"
# lsblk failing where findmnt succeeded is the other half: a source with no resolvable parent.
printf '#!/bin/sh\necho /dev/nvme0n1p2\n' >"$T/bin/findmnt"
printf '#!/bin/sh\nexit 1\n' >"$T/bin/lsblk"
chmod +x "$T/bin/findmnt" "$T/bin/lsblk"
out=$(PATH="$T/bin:$PATH" NOVADECK_SELECT_FIXTURE= NOVADECK_SELECT_DISKS="$T/running.img" \
      bash "$SELECT" 2>&1); rc=$?
[ "$rc" != 0 ] \
  && ok "a source whose parent cannot be resolved refuses as well" \
  || bad "an unresolvable parent still selected: $out"
# And the flag relaxes exactly this, which is what keeps the other 90 cases runnable in a container.
out=$(PATH="$T/bin:$PATH" NOVADECK_SELECT_DISKS="$T/running.img" bash "$SELECT" 2>&1)
[ -n "$(field "$out" TARGET)" ] \
  && ok "and under NOVADECK_SELECT_FIXTURE it is relaxed, as the three sysfs checks are" \
  || bad "the fixture flag no longer relaxes the running-disk rule: $out"
# RESTORE case 7's shims: the scan cases below depend on them to make running.img the running disk.
printf '#!/bin/sh\necho /dev/nvme0n1p2\n' >"$T/bin/findmnt"
printf '#!/bin/sh\necho ..%s\n' "$T/running.img" >"$T/bin/lsblk"
chmod +x "$T/bin/findmnt" "$T/bin/lsblk"

# --- 8. the scan -- rule 9, which the explicit-target path cannot reach -----------------------------
# Zero says why, one prints it, two or more refuses rather than picks. The last is the rule with
# teeth: on a disk it did not choose, every geometric guarantee in this script is about the wrong
# device. NOVADECK_SELECT_DISKS exists for these four cases and for nothing else.
CASE="the scan picks exactly one disk or none"
cp --sparse=always "$base" "$T/one.img"
cp --sparse=always "$base" "$T/two.img"
rows_for "AYANEO Pocket S2" /dev/sdb | build "$T/nolun.img"

out=$(NOVADECK_SELECT_DISKS="$T/one.img $T/nolun.img" bash "$SELECT" 2>&1)
[ "$(field "$out" TARGET)" = "$T/one.img" ] \
  && ok "one eligible disk among ineligible ones -> selected" \
  || bad "the scan did not select the only eligible disk: $out"

out=$(NOVADECK_SELECT_DISKS="$T/one.img $T/two.img" bash "$SELECT" 2>&1)
{ printf '%s\n' "$out" | grep -q "more than one disk qualifies" && [ -z "$(field "$out" TARGET)" ]; } \
  && ok "two eligible disks -> refused, and nothing is emitted to act on" \
  || bad "the scan chose between two eligible disks: $out"

out=$(NOVADECK_SELECT_DISKS="$T/nolun.img" bash "$SELECT" 2>&1)
{ printf '%s\n' "$out" | grep -q "no disk qualifies" && printf '%s\n' "$out" | grep -q "not supported yet"; } \
  && ok "no eligible disk -> refused, naming what was rejected and why" \
  || bad "an empty scan did not say what it rejected: $out"

# The running disk is excluded from the SCAN too, not only from an explicit target -- and this is the
# arm that runs unattended, so it is the one where a miss is not caught by a human reading the screen.
out=$(PATH="$T/bin:$PATH" NOVADECK_SELECT_DISKS="$RUN_PATH $T/one.img" bash "$SELECT" 2>&1)
[ "$(field "$out" TARGET)" = "$T/one.img" ] \
  && ok "the scan skips the running disk and takes the other" \
  || bad "the scan did not exclude the running disk: $out"

# --- 9. an eMMC-shaped target, which no board we own can provide -----------------------------------
# EVERY device in the fleet is UFS -- the internal disk is always sdX and the only mmcblk is the boot
# SD, so "an mmcblk device SELECTED as a target" has never happened on hardware and, with no eMMC
# board to test on, cannot. Checked 2026-08-21 across the five captures plus a Thor Lite (UFS 3.1).
#
# BE CLEAR ABOUT WHAT THIS REPLACES AND WHAT IT DOES NOT. The fixture seam skips the three sysfs
# checks, so this is not the hardware test: it cannot show that an eMMC disk reports removable=0, and
# it cannot show rules 1/2 discriminating when the boot medium and the target are BOTH mmcblk. What
# it does cover is the half that is name-shaped, which is the half that would break silently:
# enumeration must reach mmcblk at all, and no rule may parse the disk name to reach a partition
# (the `p` infix -- mmcblk0p11 against sda11 -- is where that breaks).
CASE="an eMMC-shaped disk is enumerated and selectable"
grep -q '/dev/mmcblk?' "$SELECT" \
  && ok "the default scan glob names mmcblk, so an eMMC disk is a candidate at all" \
  || bad "the scan glob does not enumerate mmcblk devices -- an eMMC board would be invisible"

emmc="$T/mmcblk0"; cp --sparse=always "$base" "$emmc"
out=$(NOVADECK_SELECT_DISKS="$emmc" bash "$SELECT" 2>&1)
{ [ "$(field "$out" TARGET)" = "$emmc" ] && [ -n "$(field "$out" UD_INDEX)" ]; } \
  && ok "a disk whose name carries no partition-suffix convention is selected, p$(field "$out" UD_INDEX) emitted" \
  || bad "an mmcblk-named disk was not selected: $out"

# The emitted block must be identical to the same image under an sdX name: anything that differs is
# a rule reading the device NAME, which is exactly the dependency that cannot be tested on hardware.
sdx="$T/sda-same"; cp --sparse=always "$base" "$sdx"
out_sdx=$(NOVADECK_SELECT_DISKS="$sdx" bash "$SELECT" 2>&1)
[ "$(printf '%s\n' "$out"     | grep -v '^TARGET=')" \
= "$(printf '%s\n' "$out_sdx" | grep -v '^TARGET=')" ] \
  && ok "the same image under an mmcblk name and an sdX name emits identical geometry" \
  || bad "geometry differs by device name -- a rule is parsing the name"

# --- 11. the FIT with its proportions REVERSED -- the case rule 3b was written for -------------------
# The plan states it plainly: as captured, the FIT is refused partly BY ACCIDENT OF PROPORTIONS --
# STORAGE (380 GiB) is larger than userdata (64 GiB). An install that had left userdata at 300 GiB
# and taken 100 would have passed every rule that existed before 3b and SUCCEEDED, producing one disk
# carrying Android, another distribution and NovaDeck, three of them believing they own the boot
# chain. Section 4 above tests 3b on the proportions the capture happens to have; this tests it on
# the ones that made the rule necessary.
CASE="a foreign install is refused on content, not on proportions"
rev="$T/fit-reversed.img"; rows_for "KONKR Pocket FIT" /dev/sda | build "$rev"
stor="$(sgdisk -p "$rev" | awk '/STORAGE/ {print $1}' | head -1)"
rock="$(sgdisk -p "$rev" | awk '/ROCKNIX/ {print $1}' | head -1)"
if [ -n "$stor" ] && [ -n "$rock" ]; then
  # Shrink STORAGE at its own start, so userdata becomes the largest partition on the disk and every
  # size-shaped intuition about this layout is inverted. Nothing else moves.
  stor_s="$(sgdisk -i "$stor" "$rev" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
  sgdisk -d "$stor" "$rev" >/dev/null 2>&1
  sgdisk -n "$stor:$stor_s:+2G" -c "$stor:STORAGE" "$rev" >/dev/null 2>&1
  ud_sz="$(sgdisk -p "$rev" | awk '$NF=="userdata" {print $3-$2}')"
  st_sz="$(sgdisk -p "$rev" | awk '$NF=="STORAGE" {print $3-$2}')"
  [ "$ud_sz" -gt "$st_sz" ] \
    && ok "the fixture now has userdata larger than STORAGE, as intended" \
    || bad "the reversed fixture is not reversed: userdata $ud_sz, STORAGE $st_sz"

  rock_s="$(sgdisk -i "$rock" "$rev" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')"
  rock_e="$(sgdisk -i "$rock" "$rev" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')"
  sgdisk -t "$rock:ef00" "$rev" >/dev/null 2>&1
  rfat="$T/rev.fat"
  dd if=/dev/zero of="$rfat" bs=512 count=$(( rock_e - rock_s + 1 )) status=none
  mkfs.vfat "$rfat" >/dev/null 2>&1
  : >"$T/KERNEL"; mcopy -i "$rfat" "$T/KERNEL" ::/KERNEL >/dev/null 2>&1
  dd if="$rfat" of="$rev" bs=512 seek="$rock_s" conv=notrunc status=none

  out=$(bash "$SELECT" "$rev" 2>&1)
  printf '%s\n' "$out" | grep -q "bootable ESP that is not ours" \
    && ok "userdata largest, foreign bootable ESP present -> still refused, and refused BY 3b" \
    || bad "the layout the plan says would have succeeded was not refused by 3b: $out"
else
  skip "the FIT capture has no ROCKNIX/STORAGE pair to reverse"
fi

# --- a disk a foreign uninstaller left behind (issue #56) -----------------------------------------
# The board is the same AYANEO Pocket ACE, captured after an uninstall from ROCKNIX LinuxLoader:
# eight GPT entries whose type GUID was zeroed while their LBAs were kept, with userdata regrown
# across them. FIXTURE_LAYOUT=captured because the OFFSETS are the finding -- a packed rebuild
# cannot express residue sitting inside a live partition, which is what this disk is.
#
# It is not a hypothetical shape. "Try one distro, then try another" is ordinary, and before this
# the refusal landed after carve.sh had already shrunk userdata, leaving the disk mid-carve and
# permanently uninstallable.
CASE="a disk a foreign uninstaller left behind is still installable"
RESIDUE_BOARD='AYANEO Pocket ACE (after a ROCKNIX uninstall)'
res="$T/ace-post-uninstall.img"
if rows_for "$RESIDUE_BOARD" /dev/sda | FIXTURE_LAYOUT=captured build "$res"; then
  # The fixture is the disk it claims to be: sgdisk renders 19 rows, the GPT uses 11.
  rendered="$(sgdisk -p "$res" 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/' | wc -l)"
  live="$(gpt_live_indices "$res" | wc -l)"
  { [ "$rendered" = 19 ] && [ "$live" = 11 ]; } \
    && ok "the fixture reproduces the capture: sgdisk -p renders $rendered rows, the GPT uses $live" \
    || bad "the fixture is not the captured state: $rendered rendered, $live live (want 19 and 11)"

  # The residue overlaps userdata, which is what makes a geometric rule impossible and the type
  # GUID the only discriminator. Asserted rather than assumed: a fixture that quietly lost the
  # overlap would still pass everything below and prove nothing.
  ud_e="$(sgdisk -p "$res" | awk '$NF=="userdata" {print $3}')"
  p12_s="$(sgdisk -p "$res" | awk '$1==12 {print $2}')"
  { [ -n "$p12_s" ] && [ "$p12_s" -lt "$ud_e" ]; } \
    && ok "the residue sits INSIDE userdata (p12 at $p12_s, userdata ends $ud_e)" \
    || bad "the fixture lost the overlap: p12 at '$p12_s', userdata ends '$ud_e'"

  if out=$(bash "$SELECT" "$res" 2>&1); then
    ok "accepted, where every scan used to count the residue as something in the way"
    [ "$(field "$out" MODE)" = fresh ] \
      && ok "MODE=fresh -- zeroed entries are not a novadeck install" \
      || bad "MODE is '$(field "$out" MODE)', want fresh"
    [ "$(field "$out" UD_INDEX)" = 11 ] \
      && ok "picked p11, the regrown userdata" \
      || bad "picked p$(field "$out" UD_INDEX), the capture puts userdata at p11"
    # CEIL must reach the end of the disk. Reading the residue put it at 6892072-1 on hardware --
    # a window of zero sectors, which is the refusal in the issue.
    lastu="$(sgdisk -p "$res" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p' | head -1)"
    [ "$(field "$out" CEIL)" = "$lastu" ] \
      && ok "CEIL reaches the last usable sector $lastu, not the first residue row" \
      || bad "CEIL is $(field "$out" CEIL), want the last usable sector $lastu"
    # The other half of #56: ROCKNIX stamps userdata Linux-filesystem on its way out, and a carve
    # that preserved what it found would hand Android a partition it does not recognise.
    [ "$(field "$out" UD_TYPE)" = "$NOVADECK_ANDROID_USERDATA_GUID" ] \
      && ok "UD_TYPE is restored to the Android vendor type, not the Linux type left on the disk" \
      || bad "UD_TYPE is $(field "$out" UD_TYPE), want $NOVADECK_ANDROID_USERDATA_GUID"
  else
    bad "refused: $out"
  fi

  # The restore is EVIDENCE-DRIVEN, not a blanket rewrite. Drop the residue and userdata's own
  # type must be left exactly as found -- a board whose stock type genuinely differs is not ours
  # to correct.
  clean="$T/ace-residue-dropped.img"; cp "$res" "$clean"
  gpt_drop_dead_entries "$clean" >/dev/null
  out=$(bash "$SELECT" "$clean" 2>&1) || out=""
  got="$(field "$out" UD_TYPE)"
  [ "${got^^}" = "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ] \
    && ok "with the residue gone there is no evidence to act on, so the type on the disk is kept" \
    || bad "UD_TYPE is '$got' on a residue-free disk -- the restore must not fire without evidence"
else
  bad "could not rebuild the post-uninstall capture"
fi

printf '\ntest-select-target.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
