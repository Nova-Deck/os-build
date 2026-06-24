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
| 1c | Vulkan client renders under gamescope | default client `vkcube` → gamescope Wayland → Turnip WSI; cube on panel | ✅ **CLOSED (HW 2026-06-21)**: patched gamescope + `--use-rotation-shader` → vkcube animates **upright landscape** on panel |
| 1d | Input reaches the client | InputPlumber virtual gamepad (Phase-1 green) seen inside gamescope via libinput | ✅ **CLOSED (HW 2026-06-23)**: `gamescope --backend drm --use-rotation-shader -- evtest /dev/input/event7` — gamescope's hosted child reads the **InputPlumber virtual DualSense** (event7) while gamescope owns the seat/libinput. Physical presses landed: 33 `EV_KEY` (BTN_SOUTH/EAST/WEST/NORTH, BTN_TL/TR) + 103 `EV_ABS` (sticks/triggers) in a 30 s window. gamescope does **not** exclusively grab the pad — it passes through to the client, the exact path the Phase-3 Steam shell needs. |
| 1e | **Per-frame atomic flip** | steady-state plane-only flips to DSI-1 | ✅ **rotation CLOSED; freeze CHARACTERIZED — re-launch/teardown contamination, NOT a fresh-boot race**. (a) gamescope's compensating **90° plane rotation** on a LINEAR buffer — msm DPU rejects `ROTATE_90` except on inline-rotation pipes w/ UBWC — fixed by patched gamescope (`3.16.23.2-1.1`, from-source overlay `packages/gamescope`) rotating in **GPU composite** via `--use-rotation-shader` (`ROTATE_0` scanout). (b) the "cold-start composite-flip freeze" is **a re-launch artefact**: the decisive 10-reboot experiment (session 3) shows the original WSI-on model spins **10/10 on a true power-on** (L1) and only wedges on **re-launch after a prior instance** (L2, 7/10) — a killed instance leaves stale explicit-sync syncobj/GPU state that wedges the next WSI client. So it is a non-issue at real boot; `ENABLE_GAMESCOPE_WSI=0` masks the restart-path wedge but the proper fix is clean teardown. `--immediate-flips` is a no-op here and was never the fix. (see DECISIVE EXPERIMENT below.) |

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
`make overlay` rebuilds the holo gamescope PKGBUILD with the patch (originally pkgrel `3.16.17-1.1`,
later bumped to `3.16.23.2-1` — see the version-bump update below) into the local pacman repo
`work/repo/aarch64/`, and `customize-base.sh` inserts that repo **ahead** of the holo repos so the
patched build is installed (verified: base carries the patched `gamescope` overlay build, now
`3.16.23.2-1`). See
`packages/README.md` for the mechanism. The `nova-gamescope-smoke` helper now launches with
`--use-rotation-shader` (`--immediate-flips` was dropped — see the no-op finding in the follow-up below).

**On-HW result:** `--use-rotation-shader` rotates correctly → **upright landscape**. (Plain
`--force-orientation normal` spins fine but sideways.)

**FOLLOW-UP (not blocking the plumbing; blocks a *steady* session) — REVISED 2026-06-22:** the
composite-flip path **freezes after the first frame intermittently**: same command + build, it
sometimes animates and sometimes stalls on frame 1, while the direct-scanout path (`vkcube --wsi
display`) always paces fine.

Two earlier beliefs about this were **wrong** and are corrected here:

1. **`--immediate-flips` is NOT a fix — it is a no-op on this HW.** gamescope logs `drm: Immediate
   flips are not supported by the KMS driver` on *every* run because the msm DPU does not advertise
   `DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP` (`DRMBackend.cpp:1253` sets `g_bSupportsAsyncFlips=false`).
   `--immediate-flips` only sets `cv_tearing_enabled`, and the async flag is gated by
   `bTearing = cv_tearing_enabled && SupportsTearing() && …` (`steamcompmgr.cpp:8505`), where
   `SupportsTearing()` returns `g_bSupportsAsyncFlips` — so `DRM_MODE_PAGE_FLIP_ASYNC` is never set.
   ROCKNIX runs this same patched gamescope on this panel **without** the flag. It has been dropped
   from the launcher and smoke helper.
2. **This is NOT a command-mode-DSI re-arm problem — the panel is video-mode.** The `wt0630-2k`
   panel (`kernel/sm8650/patches/0062`) declares `MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST |
   MIPI_DSI_CLOCK_NON_CONTINUOUS | MIPI_DSI_MODE_LPM`. A video-mode panel scans out continuously;
   vblank/page-flip-done come from the DPU's own timing, not a panel TE signal. So the freeze is
   not a TE/command-mode quirk.

What is actually different between the working and stalling paths: the rotation shader forces a
**full GPU composite every frame** (`bNeedsFullComposite |= rotationShaderOrientation != 0` in the
patch), so gamescope renders to its own buffer and flips *that*, whereas the direct path scans out
the client buffer with no composite. The freeze is therefore in the **composite → fence → atomic
flip → wait-for-flip-done** loop on the vsync'd path. Leading hypothesis: a lost/!armed vblank on
the **first** atomic flip after the modeset (a known msm pattern — vblank IRQ not yet enabled when
the first post-modeset flip is queued, so flip-done never fires and gamescope blocks). "Intermittent
on frame 1" fits this.

**HW RESULTS — measured on device 2026-06-22 (192.168.1.240, fresh card, `--immediate-flips`
dropped). ROOT CAUSE (supersedes the two wrong calls below): the freeze is a Gamescope WSI
swapchain present stall.** The swapchain is *created* on every run, but on a frozen run it **never
receives its first refresh cycle** — the present / frame-callback loop never starts, so no frames
are ever presented and the panel stays on its prior content. This lives in the gamescope WSI ↔
Turnip Wayland-WSI present path; the `vk_khr_present_wait` override seen in the log is the prime
suspect. DPU/vblank, seat activation, DRM-master/`EACCES`, `--immediate-flips`, and `vblankoffdelay`
are **all ruled out.**

**The discriminator (perfect across the clean baseline batch, 5/5):** the gamescope log line
`[Gamescope WSI] Swapchain received new refresh cycle: 16.67ms` is present on **every** spinning run
and **absent** on **every** frozen run. `Created swapchain for xid` appears on *all* runs, so it is
swapchain *creation* that succeeds and the *refresh-cycle start* that intermittently never happens.
Up to the missing line, frozen and healthy logs are otherwise identical (seat opened, `Enabling
seat`, DRM node opened, `DSI-1`, mode `1440x2560`, Xwayland up, swapchain created).

**Two earlier HW diagnoses were WRONG — recorded here so the mistakes aren't repeated:**
- Commit `0d6114c` — "silent msm DPU timing-engine stall." Wrong. The kernel was silent because
  gamescope never presents a frame, not because the DPU stalls. `drm.vblankoffdelay=0` was noise.
- Commit `b271a82` — "DRM-master / seat-activation race (`EACCES`)." Wrong: it over-fit a single
  teardown `Permission denied`. A 5-run baseline froze 2/5 with **`EACCES=0`**, and forcing an active
  VT via `chvt` made it **worse** (5/5 frozen) — so seat activation is not the cause. Both runs reach
  `Enabling seat` and open DRM fine.
- The **IRQ-198 oracle** (`/proc/interrupts` `msm`: ~48–60/s spin vs ~1–3/s frozen) is a valid
  *symptom* detector and matched the operator 1:1 — but the flatline is a consequence (no frames
  presented), not a cause. (Session 2 caveat: it cannot distinguish a genuinely-spinning cube from
  gamescope re-flipping a static composite — use the client `drm-engine-gpu` oracle for that; see the
  session-2 update.) Dropping `--immediate-flips` remains confirmed regression-free.

### MITIGATED (1e cold-start freeze, root cause OPEN): gamescope WSI explicit-sync (`linux-drm-syncobj`) deadlock → `ENABLE_GAMESCOPE_WSI=0`
> **Status note (session 2):** this block confirmed the *mechanism* (a syncobj fence never signals) but
> NOT the *trigger*. It is superseded by the METHODOLOGY HOLE + DECISIVE EXPERIMENT below — the root
> cause is **OPEN** (every measurement was a re-launch, never a true reboot) and `ENABLE_GAMESCOPE_WSI=0`
> is a **mitigation**, not a confirmed fix.
**Confirmed on HW 2026-06-23 (SM8650, Mesa 26.1.3 overlay, gamescope 3.16.17-1.1).** The earlier
"WSI swapchain never receives its first refresh cycle" framing was a symptom, and the `received new
refresh cycle` log line is NOT a reliable discriminator under 26.1.3 (wedged sessions log it too).
The real failure is a **fence deadlock**, caught by inspecting a live-wedged session's thread stacks:

- **`vkcube` main thread blocks indefinitely in `drm_syncobj_array_wait_timeout`** — waiting on a DRM
  syncobj (explicit-sync timeline) that never signals. `gamescope-kms` sits idle in `ppoll`, never
  flipping; the whole pipeline is flat (crtc + both clients' `drm-engine-gpu` deltas 0, msm IRQ-198
  flatlines). It persists indefinitely (not a transient frame-1 hiccup).
- **Root cause:** the **gamescope WSI Vulkan layer** routes the client swapchain through gamescope's
  Wayland **explicit-sync (`linux-drm-syncobj`)** present path. On this HW that path intermittently
  never signals the buffer-release/acquire fence on the first frame, so the client wedges acquiring
  its next image. This is the gamescope explicit-sync regression class
  ([ValveSoftware/gamescope#1520](https://github.com/ValveSoftware/gamescope/issues/1520); the
  `linux_drm_syncobj` implementation added in v3.15.0 — our overlay ships 3.16.17).
- **Fix: `ENABLE_GAMESCOPE_WSI=0`** in the session/smoke env. With the layer off the client uses a
  plain Wayland swapchain → **implicit sync** (dma-fence on the buffer), and cold starts stop
  wedging. Baked into `session/usr/bin/novadeck-session` and the `nova-gamescope-smoke` helper.
- **HW-measured A/B (restart-race, 12 cold starts each, IRQ-198 oracle, new-pid + 5 s settle):**
  WSI **on** = **8/12 wedge** (4 PASS); `ENABLE_GAMESCOPE_WSI=0` = **0/12 wedge (12/12 spin)**.
  A spinning session is rock-solid regardless (5-min soak held 60 Hz) — the bug was cold-start only.
- **Trade-off:** disabling the WSI layer loses gamescope's HDR path (not a Phase-2 concern). Revisit
  if/when bumping gamescope past a release that fixes the explicit-sync deadlock.

Note: the `/etc/gamescope/scripts/*.lua` explicit-sync convar (`drm_debug_disable_explicit_sync`)
toggles the **KMS-side** sync, a different layer, and is NOT a fix (ruled out) — do not bake it in.
The `chvt` active-VT route is also NOT a fix (made it worse) — do not pursue. The Mesa 26.1.3 bump
was NOT the fix either (freeze reproduced on it) but is kept (newer Turnip, matches ROCKNIX).

**UPDATE 2026-06-23 — gamescope bumped 3.16.17 → 3.16.23.2 (overlay), root cause refined to a
cold-start RACE, `ENABLE_GAMESCOPE_WSI=0` shipped; `--ready-fd` handshake is the HDR-preserving
follow-up.** Caught by inspecting a live-wedged session's thread stacks: `vkcube` blocks in
`drm_syncobj_array_wait_timeout` (an explicit-sync fence that never signals) while `gamescope-kms`
idles in `ppoll` — a buffer-release fence deadlock, not a vblank stall. It is purely a **cold start**
race (a session that *does* spin is rock-solid; 5-min soak held 60 Hz). HW restart-races (12–24 cold
starts each, IRQ-198 oracle, new-pid + settle):
- gamescope **3.16.17** WSI-on: **8/12 wedge**; **3.16.23.2** WSI-on: **3/12** — the bump roughly
  halves it but does NOT fix it (so it is not purely a gamescope-version bug). The bump is kept
  anyway (newer Turnip-compatible, closer to ROCKNIX) via the local PKGBUILD `packages/gamescope`.
- **`ENABLE_GAMESCOPE_WSI=0`** (disables the gamescope WSI Vulkan layer → client uses implicit sync):
  **0/24** on 3.16.23.2. **This is what ships** (launcher + smoke). Trade-off: no gamescope WSI HDR
  (not a Phase-2 concern). Distinct from the earlier crash gamescope#1520 (fixed pre-3.16.17).
- A blind **0.5 s client delay** (WSI on) also gave **0/24**, confirming the cold-start race — but a
  fixed sleep is fragile (CPU governor/load) so it was rejected.
- **FOLLOW-UP (deferred — the elegant, HDR-preserving fix):** launch the client only after gamescope
  signals readiness via **`--ready-fd`** (run gamescope as a bare compositor, no `-- client`).
  Mechanism learned on HW: `--ready-fd` takes a **PATH** (gamescope `open()`s it `O_WRONLY`,
  `steamcompmgr.cpp`), and gamescope writes one line `"<xdisplay> <wayland-display>\n"` once fully up.
  The client must also export **`GAMESCOPE_WAYLAND_DISPLAY=<wl-display>`** for the WSI layer to engage
  (`main.cpp:1028` / `VkLayer_FROG_gamescope_wsi.cpp:95`) — otherwise the layer stays off and you're
  back to implicit sync (HDR lost). A prototype gave 15/15 with the layer *inactive*; the WSI-*active*
  variant was not cleanly measured (the restart harness restarts faster than the ready-fd startup) —
  finish + validate this in a follow-up before dropping `ENABLE_GAMESCOPE_WSI=0`.

**UPDATE 2026-06-23 (session 2) — ready-fd handshake works on RE-LAUNCHES, but a deeper METHODOLOGY
HOLE was found.** _(Resolved in session 3 — see the DECISIVE EXPERIMENT at the end of this section: the
wedge is teardown/re-launch contamination, fresh boot is 10/10 clean; `ENABLE_GAMESCOPE_WSI=0` stays as
restart-path insurance but is needless at boot.)_ This session built + ran the `--ready-fd` follow-up,
then stepped back. Findings, graded by confidence:

- **CONFIRMED (why the prototype's layer was "inactive"):** the FROG WSI layer is an *implicit* Vulkan
  layer gated by `enable_environment=ENABLE_GAMESCOPE_WSI=1`, so a separately-launched client must
  export **both** `ENABLE_GAMESCOPE_WSI=1` **and** `GAMESCOPE_WAYLAND_DISPLAY=<wl>` for it to engage.
  The deferred prototype set only the latter → layer stayed off (hence "15/15 inactive"). With `=1`
  added it engages (`[Gamescope WSI] … flip: true`, `received new refresh cycle`).
- **CONFIRMED (better oracle):** the IRQ-198 oracle cannot tell a genuinely-spinning cube from
  gamescope re-flipping a static composite (rotation-shader composites every frame). Use a CLIENT
  oracle — sum `drm-engine-gpu` from `/proc/<vkcube-pid>/fdinfo/*` and require it to ADVANCE
  ([[sm8650-gpu-liveness-probing]]). SPIN = IRQ ticks AND client GPU advances.
- **CONFIRMED but possibly self-inflicted:** with a *separate-client* launcher (background bare
  gamescope `--ready-fd`, then `exec vkcube`), `systemctl stop`/`restart` intermittently took the full
  default 90 s `TimeoutStopSec` (HW ~4/8) — gamescope ignores SIGTERM when its client vanishes
  mid-frame; panel sits on console the whole time = the operator's "long pauses between cubes on
  console". A `TimeoutStopSec=5s` cap fixes the symptom. BUT this may be specific to the separate-client
  model (the shipped `gamescope … -- vkcube` model has gamescope as the main PID and may tear down
  cleanly) — UNVERIFIED. Reverted; not in the tree.
- **SUSPECT — NOT a conclusion:** the handshake+WSI-on variant measured 72/72 healthy cold starts
  (incl. a 24-trial client-GPU run) + a clean 30 s unit soak. **DO NOT TRUST THIS YET** — see the hole.

- **THE METHODOLOGY HOLE (operator's catch — RESOLVED by the decisive experiment below: operator
  right, it IS teardown contamination):** EVERY freeze/wedge number we
  have ever taken — 8/12, 3/12, 0/24, this session's 72/72, even the prior thread-stack-wedged session
  — was a **service re-launch** (`systemctl restart` / pkill+relaunch) on an already-booted device.
  **We have NEVER tested a true power-on reboot.** Teardown is now known to be dirty (gamescope can
  leave DRM master / syncobj / GPU state behind), so the cold-start "deadlock" may be **leftover-state
  contamination from the prior instance, not a fresh-boot race**. The thread stack (`vkcube` in
  `drm_syncobj_array_wait_timeout`) proves the *mechanism* (a syncobj fence never signals) but NOT the
  *trigger* (fresh vs stale state) — a stale syncobj from a botched teardown gives the same stack. So
  "the vkcube hang only happens on a re-launch after a prior spin" is consistent with all data, and
  would make `ENABLE_GAMESCOPE_WSI=0` / the handshake symptom-treatments for a teardown root cause.

- **DECISIVE EXPERIMENT — RAN 2026-06-23 (session 3), `192.168.1.193`. RESULT: operator is RIGHT — the
  wedge is teardown/re-launch contamination, NOT a fresh-boot race.** 10 real power-on reboots; per boot,
  with the ORIGINAL model (`seatd-launch -- gamescope --backend drm --use-rotation-shader -- vkcube`,
  WSI **on**, NO handshake, NO `ENABLE_GAMESCOPE_WSI=0`), ran **L1** (first gamescope since power-on) then
  **L2** (SIGKILL teardown + re-launch), classified by the CLIENT-GPU oracle (sum `drm-engine-*` from the
  vkcube `fdinfo`, require advance — [[sm8650-gpu-liveness-probing]]):

  | Launch | SPIN | HANG |
  |---|---|---|
  | **L1 (fresh boot)** | **10 / 10** | **0 / 10** |
  | **L2 (re-launch)** | 3 / 10 | **7 / 10** |

  - **L1 NEVER wedges** (0/10) — the original WSI-on model spins on every genuine power-on. So
    `ENABLE_GAMESCOPE_WSI=0` and the `--ready-fd` handshake are solving a problem that **does not occur at
    boot**; they are symptom-treatments for a re-launch/teardown root cause.
  - **L2 wedges ~70%** — a killed prior instance leaves stale explicit-sync **syncobj / GPU / DRM-master**
    state that wedges the *next* WSI client (`vkcube` blocks in `drm_syncobj_array_wait_timeout`; the
    thread-stack mechanism was always real, only the *trigger* was misattributed). Harsher teardown =
    more contamination: SIGKILL gave **7/10** vs the prior `systemctl restart` numbers (8/12 on 3.16.17,
    3/12 on 3.16.23.2) — consistent, monotonic with teardown dirtiness.
  - **Harness gotchas found (so the numbers are trustworthy):** (1) run L1 too early (~30 s uptime) and
    cold gamescope hasn't spawned vkcube inside the wait window → false `NOVKCUBE` (= the operator's "only
    launches once per boot"); fixed by settling to ≥45 s uptime + a 60 s vkcube wait. (2) `/` is btrfs and
    a fast `systemctl reboot` right after a write discards the uncommitted result (30 s commit window) —
    `sync` before reboot. Harness: `/root/freeze-trial.sh` (persists across reboot; `/run` is tmpfs).

- **IMPLICATION / what to do:** the product boots gamescope **once** per power-on = the L1 case = no wedge,
  so the freeze is a non-issue at real boot. It only bites the **re-launch** path (`Restart=on-failure`,
  `systemctl restart`). The proper fix is **clean teardown** (ensure gamescope fully releases syncobj /
  GPU / DRM-master on exit) rather than disabling the WSI layer. `ENABLE_GAMESCOPE_WSI=0` still validly
  *masks* the re-launch wedge (implicit sync sidesteps the stale syncobj) so it can stay as cheap
  insurance for the restart path — but it is NOT the root-cause fix and is needless at boot.

- **Device state left behind (`192.168.1.193`, IP drifted off `.189`):** `/root/freeze-trial.sh` +
  `/root/freeze-results.log` (10-boot raw data) remain. `novadeck-session` is the repo's shipped
  `ENABLE_GAMESCOPE_WSI=0` simple model, **DISABLED** (nothing auto-runs). Reflash/redeploy from the tree
  before trusting on-device behaviour.

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
| `/usr/bin/novadeck-session` | launcher: seat (`seatd-launch`) + env + patched gamescope (`--backend drm --use-rotation-shader`, the HW-validated combo) → runs `$NOVADECK_SESSION_CMD` |
| `/etc/novadeck/session.conf` | single config point — `NOVADECK_SESSION_CMD` (Phase-2 placeholder `vkcube`; Phase-3 → `steam -gamepadui …`), `NOVADECK_GAMESCOPE_EXTRA` |
| `/usr/lib/systemd/system/novadeck-session.service` | boots the compositor on VT1 (`Conflicts=getty@tty1`, `After=inputplumber`), `Restart=on-failure` |

**Design choices (Phase-2):**
- **Runs as root via `seatd-launch`** — identical seat + rotation path Step 1 validated; the SteamOS
  `deck` user / logind-seat model is a Phase-4 hardening concern, not session de-risk.
- **Shipped installed-but-DISABLED** (no preset, no `.wants` symlink). Validate on HW by hand first —
  `systemctl start novadeck-session` — so it never seizes the panel from the SSH/`nova-gamescope-smoke`
  bring-up path. (The intermittent composite-flip freeze that previously gated this is now MITIGATED —
  `ENABLE_GAMESCOPE_WSI=0`, step 1e; root cause still OPEN.) Flipping to boot-enabled is a one-line preset add
  (`enable novadeck-session.service` in a release preset, plus switching the default target to
  `graphical.target`) once the Phase-3 Steam shell lands.
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

**MITIGATED (was the Step-2 blocker; root cause OPEN):** the intermittent cold-start composite-flip
**freeze** presents as the gamescope **WSI explicit-sync (`linux-drm-syncobj`) deadlock**, mitigated by
`ENABLE_GAMESCOPE_WSI=0` (now set in `novadeck-session`). HW A/B (3.16.23.2 overlay): **0/24** cold
starts wedge with the WSI layer off vs **3/12** with it on (8/12 on the older 3.16.17). The mechanism
is confirmed but the trigger is **OPEN** — every measurement was a service re-launch, never a true
reboot (see the METHODOLOGY HOLE + DECISIVE EXPERIMENT in step 1e). `ENABLE_GAMESCOPE_WSI=0` is a
mitigation, not a confirmed fix.

### Remaining ☐
- ~~InputPlumber gamepad reaches the client inside the session (ties off step 1d).~~ ✅ **CLOSED (HW 2026-06-23, step 1d)** — gamescope passes the InputPlumber virtual DualSense (event7) through to its hosted client; verified with `gamescope … -- evtest /dev/input/event7`.
- Boot-enable (preset + default target → `graphical.target`) — unblocked in practice (freeze
  mitigated by `ENABLE_GAMESCOPE_WSI=0`; root cause still OPEN); deferred until the Phase-3 Steam shell lands.

## Step 3 — novadeck Qualcomm HW-support (layer C) [IN PROGRESS]
Port/replace `jupiter-hw-support` + `steamos-manager` affordances onto Qualcomm backings per the
layer-C matrix in `.claude/plans/novadeck.plan.md`. The backings ship as a static, SoC-agnostic
overlay tree under `hw-support/` (mirror-copied into the rootfs by `images/assemble-rootfs.sh`
block 4e), the same overlay mechanism as the layer-B `session/` tree.

| Deck-UI affordance | Qualcomm backing | Notes |
|---|---|---|
| TDP / power slider | cpufreq + GPU devfreq | no 1:1 TDP — shim maps slider → clocks/thermal |
| Refresh-rate / VRR | Turnip + DSI panel modes | VRR likely a gap; stub honestly |
| Suspend / resume | **userspace rest mode (fake suspend)** | real s2idle out of scope — see below |
| Brightness | SY7758 backlight (kernel patch 0060) | driver in tree |
| Gyro / rotation | IIO (libiio) | Pocket S2 is portrait-native — Deck-style rotation handling |
| Battery / charge | fuel-gauge + UPower | |
| First-boot OOBE | steamos-oobe (adapt) | SteamOS owns first-boot networking |

### Suspend → userspace "rest mode" (`novadeck-rest`) [MECHANISM LANDED & VALIDATED on HW 2026-06-24]
Real Qualcomm **s2idle** suspend/resume is immature on these SoCs and kernel-depth debugging it is
out of scope. Decision (2026-06-23): stand in with a **reversible userspace rest state** instead of
calling into the kernel sleep path at all. `hw-support/usr/bin/novadeck-rest`:

- **enter** — blank the panel via **gamescope's own KMS modeset** (`gamescopectl drm_sleep_internal_screen 1`;
  gamescope holds DRM-master and detaches the connector from its CRTC → the DSI link blanks, deeper
  than a backlight-off), offline every CPU **but the boot CPU** (`/sys/devices/system/cpu/cpuN/online`),
  soft-block all radios (`/sys/class/rfkill/*/soft`), switch every cpufreq policy to **powersave**, and
  switch the **GPU devfreq governor → powersave** (the GPU node is found SoC-independently by its
  `.gpu` devfreq-name suffix — `gpu@<addr>` → `<addr>.gpu` — not a hardcoded per-SoC address).
- **leave** — restore each in reverse, from state captured at enter under `/run/novadeck/rest.d/`
  (records *only* what it actually changed, so it restores the prior governor / CPU / radio state
  rather than blindly onlining everything).
- **toggle** / **status** — for the future single-button trigger.

**Why these primitives:** `gamescopectl` is the clean panel lever — it ships in our from-source
gamescope (`src/Apps/gamescopectl.cpp`, `install: true`) and the `drm_sleep_internal_screen` ConVar
(`src/Backends/DRMBackend.cpp`) routes through the compositor that already owns DRM-master, so we
never fight it for the panel. Everything else is pure sysfs — **no new package**.

**Phase-2 scope = MECHANISM only**, shipped hand-run (no trigger unit), exactly like the session was
de-risked. The trigger that fires it (a power-button watcher / Deck-UI request → `novadeck-rest
toggle`) is a deliberate follow-up.

**Validate ✅ (on HW 2026-06-24):** with the session up, `novadeck-rest enter` blanks the panel
(connector `dpms On→Off`, `enabled→disabled`) and `leave` restores it (`→On`/`→enabled`); the GPU
devfreq governor flips `simple_ondemand→powersave` on enter and restores on leave (state recorded
per-device in `/run/novadeck/rest.d/gpu_governors`, e.g. `3d00000.gpu simple_ondemand`). cpu-offline,
rfkill and cpufreq-governor ops use the same record-and-restore pattern (cpu/rfkill skipped during the
SSH-safe runs so the link stays up on the no-UART device). Each op records *only* what it actually
changed, so leave restores the prior reading.

### Suspend = userspace freeze + power-key wake [VALIDATED on HW 2026-06-24]
Real suspend stops the *game*, not just the screen. Mechanism (overlay `hw-support/`):
- **`novadeck-suspend`** — freezes all userland via the cgroup v2 freezer
  (`echo 1 > /sys/fs/cgroup/{system,user}.slice/cgroup.freeze`) so the game halts; resume thaws,
  runs `/etc/novadeck/resume.d/*` (generic hook point — the test card's Wi-Fi re-up lives here),
  and a safety auto-thaw covers a missed wake. Panel blank/unblank via gamescope DPMS around the
  freeze.
- **`novadeck-waked`** — the wake/power agent: `libinput debug-events --device /dev/input/event0`
  (pmic_pwrkey) times the key from `KEY_POWER pressed` → `released`. A short **tap** →
  `novadeck-suspend toggle`; a **hold ≥ `NOVADECK_WAKE_LONGPRESS_MS`** (default 2000ms) → thaw-then-
  `systemctl poweroff`. Runs in a top-level **`novadeck-wake.slice`** (sibling of system.slice) so it
  is NEVER frozen and can thaw the system. **Enabled at boot** via the overlay (preset
  `60-novadeck-waked.preset` + `multi-user.target.wants` symlink) — no longer SSH-only.
- logind `HandlePowerKey=ignore`/`HandlePowerKeyLongPress=ignore` drop-in so logind neither
  poweroffs nor suspends. Press tiers: **tap** = suspend/resume, **~2s hold** = clean software
  poweroff (above), **~8s+ hold** = PMIC hardware reset (escape hatch, below us).

**Proven (power-key cycle):** short-press froze the game (cube stopped on-panel, SSH dropped); a
second short-press **resumed in 13s** — `novadeck-waked` read `KEY_POWER` *while all userland was
frozen* (2 toggles logged), thawed, re-associated Wi-Fi via the resume hook, no reboot. The
freezer halts the workload (cgroup CPU usage → 0) and the un-frozen agent reads the key from its own
evdev fd (the key is not EVIOCGRAB-exclusive). The kernel s2idle path is never touched.

**Resume-latency bug — FIXED & HW-validated 2026-06-24 (IP .188).** That "resumed in 13s" was the
tell: `do_resume` called `systemctl stop novadeck-autothaw.timer` *before* the thaw, so it blocked on
the **frozen system D-Bus daemon** (in `system.slice`) until the bus call timed out — 13s in the
light case, ~90s with the autothaw timer actually loaded, during which the device looks dead. Fix:
thaw (`freeze 0`) first, *then* call systemctl; power-restore stays before the thaw (pure sysfs, safe
while frozen). Rule: **never invoke systemctl/D-Bus while the freezer is engaged — thaw first.**
Traced reproduce confirmed the wake agent fired the toggle correctly the whole time; resume is now
~2-3s. The power-key trigger (`novadeck-waked`, enabled at boot) drives this; a ~2s hold → poweroff.

**DPMS panel blank — FIXED & VALIDATED on HW 2026-06-24.** Two distinct bugs; the second was the
decisive one for the suspend path.

1. *gamescopectl couldn't always reach gamescope.* `gamescopectl` defaults to the `gamescope-0`
   control socket, but gamescope binds the **first free slot** (`gamescope-0`, `gamescope-1`, … —
   `wlserver.cpp`); a live overlapping instance (smoke + session) can push the real compositor onto
   `gamescope-1`, leaving `gamescopectl` talking to the wrong/dead `gamescope-0`. Fix: a sourced
   resolver `usr/lib/novadeck/gamescope-display.sh` (`gs_resolve_display`) finds the LIVE slot by the
   `gamescope-N.lock` fd a wayland server keeps open (scan `/proc/*/fd`) — robust to the comm rename
   (`gamescope-wl`) and to `setenv` not reaching `/proc/<pid>/environ`. NB a socket left by a *dead*
   owner is reclaimed at the same slot (flock auto-releases on death), so pure stale-on-death stays on
   slot 0 — the resolver still resolves it correctly. Both `novadeck-suspend` and `novadeck-rest`
   export the resolved name before `gamescopectl`. (`novadeck-rest enter/leave` confirmed the panel
   blanks/restores on HW: connector `dpms On→Off→On`, `enabled→disabled→enabled`.)

2. *suspend froze gamescope before the blank landed.* gamescope applies the `drm_sleep` convar on its
   OWN main loop — HW-measured **~324 ms** after `gamescopectl` returns — but `novadeck-suspend` did
   `panel 1` then `freeze 1` back-to-back, trapping gamescope mid-apply so the panel stayed lit (the
   screen-still-on symptom; `novadeck-rest` never froze, so it always blanked). Fix: `do_suspend`
   now polls the connector's sysfs `enabled` attr (`wait_panel disabled`, plain attribute read, no
   debugfs) and freezes only AFTER the blank is confirmed; `do_resume` confirms restore symmetrically.
   HW cycle: log shows `panel blank confirmed` → frozen window with **screen off** → auto-thaw →
   `panel restore confirmed` → `resumed`, `dpms=On`.

**Power ops folded in ✅ (HW-validated 2026-06-24).** The cpu-offline / rfkill / cpu+gpu
cpufreq+devfreq powersave-governor primitives now live in a shared sourced lib
`hw-support/usr/lib/novadeck/power-ops.sh` (`power_enter`/`power_leave`); `novadeck-rest` sources it
(was its own copies) and `novadeck-suspend` applies `power_enter` AFTER the freeze and `power_leave`
BEFORE the thaw, guarded by `NOVADECK_SUSPEND_SKIP` (keys `cpu rfkill governor gpugov`). HW
(192.168.1.187): log `freezing → lowering power(skip='rfkill') → … → restoring power → thaw`;
post-resume CPUs `0-7`, governors `performance`, GPU `simple_ondemand` all restored, gamescope (pid
659) survived the freeze/thaw. `novadeck-rest` is now a dev/bring-up tool (lowers power WITHOUT the
freeze, so it stays SSH-reachable), superseded by `novadeck-suspend` as the suspend affordance.

**Open ☐:** release Wi-Fi resume (NetworkManager) and long-press=clean-shutdown — see TODO.md. Units
ship installed-but-DISABLED (validate by hand).

## Validate (Phase-2 exit, per plan)
gamescope session launches on SM8650; Deck UI renders; Quick Access + suspend reach the
layer-C affordances that have a Qualcomm backing (the rest documented as stubbed).

_Phase 2 scaffold._
