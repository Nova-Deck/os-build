# Plan: Alien games — library entry writer

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 4 — Library entry writer
**Complexity**: Medium (was Large before the write-mechanism finding below)
**Depends on**: nothing in milestones 1–3 — drivable with a hand-placed game directory (PRD
ordering note). The install record from milestone 3 is used when present, never required.

## Summary

An alien game gets an entry in Steam's library that survives a Steam restart and a reboot, keyed
on **our** stable id (`<store>:<game_id>`) behind a launcher stub — never on Steam's appid — and
is removed cleanly. Creation and removal happen through Steam's own live API, so Steam persists
its own file and the ecosystem's restart-and-rewrite pathology never applies to us.

The launch itself is milestone 6: this milestone's stub records the attempt and exits nonzero.
The panel is milestone 7: the writer is backend/bridge machinery, driven directly at the gate.

## Verified before planning

| Fact | Evidence |
|---|---|
| **Steam's live API creates and removes shortcuts**: `AddShortcut(appName, exe, dir, launchOpts) → Promise<appid>`, `SetShortcutName/Exe/StartDir/LaunchOptions/Icon`, `RemoveShortcut(appid)` | `@decky/ui` `steam-client/App.ts:17,467,614-649`; unifideck uses them live (`steam-bridge/temp-shortcut.ts:91-130`) and its API-created shortcuts launch in the same session — only file-written ones need the restart |
| unifideck writes `shortcuts.vdf` directly and pays for it: vendored vdf lib, write guard, foreign-entry merge, 3-deep backups, byte re-count, `chmod 0755` against a foreign scanner, and a restart prompt — Steam loads the file at startup and overwrites external writes on shutdown | `_reference/unifideck` `services/shortcut/{persistence,write_guard,vdf_read,vdf_backup}.py`, `events.py:288-292`; their restart modal calls `StartShutdown(false)` |
| **Ownership is proven by the `Exe` basename, never by tags or `LaunchOptions`** — foreign tools copy both, which is how their incident UD-006 deleted users' own games | `orphan_scan.py:36-53`, `write_guard.py:88-101`, `stale_predicate.py:77-86` |
| The durable id rides in `LaunchOptions` as argv[1] (`store:game_id`), user params kept around it; a leading bare `%command%` in a shortcut's options makes Steam launch **nothing** | `launch_options.py:23-26,129-178`, `launcher/argv_options.py:30-61` |
| They keep a registry `store:id → appid` outside Steam's tree and reclaim by registry first, token second, appid third | `registry.py`, `reconcile_phases.py:240-292` |
| Shortcut appids are not computable ahead of time and churn on re-add | PRD evidence (steam-for-linux#9463); unifideck assigns its own CRC ids and still needs the registry to survive a moved plugin dir |
| `SteamClient` is reachable only from the plugin frontend; our cdp.py deliberately holds **no** socket to `SharedJSContext` — a dropped one can cost Decky its injection (one-shot `Runtime.evaluate` on another target is the pattern it does allow) | `novadeck_stores/cdp.py:1-20`, `tests/test-decky.sh` |
| We already parse binary `shortcuts.vdf` (types 0/1/2) read-only | `novadeck_control/steam.py:15-60` |
| `SetAppLaunchOptions` is already production machinery here (launchWrapper), and `SetCustomArtworkForApp(appId, base64, …)` exists for milestone 5 | `novadeck-control/src/lib/launchWrapper.ts`, `App.ts:62,567` |
| The userdata account dir is a single-user question on this image: one `deck` user, Steam autologin | `userdata/*/config/shortcuts.vdf` glob in `steam.py:45` tolerates several; the writer must still pick the live one |

## Design

**Write through Steam, never the file.** `AddShortcut` / `SetShortcut*` / `RemoveShortcut` from
the plugin frontend, while Steam runs. Steam keeps `shortcuts.vdf` itself, so the write guard,
foreign merge, backups and restart prompt that unifideck carries all have nothing to guard here.
Our binary-VDF reader is kept for **verification only** (the gate reads the file after a
restart/reboot to prove persistence) and for the orphan scan.

**Identity, answering the PRD's open question.**
- `Exe` = `"/usr/lib/novadeck/store-launch"` — a stub on the read-only root, identical on both
  A/B slots, so the path survives every OTA. **The Exe basename is the ownership proof**, exactly
  as unifideck's incident taught: tags and LaunchOptions are never trusted.
- `LaunchOptions` = `<store>:<game_id>` (argv[1]; user-added params survive around it). The token
  is convenience and recovery input, not proof.
- **`game-launch %command%` never enters an alien entry's LaunchOptions**: we own the stub, so
  per-game tuning (milestone 6+) happens *inside* it. Identity and tuning stop sharing the field
  because the field only carries identity. The appid-churn question for tuning resolves the same
  way: the stub knows `store:id`, so tuning re-keys on our id when it returns to scope.
- `AppName` = store title; `StartDir` = the recorded install path, `""` when not installed.
- **Steam's appid is accepted, not computed**: `AddShortcut` returns it, and it lands in our
  registry `<store home>/shortcuts.json` (`store:id → {appid, title, created}`), written as
  `deck` like installs.json. Re-found after churn registry-first, then token, then never by
  appid alone — and every destructive act re-checks ownership by `Exe` first.

**Who runs what.** The frontend owns the five `SteamClient` calls behind one small bridge module
(`src/lib/shortcutBridge.ts`), called by the panel in milestone 7. The backend owns sequencing,
the registry, and verification. Backend→frontend crossings use the decky event bus exactly like
`connect_done` does today. At the gate (no panel), the bridge functions are invoked by a one-shot
CDP `Runtime.evaluate` into `SharedJSContext` — short-lived socket, one call, closed, gate-only;
the production path never opens one.

**The stub, this milestone**: parses `store:id`, appends one line to a log in the store home, and
exits 64. Pressing Play on an entry before milestone 6 visibly does nothing *and says so* in the
log; the stub is the ownership anchor and the argv contract, not yet a launcher.

**Removal** is `RemoveShortcut(appid)` live, then the registry row drops. An uninstall (milestone
3) does not remove the entry — a user can keep the entry and reinstall; milestone 7 decides the
surfaced behaviour. An orphan scan (ours-by-Exe, token missing or unknown) only ever reports this
milestone; nothing deletes on its own judgment.

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Frontend executes, backend decides | `novadeck-stores/main.py` connect flow + `index.tsx` listener | Event out, backend call back with the result |
| Live Steam API with a null-check contract | `novadeck-control/src/lib/launchWrapper.ts` | Best-effort, never block a launch; redundant writes avoided |
| Records written as deck | `installs.py read_records/write_records` | Same shape for `shortcuts.json` |
| Binary VDF read | `novadeck_control/steam.py:15-60` | Copied (plugins cannot import each other), header says where from |
| Offline tests | `tests/test-store-install.sh` | Fixture vdf bytes, argv assertions, ownership refusals |

## Files to Change

| File | Action | Why |
|---|---|---|
| `rootfs/overlay/usr/lib/novadeck/store-launch` | CREATE | The stub: argv contract, ownership anchor, milestone-6 seam |
| `apps/decky/novadeck-stores/py_modules/novadeck_stores/shortcuts.py` | CREATE | Registry, entry templates, vdf verification reader, orphan classification |
| `apps/decky/novadeck-stores/src/lib/shortcutBridge.ts` | CREATE | The five SteamClient calls, nothing else |
| `apps/decky/novadeck-stores/src/index.tsx` | UPDATE | Event listener wiring the bridge, like connect_done |
| `apps/decky/novadeck-stores/main.py` | UPDATE | `register_entry`, `deregister_entry`, `entry_status` — callable, not yet surfaced |
| `tests/test-store-shortcuts.sh` | CREATE | Every decision above, offline |
| `Makefile` | UPDATE | The new suite in `make test` |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 4 row on completion |

## Tasks

### Task 1: The stub and the argv contract
- `store-launch`: argv[1] must match `^(epic|gog):[A-Za-z0-9][A-Za-z0-9._-]*$` (control
  characters refused for the same reason as installs.py's `safe_component`); logs and exits 64.
- **Validate**: suite drives good/bad argv; the exit code and log line asserted.

### Task 2: Registry and templates
- `shortcuts.py`: `read/write` of `shortcuts.json` (deck-owned, like installs.json), the entry
  field template, and `is_ours(entry)` by Exe basename after strip-quotes — unifideck's exact
  test, including the quoted-path form.
- **Validate**: fixture entries ours/foreign/quoted/missing-Exe; a tags-only or token-only
  claim is refused.

### Task 3: Bridge and wiring
- `shortcutBridge.ts` wraps AddShortcut → returns appid; Set* setters; RemoveShortcut takes the
  **unsigned** appid (unifideck: live calls use unsigned). `index.tsx` listens, executes, calls
  the backend back with the result.
- **Validate**: `make decky-plugin` builds; offline suite asserts the event payload shape from
  the backend side.

### Task 4: Backend sequencing
- `register_entry(store, gid)`: look up title (library cache or record), install path (record,
  else `""`), emit to the frontend, await the appid callback, write the registry row. Refuse a
  second entry for a registered id (registry hit + a live entry that `is_ours`).
  `deregister_entry` reverses it. `entry_status` joins registry and a read of shortcuts.vdf.
- **Validate**: suite fakes the frontend callback; double-register refused; deregister of an
  unknown id refused and logged.

### Task 5: Verification reader and orphan report
- The copied vdf reader finds our entries in the written file (ownership by Exe), joins them to
  the registry: `healthy` / `orphan-no-token` / `registry-without-entry`. Report only.
- **Validate**: fixture vdf bytes for each class, including a foreign entry carrying our token
  (unifideck's NSL case — must be left alone and excluded from matching).

### Task 6: Hardware gate
- On the dev card, Steam running, driven over SSH (backend via drive.py; bridge via one-shot CDP
  evaluate into SharedJSContext — gate-only):
  1. Register an entry for a hand-placed game dir and one for an installed milestone-3 title.
  2. Entry appears in Big Picture with its name; Play produces the stub's log line and exit.
  3. **Steam restart** (kill the session tree per the known procedure, never `systemctl restart
     sddm`): entry still present, appid unchanged, registry agrees, shortcuts.vdf on disk shows
     the entry (our reader).
  4. **Reboot**: same checks.
  5. Deregister both; shortcuts.vdf shows them gone after the next Steam flush; registry empty;
     no orphans reported.
  6. The sweep: registry deck-owned `0600`-dir semantics like the store home, no stray writes to
     `userdata` beyond what Steam itself did.

## Validation

```bash
bash tests/test-store-shortcuts.sh      # offline, every decision above
source dev.env && make test             # all suites
source dev.env && make decky-plugin     # the bridge compiles into dist/
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `AddShortcut` behaviour differs on the arm64 client (fields ignored, appid semantics) | Medium | Gate step 2/3 measures on the real client before anything builds on top; the mis-packed-atoms precedent says never assume parity |
| A CDP evaluate into SharedJSContext destabilises Decky | Low, costly | Gate-only, one-shot, closed immediately; production path is the event bus; if the gate shows instability, fall back to driving through a temporary backend method calling decky's own frontend bridge |
| Steam restart loses an API-created entry | Low | That is the gate's central question (mirrors milestone 3's network cut): measured before design hardens; unifideck's same-session launches of API-created entries say the client owns them properly |
| Appid churns on re-add after deregister | Certain | By design: registry is rewritten on every register; nothing durable keys on Steam's appid |
| A foreign tool copies our token into its entry | Known real (NSL) | Ownership by Exe only; token never proof; Task 5 fixture pins it |
| The stub path moves in a future restructure | Low | The basename is the ownership test, mirroring unifideck's reasoning; the absolute path matters only to Steam |

## Acceptance

- [ ] An entry is created and removed through Steam's own API, no direct shortcuts.vdf write
- [ ] Ownership of every destructive act is proven by the Exe basename
- [ ] The entry survives a Steam restart and a reboot with its appid, verified in the file
- [ ] Our registry, not Steam's appid, is the durable key; churn on re-add is absorbed
- [ ] Play before milestone 6 fails loudly in the stub's log, exit 64
- [ ] `make test` green with the new suite
