# images/

A/B atomic-update image assembly (SteamOS-style: RAUC + Btrfs read-only root). The
recipes consume the staged kernel (`kernel/build.sh`), extracted firmware
(`firmware/extract.sh`), and a base rootfs, and emit a slot image + signed OTA bundle.

| File | Purpose |
|---|---|
| `build-image.sh <soc> [vendor-tree]` | **Phase 1 flow orchestrator.** Chains base fetch → firmware extract/verify → rootfs assembly into `out/<soc>/images/rootfs.img`. |
| `fetch-base.sh <soc>` | Pull the pinned upstream base (`base.digest`) and export its **bare** rootfs to `work/base/<soc>/`. No qemu — `docker export` only moves files. |
| `customize-base.sh <soc>` | Pin-pull the base, then under **arm64 emulation** (qemu binfmt) `pacman`-install the release runtime — NetworkManager (Wi-Fi, with its wpa_supplicant backend), bluez (Bluetooth), openssh (SSH), mesa + Turnip + vulkan-tools — and export to `work/base/<soc>/`. What `build-image.sh` uses. Network required; no credentials baked in (NM is installed but inactive in a plain release base). |
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B GRUB, A/B root, A/B /var, shared /home). Single source of truth. |
| `genpart.sh <soc> [target]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given. |
| `assemble-rootfs.sh <soc> <base-rootfs>` | Stage base + kernel + firmware and bake a read-only Btrfs root image (`mkfs.btrfs --rootdir`, unprivileged) → `out/<soc>/images/rootfs.img`. Also injects per-SoC InputPlumber config (`devices/<soc>/inputplumber/` → `/etc/inputplumber/`) and enables the daemon on release, and the `session/` gamescope-session overlay (launcher + `novadeck-session.service`, installed but not auto-enabled — layer B). |
| `make-sdcard.sh <soc>` | **Phase 1 SD-test image.** Wrap the boot image + root into one flashable card image (GPT: FAT32 ESP holding `/KERNEL` + the Btrfs root) → `out/<soc>/images/sdcard.img`. Unprivileged (mtools + sgdisk + `dd`, no loop). Not A/B — that is `partition-table.txt`. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@SOC@`/`@VERSION@`). |
| `genbundle.sh <soc> [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Dev builds mint an ephemeral cert; release builds pass `RAUC_CERT`/`RAUC_KEY`. |

## End-to-end (Phase 1 bootable card)

Kernel first (`kernel/build.sh sm8650`), then one orchestrated flow that fetches the
base, stages firmware, and assembles the root:

```
images/build-image.sh sm8650 /path/to/vendor-partition-dump
```

`customize-base.sh` runs on the host (needs `docker` + network + arm64 binfmt; it
pacman-installs the release runtime under emulation); firmware extract/verify + assembly
run in `novadeck-build`. The vendor dump is your device's own partitions — omit it only
if `firmware/extract.sh` has already populated `firmware/extracted/sm8650/`. Output is
`out/sm8650/images/rootfs.img`; package + deploy per `boot/` (KERNEL onto the ESP, rootfs
image onto the rootfs partition).

To test on hardware off an SD card first, package the boot image then wrap both into one
card image (ESP + root, no A/B):

```
docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh sm8650
docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh sm8650
sudo dd if=out/sm8650/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### Test card: Wi-Fi + SSH (test-only)

The release runtime (NetworkManager, openssh, mesa/Turnip/vulkan-tools) ships in every build
via `customize-base.sh`. **Credentials** are not — they are injected only when assembling with
`NOVADECK_TEST=1`, straight from the environment, so they never touch the repo. Use this to
build a throwaway card that joins your LAN and accepts SSH, to run `vulkaninfo` on hardware:

```
docker run --rm -v "$PWD":/src -w /src \
  -e NOVADECK_TEST=1 -e NOVADECK_WIFI_SSID="$SSID" -e NOVADECK_WIFI_PSK="$PSK" \
  -e NOVADECK_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
  novadeck-build images/assemble-rootfs.sh sm8650 work/base/sm8650
docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh sm8650
docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh sm8650
```

`build-image.sh` forwards the same `NOVADECK_*` env, so the full flow honours it too. The
injection drops a `0600` `/etc/NetworkManager/system-connections/<SSID>.nmconnection` +
`/root/.ssh/authorized_keys` and enables `NetworkManager.service`; NM does its own DHCP and sshd
allows key-only root login (`PermitRootLogin prohibit-password`). Then on the device:
`ssh root@<dhcp-ip>` → `vulkaninfo | grep -E 'deviceName|driverName'` (expect Turnip / Adreno 750).

Individual tools (btrfs-progs, gdisk, dosfstools, mtools, rauc, casync, openssl) live in
the build image, so run them there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-build images/assemble-rootfs.sh sm8650 /path/to/base
docker run --rm -v "$PWD":/src -w /src novadeck-build images/genbundle.sh sm8650
```

**Done (Phase 4 assembly):** partition layout, read-only Btrfs root, signed RAUC bundle.
**Deferred (runtime, needs an installed system/VM):** full disk population + GRUB A/B,
overlayfs `/etc`, `steamos-atomupd` client, and boot-failure auto-rollback — these are
validated by the Phase 4 gate (`install → OTA → forced-failure rollback`) on hardware.

_Phase 4._
