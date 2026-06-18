# images/

A/B atomic-update image assembly (SteamOS-style: RAUC + Btrfs read-only root). The
recipes consume the staged kernel (`kernel/build.sh`), extracted firmware
(`firmware/extract.sh`), and a base rootfs, and emit a slot image + signed OTA bundle.

| File | Purpose |
|---|---|
| `partition-table.txt` | The 8-partition A/B layout (ESP, A/B GRUB, A/B root, A/B /var, shared /home). Single source of truth. |
| `genpart.sh <soc> [target]` | Emit an `sgdisk` script from the table; apply it to a disk/image when `target` is given. |
| `assemble-rootfs.sh <soc> <base-rootfs>` | Stage base + kernel + firmware and bake a read-only Btrfs root image (`mkfs.btrfs --rootdir`, unprivileged) → `out/<soc>/images/rootfs.img`. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@SOC@`/`@VERSION@`). |
| `genbundle.sh <soc> [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Dev builds mint an ephemeral cert; release builds pass `RAUC_CERT`/`RAUC_KEY`. |

Tools (btrfs-progs, gdisk, dosfstools, mtools, rauc, casync, openssl) live in the
build image, so run there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild images/assemble-rootfs.sh sm8650 /path/to/base
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild images/genbundle.sh sm8650
```

**Done (Phase 4 assembly):** partition layout, read-only Btrfs root, signed RAUC bundle.
**Deferred (runtime, needs an installed system/VM):** full disk population + GRUB A/B,
overlayfs `/etc`, `steamos-atomupd` client, and boot-failure auto-rollback — these are
validated by the Phase 4 gate (`install → OTA → forced-failure rollback`) on hardware.

_Phase 4._
