# Plan: Alien games — account connection

**Source PRD**: `.claude/prds/alien-games.prd.md`
**Selected Milestone**: 2 — Account connection
**Complexity**: Large
**Depends on**: milestone 1 (`alien-games.plan.md`), complete and HW-gated 2026-09-20

## Summary

A user connects an Epic and a GOG account from Game Mode, with a gamepad, and the tokens survive a
reboot and an OTA. The research below answers the PRD's biggest open question — how the
authorization code reaches the device — and the answer removes the LAN listener, the phone, and the
typing: **Steam's own CEF browser is already on the device and is scriptable from a Decky plugin.**

The milestone's own wording needs amending as a result. It reads "with no browser on it"; what was
meant is *no browser we ship*. Steam's browser is not something we install, package or update.

## Verified before planning

| Fact | Evidence |
|---|---|
| Steam exposes a scriptable browser view | `SteamClient.BrowserView.Create({strInitialURL})` → a `BrowserViewPopup` with `LoadURL()` (`@decky/ui` `globals/steam-client/browser-view/index.d.ts`) |
| **The redirect URL is observable** | `BrowserViewPopup` emits `'finished-request': (currentURL, previousURL)`, plus `'start-request'`, `'blocked-request'`, `'load-error'` |
| A GUI in Game Mode must come from Steam | A bare subprocess gets no gamescope session and its window never appears — `_reference/unifideck/py_modules/unifideck/stores/shared/auth_shortcut.py`, which is why their vendor-client sign-ins go through a temporary shortcut |
| Mid-session shortcuts need the API, not the file | `SteamClient.Apps.AddShortcut` populates Steam's in-memory app store immediately; a `shortcuts.vdf` write is only read at Steam startup and `RunGame` fails with "Game configuration unavailable" (`_reference/unifideck/src/lib/steam-bridge/temp-shortcut.ts`) — **this also matters to milestone 4** |
| Typing the code is not an option | Measured on hardware: Epic's `authorizationCode` is 32 hex chars, GOG's is **192** mixed-case with `-`/`_`. The PRD's "~60 characters of pain" estimate was 3x low, and one mis-key restarts a single-use login |
| legendary's config location is redirectable | `LEGENDARY_CONFIG_PATH`, else `XDG_CONFIG_HOME` (`_reference/legendary/legendary/lfs/lgndry.py:29-31`) |
| gogdl's is mandatory and has no default | `--auth-config-path` is `required=False` with no default; `__write_config` does `open(None, "w")` **after** the token exchange, so a missing path spends the user's code and discards the tokens (milestone 1's HW finding) |
| `/root` is **already persistent and shared** | `rootfs/lib-assemble-offload.sh:35` injects offload binds for `/opt /root /srv` plus `var/{log,tmp,cache/pacman,lib/*}` into `/home/.novadeck/offload`; `lib-slotwrite.sh:233` skips them on a slot write *because* they are shared. Confirmed on device: `/root` is `/dev/mmcblk0p8[/.novadeck/offload/root]`, and the milestone-1 tokens survived a reboot |

**A correction to an earlier draft of this plan.** It claimed `/root` was on the per-slot root
filesystem and that an OTA would wipe the credentials, so Task 2 had to relocate them. That came
from inspecting `out/images/rootfs.img`, where `/root` *is* a plain directory — true of the image
and false at runtime, because the offload bind is mounted at boot. The root filesystem is genuinely
`ro` (`/dev/mmcblk0p4 btrfs ro`), which is what made the writable `/root` look like a contradiction
worth chasing. Credentials in `/root/.config/` already persist across reboots and OTAs. Task 2 is
therefore about ownership, permissions and explicitness, not relocation.

## Design

**Connect flow, per store, entirely on-device:**

1. The plugin builds the store's OAuth URL (GOG's is `auth.gog.com/auth` with the Galaxy client id;
   Epic's is `legendary.gl/epiclogin`, which is upstream's redirect helper).
2. `SteamClient.BrowserView.Create({ strInitialURL })` opens it in Steam's own browser.
3. The user signs in with the on-screen keyboard — an email and a password, not a 192-char blob.
4. `finished-request` fires on every navigation; the plugin matches the store's redirect target and
   extracts the code from the URL (`?code=` for GOG, the `authorizationCode` JSON for Epic).
5. The view is destroyed and the code goes to the backend, which runs `legendary auth --code` or
   `gogdl --auth-config-path … auth --code`, both pointed at the persistent store.

Nothing is typed, nothing leaves the device, and there is no listener on the LAN.

**Fallback, designed but not built:** if the spike fails, the phone-and-paste flow returns — QR to
the login page, user pastes the code into a small page the device serves. It costs a LAN listener
and a security review, which is why it is the fallback rather than the plan.

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| Plugin shape | `apps/decky/novadeck-framegen/` | `main.py` + `py_modules/<pkg>/` + `src/{index,Content,backend,types,styles}` — the smallest complete first-party plugin |
| Backend RPC | `apps/decky/novadeck-control/py_modules/novadeck_control/` | Plain methods on the plugin class, JSON-serialisable returns |
| Shortcut store reads | `apps/decky/novadeck-control/py_modules/novadeck_control/steam.py:43` | Binary VDF parsing already exists; do not write a second one |
| Tests | `tests/test-decky.sh` | Asserts the plugin backend compiles and its declarations agree; names the HW gates it cannot replace |
| Secret handling | `_reference/unifideck/py_modules/unifideck/security/token_file.py` | A single owner for the token file, including the cleanup it owes |

## Files to Change

| File | Action | Why |
|---|---|---|
| `apps/decky/novadeck-stores/` | CREATE | New first-party plugin: the Stores QAM surface and its backend |
| `rootfs/overlay/usr/lib/novadeck/store-env` | CREATE | One place that defines the persistent credential paths and exports them for both CLIs |
| `rootfs/assemble-rootfs.sh` | UPDATE | Stage the new plugin the way the other three are staged |
| `rootfs/guard-rootfs.sh` | UPDATE | Extend the loader/plugin completeness assertion to the new plugin |
| `tests/test-decky.sh` | UPDATE | Add the new plugin to the per-plugin checks that already run against all three |
| `tests/test-store-cli.sh` | UPDATE | Assert the credential paths are on `/home`, never on `/root` or `/etc` |
| `.claude/prds/alien-games.prd.md` | UPDATE | Milestone 2 row, and amend "with no browser on it" → "with no browser we ship" |

## Tasks

### Task 1: Spike — is `BrowserView` real on our client? (gates the rest)
- **Action**: From a scratch Decky plugin on a dev card, call
  `SteamClient.BrowserView.Create({ strInitialURL: '<gog auth url>' })`, register `finished-request`,
  and log every `(currentURL, previousURL)` pair through a full GOG sign-in. Confirm the view
  renders under gamescope, that the on-screen keyboard reaches the form, and that the redirect to
  `embed.gog.com/on_login_success?code=…` is observed.
- **Why first**: `@decky/ui`'s typings are community-maintained and describe Valve's client in
  general, not our arm64 build. Everything below assumes this works.
- **Validate**: the captured `currentURL` contains a `code=` value that `gogdl auth --code`
  accepts. That is the whole milestone proven in one throwaway.
- **If it fails**: stop and re-plan around the phone-and-paste fallback before writing any of the
  rest. Do not build both.

#### Result, 2026-09-20 — PARTIAL: the browser works, the display does not

Run over CDP against Steam's own remote-debugging port (`.cef-enable-remote-debugging`, which
`novadeck-steam` already creates), so no plugin build was needed to answer it.

**CONFIRMED — the capture half of the design holds:**

- `SteamClient.BrowserView` is real on our arm64 client: `Create`, `CreatePopup`, `Destroy`,
  `PostMessageToParent`. `SteamClient.Apps.AddShortcut` is also a function (milestone 4's interest).
- A created view loads real pages and follows cross-domain redirects: `auth.gog.com` →
  `login.gog.com`, with `start-request` and `finished-request` firing and carrying the URL.
- The view appears in the CDP target list as a **fully live page**, having pulled in GOG's login
  and its reCAPTCHA frames. The browser genuinely runs.
- `EnableSteamInput()`, `SetBounds`, `SetVisible`, `SetFocus` all present and callable.

**REFUTED:** `steam://openurl/…` via `SteamClient.URL.ExecuteSteamURL` throws `Unknown method` on
this client. That candidate is gone.

**NOT ACHIEVED — nothing reaches the screen.** Three shapes were tried and all three left the
device showing only the ordinary Steam UI:

| Attempt | `strCreateURL` | On screen |
|---|---|---|
| `Create({strInitialURL})` | — (offscreen view) | nothing |
| `CreatePopup({strInitialURL})` + `window.open` | `…&requestid=5&parentpopup=0` | nothing |
| `CreatePopup({…, parentPopupBrowserID: 2})` + `window.open` | `…&requestid=6&parentpopup=2` | nothing |

The third is the interesting one: it produced the **same `parentpopup=2` shape as Steam's own
visible `QuickAccess_uid2` and `MainMenu_uid2` views**, and still did not composite. So parentage
was not the missing piece, and the conclusion is narrower than "it does not work": **a BrowserView
created from outside SteamUI's own React tree has no host to render into.** Creating one over CDP
was always going to be the cheapest test, and it has answered everything except the one thing that
needs to live inside the UI.

**Two smaller findings worth keeping:**

- The second argument of `finished-request` is **not** `previousURL` as the typings say — it came
  back as the page *title* (`"Login ● GOG.com"`). Read the code from the first argument; anything
  built on the second works by accident.
- `CreatePopup` ignores `strInitialURL`; the view sat on `about:blank` until an explicit `LoadURL`.

**Next step — spike part 2, and it needs a plugin.** SteamUI exposes a `QuickAccessMenuBrowserView`
component, which Decky itself locates and patches by name (`decky-loader/frontend/src/tabs-hook.tsx:44`).
That is SteamUI rendering a browser view *inside the QAM panel* — which is exactly where our plugin's
UI lives. The throwaway to build is a plugin that renders a login into the QAM through that
component and attaches the same handlers. Framing restrictions do **not** apply: a BrowserView is a
separate CEF browser composited by Steam, not an iframe, so the `X-Frame-Options` that would defeat
an embedded iframe are irrelevant here.

If part 2 fails too, fall back to phone-and-paste — but do not build both, and do not start Tasks
2–7 until the display question is settled either way.

### Task 2: Credential store — explicit, not relocated
- **Action**: `rootfs/overlay/usr/lib/novadeck/store-env` defines and exports
  `LEGENDARY_CONFIG_PATH` and the gogdl auth path, creates them `0700`, and is sourced by
  everything that invokes either CLI. The paths stay under `/root`, which the offload bind already
  makes persistent and shared across slots — the point of naming them is that the plugin, the
  launcher and any future caller agree on one location rather than inheriting three different
  defaults. gogdl's path is passed explicitly **before the subcommand** on every call, and its
  parent directory is created first — gogdl does neither, and a missing path costs the user their
  single-use code.
- **Mirror**: the existing `/usr/lib/novadeck/` helper scripts.
- **Validate**: offline assertions that neither path is under `/root`, `/etc` or `/var`; on
  hardware, both CLIs write there and nothing appears in their default locations.

### Task 3: Plugin skeleton, inert
- **Action**: `apps/decky/novadeck-stores` with a QAM tab showing both stores as "not connected"
  and no way to connect yet. Staged, guarded and tested like the other three.
- **Validate**: `make test` covers it; the tab renders on a dev card.

### Task 4 + 5: Epic and GOG connect flows
- **Action**: The connect button opens the store's login in a browser view, captures the code on
  `finished-request`, destroys the view, and hands the code to the backend. Epic and GOG differ
  only in URL and extraction, so one flow with two configs — the shape
  `_reference/unifideck/src/utils/authShortcutLaunch.ts` arrived at for the same reason.
- **Validate**: a real account connects on hardware, per store, with a gamepad only.

### Task 6: Status, refresh and disconnect
- **Action**: The tab shows the connected account and refreshes tokens through each CLI's own
  refresh path. A disconnect action deletes the credentials and says so.
- **Validate**: force expiry by editing `loginTime`/`expires_in`, confirm the next call refreshes
  rather than failing; disconnect leaves no token on disk.

### Task 7: Security review and the walkthrough
- **Action**: Credential-at-rest review before merge, as the PRD requires. State the posture
  honestly rather than implying more than we do: `/home` is not encrypted, so the tokens are as
  safe as Steam's own credentials on the same card — `0600`, owned by the account that uses them,
  deletable from the UI. If that is not enough, say so in the UI rather than in a comment.
- **Validate**: full walkthrough — connect both stores, reboot, confirm still connected, OTA in
  both directions, confirm still connected.

## Validation

```bash
make test                                         # offline suites incl. the new plugin checks
bash tests/test-store-cli.sh                      # credential paths are on /home
source dev.env && make sdcard                     # a card to walk through
# on device, after connecting:
#   legendary status          -> account, not <not logged in>
#   gogdl --auth-config-path <persistent> auth    -> credentials, not null
#   ls -la /root/.config/legendary                -> must NOT exist
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ~~`BrowserView` is absent or does not fire `finished-request`~~ | **Resolved** | It exists and fires; see Task 1's result |
| **A BrowserView created outside SteamUI's React tree never reaches the screen** | **Observed** | The real risk, and it is now the live one. Spike part 2 tests the `QuickAccessMenuBrowserView` host from inside a plugin; phone-and-paste remains the fallback and stays unbuilt until part 2 answers |
| The login page is unusable with a gamepad and the on-screen keyboard | Medium | Part of Task 1's acceptance, not a later discovery — if the form cannot be filled, the flow is dead regardless of the API |
| Steam changes or removes the browser-view API in a client update | Low | It is how Steam renders its own store pages; but the plugin must degrade to a clear "cannot open sign-in" message rather than a blank view |
| A failed credential write spends the user's single-use code | **Observed in milestone 1** | Create the directory and verify it is writable *before* opening the browser, not after the code arrives |
| Tokens written somewhere per-slot and silently lost at the next OTA | Low | `/root` is an offload bind from the shared `/home` tree, so the default locations already persist; Task 2 makes the paths explicit and the walkthrough still OTAs in both directions to prove it |
| ~~`/root` was writable although the root is read-only~~ | **Explained** | The root *is* `ro`; `/root` is an offload bind from `/home`. Not a dev-only behaviour, so the milestone-1 hand-run reproduces on a release card |
| Refresh tokens rotate and a stale copy locks the user out | Medium | Let each CLI own its own refresh; never cache a second copy |
| The QAM surface implies more than exists (browse, install) | Medium | The tab says connected/not connected and nothing else until milestone 3 |

## Acceptance

- [ ] Task 1's spike answered on hardware, with the captured redirect URL recorded
- [ ] Epic and GOG both connect from Game Mode, gamepad only, no SSH and no typed code
- [ ] Credentials live on the shared `/home`; nothing is written under `/root` or `/etc`
- [ ] Connection survives a reboot **and** an OTA in both directions
- [ ] A forced token expiry refreshes rather than failing
- [ ] Disconnect removes the credentials
- [ ] Security review of credential-at-rest completed before merge
- [ ] `make test` green, including the new plugin's checks
