# novadeck — follow-up TODO

Deferred work. Closed items keep a one-line resolution + HW-validation date; the full
rationale lives in the linked memories and commit history.

## Open

- [ ] **Pocket DS: SY7758 backlight has no `enable-gpios` → panel will defer (no display)** — the
  upstream `silergy,sy7758` driver requires `enable-gpios` to bind (root cause of the Pocket ACE blue
  screen, fixed 2026-07-13 for ace/s2k/s1k with `enable-gpios = <&tlmm 41 GPIO_ACTIVE_HIGH>`). The
  Pocket DS node (`qcs8550-ayaneo-pocketds.dts:129` `backlight: backlight@2e`) has **no enable GPIO and
  no `backlight_pwr_active` pinctrl** to derive one from — unlike the other AYANEO boards. Its I2C bus
  carries a **`tca6408` GPIO expander** (`tca64_20@20`), so the DS backlight enable is most likely an
  **expander pin** (`enable-gpios = <&tca6408 N GPIO_ACTIVE_HIGH>`), not a tlmm gpio — pin N unknown,
  needs the DS schematic or a reference. Not in Armada's fix commit (a537fbae, which only did
  ace/s2k). Without it the AR-class DS panel(s) will sit in deferred-probe exactly like ace did. See
  [[sm8550-bringup-pickup]].

- [ ] **PMIC RTC probe defers forever → no `/dev/rtc` (SM8650 ayaneo boards)** — HW-confirmed on
  Pocket S2 (2026-07-12). `/sys/kernel/debug/devices_deferred` holds `c400000.spmi:pmic@0:rtc@6100`
  ("reason unknown") and there is no `/dev/rtc0`. Root cause: `sm8650-ayaneo-common.dtsi` sets
  `qcom,uefi-rtc-info` on `&pmk8550_rtc`. That property makes `rtc-pm8xxx` read the RTC offset from a
  UEFI variable; with `CONFIG_EFI=y` on a device that is **not** UEFI-booted (`efi: UEFI not found` —
  we boot via ABL android-bootimg), `pm8xxx_rtc_probe_offset()` hits
  `if (!efivar_is_available()) { if (IS_ENABLED(CONFIG_EFI)) return -EPROBE_DEFER; }`
  (`drivers/rtc/rtc-pm8xxx.c:584`) and defers permanently — efivars never appear.
  Fix: drop `qcom,uefi-rtc-info` from the `&pmk8550_rtc` override (keep `qcom,no-alarm` + `status`).
  The RTC then binds offset-less (read-only, offset=0) and `/dev/rtc0` appears; `systemd-timesyncd`
  already owns wall-clock so nothing else regresses. Impact is cosmetic today (NTP fixes the clock
  seconds after Wi-Fi), which is why it's parked — but it's a one-line DTS change on the next kernel
  build. Property arrived with the unified-image refactor (`a6fc71f`); only in this one dtsi.

- [ ] **RAUC must rsync `/var` across slots — `/etc` and the Wi-Fi MAC ride on it** — NOT yet built;
  a hard prerequisite for the A/B switch, not a nicety. The `/etc` overlay's upperdir lives at
  `/var/lib/overlays/etc/upper`, and `/var` is **per-slot** (`var-a`/`var-b`). So booting the other
  slot presents a *different* `/etc`: no saved Wi-Fi, and a fresh `/etc/machine-id`. That last one
  bites twice, because `hw-support/usr/lib/novadeck/gen-mac.sh` derives the Wi-Fi MAC from
  `sha256(machine-id)` — a slot switch would silently change the device's MAC.
  SteamOS solves this exactly the way we must (`_reference/steamos-teardown/docs/system-updates.md`
  :132-137): the post-update hook **reformats** the target slot's `/var`, `rsync`s the running slot's
  `/var` over it, and *additionally* writes NetworkManager connections into both partsets'
  `…/overlays/etc/upper/NetworkManager/system-connections/`. Port that hook when wiring RAUC.
  See [[stable-mac-first-boot]], [[wifi-connect-fails-after-list]].

- [ ] **Populate `efi-a`/`efi-b` with per-slot boot images** — created + formatted vfat, currently
  EMPTY. ABL only ever reads `/KERNEL` from the shared ESP (p1), so an A/B switch cannot just point
  the bootloader at another partition: the per-slot boot image (`KERNEL-A` / `KERNEL-B`, ~23M each
  incl. the initramfs) has to live in `efi-a`/`efi-b`, and a RAUC post-install hook copies the
  newly-written slot's image over `/KERNEL` on the ESP. Note each slot's image carries its OWN
  cmdline (`root=PARTLABEL=novadeck-root-{A,B}` + `novadeck.var=…-{A,B}`), so `boot/package.sh` needs
  a slot argument. See [[sm8650-rocknix-abl-boot]].

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

- [ ] **MangoHud performance-overlay enable/disable still misbehaves — REOPENS the "DONE" item
  below.** User re-reported (2026-07-11) that toggling the SteamUI Quick-Access **Performance** overlay
  on/off is still not behaving on HW, so the earlier "both control paths confirmed" close is NOT
  reliable. Investigate the toggle path end-to-end: the SysV `no_display` control queue (show/hide) vs
  the config-file + reload (level), and the **focused-GAME gate** (mangoapp self-suppresses while the
  Steam UI / appid 769 is focused, so a library-side toggle is a no-op *by design* — confirm the report
  is in-game, not in the library). Capture what actually happens on toggle: does mangoapp receive the
  control message, does the overlay redraw, does it get stuck on/off, or flicker? Compare live against
  the DONE item's claimed mechanism. See [[mangohud-quickaccess-control-gap]],
  [[sm8650-gamescope-session-plumbing]].

- [ ] **QuickAccess frame-rate limiter has no effect in-game** — the SteamUI Performance FPS cap
  doesn't limit the framerate on HW (user, 2026-07-08). This is a gamescope path, NOT mangohud (the
  perf overlay toggle + Level are HW-verified working in-game as of the same day —
  [[mangohud-quickaccess-control-gap]]). Mechanism: gamescope's `steamcompmgr` caps commits via
  `g_nSteamCompMgrTargetFPS` / `steamcompmgr_set_app_refresh_cycle_override()` (vblank-divisor pacing,
  `steamcompmgr.cpp` ~5647-5673) and writes a `limiter_enabled` u32 flag to `GAMESCOPE_LIMITER_FILE`
  (~5590). Cheap decisive probe: set an FPS cap in-game and read byte 0 of `$GAMESCOPE_LIMITER_FILE`
  (from gamescope's `/proc/<pid>/environ`) — flips to `1` = client reached gamescope (cap engaged, chase
  the pacing / dynamic-refresh path); stays `0` = the client→gamescope override isn't landing (check the
  driving control channel / STEAM_* gate + whether the connector exposes valid dynamic refresh rates,
  `GetValidDynamicRefreshRates()`). Also check `STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER` (the WSI-layer
  limiter path). See [[sm8650-gamescope-session-plumbing]], [[chimeraos-gamescope-session-reference]].

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

- [ ] **Find the new SteamUI scale lever — panel mm is now IGNORED (2026-07-11)** — a Steam client
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
  `--force-composition-rotation` (`session/usr/bin/novadeck-session` + `images/assemble-rootfs.sh`
  smoke both now launch bare `--backend drm`). `-W/-H` stay the landscape logical size (PR keeps
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
  **Possible workaround if there are no dedicated keys:** map a **chord** (e.g. a function/hotkey button +
  vol-/vol+) to `KEY_BRIGHTNESSDOWN`/`KEY_BRIGHTNESSUP` via **InputPlumber**, so brightness gets a control
  surface even without physical brightness keys — `novadeck-hotkeyd` already handles those keysyms.
  See [[sm8650-inputplumber-input]].

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

- [x] **MangoHud performance overlay via `--mangoapp`** — DONE + HW-validated 2026-07-08.
  Confirmed `mangohud`/`mangoapp` are NOT in the holo aarch64 repos (no `mango*` in the pinned base's
  synced core/extra dbs; gamescope/mesa/openal do resolve), so shipped as a from-source overlay like
  gtk2/sddm: `packages/mangohud/` (local `PKGBUILD` @ MangoHud 0.8.4, `-Dmangoapp=true
  -Dmangohudctl=true` + system spdlog, NVIDIA XNVCtrl off) plus the ROCKNIX Qualcomm/SM85xx patch set
  as carried by armada (`packages/mangohud/patches/0001..0006`, applied by `build-overlay.sh`) that
  teaches GPU_fdinfo/BatteryStats/HUD to read an Adreno SoC (kgsl/devfreq GPU clock+temp, `battery`
  power-supply, RAM label) — all 6 taken, incl. the SM8550/SM8750 device patches (closest match for
  our SM8650 Adreno 750). Added `mangohud` to `customize-base.sh` PKGS (installs ahead of holo from
  the [novadeck] overlay) and pass `--mangoapp` to gamescope in `session/usr/bin/novadeck-session`
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
