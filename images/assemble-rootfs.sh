#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 4.
#
# Builds the Btrfs root image RAUC writes to a slot: stages a base rootfs, injects
# the novadeck kernel + dtbs (from kernel/build.sh) and the device firmware
# (from firmware/fetch-qcom-fw.sh), then bakes a single-subvolume Btrfs image with
# `mkfs.btrfs --rootdir` — no root, no loop mount.
#
# The image content is read-only by construction; the subvolume's ro *property* is
# set by RAUC at deploy time (needs a mount), so it is not applied here.
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
SIZE="${ROOTFS_SIZE:-5G}"   # matches rootfs-a/-b in partition-table.txt; --shrink trims it

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

# Scrub the container provenance that `docker export` of the base leaves behind, so the sealed
# image looks like the bare-metal OS it is — not the build container it was assembled in. This is
# the maintenance tax of bootstrapping from a Docker base (vs SteamOS's manifest-sealed image); keep
# it explicit and named so a future base bump that leaks a new artifact has an obvious home. Phase-4
# migrates to manifest-driven sealing, which removes the need for this entirely (see rootfs plan).
#
# Audited on the SM8650 base 2026-06-25 — only the marker below was actually harmful; the other
# docker-export tells are benign and deliberately left alone:
#   - /etc/{resolv.conf,hostname,hosts}: empty 0-byte stubs; NetworkManager populates resolv.conf at
#     runtime (DNS verified working on HW), so blanking/owning them here would be churn for no gain.
#   - /etc/machine-id: correctly empty — REQUIRED so systemd runs preset-all on first boot. Do NOT
#     populate it here (that would disable our preset-based service enablement).
sanitize_base_provenance() {
  # /.dockerenv (and podman's /run/.containerenv) make `systemd-detect-virt` report a container on
  # the real device, so systemd SILENTLY skips every `ConditionVirtualization=!container` unit —
  # systemd-timesyncd is the visible casualty (clock stuck at epoch) but it gates ~13 units.
  # HW-confirmed on 192.168.1.186 (2026-06-25). These must never reach the sealed image.
  rm -f "$1/.dockerenv" "$1/run/.containerenv"
}
sanitize_base_provenance "$stage"

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

# 4b. RELEASE input config: ship InputPlumber's device/profile config from
# devices/inputplumber/ into /etc/inputplumber/ and enable the daemon. This is the union of
# every supported board's config; InputPlumber matches by hardware, so non-matching configs
# are inert. Unlike the TEST block below this is part of EVERY build — a handheld needs its
# gamepad/gyro mapping
# at first boot. The inputplumber package itself comes from the base (customize-base.sh).
# /etc/inputplumber overrides the package's /usr/share/inputplumber defaults — but ONLY via
# the `.d` override dirs InputPlumber actually scans under /etc: composite configs in
# devices.d/ and capability maps in capability_maps.d/ (the un-suffixed `devices`/
# `capability_maps` names apply only under the /usr/share base path). The repo tree is laid
# out with those `.d` names so this plain mirror-copy lands them where the daemon reads them;
# do NOT rename them back or the configs load from nowhere and no composite device is built.
IPCONF="$ROOT/devices/inputplumber"
if [ -d "$IPCONF" ]; then
  echo "  injecting InputPlumber config from ${IPCONF#"$ROOT"/}"
  install -d -m0755 "$stage/etc/inputplumber"
  cp -a "$IPCONF"/. "$stage/etc/inputplumber/"
  # Enable on release: stock 99-default.preset is "disable *", so ship a higher-priority
  # preset (60 < 99) plus a build-time symlink as a fallback (cf. the test preset at 70).
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  echo "enable inputplumber.service" \
    >"$stage/usr/lib/systemd/system-preset/60-novadeck.preset"
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/inputplumber.service \
         "$stage/etc/systemd/system/multi-user.target.wants/inputplumber.service"
else
  echo "  (no InputPlumber config at devices/inputplumber — skipping; package defaults apply, daemon not force-enabled)"
fi

# 4d. RELEASE gamescope-session (SteamOS layer B): the boot-to-compositor plumbing. A static,
# SoC-agnostic overlay tree under session/ (launcher /usr/bin/novadeck-session, its config
# /etc/novadeck/session.conf, the SDDM autologin wiring, and PAM drop-ins) mirror-copied into the
# rootfs. gamescope/seatd/vulkan-tools + sddm come from the base (customize-base.sh; sddm is built
# into the [novadeck] overlay) — this adds no package here, only the session wiring.
# The device boots through SDDM autologin, the SteamOS/armada way: sddm.service is enabled here
# (60-novadeck-sddm.preset + an etc/systemd/system/display-manager.service symlink) and the overlay
# points default.target at graphical.target, so on boot SDDM logs the deck user in through PAM
# (pam_systemd → a REAL ACTIVE seat0 logind session) and launches the `novadeck` wayland session
# (/usr/share/wayland-sessions/novadeck.desktop → the launcher). That active session is what lets
# STOCK polkit authorize Wi-Fi (allow_active) and timezone (subject.active && wheel), so the old
# "no-active" bypass rule is gone. Because it is a login session, logind provides /run/user/1000 +
# the user D-Bus bus (no linger needed). seatd.service still IS enabled (60-novadeck-seatd.preset +
# multi-user.target.wants symlink): the launcher keeps opening the DRM seat via the persistent root
# seatd (armada runs seatd alongside SDDM too) — the HW-validated seat/DRM path is unchanged; SDDM
# only wraps it in a login session. See devices/bringup-phase2.md step 2.
SESSION="$ROOT/session"
if [ -d "$SESSION" ]; then
  echo "  injecting novadeck gamescope-session from ${SESSION#"$ROOT"/} (ARMED: boots to Deck shell)"
  cp -a "$SESSION"/. "$stage/"
  chmod 0755 "$stage/usr/bin/novadeck-session"
else
  echo "  (no session/ tree — skipping gamescope-session injection)"
fi

# 4e. RELEASE novadeck HW-support (SteamOS layer C): the Qualcomm backings for Deck-UI affordances
# that AMD's jupiter-hw-support assumes. A static, SoC-agnostic overlay tree under hw-support/.
# First backing: novadeck-rest — a userspace "rest mode" (fake suspend) standing in for s2idle,
# whose maturity on these SoCs is the top HW risk; it blanks the panel (via gamescope's own KMS
# modeset), offlines all but the boot CPU, soft-blocks radios, and drops cpufreq to powersave. No
# package added — gamescopectl ships in our from-source gamescope; the rest is pure sysfs. The
# power-key trigger (novadeck-waked) IS enabled here (preset + multi-user.target.wants symlink ship
# inside the overlay) so the key drives suspend/resume + long-press poweroff at boot; novadeck-rest
# stays a hand-run dev tool. The overlay also carries the SoC-agnostic release-system backings that
# pair with the Deck UI: the Bluetooth stack (bluetoothd enabled via 60-novadeck-bluetooth.preset;
# bluez packages come from customize-base.sh), systemd-timesyncd for a sane clock (no RTC sync
# otherwise). No Wi-Fi resume hook ships: NM re-associates unaided after the suspend rfkill-unblock
# (the old resume.d/50-nm-reup nudge was HW-confirmed moot, 2026-06-25). The generic resume.d drop-in
# point in novadeck-suspend remains for future fix-ups. See devices/bringup-phase2.md step 3.
HWSUPPORT="$ROOT/hw-support"
if [ -d "$HWSUPPORT" ]; then
  echo "  injecting novadeck HW-support from ${HWSUPPORT#"$ROOT"/} (wake agent + bluetooth + timesyncd enabled)"
  cp -a "$HWSUPPORT"/. "$stage/"
  chmod 0755 "$stage/usr/bin/novadeck-rest" "$stage/usr/bin/novadeck-suspend" "$stage/usr/bin/novadeck-waked"
else
  echo "  (no hw-support/ tree — skipping HW-support injection)"
fi

# 4f. RELEASE Steam shell (SteamOS layer D): the native arm64 Steam plumbing. Two parts:
#  - the steam/usr overlay (SoC-agnostic): the first-boot SEEDER (/usr/lib/novadeck/
#    steam-bootstrap.sh) + its oneshot (novadeck-steam-bootstrap.service) and the launcher
#    (/usr/bin/novadeck-steam) NOVADECK_SESSION_CMD points at. Also 50-novadeck-timezone.rules —
#    a small polkit grant for org.freedesktop.timedate1.set-timezone (active session + wheel), the
#    ONE thing stock polkit still prompts for now that the shell runs in a real active logind
#    session (Wi-Fi is covered by NetworkManager's allow_active, no rule needed). Also the OOBE
#    update-check stubs (steamos-update, steamos-mandatory-update, jupiter-biosupdate,
#    jupiter-initial-firmware-update) — SteamUI shells to these past the Wi-Fi/timezone screens and
#    a missing binary blocks onboarding with an "update check failed" error; we bake no
#    jupiter-hw-support and have no OS updater in Phase 1, so they report "up to date". ONLY usr/ is
#    copied — the steam/ top-level build files (STEAM_SEED.pin, fetch-steam-seed.sh) are NOT rootfs
#    content.
#  - the BAKED seed: the native client + SR3 runtime staged on the build host (steam/
#    fetch-steam-seed.sh -> work/steam-seed) copied into the SEALED root at
#    /usr/share/novadeck/steam-seed. UNLIKE the old curl-on-first-boot path, the client IS baked in;
#    the first-boot seeder copies it into the writable /home/deck OFFLINE (Steam's OOBE owns Wi-Fi,
#    so an OS-side first-boot fetch deadlocks — see steam-must-be-baked-offline). Steam still
#    self-updates the rest of the UI on first launch (curl/unzip/tar stay in the base for that).
# The seeder unit is enabled via the session overlay (60-novadeck-steam-bootstrap.preset +
# graphical.target.wants symlink) and ordered Before=sddm.service, so its ~1GB seed lands in
# /home/deck before SDDM autologins the shell. See devices/bringup-phase3.md.
STEAM="$ROOT/steam"
if [ -d "$STEAM/usr" ]; then
  echo "  injecting novadeck Steam shell from ${STEAM#"$ROOT"/}/usr (seeder + launcher)"
  cp -a "$STEAM"/usr "$stage/"
  chmod 0755 "$stage/usr/bin/novadeck-steam" "$stage/usr/lib/novadeck/steam-bootstrap.sh" \
             "$stage/usr/bin/steamos-mandatory-update" "$stage/usr/bin/jupiter-initial-firmware-update" \
             "$stage/usr/bin/steamos-polkit-helpers/steamos-set-timezone" \
             "$stage/usr/bin/steamos-polkit-helpers/steamos-update" \
             "$stage/usr/bin/steamos-polkit-helpers/jupiter-biosupdate"
  SEED="$ROOT/work/steam-seed"
  if [ -x "$SEED/steamrtarm64/steam" ]; then
    echo "  baking Steam seed from ${SEED#"$ROOT"/} -> /usr/share/novadeck/steam-seed ($(du -sh "$SEED" | cut -f1))"
    install -d -m0755 "$stage/usr/share/novadeck"
    cp -a "$SEED" "$stage/usr/share/novadeck/steam-seed"
  else
    echo "  WARNING: no baked Steam seed at ${SEED#"$ROOT"/} — run steam/fetch-steam-seed.sh (first boot will have no client)" >&2
  fi
else
  echo "  (no steam/usr tree — skipping Steam shell injection)"
fi

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
# we have no initramfs, so ship our own unit running the same tool early in real-root boot, before
# /home mounts. repart matches our partition by its discoverable "Linux /home" GUID (make-sdcard
# gives p3 typecode 8302), so it can never touch the root partition.
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
# resize2fs), so silence the duplicate. REVISIT at Phase-4 initramfs — the stock unit is meant to run
# there (see the initramfs-phase4 note) and should be UNmasked when that path exists.
ln -sf /dev/null "$stage/etc/systemd/system/systemd-repart.service"

# 4b-audio. ALSA UCM2 machine profile (SteamOS layer C audio). A static overlay tree under
# audio/ mirror-copied into the rootfs: the device's card-name-matched UCM2 profile so userland
# knows the routing (speaker/headphone/DP paths, jack handling). The profile is the ROCKNIX
# Pocket S2 config (card model SM8650-APS2, matching the DT sound_card model + the AudioReach
# tplg). conf.d/sm8650/ ships two relative symlinks (SM8650-APS2 + the EFI-boot card-name
# variant ayaneo-AYANEOPocketS2-) -> the profile; cp -a preserves them. The profile Includes
# codec snippets (/codecs/wcd939x, /codecs/qcom-lpass/{wsa,rx}-macro, /codecs/wsa884x) that must
# be provided by the base alsa-ucm-conf package — ensure it is in the release PKGS (layer-4 work).
AUDIO="$ROOT/audio"
if [ -d "$AUDIO" ]; then
  echo "  injecting novadeck ALSA UCM2 profile from ${AUDIO#"$ROOT"/}"
  cp -a "$AUDIO"/. "$stage/"
else
  echo "  (no audio/ tree — skipping UCM2 injection)"
fi

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
# Keep the gamescope WSI Vulkan layer ON by default (matches the novadeck-session launcher + upstream
# ChimeraOS gamescope-session-plus). NOTE: this smoke is a RE-LAUNCH-heavy bring-up tool, and with WSI
# on, re-launching gamescope after a prior instance intermittently wedges (the client blocks in
# drm_syncobj_array_wait_timeout on a never-signaling explicit-sync fence — a userspace race, NOT stale
# GPU state; a fresh power-on is always clean). While iterating over SSH you can force the clean
# implicit-sync path with `ENABLE_GAMESCOPE_WSI=0 nova-gamescope-smoke`. See bringup-phase2.md step 1e.
export ENABLE_GAMESCOPE_WSI="${ENABLE_GAMESCOPE_WSI:-1}"
client="${1:-vkcube}"
echo "[nova] gamescope DRM smoke: client=$client  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
# An SSH session has no graphical logind seat, and the holo libseat is built with only the
# logind+seatd backends (no 'builtin'), so run under a seatd daemon. seatd-launch spawns seatd,
# exports SEATD_SOCK + LIBSEAT_BACKEND=seatd for the child, and tears seatd down on exit.
# Patched gamescope (from-source overlay): --use-rotation-shader rotates the portrait-native
# Pocket S2 panel in the GPU composite and scans out a ROTATE_0 buffer (the msm DPU can't
# ROTATE_90 a LINEAR plane). Verified upright on HW 2026-06-21. NOTE: --immediate-flips is NOT
# passed — it is a no-op here (the msm DPU does not advertise DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP, so
# gamescope drops the async flag). The intermittent composite-flip freeze is on the vsync'd path
# and unrelated. See devices/bringup-phase2.md.
gs_args="--backend drm --use-rotation-shader"
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

# 4z. Normalize overlay ownership to root. The overlay trees (session/, hw-support/, steam/usr,
# audio/, inputplumber config) are injected with `cp -a`, which PRESERVES the host build user's
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

# 5. bake the Btrfs image (populate without mounting), then shrink to fit
mkdir -p "$IMGDIR"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.btrfs --rootdir "$stage" --shrink -L novadeck-root -f "$IMG" >/dev/null

echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h "$IMG" | cut -f1), from $(du -sh "$stage" 2>/dev/null | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
