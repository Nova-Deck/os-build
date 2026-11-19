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
   **The account's real data (HW 2026-11-19, Pocket Max, fresh dev card, nothing installed).**
   29 of the 66 cached metadata files name a `CloudSaveFolder`; `legendary list-saves` shows
   cloud saves for 11 of them (Guacamelee! STCE and Guacamelee! 2 dated 2026-10/11, the rest
   2019-2026). What the paths look like, which steps 2 and 4 must handle:
   - the variable's CASE varies (`{AppData}`, `{appdata}`, `{userdir}`); legendary lowercases;
   - `{AppData}/../LocalLow/<company>/<game>/` is the most common form (10 games), so `..` from
     Local AppData into LocalLow must resolve and stay inside drive_c;
   - `{EpicID}` inside the path (PREY, RUINER, Phoenix Point, Death Stranding, WWZ, Wolfenstein);
   - `{InstallDir}/` as the WHOLE install folder with only an include list (Fallout, Fallout 2,
     Fallout Tactics: `*.sav, *.dat`). That settles the Risks item: a backup must copy only what
     the filters select, never the whole folder;
   - include lists carry spaces after the commas (`*.sav, *.dat`). legendary strips them for an
     upload but NOT for the download's deletion list (`core.py:1066-1068`, `split(',')` without
     `strip()`), so there ` *.dat` matches nothing and those files survive a download.
   **The HW dry run (DOOM 64, `5b60142e…`, appid 2607617071, freshly installed, never launched,
   no cloud saves on the account).** As deck, `sync-saves <app> --save-path
   <compatdata>/pfx/drive_c/users/steamuser/Saved Games/Nightdive Studios/DOOM 64/saves
   --dry-run`: rc 0, one line, `no_save` ("Got 0 remote save game(s)"). `installed.json` and
   `user.json` were byte-identical before and after, and `compatdata/2607617071` was still absent.
   So a pre-launch dry run on a first launch creates nothing, and Proton's prefix setup is not
   disturbed. **Without `--save-path` it CRASHED**: with no prefix, `{UserSavedGames}` stays
   unresolved, the path stays relative to the cwd, and `case_insensitive_path_search` lists the
   cwd (`/root`, unreadable to deck), raising `PermissionError`. An unpatched real sync crashes
   the same way. The patch now catches the `OSError` and reports `no_save_path`, and
   `check-dry-run.py` reproduces it from an unlistable cwd (36 checks). Production always passes
   `--save-path`, so this only mattered for the patch's own promise.
   `list-saves` did NOT rewrite `user.json` (same mtime and sha256; "re-use existing login
   session"), but `login()` fetched metadata for 6 apps, which writes `metadata/`.
   **legendary's own rule, seen while writing the check:** the conflict test runs BEFORE same-age.
   Both sides more than 60 s past the last sync is a conflict, even if they are the same save.
   After a real sync this never happens: the upload names its manifest after the newest local file,
   then stores `time.time()`.

### Phase 2 — sync

2. **Epic path variables** (TDD, `tests/test-store-savepaths.sh`).
   **Done 2026-11-19** (`novadeck_savepaths.resolve_epic(location, install, prefix, epic_id)`;
   the suite went from 25 to 51 checks). Each Epic variable is rewritten as the GOG token or
   Windows variable for the same folder (`EPIC_VARIABLES`), and resolution continues as for GOG:
   the registry, `..`, case and containment are shared. Variables match in any case. `{EpicID}`
   must be one alphanumeric component, or the location is refused. A `%VAR%` or `<?TOKEN?>` in an
   Epic location is refused, as legendary refuses an unresolved `%`. The checks use real
   CloudSaveFolder values from the account (DOOM 64, Guacamelee, MYZ, Moving Out, Death Stranding,
   Torchlight II, Breathedge, Fallout).
   **New for both stores:** a profile folder that does not exist yet (AppData, Documents, Saved
   Games under `users/<user>`; Local, LocalLow, Roaming under AppData) takes Windows' spelling.
   Epic's `{appdata}/../locallow` would otherwise create `locallow` before the first launch. Proton's
   copy_pfx adds only MISSING files and compares case-sensitively, so it would add `LocalLow` beside
   it, and Wine would open the exact-case, empty `LocalLow`. This is reasoned from copy_pfx, not
   seen on HW; the step 9 gate (fresh prefix) checks it on a LocalLow game.
3. **Epic rows in the plugin** (TDD): `CloudSaveFolder` present/absent, the switch, the install
   folder.
   **Done 2026-11-19** (`py_modules/novadeck_stores/epic_cloud.py`, `tests/test-store-epic-cloud.sh`,
   23 checks, in `make test`). It is a sidecar of its own, `<store home>/epic-cloud.json`, beside
   galaxy.json and keyed the same way (unsigned appid), written from `shortcuts.write_registry`.
   Row: `{token, gid, install, cloud: {supported, enabled, location, include, exclude} | None}`.
   `location` is Epic's string, untranslated; the launch side resolves it (step 2). The filter lists
   are split on commas with the spaces stripped, or None. `cloud` is None when legendary has cached
   no metadata for the game (unknown, so the launch skips it), and `supported` is False with no
   `CloudSaveFolder` or only a macOS one. The switch is cloud_config.TOGGLES, shared with GOG per
   token (absent = on). The metadata is read owner-checked, and a symlinked file is refused. No
   network.
   **Left for step 4:** the account id for `{EpicID}`. The launch side reads it from legendary's
   `user.json` (`account_id`), which it can read as deck, rather than copying it into every row.
4. **Pre-launch Epic sync** (TDD, legendary stubbed): each status of design §3, the backup before
   every download, a failed backup stops it, timeout → launch proceeds.
   **Done 2026-11-19** (`/usr/lib/novadeck/novadeck_epicsaves.py`, the glue in
   `novadeck_savesync.py`, and `tests/test-store-epicsync.sh` with 41 checks, in `make test`; GOG's
   89 savesync checks are unchanged and pass). `cloud_row` falls back to epic-cloud.json, shaped
   like a GOG row: one location named `saves`, `store: "epic"`, the filter lists. `Session`
   dispatches on the store in two places only, the classify step and the transfer. The lock,
   picker, budget, backups and status (`save-status.json`, keyed by token, so the game page reads
   Epic too) are shared.
   - legendary calls: `legendary sync-saves <gid> --save-path P --dry-run`, then
     `legendary -y sync-saves <gid> --save-path P <flag>`, with `LEGENDARY_CONFIG_PATH` set and the
     game's `LD_*` dropped. `-y` matters because legendary would otherwise prompt on a terminal it
     doesn't have. No timestamp is stored: legendary keeps its own.
   - Status → action: `remote_newer` → download, `local_newer` → upload, `conflict` → conflict,
     `same_age`/`no_save` → none. `unsupported`/`no_save_path` are skipped with a reason.
   - `{EpicID}` comes from legendary's `user.json`; if it's missing, the location is skipped and the
     reason names `{EpicID}`.
   - **Whole-install refusal:** a folder that IS the install folder, with no include list, is
     skipped. legendary's download would delete every file in it that isn't excluded, i.e. the
     game.
   - **The backup follows the include list** (Fallout: the install folder, `*.sav, *.dat`), and
     ignores the exclude list, so it is a superset of what a download might delete. It matches in
     ANY case.
   - **A backup of nothing is not taken** (only empty folders, or no selected file), for GOG too, so
     it can't rotate a real backup out of the 5 kept.
   - Offline reads "Epic could not be reached (no network?)".
   **Found on the way: legendary's filter matching is case-sensitive on Linux** (`fnmatch` with
   POSIX normcase). So legendary's `*.sav` misses Fallout's `AGRUN.SAV`: legendary on Linux would
   neither upload nor delete uppercase save files that a Windows client syncs. See Risks.
5. **Post-exit upload** through the existing watcher (TDD).
   **Done 2026-11-19, no code change.** The watcher (`novadeck_gogsession.start`) gates the upload on
   `novadeck_savesync.cloud_row`, which reads epic-cloud.json since step 4, and only starts Comet for
   a galaxy.json row with `comet: true`. `tests/test-store-launch.sh` now checks this (129 checks,
   up from 126): an Epic game with cloud on gets the watcher with the upload prefix and no Comet;
   no GOG username is looked for; and one switched off gets no unit. `post_exit` for Epic (only
   `local_newer` uploads, with `--skip-download`; a conflict waits for the next launch) is in
   `tests/test-store-epicsync.sh` (step 4).
   **Cosmetic, left as is:** for an Epic game the unit is still `novadeck-comet.service` and the
   upload `novadeck-gog-upload-<pid>`, and the watcher's log lines say "comet:". Renaming touches
   GOG's units and their checks for no behaviour change; do it if the journal confuses anyone.
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
- **Games that save in `{InstallDir}`**: decided in step 4. The backup copies only what the include
  list selects, and a whole-install folder with no include list is refused.
- **legendary matches filters case-sensitively on Linux.** The Fallouts' uppercase saves
  (`SAVE.DAT`, `*.SAV`) don't match `*.sav, *.dat`, so they would never be uploaded. Check on HW
  with a Fallout before trusting it. If confirmed, the fix is a second legendary patch
  (case-insensitive `_filename_matches`, which is what Epic's Windows client effectively does),
  sent upstream with 0001.
- **CALL_TIMEOUT (30 s) per transfer**, shared with GOG. A large Epic save (Cities: Skylines) over
  slow Wi-Fi could be cut off mid-download, after legendary has already deleted the local files.
  The backup holds them, and the next launch downloads again (an empty local side reads
  `remote_newer`; nothing is uploaded after exit). Restoring the backup automatically after a
  failed download is a possible follow-up.
- **Variables the table lacks**: `{UserProfile}` is unset outside Windows in legendary. We map it
  from the prefix, so a game legendary itself cannot resolve may work with us; refuse anything
  else with a reason.
