# image/

Turning a built root into **partitions on a disk**: the A/B layout, the initramfs that mounts
the booted slot, the card assembler that populates both slots, and the verifier that reads the
result back. What goes *inside* the root is `rootfs/`; wrapping it for OTA is `ota/`.

A/B atomic updates, SteamOS-style: RAUC + Btrfs read-only root. The recipes consume the staged
kernel (`kernel/build.sh`), fetched firmware (`firmware/fetch-qcom-fw.sh` +
`firmware/fetch-linux-fw.sh`), and the assembled root, and emit a flashable card.

## The layout

| File | Purpose |
|---|---|
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B boot, A/B root, A/B /var, shared /home). Single source of truth for sizes, typecodes and labels. |
| `genpart.sh [target\|--min]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given; print the fixed layout's minimum size in MiB with `--min`. |
| `lib-gpt.sh` | Sourced, never executed. The shared GPT reader — live partition index, type GUIDs, extents. Used by `genpart.sh` and `rootfs/guard-rootfs.sh` here, and by the installer's `select-target.sh`/`carve.sh` on the device, so both sides read a disk the same way. |

## Boot

| File | Purpose |
|---|---|
| `initramfs/init` | The initramfs `/init` (Phase 5): mounts the booted slot's root read-only + its `/var`, mounts the slot's efi-a/b partition at `/efi` (from `novadeck.efi=PARTUUID=`), stacks the `/etc` overlay on `/var`, then `switch_root`s into systemd. Slot selection is not here — the bootloader chain did it. Degrades to a writable un-overlaid root (loudly, via `/dev/kmsg`) rather than bricking a device with no serial console. |
| `mkinitramfs.sh <base-rootfs>` | Stage `bash` + util-linux out of the base, resolve their libraries via `readelf`, and roll `init` into `out/initramfs.cpio.gz` (installed as `/boot/initramfs-novadeck.img`). No mkinitcpio/dracut, no modules — every filesystem and block driver we need is `=y`. |

## Assembly and verification

| File | Purpose |
|---|---|
| `make-sdcard.sh` | Lay the **full** GPT from the table and populate **both** slots (Phase 5): the ESP carries the stage-1 steamcl + `SteamOS/conf` + a seeded grubenv; each slot's `efi-*` partition carries its stage-2 GRUB + partsets; root-A/B + var-A/B + home. `/home` is pre-seeded with the native arm64 Steam client. → `out/images/sdcard.img`. Unprivileged (mtools + sgdisk + `dd`, no loop). |
| `lib-homestage.sh` | Sourced, never executed. The deck user's `/home`, built once and used by two writers — `make-sdcard.sh` at build time and `installer/novadeck-install` on the device — because the two must produce the same tree. The parts that drift silently are the `~/.steam` compat symlinks: a missing sdk64 does not stop Steam starting, it makes an x86 title's `SteamAPI_Init()` fail at launch, on that medium only. |
| `verify-card.sh` | Read the built card back and assert what actually landed: the GPT against the table, each slot's stage-2 config, the seeded grubenv. `make verify-card`. |
| `card-meta.sh` | Emit the card's own metadata (version, git, mode, sizes) for the release workflows and `ota/publish-card.sh`. |

## End-to-end

Build the root first (`rootfs/build-image.sh`), then:

```
image/make-sdcard.sh
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

For a throwaway card that joins your LAN and accepts SSH, see `rootfs/README.md` — the
credentials are injected during rootfs assembly, not here.

Individual tools (btrfs-progs, gdisk, dosfstools, mtools, rauc, casync, openssl) live in
the build image, so run them there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-build image/make-sdcard.sh
```

**Done (Phase 5 assembly):** partition layout, read-only Btrfs root, SteamDeck-style boot
(steamcl stage 1 + per-slot GRUB stage 2 + kernel in the slot root), initramfs `/efi` mount,
both slots populated by `make-sdcard.sh`, and the offline suites in `make test`
(`tests/test-stage2-grub.sh`, `tests/test-units.sh`, `tests/test-bootctl.sh`,
`tests/test-post-install.sh`) plus `make verify-card` against the built image.
**Deferred (needs hardware):** the whole chain end to end — ABL chainloading stage 1, the board
choice persisting to the ESP grubenv, a slot switch, and the demote path. All of those, plus the
stage-2 `novadeck_bootattempts` counter that rolls back a slot never reaching systemd, are
HW-validated as of 2026-08-02 (`docs/phase5.md`). `steamos-atomupd` remains out of scope.

_Phase 5._
