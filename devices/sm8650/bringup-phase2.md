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

**On-HW result:** `--use-rotation-shader` rotates correctly → **upright landscape**. (Plain
`--force-orientation normal` spins fine but sideways.)

**FOLLOW-UP (not blocking the plumbing; blocks a *steady* session) — REVISED 2026-06-22:** the
composite-flip path **freezes after the first frame intermittently**: same command + build, it
sometimes animates and sometimes stalls (a race on the command-mode-DSI page-flip completion / next
composite-flip re-arm; the direct-scanout path always paces fine). NOTE the earlier belief that
`--immediate-flips` deterministically fixes this was **wrong** — gamescope logs
`drm: Immediate flips are not supported by the KMS driver` on every run, so the async-flip flag is
*rejected* by this msm DPU and never actually applied. Real fix needs investigating the composite
path's flip-done/vblank handling on this DPU (vs the working direct path), not the flag.

Note: the `/etc/gamescope/scripts/*.lua` explicit-sync convar is NOT a fix (ruled out) — do not
bake it into the image.

## Step 2 — gamescope session (Deck UI shell) [IN PROGRESS]
Step 1 proved bare gamescope renders a client through Turnip's Wayland WSI when run **by hand**
(`nova-gamescope-smoke`). Step 2 turns that into the **session plumbing**: a long-running gamescope
compositor started by a **systemd unit**, so the device boots into the Deck-UI shell rather than a
hand-run client. Native arm64 Steam lands in Phase 3 — Step 2 is the *compositor + session unit*,
not the Steam client.

### Plumbing (landed) — `session/` overlay tree
A static, SoC-agnostic overlay (`session/`) mirror-copied into the rootfs by `images/assemble-rootfs.sh`
(release block 4d):

| File | Role |
|---|---|
| `/usr/bin/novadeck-session` | launcher: seat (`seatd-launch`) + env + patched gamescope (`--backend drm --use-rotation-shader --immediate-flips`, the HW-validated combo) → runs `$NOVADECK_SESSION_CMD` |
| `/etc/novadeck/session.conf` | single config point — `NOVADECK_SESSION_CMD` (Phase-2 placeholder `vkcube`; Phase-3 → `steam -gamepadui …`), `NOVADECK_GAMESCOPE_EXTRA` |
| `/usr/lib/systemd/system/novadeck-session.service` | boots the compositor on VT1 (`Conflicts=getty@tty1`, `After=inputplumber`), `Restart=on-failure` |

**Design choices (Phase-2):**
- **Runs as root via `seatd-launch`** — identical seat + rotation path Step 1 validated; the SteamOS
  `deck` user / logind-seat model is a Phase-4 hardening concern, not session de-risk.
- **Shipped installed-but-DISABLED** (no preset, no `.wants` symlink). Validate on HW by hand first —
  `systemctl start novadeck-session` — so it never seizes the panel from the SSH/`nova-gamescope-smoke`
  bring-up path, and because the `--immediate-flips` vsync follow-up (step 1e) is still open. Flipping
  to boot-enabled is a one-line preset add (`enable novadeck-session.service` in a release preset, plus
  switching the default target to `graphical.target`) once proven + Steam lands.
- **No new packages** — gamescope/seatd/vulkan-tools (vkcube) already in the release set.

### Validate (on HW, 2026-06-22) — plumbing ✅, two unit bugs found + fixed
Running the unit at boot first **failed**: gamescope started then exited 0 right after `scriptmgr`.
Bisected by running the launcher by hand (worked) → it was the **systemd unit context**, two bugs:

1. **VT binding (FIXED).** The first unit bound the service to VT1 (`TTYPath=/dev/tty1` +
   `StandardInput=tty`). seatd's VT-bound seat activates a VT itself; forcing the service onto tty1
   clashed with that and gamescope bailed instantly. The working manual run / `nova-gamescope-smoke`
   have **no controlling VT**. Fix: unit uses `StandardInput=null`, **no `TTYPath`/`TTY*`** — let
   seatd own the VT (`Conflicts=getty@tty1` still keeps a getty off the panel). Confirmed via
   `systemd-run -p StandardInput=null /usr/bin/novadeck-session` → renders upright.
2. **`seatd-launch` socket leak (FIXED).** An unclean exit leaves `/run/seatd.sock`, so the next
   `seatd-launch` refuses to start (`Socket file found … refusing to start`) — fatal under
   `Restart=on-failure`. Fix: the launcher clears a stale socket (when no seatd is running) before
   launch.

**Result:** `novadeck-session` renders the placeholder (`vkcube`) **upright-landscape** under
systemd — the byte-identical gamescope line to the smoke. Plumbing is sound.

**Still open (NOT a Step-2 bug):** the composite-flip **freeze is intermittent** — same command, same
build, sometimes animates, sometimes stalls on the first frame. And gamescope logs
`drm: Immediate flips are not supported by the KMS driver` on **every** run, so `--immediate-flips`
is *rejected* by this msm DPU and is **not** the deterministic fix step 1e believed — we are racing
the vsync'd composite-flip / page-flip-completion on the command-mode DSI either way. This is the
step-1e display follow-up, now reproduced; it gates a *usable* session (not the plumbing).

### Remaining ☐
- Chase the intermittent composite-flip freeze (vblank / page-flip-done re-arm on the command-mode
  DSI; the direct-scanout path paces fine) — the real blocker for a steady session.
- InputPlumber gamepad reaches the client inside the session (ties off step 1d).
- Boot-enable (preset + default target → `graphical.target`) — deferred until the freeze is solved
  and the Phase-3 Steam shell lands.

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
