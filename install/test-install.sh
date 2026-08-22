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

  # The EMPTY case, which is a different artifact with a different owner: boot/grub.sh runs
  # `grub-editenv create` to emit out/boot/grubenv, the shared ESP's stage-2 env block, and ships it
  # into the root so the internal installer can cp it onto an ESP it just made (the device has no
  # grub-editenv). Asserting our writer reproduces that block with NO keys says the shipped constant
  # is not opaque: if grub-editenv ever left the build container, parts_env_block emits the same
  # bytes, and nothing about the card or an install would change.
  pristine="$T/pristine.env"
  grub-editenv "$pristine" create 2>/dev/null
  parts_env_block >"$T/pristine-ours.env"
  cmp -s "$pristine" "$T/pristine-ours.env" \
    && ok "a keyless block is byte-identical to grub-editenv's pristine grubenv" \
    || bad "our keyless block differs from a pristine grub-editenv grubenv"
  [ "$(wc -c <"$pristine")" -eq 1024 ] \
    && ok "the pristine grubenv is 1024 bytes (what boot/grub.sh asserts about the shipped one)" \
    || bad "a pristine grub-editenv block is not 1024 bytes"
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

# --- 5. the primitives shared with the OTA path -------------------------------------------------
# write_efi_partition and refresh_esp_stage1 came OUT of post-install.sh, and that hook's suite
# (images/test-post-install.sh) is what proves the extraction did not change what an UPDATE does.
# What it cannot cover is the installer's side of the same functions: it always calls them with the
# OTA path's arguments, on a target chosen by bootconf. These cases drive them directly, with plain
# directories standing in for mountpoints, which is all either function needs.

# A stand-in for /usr/lib/novadeck/boot of a freshly written root.
mkboot() {  # <dir> <tag>
  local d="$1" tag="$2"
  mkdir -p "$d/fonts"
  printf 'GRUB-%s\n'    "$tag" >"$d/grubaa64.efi"
  printf 'CFG-a-%s\n'   "$tag" >"$d/grub-a.cfg"
  printf 'CFG-b-%s\n'   "$tag" >"$d/grub-b.cfg"
  printf 'MONO-%s\n'    "$tag" >"$d/fonts/dejavu-mono.pf2"
  printf 'DEFAULT-%s\n' "$tag" >"$d/fonts/default.pf2"
  printf 'STEAMCL-%s\n' "$tag" >"$d/steamcl.efi"
  printf 'VER-%s\n'     "$tag" >"$d/steamcl-version"
}
BOOT="$T/boot"; mkboot "$BOOT" 1

CASE="write_efi_partition"
efimnt="$T/efimnt"; mkdir -p "$efimnt"
write_efi_partition "$efimnt" B "$BOOT" \
  && ok "writes without error" \
  || bad "write_efi_partition failed"
# The per-slot cfg is the one argument-dependent choice here: a function that ignored its slot would
# still produce a bootable-looking efi partition carrying the OTHER slot's grub.cfg, and that boots
# the wrong root.
[ "$(cat "$efimnt/EFI/steamos/grub.cfg" 2>/dev/null)" = "CFG-b-1" ] \
  && ok "grub.cfg is the requested slot's (grub-b.cfg -> grub.cfg)" \
  || bad "grub.cfg is not slot B's"
[ "$(cat "$efimnt/EFI/steamos/grubaa64.efi" 2>/dev/null)" = "GRUB-1" ] \
  && ok "grubaa64.efi comes from the given bootdir" \
  || bad "grubaa64.efi was not installed"
[ "$(cat "$efimnt/EFI/steamos/fonts/dejavu-mono.pf2" 2>/dev/null)" = "MONO-1" ] \
  && ok "the stage-2 font is installed" \
  || bad "the stage-2 font was not installed"

CASE="write_efi_partition slot A"
efimnt_a="$T/efimnt-a"; mkdir -p "$efimnt_a"
write_efi_partition "$efimnt_a" A "$BOOT" >/dev/null 2>&1
[ "$(cat "$efimnt_a/EFI/steamos/grub.cfg" 2>/dev/null)" = "CFG-a-1" ] \
  && ok "slot A gets grub-a.cfg" \
  || bad "slot A did not get grub-a.cfg"

CASE="write_efi_partition preserves parts.env"
# THE ONE THING ON THAT PARTITION THIS FUNCTION MUST NOT TOUCH. On an internal install parts.env is
# the only record of where our eight partitions landed on the OEM's GPT, and nothing can rebuild it
# -- an update running on the device cannot know the layout any better than the installer did. A
# refresh that wiped or --delete'd would leave stage 2 falling back to the SD card's 1..8.
printf 'SENTINEL\n' >"$efimnt/EFI/steamos/parts.env"
write_efi_partition "$efimnt" B "$BOOT" >/dev/null 2>&1
[ "$(cat "$efimnt/EFI/steamos/parts.env" 2>/dev/null)" = "SENTINEL" ] \
  && ok "a second write leaves parts.env alone" \
  || bad "parts.env did not survive write_efi_partition"

CASE="write_efi_partition with an incomplete root"
mkboot "$T/boot-nogrub" 2; rm -f "$T/boot-nogrub/grubaa64.efi"
( write_efi_partition "$T/efimnt-x" B "$T/boot-nogrub" >/dev/null 2>&1 ) \
  && bad "wrote an efi partition from a root with no stage-2 GRUB" \
  || ok "refuses a root carrying no stage-2 GRUB"
mkboot "$T/boot-nocfg" 3; rm -f "$T/boot-nocfg/grub-b.cfg"
( write_efi_partition "$T/efimnt-y" B "$T/boot-nocfg" >/dev/null 2>&1 ) \
  && bad "wrote an efi partition with no grub.cfg for the slot" \
  || ok "refuses a root carrying no grub-<slot>.cfg"

CASE="write_efi_partition with a bad slot name"
( write_efi_partition "$T/efimnt-z" C "$BOOT" >/dev/null 2>&1 ) \
  && bad "accepted an image name that is not A or B" \
  || ok "refuses an image name that is not A or B"

# --- 6. mint_partsets ---------------------------------------------------------------------------
# Installer-only: the OTA path COPIES the partsets off the running /efi, because they describe the
# disk it already booted from. The installer is writing a disk with no novadeck on it, so nothing
# exists to copy and the uuids come from the GPT it just laid down. Nothing else covers this.
U_ESP=1a2b3c4d-1111-2222-3333-444455556666
U_EFIA=2b3c4d5e-1111-2222-3333-444455556667
U_EFIB=3c4d5e6f-1111-2222-3333-444455556668

CASE="mint_partsets"
ps="$T/ps-b"; mkdir -p "$ps"
mint_partsets "$ps" B "$U_ESP" "$U_EFIA" "$U_EFIB" \
  && ok "mints without error" \
  || bad "mint_partsets failed"
expect_partset() {  # <file> <content>
  [ "$(cat "$ps/SteamOS/partsets/$1" 2>/dev/null)" = "$2" ] \
    && ok "partsets/$1 = '$2'" \
    || bad "partsets/$1: expected '$2', got '$(cat "$ps/SteamOS/partsets/$1" 2>/dev/null)'"
}
expect_partset A      "efi $U_EFIA"
expect_partset B      "efi $U_EFIB"
expect_partset all    "esp $U_ESP"
expect_partset shared "esp $U_ESP"
# self/other are the only two that depend on which image this partition is. steamcl matches the
# booted efi partition's uuid against partsets/self to name the image, so a swapped pair makes each
# efi partition claim to be the other one.
expect_partset self   "efi $U_EFIB"
expect_partset other  "efi $U_EFIA"

CASE="mint_partsets for slot A"
ps="$T/ps-a"; mkdir -p "$ps"
mint_partsets "$ps" A "$U_ESP" "$U_EFIA" "$U_EFIB" >/dev/null 2>&1
expect_partset self  "efi $U_EFIA"
expect_partset other "efi $U_EFIB"

CASE="mint_partsets rejects an upper-case uuid"
# sgdisk PRINTS partition GUIDs in upper case, and steamcl compares these strings. A set minted from
# raw sgdisk output is well-formed, matches nothing, and the symptom is a disk that does not boot --
# visible only on hardware. images/make-sdcard.sh lowercases at the same seam.
( mint_partsets "$T/ps-upper" B "${U_ESP^^}" "$U_EFIA" "$U_EFIB" >/dev/null 2>&1 ) \
  && bad "an upper-case partition uuid was accepted" \
  || ok "refuses an upper-case partition uuid"

CASE="mint_partsets rejects a non-uuid and a bad image name"
( mint_partsets "$T/ps-junk" B "not-a-uuid" "$U_EFIA" "$U_EFIB" >/dev/null 2>&1 ) \
  && bad "a non-uuid was accepted" \
  || ok "refuses a value that is not a partition uuid"
( mint_partsets "$T/ps-c" C "$U_ESP" "$U_EFIA" "$U_EFIB" >/dev/null 2>&1 ) \
  && bad "accepted an image name that is not A or B" \
  || ok "refuses an image name that is not A or B"

# --- 7. refresh_esp_stage1 ----------------------------------------------------------------------
# The OTA suite covers this against the running ESP. What it never does is call it on an ESP that is
# EMPTY, which is the installer's case: every file is new, so every comparison takes the "not
# present" arm rather than the digest arm.
CASE="refresh_esp_stage1 onto an empty ESP"
esp="$T/esp"; mkdir -p "$esp"
refresh_esp_stage1 "$esp" "$BOOT" >/dev/null \
  && ok "populates an ESP with nothing on it" \
  || bad "refresh_esp_stage1 failed on an empty ESP"
expect_esp_file() {  # <path> <content>
  [ "$(cat "$esp/$1" 2>/dev/null)" = "$2" ] \
    && ok "/$1 = '$2'" \
    || bad "/$1: expected '$2', got '$(cat "$esp/$1" 2>/dev/null)'"
}
# ABL chainloads bootaa64.efi by that name; the source is called steamcl.efi. A copy that kept the
# source name would leave a disk ABL cannot boot at all.
expect_esp_file EFI/BOOT/bootaa64.efi 'STEAMCL-1'
expect_esp_file EFI/BOOT/steamcl-version 'VER-1'
expect_esp_file EFI/BOOT/fonts/default.pf2 'DEFAULT-1'
[ -f "$esp/EFI/BOOT/steamcl-restricted" ] \
  && ok "steamcl-restricted exists (chainloading stays on this physical device)" \
  || bad "steamcl-restricted was not created"

CASE="refresh_esp_stage1 skips identical files"
# Not an optimisation: the shared ESP is the only write with no A/B copy behind it, so every
# needless rewrite of the file ABL chainloads is a power-cut window with nothing to roll back to.
# By mtime, because `cp -f` truncates in place and keeps the inode.
touch -d '2001-01-01 00:00:00' "$esp/EFI/BOOT/bootaa64.efi"
before=$(stat -c %Y "$esp/EFI/BOOT/bootaa64.efi")
refresh_esp_stage1 "$esp" "$BOOT" >/dev/null
[ "$before" = "$(stat -c %Y "$esp/EFI/BOOT/bootaa64.efi")" ] \
  && ok "an unchanged bootaa64.efi is not rewritten" \
  || bad "bootaa64.efi was rewritten despite identical content"

CASE="refresh_esp_stage1 still refreshes what changed"
# A skip that skipped everything would pass the case above and be just as wrong.
mkboot "$T/boot2" 2
refresh_esp_stage1 "$esp" "$T/boot2" >/dev/null
expect_esp_file EFI/BOOT/bootaa64.efi 'STEAMCL-2'
expect_esp_file EFI/BOOT/steamcl-version 'VER-2'

CASE="refresh_esp_stage1 with no steamcl in the root"
mkboot "$T/boot-nocl" 4; rm -f "$T/boot-nocl/steamcl.efi"
( refresh_esp_stage1 "$T/esp-x" "$T/boot-nocl" >/dev/null 2>&1 ) \
  && bad "refreshed the ESP from a root with no steamcl" \
  || ok "refuses a root carrying no steamcl.efi"

CASE="refresh_esp_stage1 with a missing hasher"
# The two ways of losing the comparator fail in OPPOSITE directions and only one is survivable. A
# comparator that EXITS non-zero degrades to always-copy: wasteful, bytes right. A comparator that
# is ABSENT yields two empty strings inside $(...) that compare EQUAL, so nothing is ever refreshed
# and a new root boots against the old stage 1. Callers assert the tool before touching anything;
# this proves the seam they assert through is the one the function reads.
( SHA256=novadeck-no-such-hasher refresh_esp_stage1 "$T/esp-h" "$BOOT" >/dev/null 2>&1
  [ "$(cat "$T/esp-h/EFI/BOOT/bootaa64.efi" 2>/dev/null)" = "STEAMCL-1" ] ) \
  && ok "a first write still lands (the not-present arm does not consult the hasher)" \
  || bad "the empty-ESP write depends on the hasher"

# mkfs_esp is NOT covered here and cannot be: it needs a block device and root. It is one
# mkfs.vfat with the label and -F 32 fixed, and the installer's hardware bring-up is where it gets
# exercised. Named so a reader does not mistake its absence for an oversight.
CASE="mkfs_esp"
declare -F mkfs_esp >/dev/null \
  && ok "defined (unexercised offline -- needs a block device and root)" \
  || bad "mkfs_esp is not defined"

# --- 8. the /var seed: one archive, two programs, and they must agree ---------------------------
# images/assemble-rootfs.sh PACKS var-seed.tar.zst and lib-slotwrite.sh's seed_var UNPACKS it, and
# between them they have to reproduce what the OTA path gets from `rsync -aHAX --numeric-ids`. The
# flags are the whole contract: nothing fails if they drift, the slot just comes up subtly wrong.
ASSEMBLE="$ROOT/images/assemble-rootfs.sh"

CASE="the pack and unpack flag sets agree"
for flag in -- --numeric-owner --xattrs --acls; do
  [ "$flag" = -- ] && continue
  grep -q -- "$flag" <(grep -A3 'tar --numeric-owner' "$ASSEMBLE") \
    && ok "assemble-rootfs.sh packs with $flag" \
    || bad "assemble-rootfs.sh no longer packs with $flag"
  grep -q -- "$flag" <(grep -A2 'tar -p --numeric-owner' "$LIB") \
    && ok "seed_var unpacks with $flag" \
    || bad "seed_var no longer unpacks with $flag"
done
# -p is the one that looks redundant and is not: tar defaults to preserving permissions only when
# it thinks it is root, and the round-trip below is what proves what that costs.
grep -q 'tar -p --numeric-owner' "$LIB" \
  && ok "seed_var unpacks with -p (not left to tar's root-only default)" \
  || bad "seed_var lost -p -- setuid/sticky bits come back masked"

CASE="the seed round-trips the modes that matter"
if command -v zstd >/dev/null 2>&1; then
  V="$T/varstage"
  mkdir -p "$V/lib/overlays/etc/upper" "$V/lib/novadeck" "$V/tmp"
  chmod 1777 "$V/tmp"
  printf '7070e56b\n'   >"$V/lib/overlays/etc/upper/machine-id"
  printf 'ssh-ed25519\n' >"$V/lib/overlays/etc/upper/ssh_host_ed25519_key"
  chmod 0600 "$V/lib/overlays/etc/upper/ssh_host_ed25519_key"
  printf 'a\n'          >"$V/lib/novadeck/slot"
  printf 'de:ad\n'      >"$V/lib/novadeck/mac-wifi"

  seed="$T/var-seed.tar.zst"
  tar --numeric-owner --xattrs --acls --zstd \
      --exclude=./lib/novadeck/slot --exclude=./lib/novadeck/mac-wifi \
      -cf "$seed" -C "$V" . 2>/dev/null
  M="$T/seedmnt"; mkdir -p "$M"
  tar -p --numeric-owner --xattrs --acls -xf "$seed" -C "$M" 2>/dev/null

  # sshd refuses to start if a private host key is group/world-readable, so this one takes SSH down
  # on installed devices and nowhere else -- the worst shape on a device with no serial console.
  [ "$(stat -c %a "$M/lib/overlays/etc/upper/ssh_host_ed25519_key")" = 600 ] \
    && ok "a 0600 host key survives the round-trip (sshd would start)" \
    || bad "the host key came back $(stat -c %a "$M/lib/overlays/etc/upper/ssh_host_ed25519_key") -- sshd would refuse to start"
  # MEASURED, not assumed: without -p this comes back 0777. The bit is in the archive either way.
  [ "$(stat -c %a "$M/tmp")" = 1777 ] \
    && ok "/var/tmp keeps its sticky bit (1777)" \
    || bad "/var/tmp came back $(stat -c %a "$M/tmp") -- any user could delete another's files there"
  [ -f "$M/lib/overlays/etc/upper/machine-id" ] \
    && ok "the machine-id rides across (the derived Wi-Fi MAC depends on it)" \
    || bad "machine-id did not survive the seed"
  # The two exclusions, which are what stop every installed device sharing an identity.
  [ ! -e "$M/lib/novadeck/slot" ] \
    && ok "no baked-in slot witness (seed_var writes it after unpacking)" \
    || bad "the seed carried lib/novadeck/slot"
  [ ! -e "$M/lib/novadeck/mac-wifi" ] \
    && ok "no baked-in mac-wifi (else every install shares one Wi-Fi MAC)" \
    || bad "the seed carried lib/novadeck/mac-wifi"
else
  skip "zstd is not installed -- the /var seed round-trip did not run"
fi

# --- 9. genpart.sh + the table, from the SHIPPED layout -----------------------------------------
# Both files are installed verbatim into /usr/lib/novadeck/install/ of the built root, and
# images/guard-rootfs.sh diffs them against images/ at build time. Byte-identity is not the whole
# claim though: the shipped copies also have to WORK from that directory, which is a different
# thing and is what genpart.sh's `TABLE=$SELFDIR/partition-table.txt` seam exists for. A copy that
# resolved the table through a repo-relative path would be byte-identical and dead on a device.
#
# So: reproduce the shipped layout in a tmpdir and assert the output is identical to the repo
# invocation. Neither mode touches a disk without a target argument, so this needs no sgdisk.
CASE="the shipped layout resolves its own table"
SHIPPED="$T/usr-lib-novadeck-install"; mkdir -p "$SHIPPED"
cp "$GENPART" "$SHIPPED/genpart.sh"
cp "$TABLE"   "$SHIPPED/partition-table.txt"
chmod 0555 "$SHIPPED/genpart.sh"

for mode in create append; do
  case "$mode" in
    create) repo_out=$(bash "$GENPART" 2>/dev/null);            ship_out=$(bash "$SHIPPED/genpart.sh" 2>/dev/null) ;;
    append) repo_out=$(bash "$GENPART" --append 2>/dev/null);   ship_out=$(bash "$SHIPPED/genpart.sh" --append 2>/dev/null) ;;
  esac
  [ -n "$ship_out" ] \
    && ok "$mode mode emits from the shipped location" \
    || bad "$mode mode emitted nothing from the shipped location -- did it fail to find its table?"
  [ "$repo_out" = "$ship_out" ] \
    && ok "$mode mode is identical from images/ and from the shipped dir" \
    || bad "$mode mode differs between the repo and the shipped copy"
done

# The eight GPT names have to survive into the emitted script, or --append lays down partitions
# parts_env_from_genpart_map cannot name. This is the join between the two halves of Phase 2.
CASE="the shipped script carries every table name"
ship_append=$(bash "$SHIPPED/genpart.sh" --append 2>/dev/null)
while read -r label; do
  [ -n "$label" ] || continue
  printf '%s\n' "$ship_append" | grep -q -- "$label" \
    && ok "$label appears in the emitted append script" \
    || bad "$label is in partition-table.txt but not in what the shipped genpart.sh emits"
done < <(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {print $5}' "$TABLE")

CASE="the table is resolved next to the script, not through the cwd"
# Run from an unrelated directory: a script that reached for ./partition-table.txt or a repo-relative
# path would work in the repo and die on a device, which is the failure this seam prevents.
( cd "$T" && bash "$SHIPPED/genpart.sh" >/dev/null 2>&1 ) \
  && ok "works with the cwd elsewhere" \
  || bad "the shipped genpart.sh depends on the cwd"

CASE="NOVADECK_PARTITION_TABLE still overrides"
# The other half of the seam: the installer needs to be able to point genpart at a table it chose.
# A copy that hardcoded $SELFDIR would pass every case above and remove that lever.
printf '# empty table\n' >"$T/empty-table.txt"
alt_out=$(NOVADECK_PARTITION_TABLE="$T/empty-table.txt" bash "$SHIPPED/genpart.sh" 2>/dev/null)
[ "$alt_out" != "$ship_out" ] \
  && ok "an overridden table changes the output" \
  || bad "NOVADECK_PARTITION_TABLE was ignored by the shipped copy"

# --- 10. the append floor is MANDATORY (Phase 3) ------------------------------------------------
# Through Phase 2 the floor was opt-in, which was right while every caller passed --append with no
# target. Applied to a real device it is the assertion that makes span containment hold by
# construction: unset, sgdisk starts our eight at whatever the largest free block is, which is the
# carve's freed tail only by luck.
#
# These run the EMITTED script rather than genpart.sh itself, because the emitted text is what the
# installer executes and what ships to the device. sgdisk is not needed and deliberately not used:
# the floor is checked ahead of the first disk read, so a refusal here cannot be a "sgdisk: command
# not found" in disguise -- which is the shape this suite would otherwise get for free and prove
# nothing with.
# Before anything behavioural: the emitted text has to PARSE. genpart runs it as
# `bash -c "$(emit_append)"`, so a quoting slip in the generator is a runtime failure on a device
# rather than a build error, and every case below would refuse for that reason and read green.
# (Caught one immediately: an apostrophe inside ${var:?...} opens a quote even within double quotes,
# and bash reports it dozens of lines further down.)
CASE="the emitted scripts are syntactically valid"
for mode in create append; do
  case "$mode" in
    create) bash "$SHIPPED/genpart.sh"          >"$T/emitted-$mode.sh" 2>/dev/null ;;
    append) bash "$SHIPPED/genpart.sh" --append >"$T/emitted-$mode.sh" 2>/dev/null ;;
  esac
  bash -n "$T/emitted-$mode.sh" 2>/dev/null \
    && ok "$mode mode emits parseable bash" \
    || bad "$mode mode emits a script bash cannot parse: $(bash -n "$T/emitted-$mode.sh" 2>&1 | head -1)"
done

CASE="the append floor is required, not optional"
append_script=$(bash "$SHIPPED/genpart.sh" --append 2>/dev/null)
run_append() {  # <floor, or UNSET> [ceil, or UNSET] -> rc, with stderr merged onto stdout
  ( case "$1" in UNSET) unset NOVADECK_APPEND_FLOOR ;; *) export NOVADECK_APPEND_FLOOR="$1" ;; esac
    case "${2-100000000}" in UNSET) unset NOVADECK_APPEND_CEIL ;; *) export NOVADECK_APPEND_CEIL="${2-100000000}" ;; esac
    DISK="$T/nodisk.img" PATH="$T/nobin:$PATH" bash -euo pipefail -c "$append_script" ) 2>&1
}
mkdir -p "$T/nobin"

out=$(run_append UNSET); rc=$?
[ "$rc" -ne 0 ] \
  && ok "no floor -> refuses (rc=$rc)" \
  || bad "an append with NO floor was accepted -- sgdisk would place our eight anywhere"
printf '%s\n' "$out" | grep -q 'NOVADECK_APPEND_FLOOR' \
  && ok "the refusal names the variable the caller has to set" \
  || bad "refused without saying the floor is what is missing: $out"
# Which check fired matters: a run that died on the GPT probe would also be non-zero, and would
# still accept a floorless append against a disk that HAS a readable GPT.
printf '%s\n' "$out" | grep -q 'has no readable GPT' \
  && bad "the GPT probe fired first -- a floorless append still reaches the disk" \
  || ok "the floor is checked before the target is read at all"

# `[ 34 -lt abc ]` exits 2, and an `if` reads that as false: a typo'd floor would sail straight
# through the comparison with the check LOOKING set. Measured, not assumed -- hence its own case.
CASE="a floor that is not a sector number is refused"
for bogus in 16GiB 2048MiB ' ' -1 0x800 ''; do
  out=$(run_append "$bogus"); rc=$?
  # Non-zero alone is not the assertion. Under a reverted guard these runs die on the GPT probe
  # instead and every one of them reads green -- measured during the mutation check, not supposed.
  # So match the message: the numeric gate has to be what rejected it.
  { [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE 'must be a sector number|NOVADECK_APPEND_FLOOR: required'; } \
    && ok "floor '$bogus' -> refused by the numeric gate" \
    || bad "floor '$bogus' was not refused by the floor check (rc=$rc): $out"
done
# ...and the numeric one gets past the floor gate, or the case above proves only that everything
# fails. It dies later, at the missing sgdisk, which is exactly how far this test can honestly go.
out=$(run_append 2048)
printf '%s\n' "$out" | grep -qE 'NOVADECK_APPEND_FLOOR|must be a sector number' \
  && bad "a plain sector number was rejected by the floor gate: $out" \
  || ok "a plain sector number passes the gate (the run then needs a real sgdisk)"

# --- 11. the window: a ceiling, a size check and a containment check ------------------------------
# WHY THE CEILING EXISTS, measured against real sgdisk 2026-08-10 rather than reasoned: `-n 0:0:+sz`
# re-resolves the LARGEST FREE BLOCK on every call, so a run that starts correctly inside the carve's
# tail still relocates mid-layout. On a 40 GiB fixture the ESP and both roots landed in the tail,
# then var-A/var-B/home jumped past an OEM partition into a bigger hole and sgdisk reported success.
# A floor cannot catch it -- it only ever sees the first call. Hence explicit placement between a
# floor and a ceiling, and hence these cases.
#
# The stub serves `sgdisk -p` from a synthetic table and fails every mutating call, so a run that
# survives all the checks dies at the first create. It is the MESSAGE that says which outcome it was.
CASE="the append window is checked before anything is written"
mkdir -p "$T/stub"
cat >"$T/stub/sgdisk" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -p) printf 'Disk /stub: 83886080 sectors, 40.0 GiB\n'
        printf 'Sector size (logical): %s bytes\n' "${STUB_SS:-512}"
        printf 'Number  Start (sector)    End (sector)  Size       Code  Name\n'
        printf '%s\n' "$STUB_ROWS"
        exit 0 ;;
  esac
done
echo "stub sgdisk: refusing to partition" >&2
exit 1
STUB
chmod +x "$T/stub/sgdisk"

# lib-gpt.sh reads type GUIDs with `sfdisk --dump` to tell a live GPT entry from one the table no
# longer uses (issue #56), so the stub disk has to answer that too -- and answering it is what lets
# the last case below put a DEAD row inside the window and assert it is not a refusal. STUB_DEAD is
# the list of indices to render with an all-zero type; everything else is a real partition.
cat >"$T/stub/sfdisk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--dump" ] || { echo "stub sfdisk: only --dump is served" >&2; exit 1; }
printf 'label: gpt\ndevice: %s\nunit: sectors\n\n' "$2"
while read -r n s e _; do
  [ -n "$n" ] || continue
  t=0FC63DAF-8483-4772-8E79-3D69D8477DE4
  case " ${STUB_DEAD:-} " in *" $n "*) t=00000000-0000-0000-0000-000000000000 ;; esac
  printf '%s%s : start=%s, size=%s, type=%s\n' "$2" "$n" "$s" "$(( e - s + 1 ))" "$t"
done <<<"$STUB_ROWS"
STUB
chmod +x "$T/stub/sfdisk"
: >"$T/nodisk.img"

# 40 GiB disk; userdata shrunk to 8 GiB ending at 16812031, an OEM partition at 62949376. So the
# carve's window is 16812032..62949375 -- the shape the real-sgdisk run above was driven with.
STUB_TABLE='   1            2048           34815   16.0 MiB    8300  oem-early
   2           34816        16812031   8.0 GiB     8300  userdata
   3        62949376        63080447   64.0 MiB    8300  oem-late'
FLOOR=16812032
CEIL=62949375
try_window() {  # <floor> <ceil> [rows] [dead-indices] -> the run's output
  ( export NOVADECK_APPEND_FLOOR="$1" NOVADECK_APPEND_CEIL="$2"
    # The emitted script resolves lib-gpt.sh from /usr/lib/novadeck/install by default -- that is
    # the shipped location, and it is not where the repo copy lives. genpart.sh exports this same
    # variable when it applies the script itself.
    STUB_ROWS="${3-$STUB_TABLE}" STUB_DEAD="${4-}" DISK="$T/nodisk.img" PATH="$T/stub:$PATH" \
    NOVADECK_LIB_GPT="$ROOT/images/lib-gpt.sh" \
    bash -euo pipefail -c "$append_script" ) 2>&1
}

out=$(run_append "$FLOOR" UNSET)
printf '%s\n' "$out" | grep -q 'NOVADECK_APPEND_CEIL' \
  && ok "a floor without a ceiling is refused" \
  || bad "the ceiling is not required -- home would run to the end of the disk: $out"
out=$(run_append "$FLOOR" 4096MiB)
printf '%s\n' "$out" | grep -q 'must be a sector number' \
  && ok "a non-numeric ceiling is refused" \
  || bad "a non-numeric ceiling was accepted: $out"
out=$(run_append "$FLOOR" "$FLOOR")
printf '%s\n' "$out" | grep -q 'is not above floor' \
  && ok "a ceiling equal to the floor is refused" \
  || bad "an empty window was accepted: $out"

# The layout needs ~15 GiB. A window smaller than that used to create three partitions and refuse
# the fourth, leaving a half-appended GPT -- the state a user cannot boot and cannot diagnose.
out=$(try_window "$FLOOR" "$((FLOOR + 2 * 1024 * 2048))")
{ printf '%s\n' "$out" | grep -q 'the layout needs' \
  && printf '%s\n' "$out" | grep -q 'nothing has been written'; } \
  && ok "a 2 GiB window is refused before the first sgdisk -n" \
  || bad "a too-small window was not refused up front: $out"
out=$(try_window "$FLOOR" "$CEIL")
printf '%s\n' "$out" | grep -q 'the layout needs' \
  && bad "the real 22 GiB window was rejected as too small: $out" \
  || ok "a window that fits the layout passes the size check"

# CONTAINMENT. The window is asserted clear of every existing partition, so no arithmetic error
# upstream can put us on top of one. Widening the ceiling by a single sector reaches oem-late.
out=$(try_window "$FLOOR" "$((CEIL + 1))")
{ printf '%s\n' "$out" | grep -q 'inside the window' \
  && printf '%s\n' "$out" | grep -q 'nothing has been written'; } \
  && ok "a ceiling one sector into oem-late is refused, naming it" \
  || bad "the window was allowed to overlap an existing partition: $out"
out=$(try_window "$((FLOOR - 1))" "$CEIL")
printf '%s\n' "$out" | grep -q 'inside the window' \
  && ok "a floor one sector inside the shrunk userdata is refused" \
  || bad "the window was allowed to overlap the userdata we just recreated: $out"

# A GPT ENTRY THE TABLE NO LONGER USES IS NOT SOMETHING IN THE WAY -- issue #56. `sgdisk -p` keeps
# rendering a row for an entry whose type GUID was zeroed by a foreign uninstaller, carrying stale
# LBAs, and the containment check believed it: on an AYANEO Pocket ACE, 2026-08-21, it refused with
# "partition 12 occupies 6892072..6957607, inside the window" on a disk with nothing there. Same
# window, same rows, and the only difference is whether the entry is live.
out=$(try_window "$FLOOR" "$((CEIL + 1))")
printf '%s\n' "$out" | grep -q 'inside the window' \
  && ok "oem-late inside the window is a refusal while it is a real partition" \
  || bad "the live-partition case stopped refusing, so the case below proves nothing: $out"
out=$(try_window "$FLOOR" "$((CEIL + 1))" "$STUB_TABLE" "3")
printf '%s\n' "$out" | grep -q 'inside the window' \
  && bad "a zeroed GPT entry inside the window still refuses -- the disk stays uninstallable: $out" \
  || ok "the same row with an all-zero type GUID is not in the way"

# A 4096-byte logical sector is what a real UFS LUN reports, and it changes MiB->sectors eightfold.
# Read wrong, the size check compares against a window 8x too small and refuses every real install.
out=$( STUB_SS=4096 try_window "$FLOOR" "$CEIL" )
printf '%s\n' "$out" | grep -q 'the layout needs' \
  && bad "a 4096-byte-sector disk was refused -- the MiB conversion is hardcoded to 512: $out" \
  || ok "a 4096-byte logical sector is handled (what a UFS LUN reports)"

CASE="the shipped copy carries the mandatory form"
# Byte-identity with images/ is asserted elsewhere; what is asserted here is that the emitted text
# is the MANDATORY shape, so a revert to the opt-in `[ -n "${NOVADECK_APPEND_FLOOR:-}" ] && ...`
# guard fails a test rather than quietly restoring luck-based containment.
printf '%s\n' "$append_script" | grep -q 'NOVADECK_APPEND_FLOOR:?' \
  && ok "the emitted script hard-requires the floor" \
  || bad "the emitted append script no longer requires a floor"
printf '%s\n' "$append_script" | grep -q 'NOVADECK_APPEND_FLOOR:-' \
  && bad "the opt-in floor guard is back -- an unset floor would be accepted again" \
  || ok "no opt-in floor guard remains"

# --- 12. install/rauc-session.sh — the synthesized config and who owns the bus (Phase 4a) --------
# WHAT IS AT RISK. Everything this script does is about making `rauc install` write ONE partition on
# a FOREIGN disk, and every failure mode is the same failure: it writes somewhere else instead. The
# config is the whole mechanism -- with the service enabled the install subcommand's own --conf is
# compiled out, so the config that runs is the service's, and if a stock rauc.service ever won the
# bus name the bundle would land on /dev/disk/by-partlabel/novadeck-root-A, which on an internal
# install is the INSTALLER'S OWN MEDIUM. So these assert the config's shape and the ownership proof,
# and neither can be checked on hardware without doing the destructive thing first.
SESSION="$ROOT/install/rauc-session.sh"
FRESH="$ROOT/install/post-install-fresh.sh"
for f in "$SESSION" "$FRESH"; do
  [ -x "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# The stub bin dir. `rauc` answers to two invocations and must be told apart by argv, because
# telling them apart is exactly what the script's two call sites depend on: the SERVICE gets -c and
# --override-boot-slot, and the INSTALL gets neither. The service stub records its own pid so the
# gdbus stub can hand back an owner that really is the process the script started -- that identity
# is the assertion, not the presence of the name.
STUBS="$T/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/rauc" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = install ]; then printf '%s\n' "$@" >"$STUBDIR/install.args"; exit "${STUB_INSTALL_RC:-0}"; fi
printf '%s\n' "$@" >"$STUBDIR/svc.args"
printf '%s\n' "$$"  >"$STUBDIR/svc.pid"
while :; do sleep 1; done
EOF
# The stub MODELS the tool rather than obliging the caller: --print-pid takes a file DESCRIPTOR, so
# handing it a path is `Invalid file descriptor` and exit 1, exactly as the real daemon answered on
# the Pocket ACE. A stub that quietly accepted a path would have let that ship.
cat >"$STUBS/dbus-daemon" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUBDIR/bus.args"
for a in "$@"; do
  case "$a" in
    --print-pid=*) v="${a#--print-pid=}"
                   case "$v" in ''|*[!0-9]*) printf 'Invalid file descriptor: "%s"\n' "$v" >&2; exit 1 ;; esac ;;
  esac
done
case " $* " in *' --print-pid '*) printf '%s\n' "$$" ;; esac
exit 0
EOF
# GetNameOwner then GetConnectionUnixProcessID, in gdbus' own output spelling -- the script parses
# those two shapes and a stub that emitted bare values would let a parsing bug pass.
cat >"$STUBS/gdbus" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *GetNameOwner*)              [ -f "$STUBDIR/svc.pid" ] || exit 1; printf "(':1.7',)\n"; exit 0 ;;
  *GetConnectionUnixProcessID*) printf '(uint32 %s,)\n' "${STUB_OWNER_PID:-$(cat "$STUBDIR/svc.pid")}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUBS/rauc" "$STUBS/dbus-daemon" "$STUBS/gdbus"

# The sandbox directory is set by the CALLER, not by the helper. Every call site here runs the
# helper inside $( ), which is a subshell -- a variable the helper assigned would be gone by the
# time the assertions below want to look in it.
sess_dir() { SESS_RUNDIR="$T/run.$1"; rm -rf "$SESS_RUNDIR"; mkdir -p "$SESS_RUNDIR"; }

sess_run() {  # runs rauc-session.sh in the sandbox sess_dir last named
  local rundir="$SESS_RUNDIR"
  env PATH="$STUBS:$PATH" STUBDIR="$rundir" \
      NOVADECK_INSTALL_RUN="$rundir" DEVTEST=-e OWN_TIMEOUT=5 \
      KEYRING="${SESS_KEYRING:-$T/keyring.pem}" POST_INSTALL="${SESS_POST:-$FRESH}" \
      ${STUB_OWNER_PID:+STUB_OWNER_PID="$STUB_OWNER_PID"} \
      "$SESSION" "${1:-$T/target-root}" "${2:-https://example.invalid/b.raucb}" 2>&1
}
: >"$T/keyring.pem"; : >"$T/target-root"

CASE="rauc-session: the happy path"
sess_dir happy
out="$(sess_run)" && ok "exits 0 with the tools stubbed" || bad "failed: $out"
conf="$SESS_RUNDIR/rauc.conf"

CASE="rauc-session: the synthesized config"
if [ -f "$conf" ]; then
  ok "writes $conf"
  grep -q '^\[slot\.rootfs\.0\]' "$conf" \
    && [ "$(grep -c '^\[slot\.' "$conf")" -eq 1 ] \
    && ok "declares exactly one slot (two make select_inactive_slot_class_member hash-order dependent)" \
    || bad "the config does not declare exactly one slot"
  grep -q '^bootname=' "$conf" \
    && bad "bootname= is back -- rauc would pick a boot_mark_slot and call a bootloader backend" \
    || ok "no bootname= (so boot_mark_slot is NULL and r_mark_active never runs)"
  # NOT an omission, and the plan was wrong to call the field optional: config_file.c:1506 refuses
  # a config without it unconditionally, which is how the Pocket ACE answered on 2026-08-21. `noop`
  # is the statement that there is no boot state here; any other value names a backend that would
  # act on the INSTALLER'S boot state, not the target's.
  grep -qx 'bootloader=noop' "$conf" \
    && ok "bootloader=noop (required by rauc, and the only value that acts on nothing)" \
    || bad "the bootloader is not noop: $(grep '^bootloader=' "$conf" || echo '<absent, and rauc refuses that>')"
  grep -q '^data-directory=' "$conf" \
    && bad "data-directory= is back -- a virgin slot has nothing for adaptive to reuse" \
    || ok "no data-directory="
  # The default (/mnt/rauc) cannot be created on a read-only root, and the key is UNHYPHENATED --
  # `mount-prefix` is an unknown key, so the default silently stands and the install dies after
  # streaming and verifying. Both halves asserted, because a hyphen typo looks right.
  grep -qx "mountprefix=$SESS_RUNDIR/mnt" "$conf" \
    && ok "mountprefix points into the run dir (the default is unwritable on an ro root)" \
    || bad "mountprefix is wrong or hyphenated: $(grep -i 'mountprefix\|mount-prefix' "$conf" || echo '<absent>')"
  [ -d "$SESS_RUNDIR/mnt" ] \
    && ok "the mount prefix exists before rauc needs it" \
    || bad "the mount prefix was named but not created"
  grep -q '^check-purpose=codesign' "$conf" \
    && ok "keeps check-purpose=codesign (the release cert's EKU; without it every bundle is rejected)" \
    || bad "check-purpose=codesign is missing -- verification would reject every bundle"
  grep -q "^device=$SESS_RUNDIR/target-root-a\$" "$conf" \
    && ok "the slot device is the run-dir link, not the raw path" \
    || bad "the slot device is not the stable run-dir link: $(grep '^device=' "$conf")"
  [ "$(readlink "$SESS_RUNDIR/target-root-a")" = "$T/target-root" ] \
    && ok "the link points at the device it was given" \
    || bad "target-root-a points at $(readlink "$SESS_RUNDIR/target-root-a")"
else
  bad "no config written"
fi

CASE="rauc-session: the bus is not activatable"
if grep -qi 'servicedir' "$SESS_RUNDIR/dbus.conf"; then
  bad "the private bus declares an activation directory -- a stock rauc.service could be started onto it"
else
  ok "no servicedir: dbus-daemon cannot activate anything onto this bus"
fi
grep -q -- '--' "$SESS_RUNDIR/dbus.conf" \
  && bad "a double dash appears in the bus config -- dbus' XML parser rejects the whole file" \
  || ok "no double dash in the bus config"

CASE="rauc-session: how the bus pid is obtained"
# The first thing hardware found (Pocket ACE, 2026-08-21). --print-pid=<path> is not the path form
# -- that is --pidfile= -- and dbus-daemon answers a path with `Invalid file descriptor`, so the
# bus never started. The bare form prints the forked daemon's pid on stdout, which is the pid and
# the readiness signal in one.
busargs="$(cat "$SESS_RUNDIR/bus.args" 2>/dev/null)"
printf '%s\n' "$busargs" | grep -q -- '--print-pid=' \
  && bad "--print-pid was given a value; it takes a file descriptor, not a path" \
  || ok "--print-pid is used bare (the pid comes back on stdout)"
printf '%s\n' "$busargs" | grep -qx -- '--fork' \
  && ok "the daemon is forked, so the parent's exit is the readiness signal" \
  || bad "the bus was not started with --fork"

CASE="rauc-session: the two rauc invocations"
svcargs="$(cat "$SESS_RUNDIR/svc.args" 2>/dev/null)"
printf '%s\n' "$svcargs" | grep -qx -- '--override-boot-slot=_external_' \
  && ok "the service is started with --override-boot-slot=_external_" \
  || bad "the service was not put in external mode: $(printf '%s' "$svcargs" | tr '\n' ' ')"
printf '%s\n' "$svcargs" | grep -qx -- "$conf" \
  && ok "the service runs under the synthesized config" \
  || bad "the service was not given the synthesized config"
insargs="$(cat "$SESS_RUNDIR/install.args" 2>/dev/null)"
printf '%s\n' "$insargs" | grep -qx -- '-c' \
  && bad "install was passed -c, which is compiled out with the service enabled -- it reads as if it did something" \
  || ok "install is not passed -c (the service's config is the one that counts)"
printf '%s\n' "$insargs" | grep -qx 'https://example.invalid/b.raucb' \
  && ok "install is handed the bundle" \
  || bad "install did not get the bundle: $(printf '%s' "$insargs" | tr '\n' ' ')"

CASE="rauc-session: the ownership proof"
# THE ASSERTION THAT MATTERS. "Something owns de.pengutronix.rauc" is true of the very failure this
# guards against, so the script matches the owner's pid against the service it started. Break that
# and the install proceeds through a service whose config is unknown.
sess_dir impostor
out="$( STUB_OWNER_PID=999999 sess_run )" \
  && bad "an install went ahead against a bus name owned by another process" \
  || ok "refuses when the name owner is not our service"
printf '%s\n' "$out" | grep -q 'owned by pid 999999' \
  && ok "names the impostor pid" \
  || bad "the refusal does not say who held the name: $out"
[ -f "$SESS_RUNDIR/install.args" ] \
  && bad "it refused but still ran the install" \
  || ok "nothing was installed"
# In bash a variable assignment preceding a FUNCTION call persists after it returns, unlike one
# preceding an external command. Left set, this would quietly poison every later sess_run.
unset STUB_OWNER_PID

CASE="rauc-session: fail-closed on the tools it does not carry"
# The shipped image carries few of these and the installer image is a different root again. A
# missing binary and a missing file are indistinguishable to a caller that does not check -- the
# 2026-08-21 Pocket FIT finding, and the reason these are asserted up front rather than at use.
# Reached through the seams rather than by emptying PATH, which is the same idiom post-install.sh
# documents for $SHA256: an offline suite runs with the host's PATH and cannot make a tool absent,
# so it points the seam at a name that does not exist. Emptying PATH instead breaks the stubs' own
# `#!/usr/bin/env bash` and tests nothing.
for seam in RAUC DBUS_DAEMON GDBUS; do
  rundir="$T/run.miss.$seam"; mkdir -p "$rundir"
  out="$(env PATH="$STUBS:$PATH" STUBDIR="$rundir" NOVADECK_INSTALL_RUN="$rundir" DEVTEST=-e OWN_TIMEOUT=3 \
             KEYRING="$T/keyring.pem" POST_INSTALL="$FRESH" "$seam=novadeck-absent-$seam" \
             "$SESSION" "$T/target-root" b.raucb 2>&1)" \
    && bad "an absent $seam was not noticed" \
    || { printf '%s\n' "$out" | grep -q "novadeck-absent-$seam is not on PATH" \
           && ok "refuses when $seam is absent, and names it" \
           || bad "an absent $seam produced the wrong error: $out"; }
done

CASE="rauc-session: the verification inputs"
sess_dir nokeyring
out="$( SESS_KEYRING="$T/nope.pem" sess_run )" \
  && bad "ran with no keyring -- nothing would have been verified" \
  || { printf '%s\n' "$out" | grep -q 'keyring' && ok "refuses without a readable keyring" \
       || bad "the wrong error for a missing keyring: $out"; }
sess_dir nohandler
out="$( SESS_POST="$T/nope.sh" sess_run )" \
  && bad "ran with no post-install handler -- the slot would be left with the wrong fsid and no /var" \
  || { printf '%s\n' "$out" | grep -q 'post-install handler' && ok "refuses without the post-install handler" \
       || bad "the wrong error for a missing handler: $out"; }
unset SESS_KEYRING SESS_POST

# --- 13. install/post-install-fresh.sh — the slot half (Phase 4a) --------------------------------
# RAUC_TARGET_SLOTS IS AN ITERATOR OF INTEGERS, not of slot names: install.c appends "%i" (slotcnt)
# and reference.rst:1745 spells the `eval RAUC_SLOT_DEVICE_${i}` idiom. A handler that matched it
# against a slot NAME would compare two things that are never equal, so its check would silently
# never fire -- which is why the case below uses an index that is deliberately not 0 or 1.
FRESH_STUBS="$T/fstubs"; mkdir -p "$FRESH_STUBS"
for t in btrfstune btrfs mkfs.ext4 tar mount umount rsync; do
  cat >"$FRESH_STUBS/$t" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$t" "\$*" >>"\$STUBDIR/calls"
case "$t" in
  mount) for a in "\$@"; do case "\$a" in -*) ;; *) last="\$a" ;; esac; done; mkdir -p "\$last" ;;
esac
exit 0
EOF
  chmod +x "$FRESH_STUBS/$t"
done

# Set by the caller, for the same subshell reason sess_dir is. The mount stub creates a mountpoint
# but cannot conjure its contents, so the seed is laid down here -- under $MNT, standing in for the
# root RAUC just wrote, which is the whole point of the case that looks for it there.
fresh_dir() {
  FRESH_RUNDIR="$T/fresh.$1"; rm -rf "$FRESH_RUNDIR"
  mkdir -p "$FRESH_RUNDIR/root/$(dirname "$FRESH_SEED_REL")"
  : >"$FRESH_RUNDIR/root/$FRESH_SEED_REL"
}

fresh_run() {  # runs post-install-fresh.sh in the sandbox fresh_dir last named
  local rundir="$FRESH_RUNDIR"
  env PATH="$FRESH_STUBS:$PATH" STUBDIR="$rundir" \
      MNT="$rundir/root" VARMNT="$rundir/var" DEVTEST=-e \
      NOVADECK_SLOTWRITE="$LIB" VAR_SEED_REL="$FRESH_SEED_REL" \
      "$@" "$FRESH" 2>&1
}
# The seed the handler must find inside the root it just wrote. Pre-created under the mount stub's
# directory because the stub does not really mount anything; what is being asserted is that the
# handler looks for it THERE -- in the new root -- and not on the installer medium.
FRESH_SEED_REL=usr/lib/novadeck/var-seed.tar.zst

CASE="post-install-fresh: refusals before anything destructive"
fresh_dir novar
out="$( fresh_run env RAUC_TARGET_SLOTS=1 RAUC_SLOT_DEVICE_1="$T/target-root" )" \
  && bad "ran without being told where /var goes" \
  || { printf '%s\n' "$out" | grep -q 'NOVADECK_TARGET_VAR_A' \
         && ok "refuses when the spine did not name the /var partition" \
         || bad "the wrong error: $out"; }
[ -s "$FRESH_RUNDIR/calls" ] \
  && bad "it refused but had already called $(head -1 "$FRESH_RUNDIR/calls")" \
  || ok "nothing was called before the refusal"

fresh_dir noslots
out="$( fresh_run env NOVADECK_TARGET_VAR_A="$T/target-var" )" \
  && bad "ran outside a rauc transaction" \
  || { printf '%s\n' "$out" | grep -q 'RAUC_TARGET_SLOTS' \
         && ok "refuses when not run by rauc" || bad "the wrong error: $out"; }
: >"$T/target-var"

fresh_dir twoslots
out="$( fresh_run env NOVADECK_TARGET_VAR_A="$T/target-var" RAUC_TARGET_SLOTS='1 2' \
                     RAUC_SLOT_DEVICE_1="$T/target-root" RAUC_SLOT_DEVICE_2="$T/target-root" )" \
  && bad "accepted two target slots -- the config declares one and this handler assumes it" \
  || ok "refuses when rauc reports more than one target slot"

CASE="post-install-fresh: the integer indirection"
mkdir -p "$T/fresh-seed-src"
fresh_dir slot7
out="$( fresh_run env NOVADECK_TARGET_VAR_A="$T/target-var" RAUC_TARGET_SLOTS=7 \
                     RAUC_SLOT_DEVICE_7="$T/target-root" )"
rc=$?
[ $rc -eq 0 ] && ok "resolves the device through RAUC_SLOT_DEVICE_<n> for a non-obvious n" \
              || bad "slot 7 was not resolved: $out"

CASE="post-install-fresh: the order is load-bearing"
calls="$(cat "$FRESH_RUNDIR/calls" 2>/dev/null || true)"
tune_line=$(printf '%s\n' "$calls" | grep -n '^btrfstune ' | head -1 | cut -d: -f1)
mount_line=$(printf '%s\n' "$calls" | grep -n '^mount ' | head -1 | cut -d: -f1)
if [ -n "$tune_line" ] && [ -n "$mount_line" ] && [ "$tune_line" -lt "$mount_line" ]; then
  ok "the fsid is re-randomised BEFORE anything mounts the target"
else
  bad "btrfstune did not run before the first mount (tune=$tune_line mount=$mount_line)"
fi
printf '%s\n' "$calls" | grep -q '^btrfs filesystem label .* novadeck-root-A' \
  && ok "labels the slot novadeck-root-A" \
  || bad "the slot was not labelled: $calls"
printf '%s\n' "$calls" | grep -q '^mkfs.ext4 .*novadeck-var-A' \
  && ok "reformats the slot's /var as novadeck-var-A" \
  || bad "/var was not reformatted: $calls"
printf '%s\n' "$calls" | grep -q "^tar .*$FRESH_SEED_REL" \
  && ok "seeds /var from the tarball inside the root RAUC just wrote, not from the installer medium" \
  || bad "the /var seed did not come from the new root: $calls"

# --- 14. refresh_esp_stage1 writes bootaa64.efi LAST (Phase 4c) ----------------------------------
# THE ORDER INSIDE THIS FUNCTION IS A HARDWARE FINDING, not a style. ABL's test is content-based:
# it chainloads /EFI/BOOT/bootaa64.efi off an internal ESP if that file is there, and an internal
# ESP that exists but is EMPTY does not divert it at all (measured, Pocket ACE 2026-08-21). So on an
# internal install this one copy is the byte that flips the device off the installer medium, and
# every interruption before it leaves a device that still boots the card and can simply be re-run.
# Write it first and an install interrupted a second later boots internal steamcl with no
# steamcl-version, no font and no restricted flag beside it -- the files steamcl resolves relative
# to the chainloader. Nothing else in this suite would notice the difference, which is why it is
# asserted directly against write order rather than against the resulting directory.
CASE="refresh_esp_stage1: bootaa64.efi is the last write"
espt="$T/esp-order"; bootd="$T/esp-order-boot"
mkdir -p "$espt" "$bootd/fonts"
printf 'steamcl\n'      >"$bootd/steamcl.efi"
printf 'version\n'      >"$bootd/steamcl-version"
printf 'font\n'         >"$bootd/fonts/default.pf2"
# The observation seam: refresh_if_diff is what actually copies, so wrapping it records the order
# the primitive asked for rather than the order the filesystem happened to produce.
ESP_ORDER="$T/esp-order.log"; : >"$ESP_ORDER"
eval "orig_refresh_if_diff() $(declare -f refresh_if_diff | tail -n +2)"
refresh_if_diff() { printf '%s\n' "${2##*/}" >>"$ESP_ORDER"; orig_refresh_if_diff "$@"; }
refresh_esp_stage1 "$espt" "$bootd"
refresh_if_diff() { orig_refresh_if_diff "$@"; }
[ "$(tail -1 "$ESP_ORDER")" = bootaa64.efi ] \
  && ok "bootaa64.efi is written last (an interrupted install still boots the medium)" \
  || bad "bootaa64.efi is not the last write: $(tr '\n' ' ' <"$ESP_ORDER")"
grep -qx steamcl-version "$ESP_ORDER" && grep -qx default.pf2 "$ESP_ORDER" \
  && ok "the companions steamcl resolves relative to itself are written before it" \
  || bad "a companion file was not written: $(tr '\n' ' ' <"$ESP_ORDER")"
[ -f "$espt/EFI/BOOT/steamcl-restricted" ] \
  && ok "the restricted flag is still written" \
  || bad "steamcl-restricted is missing"

# --- 15. part_uuid / part_dev — the index-to-device rule (Phase 4c) ------------------------------
# The rule every write in the install depends on: an index becomes a device path through the
# PARTUUID sgdisk reports, never through `${disk}${n}` or `${disk}p${n}`. The `p` infix is what this
# fleet cannot test -- every board is UFS -- so a bug of that shape would first appear on a
# customer's eMMC device, mid-install, on a disk whose userdata is already gone. Both halves of the
# installer (carve.sh and the spine) call THIS function, so a regression here fails once, loudly.
CASE="part_dev: by partuuid, lower-cased, never name arithmetic"
sgstub="$T/sgstub"; mkdir -p "$sgstub"
cat >"$sgstub/sgdisk" <<'EOF'
#!/usr/bin/env bash
# Prints the GUID in UPPER case, as the real tool does -- lower-casing is the caller's job and the
# thing worth asserting.
[ "${1:-}" = -i ] || exit 1
printf 'Partition unique GUID: 6F2A1B3C-4D5E-6789-ABCD-EF0123456789\n'
EOF
chmod +x "$sgstub/sgdisk"
uuid="$(PATH="$sgstub:$PATH" part_uuid /dev/anything 12)"
[ "$uuid" = 6f2a1b3c-4d5e-6789-abcd-ef0123456789 ] \
  && ok "part_uuid lower-cases sgdisk's upper-case GUID (steamcl string-compares these)" \
  || bad "part_uuid returned '$uuid'"
if PATH="$sgstub:$PATH" part_dev "$T/not-a-block-device" 12 >/dev/null 2>&1; then
  bad "part_dev answered for something that is not a block device -- a caller would open a path that names nothing"
else
  ok "part_dev refuses anything that is not a block device rather than inventing a node"
fi
# The negative that matters: no output of this function may ever contain the disk name.
out="$(PATH="$sgstub:$PATH" part_uuid /dev/mmcblk0 12)"
case "$out" in *mmcblk*) bad "part_uuid leaked the disk name into its answer: $out" ;;
  *) ok "the answer names no disk, so the p-infix spelling cannot enter it" ;; esac

# --- 16. images/lib-homestage.sh — one /home layout, two writers --------------------------------
# make-sdcard.sh builds this tree into a card image at build time and novadeck-install builds it
# onto an internal disk on the device. The drift is SILENT in the worst way: a missing
# ~/.steam/sdk64 does not stop Steam starting, it makes an x86 title's SteamAPI_Init() fail at
# launch, on that medium only. So the layout is asserted here and both writers call the same code.
HOMESTAGE="$ROOT/images/lib-homestage.sh"
[ -r "$HOMESTAGE" ] || { echo "missing input: $HOMESTAGE" >&2; exit 1; }
CASE="lib-homestage: the deck home layout"
# shellcheck source=/dev/null
( set -e
  DECK_UID="$(id -u)"; DECK_GID="$(id -g)"   # unprivileged: chown to ourselves is a no-op that still runs
  . "$HOMESTAGE"
  seeddir="$T/seed"; mkdir -p "$seeddir/linuxarm64"; : >"$seeddir/steam.sh"
  hs="$T/homestage-dir"; mkdir -p "$hs"
  stage_deck_home "$seeddir" "$hs"
) >/dev/null 2>&1 && ok "stages from a directory (make-sdcard.sh's caller)" \
  || bad "staging from a directory failed"

# The tarball arm is the INSTALLER's, and it is not a variation: on the device there is no staged
# tree and no tmpfs with room for one, so the ~1 GB seed is unpacked straight into the mounted
# /home. A helper that only took a directory would force a second copy that cannot fit.
CASE="lib-homestage: the tarball arm (the installer's)"
( set -e
  DECK_UID="$(id -u)"; DECK_GID="$(id -g)"
  . "$HOMESTAGE"
  seeddir="$T/seed2"; mkdir -p "$seeddir/linuxarm64"; : >"$seeddir/steam.sh"
  tar -cf "$T/seed.tar" -C "$seeddir" .
  hs="$T/homestage-tar"; mkdir -p "$hs"
  stage_deck_home "$T/seed.tar" "$hs"
) >/dev/null 2>&1 && ok "stages from a published tarball (novadeck-install's caller)" \
  || bad "staging from a tarball failed"

CASE="lib-homestage: both arms produce the same tree"
a="$(cd "$T/homestage-dir" 2>/dev/null && find . | sort)" || a=""
b="$(cd "$T/homestage-tar" 2>/dev/null && find . | sort)" || b=""
[ -n "$a" ] && [ "$a" = "$b" ] \
  && ok "a directory seed and a tarball seed give byte-identical layouts" \
  || bad "the two arms disagree:\n$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") || true)"

CASE="lib-homestage: the compat symlinks Steam resolves at game launch"
for l in .steam/steam .steam/root .steam/sdkarm64 .steam/sdk32 .steam/sdk64 .steam/bin32 .steam/bin64; do
  [ -L "$T/homestage-dir/deck/$l" ] \
    && ok "~/$l exists" \
    || bad "~/$l is missing -- an x86 title's SteamAPI_Init() fails at launch and nothing else does"
done
CASE="lib-homestage: the links are HOME-relative"
tgt="$(readlink "$T/homestage-dir/deck/.steam/sdk64")"
case "$tgt" in
  /*) bad "sdk64 points at an absolute path ($tgt) -- right in the staging dir, wrong at boot" ;;
  *)  ok "sdk64 -> $tgt, relative, so it is right under a mountpoint and on the booted device" ;;
esac
CASE="lib-homestage: a missing seed is fatal, not silent"
( DECK_UID="$(id -u)"; DECK_GID="$(id -g)"; . "$HOMESTAGE"; \
  stage_deck_home "$T/no-such-seed" "$T/homestage-none" ) >/dev/null 2>&1 \
  && bad "staged a home from a seed that does not exist" \
  || ok "refuses a seed that is neither a directory nor a file"

# --- 17. install/novadeck-install — the spine (Phase 4c) ----------------------------------------
# WHAT IS AT RISK. Every other file in this install has a narrow job with its own suite; this one's
# entire content is an ORDER, and the two things the order buys cannot be checked anywhere else:
#
#   NOTHING DESTRUCTIVE HAPPENS BEFORE THE CONFIRM. A bundle that will not verify, a seed that does
#   not match its pin, a missing mkfs -- each of those is free to discover before the carve and
#   costs the user their Android data to discover after it. There is no way back: userdata cannot
#   be restored, by us or by them.
#
#   bootaa64.efi IS THE LAST BYTE. ABL's test is content-based, so that copy is what flips the
#   device off the installer medium. Everything before it is re-runnable; after it, recovery needs
#   ABL's force-external.
#
# Neither can be checked on hardware without doing the destructive thing first, so they are checked
# here, against the real script, with every external command stubbed and recording its arguments.
SPINE="$ROOT/install/novadeck-install"
CONFIRM_TTY="$ROOT/install/confirm-tty"
for f in "$SPINE" "$CONFIRM_TTY"; do
  [ -x "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# The sandbox. One directory per case, so a failure leaves that run's evidence alone.
spine_dir() {  # <name>
  local i i12
  SP="$T/spine.$1"; rm -rf "$SP"
  SP_STUBS="$SP/bin"; SP_RUN="$SP/run"; SP_PART="$SP/by-partuuid"
  mkdir -p "$SP_STUBS" "$SP_RUN" "$SP_PART" "$SP/disks"
  : >"$SP/calls"
  SP_DISK="$SP/disks/sda"; : >"$SP_DISK"

  # --- the components, stubbed at their own boundary -------------------------------------------
  # select-target.sh emits the geometry the real one does. Two fixtures below drive it with
  # different numbers, which is how the derived-text assertions get their teeth.
  cat >"$SP_STUBS/select-target.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "select-target.sh $*" >>"$SP_CALLS"
printf 'TARGET=%s\nMODE=%s\nSECTOR=%s\nUD_INDEX=%s\nUD_START=%s\nUD_END=%s\nUD_TYPE=%s\nCEIL=%s\n' \
  "$SP_SEL_TARGET" "$SP_SEL_MODE" "$SP_SEL_SECTOR" "$SP_SEL_UDINDEX" \
  "$SP_SEL_UDSTART" "$SP_SEL_UDEND" \
  "0FC63DAF-8483-4772-8E79-3D69D8477DE4" "$SP_SEL_CEIL"
EOF
  # carve.sh prints the name=index map on stdout, at INDICES THAT ARE NOT 1..8 and not contiguous:
  # the Pocket-FIT-shaped case, where our ESP fills a hole at p3 and the rest land at 7..13. A spine
  # that quietly assumed row order would pass against 1..8 and destroy a real board.
  cat >"$SP_STUBS/carve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "carve.sh $*" >>"$SP_CALLS"
# `plan` writes nothing and answers the two facts the consent screen cannot derive. $SP_PLAN_RC is
# how a case makes it unavailable, which must degrade to `unknown` on the screen and never to a
# number the spine invented -- the 0 GiB that shipped was exactly such a number.
if [ "${1:-}" = plan ]; then
  [ "${SP_PLAN_RC:-0}" = 0 ] || exit "$SP_PLAN_RC"
  printf 'CEIL=%s\nNEW_END=%s\nNOVADECK_MIB=%s\nNOVADECK_GIB=%s\nREPLACES_OURS=%s\n' \
    499999999 100000000 "$(( ${SP_PLAN_GIB:-72} * 1024 ))" "${SP_PLAN_GIB:-72}" \
    "${SP_PLAN_REPLACES:-0}"
  exit 0
fi
[ "${SP_CARVE_RC:-0}" = 0 ] || exit "$SP_CARVE_RC"
cat <<MAP
NOVADECK-ESP=3
novadeck-efi-A=7
novadeck-efi-B=8
novadeck-root-A=9
novadeck-root-B=10
novadeck-var-A=11
novadeck-var-B=12
novadeck-home=13
MAP
EOF
  # rauc-session.sh answers to two shapes and must be told apart by argv, because telling them apart
  # is what the spine's ordering depends on: --info is the pre-carve verify and the two-argument
  # form is the ~4 GB stream.
  cat >"$SP_STUBS/rauc-session.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --info ]; then
  printf '%s\n' "rauc-session --info $2" >>"$SP_CALLS"
  exit "${SP_INFO_RC:-0}"
fi
printf '%s\n' "rauc-session install $1 $2 var=${NOVADECK_TARGET_VAR_A:-<unset>}" >>"$SP_CALLS"
exit "${SP_RAUC_RC:-0}"
EOF
  # sgdisk answers -i with a per-index GUID in UPPER case, so the lower-casing in part_uuid is
  # exercised end to end rather than only in its own unit case.
  cat >"$SP_STUBS/sgdisk" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -i ]; then
  printf 'Partition unique GUID: AAAAAAAA-BBBB-CCCC-DDDD-%012d\n' "$2"
  exit 0
fi
if [ "${1:-}" = -p ]; then printf '  13  100  200  8.0 GiB  novadeck-home\n'; exit 0; fi
exit 0
EOF
  # blkid answers ONE question -- does this partition hold a filesystem -- and $SP_HOME_FSTYPE is
  # how a case says no. It cannot be a silent member of the recorder loop below: those exit 0 with
  # no output, which this predicate reads as "no filesystem", and every keep-/home case would then
  # refuse. It also cannot be left to the host's real blkid, which an offline suite inherits on
  # PATH and which would be asked about a path under $T that is not a block device at all.
  cat >"$SP_STUBS/blkid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "blkid $*" >>"$SP_CALLS"
[ -n "${SP_HOME_FSTYPE:-}" ] || exit 2
printf '%s\n' "$SP_HOME_FSTYPE"
EOF
  # Every filesystem creation and every mount, recorded. The mount stub deliberately does NOT
  # populate anything: the mountpoints are pre-seeded below, so the real primitives write into real
  # directories and what they produce can be inspected afterwards.
  for i in mkfs.vfat mkfs.ext4 mkfs.btrfs btrfstune btrfs mount umount tar rauc dbus-daemon \
           gdbus partprobe udevadm sfdisk curl df; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"$SP_CALLS"\nexit 0\n' "$i" >"$SP_STUBS/$i"
  done
  # The one stub that must produce a file, because the spine asserts the file afterwards.
  cat >"$SP_STUBS/steamos-bootconf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "steamos-bootconf $*" >>"$SP_CALLS"
conf=""; img=""
while [ $# -gt 0 ]; do
  case "$1" in --conf-dir) conf="$2"; shift 2 ;; --image) img="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$conf" ] && [ -n "$img" ] && { mkdir -p "$conf"; printf 'title: novadeck %s\n' "$img" >"$conf/$img.conf"; }
exit 0
EOF
  chmod +x "$SP_STUBS"/*

  # The freshly written root, as it will look mounted read-only: the boot software the efi and ESP
  # steps take their files from, plus the bootconf binary. Pre-seeded rather than produced by the
  # mount stub, so the real primitives copy real bytes.
  mkdir -p "$SP_RUN/root-a/usr/lib/novadeck/boot/fonts" "$SP_RUN/root-a/usr/bin"
  for i in steamcl.efi steamcl-version grubaa64.efi grub-a.cfg grub-b.cfg grubenv; do
    printf '%s\n' "$i" >"$SP_RUN/root-a/usr/lib/novadeck/boot/$i"
  done
  printf 'font\n' >"$SP_RUN/root-a/usr/lib/novadeck/boot/fonts/default.pf2"
  printf 'font\n' >"$SP_RUN/root-a/usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
  cp "$SP_STUBS/steamos-bootconf" "$SP_RUN/root-a/usr/bin/steamos-bootconf"

  # The partition "devices". DEVTEST is -e in the sandbox, so a regular file stands in for a block
  # device; PARTUUID_DIR is what points part_dev at them instead of /dev.
  for i in 3 7 8 9 10 11 12 13; do
    printf -v i12 '%012d' "$i"
    : >"$SP_PART/aaaaaaaa-bbbb-cccc-dddd-$i12"
  done
  SP_KEYRING="$SP/keyring.pem"; : >"$SP_KEYRING"
  SP_SEED="$SP/steam-seed.tar"
  mkdir -p "$SP/seedsrc/linuxarm64"; : >"$SP/seedsrc/steam.sh"
  tar -cf "$SP_SEED" -C "$SP/seedsrc" .
  SP_PIN="$SP/seed.sha256"; sha256sum <"$SP_SEED" | awk '{print $1}' >"$SP_PIN"

  # The default consent program: it echoes back the sequence it was told to display, i.e. a user who
  # read the screen. Every refusal case below replaces it.
  SP_FACTS="$SP/facts.seen"
  SP_CONFIRM="$SP/confirm"
  cat >"$SP_CONFIRM" <<'EOF'
#!/usr/bin/env bash
seq=""; facts=""
while [ $# -gt 0 ]; do
  case "$1" in --sequence) seq="$2"; shift 2 ;; --facts) facts="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "confirm $seq" >>"$SP_CALLS"
[ -n "$facts" ] && cp "$facts" "$SP_FACTS" 2>/dev/null
printf '%s\n' "$seq"
EOF
  chmod +x "$SP_CONFIRM"

  SP_SEL_TARGET="$SP_DISK"; SP_SEL_MODE=fresh
  SP_SEL_SECTOR=512; SP_SEL_UDINDEX=11; SP_SEL_UDSTART=2097152
  SP_SEL_UDEND=204800000; SP_SEL_CEIL=500000000
  SP_INFO_RC=0; SP_RAUC_RC=0; SP_CARVE_RC=0
  # The default is a /home that EXISTS, so only the case that clears it exercises the refusal.
  SP_HOME_FSTYPE=ext4
  SP_PLAN_RC=0; SP_PLAN_GIB=72; SP_PLAN_REPLACES=0
}

spine_run() {  # extra args passed through to the spine
  env PATH="$SP_STUBS:$PATH" \
      SP_CALLS="$SP/calls" SP_FACTS="$SP_FACTS" \
      SP_SEL_TARGET="$SP_SEL_TARGET" SP_SEL_MODE="$SP_SEL_MODE" SP_SEL_SECTOR="$SP_SEL_SECTOR" \
      SP_SEL_UDINDEX="$SP_SEL_UDINDEX" SP_SEL_UDSTART="$SP_SEL_UDSTART" \
      SP_SEL_UDEND="$SP_SEL_UDEND" SP_SEL_CEIL="$SP_SEL_CEIL" \
      SP_INFO_RC="$SP_INFO_RC" SP_RAUC_RC="$SP_RAUC_RC" SP_CARVE_RC="$SP_CARVE_RC" \
      SP_HOME_FSTYPE="$SP_HOME_FSTYPE" \
      SP_PLAN_RC="$SP_PLAN_RC" SP_PLAN_GIB="$SP_PLAN_GIB" SP_PLAN_REPLACES="$SP_PLAN_REPLACES" \
      NOVADECK_INSTALL_RUN="$SP_RUN" DEVTEST=-e REQUIRE_ROOT=0 FAT_ASSERT=0 \
      PARTUUID_DIR="$SP_PART" DISKTEST=-e \
      DECK_UID="$(id -u)" DECK_GID="$(id -g)" \
      KEYRING="$SP_KEYRING" NOVADECK_SEED_PIN="$SP_PIN" SGDISK="${SP_SGDISK:-sgdisk}" \
      NOVADECK_CONFIRM="${SP_CONFIRM_OVERRIDE:-$SP_CONFIRM}" \
      NOVADECK_SELECT_TARGET="$SP_STUBS/select-target.sh" \
      NOVADECK_CARVE="$SP_STUBS/carve.sh" \
      NOVADECK_RAUC_SESSION="$SP_STUBS/rauc-session.sh" \
      NOVADECK_SLOTWRITE="$LIB" \
      NOVADECK_HOMESTAGE="$ROOT/images/lib-homestage.sh" \
      "$SPINE" --bundle https://example.invalid/b.raucb --home-seed "$SP_SEED" \
      --userdata-gib 16 "$@" 2>&1
}

# The order of two recorded calls, by first occurrence. Returns non-zero if either never happened,
# which is an answer in itself for most of the cases below.
# DID THE DISK GET WRITTEN? Not the same question as "was carve.sh called", since 2026-08-21:
# `carve.sh plan` is a read-only query the spine makes BEFORE drawing the consent screen, because
# the screen has to quote the space NovaDeck ends up with and only carve.sh can compute it. Every
# "nothing was written" assertion below therefore has to name the destructive invocations, or it
# fires on a query and the four ordering guards go red for the wrong reason. They did, once.
carve_wrote() { grep -qE 'carve\.sh (fresh|reinstall|uninstall) ' "$SP/calls"; }

sp_before() {  # <pattern-a> <pattern-b>
  local a b
  a=$(grep -n -- "$1" "$SP/calls" | head -1 | cut -d: -f1)
  b=$(grep -n -- "$2" "$SP/calls" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

CASE="spine: the happy path"
spine_dir happy
out="$(spine_run)" && ok "exits 0 with every component stubbed" || bad "failed: $out"

CASE="spine: the order, and what each boundary buys"
sp_before 'rauc-session --info' 'carve.sh fresh' \
  && ok "the bundle is verified BEFORE the carve (a bundle that will not verify must not cost the user Android)" \
  || bad "the carve ran before the bundle was verified"
sp_before 'confirm ' 'carve.sh fresh' \
  && ok "consent is taken BEFORE the first write" \
  || bad "the carve ran before consent was taken"
sp_before 'carve.sh fresh' 'mkfs.vfat' \
  && ok "the partitions exist before anything is formatted" \
  || bad "a filesystem was created before the carve"
sp_before 'mkfs.vfat' 'rauc-session install' \
  && ok "the filesystems exist before the root is streamed" \
  || bad "the root was streamed before the filesystems existed"
sp_before 'rauc-session install' 'steamos-bootconf' \
  && ok "the boot state is armed after there is a root to boot" \
  || bad "A.conf was armed before the root existed"

CASE="spine: bootaa64.efi is the last byte written"
# Asserted against the ESP the run actually produced: the file exists, and every other artifact the
# install writes was in place before it. Its position INSIDE refresh_esp_stage1 is case 14's; this
# is the same property one level up, where the ordering of the whole install decides it.
esp="$SP_RUN/esp"
[ -f "$esp/EFI/BOOT/bootaa64.efi" ] \
  && ok "the ESP carries the stage-1 loader ABL chainloads" \
  || bad "no bootaa64.efi on the ESP -- the device would not boot internally at all"
[ -f "$esp/EFI/steamos/grubenv" ] && [ -f "$esp/SteamOS/conf/A.conf" ] \
  && ok "the grubenv and A.conf were in place before it" \
  || bad "the ESP is missing the grubenv or A.conf"
[ ! -e "$esp/SteamOS/conf/B.conf" ] \
  && ok "NO B.conf -- steamcl requires a config for an image before that partition enters found[], so slot B is not a candidate at all" \
  || bad "a B.conf exists; a never-booted B reports boot-attempts 0 and wins steamcl's alt pick"

CASE="spine: the efi partitions carry the map of THIS disk"
for slot in a b; do
  pe="$SP_RUN/efi-$slot/EFI/steamos/parts.env"
  if [ -f "$pe" ]; then
    grep -aq 'nd_esp=3' "$pe" && grep -aq 'nd_home=13' "$pe" \
      && ok "efi-$slot parts.env names the indices the carve reported, not 1..8" \
      || bad "efi-$slot parts.env does not carry the carve's indices"
  else
    bad "efi-$slot has no parts.env -- stage 2 cannot address anything on this disk"
  fi
  [ -f "$SP_RUN/efi-$slot/EFI/steamos/grubaa64.efi" ] \
    && ok "efi-$slot carries stage 2 out of the root that was just written" \
    || bad "efi-$slot has no stage-2 GRUB"
done

CASE="spine: partsets are minted from the new GPT, and only self/other differ"
a_self="$(cat "$SP_RUN/efi-a/SteamOS/partsets/self" 2>/dev/null || true)"
b_self="$(cat "$SP_RUN/efi-b/SteamOS/partsets/self" 2>/dev/null || true)"
[ -n "$a_self" ] && [ "$a_self" != "$b_self" ] \
  && ok "efi-a and efi-b resolve to different images (steamcl matches the booted uuid against these)" \
  || bad "the two partsets/self are the same or missing"
if printf '%s' "$a_self" | grep -q '[A-Z]'; then
  bad "the partset uuid is not lower-cased -- steamcl string-compares it and would match nothing"
else
  ok "the partset uuid is lower-cased"
fi

CASE="spine: var-a is the handler's and var-b is never touched"
grep -q 'rauc-session install .* var=' "$SP/calls" \
  && ok "the spine names the /var partition for the handler (it cannot derive it: the config declares one slot)" \
  || bad "NOVADECK_TARGET_VAR_A was not passed to the session"
grep -q "var=$SP_PART/aaaaaaaa-bbbb-cccc-dddd-000000000011" "$SP/calls" \
  && ok "and it is var-A's partuuid path, resolved from the carve's index" \
  || bad "the var device is not the resolved partuuid"
if grep -q 'mkfs.ext4 .*000000000012' "$SP/calls"; then
  bad "var-B was formatted -- a release install leaves B empty, matching the card"
else
  ok "var-B is untouched, matching the release card's empty-B shape"
fi
if grep -q 'mkfs.ext4 .*000000000011' "$SP/calls"; then
  bad "the spine formatted var-A; seed_var reformats AND populates it as one operation, and a var that is mkfs'd but not populated is a slot that does not boot"
else
  ok "the spine does not format var-A -- the handler owns the slot, the spine owns the disk"
fi

CASE="spine: every device it opens is addressed by partuuid"
# The rule the whole install depends on. Concatenation gives ${disk}${n} on one kind of disk and
# ${disk}p${n} on the other, no board in the fleet is eMMC, and a bug of that shape would first
# surface on a customer's device mid-install. So: no recorded argument may be the disk path with
# digits or a p stuck on the end.
if grep -Eq "$SP_DISK[0-9p]" "$SP/calls"; then
  bad "the spine built a device name by concatenation"
else
  ok "no call names the disk with an index appended"
fi
grep -q "mkfs.vfat .*$SP_PART/" "$SP/calls" \
  && ok "the filesystems were created on by-partuuid paths" \
  || bad "a filesystem was created on something that is not a partuuid path"

# --- the consent gate ---------------------------------------------------------------------------
CASE="spine: it refuses without a completed confirm"
spine_dir noconsent
SP_CONFIRM_OVERRIDE=/bin/true
out="$(spine_run)" && bad "installed with /bin/true as the consent program" \
  || ok "a program that exits 0 and says nothing does NOT satisfy the gate"
if carve_wrote; then
  bad "the carve ran anyway -- the user's Android data is gone and consent was never given"
else
  ok "and nothing was written"
fi
unset SP_CONFIRM_OVERRIDE

CASE="spine: a wrong answer re-randomises rather than advancing"
spine_dir wrong
SP_CONFIRM_OVERRIDE="$T/confirm-wrong"
cat >"$SP_CONFIRM_OVERRIDE" <<'EOF'
#!/usr/bin/env bash
seq=""
while [ $# -gt 0 ]; do case "$1" in --sequence) seq="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "confirm $seq" >>"$SP_CALLS"
printf 'ZZZZ\n'          # always wrong, and never one of the permutations
EOF
chmod +x "$SP_CONFIRM_OVERRIDE"
out="$(spine_run)" && bad "a wrong sequence installed the device" || ok "a wrong sequence refuses"
tries=$(grep -c '^confirm ' "$SP/calls")
[ "$tries" -ge 2 ] \
  && ok "it asked again ($tries attempts) rather than locking out on the first slip -- this is a recovery tool" \
  || bad "it gave up after one attempt"
seqs=$(grep '^confirm ' "$SP/calls" | sort -u | wc -l)
[ "$seqs" -ge 2 ] \
  && ok "the sequence is re-randomised between attempts, so a mistake cannot be brute-forced by repetition" \
  || bad "the same sequence was shown every time"
if carve_wrote; then bad "the carve ran after consent was refused"; else ok "nothing was written"; fi

# Same spine directory, so $SP/calls still holds the sequences that were asked for above.
CASE="spine: the buttons are named by POSITION, not by the letter printed on them"
# The face cluster's silkscreen is not the same across the boards this installer is unified over --
# `A` is EAST on the AYANEO Pocket ACE and SOUTH on the Pocket S2. A sequence carrying `A` therefore
# names a different physical button per device, on the one screen where a misread erases an Android
# install. This asserts the alphabet the spine actually emits, not what a comment says it emits.
asked=$(grep '^confirm ' "$SP/calls" | awk '{print $2}')
[ -n "$asked" ] || bad "no sequence was recorded to check"
if printf '%s\n' "$asked" | grep -qvE '^[NESW]{4}$'; then
  bad "a sequence used something other than N/E/S/W: $(printf '%s' "$asked" | tr '\n' ' ')"
else
  ok "every sequence is four cardinal points -- no A/B/X/Y reaches a screen"
fi
if printf '%s\n' "$asked" | while read -r s; do
     [ "$(printf '%s' "$s" | grep -o . | sort | tr -d '\n')" = ENSW ] || exit 1
   done; then
  ok "and each one is a permutation of all four, so no button is asked for twice"
else
  bad "a sequence repeated or dropped a button"
fi
unset SP_CONFIRM_OVERRIDE

CASE="spine: no variable and no file on the medium can pre-satisfy the gate"
# The medium legitimately carries wifi.conf, so a "drop a file to configure it" idiom already exists
# here. Consent must never join it. This drives the spine with every plausible bypass set at once
# and a consent program that refuses, and requires the refusal to stand.
spine_dir bypass
SP_CONFIRM_OVERRIDE=/bin/true
printf 'yes\n' >"$SP_RUN/consent.txt"
printf 'yes\n' >"$SP/consent.txt"
export NOVADECK_CONSENT=1 NOVADECK_YES=1 NOVADECK_ASSUME_YES=1 NOVADECK_FORCE=1 \
       NOVADECK_INSTALL_CONFIRMED=1 CONFIRMED=1 ASSUME_YES=1 FORCE=1 YES=1
out="$(spine_run)" && bad "one of the bypass variables satisfied the gate" \
  || ok "none of NOVADECK_CONSENT/YES/ASSUME_YES/FORCE/CONFIRMED means consent"
unset NOVADECK_CONSENT NOVADECK_YES NOVADECK_ASSUME_YES NOVADECK_FORCE \
      NOVADECK_INSTALL_CONFIRMED CONFIRMED ASSUME_YES FORCE YES
if carve_wrote; then bad "the carve ran"; else ok "and nothing was written"; fi
# Comments stripped first: the spine EXPLAINS the ban at length ("no consent.txt, no --yes"), and
# an assertion that could not tell the prohibition from the thing prohibited would fail on its own
# documentation and then be deleted.
if sed 's/[[:space:]]*#.*$//' "$SPINE" | grep -qE '(--yes|--assume-yes|--force|consent\.txt)'; then
  bad "the spine names a bypass flag or a consent file"
else
  ok "the spine contains no --yes, no --force and no consent.txt"
fi
unset SP_CONFIRM_OVERRIDE

CASE="spine: the consent screen is DERIVED, never a fixed string"
spine_dir derived1
SP_SEL_UDSTART=2097152; SP_SEL_UDEND=204800000
out="$(spine_run)" || bad "run failed: $out"
gib_small="$(sed -n 's/^UD_GIB_NOW=//p' "$SP_FACTS" 2>/dev/null || true)"
spine_dir derived2
SP_SEL_UDSTART=2097152; SP_SEL_UDEND=838860800    # a much larger userdata
out="$(spine_run)" || bad "run failed: $out"
gib_big="$(sed -n 's/^UD_GIB_NOW=//p' "$SP_FACTS" 2>/dev/null || true)"
facts_wipe="$(cat "$SP_FACTS" 2>/dev/null || true)"
if [ -n "$gib_small" ] && [ -n "$gib_big" ] && [ "$gib_small" != "$gib_big" ]; then
  ok "two disks quote two different userdata sizes ($gib_small GiB vs $gib_big GiB) -- a fixed 'this will erase your data, continue?' does not discharge the obligation here"
else
  bad "the quoted size did not change with the disk"
fi

CASE="spine: an Android disk and a NovaDeck disk cannot produce each other's screen"
printf '%s\n' "$facts_wipe" | grep -qx 'SCREEN=android-wipe' \
  && ok "a disk with no novadeck on it renders the userdata-wipe screen" \
  || bad "an Android disk did not produce the android-wipe screen"
spine_dir reinst
SP_SEL_MODE=reinstall
out="$(spine_run --intent reinstall)" || bad "the reinstall path failed: $out"
facts_re="$(cat "$SP_FACTS" 2>/dev/null || true)"
printf '%s\n' "$facts_re" | grep -qx 'SCREEN=reinstall' \
  && ok "a disk that already carries novadeck renders the /home choice instead" \
  || bad "a novadeck disk did not produce the reinstall screen"
if printf '%s\n' "$facts_re" | grep -q 'UD_GIB_NOW'; then
  bad "the reinstall screen quotes a userdata size -- there is no userdata to destroy on that path and the wipe text would be flatly false"
else
  ok "and it quotes no userdata size at all"
fi
printf '%s\n' "$facts_re" | grep -qx 'HOME_ACTION=keep' \
  && ok "the default reinstall keeps /home" \
  || bad "the reinstall default is not keep"
if grep -q "mkfs.ext4 .*000000000013" "$SP/calls"; then
  bad "a keep-/home reinstall recreated /home -- that promise is the only content of the mode"
else
  ok "and /home was not recreated"
fi

CASE="spine: --erase-home is the only thing that recreates /home on a reinstall"
spine_dir reinst_erase
SP_SEL_MODE=reinstall
out="$(spine_run --intent reinstall --erase-home)" || bad "failed: $out"
grep -q "mkfs.ext4 .*000000000013" "$SP/calls" \
  && ok "--erase-home recreates it" \
  || bad "--erase-home did not recreate /home"
grep -qx 'HOME_ACTION=erase' "$SP_FACTS" \
  && ok "and the screen says so, so the gate quotes what is being destroyed" \
  || bad "the screen did not say /home was being erased"

CASE="spine: the free-space figure comes from carve.sh, not from select-target's CEIL"
# THE 0 GiB BUG, 2026-08-21. The screen derived the space NovaDeck gets as
# (CEIL - UD_START)/GiB - UD_GIB. CEIL stops at whatever follows userdata, which on a disk that
# already carries novadeck is our OWN ESP -- so the expression yields 0 while the carve went on to
# hand NovaDeck 90853 MiB. The number now comes from `carve.sh plan`, which derives it from
# effective_ceiling, the rule that is right.
spine_dir plan_number
SP_SEL_MODE=reinstall; SP_PLAN_GIB=88; SP_PLAN_REPLACES=1
out="$(spine_run --intent fresh)" || bad "run failed: $out"
grep -q 'carve.sh plan ' "$SP/calls" \
  && ok "the spine asks carve.sh what the carve will actually do" \
  || bad "the spine never asked carve.sh for a plan"
sp_before 'carve.sh plan' 'confirm ' \
  && ok "and asks BEFORE the screen is drawn, which is the only time the answer is useful" \
  || bad "the plan was fetched after consent was taken"
grep -qx 'NOVADECK_GIB=88' "$SP_FACTS" \
  && ok "the screen quotes 88 GiB -- carve's figure, not a ceiling that stops at our own ESP" \
  || bad "NOVADECK_GIB is not carve's figure: $(grep NOVADECK_GIB "$SP_FACTS" 2>/dev/null)"
grep -qx 'NOVADECK_GIB=0' "$SP_FACTS" \
  && bad "the 0 GiB bug is back" \
  || ok "and it is not 0"
# `plan` must not write. If it ever does, the whole ordering guarantee is void: it runs BEFORE
# consent, so a plan with side effects means the disk is touched before the user has agreed.
sp_before 'carve.sh plan' 'carve.sh fresh' \
  && ok "plan runs before the destructive carve, and is a separate invocation from it" \
  || bad "plan and fresh are not distinguishable in the call log"

CASE="spine: a plan it could not obtain says so, rather than inventing a number"
spine_dir plan_missing
SP_SEL_MODE=reinstall; SP_PLAN_RC=1
out="$(spine_run --intent fresh)" || bad "run failed: $out"
grep -qx 'NOVADECK_GIB=unknown' "$SP_FACTS" \
  && ok "an unavailable plan degrades to 'unknown' -- 'we could not tell' and a confident 0 must not look the same" \
  || bad "a failed plan did not produce unknown: $(grep NOVADECK_GIB "$SP_FACTS" 2>/dev/null)"

CASE="spine + confirm-tty: a fresh install over an existing novadeck says it is destroying /home"
# THE SERIOUS HALF OF THE SAME FINDING. `fresh` on a disk we already own destroys the existing
# /home -- carve.sh has always printed "it is being replaced, /home included", but it printed it
# AFTER consent, where nobody could act on it. Worse, the screen reassured "your game library is
# safe", which is true when the games are on the SD card and flatly false once they are on the
# internal /home this is about to erase.
spine_dir replaces
SP_SEL_MODE=reinstall; SP_PLAN_REPLACES=1
out="$(spine_run --intent fresh)" || bad "run failed: $out"
grep -qx 'REPLACES_OURS=1' "$SP_FACTS" \
  && ok "the facts record that an existing install is being replaced" \
  || bad "REPLACES_OURS is not set on a fresh-over-ours disk"
screen="$("$ROOT/install/confirm-tty" --facts "$SP_FACTS" --sequence NESW </dev/null 2>&1 >/dev/null || true)"
printf '%s\n' "$screen" | grep -qi 'DELETES THE NOVADECK INSTALL ALREADY ON THIS DISK' \
  && ok "and the screen says so, in its own block" \
  || bad "the screen does not disclose that an existing novadeck install is destroyed"
printf '%s\n' "$screen" | grep -qi 'games' \
  && ok "in the user's terms -- 'games' is the word that stops someone, not '/home'" \
  || bad "the screen never mentions games"
printf '%s\n' "$screen" | grep -q 'your game library is safe' \
  && bad "the screen still reassures 'your game library is safe' while erasing the disk holding it" \
  || ok "and it no longer reassures about a library it is about to delete"

CASE="confirm-tty: the SD-card reassurance survives on the disk where it is true"
spine_dir noreplace
SP_SEL_MODE=fresh; SP_PLAN_REPLACES=0
out="$(spine_run --intent fresh)" || bad "run failed: $out"
screen="$("$ROOT/install/confirm-tty" --facts "$SP_FACTS" --sequence NESW </dev/null 2>&1 >/dev/null || true)"
printf '%s\n' "$screen" | grep -q 'your game library is safe' \
  && ok "a stock Android disk still gets it -- there the games really are on the card" \
  || bad "the reassurance was lost on the disk where it is true"
printf '%s\n' "$screen" | grep -qi 'DELETES THE NOVADECK INSTALL ALREADY' \
  && bad "a stock Android disk rendered the replace-existing block" \
  || ok "and it does not claim to be replacing an install that is not there"

CASE="spine: a reinstall that keeps /home refuses when there is no /home to keep"
# FOUND ON HARDWARE 2026-08-21, on the Pocket ACE after the Phase 4a gate: eight partitions in
# place, only root-A and var-A carrying filesystems. Nothing downstream catches it -- the keep path
# skips mkfs_home AND skips seed_home -- so the install runs to the last byte, reports success, and
# leaves a device that cannot mount /home. The failure is invisible until the user reboots into it.
spine_dir reinst_nohome
SP_SEL_MODE=reinstall
SP_HOME_FSTYPE=""                                   # the partition exists; nothing is on it
out="$(spine_run --intent reinstall)" \
  && bad "the spine installed over an unformatted /home and called it keeping it" \
  || ok "it refuses rather than producing an install that cannot mount /home"
printf '%s\n' "$out" | grep -q 'holds no filesystem' \
  && ok "and says what is wrong, not just that something is" \
  || bad "the refusal does not name the empty /home: $out"
printf '%s\n' "$out" | grep -q -- '--erase-home' \
  && ok "and names the flag that fixes it -- a refusal with no way forward is a dead end on a recovery tool" \
  || bad "the refusal does not name --erase-home: $out"
carve_wrote \
  && bad "it refused AFTER the carve -- the whole value of this check is that the disk is untouched" \
  || ok "and nothing was written: the refusal lands before the carve"
# The direction matters as much as the refusal. Quietly upgrading to --erase-home would answer
# "keep this" by destroying it, which is the one direction that cannot be undone.
grep -q "mkfs.ext4 .*000000000013" "$SP/calls" \
  && bad "it silently recreated /home -- the user asked to KEEP it" \
  || ok "and it did not quietly erase what it was asked to keep"

CASE="spine: --erase-home is what an empty /home needs, and it still works"
spine_dir reinst_nohome_erase
SP_SEL_MODE=reinstall
SP_HOME_FSTYPE=""
out="$(spine_run --intent reinstall --erase-home)" \
  && ok "the flag the refusal named actually completes the install" \
  || bad "--erase-home did not recover the empty-/home case: $out"
grep -q "mkfs.ext4 .*000000000013" "$SP/calls" \
  && ok "and /home was created" \
  || bad "--erase-home did not create /home"

CASE="spine: intent is the user's, never inferred from the disk"
spine_dir intent
SP_SEL_MODE=reinstall
out="$(spine_run)" && bad "it picked an intent for a disk that admits three different answers" \
  || ok "a disk that already carries novadeck refuses to default -- reinstall, resize and remove all fit it, and two of those guesses erase something the user wanted kept"
if carve_wrote; then bad "it wrote anyway"; else ok "and nothing was written"; fi
spine_dir intent2
SP_SEL_MODE=fresh
out="$(spine_run --intent reinstall)" && bad "it reinstalled over a disk with no install on it" \
  || ok "--intent reinstall on a stock disk is refused"

# --- sources verified before the first sgdisk (plan §3 rule 11) ----------------------------------
CASE="spine: a bundle that will not verify costs the user nothing"
spine_dir badbundle
SP_INFO_RC=1
out="$(spine_run)" && bad "installed a bundle that did not verify" || ok "refuses"
if carve_wrote; then
  bad "the carve ran first -- Android's data is gone to reach an error that was free at second zero"
else
  ok "and the disk was never touched"
fi
if grep -q '^confirm ' "$SP/calls"; then
  bad "it asked for consent before it knew the sources were good"
else
  ok "it did not even ask for consent"
fi

CASE="spine: the /home seed is checked against the pin baked into the INSTALLER"
spine_dir badseed
printf '%064d\n' 0 >"$SP_PIN"          # a well-formed sha256 that is not the seed's
out="$(spine_run)" && bad "installed a seed that does not match the baked pin" || ok "refuses"
if carve_wrote; then bad "the carve ran first"; else ok "and the disk was never touched"; fi

CASE="spine: a missing pin is fatal, not skippable"
spine_dir nopin
rm -f "$SP_PIN"
out="$(spine_run)" && bad "installed with no pin to check the seed against" \
  || ok "'we could not check' and 'it checked out' must not have the same effect"

CASE="spine: it fails closed on a missing tool"
# AN OFFLINE SUITE INHERITS THE HOST'S PATH and so cannot make a real tool absent -- and emptying
# PATH does not work either, because the script's own `#!/usr/bin/env bash` needs it. The way in is
# the seam, exactly as images/test-post-install.sh reaches its die(): point one of the tool names at
# something that does not exist. It is the same loop and the same refusal.
spine_dir notool
SP_SGDISK=novadeck-no-such-tool
out="$(spine_run)" && bad "ran with one of its tools absent" \
  || ok "a missing tool is found at second zero, not after userdata is gone"
printf '%s' "$out" | grep -q 'novadeck-no-such-tool' \
  && ok "and it names what is missing, rather than failing later at the use site" \
  || bad "the error does not name the missing tool: $out"
if carve_wrote; then bad "the carve ran anyway"; else ok "and nothing was written"; fi
unset SP_SGDISK

# --- confirm-tty, the renderer behind the seam ---------------------------------------------------
# It is one implementation of the contract; §5's gamepad screen is another. What is asserted here is
# that it renders the FACTS (not a fixed string) and that the two screens share no path.
CASE="spine + confirm-tty: the real renderer satisfies the real gate"
# THE CASE THAT CATCHES THE SEAM ITSELF. Every gate case above drives a stub that prints the
# sequence and nothing else -- so all of them pass against a renderer whose stdout also carries the
# screen, and the spine then reads several hundred lines of prose, decides that was not the
# sequence, re-randomises, and refuses. An installer that can NEVER take consent, with a symptom
# ("that was not the sequence shown") pointing nowhere near the cause. Measured while writing this,
# which is why the case exists. The wrapper is only a keyboard: it types the sequence it was told to
# display, and the real confirm-tty does everything else.
spine_dir tty
SP_CONFIRM_OVERRIDE="$T/confirm-typist"
cat >"$SP_CONFIRM_OVERRIDE" <<EOF
#!/usr/bin/env bash
seq=""
for a in "\$@"; do [ "\$prev" = --sequence ] && seq="\$a"; prev="\$a"; done
printf '%s\n' "\$seq" | "$CONFIRM_TTY" "\$@"
EOF
chmod +x "$SP_CONFIRM_OVERRIDE"
out="$(spine_run)" \
  && ok "the shipped renderer's answer is accepted on the first attempt" \
  || bad "the real confirm-tty did not satisfy the gate: $out"
[ -f "$SP_RUN/esp/EFI/BOOT/bootaa64.efi" ] \
  && ok "and the install ran to the last byte" \
  || bad "the install did not complete"
unset SP_CONFIRM_OVERRIDE

CASE="confirm-tty: renders the numbers the spine measured"
cat >"$T/facts-wipe" <<'EOF'
SCREEN=android-wipe
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
UD_INDEX=11
UD_GIB_NOW=96
UD_GIB_AFTER=16
NOVADECK_GIB=80
HOME_ACTION=create
EOF
wipe_render="$("$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence SWNE </dev/null 2>&1 || true)"
printf '%s' "$wipe_render" | grep -q '96 GiB' && printf '%s' "$wipe_render" | grep -q '16 GiB' \
  && ok "quotes both the size lost and the size kept" \
  || bad "the rendering does not quote the measured sizes"
printf '%s' "$wipe_render" | grep -qi 'NOT recoverable' \
  && ok "says the data is not recoverable, in the user's terms" \
  || bad "the screen does not say the loss is permanent"
printf '%s' "$wipe_render" | grep -qi 'SD card is never written' \
  && ok "says the SD card is never written -- the one reassurance that is both true and load-bearing" \
  || bad "the screen does not mention the SD card"
printf '%s' "$wipe_render" | grep -qi 'Volume Up' \
  && ok "names how to get back to Android" \
  || bad "the screen does not say how to reach Android afterwards"

CASE="confirm-tty: the reinstall screen shares no text with the wipe screen"
cat >"$T/facts-reinst" <<'EOF'
SCREEN=reinstall
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
HOME_ACTION=keep
HOME_GIB=214
EOF
re_render="$("$CONFIRM_TTY" --facts "$T/facts-reinst" --sequence SWNE </dev/null 2>&1 || true)"
if printf '%s' "$re_render" | grep -qi 'DELETES ANDROID'; then
  bad "the reinstall screen renders the Android-wipe warning, which is flatly false there"
else
  ok "no Android-wipe text on the reinstall path"
fi
printf '%s' "$re_render" | grep -q '214 GiB' \
  && ok "it quotes the /home figure instead -- 'erase 214 GiB of games and saves' is the number that stops someone" \
  || bad "the reinstall screen does not quote the /home size"

CASE="confirm-tty: it echoes back what was typed, and nothing else"
typed="$(printf 's w n e\n' | "$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence SWNE 2>/dev/null || true)"
[ "$(printf '%s' "$typed" | tr -d '[:space:]')" = SWNE ] \
  && ok "typed with the spacing shown, upper-cased, is accepted (a gate that fails on whitespace teaches retyping, not reading)" \
  || bad "it did not echo the typed sequence"
# The screen prints SOUTH/WEST/NORTH/EAST under the diamonds, so someone will type that. It is the
# same intent and the same reading of the same screen; only the abbreviation differs.
typed="$(printf 'south west north east\n' | "$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence SWNE 2>/dev/null || true)"
[ "$(printf '%s' "$typed" | tr -d '[:space:]')" = SWNE ] \
  && ok "and the full words under the diamonds are accepted as their initials" \
  || bad "typing the words printed on the screen was not accepted: '$typed'"
# But it is not a filter that throws away whatever it does not recognise: that would forgive a
# wrong answer with a right answer buried in it.
typed="$(printf 'a b x y\n' | "$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence SWNE 2>/dev/null || true)"
[ "$(printf '%s' "$typed" | tr -d '[:space:]')" = SWNE ] \
  && bad "an answer that is not the sequence was normalised into one" \
  || ok "a wrong answer stays wrong -- junk is not filtered out of it"

CASE="confirm-tty: it draws the POSITION, and says the printed letter is not it"
# The face cluster's silkscreen differs across the boards this installer is unified over (`A` is
# EAST on the AYANEO Pocket ACE, SOUTH on the Pocket S2), so the screen must not name a letter.
draw="$("$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence SWNE </dev/null 2>&1 >/dev/null || true)"
printf '%s' "$draw" | grep -q 'SOUTH' && printf '%s' "$draw" | grep -q 'NORTH' \
  && ok "the four presses are named as positions" \
  || bad "the acknowledgement does not name the positions"
printf '%s' "$draw" | grep -qi 'not the letter printed on the button' \
  && ok "and it says outright that the printed letter is not what is meant" \
  || bad "nothing on the screen warns that the silkscreen differs between devices"
# Three rows of diamonds, one column per press: the picture is the instruction for anyone who
# reads the panel rather than the words.
[ "$(printf '%s\n' "$draw" | grep -c '^ *[o#]\( *[o#]\)* *$')" -ge 3 ] \
  && ok "and it draws them, one diamond per press" \
  || bad "the diamonds were not drawn"
# A sequence naming a button it cannot draw is a contract violation between the spine and the
# renderer, and it must be loud: a blank diamond would mean the two disagree about what was shown.
"$CONFIRM_TTY" --facts "$T/facts-wipe" --sequence ABXY </dev/null >/dev/null 2>&1 \
  && bad "a sequence of printed-letter buttons rendered as if it were positions" \
  || ok "a sequence it cannot draw is refused, not rendered blank"

printf '\ntest-install.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
