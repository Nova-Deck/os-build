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
worth chasing.

**That correction was then over-applied, and this is the second correction.** Having established
that `/root` persists, an earlier draft concluded the credentials could stay there. Persistence was
never the objection — ownership is. The credentials belong to the person using the device, the
launch path that will read them runs as `deck`, and `/root` sits outside anything that resets or
backs up user data. They go in `/home/deck`, owned by `deck`; see Task 2.

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

~~**Fallback, designed but not built:** phone-and-paste — QR to the login page, user pastes the
code into a small page the device serves.~~ **Struck 2026-09-20**: the spike proved the on-device
flow end to end, so the LAN listener and its security review are not needed and will not be built.

**Amended by the spike:** step 2 is not `BrowserView.Create` — it is
`Navigation.NavigateToExternalWeb(url)` from inside the plugin, because a view created by an
outside caller renders nowhere. Step 4 reads the redirect from Steam's CEF target list on
`127.0.0.1:8080` rather than from a `finished-request` handler, since the browser belongs to
SteamUI and we hold no handle on it.

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

#### Result of part 2, 2026-09-20 — COMPLETE. Display, capture and exchange all proven

A throwaway Decky plugin calling `Navigation.NavigateToExternalWeb(url)` (`@decky/ui`
`modules/Router.d.ts:61`) **puts the GOG login on screen in Game Mode**. The user signed in with
the gamepad; `SharedJSContext` navigated to `steamloopback.host/routes/externalweb`, which is
SteamUI's own external-browser route hosting the page.

That is why part 1 failed and this did not, and the distinction is the whole finding: **a browser
view has to be created by SteamUI's own React code, not by an outside caller.** The API was never
the problem — `Create`, `CreatePopup` and `parentPopupBrowserID` all worked and all rendered
nothing, because nothing in the UI owned them. Called from inside a plugin, the same machinery
renders.

The redirect was then observed carrying the code:

```
embed.gog.com/on_login_success | https://embed.gog.com/on_login_success?origin=client&code=Md9hLkfppUeq…
```

and the captured code was handed straight to `gogdl --auth-config-path … auth --code`, which
returned a full credential set (`access_token`, `refresh_token`, `user_id`, …), exit 0. **A
192-character single-use code went from a gamepad login to a live GOG token with nothing typed and
nothing carried off the device.**

**Decision: the CEF debugging port is a fair dependency.** The redirect is read by polling Steam's
CEF target list on `127.0.0.1:8080`, which exists because `novadeck-steam` writes
`.cef-enable-remote-debugging`. That is a debugging facility, and depending on one in shipped code
deserved a second look — but Decky's own frontend is *injected* over that same port, so every
Decky plugin already depends on it absolutely. If the port is gone, our plugin is not running
either. The dependency is therefore not new, and the user confirmed it stays.

**Use the HTTP `/json` endpoint, not a websocket**, and this is not a style preference:
`tests/test-decky.sh:100` records that Decky's CDP *websocket* can drop permanently when the tab
goes stale mid-connect, which is what `novadeck-decky-watchdog.service` exists to recover. Polling
a stateless HTTP endpoint adds no consumer to that fragile path; holding a second websocket would.

**Consequences:** the phone-and-paste fallback is **struck, not deferred** — no QR, no LAN
listener, and no security review for a listener that will not exist. Tasks 2–7 are unblocked.
Epic is the same shape with one difference that is not a copy-paste: its `authorizationCode`
arrives in a JSON body rather than a query parameter, so Task 4 reads the *page*, not just the URL.

### Task 2: Credential store — in the user's home, owned by the user
- **Action**: `rootfs/overlay/usr/lib/novadeck/store-env` defines and exports
  `LEGENDARY_CONFIG_PATH` and the gogdl auth path under **`/home/deck/.local/share/novadeck/stores/`**,
  creates the tree `0700` **owned by `deck`**, and is sourced by everything that invokes either CLI.
  gogdl's path is passed explicitly **before the subcommand** on every call, and its parent
  directory is created first — gogdl does neither, and a missing path costs the user their
  single-use code.
- **NOT `/root`.** An earlier draft of this plan said the paths could stay there because the offload
  bind makes `/root` persistent. Persistence was never the objection:
  - **These are the user's credentials, not the system's.** `/root` is the root account's home; the
    account being authenticated is the person holding the device.
  - **The plugin is not the only caller.** It runs as root (`plugin.json` `flags: ["root"]`), but
    milestones 3, 5 and 6 invoke these CLIs from the launch path, which runs as `deck`. Credentials
    only root can read would work in the plugin and fail everywhere else — the exact failure
    `novadeck-framegen/conf.py:78-84` already documents for lsfg-vk's config: *"A root-owned
    conf.toml would make lsfg-vk's own writes fail and the UI unable to fix it."*
  - **`/root` is outside the user-data model.** Anything that resets or backs up user data will
    reason about `/home/deck`; credentials hidden in `/root` would survive a reset that the user
    expected to clear their accounts, which is a worse failure than losing them.
  - `/root` was never a decision — it is where milestone 1's SSH session happened to run.
- **Mirror**: `novadeck-framegen/py_modules/novadeck_framegen/conf.py:85-97` — write to a temp file
  in the target directory, `os.chown` it to the directory's existing uid/gid, `os.replace` it in
  atomically. The plugin runs as root, so every write into `/home/deck` must restore ownership or
  it hands the user a file their own tools cannot rewrite.
- **Validate**: offline assertions that the configured paths are under `/home/deck` and never
  `/root`, `/etc` or `/var`; on hardware, `stat -c %U` on every credential file returns `deck`, and
  nothing appears in either CLI's default location.
- **Mirror**: the existing `/usr/lib/novadeck/` helper scripts.
- **Validate**: offline assertions that neither path is under `/root`, `/etc` or `/var`; on
  hardware, both CLIs write there and nothing appears in their default locations.

### Task 3: Plugin skeleton, inert
- **Action**: `apps/decky/novadeck-stores` with a QAM tab showing both stores as "not connected"
  and no way to connect yet. Staged, guarded and tested like the other three.
- **Validate**: `make test` covers it; the tab renders on a dev card.

#### Tasks 2 + 3 — hardware result, 2026-09-20

One dev card (`NOVADECK_GIT=a9c8260`, mode `dev`) gated both.

| Check | Result |
|---|---|
| `store-env` ships executable | `-rwxr-xr-x` at `/usr/lib/novadeck/store-env` |
| It prints the three paths | all under `/home/deck/.local/share/novadeck/stores` |
| `--ensure` resolves the **real** `deck` user | `deck:deck 700` on all three directories — the offline suite could only drive this through an override, since the host has no `deck` |
| The plugin ships and loads | staged to `/usr/share/decky-plugins/novadeck-stores`, synced to homebrew, `Loaded NovaDeck Stores (v0.1.0)` |
| The QAM panel renders | **Epic Games — Not connected / GOG — Not connected** |

That last row is worth more than it looks. Reading "Not connected" rather than an error means the
backend spawned `store-env` successfully **from inside the x86 PluginLoader running under FEX** —
i.e. `_clean_env` really does keep PyInstaller's `LD_LIBRARY_PATH` off an aarch64 shell. That is
the one environment where the bug could exist and the only place it could be proven.

**Still open from Task 2, and structurally not closable yet:** that a *root-running plugin* writing
into that tree restores `deck` ownership. `--ensure` proves the directories; the first credential
file is not written until Task 4 gives it a caller, so `stat -c %U` on a real token file stays on
the acceptance list.

**Correction to an expectation, not a defect:** guard assertion 9 never ran — a dev build skips the
sealed-root guard (`[DEV] skipping the sealed-root guard`). What actually fails a build with a
missing plugin dist is the staging loop's own `[ -s dist/index.js ]` check, plus the new list-drift
assertion in `make test`. The guard is a release-path backstop, not the first line of defence.

### Task 4 + 5: Epic and GOG connect flows
- **Action**: The connect button opens the store's login in a browser view, captures the code on
  `finished-request`, destroys the view, and hands the code to the backend. Epic and GOG differ
  only in URL and extraction, so one flow with two configs — the shape
  `_reference/unifideck/src/utils/authShortcutLaunch.ts` arrived at for the same reason.
- **Validate**: a real account connects on hardware, per store, with a gamepad only.

#### Tasks 4 + 5 — built 2026-09-24, NOT yet HW-gated

The Action above predates the spike and is superseded by it: there is no view we create and no
`finished-request` handler. What was built:

| Step | Where | How |
|---|---|---|
| Prepare | `main.py start_connect` | `store-env --ensure`, then `test -w` as `deck` (via `systemd-run`, see Exchange) on both directories — every failure that would spend the code happens here, before the login is on screen |
| Open | `Content.tsx signIn` | `CloseSideMenus()` then `NavigateToExternalWeb(url)` — the spike's proven path |
| Capture | `connect.py capture` | Polls CEF `/json` once a second, up to 10 min. GOG: `code=` from the URL. Epic: one `Runtime.evaluate(document.body.innerText)` on the redirect page's **own** target (`cdp.py read_body`) — never SharedJSContext, so Decky's injection socket is untouched |
| Exchange | `cli.py exchange` | The CLI runs **as `deck`** in a transient unit (`systemd-run -p User=deck --pipe --wait`), so its files are `deck`-owned from creation — this closes Task 2's open ownership item by construction rather than by chown. Host PID 1 starts it natively: under FEX a direct child resolves `#!/usr/bin/python` to the x86 guest's python, which has neither CLI. stdout discarded (gogdl prints the tokens); `--pipe` keeps it out of the journal and `--description` keeps the code out of the "Started" line |
| Verdict | `main.py _connect_flow` | Read the credential file back — **neither CLI's exit status means anything**: `legendary auth` logs a failure and exits 0, `gogdl auth` prints `{"error": true}` and exits 0 |
| Close | `index.tsx onConnectDone` | `connect_done` event → `Navigate("/library/home")` (only if the redirect was captured, i.e. the page is still up) + a toast. The listener lives in `definePlugin`, because the QAM panel is unmounted while the browser shows |

**A leftover redirect is ignored.** The target list is snapshotted before the login opens; a
redirect page still carrying an earlier, already-spent code would otherwise be captured on the
first poll and fail the exchange before the user saw anything. `tests/test-store-cli.sh` drives
this, plus the redirect matching, code extraction and the `systemd-run`/stdout contract.

**Epic's login URL is `legendary.gl/epiclogin`, not one we build.** legendary can replace its
client id from its remote config (`egs.py update_egs_params`), and the code has to be issued to
the client id legendary exchanges it with; upstream's own helper tracks that.

**Security review, 2026-09-24.** One CRITICAL found and fixed: `store-env --ensure` ran
`install -d -o deck` as root on paths inside `/home/deck`, and `install` follows symlinks — any
process running as `deck` (a game) could plant a link and have root chown its target. Task 2
introduced it; the sign-in flow made it reachable on every connect. The tree is now created *as*
the user, and the suite asserts there is no `install -o`. Also hardened: the Epic page read only
connects to a loopback `:8080` socket (a squatted port cannot aim root elsewhere), and the CLI
gets `PATH`/`LANG`/`LEGENDARY_CONFIG_PATH` rather than root's environment.
**Accepted:** the code sits in `/proc/<pid>/cmdline` while the CLI runs, readable by any `deck`
process, which could race to replay it. Both CLIs accept it only on argv; the code is single-use
and spent within the call. Anything that can read it can already read the stored tokens.

**Hardware, 2026-09-25 (Pocket ACE, dev card @ `5058059`):**
- PROVEN: Epic's code is captured — the websocket to the redirect target works from inside the
  x86 PluginLoader under FEX, and `connect_done` reaches the frontend listener.
- FAILED, FIXED: `NavigateBack()` left the login on screen. The external-web route spends Back on
  the page's own history, and the login is a redirect chain. Now `Navigate("/library/home")`,
  checked live over CDP (`/externalweb` → `/library/home`). The hidden browser target outlives
  the route (still listed in `/json`); the snapshot already ignores a leftover redirect.
- FAILED, FIXED: both exchanges exited **1** with no credential file. stderr, captured once to a
  root-only tmpfs file: `ModuleNotFoundError: No module named 'legendary'` — the CLI never
  started. FEX resolves the children's paths against the x86 guest rootfs, whose python has
  neither CLI (a native replay over SSH cannot see this, which is why it exited 0). Now run via
  `systemd-run`; the exact argv was reproduced under FEX (`legendary --version` via guest bash).

**Hardware, 2026-09-25, second card (Pocket ACE, dev card @ `6cec0ce` + the two fixes above):**
- PASSED: GOG and Epic end to end — `gog: exchange exited 0, connected=True`,
  `epic: exchange exited 0, connected=True`. `auth.json` and `user.json` hold the full token sets.
- PASSED: for both stores the login page closed on its own and landed on the Home library.
- PASSED: every file under `~deck/.local/share/novadeck/stores/` is owned by `deck` (Task 2's
  acceptance item); no `/root/.config/legendary`. The boot's journal carries no token, no
  `authorizationCode`, no `--code`: the units log only `Started novadeck-stores <cli>`.
- For Task 7: both token files are mode `644` (the CLIs' own default). The `0700` directories
  keep them private, but the files themselves are not.

### Task 6: Status, refresh and disconnect
- **Action**: The tab shows the connected account and refreshes tokens through each CLI's own
  refresh path. A disconnect action deletes the credentials and says so.
- **Validate**: force expiry by editing `loginTime`/`expires_in`, confirm the next call refreshes
  rather than failing; disconnect leaves no token on disk.

**Implementation, 2026-09-25 (offline suite green); hardware walkthrough passed 2026-09-26 on the Pocket ACE:**

| Piece | Where | What |
|---|---|---|
| Status | `status.py` | Adds `expired`, from each CLI's own test: legendary's `expires_at`, gogdl's `loginTime + expires_in`. The panel still gets only store / connected / account / expired. GOG has no account name offline (gogdl stores a user id) |
| Refresh | `cli.py refresh_argv` | Epic: `legendary list-installed --check-updates`, the lightest command that runs legendary's login (`status` also fetches the whole library). GOG: `gogdl … auth`, which renews an expired token and writes it back |
| When | `Content.tsx` | Every panel open, for each connected store, in the background. The row shows the file's answer at once and "Checking the session…" until the CLI answers |
| Verdict | `main.py refresh` | Read back from the file. Epic refused: legendary deletes `user.json`, so the row turns into Sign in. Offline, or GOG refused: the file stays expired, and the row reads Expired, "could not be renewed", with Sign in again (straight over the dead session, the exchange overwrites it) stacked above Disconnect in a `flow-children="column"` Focusable. gogdl cannot tell those two apart, so the text doesn't either |
| Disconnect | `cli.py disconnect_argv` | Behind a confirm modal. Epic: `legendary auth --delete`. GOG: `rm -f` of `auth.json` as `deck` (gogdl has no logout). Local only: neither CLI can end the session with the store, and the modal says so |
| Serialized | `main.py _LOCKS` | One CLI call per store at a time, the sign-in exchange included. gogdl rewrites its whole file with no lock, so a refresh in flight would otherwise put back credentials a disconnect had just removed |

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
| ~~A BrowserView created outside SteamUI's React tree never reaches the screen~~ | **Resolved** | True, and the answer is to let SteamUI create it: `Navigation.NavigateToExternalWeb()` from inside the plugin renders, and the full flow was proven to a live GOG token |
| The redirect is read by polling Steam's CEF debug port rather than an event | Accepted | Decky is itself injected over that port, so the dependency is not new; poll the stateless HTTP `/json`, never a second websocket (`tests/test-decky.sh:100`) |
| Epic's code is in a JSON body, not a query parameter | Medium | Task 4 reads page content, not just the URL — do not assume GOG's shape transfers |
| The login page is unusable with a gamepad and the on-screen keyboard | Medium | Part of Task 1's acceptance, not a later discovery — if the form cannot be filled, the flow is dead regardless of the API |
| Steam changes or removes the browser-view API in a client update | Low | It is how Steam renders its own store pages; but the plugin must degrade to a clear "cannot open sign-in" message rather than a blank view |
| A failed credential write spends the user's single-use code | **Observed in milestone 1** | Create the directory and verify it is writable *before* opening the browser, not after the code arrives |
| Tokens written somewhere per-slot and silently lost at the next OTA | Low | `/home/deck` is the shared user partition; the walkthrough still OTAs in both directions to prove it |
| Credentials written as root into the user's home, so the launch path cannot read or replace them | Medium | The `os.chown`-to-owner write from `novadeck-framegen/conf.py:85-97`, plus a hardware check that `stat -c %U` returns `deck` on every credential file |
| ~~`/root` was writable although the root is read-only~~ | **Explained** | The root *is* `ro`; `/root` is an offload bind from `/home`. Not a dev-only behaviour, so the milestone-1 hand-run reproduces on a release card |
| Refresh tokens rotate and a stale copy locks the user out | Medium | Let each CLI own its own refresh; never cache a second copy |
| The QAM surface implies more than exists (browse, install) | Medium | The tab says connected/not connected and nothing else until milestone 3 |

## Acceptance

- [x] Task 1's spike answered on hardware, with the captured redirect URL recorded — and taken
      further than the gate asked: the captured code was exchanged for a live GOG token
- [ ] Epic and GOG both connect from Game Mode, gamepad only, no SSH and no typed code
- [ ] Credentials live under `/home/deck`, owned by `deck`; nothing under `/root`, `/etc` or `/var`
- [ ] Connection survives a reboot **and** an OTA in both directions
- [ ] A forced token expiry refreshes rather than failing
- [ ] Disconnect removes the credentials
- [ ] Security review of credential-at-rest completed before merge
- [ ] `make test` green, including the new plugin's checks
