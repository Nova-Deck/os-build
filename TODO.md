# novadeck — follow-up TODO

Deferred work. Closed items keep a one-line resolution + HW-validation date; the full
rationale lives in the linked memories and commit history.

## Open

- [ ] **Poweroff / sleep issues resurfacing** — the Phase-2 suspend/poweroff path was closed
  HW-validated 2026-06-24 (freeze+wake, power-key tap→suspend, long-press→poweroff, thaw-before-
  systemctl — see the Phase-2 HW-support closed items below), but problems are showing again on
  current images. NEEDS CHARACTERIZATION: capture the exact symptom and WHICH path (L1 cold poweroff
  vs power-key tap→suspend vs long-press→poweroff vs resume/thaw) on a plain RELEASE image, via
  offline card-mount `journalctl -D` (no UART). Suspects to rule out: interaction with the
  SDDM-autologin / active-seat session model, and the dirmngr slow-shutdown stall. Grade findings
  CONFIRMED/SUSPECT/OPEN and test true reboots, not just service re-launches.
  **ChimeraOS reference (see [[chimeraos-gamescope-session-reference]]):** SteamUI's own
  Restart/Shutdown menu items work via **reboot/shutdown sentinel files** — Steam writes
  `$REBOOT_SENTINEL`/`$SHUTDOWN_SENTINEL` and exits, then the session script (after the client
  returns) checks for them and calls `reboot`/`poweroff`. novadeck's launcher `exec`s Steam and has
  no post-exit sentinel handler, so a SteamUI-initiated restart/poweroff likely has nowhere to land —
  a prime suspect for the resurfacing symptom. Also cross-check our `novadeck-waked` power-key path
  against ChimeraOS's `systemd-inhibit --what=handle-power-key… + powerbuttond` (validates our design,
  not a replacement). See
  [[suspend-freeze-wake-design]], [[suspend-systemctl-while-frozen-blocks]],
  [[waked-holdtime-background-dispatch]], [[sm8650-gamescope-session-plumbing]],
  [[dirmngr-slow-shutdown-defer-phase4]], [[verify-before-concluding-reboot-vs-restart]].

- [ ] **Wire brightness controls (+ hotkeys)** — make panel backlight adjustable from the Deck UX.
  Two parts: (1) expose the SM8650 panel backlight so SteamUI's Quick-Access brightness slider drives
  it — confirm the `/sys/class/backlight/*` device the DSI panel registers, and give the active
  session write access (udev/logind `uaccess` or a small polkit/helper path, on the writable side, not
  the RO root). (2) Brightness up/down **hotkeys** — map them to backlight steps, following the
  `novadeck-waked` libinput pattern (power key) or an InputPlumber binding. Watch: match SteamUI's
  expected backlight interface (it uses the `steamos` backlight path, cf. the OOBE/format helper
  strings in `steamui.so`), and clamp min brightness so the screen can't go fully dark.
  **ChimeraOS reference (see [[chimeraos-gamescope-session-reference]]):** the QuickAccess
  brightness/adaptive-brightness control is ENV-GATED — SteamOS's session exports
  `STEAM_ENABLE_DYNAMIC_BACKLIGHT=1` (+ `STEAM_DISPLAY_REFRESH_LIMITS=<lo,hi>` for the refresh
  slider). novadeck's `novadeck-steam` exports none of these, so the slider may not even appear
  regardless of the backlight sysfs work. Export the gate FIRST (free, no rebuild); it's orthogonal
  to — and a precondition for — the `/sys/class/backlight` write-access piece above. See
  [[sm8650-working-display-baseline]], [[sm8650-inputplumber-input]], [[suspend-freeze-wake-design]],
  [[sm8650-gamescope-session-plumbing]].

- [ ] **Display color controls not working (night mode / color temp, etc.)** — SteamUI's color
  settings (night mode / color temperature, saturation, gamut) don't take effect. gamescope owns the
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
  color AND brightness at once — before doing the gamescope.spec build work. See
  [[sm8650-gamescope-flip-blocker]], [[overlay-package-pipeline]],
  [[inspect-upstream-by-cloning-not-scraping]], [[mesa-freedreno-depends-libdisplay-info]].

- [ ] **Adopt SteamUI-expected session defaults we omit** — `novadeck-session` runs a comparatively
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

- [ ] **`--ready-fd` ready-then-launch handshake** — candidate mitigation for the residual
  Phase-2 gamescope re-launch wedge (below). Run gamescope bare, launch the client only after
  it signals ready via `--ready-fd`. Prototyped, never proven to reliably dodge the wedge. Only
  relevant if a session restart (WSI on) actually wedges in the field.

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
