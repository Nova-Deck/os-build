# Upstream base pinning

novadeck layers on Valve/Collabora's official **aarch64 Arch Linux port**, not a
from-scratch userspace rebuild. This document records *what* we pin and *how*.

## Source of truth

| Item | Value |
|---|---|
| Reference repo | `https://gitlab.steamos.cloud/holo/holo-core-aarch64-preview` |
| Binary pacman repo | `https://holo-packages.steamos.cloud/holo-core-aarch64-preview` |
| Docker base | `registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base` |
| Docker base-devel | `registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base-devel` |
| Arch snapshot | `2025-11-18` — gitref `mash-squashed_2025-11-18.3` |
| Snapshot ceil id | `a4790e7b6da0714e7ddd523658fa1a4486ce8f18` |
| Snapshot floor id | `6eaea65976f149fda9380358ddefc146826b1e51` |

## Why pin

The base is an explicit **technology preview** — "not intended for production… no
stability, support, or compatibility guarantees." It can move or disappear. We therefore
pin by **immutable digest**, not by tag, and plan to **mirror locally**.

## What the base already provides (do NOT rebuild)

`gamescope` (3.16.17), `mesa`, `rauc`, `casync`, `grub`, `linux-firmware`, `mkinitcpio`,
`ostree`, `vulkan-tools`, `wine`, and ~3,586 package sources total.

## What the base does NOT provide (novadeck's work)

`steam`, `proton`, `fex`/FEX-Emu, `box64`, the **device kernel** (`linux` — only
`linux-firmware` ships), Qualcomm SoC firmware, the SteamOS `jupiter-*` layer, and any
assembled bootable image.

## What we pin, and why the image pin went away (Phase 4c)

Two artifacts, pinned by different mechanisms and for different reasons:

| Pin | File | What it selects |
|---|---|---|
| Package repo revision | [`build/snapshot.pin`](../build/snapshot.pin) | the repo **every file on the image is installed from** |
| arm64 builder image | [`build/base-devel.digest`](../build/base-devel.digest) | the **execution environment** the build runs pacman/makepkg in |

There used to be a third, `base.digest`, pinning the `…/base` container image the root was
`docker export`ed from. **Phase 4c deleted it.** The root is now bootstrapped —
`pacman -r <empty-dir>` against the pinned snapshot (`rootfs/customize-base.sh`) — so no
container image contributes files to what ships, and the one that remains is only where
aarch64 binaries are *executed*. Docker is still required, and so is qemu binfmt: laying an
aarch64 root down means running an aarch64 pacman and its install scriptlets.

The digest it held, for the record:

```
registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview/base@sha256:edd05b6cf82e4a7f8bab2fb8dd453c45fc44405d7e5a25e36fe229607a224e88
```

Reference any image **by digest**, never by tag — `build/base-devel.digest` follows the same rule,
and `rootfs/customize-base.sh` refuses a ref that is not `…@sha256:<digest>`.

### How to re-resolve / detect drift

No `skopeo` locally; use the registry HTTP API token dance (works anonymously):

```bash
REG=https://registry.gitlab.steamos.cloud
REPO=holo/holo-core-aarch64-preview/base
tok=$(curl -s "https://gitlab.steamos.cloud/jwt/auth?service=container_registry&scope=repository:${REPO}:pull" \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -sI -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  "$REG/v2/$REPO/manifests/aarch64-mash-20251118.1" | grep -i docker-content-digest
```

> TODO(Phase 7): add a CI step that re-resolves the builder digest and fails if it drifts
> from `build/base-devel.digest` without an explicit bump.
