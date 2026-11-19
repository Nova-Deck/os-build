# Plan: Epic cloud saves

**Branch**: `epic-cloud-saves`, one commit per step.
**Complexity**: Medium. Mostly reuses the GOG cloud-save machinery
(`.claude/plans/gog-galaxy-comet.plan.md` phase 3): the launch hook, the exit watcher, the lock,
backups, the "Which saves?" spool, the status file and the game-page switch. What is new: a
legendary `--dry-run` patch, Epic's path variables, and an Epic branch in the sync.
**Depends on**: GOG cloud saves (merged cc11041) and the Epic install path (`legendary install`,
so `installed.json` lists every game we installed).

## Summary

Epic games with cloud saves sync them with Epic's cloud through `legendary sync-saves`. The
behaviour is the same as for GOG: down before a launch (with a backup, and the "Which saves?"
dialog when both sides changed), up after an exit, with a per-game switch and the last sync on
the game page.

User decisions carried over from GOG (2026-11-17), not re-asked:
- **Conflicts are asked**, with both dates. **The local folder is backed up before any download.**
- **Sync is ON by default** for every cloud-enabled game, with a per-game switch.

## Verified before planning

### Heroic (`_reference/heroic` ce05767, 2026-11-18)

| Fact | Evidence |
|---|---|
| Heroic leaves Epic's save sync to `legendary sync-saves` | `storeManagers/legendary/games.ts:848-879` |
| The save path: it clears legendary's stored `save_path`, then runs `sync-saves <app> --skip-upload --skip-download --accept-path` with the prefix in the env. legendary computes the path and stores it in `installed.json`, and Heroic reads it back. The user can edit the path | `save_sync.ts:40-102`, `Settings/sections/SyncSaves/legendary.tsx` |
| Before launch `--skip-upload --save-path P -y`, after exit `--skip-download`; only with the per-game `autoSyncSaves` (default **off**) and online | `launcher.ts:128-160, 295-316` |
| A conflict is skipped silently (`-y` only logs it) and no backup is taken | `legendary cli.py:535-542` |

### legendary (0.20.43, the Heroic fork we package; `_reference/legendary` f6fb311 = the tag + CI only)

| Fact | Evidence |
|---|---|
| One location per game: `metadata.customAttributes.CloudSaveFolder.value` (a game supports cloud saves iff it is set); filters `CloudIncludeList` / `CloudExcludeList` | `models/game.py:111-112`, `core.py:1003-1016` |
| Variables: `{InstallDir}`, `{EpicID}` (account id), and from the prefix's `user.reg`: `{AppData}` = Local AppData, `{UserDir}` = Documents, `{UserSavedGames}`; plus a legacy-AppData rewrite for `locallow`/`roaming`. `{UserProfile}` is only set on Windows | `core.py:847-964` |
| The computed path goes through `realpath()` with **no containment check**: a Documents folder that winecfg linked to `$HOME` resolves into `$HOME` | `core.py:958` |
| Classification is `check_savegame_state`: newest local mtime vs the manifest's name (`YYYY.MM.DD-HH.MM.SS.manifest`) vs `installed.json`'s `save_timestamp`; 60 s windows; statuses `local_newer`, `remote_newer`, `same_age`, `no_save`, `conflict` | `core.py:966-1001` |
| legendary keeps the sync time itself (`save_timestamp = time.time()` after each transfer) | `cli.py:549-602` |
| A download deletes the local save files **before** it fetches the cloud manifest; a failed fetch leaves the folder emptied | `core.py:1059-1072` |
| `--save-path` with an app name is written to `installed.json` (under its lock) | `cli.py:484-490` |
| No dry run. Logging goes to stderr, so stdout is free for a report | `cli.py:37-40` |
| `sync-saves` calls `core.login()` first: network, and it may refresh `user.json` | `cli.py:452-454` |

### Our code

| Fact | Evidence |
|---|---|
| `game-launch` calls `novadeck_savesync.pre_launch(appid)` for any game; it reads GOG rows only | `game-launch:442-449`, `novadeck_savesync.py` |
| The exit watcher already runs without Comet, only for the upload | `novadeck_gogsession.start`, `unit_argv` |
| The resolver reads the prefix's `user.reg`, falls back to the table for a prefix not yet created, refuses escapes by `..` or a symlink | `novadeck_savepaths.py` |
| The plugin already reads Epic `customAttributes` (third-party, extras) | `library.py:46-59` |
| legendary's config dir is `$STORE_HOME/legendary` (`LEGENDARY_CONFIG_PATH`) | `store-env:51` |

## Design

### 1. legendary patch 0001: `sync-saves --dry-run`

legendary has no dry run, and a real sync either logs a conflict and does nothing (`-y`) or
deletes and transfers. So, as for gogdl: `sync-saves <app> --save-path P --dry-run` prints one
JSON line per game it checks and changes nothing. No `installed.json` write, no directory
created, no transfer:

    {"app_name": "...", "status": "local_newer|remote_newer|same_age|no_save|conflict|unsupported|no_save_path",
     "save_path": "...", "local_newest": ts|null, "cloud_newest": ts|null,
     "cloud_manifest": "...|null", "last_sync": ts|null}

`status` comes from legendary's own `check_savegame_state`, so it is the same verdict a real sync
acts on. `--skip-*` / `--force-*` are not applied. `packages/legendary/check-dry-run.py` (network
stubbed, transfers and `installed.json` writes made to fail) runs from `build()`, as gogdl's
does. Sent upstream; drop it once a release carries `--dry-run`.

### 2. Save paths (`novadeck_savepaths`)

Epic variables, mapped to the same folders the GOG tokens use: `{InstallDir}`, `{AppData}` (Local
AppData), `{UserDir}` (Documents), `{UserSavedGames}`, `{UserProfile}`, `{EpicID}` (the account
id, from `user.json`). The same rules apply: case-insensitive matching of existing levels,
refusal with a reason, containment in drive_c or the install folder. We always pass
`--save-path`, so legendary never computes or stores a path of its own.

### 3. Sync (`novadeck_savesync`, an Epic branch)

Pre-launch, by dry-run status:
- `remote_newer`: back up, then `--skip-upload -y`. This includes the empty-local case, which is
  how a new device gets its saves.
- `conflict`: ask (the `.savepick` spool, with one location). "cloud" → back up +
  `--force-download -y`; "local" → `--force-upload -y`; no answer → keep local.
- `local_newer` / `same_age` / `no_save`: nothing.

Post-exit: only `local_newer` → `--skip-download -y`. legendary stores the timestamp itself, so
there is no `save-timestamps.json` entry for Epic. The lock, `BUDGET`, call timeouts, backups
(`save-backups/<token>/<location>/`), the status file and the failure text all stay shared, with
"Epic could not be reached" for an offline sync.

### 4. Plugin

An Epic row beside the GOG ones (appid → token, gid, install, `cloud: {enabled, location}`) from
legendary's cached metadata, without a network call. The game-page switch and last sync work for
Epic tokens. The picker's location name is the game's title.

## Steps

### Phase 1 — classification

1. **legendary `--dry-run` patch** + `check-dry-run.py` in `build()` + `make relock`; the offline
   suite checks the patch and check-script pins. HW: as the store user, dry-run a real
   cloud-enabled Epic game, and compare `installed.json` and the save dir before and after.
   Record whether `login()` rewrote `user.json` (Risks).
   **Patch done 2026-11-19** (`packages/legendary/patches/0001-sync-saves-add-dry-run.patch`,
   legendary 0.20.43-2.1). It adds an empty `prepare()` to the PKGBUILD, because build-overlay
   places patches after its first `cd`. One JSON line per game checked; a game without cloud
   saves prints `unsupported` instead of nothing. The update notice (a stdout `print`, only shown
   where `disable_update_notice` defaults off, so not on Linux) is suppressed for `--dry-run`, as
   it is for `--json`. `check-dry-run.py` runs legendary's real `main()` and core against a seeded
   config dir, with only the network stubbed and transfers plus `set_installed_game` made to fail:
   33 checks. Unpatched 0.20.43 fails it (the real sync stores `--save-path`). The offline suite
   (`tests/test-store-cli.sh`) now checks, for both legendary and gogdl, that the declared patch
   exists, that `prepare()` has its `cd`, that build() runs the check, and that the check's sha256
   is pinned.
   **legendary's own rule, seen while writing the check:** the conflict test runs BEFORE same-age.
   Both sides more than 60 s past the last sync is a conflict, even if they are the same save.
   After a real sync this never happens: the upload names its manifest after the newest local file,
   then stores `time.time()`.

### Phase 2 — sync

2. **Epic path variables** (TDD, `tests/test-store-savepaths.sh`).
3. **Epic rows in the plugin** (TDD): `CloudSaveFolder` present/absent, the switch, the install
   folder.
4. **Pre-launch Epic sync** (TDD, legendary stubbed): each status of design §3, the backup before
   every download, a failed backup stops it, timeout → launch proceeds.
5. **Post-exit upload** through the existing watcher (TDD).
6. **Game page** for Epic: switch, last sync, reasons.

### Phase 3 — hardware gates (Pocket Max)

7. First sync of a game with saves on both sides → asked; each answer does what it says.
8. Play, quit → uploaded; dry run says `same_age`.
9. Fresh prefix (or a second device) → the cloud's saves come down before the first start.
10. Offline launch → the game starts, and the page says Epic could not be reached.

### Bookkeeping

- A GitHub issue tracks the work, linking this plan.
- Send the legendary patch upstream (the user's call, as with gogdl).

## Risks / open questions

- **`login()` before every sync** may refresh `user.json` while the plugin runs its own
  legendary call. Check in step 1 whether the two can collide, and widen the lock if they can.
- **Upload filters**: legendary's local "newest" counts every file under the path, but an upload
  only sends files that pass `CloudIncludeList`/`CloudExcludeList`. A game that writes a
  non-save file there on every run reads as `local_newer` on every exit. The upload would then
  re-send unchanged saves, which is harmless, but note it if seen.
- **Games that save in `{InstallDir}`**: the download deletes only files matching the filters, but
  the backup copies the whole folder. That could be the whole game. Cap the backup to the files
  the filters match, or refuse install-dir locations without filters; decide in step 4.
- **Variables the table lacks**: `{UserProfile}` is unset outside Windows in legendary. We map it
  from the prefix, so a game legendary itself cannot resolve may work with us; refuse anything
  else with a reason.
