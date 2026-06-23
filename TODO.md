# novadeck — follow-up TODO

Tracking work that is understood but deliberately deferred. Each item links to the
investigation that produced it.

## Phase 2 — gamescope session

- [ ] **Clean gamescope teardown (root-cause fix for the re-launch wedge).**
  The decisive 10-reboot experiment (`devices/sm8650/bringup-phase2.md` step 1e, session 3)
  proved the "cold-start freeze" is **teardown/re-launch contamination, not a fresh-boot race**:
  the original WSI-on model spins **10/10 on a true power-on** (L1) and only wedges on
  **re-launch after a prior instance** (L2, 7/10) — a killed gamescope leaves stale explicit-sync
  **syncobj / GPU / DRM-master** state that wedges the next WSI client
  (`drm_syncobj_array_wait_timeout`).
  - `ENABLE_GAMESCOPE_WSI=0` (shipped in `session/usr/bin/novadeck-session` + the smoke helper)
    only **masks** the wedge on the restart path; it is needless at boot and is **not** the
    root-cause fix.
  - **Do:** make gamescope release its syncobj/GPU/DRM-master state cleanly on exit (or have the
    unit guarantee a clean slate before re-launch), so `Restart=on-failure` / `systemctl restart`
    cannot wedge the next client. Then re-test the re-launch path and consider dropping
    `ENABLE_GAMESCOPE_WSI=0` to recover the WSI HDR path.
  - Harness for re-validation lives on the test device at `/root/freeze-trial.sh`
    (`192.168.1.193`, IP drifts); raw 10-boot data in `/root/freeze-results.log`.

- [ ] **`--ready-fd` HDR-preserving handshake** — only worth finishing if HDR is needed *and*
  clean teardown alone doesn't let us drop `ENABLE_GAMESCOPE_WSI=0`. See step 1e session-2 notes.

## Phase 2 — HW-support (layer C)

- [ ] **Rest-mode trigger (`novadeck-rest toggle`).** The rest-mode *mechanism* landed hand-run
  (`hw-support/usr/bin/novadeck-rest`, validated by SSH per step 3). Wire something to fire it:
  a power-button watcher (`HandlePowerKey=ignore` in logind + evdev on the power key → `toggle`),
  the powerbuttond-equivalent, and/or the Deck-UI / steamos-manager suspend request once that lands.
  Deferred until the mechanism is proven on HW. See `devices/sm8650/bringup-phase2.md` step 3.

- [ ] **Add a Bluetooth stack.** Pull BlueZ (+ bluez-utils) into the base/package set so the Deck UI
  can pair controllers/audio. Today rfkill sees a `bluetooth` radio but there is no userspace stack.
  Layer-C affordance; pairs with the gamepad/input work.

- [ ] **Release Wi-Fi resume after userspace suspend.** The `resume.d` hook *mechanism* is generic
  (`novadeck-suspend` runs `/etc/novadeck/resume.d/*` after thaw, ships in the overlay). The test card's
  hook re-ups `wpa_supplicant@wlan0` (test-only, matches the test Wi-Fi stack). RELEASE uses
  NetworkManager (Steam wizard-configured) — verify NM reconnects on thaw on its own; if not, ship an
  NM-flavored resume hook. Don't leave release without a Wi-Fi resume path.

- [ ] **Long-press power = clean shutdown (in `novadeck-waked`).** logind already ignores the key
  (`HandlePowerKey=ignore`/`LongPress=ignore`); have the agent time the press: short = suspend/resume
  toggle (done), long hold (software, ~2-4s before the PMIC hardware S2 reset) = `systemctl poweroff`.
  Gives short/long/very-long = suspend / clean-shutdown / hardware-off.
