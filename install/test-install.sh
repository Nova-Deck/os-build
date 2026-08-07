#!/usr/bin/env bash
# Offline tests for the internal-install primitives — Phase 2 of
# .claude/plans/internal-install.plan.md.
#
#   install/test-install.sh
#
# Everything runs on the host with no root, no device and no cross-build. Run via `make test`.
#
# WHAT IS ACTUALLY AT RISK HERE. parts.env is a GRUB environment block we write BY HAND, because its
# contents are per-disk and grub-editenv is not on the shipped image. Hand-rolling a binary format
# another program parses is the kind of thing that works until it does not, and the failure is
# silent in the worst way: grub_envblk_open only requires the 25-byte signature to fit, so a block
# that is the wrong LENGTH still reads back perfectly with grub-editenv while differing from what
# make-sdcard.sh writes on a card. So this asserts two independent things -- that GRUB's own tool
# reads back every key, and that the bytes match the card's shape exactly.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh"
GENPART="$ROOT/images/genpart.sh"
TABLE="$ROOT/images/partition-table.txt"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$LIB" "$GENPART" "$TABLE"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB"

# The indices from a REAL captured layout rather than 1..8: the Pocket-FIT-shaped case from the
# plan's Phase 0, where our ESP fills a hole at p3 and the rest land at 7..13. A test that only ever
# exercised 1..8 would pass against a parts.env writer that ignored its arguments.
MAP_FIXTURE='NOVADECK-ESP=3
novadeck-efi-A=7
novadeck-efi-B=8
novadeck-root-A=9
novadeck-root-B=10
novadeck-var-A=11
novadeck-var-B=12
novadeck-home=13'

# --- 1. the genpart map -> parts.env keys -------------------------------------------------------
CASE="genpart map -> parts.env keys"
mapped="$(printf '%s\n' "$MAP_FIXTURE" | parts_env_from_genpart_map)" \
  && ok "the eight GPT names all map to a key" \
  || bad "mapping the genpart map failed"

for expect in nd_esp=3 nd_efi_a=7 nd_efi_b=8 nd_root_a=9 nd_root_b=10 nd_var_a=11 nd_var_b=12 nd_home=13; do
  printf '%s\n' "$mapped" | grep -qx -- "$expect" \
    && ok "emits $expect" \
    || bad "missing $expect (got: $(printf '%s' "$mapped" | tr '\n' ' '))"
done

# Every name in the shipped table must be mappable -- this is what breaks loudly when a row is
# renamed, instead of writing a well-formed parts.env that names nothing stage 2 looks for.
CASE="table names are all mappable"
while read -r label; do
  [ -n "$label" ] || continue
  printf '%s=1\n' "$label" | parts_env_from_genpart_map >/dev/null 2>&1 \
    && ok "$label has a parts.env key" \
    || bad "$label is in partition-table.txt but parts_env_from_genpart_map has no key for it"
done < <(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {print $5}' "$TABLE")

CASE="a name with no key is fatal"
( printf 'not-ours=4\n' | parts_env_from_genpart_map >/dev/null 2>&1 ) \
  && bad "an unknown GPT name was accepted" \
  || ok "refuses a GPT name it has no key for"

CASE="a non-numeric index is fatal"
( printf 'novadeck-home=xyz\n' | parts_env_from_genpart_map >/dev/null 2>&1 ) \
  && bad "a non-numeric index was accepted" \
  || ok "refuses a non-numeric index"

# --- 2. the block's bytes -----------------------------------------------------------------------
CASE="parts.env block shape"
# shellcheck disable=SC2046  # word splitting is the point: one argument per key=value line
block="$T/parts.env"
parts_env_block $(printf '%s\n' "$mapped") >"$block"

size=$(wc -c <"$block")
[ "$size" -eq 1024 ] \
  && ok "the block is exactly 1024 bytes" \
  || bad "the block is $size bytes, not 1024 -- grub_envblk_open would still read it, and it would not match a card"

head -c 25 "$block" | cmp -s - <(printf '# GRUB Environment Block\n') \
  && ok "the 25-byte signature is byte-exact (envblk.c memcmp's it)" \
  || bad "the signature does not match what GRUB compares against"

tail -c 1 "$block" | grep -q '#' \
  && ok "the block ends on padding, with no trailing newline" \
  || bad "the block does not end on '#' padding"

LC_ALL=C grep -q '^nd_esp=3$' "$block" \
  && ok "carries the discovered index, not the row order (nd_esp=3)" \
  || bad "nd_esp is not the discovered index"

CASE="over-long content is fatal"
# 1024 bytes of keys cannot fit alongside the signature; the writer must say so rather than emit a
# truncated block that reads back fine.
long=(); for i in $(seq 1 120); do long+=("nd_pad_$i=123456789"); done
( parts_env_block "${long[@]}" >/dev/null 2>&1 ) \
  && bad "content overflowing the block was accepted" \
  || ok "refuses content that does not fit the 1024-byte block"

CASE="a non key=value entry is fatal"
( parts_env_block "nd_esp" >/dev/null 2>&1 ) \
  && bad "a bare token was accepted as an entry" \
  || ok "refuses an entry that is not key=value"

# --- 3. GRUB's own parser reads it back ---------------------------------------------------------
# The assertion the rest of this file exists to support: our hand-rolled bytes are what
# grub-editenv parses. Structure tests above can all pass against a block GRUB rejects.
CASE="grub-editenv reads back the hand-rolled block"
if command -v grub-editenv >/dev/null 2>&1; then
  readback="$(grub-editenv "$block" list 2>/dev/null)"
  for expect in nd_esp=3 nd_efi_a=7 nd_efi_b=8 nd_root_a=9 nd_root_b=10 nd_var_a=11 nd_var_b=12 nd_home=13; do
    printf '%s\n' "$readback" | grep -qx -- "$expect" \
      && ok "grub-editenv list reads back $expect" \
      || bad "grub-editenv did not read back $expect"
  done
  # And byte-identical to what grub-editenv itself would have written, which is the standard the
  # plan sets: one reader, two writers, same object.
  ref="$T/ref.env"
  grub-editenv "$ref" create 2>/dev/null
  # shellcheck disable=SC2046
  grub-editenv "$ref" set $(printf '%s\n' "$mapped") 2>/dev/null
  cmp -s "$block" "$ref" \
    && ok "byte-identical to a grub-editenv-written block" \
    || bad "differs from what grub-editenv writes for the same keys"
else
  skip "grub-editenv is not installed -- the readback assertion did not run"
fi

# --- 4. write_parts_env puts it where stage 2 looks ---------------------------------------------
CASE="write_parts_env"
mnt="$T/efi"; mkdir -p "$mnt"
# shellcheck disable=SC2046
( write_parts_env "$mnt" $(printf '%s\n' "$mapped") ) \
  && ok "writes without error" \
  || bad "write_parts_env failed"
[ -f "$mnt/EFI/steamos/parts.env" ] \
  && ok "lands at /EFI/steamos/parts.env, where the stage-2 grub.cfg loads it" \
  || bad "no parts.env at EFI/steamos/"
cmp -s "$mnt/EFI/steamos/parts.env" "$block" \
  && ok "the written file is the block" \
  || bad "the written file differs from parts_env_block's output"

CASE="write_parts_env with no mountpoint"
( write_parts_env "$T/definitely-not-here" nd_esp=1 >/dev/null 2>&1 ) \
  && bad "wrote to a mountpoint that does not exist" \
  || ok "refuses when the efi partition is not mounted"

printf '\ntest-install.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
