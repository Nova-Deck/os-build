# Plan: Alien games — store CLIs, native arm64

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 1 — Store CLIs, native arm64
**Complexity**: Medium

## Summary

Package `legendary` (Epic) and `gogdl` (GOG) as novadeck overlay packages built from source for
aarch64, and add them to the image. Neither exists in any holo repo, so both need a novadeck-owned
PKGBUILD — the same shape `packages/f3/` already uses. This milestone lands **inert**: nothing in
the image calls either binary yet. It is proven by the package building in the normal pipeline and
by both CLIs running on hardware and listing a library from a hand-supplied token.

The point of the milestone is to retire the "x86 freeze under FEX" assumption the PRD started from.
No FEX, no PyInstaller artifact, no vendored zipapp.

## Verified before planning

These were checked against the tree and the pinned snapshot, not assumed:

| Fact | Evidence |
|---|---|
| Neither `legendary` nor `gogdl` is in holo core/extra aarch64 | repo dbs at `build/snapshot.pin` (`mash-20251118.3`), searched |
| **Every** Python dep is in holo extra-aarch64 | `python-requests 2.32.5-1`, `python-requests-futures 1.0.1-3`, `python-filelock 3.20.0-1`, `python-pycryptodomex 3.23.0-1`, `python-setuptools 1:80.9.0-2`; build side `python-build 1.3.0-1`, `python-installer 0.7.0-10`, `python-wheel 0.45.1-1` |
| Image Python is 3.13.7 | `rootfs/manifest.lock:353` |
| legendary 0.20.43 is pure Python | `_reference/legendary/setup.py` — `install_requires` = requests<3.0, requests_futures, setuptools, wheel, filelock, pycryptodomex |
| **gogdl is not pure Python** | `_reference/heroic-gogdl/pyproject.toml:47-53` — `[[tool.setuptools.ext-modules]]` builds `gogdl_xdelta3` from `gogdl_xdelta3.c` + `xdelta3/xdelta3/xdelta3.c` |
| The extension is mandatory, not optional | `gogdl/dl/workers/task_executor.py:20` imports `gogdl_xdelta3` at module level |
| `xdelta3/` is a **git submodule** | `.gitmodules` → `jmacd/xdelta` @ `0525275fe4b553a10f38e455d30c60dc6ed9b45d`. A GitHub archive tarball of gogdl therefore ships that directory **empty** |
| The extension is abi3 | `py-limited-api = true`, `-DPy_LIMITED_API=0x03090000` — a Python minor bump will not break the built `.so` |

That last pair is the trap in this milestone: a one-source PKGBUILD for gogdl builds green on a
tarball whose `xdelta3/` is empty only if the compile is skipped — and it is not, so it fails
loudly at compile. The failure is honest; the wasted cycle is avoidable by fetching both sources
from the start.

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Package shape | `packages/f3/source.pin:20-22` | `name:` / `pkgbuild_local: PKGBUILD` / `pkgrel_suffix: 1` — the local-recipe form for a package holo does not carry |
| PKGBUILD prose | `packages/f3/PKGBUILD:1-30` | Header states WHY IT IS HERE, WHY LOCAL AND NOT FETCHED, and what was deliberately left out, before any variable |
| Recipe body | `packages/f3/PKGBUILD:33-55` | `arch`/`depends` pinned to what is actually linked, `source=(...::url/archive/vX.tar.gz)` with a committed `sha256sums`, minimal `build()`/`package()` |
| Package list | `rootfs/customize-base.sh:232` | One flat `PKGS=(...)` array; additions are plain names resolved against overlay-first repo order |
| Lock discipline | `packages/README.md:192-222` | `inputhash.sh` digests committed inputs; `make relock` after any pin or patch change; `make verify-lock` catches a stale row in a second |
| Tests | `tests/test-decky.sh:1-16` | Header names what the suite proves and what it explicitly cannot; asserts against the committed tree; states the HW gate it does not replace |
| Test harness | `tests/test-decky.sh:33` | `ok()`/fail counters, `ROOT` derived from `$BASH_SOURCE/..`, no root, no device, no network |

## Files to Change

| File | Action | Why |
|---|---|---|
| `packages/legendary/source.pin` | CREATE | Declares the local-PKGBUILD build, per `packages/README.md` |
| `packages/legendary/PKGBUILD` | CREATE | Builds legendary 0.20.43 from the Heroic fork tarball, `arch=('any')` |
| `packages/gogdl/source.pin` | CREATE | Same, for gogdl |
| `packages/gogdl/PKGBUILD` | CREATE | Builds gogdl 1.3.0 **plus** the xdelta3 C extension, `arch=('aarch64')`, two sources |
| `rootfs/customize-base.sh` | UPDATE | Add `legendary gogdl` to `PKGS` (line 232) |
| `rootfs/manifest.lock` | UPDATE | `make relock` — new `novadeck` rows plus the holo python-* rows they drag in |
| `tests/test-store-cli.sh` | CREATE | Offline suite over both package declarations |
| `Makefile` | UPDATE | Register the new suite in the `test` target and its help line |
| `packages/README.md` | UPDATE | Add both to the "Current overlay" list |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 1 row → `in-progress`, `Plan` cell → this file |

## Tasks

### Task 1: Package legendary
- **Action**: `packages/legendary/{source.pin,PKGBUILD}`. `pkgname=legendary`, `pkgver=0.20.43`,
  `arch=('any')`, source `legendary-0.20.43.tar.gz::https://github.com/Heroic-Games-Launcher/legendary/archive/0.20.43.tar.gz`
  (bare tag, no `v`). `depends=('python' 'python-requests' 'python-requests-futures'
  'python-filelock' 'python-pycryptodomex' 'python-setuptools')`,
  `makedepends=('python-build' 'python-installer' 'python-wheel')`. Standard PEP 517
  `python -m build --wheel --no-isolation` + `python -m installer`. Header records why the Heroic
  fork and not `derrod/legendary`: it is the maintained line the ecosystem drives, and it is the
  version the reference plugin pins.
- **Mirror**: `packages/f3/PKGBUILD` header shape and `source=`/`sha256sums` discipline.
- **Validate**: `packages/inputhash.sh packages/legendary` prints a digest;
  `packages/build-overlay.sh --only legendary` produces `work/repo/aarch64/legendary-*.pkg.tar.zst`.

### Task 2: Package gogdl, including the xdelta3 extension
- **Action**: `packages/gogdl/{source.pin,PKGBUILD}`. `pkgname=gogdl`, `pkgver=1.3.0`,
  `arch=('aarch64')` (it emits a compiled `.so`), `depends=('python' 'python-requests')`,
  `makedepends=('python-build' 'python-installer' 'python-wheel' 'gcc')`. **Two sources**: the
  gogdl `v1.3.0` archive and the `jmacd/xdelta` archive at submodule commit
  `0525275fe4b553a10f38e455d30c60dc6ed9b45d`; `prepare()` moves the xdelta tree into
  `xdelta3/` so `sources`/`include-dirs` in `pyproject.toml` resolve. Header states the submodule
  trap explicitly so the next bump does not rediscover it.
- **Mirror**: same as Task 1; the two-source + `prepare()` shape is new to this tree, so document
  it rather than imitate something that is not there.
- **Validate**: built package contains `gogdl_xdelta3.abi3.so`:
  `bsdtar tf work/repo/aarch64/gogdl-*.pkg.tar.zst | grep gogdl_xdelta3`.

### Task 3: Add both to the image
- **Action**: append `legendary gogdl` to `PKGS` (`rootfs/customize-base.sh:232`). Nothing calls
  them — that is intended; the PRD's delivery constraint prefers unwired over flagged off.
- **Mirror**: `f3` and `scx-scheds`, which sit in the same array as plain names.
- **Validate**: `grep -c 'legendary gogdl' rootfs/customize-base.sh`.

### Task 4: Relock
- **Action**: `make relock`. Expect new `novadeck` rows for both packages and new holo rows for the
  python-* dependency closure. Re-run `make verify-lock` to confirm the **installer** lock is
  untouched — the installer does not install these, so a row appearing there is a mistake.
- **Mirror**: `packages/README.md:192-222`.
- **Validate**: `make verify-lock` passes; `git diff --stat rootfs/manifest.lock installer/manifest.lock`
  shows changes only in the first.

### Task 5: Offline suite
- **Action**: `tests/test-store-cli.sh`. Asserts on committed files only: each `source.pin` names
  the package its `PKGBUILD` declares; `pkgrel_suffix` is present; both names appear in `PKGS`;
  `legendary` is `arch=any` and `gogdl` is `arch=aarch64`; gogdl's PKGBUILD carries **both**
  sources and `_xdelta_commit` is a full 40-char sha that the second source URL interpolates, so
  the pin and the fetch cannot drift apart; every name in each `depends=` exists as a row in
  `rootfs/manifest.lock`. Header states what it cannot prove — that either binary runs, that
  either can talk to a store, that the extension compiled, **and** that `_xdelta_commit` still
  matches upstream's `.gitmodules`: that last one needs the network, and an offline suite that
  reaches out fails on a plane. Matching it to upstream is a human step at bump time, recorded in
  `packages/gogdl/source.pin` where the person doing the bump will be reading.
- **Mirror**: `tests/test-decky.sh` header and `ok()` harness.
- **Validate**: `bash tests/test-store-cli.sh` passes; register it in `make test`.

### Task 6: Build and measure
- **Action**: `make overlay && make base`. Record the rootfs size delta from the python-* closure;
  the image has been trimmed once already and this is the first new Python dependency chain since.
- **Validate**: build green; size delta recorded in the commit message. If it is larger than a few
  MB, say so before milestone 3 plans downloads.

### Task 7: Hardware gate
- **Action**: Flash a dev card, then on the device: `legendary --version` and `gogdl --version`
  run; with a hand-supplied token, `legendary list` and a gogdl library call each return a real
  library. Confirms there is no x86 anywhere in the path (`file $(which legendary)` reasoning does
  not apply — both are Python entry points, so check the interpreter and that no FEX process
  appears).
- **Validate**: output pasted into the commit or the PRD row. **Never commit the token.**

## Validation

```bash
make verify-lock                                  # lock rows vs packages/, seconds, no build
packages/inputhash.sh packages/legendary          # the digest that decides a rebuild
packages/inputhash.sh packages/gogdl
packages/build-overlay.sh --only legendary        # one package, skip the rest
packages/build-overlay.sh --only gogdl
bsdtar tf work/repo/aarch64/gogdl-*.pkg.tar.zst | grep gogdl_xdelta3   # the extension shipped
bash tests/test-store-cli.sh                      # new offline suite
make test                                         # full host suite incl. verify-lock
source dev.env && make base                       # build the base with both packages in
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| gogdl's GitHub tarball ships an empty `xdelta3/`, so the extension cannot compile | **Certain** if written as one source | Two sources plus a `prepare()` that assembles the tree; the offline suite asserts both sources are present |
| The xdelta3 submodule commit drifts on a gogdl bump and the PKGBUILD keeps the old one | Medium | Not checkable offline — the suite only proves the pin and the fetch URL cannot disagree with each other. Re-reading upstream's `.gitmodules` is a bump-time step, written into `packages/gogdl/source.pin` |
| Compiling the extension under arm64 qemu is slow or trips on a 32/64-bit define | Low | Upstream sets the size defines explicitly in `extra-compile-args`; a native aarch64 runner is the normal path anyway |
| The python-* dependency closure grows the rootfs more than expected | Medium | Measured in Task 6, before anything depends on it; dropping back to a vendored zipapp stays available and strands nothing |
| A future image Python bump breaks the compiled `.so` | Low | `py-limited-api`/abi3 at 3.9 — the `.so` is stable across 3.x minors |
| Upstream retags or a tarball hash moves | Low | `sha256sums` committed, as every other package here does |
| The HW gate needs real store credentials and someone pastes one into a commit | Medium | Token is hand-supplied at the prompt for the test and never written to the tree; the gate records only the output shape |
| Two packages land that nothing calls, and go stale before milestone 7 | Medium | Accepted by the PRD's delivery constraint; the mitigation is keeping the gap between milestones small, not gating the code |

## Acceptance

- [ ] `packages/legendary/` and `packages/gogdl/` build in the normal pipeline, no FEX involved
- [ ] `gogdl_xdelta3.abi3.so` is present in the built gogdl package
- [ ] Both names are in `PKGS`; `make verify-lock` passes; only `rootfs/manifest.lock` moved
- [ ] `tests/test-store-cli.sh` passes and is registered in `make test`
- [ ] Rootfs size delta measured and recorded
- [ ] **HW gate**: both CLIs run on a dev card and list a library from a hand-supplied token
- [ ] Patterns mirrored from `packages/f3/` and `tests/test-decky.sh`, not reinvented
