#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 5.
#
# Stages a base rootfs, injects the novadeck kernel + dtbs + initramfs (from kernel/build.sh and
# image/mkinitramfs.sh) and the device firmware (from firmware/fetch-qcom-fw.sh), then splits
# the staged tree into the TWO filesystem images the partition table wants
# (image/partition-table.txt):
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
# the ESP/efi partitions laid by image/make-sdcard.sh and refreshed by the RAUC hook.
#
#   rootfs/assemble-rootfs.sh <base-rootfs-dir>
#   BASE_ROOTFS=<dir> rootfs/assemble-rootfs.sh
#
# Run inside the build image (needs btrfs-progs + rsync):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build rootfs/assemble-rootfs.sh sm8650 /path/to/base
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
# Also inherited-and-now-ours, handled at the source in rootfs/customize-base.sh rather than
# patched up here: /etc/os-release (rootfs/conf/os-release), /etc/locale.conf and /etc/hostname.
# Still deliberately left alone: /etc/{resolv.conf,hosts} (NetworkManager populates resolv.conf
# at runtime, DNS verified working on HW) and /etc/machine-id, which must stay absent so systemd
# runs preset-all on first boot — populating it would disable our preset-based service enablement.
#
# NOT closed by 4c, and NOT covered by anything here: packages/inputplumber's prebuilt tarball is
# still unpacked at `/` with strip-components=1 (rootfs/customize-base.sh), so a third-party
# archive can still place arbitrary paths in the root. Two marker names were never a guard for
# that; see issues #35 and #36 for the real one (assert every file is package-owned or declared).

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
# This is the file rootfs/conf/os-release designates for per-build identity ("NO PER-BUILD FIELDS ... the
# per-build identity is written by rootfs/assemble-rootfs.sh to /etc/novadeck-release, which is where
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

# 4a-2. The same identity, in the field names OTHER software reads.
#
# SteamUI's Settings -> System renders OS Variant / Version / Build / Codename straight out of
# /etc/os-release, and shipped them all BLANK (HW-observed 2026-08-09) because our os-release
# carries only the static NAME/ID block. The values existed the whole time — they are the file
# written just above — under names nothing but novadeck knows to look for.
#
# APPENDED HERE rather than added to rootfs/conf/os-release, because that file is committed and
# deliberately static ("NO PER-BUILD FIELDS ... so that rebuilding does not churn the tree"), and
# VERSION_ID/BUILD_ID are per-build by definition. Same rule as novadeck-release: the identity is
# stamped ONCE, in one place, and everything downstream reads it back — so these cannot drift from
# the file above the way the bundle version once drifted from the image's.
#
# VERSION_CODENAME is deliberately NOT set: os-release(5) wants a lowercase distro codename and we
# have not chosen one. A field we would have to invent is worth less than the blank that shows we
# have not named it, and inventing it here would put a product decision in a build script.
{
  echo "VARIANT=\"unified\""
  echo "VARIANT_ID=unified"
  echo "VERSION_ID=${NOVADECK_VERSION:-dev}"
  echo "VERSION=\"${NOVADECK_VERSION:-dev} (${NOVADECK_GIT:-unknown})\""
  echo "BUILD_ID=$(sed -n 's/^NOVADECK_BUILD=//p' "$stage/etc/novadeck-release")"
} >>"$stage/etc/os-release"

# The same three fields are needed OUTSIDE the image, by ota/genbundle.sh: a RAUC bundle has to
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
# shell — lives in ONE filesystem-mirror tree under rootfs/overlay/ and is injected with a single
# cp -a. The tree already carries final target paths, executable bits (tracked in git) and the
# systemd presets + .wants symlinks that enable each service, so nothing is generated or chmod'd
# here. rootfs/overlay/README.md documents what each backing does and WHY (the per-layer rationale
# that used to live in this script). Ownership is normalized to root:root in step 4z below.
OVERLAY="$ROOT/rootfs/overlay"
if [ -d "$OVERLAY" ]; then
  echo "  injecting rootfs/overlay payload -> session + HW-support + InputPlumber + audio + FEX + Steam shell (ARMED: boots to Deck shell)"
  cp -a "$OVERLAY"/. "$stage/"
  rm -f "$stage/README.md"   # rootfs/overlay/README.md documents the tree; it is NOT rootfs content
  # Host-side Python bytecode, same class of thing as the README: build-tree litter, not rootfs
  # content. The offline suites import rootfs/overlay's clients as modules (test-perf.sh, -fan-curve,
  # -update), and CPython writes a __pycache__ NEXT TO THE SOURCE — inside rootfs/overlay/, which this
  # cp copies verbatim. .gitignore covers the repo but NOT this copy, and the difference is not
  # theoretical: v0.2.x dev cards shipped .pyc files that the device can never load, because they
  # are the HOST's CPython ABI (3.14) and the image runs 3.13. Pruned here rather than left to the
  # release-only guard, since a dev card is exactly where it happened.
  find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
else
  echo "  (no rootfs/overlay/ tree — skipping overlay injection)" >&2
fi

# The stages below live in rootfs/lib-assemble-*.sh (issue #43). Each is sourced at the exact point
# it used to run inline, so the assembly order is unchanged; the helpers read this script's globals
# ($stage, $ROOT, $OUT) rather than taking arguments.
. "$ROOT/rootfs/lib-assemble-boot.sh"
. "$ROOT/rootfs/lib-assemble-proton.sh"

. "$ROOT/rootfs/lib-assemble-storage.sh"

. "$ROOT/rootfs/lib-assemble-offload.sh"

# 4c is DEV-ONLY and lives in its own file so a release build never reads it (issue #43). dev_wifi
# stays here: it is the default the release path leaves at 0, and the Makefile's DEV_WIFI mirrors
# this decision.
dev_wifi=0
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  . "$ROOT/rootfs/lib-assemble-devcard.sh"
fi

# 4c-3 + 4c-4 run on EVERY build -- they sat inside the 4c banner but are not dev injections, and
# guard-rootfs.sh assertion 9 requires the plugin dists on a release image. Sourced after the dev
# gate rather than between its halves; the assembler records that their position was arbitrary
# (they only have to precede 4d).
. "$ROOT/rootfs/lib-assemble-decky-splash.sh"

# 4d is DEBUG-ONLY, same construction -- and independent of NOVADECK_DEV.
if [ "${NOVADECK_DEBUG:-}" = "1" ]; then
  . "$ROOT/rootfs/lib-assemble-debug.sh"
fi

# 4y. SEAL — strip the package manager from the RELEASE root (Phase 4a step 3).
#
# Last injection before the tree is frozen: everything above may still add files, and the seal
# has to be the final word on what a release image carries. It deletes pacman, gnupg/dirmngr and
# the keyring package with its vendor-enabled weekly timer — the timer being what activates the
# dirmngr that then burns a 90s stop timeout at every shutdown. See rootfs/conf/seal.list for the
# declaration and rootfs/seal-rootfs.sh for the mechanism; the package database survives as
# provenance under /usr/lib/novadeck/pkgdb.
#
# TEST builds keep it all: on-device pacman is a real bring-up affordance and the divergence is
# confined to TOOLING — it touches neither the boot nor the session path, so it does not repeat
# the "verify OOBE on a release build" trap. The step-4 guard runs against the release tree.
#
# 4y-2. TRIM — delete build and documentation artefacts (rootfs/conf/trim.list).
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
  "$ROOT/rootfs/seal-rootfs.sh" "$stage"
  "$ROOT/rootfs/trim-rootfs.sh" "$stage"
fi

# 4y. Drop /etc/machine-id, for EVERY build.
#
# The image is supposed to ship without one so systemd treats the first boot as a first boot:
# ConditionFirstBoot=yes, a per-device id generated, preset-all run. That was stated in two places
# and enforced in none, and the built tree had one — measured 2026-07-28 on rootfs.img: a real
# 33-byte id, identical on every unit ever flashed from that image. Two silent consequences:
#
#   - rootfs/overlay/usr/lib/novadeck/gen-mac.sh seeds the Wi-Fi MAC from /etc/machine-id, falling back
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
# console to see it on. rootfs/customize-base.sh masks that unit precisely because the root is
# meant to ship without a machine-id. The two facts are load-bearing together, so guard assertion
# 6 checks both and refuses a tree that has one without the other.
rm -f "$stage/etc/machine-id"
echo "  dropped /etc/machine-id (first-boot identity is generated per device)"

# 4z. Normalize overlay ownership to root. The rootfs/overlay/ tree (and the other cp -a injections)
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

# 4za. FILE CAPABILITIES — gamescope gets CAP_SYS_NICE, for the realtime Vulkan queues.
#
# WHAT IT BUYS. Upstream gamescope already requests VK_QUEUE_GLOBAL_PRIORITY_REALTIME_EXT for its
# own Vulkan queues, but only `if HasCapSysNice()` (rendervulkan.cpp). Without the capability that
# request is never made, so the compositor competes with the game on equal footing in the msm
# scheduler. It matters only when gamescope actually COMPOSITES rather than direct-scanning-out the
# game buffer -- rotation, scaling, an overlay -- because that is when its work sits on the critical
# path every frame: a small composite job queued behind a saturated game misses vblank, and the
# output judders while the game's own frame pacing still looks clean.
#
# ONE CAPABILITY, TWO UNRELATED THINGS, and that is the thing to know before changing it. CAP_SYS_NICE
# gates CPU thread priority AND this GPU queue request, so they cannot be separated: taking the
# capability away to drop the CPU half silently drops the GPU half too. There is a third-party patch
# that decouples them (--force-vulkan-realtime); we deliberately do NOT carry it, because we own the
# image and can grant the capability, which is upstream's supported path and needs no rebasing.
#
# WHY IT IS SAFE HERE. setcap puts a binary in secure-execution mode (AT_SECURE), so the loader
# ignores LD_PRELOAD/LD_LIBRARY_PATH for THAT process -- the usual reason distros back this out. We
# set neither for gamescope: novadeck-steam exports LD_LIBRARY_PATH for the Steam process, which is
# a different one, and ENABLE_GAMESCOPE_WSI is ordinary env the loader does not strip. Children do
# not inherit AT_SECURE, so games and Steam are unaffected.
#
# WHAT IT IS WORTH IS PER-SOC, and an SM8250 will make it look like the whole thing does nothing.
# msm maps a submitqueue priority onto (ring, sched_prio), and there are only multiple rings when
# preemption is on: a6xx_gpu.c takes `nr_rings = 4` when the module param says so or when the part
# carries ADRENO_QUIRK_PREEMPTION. In the a6xx catalog that quirk is on the 7XX/8XX entries --
# 0x43050a01 (A740, SM8550) and 0x43051401 (A750, SM8650) among them -- and on NO a6xx entry, so
# Adreno 650 / SM8250 runs one ring. There, a realtime queue can only reorder work still QUEUED; it
# cannot preempt work already on the GPU. Measure this on an A740 or A750, and do not conclude from
# an SM8250 that the capability is inert.
#
# NOTE THE DRIVER DOES NOT GATE ON THE CAPABILITY AT ALL: there is no CAP_SYS_NICE check anywhere in
# drivers/gpu/drm/msm, so msm honours whatever priority it is handed. gamescope is the only gate --
# without the capability it never asks, which is exactly why granting it is the whole fix.
#
# FAIL LOUDLY. The capability is an xattr (security.capability); it must survive `cp -a`, rsync -X
# and mkfs.btrfs --rootdir to reach the image, and a capability that silently did not survive looks
# exactly like one that was granted and changed nothing -- you would then measure the wrong
# conclusion. rootfs/guard-rootfs.sh asserts it on the built tree for the same reason.
gs_bin="$stage/usr/bin/gamescope"
[ -f "$gs_bin" ] || { echo "ERROR: no $gs_bin to grant cap_sys_nice to" >&2; exit 1; }
command -v setcap >/dev/null 2>&1 || { echo "ERROR: setcap not found (libcap2-bin missing from the build image)" >&2; exit 1; }
setcap cap_sys_nice+ep "$gs_bin"
gs_cap="$(getcap "$gs_bin")"
case "$gs_cap" in
  *cap_sys_nice*) echo "  granted CAP_SYS_NICE to /usr/bin/gamescope (${gs_cap#* })" ;;
  *) echo "ERROR: setcap reported success but getcap shows '${gs_cap:-<nothing>}'" >&2; exit 1 ;;
esac

# 4zy. /var, finalized — and packed as the installer's seed.
#
# This block used to open section 5, below the guard. It runs HERE now because the seed tarball it
# produces goes INSIDE the root, and rootfs/guard-rootfs.sh's contract is that the tree it inspects
# is the tree mkfs.btrfs bakes ("nothing between here and there adds content"). A file written after
# the guard would quietly falsify that, and that contract exists because a file-mode regression once
# reached hardware. Moving the block up also means the guard now sees the /var that actually ships
# — no pacman cache, overlay dirs present — rather than an intermediate one.
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
  echo "(largest offenders below; trim them or raise var-a/-b in image/partition-table.txt)" >&2
  du -sm "$varstage"/* 2>/dev/null | sort -rn | head -5 >&2
  exit 1
fi

# THE INSTALLER'S /var SEED (Phase 2 of .claude/plans/internal-install.plan.md).
#
# The OTA path fills a target slot's /var by rsyncing the RUNNING one -- there is a live system that
# describes this device, and copying it is the whole point. An install has no such source: the
# running system is the INSTALLER, whose /var describes the installer. So the /var a fresh slot
# starts from ships inside the root, and rootfs/overlay/usr/lib/novadeck/install/lib-slotwrite.sh's
# seed_var unpacks it (that function takes a directory OR a tarball for exactly this reason).
#
# It is the same $varstage the two var images below are built from, so a slot installed from the
# medium and a slot flashed on a card start from identical state by construction rather than by two
# lists being kept in agreement.
#
# --numeric-owner --xattrs --acls to match what the OTA path's `rsync -aHAX --numeric-ids` promises;
# tar preserves hard links natively. Modes matter more than they look here: sshd refuses to start if
# a private host key is group/world-readable, so a mode-losing pack would take SSH down on an
# installed device and nowhere else.
#
# lib/novadeck/slot is EXCLUDED because it is the one file in /var that is per-slot -- seed_var
# writes it after unpacking, and a copy baked in here would be a second answer to the question
# "which slot is this", of the kind /var/lib/novadeck/slot exists to be the independent witness for.
# ~13 MiB of /var, so a few MiB compressed: negligible against a 7 G slot.
install -d -m0755 "$stage/usr/lib/novadeck"
tar --numeric-owner --xattrs --acls --zstd \
    --exclude=./lib/novadeck/slot --exclude=./lib/novadeck/mac-wifi \
    -cf "$stage/usr/lib/novadeck/var-seed.tar.zst" -C "$varstage" . \
  || { echo "cannot pack the installer's /var seed" >&2; exit 1; }
chmod 0444 "$stage/usr/lib/novadeck/var-seed.tar.zst"
echo "  var-seed.tar.zst  $(du -h "$stage/usr/lib/novadeck/var-seed.tar.zst" | cut -f1) (installer /var seed, from the same staged tree as var-a/-b)"

# 4zz. GUARD — assert the sealed tree against its declaration (Phase 4a step 4).
#
# Placed here, at the last point the tree is both complete and still a directory: everything above
# has finished injecting, and section 5 below carves /var out into its own image (so a guard after
# it could no longer see var/lib/pacman, which is exactly one of the things it has to find gone).
# What mkfs.btrfs bakes in section 6 is this directory, unmodified.
#
# Release-only, mirroring the seal — a dev tree deliberately keeps the package manager and carries
# DEV_PKGS the lock does not describe. See rootfs/guard-rootfs.sh for what it asserts and why.
if [ "${NOVADECK_DEV:-}" = "1" ]; then
  echo "  [DEV] skipping the sealed-root guard (nothing was sealed)"
else
  "$ROOT/rootfs/guard-rootfs.sh" "$stage"
fi

mkdir -p "$IMGDIR"

# 5. carve /var out of the staged tree into its own ext4 image (partition var-a). The root is
# sealed read-only, so every writable system path has to live here — including the /etc overlay's
# upper+work dirs, which the initramfs stacks before handing off to systemd. $varstage was
# finalized, size-checked and packed as the installer's seed in section 4zy, above the guard; what
# is left here is turning it into the two per-slot images.
#
# One var image per slot (Phase 4b). They differ by exactly one file: /var/lib/novadeck/slot.
#
# The two root images are content-identical by design -- that is what an A/B update produces, and
# RAUC will write the same bytes into whichever slot is inactive. So slot identity can never come
# from the root's CONTENT; it has to come from where the initramfs mounted it. The initramfs
# records its own decision in /run/novadeck/boot, but that comes from the code doing the choosing.
# This file is an INDEPENDENT witness: /run/novadeck/boot says which slot the initramfs thinks it
# picked, /var/lib/novadeck/slot says which var actually got mounted. If those two ever disagree,
# the selection is lying -- which is exactly the symptom of two btrfs filesystems sharing an fsid
# (see image/make-sdcard.sh). Four lines, and it is the only cross-check that does not share a
# failure mode with the thing it checks.
#
# Two mkfs runs also give the two images distinct ext4 UUIDs for free, which matters for the same
# reason: /home is mounted by LABEL, and duplicate filesystem identity across slots is the hazard.
install -d -m0755 "$varstage/lib/novadeck"
for slot in a b; do
  # UPPERCASE, matching the boot chain and the installer. The loop variable stays lowercase because
  # it names the images and the partitions (var-a, novadeck-var-A via ${slot^^}), but the WITNESS is
  # in bootconf naming: the kernel command line carries novadeck.slot=A|B, seed_var writes $SLOT,
  # and tests/test-post-install.sh asserts 'B'. This wrote 'a' and was the only thing in the
  # system spelling it lowercase -- discovered 2026-08-22 when installer/verify-install.sh, which
  # runs the card's check list against a real install, disagreed with image/verify-card.sh about
  # the same file. Nothing reads it at runtime (the initramfs takes the slot from the cmdline), so
  # this was cosmetic -- but a witness that answers differently depending on how the disk was made
  # is not a witness.
  printf '%s\n' "${slot^^}" >"$varstage/lib/novadeck/slot"
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
# anyone sizing the slot reads. rootfs-a is 7G (image/partition-table.txt), so the honest figure
# is a ~0.9G margin, where the allocated one implies ~2.9G. Both are printed: the allocated size
# is what the file costs on the build host, which is worth knowing too, just not on its own.
echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h --apparent-size "$IMG" | cut -f1) in a 7G slot," \
     "$(du -h "$IMG" | cut -f1) allocated, from $(du -sh "$stage" 2>/dev/null | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (ota/genbundle.sh)."
