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
: >"$T/nodisk.img"

# 40 GiB disk; userdata shrunk to 8 GiB ending at 16812031, an OEM partition at 62949376. So the
# carve's window is 16812032..62949375 -- the shape the real-sgdisk run above was driven with.
STUB_TABLE='   1            2048           34815   16.0 MiB    8300  oem-early
   2           34816        16812031   8.0 GiB     8300  userdata
   3        62949376        63080447   64.0 MiB    8300  oem-late'
FLOOR=16812032
CEIL=62949375
try_window() {  # <floor> <ceil> [rows] -> the run's output
  ( export NOVADECK_APPEND_FLOOR="$1" NOVADECK_APPEND_CEIL="$2"
    STUB_ROWS="${3-$STUB_TABLE}" DISK="$T/nodisk.img" PATH="$T/stub:$PATH" \
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

printf '\ntest-install.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
