# novadeck — DONE

Resolved items, split out of [TODO.md](TODO.md) on 2026-08-04 so the open queue is
scannable. Nothing here is an archive to be pruned: these entries carry the measurements,
the HW-validation dates and the dead ends, and open items in TODO.md reference them by
name. Order is as it was in TODO.md — roughly the order things were closed, not a ranking.

## Closed

- [x] **The GX rail is GMU-owned, so gpucc must not vote on it — HW-VALIDATED on BOTH SoCs
  2026-08-10** (`6f973e0`). Ported from an upstream-peer change whose author reports it fixing GX clock issues on
  SM8550/SM8650. Two coupled kernel patches, and neither alone is the fix:
  - `0120-...gpu_cc_power_requirements_reality_check.patch` — upstream's RFC describes gpucc as
    needing CX/MX/**GFX**/MXC. GX is owned by the GMU on these SoCs, so a gpucc *device* vote on it
    fights the GMU's own and the clock wedges. Our copy drops `RPMHPD_GFX` from the sm8550 and
    sm8650 hunks. The sm8250 hunk stays upstream-verbatim — nothing is built from it and the
    ownership claim was never checked there.
  - `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` — replaces the older
    `...no-max-clamp...` patch, which set `.state_synced = true` on gfx/gmxc from boot to dodge
    rpmhpd's pre-sync clamp-to-top-corner. That overshoots the other way and lets the vote fall to
    corner 0 or RETENTION, below what the GMU needs for its first ramp. The new one adds
    `.presync_floor` (hold at `max(corner, pd->enable_corner)` until `sync_state`) plus
    `.skip_retention_level` so the floor is a corner logic can run at.
  - **What was actually measured.** BOTH SoCs booted, which matters because `0120` edits a separate
    dtsi hunk for each and they could have failed independently:
    - **SM8650 — Pocket S2**, dev card to OOBE: the GPU probed, the panel modeset and gamescope
      completed its startup handshake. That handshake is what arms `novadeck-boot-good.path`, so
      reaching OOBE *is* the evidence drm/msm bound and took DRM master. Zero rpmhpd or gpucc errors
      in the journal (read offline from the offload journal on the card).
    - **SM8550 — Pocket ACE**, same check, same result.
    - Verified in the shipped artifact too, not just the source: `dtc` on
      `qcs8550-ayaneo-pocketace.dtb` and `sm8650-ayaneo-ps2.dtb` shows
      `power-domains = <… 0x00 … 0x08 … 0x0a>` = CX(0), MX(8), MXC(10) — three entries, GFX(3) absent.
  - **NOT measured, deliberately recorded as a gap:** nothing ran past OOBE on either board — no
    game, no FPS number. So this establishes that the GPU still comes up, NOT that the GX clock
    behaviour improved, which is the claim the patch is actually making and is still unmeasured. The
    instruments for it are [[sm8650-gpu-liveness-probing]] and
    [[gamescope-stats-pipe-fps-instrument]] on a title with a known number.
  - **A boot does not clear the SM8550 GMU wedge** ([[sm8550-gmu-wedge-ifpc-cpuidle]]). That wedge is
    an idle/runtime failure, not a probe-time one, so Pocket ACE reaching OOBE says nothing about it.
    This is now a THIRD variable in that subsystem alongside the cpuidle quirk and our IFPC patch —
    if the wedge reappears on SM8550, suspect this before either of those.
  - **Patch-apply baseline**, re-run against the pinned 7.1.6 tree and recorded in `kernel/SOURCE.pin`:
    53/53 apply cumulatively, zero rejects, 10 need fuzz, and 0120/0121 are not among the 10.

- [x] **A Steam client self-update paints NOTHING — black panel for minutes — FIXED and HW-VALIDATED
  2026-08-06** (gamescope patch `0005-steamcontrolled-steam-focus-fallback.patch`). Observed
  2026-08-06 on a release unit (v0.2.1, slot A) taking client `1785347151` -> `1785979169`: 13.5
  minutes of black screen with no progress, and a power-cycle during it corrupts the download.
  - **ROOT CAUSE.** `novadeck-session` passes `--steam`, which flips
    `cv_backend_virtual_connector_strategy` from `SingleApplication` to `SteamControlled`
    (`main.cpp:771-774`). That makes `controlledFocus` true for the whole session, and
    `pick_primary_focus_and_override()`'s `if ( !focus && ( !globalFocus || !controlledFocus ) )`
    then withholds the generic `vecPossibleFocusWindows[0]` fallback from the GLOBAL pass. That
    leaves `focusControlWindow` and `ctxFocusControlAppIDs` as the only routes to global focus — and
    **Steam publishes both**, so on a gamescope that has not yet hosted SteamUI neither exists.
    Measured: `ctrlwin=0x0` always, `ctrlappids` empty early in boot and only later `[413091, 769]`.
    The bootstrapper's update dialog matches neither, `focus` stays NULL, nothing is composited, and
    the backend commits ZERO atomic flips. Not a filter problem — **selection cannot reach a window
    that no filter rejects.**
  - **THE FIX.** After the generic fallback, a last-resort route: if `focus` is still NULL, take the
    highest-priority candidate for which `window_is_steam()` is true. Four guards keep the blast
    radius at exactly that hole — `!focus` (so anything Steam actively asked for has already matched
    and a live client's choice is never overridden), `globalFocus` (the local pass keeps its existing
    path), `eStrategy == SteamControlled` (the other three strategies are untouched), and
    Steam-windows-only (it will never select a game, which is the behaviour the withheld fallback
    exists to protect). `localGameFocused` is computed as `focus->appID != 0`, matching the generic
    fallback. Placed AFTER the generic block, not inside the `SteamControlled` branch: inside, it
    would also fire on the local pass and could pick something other than `[0]`, changing a path that
    already works.
  - **HW VALIDATION 2026-08-06 — the organic path, on a real reboot.** Dev card with the patch plus
    the instrumentation armed. Staged an update, then rebooted from the SteamUI power menu
    (`boot_id` confirmed changed `be905fee…` -> `fb8bae85…`, session log truncated). The device came
    up straight into a VISIBLE updater:
    ```
    cand: global pick from 1 candidate(s), controlled=1(strategy=SteamControlled[1]<- ctrlwin=0x0 ctrlappids=0[])
        cand:   focus  0x600002 "Steam" pid=915 appID=769 or=1 bigpicture=1 is_steam=1
                       geom=2560x1440+1+1 queue=1 done=1 lastid=3 -> PRESENTING
    ```
    Fresh gamescope that had never hosted SteamUI, `ctrlappids` empty, override-redirect
    bootstrapper dialog — the exact configuration that produced 13.5 minutes of black on the release
    unit, now presenting at boot.
  - **Earlier the same day, the same result via a manufactured cold start** (kill the client so the
    session restarts and gamescope is fresh): identical line with `pid=5772`, ran to
    `Update complete, launching Steam...` with the dialog visible throughout, SteamUI returning
    normally afterwards (`ctrlappids=2[413091,769]`, `-> PRESENTING`).
  - **BONUS, measured on a patched cold boot:** SteamUI ITSELF now reaches `-> PRESENTING` while
    `ctrlappids=0[]` — the fallback carries Big Picture on screen before Steam publishes its control
    atoms, which under the old code left global focus NULL until they landed. So `0005` also shrinks
    the post-gamescope boot black gap. Duration unmeasured (gamescope's focus lines are
    untimestamped) — see the splash item in TODO.md.
  - **How the boot install actually works** (this corrects the original entry's mechanism): the
    startup check CANNOT discover an update — it runs before the network is up and fails all three
    mirrors with `http error 0` every time. Discovery is the in-session background loop. But once
    that has staged the packages locally, the next boot's startup check fails the network as usual
    and then installs from the staged copy anyway: `Download failed: http error 0` 21:23:21 ->
    `Installing update...` 21:23:21 -> `Show window` 21:23:22. That is why the bug presented as a
    BOOT-time black screen despite the update being found in a previous session.
  - **The commit-fence mechanism is NOT a second blocker.** `window_has_commits()` gating
    (`pick_primary_focus_and_override` only publishes a pick whose queue holds a `done` commit) is
    real, and the dialog did log `-> HELD, no done commit` twice before settling to
    `queue=1 done=1 -> PRESENTING`. Transient. The fix is sufficient, not merely necessary.
  - **CORRECTION — it is not "appID == 0 can never take focus".** `xprop` on the release unit showed
    no `STEAM_GAME` (hence the original reading), but gamescope's internal `w->appID` for that window
    is 769 via `isSteamLegacyBigPicture`. Both are true and neither is the blocker: the blocker is
    that `ctxFocusControlAppIDs` is **empty**, so no appID could match whatever its value.
  - **ONLY the cold path was ever broken.** Two later runs did NOT exercise the fix, because
    `ctxFocusControlAppIDs` is read from a root-window property that survives the client exiting. If
    gamescope has already hosted SteamUI, the atoms are still set and the pre-existing appID route
    matches the updater unaided (measured: `ctrlappids=2[413091,769]`, updater `appID=769`,
    presented). The broken case is specifically a gamescope that has never seen Steam.
  - **Do NOT re-derive these dead ends.** The window passes EVERY filter (`IsViewable`,
    `InputOutput`, opaque, `window_is_steam()` true) and IS in `vecPossibleFocusWindows`. A gamescope
    version bump is not the fix (3.16.25 reproduces identically). A peer's `GAMESCOPE_FALLBACK_APPID`
    patch cannot help — it keys on an appID, and no appID is matchable when the control list is
    empty. `backend.cpp:20` defaulting to `SingleApplication` is real but irrelevant: `--steam`
    overrides it, and any analysis starting from "we are SingleApplication" is void — that wrong
    assumption cost most of a session. `--steam` itself cannot be dropped: the startup handshake,
    night mode and the colour pipeline all ride it.
  - **Do NOT read `GAMESCOPE_FOCUSABLE_WINDOWS` as evidence** — `:4192-4195` deliberately drops
    override-redirect windows from the property *reported to Steam*, independently of actual focus
    selection. Same trap for `GAMESCOPE_FOCUSED_WINDOW`/`_APP`, written with `nelements = 0` when the
    appID is 0, so "unset" and "none" are indistinguishable. The trustworthy signal is the flip
    counter (`gamescopectl backend_info`, `Total Presents Queued`: 0 during the update, 1484 once Big
    Picture maps).
  - **THE WINDOW, MEASURED** (dev card `3e06d48`, live while the dialog was up and the panel black):
    ```
    0x600002 "Steam"   2560x1440+1+1      <- fullscreen, NOT the small dialog seen under Xvfb
      Class: InputOutput / Map State: IsViewable / Override Redirect: yes / Depth: 24
    properties, ALL of them:
      WM_NAME(UTF8_STRING) = "Steam"
      STEAM_BIGPICTURE(CARDINAL) = 1
    ```
    `STEAM_BIGPICTURE=1` is load-bearing: it is gamescope's `steamAtom` ->
    `w->isSteamLegacyBigPicture` -> `window_is_steam()` true, which is both why the window is exempt
    from the one override-redirect exclusion that names it (`:8650`, `// bootstrapper is override
    redirect :(` — Valve added that clause *for* the bootstrapper) and what the fix keys on.
  - **The instrumentation that localized it** is
    `packages/gamescope/patches/0006-focus-candidate-instrumentation.patch`, deliberately kept OUT of
    `source.pin` (carrying it makes `fetchlock.sh` report the gamescope row as built from UNADOPTED
    sources). Arm with `export GAMESCOPE_DEBUG_FOCUS=1` in `/etc/novadeck/session.conf` — the only
    way to catch this at boot, before SSH is up — or `gamescopectl debug_focus_candidates 1` live;
    output goes to `~/.local/share/sddm/wayland-session.log`, `grep 'cand:'`. Two notes worth not
    re-deriving: gate it on a ConVar whose default reads `env_to_bool( getenv(...) )` so it works
    both at boot and live, and collapse repeated reports or a 13.5-minute stall writes the same line
    thousands of times to the SD card.
  - **Steam's stderr is NOT in the journal** — it lands in
    `~/.local/share/sddm/wayland-session.log`, because SDDM owns the session's stdio. Anyone grepping
    the journal for update-UI evidence will wrongly conclude the UI never ran. Worth wiring the
    session's stderr into the journal so it is greppable with everything else.
  - **Backend differs from the host harness:** under Xvfb in the build container the bootstrapper
    selects `xwin`; on device it selects `glx` (because `msm_dri.so` is present and GLX works).
    Anything reproduced host-side exercises a different code path.
  - **How to force a client update on demand.** In `~/.local/share/Steam/package/`, edit
    `…linuxarm64.manifest`'s `"version"` DOWN, `chown deck:deck` it afterwards if you used `sed -i`
    (which rewrites via a temp file and leaves it root-owned — Steam must be able to write it), and
    `rm -f *.installed`. Then reboot, let the session sit ~15s so the background loop discovers and
    stages it, and reboot again — the second boot installs it with the dialog up. The "reboot twice"
    shape is correct; only its stated mechanism was wrong, per the note above.
  - **Why it was worth fixing at all:** a black unresponsive screen after boot invites exactly one
    user action — hold the power button — which interrupts the download and guarantees a longer,
    messier recovery next boot. Self-reinforcing, and on a handheld with no activity indicator there
    is no way to tell it from a hang. It was NOT fixed by drawing our own progress dialog: Steam's
    works and is wired to real percentages, and a replacement would duplicate a working upstream UI
    while leaving the actual defect unfixed. `STEAM_UPDATEUI_PNG_BACKGROUND` is real in our binary
    and sets the update UI's background image — a branding lever now that presentation works, and
    unrelated to this defect.

- [x] **rauc's D-Bus policy lets ANY local process install a bundle — ACCEPTED AS A DESIGN CHOICE
  2026-08-04. Closed as decided, NOT as fixed: the exposure below is unchanged and still ships.**
  Found 2026-08-03 while wiring the SteamUI update path. rauc 1.15.2 ships
  `data/de.pengutronix.rauc.conf` = `<policy context="default"><allow
  send_destination="de.pengutronix.rauc"/></policy>`, whose own comment reads *"This config allows
  anyone to control rauc"*, and it ships **no polkit policy at all** (checked at `v1.15.2` in
  `_reference/rauc`). So any local process — including anything the Steam client launches, i.e. any
  game — can call `InstallBundle`, overwrite the inactive slot and arm a trial, or deny service by
  holding the installer busy.
  **Bounded, not harmless.** The signature is the real gate: the device installs only a bundle that
  chains to `/etc/rauc/keyring.pem` with `check-purpose=codesign`, so this is not arbitrary code
  execution and an attacker cannot install their own image. What they CAN do is force a slot
  overwrite + reboot-arming with a validly-signed bundle, at a moment of their choosing.
  **Already shipping — NOT introduced by the update work.** It is written down because the UI
  path is what makes it reachable by design rather than by someone with a shell.
  **Why accepting it is the right call, not a deferral.** This is a single-user handheld: "any local
  process" is, in practice, "anything the user chose to run", and there is no local privilege
  boundary here worth defending — the user already owns the device. The control that actually
  matters is cryptographic and intact, and it is doing the job a bus policy would only duplicate
  less well. Narrowing the policy means shipping our own bus policy or polkit action, i.e. a
  privilege-model change with its own hardware check that a legitimate install still works from the
  SEAT session (not just over SSH — they are **not** the same D-Bus subject). That is real cost and
  a real new way to break updates, bought against a threat that reduces to nuisance: a hostile game
  can make the device write a slot and arm a trial with one of OUR OWN signed images.
  **The trigger that would reopen this, stated so it is recognisable:** the signature gate is
  load-bearing for the whole argument, so anything that widens who can produce a bundle this device
  accepts invalidates it — a second CA in `/etc/rauc/keyring.pem`, community or third-party signed
  builds, or a signing key that leaves our control. Likewise if the device ever grows a genuine
  multi-user, kiosk or untrusted-local-code model. Absent one of those, leave it.
  **Correction this forces elsewhere, kept because it is a durable fact:** the HW-validated "A REAL
  release bundle IS verifiable on hardware" item in this file credits "rauc's D-Bus service +
  polkit" for the unprivileged install as `deck`. Polkit had nothing to do with it; the bus policy
  is simply open. Corrected in place.

- [x] **Faster arm64 package builds: qemu-master + native distcc cross-compiler — WON'T-DO
  2026-08-04. The local overlay cache already took the pain away.** The premise was that overlay
  packages build inside an emulated aarch64 environment, where qemu runs the compiler
  instruction-by-instruction, so every build pays full emulated compile cost. That premise no
  longer describes what we actually experience: `packages/build-overlay.sh` keeps a per-package
  content-hash stamp at `work/repo/<arch>/.stamps/<name>.hash` (computed by `packages/inputhash.sh`)
  and rebuilds a package **only when its inputs change** — everything else logs `up-to-date — skip`.
  The steady-state cost is therefore not "compile the overlay under qemu", it is "compile the one
  or two packages you touched", and the emulation penalty on that is something we are willing to
  pay. Optimising the cold-build path is optimising the case we rarely hit.
  **What was proposed, recorded so nobody re-derives it from scratch:** restructure `packages/`
  into a docker-compose topology — a master aarch64 (qemu) container running `makepkg`/`pacman` so
  the build sees a native arm64 sysroot and resolves deps correctly, delegating the actual compiles
  over **distcc** to native amd64 daemon containers running an `aarch64-linux-gnu` cross-toolchain,
  leaving only linking/configure/packaging under qemu. It would have kept per-package isolation
  ([[overlay-isolate-per-package-container]]): compose can spin the master fresh per package while
  the distcc workers persist.
  **Why it is not merely unnecessary but a bad trade**, which is the part worth keeping: distcc
  would have to use a cross-gcc at ABI/version parity with the holo toolchain — a second toolchain
  to pin, and a silent-mismatch class of bug in the compiler itself, which is the worst place to
  have one. Packages doing arch-native codegen or running built binaries mid-build (tests,
  `-march=native`) would not offload cleanly, so the topology needs per-package exceptions. That is
  real ongoing complexity in the build system's most load-bearing component, bought to speed up a
  path the stamp cache already makes rare. Revisit only if cold rebuilds become routine — e.g. a CI
  runner with no persistent `work/repo` that rebuilds the whole overlay every run.
  Relates to [[builds-use-docker-crosscompile]], [[overlay-package-pipeline]].

- [x] **Release cards ship slot B empty with no `B.conf` — HW-VALIDATED 2026-08-04** (`7f49ef2`).
  The card compresses 8.97 -> 5.08 GiB (pigz -6, CI's settings): 3.89 GiB and 43% off every
  download, and `KEEP=1` in `images/publish-card.sh` was re-checked against the real number and
  still holds. Validated end to end on device .192: the card boots A; `novadeck-bootctl` reports B
  as `(no config on the ESP)` rather than as a second candidate; `rauc install` creates
  `/esp/SteamOS/conf/B.conf` through `ensure_exists()`'s `bc create` branch and the device then
  boots B, confirmed independently by `novadeck-bootctl`, `/var/lib/novadeck/slot` and `rauc`.
  `make verify-card` asserts `B.conf` is ABSENT on an empty-B card.
  - Worth keeping: an empty-B card is the ONLY state that reaches the `bc create` branch — on a
    dev card the conf already exists and `ensure_exists()` short-circuits. And omitting the conf is
    load-bearing: `image-invalid: 1` would NOT have sufficed, because steamcl honours it only as a
    sort demotion and `set_menu_conf()` picks the other entry past `SUPERMAX_BOOT_FAILURES` without
    consulting it. Full mechanism in the commit message and the release-card-empty-b-slot memory.

- [x] **The overlay artifact store and the whole pin machinery are RETIRED — LANDED 2026-08-04.**
  Deleted: `packages/overlay-store.sh`, `packages/verify-pins.sh`, `packages/oras.pin`, all eight
  `packages/*/artifact.pin`, `ci.yml`'s `pins` job, and `overlay.yml`'s publish / cold-retrieval /
  pin-bump / prune jobs — ~1300 lines, two PATs, and a bot with write access to `main`. A release
  build now compiles the overlay in the same run that publishes the image; a PR that touches a
  package gets a compile pass over the packages it changed, publishing nothing.
  - **The premise was a dev-box number that never applied to CI.** Everything above was sized
    against ~4h for a cold overlay build under arm64 emulation (`fex-emu` alone ~2h). MEASURED on
    `ubuntu-24.04-arm` (run `30490159103`, real aarch64, no qemu): `gtk2 7m, sddm 5m, mesa 5m,
    fex-emu 5m, gamescope 4m, scx-scheds 4m, mangohud 3m, rauc 1m` — **~34 min for the whole set**,
    against a release card run that already took 33-41 min with the store doing all the compiling.
    Half an hour, for all of that machinery. **Re-measure these before anyone proposes a cache
    again**; they are the entire basis of the decision.
  - **The byte claim did not go missing, it collapsed into the source claim.** `artifact.pin`
    existed because a release image installed bytes some OTHER machine had compiled. It no longer
    does: CI compiles from the sources in the commit it is building, into a fresh runner nothing
    else writes to, so "built from the reviewed sources" and "these exact bytes" are one statement —
    the one `images/manifest.lock`'s `novadeck` rows already make on every machine.
  - **A local release build is possible again, deliberately.** The `PINNED` gate is gone, so
    `make sdcard` with no `NOVADECK_DEV` produces a real release image — which un-blocks testing
    OOBE on hardware without flashing a CI artifact first. Publishing stays CI-only because the R2
    and RAUC signing credentials live there; that is the real control and it is untouched.
  - **Accepted loss:** `verify-lock-rows.sh` drops to hash-membership only, since the pins were what
    mapped an artifact filename to its owning package. The mesa split-package bug it was written for
    is still caught (the stale siblings carried a digest no package produces any more); what is no
    longer detectable is a row carrying a hash that is *current for a different package*.
  - **Local caching is unchanged and was never the store's job**: `build-overlay.sh` keys each
    package on `packages/inputhash.sh` and skips what has not moved
    (`work/repo/<arch>/.stamps/<name>.hash`).
  - Repo settings to clean up by hand: delete the `PIN_BUMP_PAT` and `GHCR_PRUNE_TOKEN` secrets.
    The `novadeck-overlay/*` GHCR packages can rot; nothing pulls them.
  - Superseded by this: the two items below on byte-pinning artifacts and the package store. Kept
    for their reasoning, which is still correct about the problems they were solving.

- [x] **Remote access — (a) HW-VALIDATED 2026-07-29; (b) the approval prompt is INVESTIGATED AND
  REJECTED, not deferred.** Shipped in `78982fe` (`novadeck-pairingd` + `steamos-devkit-mode` +
  `org.novadeck.policy`, 34 offline cases in `images/test-pairingd.sh`).
  **(a) the switch's argument contract — CONFIRMED on the device.** The Developer page does render
  the switch, the client calls `/usr/bin/steamos-polkit-helpers/steamos-devkit-mode` with exactly
  `--enable`/`--disable` (the verbs inferred from the reference platform were right), and `pkexec
  --disable-internal-agent` authorizes against `org.novadeck.policykit.devkit-mode` without
  prompting. All three follow from the daemon actually starting and stopping on the flip: ON opened
  `:32000` in ~6s, OFF closed it in ~18s logging `Deactivated successfully`, with no exit-22
  dead-switch symptom. The same run validated the whole path on a FRESH build: `:22` open on first
  boot but `ssh deck@` refused (`publickey,password`) with no key installed, which is the core
  safety claim of an always-on sshd; `command=`, `permitopen`, junk and `ssh-dss` registrations all
  400 with nothing written; a real key pairs and logs in as `deck` (`.ssh` 0700, `authorized_keys`
  0600); OFF withdraws the mDNS advert and leaves the installed key working, so an already-paired
  machine is unaffected. Across a subsequent power cycle the installed key still logged in (it lives
  in `/home/deck/.ssh`, its own partition) and `novadeck-pairingd` came back `inactive` — the switch
  being off persists across a boot, so an unattended device does not resume accepting keys. **A latent blocker was found and fixed in that run:** the unit's
  `ExecStartPre` wrote the avahi service file into `/etc` under `ProtectSystem=full` with no `-`
  prefix — fatal EROFS, so the daemon had never started on ANY build and the switch would have
  presented as dead. Now `ExecStartPre=-` + `ReadWritePaths=-/etc/avahi`, pinned in the offline
  suite.
  **(b) the pairing-approval prompt — NOT VIABLE by this route. Do not retry without a new idea.**
  The mechanism was fully mapped on hardware (token = `~/.steam/steam.token`, 16 bytes mode 0400,
  regenerated per boot; dispatch via the `~/.steam/steam.pipe` FIFO; response path must be
  `/tmp/<subdir>/<file>`; requires the client in pairing mode via Settings→Developer→**Pair new
  host**, which is `System.Devkit.SetPairing` and NOT the remote-access switch). Two blockers, the
  second fatal: drawing the modal needs a JS prompt callback only Steam's own devkit view
  registers, reachable only by CDP injection over the CEF debug port — brittle; and **the token is
  readable by any process running as `deck`, i.e. every game, so a token-gated prompt is forgeable
  by a running game** and adds no consent the switch does not already give. "Pair new host" has no
  script hook at all (pressing it produced zero journal activity). A real prompt must be OUR OWN
  gamescope overlay gated on something a game cannot supply — that is new work, not this item.
  **Note the original text's premise is gone:** consent no longer rests on a five-minute window.
  It was removed in `b6f67a6` because the UI switch and the window could disagree (the UI kept
  showing "on" after the window had silently closed) and the client re-asserts the switch position
  at session start anyway. Consent is now the switch position itself, which is why the daemon
  accepts keys for exactly as long as it runs. See [[release-ssh-devkit-toggle]] and
  `docs/remote-access.md`.

- [x] **A REAL release bundle IS verifiable on hardware — HW-VALIDATED 2026-07-29. Supersedes
  "use a TEST-mode bundle so the trial boot keeps SSH".** The old premise — a release bundle
  trial-boots headless, so it cannot be verified — is now false, because remote access no longer
  depends on the slot: sshd ships always-on in every image and the paired key lives in
  `/home/deck/.ssh`, its own partition. Proven end to end in one run:
  `PKIDIR=$HOME/novadeck-pki make bundle` produced a 3.5G verity bundle signed by
  `O = novadeck, CN = novadeck OTA release`; `rauc install` was driven **as `deck` over SSH on a
  release image with no `sudo` on the box at all** (rauc's D-Bus service, no password anywhere —
  this originally said "+ polkit", which is wrong and was corrected 2026-08-03: rauc ships no
  polkit policy, its BUS policy is simply open to every local process — see the
  "rauc's D-Bus policy lets ANY local process install a bundle" item above, closed 2026-08-04 as an
  accepted design choice rather than fixed, so that openness still ships), and
  the DEVICE's own keyring verified the signature (`Verifying signature done` at
  20%); the reboot came back on SSH in ~35s booted from `rootfs.1 (b)`, with the **host key
  unchanged** (`SHA256:SqV+NzOd…d15pc` before and after) — so an OTA does NOT invalidate every
  already-paired machine, which was the sharpest unknown here. The ESP slot state confirms it was
  PROMOTED rather than merely booted: `STATE.0` is the newer record (`gen=9` > `gen=8`) and reads
  `active=b pending= tries=0`, while the `gen=8` record preserves the armed mid-flight state
  (`active=a pending=b`). Two traps for whoever reads this next: **`rauc status` alone cannot tell
  promoted from still-on-trial** (it showed B `good` in both states — only the ESP state
  distinguishes them), and **the STATE filename is not the slot** — `STATE.0` held slot B's record,
  so `gen=` is the tiebreak, and reading `STATE.0` as "slot A" inverts the conclusion. `novadeck-bootctl
  status` needs root to mount the ESP, so as `deck` it cannot answer this at all; read the card
  offline or run it as root. Playbook below rewritten accordingly. Use `deck`, not `root` — `/root`
  is on the read-only root and does not survive the slot write.

- [x] **The ROLLBACK half of A/B — HW-VALIDATED 2026-07-29, both entry points, organic route.**
  Until this run every trial boot we had ever done SUCCEEDED and was promoted, so `tries` reaching
  zero, the init reverting, and `KERNEL.BAK` being restored were offline-verified only. Both
  branches of `abandon_trial()` have now run on the device, each reached the way production would
  reach it rather than by seeding state:

  | entry point | trigger | ESP evidence |
  |---|---|---|
  | `SOURCE=failover` | trial slot will not mount | `gen=8` → `gen=9` |
  | `SOURCE=rollback` | trial booted, never confirmed | `gen=16` → `gen=17` |

  In both cases the abandoning generation wrote `active=a pending='' tries=0 kernel=a bak=''`, and
  the boot that survived reported `source=state` — NOT `source=failover`/`rollback`, which is the
  proof it rebooted after restoring instead of carrying on. `rauc status` agreed: `Booted from:
  rootfs.0 (a)`. Pre-fix, that generation would have kept `kernel=b bak=KERNEL.BAK`.
  **How the rollback was finally reached** (the recipe that works, after one that did not — see the
  correction below): install clean so `post-install.sh` rotates `/KERNEL` and records `bak`, then
  mask `sddm.service` in the TARGET slot's `/etc` overlay upper — on var-B at
  `lib/overlays/etc/upper/systemd/system/sddm.service -> /dev/null`, applied AFTER the install
  because `post-install.sh` copies `/var` wholesale and would wipe it. The trial then boots, no
  session marker ever appears, `novadeck-boot-good.path` never fires, `tries` goes 1 → 0
  unconfirmed, and the NEXT boot rolls back. SSH stays live throughout, which is why this beats
  inducing a hang: a hang costs the only recovery channel and exercises no extra code.
  **This also confirmed the property `novadeck-boot-good.service` documents** — no backstop timer
  marked it good. Uptime passed the unit's 30s `ExecStartPre` with the unit still `inactive` and
  `pending=b` still armed, because the `.path` never triggered.
  **RESIDUAL LIMIT, deliberately not closed:** `KERNEL` and `KERNEL.BAK` were byte-identical
  (`71605ef04b6d861f`) for both runs, because the device already ran the build being installed. The
  state transitions prove the restore LOGIC ran; they do not prove the right BYTES came back.
  Proving that needs two genuinely different builds — bump `VERSION` and rebuild so `boot.img`
  differs, then re-run either branch. Cheap to do next time an image is built for another reason.
  See also the still-open unconfirmed-trial item in TODO.md: the rollback is automatic ON NEXT BOOT, and nothing
  in the system causes that boot to happen.

  Two things made this harder to test than it looks, both learned 2026-07-28 and both still true:
  1. **A half-written slot is not an unbootable slot.** The tamper test aborted an install into a at
     67%, yet a still mounted and booted cleanly — the bundle and the flashed image are the same
     build, so the bytes that landed were nearly identical to the ones they replaced. Corrupting a
     payload byte is enough to test *verity*; it is not enough to test *rollback*.
  2. **"Just don't run `mark-good`" does not work either.** `novadeck-boot-good.path`/`.service`
     confirms the trial automatically once a session comes up and stays up, so a trial that boots at
     all is promoted with no operator action.

  **CORRECTION 2026-07-28 — the test procedure this item used to prescribe would not have tested
  rollback.** It said to zero the target's btrfs superblocks (primary at 64K, copy at 64M) before
  `try`. A slot that will not MOUNT never reaches the rollback branch: `mount_root` fails and
  `images/initramfs/init` takes the **failover** path (`SOURCE=failover`) on that first boot,
  before `tries` can ever run out. Two different branches, and only one of them is what this item
  is about. Anyone running that recipe would have watched a clean recovery and ticked the box.
  To reach `SOURCE=rollback` the trial slot must **mount and boot, then fail to reach a session**:
  mask `novadeck-boot-good.path` so nothing auto-confirms, and break something after mount but
  before session start. Then boot 1 spends the try (`tries` 1 → 0), and boot 2 is the rollback.
  Sequence to expect on the ESP: `pending=b tries=1` → `pending=b tries=0` → `pending='' tries=0`
  with `active=a`, `kernel=a`, `bak=''`, and `KERNEL` byte-identical to the pre-update image.
  **Risk to price in first:** this board has no UART ([[sm8650-no-uart]]), so if neither path fires
  the device is dark and recovery means pulling the SD card and repairing `/efi/NOVADECK/STATE.*`
  on the host. Do it with the card physically accessible, and with a known-good slot on the other
  side. Recovery from a deliberately broken slot is otherwise cheap: boot the good slot and
  `rauc install` into the broken one.
  **Fixed while writing that correction** — the failover path was *also* the one with the bug.
  `init:276` states the rule ("reverting the root without the kernel is the mismatch the rollback
  exists to avoid"), but of the three paths that abandon a trial only the tries-exhausted one
  obeyed it. Failover and the manual `novadeck-bootctl rollback` both cleared `pending` and left
  the NEW kernel on the ESP against the OLD root — `/lib/modules` mismatch, and `CFG80211`/`ATH12K`
  are `=m`, so no Wi-Fi and no console to say why. Since a failed OTA reaches failover and not the
  rollback branch, **the broken path was the one production actually takes.** Now factored into
  `abandon_trial()` (`images/initramfs/init`) used by both init paths, with the same field
  discipline in `cmd_rollback`. It survived this long because the one failover case in
  `test-slot-state.sh` seeded no `bak` at all; there are now seven cases across the two suites that
  do (`make test`: 247 checks, was 210). Both halves are HW-confirmed by the runs recorded at the
  top of this item.

- [x] **`novadeck-bootctl`'s RAUC backend contract has no offline coverage — FIXED 2026-07-28**,
  **HW-CONFIRMED 2026-07-28**: a full OTA install of a release-signed TEST bundle logged
  `Marking target slot rootfs.1 as non-bootable (bad)... Marked slot rootfs.1 as bad` at `19:44:21`
  and proceeded — the exact call that aborted the first hardware install at 40%. Originally: **and that is how a broken one shipped** — found 2026-07-28, the same day it cost the first hardware `rauc install`.
  `set-state <slot> bad` returned exit 1 for a slot that was neither active nor pending, which is
  precisely the normal pre-write case (RAUC marks the TARGET slot bad before writing it), so every
  install aborted at 40% with `Failed marking slot rootfs.1 as bad` — a message describing our exit
  code, not our state. Fixed in `b04b9c9`; the gap that let it ship is not.
  `images/initramfs/test-slot-state.sh` exercises the initramfs READER only and never executes
  `novadeck-bootctl` at all, so **five** backend subcommands (`get-current`, `get-primary`,
  `set-primary`, `get-state`, `set-state`) have zero assertions on their **exit statuses** — the
  part of the contract RAUC actually consumes. Worth noting the failure needed no hardware and no
  bundle: a dozen lines against a temp-dir ESP would have caught it. The bug was also a shell idiom,
  not logic (`[ x = y ] && action` as the last statement returns 1 when the test is false), so the
  test should assert `rc=0` for every legal call INCLUDING the no-ops, not just check side effects.
  **The count was wrong when this was written, which is itself the point:** `get-current` was a
  fifth subcommand we had never implemented at all, and nothing noticed until hardware (fixed on
  `feat/phase4b-rauc`, `389830f` — see the entry below for what its absence cost). A test enumerating
  the contract would have flagged a MISSING command as loudly as a broken one.
  One concrete blocker to writing that test: `BOOTINFO` is a hardcoded constant
  (`novadeck-bootctl:28`), so a test cannot point the tool at a fake initramfs handoff and must
  either run against the real `/run/novadeck/boot` or test a `sed`-mangled copy — which is not the
  artifact that ships. Make it `BOOTINFO=${BOOTINFO:-/run/novadeck/boot}` first; the ESP path is
  already redirectable via `PARTLABEL` lookup + a temp dir, so that one line is what unblocks the
  rest.
  **Resolution: `images/test-bootctl.sh`, 101 checks, and it executes the SHIPPED tool** — not a
  copy and not a `sed`-mangled variant, so what it asserts is the artifact that ships. The seam is
  three lines (`BOOTINFO`/`ESP_AUTO`/`ESP_MANUAL` became `${VAR:-default}`), documented as a test
  seam at the top of the tool; `ESP_AUTO` was worth taking too, because pointing it at a sandbox
  keeps the test on the gpt-auto path the device actually uses instead of the findfs fallback
  nothing normally reaches. `id` and `mountpoint` are stubbed on `PATH`; nothing else is faked.
  What it asserts, in the order the failure taught us to care about:
  - **Exit status on every legal call, no-ops included** — `backend-exits-0-on-every-legal-call`
    walks all ten (`get-current`, `get-primary`, `get-state a|b`, `set-primary a|b`,
    `set-state a|b good|bad`) from a pristine state each time, because the bug was a sequence-
    independent shell idiom and a side-effect assertion could not have seen it.
  - **Completeness** — `backend-is-complete` enumerates the five subcommands `system.conf`'s
    contract requires and fails if the tool does not dispatch one. A MISSING command now fails as
    loudly as a broken one, which is the `get-current` lesson.
  - The rest: values (`get-current` off the handoff and not the cmdline, and non-zero on a
    degraded boot), the `broken=` semantics below, format preservation including unknown keys, and
    rejection paths.
  **`make test` now runs both suites** (210 checks; `test-slot-state.sh` is at 109, up from 100).
  Host-side and needing no build, container, root or device — the previous absence of any target
  that ran them is a large part of why the gap survived. Two of the new cases failed on their first
  run against correct code: both had marked the ACTIVE slot bad, which the tool deliberately
  refuses. That is the enumeration doing its job — the reachable path to `broken=ab` is genuinely
  narrower than it looks, and the test now documents it.

- [x] **`post-install.sh` — the most destructive program we ship — had no offline coverage either.
  FIXED 2026-07-29: `images/test-post-install.sh`, 107 checks, executing the SHIPPED hook.**
  `test-bootctl.sh` asserts the calls the hook MAKES and never the hook itself, so until now every
  claim in its header was verified by reading it. That is precisely the shape that let the broken
  `set-state <slot> bad` ship. The hook runs `mkfs.ext4` and `btrfstune -f -U` against a partition
  it chooses itself, from two sources that disagree by design (our initramfs handoff vs RAUC's
  exported `RAUC_TARGET_SLOTS`), and a wrong choice reformats the RUNNING slot's `/var`.
  **`make test` now runs three suites, 354 checks** (`test-slot-state.sh` 132, `test-bootctl.sh`
  115, `test-post-install.sh` 107) — still host-side, no build, no container, no root, no device.
  **What it asserts is ORDER, because that is what the hook's header claims and what is expensive to
  check by eye.** Every stub appends to one call log: the fsid is randomised before anything mounts
  the target (step 1 exists because until then the two roots share an fsid AND `devid=1`, so a mount
  of one can hand you the other), the slot is disarmed before the work and re-armed only after
  `set-kernel`, the target `/var` is unmounted before the target root is mounted, and the slot
  witness is written AFTER the wholesale copy that would otherwise clobber it. Also covered: the
  target choice and all four ways of refusing it, the two exclusions (`slot` rewritten to the
  target's letter, `mac-wifi` deleted) against actual bytes, that the saved Wi-Fi and SSH host keys
  ride across (the brick-class item further down), `/KERNEL` rotation including `bak=''` when there
  is nothing to back up, and — one case per failure point — that a hook that dies mid-run leaves
  **nothing armed**, which is the entire justification for the disarm.
  **Six test seams added to the hook** (`ESP`, `MNT`, `BOOTINFO`, `VAR`, `DEVDIR`, `DEVTEST`),
  documented at its head exactly as `novadeck-bootctl`'s three are. `DEVTEST` is the one assertion
  the sandbox gives up: an unprivileged test has no block device to offer, so `-b` relaxes to `-e`.
  Stubbed on `PATH`: only the commands that would touch real storage (`mount`, `umount`,
  `mkfs.ext4`, `btrfstune`, `rsync`) plus `id`/`mountpoint`. `novadeck-bootctl` is the shipped tool
  behind a shim, so the suite exercises hook and backend as one program.
  **It was mutation-tested rather than trusted for passing.** Nine deliberate breakages, all caught:
  targeting the booted slot (43 checks), taking the kernel from the running root (39), dropping the
  disarm (13), dropping the fsid randomisation (14), skipping the reformat (8), copying the witness
  verbatim (1), keeping `mac-wifi` (1), dropping `--one-file-system` (1), and never clearing
  `broken` (2). A suite that passes first try against correct code has proven nothing yet.
  **What it deliberately cannot cover, so a green run is not read as more than it is:** whether the
  new fsid actually stops the kernel aliasing the two roots, whether real `rsync --one-file-system`
  skips our offload bind mounts, and whether 256M holds the copy. A stub can only prove we ask for
  the right things in the right order. Those three need the device, and the RELEASE-image OTA run is
  still the gate — see the `/var` item below.

- [x] **RAUC arms the new slot BEFORE `post-install.sh` makes it bootable — FIXED 2026-07-28**,
  **HW-CONFIRMED 2026-07-28**: RAUC marked b active at `19:49:47`, the hook logged
  `disarmed slot b for the duration of the install` in the same second and
  `slot b re-armed for a trial boot` at `19:50:07` — the 20s of "armed but no /var, wrong kernel"
  is covered end to end, and the following reboot booted b successfully. Was: **a ~15s window where the ESP says "boot b" and b cannot boot** — found 2026-07-28 on hardware, from the journal of a
  successful install. RAUC's order is fixed and not ours to change:

  ```
  17:55:03  Marked slot rootfs.1 as active        <- set-primary: pending=b tries=1 written HERE
  17:55:03  Starting post install handler
  17:55:11    fsid randomised
  17:55:12    copied /var wholesale
  17:55:19    kernel rotated to slot b            <- only NOW is b actually bootable
  ```

  The stale `STATE.1` left on the first test card is that window preserved: `gen=2 active=a
  pending=b tries=1 kernel=` — "boot b next", recorded while b's `/var` had not been migrated and
  `/KERNEL` still held a's image. Lose power in there and the next boot targets a slot whose `/var`
  is at best stale and at worst **freshly `mkfs.ext4`'d and empty** — no
  `/var/lib/overlays/etc/upper`, which `post-install.sh`'s own comment says means the slot "does not
  come up" — under a kernel whose `/lib/modules` is the other slot's (CFG80211/ATH12K are `=m`: no
  Wi-Fi, no serial console, nothing on screen).
  Not fatal: `tries=1` means one failed boot then rollback, and the rollback path is now
  HW-validated (2026-07-28). But it spends the safety net on a failure we can simply not create.
  **Fix is cheap and local to us:** have `post-install.sh` DISARM at entry (write `pending='' tries=0`)
  and re-arm at exit, after `set-kernel`. Then an interrupted post-install leaves nothing pointing at
  a half-prepared slot, and the failure mode becomes "install failed, run it again" instead of "one
  bad boot, hope the rollback fires". Test it by cutting power during the hook — the window is ~15s
  of a ~6min update, so script the kill rather than racing it by hand.
  **Resolution: exactly the cheap local fix above.** `post-install.sh` gained a step 0 (disarm) and
  a step 4 (re-arm), and the header's "order is load-bearing" list now runs 0–4. The disarm reuses
  `novadeck-bootctl rollback` rather than inventing a synonym — clearing `pending` and zeroing
  `tries` *is* rollback, and it already exits 0 as a no-op when nothing is armed. The re-arm is two
  statements after `set-kernel`, both fatal on failure: `set-state <target> good` (clears the
  pre-write `broken` mark — see the item below, and note this is the only place that knows the
  install completed) then `set-primary <target>`.
  Offline-verified as a SEQUENCE, which is what this needed: `a-completed-install-ends-armed-and-
  unmarked` drives RAUC's real order (mark bad → write → set-primary → hook) and asserts the end
  state is `pending=b tries=1 broken='' kernel=b`; `a-power-cut-inside-the-hook-leaves-nothing-
  armed` stops after the disarm and asserts `get-primary` answers the RUNNING slot with
  `pending=''`. **Still worth the HW power-cut test**, and it is now a cheaper one: the assertion
  is "the ESP never names the target while the target is not bootable", so any kill point inside
  the hook should show the same thing.

- [x] **An interrupted install leaves NO record — a half-written slot still reports `good` —
  FIXED 2026-07-28**, **HW-CONFIRMED 2026-07-28** by re-running the tamper test: one payload byte
  flipped at offset 2000000000 (signature still valid, verity catches it at read time) killed the
  install at 67% with `Failed to copy data: ... Input/output error`, and the ESP state gained
  `broken=a` in a new `gen=10` buffer. `get-state a` now answers `bad` (it answered `good` before
  the fix), `rauc status` prints `boot status: bad`, and `bootctl status` warns. **The
  survives-a-trial-boot trap is HW-cleared too**: `try a` warned-but-armed (`tries=1`), the trial
  boot decremented to `tries=0` at `gen=12`, and `broken=a` came through intact and was published
  in the `/run/novadeck/boot` handoff — a naive marker would have been erased by that one write.
  **STILL OPEN, found by the same run — a promotion does not clear the marker.** The trial boot of
  a *succeeded* (its content is largely the same image, so a half-written slot still mounted and
  booted), `novadeck-boot-good.service` auto-confirmed it, and the result was `active=a` **and**
  `broken=a` simultaneously: the running, promoted slot reporting `bad`. That is precisely the
  contradiction the design rule below forbids ("a slot we are running is demonstrably bootable").
  `set-state good` is specified to clear the marker unconditionally, but the promotion path never
  calls it — only a successful *install* does. Fix is one of: have `mark-good` clear `broken=` for
  the slot it promotes, or have the init clear it for the slot it successfully booted. Originally:
  demonstrated on hardware 2026-07-28 (deliberately, via the tampered-bundle test): a payload byte
  flip made dm-verity fail 13s into writing slot a, aborting the install partway through the copy.
  Slot a was then genuinely inconsistent, and both readers disagreed with reality:

  ```
  novadeck-bootctl get-state a  ->  good
  rauc status: [rootfs.0] ... boot status: good
  ```

  This is `set-state <slot> bad` behaving exactly as written: it is a deliberate no-op when the slot
  is neither active nor pending (`b04b9c9`), and that reasoning is sound as far as it goes — nothing
  automatic boots such a slot, so the device stays safe. The gap is that RAUC's `bad` marking is
  *dropped* rather than *recorded*, so nothing can distinguish "never installed" from "install died
  halfway". `novadeck-bootctl try a` would cheerfully boot it, and its only warning is about kernel
  mismatch. Note RAUC cannot cover for us here: the journal says `Using per-slot statusfile. System
  status information not supported!` — raw slots have nowhere for RAUC to keep its own status.
  Options: a `broken=` key in the ESP state (unknown keys are already preserved verbatim across
  versions, so this is additive and safe), set on `set-state bad` for any slot and cleared on a
  successful post-install; then `get-state`, `try` and `status` all consult it. Whatever the shape,
  the invariant to restore is that a slot RAUC was told is bad does not later answer `good`.
  **Resolution: the `broken=` key, as sketched.** It holds the SET of marked slots ('', 'a', 'b',
  'ab') in canonical order, not a single letter: `ab` is reachable (a failed install into b, then
  `try b` + `mark-good` promoting it, then an install into a that dies) and a single letter would
  erase the first mark on the second write. `set-state bad` records it for any slot except the
  ACTIVE one — a slot we are running is demonstrably bootable, and marking it would make
  `get-state` contradict the fact that it answered at all. `set-state good` clears it
  unconditionally, deliberately NOT only when the slot is pending: the hook disarms while it works,
  so the completed slot is neither active nor pending at the moment the mark must come off.
  Consumers: `get-state` answers `bad`, `status` prints the field and warns per slot, `try` warns
  but still arms — refusing would let the one recorded fact about a half-installed slot disable the
  only recovery path, and the trial counter already bounds the risk.
  **The trap this nearly walked into, and the reason it is a named field rather than a new key:**
  `images/initramfs/init`'s `write_state` emits a FIXED field list, so it DESTROYS any key it does
  not name — and it writes on every trial boot, to decrement `tries`. A `broken` marker would have
  survived exactly one boot. "Unknown keys are ignored, never rejected" is a property of the init's
  READER and has never been one of its writer, though the header comment reads as if it covered
  both (`novadeck-bootctl` really does preserve them, via `S_EXTRA`). So `broken=` is parsed,
  carried and emitted by the init as a first-class field, published in the `/run/novadeck/boot`
  handoff, seeded empty by `make-sdcard.sh` and asserted empty-and-present by `verify-card.sh`.
  `test-slot-state.sh` covers the carry on a decrement, on a rollback, for both letters, and in
  the handoff. A malformed value is NORMALISED rather than rejected — a bookkeeping field must
  never invalidate the state the device boots from.
  **Left open deliberately:** the init's writer still drops genuinely unknown keys, so the next
  field added to this format has the same trap waiting. Making `write_state` preserve them needs a
  builtin-only passthrough (no `cat`/`sed` in the initramfs, cf. `images/mkinitramfs.sh`) and is
  not free; it is worth doing before a third field, not as part of this.

- [x] **`kernel=` in the ESP slot state goes stale after a kernel rotation — FIXED 2026-07-28** on
  `feat/phase4b-rauc`, offline-verified; **partially HW-confirmed** the same day — the device's
  shipped `/usr/lib/rauc/post-install.sh:184` calls `set-kernel`, the install at `18:28:38`
  completed through it, and the resulting handoff reads `kernel=a` for a booted slot a, consistent.
  **The letter change IS now HW-exercised (2026-07-28)**: an install from a booted slot a into b
  logged `/KERNEL is now slot b's boot image (previous kept as KERNEL.BAK)`, `/efi` held `KERNEL`
  and `KERNEL.BAK` at 30109696 bytes each, and the state read `kernel=b` across the rotation and the
  trial boot. `novadeck-bootctl try a` then correctly warned `/KERNEL is slot b's boot image -- slot
  a will boot with /lib/modules from a different build`, and the init logged the matching
  `DEGRADED:` line on the boot that followed. Originally NOT exercised, when `get-current` is separately HW-confirmed: it answers `a`
  and `rauc status` reads `Booted from: rootfs.0 (a)`. Found on hardware immediately after a
  successful `rauc install`. The post-install hook rotates `/KERNEL`
  to the newly installed slot's boot image and records the backup via `novadeck-bootctl set-bak`,
  but nothing updates `kernel=`: the ESP still read `kernel=a` while slot **b**'s kernel was at
  `/KERNEL`. Harmless *today* — `images/initramfs/init:36` marks the field "reserved (pass 2)" and
  the rollback path keys off `bak=`, not this — but it is now a field that actively lies, and its
  name invites the next reader to trust it. Two honest options: have the hook maintain it (pass 2
  was the pass that was meant to start), or delete it from the format. Do NOT leave it as a
  declaration with nothing behind it — cf. the `/etc/machine-id` item further down, which is the
  same failure mode one iteration earlier.
  **Resolution: MAINTAINED, and given a consumer.** Deleting it was the worse half of the choice —
  `novadeck-bootctl` preserves unknown keys verbatim, so dropping the parser case would not remove
  the line, it would *fossilise* the stale `kernel=a` on every card already in the field, forever
  and unreadably. Maintaining it costs one call and buys a check nothing else can make: `/KERNEL`
  is SHARED while `/lib/modules/<ver>` ships INSIDE a root, so a boot can run a root under the
  other build's kernel — `novadeck-bootctl try <other>` after an update reaches it with no second
  update involved, and with `CFG80211`/`ATH12K` at `=m` the symptom is "Wi-Fi broke", not "wrong
  kernel". What landed:
  - `set-bak <name>` became **`set-kernel <a|b> [bak]`** — one call, so both fields land in ONE
    generation. Split writes leave a state naming a backup for a kernel it has not recorded.
  - The rollback in `images/initramfs/init` re-points `kernel=` at the slot it restores to, in the
    same generation that clears `bak=`. The write necessarily precedes the copy, so a *failed*
    restore spends a second generation taking the claim back — a field maintained only on the happy
    path is the same defect one branch deeper.
  - Consumers: the initramfs logs a mismatch to kmsg at boot (the whole debugging surface on a
    no-UART device), `status` prints and warns, `try` warns before arming. None of them refuse —
    the alternative to a mismatched pair is no pair.
  - **`make-sdcard.sh` now seeds `kernel=` EMPTY, not `a`** (asserted in `verify-card.sh`). On a
    fresh card both slots are the same `rootfs.img`, so a letter would make the ordinary `try b`
    slot test warn about a mismatch that does not exist. Empty = no claim; only a rotation writes
    a letter, so the field is either silent or true.
  - The hook also stops recording `bak=KERNEL.BAK` when it made no backup (no `/KERNEL` to save),
    which armed a restore that could only fail.
  - Guard 7 now asserts every `novadeck-bootctl` subcommand the hook invokes is one the shipped
    tool dispatches — the skew this rename could have shipped, whose symptom is an install that
    replaces the root, rotates `/KERNEL`, then fails at its last step recording neither.
  `images/initramfs/test-slot-state.sh` is at **100 checks (was 73)**: restore, failed restore,
  missing backup, read-only ESP, and mismatch/match/unrecorded. It still does not execute
  `novadeck-bootctl` — that gap is the item above, unchanged by this.

- [x] **`$(BASE_STAMP)` was not mode-scoped — a test-built base could feed a release build — FIXED
  2026-07-28** — found the same day, building a RAUC bundle right after a
  `NOVADECK_DEV=1 make sdcard`. `MODE_STAMP`
  (`Makefile:69`, `work/.rootfs-mode-$(ROOTFS_MODE)`) exists precisely so flipping `NOVADECK_DEV`
  rebuilds the **rootfs** — its comment records the boot cycle that cost on 2026-07-09. `$(BASE_STAMP)`
  (`Makefile:127`, rule at `305`) had no equivalent: every prerequisite was a file, none encoded the
  mode, so a base carrying `DEV_PKGS` looked up-to-date to a release build. `customize-base.sh` is
  *already* mode-aware (`242` adds `DEV_PKGS`, `306` folds mode into the reuse key) — make
  simply never invokes it, so that logic is unreachable in the exact case it was written for.
  **Caught, but only in one direction:** the release guard failed with `only in tree: evtest-1.36-1 /
  usbutils-019-1` against `manifest.lock`, so nothing shipped. The reverse — a release base feeding a
  TEST card — has NO check, because `guard-rootfs.sh` is release-only (`assemble-rootfs.sh:771`), and
  that is the direction that produced the 2026-07-09 boot cycle: a release root in a test-built card,
  no Wi-Fi, no SSH, no error anywhere.
  **The one-line fix written here was wrong, and shipping it would have kept the bug in the direction
  with no guard.** Renaming the stamp per mode (`work/.base-$(ROOTFS_MODE).stamp`) works for the
  rootfs because each mode has its own *artifact*; the base has one shared tree at `work/base`. Two
  stamps against one tree means a `.base-test.stamp` left behind by an earlier test build still looks
  satisfied after a release build has since overwritten that tree — the same stale-base bug, now
  arrived at through the stamp meant to prevent it.
  Shipped instead: a **prerequisite** stamp. `$(BASE_MODE_STAMP)` (`work/.base-mode-$(ROOTFS_MODE)`)
  is a prerequisite of `$(BASE_STAMP)`, and its rule `rm -f work/.base-mode-*` before touching, so
  exactly one marker exists and it always names the mode `work/base` was last built in. A flip
  re-creates it newer than `$(BASE_STAMP)`, `customize-base.sh` re-runs, and its own reuse key
  (`test:1`) makes that a real rebuild rather than a short-circuit. One stamp per artifact, one
  marker per mode.
  The stamp is also no longer trusted on its own: the recipe now asserts the *built tree* is in the
  requested mode (`test:1` present in `work/base/usr/lib/novadeck/pkgs` iff `ROOTFS_MODE=test`) and
  fails with `base tree is a <got> build, this is a <want> build (stale work/base)`. That closes the
  direction `guard-rootfs.sh` never covered. `relock` and `clean-base` drop the marker along with
  the stamp — the first leaves a RESOLVE tree that is in no mode, the second leaves no tree at all.
  Verified offline both ways with `make -n -o work/repo/aarch64/.overlay.stamp base` (the overlay
  rule otherwise always cascades under `-n`): same mode + fresh stamp is `Nothing to be done`, a
  flipped mode re-runs `customize-base.sh`. The assertion was exercised against the live test tree
  in both modes. The flip costs a full base rebuild — the correct price, and what `make relock`
  already pays deliberately.

- [x] **rauc 1.15.2 as an INSTALLER — HW-VALIDATED 2026-07-28** — `packages/rauc` (`8304bc6`) builds
  1.15.2 from source solely because the snapshot's 1.14 cannot install a dm-verity bundle on
  kernel >= 6.19, and we ship 7.1.5. That premise was an **upstream changelog claim we inherited**,
  with no test in the tree able to confirm or refute it. Settled on hardware: device `rauc 1.15.2`
  on `uname -r` 7.1.5 installed `novadeck-hwtest6.raucb` (`Bundle Format: verity`, verity size
  30851072) **three times successfully** — `17:55:19` and `18:02:49` into rootfs.1, `18:28:38` into
  rootfs.0 — each logging `Configured dm-verity device '/dev/dm-0'` before `Updating slots`. The
  writer/installer pair is exercised too: the bundle was written by the BUILD container's 1.15.1
  (`build/Dockerfile`) and installed by the overlay's 1.15.2, with no version-skew symptom.
  **Verity is enforcing, not merely configured** — the deliberate tamper test hit both layers, from
  the same filename, at two byte positions: a signature-region flip was rejected outright
  (`Invalid bundle format: Signature data is no valid CMS`, before any write), and a payload flip
  mounted fine and then died 13s into the copy (`Failed to copy data: Error reading from file:
  Input/output error`) — a verity hash failure surfacing as EIO. That second case is the one that
  left slot a inconsistent, which is the item above (open when this was written, since closed).
  What this does **not** cover: `guard-rootfs.sh` assertion 7 still runs
  `images/rauc/verify-signing.sh` inside the BUILD container, so it asserts cert profile + bundle
  format + keyring agreement and never touches the device binary — the offline tree still cannot
  catch a device-side rauc regression, only a HW install can.
  **Playbook for the next HW run** (rewritten 2026-07-29 after the run above): sign with the real
  key — `PKIDIR=$HOME/novadeck-pki make bundle`, NOT `RAUC_CERT=out/pki/...`, because the PKI moved
  out of `out/pki` (see [[novadeck-pki-location]]) and is invisible to the container unless PKIDIR
  mounts it. Without it `genbundle.sh` mints an *ephemeral dev cert* (7-day self-signed, deleted with
  its tempdir) that the device keyring rejects on signature, which reads as a rauc failure but is not
  one. **Test a REAL release bundle, not a TEST-mode one** — the old advice here is obsolete: a
  release image keeps SSH through the trial boot on its own (always-on sshd + the key on `/home`),
  which is what made the whole path verifiable. Run `rauc info` before `rauc install` to separate
  version skew from the verity path under test — but note `rauc info --keyring <ca>` applies rauc's
  DEFAULT purpose (`smimesign`, which accepts only emailProtection or no EKU) and therefore REJECTS
  our codeSigning release cert with `unsuitable certificate purpose`. That is a false red: verify
  through the shipped config instead, `rauc --conf=fs-overlay/etc/rauc/system.conf info <bundle>`
  (`check-purpose=codesign`). Note also that `make bundle` does NOT verify its own output — rauc
  logs `No keyring given, skipping signature verification` at creation — so a green `make` is not
  evidence the bundle is validly signed.

- [x] **Retroid Pocket Nova — board support COMPLETE, HW-VALIDATED 2026-07-30, all gaps CLEARED
  2026-08-04 (incl. 120 Hz).** Merged 2026-08-04 with the separate "Nova gamepad + SM8550 audio
  fixes ported" item, which tracked the same board's remaining unknowns and had no reason to be
  its own entry. SM8550
  sibling of the Retroid Pocket 6: same `qcs8550-retroidpocket-rp6.dts` base (AYN common dtsi, RSInput
  gamepad, ayn/odin2 ADSP+amp firmware), differing only in the display/touch pair. Its 4.5" panel is an
  **Ilitek IL97680A wired NATIVE LANDSCAPE 1280x960 (4:3) at 60/120 Hz** — the first board in the
  fleet with no DTS `rotation`, so `qcs8550-retroidpocket-rpnova.dts` deletes the inherited
  `rotation = <270>` and re-declares the digitizer 1280x960 without `touchscreen-inverted-y`.
  Novadeck has been run on the device. **Cleared on HW:** gamescope comes up unrotated (the composite
  rotation path does NOT wrongly auto-engage off the connector, despite every other board feeding it a
  rotated scanout); `NOVADECK_GAMESCOPE_FAKE_OUTPUT_MM=120x90` — arithmetic, never measured, exact 4:3
  at ~10.7 px/mm vs the fleet's 10.8 — reads correct by eye, so it stays; and the 1280x960 digitizer
  maps correctly without `touchscreen-inverted-y`. Build-side checks stand: panel patch `0105` applies
  to the pinned 7.1.5 (Kconfig at offset, Makefile at fuzz 1 — the insertion point around
  `DRM_PANEL_ILITEK_IL9322` is exact), the DTB compiles with only the fleet's pre-existing
  `unique_unit_address` noise, and `device-env` resolves the profile. No new firmware or ALSA UCM: it
  inherits the AYN-Odin2 sound-card model.
  **120 Hz — CLEARED ON HW 2026-08-04.** The panel's init sequence branches on vrefresh, and the
  open question was whether the 120 Hz mode actually selects and drives rather than silently landing
  at 60. It drives.

  **The three ported upstream fixes below — ALSO CLEARED ON HW 2026-08-04.** They were in tree and
  build-verified but had only ever been exercised on the upstream tree, not ours; all three are now
  confirmed on the device, including the two judgement calls that could only be settled by feel and
  measurement (the trigger deadzone value, and whether the audio fix changes our boot):
  (1) **Left stick mirrored.** The Nova reports ABS_X/ABS_Y inverted relative to the RP6 it inherits
  from; `qcs8550-retroidpocket-rpnova.dts` now sets `invert-x` + `invert-y` on `&gamepad`. The right
  stick is already correct — do NOT add `invert-rx`/`invert-ry`.
  (2) **Triggers idle above zero**, reading as permanently half-pulled. `trigger-left-deadzone` /
  `trigger-right-deadzone` = `<100>` against the inherited `axis-range = <1024>`. This needed a driver
  change too: `0031_input--Add-driver-for-RSInput-Gamepad.patch` gained the two `device_property_read_u32`
  overrides in probe (the module params existed; the DT plumbing did not). `100` is upstream's number,
  not ours, and the open question was whether it eats usable travel at the bottom of the pull — it
  does not; the value stands as upstream set it.
  (3) **Audio boot delay / amp log spam.** New `0201-ASoC-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch`:
  port start moved out of `.prepare` into `.trigger` upstream, so MI2S BCLK now comes up *after* the
  codec DAPM widgets power on. The aw88166 amps validate their PLL against BCLK at DAPM `PRE_PMU`,
  before the trigger — with no clock the PLL never locks, the amps stay silent, and the retry spams the
  log and stretches audio bring-up. Starting the playback port back in `.prepare` fixes it; the
  trigger's `!is_port_started` guard then no-ops and capture is untouched. **This is fleet-wide, not
  Nova-only** — aw88166 lives in `qcs8550-ayn-common.dtsi`, so Odin2/mini/portal/Thor inherit it too,
  and any of them could have been silently paying this cost. Verified: all 51 patches apply to pinned
  7.1.5 with zero rejects, and the rebuilt DTB carries all four gamepad properties.
  **Scope of the 2026-08-04 clearance, stated precisely so nobody over-reads it:** it was taken on
  the **Nova**. The fleet-wide claim is still an INFERENCE for Odin2/mini/portal/Thor — they inherit
  the same `qcs8550-ayn-common.dtsi` amp node, so the same fix should apply, but none of them has
  been booted to check. Cheap to confirm opportunistically the next time any of those boards is in
  hand; not worth its own item.

- [x] **~90s poweroff stall — RESOLVED, HW-VALIDATED 2026-07-26** (fix `876adb1`) — second, independent
  cause from the dirmngr one (that was killed by the Phase 4a seal). `gamescope-wl` ignores SIGTERM
  during session teardown, so logind's `session-1.scope` burned the stock 90s `DefaultTimeoutStopSec`
  and then SIGKILLed it anyway. `fs-overlay/etc/systemd/system/session-.scope.d/
  10-novadeck-stop-timeout.conf` sets `TimeoutStopSec=10s` on every logind session scope; the wedge
  path finally reproduced on an OOBE boot (`917c2c01`) and measured **10.23s** from "Session 1 logged
  out. Waiting for processes to exit" to `Stopping timed out. Killing.`, with `gamescope-wl` healthy
  and *Xwayland* aborting — the same signature as the original 90s stall. Scope binding separately
  confirmed on device (`systemctl show -p TimeoutStopUSec session-1.scope` → `10s`), settling whether
  the dash-truncated drop-in dir reaches logind's transient scope.
  **A ~10s shutdown is now EXPECTED, not a bug — do not re-investigate it as one.** Root cause
  (gamescope ignoring SIGTERM) is upstream and unfixed; this only bounds the damage. Reopen only if
  Steam is seen SIGKILLed mid config/cloud-save write (it shares the scope), and then RAISE the 10s,
  don't lower it. Reading a shutdown: `Stopping timed out. Killing.` = the wedge, fix exercised;
  `Deactivated successfully` in <1s = gamescope collapsed or exited cleanly on its own, which proves
  nothing either way. Do **not** retry the `novadeck-session` `cleanup()` SIGTERM→SIGKILL escalation:
  HW-disproven 2026-07-15, and the journal shows why — SDDM tears the script down in the same
  millisecond (`sddm-helper ... crashed (exit code 1)`), so it never outlives its own grace period.
  See [[gamescope-slow-shutdown-sigterm-wedge]], [[dirmngr-slow-shutdown-defer-phase4]].

- [x] **`novadeck` lock rows are sha-pinned to non-reproducible builds — FIXED 2026-07-29 (interim
  taken)** — found 2026-07-26 during a `rm -rf work` full-rebuild test. `images/manifest.lock` recorded a
  sha256 of the *built artifact* for the 10 overlay rows, and `images/fetchlock.sh` refused the install
  when it differed. Our builds are **not bit-reproducible**: wiping `work/repo/aarch64` and rebuilding
  from *identical* inputs moved all 10 shas, so the lock only verified on the machine that last ran
  `make relock` — a hard block in CI (a clean runner has no `work/`, so it fails every run) and the
  reason `make distclean && make sdcard` could not succeed on its own. Root cause: one column carrying
  two guarantees — for `snapshot` rows it catches a third party republishing under a fixed name (real
  value, kept); for `novadeck` rows it could only ever say "you rebuilt", never "the inputs changed".
  **Fix shipped — the cheap interim below, with one correction.** `novadeck` rows now record a hash of
  the package's **committed sources** (`source.pin` + patches + local `PKGBUILD`), computed by a new
  `packages/inputhash.sh` that `build-overlay.sh`, `genmanifest.sh` and `fetchlock.sh` all share. The
  correction: the formula this item pointed at (inlined in `build-overlay.sh`) was **path-dependent** —
  `sha256sum "${inputs[@]}" | sha256sum` hashes `<hash>  <path>` lines, so the digest followed the
  checkout directory and would have silently failed the very cross-machine property the change exists
  for. It hashes the content column only, and `fetchlock.sh` re-derives it from the repo rather than
  reading `.stamps/<name>.hash`, so the check is against sources a reviewer can see, not the builder's
  claim about itself. mesa's three installed artifacts share one hash — one split PKGBUILD, one pin.
  Also: `distclean` no longer runs `clean-overlay`, so `work/repo` joins the kept caches (`make
  clean-overlay` is still the force-rebuild button). Verified: path-independent across two checkout
  dirs; an edited patch fails `fetchlock` naming the package; deleting and rebuilding `rauc` leaves the
  lock untouched. **Gives up** the byte-level claim about the artifact — anyone who can write
  `work/repo` can substitute one — in exchange for a provenance claim that survives crossing a machine.
  See [[rootfs-build-approach]], [[overlay-package-pipeline]].

- [x] **Byte-pin overlay artifacts + dev/release split — LANDED 2026-07-30, ~~HW-validation
  pending~~ SUPERSEDED 2026-08-04.** The store and the pins described below were retired; see the
  retirement item at the top for the measurements that motivated it. Everything here is history,
  including the `--require-all` / `overlay-pull` / `verify-pins` commands it names.
  Successor to the item above, which fixed the *correctness* half. Both halves are now done, but NOT
  the way this item originally proposed.
  **What shipped instead of `prebuilt` rows.** The plan below said "promote these to the `prebuilt`
  class". That is unbuildable: `prebuilt` rows are not pacman installs at all — `fetchlock.sh:168`
  skips them and `customize-base.sh` stages them as tarballs from `packages/*/prebuilt.pin`. Overlay
  packages are real `pacman -U` inputs. Extending the lock was rejected for a second reason:
  `fetchlock.sh` reads rows with a 5-field positional `read`, and `genmanifest.sh:142` already refuses
  to put an artifact sha in that column because it would produce "a lock that verifies differently
  depending on which script wrote it". So the byte claim went into its own file with its own lifetime:
  **`packages/<name>/artifact.pin`** (`name` + `inputhash` + one `artifact:` line per shipped
  artifact, 8 pins covering 10 installed rows — mesa contributes 3 of the 5 it builds), enforced by
  **`packages/verify-pins.sh`**. The lock still answers "built from the reviewed SOURCES?" on every
  machine; the pin answers "are these the reviewed BYTES?" and only for release. Two questions, two
  files, neither overloaded.
  **The gate is `ROOTFS_MODE=release`, with no opt-in knob** — `PINNED` in the Makefile, wired as an
  **order-only** prerequisite of `$(BASE_STAMP)`. Order-only is load-bearing, not stylistic: a phony
  target in the normal position is perpetually newer than the stamp and would rebuild the base on
  every release `make` (verified: with the overlay current, `customize-base.sh` appears 0 times and
  the gate still runs). Gating the base rather than the image targets puts the check *before* the
  install; checking `work/repo` is sound because `$(OVERLAY_STAMP)` already keys off `sha256sum
  $(OVERLAY_DB)`, so a substitution there rebuilds the base anyway. A knob was rejected: a gate only
  CI remembers to set is a gate that rots.
  **Consequence, accepted deliberately: a release image can only be built by CI.** Locally built
  bytes will never match a published sha, so `make sdcard` on a dev box now fails the gate. This
  **replaces the plain-release OOBE workflow** — verifying OOBE means flashing what
  `release-sdcard.yml` produces. That is the one thing here still needing a hardware pass.
  **`NOVADECK_TEST` → `NOVADECK_DEV`, mode string `test` → `dev`, marker `test:1` → `dev:1`** — the
  name dated from the first Steam OOBE debugging and mislabelled what is now the ordinary dev cycle.
  Renamed with this change because both turn on the same distinction: who built these bytes. The three
  marker readers (`Makefile:380`, `genmanifest.sh:65`, `customize-base.sh:308`) had to move together;
  it self-heals because the *marker filename* changes, so the mode stamp is newer than the base stamp
  and the assertion runs after the rebuild. `test.pkgs` → `dev.pkgs`. The local gitignored
  credentials file was renamed to `dev-wifi.env`, then split later the same day into a TRACKED
  secret-free `dev.env` plus a gitignored `dev.env.local` holding only the SSID/PSK, so a fresh
  clone runs `set -a; . ./dev.env; set +a` with nothing to edit and no PSK ever sits in a tracked
  file. The Wi-Fi profile became OPTIONAL at the same time (`NOVADECK_WIFI`), which is what makes a
  no-network dev card — the OOBE condition — buildable at all; `ROOTFS_MODE` gained `dev-nowifi` so
  the flip cannot silently reuse the previous card. `.gitignore` updated — done 2026-07-30. Note a
  stale copy is no longer a silent failure: `NOVADECK_TEST=1` now falls through to `release`, which
  fails the pin gate loudly instead of shipping a release root in a dev card (the 2026-07-09 footgun).
  **CI: `image.yml` (`workflow_call`) + `release-sdcard.yml` + `release-bundle.yml`**, so the rootfs
  recipe exists once and the two artifacts keep independent cadences. `overlay.yml` gained a
  `pin-bump` job — a separate job because it is the only one holding a write token — that opens a PR
  carrying the new shas, using `gh` rather than a marketplace action for the same reason
  `overlay-store.sh` pins its own `oras`. **The review of that PR is where trust enters**; the check
  proves the bytes match the pins, never that anyone looked. It landed and then failed three times
  before opening anything, all three the same shape — **green while doing nothing** — and worth
  recording because that is the failure mode to expect from this job: (1) no `!cancelled()`, so a
  *skipped* `build` (the GOOD case: full cache hit) propagated transitively and the job was dead code
  on the common path — `verify` had its own `always()` and survived, `pin-bump` inherited the skip
  (`fa88f93`); (2) the change gate ran `git diff --quiet` **unstaged**, and `git diff` cannot see
  untracked files, so on the bootstrap run — no `artifact.pin` tracked yet, exactly the run whose PR
  introduces them — it reported "unchanged" about 8 files it had just created (`4354b6a`; fix is `git
  add` then `git diff --cached`); (3) `GITHUB_TOKEN` cannot create a PR at all without an org-wide
  grant. PR #6 finally carried the 8 pins onto `main`.
  **The PR credential is `secrets.PIN_BUMP_PAT`** (fine-grained, this repo only, *Pull requests:
  read+write*), not `GITHUB_TOKEN`. The alternative is the org setting "Allow GitHub Actions to create
  and approve pull requests", which cannot be narrowed — org-wide, every repo, and it grants **approve**
  as well as create, so any workflow in the org could satisfy a required-review protection by itself.
  Wrong trade for a mechanism whose premise is that a human reviewed the pins. It was briefly enabled
  and is now **off at org and repo**; do not flip it back to "fix" a PR-creation failure. Second reason
  it matters: a `GITHUB_TOKEN`-created PR **triggers no workflows**, so PR #6 arrived with no checks.
  `git push` still uses `GITHUB_TOKEN` (`contents: write`; `pull-requests: write` deliberately absent).
  A missing/expired secret **fails** the step — opposite to `prune`, deliberately, since this job *is*
  the mechanism.
  **CLOSED — the PAT path opened a real PR, on real traffic, 2026-07-30 (PR #8).** It only fires when a
  pin actually changes — a `source.pin`/patch/`PKGBUILD` change — and an ordinary merge is a full cache
  hit that correctly no-ops, which is why it went so long unexercised. The mangohud `0002` swap
  (`317c152`) was the first genuine source change since the PAT landed, so this was real traffic and
  not the `force=true` stand-in. Every success tell was met: `inputhash` moved `bdbcde0e…` →
  `6a8f4393…`, the pipeline republished, and PR #8 opened carrying **exactly one changed file**
  (`packages/mangohud/artifact.pin`) **with `ci` checks on it** — both jobs green, which is the
  specific thing a `GITHUB_TOKEN`-opened PR could not do and the second reason the PAT was chosen.
  Merged 06:59 UTC; `artifact:` is now `439f25aa…` and the tree reads clean. None of the three
  "green while doing nothing" failure modes recurred (inherited cache-hit skip, a change gate blind to
  untracked files, no PR-creation right). The whole mechanism — source change → republish → pin-bump
  PR → human review → merge — has now been walked end to end by an ordinary edit, which is the only
  evidence that counts for it. If a future run ever needs forcing:
  `gh workflow run overlay.yml --ref main -f packages=rauc -f force=true` (`rauc` is cheapest, and
  non-reproducible builds mean a forced rebuild alone changes the bytes). Between that republish and
  merging the PR, the store disagrees with `main`'s pin, so don't cut a `v*` tag in the window.
  **Left open deliberately:** nothing checks an `artifact.pin` at commit time. It is excluded from
  `overlay.yml`'s trigger paths (correctly — the pipeline writes those files, so triggering on them
  loops), and `ci.yml` only runs `make test` / `make test-signing`. So a hand-edit to an `artifact.pin`
  lands green and is not caught until a release build runs `make verify-pins` (`image.yml`). It does
  self-heal — the next genuine pipeline run overwrites the file from published bytes and opens a
  restoring PR — but detection is deferred. The stale check needs **no built artifacts** (pure
  `inputhash.sh` over sources), so `ci.yml` could validate every `artifact.pin`'s `inputhash` on every
  push for near-zero cost; only the byte comparison genuinely needs the artifacts.
  **STILL OPEN: bundle signing.** `release-bundle.yml` builds an unsigned dev-cert bundle — a real
  smoke test (it assembles, verity hashes compute, the pin gate passes) that every device rejects.
  `image.yml` accepts `RAUC_CERT_PEM`/`RAUC_KEY_PEM` and warns loudly when absent. What is undecided
  is whether the release private key belongs in GitHub at all; the file documents the four steps
  (protected environment with required reviewers, secrets on that environment, an `environment` input
  on `image.yml`'s build job, `secrets: inherit`) rather than guessing at a root-of-trust decision.
  Also unverified: whether an empty `environment` value means "no environment" for the sdcard path.
  Original framing, kept because the reasoning still holds:
  **DONE: the package pipeline and the store.** `.github/workflows/overlay.yml` +
  `packages/overlay-store.sh` build each from-source package once and publish it to
  `ghcr.io/nova-deck/novadeck-overlay/<name>-aarch64:<inputhash>`, on native `ubuntu-24.04-arm`
  runners (no qemu, no `--privileged`). `make overlay-pull && make overlay` reconstitutes
  `work/repo/aarch64` on a cold machine with **zero compiles** — validated end to end against a local
  `registry:2`: 19 artifacts byte-identical, repo db rebuilt, `fetchlock.sh` verifying all 392 rows
  (10 overlay) against an untouched lock. As predicted, `packages/inputhash.sh` was exactly the
  trigger key — it is now a *fourth* reader of that one formula, so a `plan` job asking the registry
  "do you already have this hash?" is the whole change-detection mechanism, and an unchanged package
  is no build at all. `build-overlay.sh` gained `--only` / `--no-index` for the per-package fan-out,
  plus a fix for an early exit that `set -e` turned fatal in exactly the state a pull produces
  (stamps fresh, db absent). This unblocks a cold-runner image build: wire `overlay-pull` ahead of
  `make sdcard`.
  **~~STILL OPEN~~: the byte claim — CLOSED, see the top of this item.** Kept for the reasoning, not
  as an open gap; the shape it proposed (`prebuilt` rows) is the one that turned out unbuildable.
  The lock attests these artifacts' *sources*, not their bytes —
  anyone who can write `work/repo` can substitute one, and the store does not change that (`oras pull`
  verifies what the *registry* holds, a different question from what a reviewer approved). The
  remaining shape is the original one: promote these to the `prebuilt` class (sha256-pinned, fetched
  not built), have the pipeline open a **pin-bump PR carrying each artifact's sha**, and make
  `fetchlock`'s `novadeck` class fetchable-and-byte-verified like `snapshot`. Cost is no longer the
  motivation for it; provenance is. Note the trade it imposes: a local `make overlay` would no longer
  be enough to image from, since locally built bytes will not match a published sha without a
  publish + `make relock` round trip.
  Reproducible builds (`SOURCE_DATE_EPOCH` etc.) remain the purist fix and a project on their own —
  layer them later as *verification* of the pipeline, not as a prerequisite. One measured wart worth
  knowing: `repo-add` is not byte-reproducible either, so a pull-then-index moves `novadeck.db`'s sha
  and therefore rebuilds the base — cheap next to the compiles skipped, but `overlay-pull` is not
  entirely free on a warm machine.
  **Rejected (unchanged):** GitHub Actions `cache` for `work/repo` — a miss is a red build, guaranteed
  on the first build after any patch edit, and a cache keyed by anything other than the input hash is
  not a provenance mechanism. The store above is content-addressed per package, which is why a miss
  there is merely slow.
  See `ci/README.md` and `packages/README.md` for what replaced this, and the retirement item at the
  top of this file for why. [[overlay-package-pipeline]]

- [x] **Power profiles + device-env stack — LANDED + HW-VALIDATED 2026-07-14 (Pocket S2)** — SteamUI's
  Performance profiles / GPU / fan controls work end-to-end. Three pieces (ported from the reference
  handheld distro's Python daemons; refs stripped from shipped source): `fs-overlay/usr/lib/novadeck/
  device-env` (per-board registry resolving `/proc/device-tree/model` → `devices/<board>.conf` over
  `defaults.conf`, emitting 10 `NOVADECK_*` vars); `novadeck-powerd` (system bus `org.novadeck.Power`,
  root — eco/balanced/performance + GPU auto/manual + fan curve, reads `power-profiles.conf`);
  `novadeck-steamos-manager` (owns `com.steampowered.SteamOSManager1`, forwards `PerformanceProfile1` /
  `GpuPerformanceLevel1` to powerd). HW-confirmed: all three profiles apply live (SM8650 policy0/2/5/7
  caps + `3d00000.gpu` clamps), and the fan handoff (`novadeck-suspend` → powerd `Suspend`/`Resume`)
  stops/restarts the fan on sleep/wake — **closes the fan half of the suspend-polish item, still
  open in TODO.md**
  (`bl_power` panel-blank fallback still open). `novadeck-session` now reads panel/output from device-env
  (dropped `detect_panel()`). **KEY GOTCHA:** the Steam client reads the manager on the deck **SESSION
  bus**, not the system bus — a system-only instance leaves QAM controls empty (`daemon not present`); we
  ship BOTH system + user units. Needs `python-gobject` in PKGS. `SessionManagement1` (desktop/game
  switch) stubbed until a session-control helper exists. See [[power-profiles-device-env-stack]],
  [[steam-ui-scale-panel-mm]].

- [x] **Blueish panel / intermittent blue frame = dirty ABL framebuffer handover — RESOLVED,
  HW-validated 2026-07-14 (Pocket S2, Pocket ACE, Odin2)** — the `cont_splash_region`
  `reserved-memory` carve-out in the three commons (`qcs8550-ayaneo-pocket-common.dtsi`,
  `qcs8550-ayn-common.dtsi`, `sm8650-ayaneo-common.dtsi`) reserved the framebuffer ABL had lit for
  its boot splash and handed to Linux. Linux inheriting that live aperture is what produced the
  blueish cast / intermittent blue frame (DPU/DRM takeover racing a still-active handover — the old
  vblank / frame-done-timeout signature). **Fix = delete the `splash_region` node** so ABL has no
  region to hand off into and blanks the panel before jumping to Linux → no framebuffer handover,
  clean msm/iommu bring-up. Self-contained: nothing consumed the label (no `memory-region` phandle,
  no simple-framebuffer anywhere in `kernel/dts/`). Complements `video=efifb:off`
  ([[sm8650-working-display-baseline]]) and is orthogonal to the sy7758 `enable-gpios` deferred-probe
  fix above (that was a genuinely absent backlight, not a handover artifact). Committed + pushed to
  main as `6c1677e`. See [[sm8550-bringup-pickup]].

- [x] **RAUC must rsync `/var` across slots — `/etc` and the Wi-Fi MAC ride on it — BUILT
  2026-07-28 (`077e22a`, `4862460`), CLOSED 2026-08-04.** Was a hard prerequisite for the A/B
  switch, not a nicety; the closure evidence is at the foot of this item. The `/etc` overlay's
  upperdir lives at
  `/var/lib/overlays/etc/upper`, and `/var` is **per-slot** (`var-a`/`var-b`). So booting the other
  slot presents a *different* `/etc`: no saved Wi-Fi, and a fresh `/etc/machine-id`. That last one
  bites twice, because `fs-overlay/usr/lib/novadeck/gen-mac.sh` derives the Wi-Fi MAC from
  `sha256(machine-id)` — a slot switch would silently change the device's MAC.
  SteamOS solves this exactly the way we must (`_reference/steamos-teardown/docs/system-updates.md`
  :132-137): the post-update hook **reformats** the target slot's `/var`, `rsync`s the running slot's
  `/var` over it, and *additionally* writes NetworkManager connections into both partsets'
  `…/overlays/etc/upper/NetworkManager/system-connections/`. Port that hook when wiring RAUC.
  See [[stable-mac-first-boot]], [[wifi-connect-fails-after-list]].
  **CONFIRMED ON HW 2026-07-28 — the divergence is real and measured.** Supersedes the earlier
  "measured, did not happen" note on this item: that reading was taken while the populated
  `/etc/machine-id` still sat in the shared read-only lower layer, making both slots read one id.
  With `1d1c68e` in, an A→B→A round trip on a test card gives each slot its own identity:

  | | slot A | slot B |
  |---|---|---|
  | machine-id | `381853e2b0f04fab91e1ac100f929314` | `d0c69c85fe60419da8977b87b20c2a0f` |
  | derived MAC | `76:65:55:27:14:67` | `7a:9e:e0:c4:52:04` |
  | DHCP lease | 192.168.1.130 | 192.168.1.161 |

  B booted as a FIRST BOOT (`Detected first boot` in its journal) because its `/var` is a separate
  partition (`novadeck-var-A` = p6, `-B` = p7) and its `/var/lib/overlays/etc/upper` was empty. Both
  MACs reproduce exactly from `sha256("<machine-id>-wifi")[0:12]` with the LAA bit set and multicast
  cleared, so the derivation is healthy on both slots — only the seed differs. Returning to A
  restored `381853e2…` / `76:65:55:27:14:67` / `.130` with zero first-boot lines, so neither slot
  disturbs the other. **So this hook is a hard prerequisite: without it every OTA update silently
  changes the device's Wi-Fi MAC and breaks any DHCP reservation.**

  **SUPERSEDED 2026-07-28 by `feat/phase4b-rauc` (`077e22a`, `4862460`) — the hook DOES rsync
  `/var`, with two explicit exclusions.** The advice below was "do NOT blindly rsync `/var`; migrate
  `machine-id` ALONE", on the grounds that `/var/lib/novadeck/mac-wifi` is write-once and takes
  precedence over the seed (`gen-mac.sh:40-44`), so copying a stale one pins the old address
  regardless of the new machine-id. That reasoning only holds when one file is copied WITHOUT the
  other, which a wholesale copy cannot do — and as a policy it was the wrong shape: a whitelist has
  to be extended for every new piece of per-device state, and forgetting one fails silently on a
  device with no serial console. SSH host keys were the next instance (they were baked into the
  image, so every OTA changed them); there would have been another.
  What the hook does now: reformat the target `/var`, `rsync -aHAX --numeric-ids --one-file-system`
  the running one over it, then apply exactly two exclusions, both stated in the script —
  `/var/lib/novadeck/slot` is rewritten with the TARGET's letter (it is the independent witness
  `novadeck-bootctl status` cross-checks against), and `/var/lib/novadeck/mac-wifi` is DELETED so
  the address re-derives from the migrated machine-id. `--one-file-system` is load-bearing: the
  offload dirs are bind mounts from shared `/home` and must not be copied into a 256M partition.
  The deletion is what keeps the repair described further down this item working — see it.

  Cheap inspection, no reboot needed: `mount -o ro /dev/mmcblk0p7 /run/varb` from the running slot
  and read the other slot's `/var` directly — that is how B's empty overlay was confirmed *before*
  the switch. Second reason pass 1 could not exercise this: the TEST image injects Wi-Fi into the
  shared rootfs, not the per-slot `/etc` overlay, so a `NOVADECK_DEV=1` card cannot reproduce "the
  other slot has no saved Wi-Fi" at all. Validate the hook on a RELEASE image — same trap as the
  OOBE work. Leftover from this test: slot B's `/var` now permanently holds `d0c69c85…` /
  `7a:9e:e0:c4:52:04`, so wipe `/var/lib/novadeck/mac-wifi` on B before any test expecting clean
  first-boot derivation there.

  **WHY THIS IS A BRICK-CLASS BUG ON A RELEASE IMAGE, not just an inconvenience.** The MAC/DHCP
  half is annoying (a broken reservation). The `/etc` half is not recoverable by the user: on a
  release image the target slot's `NetworkManager/system-connections/` is EMPTY, so the first boot
  after an OTA has no saved network. This device is Wi-Fi-only, headless and has no serial console
  ([[sm8650-no-uart]]) — no network means no SSH, and the only way back in is the on-screen OOBE
  Wi-Fi picker, which is exactly the flow that needs an active session and has failed before
  ([[wifi-connect-fails-after-list]]). If the update also broke the session, there is no way in at
  all. So the NetworkManager-connections half of the SteamOS hook is NOT optional garnish on top of
  the `/var` rsync — it is the part that keeps a released device reachable, and it must be
  validated on a RELEASE image before any OTA ships.

  Second HW instance 2026-07-28 on a fresh card (`try b` + reboot, different unit/card from the
  numbers above): A `9a04534c…`/`32:2c:d5:ee:d1:b9`/`.187` vs B `40f8f6e7…`/`92:e6:c8:4d:f8:6d`/
  `.230`. Same mechanism, reproduced independently — recorded because the surprise on the day was
  operational: the device "vanished" from its known IP after a routine slot test.

  **CLOSED 2026-08-04. Everything above is history; here is what actually ships.**
  `fs-overlay/usr/lib/rauc/post-install.sh` reformats the target `/var` (`mkfs.ext4 -F -L
  novadeck-var-<TARGET>`, :145), `rsync -aHAX --numeric-ids --one-file-system`s the running one over
  it (:164), then applies the two exclusions the script states in place: `/var/lib/novadeck/slot` is
  rewritten with the TARGET's letter, and `/var/lib/novadeck/mac-wifi` is deleted (:187) so the
  address re-derives from the migrated machine-id. `--one-file-system` keeps the `/home` bind mounts
  out of a 256M partition.
  **The BRICK-CLASS paragraph above is answered, on a release image, not by inspection.** The
  release-bundle run (see the HW-validated item near the top of this file, 2026-07-29) installed a
  real signed bundle as `deck` over SSH on a RELEASE image and **came back on the network from slot
  B in ~35s with the host key unchanged** — i.e. the migrated `/etc` overlay carried working
  NetworkManager connections into the target slot, which is precisely the half that keeps a released
  device reachable. Offline coverage backs it: `images/test-post-install.sh:426` asserts the
  migrated `…/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection` exists in
  slot B after the hook runs.
  **One trap survives for whoever tests next**, and it is card hygiene rather than open work: slot
  B's `/var` on the 2026-07-28 test card permanently holds `d0c69c85…` / `7a:9e:e0:c4:52:04`, so
  wipe `/var/lib/novadeck/mac-wifi` on B before any test that expects a clean first-boot derivation
  there. Also note a TEST image injects Wi-Fi into the shared rootfs rather than the per-slot `/etc`
  overlay, so a `NOVADECK_DEV=1` card cannot reproduce "the other slot has no saved Wi-Fi" at all —
  validate this path on a RELEASE image, same trap as the OOBE work.

- [x] **FIXED + HW-VALIDATED 2026-07-28 (`1d1c68e`, `feat/phase4b-boot-slots`). The image shipped a
  populated `/etc/machine-id` against its own stated invariant, with nothing asserting it** — found
  during Phase 4b HW validation; NOT a 4b bug.
  **Verified end to end on a test card:** the built `rootfs.img` no longer carries the file
  (`btrfs restore -S -x`, 115 other `/etc` entries restored so the absence is real), and
  `systemd-firstboot.service` is present as `-> /dev/null`. On device: `Detected first boot` →
  `Applying preset policy.` → `Populated /etc with preset unit settings.`, 8 novadeck units enabled,
  no failed units, and the derived MAC reproduces exactly from `sha256("$(cat /etc/machine-id)-wifi")`
  — proving the seed chain finally falls through to machine-id instead of losing to a baked value.
  Survives reboot unchanged (`boot_id` confirmed changed; zero first-boot lines on the second boot).
  **Two caveats that remain true:** (1) guard assertion 6 is **release-only**, so on a
  `NOVADECK_DEV=1` card `assemble-rootfs.sh` skips it entirely and the image must be checked by
  hand — the §4y removal itself is unconditional, which is what makes a test card correct anyway;
  (2) **already-flashed devices are NOT repaired** — `gen-mac.sh` persisted the derived address
  write-once to `/var/lib/novadeck/mac-wifi` and prefers it forever, so an existing unit keeps the
  colliding MAC until that file is deleted or its `/var` is reformatted. The RAUC `/var` hook must
  clear it rather than copying it across slots, or the bad address propagates to the new slot.
  Benign new log noise on every first boot: two `Failed to preset unit: … is masked` lines for
  `systemd-networkd`/`-wait-online` — that mask is deliberate, do not chase it.
  `images/assemble-rootfs.sh` says in as many words that `/etc/machine-id` "must stay absent so
  systemd runs preset-all on first boot", but `out/images/rootfs.img` contains
  `def47b5c6d984873ac0b077c16b18341` (33 bytes). No `rm`, no truncate, and it appears in neither
  `guard-rootfs.sh`, `seal.list` nor `trim.list` — a declaration with no assertion behind it, which
  is exactly what `docs/phase4.md` step 4 exists to prevent. Two consequences:
  (a) **per-device MAC uniqueness is broken** — `fs-overlay/usr/lib/novadeck/gen-mac.sh` states
  "systemd writes a fresh RANDOM id on first boot: unique per device", which is false for this
  artifact, so every flashed device derives the *same* Wi-Fi MAC and two novadecks on one network
  collide; (b) **preset-based enablement is silently dead on a fresh flash** — a non-empty
  machine-id means systemd does not treat it as a first boot, so `preset-all` never runs and the
  nine `60-novadeck-*.preset` files do not take effect. The device only works because explicit
  `multi-user.target.wants` symlinks also ship; anything relying on preset alone is off and nobody
  would notice. Fix = remove it at the end of `assemble-rootfs.sh` **plus a sixth guard assertion**
  (the removal without the assertion just recreates the same unguarded declaration).
  **Producer CONFIRMED 2026-07-28:** `work/base/etc/machine-id` exists at mode `0444` (systemd's
  own signature — `systemd-machine-id-setup` writes read-only), so the **4c `pacman -r` bootstrap**
  creates it via systemd's install scriptlet. 4c deleted the old sanitize step reasoning that "no
  container filesystem contributes bytes to the root" — true, and precisely the blind spot: the
  bootstrap *itself* generates this one. Fixed in `assemble-rootfs.sh` (the staged tree, which is
  what the guard sees) rather than in the bootstrap, so a cached base still yields a correct image.
  **The fix is a PAIR, and guard assertion 6 enforces both halves together:** no `/etc/machine-id`,
  AND `systemd-firstboot.service` masked. Removing the file is what makes `ConditionFirstBoot=yes`
  true, and that unit then prompts for locale and a root password on a console with no usable input,
  blocking `sysinit.target` forever on a device with no serial console — so a tree with neither is a
  bricked boot, not a cosmetic slip. See [[stable-mac-first-boot]], [[sm8650-firstboot-hang]],
  [[declared-invariants-need-assertions]].

- [x] **`/run/novadeck/boot` reported the post-write `gen` with the pre-write `pending` — FIXED
  2026-07-28** on `feat/phase4b-boot-slots` (unmerged). `write_state()` (`images/initramfs/init`)
  updated `STATE_GEN` but left `STATE_ACTIVE`/`STATE_PENDING`/`STATE_TRIES` alone, and the handoff
  is emitted from those same variables, so a rollback boot wrote `pending=''` to the ESP while the
  handoff still said `pending=b`. REPRODUCED on the destroy-B failover boot (handoff `gen=10` with
  `pending=b`, ESP `pending=<none>`), so it was never rollback-specific: any path that wrote state
  showed it. Diagnostic-only — `novadeck-bootctl` takes `pending` from the ESP and only
  `slot`/`source` from the handoff — but the init header calls this file the first evidence to
  check when debugging a boot offline, and on a no-UART device that is most of the debugging
  surface. Held until after pass-1 HW validation deliberately (one variable at a time).
  **Fix:** `write_state()` advances all four parsed fields on success, so the handoff describes the
  ESP as it stands at `switch_root`. The try branch now captures `pending` and the decremented
  count BEFORE the call (otherwise it decrements twice — the hazard the old code avoided only by
  never updating those variables), and the redundant `TRIES_LEFT` is gone. On boots that write
  nothing (`esp=ro`, `esp=none`) the parsed values are still what is on the card, so the invariant
  needs no special case. `images/initramfs/test-slot-state.sh` asserts handoff-mirrors-ESP on every
  write path (56 checks, all passing); reverting the one-line fix fails 6 of them, including the
  exact skew hardware showed. No HW re-test needed — the changed values are diagnostic output only,
  and the decision table they accompany is unchanged and covered offline.

- [x] **Phase 4b pass-1 HW matrix — COMPLETE 2026-07-28, except the power-cut test (WON'T-DO)** —
  passed: offline card verify, regression gate, read-only tools, rollback-without-booting-B, the
  actual switch, rollback-from-unhealthy, and torn-state rejection. The last two ran 2026-07-28:

  **cmdline degrade — PASSED.** `/NOVADECK` renamed away on the ESP: `source=cmdline`, `slot=?`,
  booted the baked `root=PARTLABEL=novadeck-root-A`, and `DEGRADED: no valid slot state on the ESP`
  at user.err (`<11>`) in kmsg. State dir restored afterwards, `gen=7 active=a pending=<none>`
  unchanged. **It also surfaced a real defect — fixed in `0f3ac84` on `feat/phase4b-boot-slots`:**
  `novadeck-boot-good` fired and failed every 30s for the whole uptime (4 starts in 165s), because
  the `.path` guarded on `ConditionPathExists=/run/novadeck/boot` while asserting in a comment that
  a degraded boot writes no such file — false, `images/initramfs/init` writes the handoff on every
  path including the one that resolves no slot. `mark-good` then died in `state_require` (exit 1 →
  `failed` → the level-triggered path re-arms). Now settled before `state_require`, returning 0
  when the handoff names no slot; exit 0 is load-bearing, since `RemainAfterExit=yes` is what stops
  the re-arm. Same commit closed a second hole in that function: the pending-vs-booted guard was
  `[ -n "$bs" ] && …`, so an EMPTY booted-slot skipped the check and fell through to `state_write`
  — absence of evidence promoting a slot nothing had booted.

  **destroy-B — PASSED.** First 2 MiB of `rootfs-b` zeroed (`blkid` dropped to `PARTLABEL` only, a
  direct mount gave `bad superblock`), then `try b --tries 1` + reboot. Full expected sequence:
  `state gen=9 … pending='b' tries=0 -> STATE.0` (counter decremented durably BEFORE the trial, so
  a broken slot cannot be retried forever) → `trying pending slot b` → `cannot mount root
  /dev/mmcblk0p5 (btrfs)` → `DEGRADED: slot b will not mount — failing over to slot a` → `state
  gen=10 … pending='' tries=0 -> STATE.1` (cleared, written to the alternating file) → `root
  /dev/mmcblk0p4 mounted ro (slot=a source=failover)`. Landed on A with its identity intact and no
  failed units. **Slot B is destroyed and needs a reflash before it is usable again.**

  **The power-cut test is WON'T-DO (user, 2026-07-28) — and the `novadeck.torntest=1` substitute
  is not being built.** It cannot be run on this hardware at all: a battery device has no
  interruptible supply, and long-press force-off is ~8–10s against a ~1s write window. The SD
  card's behaviour under abrupt VCC loss stays an accepted, untested risk, recorded as such in
  `docs/phase4.md`. Do not re-propose the init hook (write half the state fields, `exit 1`, let
  `panic=5` reboot so the `umount` durability barrier never runs) — it was designed and
  deliberately declined, not overlooked. What DOES cover the same ground and has passed: torn-state
  rejection (a truncated state file is refused by the parser) and the two-file generation scheme,
  which is what makes a torn write survivable in the first place.

- [x] **Wire the `boot-attempts` counter — DONE 2026-08-02, awaiting one device boot**

  Landed as a minimal `novadeck` GRUB module: one command, `novadeck_bootattempts <image-name>`,
  which opens `\SteamOS\conf\<name>.conf` on the ESP through the firmware's `EFI_FILE_PROTOCOL`,
  increments `boot-attempts:` and writes it back. `boot/gen-grub-cfg.sh` calls it once per boot,
  AFTER `terminal_output gfxterm`. It needs to be a module at all because GRUB's own `fat` driver
  is read-only. Design and post-mortem: `docs/phase5-bootattempts.md`.

  It REPLACED Valve's `steamenv`, which is gone from the tree — both patches, the `MODULES` entry
  and the `steamenv_boot` guards. `steamenv_init` was tried on hardware 2026-08-02 and reverted
  (`157ee42`): BLACK SCREEN, no message, and `A.conf` completely untouched. Do not retry it. Two
  causes, both in Valve's code — `load_steamenv` discovers the ESP by matching a partsets uuid
  across every `SIMPLE_FILE_SYSTEM` handle (ABL likely publishes only the volume it booted from),
  and `process_boot_config()` acts only `if( rv == GRUB_ERR_NONE )` then returns `GRUB_ERR_NONE`
  regardless, so total failure is indistinguishable from success. The replacement inverts all
  three: image name is an ARGUMENT, the conf is found by try-each-handle, every failure is a
  `grub_error` naming what it tried. A grubenv counter stays rejected — `save_env` cannot write the
  bootconf's `key: value` format at all.

  Verified offline: builds warning-free under `-Wall -W` from the pristine tarball plus the two
  patches, embedded in `grubaa64.efi`; `images/test-stage2-grub.sh` asserts the config counts
  against THIS slot, never the other, and after the terminal is up.

- [x] **Hardware-validate `novadeck_bootattempts` — DONE 2026-08-02, Pocket S2**

  Result: `boot-attempts` went `0 -> 1` across a reboot while `boot-count` and `boot-time` stayed
  on the previous boot's values, so the increment came from the bootloader and nothing else.
  `mark-good` then cleared it (`boot-count` 1 -> 2). The bootloader half of rollback is closed.

  **How to re-run it, because the obvious method does not work.** A healthy boot runs
  `set-mode booted`, which CLEARS `boot-attempts` — so a working module and a module that never
  ran both leave `0`. Mask the health unit first, or you learn nothing:

      systemctl mask novadeck-boot-good.path novadeck-boot-good.service
      reboot                     # then read boot-attempts; unmask + mark-good afterwards

  Two things that look like faults and are not: the success line prints just before the board menu
  paints over it, so on a 3s boot you will usually miss it — absence of the message is not absence
  of the increment; and the ESP grubenv keeps its card-build mtime forever, because `save_env`
  writes raw disk blocks and never touches the FAT directory entry.

- [x] **`efi-a`/`efi-b` are unused under design C — CLOSED 2026-08-02 BY PHASE 5** — created +
  formatted vfat, EMPTY, and no longer earmarked for per-boot images. That was design A. Phase 4b
  picked design **C** (`docs/phase4.md`): one slot-AGNOSTIC `/KERNEL`, slot selection moved out of
  the baked cmdline into the initramfs, which reads a try-counter state file on the ESP and falls
  back to the other slot at zero. So `boot/package.sh` does NOT need a slot argument, and there is
  nothing per-slot to store. They stay allocated because the alternative is a reflash if a later
  pass does want them — as staging for a new boot image, or for the previous kernel a failed health
  check reverts to. 128MiB of card sitting idle. Adding a GRUB stage stays a legitimate fallback if
  C proves unworkable — reconsider it rather than working around it. See
  [[sm8650-rocknix-abl-boot]].
  **Resolution (Phase 5, `docs/phase5.md`): the "adding a GRUB stage" fallback became the design.**
  Design C was replaced by the SteamDeck-style chain — ABL → steamcl (stage 1, ESP) → per-slot
  GRUB (stage 2, `efi-a`/`efi-b`) → kernel in the slot root — so `efi-a`/`efi-b` now carry the
  per-slot `grubaa64.efi` + `grub.cfg` + partsets, `/KERNEL` and `/NOVADECK/STATE.*` are gone, and
  `boot/package.sh`/`boot/cmdline` were deleted.

- [x] **Phase 4b pass 2 — RAUC on top of the landed boot path — CLOSED 2026-08-02 BY PHASE 5** —
  pass 1 is merged (`d524f09`).
  **Resolution: absorbed into Phase 5.** The boot-path rework (`docs/phase5.md`) replaced design C
  wholesale: the post-install hook's `/KERNEL`
  rotation and the `KERNEL.BAK`/`kernel=` machinery are gone, the hook now refreshes the slot's
  `efi-a/b` stage 2 + partsets and the ESP steamcl from the installed root's
  `/usr/lib/novadeck/boot` mirror and writes the bootconf (steps 1-4 land there), and the RAUC
  backend runs Valve's `bootloader-custom-backend.sh.in` over `steamos-bootconf`. Still open and
  independent of the boot path: steps 5-6 (the `steamos-update`/`novadeck-steamos-manager` D-Bus
  surface on the deck session bus, and the bundle server).
  **Steps 1-4 IMPLEMENTED 2026-07-28 on `feat/phase4b-rauc`, NOT yet HW-validated; steps 5-6 are
  deliberately deferred to a follow-up branch** (updates are CLI-driven for now, so a failure in
  this pass is attributable to the update machinery and not to UI wiring on top of it).
  Two deviations from the original wording below, both explained in `docs/phase4.md`: the new
  kernel ships **inside the rootfs** at `/usr/lib/novadeck/boot.img` rather than as bundle content
  (makes kernel/module coherence true by construction, and needs no RAUC handler-environment
  variable), and the `/var` migration copies **`machine-id` alone** rather than rsyncing `/var`
  (copying the write-once `mac-wifi` would relocate the machine-id bug rather than fix it).
  **This paragraph is STALE as of the 2026-07-28 HW run — the shipped hook does something else.**
  It logs `copied /var wholesale (14M, offload bind mounts skipped)`, and slot b was confirmed to
  receive `powerd.state` and a rewritten `slot` but **not** `mac-wifi`. The outcome is still right:
  `machine-id` rides across in the `/etc` overlay upper (`/var/lib/overlays/etc/upper/machine-id`),
  both slots read `7070e56b…`, both derive `66:53:fc:41:2d:f7`, and the device kept the same IP
  across an install + slot switch. `mac-wifi` being absent is harmless — `gen-mac.sh:40` treats it
  as a cache and re-derives identically. Reword this to describe the wholesale copy, or change the
  hook to match the wording; right now the doc and the code disagree.
  Also corrected while implementing: `btrfs-progs` was **not** on the device at all, so step 3's
  `btrfstune` had nothing to run — it is now in `PKGS` alongside `rauc`. Pass 2, in `docs/phase4.md`:
  1. `PKGS += rauc` + `make relock`. **Measured 2026-07-27: `rauc-1.14-1` IS in the pinned
     snapshot's `extra` repo** and every dep but `json-glib` is already in `manifest.lock` — so no
     `packages/rauc/` from-source recipe is needed, which was the largest unknown.
     **Overturned by the 2026-07-28 HW run: that snapshot 1.14 cannot install a verity bundle on
     kernel >= 6.19** (fixed upstream first in `v1.15.1`), and we ship 7.1.x — so it fails every
     install. `packages/rauc/` now exists after all: the holo 1.14-1 recipe, version-bumped to
     **1.15.2**, no other change. Higher `pkgver` than holo's, so pacman prefers it by version,
     not by repo order.
  2. `/etc/rauc/system.conf`: two slot groups, `bootloader=custom` pointed at `novadeck-bootctl`
     (its `get-primary`/`set-primary`/`get-state`/`set-state` already implement that contract), and
     `keyring=/etc/rauc/keyring.pem` installed from the committed `images/rauc/novadeck-ca.pem`.
  3. Post-install hook: **randomise the target slot's btrfs fsid.** Every `rauc install` writes
     identical bytes into the inactive slot, so both slots end up sharing an fsid AND `devid=1` —
     the pair btrfs keys its device list on — and mounting one can hand you the other. `make
     sdcard` already handles this with `btrfstune -U`; the hook must do the same. Invisible until
     a slot test starts lying, so it is written down here rather than discovered twice.
  4. The kernel half of C (`KERNEL.BAK`). **Settle first:** promoting `/KERNEL` at the same time
     the new root goes on trial makes a bad kernel unrecoverable; NOT promoting it means the trial
     boot runs the new root under the old kernel, whose `/lib/modules/<oldver>` that root does not
     carry (2817 modules, and `CFG80211`/`ATH12K` are `=m`, so that boot has no Wi-Fi). Neither is
     free. Pass 1 deliberately does not prejudge it — the restore is reserved in the state format
     but not implemented.
  5. Wire `steamos-update` + the `novadeck-steamos-manager` D-Bus surface. It must own the name on
     the **deck session bus**, not the system bus, or SteamUI will not see it
     ([[power-profiles-device-env-stack]]).
  6. A bundle server (an Oracle Cloud instance is available; nginx over HTTPS is enough — the
     bundle is signed by the release cert and the device trusts the CA).

- [x] **`verify-signing.sh` hand-copies the release cert's extensions from `ci/gen-signing-ca.sh`
  — FIXED 2026-07-29 by option 1 (factor the profile into a file both read), plus the two holes
  found while doing it.** The profile now lives in `images/rauc/release.ext`, read by
  `ci/gen-signing-ca.sh` and `images/rauc/verify-signing.sh` alike: there is no second copy left to
  drift, so the failure this item describes is gone by construction rather than by an assertion.
  Option 2 (shell out to the CA script) was rejected for the reason recorded below — it mints a
  real 4096-bit CA and refuses to overwrite an existing one. Option 3 (assert the shipped cert's
  EKU) is in as well, in the stronger form: **`verify-signing.sh` now asserts the profile actually
  LANDED on the cert it minted.** That hole was not in the original item and is worse than the one
  that was: `openssl x509 -req` with an empty or unparseable `-extfile` mints a cert with NO
  extensions and reports success, and an EKU-less cert satisfies RAUC's DEFAULT `smimesign`
  purpose — so a truncated profile could have taken the whole self-test green while it asserted
  nothing. Also closed: the "still manual" note below. When `out/pki` exists, `openssl verify
  -CAfile` now proves the committed `images/rauc/novadeck-ca.pem` is the CA behind
  `release.cert.pem`; when it does not (CI), the run says `skip ... NOT checked` rather than
  passing silently. Nothing else in the repo can see that mistake, and it ships a device that
  rejects every bundle we can ever sign, curable only by reflash.
  **`images/test-verify-signing.sh`, 26 checks, `make test-signing`** (container-only — it signs
  real bundles, so it needs rauc; the other three suites stay host-side). **Every case is a
  negative**: the check-purpose regression that actually shipped, a wrong `check-purpose`, a
  `bundle-formats` that disagrees with the manifest template, an empty profile, a profile without
  `codeSigning`, a missing profile, an unrelated keyring, an absent PKI, plus a structural case
  asserting neither script has grown a second copy of the extensions again. A self-test that cannot
  be made to fail is indistinguishable from one that always passes.
  Mutation-tested like the post-install suite: deleting the profile-landed assertion (2 checks),
  the keyring/PKI check (2), or re-adding a hand-copied EKU (1) each turns it red. One nuance worth
  keeping: with the profile assertion removed, an empty profile still fails — but the message
  blames `system.conf` for rejecting a codeSigning cert, which is the misdiagnosis that would send
  someone to widen `check-purpose`. The assertion converts a misleading red into a correct one, and
  is a true green-when-broken only if `check-purpose` is missing too.
  `ci/gen-signing-ca.sh` was verified end-to-end against a scratch tree — never the repo, since it
  installs the keyring — and mints `CA:FALSE + digitalSignature + codeSigning` from the shared file.
  ORIGINAL ITEM, kept for the reasoning: `5d6c447` (`feat/phase4b-rauc`, since merged to `main`) added
  `images/rauc/verify-signing.sh`, which signs a throwaway bundle and verifies it through the
  shipped `/etc/rauc/system.conf`. It catches the real bug it was written for (a `codeSigning`
  EKU against RAUC's default `smimesign` purpose rejects every bundle), but it mints its own
  cert with `basicConstraints`/`keyUsage`/`extendedKeyUsage` **copied by hand** from
  `release.ext` in `ci/gen-signing-ca.sh`. If those drift apart the test keeps passing for a
  cert profile we no longer ship — a green check asserting the wrong thing, which is worse than
  no check. It mints its own rather than reusing `out/pki` deliberately: that key is gitignored
  and absent in CI. Options, none free: factor `release.ext` into a file both scripts read;
  have the self-test shell out to `ci/gen-signing-ca.sh` with `PKIDIR` pointed at a temp dir
  (mints a real 4096-bit CA, slower, and that script refuses to overwrite an existing CA); or
  assert the shipped cert's EKU with `openssl x509 -noout -ext extendedKeyUsage` when
  `out/pki` happens to exist. Related: the self-test also does NOT check that
  `images/rauc/novadeck-ca.pem` matches the key in `out/pki` — verified by hand as of `5d6c447`,
  still manual.

- [x] **Build `packages/rauc/` at v1.15.2 — the pinned snapshot's `rauc 1.14-1` CANNOT install a
  verity bundle on our kernel** — LANDED 2026-07-28 (`packages/rauc`, `8304bc6`). Kept as the
  ROOT-CAUSE record for the closed item above; that one records the HW evidence that 1.15.2
  installs, this one records why 1.14 could not. `rauc install` failed at 30%:

      Failed mounting bundle: Unexpected dm-verity status 'V -' (instead of '\0')

  Not our bug and nothing novadeck-specific. Kernel commit `ae97648e14f7` extended dm-verity's
  `STATUSTYPE_INFO` with a trailing FEC corrected-block count, emitted UNCONDITIONALLY —
  `drivers/md/dm-verity-target.c:849` in our 7.1.5 tree prints `" %lld"` with FEC on and `" -"`
  with it off. So `V -` means *verified, FEC disabled*: the integrity check PASSED and rauc
  rejected the status string. `rauc < 1.15.1` does a strict full-string compare (`src/dm.c:242`
  at v1.14). Upstream fix is `a45cdb14` "src/dm: fix compatibility with new dm-verity output in
  since v6.19-rc1" (+ refactor `a40986fe`), upstream issue #1842, by RAUC's own maintainer —
  splits on spaces and checks only the first field. **First released in v1.15.1**; not in v1.14
  or v1.15. Enabling `CONFIG_DM_VERITY_FEC` does NOT help: it emits `V 0`, equally unequal.

  Decision: build `packages/rauc/` from the upstream **v1.15.2** release through the existing
  overlay pipeline (a clean version bump, NOT a hand-written patch — that distinction is why this
  path was chosen over editing the parse ourselves), then `make relock` → rootfs → fresh card.
  This reintroduces the from-source recipe that pass 2 had avoided; `[novadeck]` precedes the
  snapshot in repo order, so the overlay build is the supported way to outrank `rauc 1.14-1`.
  Keeps `bundle-formats=verity` as designed — do NOT fall back to `plain` in the shipped config.

  Two results worth keeping from the HW run:
  - **the failure is SAFE.** rauc aborted before writing: slot B's fsid was unchanged
    (`0dfb7b2e…` before and after), `dmsetup ls` showed no leftover devices, and slot state was
    untouched (`gen=1 active=a pending=<none>`). A broken bundle format cannot strand the device.
  - **`check-purpose=codesign` is HW-CONFIRMED** (`5d6c447`, since merged to `main`).
    On-device `rauc info` against the real `/etc/rauc/system.conf` + `/etc/rauc/keyring.pem`:
    `Verified inline signature by 'O = novadeck, CN = novadeck OTA release'`. That fix is correct
    and independent of this one.

  **Blind spot this exposed** — the acute form is CLOSED, the general form is NOT. At the time,
  `images/rauc/verify-signing.sh` ran the BUILD CONTAINER's rauc (1.15.1, already carrying
  `a45cdb14`) while the device ran 1.14, so the offline self-test validated the shipped config
  against a binary that could not reproduce the device's failure. Both sides are now on the fixed
  line — build container `RAUC_VERSION=1.15.1-1` (`build/Dockerfile:23`), device `packages/rauc`
  1.15.2 — so this exact skew cannot recur. They are still not the SAME binary, and the structural
  point survives: `verify-signing.sh` asserts cert profile, bundle format and keyring agreement
  against the writer, never against the device's installer. An offline pass is still not evidence
  about the device — only an HW `rauc install` is. Same statement as the closed rauc-1.15.2 item
  above; keep them in sync.

- [x] **Phase 4c — bootstrap the root from packages — LANDED + HW-VALIDATED 2026-07-26**
  (design: `docs/phase4.md`; branch `feat/phase4-manifest-rootfs`). The rootfs no
  longer ORIGINATES as `docker export` of a vendor image: it is `pacman -r <empty-dir>` against the
  pinned snapshot. Docker is still required and so is qemu binfmt — an aarch64 root has to be laid
  down by an aarch64 pacman running aarch64 scriptlets — but it is now the EXECUTION ENVIRONMENT
  only (`base-devel.digest`, shared with `packages/build-overlay.sh`), never the content source.
  `base.digest` is deleted, as are `images/fetch-base.sh`, `sanitize_base_provenance()` and
  `images/provenance.list`.
  **Result:** the lock's 116 `base` rows (no package file, so no sha256, so ~29% of the image
  outside anything reviewable) are gone. `images/manifest.lock` is **398/398 rows hashed**, up from
  282, and `stripped` rows became installable (they are `base` metapackage deps, fetched and
  verified like any `snapshot` row, then deleted by the seal).
  **The set did not change.** Measured before writing any code: `pacman -r <empty> -Sy base <PKGS>`
  resolves 394 packages matching the old lock **name-for-name and version-for-version**, and the
  relocked file confirms it — 120 of 124 changed lines are a class rename plus a hash appearing.
  Image size is unchanged too (6.1G apparent, vs 6157 MiB recorded for the last export build).
  **Blocker found by that measurement** (`151c9f0`): `packages/build-overlay.sh` copied the whole
  makepkg build directory into the overlay repo, so the six x86_64 packages `packages/fex-emu`
  DOWNLOADS for its sysroot were indexed as installable `[novadeck]` packages. Invisible while the
  root arrived pre-populated (those names were already installed); a bootstrap picked the overlay's
  glibc 2.43 over the snapshot's 2.42. Fixed with `PKGDEST` + a foreign-arch drop at index time.
  **Three defects found by reading the built tree of a GREEN build** — pacman reports a failed hook
  as a warning, so none of them failed anything. All share one cause: pacman runs scriptlets and
  hooks chrooted into a target with no `/proc`, `/dev` or `/sys` (pacstrap mounts them; we cannot,
  `CAP_SYS_ADMIN` is dropped). (a) `systemd-tmpfiles` never ran, so directories a read-only root
  can never create at boot were absent — and running it with `--root=` then failed a second time
  because `work/base` was host-owned while its contents were root ("unsafe path transition"), so
  the target root is now created root-owned inside the container. (b) `journalctl
  --update-catalog` failed, leaving no `/var/lib/systemd/catalog/database` and so no `journalctl
  -x` explanations — on a device whose only debug path is an offloaded journal. Both now run
  offline with `--root=`. (c) `gnupg`'s scriptlet died on `/dev/null`; the five standard nodes are
  now `mknod`'d before the install (`CAP_MKNOD` is granted). Commits `1254f1b`, `4a2cec6`.
  **Identity is ours now:** `/etc/os-release` (`images/os-release`, `ID=novadeck` — we shipped
  `ID=holo-core` before), `/etc/locale.conf` and `/etc/hostname`. None is owned by any package,
  measured against the snapshot, so a bootstrap that wrote none of them would have inherited the
  vendor's string, an unset LANG and a compiled-in hostname.
  **HW result 2026-07-26:** a card built from the bootstrap booted OOBE and then a SteamUI session,
  exactly as the 4a card did — no regression from changing where the tree comes from. The four
  post-conditions checked on the booted card: `/etc/os-release` reads `ID=novadeck` (not
  `holo-core`), `/etc/locale.conf` `LANG=en_US.UTF-8` and `/etc/hostname` `novadeck`; the journal
  catalog `database` exists at 286K (on the `/var` partition — the root's own `/var` is an empty
  mountpoint, so check the mounted one, not the root tree); `/usr`, `/etc` and `/var` are all
  `root:root 755`, so the host-ownership "unsafe path transition" is gone; and `/.dockerenv` is
  absent, which is what stops systemd misdetecting a container and skipping every
  `ConditionVirtualization=!container` unit.
  **Carried forward as their own items:** the two above (prebuilt tarballs at `/`, and the guard
  never asserting file ownership). See [[rootfs-build-approach]],
  [[dockerenv-systemd-container-misdetect]], [[overlay-package-pipeline]].

- [x] **Phase 4a — sealed manifest rootfs — ALL FIVE STEPS LANDED + HW-VALIDATED 2026-07-26**
  (plan: `docs/phase4.md`; branch `feat/phase4-manifest-rootfs`). The half of Phase 4 that could not
  brick a device (a bad build just fails to boot a card you reflash). A sealed **release** card boots
  to a session on HW, and the guard passes in the release build.
  (0) **Mirror re-pinned** to an explicit `mash-20251118.3` (`6abd676`, `0f82f36`) — `snapshot.pin` is
  a base input, and `customize-base.sh` overwrites the base's mirrorlist with it, *refusing* an
  unsuffixed URL and folding the revision into the reuse key. The finding that forced it: our
  `mirrorlist` pointed at the UNSUFFIXED path, which is an **alias tracking the newest revision**
  (unsuffixed and `.3` share ETag `6a510539-16f23323`; `.2` is a different, five-weeks-older
  artifact). It had never bitten us only because all three revisions carry an identical 4560-package
  set — weaker than it looks, since equal versions do not prove equal package files.
  (1) **`images/manifest.lock` committed** (`images/genmanifest.sh`, `make relock`) — `name version
  arch source sha256`, 398 rows: 265 `snapshot` / 116 `base` / 9 `novadeck` / 4 `prebuilt` /
  4 `stripped`. The sha256 is what catches a same-version rebuild; `base` rows carry none (they ship
  inside the digest-pinned image — the gap Phase 4c then closed; every row is hashed now).
  (2) **Install from the lock**, not `pacman -Sy` (`images/fetchlock.sh`, `c29bd62`).
  (3) **Release root sealed** (`images/seal.list` + `images/seal-rootfs.sh`, `a9ea0e6`): 4 packages
  (`pacman`, `pacman-mirrorlist`, `gnupg`, `archlinux-keyring`) + 2 paths (`var/lib/pacman`,
  `etc/pacman.d`), with the DB preserved as provenance at `/usr/lib/novadeck/pkgdb`. **FILE REMOVAL,
  not `pacman -R`** — these are deps of the `base` metapackage, so a removal transaction is refused;
  that is why the set is a hand-reviewed declaration rather than a derivation. Nothing is stripped
  under `NOVADECK_DEV=1` (on-device pacman is a real bring-up affordance; divergence confined to
  tooling). This killed the ~90s "stop job … GnuPG network certificate management daemon" stall by
  deleting the daemon instead of masking it — HW-confirmed, and it supersedes
  [[dirmngr-slow-shutdown-defer-phase4]]'s "defer, do not patch". The *other* ~90s cause
  (`gamescope-wl` ignoring SIGTERM) is the separate open item at the top of this file.
  (4) **Guard on the BUILT TREE** (`images/guard-rootfs.sh`, `2843e0d` + `391a5f5`), release-only,
  6 assertions: the seal's declaration fully applied (expanded through the preserved DB, not a
  hand-kept list); the named pacman/gnupg/dirmngr entry points gone — and each name cross-checked
  against what `seal.list` actually removes, so a typo can't become a dead assertion; no dangling
  systemd enable-symlink (scoped to `.wants`/`.requires` — the base image carries ~48 pre-existing
  dangling links elsewhere); no build-provenance marker survived (`images/provenance.list`,
  `0a4716e` — `/.dockerenv` is the one that costs a HW cycle, see
  [[dockerenv-systemd-container-misdetect]]); the lock still describes the tree (set equality both
  ways + `stripped` rows == `seal.list`'s `pkg` rows); and a per-top-level-directory size delta
  (report only, never fails a build; baseline recorded to `out/images/rootfs.sizes` *only* on a pass,
  so a rejected tree never becomes the next build's normal). **It asserts the TREE, never the source
  diff** — this repo already shipped a change that was correct in the diff and wrong in the built
  tree (the git-644 mode regression that blacked out the OOBE, [[gamescope-x11-unix-tmpfiles-oobe]]).
  Last release build: 8707 MiB staged → 6157 MiB `rootfs.img`.
  **Carried forward as their own items:** Phase 4b (A/B updates, design C) and the
  non-reproducible `novadeck` lock rows that block CI. Phase 4c (bootstrap from packages) LANDED
  2026-07-26 — see its own item above; it retired the 116 `base` rows and `base.digest`. See [[rootfs-build-approach]].

- [x] **Rework overlay build to only rebuild changed packages** — DONE (build-infra, not yet
  HW-cycle-validated). `build-overlay.sh` is now incremental: it persists `work/repo/<arch>/` across
  runs and keeps a per-package stamp under `.stamps/<name>.hash` (sha256 of that package's own
  `source.pin` + patches + local PKGBUILD) plus `.stamps/<name>.files` (its produced artifacts). A
  package is rebuilt only when its hash changes or an artifact is missing — a one-line gamescope patch
  no longer recompiles mesa. Stale artifacts from a renamed/bumped build are purged via the per-package
  file manifest; the db is re-indexed from all present `*.pkg.tar.zst`. When nothing changed the script
  just `touch`es the db (mtime only — content/sha unchanged so customize-base's overlay reuse key stays
  warm). `$(OVERLAY_DB)` keeps the union prereq (re-invokes the now-cheap script, which self-selects);
  fail-fast "missing patch" guard preserved. See [[overlay-package-pipeline]],
  [[overlay-isolate-per-package-container]], [[content-hash-cache-pattern]].

- [x] **FEX + baked arm64 Proton — DONE + HW-VALIDATED 2026-07-11** (commits `5636d21` bake,
  `d46d156` native-x86 thunkless fix). Replaced the old `proton11sc`/`novadeck-chain` two-runtime fetch
  (SLR 4.0 Arm64 `4185400` → Proton 11 ARM64 `4628740`), now deleted. Shipped: `packages/fex-emu/`
  (from-source PKGBUILD, FEX-2607, Arch x86 sysroot assembled in `prepare()` from pinned
  `archive.archlinux.org` packages), `packages/fex-rootfs/` (`ArchLinux.ero`, raw-file pin),
  `packages/proton-cachyos/` (baked compat tool), `fex/` (system `Config.json` + `proton-wrapper`).
  Root slots grew 5G→8G, then 8G→6G once zstd-sealed ([[steamos-partition-overlay-layout]]).
  **KEY FINDING: the two x86 paths are INDEPENDENT** — Windows games use Proton's *bundled* WoW64 FEX
  (no system FEX, no rootfs, no thunks, no SLR container); only native x86 *Linux* ELFs use the
  `fex-emu` package + `ArchLinux.ero` + binfmt. Native x86 Linux titles (Super Meat Boy, Garage Circuit
  Rally) resolved by adopting ROCKNIX's **thunkless** FEX `Config.json` globally — both playable,
  user-confirmed. **NOTE — this deliberately REVERSED the earlier "use Valve's precompiled FEX, do NOT
  ship our own" stance** (user 2026-07-08). See [[fex-rearchitecture-pickup]],
  [[fex-native-x86-game-crash-hw]], [[fex-two-paths-independent]],
  [[native-x86-linux-games-xwayland-fix]], [[steam-native-arm64-launch-chain]].

- [x] **Make `proton-cachyos-11.0-arm64` the DEFAULT compat tool (CompatToolMapping) — WON'T-DO
  (user, 2026-07-11).** The default-compat-tool change is declined; users set `proton-cachyos-11.0-arm64`
  manually per title via *Steam Play for all other titles* / per-game compat tool. HW evidence that
  motivated it stands (retained for provenance): anything that runs x86 code under the *system*-FEX path
  is fragile — Parking Garage Rally Circuit's *native x86-64 Linux* build crashes in system-FEX (SIGSEGV
  on `--rendering-driver opengl3`, SIGILL on Vulkan) while its *Windows* build runs fine on arm64 Proton;
  Gravity Circuit's Steam-auto-selected **stock Proton 10.0** (x86 wine under system-FEX) threw a CRT
  `assert()` popup, fixed by forcing arm64 Proton. A native-FEX crash capture (FEXInterpreter
  unsupported-instruction log) remains an optional nice-to-have. See
  [[fex-native-x86-game-crash-hw]], [[fex-two-paths-independent]], [[fex-rearchitecture-pickup]].

- [x] **Native x86 SDL2 Linux games crash under system-FEX — RESOLVED 2026-07-11 (thunkless ROCKNIX
  config, NOT the wl_list thunk patch).** Both HW-test titles — Super Meat Boy (native x86-64 Linux SDL2
  ELF, AppId 40800) and Garage Circuit Rally — now run and are **playable** (user-confirmed "both are
  working"). Fix = adopt ROCKNIX's game-tuned FEX profile **globally** in
  `fex/usr/share/fex-emu/Config.json`: **thunkless** `ThunksDB` (all `0`) + ROCKNIX's JIT tuning,
  `RootFS`→`ArchLinux.ero`. Thunkless drops the WaylandClient thunk entirely, so games load the guest's
  REAL x86 libwayland (which DOES export `wl_list_*`) — the original `libdecor: undefined symbol:
  wl_list_init` load crash simply cannot occur, and the render-path `sig=11` (which was actually in the
  host GPU thunk path, not wayland) is gone because the guest x86 Mesa renders instead of forwarding to
  host Turnip. Trade-off: no host-Turnip accel for native x86 Linux titles (guest GPU driver runs
  emulated); acceptable — both titles are playable and ROCKNIX ships this globally incl. 3D. **Option C
  (the FEX guest-thunk `wl_list` patch, == upstream FEX#4520) was ABANDONED as moot** — correct in
  isolation, but the real crash cause was the GPU thunks, not the wayland thunk. This REVERSES the
  earlier "never copy ROCKNIX's thunkless ThunksDB" stance. NOTE: baked in the working tree (Config.json),
  COMMITTED (`5636d21` bake, `d46d156` thunkless fix); Config.json now at `fs-overlay/usr/share/fex-emu/`. See [[native-x86-linux-games-xwayland-fix]],
  [[fex-native-x86-game-crash-hw]], [[fex-two-paths-independent]].

- [x] **Cherry-pick FEX `Config.json` perf/compat knobs from ROCKNIX — DONE 2026-07-11 (adopted
  wholesale).** Instead of cherry-picking, the ENTIRE ROCKNIX game-tuned FEX `Config` block was taken
  globally (`Multiblock:1`, `SMCChecks:1`, `MonoHacks:1`, `VolatileMetadata:1`, `DynamicL1Cache`/
  `DisableL2Cache:1` + cache heuristics, `MaxInst:5000`, `KernelUnalignedAtomicBackpatching:1`,
  `DISABLE_VIXL_INDIRECT_RUNTIME_CALLS:1`, …) — the same change that closed the native-x86-crash item
  above. It also flips `ThunksDB` to **thunkless**, which the earlier note warned against; that warning
  is now overturned — thunkless is the right global default for the native x86 Linux system-FEX path
  because it's what actually made both test games run (trading host-Turnip speed for not-crashing). Baked
  COMMITTED (`5636d21`/`d46d156`). See [[fex-config-tuning-from-rocknix-todo]],
  [[native-x86-linux-games-xwayland-fix]], [[overlay-package-pipeline]].

- [x] **MangoHud performance-overlay enable/disable — FIXED + HW-VALIDATED 2026-07-25, COMMITTED `e8bc680`.**
  On HW the overlay now works: the launch command has NO `mangohud` prefix any more (the legacy-path
  tell), Steam's environ carries `STEAM_USE_MANGOAPP=1` + `MANGOHUD_CONFIGFILE`, and that file now
  holds lines the CLIENT wrote (`control=mangohud`, `fsr_steam_sharpness`, `nis_steam_sharpness`) —
  impossible before. Root cause: the Steam client never saw gamescope's steam-mode environment.
  `novadeck-session` backgrounds gamescope (`--steam -R/-T`) and then starts the client from the SAME
  shell, so Steam is gamescope's **sibling**, not its child: everything gamescope sets in
  `UpdateCompatEnvVars()` (`src/main.cpp` ~596-686 @ 3.16.23.2) lands in gamescope's own env and in what
  IT spawns (mangoapp) — never in Steam. The 2026-07-08 "already set, adding them is redundant" close
  read **mangoapp's** `/proc/<pid>/environ`, which is gamescope's child; Steam's environ carried only
  the two `STEAM_*` vars `novadeck-steam` set by hand. Without `STEAM_USE_MANGOAPP` the client takes the
  LEGACY overlay path — it prepends `mangohud` to the game launch command instead of driving mangoapp
  (exactly the HW-observed `reaper … -- mangohud <compat-tool> …`) — and without `MANGOHUD_CONFIGFILE`
  it has nowhere to write `preset=N` for the Level selector. The upstream SteamOS-derived session
  scripts export this whole block by hand *for this same reason* (their client is a sibling too).
  **Fix (`e8bc680`):** `novadeck-session` now creates + exports `MANGOHUD_CONFIGFILE` (seeded
  `no_display`) and `GAMESCOPE_LIMITER_FILE` in `$GS_RUNDIR` BEFORE launching gamescope — gamescope
  adopts them (both creations are guarded on the var being unset), mangoapp inherits from gamescope,
  Steam inherits from the shell; and `novadeck-steam` exports the client gates `STEAM_USE_MANGOAPP`,
  `STEAM_MANGOAPP_PRESETS_SUPPORTED`, `STEAM_MANGOAPP_HORIZONTAL_SUPPORTED`,
  `STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND`, `STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER`,
  `STEAM_GAMESCOPE_NIS_SUPPORTED`, `STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT`, `STEAM_MULTIPLE_XWAYLANDS`,
  `SRT_URLOPEN_PREFER_STEAM` (see the script for the ones deliberately NOT set, and why).
  **HW test:** in-game, toggle Performance on/off + change Level; confirm `mangohud` is NO LONGER
  prepended to the launch command, that `$MANGOHUD_CONFIGFILE` gains `preset=N`, and that the overlay
  follows. `STEAM_MULTIPLE_XWAYLANDS` is the one behaviour-changing gate — bisect it first if a title
  regresses. Package builds were audited against the peer distro and are NOT the problem: mangohud
  0.8.4 meson flags + all six Qualcomm patches match exactly, and every gamescope meson option is
  already on by default/auto in our build. See [[mangohud-quickaccess-control-gap]],
  [[sm8650-gamescope-session-plumbing]], [[chimeraos-gamescope-session-reference]].

- [x] **QuickAccess frame-rate limiter — FIXED + HW-VALIDATED 2026-07-25 (Vulkan titles).** Root cause: **the legacy `GAMESCOPE_FPS_LIMIT` X atom is
  dead in gamescope, and it is the only channel our client uses.** The Steam client writes the chosen
  cap into that root atom on `:0` correctly (HW: pick 30 in SteamUI -> `xprop -root
  GAMESCOPE_FPS_LIMIT` reads 30), but gamescope's handler assigns `g_nSteamCompMgrTargetFPS`
  directly, and `paint_all()` calls `update_app_target_refresh_cycle()` EVERY frame, which resets
  that global to 0 and recomputes it from `g_nCombinedAppRefreshCycleOverride[]` — written only by
  the `gamescope_control` WAYLAND protocol (`set_app_target_refresh_cycle`) and the
  `debug_set_fps_limit` concommand. So the cap survives <1 vblank. Identical code in 3.16.17, so NOT
  a regression from our version bump: upstream never exercises the atom because Valve's client drives
  the cap over the Wayland protocol — and **our arm64 client never opens gamescope's Wayland socket
  at all** (`lsof -U`: only the two Xwayland servers are connected, despite `GAMESCOPE_WAYLAND_DISPLAY`
  being set and `libwayland-client` mapped in the client). **Fix:** `packages/gamescope/patches/
  0004-fps-limit-atom-persist.patch` routes the atom through
  `steamcompmgr_set_app_refresh_cycle_override(..., change_refresh=false, change_fps_cap=true)`.
  **Pre-validated on HW without a rebuild** by bridging the atom to `gamescopectl debug_set_fps_limit`
  and timing `vkcube --c 300 --present_mode 2` on `:1`: with the value SteamUI itself wrote,
  30 -> 29fps, 20 -> 20fps, 0 -> 59fps. Everything else in the chain is confirmed HEALTHY — pacing,
  the focus gate, and `GAMESCOPE_LIMITER_FILE` all work, with AND without the FROG WSI layer.
  **HW-VALIDATED after rebuild:** the QuickAccess cap now works on Vulkan titles (user, 2026-07-25). Corrections to earlier entries, do not re-litigate: (a) the `xprop` reading of 60 was not
  the client clamping, it was the profile's value at the time — the atom tracks the selection fine;
  (b) `GAMESCOPE_LIMITER_FILE` reading `1` is a real signal (`g_nSteamCompMgrTargetFPS != 0`), not a
  false positive; (c) `STEAM_DISPLAY_REFRESH_LIMITS=40,60` is EXONERATED as the cause here — but see
  the follow-up below; (d) the GPU-submitting process is title-dependent (wine `explorer.exe` for one
  title, the `<Game>.exe` for another) — find it with `grep -l drm-engine-gpu /proc/*/fdinfo/*` and
  check for a NONZERO `drm-engine-gpu`, don't guess by name.
  See [[sm8650-gamescope-session-plumbing]], [[chimeraos-gamescope-session-reference]].

- [x] **One title (Gravity Circuit) not paced by the frame limiter — ROOT-CAUSED + HW-CONFIRMED
  2026-07-25: it free-runs without vsync; `vblank_mode=3` fixes it.** The hypothesis held: gamescope
  caps by withholding wl frame callbacks, which throttles only a client that WAITS on them, so a title
  that presents without vsync is untouchable by the compositor's limiter no matter how healthy the
  rest of the chain is. Setting `vblank_mode=3 %command%` (Mesa GL force sync-to-vblank) as the title's
  Steam launch option makes the QuickAccess cap bite — user-confirmed on HW. With patch 0004 the cap
  therefore works on vulkan titles, on OpenGL titles that already vsync (Parking Garage Circuit in
  OpenGL3 mode), and now on this one. **Two earlier framings were WRONG and stay retracted — do not
  resurrect them:** "GL titles cannot be capped at all" and "gamescope's pacing does not reach GL
  titles". It was never an API class; it was one title's presentation mode. ROCKNIX's route (in-process
  MangoHud `fps_limit` sleeping in the swap call, no gamescope) remains unreachable in our mangoapp
  architecture and was correctly not pursued. **Productization is a separate item, still open in
  TODO.md** (how `vblank_mode=3` ships).

- [x] **`STEAM_DISPLAY_REFRESH_LIMITS=40,60` was a fabricated range — RESOLVED, COMMITTED `6960aa8`
  (registry-derived; NOT booted).** The hardcoded `40,60` was the Steam Deck LCD device-quirk and was
  wrong in BOTH directions: it invented a 40Hz floor no panel of ours has a mode for (the S2/wt0630,
  ACE, DMG, TD4328 and XM91080G drivers each declare exactly one `drm_display_mode`), and it capped the
  genuinely multi-rate boards at 60 (evo, ds, odin-2-portal, thor, retroid-pocket-6 have real 60+120
  modes). Worst case was the Pocket FIT: a single 144Hz mode, the session already passing `-r 144`, and
  Steam told the maximum was 60. Fix = `novadeck-steam` resolves `NOVADECK_PANEL_REFRESH_RATES` from
  the device-env registry and sets `<first>,<last>` ONLY when the panel really is multi-rate, else
  leaves the var unset — the same derive-or-unset rule the reference session script uses. GOTCHA:
  `novadeck-session` evals device-env WITHOUT export, so the `NOVADECK_*` facts do not reach this
  client and it has to eval the helper itself. Verified by evaluating the real registry through `sh`
  (S2 unset, Pocket FIT unset, Retroid Pocket 6 → `60,120`, ACE unset); `sh -n` clean. Exonerated as
  the frame-limiter cause (that was the gamescope atom, above), and the QuickAccess cap stays
  selectable on a 60Hz board regardless — it is driven by `STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER`, whose
  choices are divisors of the CURRENT refresh. See [[power-profiles-device-env-stack]].

- [x] **`STEAM_ENABLE_DYNAMIC_BACKLIGHT` export DROPPED — DONE + HW-VALIDATED 2026-07-25 (user
  decision, user-confirmed on device).** The unconditional `=1` was the Steam Deck's adaptive-brightness
  gate; almost none of the boards we support have an ambient-light sensor, and any that do most likely
  have no upstream driver, so nothing publishes an `iio` light channel for the client to read — it
  advertised a toggle that cannot work. Now listed in `novadeck-steam`'s DELIBERATELY-NOT-SET block
  with the rule that a future ALS board derives it per-board from the device-env registry (as
  `STEAM_DISPLAY_REFRESH_LIMITS` does), never a blanket `=1`.
  **Regression risk RAISED AND CLEARED on HW (2026-07-25).** The worry was that the closed "Wire
  brightness controls" item below (2026-07-05) credited this same gate with making the slider
  *appear*, which would have made removing it a regression rather than a cleanup — and it could not
  be settled off-device (`strings steamui.so` shows the client reads
  `STEAM_ENABLE_DYNAMIC_BACKLIGHT`, `display_backlight_raw` and `/sys/class/backlight/`, but not
  which control each gates). Tested: with the export gone, the QuickAccess brightness **slider is
  still present and still drives the panel** (user-confirmed). So the gate is the ADAPTIVE-brightness
  feature only; the manual slider never depended on it. **That 2026-07-05 claim is retracted in place
  below** — the udev ACL in `60-novadeck-perf-acls.rules` is the whole story for manual brightness.
  Do not restore this export to "fix" a slider problem. See [[brightness-volume-keys-resolved]].

- [x] **Switch InputPlumber virtual device from DS5 to Xbox — DONE, COMMITTED `b63e4fe`, HW-VALIDATED.**
  (Files moved from `devices/inputplumber/` → `fs-overlay/usr/...` in the `4bce06a` refactor.)
  Reversed ROCKNIX commit `296851b1` (which had moved SM8650 xbox-series→ds5) for our port. Target is
  **`xbox-series`** (not the Elite variant floated earlier — plain xbox-series is what the ROCKNIX
  reverse restores, and gives standard Xbox glyphs). Two files changed in `devices/inputplumber/`:
  (1) `devices.d/01-ayaneo-controller.yaml` — `target_devices: [ds5, keyboard]` → `[xbox-series,
  keyboard]` (deliberately did NOT re-add the `mouse` target the strict reverse carries, per user);
  (2) `capability_maps.d/ayaneo_mcu_xbox_standard.yaml` — the BTN5 mapping goes back from the ds5-era
  keyboard shim (`F1 Key` → `keyboard: KeyF1`) to a real gamepad button (`QuickAccess2 Button` →
  `gamepad: QuickAccess2`), matching the map's "(Xbox mode)" name. Everything else (Guide, sticks,
  dpad, triggers) was untouched by that commit. **HW-CONFIRMED on the Pocket S2:** all buttons + dpad
  map, the QuickAccess2 button reaches Steam, and Steam Input shows Xbox glyphs. See
  [[sm8650-inputplumber-input]].

- [x] **SteamUI scale lever — RESOLVED 2026-07-14 via gamescope `GAMESCOPE_FAKE_OUTPUT_MM`** (patch
  `0003-drmbackend-fake-output-mm.patch`, exported by `novadeck-session` from device-env); was
  panel-mm-IGNORED since 2026-07-11. Original investigation retained below. — a Steam client
  update **stopped honoring the panel's physical mm** for gamepad-UI auto-scale (it does NOT "fix" scale,
  it ignores the dimension). Symptom: the UI now renders **too small** on the Pocket S2, and reverting
  `kernel/patches/0062` (wt0630) from the old +20% fudge (94×168) to the panel's **real 79×140 mm** built,
  flashed, and **changed nothing on HW** — proving mm no longer moves the scale. The old "mm magnitude is
  the lever" thesis (HW-believed 2026-07-07) is dead. Panel now ships TRUE dimensions (correct, but no
  longer a scale control). **Still open:** the UI is too small and we have no working lever yet — chase
  where SteamUI/gamescope now sources its DPI/scale (client config, gamescope `--scale`/output props, a
  new env) and wire a per-device control. Knock-on: Pocket Fit (`kernel/patches/0063`) needs real mm only
  for EDID sanity, NOT to chase UI size; gamescope `0003` status unchanged (coherence-only swap). See
  [[steam-ui-scale-panel-mm]], [[sm8650-working-display-baseline]], [[sm8650-gamescope-session-plumbing]].

- [x] **Replace our rotation-shader patch with upstream composited-output rotation** — DONE, rotation
  HW-confirmed on Pocket S2 2026-07-07: orientation is upright-landscape and gamescope auto-engages
  the composite pass off the connector orientation (no `--force-composition-rotation` needed). The UI
  auto-scale bug is still open, tracked separately below. Swapped the ROCKNIX `--use-rotation-shader`
  patch for upstream gamescope PR
  [#2228](https://github.com/ValveSoftware/gamescope/pull/2228) (`packages/gamescope/patches/0001-composite-rotation-pr2228.patch`):
  rotation via a composition pass (scene stays in logical landscape space; only the final store
  coordinate is rotated, so sampling/blending/input/cursor/EDID stay coherent). We drop the launch
  flag entirely and let gamescope AUTO-ENGAGE off the DRM connector panel orientation (our DTS
  `rotation=<90>`) when the primary plane can't rotate at scanout — no `--use-rotation-shader`, no
  `--force-composition-rotation` (`fs-overlay/usr/bin/novadeck-session` launches bare
  `--backend drm`; the TEST-only `nova-gamescope-smoke` in `images/assemble-rootfs.sh` did too, and
  was removed 2026-07-30 — the real session covers the same path). `-W/-H` stay the landscape logical size (PR keeps
  `g_nOutputWidth/Height` unswapped). The nightmode patch is renumbered `0002`. **HW to re-validate:**
  (1) panel is upright-landscape, not 180°-flipped or blank (if flipped, the connector orientation /
  rotation direction differs from ROCKNIX's shader — compensate via `--force-orientation`); (2) the
  L2 re-launch flip behavior ([[sm8650-gamescope-flip-blocker]]); (3) whether this also fixes the
  UI-scale bug below (the coherent EDID/phys-size orientation is the root-cause candidate). WSI +
  version pin (3.16.23.2) preserved.

- [x] **Poweroff / sleep issues resurfacing** — RESOLVED by the Steam-driven power/suspend
  rearchitecture (commit `86c88fa`, HW-validated on Pocket S2 2026-07-05): `novadeck-powerbuttond`
  forwards the power key to Steam (`steam://shortpowerpress`/`longpowerpress`); logind ignores
  power/suspend/lid keys but still services `Suspend()`; a `systemd-suspend.service` drop-in redirects
  every logind `Suspend()` into `novadeck-suspend`'s userspace fake-suspend (freezes user.slice, grabs
  the power key, blocks until wake); retired the old `novadeck-waked` + `novadeck-wake.slice`. This
  puts the client in charge of the power menu, addressing the sentinel-handler suspicion. See
  [[suspend-freeze-wake-design]], [[suspend-systemctl-while-frozen-blocks]],
  [[sm8650-gamescope-session-plumbing]], [[dirmngr-slow-shutdown-defer-phase4]].

- [x] **Wire brightness controls** — RESOLVED, HW-validated 2026-07-05 (branch
  `feat/brightness-volume-perf-acls`). ~~Env gate (`STEAM_ENABLE_DYNAMIC_BACKLIGHT=1`) made the slider
  appear but~~ **RETRACTED 2026-07-25** — that env gate had nothing to do with the slider appearing
  (dropping it left the slider working on HW; see the item above). The real and only problem was that
  the write path was missing: `/sys/class/backlight/sy7758-backlight/brightness` is
  `root:root 0644` on the RO root and gamescope runs as `deck`. Fix = `hw-support/usr/lib/udev/
  rules.d/60-novadeck-perf-acls.rules` (chgrp `wheel` + `g+w` on backlight brightness — plus cpu/gpu
  perf knobs; deck ∈ wheel). Live-validated: deck wrote brightness, panel responded. See
  [[brightness-volume-keys-resolved]].

- [x] **Volume buttons don't change volume (OSD shows, no change)** — RESOLVED, HW-validated
  2026-07-05 (same branch). The keys reach the Steam client (OSD draws) but the native arm64 client
  never applies the change to PipeWire; the QuickAccess slider does. No OS-level volume-key handler
  exists in SteamOS or Armada (client-only; SteamOS's is x86 and works) — nothing to port, confirmed
  by mounting the SteamOS recovery image. Fix = NEW daemon `hw-support/usr/bin/novadeck-hotkeyd`:
  `libinput debug-events` → `wpctl` in the deck PipeWire session on KEY_VOLUMEUP/DOWN/MUTE (Steam's
  OSD follows the sink); also maps KEY_BRIGHTNESSUP/DOWN → backlight step (clamped). Keys come from
  `gpio-keys`, not the DS5. HW: 0.45→0.55, OSD moved. `stdbuf -oL` on libinput was required (piped
  block-buffering). See [[brightness-volume-keys-resolved]].

- [x] **Rearchitect power/suspend to the Steam-driven model; retire `novadeck-waked`** — DONE +
  **HW-VALIDATED 2026-07-05** (Pocket S2). Replaced our bespoke power-key daemon (which read the key AND drove
  suspend/poweroff itself) with the reference handheld split, so Steam owns the power UX and we only
  intercept the kernel suspend:
  - **`novadeck-powerbuttond`** (NEW, root system service): forwards the power key to the running
    Steam client — short → `steam://shortpowerpress` (sleep), long → `steam://longpowerpress` (power
    menu). Reads evdev as root, dispatches via `runuser` into the deck session (mirrors `hotkeyd`).
  - **logind drop-in**: expanded to ignore Power/Suspend/Hibernate/Lid keys (Steam owns them) while
    still SERVICING the `Suspend()` D-Bus call — the path we intercept.
  - **`systemd-suspend.service` drop-in** → `ExecStart=/usr/bin/novadeck-suspend sleep`,
    `TimeoutStartSec=infinity`. EVERY logind `Suspend()` (Steam menu, idle, forwarded key) lands in
    fake-suspend; kernel s2idle/s2ram is unreachable via the normal stack.
  - **`novadeck-suspend` rewritten** into a self-contained blocking engine: freezes **user.slice only**
    (engine/journald/dbus/logind stay live in system.slice → the whole thaw-before-dbus / autothaw /
    wake.slice gotcha layer is GONE), lowers power, then **grabs the power key** (`libinput --grab`,
    EVIOCGRAB) and blocks until KEY_POWER — it owns the wake. The grab stops the (un-frozen) forwarder
    from bouncing us back into suspend on resume.
  - **Deleted**: `novadeck-waked` + service + preset + wants, `novadeck-wake.slice`, the interim
    `suspend-to-freeze` bridge, autothaw. **`novadeck-hotkeyd` unchanged** (separate volume/brightness
    agent). `git` history keeps `waked` recoverable.

  **Linchpin CONFIRMED (HW 2026-07-05):** short-press → `powerbuttond: tap 131ms -> shortpowerpress`
  → Steam called a logind `Suspend()` → `novadeck-suspend` froze `user.slice`, grabbed the power key,
  and the power key woke it — `journalctl -k` shows NO `PM: suspend`/`s2idle`/`/sys/power` write, so
  kernel suspend never fired. Not exercised yet: the Steam "Sleep" menu and idle-timeout entry points
  (same logind path, expected fine). NOT covered: hibernate/hybrid-sleep (Steam never calls them; mask
  if a path appears). See [[suspend-freeze-wake-design]], [[waked-holdtime-background-dispatch]],
  [[brightness-volume-keys-resolved]].

- [x] **Narrow the fake-suspend freeze set so the session bus stays live — DONE + HW-VALIDATED
  2026-07-26 (Pocket S2, full suspend/resume cycle with a game running).** Default is now
  `/sys/fs/cgroup/user.slice/user-1000.slice/session-*.scope` in both `novadeck-suspend` and the
  `rest.conf` template. **Cycle evidence:** 43 consecutive frozen samples over ~70s with the scope's
  `cpu.stat usage_usec` pinned at exactly `660453813` — the game and the whole session truly halted,
  zero drift; `systemctl --user is-active dbus-broker` answered as `deck` THROUGHOUT the frozen window
  (it used to hang); root SSH stayed *responsive* the entire time rather than going dead; wake on
  KEY_POWER thawed cleanly and `usage_usec` resumed advancing at its pre-freeze rate. Test ran with
  `NOVADECK_SUSPEND_SKIP="rfkill"` so the link stayed up to observe — orthogonal to the freeze set.
  **CAVEAT — one criterion NOT validated:** the panel never blanked during the cycle, so "stays blank
  while frozen" is untested. That is the pre-existing `gamescopectl unreachable` gap (the `bl_power`
  item above), not a regression from this change, and it was visible only because the cycle was
  triggered with `systemctl suspend` directly — the Steam power-press path does its own blank first.
  Unaffected by construction anyway: gamescope remains INSIDE the frozen set, so whatever it was doing
  with the blank modeset it still does. Original analysis retained below. — `novadeck-suspend` froze all of `/sys/fs/cgroup/user.slice`, which includes
  `session.slice` and therefore `dbus-broker` + `systemd --user`. That is the whole reason
  `systemctl --user` / `gamescopectl` hang inside the frozen window (see
  [[suspend-systemctl-while-frozen-blocks]]); the file header used to claim this hazard didn't exist,
  which was wrong and is now corrected in place. The reference handheld distro moved its equivalent
  script off `user.slice` onto the app-level subtree for exactly this reason, keeping the game frozen
  while the session plumbing stays answerable.
  - **MEASURED ON HW 2026-07-26 (Pocket S2, live session WITH a game running — AppId 40800 under
    FEX). A qualifying set exists.** Read straight out of `/proc/<pid>/cgroup`:
    - `/user.slice/user-1000.slice/`**`session-1.scope`** (24 entries) holds EVERYTHING we want frozen:
      `gamescope-wl` (842), both Xwaylands (`:0`/`:1`), `novadeck-session`, `novadeck-steam`,
      `gamescopereaper` + `mangoapp`, the Steam client (904) + `steamwebhelper`, **and the game**
      (`reaper` 2690, `pv-adverb`/FEX 2764).
    - The session plumbing is OUTSIDE that scope, as siblings under `user@1000.service`:
      `session.slice/dbus-broker.service` (854, the user bus), `init.scope` (`systemd --user`, 803),
      and `app.slice` (`novadeck-steamos-manager`, 820).
    - Root's SSH sessions are outside `user-1000.slice` entirely (`user-0.slice/session-*.scope`).
  - **Their `app.slice` fix is CONFIRMED DEAD for us** — the doubt in this item was right. Our
    `user@1000.service/app.slice` contains only `novadeck-steamos-manager` and at-spi; no gamescope,
    no Steam, no game. Freezing it would freeze nothing that matters.
  - **New default to adopt:** `/sys/fs/cgroup/user.slice/user-1000.slice/session-*.scope`. Use the
    GLOB, do not hardcode `session-1` — the scope number is assigned per login and is not stable
    across a session restart. No plumbing change: `freeze()` iterates `for cg in
    $NOVADECK_SUSPEND_FREEZE_CGROUPS` **unquoted**, so the value undergoes pathname expansion at use,
    and the glob stays scoped to uid 1000.
  - **What this fixes and what it does NOT.** It thaws `dbus-broker` + `systemd --user`, so
    `systemctl --user` answers inside the frozen window, and root SSH stays *responsive* rather than
    merely connected (see [[suspend-ssh-survives-established]]). **`gamescopectl` will still hang** —
    gamescope is in the frozen set BY DESIGN (it holds the blank KMS modeset statically). So the
    blank-BEFORE-freeze ordering in `do_suspend()` stays load-bearing, and this does not remove the
    need for the `bl_power` fallback above. Update [[suspend-systemctl-while-frozen-blocks]] when it
    lands: the hazard narrows from "any user-session IPC" to "gamescope only".
  - ~~Still to validate before flipping the default~~ — **DONE, see the HW result in the header.**
    (a) game halts: YES, `usage_usec` frozen solid; (b) panel stays blank: NOT TESTED, it never
    blanked (pre-existing gap, see caveat); (c) resume clean: YES.

- [x] **Provide `com.steampowered.SteamOSManager1` (steamos-manager) — DONE 2026-07-14** (see the LANDED
  power-profiles stack entry at the top of Open). SteamUI's privileged backend
  — SteamUI calls this D-Bus name for system actions it can't do as the unprivileged `deck` user;
  when it's absent those controls silently no-op (the shape of our "SteamUI setting is inert" class).
  Adopt the **reference-handheld pattern, NOT the upstream binary**: the upstream Rust project
  (cloned at `_reference/steamos-manager/`, the authoritative interface spec — see its `data/*.xml`)
  is jupiter/x86-oriented (Ryzen TDP, Deck fans, jupiter sysfs) so its method BODIES don't map to
  SM8650/Adreno. Our peer ships a ~389-line Python reimplementation of just the interfaces SteamUI
  needs, backed by its own hw daemons: `SessionManagement1` (SwitchToDesktop/GameMode + desktop/login
  sessions), `PerformanceProfile1` + `GpuPerformanceLevel1` (perf tab), `Manager2` (ReloadConfig),
  `ObjectManager`; power is delegated to a separate power daemon. Wins: **Desktop/Game-mode switching**
  (a Deck-UX feature we lack) and the **Performance/GPU-level sliders** (currently inert, no backend);
  it's the standard home for future "SteamUI toggle → OS action" wiring, replacing hand-rolled per-key
  daemons (`novadeck-hotkeyd` etc.). ORTHOGONAL to the power/suspend work: the reference's manager does
  NOT expose Suspend/Reboot/Shutdown — suspend still flows through the logind intercept we built. Scope:
  a real D-Bus daemon (its own effort), a natural next layer AFTER power/suspend lands. See
  [[inspect-upstream-by-cloning-not-scraping]], [[validate-architecture-vs-steamos-goal]].

- [x] **Brightness up/down hotkeys — no HW keys; Guide+VOL chord is UNFEASIBLE** — the Pocket S2 has no
  physical brightness keys (raw capture shows only `KEY_VOLUMEUP` on gpio-keys, `KEY_VOLUMEDOWN` on
  pmic_resin; `novadeck-hotkeyd`'s KEY_BRIGHTNESS* handlers therefore never fire). The proposed
  **Guide+VOL → brightness chord is a dead end**, investigated fully 2026-07-14 (reverted, nothing shipped):
  * **UX killer (fatal, approach-independent):** Guide is the Steam button — Steam opens its overlay on
    the Guide *press*. Any Guide+X combo brings up SteamUI. The OS can detect the combo but cannot stop
    the press from reaching Steam. This alone rules out Guide+VOL regardless of implementation.
  * **InputPlumber chord also breaks Guide:** on AYANEO, Guide arrives as a real gamepad button
    (`BTN_MODE`); putting it in an IP `chord` makes IP hold/consume it, killing the plain Guide button
    (HW-confirmed: QuickAccess kept working, Guide died). IP chords are meant for throwaway trigger keys
    (e.g. OneXPlayer's Meta+G "home"), not live gamepad buttons.
  * **hotkeyd variant works mechanically but shares the UX killer:** a small `evtest` watcher on the IP
    virtual gamepad (libinput hides gamepads) can track `BTN_MODE` and gate VOL→brightness, no IP change
    — but still triggers SteamUI on the Guide press. Built and reverted.
  * Notes for any future attempt: IP `keyboard:` targets are PascalCase (`KeyVolumeUp`), NOT `KEY_*`;
    grabbing VOL in IP requires re-emitting plain VOL or volume dies. If brightness is still wanted, use a
    **non-Guide** button that doesn't trigger SteamUI (e.g. QuickAccess/`BTN5`+VOL, if usable) or a Steam
    UI brightness slider — a fresh design, not this chord. See [[sm8650-inputplumber-input]].

- [x] **Display color controls — RESOLVED** — confirmed working (user, 2026-07-05): the `--steam`
  handshake + R/T sockets (cabb498) gave SteamUI's color pipeline a channel, and the
  `GAMESCOPE_COLOR_NIGHT_MODE` atom sanitize (ddbe201) fixed the RED cast → amber night mode. Original
  investigation retained below for provenance. gamescope owns the
  color pipeline, so suspect our from-source gamescope build is missing what Armada ships. Compare
  **Armada's `gamescope.spec`** (build flags + deps) against our `packages/gamescope` PKGBUILD —
  specifically whether it pulls in **vkroots** (the Vulkan layer-interposition framework gamescope's
  color-mgmt / shader path relies on) and **reshade** (shader effects); we likely need those as build
  deps / the matching meson options enabled. Clone Armada into `_reference/` to diff (don't scrape).
  Watch: preserve our rotation-shader / WSI patches when touching the build.
  **ChimeraOS reference (see [[chimeraos-gamescope-session-reference]]) — likely mis-diagnosed:** the
  build-flag theory may be secondary. SteamUI drives gamescope's color/reshade pipeline over a RUNTIME
  IPC that only exists when gamescope is launched in **`--steam` mode with `-R <startup.socket>
  -T <stats.pipe>`** (+ `GAMESCOPE_STATS` exported). `novadeck-session` runs a BARE gamescope (no
  `--steam`, no sockets), so the color sliders have nothing to talk to regardless of vkroots/reshade.
  TEST `--steam` + the R/T sockets FIRST — it's a launch-flag change, no rebuild, and may light up
  color AND brightness at once — before doing the gamescope.spec build work.
  **HW 2026-07-04 (branch `feat/gamescope-steam-handshake`) — channel CONFIRMED:** with `--steam` +
  `-R/-T` sockets wired, the color controls now REACH gamescope (previously fully inert), so the
  IPC-channel theory is CLOSED. Baseline is a strong RED filter when night mode is ON; the night-mode
  **tint** and **primary-hue** sliders have NO effect; only **peak-saturation** modulates the cast.

  **⚠️ ROOT CAUSE CORRECTED — source analysis 2026-07-04 (everything above from "gamescope owns the
  color pipeline" down to the vkroots/gamescope.spec rebuild plan is SUPERSEDED / WRONG):** the
  gamescope build, patch, and plumbing are all EXONERATED. Walked gamescope 3.16.23.2 source:
  1. **No color meson option exists** — color-mgmt is always compiled in; **vkroots is the WSI layer,
     not color.** The "missing vkroots / color meson opts" theory is dead — do NOT do the rebuild.
  2. Our `0001-rotate-portrait-panel-in-composite.patch` is **byte-for-byte ROCKNIX/Armada's `0005`
     rotation patch** (only a 2-line aggregate-init diff, from being adapted to 3.16.23.2's fuller
     `PipelineInfo_t`). It only redirects the composite shader's OUTPUT store coord; it does **not**
     touch or reorder the color-mgmt LUT sampling or `encodeOutputColor`. Rotation shader fully CLEARED.
  3. 3.16.23.2 ≈ Armada's 3.16.24; both run **no-EDID DSI panels** where gamescope defaults to the
     safe `displaycolorimetry_709`. Not a version / EDID / colorimetry issue.
  4. **Actual mechanism:** night mode is literally `HSV_to_RGB(nightmode.hue, saturation*amount, 1.0)`
     used as a multiply (`color_helpers.cpp` ~L731). **hue≈0 ⇒ pure RED**; correct night mode is amber
     (**hue≈0.083**). amount/hue/saturation arrive **together in ONE atom** `GAMESCOPE_COLOR_NIGHT_MODE`
     (CARDINAL[3], each `bit_cast<float>`; `steamcompmgr.cpp` ~L6334), so saturation responding PROVES
     hue (vec[1]) is received. gamescope faithfully renders what it's told ⇒ **the red is the value the
     STEAM CLIENT sends for hue (≈0), not our build.**

  So the fix is NOT in `packages/gamescope`. **CAVEAT:** "Armada's night mode works" was an assumption,
  never tested — the conclusion rests on gamescope source + the atom math, not on Armada.
  **NEXT (no rebuild) — bisect gamescope vs SteamUI on-device:** inject
  `GAMESCOPE_COLOR_NIGHT_MODE`=[amount=1.0, hue=0.083, sat=1.0] on the session X root via `xprop`
  (CARDINAL[3] of the float bit patterns) and watch the panel — **amber ⇒ gamescope is perfect, bug is
  100% SteamUI-side** (client-integration / likely a documented non-blocker); **still red ⇒ reopen the
  gamescope-render angle with a specific target.** Sweep hue 0.0→0.17 to confirm gamescope honors it.
  **HW-CONFIRMED 2026-07-04 (device .216): gamescope FULLY EXONERATED.** Injected [1.0,0.083,1.0] →
  panel went correct AMBER. The vector SteamUI itself left on the root read back as
  `[amount=0.0, hue=0.85 (magenta, NOT amber), saturation=1.02e15 (WILDLY out of [0,1])]` — **SteamUI
  computes a garbage night-mode vector** (gamescope only survived it because amount=0 zeroed the
  product). Repro: `xprop` must run as the **deck** user (root is refused, wrong uid); `gamescopectl`
  has no night-mode convar (X-atom only). With night mode toggled ON the vector =
  `[amount=0.382, hue=0.85, sat=1.02e15]` → **only `amount` is live (intensity slider); `hue` and `sat`
  are FROZEN garbage regardless of any slider** (hence the inert tint/hue sliders).

  **Colorimetry route = DEAD END (checked 2026-07-04):** DSI-1 exposes NO EDID (kernel panel driver
  provides none) and gamescope has NO EDID/colorimetry override input (env or file) — it only reads the
  connector EDID, else defaults to `displaycolorimetry_709`. "Advertise real colorimetry" would need a
  kernel panel-driver EDID with the panel's measured chromaticity (heavy; coords unknown). AND it's
  UNCERTAIN to help: SteamUI's `hue=0.85` is CONSTANT across off/on, so it may be a fixed SteamUI
  default, not a colorimetry-derived value → better primaries might not move it.

  **CLOSED HARDER 2026-08-03 — it is the arm64 Steam CLIENT, not our panel, and the difference
  matters.** An unrelated arm64 distribution on different hardware and a different (EDID-carrying)
  panel hit the IDENTICAL broken vector and shipped their own gamescope workaround for it. Since the
  fault reproduces where the EDID premise does not hold, no panel-side work — EDID, chromaticity,
  colorimetry override — can move what the client writes into `GAMESCOPE_COLOR_NIGHT_MODE`. Do not
  re-open this route on the theory that a proper EDID would fix night mode; it would not.
  **Their fix is NOT worth adopting, and the reason is a useful trap to record.** It gates on
  `#if defined(__aarch64__)` and re-reads the vector as `[amount, saturation]`, on the theory that
  the arm64 client sends a 2-element property. That mechanism is impossible: `steamcompmgr.cpp`
  fills a zero-initialised local `float vec[3]` only `if ( bHasVec && user_vec.size() == 3 )`
  (verified at our pinned 3.16.23.2 AND on gamescope master), so a 2-element property would make
  night mode fully INERT, not garbage — and we measured a live `amount` driving a visible tint, so
  the client really does send 3 elements and `1.02e15` is really what it wrote. Their patch does
  land on amber, but by forcing hue at compile time on every arm64 build (so a fixed client stays
  overridden), treating a frozen constant as if it were the user's saturation, and dropping the
  non-finite guard. Ours is runtime, arch-neutral, self-healing, and HW-confirmed. The one thing
  taken from it: the amber hue constant, now `25/360` rather than `0.083`.

  **RECOMMENDED FIX (reliable, fully in our control): a gamescope-side sanitize patch** on the night-mode
  atom handler (`steamcompmgr.cpp` ~L6347) / `set_color_nightmode`: (1) clamp `nightmode.saturation` to
  [0,1] (kills the 1e15); (2) remap/force `nightmode.hue` into a warm amber band (~0.05–0.12) when it's
  outside a sane night-mode range (fixes the fixed-magenta 0.85). Salvages night mode into correct amber
  regardless of SteamUI's garbage; no kernel work. Ship as `packages/gamescope/patches/0002-*`. This
  gates the branch merge (night mode currently flips inert→red for users). See
  [[steam-gamescope-handshake-hw-result]], [[chimeraos-gamescope-session-reference]],
  [[sm8650-gamescope-flip-blocker]], [[overlay-package-pipeline]].

  **✅ RESOLVED — HW-CONFIRMED 2026-07-05 (device .226, gamescope binary sha `c10f774a…`).** Night mode
  now toggles to a reliable **amber** (no red/magenta at any slider position); the "night mode tint"
  intensity slider correctly scales it light-brown→dark-orange. The "Primary Hue" and "Peak Saturation"
  sliders are intentionally inert now — both drive the atom's `hue` (measured sweep 0.5→1.0, never warm)
  and the `saturation` field is frozen garbage (~6.5e22), so the patch overrides them with a fixed amber.
  That's the fix working: substituting sane values instead of rendering the client's garbage. **The merge
  hold on this item is LIFTED** (night mode no longer degrades to red; it degrades to correct amber).
  Real hue/saturation tuning stays unavailable (needs real panel colorimetry we don't have) — acceptable.
  The FIRST HW build (2026-07-04) still flipped red past a pivot: the initial patch had a `[0.90,1.0]`
  hue wrap-around pass-through, and the client's hue near 1.0 = red sailed through it. Removed the
  wrap band; only a tight warm band `[0.02,0.20]` (which the client never hits) now passes.

  **IMPLEMENTED 2026-07-04 → corrected 2026-07-05:** `packages/gamescope/patches/0002-sanitize-nightmode-atom.patch`
  sanitizes the atom right where it's decoded (`steamcompmgr.cpp` ~L6349, in the
  `gamescopeColorNightMode` handler): clamp `amount`/`saturation` into [0,1] (kills the 1e15 and
  non-finite), and rewrite `hue` to amber `0.083` ONLY when it's outside the warm band a night-mode
  tint can occupy — `[0.0, 0.17]` ∪ `[0.90, 1.0]` (the second range = deep red wrapping toward hue
  1.0). This is a band-pass, NOT a hard override: a **functional SteamUI hue slider** (which spans
  the warm red↔amber↔yellow range) passes through untouched; only impossible values like the frozen
  magenta `0.85` get corrected. NB: on current HW that slider is inert (hue frozen), so in practice
  it always amber-izes until the SteamUI-side freeze is fixed. Round-trip-verified
  and applies clean to pristine 3.16.23.2. Wired into `source.pin` after the rotation patch
  (`makepkg -sf` force-rebuilds, so a fresh `make sdcard` picks it up — no pkgrel bump needed).
  **NEXT: build image → HW-verify night mode toggles to correct amber (not red/magenta), and that
  the intensity slider still modulates it (amount stays live).**

- [x] **Volume up/down keys don't change volume** — RESOLVED (works, user-confirmed) — **duplicate of
  the closed "Volume buttons don't change volume (OSD shows, no change)" item above.** Fixed by the
  `novadeck-hotkeyd` daemon (`libinput debug-events` → `wpctl` in the deck PipeWire session; Steam's OSD
  follows the sink), HW-validated 2026-07-05. The old "missing gamescope/`STEAM_*` keybind" hypothesis
  was a DEAD END: there is no OS-level volume-key handler in SteamOS/Armada (client-only; the arm64
  client no-ops it), so there was nothing to wire through gamescope — an external daemon is the fix.
  See [[brightness-volume-keys-resolved]], [[sm8650-inputplumber-input]].

- [x] **Adopt SteamUI-expected session defaults — DONE** — user-confirmed 2026-07-05; the defaults
  below were ported alongside the `--steam` handshake + SteamUI env gates (cabb498, 0970590).
  Historical scope: `novadeck-session` ran a comparatively
  bare gamescope; ChimeraOS's SteamOS session sets several defaults SteamUI/gamescope expect that we
  don't (all env/flag, no rebuild — see [[chimeraos-gamescope-session-reference]]). Port and
  HW-validate: **`--xwayland-count 2`** (the nested overlay Xwayland the Steam UI + game/overlay model
  expects — likely load-bearing, not cosmetic), **`GAMESCOPE_MODE_SAVE_FILE`** (persist the user's
  resolution/refresh choice across boots), the **`short_session` crash-loop guard** (fall back / reset
  after N sub-60s client deaths — robustness novadeck lacks; today we lean on the exit-42 loop +
  systemd), **`ulimit -n 524288`**, and the client env defaults **`SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0`**
  + **`vk_xwayland_wait_ready=false`**. (`ENABLE_GAMESCOPE_WSI=1` we already set.) Fold the display/power
  ones in alongside the `--steam`+sockets + `STEAM_*` experiment above; introduce each deliberately and
  watch for interaction with our rotation-shader / WSI re-launch caveat. See
  [[sm8650-gamescope-session-plumbing]], [[sm8650-gamescope-flip-blocker]].

- [x] **OOBE timezone not set — polkit denies `timedate1.set-timezone`** — RESOLVED, HW-confirmed
  2026-07-02. The real fix was giving the shell a real ACTIVE seat0 logind session: boot via **SDDM
  autologin** and let gamescope use libseat's **logind** backend (NOT forced `LIBSEAT_BACKEND=seatd`,
  which keeps the session inactive). Then the stock `subject.active && isInGroup("wheel")` rule
  (`50-novadeck-timezone.rules`, deck∈wheel) grants it, and NM's OOBE Wi-Fi rides `allow_active` with
  no rule at all — so the old broad `50-novadeck-steamos.rules` "no-active" bypass was deleted. Journal
  proof: the OOBE tz picker set every zone (…→`Europe/Paris`) with ZERO "Permission denied". Also fixed
  in the same pass: `/etc` was deck-owned (overlay `cp -a` preserved the build uid) → assemble-rootfs
  now normalizes overlay ownership to root. See [[sm8650-gamescope-session-plumbing]],
  [[wifi-connect-fails-after-list]].

- [x] **OOBE update-check error after Wi-Fi/timezone** — RESOLVED, HW-confirmed 2026-07-03. Past the
  Wi-Fi/timezone screens SteamUI shells to update-check helpers (confirmed in `steamui.so`):
  `steamos-update` + `jupiter-biosupdate` via the polkit-helpers wrapper, and `steamos-mandatory-update`
  + `jupiter-initial-firmware-update` on PATH. We bake no jupiter-hw-support and have no Phase-1 OS
  updater, so those were missing and OOBE errored. Fix: no-op stubs under `steam/usr/bin/` that report
  "up to date" (exit 7 on `check`, else 0), matching Valve's/Armada's contract. First boot now clears
  the update screen (the one post-Wi-Fi reboot is normal SteamOS first-run). Commit `8aa5283`.

- [x] **Preseed `/home/deck` in the image instead of first-boot copy** — RESOLVED, HW-confirmed
  2026-07-03 (commit `930058f`). `make-sdcard.sh` now populates the `/home` ext4 directly at build
  (`mkfs.ext4 -d`, owned `deck:deck`, `.steam` symlinks + seed baked in), sized to the seed and grown
  to fill the card on first boot by `novadeck-grow-home` — a healthy boot does ZERO copy (killed the
  old ~1GB rootfs→home copy and its grow-race ENOSPC trap). See
  [[steam-must-be-baked-offline]], [[steam-offline-sdl3-seed]], [[grow-home-repart-no-initramfs]].
  - **UPDATE 2026-07-11:** the separate recovery-seed mechanism was DROPPED. The pre-seeded `/home`
    is now the only client copy — no squashfs seed partition (p8 removed, layout back to 8 SteamOS
    partitions), no `/usr/share/novadeck/steam-seed` in the RO root, and `steam-bootstrap.sh` +
    `novadeck-steam-bootstrap.service` deleted. There is no in-place re-seed: a factory reset is a
    reflash of the card, and a UFS install is recovered by booting a separate SD-card image.

- [x] **Audio on release** — RESOLVED, HW-confirmed 2026-07-03. The "works on test, not release"
  framing was a red herring: the real precondition is **session-alive + client-updated**. Earlier
  release "no sound" stacked two causes — the grow-home ENOSPC crash (no session at all) and, later,
  the pinned-client launch flags that blocked the Steam self-update. On the fixed release image sound
  works once the client self-update lands (new logo); before the update a healthy session still has no
  sound, because the offline-baked seed ships a stale/partial client audio path that the update
  replaces. Audio packages/UCM were never the gap. See [[audio-l4-deferred-to-user-session]],
  [[steam-launch-flags-no-pinned-client]]. Follow-up (minor, optional): make the SEED client produce
  sound pre-update so first-boot-before-update isn't silent — likely needs the bundled `steamrtarm64/`
  audio libs refreshed in the seed.

- [x] **`--ready-fd` ready-then-launch handshake — MOOT** — dropped (user, 2026-07-05). It only
  mattered if a WSI-on session restart wedged in the field; the release shell launches once and WSI
  stays `=1` (see [[sm8650-gamescope-flip-blocker]]), so the wedge is not a field problem. Prototype
  abandoned.

- [x] **Stable Wi-Fi MAC address (first-boot) — DONE, HW-verified 2026-07-07** — the WCN7850 comes up
  without a persistent MAC (no vendor NVRAM/`nvmem` MAC path on this SM8650 port), so the Wi-Fi address
  was non-deterministic across boots (random/locally-administered, and identical across units flashed
  from the same image). Shipped in the `hw-support/` overlay: `usr/lib/novadeck/gen-mac.sh` derives a
  locally-administered **unicast** address by `sha256(seed)` — seed = the per-unit `/etc/machine-id`
  (empty in the image → systemd writes a fresh random one on first boot; falls back to the SoC serial,
  then a persisted urandom value). **Write-once** persisted to `/var/lib/novadeck/mac-wifi` (RW even
  under the Phase-4 immutable root), then applied every boot by `novadeck-macgen.service` (oneshot,
  Before `NetworkManager.service`): it writes a cloned-mac drop-in into `/run/NetworkManager/conf.d/`
  (tmpfs, so no RO-root write) with `wifi.scan-rand-mac-address=no` +
  `wifi/ethernet.cloned-mac-address=<MAC>`. HW-verified across reboots: `wlp1s0` takes the derived MAC
  and holds a stable DHCP lease. Note: interface is `wlp1s0` (predictable naming), so a global
  `[connection]` default is used rather than a per-iface key. Relates to [[wifi-config-is-test-only]].
  **Bluetooth deliberately NOT done:** a stable BT address via `btmgmt public-addr` is not achievable
  on this controller — before `bluetoothd` initialises it the mgmt interface is unreachable (every
  `btmgmt` call blocks/times out, even `info`), and after `bluetoothd` the controller is powered up so
  `public-addr` (settable only while powered off) is refused. The two windows never overlap (HW
  2026-07-07). Left as a known limitation; revisit only if BT identity ever matters (BT re-pairs
  anyway).

- [x] **MangoHud performance overlay via `--mangoapp`** — DONE + HW-validated 2026-07-08.
  Confirmed `mangohud`/`mangoapp` are NOT in the holo aarch64 repos (no `mango*` in the pinned base's
  synced core/extra dbs; gamescope/mesa/openal do resolve), so shipped as a from-source overlay like
  gtk2/sddm: `packages/mangohud/` (local `PKGBUILD` @ MangoHud 0.8.4, `-Dmangoapp=true
  -Dmangohudctl=true` + system spdlog, NVIDIA XNVCtrl off) plus the ROCKNIX Qualcomm/SM85xx patch set
  as carried by armada (`packages/mangohud/patches/0001..0006`, applied by `build-overlay.sh`) that
  teaches GPU_fdinfo/BatteryStats/HUD to read an Adreno SoC (kgsl/devfreq GPU clock+temp, `battery`
  power-supply, RAM label) — all 6 taken, incl. the SM8550/SM8750 device patches (closest match for
  our SM8650 Adreno 750). Added `mangohud` to `customize-base.sh` PKGS (installs ahead of holo from
  the [novadeck] overlay) and pass `--mangoapp` to gamescope in `fs-overlay/usr/bin/novadeck-session`
  (in the `--steam`/`-T` stats block; `--mangoapp` verified present in our gamescope 3.16.23.2).
  **HW-validated 2026-07-08:** (1) the overlay pkg builds cleanly under qemu (all 6 patches apply @
  0.8.4); (2) the overlay renders in-session and the SteamUI Quick-Access **Performance** toggle +
  Level drive it live over the control channel — **both** paths confirmed on device: the SysV
  `no_display` control queue (show/hide) *and* the config-file + reload (level). **No source patch
  needed** — the earlier "reload ignores `MANGOHUD_CONFIGFILE`, must patch it" theory is DISPROVEN by
  the 0.8.4 source + live tests; our pkg == armada's exactly. Key gotcha: the perf overlay is **gated
  on a focused GAME** (mangoapp self-suppresses while the Steam UI / appid 769 is focused), so
  toggling it in the library is a no-op *by design* — exercise it in-game. `gamescope --steam
  --mangoapp` sets `MANGOHUD_CONFIGFILE` + the `STEAM_*` gates itself (don't add them to the session).
  (3) the earlier launch-crash is GONE now that `mangohud` exists on-image. See
  [[mangohud-quickaccess-control-gap]], [[sm8650-gamescope-session-plumbing]], [[holo-pacman-no-gtk2]],
  [[overlay-package-pipeline]].
  **Severity (HW 2026-07-07):** this wasn't cosmetic — with no `mangohud` on the image, enabling the
  Quick Access performance overlay *crashed game launches*. Steam prepends `mangohud` to the launch
  command (`reaper … -- mangohud <compat-tool> …`); the process was added and removed in the same
  second (instant exec failure, before the compat tool runs). Confirmed on Gravity Circuit via
  `proton11sc`: identical launch ran fine without the overlay, died the moment the overlay was toggled
  on. Shipping `mangoapp` closes that too.

- [x] **Trim the Kconfig: stop building drivers for hardware novadeck will never have — DONE
  2026-08-03 (config-validated; HW boot test still owed).** Landed as `kernel/trim-platforms.config`,
  a third declared list alongside `kernel.config` and `trim.list`, plus a self-verification block in
  `kernel/build.sh`. **Measured on 7.1.6, pre → post:** enabled symbols 4961 → 3370 (**−1591, −32%**);
  `=y` 3721 → 2625; `=m` 1240 → 745. Artifacts: `Image` 70.1 → 56.4 MiB (**−13.6, −19.4%**),
  `out/modroot` 89.4 → 58.6 MiB (**−30.8, −34.5%**), 1397 → 888 `.ko` (**−509**). **~44.5 MiB off the
  read-only rootfs**, which is also 44.5 MiB off every OTA bundle (see the disk budget in `docs/ota.md`).
  All 15 board DTBs still build.
  **The method that made it small: cut the PLATFORM GATES, not the drivers.** All 48 top-level gates in
  `arch/arm64/Kconfig.platforms` were enabled by the multi-platform defconfig; 47 are now negated (all
  but `ARCH_QCOM`). Vendor drivers hang off them (`ARCH_MXC` alone is referenced in 148 Kconfig lines),
  so kconfig's dependency closure prunes ~1591 symbols from 49 directives — and the file **maintains
  itself**, because a vendor driver added upstream in a future kernel is born disabled. Child options
  (`ARCH_TEGRA_*_SOC`, `ARCH_R8A*`, and the umbrella `ARCH_BCM`/`ARCH_NXP`/`ARCH_MICROCHIP`) cascade off
  on their own and are deliberately NOT listed. **Do not convert this to a per-driver list** — that is
  the version that rots. Safety: removals are safe by construction, since kconfig will not drop a symbol
  that anything we keep `select`s. Verified **every** symbol matching `QCOM|MSM|ADRENO|SNAPDRAGON|QRTR|SLIMBUS`
  is **bit-identical** pre/post, and `SCHED_CLASS_EXT`/`DEBUG_INFO_BTF` are still `=y` in the real
  container build (a host-side probe cannot check those two — no `pahole`).
  **Two claims in the original entry were wrong, corrected here:** (1) family (1) was already almost
  entirely false — `DRM_AMDGPU`, `DRM_RADEON`, `AST`, `MGAG200`, `QXL` and `VMWGFX` were *never* enabled;
  the only discrete GPU on was `DRM_NOUVEAU=m`, a 2-line cut, not a family. (2) The objection to option
  (a) ("forever subtracting from a multi-platform base") assumed a hand-maintained per-driver list; at
  gate level it is 49 self-maintaining lines, so option (b) — the downstream CodeLinaro `BASE_CONFIG`
  path, with its downstream-only symbols and papering `olddefconfig` — was not needed at all.
  **TRAP PAID FOR (one wasted kernel build):** `merge_config.sh` matches negatives with
  `notset_regex = "^# CONFIG_[a-zA-Z0-9_]+ is not set$"`. That `$` is hard-anchored, so an inline
  trailing comment (`# CONFIG_ARCH_TEGRA is not set   # NVIDIA Tegra`) silently demotes the directive to
  a plain comment — **no warning, build succeeds, drivers ship anyway**. Subtractive config fails
  silently in a way additive config does not: the result is just the old, larger kernel. Hence the guard
  in `build.sh` — it re-derives the directives with merge_config's own regex, asserts each resolved to
  unset, enforces a floor on the directive count (an empty parse would otherwise "pass"), and greps
  explicitly for the trailing-text form. Prints `trim-platforms: N symbols confirmed disabled`.
  The same block now also asserts `DRM_MSM`, `PCIE_QCOM`, `PCI_PWRCTRL_GENERIC`, `MMC_SDHCI_MSM`,
  `SCSI_UFSHCD`, `ARM_SMMU`, `ARM64_4K_PAGES`, `SCHED_CLASS_EXT`, `DEBUG_INFO_BTF`, `SQUASHFS`,
  `OVERLAY_FS` — several were declared invariants that nothing checked ([[declared-invariants-need-assertions]]).
  **Still owed: the HW boot test** on Pocket S2 + Pocket ACE (display, Vulkan, audio, Wi-Fi, controller,
  suspend/wake; diff `dmesg` probe failures against a pre-trim capture). Cut in ONE pass rather than the
  per-vendor sequence the original entry proposed — justified by the empty Qualcomm-surface diff, and
  agreed 2026-08-03. See [[kernel-build-from-rocknix-config]], [[sm8650-working-display-baseline]],
  [[drop-dead-config-symbols]], [[initramfs-phase4-immutable]].

- [x] **`card/v0.2.0` is a MANDATORY REFLASH — every device on a pre-phase-5 card must be
  re-imaged by hand, and the release notes have to say so — SAID, 2026-08-04.** The published
  `card/v0.2.0` notes now lead with the warning: re-image by hand, do not wait for an OTA, and the
  attempt is destructive to the inactive slot. Devices already on `v0.2.0` are called out as
  unaffected. The reasoning below is unchanged and is why no later bundle can soften this.
  Determined 2026-08-03 by reading both
  ends, not by running it; the two halves name the same missing file. The phase-5 build ships **no**
  `/usr/lib/novadeck/boot.img` (`images/assemble-rootfs.sh:202` — the boot *directory* replaces it),
  and a `card/v0.1.0` device's own `post-install.sh:194` hard-fails without exactly that file.
  **The reason no future bundle can fix this is the durable part: RAUC runs the BOOTED slot's
  post-install handler, not the bundle's.** A v0.1.0 device runs v0.1.0's Phase-4b handler, which
  rotates `/KERNEL` and knows nothing of stage-2 GRUB, per-slot efi partitions or partsets. Nothing
  shipped later reaches it. This is not a signing or a mode problem — the signature verifies and the
  mode gate is publisher-side only ([[ota-steamui-pickup]]).
  **The failure is safe but is not a dry run.** The handler disarms the target (`:109`),
  re-randomises its fsid (`:115`) and reformats its `/var` (`:131`) *before* the kernel step, so
  slot B is left overwritten and unbootable while slot A keeps running; it never re-arms
  (`:246-247`). A user who tries the OTA loses nothing they were using, but B is not recoverable
  without a reflash either.
  **Consequence for validation:** test (b) no longer subsumes test (a), which was the plan of
  record. (a) — OTA between two phase-5 builds — has to be run on its own and is the only thing
  that validates the path that actually ships. `docs/ota.md` is updated.

- [x] **kernel 7.1.6 + mesa 26.1.6 — HW-VALIDATED on Pocket S2 2026-08-03.** Validated on a dev card
  carrying the trimmed 7.1.6 kernel (see the Kconfig-trim entry — the trim and the bump were proven
  in the same pass): display, audio, **Vulkan 1.4.354 / Turnip Adreno 750** (which exercises mesa
  26.1.6), Wi-Fi associated on 5 GHz, USB3 enumeration through the PCIe hub, InputPlumber,
  suspend/wake, zram active — zero failed units, no missing modules, `depmod` clean. That clears the
  display/Vulkan/gamescope regression risk this entry was written to catch, which was the whole
  question: 7.1.6 carries ZERO drm/msm changes, so a regression there would have been *mesa*.
  Two verification items from the original text are NOT covered by this and are split into their own
  entry below (night mode, ath12k throughput) — they are release-gate checks, not "is the bump good".
  Original context: `a964be1`. A dev card (`NOVADECK_MODE=dev`, `NOVADECK_GIT=a964be1`) carries kernel
  `7.1.6` (`out/modroot/lib/modules/7.1.6`), `mesa 1:26.1.6-1.1` + `vulkan-freedreno` +
  `vulkan-mesa-device-select`, and the re-patched gamescope. **7.1.6 carries ZERO drm/msm changes**,
  which is the useful part: a display/Vulkan/gamescope regression is *mesa*, and Wi-Fi or input is
  the *kernel*. Also picks up an ath12k WCN7850 MLO RX throughput fix worth measuring against a
  5 GHz AP ([[ath12k-self-managed-regdom-5ghz-works]]). Night mode should read as warm amber
  tracking the intensity slider at every setting — no magenta/red.

- [x] **Pre-tag HW gates for `card/v0.2.0` — CLEARED 2026-08-04. Nothing gates the tag.** Two of the
  three were run on hardware and passed; the third (ath12k throughput) was **dropped as a gate by
  decision, not by measurement** — see it. Split out of the
  7.1.6/26.1.6 entry above 2026-08-03, because that entry's question ("did the bump regress
  display/Vulkan/Wi-Fi/input?") is answered, while these three are independent verification that
  would otherwise hide as sub-bullets inside a checked-looking entry.
  1. ~~**Night mode on hardware**~~ — **CLEARED ON HW 2026-08-04.** The sanitize patch (`ddbe201`,
     `3a90242`) has now been exercised on a device and night mode reads correctly; this was the
     highest-value of the three precisely because it was a shipped-behaviour bug whose fix had
     never been seen working, and that gap is closed. The atom's real layout is
     `[amount, saturation, UNUSED]` — see [[nightmode-atom-is-amount-saturation]], and
     [[fps-limiter-atom-clobber]] for the adjacent atom-clobber class.
  2. **ath12k WCN7850 MLO RX throughput** — **DROPPED AS A TAG GATE 2026-08-04 (decision). Still
     NEVER MEASURED — do not read this item as a pass.** Association against a 5 GHz AP is confirmed
     working, which is what users actually hit; the unmeasured part is throughput, and the MLO RX
     fix is the reason the kernel was bumped in the first place
     ([[ath12k-self-managed-regdom-5ghz-works]]). So the claim "the bump improved Wi-Fi throughput"
     remains unverified and should not be repeated as fact in release notes or anywhere else until
     someone puts a number on it. Deliberately not spawned as its own open item: the call was that
     it does not block a card tag, and re-filing what was just set aside would only re-litigate it.
     Cheap to settle opportunistically — one `iperf3` run against a 5 GHz AP.
  3. ~~**Pocket ACE boot on the trimmed kernel**~~ — **CLEARED ON HW 2026-08-04: it boots.** This
     was the second of the two boards we can actually HW-test (the trim had only ever run on Pocket
     S2), and it was cheap insurance rather than a suspected failure, since platform-gate removals
     are safe by construction. It matters more than "one more board booted" suggests: 13 of the 15
     boards in the tree cannot be tested at all, so the trim's blast radius is only ever sampled by
     these two. A second board booting is the whole of the evidence that the gate negation
     generalises — see [[kconfig-trim-cut-platform-gates]] and the trailing-comment trap in
     [[kconfig-negative-line-trailing-comment-trap]].

- [x] **The pin-bump PR must land before `card/v0.2.0` — DONE 2026-08-03, merged as PR #21**
  (`4f547da` chore(pins): record overlay artifact sha256s, merged in `9cb89f0`). Both
  `packages/mesa/artifact.pin` and `packages/gamescope/artifact.pin` now carry reviewed shas, so the
  stated blocker below is resolved and CI can build the release card.
  **Expected local behaviour, do NOT mistake it for a regression:** `packages/verify-pins.sh` exits
  **1** on a developer machine after a local overlay build. It is comparing the reviewed *store* pins
  against *your* freshly built bytes, and our builds are not bit-reproducible — the script says so
  itself and points at `NOVADECK_DEV=1 make sdcard`. It passes in CI, which pulls from the store.
  Check its exit code directly; do not pipe it through `tail`, or you capture the pager's status
  instead ([[piped-build-exit-code-hides-failure]]).
  Original entry follows — the release gate is BYTES, and the bytes
  for mesa `26.1.6` and the re-patched gamescope did not exist in `packages/*/artifact.pin` yet.
  `pin-artifacts` was deliberately NOT run into the commits: locally built overlay artifacts are not
  bit-reproducible, so pinning this machine's bytes would both record a sha nobody can regenerate
  and bypass the review that *is* the provenance claim. Push, let `overlay.yml` publish to the store
  and open its `pin-bump` PR, review that diff, merge — *then* the release card can be built by CI.
  A release build before that fails `verify-pins.sh`, correctly.
  **Ordering trap found doing this:** `make relock` must run BEFORE `make pin-artifacts` whenever a
  package's VERSION moves. `verify-pins.sh` only pins artifacts the *lock* says are installed, so
  against a stale lock it logs `mesa: no installed artifacts — no pin written`, **exits 0**, and
  leaves the previous version's pin in place.

- [x] **Journal cap — DEPLOYED 2026-08-03 18:22 UTC** — `ccd6098` adds the `SystemMaxUse=200M`
  drop-in to `ota/setup-server.sh` and `5e12af8` documents the disk budget it protects. Verified on
  the instance, not assumed: `/etc/systemd/journald.conf.d/10-novadeck-cap.conf` is byte-identical
  to the one the script writes, `systemd-journald` shows `ActiveEnterTimestamp` 18:22:06 UTC, and
  the journal sits at **191.9M** — i.e. the cap is not merely configured, the vacuum actually ran
  against the 242M that was already there. Disk 2.4G of 96G, so the ~12G retention budget
  (`KEEP=3` at ~4G) is intact.

- [x] **Adaptive (delta) bundles — IMPLEMENTED (f552b23), HW-CONFIRMED on the wire at 61.8x, and a
  delta-written slot has now BOOTED and confirmed itself good. DONE.** `[image.rootfs]` in
  `images/rauc/manifest.raucm.in` names `rootfs.img` and nothing else, so `rauc install` streams
  and writes the entire root image whatever changed in it — 3.90 GB per bundle for a one-package
  bump. rauc 1.15.2 already ships the fix: **adaptive updates** (`adaptive=block-hash-index`, its
  only supported method — `docs/advanced.rst` §"Adaptive Updates", now readable at
  `_reference/rauc/`). RAUC hashes every 4 KiB block, looks each one up in the two local slots, and
  fetches only what is genuinely new. Matching is content-addressed, not offset-based, and every
  local hit is re-hashed against the signature-covered bundle index — so a stale or tampered local
  index can only cost bandwidth, never correctness.

  **THE FULL PLAN, with the measurement written up, lives at
  `~/.claude/plans/fizzy-fluttering-hopper.md`** (outside the repo — read it before starting).

  **Phase 1 is DONE and the gate is passed.** Measured offline against the real bundles in
  `out/images/`, streaming each payload with `unsquashfs -cat <bundle> rootfs.img` (squashfs-tools
  4.7.5 inside `novadeck-build`, so nothing is extracted to disk) into a 4 KiB block hasher kept at
  `work/adaptive-measure/blockindex.py`:

  | pair | non-zero 4K reuse | squashfs blocks touched | on the wire |
  |---|---|---|---|
  | `0.2.1` -> `0.2.2` (consecutive releases) | **96.1%** | 1531 / 48424 | **~123 MB** of 3.90 GB |
  | `20260802` -> `0.2.2` (a day apart) | **96.1%** | 1560 / 48424 | **~125 MB** of 3.90 GB |

  Both payloads are 1 549 568 blocks, of which **33.3% are all-zero** (`mkfs.btrfs --shrink`
  sparseness). Those are counted and EXCLUDED — including them reports a flattering 97.4%, which
  is the number not to quote.

  Three things that settles: (1) `mkfs.btrfs --rootdir --compress zstd` produces a **stable**
  extent layout across builds — that was the top risk and it is retired; (2) changed blocks
  **cluster** (3466 runs, 46 KiB average), so the default 128 KiB squashfs block barely amplifies
  — `--mksquashfs-args="-b 64k"` measured 122.9 MB vs 123.2 MB and is **not worth doing**;
  (3) casync/casync-nano is **not** the answer here — see the plan file for the four reasons, and
  note the CDC comparison was deliberately not run because the only condition that would overturn
  the recommendation (fixed 4 KiB blocks matching poorly) did not occur.

  **What is left, in order.** (a) `data-directory=/home/.novadeck/rauc` in
  `fs-overlay/etc/rauc/system.conf` — WITHOUT IT `adaptive=` IS SILENTLY INERT (the shipped binary
  logs `Ignoring adaptive method since 'data-directory' is not configured` and falls back to a full
  copy). It cannot live in `/var`: `post-install.sh` step 2 `mkfs.ext4`s the target `/var` and
  rsyncs the running one over it, and rauc requires a filesystem "not overwritten during updates"
  — `/home` is the only one that qualifies. Needs the dir created in `assemble-rootfs.sh` §4h
  (sibling of `OFFLOAD_ROOT`, not an offload bind) plus a `rauc.service` drop-in with
  `RequiresMountsFor=`, because rauc is D-Bus activated and nothing orders it after `home.mount`.
  Note it also implies `statusfile=<dir>/central.raucs`, which replaces the per-slot status rauc
  cannot keep for `type=raw` slots — re-check `staged_identity()` in `novadeck-update`, that
  function has already shipped one HW-only bug. (b) one line `adaptive=block-hash-index` in the
  manifest. (c) `novadeck-update` must hand `InstallBundle` a **URL** instead of a downloaded path
  — adaptive only pays when the bundle is streamed. That deletes `download()`, `room_for()` and the
  `DOWNLOAD_*` stall guard; rauc has **no Cancel method**, so the stall guard cannot be reproduced
  (accepted: `nbd.c` retries a range request 5x then fails, and a re-run is cheap because the
  partially written target slot is exactly what the next index finds locally). (d) retire the three
  now-dead cases in `images/test-update.sh` (`insufficient-disk`, `download-stall-abort`,
  `bundle-not-left-behind`) and add two `guard-rootfs.sh` assertions — `nbd.ko` present, and the
  staged `usr/bin/rauc` still reporting `streaming=1`.

  **Preconditions from the original entry, now resolved rather than open.** Streaming: rauc is
  ALREADY built with `streaming=1` and `CONFIG_BLK_DEV_NBD=m` is already in the kernel with
  `nbd.ko` shipped — and it **autoloads**, because `nbd.c` declares `MODULE_ALIAS_GENL_FAMILY` and
  genetlink `request_module()`s an unknown family by name. nginx already serves Range requests
  (`gzip off` on `\.raucb$`, which today's `curl -C -` resume depends on). The fsid worry is a
  non-issue: `btrfstune -U` diverges metadata blocks, but content-addressed matching just re-fetches
  them — it costs bandwidth proportional to btrfs metadata, not correctness. And a **local**
  `rauc install /path/bundle.raucb` keeps working byte-for-byte: `_reference/rauc/src/
  update_handler.c:986-1035` makes adaptive best-effort with an unconditional `goto raw_copy` on
  every failure path, so the pre-publish HW gate is untouched.

  **HW RESULT 2026-08-04 — the wire measurement, which was the open gate.** Device on `0.2.1`
  (slot B, git c9f208c), `rauc install <https URL>` of the published `test`-channel `0.2.2`,
  dispatched over rauc's open D-Bus policy. Counters read either side of the install ON the device
  (`/sys/class/net/wlp1s0/statistics/`):

  | | |
  |---|---|
  | on the wire (rx) | **60 529 625 B = 57.7 MiB** |
  | bundle, in full | 3 740 633 702 B = 3.48 GiB |
  | reduction | **61.8x, 98.38% saved** |
  | elapsed, `rc=0` | 8m08s |

  Adaptive engaged and is confirmed, not inferred: the log shows `Checking slot rootfs.0 (A)`
  consuming the first ~46% of the run, which is the on-demand index build — no index was stored
  yet, exactly as c9f208c predicted (slower, not bigger).

  **DO NOT quote 61.8x as the `0.2.1 -> 0.2.2` number, and do not read it as the offline model
  under-predicting.** Adaptive matches against the TARGET slot, which was A — and rauc tracks no
  per-slot installed version here (`rauc status --output-format=json` reports `?`), so what A held
  is genuinely unknown. It was most likely a same-day build, which would explain landing 2.1x under
  the ~123 MB predicted for the consecutive-release pair. The measured pair is `unknown -> 0.2.2`.
  Re-running it against a slot whose content is known is the only way to close that, and it is not
  worth a dedicated build — take it opportunistically the next time both slots are known.

  **The reboot settled it, same day: the delta-written slot BOOTS.** Device came up on `rootfs.0`
  (A) running `0.2.2` / build `20260804T180433Z`, `novadeck-boot-good` logged `boot confirmed good
  (image A)`, both slots ended `good`, zero failed units. So adaptive is validated, not merely
  measured — correctness was already bounded by design (every local hit re-hashed against the
  signature-covered index) and is now also observed.

  One trap for whoever repeats this: **immediately after the reboot A reads `boot status: bad`, and
  that is the normal unconfirmed-trial state, not a failure.** `novadeck-boot-good.path` waits for a
  live session and the service adds `ExecStartPre=/usr/bin/sleep 30`, so the flip to `good` lands
  minutes in. Reading `rauc status` at once and concluding the delta write was corrupt is the
  available mistake here. (Do not use `uptime -p` to judge how long to wait — it disagreed with
  `who -b` by ~10 min on this device, the stale-RTC behaviour noted elsewhere. Trust unit
  timestamps.)

  Raised 2026-07-29 while rejecting Android-style Virtual A/B (single slot + dm-snapshot COW). That
  was declined on its merits — it reclaims ~7G, needs `dm-user`/`snapuserd` which are **not**
  upstream (mainline gives us plain uncompressed `dm-snapshot` only), would force
  `images/initramfs/init` to mount and fsck `/home` before it can assemble a root on a board with
  no UART, and its merge phase destroys the known-good slot that the whole trial/rollback design
  depends on. Adaptive bundles are the part of that idea worth having, at config-level cost.
  See also the slot-sizing note in `images/partition-table.txt` (~2G/slot of `mkfs.btrfs --shrink`
  block-group padding, 5.7G apparent vs 3.7G real) — a cheaper disk-space win than any of this,
  and not yet its own item.

## Phase 2 — gamescope session (closed)

- [x] **Clean gamescope teardown / re-launch wedge** — WON'T-FIX (HW-disproven 2026-06-25).
  The re-launch (L2) wedge is a userspace never-signaling syncobj fence in gamescope's
  `linux-drm-syncobj` WSI handshake, not stale GPU/DRM state — a clean SIGTERM teardown doesn't
  prevent it (~50% either way; dmesg shows zero GPU faults). **Decision: keep
  `ENABLE_GAMESCOPE_WSI=1`** (upstream/ChimeraOS default; FROG WSI gives frame pacing, latency,
  adaptive-sync, HDR). Release launches gamescope once per power-on (clean L1, 10/10), so it
  should not bite. `=0` (implicit sync, 8/8 clean re-launch) is the env-overridable fallback.
  **Residual risk OPEN**: `Restart=on-failure` / a deliberate session restart takes the L2 path.
  Dead ends (do not retry): `--immediate-flips` (KMS-unsupported on msm), a Turnip/Mesa bump.
  Re-validation harness on the test device: `/root/freeze-trial-graceful.sh`. See [[sm8650-gamescope-flip-blocker]].

## Phase 2 — HW-support layer C (closed)

- [x] **Fold power ops into the suspend path** — DONE + HW-validated 2026-06-24. Reversible
  primitives (cpu-offline, rfkill, cpu+gpu powersave governor) extracted to
  `hw-support/usr/lib/novadeck/power-ops.sh` (`power_enter`/`power_leave`); applied after the
  freeze, restored before the thaw. Guard: `NOVADECK_SUSPEND_SKIP`.

- [x] **Power-key suspend trigger** — DONE. `novadeck-waked` (logind `HandlePowerKey=ignore` +
  libinput on the power key): tap → `novadeck-suspend toggle`. Enabled at boot via overlay preset.

- [x] **Long-press power = clean shutdown** — DONE + HW-validated 2026-06-24. Hold ≥
  `NOVADECK_WAKE_LONGPRESS_MS` (default 2000ms) thaws then `systemctl poweroff`. Knob in `rest.conf`.
  See [[waked-holdtime-background-dispatch]].

- [x] **`do_resume` must not call systemctl while frozen** — DONE + HW-validated 2026-06-24. The
  system D-Bus daemon is in the frozen `system.slice`, so a pre-thaw systemctl blocked ~90s. Thaw
  first, then systemctl; power-restore stays pre-thaw (pure sysfs). See [[suspend-systemctl-while-frozen-blocks]].

- [x] **Bluetooth stack** — DONE + adapter HW-validated 2026-06-25. `bluez`/`bluez-utils` in PKGS,
  `bluetoothd` enabled via overlay; WCN7850 BT firmware ships. Controller pairing exercised in the
  Phase-3 Steam shell (known-good ROCKNIX path).

- [x] **Release Wi-Fi resume after suspend** — DONE + HW-validated 2026-06-25, no hook needed.
  NetworkManager re-associates unaided after a freeze+rfkill cycle. Test card rewritten to NM
  (`.nmconnection` keyfile) so test == release stack; `50-nm-reup` dropped as moot; docs reconciled
  off iwd. See [[wifi-config-is-test-only]], [[suspend-ssh-survives-established]].

- [x] **System clock / NTP** — DONE + HW-validated 2026-06-25. `systemd-timesyncd` config +
  enablement in overlay. The epoch-stuck clock root cause was `/.dockerenv` (→
  `systemd-detect-virt=docker` skipped the unit's `ConditionVirtualization`); fixed by
  `sanitize_base_provenance()`. See [[dockerenv-systemd-container-misdetect]].

- [x] **A restricted SSH key so CI can publish OTA bundles** — DONE 2026-08-04, server-side verified.
  `ota/v0.2.1` was cut, built and signed, and its run went **green having published nothing**: the
  `publish` job reported the missing `OTA_SSH_KEY` as a `::notice::` and skipped its steps, which no
  one reads at the bottom of an hour-long success. Two things were wrong and only one of them was
  the credential.
  **The principal.** `ota/setup-ci-user.sh` (new, idempotent, runs as root on the instance) creates
  `otapub`: a system account with no password, no sudo and no group but its own, whose sole
  `authorized_keys` entry is `restrict`-prefixed. Public half committed at `ota/ci-publish.pub`;
  private half exists only as the CI secret. Verified from outside with the CI key: docroot write,
  `df`, `mv`, `chmod`, `sha256sum` and the `bash -s` prune all work; `sudo -n`, writing `/etc`,
  reading `/etc/shadow`, a pty, and both `-L` and `-R` forwarding all refused. (`-L` binds
  client-side and *appears* to succeed — the honest test is whether bytes traverse it. They do not.)
  **A forced command was rejected, not skipped.** `rrsync` covers rsync and `publish-bundle.sh` is
  not an rsync wrapper; a wrapper whitelisting the other five verbs becomes a second, unversioned
  copy of the publish protocol. An account with no sudo is the same bound enforced by the kernel.
  **The second bug: an environment-scoped secret reads as EMPTY in a job that does not declare the
  environment.** No error, no warning. `OTA_SSH_KEY` went into `release-signing` as planned, so
  without `environment:` on the `publish` job the fix would have reproduced the original symptom
  exactly — green, nothing published, secret visibly present in repo settings. The job now declares
  it (costing a second approval per release, which is the right shape) and a missing credential is a
  hard `::error::` + `exit 1`: the only two outcomes are **published** or **red**.
  **Docroot ownership moved** to `otapub:otapub` mode 2775 (setgid), with `ubuntu` in the `otapub`
  group so the workstation path and the by-hand rollback keep working. `setup-server.sh`'s owner
  default moved with it — left at `ubuntu` it would have chowned the tree back and dropped the
  setgid bit on its next run, surfacing months later as a publish that fails on `mkdir` for a new
  channel. Re-ran it to prove it: ownership survived, CI key still writes, `/healthz` still 200.
  See [[ota-server-oracle-instance]], `docs/ota.md`.

- [x] **Move the `R2_*` card credentials into their own protected environment** — DONE 2026-08-04.
  The trio was repo-wide, so any `workflow_dispatch` by anyone with write access reached it. That is
  worse than "a write credential to a public bucket" suggests: `images/publish-card.sh` prunes with
  `rclone purge` at KEEP=1, so these credentials can **delete** the published card, not merely add
  one. Now in `release-cards` (required reviewer `loki666`), with the repo-wide copies deleted.
  **A SECOND environment, not `release-signing`.** That one's deployment policy is `ota/v*`; cards
  ship on `card/v*`, so reusing it would have rejected every card release at the gate. Its policy
  allows `main` as well as the `card/v*` tags, because a dispatch with `publish: true` is a
  documented way to cut a card and a tag-only policy would refuse it. Both still require a reviewer,
  so the result is strictly tighter than repo-wide rather than a new door.
  **The half that would have failed silently.** `release-sdcard.yml` passed the secrets explicitly
  (`R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}`), and that expression evaluates in the CALLER's
  context — a job calling a reusable workflow, which cannot declare an environment. The secrets
  would have resolved to the empty string there, been handed to `image.yml` as empty strings, and
  the build would have run ~4h before dying at the upload step. Now `secrets: inherit`, which defers
  resolution to `image.yml`'s build job where the environment IS declared. Load-bearing in both
  directions: `inherit` without the environment input, or the input without `inherit`, both give
  blank credentials.
  **Gated on `publish`, not on `ref_type == 'tag'`** — unlike the bundle path those differ for
  cards, and gating on the tag would hand a publishing dispatch empty credentials. A dispatch that
  only asks "does this still build?" names no environment, needs no approval, and cannot reach the
  upload step at all (`image.yml` guards it on `inputs.publish`).
  `r2_env` now names this mechanism in its failure message instead of saying only "R2_ACCOUNT_ID not
  set", which is useless when the secret is plainly visible in repo settings.
  **Proven:** `card/v0.2.1` was moved to head and its run paused at the `release-cards` gate — it
  could not have paused there before this change. `R2_BUCKET`/`R2_PUBLIC_BASE` stay repo variables.
  Second occurrence of the empty-secret trap in one day; the first cost `ota/v0.2.1` a green run
  that published nothing. See [[ci-protected-environments]].

- [x] **`novadeck_perf` walked `/proc` TWICE per tick — collapsed to one pass, 2026-08-10.** Pure
  optimization, no behaviour change. `pids_by_comm()` reads every `/proc/<pid>/comm` and was called
  twice per 3s tick with different comm sets: once for `steam` (inside `scan_games`) and once for
  `gamescope` (inside `apply_gamescope`). Now `Enforcer.tick()` builds one `comm_index(STEAM_COMMS +
  GAMESCOPE_COMMS)` — `{comm: [pid]}` from a single `listdir` — and hands it to both; each consumer
  still works standalone, walking on its own when passed no index, which is what keeps the offline
  suite and any future caller honest. Measured on the DEV HOST (read-only `/proc` benchmark, not the
  device): at 567 processes, 10.95 ms for two walks vs 5.43 ms for one — the predicted halving, from
  ~6.8 ms/walk at 675 processes measured 2026-08-09. `images/test-perf.sh` asserts the shape (index
  grouped by comm, indexed lookups equal to a fresh walk) AND the point of the change: it counts
  `listdir` calls on `PROC_ROOT` during a tick and requires exactly **one**, so a future caller
  reintroducing a second walk fails the suite rather than silently costing a tick.
  **Why the tick must NOT be `nice`d** — the question that raised this, and the reason it was worth
  writing down. `fan_tick` is the ONLY `sd_notify("WATCHDOG=1")` caller (`perf_tick` has none), and
  the unit pairs `WatchdogSec=15` with `Restart=always` + `ExecStopPost=--fan-safe`. Starving the
  tick past 15s therefore kills powerd, slams the fan to `FAN_SAFE_PWM=128` and restarts the daemon,
  precisely under the full load where the curve matters most. It would also be queued behind the very
  processes we prioritize ourselves (game tree `nice -5`, gamescope `SCHED_RR`), and `nice` does not
  mean the same thing under `scx_lavd` as under EEVDF.
  **The remaining win is NOT free**, and is deliberately not taken: skipping the scan entirely when
  no tweaks are configured would break `apply_gamescope`'s restore path, which puts gamescope's
  children back on all CPUs when a mask is withdrawn — it would need the touched-state bookkeeping
  `apply_game_tree` already has. Relates to [[per-game-perf-port]], [[scx-sched-bringup]].
