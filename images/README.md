# images/

A/B atomic-update image assembly (SteamOS-style: RAUC + Btrfs read-only root). The
recipes consume the staged kernel (`kernel/build.sh`), fetched firmware
(`firmware/fetch-qcom-fw.sh` + `firmware/fetch-linux-fw.sh`), and a base rootfs, and emit
a slot image + signed OTA bundle.

## The read-only root

The root is mounted `ro`. Writable state lives in three places, mirroring SteamOS
(cf. the steamos-teardown reference):

- **`/var`** — its own ext4 partition, per-slot.
- **`/etc`** — an `overlayfs` whose upper dir is `/var/lib/overlays/etc/upper`. This is
  assembled by `initramfs/init` **before** systemd starts, and it has to be: systemd reads
  `/etc/fstab` (via generators), `machine-id` and `hostname` before any unit could run, so an
  overlay mounted by a unit would leave all of them pinned to the read-only lower dir forever.
- **`/home`** — the shared partition. The paths that grow without bound (`/var/log`,
  `/var/tmp`, `/var/cache/pacman`, `/opt`, `/root`, …) are bind-mounted onto
  `/home/.novadeck/offload/` by `novadeck-offload.target`, so the 256M `/var` never fills.

Because `/etc` rides on `/var`, and `/var` is per-slot, **a slot switch carries `/etc` with
it** — which is why RAUC must rsync `/var` across on update (see `TODO.md`).

| File | Purpose |
|---|---|
| `build-image.sh` | **Phase 1 flow orchestrator.** Chains base fetch → firmware fetch/verify → rootfs assembly into `out/images/rootfs.img`. |
| `fetch-base.sh` | Pull the pinned upstream base (`base.digest`) and export its **bare** rootfs to `work/base/`. No qemu — `docker export` only moves files. |
| `customize-base.sh` | Pin-pull the base, then under **arm64 emulation** (qemu binfmt) `pacman`-install the release runtime — NetworkManager (Wi-Fi, with its wpa_supplicant backend), bluez (Bluetooth), openssh (SSH), mesa + Turnip + vulkan-tools — and export to `work/base/`. What `build-image.sh` uses. Network required; no credentials baked in (NM is installed but inactive in a plain release base). |
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B boot, A/B root, A/B /var, shared /home). Single source of truth for sizes, typecodes and labels. |
| `genpart.sh [target\|--min]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given; print the fixed layout's minimum size in MiB with `--min`. |
| `initramfs/init` | The initramfs `/init`: mounts the root read-only, mounts `/var`, stacks the `/etc` overlay on it, then `switch_root`s into systemd. Degrades to a writable un-overlaid root (loudly, via `/dev/kmsg`) rather than bricking a device with no serial console. |
| `mkinitramfs.sh <base-rootfs>` | Stage `bash` + util-linux out of the base, resolve their libraries via `readelf`, and roll `init` into `out/initramfs.cpio.gz` (~2.2M). No mkinitcpio/dracut, no modules — every filesystem and block driver we need is `=y`. |
| `assemble-rootfs.sh <base-rootfs>` | Stage base + kernel + firmware, then split the tree into the two images the table wants: `rootfs.img` (btrfs, ro) and `var.img` (ext4, carries the `/etc` overlay upper). All unprivileged. Also injects InputPlumber config for all boards, the `session/` gamescope-session overlay, and the offload bind units. |
| `make-sdcard.sh` | Lay the **full** GPT from the table and populate only the A side (ESP + root-A + var-A + home, with `/home` pre-seeded with the native arm64 Steam client) → `out/images/sdcard.img`. The B slots and both `efi-*` partitions are created but empty, so adding RAUC later never needs a reflash. Unprivileged (mtools + sgdisk + `dd`, no loop). |
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
