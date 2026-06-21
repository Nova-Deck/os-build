# SM8650 bring-up checklist (Phase 2 — SteamOS layer)

Phase 1 cleared the hardware gate (Turnip Vulkan presenting to KMS; see `bringup.md`).
Phase 2 stacks the **SteamOS experience layers** on the working base:

- **Layer B** — gamescope session + Deck UI (boot → Big Picture, Quick Access, OSK/OSD).
- **Layer C** — `jupiter-*` hardware support, replaced by a novadeck **Qualcomm HW-support**
  package backing the layer-C affordance matrix (TDP/refresh/suspend/brightness/gyro/battery)
  with cpufreq/devfreq/IIO/UPower/backlight, honestly stubbed where no Qualcomm equivalent exists.

Phase 2 is **not** a hard go/no-go gate (that is Phase 3). The mandate from the plan is
**de-risk first**: prove bare gamescope on Turnip before doing the jupiter-* porting work, so
the Turnip↔gamescope Vulkan-feature question is isolated from the port.

## Step 1 — Bare gamescope on Turnip (the de-risk) [IN PROGRESS]

The Phase-1 gate proved the **direct** present path (`vkcube --wsi display`, `VK_KHR_display`,
no compositor). gamescope adds a **Wayland compositor** in the middle: it owns KMS via the DRM
backend and clients render into its Wayland display. The open question is whether **Turnip's
Wayland WSI** + the modifiers/present features gamescope wants are all present on Adreno 750.

| # | Check | How | Status |
|---|---|---|---|
| 1a | gamescope present in base | `pacman -Si gamescope seatd` against the pinned base repo | ✅ both in `extra/aarch64`: gamescope 3.16.17-1, seatd 0.9.1-1 (verified 2026-06-21) |
| 1b | gamescope opens DRM/KMS | `nova-gamescope-smoke` — DRM backend under `seatd-launch` (holo libseat has only logind+seatd backends, no `builtin`) | ✅ seat via seatd; opens `/dev/dri/card0`, selects `DSI-1` @ native `1440x2560@60`; **first (modeset) atomic commit scans out a frame** (LINEAR XR24, bw OK) |
| 1c | Vulkan client renders under gamescope | default client `vkcube` → gamescope Wayland → Turnip WSI; cube on panel | ◐ **client path proven** (Gamescope-WSI swapchain created on Turnip, BGRA8888) but **not visible — blocked by 1e** |
| 1d | Input reaches the client | InputPlumber virtual gamepad (Phase-1 green) seen inside gamescope via libinput | ☐ blocked by 1e |
| 1e | **Per-frame atomic flip** | steady-state plane-only flips to DSI-1 | ❌ **BLOCKER**: every flip after the first returns `EINVAL` (`xwm: Failed to prepare 1-layer flip (Invalid argument)`), rejected at DRM-core level (no DPU `atomic_check` log) |

**How to run** (TEST build, SSH in, watch the panel):

```
nova-gamescope-smoke            # gamescope --backend drm -- vkcube
nova-gamescope-smoke <client>   # swap the nested client
```

The helper ships **test-only** (installed by `images/assemble-rootfs.sh` under `NOVADECK_TEST=1`)
and is launched by hand — it is **not** a systemd unit, so it never seizes the panel from the
SSH/console bring-up path on a throwaway card. `gamescope` + `seatd` themselves are in the
**release** package set (`images/customize-base.sh` PKGS) — they are layer-B runtime, not test
tooling.

### Findings (on-HW, 2026-06-21)
What WORKS: seat (seatd-launch; libseat has no `builtin` backend so `seatd-launch` is required —
the smoke helper does this and also `unset WAYLAND_DISPLAY` to force the DRM backend), DRM open,
DSI-1 @ native mode, Turnip selected, **DRM format modifiers supported**, `vkcube` swapchain
created through the **Gamescope WSI** on Turnip, and the **first atomic (modeset) commit presents
one frame** (kernel: `dpu_plane_atomic_update … XR24 … ubwc 0`, `dpu_crtc_frame_event_work …
event:1`). So the whole Turnip↔gamescope↔panel path is sound for a single modeset commit.

RULED OUT as the blocker (tested on HW):
- **Buffer format/modifier** — the first frame scanned out a plain LINEAR XR24 buffer fine; no
  `Cannot import FB to DRM` / `AddFB2 … failed`.
- **Plane scaling** — fails identically with `--disable-layers` + `GAMESCOPE_COMPOSITE_FORCE=1`
  (full-res 1:1 composited buffer, no plane scaling).
- **Async / immediate flips** — `--immediate-flips` is opt-in (never passed); also tried
  `GAMESCOPE_DISABLE_ASYNC_FLIPS=1`.
- **Explicit sync** — disabled via startup Lua convar
  (`/etc/gamescope/scripts/*.lua: gamescope.convars.drm_debug_disable_explicit_sync.value = true`;
  the `Using explicit sync when available` log line disappears, confirming it took) — flips still
  EINVAL.

### OPEN BLOCKER (1e): msm DPU rejects gamescope's steady-state atomic page-flips
First blocking modeset commit succeeds; every subsequent **non-blocking, plane-only** atomic flip
returns `EINVAL` *before* the DPU's `atomic_check` (no kernel driver log → rejected in DRM core /
the atomic ioctl). gamescope's modeset-retry also fails "entirely". Net: one frame, then frozen.

Investigation backlog (resume here — do offline/cheaply, not interactive roulette):
1. **Isolate gamescope vs kernel**: drive a non-blocking atomic page-flip with `modetest` (libdrm,
   `modetest -P` / `-v`) on DSI-1. If `modetest` page-flips work, it's gamescope's request; if it
   also EINVALs, it's the msm DPU/panel (likely **command-mode DSI** non-blocking-flip handling).
2. **Capture the failing flip**: `echo 0x14 > /sys/module/drm/parameters/debug` (KMS+ATOMIC) and
   `strace -f -e trace=ioctl` around `DRM_IOCTL_MODE_ATOMIC` to see the exact flags/props on the
   commit that returns EINVAL (the first capture only caught the *working* modeset).
3. **Suspect: `DRM_MODE_ATOMIC_NONBLOCK` + OUT_FENCE / vblank event** on this msm DPU; or a CRTC
   property gamescope sets only on flips. Check msm DPU `atomic_check`/`atomic_async_check` support
   for plane-only nonblocking commits on the Pocket S2 panel; look for upstream msm patches.
4. If kernel-side: pin/patch the kernel; if gamescope-side: a convar/flag or a small gamescope
   patch. Either way this is the Phase-2 "gamescope needs DPU features that may be absent" risk
   realized — fix or document as the layer-B gate.

Note: the `/etc/gamescope/scripts/*.lua` explicit-sync convar is NOT a fix (ruled out) — do not
bake it into the image.

## Step 2 — gamescope session (Deck UI shell) [NOT STARTED]
Once bare gamescope renders, layer the Steam **gamescope-session** so the device boots into
Big Picture / Deck UI rather than a hand-run client. Native arm64 Steam shell lands in Phase 3;
Step 2 here is the *session plumbing* (compositor + session unit), not the Steam client.

## Step 3 — novadeck Qualcomm HW-support (layer C) [NOT STARTED]
Port/replace `jupiter-hw-support` + `steamos-manager` affordances onto Qualcomm backings per the
layer-C matrix in `.claude/plans/novadeck.plan.md`:

| Deck-UI affordance | Qualcomm backing | Notes |
|---|---|---|
| TDP / power slider | cpufreq + GPU devfreq | no 1:1 TDP — shim maps slider → clocks/thermal |
| Refresh-rate / VRR | Turnip + DSI panel modes | VRR likely a gap; stub honestly |
| Suspend / resume | Qualcomm s2idle | **top HW risk after GPU** — validate early on HW |
| Brightness | SY7758 backlight (kernel patch 0060) | driver in tree |
| Gyro / rotation | IIO (libiio) | Pocket S2 is portrait-native — Deck-style rotation handling |
| Battery / charge | fuel-gauge + UPower | |
| First-boot OOBE | steamos-oobe (adapt) | SteamOS owns first-boot networking |

## Validate (Phase-2 exit, per plan)
gamescope session launches on SM8650; Deck UI renders; Quick Access + suspend reach the
layer-C affordances that have a Qualcomm backing (the rest documented as stubbed).

_Phase 2 scaffold._
