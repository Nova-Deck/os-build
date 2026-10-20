# Plan: Alien games — launch path

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 6 — Launch path
**Complexity**: Large (it reopens the milestone-4 entry/ownership contract)
**Depends on**: milestone 4 (an entry to launch) and milestone 3 (an install whose exe we resolve).

## Summary

Pressing Play on an alien-game entry starts the game: a Windows title through Steam's own
Proton + SLR4 + FEX chain, a Linux-native title through the baked system FEX, both fronted by
`game-launch` so per-game tuning works exactly as it does for a Steam title. The decisive change
from the milestone-4 design: **Steam launches the game, not our stub.** The shortcut's Exe becomes
the resolved game executable and we set a compat tool on it, so the Steam client composes the
runtime (and lazily provisions SLR4 + the FEX compat tool, into an otherwise-empty
`steamapps/common`) instead of us reimplementing umu for arm64.

## The milestone-4 amendment (stated plainly)

Milestone 4 shipped and HW-gated with `Exe = /usr/lib/novadeck/store-launch` and ownership proven
by that basename. Model B makes the Exe the game binary, which **overturns that ownership
anchor**. This milestone therefore rewrites `shortcuts.py` (`entry_fields`, `is_ours`,
`our_entries`) and its test pins, retires the `store-launch` stub from the launch path, and adds
a managed-install-root invariant. No production entries exist (the M4 gate's were cleaned up), so
the change is clean; it is called out here because it reopens a gated contract.

## Verified before planning (two research passes + device)

| Fact | Evidence |
|---|---|
| `game-launch` is a transparent exec wrapper: tunes FEX from `STEAM_COMPAT_APP_ID`, then `os.execv`s whatever follows. `game-launch %command%` is the post-shim mechanism it was rebuilt for | `rootfs/overlay/usr/lib/novadeck/game-launch:13-23,400`; `docs/FEX_README.md:68-81` |
| **Windows path**: Steam composes SLR4 (`require_tool_appid 4185400`) + our arm64 Proton + its WoW64 FEX, and provisions them lazily on first launch through a compat tool | baked tools at `/usr/share/steam/compatibilitytools.d/{proton-cachyos-11.0-arm64,proton-ge-arm64}`, toolmanifest `require_tool_appid 4185400` (read on device); `docs/windows-games-fex.md:84-95` |
| **Native x86-64 path is BARE, no container**: `binfmt_misc → /usr/bin/FEX → ArchLinux.ero`. The two titles the user named (Super Meat Boy, (Parking) Garage Rally Circuit) are HW-validated working this way, 2026-07-11 | `docs/worklog/DONE.md:1625-1636`; `docs/FEX_README.md:9-14,29-32`; binfmt `FEX-x86_64 → /usr/bin/FEX` confirmed on device |
| **Sniper (SLR 3.0, 1628350) does not exist on arm64** — it is an x86-64-host runtime; wrapping native titles in it is not an option here, and `ArchLinux.ero` already supplies the stable ABI | tree grep: no `sniper`/`1628350`; the only SLR is arm64 4185400 (Windows-only) |
| `SpecifyCompatTool(appId, strToolName)` is void/fire-and-forget; it persists to GLOBAL `config.vdf` `CompatToolMapping`, keyed by the **UNSIGNED** appid; tool name is the internal `compat_tools` name | `@decky/ui App.ts:115,694`; unifideck `selector.py:222-248`, `vdf_compat.py:227-308` (signed→unsigned trap at `:231-234`) |
| `GetAvailableCompatTools(appId): Promise<CompatibilityTool[]>` lists installed tools (`{strToolName, strDisplayName}`) — used to verify our Proton is present before setting it | `@decky/ui App.ts:115,1536-ish` |
| legendary resolves the game exe: `legendary launch <app> --json` prints `game_directory`/`game_executable`; GOG from `goggame-<id>.info` playTasks (`--platform linux` → `start.sh`) | `_reference/legendary/legendary/cli.py:697-711`; gogdl `launch.py:285-320` |
| Proton derives `WINEPREFIX` from `STEAM_COMPAT_DATA_PATH`; Steam provides both plus `STEAM_COMPAT_CLIENT_INSTALL_PATH` when IT launches — we do not set these under model B | `_reference/proton/proton:1686,2099-2101` |

## Design

**Windows title (Epic or GOG) — model B.** At registration (milestone 4's `register_entry`, now
amended):
1. Resolve the game's executable: Epic via `legendary launch <app> --json` (`game_directory` +
   `game_executable`); GOG via `goggame-<id>.info` under the install path.
2. `Exe = "<install>/<exe>"`, `StartDir = "<install dir>"`,
   `LaunchOptions = "/usr/lib/novadeck/game-launch %command%"`.
3. `AddShortcut` → appid; then `SpecifyCompatTool(appid >>> 0, "proton-cachyos-11.0-arm64")`
   after `GetAvailableCompatTools` confirms it is installed. Re-assert the mapping on plugin
   boot (it is in-memory until Steam flushes `config.vdf`).

Steam then runs `proton waitforexitandrun <Exe>` inside SLR4, expands `%command%` host-side, and
`game-launch` fronts it — per-game FEX tuning with zero new launcher code.

**Native Linux title (GOG `--platform linux`) — bare.** `Exe = "<install>/<start.sh-or-elf>"`,
`LaunchOptions = "/usr/lib/novadeck/game-launch %command%"`, **no compat tool**. binfmt routes the
x86-64 ELF to system FEX against `ArchLinux.ero`. Native is the non-default opt-in: a GOG title
offering both builds installs the **Windows** build by default (user's call, 2026-10-20), native
only when explicitly chosen.

**Ownership re-anchor.** `is_ours(entry)` becomes: the entry's `Exe`, resolved with `realpath`,
lies under a managed game root (`locations.game_root(volume, store)` for some known volume/store).
Foreign tools point their Exe at their own trees, so this is a basename-class proof that survives
appid churn. The `<store>:<game_id>` token in `LaunchOptions` + the `shortcuts.json` registry
remain the identity map (token → appid/exe/platform), never the ownership proof — the UD-006
lesson holds.

**The CLI-env caveat (noted, not solved in MVP).** Running the exe directly under Proton skips
the launch env legendary/gogdl would inject (Epic's EGL/EOS vars, the overlay). GOG DRM-free
titles need none. Some Epic titles (online/EOS) may. If the HW gate finds a title that needs it,
the fix is to capture legendary's `environment` at register time and inject it via the shortcut's
launch options (`VAR=val … game-launch %command%`) or a per-game `game-tweaks.json` env — not to
put the arm64 CLI back in the Proton-wrapped launch path (that is the double-Proton breakage).

**The stub retires.** `store-launch` leaves the launch path. Removed with its stub-specific tests;
its ownership role moves to the managed-root check above.

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Tuning via launch options | `novadeck-control` launchWrapper + `game-launch %command%` | The exact existing Steam-game path; alien entries join it by the same door |
| Exe resolution as the user | `installs.py` `cli.capture` / `_as_user` | `legendary launch --json` run as `deck`, stdout parsed |
| Live client call via the bridge | milestone 4 `shortcutBridge.ts` + `shortcut_op` | A `compat` op carrying `SpecifyCompatTool` |
| Ownership by what we control | `shortcuts.py` registry | Managed-root path test + registry identity |

## Files to Change

| File | Action | Why |
|---|---|---|
| `.../novadeck_stores/launch.py` | CREATE | Resolve the exe + platform per store (legendary `--json`, GOG `goggame-*.info`); the compat-tool name; the managed-root check |
| `.../novadeck_stores/shortcuts.py` | UPDATE | `entry_fields` takes the resolved exe + platform; `is_ours`/`our_entries` move to the managed-root test; drop the stub constant |
| `apps/decky/novadeck-stores/main.py` | UPDATE | `register_entry` resolves exe, sets Exe/StartDir/LaunchOptions, calls the compat op for Windows; a boot-time re-assert of compat mappings |
| `apps/decky/novadeck-stores/src/lib/shortcutBridge.ts` | UPDATE | A `compat` op: `GetAvailableCompatTools` guard + `SpecifyCompatTool(unsigned, tool)` |
| `rootfs/overlay/usr/lib/novadeck/store-launch` | DELETE | No longer on the launch path |
| `tests/test-store-shortcuts.sh` | UPDATE | Re-pin entry shape (game exe, launch options, compat) and the managed-root ownership; drop stub cases |
| `tests/test-store-launch.sh` | CREATE | Exe resolution per store, the compat-tool decision (Windows yes / native no), the signed→unsigned conversion, offline |
| `Makefile` | UPDATE | Swap the suite name; keep in `make test` |
| `.claude/plans/alien-games-library-entry.plan.md` | UPDATE | Note the amendment |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 6 row on completion; close the two identity/tuning open questions |

## Tasks

### Task 1: Exe + platform resolution
- `launch.py`: `resolve_target(store, gid, p)` → `{exe, startdir, platform}`. Epic:
  `legendary launch <app> --json` as deck. GOG: read `goggame-<id>.info` playTasks under the
  recorded install path; default platform windows, honor a recorded `platform: linux`.
- **Validate**: fixture legendary JSON and a GOG info file; missing/!installed → clear error.

### Task 2: The compat decision and the managed-root test
- `launch.py`: `compat_tool(platform)` → `"proton-cachyos-11.0-arm64"` for windows, `None` for
  native. `is_managed(exe_path, p)` → realpath under a `locations.game_root`.
- **Validate**: windows→tool, native→None; a path under `/home/deck/Games/Epic/..` is managed, a
  foreign `/usr/bin/x` and a symlink-escape are not.

### Task 3: The bridge compat op
- `shortcutBridge.ts`: `{op:"compat", req, appid, tool}` → `GetAvailableCompatTools(appid)`,
  refuse if `tool` absent, else `SpecifyCompatTool(appid >>> 0, tool)`, result back.
- **Validate**: `make decky-plugin`; payload shape asserted from the backend side; unsigned conv.

### Task 4: register_entry amended + boot re-assert
- `entry_fields(store, gid, title, resolved)` builds the game-exe entry + `game-launch %command%`.
  `register_entry` resolves the target first, writes the entry, and for a Windows title fires the
  compat op; the registry row records `{appid, exe, platform}`. A plugin-boot pass re-asserts the
  compat mapping for every Windows row (config.vdf may not have flushed).
- **Validate**: backend suite — windows register emits add + compat ops with the right tool;
  native register emits add only; registry carries platform; double-register still refused.

### Task 5: Ownership rewrite
- `is_ours`/`our_entries`/`orphan_report` move to the managed-root test; the stub constant and
  its grammar pin go; the token helper stays for identity.
- **Validate**: a foreign entry under its own tree is not ours even with our token; one under a
  managed root is; the registry-join report still classifies healthy/orphan/registry-only.

### Task 6: Hardware gate
On the Pocket FIT, Steam running, driven over SSH + the gate CDP evaluate:
1. Install a small **Windows** title per store (Epic + GOG) to the home volume (milestone 3).
2. Register each → entry has `Exe = game.exe`, `game-launch %command%`, compat tool set; confirm
   `config.vdf` CompatToolMapping carries the unsigned appid → `proton-cachyos-11.0-arm64`.
3. **Press Play** (`RunGame` via the appStore gameid). Measure: SLR4 + Proton + FEX provision and
   the title reaches a window; `game-launch` is in the chain (its log / FEX config written);
   the game actually renders. This is the milestone's real proof.
4. Install a **native Linux** GOG title (`--platform linux`; Super Meat Boy or PGRC if owned on
   GOG), register (no compat tool), Play → runs via bare binfmt FEX, renders.
5. Restart + reboot: entries + compat mappings survive; Play still works.
6. Note any Epic title needing legendary's env (the caveat) for a followup.

## Validation

```bash
bash tests/test-store-launch.sh         # resolution, compat decision, managed-root — offline
bash tests/test-store-shortcuts.sh      # amended entry shape + ownership
source dev.env && make test
source dev.env && make decky-plugin
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Setting a compat tool on a non-Steam shortcut doesn't make Steam build SLR4+Proton | Low-Med | HW gate step 3 is exactly this; if it fails, fall back to model A (stub reconstructs — the higher-risk umu-equivalent) |
| `SpecifyCompatTool` not flushed to config.vdf / lost on crash | Med | Boot-time re-assert of every Windows row; GetAvailableCompatTools guard; the signed→unsigned conversion pinned in tests |
| An Epic title needs legendary's EGL/EOS env the direct-exe launch skips | Med | Named caveat; capture legendary `environment` into launch options if a gated title needs it — not the CLI back in the Proton path |
| Native title actually needs Steam's scout-on-soldier PV (not bare) | Low | DONE.md validated bare for the named titles; gate step 4 confirms from a store-launch shortcut vs Steam's own session |
| Managed-root ownership misfires on a card path that moved | Low | `locations.game_root` already handles per-volume label paths; realpath + per-volume check |
| Reopening milestone 4 breaks the gated writer | Med | Full offline re-pin before the gate; no production entries exist to migrate |

## Acceptance

- [ ] A Windows title per store launches through Proton+SLR4+FEX, `game-launch` in the chain, and renders
- [ ] A native GOG Linux title launches through bare FEX and renders
- [ ] The compat tool is set on Windows entries (unsigned appid) and survives a reboot
- [ ] Ownership is the managed-root path test; a foreign entry with our token is not ours
- [ ] The stub is gone from the launch path; no entry's Exe is store-launch
- [ ] `make test` green with the amended + new suites
