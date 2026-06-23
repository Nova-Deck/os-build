# packages/

novadeck-specific packages and ported SteamOS `jupiter-*` builds layered on top
of the upstream aarch64 base. Includes the `jupiter-hw-support` replacement for
Qualcomm devices, plus `steam`, `proton`, and `fex` packaging.

## Precompiled external packages (`prebuilt.pin`)

Components that aren't in the holo pacman repo and aren't built from source here are
pulled in as **pinned precompiled tarballs**. Drop a `packages/<name>/prebuilt.pin`:

```
name: inputplumber                 # staged as work/prebuilt/<name>.tar.gz; manifest key
version: 0.77.6
url: https://.../inputplumber-aarch64.tar.gz
sha256: 0e0f7600…                  # from the asset's .sha256.txt sidecar
strip: 1                           # tar --strip-components to land files at /usr
deps: libiio                       # optional: holo-repo runtime deps (space-separated)
```

`images/customize-base.sh` auto-discovers every `prebuilt.pin`, fetches + sha256-verifies
it on the host, and extracts it into the release base — **adding a package is just a new
pin file, no code change**. Any `deps:` a pin declares are pacman-installed into the base
alongside the prebuilt (e.g. shared libraries the binary links), so a prebuilt's runtime
deps live with the pin instead of being hardcoded in the install list. The set of installed
prebuilts **and their deps** is recorded in the base at `/usr/lib/novadeck/prebuilt.manifest`,
which keys the base reuse-cache (bump a pin, or change its deps, → the base rebuilds).
Current pins: `inputplumber/` (InputPlumber input daemon; `deps: libiio`).

## From-source overlay packages (`source.pin`)

Holo packages that need a novadeck **code** patch are rebuilt from source instead of pulled as
binaries. Drop a `packages/<name>/source.pin` plus the patches under `packages/<name>/patches/`:

```
name: gamescope
pkgbuild_repo: holo/holo-core-aarch64-preview   # GitLab project hosting the PKGBUILD
pkgbuild_path: extra-aarch64/g/gamescope/3.16.17-1
pkgbuild_ref: 1a6f6e90...                        # commit SHA to pin (reproducible)
pkgrel_suffix: 1                                 # integer only: N -> N.1 (kept across upgrades)
patches: 0001-foo.patch 0002-bar.patch          # applied -p1 in the source root
```

`make overlay` (→ `packages/build-overlay.sh`) fetches the PKGBUILD from the monorepo raw endpoint
at the pinned commit (anonymous read; the PKGBUILD pulls the upstream source from public GitHub),
applies the patches, bumps `pkgrel`, and `makepkg`s it inside the pinned `base-devel` image
(`base-devel.digest`) under arm64 qemu. Output is a local pacman repo at **`work/repo/<arch>/`** —
**arch-scoped**, since one aarch64 build serves every aarch64 SoC (NOT per-device). `customize-base.sh`
adds it as a `file://` repo **ahead of the holo repos** so the patched package wins (`pacman -S`
resolves by repo order, not version — the higher `pkgrel` only matters for later upgrades), and
folds the repo db's hash into the base reuse-cache key. `base` depends on `overlay` automatically.

**Publishing for CI:** `work/repo/<arch>/` is a standard pacman repo. To share it (so CI need not
rebuild from scratch), upload that dir and point a pinned `[novadeck]` `Server` at the URL instead
of `file://` — same mechanism, different `Server`.

### Local (checked-in) PKGBUILD — `pkgbuild_local`

When there is **no suitable holo PKGBUILD** to fetch — a version bump holo hasn't taken, or a
build the holo recipe doesn't cover — point the pin at a novadeck-owned PKGBUILD committed next
to it instead of the `pkgbuild_repo`/`pkgbuild_path`/`pkgbuild_ref` triple:

```
name: mesa
pkgbuild_local: PKGBUILD                          # checked-in recipe (relative to this dir)
pkgrel_suffix: 1
patches: 0001-foo.patch                           # optional; same -p1 injection as fetched pins
```

Everything else is identical: `build-overlay.sh` bumps `pkgrel`, injects the `patches:` after the
first `cd` in `prepare()`, and `makepkg`s it under arm64 qemu. The PKGBUILD still downloads its own
upstream source (e.g. a release tarball), so this stays "from-source", just with a recipe we own.

Current overlay:
- `gamescope/` — composite-rotation patch for the portrait Pocket S2 panel (fetched holo PKGBUILD;
  needs the patch dropped at `packages/gamescope/patches/`).
- `mesa/` — **local PKGBUILD** building mesa `26.1.3` from the upstream tarball. It tracks the
  Arch/holo recipe (same `arch-meson` invocation + meson options) as closely as possible; the only
  deviations are `gallium-drivers`/`vulkan-drivers` narrowed to **freedreno** (GL) + **freedreno**
  Vulkan (Turnip), plus `gallium-rusticl=false` (no OpenCL → no Rust crate chain) and
  `html-docs=disabled`. LLVM/clang stay on, as upstream. Replaces holo's stale, all-driver
  `mesa`/`vulkan-freedreno`. Carries SM8750 / Adreno a830 enablement patches under
  `packages/mesa/patches/`.

_Phase 0 placeholder — populated in Phases 2-3._
