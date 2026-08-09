# Decky Loader + novadeck-control

Decky Loader is the plugin host that gives SteamUI features an in-UI surface (a Quick Access
Menu tab). Every image ships it plus one first-party plugin, **novadeck-control**, which is the
UI for [per-game tweaks](per-game-perf.md), power profile selection, and GPU clock control.

## How the pieces fit

```
packages/decky-loader/prebuilt.pin       sha256-pinned upstream PluginLoader (x86_64)
        │ customize-base places it
        v
/usr/share/decky-loader/PluginLoader     read-only master copy
/usr/share/decky-plugins/novadeck-control  baked plugin (assemble-rootfs 4c-3)
        │ novadeck-decky-sync.service (oneshot, Before=plugin_loader.service)
        v
/home/deck/homebrew/…                    what actually runs; survives OTA, wiped by reflash
        │ plugin_loader.service (root; the upstream unit name — Decky's self-updater manages it)
        v
SteamUI                                  injected via the CEF debugger port (the sentinel
                                         novadeck-steam always touches)
```

- The loader is x86_64 (upstream ships no aarch64 build) and runs under the system FEX binfmt.
  Its FEX knobs live in `fs-overlay/usr/share/fex-emu/AppConfig/PluginLoader.json` — keyed by
  binary name, TSO fully on, Multiblock off, UI thunks enabled.
- There is no runtime existence-gating: the loader ships in every image, so image completeness
  is asserted at build time (guard-rootfs assertion 9 — loader executable, plugin dist staged)
  and a genuinely broken image fails its units loudly on device.

## The seed/sync policy (`/usr/lib/novadeck/decky-sync`)

The loader must live on `/home` (it self-updates; user-installed plugins land beside it), but
`/home` is what a reflash wipes and an OTA preserves. The oneshot reconciles the two:

| Situation | Action |
|---|---|
| Fresh flash (empty homebrew) | full seed: loader, `loader.json` (prerelease branch), baked plugins |
| Image bundle changed, install untouched | re-seed the loader — **including a rollback**; the pin is authoritative |
| Operator self-updated Decky | hands off the loader entirely |
| Every boot | baked plugins force-replaced by name; user-installed plugins untouched |

"Untouched vs self-updated" is decided by a sha marker (`services/.novadeck-seeded`), not a
version compare — a version compare cannot express a deliberate pin rollback.

`loader.json` is written once (first seed) to pin new installs to Decky's **prerelease** branch,
where upstream lands its Steam-on-ARM fixes; after that the file is loader-owned state and the
user's branch choice sticks.

## novadeck-control

Two tabs; the backend runs as root inside the loader (`"flags": ["root"]`).

- **Games** — edits `/etc/novadeck/game-tweaks.json` (atomic writes, same file + `enabled:true`
  contract as [per-game-perf.md](per-game-perf.md)). Scheduling keys apply within one powerd
  tick; exec-time keys (FEX profile, Wine topology) need a game relaunch. The sanitizer refuses
  appid `0` — Valve's "no app" sentinel can never grow a section.
- **Power** — active profile plus GPU frequency control (auto/manual level, MHz slider bounded
  by powerd's reported min/max), straight to powerd's `org.novadeck.Power1` on the system bus
  (via `busctl`; the loader's bundled Python has no dbus module). The plugin is the ONLY UI
  surface for these: the steamos-manager shim no longer exports `PerformanceProfile1` or
  `GpuPerformanceLevel1` to SteamUI.

Frontend: TypeScript + `@decky/ui`, built by `make decky-plugin` (npm ci in a digest-pinned
node container; lockfile committed; `dist/` gitignored). The dist is a `$(ROOTFS)`
prerequisite, so a card can never assemble without its settings UI.

## Verifying on device

```sh
systemctl status novadeck-decky-sync plugin_loader   # both active (exited / running)
ls -l /home/deck/homebrew/services/PluginLoader      # seeded, 0755, deck-owned
journalctl -u plugin_loader -b                       # injection log; "Steam version" line = connected
```

The QAM tab appears under the plug icon. If the loader runs but no tab appears, check that
`~/.local/share/Steam/.cef-enable-remote-debugging` exists in the deck user's Steam root —
novadeck-steam touches it unconditionally at launch.

## What the offline suite cannot prove

`images/test-decky.sh` (in `make test`) covers the pin, units, sync decisions, and the
sanitizer; guard-rootfs assertion 9 covers image completeness. Neither can prove PluginLoader
executes under our FEX build, nor that injection works against our Steam client — both were
HW-validated 2026-08-08 (erofs guest mount + clean start + frontend injection in the journal),
and both remain worth a glance after a loader or Steam-channel bump.
