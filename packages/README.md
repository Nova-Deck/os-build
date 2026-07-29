# packages/

Pacman packages layered on top of the upstream aarch64 base — overlays rebuilt from
source with novadeck patches (`source.pin`) and pinned precompiled tarballs
(`prebuilt.pin`). (Static overlay trees baked straight into the rootfs — the Qualcomm
HW-support layer and the Steam shell — live at top-level `hw-support/` and `steam/`, not
here; the FEX runtime *configuration* likewise lives at top-level `fex/`.)

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

`images/customize-base.sh` auto-discovers every `prebuilt.pin`, fetches + sha256-verifies
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

### The package store — build once, retrieve everywhere

A cold `make overlay` compiles every package under emulation: ~4h on a 16-core box, `fex-emu`
alone ~2h. `packages/overlay-store.sh` makes that a one-time cost **per source change** by
publishing each built package to a registry keyed by its `inputhash.sh` digest, so any other
machine or pipeline pulls the bytes instead of recompiling.

```
make overlay-pull && make overlay      # cold consumer: fetch, then assemble. No compiles.
make overlay-publish                   # publish what this machine built (needs a login)
packages/overlay-store.sh plan         # which packages the store does NOT already have (JSON)
packages/overlay-store.sh pull-all --require-all   # fail unless EVERY package came from the store
```

**`--require-all` is for verification, not for building.** By default a miss is fine — whatever the
store lacks gets compiled locally, which is slow but correct, so `make overlay-pull` never fails a
build over a cache miss. CI's `verify` job wants the opposite: it exists to prove the store covers
the whole set, so it fails immediately and names the package. Reach for the flag when a miss means
something is *wrong*, not merely absent.

The retrieval path distinguishes **absent** from **unreadable**, which is worth knowing because the
two have completely different fixes and used to look identical:

| symptom | cause | fix |
|---|---|---|
| `not in the store` | nothing has published that input hash yet | build and publish it (or let CI) |
| `PERMISSION DENIED` | the package exists but is not public | make it public / link it to the repo |

That second row is the trap: **a GHCR package is private when first created, even in a public
repo.** Before it was classified separately, a freshly published (still-private) store read as a
plain miss, and CI dutifully recompiled all eight packages instead of saying "I am not allowed to
read this". Verify a visibility change with no credentials in the environment, not by reading the
setting back:

```
DOCKER_CONFIG=$(mktemp -d) packages/overlay-store.sh have rauc && echo readable
```

`.github/workflows/overlay.yml` is the producer: one job per package that the store lacks, on
native `aarch64` runners (no qemu), publishing to `ghcr.io/nova-deck/novadeck-overlay/<name>-<arch>`
tagged with the input hash. An unchanged package is not a fast build there — it is **no build**.

Things worth knowing:

- **Pulling needs no credentials.** The packages are public, so a fresh clone retrieves with no
  token and no `gh`. Only publishing authenticates — and in CI nothing extra is needed there either,
  because the workflow's `GITHUB_TOKEN` with `permissions: packages: write` is accepted.
- **Publishing from a workstation needs a CLASSIC personal access token**, and this is worth knowing
  before you spend time on it: `gh auth token` hands out a `gho_` OAuth token which GHCR
  *authenticates* — the blob uploads all succeed — and then refuses at the manifest with `the token
  provided does not match expected scopes`. The message points at scopes, but the token **type** is
  the problem, so `gh auth refresh -s write:packages` does not fix it. Create a classic PAT with
  `write:packages` (plus `delete:packages` only if you also want the prune job), then:

  ```
  export NOVADECK_GHCR_TOKEN=ghp_...
  packages/overlay-store.sh login && make overlay-publish
  ```

  None of this is on the critical path: publishing from a workstation only pre-seeds the store so CI
  need not build on its first run, and CI builds the whole set from cold in well under ten minutes
  on native `aarch64`. Skipping it is a perfectly good default.
- **The input hash is the key**, which is why it is not throwaway: same hash ⇒ same sources ⇒ the
  published artifacts are the ones you would have built. It is a fourth reader of the one formula
  above and must agree with the other three.
- **`.stamps/<name>.files` travels with the artifact**, because it is the only mapping from a pin
  to its several outputs (`mesa` emits five) and both `genmanifest.sh` and `fetchlock.sh` hard-fail
  without it. A pull writes the stamps last, so an interrupted pull looks un-built and gets rebuilt
  rather than looking complete with files missing.
- **No checksum sidecar**: a registry content-addresses every blob, so `oras pull` already verifies
  the bytes it returns. `oras` itself is pinned by `packages/oras.pin`.
- **This is a cache, not a provenance mechanism.** `images/manifest.lock` still pins the `novadeck`
  rows to their *sources* and `fetchlock.sh` still re-derives that hash from `packages/` — the store
  changes neither, and a miss just means a local build. Making the lock verify these artifacts *by
  byte* is a separate open item in `TODO.md`.
- **The repo db is rebuilt locally, not shipped**, since it must describe whatever set the consumer
  actually has. `repo-add` output is not byte-reproducible, so a pull-then-index yields a different
  `novadeck.db` sha than the machine that built the packages — which advances `.overlay.stamp` and
  so rebuilds the *base*. Cheap next to the compiles it skipped, and conservative in the right
  direction, but it does mean `overlay-pull` is not completely free on a warm machine.

`work/repo/<arch>/` remains a plain pacman repo, so the alternative of serving it over HTTP and
repointing the `[novadeck]` `Server` still works; the store is preferred because it is
content-addressed per package rather than a single mutable directory.

### How these packages are pinned — `inputhash.sh`

`packages/inputhash.sh <package-dir>` prints a digest of a package's **committed inputs**: its
`source.pin`, the patches that pin declares, and `pkgbuild_local` if it has one. Three readers share
that one formula, and they have to agree byte for byte:

| reader | what it does with it |
|---|---|
| `build-overlay.sh` | incremental-rebuild cache key (`work/repo/<arch>/.stamps/<name>.hash`) |
| `images/genmanifest.sh` | writes it into `images/manifest.lock` as the `novadeck` rows' hash |
| `images/fetchlock.sh` | re-derives it and refuses the install when the lock disagrees |

So the lock pins these rows to their **sources**, not to the built artifact's bytes — these builds
are not bit-reproducible, and an artifact hash moved on every rebuild from unchanged inputs, which
only ever verified on the machine that last ran `make relock`. Consequences worth knowing:

- Rebuilding a package changes nothing in the lock. Editing a patch or bumping a pin **does**, and
  `fetchlock` will say so by name and ask for `make relock`.
- One split PKGBUILD legitimately gives several rows the same hash (`mesa` emits `mesa`,
  `vulkan-freedreno`, `vulkan-mesa-device-select`).
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
- `gamescope/` — **local PKGBUILD** building gamescope `3.16.23.2` (newer-Turnip/ROCKNIX parity)
  with the composite-rotation patch for the portrait Pocket S2 panel under
  `packages/gamescope/patches/`. (Was a fetched holo PKGBUILD at 3.16.17; moved local for the bump.)
- `mesa/` — **local PKGBUILD** building mesa `26.1.5` from the upstream tarball. It tracks the
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
