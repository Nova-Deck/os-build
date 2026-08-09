# Per-game performance tweaks

`/etc/novadeck/game-tweaks.json` is the single per-game settings file. It already selects FEX
profiles per game (see [windows-games-fex.md](windows-games-fex.md)); the same file also carries
performance keys, enforced at runtime by `novadeck-powerd`.

The [novadeck-control Decky plugin](decky.md) edits this file from the Quick Access Menu;
editing it directly stays fully supported — the plugin's writes are atomic and its validation
is deliberately shallower than the consumers' own.

## File shape

```json
{
  "global": { "gamescopeNice": 0 },
  "games": {
    "858710": { "enabled": true, "gamescopeRr": true, "gamescopeCores": "big" }
  }
}
```

The key under `games` is the Steam appid. A game entry applies only while that game is running
**and** carries `"enabled": true` — the same contract the FEX keys use. Game values overlay the
`global` section. The file is optional; when it is absent nothing is enforced.

## Keys

Compositor (gamescope):

| Key | Type | Effect |
|-----|------|--------|
| `gamescopeNice` | int −20…19 | niceness applied to every gamescope thread |
| `gamescopeRr` | bool | promote gamescope's threads to `SCHED_RR` (realtime CPU class) |
| `gamescopeCores` | cpulist or preset | pin gamescope's threads to these CPUs |

The game itself:

| Key | Type | Effect |
|-----|------|--------|
| `nice` | int −20…19 | niceness applied to every thread of the game's process tree |
| `cores` | cpulist or preset | pin the game's threads to these CPUs |
| `env` | object | environment variables for the launch (`null` unsets one) — Proton titles only |
| `wineTopology` | bool | set `false` to pin via `cores` without reshaping what Wine reports |
| `scheduler` | `"none"` or `"lavd"` | CPU scheduler to run while this game is running |

### `scheduler` is per-game only

Every other key here can also be set in `global`. `scheduler` cannot, and the omission is
deliberate: the system-wide CPU scheduler already has exactly one home — `novadeck-powerd`'s
persisted `CpuScheduler` property, which both `novadeck-scheduler` and the plugin's **Power** tab
drive. A `global.scheduler` would be a second place to set the same value with no way for either
to show the other's state.

So the order is: a running game's `scheduler` wins; otherwise the system-wide `CpuScheduler`
applies. `"none"` is spelled out rather than implied, because forcing stock for one title on a
device whose system-wide choice is `lavd` is exactly what it is for.

The override is temporary. `novadeck-powerd` starts or stops `scx.service` when the game starts and
puts the persisted choice back when it exits — the saved choice is never rewritten, so one launch of
one game cannot change the setting for everything else. `org.novadeck.Power1.ActiveCpuScheduler`
reports what is actually loaded, and differs from `CpuScheduler` only while an override holds.

`lavd` is `scx_lavd`; see [`packages/scx-scheds/source.pin`](../packages/scx-scheds/source.pin) for
the measurements behind it and why the shipped default is still stock.

`cores` also derives `WINE_CPU_TOPOLOGY` for Proton titles, so Wine reports the CPUs the game
will actually get instead of the machine's full set.

`gamescopeCores` accepts a kernel-style cpulist (`"0,3-5"`) or a named preset: `all`, `little`,
`big` (everything that is not little, prime included), `prime`. Presets are resolved from the live
CPU topology (`cpu_capacity`), so they mean the right cores on every supported board. A per-game
`"gamescopeCores": "all"` explicitly clears a restrictive global pin.

## How enforcement works

`novadeck-powerd` re-applies the merged policy every few seconds (idempotently — a setting already
in force costs nothing). The running game is identified by walking the Steam client's process tree
(`/proc/<pid>/task/<tid>/children`, `CONFIG_PROC_CHILDREN`) and reading the game's environment for
its appid, so no launch-option wrapper is needed. When a restrictive `gamescopeCores` mask is in
force, gamescope's helper children are explicitly kept on all CPUs so the pin applies to the
compositor alone.

Notes:

- The game tree is found the same way the appid is: every process Steam launches for a title
  inherits the appid in its environment, so `nice` and `cores` reach the game on the Proton,
  system-FEX and native launch paths alike. The Steam client carries no appid and is never
  touched.
- Compositor and game keys are enforced with deliberately different rules. gamescope is ours, so
  clearing a `gamescope*` key restores the default. A game tree is not ours — Proton, FEX and the
  game set their own priorities — so `nice`/`cores` are written only when set, and only threads
  novadeck itself changed are ever put back. Each such thread is restored to *its own* prior nice
  and cpu mask, recorded before the first overwrite, so a game that pins or deprioritises its own
  threads gets that tuning back rather than a flattened "nice 0, all CPUs".
- `gamescopeRr` outranks every normal thread including the game's. It can help frame pacing when
  the compositor is starved; it can also starve the game if something in gamescope spins. Treat it
  as a per-title experiment, not a default.
- Removing a tweak (or the whole file) is picked up on the next tick and the previous state is
  repaired — no reboot, no powerd restart.

## How the keys divide across launch paths

Games launch three ways — Proton (compat tool), native x86 Linux via the system FEX
(binfmt_misc, no compat tool), native arm64 (direct exec) — and only the Proton path has
`proton-wrapper` in its exec chain. So the keys split by *binding time*, not by file:

- **Scheduling for the game tree** (`nice`, `cores`) needs no launch hook at all, and is
  enforced post-launch by `novadeck-powerd` on **every** path. Caveat: enforcement lands up to
  one tick (~3 s) after launch, so the first moments run untuned.
- **Wine/Proton env** (`env`, `WINE_CPU_TOPOLOGY` from `cores`) must exist before exec, and
  `proton-wrapper` is in the exec chain precisely for this path. Meaningless for non-Wine
  titles, so no coverage gap.

Still open, deliberately:

- **`uclamp.min` per game.** The kernel supports it (`CONFIG_UCLAMP_TASK`), but applying it per
  task needs `sched_setattr` (no Python binding — ctypes or a cgroup placement), so it is a
  separate piece of work rather than another key.
- **FEX tuning for native x86 games.** FEX has its own per-app mechanism (AppConfig JSON, looked
  up by guest binary name) in the same layer as the base `Config.json`. Per-game TSO and similar
  knobs on the system-FEX path belong there rather than in env injection. Wrinkle: it keys on
  binary name, not Steam appid, so it cannot simply reuse this file's schema.
- **Generic `env` for non-Proton titles.** No clean hook exists today; `env` therefore applies to
  Proton launches only. If a concrete need appears, the interception point is the binfmt
  registration (a shim before `FEXInterpreter` that reads this file, keyed off `SteamAppId` in
  its own environment). Native arm64 titles would still need `%command%` launch options — an
  accepted gap for the rare case.
