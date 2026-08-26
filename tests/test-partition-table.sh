#!/usr/bin/env bash
# Every FAT partition in partition-table.txt must be a filesystem the FIRMWARE can mount, on BOTH
# media we ship to — 512-byte SD cards and 4096-byte internal UFS.
#
#   tests/test-partition-table.sh          # needs dosfstools
#
# WHY THIS SUITE EXISTS. A FAT32 needs at least 65525 data clusters to be one, and cluster count
# scales with SECTORS, not bytes. The table sizes partitions in bytes, so one row is two different
# filesystems on the two media — and the failing half is invisible to everything else we run:
# make-sdcard.sh formats inside an IMAGE FILE, where mkfs.vfat sees 512-byte sectors whatever the
# eventual target is, and so does every other fixture in this repo. 296 + 252 + 127 + 85 + 70 green
# assertions never touched the 4Kn path.
#
# MEASURED on an AYANEO Pocket ACE, 2026-08-21: the ESP at 256M (65376 clusters) and efi-A/B at 64M
# (16320) were both invalid FAT32 at 4096-byte sectors, against a floor of 65525. The device could
# not boot from internal storage, and the two halves failed in different components with
# unrelated-looking messages -- ABL's "Failed to load EFI: Not Found" for the ESP, steamcl's
# "Boot failed, waiting 5s" for the efi pair. This is the check that would have caught both from the
# table alone, with no device and no image build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$ROOT/images/partition-table.txt"
LIB="$ROOT/fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$TABLE" "$LIB"; do
  [ -r "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
command -v mkfs.vfat >/dev/null 2>&1 || {
  CASE="prerequisites"; skip "mkfs.vfat is not installed -- run this inside novadeck-build"
  printf '\ntest-partition-table.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
}

die() { printf 'lib: %s\n' "$*" >&2; return 1; }
# shellcheck source=../fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Read the FAT rows straight out of the shipped table: name, size, fs.
mapfile -t ROWS < <(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  $4 == "vfat" { print $1, $2 }' "$TABLE")

CASE="the table declares FAT partitions at all"
[ "${#ROWS[@]}" -gt 0 ] \
  && ok "${#ROWS[@]} vfat rows found" \
  || bad "no vfat rows in $TABLE -- has the fs column moved?"

mib() {  # 256M / 1G -> MiB
  local u="${1: -1}" v="${1%?}"
  case "$u" in G) echo $(( v * 1024 )) ;; M) echo "$v" ;; *) echo 0 ;; esac
}

# clusters, read back off the superblock mkfs actually wrote -- never from our own arithmetic about
# what it should have chosen. reserved sectors and FAT size are mkfs's decisions, not ours.
clusters_of() {  # <img> -> "<type> <clusters>"
  local f="$1" bps spc rsv nf t16 t32 re fsz tot rootsec
  g() { dd if="$f" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu"$2" | tr -d ' '; }
  bps=$(g 11 2); spc=$(g 13 1); rsv=$(g 14 2); nf=$(g 16 1)
  t16=$(g 19 2); t32=$(g 32 4); re=$(g 17 2); fsz=$(g 22 2)
  [ "${fsz:-0}" != 0 ] || fsz=$(g 36 4)
  tot=$t16; [ "${tot:-0}" != 0 ] || tot=$t32
  rootsec=$(( (re * 32 + bps - 1) / bps ))
  printf '%s %s\n' "$([ "$re" = 0 ] && echo 32 || echo 16)" \
                   "$(( (tot - (rsv + nf * fsz + rootsec)) / spc ))"
}

for ss in 512 4096; do
  for row in "${ROWS[@]}"; do
    read -r name size <<<"$row"
    m="$(mib "$size")"
    CASE="$name ($size) at ${ss}-byte sectors"
    [ "$m" -gt 0 ] || { bad "cannot parse the size '$size'"; continue; }

    img="$T/$name-$ss.img"; truncate -s "${m}M" "$img"

    # The rule under test is the shipped one, not a copy of it.
    want="$(FAT_SECTOR_SIZE="$ss" fat_type_for "$img")"
    case "$want" in 32|16) ;; *) bad "fat_type_for returned '$want'"; continue ;; esac

    if ! out="$(mkfs.vfat -F "$want" -S "$ss" -n T "$img" 2>&1)"; then
      bad "mkfs.vfat -F $want refused the geometry the rule chose: $out"
      continue
    fi
    read -r got cl < <(clusters_of "$img")

    [ "$got" = "$want" ] \
      && ok "the rule picked FAT$want and that is what was written" \
      || bad "the rule picked FAT$want but the superblock says FAT$got"

    if [ "$got" = 32 ]; then lo=65525; hi=268435445; else lo=4085; hi=65524; fi
    if [ "$cl" -ge "$lo" ] && [ "$cl" -le "$hi" ]; then
      ok "$cl clusters, inside FAT$got's ${lo}..${hi} (margins $((cl-lo)) / $((hi-cl)))"
    else
      bad "$cl clusters is OUTSIDE FAT$got's ${lo}..${hi} -- the firmware will refuse to mount it"
    fi

    # A margin of a handful of clusters is decided by mkfs.fat's reserved-sector arithmetic rather
    # than by us, and moves with its version. efi-a/b at 64M sat 7 clusters above the FAT12 floor.
    [ $(( cl - lo )) -ge 2000 ] && [ $(( hi - cl )) -ge 2000 ] \
      && ok "and not within 2000 clusters of either boundary" \
      || bad "$cl is within 2000 clusters of a boundary (${lo}..${hi}) -- too tight to rely on"

    # The shipped assertion must agree; it is what runs on the device.
    ( FAT_SECTOR_SIZE="$ss" assert_fat_valid "$img" "$name" ) >/dev/null 2>&1 \
      && ok "assert_fat_valid accepts it, as it will on the device" \
      || bad "assert_fat_valid rejects a filesystem this suite considers valid"
  done
done

# The regression itself, stated as a case: the sizes that failed on hardware must still fail here.
CASE="the geometry that broke the ACE is still rejected"
for spec in "64 4096" "256 4096"; do
  read -r m ss <<<"$spec"
  img="$T/regress-$m-$ss.img"; truncate -s "${m}M" "$img"
  if mkfs.vfat -F 32 -S "$ss" -n T "$img" >/dev/null 2>&1; then
    read -r _ cl < <(clusters_of "$img")
    [ "$cl" -lt 65525 ] \
      && ok "${m}M at ${ss}b forced to FAT32 gives $cl clusters, below 65525 as it did on hardware" \
      || bad "${m}M at ${ss}b forced to FAT32 gives $cl clusters -- the premise of this fix is wrong"
  else
    ok "${m}M at ${ss}b cannot even be made FAT32"
  fi
  [ "$(FAT_SECTOR_SIZE="$ss" fat_type_for "$img")" = 16 ] \
    && ok "and the rule declines FAT32 there" \
    || bad "the rule still chooses FAT32 for ${m}M at ${ss}b"
done

printf '\ntest-partition-table.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
