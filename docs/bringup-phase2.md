# SM8650 bring-up checklist (Phase 2 — SteamOS layer)

Phase 1 cleared the hardware gate (Turnip Vulkan presenting to KMS; see `bringup.md`).
Phase 2 stacks the **SteamOS experience layers** on the working base:

- **Layer B** — gamescope session + Deck UI (boot → Big Picture, Quick Access, OSK/OSD).
- **Layer C** — `jupiter-*` hardware support, replaced by a novadeck **Qualcomm HW-support**
  package backing the layer-C affordance matrix (TDP/refresh/suspend/brightness/gyro/battery)
  with cpufreq/devfreq/IIO/UPower/backlight, honestly stubbed where no Qualcomm equivalent exists.

Phase 2 is **not** a hard go/no-go gate (that is Phase 3). The mandate: **de-risk first** — prove
bare gamescope on Turnip before the jupiter-* porting work, isolating the Turnip↔gamescope
Vulkan-feature question from the port.

**Status: Phase-2 exit criteria met** (compositor + layer-C affordances HW-validated 2026-06-26;
see the exit sweep at the end). The Steam shell and audio L4 carry into Phase 3.

## Step 1 — Bare gamescope on Turnip (the de-risk) [DONE]

The Phase-1 gate proved the **direct** present path (`vkcube --wsi display`, `VK_KHR_display`, no
compositor). gamescope adds a **Wayland compositor**: it owns KMS via the DRM backend and clients
render into its Wayland display. Step 1 proved Turnip's Wayland WSI + the modifiers/present features
gamescope needs are all present on Adreno 750.

| # | Check | Status |
|---|---|---|
| 1a | gamescope + seatd in base | ✅ `extra/aarch64` (gamescope overlay build, seatd 0.9.1) |
| 1b | gamescope opens DRM/KMS | ✅ seat via `seatd-launch` (libseat has no `builtin` backend); opens `/dev/dri/card0`, DSI-1 @ native `1440x2560@60`, first modeset commit scans out a frame |
| 1c | Vulkan client renders under gamescope | ✅ patched gamescope + `--use-rotation-shader` → vkcube animates upright-landscape on panel |
| 1d | Input reaches the client | ✅ gamescope passes the InputPlumber virtual DualSense through to its hosted child (does NOT EVIOCGRAB the pad) — the path the Phase-3 Steam shell needs |
| 1e | Per-frame atomic flip | ✅ rotation fixed (composite shader); re-launch freeze characterized — WSI kept **ON** (release launches once), see below |

**How to run** (TEST build, SSH in, watch the panel): `nova-gamescope-smoke [client]` — gamescope
`--backend drm --use-rotation-shader -- vkcube` (or a swapped nested client). Ships **test-only**
(`images/assemble-rootfs.sh` under `NOVADECK_TEST=1`), hand-launched, not a systemd unit, so it
never seizes the panel from the bring-up path. gamescope + seatd themselves are in the **release**
set (layer-B runtime, not test tooling).

### Resolved 1e (a): rotation flip EINVAL → patched gamescope (composite rotation)

> **Superseded (in-tree, HW-validation pending):** the ROCKNIX `--use-rotation-shader` patch below
> was replaced by upstream gamescope PR #2228 (composite-rotation pass). The shipped launcher now
> passes **no** rotation flag — gamescope auto-engages compositor rotation off the DRM connector
> panel orientation (DTS `rotation=<90>`). See TODO.md and
> `packages/gamescope/patches/0001-composite-rotation-pr2228.patch`. The historical account of the
> original fix follows.
The Pocket S2 panel (`sm8650-ayaneo-ps2.dts`, `compatible="ayaneo,wt0630-2k"`) declares
`rotation = <90>`, published as the connector `panel orientation`. gamescope applied a compensating
**90° plane rotation**; msm `dpu_plane.c` only advertises `ROTATE_0|180|REFLECT_*` on a normal pipe
(90/270 needs an inline-rotation pipe + UBWC-tiled format), so on a **LINEAR** buffer drm core
rejects `ROTATE_90` before the driver `atomic_check` → EINVAL every flip. (The first modeset frame
survived because it didn't carry the rotated client plane; Phase-1 direct present is `ROTATE_0`.)

A portrait panel in a landscape chassis needs the 90° transform *somewhere*, and the DPU can't do it
for LINEAR buffers — so it's done in gamescope's **GPU composite** (scanning out a `ROTATE_0`
buffer) via a rotation-shader patch (from ROCKNIX), opt-in with `--use-rotation-shader`. Ships as a
from-source overlay package (`packages/gamescope/`, see `packages/README.md`); the overlay repo is
inserted ahead of the holo repos so the patched build wins. `novadeck-session` +
`nova-gamescope-smoke` pass the flag.

### 1e (b): re-launch freeze — characterized; WSI kept ON
A steady session intermittently wedged: the client (`vkcube`) blocks forever in
`drm_syncobj_array_wait_timeout` on a **never-signaling explicit-sync fence** in gamescope's WSI
`linux-drm-syncobj` present path, while `gamescope-kms` idles in `ppoll` — a userspace fence
deadlock (the gamescope explicit-sync regression class, `linux_drm_syncobj` added in v3.15).

**It is a re-launch artefact, not a fresh-boot race:** a true first-gamescope-since-power-on (L1) is
clean (10/10); only a re-launch after a prior instance (L2) wedges (~50%). dmesg shows zero GPU
faults/hangcheck/recovery/syncobj-timeout across all trials, so it is **not** stale GPU or DRM-master
state — and a clean teardown does **not** prevent it (graceful SIGTERM re-launch wedges the same
~50% as SIGKILL).

**Decision: keep `ENABLE_GAMESCOPE_WSI=1`** (the upstream + ChimeraOS `gamescope-session-plus`
default — see their [`gamescope-session-plus`](https://github.com/ChimeraOS/gamescope-session/blob/73d2da8/usr/share/gamescope-session-plus/gamescope-session-plus#L51)),
set in `fs-overlay/usr/bin/novadeck-session` + the smoke helper (env-overridable, defaults on). The FROG
WSI layer is the **standard present path** — framerate limiter / frame pacing, latency control,
adaptive-sync hints AND HDR — so disabling it is **not** just an HDR loss; it degrades all of those.
Since the release product boots gamescope **once per power-on** (the clean L1 case), the re-launch
wedge should not bite in normal use.

**Residual risk (OPEN):** the session unit's `Restart=on-failure`, or any deliberate session restart,
takes the L2 re-launch path and may wedge. If that proves a real problem in the field, the fallback is
`ENABLE_GAMESCOPE_WSI=0` (implicit sync → 8/8 clean re-launch) at the cost of the WSI features above,
or a genuine teardown/explicit-sync fix upstream. (A `--ready-fd` ready-then-launch handshake — run
gamescope bare, launch the client only once it signals ready — was prototyped but never proven to
reliably dodge the wedge.)

**Dead ends (do not retry):** `--immediate-flips` is KMS-unsupported on msm (no
`DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP`) and never the fix; the `/etc/gamescope/scripts/*.lua`
`drm_debug_disable_explicit_sync` convar toggles a different (KMS-side) layer and is not a fix; a
Turnip/Mesa version bump does not fix the freeze (reproduced on newer Mesa than ROCKNIX). gamescope
was bumped to 3.16.23.2 as a local-PKGBUILD overlay for newer-Turnip/ROCKNIX parity (it roughly
halves but does not fix the wedge alone). For liveness probing without perturbing the display, see the GPU-liveness method
(client `drm-engine-gpu` fdinfo delta + crtc framecount; never poll `/sys/kernel/debug/dri/0/gpu`).

## Step 2 — gamescope session (Deck UI shell) [DONE]
Turns the hand-run smoke into **session plumbing**: a long-running gamescope compositor started by a
systemd unit. Native arm64 Steam lands in Phase 3 — Step 2 is the *compositor + session unit*, not
the Steam client.

### Plumbing — `session/` overlay tree
A static, SoC-agnostic overlay mirror-copied into the rootfs by `images/assemble-rootfs.sh`:

| File | Role |
|---|---|
| `/usr/bin/novadeck-session` | launcher: `seatd-launch` + env (`ENABLE_GAMESCOPE_WSI=1`, default) + patched gamescope (`--backend drm`; rotation auto-detected from the connector orientation) → runs `$NOVADECK_SESSION_CMD` |
| `/etc/novadeck/session.conf` | single config point — `NOVADECK_SESSION_CMD` (Phase-2 placeholder `vkcube`; Phase-3 → `steam -gamepadui …`), `NOVADECK_GAMESCOPE_EXTRA` |
| `/usr/lib/systemd/system/novadeck-session.service` | `Conflicts=getty@tty1`, `After=inputplumber`, `Restart=on-failure` |

**Design:** runs as **root via seatd-launch** (the `deck`-user/logind-seat model is a later
hardening concern); ships **installed-but-DISABLED** (no preset/`.wants`) so it never seizes the
panel during bring-up — boot-enable is a one-line preset add + default target → `graphical.target`,
deferred until the Phase-3 Steam shell lands; no new packages.

### Two unit bugs found + fixed (a system service is NOT an interactive SSH run)
1. **Do NOT bind the unit to a VT.** `TTYPath=/dev/tty1` + `StandardInput=tty` made gamescope exit 0
   at boot — seatd's VT-bound seat activates a VT itself and the binding clashed. Fix:
   `StandardInput=null`, no `TTY*` (keep `Conflicts=getty@tty1`). Test cheaply with
   `systemd-run -p StandardInput=null /usr/bin/novadeck-session`.
2. **`seatd-launch` leaks `/run/seatd.sock`** on unclean exit → next start fails "Socket file found
   … refusing to start" (fatal under `Restart=on-failure`). The launcher clears a stale socket
   (when no seatd is running) before launch.

Result: `novadeck-session` renders the placeholder upright-landscape under systemd, byte-identical
gamescope line to the smoke. Input (step 1d) reaches the hosted client.

## Step 3 — novadeck Qualcomm HW-support (layer C) [DONE]
Port/replace `jupiter-hw-support` + `steamos-manager` affordances onto Qualcomm backings per the
layer-C matrix in `.claude/plans/novadeck.plan.md`. Backings ship as a static, SoC-agnostic overlay
under `fs-overlay/`, mirror-copied into the rootfs by `images/assemble-rootfs.sh`.

| Deck-UI affordance | Qualcomm backing | Notes |
|---|---|---|
| TDP / power slider | cpufreq + GPU devfreq | no 1:1 TDP — shim maps slider → clocks/thermal |
| Refresh-rate / VRR | Turnip + DSI panel modes | VRR likely a gap; stub honestly |
| Suspend / resume | **userspace freeze** (below) | real s2idle out of scope on these SoCs |
| Brightness | SY7758 backlight (kernel patch 0060) | driver in tree |
| Gyro / rotation | IIO (libiio) | Pocket S2 is portrait-native |
| Battery / charge | fuel-gauge + UPower | |
| First-boot OOBE | steamos-oobe (adapt) | SteamOS owns first-boot networking |

### Suspend = userspace freeze + power-key wake [HW-validated]
Kernel s2idle is immature on these SoCs and out of scope; suspend is a **reversible userspace
freeze** that stops the *game*, not just the screen.

- **`novadeck-suspend`** — freezes all userland via the cgroup v2 freezer (direct write to
  `/sys/fs/cgroup/{system,user}.slice/cgroup.freeze`), so the game halts; resume thaws and runs
  `/etc/novadeck/resume.d/*` (generic hook point), with a safety auto-thaw. Power-ops
  (cpu-offline, rfkill, cpu+gpu powersave governor) live in the shared `usr/lib/novadeck/power-ops.sh`
  (`power_enter`/`power_leave`, guarded by `NOVADECK_SUSPEND_SKIP`), applied AFTER the freeze and
  restored BEFORE the thaw (pure sysfs, safe while frozen).
- **`novadeck-waked`** — the wake agent: `libinput debug-events --device event0` (pmic_pwrkey) times
  the key. Short **tap** → `novadeck-suspend toggle`; **hold ≥ `NOVADECK_WAKE_LONGPRESS_MS`** (default
  2000ms) → thaw-then-`systemctl poweroff`. Runs in a top-level **`novadeck-wake.slice`** (sibling of
  system.slice) so it is never frozen and can thaw the system. **Enabled at boot** via the overlay.
- logind `HandlePowerKey=ignore` + `HandlePowerKeyLongPress=ignore` drop-in (needs a full logind
  restart to apply). Press tiers: tap = suspend/resume, ~2s hold = clean poweroff, ~8s+ = PMIC
  hardware reset (below us). The power key is a software `KEY_POWER`, interceptable; an open fd is not
  a grab, so the agent reads it while gamescope/seatd also hold it.

**Two ordering/timing rules that bit and were fixed:**
- **Never call systemctl/D-Bus while frozen — thaw (`freeze 0`) first.** The system D-Bus daemon is
  in the frozen `system.slice`, so a pre-thaw `systemctl` blocks ~90s and the device looks dead.
  `do_resume` thaws first, then systemctl; power-restore stays pre-thaw (pure sysfs). Resume ~2-3s.
- **Blank the panel before freezing gamescope.** gamescope applies the `drm_sleep` convar on its own
  main loop (~324ms after `gamescopectl` returns); freezing it back-to-back trapped it mid-apply and
  the panel stayed lit. `do_suspend` polls the connector `enabled` sysfs attr (`wait_panel disabled`)
  and freezes only after the blank confirms. `gamescopectl` is reached via the
  `usr/lib/novadeck/gamescope-display.sh` resolver, which finds the live `gamescope-N` slot by its
  lock fd (gamescope binds the first free slot, so the control socket isn't always `gamescope-0`).

`novadeck-rest` is the older dev/bring-up rest-mode tool (lowers power WITHOUT the freeze, stays
SSH-reachable), superseded by `novadeck-suspend` as the suspend affordance.

## Validate (Phase-2 exit, per plan)
gamescope session launches on SM8650; Quick Access + suspend reach the layer-C affordances that have
a Qualcomm backing (the rest documented as stubbed). ("Deck UI renders" = Phase-3 Steam shell.)

### ✅ Exit sweep — HW-validated 2026-06-26 (kernel 7.0.11, Holo build 240949)

- **gamescope session launches + scans out** — `systemctl start novadeck-session` brought up
  `gamescope --backend drm -W 2560 -H 1440 -r 60 --prefer-output DSI-1 -- vkcube`  (rotation auto-detected)
  via `seatd-launch`. DSI-1 `connected + enabled`; crtc-0 `total_framecount` advanced over 2s at
  59–60 fps (native 60 Hz scanout); the vkcube client drove the GPU (`drm-engine-gpu` advancing on
  its render fd). Clean `systemctl stop` left no gamescope/seatd-launch residue.
- **Layer-C affordances reaching their Qualcomm backing (all active):** `novadeck-waked` (power-key
  wake agent, enabled+active; logind drop-in + `power-ops.sh` present), `bluetooth` (adapter up),
  `NetworkManager`, `systemd-timesyncd` (NTP synced). Suspend/resume itself was **not** re-run in
  this sweep — already HW-validated in prior sessions, and `novadeck-suspend` must run from
  `novadeck-wake.slice`, not an SSH shell (which lives in the frozen `user.slice`), so re-testing it
  headless without the physical power key would strand the device.
- **Out of scope (Phase 3):** the native arm64 Steam shell, and audio L4 (PipeWire start + HW play),
  deferred to the user-session bring-up.
