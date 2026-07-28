#!/usr/bin/env bash
# novadeck initramfs builder -> out/initramfs.cpio.gz (picked up by boot/package.sh).
#
# Stages a handful of aarch64 binaries out of the base rootfs, resolves their shared
# libraries, adds images/initramfs/init, and rolls the lot into a newc cpio.
#
# Deliberately NOT mkinitcpio/dracut: the base is minimal core and ships neither, and we
# need no modules anyway — btrfs/ext4/overlayfs and every block driver are =y in
# kernel.config (the device booted for months with no initramfs at all). So the whole job
# is "pick the A/B slot, mount its root + var, stack the /etc overlay, and switch_root",
# which is a shell script and ~7 binaries.
#
# Library resolution walks DT_NEEDED with readelf rather than calling ldd: these are aarch64
# ELFs staged on an x86_64 build host, so nothing here can be executed to introspect it.
#
#   images/mkinitramfs.sh <base-rootfs-dir>
#   BASE_ROOTFS=<dir> images/mkinitramfs.sh
#
# Run inside the build image (needs readelf + cpio + gzip):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/mkinitramfs.sh work/base
set -euo pipefail

BASE="${1:-${BASE_ROOTFS:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
INIT="$ROOT/images/initramfs/init"
IMG="$OUT/initramfs.cpio.gz"

# /bin/sh is bash (the base has no busybox); the rest is util-linux + coreutils. findfs
# resolves root=PARTLABEL=... without udev; mkdir creates the overlay upper/work on first
# boot; sleep paces the device-probe poll.
#
# umount is for the ESP, and it is a correctness requirement rather than tidiness: switch_root
# moves only {/dev,/proc,/sys,/run} into the new root (see the init's own note at its /run
# mount), so a still-mounted /esp would survive as an orphan mount with no path and never be
# flushed -- and then systemd's gpt-auto generator mounts THE SAME vfat device a second time at
# /efi. Two concurrent rw FAT mounts of one device corrupt it.
#
# NOTHING ELSE BELONGS HERE. Every ESP read and write in images/initramfs/init is a bash
# builtin (read, printf, case, [), and the A/B slot-state format was chosen specifically so
# that stays true -- see the state-file section of the init's header before adding cat, cp, mv,
# dd or sync here.
# cp: the rollback path restores the previous kernel (KERNEL.BAK -> KERNEL) on the ESP. A ~30MB
# vfat file is not a shell-builtin job, and this is the one place the init writes something other
# than the small state file.
BINS=(bash mount umount switch_root findfs mkdir sleep cp)

[ -n "$BASE" ] || { echo "usage: mkinitramfs.sh <base-rootfs-dir>" >&2; exit 2; }
[ -d "$BASE" ] || { echo "no base rootfs dir: $BASE" >&2; exit 2; }
[ -f "$INIT" ] || { echo "no init script: $INIT" >&2; exit 1; }
for t in readelf cpio gzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found (run inside novadeck-build)" >&2; exit 1; }
done

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"   # mktemp -d is 0700; that mode would become the initramfs root's

# Pre-create every directory init needs, so it never has to mkdir before /dev exists.
# /bin, /sbin and /lib are symlinks into /usr, matching the base's merged-usr layout — the
# binaries' hardcoded PT_INTERP (/lib/ld-linux-aarch64.so.1) resolves through /lib.
# /esp is where the ESP is mounted to read the A/B slot state; it is unmounted again before
# switch_root. /run/novadeck is NOT pre-created here -- /run is over-mounted with a fresh
# tmpfs, so a directory staged in the cpio would be invisible; the init mkdirs it at runtime.
mkdir -p "$stage"/{usr/bin,usr/lib,proc,sys,dev,run,sysroot,esp}
ln -s usr/bin "$stage/bin"
ln -s usr/bin "$stage/sbin"
ln -s usr/lib "$stage/lib"
ln -s bash    "$stage/usr/bin/sh"

# Recursively copy a binary's DT_NEEDED libraries, plus its PT_INTERP loader (which is not
# always listed in DT_NEEDED — findfs, for one, omits it).
declare -A copied=()
copy_deps() {
  local elf="$1" lib src interp
  while read -r lib; do
    [ -n "$lib" ] || continue
    [ -n "${copied[$lib]:-}" ] && continue
    copied[$lib]=1
    src="$BASE/usr/lib/$lib"
    [ -e "$src" ] || { echo "missing library $lib (needed by ${elf#"$BASE"/})" >&2; exit 1; }
    cp -L "$src" "$stage/usr/lib/$lib"
    copy_deps "$src"
  done < <(readelf -d "$elf" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')

  interp="$(readelf -l "$elf" 2>/dev/null \
    | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
  if [ -n "$interp" ]; then
    lib="$(basename "$interp")"
    if [ -z "${copied[$lib]:-}" ]; then
      copied[$lib]=1
      cp -L "$BASE/usr/lib/$lib" "$stage/usr/lib/$lib"
    fi
  fi
}

for b in "${BINS[@]}"; do
  src="$BASE/usr/bin/$b"
  [ -x "$src" ] || { echo "missing binary: usr/bin/$b in ${BASE}" >&2; exit 1; }
  cp -L "$src" "$stage/usr/bin/$b"
  copy_deps "$src"
done

install -m0755 "$INIT" "$stage/init"

# newc cpio, gzip (CONFIG_RD_GZIP=y). Ownership comes from the build user — root in the
# build container, which is what the kernel should unpack as. Refuse to build a cpio whose
# files would land owned by a non-root uid.
[ "$(id -u)" -eq 0 ] || { echo "must run as root (else initramfs files are not root-owned)" >&2; exit 1; }

mkdir -p "$OUT"
( cd "$stage" && find . -print0 | sort -z | cpio --null -o -H newc --quiet ) \
  | gzip -9 >"$IMG"

echo "[novadeck] initramfs: ${#BINS[@]} binaries, ${#copied[@]} libraries -> ${IMG#"$ROOT"/} ($(du -h "$IMG" | cut -f1))"
