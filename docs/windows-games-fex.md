# Running x86 games on arm64 (Proton + FEX)

novadeck runs x86 and x86-64 games on this arm64 handheld through **FEX**, an x86→arm64
translator. There are two separate paths, and which one a game takes depends on whether it is a
*Windows* game or a *native Linux* game. Both are baked into the image: nothing needs to be
downloaded, and nothing needs to be configured.

## Windows games

novadeck ships an arm64 build of **Proton** as a compat tool. Proton carries its own copy of FEX
(as a Windows DLL) which translates the game's x86 code, while the Wine underneath it is a native
arm64 binary. Nothing is downloaded — the tool is already on the image.

Steam does not pick a *custom* compat tool on its own, so select it once. Either:

- **Per game** — **Properties → Compatibility**, tick *Force the use of a specific Steam Play
  compatibility tool*, and choose the **Proton … (CachyOS, arm64)** entry (its name carries the
  Proton version). Steam remembers this per game.
- **For everything** — **Settings → Compatibility**, enable *Steam Play for all other titles*, and
  choose the same entry. This is the setting most people want.

### Tuning a game that misbehaves

x86 guarantees stronger memory ordering than ARM does, so FEX emulates it. That emulation (TSO) is
on by default and is the largest single cost in the translation. Turning it off is the biggest
performance win available, and also the most likely way to introduce a race-condition crash in a
game that was relying on x86's ordering.

Three presets are available: `default`, `fast` (TSO off), and `compatible` (stricter, slower).
Set one per game by creating `/etc/novadeck/game-tweaks.json`:

```json
{
  "games": {
    "858710": { "enabled": true, "fexProfile": "fast" }
  }
}
```

The key is the Steam appid. `enabled` must be `true` or the entry is ignored. Without this file
every game uses `default`.

For a one-off experiment you can instead set `STEAM_FEX_TSOENABLED=0` in a game's launch options —
Proton reads it directly.

## Native Linux games (x86 / x86-64)

These run through the *system* FEX, which is registered with the kernel so that an x86 Linux
binary executes as if it were native. It runs against a bundled Arch Linux x86 root filesystem,
and forwards graphics and audio calls out to the device's real arm64 drivers.

No setup is required, and no compat tool is involved: launching the game is enough.

## What novadeck ships

Everything below is part of the OS image, replaced atomically with a system update:

- **arm64 Proton compat tool** — `/usr/share/steam/compatibilitytools.d/`.
- **FEX** — the system x86 interpreter, plus its host/guest thunks.
- **x86 guest root filesystem** — `/usr/share/fex-emu/RootFS/ArchLinux.ero`.
- **FEX tuning profiles** — `/usr/share/novadeck/fex-profiles.json`.
- **uinput access rule** — lets Steam Input create the virtual gamepad games read.

## Maintainer notes

The two paths share a name and almost nothing else:

| | Windows games | Native x86 Linux |
|---|---|---|
| Emulator | Proton's bundled WoW64 FEX | system FEX (`fex-emu`) |
| Guest rootfs | none | `ArchLinux.ero` |
| Thunks | none | Vulkan/GL/EGL/drm/WaylandClient/asound |
| Runtime container | none | none |

A Windows game therefore still works on an image with no `fex-emu` package and no guest rootfs:
Proton translates only the game's *Windows* x86 code, and every Linux syscall is issued by the
arm64 side of Wine. That is why Proton's bundled FEX config sets neither `RootFS` nor `ThunksDB`.

**Why the compat tool is baked rather than downloaded.** Valve's own arm64 Proton declares
`require_tool_appid` for an arm64 Steam Linux Runtime container. On a non-Deckard client that
dependency is never *registered* as a compat tool even when its files are installed, so the launch
dies before Proton runs (`AppError_51`). Steam also owns first-boot Wi-Fi, so nothing can be
fetched before OOBE finishes. `images/assemble-rootfs.sh` strips `require_tool_appid` from the
baked tool's `toolmanifest.vdf` and repoints its `commandline` at `proton-wrapper`; it also
rewrites `compatibilitytool.vdf` to a **stable, version-free internal name** (`proton-cachyos-arm64`)
and a friendly `display_name`, because Steam records the internal name — not the directory — against
every game the tool is forced on, so leaving upstream's dated name would unpin every game on a
Proton bump. All edits fail the build loudly if upstream's files change shape.

The client only scans the per-user `compatibilitytools.d` and whatever `STEAM_EXTRA_COMPAT_TOOLS_PATHS`
lists — not `/usr/share/steam/compatibilitytools.d` on its own — so `novadeck-steam` exports that
path before launching the client.

**How per-game tuning reaches Proton's internal FEX.** Proton generates its own FEX config only if
`FEX_APP_CONFIG` is unset, and honours a pre-set value otherwise. `proton-wrapper` resolves the
profile for the running appid, writes a merged config into `$XDG_RUNTIME_DIR` (`/usr` is
read-only), exports `FEX_APP_CONFIG`, and execs the real `proton`. A failure to write that config
is never fatal — the wrapper logs and execs Proton anyway.

**erofsfuse is a hard dependency.** FEXServer `execvpe`s `erofsfuse` to mount the guest rootfs; if
the binary is missing, the exec fails inside a forked child and FEXServer aborts, taking every x86
launch with it. It ships in its own package — `erofs-utils` does **not** contain it.

See `docs/FEX_README.md` for the configuration layout and `packages/fex-emu/PKGBUILD` for how FEX and
its x86 thunks are built.
