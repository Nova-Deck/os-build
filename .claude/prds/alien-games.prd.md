# Alien games — games you own outside Steam

## Problem

NovaDeck can run a Steam library well: FEX/Proton, per-game tuning and the Decky surfaces all
landed. It can do nothing at all with a game the user owns outside Steam.

For most people that library is not a pile of loose files — it is a **store account**. Epic gives
away a game a week; GOG is where a DRM-free collection accumulates. Those games live behind a
store client that NovaDeck does not ship and cannot ship — the Epic launcher and GOG Galaxy have
no Linux build at all — and that would have nowhere to run if it did: **desktop mode is an explicit
non-goal** (`.claude/plans/novadeck.plan.md:23`), and Steam offers no Game Mode path for adding or
installing a non-Steam title.

So every step — authenticate, discover what you own, download it, register it, launch it — has to
be supplied by NovaDeck or it does not exist.

Left unsolved, a NovaDeck device is a Steam-only appliance. A user with years of free Epic titles
and a decade of GOG purchases can see none of them, and the workaround costs a laptop, a shell, and a
file copy per game.

## Rescope note — 2026-09-20

This PRD previously excluded store-account integration as too complex, and made **LAN file
staging** the MVP as a direct consequence: if the device cannot talk to a store, the only way a
game reaches it is a copy from the user's PC. The exclusion drove the scope, not the other way
round.

Reading [unifideck](https://github.com/mubaraknumann/unifideck) (a Decky plugin doing this for
seven stores) changed the complexity estimate, because the expensive-looking part turns out not to
be load-bearing — see Evidence. Store integration is now the MVP; LAN staging and the local-file
forms are demoted to a follow-on milestone, not deleted. They remain the only path the
loose-files and AppImage users will ever have.

## Evidence

**Why the complexity estimate changed — verified by reading `_reference/unifideck`:**

- **The browser is UX, not architecture.** Every store login there ends by driving Microsoft Edge
  to a login page and scraping a short code out of the redirect, then handing that code to a CLI
  or an HTTP call: Epic is `legendary auth --code <authorizationCode>`
  (`stores/epic/auth.py:273`); Amazon is `nile register --code <code> --code-verifier <verifier>
  --serial <serial>` (`stores/amazon/amazon_auth.py:296-301`, PKCE, verifier generated locally);
  GOG needs no CLI for the exchange at all and POSTs the code to GOG's OAuth endpoint itself
  (`stores/gog/tokens/oauth.py` — gogdl is still used for downloads, just not for sign-in).
  **Nothing requires the browser to be on the device** — it requires a browser somewhere and a way
  to return ~60 characters. Their README names Edge as required for store sign-in *and* for Xbox
  Cloud Gaming; dropping xCloud is what lets the browser go, and the flatpak runtime with it.
- **The store CLIs are portable.** legendary, gogdl and nile are Python; comet is Rust; winetricks
  is shell. unifideck pins prebuilt `*_linux_x86_64` artifacts (`build-plugin.sh:243-247`) purely
  because its target is a Deck. Native arm64 builds are a packaging job, not a porting one — no
  FEX involved.
- **Their launch path duplicates a chain we already have.** unifideck launches through `umu-run`,
  which bootstraps its own Proton and Steam Linux Runtime *outside* Steam's compat-tool selection,
  and deliberately writes no per-app `CompatToolMapping` (`core/compat_tool_bridge.py`). We need
  none of that: our Protons already run inside SLR4 exactly like Valve's, `require_tool_appid`
  left alone (`docs/windows-games-fex.md:88`), and per-game tuning already arrives as Steam
  **launch options** evaluated on the host side of pressure-vessel (`docs/FEX_README.md:74-80`) —
  the in-tool shim that used to do it is gone, precisely because a host path does not exist inside
  the container. Registering a shortcut against a compat tool and letting Steam run it is strictly
  less machinery than importing umu.
- **Adopting the plugin wholesale is the expensive option, not the cheap one.** ~600 Python files
  and ~120k lines, seven stores, an actively developed tree; an arm64 fork is a standing
  maintenance cost. Its *design* is the asset — in particular the identity trick below.
- **Identity is solvable and they solved it — but the field is contested.** Shortcuts do not point
  at the game: `Exe` points at a launcher stub and `LaunchOptions` carries a `"<store>:<game_id>"`
  token resolved through a map file (`bin/unifideck-runner`, `services/shortcut/games_map.py`,
  `services/shortcut/orphan_scan.py:8-12`). The durable key is theirs, not Steam's appid, and
  ownership of an entry is proven by the `Exe` target rather than the token — because **Steam
  mangles `LaunchOptions`** (`services/shortcut/registry.py:8`, `write_guard.py:92`). That lands on
  us twice: `LaunchOptions` is also the field we need for `game-launch %command%`, and it is not a
  field we can trust to come back unchanged.

**Ecosystem evidence — verified, external:**

- Adding a non-Steam game requires Desktop Mode; there is no Game Mode path in stock Steam.
  ([Pi My Life Up](https://pimylifeup.com/steam-deck-add-non-steam-game/))
- Non-Steam shortcut appids are **no longer computable ahead of time** — the id changes ad-hoc on
  every add, even for an identical executable path and name.
  ([ValveSoftware/steam-for-linux#9463](https://github.com/ValveSoftware/steam-for-linux/issues/9463))
- Steam rewrites the shortcut store on shutdown and overwrites external edits made while it runs;
  an interrupted shutdown can leave the file corrupt and silently ignored on next start.
  ([steamtinkerlaunch wiki](https://github.com/sonic2kk/steamtinkerlaunch/wiki/Add-Non-Steam-Game))
  unifideck's answer is to require an explicit Steam restart after writing
  (`src/components/modals/SteamRestartModal.tsx`) — treat that as the known-good shape, not a
  workaround to engineer away.
- Artwork is baseline, not polish. A library entry with a blank grid tile reads as broken.
  ([Steam Deck HQ](https://steamdeckhq.com/tips-and-guides/sgdboop-artwork-for-steam-games/))
- Solving this from Game Mode via a Decky plugin is established practice: Junk Store 2.0, unifideck,
  Heroic on desktop. ([Junk Store](https://www.junkstore.xyz/))

**Codebase evidence — verified in tree:**

- `apps/decky/novadeck-control/py_modules/novadeck_control/steam.py:43` already parses the binary
  shortcut store, so *enumerating* non-Steam entries is solved. Creating them is not.
- `rootfs/overlay/usr/lib/novadeck/game-launch` already fronts arbitrary launch chains via Steam
  **launch options** (`game-launch %command%`, written per game by novadeck-control). Because we
  write an alien game's shortcut ourselves, we own its launch options — so alien titles can reach
  the existing per-game FEX and perf machinery by the same door Steam titles do.
- `/etc/novadeck/game-tweaks.json` is keyed per-appid, and novadeck-powerd resolves the running
  game's appid from the process environment (`rootfs/overlay/usr/lib/novadeck/novadeck_perf.py`).
  That works for a shortcut *while its appid holds* — the churn problem is durability, not reach.
- `python` is already in `PKGS` (`rootfs/customize-base.sh:232`), so Python-based store CLIs need
  no new interpreter. `flatpak` is **not** in `PKGS`, and is not needed under this scope.
- `/var/lib/flatpak` is already an offload mountpoint bound from the shared `/home`
  (`rootfs/assemble-rootfs.sh:399`) — relevant only to the deferred local-files milestone.

**Demand evidence — WEAK BUT IMPROVED.** No NovaDeck tester has asked for this. It is better
evidenced than the loose-files framing was: Heroic, Junk Store and unifideck exist because Deck
owners want their Epic and GOG libraries in Game Mode. That is ecosystem demand on a different
device, not ours. *Still needs validating with a tester before the last milestone is planned.*

## Users

**Primary — store-library owner.** Owns games on Epic (including years of weekly giveaways) and/or
GOG. Expects to sign in once, see what they own, press Install, press Play. Never wants to see a
file path.

**Secondary — DRM-free collector.** Owns GOG titles and expects them to install the same way; also
has itch purchases and loose archives that only the deferred local-files milestone will reach.

**Deferred to the local-files milestone, not served by this MVP:**

- Users with loose folder trees, itch downloads or DRM-free archives on a PC.
- Users with AppImages, Flatpaks, or Linux-native tools they want on the couch.
- Users wanting an emulator installed as an app.

**Not for:**

- Users wanting per-ROM shortcuts or bulk ROM import. Out of scope, separate feature.
- Users wanting a general-purpose desktop. This feature exists *because* there is no desktop, and
  must not become the argument for adding one.

## Hypothesis

We believe that **connecting an Epic and a GOG account from Game Mode, and installing and
launching owned titles without a desktop, a shell, or a browser on the device** will **remove the
Steam-only ceiling** for **users whose non-Steam library lives in a store account**.

We'll know we're right when **a user connects an account, installs a game and plays it on the
device alone, and the entry survives a Steam restart, a reboot, and an OTA update.**

## Success Metrics

| Metric | Target | How measured |
|---|---|---|
| Steps requiring SSH, a desktop, or a browser on the device | 0 | Walkthrough audit of the full path |
| Stores connectable | 2 of 2 (Epic, GOG) | Hardware walkthrough, one real account each |
| Time from "opening the plugin" to "an owned game is installing" | < 5 min, first run, including sign-in | Timed walkthrough on real hardware |
| Registration durability | Survives Steam restart, reboot, and one OTA | Hardware checklist, both A/B directions |
| Entries presenting with a name and artwork | 100% of registered entries | Visual check in Big Picture |
| Windows titles reaching the existing FEX/Proton chain | 3 of 3 test titles launch through SLR4 + Proton with `game-launch` confirmed in the chain (tuning itself is out of MVP scope) | Per-title check on hardware against the launch log |

## Scope

**MVP** — From the Quick Access Menu the user connects an Epic and/or GOG account by signing in on
a device they already have and returning a code. NovaDeck lists what they own, installs a chosen
title to a location they pick, registers it in the Steam library with name and artwork, and
launches it through the existing Proton/FEX chain.

**Out of scope**

- **A browser on the device, and anything needing one** — Xbox Cloud Gaming, and any store whose
  sign-in cannot be reduced to a code handoff. The browser is the line; crossing it re-imports the
  complexity this rescope removed.
- **Amazon, Ubisoft, Battle.net, GameVault.** Amazon is the cheapest next one (same code-handoff
  shape, one more Python CLI) and is the obvious follow-on if demand appears.
- **LAN staging, folder trees, AppImages, Flatpak runtime support** — deferred to milestone L
  below. This is the one deletion from the previous scope that costs real users something, and it
  is a deferral, not a cut.
- **Per-game FEX and performance tuning for alien games** — no longer *blocked* (we own the launch
  options, so the existing machinery is reachable), but kept out of MVP for size. Needs the two
  identity questions answered first — the contested `LaunchOptions` field and appid churn; see
  Open Questions.
- **Cloud saves, playtime, achievements, and GOG Galaxy multiplayer (comet).**
- **Store browsing or purchasing.** This is about games already owned.
- **Desktop mode, a file manager, or any general-purpose desktop session** — remains a non-goal.

## Delivery Milestones

<!-- Business outcomes, not engineering tasks. /plan turns each into a plan. -->
<!-- Status: pending | in-progress | complete | deferred -->

**Delivery constraint: every milestone is tested and merges to `main` on its own.** No long-running
feature branch. A milestone does **not** have to be reachable or useful to a user when it lands —
it may sit inert, unwired, or switched off until the last one connects it. What it must do is land
green: its own behaviour proven by its own test, and `main` no worse for having it.

Preference when a milestone lands inert: **unwired beats flagged off.** Code nothing calls yet is
plainly incomplete and its test drives it directly; a runtime flag guarding a half-built path is a
branch in shipped code that nothing exercises in the off state, and it has to be removed later
anyway.

| # | Milestone | Outcome | How it is proven when it lands | Status | Plan |
|---|---|---|---|---|---|
| 1 | Store CLIs, native arm64 | legendary and gogdl are packaged and run on the device — no FEX, no x86 freeze | Package builds in the normal pipeline; each CLI runs on hardware and lists a library given a hand-supplied token | pending | — |
| 2 | Account connection | A user connects Epic and GOG from the device with no browser on it; tokens persist and refresh | Hardware walkthrough with real accounts; token survives reboot and an expiry/refresh cycle; security review of credential-at-rest before it merges | pending | — |
| 3 | Install and uninstall | An owned title downloads to a chosen location, resumes after an interruption, and uninstalls cleanly | Driven on hardware against a real account, including a deliberate mid-download network cut | pending | — |
| 4 | Library entry writer | An entry is created and removed in Steam's shortcut store, correctly sequenced against Steam's lifecycle, keyed on **our** stable id via a launcher stub — never on Steam's appid | Driven directly on a dev card with Steam running; entry survives a Steam restart and a reboot | pending | — |
| 5 | Artwork acquisition | An entry gets grid art, and degrades to something usable when the source is unreachable | Driven directly, including with the network cut | pending | — |
| 6 | Launch path | A downloaded Windows title starts through the existing Proton/FEX chain and a Linux-native one through system FEX, both fronted by `game-launch` | Invoked from a shell on hardware, one case per form, with `game-launch` confirmed in the chain | pending | — |
| 7 | Quick Access Menu surface | The layers are wired together and reachable: connect, browse, install, play | Full walkthrough on hardware, both stores, plus restart / reboot / OTA | pending | — |
| L | Local files (deferred) | LAN staging, candidate detection for folder trees and AppImages, and Flatpak runtime support — the previous MVP, folded in behind the shared layers 4/5/6 | As previously specced: share off by default; offline suite over fixture trees; Flatpak install verified across an OTA in both directions | deferred | — |

**Ordering notes.** Milestone 1 precedes 2 and 3. Milestones 4, 5 and 6 are independent of 1–3 and
of each other — they can be driven with a hand-placed game directory and no store account at all,
which is also how they stay testable without burning a real account. Milestone 7 depends on
everything and is the only one that changes what a user can do. Milestone L reuses 4, 5 and 6
unchanged; its cost is its own front half only.

**Acceptance is per milestone.** Each row states how it is proven when it merges — that is the
gate, not a review at the end. The restart / reboot / OTA durability check applies to the
milestones that create persistent state (2, 3, 4) and again end-to-end at milestone 7.

Tracking lives in this table. Update `Status` and fill `Plan` as each milestone is planned and
lands; no separate issues.

## Open Questions

- [ ] **How does the auth code get from the browser to the device?** Three candidates: type it with
      Steam's on-screen keyboard (works today, ~60 characters of pain); show a QR to open the login
      URL on a phone and pair back; a one-shot local page the phone posts to. The last reintroduces
      a small LAN surface — far smaller than a writable file share, but it is a surface. Undecided,
      and it is the single biggest UX risk in the MVP.
- [ ] **Do we build a reduced client or fork unifideck?** Leaning build-reduced and reuse the
      design: two stores, no browser, no umu, our launch chain. A fork inherits seven stores, an
      Edge dependency and a maintenance treadmill. Decide before milestone 1 is planned.
- [ ] **Where do games install, and who chooses?** Internal `/home`, SD card, or a user-picked path.
      Interacts with the OTA layout and with how the shortcut's stored path survives a card moving
      between slots or devices.
- [ ] **How do identity and tuning share one `LaunchOptions` field?** We need that field for
      `game-launch %command%`; the ecosystem pattern puts the durable id there too, and Steam is
      known to mangle it. Candidates: encode both, carry the id as arguments on the `Exe` stub
      instead, or resolve identity from the stub's own path. Decide at milestone 4, since the
      writer's ownership test depends on the answer.
- [ ] **What happens to per-game tuning when a shortcut's appid churns?** We own registration, so we
      can rewrite the tweak entry on re-add — or re-key tuning on our own id and teach powerd to
      resolve it. Needs a decision before tuning comes back into scope.
- [ ] **What is our stance on unofficial store clients?** legendary and gogdl are clean-room
      reimplementations, widely used via Heroic, and outside Epic's and GOG's terms in letter. We
      would be shipping one as a headline feature. State a position rather than discover one.
- [ ] **Is demand real for *our* users?** Ecosystem demand is well evidenced; NovaDeck tester demand
      is not. Validate by walkthrough or by asking, before milestone 7 is planned.
- [ ] **Where does the line on stores get drawn publicly?** Shipping two stores invites "why not
      Amazon / Ubisoft / xCloud". The technical line is the browser; the product line needs saying
      out loud.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Unofficial store clients break when a store changes its API or protocol, taking installs down with them | High | High | Pin versions and track upstream; a broken store must degrade to "cannot sync" with already-installed games still launching, never to a broken library |
| Steam overwrites externally-written shortcuts on shutdown, silently losing a registration | High | High | Treat Steam's lifecycle as a hard constraint on when registration may happen; require the explicit restart, as the ecosystem does; make a lost registration visible rather than silent |
| Unstable shortcut appids break the link between an entry and anything we record about it | High | Medium | Key durable state on our own id behind a launcher stub, never on Steam's appid, and prove ownership of an entry by its `Exe` target — Steam mangles `LaunchOptions`, so the token in it cannot be the proof. Milestone 4's gate |
| OAuth refresh tokens at rest on the device are account credentials, and a stolen card is a stolen account | Medium | High | Security review is a merge gate on milestone 2, not an afterthought; encrypt at rest and scope what is stored |
| Account action by a store against users of an unofficial client | Low | High | Take a position before shipping, and make the choice visible to the user at sign-in rather than implicit |
| The auth code handoff is too clumsy and users bounce at the first screen | Medium | High | Prototype the handoff before milestone 2 is planned; it is the first thing every user meets |
| Store downloads are tens of GB and storage runs out mid-install | Medium | Medium | Free-space check before starting; resumable downloads are a milestone 3 gate, not a later polish |
| Artwork depends on a third-party service that may be unreachable or rate-limited | Medium | Medium | A degraded path that still produces a usable entry; never block registration on artwork |
| Feature becomes the wedge that reintroduces desktop mode or an on-device browser by increments | Medium | High | The browser is the stated line; a browser, a file manager or a shell arriving as "a dependency" is a signal to stop and re-scope |
| Two more third-party tools pinned into the image, each with its own release cadence | Medium | Medium | Same pin-and-relock discipline as the rest of the overlay; a store CLI bump is an ordinary package bump, not a special case |
| Layers land green individually but do not compose — each proven against its own seam, never against the next | Medium | High | Milestone 7's gate is a full hardware walkthrough, not a wiring exercise; budget for it to find real defects |
| Built for an assumed need — our testers do not want it | Medium | Medium | Validate separately before milestone 7 is planned; ecosystem demand is not our demand |
| *(Milestone L only)* A network file share is a new attack surface on a device sitting on the user's LAN | Medium | High | Carried unchanged from the previous scope: security review before L ships, and the share is off by default and explicitly enabled |
| Deferring local files strands the AppImage and loose-files users indefinitely | Medium | Medium | Milestone L stays in this PRD with its proof lines intact, and reuses layers 4–6 rather than rebuilding them; the deferral is cheap to reverse |

---
*Status: DRAFT — requirements only. Rescoped 2026-09-20 from LAN-staging-first to
store-account-first; see Rescope note. Implementation planning pending via /plan.*
