# Per-game performance tweaks

`/etc/novadeck/game-tweaks.json` is the single per-game settings file. It already selects FEX
profiles per game (see [windows-games-fex.md](windows-games-fex.md)); the same file also carries
performance keys, enforced at runtime by `novadeck-powerd`.

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

| Key | Type | Effect |
|-----|------|--------|
| `gamescopeNice` | int −20…19 | niceness applied to every gamescope thread |
| `gamescopeRr` | bool | promote gamescope's threads to `SCHED_RR` (realtime CPU class) |
| `gamescopeCores` | cpulist or preset | pin gamescope's threads to these CPUs |

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

- These knobs affect **gamescope** (the compositor), not the game's own threads. Game-side keys
  (env, affinity, niceness for the game tree) are a planned follow-up.
- `gamescopeRr` outranks every normal thread including the game's. It can help frame pacing when
  the compositor is starved; it can also starve the game if something in gamescope spins. Treat it
  as a per-title experiment, not a default.
- Removing a tweak (or the whole file) is picked up on the next tick and the previous state is
  repaired — no reboot, no powerd restart.
