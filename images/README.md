# images/

A/B atomic-update image assembly (SteamOS-style: RAUC + Btrfs read-only root). The
recipes consume the staged kernel (`kernel/build.sh`), extracted firmware
(`firmware/extract.sh`), and a base rootfs, and emit a slot image + signed OTA bundle.

| File | Purpose |
|---|---|
| `build-image.sh <soc> [vendor-tree]` | **Phase 1 flow orchestrator.** Chains base fetch → firmware extract/verify → rootfs assembly into `out/<soc>/images/rootfs.img`. |
| `fetch-base.sh [soc]` | Pull the pinned upstream base (`base.digest`) and export its rootfs to `work/base/<soc>/`. No qemu — `docker export` only moves files. |
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B GRUB, A/B root, A/B /var, shared /home). Single source of truth. |
| `genpart.sh <soc> [target]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given. |
| `assemble-rootfs.sh <soc> <base-rootfs>` | Stage base + kernel + firmware and bake a read-only Btrfs root image (`mkfs.btrfs --rootdir`, unprivileged) → `out/<soc>/images/rootfs.img`. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@SOC@`/`@VERSION@`). |
| `genbundle.sh <soc> [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Dev builds mint an ephemeral cert; release builds pass `RAUC_CERT`/`RAUC_KEY`. |

## End-to-end (Phase 1 bootable card)

Kernel first (`kernel/build.sh sm8650`), then one orchestrated flow that fetches the
base, stages firmware, and assembles the root:

```
images/build-image.sh sm8650 /path/to/vendor-partition-dump
```

`fetch-base.sh` runs on the host (needs `docker`); firmware extract/verify + assembly
run in `novadeck-kbuild`. The vendor dump is your device's own partitions — omit it only
if `firmware/extract.sh` has already populated `firmware/extracted/sm8650/`. Output is
`out/sm8650/images/rootfs.img`; package + deploy per `boot/` (KERNEL onto the ESP, rootfs
image onto the rootfs partition).

Individual tools (btrfs-progs, gdisk, dosfstools, mtools, rauc, casync, openssl) live in
the build image, so run them there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild images/assemble-rootfs.sh sm8650 /path/to/base
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild images/genbundle.sh sm8650
```

**Done (Phase 4 assembly):** partition layout, read-only Btrfs root, signed RAUC bundle.
**Deferred (runtime, needs an installed system/VM):** full disk population + GRUB A/B,
overlayfs `/etc`, `steamos-atomupd` client, and boot-failure auto-rollback — these are
validated by the Phase 4 gate (`install → OTA → forced-failure rollback`) on hardware.

_Phase 4._
