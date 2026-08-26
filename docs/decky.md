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
  is asserted at build time (guard-rootfs assertion 9 — loader executable, plugin dist staged,
  watchdog executable) and a genuinely broken image fails its units loudly on device.

## The injection watchdog (`/usr/lib/novadeck/decky-inject-watchdog`)

The loader running is not the loader working. Decky's frontend lives inside Steam's CEF, injected
over `127.0.0.1:8080` and held open by one websocket for the life of the session. Upstream
v3.2.8-pre1 drops that websocket permanently the first time the tab goes stale mid-connect:
`decky_loader/main.py`'s `loader_reinjector` guards `get_gamepadui_tab()` with a try/except but
leaves `await tab.open_websocket()` on the next line outside it, so the exception kills the whole
coroutine — "Task exception was never retrieved" — and no retry loop survives.

The *exposure* is on every boot: `novadeck-steam`'s exit-42 relaunch tears the first webhelper
down seconds after Decky starts reaching for it. Whether it lands inside that two-line window is
timing, and both outcomes have been seen on hardware:

- 2026-08-18, card at `d93555d`: webhelper died 8s after opening, while Decky was still
  mid-connect. `ClientConnectorError` out of `open_websocket`, reinjector task dead, no
  `Loading Decky frontend!` ever, and zero further attempts in the following eight minutes.
- 2026-08-18, card at `de08339` (fresh flash): Decky injected 6s after CEF came up and had been
  connected 23s when the relaunch arrived. CEF sent a proper `Inspector.detached` — the handled
  path — so the outer loop survived and re-injected 5s later, unaided.

So this is a race that Decky sometimes wins, not a certainty. What makes it worth a mechanism is
that losing it is silent and permanent: unit active, plugin loaded, empty QAM, nothing further in
the journal, and no recovery short of a manual restart.

`novadeck-decky-watchdog.service` restores the invariant from outside, since the loader is
upstream's pinned x86_64 binary and not ours to patch. Every 15s: if CEF is listening and no
process in `plugin_loader.service`'s cgroup holds a connection to it, restart the loader. Two
consecutive ticks are required (Decky's own reconnect polls every 5s, so that is six missed
attempts), a stopped loader is left stopped, and repeated failed recoveries back off 30s → 900s,
resetting the moment injection is seen healthy.

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

Three tabs; the backend runs as root inside the loader (`"flags": ["root"]`).

- **Games** — edits `/etc/novadeck/game-tweaks.json` (atomic writes, same file + `enabled:true`
  contract as [per-game-perf.md](per-game-perf.md)). Scheduling keys apply within one powerd
  tick; exec-time keys (FEX profile, Wine topology) need a game relaunch. The sanitizer refuses
  appid `0` — Valve's "no app" sentinel can never grow a section.
- **Power** — the system-wide profile plus GPU frequency control (auto/manual level, MHz slider bounded
  by powerd's reported min/max), straight to powerd's `org.novadeck.Power1` on the system bus
  (via `busctl`; the loader's bundled Python has no dbus module). The plugin is the ONLY UI
  surface for these: the steamos-manager shim no longer exports `PerformanceProfile1` or
  `GpuPerformanceLevel1` to SteamUI. Also carries the editable fan curve for the active
  profile — one slider per fixed temperature stop, see [fan-curve.md](fan-curve.md). The
  profile and scheduler rows state when a running game's per-game override is what is in force,
  rather than leaving a dropdown that silently disagrees with the machine.
- **Monitor** — live load, clocks, governors, per-zone CPU/GPU temperatures, memory and load
  average from `/proc` and `/sys`, plus fan speed from powerd. It also shows powerd's own
  blended, smoothed *curve input* as a separate figure, labelled as such: that number — not
  either per-zone reading — is what the fan curve is evaluated against, so the two are
  deliberately different and the tab says so. Zone classification is by `type` prefix
  (`cpu*`, `gpu*`), covering both SoCs' naming (`gpuss0` on SM8650, `gpuss-0` on SM8550);
  `tests/test-decky.sh` asserts it against the real names from each dtsi. Polls at 1 Hz, and
  only while it is the tab on screen.

Frontend: TypeScript + `@apps/decky/ui`, built by `make decky-plugin` (npm ci in a digest-pinned
node container; lockfile committed; `dist/` gitignored). The dist is a `$(ROOTFS)`
prerequisite, so a card can never assemble without its settings UI.

## Verifying on device

```sh
systemctl status novadeck-decky-sync plugin_loader novadeck-decky-watchdog
ls -l /home/deck/homebrew/services/PluginLoader      # seeded, 0755, deck-owned
journalctl -u plugin_loader -b                       # "Loading Decky frontend!" = injected
ss -tnp state established '( dport = :8080 )'        # a "Decky Loader" row = injection alive
```

The QAM tab appears under the plug icon. If the loader runs but no tab appears, check that
`~/.local/share/Steam/.cef-enable-remote-debugging` exists in the deck user's Steam root —
novadeck-steam touches it unconditionally at launch — and that the watchdog is running: an
empty `ss` row with CEF listening is the upstream injection bug, and the watchdog is what clears
it (its restart is logged to the journal with the reason).

## What the offline suite cannot prove

`tests/test-decky.sh` (in `make test`) covers the pin, units, sync decisions, the sanitizer, and
the watchdog's decision loop (driven against fake `ss`/`systemctl`); guard-rootfs assertion 9
covers image completeness. None of it can prove PluginLoader executes under our FEX build, nor
that injection works against our Steam client — both were HW-validated 2026-08-08 (erofs guest
mount + clean start + frontend injection in the journal), and both remain worth a glance after a
loader or Steam-channel bump.

The watchdog's own two branches were HW-validated 2026-08-18 by running the script by hand on a
dev card (healthy → no restart; probe pointed at a listening port the loader is not connected to
→ restart, followed by `Loading Decky frontend!` and a fresh CEF connection). The unit was then
confirmed on a `de08339` flash: active across a real boot, and — usefully — silent through a
Steam relaunch that took injection down for five legitimate seconds, so the two-tick settle does
not fire on Decky's own reconnect.

Still unobserved on a real boot: the watchdog recovering an injection that actually died, because
that boot's race went Decky's way. Catching it needs cold boots until the losing side comes up;
`journalctl -u novadeck-decky-watchdog -b` names the reason when it does.
