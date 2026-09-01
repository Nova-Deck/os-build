# Alien games — non-Steam titles on NovaDeck

## Problem

NovaDeck can run a Steam library well: FEX/Proton, per-game tuning and the Decky surfaces all
landed. It can do nothing at all with a game the user already owns outside Steam. There is no way
to get the files onto the device short of `scp`, no way to register them as library entries, and
no way to launch them from Big Picture.

The escape hatch every other handheld distro leans on is not available to us. On a Steam Deck the
answer to all three problems is "switch to Desktop Mode" — use a file manager to copy, then Steam's
own *Add a non-Steam game* dialog to register. **Desktop mode is an explicit non-goal for NovaDeck**
(`.claude/plans/novadeck.plan.md:23`), and Steam offers no Game Mode equivalent of that dialog. So
every step of the path — transfer, discovery, registration, launch — has to be supplied by NovaDeck
or it does not exist.

Left unsolved, a NovaDeck device is a Steam-only appliance. Any user with a GOG or itch library, a
DRM-free purchase, or a Linux app they want on the couch has no path that does not involve a laptop
and a shell.

## Evidence

**Ecosystem evidence — verified, external:**

- Adding a non-Steam game requires Desktop Mode; there is no Game Mode path in stock Steam.
  ([Pi My Life Up](https://pimylifeup.com/steam-deck-add-non-steam-game/),
  [Prima Games](https://primagames.com/tips/how-to-add-non-steam-games-to-steam-deck))
- Non-Steam shortcut appids are **no longer computable ahead of time** — the id changes ad-hoc on
  every add, even for an identical executable path and name.
  ([ValveSoftware/steam-for-linux#9463](https://github.com/ValveSoftware/steam-for-linux/issues/9463))
- Steam rewrites the shortcut store on shutdown and overwrites external edits made while it runs;
  an interrupted shutdown can leave the file corrupt and silently ignored on next start.
  ([steamtinkerlaunch wiki](https://github.com/sonic2kk/steamtinkerlaunch/wiki/Add-Non-Steam-Game))
- Solving this from Game Mode via a Decky plugin is established practice, not novel: Junk Store 2.0
  (Epic/GOG/Amazon/itch), unifideck, SteamGridDB, Steam ROM Manager via EmuDeck.
  ([Junk Store](https://www.junkstore.xyz/), [unifideck](https://github.com/mubaraknumann/unifideck),
  [EmuDeck](https://manual.emudeck.com/using-app/12_decky-plugins/))
- Artwork is treated as baseline, not polish — SteamGridDB is described as the single most useful
  plugin for anyone importing non-Steam games. A library entry with a blank grid tile reads as
  broken. ([Steam Deck HQ](https://steamdeckhq.com/tips-and-guides/sgdboop-artwork-for-steam-games/))
- Without a desktop, transfer means exFAT removable media or a network share; the SD card in use as
  storage cannot double as transfer media.
  ([How-To Geek](https://www.howtogeek.com/transfer-files-to-steam-deck-wirelessly-via-usb-and-more/))
- Flatpak is the endorsed install form on an immutable SteamOS-style root because it installs to a
  location that survives OS updates; AppImage is the portable, unsandboxed, zero-install form.
  ([PulseGeek](https://pulsegeek.com/articles/flatpak-vs-appimage-on-steam-deck-pros-and-cons/))

**Codebase evidence — verified in tree:**

- `apps/decky/.../novadeck_control/steam.py:43` already reads the binary shortcut store, so
  *enumerating* existing non-Steam entries is solved. Creating them is not, and per the appid
  finding above the id it reads is not a durable key.
- `rootfs/overlay/usr/lib/novadeck/game-launch` and `/etc/novadeck/game-tweaks.json` key all
  per-game tuning on Steam appid, so alien games inherit no tuning path for free.
- The image already reserves `/var/lib/flatpak` as an offload path (`rootfs/assemble-rootfs.sh:858`),
  bind-mounted from the shared `/home` and deliberately excluded from the per-slot `/var` copy
  (`lib-slotwrite.sh:232`). Flatpak's persistence problem is therefore already designed for. What is
  missing is the `flatpak` package itself — it is not in `PKGS`
  (`rootfs/customize-base.sh:201`).

**Demand evidence — ASSUMPTION.** No NovaDeck tester has reported this as a blocker; the trigger is
that the Steam library path is complete and this is the visible remaining gap. The pains above are
derived structurally from the code and the ecosystem, not from user reports.
*Needs validation via user research or a tester walkthrough once a prototype exists.*

## Users

**Primary — three segments, deliberately unranked pending evidence:**

- **DRM-free PC gamer.** Owns GOG or itch titles as installers or extracted folders. Expects them
  to run through FEX/Proton and sit in the library next to Steam games.
- **Linux-native tinkerer.** Has AppImages, Flatpaks, homebrew launchers and tools. Not all of it
  is games; wants it reachable from the couch.
- **Emulator user — as an app, not as content.** Wants an emulator (shipped as Flatpak or AppImage)
  installed and launchable so its own GUI comes up. Per-ROM library entries are explicitly a
  different feature.

**Not for:**

- Users wanting per-ROM shortcuts, bulk ROM import, or scraped emulator artwork. Out of scope; see
  below.
- Users wanting a general-purpose desktop. This feature exists *because* there is no desktop, and
  must not become the argument for adding one.

## Hypothesis

We believe that **an in-Game-Mode path to copy, discover, register and launch non-Steam games —
covering extracted folder trees, AppImages and Flatpaks — without a desktop or a shell** will
**remove the Steam-only ceiling on the device** for **users who already own games outside Steam**.

We'll know we're right when **a user can take a game from their PC to a launching Big Picture
library entry, on the device alone, with zero SSH and zero desktop steps, and the entry survives a
Steam restart, a reboot, and an OTA update.**

## Success Metrics

| Metric | Target | How measured |
|---|---|---|
| Steps requiring SSH or a desktop | 0 | Walkthrough audit of the full path, all three forms |
| Time from "files on the PC" to "game launches" | < 5 min | Timed walkthrough on real hardware |
| Registration durability | Survives Steam restart, reboot, and one OTA | Hardware test checklist, both A/B directions |
| Entries presenting with a name and artwork | 100% of registered entries | Visual check in Big Picture |
| Forms supported end-to-end | 3 of 3 (folder tree, AppImage, Flatpak) | Per-form walkthrough |

## Scope

**MVP** — A user on the same LAN copies game files from their PC to the device over a network
share; NovaDeck detects what was staged and presents it as candidates; the user registers a
candidate from the Quick Access Menu; it appears in Big Picture with a name and artwork and
launches.

Works for an extracted folder tree with a native or Windows executable, for an AppImage, and for a
Flatpak.

Delivery is sliced into tested, separately mergeable layers (see Delivery Milestones), but the MVP
above is what the *user* gets, and they get it all at once when the last phase wires the layers
together. The phases are a merge strategy, not a release sequence.

**Out of scope**

- **Per-game FEX and performance tuning for alien games** — deferred because Steam's shortcut appid
  is not stable across adds, so the existing appid-keyed tuning contract cannot be reused as-is.
  Needs its own identity design; a later milestone.
- **Emulator content integration (per-ROM library entries, ROM scanning, scraped artwork)** —
  explicitly a separate feature. An emulator packaged as a Flatpak or AppImage is in scope *as an
  app*: we install and launch it, and its own GUI takes over.
- **USB/SD removable-media import** — a second transfer mechanism; the network share is the MVP
  path. Revisit if evidence shows offline transfer matters.
- **Store-account integration (Epic, GOG, Amazon, itch logins and downloads)** — this feature is
  about games the user already has as files.
- **Desktop mode, a file manager, or any general-purpose desktop session** — remains a non-goal.
- **Cloud saves, playtime tracking, or achievements for alien games.**

## Delivery Milestones

<!-- Business outcomes, not engineering tasks. /plan turns each into a plan. -->
<!-- Status: pending | in-progress | complete -->

**Delivery constraint: every phase is tested and merges to `main` on its own.** No long-running
feature branch. A phase does **not** have to be reachable or useful to a user when it lands — it may
sit inert, unwired, or switched off until the last phase connects it. What it must do is land green:
its own behaviour proven by its own test, and `main` no worse for having it.

That admits a layered split, which is the cheaper one here — the machinery is shared across all
three packaging forms, so building it per form would build it three times. Each phase below is a
horizontal layer with a seam a test can drive directly, without the layers above it existing yet.
The last phase is the only one that makes any of it reachable from the device UI.

Preference when a phase lands inert: **unwired beats flagged off.** Code nothing calls yet is
plainly incomplete and its test drives it directly; a runtime flag guarding a half-built path is a
branch in shipped code that nothing exercises in the off state, and it has to be removed later
anyway.

| # | Milestone | Outcome | How it is proven when it lands | Status | Plan |
|---|---|---|---|---|---|
| 1 | Staging over the LAN | Files can be put on the device from a PC over a network share, off by default | Mount from a PC and write; share stays off unless enabled | pending | — |
| 2 | Candidate detection | A staged tree is classified into form, display name, and launch target — including choosing among several executables | Offline suite over fixture trees covering all three forms | pending | — |
| 3 | Library entry writer | An entry can be created and removed in Steam's shortcut store, correctly sequenced against Steam's lifecycle | Driven directly on a dev card with Steam running; entry survives a Steam restart and a reboot | pending | — |
| 4 | Artwork acquisition | An entry gets grid art, and degrades to something usable when the source is unreachable | Driven directly, including with the network cut | pending | — |
| 5 | Launch paths per form | An AppImage, a native tree, and a Windows tree each start correctly, the last through the existing FEX/Proton machinery | Invoked from a shell on hardware, one case per form | pending | — |
| 6 | Flatpak runtime support | The image can install and run Flatpaks on a read-only root, at an acceptable size cost | Flash and verify a Flatpak installs and runs; then install one on the running device and OTA both directions, since only runtime-created state tests the offload bind | pending | — |
| 7 | Quick Access Menu surface | The layers above are wired together and reachable: a user stages a game, registers it from the QAM, and plays it from Big Picture | Full walkthrough on hardware, all three forms, plus restart / reboot / OTA | pending | — |

**Ordering notes.** Phases 1–6 are independent of one another and may land in any order. Phase 7
depends on all of them and is the only phase that changes what a user can do — nothing is reachable
before it. Phase 6 is the only phase touching the image and OTA layout and so the likeliest to slip;
if it does, phase 7 can ship covering the other two forms and Flatpak follows behind it.

**Acceptance is per phase.** Each row above states how that phase is proven when it merges — that is
the gate, not a review at the end. The restart / reboot / OTA durability check applies to the phases
that create persistent state (1, 3, 6) and again end-to-end at phase 7.

Tracking lives in this table. Update `Status` and fill `Plan` as each phase is planned and lands;
no separate issues.

## Open Questions

- [ ] **Where do folder trees and AppImages live on disk?** They need somewhere writable with room
      that survives an update. *Flatpak is already answered:* `/var/lib/flatpak` is an existing
      offload path, bind-mounted from the shared `/home`, so system-wide Flatpak installs persist
      across updates by construction. Whether the other two forms reuse that tree or sit plainly in
      the user's home is undecided.
- [ ] **What happens when a user registers the same game twice?** Steam issues a fresh appid on
      every add, so we cannot detect a duplicate by appid alone.
- [ ] **How does a registered entry get artwork?** SteamGridDB is the ecosystem answer and is
      network-dependent and third-party. Whether MVP fetches artwork, ships a placeholder, or takes
      a user-supplied image is unresolved — but a blank tile is not acceptable.
- [ ] **Does adding Flatpak support pull in a store UI expectation?** Users who see Flatpak may
      expect to browse and install apps, not only to run ones they copied over. Where that line
      sits needs to be drawn.
- [ ] **Is a Windows executable in a folder tree expected to work as well as a Steam title does?**
      Steam-launched Windows games get Valve's per-title curation; a raw `.exe` we launch ourselves
      gets none. The quality gap may need to be stated to users rather than engineered away.
- [ ] **Does the network share need to reach the device, or the device reach the PC?** Both match
      what Deck users do; they have very different security and setup profiles.
- [ ] **Is demand real?** No tester has asked for this, and the layered delivery means no tester can
      try it until the last phase. Validate by some other means — a walkthrough of the intended flow,
      or asking directly — before phase 7 is planned.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Steam overwrites externally-written shortcuts on shutdown, silently losing a registration | High | High | Treat Steam's lifecycle as a hard constraint on when registration may happen; make a lost registration visible to the user rather than silent |
| Unstable shortcut appids break the link between an entry and anything we record about it | High | High | Do not key durable state on Steam's appid; deferring tuning out of MVP limits the blast radius until an identity design exists |
| A network file share is a new attack surface on a device on the user's LAN | Medium | High | Security review before milestone 1 ships; the share must be off by default and explicitly enabled |
| Flatpak's weight pushes the rootfs past what the image budget allows — it drags ostree, bubblewrap and appstream onto an image that has already been trimmed once | Medium | Medium | Measure the size delta first thing in phase 6, before any other work in that phase; dropping Flatpak from scope stays available and strands nothing. Its storage needs are *not* a risk — the offload tree already covers them |
| Registering arbitrary user executables to run on the device is by definition arbitrary code execution | High | Medium | This is the feature working as intended, matching Steam's own behaviour; the risk is in doing it *silently* — registration must be an explicit user act |
| Artwork depends on a third-party service that may be unreachable or rate-limited | Medium | Medium | A degraded path that still produces a usable entry; never block registration on artwork |
| Feature becomes the wedge that reintroduces desktop mode by increments | Medium | High | Out-of-scope list is explicit; a file manager, a shell, or a browser arriving as "a dependency" is a signal to stop and re-scope |
| Built for an assumed need — nobody uses it | Medium | Medium | Layered delivery means no user can try this until the last phase, so demand cannot be validated by shipping increments; validate separately, before phase 7 is planned |
| Layers land green individually but do not compose — each was proven against its own test seam, never against the next layer | Medium | High | Phase 7's gate is a full hardware walkthrough, not a wiring exercise; budget for it to find real defects rather than treating it as the small last step |
| Inert code accumulates on `main` and goes stale before phase 7 connects it | Medium | Medium | Keep the phase count and the gap between first and last merge small; a layer nothing calls for months is a layer that will need re-proving |

---
*Status: DRAFT — requirements only. Implementation planning pending via /plan.*
