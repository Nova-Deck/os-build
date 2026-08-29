# fossilize-stub-android

A valid, no-op Vulkan layer built for the Android guest, shipped under the filename Lepton demands.

## Why it exists

Valve's Lepton compat tool enables the fossilize shader-cache layer on **every** launch, with no
guard and no opt-out. `liblepton/vulkan_layers.sh`:

```bash
if [[ "${ENABLE_VULKAN_RPO_LAYER:-0}" != "0" ]]; then            # :171  env-gated
    enable_vulkan_layer "${RPO_LAYER_NAME}"
fi
if [[ "${ENABLE_VULKAN_FDM_INJECTION_LAYER:-0}" != "0" ]]; then  # :175  env-gated
    enable_vulkan_layer "${FDM_INJECTION_LAYER_NAME}"
fi

enable_vulkan_layer "${FOSSILIZE_LAYER_NAME}"                    # :181  UNCONDITIONAL
```

`find_vulkan_layer` looks only in `/usr/share/guestos/android/vendor/vulkan_layers/` — the
**distro's** slot, ours to fill — and `lepton` runs under `set -euo pipefail`, so a missing layer is
a fatal launch failure for every Android title. Measured on a Pocket ACE 2026-08-29 with Lepton
v2.8.9 (issue #58): three PIDs added for the appid, children exit `-1` ~5s later, `compatdata/`
wiped by Lepton's early-exit cleanup, no container ever created, and **nothing in the session log** —
Lepton logs to `~/.local/share/lepton/logs/lepton-steamlaunch-<appid>.log`, which is where the
`LEPTON_DEBUG=1` trace ends at `+ return 1`.

There is no environment variable that skips it: `grep -E 'DISABLE|SKIP|NO_FOSSILIZE'` over
`vulkan_layers.sh` finds nothing.

## Why a stub rather than a port

Fossilize is a shader cache. It contributes nothing to getting a title on screen, and porting it is
an NDK cross-build of a substantial CMake project. What Lepton actually requires is that a layer by
that filename exists and loads. So this is a complete passthrough layer that chains every call
straight down and records nothing.

If real shader caching in the guest is ever wanted, this package is replaced by a genuine port and
nothing else in the tree moves — the slot path, the manifest and the assembler staging are the same.

## The three things Lepton needs, and where each lives

| # | Artifact | Path | Built by |
|---|---|---|---|
| 1 | `libVkLayer_fossilize.so`, aarch64/bionic | `/usr/share/guestos/android/vendor/vulkan_layers/` | this package |
| 2 | JSON manifest naming the layer ID | `/usr/share/vulkan/novadeck-guest-layer.d/` | this package (`layer.json`) |
| 3 | `jq` on the host | — | `PKGS` in `rootfs/customize-base.sh` |

**(2) is not optional and not obvious.** `get_vulkan_layer_id` maps a layer's `.so` basename to the
layer ID it writes into the guest's settings by shelling out to `jq` over
`find /usr/share/vulkan -name '*.json'`, and it requires **exactly one** match — zero *or* two both
produce `ERROR: Unable to determine Layer ID` and `return 1`, the same fatal path as a missing `.so`.

**The manifest deliberately does NOT go in `implicit_layer.d/` or `explicit_layer.d/`.** Those are
the directories the *host's* Vulkan loader scans, and this manifest points at an Android/bionic `.so`
that the host loader must never try to load. Lepton's `find` is recursive over `/usr/share/vulkan`,
so a sibling directory the host loader does not know about satisfies Lepton while staying invisible
to everything else on the system.

**(3) `jq`** is load-bearing for the same reason `which` and `inotify-tools` were: absent, the
pipeline produces nothing, the lookup fails, and the failure is indistinguishable from a genuinely
missing layer.

## Build

x86 job, like `packages/mesa-android` and for the same reason — Google publishes NDK host binaries
for `linux-x86_64` only, so this must not run on the arm64 build image. The toolchain pin is
deliberately identical to `mesa-android`'s: both produce bionic aarch64 objects that load into the
same guest process, so they must not drift apart. `make fossilize-stub-android`.

The container build gates the payload three ways, each covering a way it can be silently wrong on
the device: it must be AArch64, it must not link glibc, and it must export
`vkNegotiateLoaderLayerInterfaceVersion` under that exact name.
