# FEX — x86 emulation runtime configuration

The config lives in the unified overlay payload (`fs-overlay/usr/share/fex-emu/`,
`fs-overlay/usr/lib/novadeck/game-launch`), copied wholesale into the rootfs by
`rootfs/assemble-rootfs.sh`. JSON has no comment syntax, so the rationale lives here.

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
tool ships the emulator and thunks only — its rootfs depot is empty — so the OS has to provide the
x86 guest. It sets `FEX_PORTABLE=1`, so it deliberately ignores a system FEX install and everything
in `usr/share/fex-emu/Config.json` above. The migration plan is
`.claude/plans/fex-compat-tool.plan.md`.

`/usr/share/guestos/fex-mesa` is the tool's **default**, not a fixed requirement: it returns that
path unless `STEAM_COMPAT_GRAPHICS_PROVIDER` names a `graphics_provider.json`, in which case that
file's parent directory wins instead (`Source/Steam/CompatTool.cpp`; the variable is a
pressure-vessel one that the tool only sets). Taking the default is a choice. Our guest is baked
into the read-only image and mounted at boot, so it can simply *sit* at the probed path — no
session plumbing, and it resolves for **any** Steam launch, not only one started through
`novadeck-session`. An OS whose guest arrives after install, in writable user storage, has no such
option and must export the variable. The override stays useful to us as a debugging lever: point it
at an alternate tree to exercise a rebuilt guest without a reflash.

Our pinned `ArchLinux.ero` already satisfies pressure-vessel's graphics-provider contract in full,
so no new guest has to be built. `rootfs/assemble-rootfs.sh` surfaces it as **two** fstab rows: the
`.ero` loop-mounted read-only as a lower layer at `/run/novadeck/guestos-lower`, and an overlay at
the probed path laying our `packages/mesa-x86` Turnip payload over it. Both `nofail`. The merged
tree is what every x86 consumer reads — the compat tool probes it, and the system FEX `RootFS`
points at it — so the guest driver carries our mesa patches while the pinned artifact stays
byte-identical to its pin. The build-time gates on both are documented at that step.

It works with no manifest of ours because **the guest ships its own `/graphics_provider.json`** as
of the 2026-08-11 image. Mounting the merged tree at `/usr/share/guestos/fex-mesa` lands it at
`/usr/share/guestos/fex-mesa/graphics_provider.json`, which is the path the tool probes, and the
same mount is a real guest tree for the tool's other use of that path — it hands it to FEX as
`RootFS`. (Inside a pressure-vessel container that second use is moot: `emulator.json` forces
`FEX_ROOTFS` empty and the container supplies the x86 userspace. Out of container it matters.)

Until that image, we overlaid a manifest of our own from `fs-overlay` — the 2026-01-08 guest
carried none. Upstream's differs from what we had written, and in its favour: no `gbm` entry for
`x86_64-linux-gnu`, a `fallback_library_paths` for it instead, and an explicit `vdpau: false` where
ours left the `true` default. Ours was deleted with the pin bump; nothing of ours may live under
the mountpoint now, because the mount would mask it.

The `.ero` itself is **not relocated**: it stays at its `fex-emu` location and is read from there
as the overlay's lower layer. Relocating it belongs with the retirement of `packages/fex-emu`, not
here.

`usr/share/fex-emu/Config.json` points the system FEX's `RootFS` at the merged mount rather than at
`ArchLinux.ero`. That was **not** the original call, and the reason it changed is worth keeping.
The mount is `nofail`; if it ever failed, a `RootFS` pointing at it would leave the system FEX
running x86 binaries against an **empty directory**, where FEX mounting the image itself would keep
working. We judged that trade worth taking only to share a *modified* guest — and with the
`packages/mesa-x86` payload we now ship exactly that: the guest's stock `libvulkan_freedreno.so` is
an unowned mesa snapshot, and under our thunkless config it is the driver that renders every native
x86 Linux title. Sharing one tree is what puts our patched Turnip under both consumers; skipping
FEXServer's own per-user `erofsfuse` mount is a bonus. Phase 3 retires this config's consumer
outright if Steam ever selects the tool.

### The manifest gate

The manifest now lives inside a 2 GiB pinned artifact that is not in the tree, so it cannot be
checked by reading committed files. `rootfs/assemble-rootfs.sh` reads it out of the image at build
time instead — `dump.erofs --cat --path=/graphics_provider.json`, parsed, with both architectures
required (FEX emulates x86-64 *and* i386; dropping i386 silently breaks every 32-bit title). A
rootfs bump to an image without a manifest would otherwise surface as a card that boots fine and
cannot launch an x86 title.

**The exit code is not the signal.** `dump.erofs --path` exits 0 for a path that does not exist and
only prints `read inode failed` to stderr, so the gate has to parse the content. This is also the
only reason `erofs-utils` is in `build/Dockerfile`.

`tests/test-graphics-provider.sh` (in `make test`) guards what committed files can still show, in
five groups:

- **fstab injection** — `packages/fex-rootfs/prebuilt.pin`'s `dest` is the lower mount's source; the
  guest is loop-mounted read-only and `nofail`; the overlay row merges the payload over the guest at
  the probed path and is ordered after the lower mount; the mountpoint exists in the read-only
  image; we ship nothing under it, since the mount would mask it.
- **`mesa-x86` payload** — it is staged at the path the overlay row names as its top `lowerdir`; the
  assembler hard-requires it complete rather than treating it as best-effort; the `Makefile` builds
  it before the rootfs assembly; the assembler checks its `NEEDED` closure against the guest; and
  its mesa snapshot matches the `fex-rootfs` pin, so the payload is built against the guest it
  overlays.
- **one shared tree** — the system FEX's `RootFS` names the merged mount, not the `.ero`.
- **the manifest gate** — it still exists, still *parses* rather than trusting an exit status, and
  the build image carries `erofs-utils` for it.
- **kernel support** — `EROFS_FS`, `EROFS_FS_ZIP` (LZ4), `BLK_DEV_LOOP`, `OVERLAY_FS`.
