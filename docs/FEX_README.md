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

Why two, precisely — the short version is *robustness*, not necessity:

- The manifest must sit at exactly `/usr/share/guestos/fex-mesa/graphics_provider.json`, because
  the tool **probes that fixed path**. (It derives the rootfs from the manifest's directory only in
  its *other* branch, the one where `STEAM_COMPAT_GRAPHICS_PROVIDER` is already set.)
- The manifest's own `root` field takes an absolute path, so the guest tree does **not** have to be
  that same directory. A lone manifest with `root` pointing at the loop mount would satisfy
  pressure-vessel by itself, with no overlay.
- But that fixed path is *also* what the tool hands FEX as `RootFS`, and FEX needs a real guest
  there. Inside a pressure-vessel container this is moot — `emulator.json` forces `FEX_ROOTFS` to
  empty, so the container supplies the x86 userspace and `RootFS` goes unused — yet **out** of
  container it matters.

Which path Steam actually takes on our device is still open (Phase 0). Overlaying the manifest onto
the guest satisfies both callers for one extra mount, rather than betting on the answer. `lowerdir`
is **leftmost-wins**, so the manifest layer is listed first; reverse it and the guest shadows the
manifest, the tool finds no provider, and the failure is silent. The `.ero` is a pinned artifact we
must not rewrite, hence an overlay rather than editing the image.

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
