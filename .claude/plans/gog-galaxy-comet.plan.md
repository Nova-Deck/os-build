# Plan: GOG Galaxy emulation (Comet) and GOG cloud saves

**Branch**: `gog-comet`, one commit per step.
**Complexity**: Medium-large. One new prebuilt package, a launch-time session helper in
`game-launch`, two new plugin sidecars, a save-conflict picker, and a per-game toggle.
**Depends on**: the alien-games launch path (model B), the first-run hook
(`novadeck_firstrun.py`) and the boxtron request spool (`requests/<appid>.dospick`), whose
patterns this mirrors.

## Summary

GOG games built on the Galaxy SDK sign in through the GOG Galaxy client. We ship no client, so
the sign-in never completes. **Another World 20th Anniversary Edition dies ~11 s in** because its
first achievement unlock (`anowor+0x1f31d`, logging `"[GOG] Trying to unlock achievement %s"`)
reads a stats object that only exists after a successful sign-in. It crashes the same way on
Proton CachyOS and Proton GE (HW 2026-11-17, Pocket Max, `PROTON_LOG` +seh).

**Comet** (imLinguin/comet, Apache-2.0, Rust) emulates the Galaxy client service on
`127.0.0.1:9977`. With Comet running, sign-in succeeds, and achievements, stats, leaderboards and
play time sync to GOG. Heroic runs it around every GOG launch.

**Cloud saves** are not part of Comet. They come from `gogdl save-sync`, which we already ship
(1.3.0). Heroic syncs before launch and after exit.

This reverses the alien-games PRD's "out of scope: cloud saves, playtime, achievements, and
GOG Galaxy multiplayer (comet)". Without Comet, some GOG games do not run at all.

User decisions (2026-11-17):
- **Conflicts are asked, Steam-style.** Before launch the plugin shows *Cloud save is newer /
  Local save is newer* with dates, using the request-file + modal pattern of the DOS version
  picker. **The local save folder is backed up before any download.**
- **Sync is ON by default** for every cloud-enabled GOG game, with a per-game toggle on the game
  page.

## Verified before planning

### The crash (Pocket Max, v0.10.8, 2026-11-17)

| Fact | Evidence |
|---|---|
| Fault is in the game's own code, main thread | winedbg: `page fault on read access to 0x00000004 … anowor (+0x1f31d)`, `movb 4(%eax),%al`, eax=0 |
| The function is the GOG achievement unlock | `anowor.exe` disassembly: the caller chain reaches `push $0x4d9e8c` → `"[GOG] Trying to unlock achievement %s"` |
| Sign-in never completes | log has `[GOG SDK] Signing user in using Galaxy client...` and no success or `SignInGalaxy failed` |
| Not FEX, not Proton-specific | identical on GE-Proton11-12; game renders 1386 frames before the fault |
| The first run's FEX/ntdll segfault is probably the same exception exiting a worse way | core 3411: `libwow64fex BTCpuResetToConsistentStateImpl+36` → `ntdll.so setup_raise_exception+44`. **Unproven.** Limbo's core (Nov 15) has the same signature and is still unexplained. |

### Comet upstream (`_reference/comet`, 46c9152 = v0.4.1)

| Fact | Evidence |
|---|---|
| `--username` required; credentials via `--from-heroic` or explicit token flags | `src/main.rs:45-91` |
| `--from-heroic` reads `$XDG_CONFIG_PATH`(sic, not `_HOME`)`/heroic/gog_store/auth.json`, the **same format gogdl writes** | `src/import_parsers/heroic.rs:17-35`; gogdl `auth.py:116,138` |
| Comet never writes `auth.json`; it exchanges the refresh token per game (`without_new_session=1`) | `src/api/gog/users.rs:5-34` |
| Binds a hardcoded `127.0.0.1:9977` | `main.rs:308` |
| `--quit` exits only after a client **has connected** and then all left, plus `COMET_IDLE_WAIT` (15 s) | `main.rs:346-369`: `if active_clients == 0 && ever_connected`. A game that never connects leaves Comet running forever. |
| Only SIGINT is handled; SIGTERM skips the final per-connection sync | `main.rs:382`, `handlers.rs:306` |
| Offline with an empty local DB: `auth_info_request` panics, so the game sees the same never-completing sign-in | `communication_service.rs:220-227` |
| `comet preload <client_id> <client_secret>` seeds the DB so the game runs offline | `main.rs:172-261` |
| Writes `$XDG_DATA_HOME/comet/gameplay/<client_id>/<user_id>/gameplay.db`, `$XDG_CONFIG_HOME/comet/config.toml` | `src/paths.rs` |
| Release v0.4.1 ships `comet-aarch64-unknown-linux-gnu` and `dummy-service.zip` (x86_64 PE) | `gh release view`; `.github/workflows/build.yml:15-74` |
| Some SDK versions need a `GalaxyCommunication` Windows service to exist (Cuphead, DOOM 3 BFG, Homeworld DoK, KCD) | `dummy-service/`, `docs/wiki/Game-Compatibility.md:62-74` |
| Comet does no cloud saves | no save code in `src/` |

### Cloud saves (gogdl 1.3.0, Heroic 509a34f)

| Fact | Evidence |
|---|---|
| `gogdl save-sync <path> <game_id> --os windows --ts <float> [--name] [--skip-download\|--skip-upload\|--force-*]` | `gogdl/args.py:172-205` |
| Which games and where: `remote-config.gog.com/components/galaxy_client/clients/<clientId>` → `content.Windows.cloudStorage.{enabled,locations}`; default location `%LocalAppData%/GOG.com/Galaxy/Applications/<clientId>/Storage/Shared/Files` (`__default`) | Heroic `gog/library.ts:243-311`, `save_sync.ts:125-134` |
| Location tokens: `<?INSTALL?>`, `<?SAVED_GAMES?>`, `<?APPLICATION_DATA_LOCAL?>`, `_LOCAL_LOW`, `_ROAMING`, `<?DOCUMENTS?>`, then `%VARS%` | `save_sync.ts:136-196` |
| gogdl **only logs conflicts**, then prints a new timestamp anyway | `saves.py:175-178` |
| Download deletes local files missing from the cloud; upload deletes cloud files missing locally | `saves.py:160-173` |
| Empty cloud → uploads, empty local → downloads, **regardless of `--skip-*`** | `saves.py:118-135` |
| The client secret comes from content-system `builds?generation=2` | `saves.py:243-251`. Works for v1-only games: **unverified**. |
| `clientId` is in `goggame-<id>.info` | Another World: `"clientId": "49843177965810898"` |

### Our code

| Fact | Evidence |
|---|---|
| `game-launch` **execs** the chain; nothing of it runs after the game exits | `rootfs/overlay/usr/lib/novadeck/game-launch:435` |
| Optional hook modules fail soft and must never block a launch | `game-launch:47-59` |
| A launch knows only its appid; the plugin writes appid-keyed sidecars from the token-keyed registry in `write_registry` | `shortcuts.py:178-192`, `first_run.py:89-111`, `dos_targets.py:138-182` |
| Store paths are declared once in `store-env` (`NOVADECK_GOGDL_AUTH` = `$STORE_HOME/gogdl/auth.json`) | `rootfs/overlay/usr/lib/novadeck/store-env` |
| Plugin ↔ launch talk through request files, polled every 1 s | `install_requests.py`, `main.py:980-1002`, `novadeck_dostarget.py:44-53` |
| First-run steps run arbitrary argv through the Proton chain, once per build | `first_run.py`, `novadeck_firstrun.py:48-54` |
| Nothing seeds the prefix; the prefix is `compatdata/<appid>`, created by Proton on first launch | `prefixes.py:28-39` |
| Prebuilt-binary package precedent | `packages/inputplumber/prebuilt.pin`; `packages/README.md:17-47` |
| The plugin stores no GOG username | `connect.py` has none; Heroic fetches `embed.gog.com/userData.json` |

## Design

### 1. Package `comet` (`packages/comet/`)

A `prebuilt.pin` for the v0.4.1 release: `comet-aarch64-unknown-linux-gnu` → `/usr/bin/comet`, and
`dummy-service.zip` → `/usr/share/comet/GalaxyCommunication.exe` (x86_64 PE; it runs under
Proton's FEX like any game exe). Added to `PKGS` in `rootfs/customize-base.sh`, then relocked.

Prebuilt rather than a source build. The source build needs edition 2024 (rustc ≥ 1.85, probably
≥ 1.88 for let-chains), the empty `proto/` submodule, and `aws-lc-sys` + `ring` + sqlite C builds
under qemu. Upstream's own CI already builds the aarch64 binary, so building it ourselves gains
nothing. If we ever patch Comet, switch to a source build then.

### 2. GOG identity in the plugin (`connect.py`, `store-env`)

`store-gog-owned` (run as the store user after every sign-in and library sync) fetches
`embed.gog.com/userData.json` through gogdl's session and writes `{username}` to
`NOVADECK_GOG_USER` (`$STORE_HOME/gogdl/user.json`, declared in `store-env`). Root never holds
the token. `galaxyUserId` is not stored: nothing uses it. A failed fetch keeps the stored name and
never fails the listing.

Credentials reach Comet without touching argv: `/proc/<pid>/cmdline` is world-readable. A
private dir `$STORE_HOME/comet/config/heroic/gog_store/auth.json` is a **symlink** to
`NOVADECK_GOGDL_AUTH`. Comet is started with **both** `XDG_CONFIG_PATH` and `XDG_CONFIG_HOME`
pointing at `$STORE_HOME/comet/config`, which keeps working if upstream fixes the variable name.
Comet's own `config.toml` lands in the same private dir.

### 3. Sidecar `galaxy.json` (`py_modules/novadeck_stores/galaxy.py`)

Built in `write_registry` like `dos-targets.json`: appid → `{token, gid, clientId, comet, cloud}`.
- `comet`: true when the install ships a Galaxy SDK DLL (`Galaxy.dll` / `Galaxy64.dll`, any case,
  anywhere in the install). This is selection, not a guard: a game without the SDK never talks
  to 9977.
- `cloud`: `{enabled, locations: [{name, location}]}` from remote-config, fetched at install and
  refresh and cached per `clientId`. `enabled` is the user's per-game toggle, default on (decision
  above). Stored token-keyed in `$STORE_HOME/gogdl/cloud-settings.json` so it survives appid churn.

### 4. Launch-time session (`/usr/lib/novadeck/novadeck_gogsession.py`, called from `game-launch`)

It runs after the DOS swap (so a cancelled launch starts no Comet) and right before exec. It
fails soft, and does two things:
1. **Pre-launch save sync** (phase 3), blocking with a bounded timeout.
2. **One transient systemd user unit, `novadeck-comet`** (`systemd-run --user --collect -p
   KillSignal=SIGINT -p TimeoutStopSec=30`). The name is fixed because port 9977 is one per
   device; a unit left from an earlier launch is stopped first. The unit runs the helper's
   `watch` mode, which takes the `game-launch` pid and start time and opens a pidfd on it.
   After exec that pid **is** the launch chain, and it lives until the game exits. The watcher
   runs Comet (`--from-heroic --username <u>`, **no `--quit`**) as its child. When the pidfd
   fires, it (a) runs the post-exit upload (phase 3), (b) sends Comet SIGINT for its final
   sync and kills it after 15 s. The watcher owns Comet's lifetime, so `--quit`'s "never exits
   if no client connected" cannot happen. The unit is outside the game's process tree, so
   Steam's reaper does not wait on it.
   `NOVADECK_COMET_STARTED` in the launch's env stops a second `game-launch` in the same chain
   (launch options + the in-tool shim) from restarting it.

This puts the after-exit work in a process that does not depend on Decky or the frontend. An
upload missed because the device died mid-game is caught by the next pre-launch sync, since local
is then newer than the stored timestamp.

### 5. Save paths (`/usr/lib/novadeck/novadeck_savepaths.py`, launch side only)

A pure function: location string + install dir + prefix → host path. `<?INSTALL?>` is the
install dir. The others map to `pfx/drive_c/users/steamuser/{AppData/Local, AppData/LocalLow,
AppData/Roaming, Documents, Saved Games}`. `%VAR%` gets the same table. Heroic shells out to
`winepath` inside the prefix; a Proton prefix's layout is fixed, so a table is testable offline
and needs no Wine run.

Only the launch side resolves (changed 2026-11-18 from "plugin module, mirrored into the launch
helper"): the pre-launch and post-exit syncs run in `game-launch`, where
`STEAM_COMPAT_DATA_PATH` names the prefix exactly, and the plugin only carries the raw location
strings (step 2). One copy, no mirror. It refuses, with a reason for the game page: unknown
tokens or variables, the macOS-only `<?APPLICATION_SUPPORT?>`, unanchored paths, other drive
letters, and `..` that leaves `drive_c` or the install folder (a download deletes what the cloud
lacks). Existing levels are matched case-insensitively, as Wine would.

### 6. Sync policy and the conflict picker

Timestamps are stored per `token.location` in `$STORE_HOME/gogdl/save-timestamps.json`.

**Pre-launch**, per location:
- **Only cloud changed**: back up the local folder, then `save-sync --skip-upload`.
- **Only local changed**: nothing. The upload happens after exit.
- **Both changed (conflict)**: write `requests/<appid>.savepick`. The plugin shows a modal with
  cloud and local dates (the `.dospick` pattern) and answers `.saveanswer`:
  - **cloud**: back up, then `--force-download`.
  - **local**: `--force-upload`.
  - **timeout or Decky absent**: keep local, sync nothing.
- **Local empty**: gogdl downloads regardless of the skip flags. That is what we want on a fresh
  prefix, and it goes through the same backup step.

**Post-exit**: `save-sync --skip-download`, then store the printed timestamp.

**Backups** go to `$STORE_HOME/save-backups/<token>/<location>/<iso-time>/`, keeping the last
`SAVE_BACKUPS_KEPT` (a named constant, 5).

**Deciding "who changed" needs gogdl's classification without its side effects.** gogdl has no
dry-run. Phase 3 step 1 picks one of:
- a small local gogdl patch adding `--dry-run`, which prints the classification (and is sent
  upstream as a PR); or
- doing the classification ourselves: list cloud files through the same API, compare with local
  mtimes against `--ts`.

The patch is preferred: one implementation of the rules, not two.

### 7. Dummy Galaxy service (phase 2)

Some Galaxy SDK versions wake a `GalaxyCommunication` Windows service through the SCM and fail
without it (Comet's list: Cuphead, DOOM 3 BFG, Homeworld DoK, KCD). We own none of them.
**Decided 2026-11-18: ship it anyway, for every Galaxy-SDK game** (`comet: true`). This is what
others do (checked 2026-11-18):
- **Heroic** (`launcher.ts:899-947`) does this for EVERY GOG game before each launch, unless
  Comet support is turned off. It copies the stub to
  `C:\ProgramData\GOG.com\Galaxy\redists\GalaxyCommunication.exe` and runs `sc create` once per
  prefix, then `reg add HKLM\SOFTWARE\WOW6432Node\GOG.com\GalaxyClient\paths /v client /d
  "C:\Program Files\GOG Galaxy"` every launch. Failures are logged; the launch goes on.
- **unifideck** (`fixes/galaxy_stub.py`, 2e9981d2) only copies the stub into every GOG prefix:
  no `sc create`, no key.
- Upstream's `install-dummy-service.bat` also runs `update-permissions.exe`, which widens the
  service's DACL. Heroic skips it (Wine does not enforce service DACLs), and so do we.

How it lands here:
- **Pin** `dummy-service.zip` from the same Comet release, `kind: zip`.
- **One `.bat` of ours** does the three actions: copy the stub, `sc create GalaxyCommunication
  binpath= …` unless `sc query` finds it, `reg add`. Wine's `sc` takes `binpath=X` and
  `binpath= X` alike (`programs/sc/sc.c` `parse_string_param`).
- **Staged into the store home.** A first-run step runs inside the game's SLR container, where
  the host's `/usr` is not `/usr`. The support installers work because they sit under `/home`. So
  the plugin copies the stub and the `.bat` to `$STORE_HOME/galaxy-service/` as the store user
  whenever it writes `first-run.json`, and the step runs the staged `.bat`.
- **A first-run step** for every installed Windows GOG entry with the Galaxy SDK, after its
  support installers. The entry id gains `:galaxy-service`, so a prefix that already ran its
  support installers runs the set again with the service step in it.
- `proton run <host .bat>` works the way `wine <.bat>` does (HW 2026-11-18, phase 2 gate).

## Steps

Four phases. Each of the first three ends in a HW gate on the Pocket Max (where Another World is
installed), or on the Pocket FIT for the dummy-service title. One commit per step.

### Phase 1 — Comet runs around a GOG launch (fixes Another World)

1. **Read before building.** Find what Comet does with `--username`. Confirm that a process in
   the pressure-vessel container reaches host `127.0.0.1:9977`, either by reading
   pressure-vessel's network handling or by a 2-minute HW check with `nc -l 9977` and the game.
   Record both in this plan.
   - **`--username`, read 2026-11-17:** Comet uses it only as the display name it returns to the
     game in the AUTH_INFO response (`communication_service.rs:238`, `content.set_user_name`). Any
     value works, but a game showing names (leaderboards, multiplayer) shows this one, so the real
     GOG username from `userData.json` stays in the plan.
   - **Container loopback, read 2026-11-18** (steam-runtime-tools d14f4cf): the game's bwrap
     shares the host network namespace, so `127.0.0.1:9977` inside is the host's.
     `pv_wrap_share_sockets` sets `FLATPAK_CONTEXT_SHARED_NETWORK` (`wrap-setup.c:124`). The
     only unconditional `--unshare-net` is in `regenerate_ld_cache`, the ldconfig helper
     (`flatpak-run.c:3009`). The conditional one in `flatpak_run_add_environment_args`
     (`:428`) is reachable only from `flatpak_run_app`, which is under `#if 0` (`:3207-4114`).
     The step 6 HW gate confirms it on the device: the game passing the 11 s mark needs the
     connection.
2. **`packages/comet`**: `prebuilt.pin` + install layout; add to `customize-base.sh`; `make
   relock`; `make verify-lock`.
3. **GOG identity** (TDD): `user.json` fetch on login and refresh. Tests: written on login,
   refreshed on refresh, a failed fetch keeps the old file. **Done** (`test-store-install.sh`,
   `test-store-cli.sh`). "No username → Comet is not started (logged, launch proceeds)" moves to
   step 5, where the launch reads it.
4. **`galaxy.py` sidecar** (TDD, `tests/test-store-galaxy.sh`): SDK detection (case, nested dir,
   absent); `clientId` from `goggame-<id>.info`; rows follow registry appids across churn;
   `write_registry` regenerates it. **Done.** Rows are `{token, gid, clientId, comet}` for every
   installed GOG Windows entry; `cloud` joins them in phase 3 step 2. The walk does not follow
   symlinks (root walks a user-owned tree).
5. **`novadeck_gogsession.py` Comet start + watcher** (TDD, extends `test-store-launch.sh`):
   - no row → no-op;
   - row with `comet` → the `systemd-run` argv (stubbed) carries SIGINT and the XDG env, and no
     token appears in argv;
   - the symlinked auth dir is created;
   - watcher stops the unit when a stand-in pid exits;
   - every failure is soft (launch still execs);
   - ordering: after the DOS swap, right before exec.
   **Done** (`test-store-launch.sh`, 27 checks; the watcher is exercised with real processes).
   The step 6 HW gate's unit check is `systemctl --user status novadeck-comet`.
6. **HW gate** (Pocket Max, Another World):
   - the game passes the first achievement unlock (where it died; not a fixed time);
   - that achievement shows on the GOG profile;
   - `systemctl --user status novadeck-comet` is up mid-game and gone shortly after exit;
   - Steam shows the game stopped when it stops;
   - a non-Galaxy GOG game starts no Comet;
   - **offline launch**: what happens (expected: the same crash; this decides whether phase 4 is needed).
   **First four PASSED 2026-11-18** (dev card BUILD_ID 20261118T165200Z, fresh card, Proton CachyOS
   11.0). From the journal:
   - unit started 21:03:36.75, Comet listening at 21:03:37.17;
   - the game identified as clientId 49843177965810898 (the `galaxy.json` value) at 21:04:28;
   - `AW_ACH_SURVIVOR` unlocked and uploaded at 21:06:35-48, and it shows on the GOG profile;
   - game socket closed 21:07:37.85, unit ended 21:07:38.32 (SIGINT path, no "killed");
   - Steam's `Game process removed` for ProcID 4249 (the watched pid) came in the same second.
   **Non-Galaxy check PASSED** with A New Beginning: Final Cut (no `galaxy*.dll`; its row has
   `comet: false`). While `anb.exe` ran: no unit, no `comet` process, nothing on 9977, no
   `game-launch: comet:` line in the session log, and no Comet line in the journal.
   **Offline launch: no crash** (Wi-Fi off 21:32:10, game 21:32:19-21:34:23):
   - Comet's token fetch failed (`There was an error getting the access token`), and Comet
     still served the game from its local `gameplay.db` (created by the earlier online run);
   - the game called a NEW unlock, `AW_ACH_1ST_SHIELD`, and kept running. That is the call
     that used to crash, so offline works once Comet has run online for that game;
   - Comet panicked on the way out (`notification_pusher.rs:70`, `Unable to get notification
     pusher connection`). That is upstream: offline, the pusher task is still retrying when
     the SIGINT shutdown cancels it, and it `expect`s a connection. It fires on the
     cancellation, so it shows the watcher's SIGINT arrived 0.4 s after the game's socket
     closed. A panic in a spawned task does not end the process (release profile keeps
     unwind). The unit was gone and nothing held 9977 afterwards.
   **Phase 4 is not needed for this case.** Untested: the first ever launch of a game while
   offline, with no `gameplay.db` yet.
   `First shield`, unlocked offline, uploaded on the next online launch (21:36:56 start,
   `Uploaded achievements` 21:37:15, before any new unlock), and it shows on the GOG profile.
   **Phase 1 HW gate: PASSED.**

### Phase 2 — dummy Galaxy service (for every Galaxy-SDK game, design §7)

1. **Pin** `packages/comet-dummy-service/prebuilt.pin` (`kind: zip`) + relock; the lock diff is
   that one row.
2. **The `.bat`, the staging and the step** (TDD in `test-store-galaxy.sh` and the first-run
   checks in `test-store-launch.sh`): a Galaxy game gets the step and the `:galaxy-service` id; a
   non-Galaxy game does not; staging copies only when the staged file differs; a failed stage
   writes no step that would run a missing `.bat`.
3. **HW gate** (we own none of the four listed titles, so Another World stands in):
   - the step's result is 0 in the prefix's `novadeck-first-run.json`;
   - the prefix's `system.reg` holds `Services\GalaxyCommunication` (its `ImagePath` the
     redists path) and `GalaxyClient\paths` `client`;
   - Another World still runs, and Comet still logs its client and an unlock.
   **PASSED 2026-11-18** (dev card BUILD_ID 20261118T213514Z, fresh card):
   - the plugin staged both files in `<store home>/galaxy-service/`, and `first-run.json` named
     the staged `.bat` under id `gog:1207658845:56925654866982961:galaxy-service`;
   - `proton run <host .bat>` works: the session log has `galaxy-service.bat -> 0`, and the
     prefix marker records result 0;
   - `system.reg` has `Services\GalaxyCommunication` with `ImagePath` the redists path and
     `Start` 3 (demand), plus `Wow6432Node\GOG.com\GalaxyClient\paths` `client`; the stub is at
     `drive_c/ProgramData/GOG.com/Galaxy/redists/`;
   - Comet identified the client, and `AW_ACH_WARRIOR` and `AW_ACH_ESCAPE_WATER` unlocked and
     uploaded.
   Not shown: that a game which needs the service now runs (we own none of the four).

### Phase 3 — cloud saves

1. **Classification**: decide gogdl `--dry-run` patch vs own classifier (design §6). If patch:
   `packages/gogdl` patch + relock + upstream PR.
   **Decided 2026-11-18: the patch.** Done: `packages/gogdl/patches/0001-save-sync-add-dry-run.patch`
   (gogdl 1.3.0-2.1). `save-sync … --dry-run` writes one JSON object on stdout and changes
   nothing, not even a missing local dir:
   `{"action": "upload|download|conflict|none", "local": {"files": N, "newest": ts|null},
   "cloud": {"files": N, "newest": ts|null}, "updated_local": [...], "updated_cloud": [...],
   "not_existing_locally": [...], "not_existing_remotely": [...]}`.
   The action is gogdl's own, including its empty-side rules; `--skip-*`/`--force-*` are not
   applied. `newest` is a Unix timestamp, for the picker's dates. `packages/gogdl/check-dry-run.py`
   (10 checks, network stubbed) runs from `build()`, because the overlay build passes
   `--nocheck`; it fails on unpatched 1.3.0. Upstream PR: not opened yet (the user's call).
   Upstream main (1.4.0) changed `saves.py` only by lint since 1.3.0, so the patch ports as is.
   **On HW 2026-11-18** (Pocket Max, package installed by hand on the dev card): Another World's
   remote-config gives one location, `saves` = `<?DOCUMENTS?>/Another World`, which is
   `pfx/drive_c/users/steamuser/Documents/Another World` (`progression.dat`,
   `AnotherWorldUserDef.xml`). `save-sync … --name saves --ts 0 --dry-run` as the store user:
   rc 0, `action: upload`, local 2 files, cloud 0 files (nothing was ever uploaded), and the save
   dir unchanged. gogdl DID rewrite `auth.json` (it adds the game's client id as a key, still
   deck 0600), as any gogdl call that fetches a game's credentials does. So the pre-launch dry
   run and Comet both touch `auth.json`, and their order matters (Risks: token rotation).
2. **remote-config fetch + `cloud` in `galaxy.json`** (TDD): enabled/disabled/no locations →
   `__default`; cache per `clientId`; the toggle persists per token.
3. **`save_paths`** (TDD): every `<?VAR?>` token and `%VAR%`, case, a location that resolves
   outside the prefix or install is refused.
   **Done** (`novadeck_savepaths.py`, `tests/test-store-savepaths.sh`, 23 checks; Another World's
   real `<?DOCUMENTS?>/Another World` is one of them).
4. **Pre-launch sync + backups** (TDD, gogdl stubbed): each row of design §6. Backup rotation.
   Timeout → launch proceeds. Prefix missing (first launch): see step 5.
5. **First launch with no prefix**: decide by test on HW whether writing into
   `pfx/drive_c/users/steamuser/…` before Proton creates the prefix survives Proton's prefix
   setup. If it does not, the download runs as a first-run step (Proton creates the prefix for
   the step) instead of before the chain.
6. **Conflict picker**: `.savepick` / `.saveanswer` spool + modal (mirror the DOS picker),
   including the dates. TDD for the backend half.
7. **Post-exit upload** in the watcher; timestamp stored.
8. **Game page toggle**: *Cloud saves: on/off*, plus the last sync time.
9. **HW gate** (Another World, or any cloud-enabled GOG title):
   - play, save, exit → the save is in the cloud (`gogdl save-sync` from the host lists it);
   - drop the prefix from the game page and relaunch → saves restored before the game starts;
   - make both sides change → the picker appears and both answers do what they say, and the
     backup exists;
   - offline launch → no wait beyond the timeout;
   - toggle off → no sync either way.

### Phase 4 — offline achievements (decided by the phase 1 offline result)

`comet preload <client_id> <client_secret>` at install and refresh, so a Galaxy game runs
offline. The client secret comes from the same content-system call gogdl uses. Skip this phase if
phase 1 shows the game runs offline anyway.

### Bookkeeping

- PRD: move Comet and cloud saves from out-of-scope into scope, citing the Another World crash.
- A GitHub issue tracks the work, linking this plan.

## Risks / open questions

- **Container loopback to 9977**: resolved from source (phase 1 step 1). pressure-vessel shares
  the host network namespace.
- **No readiness wait for Comet.** It makes no network call between reading credentials and
  binding 9977 (`main.rs:109-306`; the peer-library fetch is a spawned task), and Proton's
  startup under FEX takes seconds. A game that connects before Comet listens has not been seen;
  add a wait only if one is. On HW: Comet listened 0.4 s after the unit started, and Another
  World connected 52 s later (fresh prefix).
- **Comet's data dir stays at `~/.local/share/comet/`** (decided 2026-11-18: not moved into
  the store home). It holds `gameplay/` (the local achievement DB, which is what lets a game run
  offline) and `redist/peer/` (102 MB, four msvc builds of the GalaxyPeer component, fetched on
  the first start). The later launches did not log a second download.
- **The exec'd chain pid lives as long as the game**: assumed (steam-launch-wrapper and the
  reaper wait for their children). If a chain parent exits early, Comet stops mid-game.
  Confirmed on HW for Another World: the unit stayed up the whole game and ended with Steam's
  `Game process removed` for the same pid.
- **gogdl's client-secret lookup for v1-only games** (`builds?generation=2`): unverified. A game
  where it fails gets no cloud sync, and the game page should say why (no silent drop).
- **Token rotation**: gogdl may rotate the refresh token when it refreshes. Comet reads
  `auth.json` once at start, after the pre-launch gogdl call, so the order in design §4 matters.
- **Galaxy multiplayer**: Comet hands the game a host path to a downloaded GalaxyPeer DLL; how
  Wine resolves it is unverified. Out of the HW gates; noted, not promised.
- **Comet vs specific games**: Wolfenstein TNO crashes, STONKS-9800 does not connect (upstream
  compat table). There is no per-game opt-out in this plan; add one only when a title we test
  needs it.
- **Epic** has cloud saves via legendary; not in this plan.
- **The FEX/ntdll segfault and Limbo's identical core** stay open and separate from this work.
