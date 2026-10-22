# Panel frame-length calibration

Some of our panels self-time their refresh from a DDIC frame-length word whose stock constants
land measurably off nominal — an Odin 3 measured **118.35 Hz** on its "120 Hz" mode. gamescope's
fps limiter divides the refresh by the target with integer floor, so a panel running *under*
nominal makes every cap land one divisor high: ask 30, get ~39.5 (real/3); ask 20, get ~23.7
(real/5). HW-diagnosed 2026-10-20 on an Odin 3 (Darksiders 2, Steam framelimiter "not working").

The fix is ROCKNIX's: trim the panel until it scans **at or just above** nominal (never below —
below is the floor-division failure itself), per rate, per unit.

## Pieces

| piece | where | role |
|---|---|---|
| kernel knobs | `frame_len_<rate>` sysfs on the mipi-dsi device (patch `0533` for the Odin 3's ICNA3520) | live trim of the DDIC frame length, replayed by the driver on every panel init incl. resume |
| `novadeck_panel.py` + `panel-calibration` CLI | `/usr/lib/novadeck/` | measure the real rate (DRM vblank timestamps, no DRM master needed), run the trim loop, persist |
| `novadeck-panel-calibration.service` | preset-enabled oneshot | boot-time re-apply of persisted values; Condition-gated, a no-op on boards without knobs |
| Panel tab | Novadeck Control plugin | shows the measured rate on every board; **Calibrate Panel** button only where knobs exist |

## Rules of the design

- **No calibration at boot.** Measuring and stepping the DDIC is operator-triggered from the
  Panel tab (or `panel-calibration calibrate` over SSH as root). Boot only re-applies.
- **Stamped to the unit.** `/var/lib/novadeck/panel-calibration.json` is keyed by the SoC
  serial; two boards of the same model hold separate entries, and a card moved to a unit that
  never calibrated applies nothing there.
- **Calibrates the rate the panel is scanning now.** gamescope owns mode choice; to calibrate
  the other rate, switch the refresh in Steam's display settings and press the button again.
  In-game QAM typically means the game-presence rate (120), SteamUI the steam rate (60).

## Adding a board

Ship the kernel-side knob in that board's panel driver (hoist the frame-length words out of the
init sequence into per-mode fields with `frame_len_*` sysfs, defaults = the old constants — see
patch 0533, or ROCKNIX's RP6/Thor equivalents). Everything above keys on the attributes
existing, so no userspace or plugin change is needed.

Offline coverage: `tests/test-panel-calibration.sh` (convergence policy, serial stamping,
failure restore), in `make test`.
