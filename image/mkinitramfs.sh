#!/usr/bin/env bash
# novadeck initramfs builder -> out/initramfs.cpio.gz (installed as /boot/initramfs-novadeck.img
# by rootfs/assemble-rootfs.sh; the slot's stage-2 grub.cfg boots it via `initrd`).
#
# Stages a handful of aarch64 binaries out of the base rootfs, resolves their shared
# libraries, adds image/initramfs/init, and rolls the lot into a newc cpio.
#
# Deliberately NOT mkinitcpio/dracut: the base is minimal core and ships neither, and we
# need no modules anyway — btrfs/ext4/overlayfs and every block driver are =y in
# kernel.config (the device booted for months with no initramfs at all). So the whole job
# is "mount the slot's root + var + efi partition, stack the /etc overlay, switch_root",
# which is a shell script and ~5 binaries. Slot selection is NOT here (Phase 5) — the
# bootloader chain chose it and wrote the cmdline (docs/phase5.md).
#
# Library resolution walks DT_NEEDED with readelf rather than calling ldd: these are aarch64
# ELFs staged on an x86_64 build host, so nothing here can be executed to introspect it.
#
#   image/mkinitramfs.sh <base-rootfs-dir>
#   BASE_ROOTFS=<dir> image/mkinitramfs.sh
#
# Run inside the build image (needs readelf + cpio + gzip):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build image/mkinitramfs.sh work/base
set -euo pipefail

BASE="${1:-${BASE_ROOTFS:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
INIT="$ROOT/image/initramfs/init"
IMG="$OUT/initramfs.cpio.gz"

# /bin/sh is bash (the base has no busybox); the rest is util-linux + coreutils. findfs
# resolves root=/novadeck.var=/steamos.efi=PARTUUID= specs without udev; mkdir creates the
# overlay upper/work and the /efi mountpoint on first boot; sleep paces the device-probe poll.
#
# NO umount: the init mounts only INSIDE the btrfs root ($SYSROOT/efi, $SYSROOT/var), so every
# mount survives switch_root attached to the new root's filesystem, and the shared ESP is never
# mounted at all (the booted system mounts it at /esp from /etc/fstab). The old design-C need
# for a pre-switch_root umount — a still-mounted initramfs-root /esp becoming an orphan and
# gpt-auto mounting the same vfat twice — is gone with the ESP-state code.
BINS=(bash mount switch_root findfs mkdir sleep)

# The boot splash. Three files, staged whole rather than resolved through copy_deps() below,
# because the drawer is STATIC on purpose (apps/novadeck-splash/src/novadeck-splash.c explains
# why at length: the cross toolchain's glibc is newer than the image's, and the process has to
# outlive switch_root, which frees every .so out from under it). If it ever grows a DT_NEEDED,
# the assertion after staging catches it — that would mean the static link silently stopped
# working, which is exactly the failure that shows up as a black panel and nothing else.
SPLASH_BIN="$ROOT/apps/novadeck-splash/build/novadeck-splash"
SPLASH_ASSET="$ROOT/work/splash/logo.nds1"
# The status line is what makes the splash worth having; without a font it degrades to a bare
# logo, which is the old plymouth behaviour and not what we are shipping.
SPLASH_FONT="$BASE/usr/share/fonts/noto/NotoSansMono-Medium.ttf"

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
# /sysroot is where the slot's root (and, inside it, /var + /efi) is mounted; /run/novadeck is
# NOT pre-created here -- /run is over-mounted with a fresh tmpfs, so a directory staged in the
# cpio would be invisible; the init mkdirs it at runtime.
mkdir -p "$stage"/{usr/bin,usr/lib,proc,sys,dev,run,sysroot}
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

# --- boot splash --------------------------------------------------------------------------
# Missing pieces are a hard error, not a warning. A splash that silently is not in the cpio
# produces a black panel for the whole of early boot and no evidence anywhere, on a device with
# no serial console — the single most expensive failure shape this project has.
for f in "$SPLASH_BIN" "$SPLASH_ASSET" "$SPLASH_FONT"; do
  [ -f "$f" ] || { echo "missing splash input: ${f#"$ROOT"/} (run \`make splash\`)" >&2; exit 1; }
done
# Prove the drawer really is static before it is sealed into an image. A dynamic binary here
# would load nothing after switch_root and paint nothing before it.
if readelf -d "$SPLASH_BIN" 2>/dev/null | grep -q '(NEEDED)'; then
  echo "$(basename "$SPLASH_BIN") is dynamically linked; it must be static" >&2
  readelf -d "$SPLASH_BIN" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/  needs \1/p' >&2
  exit 1
fi
mkdir -p "$stage/usr/lib/novadeck" "$stage/usr/share/novadeck/splash"
install -m0755 "$SPLASH_BIN"   "$stage/usr/lib/novadeck/novadeck-splash"
install -m0644 "$SPLASH_ASSET" "$stage/usr/share/novadeck/splash/logo.nds1"
install -m0644 "$SPLASH_FONT"  "$stage/usr/share/novadeck/splash/font.ttf"

# newc cpio, gzip (CONFIG_RD_GZIP=y). Ownership comes from the build user — root in the
# build container, which is what the kernel should unpack as. Refuse to build a cpio whose
# files would land owned by a non-root uid.
[ "$(id -u)" -eq 0 ] || { echo "must run as root (else initramfs files are not root-owned)" >&2; exit 1; }

mkdir -p "$OUT"
( cd "$stage" && find . -print0 | sort -z | cpio --null -o -H newc --quiet ) \
  | gzip -9 >"$IMG"

echo "[novadeck] initramfs: ${#BINS[@]} binaries, ${#copied[@]} libraries, splash (static) -> ${IMG#"$ROOT"/} ($(du -h "$IMG" | cut -f1))"
