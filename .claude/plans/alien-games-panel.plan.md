# Plan: Alien games — library-first surface (Quick Access + Steam library)

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 7 — the surface that wires connect → browse → install → play
**Complexity**: Large (it is the capstone, and it adjusts the milestone-4/6 ownership model again)
**Depends on**: milestones 1–6 (all built; 1–5 + M6-Windows HW-gated).

## REVISION 2 (2026-10-21) — the surface moves INTO Steam's pages; supersedes the surface below

**Why.** The first HW walkthrough (Pocket FIT, DOOM 64) proved the BACKEND end to end — sync →
55 tiles, tile press → install, swap → model-B entry, Proton launch, artwork — but the user judged
the SURFACE unintuitive: games sit in a collection, not a tab, and "Install" is pressing Play on a
tile that silently starts a download, with progress only in the QAM. Re-reading
`_reference/unifideck` showed the original plan cited unifideck's FALLBACK, not its design:

| unifideck (primary path) | where | what revision 1 built instead |
|---|---|---|
| Store **library tabs** spliced into `/library` (routerHook patch, `afterPatch` down to the memoised tabs owner, intercept its `useMemo`); collections only when TabMaster blocks the injection, and opt-in because Steam Cloud syncs them account-wide | `src/lib/steam-bridge/library-patch.ts`, `collection-manager.ts` | always-on `[NovaDeck]` collections |
| The **game page's Play row replaced** for its own shortcuts: Install + size + storage picker / progress + pause/cancel / Play | `src/views/AppDetailsPatch.tsx` (`/library/app/:appid` renderFunc `afterPatch`, anchored on `appDetailsClasses.InnerContainer` / `playSectionClasses.Container`, gate appid > 2e9), `src/components/play/*` | Play on a stub tile = install, toast, QAM progress |

**Revised surface.**
- **Game page (the install surface).** For a registry-owned entry only (registry membership, the
  task-1 rule — never unifideck's appid>2e9 alone): not installed → **Install** + download size +
  drive; downloading → progress + Stop; paused → Resume / Remove; installed → Steam's own native
  Play (the model-B entry, untouched) + an Uninstall action. The stub stays as the FALLBACK when the
  patch cannot apply (a Steam update moved an anchor): pressing Play still installs.
- **Library tabs (the browse surface).** `Epic` / `GOG` tabs (owned games, installed or not) in
  `/library`. Collections become OPT-IN (a QAM toggle), default OFF — which also settles the
  Steam-Cloud question left open above.
- **QAM panel** unchanged in role: accounts, Sync, install drive, a downloads overview.
- **Backend unchanged**: registry, sync, request spool, swap, drive rules, artwork carry over. New
  calls only: install size per game (cached, `legendary info` / `gogdl info` already parsed by
  `installs.parse_info`), and a per-appid state read for the page.

**Biggest risk: React-tree patches on the arm64 client.** Both surfaces depend on SteamUI internals
(class-name anchors, route tree shapes, a React `useMemo` intercept for tabs). They break on client
updates, and our arm64 client already skews from x86 (no GetAvailableCompatTools, mis-packed atoms).
So **R0 is a probe, before any build**: on the Pocket FIT, read-only except a no-op router patch
that is removed again —
- `appDetailsClasses.InnerContainer`, `playSectionClasses.Container` resolve, and those classes are
  present in the DOM of a NovaDeck game's page;
- `/library/app/:appid` route tree carries a `renderFunc` (the AppDetailsPatch hook point);
- `/library` route tree reaches a component whose tabs array is reachable the way library-patch.ts
  walks it;
- the decky routerHook can add+remove a patch cleanly on this client.
Each anchor that fails changes the shape of R1/R2 (e.g. game page works, tabs do not → tabs via
TabMaster-style collections only); the plan is re-cut on the probe result, not built around hope.

**R0 RESULT (2026-10-22, Pocket FIT, client build 1791918634, Decky v3.3.0) — both surfaces are
feasible; the game page must use unifideck's FALLBACK anchor.** Driven over CDP with
observation-only router patches (every wrapper returns the original result; the useMemo intercept
passes fn/deps through), added and removed again (`routerState._routePatches` empty after);
library home rendered normally throughout. Scripts: session scratchpad `probe_static.js`,
`probe_routes.js` (diagnostic, not shipped).

| Check | Result |
|---|---|
| `playSectionClasses` / `appDetailsClasses` / `appDetailsHeaderClasses` resolve via the @decky/ui webpack lookup | all found (2614 modules) |
| `/library/app/:appid` route tree has a `renderFunc` | yes (function) |
| `appDetailsClasses.InnerContainer` in a NovaDeck game page's DOM (DOOM 64) | yes (1) |
| `playSectionClasses.Container` in that DOM — unifideck's PRIMARY insertion anchor | **NO (0)**; the play bar's own classes are present (`PlayBarLabel`, `PlayBarDetailLabel`, `MenuButton`, `ControllerConfigButton`, …) |
| Fallback anchors `appDetailsHeaderClasses.TopCapsule`, `appDetailsClasses.Header` | both present (1 each) → insert after the header, as unifideck's `findPlaySectionInsertIndex` already falls back to |
| `/library` chain: route child fn → level-1 fn → level-2 memo with `.type.type` fn → React dispatcher reachable | all yes |
| tabs `useMemo` result | tuple; ids `SteamOSCompatible, AllGames, Installed, Favorites, Collections, DesktopApps, Soundtracks` |
| `AllGames` template carries `Library_FilteredByHeader`; collections app filter (`Matches`) in deps | both yes |

Consequences for R1: anchor on the header (TopCapsule/Header), not on play `Container`; the
native Play row is identified by the play-bar classes above (to hide it on not-installed games).
Note these are DOM-level checks of what unifideck matches on React props (`className`) — R1's
first build step confirms the same classes appear on the React children of `InnerContainer`.

**Revised tasks.**
- R0 probe — DONE, result above.
- R1 game-page patch: Install / progress / Resume / Uninstall for registry-owned entries; stub kept
  as fallback; install size call; the downloads poll shared with the QAM.
  **BUILT 2026-10-22, offline-green, NOT yet on HW** (`src/GamePage.tsx`, `game_page.py`,
  `main.py game_state`/`install_size`, `tests/test-store-gamepage.sh`). Decisions: the row is
  spliced after the header for every shortcut page (top-bit pre-filter) but renders, and hides
  Steam's Play, only once the backend's registry says the appid is ours and not installed; the
  hide targets `basicAppDetailsSectionStylerClasses.PlaySection` (+ desktop `Container`) under a
  per-appid marker. A swap (install done / uninstall) gives the entry a new appid: the page follows
  through the token from its earlier poll, with a history PUSH (Steam's router has no replace) — so
  Back passes the dead page once. Installed games keep native Play plus an Uninstall row above it.
  **HW-PASSED 2026-10-22 on the Pocket FIT, fresh dev card** (DOOM 64, Epic): PlaySection hide
  works under InnerContainer; Install takes focus; install → swap → Proton launch → uninstall all
  keep the user on the game's page; a Steam game's page and a non-NovaDeck shortcut's page are
  untouched (marker only, no row, no hide rule). Fixed on HW: DialogButton's width:100% squeezed
  the meta column; a press re-ran `legendary info` (now reuses the page's cached info); focus fell
  to <body> after a press; **Steam sends an open page home when its app is removed, AND when it is
  opened for an app with no overview yet** — so the bridge waits for the replacement's overview,
  moves the page, THEN removes (`remove_payload(moved_to=)`). Then, also HW-verified: a swap
  copies the old entry's art from Steam's grid dir (no download); the compat re-assert runs on
  `frontend_ready` instead of backend boot ("compat re-asserted on 1 entries", no timeout); a press
  during the page's size lookup reuses it, and says "Starting…". OPEN: TLS handshakes time out
  repeatedly on this device (art, legendary info 2.6 s → ~15 s, SLR4 download "No connection").
- R2 library tabs: Epic / GOG (+ installed filter) via the /library patch; TabMaster detection
  falls back to collections.
  **BUILT + first HW look 2026-10-22**: the Epic tab (56) sits after Installed, Steam's own grid
  with its Filter / Sort By footer; sorting works (Steam groups by play time / last played).
  Membership is `library_tabs` (registry). Steam's own Installed tab counts no shortcuts (0).
- **In-place swap PROBED 2026-10-22 — it works on arm64.** A throwaway shortcut edited in place
  (`SetShortcutExe` / `SetShortcutStartDir` / `SetShortcutLaunchOptions` + `SpecifyCompatTool`)
  kept its appid, Steam rewrote shortcuts.vdf within the second, the compat mapping reached
  config.vdf, and all of it survived a Steam session restart (read back via appDetailsStore).
  So the install transition can EDIT the entry instead of remove + re-add: the appid — and with it
  play time, last played, art, the open page, collection membership — survives install and
  uninstall. The HW-found costs of remove + re-add (play history reset to "Never" on every swap;
  the page sent home; art re-applied) are what this removes.
  **SWITCHED + HW-PASSED 2026-10-22**: `_edit_entry` replaces `_swap_entry` (bridge op `edit`;
  compat SET for Windows, CLEARED with tool "" otherwise — Steam logs "Unmapping AppID"; a clear
  that fails is an error → pending_shelf). DOOM 64 kept appid 2274030331 through uninstall →
  install → play → uninstall; last played survived. The art copy (f0d056e) was removed as dead.
  Legacy `retired` appids from earlier builds are still removed by the next sync.
- ~~R3 collections → opt-in toggle~~ **DECIDED 2026-10-22: collections DROPPED entirely, no
  toggle and no cleanup code** (7e1c436). The tabs browse; Steam's Non-Steam tab lists every
  shortcut regardless (so even with TabMaster the games stay reachable); no released build ever
  created collections, so nothing needs deleting. The Pocket FIT's two were deleted by hand.
- R4 HW walkthrough (the old task 6, on the revised surface) on a freshly built card.

## Summary (revision 1 — the SURFACE parts are superseded by revision 2 above)

The browse surface is the **Steam library**, not the Quick Access panel. Every owned title appears
as a Steam tile — installed or not — grouped in `[NovaDeck] Epic` / `[NovaDeck] GOG` collections
with box art. A not-installed tile is a stub that **installs on press**; once installed it becomes
the model-B entry milestone 6 proved (Exe = the game, compat tool set, Steam composes SLR4+Proton
/ bare FEX for native). The QAM panel shrinks to what it is good at: connect/disconnect accounts,
show install progress, and a "sync library" action. It is never a game browser — browsing in a
narrow side strip is the UX this milestone exists to avoid.

## Why library-first keeps the milestone-6 win

Library-first is a *presentation* choice (show all owned games as tiles); model B is about how an
*installed* game launches. They are orthogonal. A not-installed stub's only job is to start a
download — no Proton, no SLR — so it never reopens the "stub reconstructs the launch" problem we
rejected. At install-completion the entry becomes a full model-B entry and Steam composes the
runtime exactly as gated with Master of Magic. We do NOT give up SLR4.

## Verified before planning (on the Pocket FIT, 2026-10-20)

| Fact | Evidence |
|---|---|
| `collectionStore` exists with `NewUnsavedCollection`, `SaveCollection`, `GetUserCollectionsByName`, `GetCollection`, `GetCollectionListForAppID` | probed live; same API unifideck's collection-manager uses |
| `SetShortcutExe` is present (function) on `SteamClient.Apps` | probed live; its persistence NOT confirmed (the app overview exposes `shortcut_override_appid`, not the Exe), so treat in-place rewrite as unverified — remove+re-add is the fallback |
| `RemoveShortcut` / `AddShortcut` / `SpecifyCompatTool` work on arm64 | milestones 4 + 6 HW gates |
| unifideck registers ALL owned games (installed or not), tags `"Not Installed"`, groups into `[Unifideck] <store>` collections; every Exe is its launcher stub, the real exe resolved at install into games.map | `_reference/unifideck` `reconcile_phases.py:307-313,435,461,524`, `collection-manager.ts` |
| Backend methods for the whole flow already exist and are gated | `owned, drives, install, install_status, stop_install, uninstall, register_entry, deregister_entry, entry_status, apply_artwork, reassert_compat` in `main.py` |

## Design

**Ownership becomes registry-membership.** With the full library registered, an entry is ours iff
its appid is in our `shortcuts.json` registry — authoritative, because we created every entry
(installed stub or model-B). This supersedes milestone 6's managed-root path test (which only
recognised installed entries) and the retired stub-basename test; both were proxies for "did we
make this." The managed-root test stays only as a secondary signal in the orphan report. Destructive
ops already key on the registry, so this narrows rather than widens what we will touch.

**Two entry shapes, one registry.**
- *Not-installed*: `Exe = /usr/lib/novadeck/store-launch` (the stub returns, install-only — see
  below), `LaunchOptions = <store>:<id>` (the stub's argv contract), tag `"Not Installed"`,
  in the collection. Registry row `{appid, title, platform?: unknown, state: "shelf"}`.
- *Installed*: the milestone-6 model-B entry (`Exe` = game, `game-launch %command%`, compat tool),
  tag cleared. Registry row gains `exe`, `platform`.

**The stub returns — install-only, never a launcher.** `store-launch <store>:<id>` starts the
install (the milestone-3 detached `systemd-run` path) and exits; it does NOT launch a game, so it
never needs Proton/SLR. This is the one place a not-installed tile's Exe has nothing else to point
at. It must make progress legible (see the UX seam) rather than silently exit.

**The install→model-B transition** (the backend, on install completion, watched via
`install_status`): resolve the real exe (`launch.resolve_target`), then either rewrite in place
(`SetShortcutExe` + `SpecifyCompatTool`, if a HW check shows it persists) or remove the stub
shortcut and add the model-B one (new appid, re-added to the collection — our token-keyed registry
absorbs the churn). Clear the `"Not Installed"` tag; apply artwork.

**Library sync** (on connect, and a manual "sync" action): `library.owned(store)` → for each owned
title not already in the registry, register a not-installed tile + add to the collection. Artwork
for not-installed tiles is wanted (the collection should look right) but is 55+ downloads, so it is
throttled/lazy (art-on-first-view or a bounded background pass), never blocking the sync.

**The slim QAM panel** (`Content.tsx`): connected-stores status + sign-in (milestone 2, kept);
an **activity view** (what is installing and how far, from `install_status`, plus errors); a
**sync library** button. No owned-games browser.

## The main UX risk — not-installed progress visibility

Pressing a "Not Installed" tile runs the stub, which starts a background install and exits. Steam's
library shows no native progress for a non-Steam shortcut, so without a progress surface the user
presses a tile and sees nothing — the exact crappy UX we are escaping. Mitigations, all needed:
- a Steam toast on install start/finish (via the plugin),
- the QAM activity view as the live progress surface,
- the tile's tag flipping `"Not Installed"` → installed as the completion signal,
- and the tile only becomes launchable (model-B) once installed.

## Files to Change

| File | Action | Why |
|---|---|---|
| `rootfs/overlay/usr/lib/novadeck/store-launch` | RE-CREATE | Install-only stub: `<store>:<id>` → start the install, surface it, exit. NOT a launcher |
| `.../novadeck_stores/shortcuts.py` | UPDATE | A not-installed entry template (stub Exe + token option + tag); ownership → registry-membership |
| `.../novadeck_stores/library_sync.py` | CREATE | Register all owned as not-installed tiles; the collection add; the throttled artwork pass |
| `.../novadeck_stores/installs.py` | UPDATE | Record the platform at install; signal completion for the transition |
| `apps/decky/novadeck-stores/main.py` | UPDATE | `sync_library`, the install→model-B transition watcher, progress for the panel |
| `apps/decky/novadeck-stores/src/lib/shortcutBridge.ts` | UPDATE | A `collection` op (NewUnsavedCollection/SaveCollection/add-app); a `set_exe` op (or remove+re-add) |
| `apps/decky/novadeck-stores/src/Content.tsx` + panel components | UPDATE | Slim panel: status + activity/progress + sync button |
| `apps/decky/novadeck-stores/src/index.tsx` | UPDATE | Route the new ops; progress event listener |
| `tests/test-store-shortcuts.sh` / new `test-store-library.sh` | UPDATE/CREATE | Not-installed template, registry-ownership, sync decisions, the transition |
| `Makefile`, PRD row, this plan | UPDATE | Wire + track |

## Tasks (outline — full detail once the shape is signed off)

1. **Ownership → registry-membership**: `is_ours` keys on appid∈registry; orphan report keeps
   managed-root as a secondary signal. Re-pin the suites.
2. **The install-only stub** + its not-installed entry template and tag.
3. **Library sync**: register all owned as not-installed tiles; the `collection` bridge op; idempotent
   re-sync (skip rows already registered); throttled artwork.
4. **The transition**: watch install completion → model-B entry (in-place rewrite or remove+re-add),
   tag flip, artwork. Decide in-place vs re-add from a HW `SetShortcutExe`-persistence check.
5. **The slim panel**: status + activity/progress + sync; the progress/toast surface for installs.
6. **Hardware gate** (the PRD's full walkthrough): connect both stores → owned games appear as tiles
   in the collections → press a not-installed tile → it installs with visible progress → tile flips
   to installed → press → launches (Windows via Proton, the native case when a native title exists)
   → restart/reboot/OTA durability → uninstall returns the tile to the shelf.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Not-installed install shows no progress → feels broken | High if unhandled | The progress surface above is a first-class deliverable, not polish |
| `SetShortcutExe` does not persist on arm64 | Medium | Remove+re-add fallback; decided by a HW check in task 4 |
| 55+ tiles + artwork floods Steam / the network on sync | Medium | Throttled/lazy artwork; register tiles first, decorate after; collection contains the clutter |
| Appid churn at the install transition breaks links | Medium | Registry keyed by token, not appid; re-add to collection on churn; reassert_compat on boot |
| Collection API skew on arm64 | Low | Probed present (NewUnsavedCollection/SaveCollection); verify add-app in task 3 |
| Library clutter in "all games" | Medium | The `[NovaDeck]` collections are the containment; consider hiding not-installed from "all games" if Steam allows |
| The install-only stub drifts toward launching | — | Hard rule: the stub installs and exits; launching is only ever the model-B entry |

## Build state (2026-10-21) — tasks 1–5 BUILT, offline-green; task 6 (HW walkthrough) owed

| Task | Commit | What landed / decided while building |
|---|---|---|
| 1 ownership | d045869 | `is_ours` = appid ∈ registry, compared **unsigned** both sides (live API may hand back a signed int). Managed-root survives only as `orphan_unregistered`. |
| 2 stub | b70821d | Stub runs as deck, install unit is root's → **request spool**: stub creates `<store home>/requests/<token>.install` (filename is the message), waits 10 s for the backend to unlink it, else withdraws + logs + exit 69. Backend polls 1 s, opens the spool O_NOFOLLOW (user-owned dir), unlinks relative to the dirfd, acts only on a registry **shelf** row. No drive picker on a press → default drive (pref in `settings.json`, else Internal). |
| 3 sync | 1e13ecf | `sync_library` after every sign-in + on demand. Registry written after EVERY add. ThirdPartyManagedApp titles get no tile. Collections re-asserted in full each sync: `[NovaDeck] Epic`/`GOG` + **`[NovaDeck] Not Installed`** (this replaces the plan's "Not Installed" tag — modern Steam tags ARE user collections). Bridge `collection` op waits ≤5 s for a fresh shortcut's overview. Art: paced background pass. |
| 4 transition | a0f17d5 | **remove+re-add, not SetShortcutExe** (in-place persistence still unverified). ADD FIRST, then remove; old appid rides as `retired` until Steam confirms (retried on the next sync; still ours by membership). Uninstall swaps back to a shelf tile. Fixed: `reassert_compat` would have put Proton on every shelf tile. |
| 5 panel | f522281 | Library (Sync, Install-to dropdown when >1 drive) + Activity (download % + Stop; paused → Resume/Remove; installed → Uninstall). Resume == a tile press; a partial resumes on the drive it is on, never restarted elsewhere. |

**Open for the user:** Steam user collections live in one blob Steam Cloud syncs account-wide
(unifideck's collection-manager.ts documents this and made collections opt-in), so the
`[NovaDeck]` collections will appear — empty — on the user's other Steam devices.

**Task 6 gate checklist additions** (beyond the walkthrough above): collectionStore AddApps/Save
persist on arm64; a shelf tile's Play runs the stub with argv[1] = token; the install_event toast
shows with the QAM closed; the swap's RemoveShortcut on the shelf appid; `SetShortcutExe` is
still unprobed — only worth probing if appid churn proves visible.

## Acceptance

- [ ] Connecting a store makes its owned games appear as Steam tiles in a `[NovaDeck]` collection
- [ ] A not-installed tile installs on press, with visible progress, then flips to installed
- [ ] An installed tile launches through the milestone-6 chain (Windows gated; native when available)
- [ ] Ownership is registry-membership; a foreign tile is never touched
- [ ] The QAM panel is status + activity + sync — not a browser
- [ ] Durability: tiles, collections and compat mappings survive restart, reboot, and one OTA
- [ ] `make test` green with the amended + new suites
