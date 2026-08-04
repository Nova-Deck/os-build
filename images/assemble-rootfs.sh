#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 5.
#
# Stages a base rootfs, injects the novadeck kernel + dtbs + initramfs (from kernel/build.sh and
# images/mkinitramfs.sh) and the device firmware (from firmware/fetch-qcom-fw.sh), then splits
# the staged tree into the TWO filesystem images the partition table wants
# (images/partition-table.txt):
#
#   out/images/rootfs.img  btrfs, ro   -> rootfs-a   the sealed system
#   out/images/var.img     ext4,  rw   -> var-a      writable state + the /etc overlay upper
#
# Both are built unprivileged: `mkfs.btrfs --rootdir`, `mkfs.ext4 -d` — no root, no loop mount.
#
# The root's content is read-only by construction; the subvolume's ro *property* is
# set by RAUC at deploy time (needs a mount), so it is not applied here. The kernel mounts
# it `ro` regardless (rootfstype=btrfs ... ro on the stage-2 grub.cfg cmdline).
#
# The root carries its own boot half (docs/phase5.md): /boot/{Image, initramfs-novadeck.img,
# dtbs} that the slot's stage-2 GRUB boots, plus the /usr/lib/novadeck/boot mirror + the
# /esp//efi mountpoints the update path reads. The stage-1/2 binaries reach the cards through
# the ESP/efi partitions laid by images/make-sdcard.sh and refreshed by the RAUC hook.
#
#   images/assemble-rootfs.sh <base-rootfs-dir>
#   BASE_ROOTFS=<dir> images/assemble-rootfs.sh
#
# Run inside the build image (needs btrfs-progs + rsync):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/assemble-rootfs.sh sm8650 /path/to/base
set -euo pipefail
shopt -s nullglob

BASE="${1:-${BASE_ROOTFS:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
FW="$ROOT/firmware/qcom-fw"
LFW="$ROOT/firmware/linux-fw"
IMGDIR="$OUT/images"
IMG="$IMGDIR/rootfs.img"
VARIMG="$IMGDIR/var.img"     # -> var-a  (ext4, carries the /etc overlay upper+work)
VARIMG_B="$IMGDIR/var-b.img" # -> var-b  (identical but for /var/lib/novadeck/slot; see section 5)
# The rootfs image is auto-sized by mkfs.btrfs --rootdir --shrink (see section 6); no fixed SIZE.
VAR_SIZE_MIB="${VAR_SIZE_MIB:-256}"   # matches var-a/-b in partition-table.txt (a hard ceiling)

[ -n "$BASE" ]        || { echo "usage: assemble-rootfs.sh <base-rootfs-dir>" >&2; exit 2; }
[ -d "$BASE" ]        || { echo "no base rootfs dir: $BASE" >&2; exit 2; }
[ -f "$OUT/Image" ]       || { echo "no kernel: $OUT/Image (run kernel/build.sh first)" >&2; exit 1; }
[ -f "$OUT/initramfs.cpio.gz" ] || { echo "no initramfs: $OUT/initramfs.cpio.gz (run make initramfs)" >&2; exit 1; }
command -v mkfs.btrfs >/dev/null 2>&1 || { echo "mkfs.btrfs not found (run inside novadeck-build)" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
echo "[novadeck] assembling unified read-only root (base=$BASE)"

# 1. base userspace (the Holo aarch64 preview rootfs)
if command -v rsync >/dev/null 2>&1; then rsync -aHAX --numeric-ids "$BASE"/ "$stage"/
else cp -a "$BASE"/. "$stage"/; fi

# NOTHING TO SCRUB (Phase 4c). This is where sanitize_base_provenance() used to run: the tree
# arrived as `docker export` of a vendor-built image, so it started life carrying two other build
# systems' artifacts (docker's /.dockerenv, the vendor CI's `repos` and
# `etc/mash-ci-tracking.job_id`), and every one had to be found by audit and removed by hand.
# images/provenance.list declared them, this scrubbed them and guard-rootfs.sh asserted the
# removal. All three are gone: the root is bootstrapped from packages, so no container filesystem
# and no vendor image contributes bytes to it and there is nothing to remove.
#
# Also inherited-and-now-ours, handled at the source in images/customize-base.sh rather than
# patched up here: /etc/os-release (images/os-release), /etc/locale.conf and /etc/hostname.
# Still deliberately left alone: /etc/{resolv.conf,hosts} (NetworkManager populates resolv.conf
# at runtime, DNS verified working on HW) and /etc/machine-id, which must stay absent so systemd
# runs preset-all on first boot — populating it would disable our preset-based service enablement.
#
# NOT closed by 4c, and NOT covered by anything here: packages/inputplumber's prebuilt tarball is
# still unpacked at `/` with strip-components=1 (images/customize-base.sh), so a third-party
# archive can still place arbitrary paths in the root. Two marker names were never a guard for
# that; see TODO.md for the real one (assert every file is package-owned or declared).

# 2. novadeck kernel + dtbs + initramfs under /boot. These are what the stage-2 grub.cfg boots
# (docs/phase5.md): `linux ($root)/boot/Image`, `initrd ($root)/boot/initramfs-novadeck.img`,
# `devicetree ($root)/boot/dtbs/<dtb>.dtb`. The kernel must be the UNCOMPRESSED Image — the
# embedded gzio filter is not in grubaa64.efi's module set, so Image.gz would not decompress.
install -Dm0644 "$OUT/Image" "$stage/boot/Image"
install -Dm0644 "$OUT/initramfs.cpio.gz" "$stage/boot/initramfs-novadeck.img"
for dtb in "$OUT"/dtbs/*.dtb; do install -Dm0644 "$dtb" "$stage/boot/dtbs/$(basename "$dtb")"; done

# 2b. loadable kernel modules under /lib/modules (from kernel/build.sh modules_install).
# The =m drivers (e.g. handheld panels) live here; without them display won't probe.
MODROOT="$OUT/modroot"
if [ -d "$MODROOT/lib/modules" ]; then
  mkdir -p "$stage/lib"
  cp -a "$MODROOT/lib/modules" "$stage/lib/"
else
  echo "  (no staged modules at ${MODROOT#"$ROOT"/} — run kernel/build.sh; built-in drivers only)"
fi

# 2c. /esp + /efi mountpoints (Phase 5). The two boot homes the OS must see are the shared ESP
# and the booted slot's own efi partition:
#   /esp  the shared ESP (p1, the only ef00) — SteamOS/conf + steamcl. Mounted HERE by /etc/fstab
#         (below); gpt-auto is switched off for it by GPT bit 63 in partition-table.txt, because
#         gpt-auto would otherwise mount it at /efi — which is the name the initramfs reserves for
#         the slot's efi partition. The root is read-only, so the mountpoint must pre-exist.
#   /efi  the booted slot's efi-a/b partition (p2/p3, typed 0700 so gpt-auto ignores them). The
#         initramfs mounts THIS partition here, from steamos.efi=PARTUUID= on the cmdline; the
#         mount persists across switch_root (it lives in the btrfs root). /boot/efi -> /efi is the
#         SteamOS convention for bootloader tooling that looks there.
install -dm0755 "$stage/esp"
install -dm0755 "$stage/efi"
ln -s /efi "$stage/boot/efi"

# 3. device-proprietary firmware under /lib/firmware (paths are already /lib/firmware-relative).
# Fetched from the qcom-firmwares repo by firmware/fetch-qcom-fw.sh.
if [ -d "$FW" ]; then
  while IFS= read -r f; do
    rel="${f#"$FW"/}"
    install -Dm0644 "$f" "$stage/lib/firmware/$rel"
  done < <(find "$FW" -type f ! -name sha256sums.txt 2>/dev/null)
else
  echo "  (no device firmware at ${FW#"$ROOT"/} — run firmware/fetch-qcom-fw.sh; continuing)"
fi

# 3b. open linux-firmware blobs (Adreno GPU, WCN7850 Wi-Fi/BT, Iris VPU) under
# /lib/firmware. The upstream base ships no /lib/firmware, so without this the GPU/BT/VPU
# firmware is absent at runtime. Staged by firmware/fetch-linux-fw.sh from the pin.
if [ -d "$LFW" ]; then
  while IFS= read -r f; do
    rel="${f#"$LFW"/}"
    install -Dm0644 "$f" "$stage/lib/firmware/$rel"
  done < <(find "$LFW" -type f ! -name .fetched.stamp 2>/dev/null)
else
  echo "  (no linux-firmware at ${LFW#"$ROOT"/} — run firmware/fetch-linux-fw.sh; GPU/BT/VPU firmware will be missing)"
fi

# 4. novadeck marker so the running system can identify the slot's provenance.
#
# This is the file images/os-release designates for per-build identity ("NO PER-BUILD FIELDS ... the
# per-build identity is written by images/assemble-rootfs.sh to /etc/novadeck-release, which is where
# anything wanting to know which image is running should look"), so the release name belongs here
# rather than churning the static os-release on every build.
#
# NOVADECK_VERSION is set by CI from the release tag (`card/v1.3.0` -> `1.3.0`, likewise `ota/`), and
# is empty for a local build — rendered `dev`, which is the honest answer for bytes that came off
# someone's box. Without these two fields the only per-build identity was a timestamp, which cannot
# answer "is this device on the card I flashed, or an OTA past it?".
# NOVADECK_MODE answers "is this a test image or a shippable one?", which nothing else could. A DEV
# image carries Wi-Fi credentials and an authorized_keys (section 4c below) and must never reach a
# device that is not the builder's own — yet a dev image signed with the real release key is
# INDISTINGUISHABLE from a release one to every check that existed before this line: the signature
# is over the bytes, not over their provenance, and version/build/git are stamped the same either
# way. ota/publish-bundle.sh refuses to publish a bundle that does not say `release` here.
#
# Derived from NOVADECK_DEV rather than from a mode string passed in, because that is the SAME
# variable the dev-only injection blocks below are gated on. The stamp cannot disagree with what
# actually went into the image, because both read the one flag.
mkdir -p "$stage/etc"
{
  echo "NOVADECK_VARIANT=unified"
  echo "NOVADECK_BUILD=$(date -u +%Y%m%dT%H%M%SZ)"
  echo "NOVADECK_VERSION=${NOVADECK_VERSION:-dev}"
  echo "NOVADECK_GIT=${NOVADECK_GIT:-unknown}"
  if [ "${NOVADECK_DEV:-}" = "1" ]; then echo "NOVADECK_MODE=dev"; else echo "NOVADECK_MODE=release"; fi
} >"$stage/etc/novadeck-release"

# The same three fields are needed OUTSIDE the image, by images/genbundle.sh: a RAUC bundle has to
# name the version it carries, and the OTA client compares that name against this very file on the
# device. Deriving it a second time from the environment is how those two drifted apart in the first
# place (see the Makefile's NOVADECK_VERSION block) — the bundle was date-stamped while the image
# called itself something else, and the comparison the whole update path rests on compared two
# unrelated strings. So the identity is stamped ONCE, here, and everything downstream reads it back.
#
# It is copied rather than re-generated for the same reason, and it is copied AT THE END of this
# script (section 5's `mkdir -p "$IMGDIR"` is the first thing that may create the directory) so a
# failed assembly cannot leave a sidecar describing an image that was never written.
release_file="$stage/etc/novadeck-release"

# 4b. RELEASE overlay payload (SteamOS layers B/C/D). Every SoC-agnostic rootfs overlay —
# the gamescope-session plumbing, the HW-support backings, the InputPlumber device/profile
# config, the ALSA UCM2 machine profiles, the FEX runtime config and the native arm64 Steam
# shell — lives in ONE filesystem-mirror tree under fs-overlay/ and is injected with a single
# cp -a. The tree already carries final target paths, executable bits (tracked in git) and the
# systemd presets + .wants symlinks that enable each service, so nothing is generated or chmod'd
# here. fs-overlay/README.md documents what each backing does and WHY (the per-layer rationale
# that used to live in this script). Ownership is normalized to root:root in step 4z below.
OVERLAY="$ROOT/fs-overlay"
if [ -d "$OVERLAY" ]; then
  echo "  injecting fs-overlay payload -> session + HW-support + InputPlumber + audio + FEX + Steam shell (ARMED: boots to Deck shell)"
  cp -a "$OVERLAY"/. "$stage/"
  rm -f "$stage/README.md"   # fs-overlay/README.md documents the tree; it is NOT rootfs content
else
  echo "  (no fs-overlay/ tree — skipping overlay injection)" >&2
fi

# --- RAUC: the device keyring and the slot's own kernel (Phase 4b pass 2) ----------------------
# Two things the overlay tree cannot carry, because both are BUILD OUTPUTS rather than static files.
#
# 1. The keyring. /etc/rauc/system.conf points at /etc/rauc/keyring.pem; it is installed here from
#    the committed CA so there is ONE copy in the repo (images/rauc/novadeck-ca.pem, which ci/
#    also signs bundles against) rather than a duplicate under fs-overlay that could drift.
#
# 2. The boot software, mirrored under /usr/lib/novadeck/boot (Phase 5; docs/phase5.md). The stage-1
#    steamcl and both per-slot stage-2 GRUB builds are owned by the same build that ships /boot/Image
#    and /lib/modules/<ver> inside this root, so carrying them here makes the pairing true by
#    construction: the RAUC post-install hook refreshes the ESP and the slot's efi partition FROM
#    this directory, so an update can never install a root whose boot chain does not boot it. This
#    directory replaces the old /usr/lib/novadeck/boot.img (Phase 1 /KERNEL flow).
#    steamos-bootconf (holo-bootconf) is installed as /usr/bin/steamos-bootconf — the boot state
#    reader both the RAUC backend (novadeck-bootctl) and the health service call.
CA_SRC="$ROOT/images/rauc/novadeck-ca.pem"
BOOTDIR_SRC="$OUT/boot"
[ -f "$CA_SRC" ] || { echo "no RAUC CA at ${CA_SRC#"$ROOT"/} (run ci/gen-signing-ca.sh)" >&2; exit 1; }
for f in steamcl.efi steamcl-version holo-bootconf fonts/default.pf2 \
         grubaa64.efi grub-a.cfg grub-b.cfg fonts/dejavu-mono.pf2; do
  [ -f "$BOOTDIR_SRC/$f" ] || { echo "no boot artifact: ${BOOTDIR_SRC#"$ROOT"/}/$f (run boot/steamcl.sh + boot/grub.sh)" >&2; exit 1; }
done
install -D -m0444 "$CA_SRC"      "$stage/etc/rauc/keyring.pem"
install -D -m0755 "$BOOTDIR_SRC/holo-bootconf" "$stage/usr/bin/steamos-bootconf"
install -d -m0755 "$stage/usr/lib/novadeck/boot/fonts"
install -D -m0444 "$BOOTDIR_SRC/steamcl.efi"      "$stage/usr/lib/novadeck/boot/steamcl.efi"
install -D -m0444 "$BOOTDIR_SRC/steamcl-version"  "$stage/usr/lib/novadeck/boot/steamcl-version"
install -D -m0444 "$BOOTDIR_SRC/fonts/default.pf2" "$stage/usr/lib/novadeck/boot/fonts/default.pf2"
install -D -m0444 "$BOOTDIR_SRC/grubaa64.efi"     "$stage/usr/lib/novadeck/boot/grubaa64.efi"
install -D -m0444 "$BOOTDIR_SRC/grub-a.cfg"       "$stage/usr/lib/novadeck/boot/grub-a.cfg"
install -D -m0444 "$BOOTDIR_SRC/grub-b.cfg"       "$stage/usr/lib/novadeck/boot/grub-b.cfg"
install -D -m0444 "$BOOTDIR_SRC/fonts/dejavu-mono.pf2" "$stage/usr/lib/novadeck/boot/fonts/dejavu-mono.pf2"
echo "  RAUC: keyring.pem + stage-1/2 boot software + /usr/bin/steamos-bootconf installed"

# Rewrite the baked Proton compat tools. We bake TWO — proton-cachyos and proton-ge — so the user
# can pick whichever runs a given title better from the Steam UI. Both are the same self-contained
# arm64 Wine + Valve WoW64-FEX Proton and ship identical toolmanifest.vdf / compatibilitytool.vdf
# shapes, so a single rewrite serves both. Every edit FAILS LOUDLY if upstream changes shape — a
# silently un-rewritten tool would refuse to launch, bypass our FEX tuning, or unpin games on a bump.
#
# rewrite_proton_tool <tool_dir> <stable_internal_name> <display_name> does, per tool:
#   toolmanifest.vdf:
#     1. Drop `require_tool_appid`. It names Valve's arm64 SLR container, which a non-Deckard client
#        never *registers* as a compat tool even when its files are installed. Steam then quietly
#        falls back to an older Proton instead of launching this one.
#     2. Point `commandline` at our wrapper, so per-game FEX tuning lands before Proton starts.
#   compatibilitytool.vdf:
#     3. Replace the tool's INTERNAL name. Upstream's is the dated build string (e.g.
#        proton-cachyos-11.0-20260602-slr-arm64 / GE-Proton11-1-aarch64), and Steam records THAT
#        internal name — not the directory — against every game it is forced on. Left as-is, a Proton
#        bump changes the internal name and silently unpins every game. Rewrite it to a stable,
#        version-free id so a bump is transparent. (The directory is already version-free via the
#        pin's `dest`; that alone does NOT stabilise what Steam pins by.)
#     4. Give it a friendly display_name (upstream reuses the dated build string there too).
# The display version is parsed per-tool at each call site (the `version` file format differs) and
# passed in, so this function stays build-agnostic.
rewrite_proton_tool() {
  local tool_dir="$1" stable_name="$2" display="$3"
  local manifest="$tool_dir/toolmanifest.vdf"
  [ -f "$manifest" ] || { echo "ERROR: Proton tool has no toolmanifest.vdf at $manifest" >&2; exit 1; }

  grep -q 'require_tool_appid' "$manifest" \
    || { echo "ERROR: Proton toolmanifest ($tool_dir) has no require_tool_appid — inspect before rewriting" >&2; exit 1; }
  sed -i '/require_tool_appid/d' "$manifest"

  grep -qE '"commandline"[[:space:]]+"/proton ' "$manifest" \
    || { echo "ERROR: Proton toolmanifest ($tool_dir) commandline is not \"/proton %verb%\" — inspect" >&2; exit 1; }
  sed -i 's#"commandline"[[:space:]]*"/proton #"commandline" "/novadeck-proton #' "$manifest"

  local ctool="$tool_dir/compatibilitytool.vdf"
  [ -f "$ctool" ] || { echo "ERROR: Proton tool has no compatibilitytool.vdf at $ctool" >&2; exit 1; }

  # The internal name is the first quoted string inside `compat_tools { ... }`; the display_name
  # is a `"display_name" "..."` pair. Both are matched positionally so an unexpected upstream shape
  # errors out rather than half-rewriting.
  python3 - "$ctool" "$stable_name" "$display" <<'PYVDF'
import re, sys
path, tool_name, display = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
text, n = re.subn(r'("compat_tools"\s*\{\s*(?://[^\n]*\n\s*)*)"[^"]+"', lambda m: m.group(1) + '"%s"' % tool_name, text, count=1)
if n != 1: sys.exit("compatibilitytool.vdf: could not find compat_tools internal name")
text, n = re.subn(r'("display_name"\s+)"[^"]+"', lambda m: m.group(1) + '"%s"' % display, text, count=1)
if n != 1: sys.exit("compatibilitytool.vdf: could not find display_name")
open(path, "w").write(text)
PYVDF

  # In-tool shim: Steam resolves `commandline` relative to the tool directory, so the wrapper is
  # reached through a path Steam accepts, while the wrapper itself stays a normal system file.
  cat >"$tool_dir/novadeck-proton" <<'PROTONSHIM'
#!/bin/sh
exec /usr/lib/novadeck/proton-wrapper "$(dirname "$0")/proton" "$@"
PROTONSHIM
  chmod 0755 "$tool_dir/novadeck-proton"
  echo "  wired Proton compat tool '$stable_name' ($display) — require_tool dropped, FEX wrapper in front, stable name"
}

COMPAT_DIR="$stage/usr/share/steam/compatibilitytools.d"
BAKED_PROTON=0

# CachyOS. `version` file format: "<epoch> cachyos-<ver>-...", e.g. "cachyos-11.0-20260703-slr".
PROTON_CACHY_TOOL="$COMPAT_DIR/proton-cachyos-11.0-arm64"   # dir == stable internal id
if [ -d "$PROTON_CACHY_TOOL" ]; then
  [ -f "$PROTON_CACHY_TOOL/version" ] || { echo "ERROR: CachyOS Proton tool has no version file at $PROTON_CACHY_TOOL/version" >&2; exit 1; }
  PVER="$(sed -n 's/.*cachyos-\([0-9][0-9.]*-[0-9]\{6,\}\).*/\1/p' "$PROTON_CACHY_TOOL/version")"
  [ -n "$PVER" ] || { echo "ERROR: could not parse CachyOS Proton version from $(cat "$PROTON_CACHY_TOOL/version")" >&2; exit 1; }
  rewrite_proton_tool "$PROTON_CACHY_TOOL" "proton-cachyos-11.0-arm64" "Proton ${PVER} (CachyOS, arm64)"
  BAKED_PROTON=1
fi

# GE (GloriousEggroll). `version` file format: "<epoch> GE-Proton<major>-<minor>", e.g. "GE-Proton11-1".
PROTON_GE_TOOL="$COMPAT_DIR/proton-ge-arm64"   # dir == stable internal id
if [ -d "$PROTON_GE_TOOL" ]; then
  [ -f "$PROTON_GE_TOOL/version" ] || { echo "ERROR: GE Proton tool has no version file at $PROTON_GE_TOOL/version" >&2; exit 1; }
  GEVER="$(sed -n 's/.*\(GE-Proton[0-9][0-9.-]*[0-9]\).*/\1/p' "$PROTON_GE_TOOL/version")"
  [ -n "$GEVER" ] || { echo "ERROR: could not parse GE Proton version from $(cat "$PROTON_GE_TOOL/version")" >&2; exit 1; }
  rewrite_proton_tool "$PROTON_GE_TOOL" "proton-ge-arm64" "${GEVER} (GloriousEggroll, arm64)"
  BAKED_PROTON=1
fi

[ "$BAKED_PROTON" = 1 ] || echo "  (no baked Proton compat tool — x86 Windows games will have no compat tool)" >&2

# 4g. First-boot STORAGE (the deck user's growable home). SteamOS sizes /home to the disk at
# install time; we dd a fixed image to a card, so we grow on first boot instead. Three pieces:
#  - /etc/fstab mounts the dedicated home partition (LABEL=novadeck-home, ext4) at /home. nofail so
#    a card without that partition (the old 2-partition test image) still boots.
#  - novadeck-grow-home: a oneshot that extends the home partition (systemd-repart) + its ext4
#    (resize2fs from e2fsprogs, in the base) to fill the device on first boot, before /home mounts.
#  - the deck user (uid 1000) is baked into the base /etc (customize-base.sh); the seeder above
#    materializes + chowns /home/deck on first boot. Steam (self-update + games) lives on /home.
#  The shared ESP is also fstab-mounted here, at /esp (Phase 5). It is the partition's only mount
#  definition: GPT bit 63 (partition-table.txt) keeps gpt-auto from auto-mounting it at /efi.
echo "  injecting first-boot storage: /home mount + grow (deck user baked in base)"
mkdir -p "$stage/etc"
if ! grep -q 'PARTLABEL=NOVADECK-ESP' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# novadeck shared ESP — SteamOS/conf + steamcl (stage 1). Mounted here at /esp; GPT bit 63' \
    '# keeps gpt-auto away so the initramfs can mount the slot efi partition at /efi instead.' \
    'PARTLABEL=NOVADECK-ESP  /esp  vfat  defaults,nofail,noatime  0 2' \
    >>"$stage/etc/fstab"
fi
if ! grep -q 'LABEL=novadeck-home' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# novadeck shared data partition — the deck user home + Steam library live here.' \
    '# novadeck-grow-home.service grows BOTH the partition (systemd-repart) and the ext4 (resize2fs)' \
    '# before this mounts. x-systemd.growfs stays only as a belt-and-suspenders fallback (a no-op' \
    '# once grow-home has already sized the fs to the partition).' \
    'LABEL=novadeck-home  /home  ext4  defaults,nofail,x-systemd.growfs  0 2' \
    >>"$stage/etc/fstab"
fi

# Grow the home PARTITION to fill the device with systemd-repart (declarative, online — it issues
# a BLKPG resize so it works while the disk is in use, and relocates the GPT backup header for us).
# The stock systemd-repart.service is initrd-only (no [Install], Before=initrd-root-fs.target) and
# our initramfs carries no systemd to run it, so ship our own unit running the same tool early in
# real-root boot, before /home mounts. repart matches our partition by its discoverable "Linux
# /home" GUID (typecode 8302 in images/partition-table.txt), so it can never touch the root
# partition. That same GUID would make systemd's gpt-auto generator synthesize a competing
# home.mount, so the partition also carries GPT bit 63 ("no-auto") — /etc/fstab below is the one
# and only definition of home.mount.
#
# The ext4 grow used to ride SOLELY on x-systemd.growfs (mount-time). That RACED home.mount: on HW
# the mount+growfs ran before repart's enlargement was visible, so the fs was sized to the flashed
# ~1G while the partition became 8.7G — /home then filled instantly and the Steam seed died with
# ENOSPC (SteamUI never started). Fix: novadeck-grow-home now runs a wrapper that does repart THEN
# resize2fs, ordered Before=home.mount so the fs grow is a race-free OFFLINE resize (partition
# already enlarged, /home not yet mounted). Idempotent — resize2fs is a no-op once the fs fills the
# partition, so it is safe to run every boot; x-systemd.growfs remains only as a fallback.
install -d -m0755 "$stage/usr/lib/repart.d"
cat >"$stage/usr/lib/repart.d/50-novadeck-home.conf" <<'REPART'
[Partition]
# Match the existing /home partition (Linux /home GUID) and grow it to claim free space at the end
# of the disk. No SizeMinBytes/SizeMaxBytes -> repart expands it to take everything available.
Type=home
REPART

install -d -m0755 "$stage/usr/lib/novadeck"
cat >"$stage/usr/lib/novadeck/grow-home.sh" <<'GROW'
#!/bin/sh
# novadeck first-boot grow: enlarge the /home partition to fill the device, THEN grow its ext4.
# Runs from novadeck-grow-home.service, ordered Before=home.mount, so the fs grow is a race-free
# offline resize2fs (partition already enlarged, /home not yet mounted) rather than the mount-time
# x-systemd.growfs that lost a race to home.mount and left the ext4 at the flashed ~1G. Idempotent.
set -eu

HOME_DEV=/dev/disk/by-label/novadeck-home

# Wait for udev to publish the home partition's by-label symlink. Even ordered After
# systemd-udev-trigger, the probe that creates the symlink is async, so settle the queue and then
# poll briefly. A card without a home partition (nofail / old 2-partition test image) never shows it,
# so time out after ~10s and no-op (x-systemd.growfs covers any fs at mount) rather than hang boot.
udevadm settle --timeout=30 2>/dev/null || true
i=0
while [ ! -b "$HOME_DEV" ] && [ "$i" -lt 50 ]; do
  sleep 0.2
  i=$((i + 1))
done
if [ ! -b "$HOME_DEV" ]; then
  echo "[novadeck-grow-home] no ${HOME_DEV} after settle — nothing to grow (x-systemd.growfs covers any fs)"
  exit 0
fi
HOME_PART=$(readlink -f "$HOME_DEV")

# 1. Grow the partition to fill the disk (systemd-repart, declarative via /usr/lib/repart.d). Pass the
#    parent DISK EXPLICITLY: with no device argument, repart auto-detects the disk from the ROOT fs,
#    which fails on our btrfs root (mounted as the pseudo-device /dev/root — no initramfs) with
#    "Cannot determine correct backing block device". That was the flaky red boot error ("Failed to
#    start ... grow of /home"); deriving the disk from the home partition sidesteps root entirely.
#    Non-fatal: log and press on to resize2fs rather than throwing a boot error if it ever fails.
DISK=$(lsblk -no pkname "$HOME_PART" 2>/dev/null | head -n1)
if [ -n "${DISK:-}" ] && [ -b "/dev/${DISK}" ]; then
  systemd-repart --dry-run=no "/dev/${DISK}" \
    || echo "[novadeck-grow-home] systemd-repart on /dev/${DISK} failed (non-fatal; resize2fs still runs)" >&2
else
  echo "[novadeck-grow-home] could not resolve parent disk of ${HOME_PART} — skipping partition grow" >&2
fi

# Let udev settle so the enlarged partition's size is current before resize2fs.
udevadm settle 2>/dev/null || true

# 2. Grow the ext4 to fill the (now enlarged) partition. No-op once it already fills it; non-fatal so
#    a not-cleanly-unmounted fs can't block boot (x-systemd.growfs is the fallback).
resize2fs "$HOME_PART" || echo "[novadeck-grow-home] resize2fs skipped/failed (non-fatal)" >&2
GROW
chmod 0755 "$stage/usr/lib/novadeck/grow-home.sh"

install -d -m0755 "$stage/usr/lib/systemd/system"
cat >"$stage/usr/lib/systemd/system/novadeck-grow-home.service" <<'UNIT'
[Unit]
Description=novadeck first-boot grow of /home to fill the storage device (systemd-repart + resize2fs)
Documentation=man:systemd-repart(8)
DefaultDependencies=no
ConditionDirectoryNotEmpty=/usr/lib/repart.d
# After systemd-udev-trigger (block coldplug), else the home partition's by-label symlink isn't
# published yet when we run and the grow no-ops (HW: grow-home ran 1s before "Found device" and
# bailed). Before home.mount (not just local-fs-pre.target): the ext4 resize must complete while
# /home is still unmounted, else it races the mount-time x-systemd.growfs (see grow-home.sh).
After=systemd-udevd.service systemd-udev-trigger.service
Before=home.mount local-fs-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Wrapper: systemd-repart (grow partition) THEN resize2fs (grow ext4). 76/77 tolerance is inside it.
ExecStart=/usr/lib/novadeck/grow-home.sh

[Install]
WantedBy=sysinit.target
UNIT

# Enable on release: higher-priority preset (60 < 99 stock "disable *") + a build-time symlink
# fallback. The unit runs early (Before=local-fs-pre.target), pulled in via sysinit.target.
install -d -m0755 "$stage/usr/lib/systemd/system-preset"
echo "enable novadeck-grow-home.service" \
  >"$stage/usr/lib/systemd/system-preset/60-novadeck-storage.preset"
install -d -m0755 "$stage/etc/systemd/system/sysinit.target.wants"
ln -sf /usr/lib/systemd/system/novadeck-grow-home.service \
       "$stage/etc/systemd/system/sysinit.target.wants/novadeck-grow-home.service"

# Mask the stock systemd-repart.service. It's static but WantedBy=sysinit.target, so it also auto-runs
# in real-root boot and FAILS the same way our old unit did: with no device argument it can't resolve
# the btrfs /dev/root backing disk ("Cannot determine correct backing block device"), throwing a red
# "Failed to start Repartition Root Disk" every boot. novadeck-grow-home replaces it (explicit disk +
# resize2fs), so silence the duplicate. It STAYS masked now that the initramfs exists: the stock unit
# is initrd-only, and our initramfs is a plain shell script with no systemd in it to run the unit.
ln -sf /dev/null "$stage/etc/systemd/system/systemd-repart.service"

# 4h. OFFLOAD mounts (SteamOS layer). The root is read-only and /var is a 256M partition, so the
# paths that grow without bound are bind-mounted out to the big shared /home partition, under
# /home/.novadeck/offload/ (SteamOS uses /home/.steamos/offload — same idea, our namespace).
#
# Shape copied from SteamOS: NOT fstab bind lines, but one .mount unit per path plus a target that
# groups them (cf. steamos-offload.target + var-log.mount et al in steamos-customizations). That
# buys explicit ordering and one place to enable.
#
# /var/lib/docker is in SteamOS's set and omitted here — we ship no container runtime.
#
# novadeck-offload-prepare.service creates each directory on /home before the binds run, and SEEDS
# it from whatever the read-only root already has at that path. The seeding is not cosmetic: the
# TEST build bakes an SSH key into /root/.ssh, and an empty bind over /root would shadow it and lock
# us out of the card. Same reasoning protects anything shipped in /opt or /srv.
echo "  injecting offload binds: /opt /root /srv + var/{log,tmp,cache/pacman,lib/*} -> /home/.novadeck/offload"
OFFLOAD_ROOT=/home/.novadeck/offload
# unit-name<TAB>path pairs; unit names must be the systemd-escaped path (see systemd-escape -p).
OFFLOAD_PATHS='opt root srv var/log var/tmp var/cache/pacman var/lib/flatpak var/lib/systemd/coredump'

# rauc's data-directory (fs-overlay/etc/rauc/system.conf), where it keeps the per-slot block-hash
# indices that make adaptive updates work, plus central.raucs. Created by the same prepare service
# because it has the same precondition -- a real directory on the /home partition, which does not
# exist in the staged tree (that /home is only a mount point).
#
# A SIBLING OF THE OFFLOAD TREE, NOT A MEMBER OF IT, and the distinction is the whole point. The
# offload paths are /var paths REDIRECTED onto /home because /var is a 256M per-slot partition.
# This is the opposite requirement: data that must live somewhere no update touches, precisely
# because post-install.sh reformats the target /var on every install. Adding it to OFFLOAD_PATHS
# would give it a bind mount from a slot-local path and quietly reintroduce the problem.
RAUC_DATA=/home/.novadeck/rauc

cat >"$stage/usr/lib/systemd/system/novadeck-offload.target" <<'UNIT'
[Unit]
Description=novadeck offload mounts (bind /opt, /root, /srv and the growable /var paths onto /home)
Documentation=file:///usr/lib/novadeck/offload-prepare.sh
# Ordered inside the local-fs stage: after /home is available, before anything that consumes these
# paths. systemd-journal-flush (sysinit.target) runs later, so /var/log is already bound by then.
After=home.mount novadeck-offload-prepare.service
Requires=novadeck-offload-prepare.service
Before=local-fs.target
UNIT

cat >"$stage/usr/lib/systemd/system/novadeck-offload-prepare.service" <<UNIT
[Unit]
Description=novadeck offload directory preparation (create + seed the bind targets on /home)
DefaultDependencies=no
RequiresMountsFor=/home
After=home.mount
Before=novadeck-offload.target local-fs.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/novadeck/offload-prepare.sh
UNIT

install -d -m0755 "$stage/usr/lib/novadeck"
cat >"$stage/usr/lib/novadeck/offload-prepare.sh" <<PREPARE
#!/bin/sh
# Create each offload directory on /home and seed it, ONCE, from the read-only root's copy of that
# path. Seeding matters: a bare empty bind over /root would hide the TEST build's baked
# /root/.ssh/authorized_keys. Idempotent — a directory that already exists is left strictly alone,
# so user data is never overwritten on later boots.
set -eu

OFFLOAD="$OFFLOAD_ROOT"

# rauc's data-directory. No bind, no seeding, no mode mirroring -- 0700 root, created if absent and
# never touched again, because everything in it is rauc's own state. An existing directory is left
# alone: it holds the block-hash indices of both slots, and deleting them costs the next update a
# full-size download (it re-hashes on demand, so it degrades in bandwidth, not in correctness).
mkdir -p "$RAUC_DATA"
chmod 0700 "$RAUC_DATA"

for rel in $OFFLOAD_PATHS; do
  dst="\$OFFLOAD/\$rel"
  [ -d "\$dst" ] && continue
  mkdir -p "\$dst"
  # cp -a of the root's existing content (may be empty; /opt and /srv usually are).
  if [ -d "/\$rel" ] && [ -n "\$(ls -A "/\$rel" 2>/dev/null)" ]; then
    cp -a "/\$rel/." "\$dst/" || echo "[novadeck-offload] seeding \$dst from /\$rel failed" >&2
  fi
  # Mirror the root's mode/owner so e.g. /root stays 0700 root:root and /var/tmp stays 1777.
  if [ -d "/\$rel" ]; then
    chmod --reference="/\$rel" "\$dst" 2>/dev/null || :
    chown --reference="/\$rel" "\$dst" 2>/dev/null || :
  fi
done
PREPARE
chmod 0755 "$stage/usr/lib/novadeck/offload-prepare.sh"

# One .mount unit per offload path. The unit FILENAME must be the escaped mount point, else systemd
# refuses to load it ("Where= setting doesn't match unit name").
for rel in $OFFLOAD_PATHS; do
  unit="$(echo "$rel" | tr '/' '-').mount"
  cat >"$stage/usr/lib/systemd/system/$unit" <<UNIT
[Unit]
Description=novadeck offload bind of /$rel onto $OFFLOAD_ROOT/$rel
Documentation=file:///usr/lib/novadeck/offload-prepare.sh
DefaultDependencies=no
RequiresMountsFor=/home
After=novadeck-offload-prepare.service
Requires=novadeck-offload-prepare.service
Before=local-fs.target shutdown.target
Conflicts=shutdown.target
PartOf=novadeck-offload.target

[Mount]
What=$OFFLOAD_ROOT/$rel
Where=/$rel
Type=none
Options=bind

[Install]
WantedBy=novadeck-offload.target
UNIT
  install -d -m0755 "$stage/etc/systemd/system/novadeck-offload.target.wants"
  ln -sf "/usr/lib/systemd/system/$unit" "$stage/etc/systemd/system/novadeck-offload.target.wants/$unit"
done

# Enable the target itself (preset-proof, same pattern as grow-home: 60 < the stock 99 "disable *").
echo "enable novadeck-offload.target" \
  >>"$stage/usr/lib/systemd/system-preset/60-novadeck-storage.preset"
install -d -m0755 "$stage/etc/systemd/system/local-fs.target.wants"
ln -sf /usr/lib/systemd/system/novadeck-offload.target \
       "$stage/etc/systemd/system/local-fs.target.wants/novadeck-offload.target"

# 4c. DEV-ONLY Wi-Fi/SSH injection (NOVADECK_DEV=1). NEVER part of a release/RAUC build:
# the release base is packages-only and first-boot networking is the SteamOS UI's job. Here
# we add ALL the scaffolding a throwaway card needs to auto-join the LAN and accept an SSH
# login to run vulkaninfo — a NetworkManager connection profile, regdom, the Wi-Fi PSK + SSH
# key (from the environment, so secrets never touch the repo), service enablement, and host
# keys. The runtime packages (networkmanager + its wpa_supplicant backend, openssh) come from
# the base (customize-base.sh). The test card deliberately uses the SAME manager as release —
# NetworkManager — so this path validates the real release Wi-Fi stack (incl. its unaided recovery
# across a novadeck-suspend cycle) instead of a divergent test-only wpa_supplicant@wlan0 + networkd path.
# Initialised OUTSIDE the dev branch because this script runs under `set -u`: a release build
# never enters the block below, and the Wi-Fi test further down would then dereference an unset
# variable and abort the assembler.
dev_wifi=0
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  # WI-FI IS OPTIONAL, and which way it went is stamped by ROOTFS_MODE so make re-assembles on a
  # flip (see the Makefile). A card with no profile is the SHIPPING first-boot condition — no
  # network until the user joins one in the UI — which is the only honest way to exercise OOBE
  # locally. It is also unreachable: no profile means no SSH, and this device has no UART, so the
  # only debug path left is the offline card-mount (`journalctl -D`).
  #
  # These vars used to be `:?` REQUIRED here, which made a no-network dev card impossible to
  # build. Optional is right, but "absent means skip" alone would trade one footgun for a worse
  # one: forgetting to source dev.env.local would silently hand you an unreachable card. So intent
  # is what decides, and NOVADECK_WIFI=1 is how a caller that depends on SSH states it.
  dev_wifi=1
  if [ "${NOVADECK_WIFI:-}" = "0" ]; then
    dev_wifi=0                                    # explicit: no profile even though creds exist
  elif [ -z "${NOVADECK_WIFI_SSID:-}" ] || [ -z "${NOVADECK_WIFI_PSK:-}" ]; then
    if [ "${NOVADECK_WIFI:-}" = "1" ]; then
      echo "NOVADECK_WIFI=1 requires NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK" >&2
      echo "  put them in dev.env.local (gitignored), or unset NOVADECK_WIFI for a no-network card" >&2
      exit 1
    fi
    dev_wifi=0
  fi

  if [ "$dev_wifi" = "0" ]; then
    echo "  [DEV] NO Wi-Fi profile — this card will NOT auto-join and is NOT reachable over SSH."
    echo "  [DEV]   first boot starts offline (the shipping OOBE condition); debug via card-mount."
    echo "  [DEV]   for a reachable card, set NOVADECK_WIFI_SSID + NOVADECK_WIFI_PSK in dev.env.local."
  fi
fi

if [ "${NOVADECK_DEV:-}" = "1" ] && [ "$dev_wifi" = "1" ]; then
  echo "  [DEV] injecting Wi-Fi profile for '$NOVADECK_WIFI_SSID' (dev-only)"

  # NetworkManager connection profile (keyfile format). NM binds by SSID, not interface, so no
  # interface rename is needed; NM also runs its own DHCP and drives wpa_supplicant itself (the
  # plain wpa_supplicant.service, NOT the @wlan0 instance). The file MUST be 0600 root-owned or NM
  # ignores it ("ignoring due to permissions"). autoconnect=true joins the LAN at boot.
  install -d -m0755 "$stage/etc/NetworkManager/system-connections"
  ( umask 077; cat >"$stage/etc/NetworkManager/system-connections/${NOVADECK_WIFI_SSID}.nmconnection" <<EOF
[connection]
id=${NOVADECK_WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${NOVADECK_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${NOVADECK_WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  )
  chmod 0600 "$stage/etc/NetworkManager/system-connections/${NOVADECK_WIFI_SSID}.nmconnection"

  # Regulatory domain at the kernel layer: the 85-regulatory.rules udev rule runs
  # set-wireless-regdom when cfg80211 loads; it sources this file and runs `iw reg set`.
  # The packaged file (from wireless-regdb) has every country commented out, so without this
  # the chip stays on the world domain (00) until something sets it. Pin it so 5 GHz is enabled
  # from the moment cfg80211 loads (and the helper stops exiting 1). NM honours the kernel regdom.
  install -d -m0755 "$stage/etc/conf.d"
  printf '\nWIRELESS_REGDOM="BE"\n' >>"$stage/etc/conf.d/wireless-regdom"

  # No resume hook needed: the test card runs NetworkManager (same as release), and NM re-associates
  # Wi-Fi unaided after a novadeck-suspend thaw — HW-validated 2026-06-25, which is why the former
  # 50-nm-reup hook was dropped as moot.
fi

# The rest of the dev scaffolding is NOT conditional on Wi-Fi. The SSH key is useful on a
# no-Wi-Fi card the moment OOBE joins a network, and the smoke helper is a local tool — gating
# either on a profile that may not exist would make a no-network dev card less useful than it
# needs to be, for no reason.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  # sshd itself is NOT enabled here anymore: it ships always-on for EVERY build via the fs-overlay
  # (60-novadeck-sshd.preset + the committed multi-user.target.wants/sshd.service symlink), because
  # release remote access is key-only and a keyless sshd admits nobody. NetworkManager is likewise
  # enabled for every build in customize-base.sh. So this block only adds the TEST credential
  # below — the root key that gives the throwaway card a root@device login for bring-up.

  # HOST KEYS ARE DELIBERATELY *NOT* GENERATED HERE. This block used to run ssh-keygen into
  # $stage/etc/ssh, on the reasoning that "a read-only root cannot generate them at boot". That
  # reasoning is wrong twice over:
  #
  #   - /etc is an overlayfs whose upper lives in /var (see the overlay setup above), so /etc/ssh
  #     IS writable at runtime. openssh's own sshdgenkeys.service (ExecStart=ssh-keygen -A, with
  #     ConditionPathExists=|! on each key) already runs before sshd.service, which Wants= and
  #     After= it. Baking keys only suppressed that unit's condition.
  #   - A key baked into the image is a property of the BUILD, not of the device. Every device
  #     flashed from one image would share one private host key -- extractable by anyone holding
  #     the image -- and every OTA would swap it, so each update looks like a MITM to every client
  #     that has the device in known_hosts. (Observed on hardware 2026-07-28: the slot-b trial boot
  #     changed the host key purely because it came from a different build.)
  #
  # So: leave /etc/ssh alone and let sshdgenkeys generate per-device keys at first sshd start. They
  # land in the /etc overlay upper, i.e. in this slot's /var, and images/../post-install.sh carries
  # them to the other slot on update so they survive an OTA. That is the same shape as machine-id.

  # SSH authorized key (key-only root; default PermitRootLogin=prohibit-password).
  if [ -n "${NOVADECK_SSH_PUBKEY:-}" ]; then
    install -d -m0700 "$stage/root/.ssh"
    printf '%s\n' "$NOVADECK_SSH_PUBKEY" >"$stage/root/.ssh/authorized_keys"
    chmod 0600 "$stage/root/.ssh/authorized_keys"
  else
    echo "  [TEST] WARNING: NOVADECK_SSH_PUBKEY unset — sshd (key-only root) will reject login"
  fi
fi

# 4d. DEBUG log capture (NOVADECK_DEBUG=1) — INDEPENDENT of NOVADECK_DEV, applies to release too.
# This device has no UART and is usually powered off abruptly, and journald's default
# SyncIntervalSec=5min means a short boot's system logs (kernel/NetworkManager/wpa_supplicant/
# regulatory) never reach disk before the power is cut — that is why a released card's persistent
# journal held only the late gamescope session and none of the Wi-Fi bring-up. Under DEBUG, force
# persistent storage, sync every few seconds so logs survive a power-yank, drop the rate limit so
# gamescope's chatter cannot evict other units, and cap size generously. Diagnostic builds only —
# never ship: the frequent fsync + unbounded logging beat on the SD card. See wifi diagnosis thread.
if [ "${NOVADECK_DEBUG:-}" = "1" ]; then
  echo "  [DEBUG] enabling persistent journald + live journal streamer to /home"
  # Runtime debug marker: NOVADECK_DEBUG is a build-time var, so bake a sentinel that on-device
  # tools can key off. novadeck-steam checks this to enable Steam CEF remote-debugging (DevTools).
  install -d -m0755 "$stage/usr/lib/novadeck"
  : >"$stage/usr/lib/novadeck/debug"
  # (a) Nudge journald toward persistence too (belt for anything that DOES reach /var).
  install -d -m0755 "$stage/etc/systemd/journald.conf.d"
  cat >"$stage/etc/systemd/journald.conf.d/60-novadeck-debug.conf" <<'DBG'
# NOVADECK_DEBUG build only — capture system logs on a no-UART, power-yanked device.
[Journal]
Storage=persistent
SyncIntervalSec=5s
RateLimitIntervalSec=0
RateLimitBurst=0
SystemMaxUse=500M
DBG

  # (b) The real capture: journald reliably RECEIVES system logs into its runtime journal but on
  # this RO-root device it does not persist them to /var before power is cut (a released card kept
  # only the late gamescope session). So stream the live journal to the ext4 /home partition, which
  # IS writable and survives a power-yank. `journalctl -b -f` first dumps the WHOLE boot backlog
  # (kernel/NM/wpa/regulatory, even though this unit starts at multi-user) then follows live — so it
  # captures the OOBE Wi-Fi connect attempt on the RELEASE path. Plus a one-shot regdom/dmesg snapshot.
  cat >"$stage/usr/lib/systemd/system/novadeck-debug-log.service" <<'UNIT'
[Unit]
Description=novadeck DEBUG log capture to /home (streams the journal + regdom snapshot)
After=systemd-journald.service
RequiresMountsFor=/home
[Service]
Type=simple
ExecStartPre=/usr/bin/sh -c 'mkdir -p /home/novadeck-debug; { echo "== iw reg get =="; iw reg get; echo "== dmesg (wifi) =="; dmesg | grep -iE "ath12k|cfg80211|regulatory|wcn|wlan"; } >/home/novadeck-debug/snapshot.log 2>&1 || true'
ExecStart=/usr/bin/sh -c 'exec journalctl -b -f -o short-precise --no-hostname >>/home/novadeck-debug/journal.log 2>&1'
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
UNIT

  # Enable preset-proof: /etc/machine-id is empty so first boot runs preset-all where 99-default is
  # "disable *"; a high-prio preset (60 < 99) keeps us enabled, plus the wants symlink as fallback.
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  echo "enable novadeck-debug-log.service" >"$stage/usr/lib/systemd/system-preset/60-novadeck-debug.preset"
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/novadeck-debug-log.service \
         "$stage/etc/systemd/system/multi-user.target.wants/novadeck-debug-log.service"
fi

# 4y. SEAL — strip the package manager from the RELEASE root (Phase 4a step 3).
#
# Last injection before the tree is frozen: everything above may still add files, and the seal
# has to be the final word on what a release image carries. It deletes pacman, gnupg/dirmngr and
# the keyring package with its vendor-enabled weekly timer — the timer being what activates the
# dirmngr that then burns a 90s stop timeout at every shutdown. See images/seal.list for the
# declaration and images/seal-rootfs.sh for the mechanism; the package database survives as
# provenance under /usr/lib/novadeck/pkgdb.
#
# TEST builds keep it all: on-device pacman is a real bring-up affordance and the divergence is
# confined to TOOLING — it touches neither the boot nor the session path, so it does not repeat
# the "verify OOBE on a release build" trap. The step-4 guard runs against the release tree.
#
# 4y-2. TRIM — delete build and documentation artefacts (images/trim.list).
#
# Ordered AFTER the seal, not before, and the order is load-bearing: the sealer expands each
# stripped package's own file list and then rmdir's the directories it listed, so running the
# trim first would hand it a tree where some of those files are already gone. Behaviour is
# identical either way, but "the seal sees exactly the tree it saw when it was HW-validated" is
# worth more than the ordering being arbitrary.
#
# Dev builds skip it for the same reason they keep pacman: deleting files out from under a live
# package database would make every on-device `pacman -Qkk` and reinstall lie.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  echo "  [DEV] keeping the package manager on the image (release builds are sealed)"
  echo "  [DEV] skipping the trim (a live package db must keep describing its own files)"
else
  "$ROOT/images/seal-rootfs.sh" "$stage"
  "$ROOT/images/trim-rootfs.sh" "$stage"
fi

# 4y. Drop /etc/machine-id, for EVERY build.
#
# The image is supposed to ship without one so systemd treats the first boot as a first boot:
# ConditionFirstBoot=yes, a per-device id generated, preset-all run. That was stated in two places
# and enforced in none, and the built tree had one — measured 2026-07-28 on rootfs.img: a real
# 33-byte id, identical on every unit ever flashed from that image. Two silent consequences:
#
#   - fs-overlay/usr/lib/novadeck/gen-mac.sh seeds the Wi-Fi MAC from /etc/machine-id, falling back
#     to /sys/devices/soc0/serial_number and then to random. The SoC serial IS per-unit, so the
#     fallback would already give every device a distinct MAC — a populated machine-id is exactly
#     what stops line 27 ever falling through to it. The bug is not that the chain is wrong; it is
#     that a baked seed always wins and makes the whole chain unreachable.
#   - a populated machine-id means systemd does NOT treat the first boot as first, so preset-all
#     never runs and the 60-novadeck-*.preset files do nothing. Service enablement only survived
#     because the explicit multi-user.target.wants symlinks ship too; anything preset-only was off.
#     This half CANNOT be fixed in gen-mac.sh — systemd's first-boot detection keys on this file.
#
# Not release-only, unlike the seal above: this is a correctness fix, and a test image wants a
# per-unit MAC and working presets just as much. Guard assertion 6 checks it on release trees.
#
# DOES NOT FIX AN ALREADY-FLASHED DEVICE. gen-mac.sh persists the derived address write-once to
# /var/lib/novadeck/mac-wifi and prefers it forever after, so a device that already booted keeps
# the colliding MAC until that file is removed or its /var is reformatted. Worth knowing for the
# RAUC /var migration hook too: copying /var across slots copies the bad address with it.
#
# SAFETY, and why this is not a one-liner: removing it makes ConditionFirstBoot=yes true again,
# which re-arms systemd-firstboot.service — which on this device prompts for locale and a root
# password on a console with no usable input and blocks sysinit.target FOREVER, with no serial
# console to see it on. images/customize-base.sh masks that unit precisely because the root is
# meant to ship without a machine-id. The two facts are load-bearing together, so guard assertion
# 6 checks both and refuses a tree that has one without the other.
rm -f "$stage/etc/machine-id"
echo "  dropped /etc/machine-id (first-boot identity is generated per device)"

# 4z. Normalize overlay ownership to root. The fs-overlay/ tree (and the other cp -a injections)
# is copied with `cp -a`, which PRESERVES the host build user's
# uid/gid (the repo checkout owner, typically 1000). In the image uid 1000 is `deck`, so /etc, /,
# and every injected file end up deck-owned — a real bug (HW journal 2026-07-01: systemd-tmpfiles
# "unsafe path transition /etc (owned by deck)"). Nothing in the read-only root legitimately belongs
# to the build user, so reclaim every such file to root:root. Match the build uid dynamically off
# this script (repo-owned) rather than hardcoding 1000. The sddm state dir (/var/lib/sddm, uid 965)
# and other service-owned paths are a different uid and stay untouched. -h: fix symlinks too.
ov_uid="$(stat -c %u "$0")"
if [ "$ov_uid" != "0" ]; then
  echo "  normalizing overlay ownership: uid $ov_uid -> root ($(find "$stage" -uid "$ov_uid" | wc -l) paths)"
  find "$stage" -uid "$ov_uid" -exec chown -h 0:0 {} +
fi

# 4zz. GUARD — assert the sealed tree against its declaration (Phase 4a step 4).
#
# Placed here, at the last point the tree is both complete and still a directory: everything above
# has finished injecting, and section 5 below carves /var out into its own image (so a guard after
# it could no longer see var/lib/pacman, which is exactly one of the things it has to find gone).
# What mkfs.btrfs bakes in section 6 is this directory, unmodified.
#
# Release-only, mirroring the seal — a dev tree deliberately keeps the package manager and carries
# DEV_PKGS the lock does not describe. See images/guard-rootfs.sh for what it asserts and why.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  echo "  [DEV] skipping the sealed-root guard (nothing was sealed)"
else
  "$ROOT/images/guard-rootfs.sh" "$stage"
fi

mkdir -p "$IMGDIR"

# 5. carve /var out of the staged tree into its own ext4 image (partition var-a). The root is
# sealed read-only, so every writable system path has to live here — including the /etc overlay's
# upper+work dirs, which the initramfs stacks before handing off to systemd.
#
# The pacman package cache is 500M of downloaded .pkg.tar.zst that nothing reads at runtime; it
# alone would blow the 256M partition. Drop it. (/var/cache/pacman is then a bind-mount target
# onto /home, so a live `pacman -S` still has somewhere to put its downloads.)
varstage="$stage/var"
rm -rf "${varstage:?}/cache/pacman/pkg"

# The overlay upper+work the initramfs expects. It creates them if missing, but shipping them means
# first boot doesn't depend on that path working.
install -d -m0755 "$varstage/lib/overlays/etc/upper" "$varstage/lib/overlays/etc/work"

# Empty mountpoints for the offload binds that land under /var (the units bind /home over these).
for rel in log tmp cache/pacman lib/flatpak lib/systemd/coredump; do
  install -d -m0755 "$varstage/$rel"
done
chmod 1777 "$varstage/tmp"

var_used_mib=$(du -sm "$varstage" | cut -f1)
# ext4 metadata on a 256M fs costs a few MiB; refuse to build an image that cannot be populated
# rather than emit a silently-truncated /var.
if [ "$var_used_mib" -ge $(( VAR_SIZE_MIB - 32 )) ]; then
  echo "staged /var is ${var_used_mib}MiB — does not fit the ${VAR_SIZE_MIB}MiB var partition" >&2
  echo "(largest offenders below; trim them or raise var-a/-b in images/partition-table.txt)" >&2
  du -sm "$varstage"/* 2>/dev/null | sort -rn | head -5 >&2
  exit 1
fi

# One var image per slot (Phase 4b). They differ by exactly one file: /var/lib/novadeck/slot.
#
# The two root images are content-identical by design -- that is what an A/B update produces, and
# RAUC will write the same bytes into whichever slot is inactive. So slot identity can never come
# from the root's CONTENT; it has to come from where the initramfs mounted it. The initramfs
# records its own decision in /run/novadeck/boot, but that comes from the code doing the choosing.
# This file is an INDEPENDENT witness: /run/novadeck/boot says which slot the initramfs thinks it
# picked, /var/lib/novadeck/slot says which var actually got mounted. If those two ever disagree,
# the selection is lying -- which is exactly the symptom of two btrfs filesystems sharing an fsid
# (see images/make-sdcard.sh). Four lines, and it is the only cross-check that does not share a
# failure mode with the thing it checks.
#
# Two mkfs runs also give the two images distinct ext4 UUIDs for free, which matters for the same
# reason: /home is mounted by LABEL, and duplicate filesystem identity across slots is the hazard.
install -d -m0755 "$varstage/lib/novadeck"
for slot in a b; do
  printf '%s\n' "$slot" >"$varstage/lib/novadeck/slot"
  case "$slot" in
    a) img=$VARIMG ;;
    b) img=$VARIMG_B ;;
  esac
  rm -f "$img"
  truncate -s "${VAR_SIZE_MIB}M" "$img"
  mkfs.ext4 -q -F -L novadeck-var-"${slot^^}" -m0 -d "$varstage" "$img"
  echo "  ok   var-$slot  -> ${img#"$ROOT"/}  (${VAR_SIZE_MIB}MiB ext4, ${var_used_mib}MiB used)"
done

# The root keeps only an empty /var mountpoint — the initramfs mounts var-a over it.
rm -rf "${varstage:?}"
install -d -m0755 "$varstage"

# 6. bake the Btrfs image (populate without mounting), compressed + shrunk to fit.
# Let mkfs.btrfs --rootdir size the device itself: on btrfs-progs v7.0 a PRE-truncated large device
# (the old `truncate -s 8G`) forces 1 GiB data block-groups, and `--shrink` can only shrink to that
# coarse granularity — so 6.3 GiB of content rounded up to a 9.25 GiB image that overflowed the 8 GiB
# slot. Creating the file fresh lets --rootdir pick tight chunks, and --shrink then lands near the
# real usage. make-sdcard's `fits` check is the backstop if content ever genuinely exceeds the slot.
#
# --compress zstd: the root is sealed read-only, so compression is pure upside — it shrinks the OS
# libraries/binaries substantially (the .ero and Proton payloads compress less, being pre-packed),
# giving ~1G of headroom under the 6 GiB slot. It is a WRITE-TIME property recorded per extent;
# reads decompress transparently, so no mount option is needed and the ro root needs no fstab change.
#
# The LABEL is slot A's, not a generic one. This image is written verbatim to rootfs-a by
# make-sdcard.sh AND shipped as the RAUC bundle payload, so it lands byte-for-byte on whichever
# slot an update targets — which is why the post-install hook has to re-label (and re-randomise
# the fsid of) the slot it just wrote. Labelling here rather than in make-sdcard.sh is what avoids
# a second full multi-gigabyte copy of the image purely to stamp eleven characters on it.
rm -f "$IMG"
mkfs.btrfs --rootdir "$stage" --compress zstd --shrink -L novadeck-root-A -f "$IMG" >/dev/null

# The identity sidecar (see section 4), beside the image and written only now that there is an image
# to describe. This is the /etc/novadeck-release that is INSIDE $IMG, byte for byte — genbundle.sh
# reads it to name the bundle, and the device compares the bundle's name against its own copy.
# Reading it back out of the btrfs image instead would need `btrfs restore` for four lines.
cp "$release_file" "$IMGDIR/rootfs.release"

# Report the APPARENT size, not the allocated one. `mkfs.btrfs --shrink` leaves the image sparse
# (~2 GiB of holes), so a bare `du -h` understates it by that much -- and this number is what
# anyone sizing the slot reads. rootfs-a is 7G (images/partition-table.txt), so the honest figure
# is a ~0.9G margin, where the allocated one implies ~2.9G. Both are printed: the allocated size
# is what the file costs on the build host, which is worth knowing too, just not on its own.
echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h --apparent-size "$IMG" | cut -f1) in a 7G slot," \
     "$(du -h "$IMG" | cut -f1) allocated, from $(du -sh "$stage" 2>/dev/null | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
