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
it** — which is why RAUC rsyncs `/var` across on update, in
`fs-overlay/usr/lib/rauc/post-install.sh` (rationale and HW evidence: `DONE.md`).

| File | Purpose |
|---|---|
| `build-image.sh` | **Phase 1 flow orchestrator.** Chains root bootstrap → firmware fetch/verify → rootfs assembly into `out/images/rootfs.img`. |
| `customize-base.sh` | **Bootstraps the root from packages** (Phase 4c): `pacman -r work/base` into an *empty* tree under **arm64 emulation** (qemu binfmt), installing the `base` metapackage plus the release runtime — NetworkManager (Wi-Fi, with its wpa_supplicant backend), bluez (Bluetooth), openssh (SSH), mesa + Turnip + vulkan-tools. Docker is the execution environment (`base-devel.digest`), never the content source, so nothing is inherited and `/.dockerenv` never exists in the target. Network required; no credentials baked in (NM is installed but inactive in a plain release base). |
| `pacman.conf` + `os-release` | Committed declarations staged into the bootstrap container: the repo set the root is resolved from, and the root's own identity (over the vendor's `/usr/lib/os-release`). |
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B boot, A/B root, A/B /var, shared /home). Single source of truth for sizes, typecodes and labels. |
| `genpart.sh [target\|--min]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given; print the fixed layout's minimum size in MiB with `--min`. |
| `initramfs/init` | The initramfs `/init` (Phase 5): mounts the booted slot's root read-only + its `/var`, mounts the slot's efi-a/b partition at `/efi` (from `novadeck.efi=PARTUUID=`), stacks the `/etc` overlay on `/var`, then `switch_root`s into systemd. Slot selection is not here — the bootloader chain did it. Degrades to a writable un-overlaid root (loudly, via `/dev/kmsg`) rather than bricking a device with no serial console. |
| `mkinitramfs.sh <base-rootfs>` | Stage `bash` + util-linux out of the base, resolve their libraries via `readelf`, and roll `init` into `out/initramfs.cpio.gz` (installed as `/boot/initramfs-novadeck.img`). No mkinitcpio/dracut, no modules — every filesystem and block driver we need is `=y`. |
| `assemble-rootfs.sh <base-rootfs>` | Stage base + kernel + firmware, then split the tree into the two images the table wants: `rootfs.img` (btrfs, ro) and `var.img` (ext4, carries the `/etc` overlay upper). All unprivileged. Also injects the unified `fs-overlay/` payload (session, HW-support, InputPlumber, audio, FEX, Steam shell) and the offload bind units. |
| `seal.list` + `seal-rootfs.sh` | **What a release root must not be able to do** (Phase 4a step 3). The list declares the packages and paths removed after the last install — pacman, gnupg/dirmngr, the keyring and its vendor-enabled weekly timer; the script expands each name through the package database and deletes its files. The database survives as provenance under `/usr/lib/novadeck/pkgdb`. Release only: a `NOVADECK_DEV` card keeps pacman on purpose. |
| `trim.list` + `trim-rootfs.sh` | **What a release root need not weigh** (Phase 4a step 5). Same declare-then-apply shape, for build and documentation artefacts: headers, static libs, cmake/pkgconfig, `.gir`, man/doc/info, locale sources and non-English catalogues, and the gcc-libs language runtimes nothing links. Runs after the seal, release only. ~225 MB compressed, paid twice under A/B (both slots, plus every bundle). |
| `guard-rootfs.sh` | **The check that stops both lists from being comments** (Phase 4a step 4). Asserts on the built tree, never on the source diff: the seal fully applied, the named package-manager entry points gone, no dangling systemd enable-symlink, `manifest.lock` still describing the tree, the trim fully applied — plus a report-only per-directory size delta against the previous build. |
| `make-sdcard.sh` | Lay the **full** GPT from the table and populate **both** slots (Phase 5): the ESP carries the stage-1 steamcl + `SteamOS/conf` + a seeded grubenv; each slot's `efi-*` partition carries its stage-2 GRUB + partsets; root-A/B + var-A/B + home. `/home` is pre-seeded with the native arm64 Steam client. → `out/images/sdcard.img`. Unprivileged (mtools + sgdisk + `dd`, no loop). |
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
needed). Output is `out/images/rootfs.img`; the root carries its own boot half
(`/boot/{Image, initramfs-novadeck.img, dtbs}` + the `/usr/lib/novadeck/boot` mirror).
The flashable card is `images/make-sdcard.sh` (or `make sdcard`).

To test on hardware off an SD card:

```
images/make-sdcard.sh
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

### Test card: Wi-Fi + SSH (test-only)

The release runtime (NetworkManager, openssh, mesa/Turnip/vulkan-tools) ships in every build
via `customize-base.sh`. **Credentials** are not — they are injected only when assembling with
`NOVADECK_DEV=1`, straight from the environment, so they never touch the repo. Normally you get
them from `set -a; . ./dev.env; set +a` (tracked and secret-free; it sources the gitignored
`dev.env.local` for your SSID/PSK and generates a throwaway SSH key under `work/dev-ssh/`).

The Wi-Fi profile is **optional**. With no creds — or with `NOVADECK_WIFI=0` — you get a card
that starts with no network and no SSH, which is the shipping first-boot condition and the only
honest way to exercise OOBE locally. `NOVADECK_WIFI=1` makes missing creds a hard error instead,
for anything that depends on being able to SSH in. Which way it went is recorded in
`ROOTFS_MODE` (`dev` vs `dev-nowifi`), so flipping it re-assembles the rootfs rather than handing
back the previous card.

Spelled out, for a throwaway card that joins your LAN and accepts SSH:

```
docker run --rm -v "$PWD":/src -w /src \
  -e NOVADECK_DEV=1 -e NOVADECK_WIFI_SSID="$SSID" -e NOVADECK_WIFI_PSK="$PSK" \
  -e NOVADECK_SSH_PUBKEY="$(cat work/dev-ssh/id_ed25519.pub)" \
  novadeck-build images/assemble-rootfs.sh work/base
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

**Done (Phase 5 assembly):** partition layout, read-only Btrfs root, signed RAUC bundle,
SteamDeck-style boot (steamcl stage 1 + per-slot GRUB stage 2 + kernel in the slot root),
initramfs `/efi` mount, both slots populated by `make-sdcard.sh`, and the offline suites in
`make test` (`test-stage2-grub.sh`, `test-units.sh`, `test-bootctl.sh`, `test-post-install.sh`)
plus `make verify-card` against the built image.
**Deferred (needs hardware):** the whole chain end to end — ABL chainloading stage 1, the board
choice persisting to the ESP grubenv, a slot switch, and the demote path. All of those, plus the
stage-2 `novadeck_bootattempts` counter that rolls back a slot never reaching systemd, are
HW-validated as of 2026-08-02 (`docs/phase5.md`). `steamos-atomupd` remains out of scope.

_Phase 5._
