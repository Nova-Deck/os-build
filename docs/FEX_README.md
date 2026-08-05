# FEX — x86 emulation runtime configuration

The config lives in the unified overlay payload (`fs-overlay/usr/share/fex-emu/`,
`fs-overlay/usr/lib/novadeck/game-launch`), copied wholesale into the rootfs by
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

Everything in this directory serves the **second** column, except `game-launch`, which bridges
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
`game-launch`.

`default` runs **`Multiblock: 1`** — the JIT compiles across basic blocks rather than one at a
time. It is on in our system FEX config too (the ROCKNIX-derived tuning both reference titles were
validated with), so the Proton-side default carrying `0` was an inconsistency rather than a
decision. `compatible` deliberately keeps it **off**, together with `X87ReducedPrecision: 0` and
the strict TSO set: that preset is the escape hatch for a title that miscompiles, and it stops
being one if every preset shares the aggressive JIT settings. Users select a profile per game through `/etc/novadeck/game-tweaks.json`
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

## `usr/lib/novadeck/game-launch`

Resolves the effective profile for the running appid, writes a merged FEX config under
`$XDG_CACHE_HOME`, exports `FEX_APP_CONFIG`, and execs the command it was given.

**One entry point, for every compat tool.** `novadeck-control` writes a game's Steam launch options
as `/usr/lib/novadeck/game-launch %command%`. Steam evaluates them on the host and expands
`%command%` to the whole chain it assembled, so the tuning lands whichever tool that is — ours,
Valve's arm64 Proton (app `4628740`, client-owned data we must not rewrite and now Steam's default
for Windows titles), or the FEX compat tool.

It used to reach only the Protons we bake, via an in-tool shim: `assemble-rootfs.sh` rewrote their
`commandline` to a `novadeck-proton` script in the tool directory. **That shim is gone**, and with
it the `require_tool_appid` strip that had to accompany it — the shim exec'd a host path that does
not exist inside SLR4, so it could not survive our Protons running in the container Valve builds
against. See `docs/windows-games-fex.md`.

Being launch options also puts the wrapper on the HOST side of pressure-vessel, which is what makes
the config it writes readable from inside the container.

This works because Proton only generates its own FEX config **if `FEX_APP_CONFIG` is unset** — a
pre-set value is honoured as-is. Proton also reads `STEAM_FEX_TSOENABLED` / `STEAM_FEX_MULTIBLOCK`
/ `STEAM_COMPAT_FEX_CONFIG` directly, which is the simpler mechanism when a single knob will do;
the wrapper exists for named presets and per-game overrides.

The generated config cannot live beside the base one because `/usr` is read-only. It lands under
`$XDG_CACHE_HOME` (falling back to `~/.cache`) rather than `$XDG_RUNTIME_DIR`: pressure-vessel
shares the cache path into a container and not the runtime dir, and an unreadable `FEX_APP_CONFIG`
is skipped **silently**, so the failure would read as "the profile did nothing". It also strips
`RootFS`/`ThunkGuestLibs`/`ThunkHostLibs` from the copy — those belong to the system FEX, and the
FEX reading this file is Proton's own.

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

## `usr/share/guestos/fex-mesa/` — the guest as a Steam graphics provider

Valve publishes FEX as a Steam Play compat tool (app `3127680`). On its **public** branch that
tool ships the emulator and thunks only — its rootfs depot is empty — and it expects the OS to
provide the x86 guest at a fixed path, `/usr/share/guestos/fex-mesa`. It sets `FEX_PORTABLE=1`, so
it deliberately ignores a system FEX install and everything in `usr/share/fex-emu/Config.json`
above. The migration plan is `.claude/plans/fex-compat-tool.plan.md`.

Our pinned `ArchLinux.ero` already satisfies pressure-vessel's graphics-provider contract in full,
so no new guest has to be built. `images/assemble-rootfs.sh` surfaces it with **two** fstab
entries, and the second is not optional:

1. the `.ero`, loop-mounted read-only on a private `/run/novadeck/fex-guest`;
2. a read-only **overlay** of `usr/share/guestos/fex-mesa.d/` over it, at the probed path.

Two mounts because the provider manifest has to appear *inside* the guest tree — the compat tool
derives the FEX `RootFS` from the manifest's own directory — while the `.ero` is an immutable
pinned artifact we must not rewrite. `lowerdir` is **leftmost-wins**, so the manifest layer is
listed first; reverse it and the guest shadows the manifest, the tool finds no provider, and the
failure is silent.

This is **additive**. The image is still read from its `fex-emu` location and the system FEX keeps
working off the same file, unchanged — the validated baseline survives and the change rolls back
for free. Relocating the `.ero` belongs with the retirement of `packages/fex-emu`, not here.

### `graphics_provider.json`

Schema is `steam-runtime-graphics-provider.json(5)` (pressure-vessel — the compat tool only sets
`STEAM_COMPAT_GRAPHICS_PROVIDER`, PV consumes it). Every value below was verified against the
pinned image rather than copied from the man page's example:

- **`root: "./"`** — the manifest's own directory, i.e. the merged overlay. The guest is a
  merged-`/usr` tree (`bin`→`usr/bin`, `lib`→`usr/lib`, `lib64`→`usr/lib`, `sbin`→`usr/bin`) and
  carries `etc/ld.so.cache`, both `ldconfig`s and both interoperable linkers.
- **`locales: false`** — the guest ships only `C.utf8` under `usr/lib/locale`. Left at its `true`
  default, PV would take locale data from a guest that has essentially none.
- **`va_api: false`** — there are no `*_drv_video.so` drivers in the image.
- **Per-arch paths** — `usr/lib/dri` and `usr/lib32/dri` (66 drivers each), `usr/lib/gbm`,
  `usr/lib/gconv` (255) and `usr/lib32/gconv` (256). `usr/lib32` is also given as a
  `fallback_library_paths` entry, since 32-bit libraries live there rather than in `usr/lib`.
- **`vdpau` is deliberately absent**, i.e. left at its default: the guest does carry
  `usr/lib{,32}/vdpau`.

Both architectures must stay declared — FEX emulates x86-64 *and* i386, and dropping the i386
entry silently breaks every 32-bit title.

`images/test-graphics-provider.sh` (in `make test`) guards the parts that fail quietly: that the
manifest parses and only names absolute paths, that `packages/fex-rootfs/prebuilt.pin`'s `dest`
still matches the mount source, that both mounts exist in the right layer order, and that the
kernel can mount any of it (`EROFS_FS`, `EROFS_FS_ZIP` for LZ4, `OVERLAY_FS`, `BLK_DEV_LOOP`).
