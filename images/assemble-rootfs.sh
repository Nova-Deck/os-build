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
  done < <(find "$LFW" -type f 2>/dev/null)
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
# /etc/novadeck/session.conf, and the novadeck-session.service unit) mirror-copied into the
# rootfs. gamescope/seatd/vulkan-tools come from the base (customize-base.sh) — this adds no
# package, only the session wiring. The unit ships installed-but-DISABLED (no preset/symlink):
# Phase 2 validates it by hand (`systemctl start novadeck-session`) so it never seizes the panel
# from the SSH/smoke bring-up path; flipping to boot-enabled is a one-line preset add once it is
# proven on HW and the Phase-3 Steam shell lands. See devices/bringup-phase2.md step 2.
SESSION="$ROOT/session"
if [ -d "$SESSION" ]; then
  echo "  injecting novadeck gamescope-session from ${SESSION#"$ROOT"/} (installed, not auto-enabled)"
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
  echo "  injecting novadeck ALSA UCM2 profile from ${AUDIO#"$ROOT"/} (card SM8650-APS2)"
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
  # units stay enabled, plus pre-create the symlinks as a build-time fallback.
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  cat >"$stage/usr/lib/systemd/system-preset/70-novadeck-test.preset" <<EOF
enable sshd.service
enable NetworkManager.service
EOF
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/sshd.service \
         "$stage/etc/systemd/system/multi-user.target.wants/sshd.service"
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         "$stage/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
  # NM's D-Bus activation alias (what `systemctl enable NetworkManager` also creates).
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         "$stage/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service"

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

# 5. bake the Btrfs image (populate without mounting), then shrink to fit
mkdir -p "$IMGDIR"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.btrfs --rootdir "$stage" --shrink -L novadeck-root -f "$IMG" >/dev/null

echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h "$IMG" | cut -f1), from $(du -sh "$stage" | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
