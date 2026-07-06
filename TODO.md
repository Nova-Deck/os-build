# novadeck — follow-up TODO

Deferred work. Closed items keep a one-line resolution + HW-validation date; the full
rationale lives in the linked memories and commit history.

## Open

- [ ] **Fix automatic UI scale** — SteamUI's automatic scaling picks the wrong factor on the device
  panel (UI too small/large for the handheld's resolution/DPI), rather than the Deck-like scale a user
  expects. Characterize on HW first: capture what auto-scale resolves to vs. what looks right, at the
  landscape logical output we hand gamescope (`-W/-H` from `session/etc/novadeck/session.conf` +
  `session/usr/bin/novadeck-session`). Investigate the levers: the logical output geometry we pass
  gamescope, gamescope's own scaling flags, and SteamUI's UI-scale (the Deck exposes a Display
  "automatic/scale" setting driven by env/config). Decide whether to set a correct default per panel
  vs. let SteamUI auto-compute it. See [[sm8650-working-display-baseline]], [[sm8650-gamescope-session-plumbing]].

- [ ] **Replace our rotation-shader patch with upstream composited-output rotation** — our portrait
  panel is rotated by a custom patch (`packages/gamescope/patches/0001-rotate-portrait-panel-in-composite.patch`,
  driven by `--use-rotation-shader`; see [[sm8650-gamescope-flip-blocker]]). Upstream gamescope PR
  [#2228](https://github.com/ValveSoftware/gamescope/pull/2228) adds this properly: rotation via a
  composition pass for drivers/panels that can't rotate the plane at scanout, integrated into the
  composite scenegraph (scene stays in logical space; only the final store coordinate is rotated, so
  sampling/blending/input/cursor/EDID are untouched). Engages automatically when the primary plane
  can't rotate, or via a new `--force-composition-rotation` flag. **It was tested on our exact device
  (Ayaneo Pocket S2, SM8650) and the Ayn Thor (SM8550).** Action: adopt the PR (rebase our patch onto
  it, or drop ours for the flag) so we ride upstream instead of carrying a bespoke shader. Preserve
  our WSI patch when reworking the build; re-validate rotation + the re-launch flip behavior on HW.

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
  `feat/brightness-volume-perf-acls`). Env gate (`STEAM_ENABLE_DYNAMIC_BACKLIGHT=1`) made the slider
  appear but the write path was missing: `/sys/class/backlight/sy7758-backlight/brightness` is
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

- [ ] **Suspend polish: stop the fan + robust panel blank** — follow-ups from the 2026-07-05 HW pass,
  both cosmetic (freeze/wake itself is solid):
  - **Fan keeps spinning during fake-suspend.** There IS a controllable fan (`pwmfan` at
    `/sys/class/hwmon/hwmon42/pwm1`); `power_enter`/`power_leave` don't touch it. Add a reversible
    fan-off op to `power-ops.sh` (save `pwm1` + `pwm1_enable`, set 0 on enter, restore on leave — same
    state-record pattern as the cpu/rfkill/governor ops), gated by a `NOVADECK_SUSPEND_SKIP`-style key.
    Groundwork for later fan-curve work (steamos-manager `PerformanceProfile1`).
  - **Our `gamescopectl` panel-blank path logs "unreachable"** when `novadeck-suspend` runs as
    `systemd-suspend.service` (root, system.slice) — it can't resolve the live gamescope socket. Harmless
    today because Steam blanks the panel itself as part of its sleep flow, but add a `bl_power` fallback
    (`echo 4 > /sys/class/backlight/*/bl_power` on suspend, `0` on resume) so a blank still happens if
    Steam's own blank ever regresses. See [[sm8650-gamescope-flip-blocker]].

- [ ] **Provide `com.steampowered.SteamOSManager1` (steamos-manager) — SteamUI's privileged backend**
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

- [ ] **Brightness up/down hotkeys — unverified** — `novadeck-hotkeyd` maps KEY_BRIGHTNESSUP/DOWN, but
  the Pocket S2 raw capture only showed `KEY_VOLUMEUP`, so the board likely has no physical brightness
  keys (harmless if absent). Confirm whether any board emits brightness keysyms; if not, this is moot.

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

- [ ] **Volume up/down keys don't change volume** — pressing a vol-/vol+ key brings up the SteamUI
  volume popup but the level doesn't move; the SteamUI Quick-Access volume **slider** works, and
  `wpctl`/PipeWire volume is fine. So audio + the SteamUI action both work — the gap is the **key → set
  volume** binding: the keycode is delivered (popup appears) but not wired to the volume action. Same
  shape as the brightness slider (appears, inert) and the `novadeck-waked` libinput mapping. Check
  whether it's an **InputPlumber** mapping (the vol keys emitting the wrong evdev codes / not the ones
  SteamUI's volume handler listens for) vs a missing gamescope/`STEAM_*` keybind; confirm what
  `KEY_VOLUMEUP/DOWN` the panel emits and whether SteamUI expects them via gamescope's key handling.
  See [[sm8650-inputplumber-input]], [[suspend-freeze-wake-design]],
  [[sm8650-gamescope-session-plumbing]].

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
  old ~1GB rootfs→home copy and its grow-race ENOSPC trap). The pristine seed stays baked in the RO
  root (`/usr/share/novadeck/steam-seed`) as the **offline factory-reset** source (survives a `/home`
  wipe); `steam-bootstrap.sh` is repurposed from first-boot seeder to the on-demand reset tool (left
  unenabled). Phase-4: move the recovery seed to a SHARED partition, not duplicated per A/B slot. See
  [[steam-must-be-baked-offline]], [[steam-offline-sdl3-seed]], [[grow-home-repart-no-initramfs]].

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

- [ ] **Stable Wi-Fi + Bluetooth MAC addresses (first-boot)** — the WCN7850 comes up without a
  persistent MAC (no vendor NVRAM/`nvmem` MAC path on this SM8650 port), so the Wi-Fi and BT
  addresses are non-deterministic across boots (random/locally-administered, and identical across
  units flashed from the same image). Generate a **stable per-device MAC once on first boot** —
  derive it from a hardware-unique seed (SoC serial / `machine-id`) with the locally-administered
  bit set, persist it, and apply it: Wi-Fi via a NetworkManager `ethernet.cloned-mac-address` /
  `wifi.cloned-mac-address` (or `.link` `MACAddress=`) keyfile, Bluetooth via a `btmgmt public-addr`
  (or `hci0` `.link`) one-shot before `bluetoothd`. Must be idempotent (write-once, survive reboots)
  and land on the writable side, not the RO root. Relates to [[wifi-config-is-test-only]].

- [ ] 🍒 **Cherry on top: install to internal UFS + SD card as game library** — today NovaDeck
  runs from a dd'd SD-card image (Phase 1). Ultimately we want a real **installer that lays the
  image down on the device's internal UFS** (like SteamOS on the Deck's internal drive), and then
  repurposes the **SD card as an external Steam game library**. SteamOS already ships the format
  helpers for the library step — `steamos-format-sdcard` / `steamos-format-device` (seen in the
  baked `steamui.so` strings next to the OOBE update helpers), called by Settings > Storage — which
  we have NOT wired up yet (candidate to port). Our ext4 `novadeck-home` already matches SteamOS
  (plain-dir libraries, no btrfs nodatacow dance — Armada's `steamapps` subvolume is Armada-only, do
  not port). Fits the Phase-4 manifest/immutable model. See
  [[install-to-ufs-sdcard-library-goal]], [[grow-home-repart-no-initramfs]], [[rootfs-build-approach]].

- [ ] **MangoHud performance overlay via `--mangoapp`** — ship the Deck-style FPS/perf overlay.
  Add `mangohud` (+ its `mangoapp` companion) to the image (`customize-base.sh` PKGS if it resolves
  in the holo repo, else a `packages/` overlay build), and pass `--mangoapp` to gamescope in the
  novadeck session launch (`session/` gamescope-session). This is how SteamOS/Armada/ROCKNIX drive
  the overlay: gamescope spawns `mangoapp` as an in-session overlay window and SteamUI's
  Performance settings toggle its level — so it wires up to the existing Deck UI, no extra config.
  Confirm the arm64 `mangohud`/`mangoapp` packages exist in holo before adding (cf.
  [[holo-pacman-no-gtk2]] — don't assume a package resolves), and that gamescope was built with
  mangoapp support. See [[sm8650-gamescope-session-plumbing]].

- [ ] **Faster arm64 package builds: qemu-master + native distcc cross-compiler** — the overlay
  packages currently build inside an emulated aarch64 environment (slow — qemu runs the compiler
  instruction-by-instruction). Restructure `packages/` into a **docker-compose** topology: a
  **master aarch64 (qemu) container** runs `makepkg`/`pacman` so the build sees a native arm64
  sysroot and resolves deps correctly, but delegates the actual compiles over **distcc** to one or
  more **native amd64 daemon containers** running an `aarch64-linux-gnu` cross-toolchain — so the
  heavy C/C++ compilation runs at native speed and only linking/configure/packaging stays under
  qemu. Keeps our per-package isolation ([[overlay-isolate-per-package-container]]) — compose can
  spin the master fresh per package while the distcc workers persist. Watch: distcc must use the
  matching cross-gcc (ABI/version parity with the holo toolchain), and packages doing
  arch-native codegen or running built binaries mid-build (tests, `-march=native`) won't offload
  cleanly. Relates to [[builds-use-docker-crosscompile]], [[overlay-package-pipeline]].

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
