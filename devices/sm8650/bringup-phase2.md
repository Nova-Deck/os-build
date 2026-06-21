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
| 1c | Vulkan client renders under gamescope | default client `vkcube` → gamescope Wayland → Turnip WSI; cube on panel | ✅ **CLOSED (HW 2026-06-21)**: patched gamescope + `--use-rotation-shader --immediate-flips` → vkcube animates **upright landscape** on panel |
| 1d | Input reaches the client | InputPlumber virtual gamepad (Phase-1 green) seen inside gamescope via libinput | ☐ next |
| 1e | **Per-frame atomic flip** | steady-state plane-only flips to DSI-1 | ✅ **CLOSED (HW)**. Cause = gamescope's compensating **90° plane rotation** on a LINEAR buffer; msm DPU rejects `ROTATE_90` except on inline-rotation pipes w/ UBWC. Fix: patched gamescope (`3.16.17-1.1`, from-source overlay `packages/gamescope`) rotates in **GPU composite** via `--use-rotation-shader`, scanning out `ROTATE_0`. The composite-flip path stalls on this panel's vsync'd page-flip completion, so `--immediate-flips` is required for continuous frames (see follow-up below). |

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

### RESOLVED (1e): root cause = panel `rotation = <90>` → gamescope plane `ROTATE_90` the DPU can't do
**Confirmed on HW 2026-06-21.** `seatd-launch -- gamescope --backend drm --force-orientation normal
-- vkcube` → vkcube animates steady-state (cube spins, displayed sideways). The earlier EINVAL was
**not** a generic nonblocking-flip / command-mode-DSI problem — it was rotation:

- The Pocket S2 panel node (`arch/arm64/boot/dts/qcom/sm8650-ayaneo-ps2.dts:59`,
  `compatible = "ayaneo,wt0630-2k"`) declares `rotation = <90>`. The panel driver publishes that as
  the connector **`panel orientation`** property.
- gamescope reads it and applies a compensating **90° plane rotation** on every steady-state flip to
  present upright landscape.
- `dpu_plane.c` advertises only `ROTATE_0 | ROTATE_180 | REFLECT_*` on a normal pipe (line ~1797);
  `ROTATE_90/270` exists **only** on inline-rotation pipes and **only** for a UBWC-tiled format list
  (`dpu_plane_check_inline_rotation`, line ~693). gamescope's buffer is **LINEAR** → `ROTATE_90` is
  an unsupported rotation value → **drm core rejects it before the driver `atomic_check`** (hence no
  DPU log) → EINVAL on every flip. First modeset frame survived because it didn't carry the rotated
  client plane; Phase-1 `vkcube --wsi display` worked because direct present is `ROTATE_0`.

So the Turnip↔gamescope↔DPU path is sound. `--force-orientation normal` is the de-risk unblock (but
the image is sideways — portrait panel, no compensation).

### FIX (CLOSED on HW 2026-06-21): landscape-upright via a gamescope composite-rotation patch
A portrait panel in a landscape chassis needs a 90° transform *somewhere*, and the msm DPU plane
cannot do it for our LINEAR buffers — so the rotation is done in gamescope's **GPU composite** step
(scanning out a `ROTATE_0` buffer) via a rotation-shader patch (from ROCKNIX). It is **opt-in**:
`gamescope --use-rotation-shader` (the flag the patch adds).

Because that is a gamescope **code** change, it ships as the first **from-source overlay package**
(`packages/gamescope/source.pin` + `patches/0001-rotate-portrait-panel-in-composite.patch`):
`make overlay` rebuilds the holo gamescope PKGBUILD with the patch (pkgrel `3.16.17-1.1`) into the
local pacman repo `work/repo/aarch64/`, and `customize-base.sh` inserts that repo **ahead** of the
holo repos so the patched build is installed (verified: base carries `gamescope-3.16.17-1.1`). See
`packages/README.md` for the mechanism. The `nova-gamescope-smoke` helper now launches with
`--use-rotation-shader --immediate-flips`.

**On-HW result:** `--use-rotation-shader` alone presented one upright frame then froze; adding
`--immediate-flips` gives continuous upright-landscape animation. (Plain `--force-orientation normal`
spins fine but sideways.)

**FOLLOW-UP (not blocking layer-B):** the shader composite-flip path freezes after the first frame
under vsync'd flips and needs `--immediate-flips` — i.e. the panel's vsync'd page-flip completion
isn't re-arming the next composite flip (the old command-mode-DSI vblank suspicion, now scoped to
the composite path; the direct-scanout path paces fine). `--immediate-flips` means no vsync / possible
tearing, so revisit before the real Deck-UI session: investigate the composite-path flip-done/vblank
handling on this msm DPU (vs the direct path that works).

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
