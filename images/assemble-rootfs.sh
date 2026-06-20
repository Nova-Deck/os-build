#!/usr/bin/env bash
# novadeck read-only root assembler — Phase 4.
#
# Builds the Btrfs root image RAUC writes to a slot: stages a base rootfs, injects
# the novadeck kernel + dtbs (from kernel/build.sh) and the extracted device firmware
# (from firmware/extract.sh), then bakes a single-subvolume Btrfs image with
# `mkfs.btrfs --rootdir` — no root, no loop mount.
#
# The image content is read-only by construction; the subvolume's ro *property* is
# set by RAUC at deploy time (needs a mount), so it is not applied here.
#
#   images/assemble-rootfs.sh <soc> <base-rootfs-dir>
#   BASE_ROOTFS=<dir> images/assemble-rootfs.sh <soc>
#
# Run inside the build image (needs btrfs-progs + rsync):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build images/assemble-rootfs.sh sm8650 /path/to/base
set -euo pipefail
shopt -s nullglob

SOC="${1:-sm8650}"
BASE="${2:-${BASE_ROOTFS:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out/$SOC"
FW="$ROOT/firmware/extracted/$SOC"
LFW="$ROOT/firmware/linux-fw/$SOC"
IMGDIR="$OUT/images"
IMG="$IMGDIR/rootfs.img"
SIZE="${ROOTFS_SIZE:-5G}"   # matches rootfs-a/-b in partition-table.txt; --shrink trims it

[ -n "$BASE" ]        || { echo "usage: assemble-rootfs.sh <soc> <base-rootfs-dir>" >&2; exit 2; }
[ -d "$BASE" ]        || { echo "no base rootfs dir: $BASE" >&2; exit 2; }
[ -f "$OUT/Image.gz" ] || { echo "no kernel: $OUT/Image.gz (run kernel/build.sh first)" >&2; exit 1; }
command -v mkfs.btrfs >/dev/null 2>&1 || { echo "mkfs.btrfs not found (run inside novadeck-build)" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
echo "[novadeck] assembling $SOC read-only root (base=$BASE)"

# 1. base userspace (the Holo aarch64 preview rootfs)
if command -v rsync >/dev/null 2>&1; then rsync -aHAX --numeric-ids "$BASE"/ "$stage"/
else cp -a "$BASE"/. "$stage"/; fi

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

# 3. extracted device firmware under /lib/firmware (paths are already /lib/firmware-relative)
if [ -d "$FW" ]; then
  while IFS= read -r f; do
    rel="${f#"$FW"/}"
    install -Dm0644 "$f" "$stage/lib/firmware/$rel"
  done < <(find "$FW" -type f ! -name sha256sums.txt 2>/dev/null)
else
  echo "  (no extracted firmware at ${FW#"$ROOT"/} — run firmware/extract.sh; continuing)"
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
  echo "  (no linux-firmware at ${LFW#"$ROOT"/} — run firmware/fetch-linux-fw.sh $SOC; GPU/BT/VPU firmware will be missing)"
fi

# 4. novadeck marker so the running system can identify the slot's provenance
mkdir -p "$stage/etc"
{ echo "NOVADECK_SOC=$SOC"; echo "NOVADECK_BUILD=$(date -u +%Y%m%dT%H%M%SZ)"; } >"$stage/etc/novadeck-release"

# 4b. TEST-ONLY Wi-Fi/SSH injection (NOVADECK_TEST=1). NEVER part of a release/RAUC build:
# the release base is packages-only and first-boot networking is the SteamOS UI's job. Here
# we add ALL the scaffolding a throwaway card needs to auto-join the LAN and accept an SSH
# login to run vulkaninfo — interface config, regdom (via wpa country=), the Wi-Fi PSK + SSH
# key (from the environment, so secrets never touch the repo), service enablement, and host
# keys. The runtime packages (wpa_supplicant, openssh) come from the base (customize-base.sh).
if [ "${NOVADECK_TEST:-}" = "1" ]; then
  : "${NOVADECK_WIFI_SSID:?NOVADECK_TEST=1 requires NOVADECK_WIFI_SSID}"
  : "${NOVADECK_WIFI_PSK:?NOVADECK_TEST=1 requires NOVADECK_WIFI_PSK}"
  echo "  [TEST] injecting Wi-Fi + SSH scaffolding for '$NOVADECK_WIFI_SSID' (test-only)"

  # Interface rename: WCN7850 is PCIe so predictable naming gives wlpXsY; pin it to wlan0 so
  # wpa_supplicant@wlan0 + the .network below target it deterministically.
  install -d -m0755 "$stage/etc/systemd/network"
  cat >"$stage/etc/systemd/network/10-wlan.link" <<EOF
[Match]
Type=wlan
[Link]
Name=wlan0
EOF
  # systemd-networkd does DHCP on wlan0; wpa_supplicant handles the WPA association.
  cat >"$stage/etc/systemd/network/25-wlan0.network" <<EOF
[Match]
Name=wlan0
[Network]
DHCP=yes
EOF

  # wpa_supplicant@wlan0 reads this. country=BE sets the regulatory domain (enables 5 GHz)
  # at the supplicant layer, independent of the set-wireless-regdom udev helper.
  install -d -m0755 "$stage/etc/wpa_supplicant"
  ( umask 077; cat >"$stage/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=BE
network={
ssid="${NOVADECK_WIFI_SSID}"
psk="${NOVADECK_WIFI_PSK}"
}
EOF
  )

  # Regulatory domain at the kernel layer: the 85-regulatory.rules udev rule runs
  # set-wireless-regdom when cfg80211 loads; it sources this file and runs `iw reg set`.
  # The packaged file (from wireless-regdb) has every country commented out, so without this
  # the chip stays on the world domain (00) until wpa_supplicant's country= kicks in. Pin it
  # so 5 GHz is enabled from the moment cfg80211 loads (and the helper stops exiting 1).
  install -d -m0755 "$stage/etc/conf.d"
  printf '\nWIRELESS_REGDOM="BE"\n' >>"$stage/etc/conf.d/wireless-regdom"

  # Enable services. /etc/machine-id is empty, so systemd runs preset-all on first boot and
  # the stock 99-default.preset is "disable *"; ship a high-priority preset (70 < 99) so our
  # units stay enabled, plus pre-create the symlinks as a build-time fallback.
  install -d -m0755 "$stage/usr/lib/systemd/system-preset"
  cat >"$stage/usr/lib/systemd/system-preset/70-novadeck-test.preset" <<EOF
enable sshd.service
enable wpa_supplicant@wlan0.service
enable systemd-networkd.service
EOF
  install -d -m0755 "$stage/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/sshd.service \
         "$stage/etc/systemd/system/multi-user.target.wants/sshd.service"
  ln -sf /usr/lib/systemd/system/wpa_supplicant@.service \
         "$stage/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
  ln -sf /usr/lib/systemd/system/systemd-networkd.service \
         "$stage/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"

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
fi

# 5. bake the Btrfs image (populate without mounting), then shrink to fit
mkdir -p "$IMGDIR"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.btrfs --rootdir "$stage" --shrink -L novadeck-root -f "$IMG" >/dev/null

echo "  ok   rootfs -> ${IMG#"$ROOT"/}  ($(du -h "$IMG" | cut -f1), from $(du -sh "$stage" | cut -f1) staged)"
echo "Done. Read-only root ready for slot install / RAUC bundling (images/genbundle.sh)."
