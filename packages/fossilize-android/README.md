# fossilize-android

Upstream [Fossilize](https://github.com/ValveSoftware/Fossilize)'s Vulkan layer (MIT), built for the
Android guest's aarch64/bionic and shipped under the filename Lepton demands. It is the same layer
Valve ships in that slot in its own image; this builds it from source.

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

## Why the real layer and not a stub

A hand-written no-op passthrough layer stood in here until 2026-10-01. A layer sits between every
Android app and the Vulkan driver, and a passthrough is only as correct as its least-exercised entry
point. The stub's `vkEnumerateDeviceExtensionProperties` resolved the next layer's function with a
NULL instance, which Android's loader refuses
(`internal vkGetInstanceProcAddr called for vkEnumerateDeviceExtensionProperties without an
instance`). Every app then saw **zero** device extensions. Harmless while the guest's GLES was
freedreno; fatal once it became zink, which requires `VK_KHR_maintenance5` — the app's EGL init
failed, left its window connected, and Unity's Vulkan swapchain could not connect (Age of Gods on a
Pocket FIT). Upstream's layer is the one Valve runs in the same slot, so it carries none of that risk.

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
The name must be `VK_LAYER_fossilize`, the ID the `.so` reports for itself: the guest is told to
enable that name, and Android's loader enables nothing under any other.

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
same guest process, so they must not drift apart. `make fossilize-android`.

The cmake invocation is upstream's `android_build.sh` minus `-DFOSSILIZE_LAYER_APK=ON`; only the
`rapidjson` submodule is fetched, since the others feed the CLI, which is off. The source is pinned
to a full commit in `builder.pin`.

The container build gates the payload three ways, each covering a way it can be silently wrong on
the device: it must be AArch64, it must not NEED glibc or `libc++_shared.so`, and it must export the
entry points Android's loader binds by name (`vkGetInstanceProcAddr`, `vkGetDeviceProcAddr`,
`vkEnumerateInstanceLayerProperties`, `vkEnumerateDeviceExtensionProperties`).

## Shader cache location

On Android the layer writes to `/sdcard/fossilize` unless the guest property
`debug.fossilize.dump_path` overrides it (`layer/instance.cpp`). Nothing sets that property yet.
