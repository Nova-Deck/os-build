# Running x86 Windows games (Proton 11 ARM64 + FEX)

novadeck runs x86/x86_64 **Windows** games on arm64 through Valve's own
**Proton 11.0 (ARM64)**, which bundles the WoW64 FEX emulator
(`libwow64fex.dll`) to translate x86 → arm64. novadeck ships the wiring to use
it, but **not** the Proton/runtime files themselves — those are Valve content
that you install from your own Steam library (see [Why you install the runtimes
yourself](#why-you-install-the-runtimes-yourself)).

## One-time setup

After you have signed in to Steam and finished first-boot setup:

1. **Install the two runtimes.** In Steam, search each of these by name and press
   **Install** (they are `Tool`-type apps, so search is the way to reach them):

   | Search for | What it is |
   |---|---|
   | `Proton 11.0 (ARM64)` | Proton with the bundled x86→arm64 FEX (~3.4 GB) |
   | `Steam Linux Runtime 4.0 - Arm64` | The container Proton runs inside (~420 MB) |

   Install **both** — Proton needs the runtime container to launch.

2. **Point a Windows game at novadeck's compat tool.** Open the game's
   **Properties → Compatibility**, tick *Force the use of a specific Steam Play
   compatibility tool*, and choose:

   > **Proton 11.0 (ARM64) [novadeck]**

3. **Launch the game.**

That is all that is required per device. The compatibility choice is remembered
per game; repeat step 2 for each Windows title.

## Why you install the runtimes yourself

Proton 11 ARM64 and the SLR 4.0 Arm64 container are Valve-distributed content.
novadeck does not bake or redistribute them — it only ships the small
`proton11sc` compat tool that knows how to run them. Fetching them with your own
account, from your own library, is the one manual step and it keeps novadeck
clear of redistributing Valve's binaries.

## What novadeck ships

Both pieces are baked into the image (and restored on a factory reset):

- **`proton11sc` compat tool** — `steam/compatibilitytools.d/proton11sc/`,
  seeded into `~/.local/share/Steam/compatibilitytools.d/`. It registers the
  user-selectable *Proton 11.0 (ARM64) [novadeck]* entry.
- **uinput access rule** — `hw-support/usr/lib/udev/rules.d/70-novadeck-uinput.rules`,
  giving Steam Input permission to create the virtual gamepad games read.

## How it works (maintainer note)

Valve's official Proton 11 ARM64 declares `require_tool_appid 4185400` (the
SLR 4.0 Arm64 container). On a non-Deckard client that dependency is never
*registered* as a compat tool even when its files are installed, so the launch
dies with `AppError_51` ("Tool 4185400 unknown"). Rather than fight that
platform gate, `proton11sc` carries **no `require_tool`** and instead
*self-chains*: its `novadeck-chain` wrapper invokes the SLR 4.0 Arm64 container
itself and then Proton inside it —

```
SteamLinuxRuntime_4-arm64/_v2-entry-point --verb=<verb> -- \
    "Proton 11.0 (ARM64)/proton" <verb> <game command>
```

— collapsing Valve's two-tool chain into one local tool that needs no
dependency resolution. The wrapper locates both runtimes under
`steamapps/common/` relative to `STEAM_COMPAT_CLIENT_INSTALL_PATH`, and fails
with an install hint if either is missing (the setup step above).

The trade-off: removing `require_tool` also removes Steam's only *native
auto-download* hook, which is why the two runtimes must be installed by hand
rather than pulled automatically. Keeping `require_tool` to get the download is
not an option — present-but-unregistered, it kills the launch before the chain
runs.

## Troubleshooting

- **"novadeck-chain: … not found … install appid 4185400 / 4628740"** — one of
  the runtimes isn't installed. Redo step 1.
- **Game renders but the controller does nothing** — Steam Input couldn't open
  `/dev/uinput`. The udev rule above fixes this on a normal image; if you are on
  a hand-modified device, ensure `/dev/uinput` is group `input`, mode `0660`.
- **Native-Linux x86 games** are a different case: they need a *system* FEX
  interpreter, which novadeck does not provide. This path covers **Windows**
  games via Proton only.
