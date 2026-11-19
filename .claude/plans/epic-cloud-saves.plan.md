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
   **Done 2026-11-19.** `cloud_saves.py` reads an Epic row when an appid has no galaxy.json row. Its
   states: `unknown` (no metadata cached), `unsupported` (no CloudSaveFolder), on/off. The last sync
   is legendary's `save_timestamp` (installed.json, owner-checked); the notes come from the shared
   status file by token. The switch writes cloud_config.TOGGLES and rewrites the epic-cloud.json
   row at once, never galaxy.json. `save_picks.describe` answers an Epic question as location 0,
   named `saves` (`epic_cloud.LOCATION_NAME`; the cloudsaves suite pins it equal to the launch's
   `novadeck_epicsaves.LOCATION_NAME`). Every save_pick event now carries `store`, and the dialog
   says "in the {GOG|Epic} cloud". `cloudLines(cloud, store)` words "no switch" per store. Suites:
   cloudsaves 58 (up from 44), savepick 31 (up from 29). The one changed GOG check is the event
   now carrying `store`. tsc clean, rollup builds, all 19 store suites pass.

### Phase 3 — hardware gates (Pocket Max)

**First HW run, 2026-11-19 (OTA `20261119T155217Z`, git 1d50cf2, slot B).** The user played DOOM 64
and saved. Nothing synced: `epic-cloud.json` was never written, so there was no row, no status
record, and no `save_path` in installed.json. The plugin regenerated galaxy.json and epic-cloud.json
ONLY on a registry write, and nothing had changed the registry since the OTA. `frontend_ready`
re-synced first-run steps and DOSBox targets for exactly this case, but not the two cloud sidecars.
GOG had the same hole; it never showed because its games were installed after galaxy.json
existed. **Fixed:** `frontend_ready` now syncs both, each best-effort under the shortcut lock;
`tests/test-store-epic-cloud.sh` has 27 checks. The save itself was where step 2 resolves it:
`Saved Games/Nightdive Studios/DOOM 64/saves/save_00.sav` (+ `.sav.sig`, 678 KB). Once the row
exists, the next exit uploads it (`local_newer`: nothing at launch, then `--skip-download`).

7. First sync of a game with saves on both sides → asked; each answer does what it says.
   **PASS for "Decide later" and "Cloud saves", 2026-11-19 (Pocket Max, Guacamelee, FAKED
   conflict).** With no second PC, the conflict was staged: `installed.json` was backed up,
   Guacamelee's `save_timestamp` was set back from 16:17:58 to 16:00 (before the 16:17:37 cloud
   manifest), and `SAVE.DAT` was touched. legendary then calls both sides "changed > 60 s after the
   last sync", and the dry run said `conflict`.
   - **Decide later:** `asking which saves to keep` → `conflict -> kept-local`; the game started.
     After exit: `conflict -> next-launch`, no upload; the cloud was unchanged; the request spool
     was empty again.
   - **Cloud saves:** `conflict -> downloaded`. The backup came first,
     `save-backups/epic:25b902…/saves/20261119T162038Z/SAVE.DAT`, holding the 16:19:52 file the
     download replaced. After exit: `upload -> uploaded` (manifest `2026.11.19-16.21.05`).
     legendary's `save_timestamp` was real again, and the dry run said `same_age`.
   - **This device's saves** (`--force-upload`): not run on HW; covered by
     `tests/test-store-epicsync.sh`.
8. Play, quit → uploaded; dry run says `same_age`.
   **PASS 2026-11-19 (Pocket Max, DOOM 64, after the frontend_ready hot patch).** At launch:
   `saves: upload -> nothing`. The watcher started `novadeck-gog-session.service` with no Comet. After
   exit (16:12:01): `saves: upload -> uploaded`, in `novadeck-gog-upload-4652` (6.8 s). The status
   record is `phase: exit, did: uploaded`. installed.json now holds our `save_path` and
   `save_timestamp` 1795104721.44. `legendary list-saves` shows `2026.11.19-16.05.17.manifest`, named
   after the save's own mtime, not the upload time. A dry run then says `same_age`. No backup was
   taken (nothing was downloaded).
9. Fresh prefix (or a second device) → the cloud's saves come down before the first start.
   **PASS 2026-11-19 (Guacamelee! STCE, `{UserDir}/GuacameleeSTCE_EGS/`, appid 2577189476, freshly
   installed, cloud saves from 2026-10-29 and 2026-11-01).** The first launch said
   `saves: download -> downloaded`, and the user confirmed their saves were in the game. The download
   ran BEFORE Proton created the prefix: `pfx/`, `users/steamuser` and `Documents/GuacameleeSTCE_EGS`
   all have the same birth time, 16:14:57.556, and Proton's own `Documents/Music`, `Pictures` etc.
   came at 16:15:00, beside our folder, which it kept. legendary's `save_path` is our resolved one.
   No backup was taken (the local side was empty). The game rewrote `SAVE.DAT` 36 s in, so a dry
   run now says `local_newer`: the upload is due at exit. **After the user quit:** `saves: upload ->
   uploaded` at 16:17:58 (`novadeck-gog-upload-5585`, 5.9 s), a new cloud manifest
   `2026.11.19-16.17.37` beside the two old ones, and a dry run says `same_age`. Not exercised: the LocalLow spelling
   (Documents is canonical already); a LocalLow game such as Moving Out covers it.
10. Offline launch → the game starts, and the page says Epic could not be reached.
    **PASS 2026-11-19 (Pocket Max, Guacamelee, Wi-Fi off).** Launch:
    `saves: - -> skipped (Epic could not be reached (no network?))`; the game started. After exit,
    the same skip, in 2.2 s. The game page row was `on`, last synced 16:21:15, with the note
    "saves: not synced after the last exit: Epic could not be reached (no network?)". The offline
    session's save stayed put; back online, a dry run says `local_newer`, so the next exit uploads
    it.

**LocalLow on a fresh prefix: PASS 2026-11-19 (Moving Out, appid 2176316226,
`{AppData}/../LocalLow/Team17 Digital Limited/Moving Out/`, cloud saves from 2021-12 and 2022-02).**
First launch: `saves: download -> downloaded`. `users/steamuser`, `AppData`, `LocalLow`,
`Team17 Digital Limited` and `Moving Out` all have the same birth time, 16:25:00.867 (the download);
Proton's `AppData/Local`, `Roaming` and `Documents` came at 16:25:03.97. There is one `AppData` and
one `LocalLow`, no second, differently-cased copy. `SaveFile.sav` kept the cloud manifest's time
(2022-02-27 16:28:30), and the game opened on it. After the user quit, `upload -> uploaded`
(manifest `2026.11.19-16.28.16`), then `same_age`. Epic spells it `LocalLow` here already, so the
lowercase respelling (`{appdata}/../locallow`, Death Stranding and Phoenix Point) is still covered
offline only.
**Moving Out writes `output_log.txt` into its save folder on every run** (no include list), and the
new manifest is named after it (16:28:16), not after `SaveFile.sav` (16:28:09). Every session
reads `local_newer`, so every exit uploads, harmlessly. Across two devices, every launch after
playing on the other asks "Which saves?"; the dialog's dates tell the user which side is real.
Same class as Another World's settings file under GOG.

**Phase 3 summary (2026-11-19).** Gates 7 (Decide later + Cloud saves, on a faked conflict), 8, 9
and 10 pass on the Pocket Max. That was on the OTA of 1d50cf2 plus the frontend_ready hot patch
(b1aad1c), which the first HW run made necessary. Not run on HW: "This device's saves"
(`--force-upload`; offline suite only), the lowercase `locallow` respelling (needs Phoenix Point;
Moving Out passed LocalLow on a fresh prefix), and the case-sensitive filter suspicion (needs a Fallout).

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
- **legendary matches filters case-sensitively on Linux: CONFIRMED offline, 2026-11-19.** The check
  ran legendary 0.20.43's own `SaveGameHelper.package_savegame` (upload) and `get_deletion_list`
  (download) against a fake install with the Fallouts' real filters, the lists parsed exactly as
  core.py does (stripped for upload, NOT for download):
  - uppercase saves (`SAVE.DAT`, `AGRUN.SAV`, `TACTICS SAVE 2.SAV`) are neither uploaded nor
    deleted. On Windows the same code matches them, because `fnmatch` normcases there; the bug is
    Linux-only. When nothing matches, legendary logs "No save files matching the specified filters"
    and exits 0, and our status then says **"uploaded"**: a game that looks synced and isn't;
  - a lowercase `save.dat` is uploaded but never deleted by a download (` *.dat` with its leading
    space matches nothing), so a download leaves stale `.dat` saves behind. That's benign;
  - **TRAP:** that same leading-space bug is what stops a download deleting `master.dat`, Fallout's
    main data file. The exclude list reaches the download as `[critter.dat, " master.dat"]`, which
    matches nothing. A patch that makes matching case-insensitive and strips ONLY the include list
    would make a cloud download delete the game's data. So a legendary 0002 must strip BOTH
    download lists and match case-insensitively together, with a check-dry-run case for exactly
    this.
  **CONFIRMED ON HW 2026-11-19 (Fallout 1, appid 2918600411, `{InstallDir}/`, `*.sav, *.dat` minus
  `critter.dat, master.dat`).** The Epic build has four language folders, each with uppercase
  `MASTER.DAT` and `CRITTER.DAT` (2.2 GB install), and runs `Fallout 1 English/falloutwHR.exe` (the
  high-res patch). The user's save landed as `Fallout 1 English/DATA/SAVEGAME/SLOT01/SAVE.DAT`,
  `V13ENT.SAV` and `AUTOMAP.SAV`, all uppercase. After exit: `saves: upload -> uploaded`, the status
  record says `uploaded`, and legendary stored a `save_timestamp`, yet `legendary list-saves` shows
  NOTHING for Fallout. The dry run still says `local_newer` (no cloud save means `local_newer`,
  always), so every exit "uploads" nothing and reports success. The game page would say "on, last
  synced …". Also seen: a dry run right after install already said `local_newer`, because
  legendary dates the local side by the newest file in the whole folder, unfiltered.
  **Our own bug, found from the install:** `selects()` ignores the exclude list and matches in any
  case, so a backup of this install would copy all eight `MASTER.DAT`/`CRITTER.DAT` (about 2 GB),
  with five copies kept. It has not fired: a backup only precedes a download, and Fallout has no
  cloud save.
  **Fix, before merge:**
  (a) legendary patch 0002: `_filename_matches` case-insensitive, and the download's lists
  stripped like the upload's, so the upload, the download and Epic's Windows client select the same
  files. Its check must prove `MASTER.DAT` is never deleted and `SAVE.DAT` is uploaded;
  (b) our backup applies the exclude list too, with the same rule, which is now exactly what the
  patched legendary deletes;
  (c) an upload where legendary packed nothing ("No save files matching…" / "No files to upload")
  is recorded as nothing uploaded, not as "uploaded".
  **All three done 2026-11-19.**
  (a) `packages/legendary/patches/0002-sync-saves-match-save-filters-in-any-case.patch`
  (legendary 0.20.43-3.1): `_filename_matches` casefolds; `parse_filter_list()` (strip, drop empty
  items) serves both the upload and the download. That fixed a THIRD bug: in `"LocalData/,"` the
  trailing empty item was a suffix of every file, so the upload excluded everything.
  `check-save-filters.py` runs legendary's real `upload_save` and `download_saves` (network
  stubbed; the manifest fetch fails, so what remains is what the clean-up kept) against Fallout's
  real Epic layout, with both Fallouts' filter strings. It checks: every save packed and cleaned,
  in any case; no MASTER.DAT or CRITTER.DAT ever; the empty item dropped. It fails on 0001 alone,
  and a mutant that fixes the case but leaves the download's exclude list unstripped deletes all
  four MASTER.DAT and fails it. Both checks pass in the aarch64 container.
  (b) `novadeck_epicsaves.selects(rel, include, exclude)` applies the same rule as the patched
  legendary, and the backup passes both lists. On Fallout's layout the backup is exactly
  SAVE.DAT, V13ENT.SAV and AUTOMAP.SAV. A folder holding only excluded game data takes no backup.
  (c) after a real Epic upload, legendary's "No files to upload" on stderr turns `uploaded` into
  `skipped`, with the reason "legendary found no file the game's save filters select; nothing
  uploaded", also for "This device's saves". `tests/test-store-epicsync.sh`: 45 checks.
- **CALL_TIMEOUT (30 s) per transfer**, shared with GOG. A large Epic save (Cities: Skylines) over
  slow Wi-Fi could be cut off mid-download, after legendary has already deleted the local files.
  The backup holds them, and the next launch downloads again (an empty local side reads
  `remote_newer`; nothing is uploaded after exit). Restoring the backup automatically after a
  failed download is a possible follow-up.
- **Variables the table lacks**: `{UserProfile}` is unset outside Windows in legendary. We map it
  from the prefix, so a game legendary itself cannot resolve may work with us; refuse anything
  else with a reason.
