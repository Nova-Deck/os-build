# FEX — x86 emulation runtime configuration

The config lives in the unified overlay payload (`fs-overlay/usr/share/fex-emu/`,
`fs-overlay/usr/lib/novadeck/proton-wrapper`), copied wholesale into the rootfs by
`images/assemble-rootfs.sh`. JSON has no comment syntax, so the rationale lives here.

## The two x86 paths are independent

| | Windows games | Native x86 Linux ELF |
|---|---|---|
| Emulator | Proton's bundled WoW64 FEX (`libwow64fex.dll`) | system FEX (`fex-emu` package) |
| Guest rootfs | none | `ArchLinux.ero` |
| Thunks | none | Vulkan/GL/EGL/drm/WaylandClient/asound |
| Container | none | none |

Proton translates only the game's *Windows* x86 code; the Linux syscalls are made by the arm64
side of Wine. That is why its bundled FEX config declares neither `RootFS` nor `ThunksDB`, and
why a Windows game works even if the `fex-emu` package and the guest rootfs are absent.

Everything in this directory serves the **second** column, except `proton-wrapper`, which bridges
the two: it lets us drive the *Proton-internal* FEX with the same tuning vocabulary.

## `usr/share/fex-emu/Config.json`

FEX's system-wide config. It lives under `/usr/share` rather than `~/.fex-emu` deliberately: a
per-user config would **mask** this file entirely rather than merge with it, so shipping the
defaults here keeps them user-overridable.

- `RootFS` names a file inside `/usr/share/fex-emu/RootFS/` (installed by
  `packages/fex-rootfs/prebuilt.pin`). FEXServer mounts it with `erofsfuse` — chosen by the `.ero`
  container type, not by configuration.
- The `Thunk*Libs` paths are Arch's (`/usr/lib`), matching FEX's `CMAKE_INSTALL_FULL_LIBDIR`.
  Distros with a `/usr/lib64` split need different values.
- `TSOEnabled` emulates x86's stronger memory ordering on ARM's weaker model. Turning it **off**
  is the single biggest performance win and the single most likely cause of race-condition bugs
  in a game — hence on by default, off only per-game via a profile.

## `usr/share/novadeck/fex-profiles.json`

Named tuning presets (`default` / `fast` / `compatible`) plus the thunk defaults. Read by
`proton-wrapper`. Users select a profile per game through `/etc/novadeck/game-tweaks.json`
(absent by default; `/etc` is an overlay, so writing it is a supported local change):

```json
{
  "global": { "fexProfile": "default" },
  "games": { "858710": { "enabled": true, "fexProfile": "fast" } }
}
```

A per-game entry applies only when it carries `"enabled": true` — the opt-in is explicit so a
half-finished entry left in the file never silently retunes a game. `thunks` is honoured only
under `"fexProfile": "custom"`, which also takes a literal `"fexConfig": {…}`; the named presets
always run the full thunk set.

## `usr/lib/novadeck/proton-wrapper`

Sits in front of Proton's `proton` entry point. It resolves the effective profile for the running
appid, writes a merged FEX config to `$XDG_RUNTIME_DIR`, and exports `FEX_APP_CONFIG` before
exec'ing the real Proton.

This works because Proton only generates its own FEX config **if `FEX_APP_CONFIG` is unset** — a
pre-set value is honoured as-is. Proton also reads `STEAM_FEX_TSOENABLED` / `STEAM_FEX_MULTIBLOCK`
/ `STEAM_COMPAT_FEX_CONFIG` directly, which is the simpler mechanism when a single knob will do;
the wrapper exists for named presets and per-game overrides.

The generated config must land in `$XDG_RUNTIME_DIR` because `/usr` is read-only.

## Native x86 Linux games run on Xwayland, not native Wayland

A native x86-64 Linux game runs inside the Steam Linux Runtime (scout-on-soldier) pressure-vessel
container under the *system* FEX. On the **native Wayland** path it dies: SDL pulls in `libdecor`,
which needs `wl_list_init` from `libwayland-client` — but the only x86 `libwayland-client` the
container sees is the FEX **WaylandClient thunk**, which forwards protocol calls to the arm64 host
and omits the client-local `wl_list_*` helpers. So `libdecor-0.so.0: undefined symbol:
wl_list_init`, and even shimming in a real x86 libwayland just moves the failure into the
GL-on-Wayland path (real libwayland-client mixed with the libwayland-egl/cursor thunks → SIGSEGV).

The fix is to keep these games off native Wayland entirely, matching the SteamOS/gamescope model:
`novadeck-session` does **not** export `WAYLAND_DISPLAY`, so SDL falls back to gamescope's nested
**Xwayland** (`DISPLAY`), where `libdecor`/`libwayland` are never loaded. No per-game launch
option and no injected libraries are needed.
