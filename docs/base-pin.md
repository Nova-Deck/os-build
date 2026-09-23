# Upstream base pinning

novadeck layers on Valve's official **Steam Frame ("deckard") aarch64 Arch Linux port** — the
same Collabora-built "mash" lineage the public `holo-core-aarch64-preview` was a frozen mirror
of — not on a from-scratch userspace rebuild. This document records *what* we pin and *how*.

## Source of truth

| Item | Value |
|---|---|
| Binary pacman repo | `https://holo-packages.steamos.cloud/archlinux-deckard/archlinux/<snapshot>/$repo/os/$arch` |
| Snapshot index | `https://holo-packages.steamos.cloud/archlinux-deckard/archlinux/` |
| Pinned snapshot | [`build/snapshot.pin`](../build/snapshot.pin) |
| Builder image | that snapshot's `system.rootfs.zst`, pinned by sha256 in [`build/builder.pin`](../build/builder.pin) |
| Frame-specific layer (NOT consumed) | `https://holo-packages.steamos.cloud/archlinux-deckard-hotfixes/<branch>/` |
| Frozen preview (previous base) | `https://holo-packages.steamos.cloud/holo-core-aarch64-preview/` |

`holo-packages.steamos.cloud` 302-redirects to `steamdeck-packages.steamos.cloud`; the host root
returns 401, subpaths are browsable. Nothing is signed: no `.sig` on any `.db` or package, and the
vendor's own `pacman.conf` sets `SigLevel = Optional`. The per-package sha256 in the locks is the
pin that actually holds.

The preview's `mash-20251118.3` is byte-identical to this tree's `mash-20251118.3` (`core.db` and
`extra.db` compared 2026-09-23) — moving the path changed no bytes.

## Snapshot naming

Under `archlinux-deckard/archlinux/`, only some directory names are snapshots:

| Name | What it is | Pinnable |
|---|---|---|
| `main`, `dev`, `builds`, `pipeline`, `tmp` | moving CI aliases | never |
| `mash-YYYYMMDD` | first revision of a snapshot, AND the alias that follows `.1`, `.2` … | yes — the lock is the real pin |
| `mash-YYYYMMDD.N` | a frozen revision | yes, preferred |
| `*.pvt`, `*-pvt` | unpublished meaning | refused |

`build/lib-pins.sh` enforces this table for every stage.

Each snapshot directory carries `core`, `extra`, their `-debug` twins, `extra-archive`, `multilib`,
`sources/` (source tarballs), a `pacman.conf` + `pacman.mirrorlist` (only `[core]` and `[extra]`
enabled — we match that in `rootfs/conf/pacman.conf`), and `system.rootfs.zst`.

## What we pin, and why

| Pin | File | What it selects |
|---|---|---|
| Package repo snapshot | [`build/snapshot.pin`](../build/snapshot.pin) | the repo **every file on the image is installed from** |
| arm64 builder | [`build/builder.pin`](../build/builder.pin) | the **execution environment** pacman/makepkg run in |

The builder is the pinned snapshot's own `system.rootfs.zst` (it ships `base-devel`). Its URL is
never written down: it is always `<snapshot>/system.rootfs.zst`, so builder and packages cannot come
from different snapshots. `build/lib-pins.sh` fetches it, checks the sha256, `docker import`s it,
points its pacman at the pinned snapshot, asserts every installed package is in that snapshot at
exactly the installed version, and tags the result `novadeck/builder:<sha256>`. The tag is keyed on
the tarball because `docker import` stamps a creation time, so the image ID is not reproducible.

Before 2026-09-23 the builder was `registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base-devel`,
pinned by digest in `build/base-devel.digest`. Its own mirrorlist pointed at the preview's
unsuffixed alias, and the overlay build ran `pacman -Sy` against it — so the overlay was never
actually built against `build/snapshot.pin`. It only agreed by coincidence.

Phase 4c deleted a third pin, `base.digest` (the `…/base` image the root used to be
`docker export`ed from). The root is bootstrapped with `pacman -r <empty-dir>` against the pinned
snapshot (`rootfs/customize-base.sh`), so no container image contributes files to what ships.

## Bumping

```bash
B=https://holo-packages.steamos.cloud/archlinux-deckard/archlinux
curl -sL $B/ | grep -o 'mash-[0-9.a-z-]*/' | sort -u                   # enumerate snapshots
curl -sL $B/<snapshot>/pacman.conf $B/<snapshot>/pacman.mirrorlist      # repo set Valve enables
curl -sIL $B/<snapshot>/core/os/aarch64/core.db | grep -iE 'etag|content-length|last-modified'
curl -sL $B/<snapshot>/system.rootfs.zst | sha256sum                    # -> build/builder.pin
```

Change `build/snapshot.pin` and `build/builder.pin` together, then `make relock` and
`make relock-installer`, and review both lock diffs. A bump moves the toolchain the overlay builds
with, so every `packages/*` rebuilds.

## Where the PKGBUILDs are

Valve's `frame-public/frame-developer-tools` (`pacman/deckard-pacman-src`) maps the base repos to
`potato/mash/monorepo` and the hotfix layer to `deckard/deckardos/holo` on gitlab.steamos.cloud —
both private. Each snapshot publishes its sources as tarballs under `sources/`. Overlay recipes we
fetch from GitLab (`packages/*/source.pin`) still come from the public
`holo/holo-core-aarch64-preview` repo at a pinned commit.
