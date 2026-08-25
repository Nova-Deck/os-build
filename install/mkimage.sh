#!/usr/bin/env bash
# novadeck INSTALLER medium image builder. Phase 6 of .claude/plans/internal-install.plan.md.
#
#   install/mkimage.sh [installer-rootfs-dir]     (default: work/installer-base)
#
# Writes out/images/installer.img — a flashable two-partition medium that boots on the handheld,
# draws the consent screen on the panel, and installs NovaDeck to the device's internal disk.
#
# RUN INSIDE THE BUILD IMAGE. It needs mksquashfs, sgdisk, mkfs.vfat, mtools and grub-editenv, and
# it must run as root to preserve the ownership pacman gave work/installer-base — a squashfs built
# by the host user would put every file on the medium under uid 1000, and the installer runs as
# root against a stranger's disk. install/mkroot.sh is the host-side half (its only container is
# the emulated pacman); this is the container-side half. Same division as
# images/customize-base.sh -> images/assemble-rootfs.sh, and the reason the plan's sketch of
# mksquashfs-inside-mkroot.sh was not followed.
#
# UNPRIVILEGED IN THE SENSE THAT MATTERS: no loop devices and no mounts. Each filesystem is built
# in a plain FILE (mksquashfs from a directory, mtools into a FAT image) and then dd'd into the
# partition at the offset sgdisk assigned it. That is images/make-sdcard.sh's technique, and it is
# what lets the whole medium be assembled in a container with no privileged flags.
#
# THE BOOT CHAIN IS SHORTER THAN THE CARD'S, BY ONE LINK. The shipped card is
# ABL -> steamcl.efi -> stage-2 GRUB on the slot's efi partition -> kernel in the slot root. steamcl
# is the A/B SLOT CHOOSER: it reads /SteamOS/conf/{A,B}.conf, matches partsets, and picks. This
# medium has one root, so there is nothing for it to choose and its conf files would be fiction.
# GRUB goes straight in at \EFI\BOOT\bootaa64.efi, which is the path ABL loads by CONTENT (not by
# partition type) — see [[abl-internal-efi-path-works]]. boot/grub.sh builds the binary with
# `-p /EFI/steamos`, and that prefix is relative to the partition it was loaded FROM, so the config
# it reads is /EFI/steamos/grub.cfg on this same ESP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-${INSTALLER_ROOTFS:-$ROOT/work/installer-base}}"
OUT="$ROOT/out/images"
BOOT="$ROOT/out/boot"
IMG="$OUT/installer.img"
TABLE="$ROOT/install/medium-table.txt"
GENPART="$ROOT/images/genpart.sh"
GENCFG="$ROOT/install/gen-grub-cfg.sh"
KERNEL="$ROOT/out/Image"
DTBDIR="$ROOT/out/dtbs"
GRUB_EFI="$BOOT/grubaa64.efi"
GRUB_FONT="$BOOT/fonts/dejavu-mono.pf2"
WIFI_EXAMPLE="$ROOT/install/wifi.conf.example"
WORK="$ROOT/work/installer-image"

log() { echo "[novadeck] $*" >&2; }
die() { echo "$*" >&2; exit 1; }

for t in mksquashfs sgdisk mkfs.vfat mcopy mmd; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found — run this inside the build image"
done
for f in "$TABLE" "$GENPART" "$GENCFG" "$KERNEL" "$GRUB_EFI" "$GRUB_FONT"; do
  [ -e "$f" ] || die "missing input: ${f#"$ROOT"/}"
done
[ -d "$DTBDIR" ] || die "missing input: ${DTBDIR#"$ROOT"/}"
[ -f "$BASE/usr/lib/novadeck/pkgs" ] \
  || die "${BASE#"$ROOT"/} is not a finished installer root — run install/mkroot.sh first"
# The marker install/mkroot.sh writes LAST. Its absence means a bootstrap died partway, and a
# squashfs of a half-populated tree is an image that boots to a panel and then cannot install.

# Refuse to build a medium out of the SHIPPED root. Both are directories full of a Linux system and
# the argument is positional, so the mistake is one word wide — and the result would be an
# "installer" with no install code on it, discovered on hardware.
grep -q '^ID=novadeck-installer$' "$BASE/etc/os-release" 2>/dev/null \
  || die "${BASE#"$ROOT"/} does not identify as novadeck-installer — wrong tree?"

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

# --- 0. the medium's identity ----------------------------------------------------------------------
# WHICH IMAGE AM I LOOKING AT. install/os-release is deliberately static so a rebuild does not churn
# the tree, and until this block every installer medium ever built answered identically — the same
# NAME, the same ID, no version, no date. That is the first question a person asks at the fallback
# console, which exists precisely for the moment something has gone wrong, and the medium could not
# answer it. Same shape as images/assemble-rootfs.sh section 4a: one stamp, in one place, read back
# by everything downstream.
#
# STAMPED HERE AND NOT IN install/mkroot.sh, because this is the half that makes an ARTIFACT.
# mkroot's tree is reused across builds on its own input key — a per-build timestamp written there
# would either bust that cache on every run (a full emulated pacstrap) or, worse, survive a reuse
# and describe a build that happened yesterday. The root is the cacheable part; the image is the
# published part; the identity belongs to the published part.
#
# IDEMPOTENT BY CONSTRUCTION: os-release is REWRITTEN from the committed file plus this block, never
# appended to. The tree it lands in is cached, so appending would stack a fresh block on every
# `make installer` until the file carried a dozen contradictory VERSION= lines, the last one
# winning by accident.
#
# THE MODE IS READ OUT OF THE TREE, NOT OUT OF THE ENVIRONMENT. install/mkroot.sh folds `dev:0|1`
# into the reuse marker it installs at /usr/lib/novadeck/pkgs, so the tree states what was baked
# into it. Deriving it from $NOVADECK_DEV here would let `NOVADECK_DEV=1 make installer-root`
# followed by a plain `make installer` stamp `release` on a medium carrying an authorized_keys and
# a Wi-Fi PSK — the exact drift assemble-rootfs.sh's "both read the one flag" note is about, except
# that here the two halves are separate processes and cannot share a variable.
OSRELEASE_SRC="$ROOT/install/os-release"
[ -f "$OSRELEASE_SRC" ] || die "missing input: ${OSRELEASE_SRC#"$ROOT"/}"
if grep -qx 'dev:1' "$BASE/usr/lib/novadeck/pkgs" 2>/dev/null; then
  IMG_MODE=dev
else
  IMG_MODE=release
fi
IMG_VERSION="${NOVADECK_VERSION:-dev}"
IMG_GIT="${NOVADECK_GIT:-unknown}"
IMG_BUILD="$(date -u +%Y%m%dT%H%M%SZ)"
{
  echo "NOVADECK_VARIANT=installer"
  echo "NOVADECK_BUILD=$IMG_BUILD"
  echo "NOVADECK_VERSION=$IMG_VERSION"
  echo "NOVADECK_GIT=$IMG_GIT"
  echo "NOVADECK_MODE=$IMG_MODE"
} >"$BASE/etc/novadeck-release"
chmod 0644 "$BASE/etc/novadeck-release"
{
  cat "$OSRELEASE_SRC"
  echo "VARIANT=\"installer\""
  echo "VARIANT_ID=installer"
  echo "VERSION_ID=$IMG_VERSION"
  echo "VERSION=\"$IMG_VERSION ($IMG_GIT)\""
  echo "BUILD_ID=$IMG_BUILD"
} >"$BASE/etc/os-release"
chmod 0644 "$BASE/etc/os-release"
# The same fields OUTSIDE the image, as a sidecar beside it. A publisher must be able to name the
# artifact without mounting a squashfs out of the middle of a GPT — images/genbundle.sh reads
# rootfs.release for exactly that reason, and a release workflow for this medium will want the same.
cp "$BASE/etc/novadeck-release" "$OUT/installer.release"
log "identity: $IMG_VERSION ($IMG_GIT) build $IMG_BUILD, mode $IMG_MODE"
[ "$IMG_MODE" = release ] || log "NOTE: this medium was built from a DEV root (sshd + baked Wi-Fi)"

# --- 1. the root filesystem ------------------------------------------------------------------------
# zstd because the kernel has CONFIG_SQUASHFS_ZSTD=y and it is the best ratio of the three the
# kernel can read. -noappend so a rebuild replaces rather than accumulating; -no-xattrs is NOT set
# because the tree carries capabilities (ping, and anything pacman set) that must survive.
squash="$WORK/root.squashfs"
log "compressing the installer root (this is the slow step)"
mksquashfs "$BASE" "$squash" -comp zstd -Xcompression-level 19 -noappend -quiet \
  -e boot   # nothing boots FROM the root here: the kernel and dtbs live on the ESP
squash_mib=$(( ( $(stat -c%s "$squash") + 1048575 ) / 1048576 ))
log "root.squashfs: ${squash_mib}M (from $(du -sh "$BASE" 2>/dev/null | cut -f1))"

# --- 2. the GPT ------------------------------------------------------------------------------------
# The medium is sized to its content plus slack, not to a card: this image is published and
# downloaded, and `rest` in the table expands to whatever the file happens to be. images/genpart.sh
# emits the sgdisk script from the table exactly as it does for the shipped card.
esp_mib=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} $1=="esp"{sub(/M$/,"",$2); print $2; exit}' "$TABLE")
[ -n "$esp_mib" ] || die "cannot read the esp size from ${TABLE#"$ROOT"/}"
# 1M of GPT at each end, plus 64M of slack so the medium is not exactly full — a filesystem with
# zero free sectors behind it is the kind of thing that works until one package grows.
total_mib=$(( 1 + esp_mib + squash_mib + 64 + 1 ))
truncate -s "${total_mib}M" "$IMG"
# The env var is images/genpart.sh's own override for which table it reads; it defaults to the
# eight-partition shipped one sitting beside it, which is precisely what must NOT be used here.
NOVADECK_PARTITION_TABLE="$TABLE" "$GENPART" "$IMG" >/dev/null
sgdisk -p "$IMG" >&2

part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }
part_start() { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
ROOT_UUID="$(part_uuid 2)"
[ -n "$ROOT_UUID" ] || die "sgdisk did not report a partition uuid for p2"

# --- 3. the ESP ------------------------------------------------------------------------------------
# -F 32 is forced here for the same reason images/make-sdcard.sh forces it, and install/medium-table.txt
# carries the full argument: the filesystem is built inside an image FILE, where mkfs.vfat sees
# 512-byte sectors regardless of the eventual target, and every installer medium is removable and
# therefore 512e. The 4Kn hazard the shipped table warns about cannot reach this partition.
esp="$WORK/esp.img"
truncate -s "${esp_mib}M" "$esp"
mkfs.vfat -F 32 -n NDINSTALLER "$esp" >/dev/null

fatdir() {  # <img> <msdos path, no leading '::'>
  local img="$1" path="$2" p=""
  local IFS=/
  for c in $path; do p="${p:+$p/}$c"; mmd -i "$img" "::$p" >/dev/null 2>&1 || true; done
}
fatdir "$esp" EFI/BOOT
fatdir "$esp" EFI/steamos/fonts
fatdir "$esp" dtbs
fatdir "$esp" novadeck

# The Wi-Fi template, at the path install/netcfg reads its real counterpart from
# (/esp/novadeck/wifi.conf). HW-FOUND 2026-08-24: the no-Wi-Fi screen has always told the operator
# to "copy wifi.conf.example next to it", and THE FILE HAD NEVER EXISTED -- nothing in this tree
# wrote one and nothing put it on a medium. Instructions naming a file that is not there are worse
# than no instructions: they read as a fault in the person following them.
[ -f "$WIFI_EXAMPLE" ] || die "missing ${WIFI_EXAMPLE#"$ROOT"/} — the no-Wi-Fi screen tells the user to copy it"
mcopy -i "$esp" "$WIFI_EXAMPLE" ::/novadeck/wifi.conf.example

# GRUB itself, at the removable-media path ABL loads. No steamcl: see the header.
mcopy -i "$esp" "$GRUB_EFI" ::/EFI/BOOT/bootaa64.efi
mcopy -i "$esp" "$GRUB_FONT" ::/EFI/steamos/fonts/dejavu-mono.pf2

# The config, generated against the partition uuid sgdisk just assigned. Generated AFTER the GPT
# exists, not before: the uuid is an output of laying the table, and a config written first would
# have to guess it.
cfg="$WORK/grub.cfg"
"$GENCFG" "$ROOT_UUID" "$cfg"
mcopy -i "$esp" "$cfg" ::/EFI/steamos/grub.cfg

# NO grubenv. The medium remembers nothing on purpose (install/gen-grub-cfg.sh's header): it travels
# between boards, so a saved board choice is a card that installed one device preselecting its
# devicetree on the next, different one — and a wrong DTB is worse than re-picking. Nothing else on
# this medium needs an environment block either; there is no boot-attempt counting on a medium with
# nothing to fall back to.

# The kernel and every dtb, at the FAT root. GRUB reads them from the partition it booted from.
mcopy -i "$esp" "$KERNEL" ::/Image
dtb_n=0
for dtb in "$DTBDIR"/*.dtb; do
  [ -e "$dtb" ] || continue
  mcopy -i "$esp" "$dtb" "::/dtbs/$(basename "$dtb")"
  dtb_n=$((dtb_n + 1))
done
[ "$dtb_n" -gt 0 ] || die "no dtbs copied from ${DTBDIR#"$ROOT"/} — every menuentry would fail"
# NOT "grub + grubenv + ...", which is what this line said until 2026-08-25 — twenty lines below the
# block explaining why this medium deliberately writes NO grubenv, and contradicting it. A build log
# is read by someone diagnosing a medium that did not boot, and a file named there that is not on
# the partition sends them looking for a fault in the wrong half.
log "ESP: grub + wifi.conf.example + Image + $dtb_n dtbs (no grubenv: this medium remembers nothing)"

# --- 4. write the filesystems into their partitions ---------------------------------------------------
# Every populated filesystem must fit the slot the table gave it. A silently truncated dd produces a
# medium that boots into a corrupt filesystem, which is a much worse failure than this one.
write_part() {  # <partnum> <file> <what>
  local start size_mib avail_mib
  start=$(part_start "$1")
  [ -n "$start" ] || die "cannot read the start sector of p$1"
  size_mib=$(( ( $(stat -c%s "$2") + 1048575 ) / 1048576 ))
  avail_mib=$(( ( $(sgdisk -i "$1" "$IMG" | sed -n 's/^Partition size: \([0-9]*\).*/\1/p') * 512 ) / 1048576 ))
  [ "$size_mib" -le "$avail_mib" ] \
    || die "$3 is ${size_mib}M but p$1 is only ${avail_mib}M"
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  log "p$1 <- $3 (${size_mib}M of ${avail_mib}M)"
}
write_part 1 "$esp" "esp"
write_part 2 "$squash" "root.squashfs"

sync
log "installer image ready: ${IMG#"$ROOT"/} ($(du -h "$IMG" | cut -f1))"
echo "  flash with:  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress" >&2
echo "$IMG"
