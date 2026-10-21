# Plan: Alien games — library-first surface (Quick Access + Steam library)

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 7 — the surface that wires connect → browse → install → play
**Complexity**: Large (it is the capstone, and it adjusts the milestone-4/6 ownership model again)
**Depends on**: milestones 1–6 (all built; 1–5 + M6-Windows HW-gated).

## Summary

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
