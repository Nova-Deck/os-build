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
| 1a | gamescope present in base | `gamescope --version` on device (pkg from holo repo via customize-base.sh) | ☐ verify pkg actually in pinned repo |
| 1b | gamescope opens DRM/KMS | `nova-gamescope-smoke` — DRM backend, libseat `builtin`, takes DRM master as root | ☐ on HW |
| 1c | Vulkan client renders under gamescope | default client `vkcube` → gamescope Wayland → Turnip WSI; cube on panel | ☐ on HW |
| 1d | Input reaches the client | InputPlumber virtual gamepad (Phase-1 green) seen inside gamescope via libinput | ☐ on HW |

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

### Likely failure modes to watch (record findings here)
- Turnip missing a Wayland-WSI / DMA-BUF modifier gamescope requires → contribute Mesa fix or
  pin a known-good Turnip (mirrors the Phase-1 GPU-firmware risk).
- `present_wait` / explicit-sync / VRR / HDR gaps → degrade gracefully; document as a layer-C
  stub rather than blocking.
- libseat `builtin` insufficient (some setups need a real seat) → fall back to running `seatd`
  and `LIBSEAT_BACKEND=seatd`.

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
