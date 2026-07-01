# images/

A/B atomic-update image assembly (SteamOS-style: RAUC + Btrfs read-only root). The
recipes consume the staged kernel (`kernel/build.sh`), fetched firmware
(`firmware/fetch-qcom-fw.sh` + `firmware/fetch-linux-fw.sh`), and a base rootfs, and emit
a slot image + signed OTA bundle.

| File | Purpose |
|---|---|
| `build-image.sh` | **Phase 1 flow orchestrator.** Chains base fetch → firmware fetch/verify → rootfs assembly into `out/images/rootfs.img`. |
| `fetch-base.sh` | Pull the pinned upstream base (`base.digest`) and export its **bare** rootfs to `work/base/`. No qemu — `docker export` only moves files. |
| `customize-base.sh` | Pin-pull the base, then under **arm64 emulation** (qemu binfmt) `pacman`-install the release runtime — NetworkManager (Wi-Fi, with its wpa_supplicant backend), bluez (Bluetooth), openssh (SSH), mesa + Turnip + vulkan-tools — and export to `work/base/`. What `build-image.sh` uses. Network required; no credentials baked in (NM is installed but inactive in a plain release base). |
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B GRUB, A/B root, A/B /var, shared /home). Single source of truth. |
| `genpart.sh [target]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given. |
| `assemble-rootfs.sh <base-rootfs>` | Stage base + kernel + firmware and bake a read-only Btrfs root image (`mkfs.btrfs --rootdir`, unprivileged) → `out/images/rootfs.img`. Also injects InputPlumber config for all boards (`devices/inputplumber/` → `/etc/inputplumber/`) and enables the daemon on release, and the `session/` gamescope-session overlay (launcher + SDDM autologin wiring that boots the deck user into the shell as an active logind session — layer B). |
| `make-sdcard.sh` | **Phase 1 SD-test image.** Wrap the boot image + root into one flashable card image (GPT: FAT32 ESP holding `/KERNEL` + the Btrfs root) → `out/images/sdcard.img`. Unprivileged (mtools + sgdisk + `dd`, no loop). Not A/B — that is `partition-table.txt`. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@VERSION@`; `compatible=novadeck`). |
| `genbundle.sh [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Dev builds mint an ephemeral cert; release builds pass `RAUC_CERT`/`RAUC_KEY`. |

## End-to-end (Phase 1 bootable card)

Kernel first (`kernel/build.sh`), then one orchestrated flow that fetches the
base, stages firmware, and assembles the root:

```
images/build-image.sh
```

`customize-base.sh` runs on the host (needs `docker` + network + arm64 binfmt; it
pacman-installs the release runtime under emulation); firmware fetch/verify + assembly
run in `novadeck-build`. Device-proprietary firmware is fetched from the pinned
Nova-Deck/qcom-firmwares repo (`firmware/fetch-qcom-fw.sh`, idempotent — no device dump
needed). Output is `out/images/rootfs.img`; package + deploy per `boot/` (KERNEL
onto the ESP, rootfs image onto the rootfs partition).

To test on hardware off an SD card first, package the boot image then wrap both into one
card image (ESP + root, no A/B):

```
docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh
docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
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
  novadeck-build images/assemble-rootfs.sh work/base
docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh
docker run --rm -v "$PWD":/src -w /src novadeck-build images/make-sdcard.sh
```

`build-image.sh` forwards the same `NOVADECK_*` env, so the full flow honours it too. The
injection drops a `0600` `/etc/NetworkManager/system-connections/<SSID>.nmconnection` +
`/root/.ssh/authorized_keys` and enables `NetworkManager.service`; NM does its own DHCP and sshd
allows key-only root login (`PermitRootLogin prohibit-password`). Then on the device:
`ssh root@<dhcp-ip>` → `vulkaninfo | grep -E 'deviceName|driverName'` (expect Turnip / Adreno 750).

Individual tools (btrfs-progs, gdisk, dosfstools, mtools, rauc, casync, openssl) live in
the build image, so run them there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-build images/assemble-rootfs.sh /path/to/base
docker run --rm -v "$PWD":/src -w /src novadeck-build images/genbundle.sh
```

**Done (Phase 4 assembly):** partition layout, read-only Btrfs root, signed RAUC bundle.
**Deferred (runtime, needs an installed system/VM):** full disk population + GRUB A/B,
overlayfs `/etc`, `steamos-atomupd` client, and boot-failure auto-rollback — these are
validated by the Phase 4 gate (`install → OTA → forced-failure rollback`) on hardware.

_Phase 4._
