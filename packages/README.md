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

_Phase 0 placeholder — populated in Phases 2-3._
