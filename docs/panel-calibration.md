# Panel frame-length calibration

Some of our panels self-time their refresh from a DDIC frame-length word whose stock constants
land measurably off nominal — an Odin 3 measured **118.35 Hz** on its "120 Hz" mode, an Odin 2
Portal 119.8 / 59.9 Hz. gamescope's fps limiter divides the refresh by the target with integer
floor, so a panel running *under* nominal makes every cap land one divisor high: ask 30, get
~39.5 (real/3); ask 20, get ~23.7 (real/5). HW-diagnosed 2026-10-20 on an Odin 3 (Darksiders 2,
Steam framelimiter "not working").

The fix: trim the panel until it scans **just above** nominal, per rate, per unit. The target
window is **+0.01% to +0.08%**: below nominal is the floor-division failure itself. Where the
panel's range cannot reach the window, the closest value still at or above nominal wins.

**Some values gray the picture, and not by rate.** On the ICNA3520's 120 Hz knob it is every
value that is 2 mod 4: an Odin 3 grayed at 46, 50, 54 and 58 while every neighbour, and 44 at
120.2 Hz, stayed clean. A calibrator stepping in 4s from a multiple of 4 never meets one. Nothing
can measure gray, so `GRAY_VALUES` in `novadeck_panel.py` lists them per panel compatible and
rate, and calibrate and `step` skip them. The 60 Hz default (2006) is 2 mod 4 and clean, so
the rule is the 120 Hz knob's only.

## Pieces

| piece | where | role |
|---|---|---|
| kernel knobs | `frame_len_120` / `frame_len_60` sysfs on the mipi-dsi device (patches `0533`, `0534`; ICNA3520 = Odin 3 and the Thor top screen, ICNA3512 = Odin 2 Portal) | live trim of the DDIC frame length, replayed by the driver on every panel init incl. resume; values outside the panel's range are refused with `EINVAL` |
| `novadeck_panel.py` + `panel-calibration` CLI | `/usr/lib/novadeck/` | measure the real rate, calibrate, step, save, revert, apply |
| `novadeck-panel-calibration.service` | preset-enabled oneshot, before the display manager | records the driver defaults in `/run/novadeck/panel-defaults.json`, then re-applies saved values; a no-op on boards without knobs |
| Panel tab | Novadeck Control plugin | measured rate on every board; Calibrate, Save, Revert and Reset where knobs exist |

## How it measures

`DRM_IOCTL_WAIT_VBLANK` on the CRTC that drives the board's primary connector (device-env
`NOVADECK_PRIMARY_CONNECTOR`; `NOVADECK_PANEL_CONNECTOR` overrides it). The rate is the vblank
**sequence** count over the elapsed time, so a reader that misses a vblank does not read the panel
slow. No DRM master needed.

## How it calibrates

1/rate is linear in the frame length. `calibrate`:

1. measures twice and refuses if the two differ by more than 0.1 Hz (compositor still settling);
2. attributes the rate to a knob (within 10% of 60 or 120, else refuses);
3. probes the knob 20 values away and back: if the rate does not follow, the measured CRTC is not
   the knobbed panel's; if it does not come back, the mode changed — both abort;
4. solves the line for the window, then steps one usable value at a time (at most 8) to land in
   it; when no usable value lands there, the measured one with the lowest rate still at or above
   nominal wins (Odin 3: the window held only the gray 46, so 45 at ~120.1 Hz);
5. leaves the result **live but unsaved**. On any failure the starting value is restored.

`panel-calibration step RATE faster|slower` (SSH, as root) moves to the next usable value with no
ceiling: that is how an operator fixes a bad automatic result. The Panel tab has no step buttons:
calibration lands clean on its own, so the hand override stays on the CLI. Save persists the live value; saving the driver default deletes the entry.
Revert goes back to the saved value, or the default.

## Rules of the design

- **No calibration at boot.** Measuring and stepping the DDIC is operator-triggered from the
  Panel tab (or `panel-calibration calibrate` over SSH as root). Boot only records the defaults and
  re-applies.
- **Stamped to the unit.** `/var/lib/novadeck/panel-calibration.json` is keyed by the SoC
  serial; two boards of the same model hold separate entries, and a card moved to a unit that
  never calibrated applies nothing there.
- **Calibrates the rate the panel is scanning now.** gamescope owns mode choice; to calibrate
  the other rate, start a game and set the Refresh Rate slider to it, then calibrate again.
  Outside a game the panel stays at its top rate. On the Portal, the 50/145/165 Hz modes keep
  Android's constants and are not calibrated.

## Adding a board

Ship the kernel-side knob in that board's panel driver: hoist the frame-length words out of the
init sequence into per-mode fields, and give the panel description a `struct icna35xx_frame_len`
(writer, value ranges, the command page the init leaves selected) — see patch `0534`. Everything
above keys on the attributes existing, so no userspace or plugin change is needed.

Offline coverage: `tests/test-panel-calibration.sh` (window policy, probe/abort paths, the
sequence-based measurement, connector resolution, serial stamping, save/revert/defaults), in
`make test`.
