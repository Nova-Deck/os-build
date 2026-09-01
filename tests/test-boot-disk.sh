#!/usr/bin/env bash
# Offline check for the boot-disk-scoped partition links.
#
#   tests/test-boot-disk.sh
#
# WHY THIS FILE EXISTS. Every novadeck medium carries the same eight GPT names, so with a card
# inserted in a device installed to internal storage, /dev/disk/by-partlabel/* and
# /dev/disk/by-label/* resolve to whichever disk udev enumerated first. Four consumers depended on
# that -- /esp, /home, grow-home's repart target, and rauc's slot devices -- and the consequences
# range from "the Steam library is on the other disk" through "systemd-repart rewrote the internal
# disk's GPT" to "the OTA landed in the internal install's slot". The links they all go through now
# are created by ONE udev rule matching through ONE program, and this suite is the only thing that
# can exercise that program: it needs two disks, and hardware only ever has the one it booted.
#
# It EXECUTES rootfs/overlay/usr/lib/novadeck/on-boot-disk -- not a copy -- through the two seams
# that file documents, against a sysfs-shaped fixture. So what passes here is the artifact that
# ships.
#
# THE FAIL-OPEN CASES ARE THE POINT, not an afterthought. This mechanism can only be adopted safely
# if it is impossible for it to make a single-disk device worse than the labels it replaces, and
# "worse" here means an unmountable /home on every device in the field. Every way the boot disk can
# be unknowable therefore has a case below, and each one asserts exit 0.
#
# Runs on the host: a directory tree, no root, no udev, no block devices.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROG="$ROOT/rootfs/overlay/usr/lib/novadeck/on-boot-disk"
RULE="$ROOT/rootfs/overlay/usr/lib/udev/rules.d/69-novadeck-bootdisk.rules"
ASSEMBLE="$ROOT/rootfs/assemble-rootfs.sh"
SYSCONF="$ROOT/rootfs/overlay/etc/rauc/system.conf"
POSTINST="$ROOT/rootfs/overlay/usr/lib/rauc/post-install.sh"
TABLE="$ROOT/image/partition-table.txt"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

for f in "$PROG" "$RULE" "$ASSEMBLE" "$SYSCONF" "$POSTINST" "$TABLE"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -x "$PROG" ] || { echo "not executable: $PROG (udev cannot run a PROGRAM without the exec bit)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- the fixture ----------------------------------------------------------------------------------
# /sys/class/block is a directory of SYMLINKS into /sys/devices, and the parent-disk derivation is
# `readlink -f <link>/..` -- so a fixture of plain directories would pass while the real thing
# failed. Build it with the real shape: devices under a devices/ tree, class/block entries pointing
# at them, and a `partition` file on partitions only (which is what tells a partition from a disk).
#
# Two disks, deliberately with DIFFERENT partition-name schemes (mmcblk0p8 vs sda8), because the
# `${rootdev##*/}` -> sysfs lookup is the step that would break on one of them.
mkdir -p "$T/sys/class/block" "$T/sys/devices"
mkdisk() {  # <disk kernel name> <partition count>
  local d=$1 n=$2 i
  mkdir -p "$T/sys/devices/$d"
  ln -sfn "../../devices/$d" "$T/sys/class/block/$d"
  for i in $(seq 1 "$n"); do
    local p="$d$3$i"
    mkdir -p "$T/sys/devices/$d/$p"
    : >"$T/sys/devices/$d/$p/partition"
    ln -sfn "../../devices/$d/$p" "$T/sys/class/block/$p"
  done
}
mkdisk mmcblk0 8 p     # the card
mkdisk sda     8 ''    # internal storage, our eight appended to the OEM's GPT

bootinfo() {  # <root device path, or empty for a file with no root= line>
  { printf 'slot=A\nsource=grub\n'
    [ -n "${1:-}" ] && printf 'root=%s\n' "$1"
    printf 'var=/dev/null\nefi=/dev/null\n'
  } >"$T/boot"
}

# The call udev makes: PROGRAM=="/usr/lib/novadeck/on-boot-disk %k".
# The argument is optional so the no-argument case below can be exercised: a rule typo'd to
# PROGRAM=="...on-boot-disk" with no %k is a real way for this to be called bare.
on_boot_disk() {  # [kernel name]
  NOVADECK_SYSBLOCK="$T/sys/class/block" NOVADECK_BOOTINFO="$T/boot" "$PROG" ${1+"$1"}
}

echo "booted from the card, internal install present"
bootinfo /dev/mmcblk0p4
if on_boot_disk mmcblk0p8; then
  ok "the card's home partition is linked"
else
  bad "the card's own home partition was refused — /home would not mount at all"
fi
if on_boot_disk sda8; then
  bad "the internal home partition is ALSO linked — this is the whole bug: /home follows udev's enumeration order"
else
  ok "the internal home partition is refused"
fi
if on_boot_disk sda4; then
  bad "the internal root slot is linked — an OTA taken from the card could write the internal install"
else
  ok "the internal root slot is refused"
fi
if on_boot_disk mmcblk0p1; then
  ok "the card's ESP is linked — mark-good clears boot-attempts on the ESP stage 2 incremented"
else
  bad "the card's ESP was refused — the trial could never be confirmed and every boot would roll back"
fi

echo
echo "booted from internal storage, card inserted"
bootinfo /dev/sda4
if on_boot_disk sda8 && on_boot_disk sda1; then
  ok "the internal home + ESP are linked"
else
  bad "the internal install's own partitions were refused"
fi
if on_boot_disk mmcblk0p8 || on_boot_disk mmcblk0p1; then
  bad "the inserted card's partitions are linked — grow-home could repart the card, /home could mount it"
else
  ok "the inserted card's partitions are refused"
fi

echo
echo "one disk only (every device in the field today)"
rm -rf "$T/sys"
mkdir -p "$T/sys/class/block" "$T/sys/devices"
mkdisk mmcblk0 8 p
bootinfo /dev/mmcblk0p4
allow=1
for p in mmcblk0p1 mmcblk0p2 mmcblk0p3 mmcblk0p4 mmcblk0p5 mmcblk0p6 mmcblk0p7 mmcblk0p8; do
  on_boot_disk "$p" || allow=0
done
[ "$allow" = 1 ] \
  && ok "all eight partitions are linked — a single-disk device is unchanged by this mechanism" \
  || bad "a single-disk device lost a link: this would take /home or /esp away from every device in the field"

echo
echo "fail-open: the boot disk cannot be determined"
# Each of these is a real state, not a hypothetical. Together they are the promise that an OTA
# carrying this change cannot leave a device without /home: when in doubt, link everything, which is
# exactly what by-partlabel did.
mkdisk sda 8 ''
rm -f "$T/boot"
on_boot_disk sda8 \
  && ok "no /run/novadeck/boot (a dev boot, or an initramfs that degraded) -> linked" \
  || bad "a missing boot handoff refuses every link — /home and /esp would not mount"
bootinfo ''
on_boot_disk sda8 \
  && ok "a boot handoff with no root= line -> linked" \
  || bad "a root-less boot handoff refuses every link"
bootinfo /dev/nonexistent99
on_boot_disk sda8 \
  && ok "a root= naming a device that is not in sysfs -> linked" \
  || bad "an unresolvable root= refuses every link"
bootinfo /dev/mmcblk0     # a whole disk, not a partition: no parent disk to derive
on_boot_disk sda8 \
  && ok "a root= naming a whole disk rather than a partition -> linked" \
  || bad "a whole-disk root= refuses every link"

echo
echo "fail-closed: only where the boot disk IS known"
bootinfo /dev/mmcblk0p4
on_boot_disk ghost99 \
  && bad "a partition absent from sysfs was linked while the boot disk was known — that link can only name another device" \
  || ok "a candidate that cannot be inspected is refused once the boot disk is known"
on_boot_disk \
  && ok "no argument at all -> linked (a malformed rule must not unmount the system)" \
  || bad "a call with no argument refuses the link"

# --- the wiring -----------------------------------------------------------------------------------
# The program being right is worth nothing if a consumer still names a bare label. These are the four
# call sites; each one is a partition this system can address on the wrong disk.
echo
echo "every consumer names the scoped link"
grep -q 'PROGRAM=="/usr/lib/novadeck/on-boot-disk %k"' "$RULE" \
  && ok "the rule matches through on-boot-disk, passing the kernel name" \
  || bad "the rule does not invoke on-boot-disk with %k — the program this suite tests is not the one that runs"
# 60-persistent-storage.rules is what exports ID_PART_ENTRY_NAME, and udev sorts rule FILES
# lexically: at 60-novadeck-* this file would run BEFORE that import and match an unset variable,
# creating no links and saying nothing. The prefix IS the mechanism here, so it is asserted.
case "$(basename "$RULE")" in
  6[1-9]-*|[7-9][0-9]-*) ok "the rule sorts after 60-persistent-storage.rules, so ID_PART_ENTRY_NAME is set when it runs" ;;
  *) bad "$(basename "$RULE") sorts at or before 60-persistent-storage.rules — ID_PART_ENTRY_NAME is unset and nothing is ever linked" ;;
esac
grep -q "'/dev/novadeck/NOVADECK-ESP  /esp" "$ASSEMBLE" \
  && ok "fstab mounts /esp from the scoped link" \
  || bad "the /esp fstab row does not name /dev/novadeck/NOVADECK-ESP"
grep -q "'/dev/novadeck/novadeck-home  /home" "$ASSEMBLE" \
  && ok "fstab mounts /home from the scoped link" \
  || bad "the /home fstab row does not name /dev/novadeck/novadeck-home"
grep -q '^HOME_DEV=/dev/novadeck/novadeck-home$' "$ASSEMBLE" \
  && ok "grow-home resolves home through the scoped link before it reparts the parent disk" \
  || bad "grow-home still resolves home by label — it can repart the other disk"
[ "$(grep -c '^device=/dev/novadeck/novadeck-root-[AB]$' "$SYSCONF")" = 2 ] \
  && ok "both rauc slots name the scoped link" \
  || bad "rauc's slot devices are not both /dev/novadeck/novadeck-root-{A,B}"
grep -q '^DEVDIR=${DEVDIR:-/dev/novadeck}$' "$POSTINST" \
  && ok "the post-install hook defaults to the scoped links" \
  || bad "post-install.sh still defaults DEVDIR to by-partlabel"
if grep -qE '/dev/disk/by-(part)?label/(novadeck|NOVADECK)' "$ASSEMBLE" "$SYSCONF" "$POSTINST"; then
  bad "a consumer still names /dev/disk/by-{part,}label for one of our partitions:"
  grep -nE '/dev/disk/by-(part)?label/(novadeck|NOVADECK)' "$ASSEMBLE" "$SYSCONF" "$POSTINST" | sed 's/^/       /'
else
  ok "no consumer resolves one of our partitions by bare label any more"
fi

# --- the fifth consumer, the one udev cannot reach ------------------------------------------------
# Stage 2 runs before Linux, so /dev/novadeck cannot help it -- and it writes the same boot
# accounting the four consumers above protect: it increments boot-attempts in
# \SteamOS\conf\<slot>.conf on the ESP. Its sweep over SIMPLE_FILE_SYSTEM handles used to take the
# first volume that carried the conf, and every novadeck medium carries one, so with two media
# inserted the firmware's enumeration order decided which install got counted. A count landing on
# the disk we did NOT boot is never cleared, because mark-good clears through /esp -- scoped to the
# booted disk. It climbs once per boot until steamcl's failsafe rolls back a healthy slot. Observed
# on HW 2026-09-01; see docs/phase5-bootattempts.md and issue #84.
#
# The C cannot be exercised offline (it needs a firmware, and the cross-build is the container's
# job), so these assert the mechanism is still IN the patch that builds the module.
echo
echo "stage 2 scopes its ESP sweep to the disk it was loaded from"
MODPATCH="$ROOT/boot/patches/grub/0002-add-the-novadeck-stage-2-module.patch"
if [ ! -f "$MODPATCH" ]; then
  bad "missing $(basename "$MODPATCH") — the boot-attempts counter has no module to build"
else
  grep -q 'grub_efi_get_loaded_image (grub_efi_image_handle)' "$MODPATCH" \
    && ok "the module asks the loaded image which disk stage 2 came from" \
    || bad "the module never reads its own loaded image — it cannot know its disk"
  grep -q 'GRUB_EFI_HARD_DRIVE_DEVICE_PATH_SUBTYPE' "$MODPATCH" \
    && ok "same-disk is decided by the device-path prefix before the HD() node" \
    || bad "the module does not split device paths at the HARD_DRIVE node"
  # Ordering is the assertion: the guard has to sit between the handle loop and the open, or it is
  # decoration. Line numbers, not text shape, so reformatting the loop does not fail this.
  ln_for=$(grep -n 'for (i = 0; handles' "$MODPATCH" | head -1 | cut -d: -f1)
  ln_same=$(grep -n 'same_disk (self_dp, self_len' "$MODPATCH" | head -1 | cut -d: -f1)
  ln_try=$(grep -n 'fh = try_handle (handles\[i\]' "$MODPATCH" | head -1 | cut -d: -f1)
  if [ -n "$ln_for" ] && [ -n "$ln_same" ] && [ -n "$ln_try" ] \
     && [ "$ln_for" -lt "$ln_same" ] && [ "$ln_same" -lt "$ln_try" ]; then
    ok "the sweep tests same_disk before it opens a conf"
  else
    bad "the handle sweep opens a conf without a same_disk test — it can count the boot on the other disk's ESP"
  fi
fi

# The rule enumerates no partition names on purpose -- it copies ID_PART_ENTRY_NAME through -- so the
# only thing that can drift is the PREFIX it matches. Assert it covers every name in the table.
echo
echo "the rule's name match covers image/partition-table.txt"
while read -r _ _ _ _ label _; do
  case "$label" in ''|'#'*|'-') continue ;; esac
  case "$label" in
    novadeck-*|NOVADECK-*) ok "$label is matched by the rule's novadeck-*|NOVADECK-* prefix" ;;
    *) bad "$label is in the partition table but matches neither prefix in the rule — it would get no scoped link" ;;
  esac
done < <(grep -vE '^[[:space:]]*(#|$)' "$TABLE")

echo
printf 'boot-disk: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
