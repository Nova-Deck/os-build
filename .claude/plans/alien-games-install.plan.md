# Plan: Alien games — install and uninstall

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 3 — Install and uninstall
**Complexity**: Large
**Depends on**: milestone 1 (the CLIs) and milestone 2 (signed-in accounts), both HW-gated

## Summary

An owned Epic or GOG title downloads to a volume the user picks, survives an interruption — a
stop, a network cut, a reboot — by resuming rather than restarting, and uninstalls leaving nothing
behind. Both CLIs already download and resume; what is missing is everything around them: where a
game goes, a download that outlives the QAM, an install record gogdl does not keep, and an
uninstall gogdl does not have.

The surface is milestone 7's. This milestone is the backend, driven on hardware through its own
Python API, the same way milestone 2's status code was checked.

## Verified before planning

| Fact | Evidence |
|---|---|
| legendary resumes by re-running the same install | per-game resume file in `<config>/tmp/<app>.resume`, one line per completed file (`core.py:1482-1486`, `downloader/mp/manager.py:127-158`); removed on success (`:917-922`) |
| legendary knows what it installed and uninstalls itself | `installed.json` in its config; `legendary uninstall <app> --skip-uninstaller -y` |
| legendary with `-y` skips prerequisite installers | `_handle_postinstall(..., skip_prereqs=args.yes)` (`cli.py:1145`) — redistributables become milestone 6's problem, not a prompt nobody can answer |
| legendary checks free space itself | refuses unless `--ignore-free-space` (`cli.py:2955`) |
| **gogdl keeps no install record and has no uninstall** | `download` / `repair` / `update` only (`args.py:55`); Heroic tracks installs in its own state |
| **gogdl writes build manifests OUTSIDE our store tree** | `$XDG_CONFIG_HOME/heroic_gogdl/manifests/<id>` unless `GOGDL_CONFIG_PATH` is set (`constants.py:15-31`). Same trap legendary had in milestone 2 |
| gogdl's manifest is written **only on success** | `v2.py:265-273`: `if cancelled: return` before the write — so "manifest present" is a truthful completion signal |
| gogdl resumes from `<game dir>/.gogdl-resume` | `task_executor.py:25, 146-179` |
| **A gogdl fatal error DELETES the resume file** | `shutdown()` removes it (`task_executor.py:585-587`) and runs on the fatal path (`:496-498`); only SIGINT/SIGTERM (`handle_sig`, `:461-465`) leaves it. A writer failure is fatal (`:792-795`). What a network cut does is **not known** — chunk failures retry 5x per worker and log a warning (`workers/task_executor.py:140-184`, `managers/task_executor.py:736`) |
| gogdl appends the game's own folder name to `--path` | `v2.py:282-283` (`installDirectory` from build meta) |
| gogdl's out-of-space exit is 2 | `v2.py:257-259` |
| legendary stops cleanly on SIGINT, not SIGTERM | it is written for CTRL-C ("CTRL-C and resume it using the same command", `cli.py:1060`); `systemctl stop` sends SIGTERM by default |
| GOG library listing is not a gogdl command | `api.py:66-68` calls `embed.gog.com/user/data/games` internally; milestone 1 hit the same API by hand |
| Cards mount through udisks as the user | `/run/media/<user>/<label>`, owned by `deck` (`rootfs/overlay/usr/lib/novadeck/storage/automount.sh`) |
| The CLI units currently force `UMask=0077` | `cli.py _as_user` (milestone 2, Task 7) — right for tokens, wrong for game files |

## Design

**Where games go — answers the PRD's open question.** Per volume, `<volume>/Games/<store>/<game
folder>`:

- The volumes are the user's home (`/home/deck`) and every card udisks has mounted under
  `/run/media/deck/`. That is the same set Settings > Storage shows, so "choose a location" means
  choosing a drive, never typing a path.
- `Games/` sits outside Steam's own tree on purpose: Steam manages `steamapps/`, and a Steam reset
  or a library removal should not take store games with it.
- A card moved between devices keeps its label and so its path. A card that is not inserted leaves
  its games recorded but unavailable, and nothing is deleted on its behalf.

**The download outlives the plugin.** Each install is a detached transient unit, not a child of
the plugin: `systemd-run --unit=novadeck-store-install -p User=deck -p KillSignal=SIGINT
-p UMask=0022`. One consequence of the milestone-2 FEX finding holds here too: host PID 1 starts
the CLI natively. More:

- **One install at a time**, enforced by the fixed unit name. A queue is milestone 7's business if
  it wants one.
- **`KillSignal=SIGINT`**, because legendary's clean stop is CTRL-C, and gogdl treats both the
  same. A stop is the one interruption both CLIs are known to resume from.
- **`UMask=0022`**, not the token umask: game files are not secrets, and a `0700` game tree
  would be unreadable to anything but `deck`.
- Output goes to a log file in the store tree, which progress is parsed from. Not the journal.

**Completion is read from artifacts, never from exit status** (milestone 2's rule, and it holds):

| | Installed | Interrupted (resumable) |
|---|---|---|
| Epic | the app is in legendary's `installed.json` | `tmp/<app>.resume` exists, or our record says installing |
| GOG | gogdl's manifest exists **and** our record says installed | our record says installing and the manifest does not exist |

**Our own install record** (`<store home>/installs.json`, written as `deck`) holds store, id,
title, the exact install path and the state. For GOG it is the only record there is. For Epic it
duplicates what legendary knows, and it exists only so that an interrupted Epic install, which
legendary does not record, has a path to resume into and to clean up.

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Running a CLI as the user | `apps/decky/novadeck-stores/py_modules/novadeck_stores/cli.py:_as_user` | `systemd-run` as `deck`, `--description` not argv, stdout never captured. Grows a detached mode and a umask parameter; not a second helper |
| Declared paths | `rootfs/overlay/usr/lib/novadeck/store-env` | One declaration; `paths.py` asks and never repeats it |
| Reading files root does not own | `status.py:_readable_json` | `O_NOFOLLOW \| O_NONBLOCK`, regular file, owned by the store uid |
| Verdict from artifacts | `main.py _run_cli` + `status.py` | Exit status to the log only |
| Per-store lock | `main.py _LOCKS` | An uninstall must not race a status read or a refresh |
| Offline tests | `tests/test-store-cli.sh` | `subprocess.run` faked and argv asserted; fixture trees in a tempdir |

## Files to Change

| File | Action | Why |
|---|---|---|
| `rootfs/overlay/usr/lib/novadeck/store-env` | UPDATE | Declare `GOGDL_CONFIG_PATH` and the install record path |
| `apps/decky/novadeck-stores/py_modules/novadeck_stores/cli.py` | UPDATE | `_as_user` gains detached + umask; `GOGDL_CONFIG_PATH` in the unit env; install / stop / uninstall argv |
| `.../novadeck_stores/library.py` | CREATE | Owned titles per store: `legendary list --json`; the GOG owned-games API plus product names |
| `.../novadeck_stores/locations.py` | CREATE | The candidate volumes, their free space, and the per-store game root |
| `.../novadeck_stores/installs.py` | CREATE | The install record, the state table above, progress parsing, and the uninstall path guard |
| `apps/decky/novadeck-stores/main.py` | UPDATE | Backend methods: `owned`, `locations`, `install`, `install_status`, `stop_install`, `uninstall` — callable, not yet surfaced |
| `tests/test-store-cli.sh` | UPDATE | Every decision above, offline |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 3 row; answer "where do games install" |

## Tasks

### Task 1: gogdl's second path, and the record's
- **Action**: `store-env` emits `GOGDL_CONFIG_PATH=<store home>/gogdl` and
  `NOVADECK_STORE_INSTALLS=<store home>/installs.json`; `_cli_setenv` passes `GOGDL_CONFIG_PATH`
  to every gogdl call, auth included.
- **Validate**: the suite asserts both are under `/home/deck` and reach the unit env; on hardware,
  no `~deck/.config/heroic_gogdl` after an install.

### Task 2: What the user owns
- **Action**: `library.owned(store)` → `[{id, title, installable}]`. Epic: `legendary list --json`
  run as `deck`, stdout captured (the game list, which carries no token). Ubisoft-activated titles
  come back `installable: False` (milestone 1's finding). GOG: the owned-games API plus product
  titles, made by a helper run as `deck` that reads the token itself. Root never handles the GOG
  token.
- **Why here**: the PRD gives "browse" to milestone 7, but no milestone owns the data. You cannot
  install an owned title without knowing its id, and GOG has no CLI that lists one.
- **Validate**: fixture JSON for both stores; on hardware, both real libraries list (55 Epic /
  2 GOG at milestone 1).

### Task 3: Where it can go
- **Action**: `locations.volumes()` → home plus each real directory under `/run/media/deck/`,
  skipping `automount.sh`'s `novadeck-*` compatibility symlinks, each with free bytes;
  `game_root(volume, store)`.
- **Validate**: fixture tree with a symlink, a plain dir and a missing card.

### Task 4: Install, detached
- **Action**: `install(store, id, volume)`:
  1. Refuse if the unit is already active.
  2. Size from `legendary info --json` or `gogdl info`, then refuse when free space is short.
     The CLIs' own checks stay as the backstop, but they fail after a slow start and with two
     different messages.
  3. Record `installing` with the exact path.
  4. Start the unit.
  - Epic: `legendary install <app> --base-path <root> -y --skip-dlcs`.
  - GOG: `gogdl --auth-config-path … download <id> --platform windows --path <root> --skip-dlcs`.
  - Windows builds only in this milestone. The native-Linux GOG build is milestone 6's second
    launch form, and it arrives as a choice there.
- **Validate**: the suite asserts argv, `KillSignal=SIGINT`, `UMask=0022`, the fixed unit name,
  and no `--pipe`/`--wait` (detached).

### Task 5: Status, stop, resume
- **Action**: `install_status()` joins the unit's `ActiveState`/`Result`, the last progress line
  (both CLIs log `= Progress: NN.NN`), and the state table → `downloading` / `interrupted` /
  `installed` / `failed`, with a percentage. `stop_install()` stops the unit. Resume is
  `install()` again on the recorded path: both CLIs pick up their own resume file. Reaching
  `installed` flips the record.
- **Validate**: state-table cases from fixture trees; the progress parser against real log lines
  (captured at the HW gate and added as fixtures).

### Task 6: Uninstall
- **Action**: Epic: `legendary uninstall <app> --skip-uninstaller -y`, then drop the record. GOG,
  and any interrupted install: `rm -rf` of the recorded path **as `deck`**, then gogdl's manifest,
  then the record.
- **The path guard is the whole task.** `gogdl` puts the folder name from build meta under our
  root. An empty or `..` name, or a record edited by anything running as `deck`, must never become
  `rm -rf <volume>/Games` or `/home/deck`. Delete only a path that is exactly one component below a
  game root the locations module produces, that exists as a directory, and that is not a symlink.
  Anything else is refused and logged, and the record stays.
- **Validate**: the suite drives the guard with `""`, `.`, `..`, a symlink, a path in another
  store's root, and a path on a volume that is no longer mounted.

#### Tasks 1–6 — built 2026-09-26, NOT yet HW-gated

`tests/test-store-install.sh` (72 checks, in `make test`) covers each task. Code:
`library.py`, `locations.py`, `installs.py`, `store-gog-owned`, `cli.py` (detached units,
`capture`, `write_as_user`), and `main.py`'s `owned` / `drives` / `install` / `install_status` /
`stop_install` / `uninstall`.

**Deviation from Task 5:** status is **read-only**. It derives each state from the CLIs' artifacts
on every call instead of writing completions back, so it takes no lock and a progress poll never
waits behind an uninstall.

**Security review, 2026-09-26: one HIGH and two MEDIUM, all fixed.**
- **HIGH:** `legendary uninstall` deletes the path in *its own* `installed.json`, which any `deck`
  process can edit and which the guard never saw. It now runs with `--keep-files`, dropping only
  its record, and the files go through the guarded `rm`.
- **MEDIUM:** a store root swapped for a symlink kept the path string valid and landed the delete
  in another tree. The guard now requires `realpath(path) == path`.
- **MEDIUM:** a status poll queued behind a 15-minute `rm`. Fixed by the read-only status above.
- **LOW:** control characters are refused in ids and folder names, since a newline would forge a
  `systemctl show` line. GOG ids are cast to `int` before they go into a URL.

### Task 7: Hardware gate
- **Action**, on a dev card with both stores signed in, driving the backend over SSH:
  1. Install a small title per store to the card, and a second to the home volume.
  2. Stop one mid-download (`stop_install`) and resume it.
  3. **Network cut mid-download, per store.** Cut at the router, or with an rfkill that re-enables
     itself: an rfkill on wlan drops the SSH session driving the test. Record what each CLI
     actually does (fails, stalls, or retries through), and whether the resume file survived.
  4. Reboot mid-download, then resume.
  5. Uninstall all of them.
  6. After each step, `stat` the tree: `deck`-owned, files `644`/`755`, nothing in
     `~deck/.config/heroic_gogdl`, nothing left after uninstall.
- **The network cut is the gate's real question.** If gogdl treats it as fatal and deletes its
  resume file, then "resumes after an interruption" needs an answer of ours: stop the unit
  ourselves before gogdl gives up, or accept a re-verify pass. Decide on the measurement, not
  before it.

#### Task 7 — ran 2026-10-20 on the Pocket FIT, home volume only

Driven over SSH against the live modules (`installs.*` / `library.*`), from the branch rebased
onto main that day. Epic: Breathedge (7.7 GB). GOG: The Witcher: Enhanced Edition (15 GB). The
cut was a self-reverting transient unit (`rfkill block wlan; sleep 75; rfkill unblock wlan`) —
it drops the driving SSH session either way; the observation happens after reconnect.

**The measurement: a 75 s network cut is fatal to NEITHER CLI.**
- legendary's workers retry unthrottled on `NameResolutionError` and ride it out; the download
  recovered on its own.
- gogdl: the unit stayed active, `.gogdl-resume` was KEPT, and the download recovered alone
  ~30 s after wlan returned. The fatal path never triggered, so nothing extra is designed around
  it. **Bound of the measurement:** 75 s sits inside the per-worker retry budget; a multi-minute
  outage was not measured and may still reach the fatal path that deletes the resume file.

**Every other step passed as designed:**
1. Stop mid-download → `interrupted`, resume file kept; resume continued, not restarted.
2. Reboot mid-download → unit gone, record `installing`, status derived `interrupted`; the
   resume logged `Attempting to continue the download` with the remaining-bytes total shrunk —
   that line is the resume proof (the percent counter restarts per run; cosmetic).
3. Both titles completed; verdicts artifact-backed. gogdl writes its manifest at
   `$GOGDL_CONFIG_PATH/heroic_gogdl/manifests/<id>` — it nests `heroic_gogdl/` under the env
   var, and `completed()` reads exactly that path.
4. Uninstall left nothing: trees, gogdl manifest, records, and legendary's `installed.json` all
   empty afterwards.
5. Sweeps after each step: `deck`-owned, `644`/`755`, nothing in `~deck/.config/heroic_gogdl`,
   no signed-URL query tokens in the install log, resume files removed on success. The record
   saying `installing` until uninstall is the read-only-status deviation working as designed.

**Open from the gate:**
- The card-volume half of step 1 did not run, and cannot yet: the dev card occupies the only
  slot, so a second volume needs the OS installed internally first ([[internal-install]] work).
  Volumes are re-read per call, so the leg runs unchanged once a card can be inserted.
- legendary's unthrottled retry wrote a 316 MB `install.log` during the 75 s cut. The log
  truncates per run (`>"$0"`), so it is bounded — a milestone-7 concern (the progress parser
  reads that file's tail; disk churn during long cuts).
- `library.owned("epic")` returned ZERO `installable: False` titles, but AC Syndicate
  (Ubisoft-activated) is in the list — milestone 1 expected it flagged. Re-check what
  legendary's list carries against what `epic_titles()` reads.

The live GOG products API matches what `store-gog-owned` assumes (both real titles listed with
correct ids); that open verification from milestone 1 is closed.

## Validation

```bash
bash tests/test-store-cli.sh          # every decision above, offline
source dev.env && make test           # all suites
source dev.env && make sdcard         # the card the gate runs on
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A network cut is fatal to gogdl, which then deletes its own resume file | Medium | Measured at the gate before anything is designed around it; SIGINT is the known-good stop |
| `rm -rf` of the wrong directory | Low, catastrophic | Task 6's guard, as `deck` so it cannot reach outside the user's files, with the refusal cases tested |
| A reboot mid-download leaves the record `installing` with no unit | Certain | That is the `interrupted` state by design, and resume is the same call |
| A detached unit is invisible to the plugin after a reload | Low | Status reads the unit by its fixed name, not a handle we hold |
| The SSH-driven gate misses a FEX-only failure (milestone 2's lesson) | Medium | Every CLI runs natively through `systemd-run`, which milestone 2 proved from inside the loader. The plugin path proper is milestone 7's walkthrough |
| legendary logs a signed CDN URL into the install log | Low | The log is in the `0700` store tree. The gate greps it for query tokens |
| The card is removed mid-install | Medium | Surfaces as a failed unit and an unavailable volume. The record stays, and nothing is deleted |
| Epic titles that need a Ubisoft or EA launcher install and then never run | Medium | `installable: False` where legendary says so; the rest is milestone 6's launch question |

## Acceptance

- [x] Both stores list the real account's owned titles (55 Epic / 2 GOG, 2026-10-20)
- [x] A title per store installs to a chosen volume, `deck`-owned, `644`/`755` — home volume
      only; the card leg is still owed (no card inserted at the gate)
- [x] A stop, a network cut and a reboot each resume rather than restart — measured 2026-10-20;
      the 75 s cut is fatal to neither CLI (see Task 7's bound)
- [x] Uninstall leaves no game files, no gogdl manifest and no record
- [x] The path guard refuses every case in Task 6 (offline suite, in `make test`)
- [x] `make test` green (post-rebase, 2026-10-20)
