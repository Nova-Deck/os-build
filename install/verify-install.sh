#!/usr/bin/env bash
# Verification of an INTERNAL install, run on the device — Phase 4c of
# .claude/plans/internal-install.plan.md.
#
#   install/verify-install.sh            # discover the installed disk
#   install/verify-install.sh /dev/sda   # check exactly this disk
#
# THE SAME CHECK LIST AS image/verify-card.sh, against real mounts. That one is unprivileged and
# reads image files at byte offsets with mtools; this one has root and real block devices, so it
# mounts read-only instead. The lists are kept deliberately parallel: a card and an install that
# pass different checks are two artifacts nobody can reason about together.
#
# WHY IT EXISTS SEPARATELY FROM THE INSTALLER. The spine writes; this reads. An installer that
# graded its own work would share the bug with its grader -- the same reason select-target.sh is a
# separate script from carve.sh. Run it after the install and BEFORE the card comes out, while
# there is still a shell that can fix things.
#
# READ-ONLY, and structurally so: every mount here is `-o ro`, nothing is created outside a
# tmpdir, and the only block-device reads are through blkid and the mounted filesystems.
#
# WHAT IT CANNOT TELL YOU: that the device boots. Nothing here replaces pulling the card and
# watching ABL hand off. It answers the narrower question of whether the eight partitions carry
# what the boot chain will look for, which is the part that is silent until it is not.
set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }
die() { printf 'verify-install: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root -- it mounts the installed filesystems"

# Fail closed on a missing tool, the same rule as select-target.sh's mdir and sfdisk. A verifier
# that skips a check because a binary is absent reports "no failures" for a disk it never looked
# at, which is worse than not running at all.
for t in sgdisk sfdisk blkid mount umount findmnt; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found -- refusing to report on checks it cannot run"
done

# lib-gpt.sh (name -> index, past any entry the GPT no longer uses) and lib-slotwrite.sh
# (index -> /dev/disk/by-partuuid/...). Resolved by search exactly as carve.sh resolves them.
LIBGPT="${NOVADECK_LIB_GPT:-}"
if [ -z "$LIBGPT" ]; then
  for c in "$SELFDIR/lib-gpt.sh" /usr/lib/novadeck/install/lib-gpt.sh "$SELFDIR/../image/lib-gpt.sh"; do
    [ -r "$c" ] && { LIBGPT="$c"; break; }
  done
fi
SLOTWRITE="${NOVADECK_SLOTWRITE:-}"
if [ -z "$SLOTWRITE" ]; then
  for c in "$SELFDIR/lib-slotwrite.sh" /usr/lib/novadeck/install/lib-slotwrite.sh \
           "$SELFDIR/../fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh"; do
    [ -r "$c" ] && { SLOTWRITE="$c"; break; }
  done
fi
[ -n "$LIBGPT" ]    && [ -r "$LIBGPT" ]    || die "cannot find lib-gpt.sh (set NOVADECK_LIB_GPT)"
[ -n "$SLOTWRITE" ] && [ -r "$SLOTWRITE" ] || die "cannot find lib-slotwrite.sh (set NOVADECK_SLOTWRITE)"
# shellcheck source=../image/lib-gpt.sh
. "$LIBGPT"
# shellcheck source=../fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh
. "$SLOTWRITE"

T="$(mktemp -d)"
cleanup() {
  # Unmount deepest-first: /esp and /efi are independent here, but a future check that nests would
  # otherwise leave a busy mount behind on a device the operator still has to reboot.
  awk -v t="$T" '$2 ~ "^"t {print $2}' /proc/mounts | sort -r | while read -r m; do
    umount "$m" >/dev/null 2>&1 || true
  done
  rm -rf "$T"
}
trap cleanup EXIT

OUR_NAMES=(NOVADECK-ESP novadeck-efi-A novadeck-efi-B novadeck-root-A novadeck-root-B \
           novadeck-var-A novadeck-var-B novadeck-home)

# --- which disk ---------------------------------------------------------------------------------
# By GPT name, not by asking which disk we booted from: the point of this script is to check an
# install that may not be the running system (run it from the card, before the first internal boot).
DISK="${1:-}"
if [ -z "$DISK" ]; then
  for d in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [ -b "$d" ] || continue
    if gpt_rows "$d" 2>/dev/null | awk '{print $5}' | grep -qx novadeck-root-A; then
      [ -z "$DISK" ] || die "more than one disk carries a novadeck install ($DISK and $d) -- name one"
      DISK="$d"
    fi
  done
fi
[ -n "$DISK" ] || die "no disk carries a novadeck install (looked for novadeck-root-A)"
[ -b "$DISK" ] || die "$DISK is not a block device"

echo "[novadeck] verifying the install on $DISK"

# --- 1. the eight are there, and addressable by PARTUUID -----------------------------------------
# The index is discovered by NAME and never by arithmetic: on an internal install the eight are
# neither row order nor contiguous, which is the whole reason parts.env exists further down.
declare -A IDX DEV
rows="$(gpt_rows "$DISK")" || die "cannot read the partition table of $DISK"
for name in "${OUR_NAMES[@]}"; do
  i="$(printf '%s\n' "$rows" | awk -v w="$name" '$5 == w {print $1; exit}')"
  if [ -z "$i" ]; then bad "$name is missing from the table"; continue; fi
  IDX["$name"]="$i"
  d="$(part_dev "$DISK" "$i")" || { bad "$name (p$i) has no partuuid path"; continue; }
  if [ -b "$d" ]; then DEV["$name"]="$d"; ok "$name = p$i, addressable by partuuid"
  else bad "$name (p$i) resolves to $d, which is not a block device"; fi
done
[ "${#DEV[@]}" = 8 ] || { printf '\nverify-install: %d of 8 partitions unusable -- stopping\n' \
  "$(( 8 - ${#DEV[@]} ))" >&2; exit 1; }

# READ THROUGH AN EXISTING MOUNT WHEN THERE IS ONE. This script is meant to run from the installer,
# where nothing on the target is mounted -- but it is at least as useful run on the installed system
# afterwards, and there /esp and /efi are already mounted read-write by the running OS. `mount -o ro`
# on a device that is already mounted fails with "would change RO state", which would report the ESP
# as unreadable on a perfectly good install. We only ever read, so an existing mount serves.
USE_PATH=""; USE_OURS=0
use_fs() {  # <dev> <tmp-mountpoint> -> 0 with USE_PATH set
  local existing
  USE_PATH=""; USE_OURS=0
  existing="$(findmnt -no TARGET --source "$1" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then USE_PATH="$existing"; return 0; fi
  mkdir -p "$2"
  mount -o ro "$1" "$2" 2>/dev/null || return 1
  USE_PATH="$2"; USE_OURS=1
}
release_fs() { [ "$USE_OURS" = 1 ] && umount "$USE_PATH" >/dev/null 2>&1; USE_OURS=0; return 0; }

fstype() { blkid -o value -s TYPE  "$1" 2>/dev/null; }
fsuuid() { blkid -o value -s UUID  "$1" 2>/dev/null; }
fslabel() { blkid -o value -s LABEL "$1" 2>/dev/null; }

# --- 2. filesystem identities --------------------------------------------------------------------
echo "  1. filesystems"
expect_fs() {  # <gpt-name> <expected type>
  local got; got="$(fstype "${DEV[$1]}")"
  [ "$got" = "$2" ] && ok "$1 is $2" || bad "$1 is '${got:-none}', expected $2"
}
expect_fs NOVADECK-ESP   vfat
expect_fs novadeck-efi-A vfat
expect_fs novadeck-efi-B vfat
expect_fs novadeck-root-A btrfs
expect_fs novadeck-var-A  ext4
expect_fs novadeck-home   ext4

# SLOT B IS EMPTY ON A FRESH INSTALL, and that is a claim worth asserting rather than a gap in the
# list. The spine formats four filesystems, not six: the RAUC handler owns var-A, and root-B/var-B
# are left untouched so the disk matches the release card's shape. A populated B here means either
# an update has already been applied (fine -- set NOVADECK_SLOT_B=1) or the installer wrote a slot
# it had no business writing.
if [ "${NOVADECK_SLOT_B:-0}" = 1 ]; then
  expect_fs novadeck-root-B btrfs
  expect_fs novadeck-var-B  ext4
  # Content-identical roots that SHARE an fsid make mounting B hand you A, and every slot test
  # after that is meaningless. Same check, same reason, as image/verify-card.sh.
  a="$(fsuuid "${DEV[novadeck-root-A]}")"; b="$(fsuuid "${DEV[novadeck-root-B]}")"
  { [ -n "$a" ] && [ "$a" != "$b" ]; } \
    && ok "root-A / root-B fsids differ (${a:0:8} vs ${b:0:8})" \
    || bad "root-A and root-B share an fsid -- a slot switch cannot be trusted"
  a="$(fsuuid "${DEV[novadeck-var-A]}")"; b="$(fsuuid "${DEV[novadeck-var-B]}")"
  { [ -n "$a" ] && [ "$a" != "$b" ]; } \
    && ok "var-A / var-B UUIDs differ" || bad "var-A and var-B share a UUID"
else
  for n in novadeck-root-B novadeck-var-B; do
    got="$(fstype "${DEV[$n]}")"
    [ -z "$got" ] && ok "$n is unformatted (empty slot B, as a fresh install leaves it)" \
                  || bad "$n carries a $got filesystem on a fresh install -- set NOVADECK_SLOT_B=1 if an update has landed"
  done
fi

[ "$(fslabel "${DEV[novadeck-root-A]}")" = novadeck-root-A ] \
  && ok "root-A btrfs label = novadeck-root-A" \
  || bad "root-A btrfs label is '$(fslabel "${DEV[novadeck-root-A]}")'"

# --- 3. the slot witness -------------------------------------------------------------------------
echo "  2. slot witness"
# UPPERCASE, and that is not a detail to normalise away. tests/test-post-install.sh states the
# convention -- the witness records the slot "in the bootconf naming (A/B)" -- and asserts 'B' for
# slot B. seed_var writes $SLOT, which is that same naming.
#
# THE CARD DISAGREES: image/verify-card.sh expects lowercase 'a', and passes, so a card's var-a
# really does carry 'a' while an install's var-A carries 'A'. Nothing reads this file at runtime --
# it is a witness for diagnosis, and the two verifiers are its only readers -- so it costs nothing
# today. It is still two artifacts answering the same question differently, which is the thing
# these parallel check lists exist to surface. Asserted here as the installer actually writes it.
if use_fs "${DEV[novadeck-var-A]}" "$T/var"; then
  got="$(tr -d '[:space:]' <"$USE_PATH/lib/novadeck/slot" 2>/dev/null)"
  [ "$got" = A ] && ok "var-A /var/lib/novadeck/slot = A" \
                 || bad "var-A slot witness: expected 'A', got '${got:-<missing>}'"
  release_fs
else
  bad "cannot read var-A"
fi

# --- 4. the ESP (stage 1) ------------------------------------------------------------------------
# ABL boots /EFI/BOOT/bootaa64.efi from here. The boot confs and the shared grubenv live here too,
# because they are per-DISK rather than per-slot.
echo "  3. ESP (stage 1)"
if use_fs "${DEV[NOVADECK-ESP]}" "$T/esp"; then
  esp="$USE_PATH"
  for f in /EFI/BOOT/bootaa64.efi /EFI/BOOT/steamcl-version /EFI/BOOT/fonts/default.pf2 \
           /EFI/steamos/grubenv /SteamOS/conf/A.conf; do
    [ -s "$esp$f" ] && ok "$f present" || bad "$f missing or empty"
  done
  [ -e "$esp/EFI/BOOT/steamcl-restricted" ] \
    && { [ -s "$esp/EFI/BOOT/steamcl-restricted" ] \
           && bad "steamcl-restricted should be empty" \
           || ok "steamcl-restricted present and empty"; } \
    || bad "/EFI/BOOT/steamcl-restricted missing"

  # B.conf is what makes steamcl offer B as a boot candidate. On a fresh install slot B holds
  # nothing, so a B.conf here points the bootloader at an empty partition.
  if [ "${NOVADECK_SLOT_B:-0}" = 1 ]; then
    [ -s "$esp/SteamOS/conf/B.conf" ] && ok "B.conf present (slot B is populated)" \
                                        || bad "B.conf missing though slot B is populated"
  else
    [ -e "$esp/SteamOS/conf/B.conf" ] \
      && bad "B.conf present with an empty slot B -- steamcl would offer B as a boot candidate" \
      || ok "no B.conf (empty slot B is not a boot candidate)"
  fi

  grep -aq "GRUB Environment Block" "$esp/EFI/steamos/grubenv" \
    && ok "grubenv is a valid GRUB env block" || bad "grubenv has no GRUB magic header"

  # A.conf must be armed for a first boot: a stamp to order it against B, and a clean attempt
  # count. `boot-attempts` non-zero here would mean the slot arrives already part-way through its
  # trial, with fewer tries than it is owed.
  a_stamp="$(sed -n 's/^boot-requested-at: *//p' "$esp/SteamOS/conf/A.conf" | head -1)"
  case "$a_stamp" in
    [0-9]*) ok "A.conf boot-requested-at = $a_stamp" ;;
    *)      bad "A.conf has no valid boot-requested-at (got '${a_stamp:-<none>}')" ;;
  esac
  for k in boot-attempts image-invalid; do
    v="$(sed -n "s/^$k: *//p" "$esp/SteamOS/conf/A.conf" | head -1)"
    [ "$v" = 0 ] && ok "A.conf $k = 0" || bad "A.conf $k = '${v:-<none>}', expected 0"
  done

  for junk in /KERNEL /NOVADECK; do
    [ -e "$esp$junk" ] && bad "$junk present on a Phase 5 ESP" || ok "no $junk"
  done
  release_fs
else
  bad "cannot read the ESP"
fi

# --- 5. efi-A (stage 2) --------------------------------------------------------------------------
# THE CHECK THAT EARNS ITS PLACE HERE AND NOT ON A CARD. On a card parts.env holds the generator's
# build-time defaults, so a wrong value is invisible at boot and the card still works. On an
# internal install the indices were DISCOVERED from somebody else's GPT -- p12..p19 on the boards
# captured so far, and neither row order nor contiguous in general -- so parts.env is the only
# thing telling stage 2 where anything is. A map that disagrees with the disk it sits on is a boot
# failure with no diagnostic, on a device with no serial console.
echo "  4. efi-A (stage 2)"
if use_fs "${DEV[novadeck-efi-A]}" "$T/efi"; then
  efi="$USE_PATH"
  for f in /EFI/steamos/grubaa64.efi /EFI/steamos/grub.cfg \
           /EFI/steamos/fonts/dejavu-mono.pf2 /EFI/steamos/parts.env; do
    [ -s "$efi$f" ] && ok "$f present" || bad "$f missing or empty"
  done
  grep -aq "GRUB Environment Block" "$efi/EFI/steamos/parts.env" \
    && ok "parts.env is a valid GRUB env block" || bad "parts.env has no GRUB magic header"
  for kv in "nd_esp=${IDX[NOVADECK-ESP]}"     "nd_efi_a=${IDX[novadeck-efi-A]}" \
            "nd_efi_b=${IDX[novadeck-efi-B]}" "nd_root_a=${IDX[novadeck-root-A]}" \
            "nd_root_b=${IDX[novadeck-root-B]}" "nd_var_a=${IDX[novadeck-var-A]}" \
            "nd_var_b=${IDX[novadeck-var-B]}"   "nd_home=${IDX[novadeck-home]}"; do
    grep -aqx -- "$kv" "$efi/EFI/steamos/parts.env" \
      && ok "parts.env $kv" \
      || bad "parts.env does not carry $kv -- the map disagrees with the GPT it sits on"
  done
  # steamos-bootconf errors and EXITS without these, so their absence is not cosmetic.
  for s in A B all other self shared; do
    [ -e "$efi/SteamOS/partsets/$s" ] && ok "partsets/$s present" || bad "partsets/$s missing"
  done
  release_fs
else
  bad "cannot read efi-A"
fi

# --- 6. the other OS ------------------------------------------------------------------------------
# The install destroyed userdata's contents by design and promised Android would come back. It only
# does if the partition still looks like Android's to Android: the vendor type GUID, not the Linux
# one a third-party uninstaller leaves behind (issue #56).
echo "  5. the other OS"
ud_idx="$(printf '%s\n' "$rows" | awk '$5 == "userdata" {print $1; exit}')"
if [ -z "$ud_idx" ]; then
  bad "userdata is gone from the table -- Android has no data partition"
else
  ud_type="$(sgdisk -i "$ud_idx" "$DISK" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
  [ "${ud_type^^}" = "$NOVADECK_ANDROID_USERDATA_GUID" ] \
    && ok "userdata (p$ud_idx) still carries the Android vendor type" \
    || bad "userdata (p$ud_idx) is typed $ud_type, not $NOVADECK_ANDROID_USERDATA_GUID -- Android may not recognise it"
fi

# A GPT entry the table no longer uses is what made this disk uninstallable before #56, and the
# carve clears them. Any left here means something rewrote the table after we did.
if gpt_has_dead_entries "$DISK"; then
  bad "the table still carries zeroed GPT entries -- something rewrote it after the carve"
else
  ok "no zeroed GPT entries left behind"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "[novadeck] install OK on $DISK"
else
  echo "[novadeck] install NOT verified on $DISK -- see the !! lines above" >&2
fi
exit "$FAIL"
