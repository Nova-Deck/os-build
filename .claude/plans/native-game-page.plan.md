# Plan: Steam's own game page for our entries

**Branch**: `feat/native-page`.
**Complexity**: Medium. Frontend only (apps/decky/novadeck-stores); no backend change.
**Depends on**: the alien-games game page (`GamePage.tsx`, R1), which stays as the fallback.

## Summary

Our game page hid Steam's Play row on a not-installed entry and drew a row of our own (Install /
Stop / Resume / Remove / Uninstall / DOSBox version / Cloud saves). It works, but it does not look
like Steam. Instead, **Steam renders the page and we steer its own parts with our state**:

- **Steam's action button** shows Install / Pause / Resume, chosen by Steam from a display status
  we hand it, and its press runs ours. An installed entry keeps Steam's own Play.
- **The play bar's status area** says what we know (store, size, drive, progress) in Steam's
  markup, in place of Steam's stats while the entry is not installed.
- **A trash button** beside Steam's controller and gear buttons: Uninstall, or Remove for a paused
  download.
- **The gear menu** carries Uninstall…, Remove download, DOSBox version… and Turn cloud saves
  on/off, before Steam's Properties….
- **The cloud-saves line** sits under the play section, where Steam puts its STEAM CLOUD line.
- Tabs stay stock.

The technique is the one unifideck (GPL-3.0) uses for its "native App-Details" mode, re-written
against our state model; no code is copied. Their feasibility doc it cites
(`docs/feasibility/native-app-details.md`) was never committed to any of their 14 branches.

User decisions (2026-11-19): go with this control layout; probe on the Pocket Max.

## N0 probe (Pocket Max, client 1792618285, Decky @decky/ui 4.11.6, 2026-11-19)

Read-only over CDP (an SSH tunnel to `:8080`, a stdlib RFC6455 one-shot client, scratchpad only,
never shipped). One game page (Master of Magic Classic, not installed) opened for 2.5 s and the UI
sent back home.

| Seam | Result |
|---|---|
| Action button: module whose source holds `bShowStreamingSelector`, `ShowStreamingMenu`, `strGameActionDetailsOverride` | module 85273, one exported forwardRef; on a live page it IS the button fiber (5 above the DOM node), props `bShowStreamingSelector, overview, className, ref` |
| `OnClick` / `ShowStreamingMenu` on the button class | prototype getters, both configurable |
| Play-bar row (forwardRef, `details` prop, render holds `ActionButtonAndStatusPanel` + `AppButtons`) | not exported; found 14 fibers above the button |
| PlaySection (render holds `.PlaySection` + `onNav`) | not exported; found 19 fibers above the button |
| Tabbed page memo (`.TabRowTabs`, `activeTab:`) | module 10272; tabs `WhatsNew, YourStuff, Community, GameInfo`, GameInfo carries our appid (not used: tabs stay stock) |
| Play-bar classes | `@decky/ui` `playSectionClasses` (module 96821): StatusAndStats, DetailsSection, OnlyDownloadBar, DownloadProgressBar, MenuButtonContainer, CloudStatusRow, … |
| Details classes (ActionRow, AppButtons, AppActionButton) | module 20297 (not in `appDetailsClasses`) |

**EDisplayStatus** (enum names are minified on this build; names read from Steam's own
value→name switch, module 18488; button action from its status→action switch, module 43394):

| Value | Name | Steam's button |
|---|---|---|
| 1 | Launching | Cancel |
| 3 | Installing | none (disabled, throbber) |
| 4 | Running | Resume / Stop |
| 7 | Downloading | **Pause** |
| 9 | ReadyToInstall | **Install** |
| 11 | ReadyToLaunch | Play |
| 14 | InvalidPlatform | none |
| 22 | DownloadPaused | **Resume** |
| 36 | Terminating | none |

unifideck's comments call 1 "Cancel", 14 "InstallUnavailable", 37 "PlayUnavailable"; Steam's own
names are Launching, InvalidPlatform, OwnerLocked. 7 and 22 fit our states exactly, and neither is
a status Steam uses while it drives the app.

## Design

| Our state | Status shown | Press |
|---|---|---|
| not ours / not known yet | Steam's own (its Play runs the stub, which installs) | Steam's |
| install | 9 Install | install |
| install, cannot start (no drive, too big, slot busy) | 14 (disabled) | swallowed |
| downloading | 7 Pause | stop (resumable) |
| paused | 22 Resume | resume |
| finishing | 3 (disabled, throbber) | swallowed |
| stale | 14 (disabled) | swallowed |
| installed | Steam's own Play | Steam's |
| a press being answered | 3 (throbber) | swallowed |
| Steam launching / running / terminating | Steam's own | Steam's |

Files: `src/native/` (status table, webpack finder, reload-safe slots, overview Proxy, button,
row, gear menu), `src/NativePage.tsx`, `src/lib/pageState.ts` (one poll per appid for every part
of the page), `src/lib/pageHooks.ts` + `pageActions.tsx` (shared with the legacy row).

**Fallback**: if the button is not found at load, or its click seam fails at first render, the
native page is inactive and the legacy row (`GamePage.tsx`) renders as before.

## Tasks

- [x] N0 probe on the Pocket Max — result above.
- [x] Status table + offline suite (`tests/test-store-native-page.sh`, wired into `make test`).
- [x] Button, row, status area, download bar, trash, cloud line, gear menu; legacy row on the shared store.
- [x] Review (typescript-reviewer): no CRITICAL; 2 HIGH + 5 MEDIUM fixed (error boundary per injected
      part, snapshot held with its appid, pending until the re-read lands and shared per entry, press
      decided at click time, no own OnClick left on instances, every button class patched, full
      stand-down on a broken click seam) and publish-only-on-change.
- [ ] **HW walkthrough** (Pocket Max, plugin hot-deployed 2026-11-19, shipped bundle kept at
      `/root/novadeck-stores-shipped.js`; then a real card):
  - [x] not-installed entry (Master of Magic Classic): Steam's blue Install with its download icon;
        status area "GOG / Needs 0.2 GB · To Internal, 8.2 GB free"; legacy row absent
  - [x] installed entry (Another World): Steam's green Play, Steam's LAST PLAYED / PLAY TIME; trash
        button same size as Steam's controller + gear; "CLOUD SAVES: ON, LAST SYNCED …" in Steam's
        cloud-line style
  - [x] a user's own shortcut (Google Play Store): page entirely stock
  - [x] plugin_loader restarted twice: still one trash button, one cloud line
  - [x] press Install: installs (Master of Magic Classic, user 2026-11-19)
  - [x] downloading: button reads Pause, bar under the button moves; Pause stops (resumable)
  - [x] paused: Resume + status line
  - [ ] finishing: disabled button with throbber; stale: disabled button (check 14 draws no throbber)
  - [x] installed: trash and gear Uninstall… open the uninstall dialog
  - [x] user walkthrough (2026-11-19): gear menu items, trash dialog, Install → Pause → Resume, focus — all OK
  - [x] DOSBox version… in the gear menu under Boxtron — PASSES after the fix (user, 2026-11-19);
        Pause / Resume and gamepad focus re-confirmed. FAILED first (Master of Magic Classic, two
        versions, Boxtron selected): nothing on the native page called useOnBoxtron/useDosVersions,
        so the menu's cache was never filled. Live tool was `boxtron` while `appDetailsStore` still
        said `proton-cachyos-11.0-arm64` (the stale-cache trap). Fixed with GearFacts.
  - [x] gamepad focus walks button → trash → Steam's buttons; nothing lost after a press
  - [ ] a Steam game: page entirely stock (no Steam game on the Pocket Max card)
  - [ ] plugin reload twice: no doubled gear-menu items
  - [ ] a real card (built image, not the hot-deployed bundle)
