# packages/

Pacman packages layered on top of the upstream aarch64 base — overlays rebuilt from
source with novadeck patches (`source.pin`) and pinned precompiled tarballs
(`prebuilt.pin`). (Static overlay trees baked straight into the rootfs — the Qualcomm
HW-support layer and the Steam shell — live at top-level `hw-support/` and `steam/`, not
here; the FEX runtime *configuration* likewise lives at top-level `fex/`.)

One directory here is neither: `mesa-x86/` carries no pin of either kind (so
`build-overlay.sh` and `customize-base.sh` both ignore it) and builds the **x86_64 + i686
Turnip payload for the FEX guest rootfs** — a plain file tree, not a pacman package — from
the same source pin + patch list as `mesa/`, in its own pinned x86 Arch container. See
`mesa-x86/builder.pin` for the why and the pin pairing with `fex-rootfs/prebuilt.pin`;
`rootfs/assemble-rootfs.sh` stages its output and injects the overlayfs mount that lays it
over the guest image.

## Precompiled external packages (`prebuilt.pin`)

Components that aren't in the holo pacman repo and aren't built from source here are
pulled in as **pinned precompiled artifacts**. Drop a `packages/<name>/prebuilt.pin`:

```
name: inputplumber                 # staged as work/prebuilt/<name>.{tar,blob}; manifest key
version: 0.77.6
url: https://.../inputplumber-aarch64.tar.gz
sha256: 0e0f7600…                  # from the asset's .sha256.txt sidecar
kind: tar                          # optional: tar (default) | file
strip: 1                           # tar only: --strip-components to land files at /usr
dest: /                            # optional: where to put it (default /)
deps: libiio                       # optional: holo-repo runtime deps (space-separated)
```

`kind: tar` extracts the archive into `dest` (any tar compression; autodetected). `kind: file`
copies the artifact verbatim **to** `dest`, which is then the full destination *file* path — for
artifacts that aren't archives at all, such as the FEX guest rootfs image.

`rootfs/customize-base.sh` auto-discovers every `prebuilt.pin`, fetches + sha256-verifies
it on the host, and extracts it into the release base — **adding a package is just a new
pin file, no code change**. Any `deps:` a pin declares are pacman-installed into the base
alongside the prebuilt (e.g. shared libraries the binary links), so a prebuilt's runtime
deps live with the pin instead of being hardcoded in the install list. The set of installed
prebuilts **and their deps** is recorded in the base at `/usr/lib/novadeck/prebuilt.manifest`,
which keys the base reuse-cache (bump a pin, or change its deps, → the base rebuilds).
Current pins: `inputplumber/` (InputPlumber input daemon; `deps: libiio`),
`fex-rootfs/` (the FEX x86 guest rootfs image; `kind: file`),
`proton-cachyos/` and `proton-ge/` (two baked arm64 Proton compat tools — CachyOS and
GloriousEggroll GE — the user picks either per game in Steam; both `kind: tar`, `deps: python`).

## What CI does with these packages

Nothing is published anywhere. `.github/workflows/overlay.yml` builds the packages a pull request
touches, purely to prove they still compile, and a release build (`.github/workflows/image.yml`)
compiles the whole set in the same run that produces the image.

There used to be more: a GHCR **artifact store** that each package was published to, keyed by
`packages/inputhash.sh`, plus a per-package `artifact.pin` recording the sha256 of the published
bytes and a bot that opened a **pin-bump PR** to carry those shas into the tree. A release build
verified them, which meant a release image could only ever be built by CI.

All of it was sized against the cost of an overlay build **on a dev box**, where arm64 emulation
makes the set take ~4h and fex-emu alone ~2h. CI does not pay that. On the native `ubuntu-24.04-arm`
runners it uses, the same eight packages measured `gtk2 7m, sddm 5m, mesa 5m, fex-emu 5m, gamescope
4m, scx-scheds 4m, mangohud 3m, rauc 1m` — **~34 minutes for everything**, against a release build
that already runs 33–41 minutes. It was retired on 2026-08-04. If you are thinking of reintroducing a
cache, re-measure those numbers first; they are what the decision rests on.

**Locally, the cache is the stamps.** `build-overlay.sh` records each package's input hash under
`work/repo/<arch>/.stamps/<name>.hash` and rebuilds only what moved, so a one-line gamescope patch
costs a gamescope build and nothing else. Change a `source.pin`, a patch or a `PKGBUILD` and the next
`make overlay` rebuilds that package; change nothing and it does nothing.

`novadeck.db` is deliberately **not** pinned: `repo-add` is not byte-reproducible either, so a pin on
it could never hold. Nothing installs *from* the db in a locked build — `fetchlock.sh` hands pacman an
explicit file list — so it is an index, not an input.

## CPU baseline (`-march`) for from-source packages

The base `makepkg.conf` ships `CFLAGS="-O2 -pipe -fno-plt -fexceptions …"` with **no `-march`**, so
everything built from source targets the stock `armv8-a` baseline. Two packages opt out of that, in
their own `PKGBUILD`:

```
-march=armv8.2-a+fp16+dotprod       # packages/fex-emu, packages/mesa
```

**The floor is set by the OLDEST SoC the image must serve, not the newest.** The overlay is built
once per architecture and the image is unified across every board, so one built byte has to run on
all of them. SM8550 (Cortex-X3/A715) and
SM8650 (X4/A720) are ARMv9-A and would tolerate far more, but **SM8250 (Cortex-A77/A55, ARMv8.2-A)**
is a planned target and it is what the floor is chosen against. Raising the floor above what the
oldest board supports does not fail at build time — it produces packages that SIGILL on that device,
after the pipeline has published them.

**Why `i8mm` is deliberately absent — VERIFIED, not assumed.** `FEAT_I8MM` is optional from
ARMv8.2-A and only *mandatory* from ARMv8.6-A, so "v8.2 core" alone does not settle it; it has to be
checked per core. Neither of SM8250's cores implements it, per the per-core tables in the two
toolchains that actually decide our codegen (mesa builds with gcc, fex-emu with clang):

| core | LLVM `AArch64Processors.td` | GCC `aarch64-cores.def` |
| --- | --- | --- |
| Cortex-A77 | `HasV8_2aOps, …FeatureFullFP16, FeatureDotProd, …FeatureLSE` | `V8_2A, (F16, RCPC, DOTPROD, SSBS)` |
| Cortex-A55 | `HasV8_2aOps, …FeatureFullFP16, FeatureDotProd, …FeatureLSE` | `V8_2A, (F16, RCPC, DOTPROD)` |

`FeatureMatMulInt8`/`I8MM` appears in neither. `bf16` (also v8.6-mandatory) and SVE are out the same
way. `armv8.2-a` is the *exact* architecture level of both cores rather than a conservative guess,
which is also what confirms the LSE claim below.

**`dotprod` had to be checked on the LITTLE core, and that is the check that matters.** SM8250 is
A77 **+ A55**, and a published byte runs on both clusters, so the constraint is the A55 — reasoning
only about the big core would leave `dotprod` unverified where it is most likely to be missing. Both
tables list it, and `F16`, on A55 explicitly. Had A55 lacked either, these flags would have been a
latent SIGILL on the little cores that nothing in the pipeline detects.

**The part that actually motivated this is not in the feature list.** `armv8.2-a` implies
`armv8.1-a`, which brings **LSE atomics** (`CAS`/`LDADD`) in place of `ldxr/stxr` retry loops. That is
the real win for FEX, which is atomic-heavy by construction — emulating x86's strong memory model on
a weakly-ordered host largely *is* atomics. Note this affects FEX's **compiled C++ only**: the JIT
selects its emitted instructions from *runtime* host feature detection, so `-march` changes nothing
about the code that actually executes guest x86.

**Why these flags live in each `PKGBUILD` and not a shared toolchain file.**
`packages/inputhash.sh` hashes exactly three things per package — `source.pin`, its declared patches,
and the local `PKGBUILD`. A shared flags file would be **invisible** to it: changing the flags would
move the artifact bytes while leaving the inputhash unchanged, so `rootfs/manifest.lock` would keep
asserting the same provenance for different bytes, and — worse — `build-overlay.sh` would consider
every package up to date and never rebuild any of them, so the flag change would silently not happen
at all. Putting the flags in the `PKGBUILD` keeps them inside the hashed input set, so a flag change
rebuilds the package like any source change. **If this ever becomes a shared file, it must be
added to `inputhash.sh`'s input set in the same commit** — and that bumps every package's hash at
once.

`-mtune` is a scheduling hint, not an ISA floor, so it is chosen separately and more loosely;
`fex-emu` passes `-DTUNE_CPU=cortex-a78` (FEX's own knob) as a conservative pick across the
big.LITTLE cluster, which stays valid with A77 in the fleet.

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
(`build/base-devel.digest`) under arm64 qemu. Output is a local pacman repo at **`work/repo/<arch>/`** —
**arch-scoped**, since one aarch64 build serves every aarch64 SoC (NOT per-device). `customize-base.sh`
adds it as a `file://` repo **ahead of the holo repos** so the patched package wins (`pacman -S`
resolves by repo order, not version — the higher `pkgrel` only matters for later upgrades), and
folds the repo db's hash into the base reuse-cache key. `base` depends on `overlay` automatically.

### Rebuilds are incremental, and that is the only cache

`build-overlay.sh` hashes each package's committed inputs with `packages/inputhash.sh` and records
the result as `work/repo/<arch>/.stamps/<name>.hash`. A package is rebuilt when that hash moves or
its artifacts are missing, and skipped otherwise — so `make overlay` on a warm tree is a no-op, and
a one-line patch to one package costs one package's build.

```
make overlay                                # rebuild whatever moved, index the repo
packages/build-overlay.sh --only mesa       # force one package, skip re-examining the rest
packages/inputhash.sh packages/mesa         # the digest that decides
```

Cost matters here because it is what shapes the CI design: a cold build of all eight is **~4h on a
dev box** under arm64 emulation (`fex-emu` alone ~2h) but **~34 minutes on a native aarch64 runner**.
If a build starts unexpectedly, check the stamp before assuming something is broken:

```
cat work/repo/aarch64/.stamps/mesa.hash     # what was built
packages/inputhash.sh packages/mesa         # what the tree says now
```

`.stamps/<name>.files` is the other half, and the more load-bearing one: it maps a package directory
to the several artifacts it emitted (`mesa` emits five), and both `genmanifest.sh` and `fetchlock.sh`
hard-fail without it.

**There is no shared artifact cache.** A GHCR store keyed by the same input hash existed until
2026-08-04 — with `oras`, an `artifact.pin` per package, and a bot PR carrying published shas — and
it was retired because it was built for the emulated cost and CI never paid it. See *What CI does
with these packages* above for the measurements. `work/repo/<arch>/` is a plain pacman repo, so if
one is ever wanted again, serving that directory over HTTP and repointing the `[novadeck]` `Server`
is the cheap version.

### How these packages are pinned — `inputhash.sh`

`packages/inputhash.sh <package-dir>` prints a digest of a package's **committed inputs**: its
`source.pin`, the patches that pin declares, and `pkgbuild_local` if it has one. Three readers share
that one formula, and they have to agree byte for byte:

| reader | what it does with it |
|---|---|
| `build-overlay.sh` | incremental-rebuild cache key (`work/repo/<arch>/.stamps/<name>.hash`) |
| `rootfs/genmanifest.sh` | writes it into `rootfs/manifest.lock` as the `novadeck` rows' hash |
| `rootfs/fetchlock.sh` | re-derives it and refuses the install when the lock disagrees |
| `packages/verify-lock-rows.sh` | the same comparison from committed files only, so it can run **before** a build (`make verify-lock`) |

So the lock pins these rows to their **sources**, not to the built artifact's bytes — these builds
are not bit-reproducible, and an artifact hash moved on every rebuild from unchanged inputs, which
only ever verified on the machine that last ran `make relock`. Consequences worth knowing:

- Rebuilding a package changes nothing in the lock. Editing a patch or bumping a pin **does**, and
  `fetchlock` will say so by name and ask for `make relock`.
- One split PKGBUILD legitimately gives several rows the same hash (`mesa` emits `mesa`,
  `vulkan-freedreno`, `vulkan-mesa-device-select`). **All of them move together.** Hand-editing the
  row whose name matches the package *directory* and stopping there is a real mistake that has
  happened (`ab3121b`, fixed in `5f15a19`): it looks correct on 7 of our 8 packages, because only
  `mesa` is split. `make verify-lock` catches it in a second and names the owning package;
  `fetchlock` also catches it, but not until a repo exists to check against.
- `work/repo` therefore survives `make distclean`; `make clean-overlay` still forces a rebuild.

The hash is **path-independent** by construction, because it has to agree between a developer's
checkout and a CI runner's workspace. Do not "simplify" it to `sha256sum "${inputs[@]}" |
sha256sum`: that hashes `<hash>  <path>` lines and silently follows the directory.

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
- `gamescope/` — **local PKGBUILD** building gamescope `3.16.25` (newer-Turnip/ROCKNIX parity)
  with the composite-rotation patch for the portrait Pocket S2 panel under
  `packages/gamescope/patches/`. (Was a fetched holo PKGBUILD at 3.16.17; moved local for the bump.)
- `mesa/` — **local PKGBUILD** building mesa `26.2.0` from the upstream tarball. It tracks the
  Arch/holo recipe (same `arch-meson` invocation + meson options) as closely as possible; the only
  deviations are `gallium-drivers`/`vulkan-drivers` narrowed to **freedreno** (GL) + **freedreno**
  Vulkan (Turnip), plus `gallium-rusticl=false` (no OpenCL → no Rust crate chain) and
  `html-docs=disabled`. LLVM/clang stay on, as upstream. Replaces holo's stale, all-driver
  `mesa`/`vulkan-freedreno`. Carries SM8750 / Adreno a830 enablement patches under
  `packages/mesa/patches/`.
- `gtk2/` — **local PKGBUILD** building gtk+ `2.24.33` from the GNOME git tag. holo ships NO gtk2
  at all, but the native arm64 Steam client's `steamui.so` links `libgtk-x11-2.0.so.0`, so we build
  it from source and install it on the host (it's in `customize-base.sh` PKGS) rather than resolving
  it from Steam's bundled SR3 runtime via pressure-vessel. Tracks the Arch recipe; carries the two
  upstream Arch patches (XID-warning severity; CVE-2024-6655 module-cwd) under `packages/gtk2/patches/`.
- `rauc/` — **local PKGBUILD** building rauc `1.15.2` from the upstream release tarball. This is
  holo's own `extra-aarch64/r/rauc/1.14-1` recipe with the version bumped and nothing else
  redesigned — the *only* reason we build it is that 1.14 cannot install a dm-verity bundle on a
  kernel `>= 6.19` (upstream fixed it first in `v1.15.1`) and we ship 7.1.x. No novadeck patches.
  Unlike the entries above it outranks holo's build by `pkgver`, not just by repo order.
