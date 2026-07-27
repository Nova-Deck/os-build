#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 4.
#
# Stages a base rootfs, injects the novadeck kernel + dtbs (from kernel/build.sh) and the
# device firmware (from firmware/fetch-qcom-fw.sh), then splits the staged tree into the
# TWO filesystem images the partition table wants (images/partition-table.txt):
#
#   out/images/rootfs.img  btrfs, ro   -> rootfs-a   the sealed system
#   out/images/var.img     ext4,  rw   -> var-a      writable state + the /etc overlay upper
#
# Both are built unprivileged: `mkfs.btrfs --rootdir`, `mkfs.ext4 -d` — no root, no loop mount.
#
# The root's content is read-only by construction; the subvolume's ro *property* is
# set by RAUC at deploy time (needs a mount), so it is not applied here. The kernel mounts
# it `ro` regardless (see boot/cmdline + images/initramfs/init).
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
[ -f "$OUT/Image.gz" ] || { echo "no kernel: $OUT/Image.gz (run kernel/build.sh first)" >&2; exit 1; }
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

# 2. novadeck kernel + dtbs under /boot
install -Dm0644 "$OUT/Image.gz" "$stage/boot/Image.gz"
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

# 2c. /efi mountpoint for the ESP (p1, the only ef00 on the disk). systemd's gpt-auto generator
# finds the ESP by type GUID and emits an automount here: mounted on first access, unmounted
# again after 120s idle. The root is read-only, so this directory cannot be created at runtime —
# without it the automount fails and the system boots degraded. A/B updates reach the boot image
# through this path, since the bootloader only ever reads p1.
install -dm0755 "$stage/efi"

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

# 4. novadeck marker so the running system can identify the slot's provenance
mkdir -p "$stage/etc"
{ echo "NOVADECK_VARIANT=unified"; echo "NOVADECK_BUILD=$(date -u +%Y%m%dT%H%M%SZ)"; } >"$stage/etc/novadeck-release"

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
echo "  injecting first-boot storage: /home mount + grow (deck user baked in base)"
mkdir -p "$stage/etc"
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

# 4c. TEST-ONLY Wi-Fi/SSH injection (NOVADECK_TEST=1). NEVER part of a release/RAUC build:
# the release base is packages-only and first-boot networking is the SteamOS UI's job. Here
# we add ALL the scaffolding a throwaway card needs to auto-join the LAN and accept an SSH
# login to run vulkaninfo — a NetworkManager connection profile, regdom, the Wi-Fi PSK + SSH
# key (from the environment, so secrets never touch the repo), service enablement, and host
# keys. The runtime packages (networkmanager + its wpa_supplicant backend, openssh) come from
# the base (customize-base.sh). The test card deliberately uses the SAME manager as release —
# NetworkManager — so this path validates the real release Wi-Fi stack (incl. its unaided recovery
# across a novadeck-suspend cycle) instead of a divergent test-only wpa_supplicant@wlan0 + networkd path.
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  : "${NOVADECK_WIFI_SSID:?NOVADECK_TEST=1 requires NOVADECK_WIFI_SSID}"
  : "${NOVADECK_WIFI_PSK:?NOVADECK_TEST=1 requires NOVADECK_WIFI_PSK}"
  echo "  [TEST] injecting Wi-Fi + SSH scaffolding for '$NOVADECK_WIFI_SSID' (test-only)"

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

  # Enable services. /etc/machine-id is empty, so systemd runs preset-all on first boot and
  # the stock 99-default.preset is "disable *"; ship a high-priority preset (70 < 99) so our
  # units stay enabled, plus pre-create the symlinks as a build-time fallback. Only sshd is
  # test-only here — NetworkManager is enabled for EVERY build in customize-base.sh (the gamepadui
  # needs it on release too), so it is NOT re-enabled here; this block only adds the test creds.
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  echo "enable sshd.service" >"$stage/usr/lib/systemd/system-preset/70-novadeck-test.preset"
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/sshd.service \
         "$stage/etc/systemd/system/multi-user.target.wants/sshd.service"

  # sshd needs host keys; a read-only root cannot generate them at boot, so pre-generate now.
  if command -v ssh-keygen >/dev/null 2>&1; then
    install -d -m0755 "$stage/etc/ssh"
    for t in rsa ecdsa ed25519; do
      f="$stage/etc/ssh/ssh_host_${t}_key"
      [ -f "$f" ] || ssh-keygen -q -t "$t" -f "$f" -N "" -C "" </dev/null
    done
  else
    echo "  [TEST] WARNING: ssh-keygen not found — sshd will have no host keys"
  fi

  # SSH authorized key (key-only root; default PermitRootLogin=prohibit-password).
  if [ -n "${NOVADECK_SSH_PUBKEY:-}" ]; then
    install -d -m0700 "$stage/root/.ssh"
    printf '%s\n' "$NOVADECK_SSH_PUBKEY" >"$stage/root/.ssh/authorized_keys"
    chmod 0600 "$stage/root/.ssh/authorized_keys"
  else
    echo "  [TEST] WARNING: NOVADECK_SSH_PUBKEY unset — sshd (key-only root) will reject login"
  fi

  # Phase-2 de-risk smoke (TEST-ONLY): bring up BARE gamescope on Turnip via DRM/KMS — the
  # exact compositor path the Deck-UI session uses. SSH in and run `nova-gamescope-smoke`
  # while watching the panel; it launches gamescope on the DRM backend with a Vulkan client
  # (default vkcube) rendering through gamescope's Wayland display. This exercises Turnip's
  # Wayland WSI under the compositor — the open question the plan flags before the jupiter-*
  # port (the Phase-1 gate only proved the direct VK_KHR_display KMS path). It is launched
  # by hand, not enabled as a unit, so it can't take the panel away from the SSH/console
  # bring-up path on a throwaway test card.
  echo "  [TEST] installing gamescope DRM smoke helper /usr/local/bin/nova-gamescope-smoke"
  install -d -m0755 "$stage/usr/local/bin"
  cat >"$stage/usr/local/bin/nova-gamescope-smoke" <<'SMOKE'
#!/bin/sh
# novadeck Phase-2 smoke: bare gamescope on Turnip (DRM/KMS). TEST-ONLY. Run over SSH as root,
# watch the panel.  Usage: nova-gamescope-smoke [client]   (default client: vkcube)
set -eu
# Force the real DRM/KMS backend: a stray WAYLAND_DISPLAY/DISPLAY in the env makes gamescope try
# to nest under a (non-existent) parent compositor and fail with "Failed to connect to wayland socket".
unset WAYLAND_DISPLAY DISPLAY
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
# Keep the gamescope WSI Vulkan layer ON by default (matches the novadeck-session launcher + the
# upstream gamescope session). NOTE: this smoke is a RE-LAUNCH-heavy bring-up tool, and with WSI
# on, re-launching gamescope after a prior instance intermittently wedges (the client blocks in
# drm_syncobj_array_wait_timeout on a never-signaling explicit-sync fence — a userspace race, NOT stale
# GPU state; a fresh power-on is always clean). While iterating over SSH you can force the clean
# implicit-sync path with `ENABLE_GAMESCOPE_WSI=0 nova-gamescope-smoke`. See docs/bringup-phase2.md step 1e.
export ENABLE_GAMESCOPE_WSI="${ENABLE_GAMESCOPE_WSI:-1}"
client="${1:-vkcube}"
echo "[nova] gamescope DRM smoke: client=$client  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
# An SSH session has no graphical logind seat, and the holo libseat is built with only the
# logind+seatd backends (no 'builtin'), so run under a seatd daemon. seatd-launch spawns seatd,
# exports SEATD_SOCK + LIBSEAT_BACKEND=seatd for the child, and tears seatd down on exit.
# Patched gamescope (from-source overlay): composite rotation (upstream PR #2228) rotates the
# portrait-native Pocket S2 panel in the GPU composite and scans out an unrotated buffer (the msm
# DPU can't ROTATE_90 a LINEAR plane). No flag needed — gamescope reads the panel orientation from
# the DRM connector (DTS rotation=<90>) and auto-engages compositor rotation when the primary plane
# can't rotate at scanout. NOTE: --immediate-flips is NOT passed — it is a no-op here (the msm DPU
# does not advertise DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP, so gamescope drops the async flag). The
# intermittent composite-flip freeze is on the vsync'd path and unrelated. See docs/bringup-phase2.md.
gs_args="--backend drm"
set -x
if command -v seatd-launch >/dev/null 2>&1; then
  exec seatd-launch -- gamescope $gs_args -- "$client"
fi
# Fallback: hand-start seatd if seatd-launch is unavailable (don't exec, so the trap cleans up).
seatd >/tmp/seatd.log 2>&1 & seatd_pid=$!
trap 'kill "$seatd_pid" 2>/dev/null || true' EXIT INT TERM
i=0; while [ ! -S /run/seatd.sock ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
export LIBSEAT_BACKEND=seatd
gamescope $gs_args -- "$client"
SMOKE
  chmod 0755 "$stage/usr/local/bin/nova-gamescope-smoke"
fi

# 4d. DEBUG log capture (NOVADECK_DEBUG=1) — INDEPENDENT of NOVADECK_TEST, applies to release too.
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
# Test builds skip it for the same reason they keep pacman: deleting files out from under a live
# package database would make every on-device `pacman -Qkk` and reinstall lie.
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  echo "  [TEST] keeping the package manager on the image (release builds are sealed)"
  echo "  [TEST] skipping the trim (a live package db must keep describing its own files)"
else
  "$ROOT/images/seal-rootfs.sh" "$stage"
  "$ROOT/images/trim-rootfs.sh" "$stage"
fi

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
# Release-only, mirroring the seal — a test tree deliberately keeps the package manager and carries
# TEST_PKGS the lock does not describe. See images/guard-rootfs.sh for what it asserts and why.
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  echo "  [TEST] skipping the sealed-root guard (nothing was sealed)"
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
  mkfs.ext4 -q -F -L novadeck-var -m0 -d "$varstage" "$img"
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
rm -f "$IMG"
mkfs.btrfs --rootdir "$stage" --compress zstd --shrink -L novadeck-root -f "$IMG" >/dev/null

# Report the APPARENT size, not the allocated one. `mkfs.btrfs --shrink` leaves the image sparse
# (~2 GiB of holes), so a bare `du -h` understates it by that much -- and this number is what
# anyone sizing the slot reads. rootfs-a is 7G (images/partition-table.txt), so the honest figure
# is a ~0.9G margin, where the allocated one implies ~2.9G. Both are printed: the allocated size
# is what the file costs on the build host, which is worth knowing too, just not on its own.
echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h --apparent-size "$IMG" | cut -f1) in a 7G slot," \
     "$(du -h "$IMG" | cut -f1) allocated, from $(du -sh "$stage" 2>/dev/null | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
