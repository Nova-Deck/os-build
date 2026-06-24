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
    (DHCP, IP drifts — `192.168.1.186` as of 2026-06-24, was `.193`); raw 10-boot data in
    `/root/freeze-results.log`.

- [ ] **`--ready-fd` HDR-preserving handshake** — only worth finishing if HDR is needed *and*
  clean teardown alone doesn't let us drop `ENABLE_GAMESCOPE_WSI=0`. See step 1e session-2 notes.

## Phase 2 — HW-support (layer C)

- [x] **Fold `novadeck-rest`'s power ops into the freeze suspend path.** ✅ **DONE + HW-validated
  2026-06-24.** Extracted the four reversible power primitives (cpu-offline, rfkill, cpu+gpu
  cpufreq/devfreq powersave governor) into a shared sourced lib `hw-support/usr/lib/novadeck/power-ops.sh`
  (`power_enter` / `power_leave`); `novadeck-rest` now sources it instead of its own copies, and
  `novadeck-suspend` applies `power_enter` **after** the freeze and `power_leave` **before** the thaw.
  Guarded/skippable via `NOVADECK_SUSPEND_SKIP` (keys `cpu rfkill governor gpugov`; same as
  `NOVADECK_REST_SKIP`). HW (192.168.1.187): suspend log shows `freezing → lowering power → … →
  restoring power → thaw`; post-resume CPUs `0-7`, governors→`performance`, GPU→`simple_ondemand` all
  restored, gamescope survived freeze/thaw. `novadeck-rest` documented as a dev/bring-up tool (its
  header) — superseded by `novadeck-suspend` for the actual suspend affordance.

- [x] **Power-key suspend trigger.** ✅ **DONE — wired at boot.** The power-button watcher is
  `novadeck-waked` (`HandlePowerKey=ignore` logind drop-in + libinput on the power key → a short tap
  fires `novadeck-suspend toggle`). The suspend path superseded rest mode, so the trigger drives
  `novadeck-suspend`, not `novadeck-rest`. `novadeck-waked.service` is now **enabled** via the
  overlay (`hw-support/usr/lib/systemd/system-preset/60-novadeck-waked.preset` + a
  `multi-user.target.wants` symlink), so the SSH-only mechanism is a real on-device affordance.
  The Deck-UI / steamos-manager suspend request remains a future alternate trigger. See
  `devices/sm8650/bringup-phase2.md` step 3.

- [ ] **Add a Bluetooth stack.** Pull BlueZ (+ bluez-utils) into the base/package set so the Deck UI
  can pair controllers/audio. Today rfkill sees a `bluetooth` radio but there is no userspace stack.
  Layer-C affordance; pairs with the gamepad/input work.

- [ ] **Release Wi-Fi resume after userspace suspend.** The `resume.d` hook *mechanism* is generic
  (`novadeck-suspend` runs `/etc/novadeck/resume.d/*` after thaw, ships in the overlay). The test card's
  hook re-ups `wpa_supplicant@wlan0` (test-only, matches the test Wi-Fi stack). RELEASE uses
  NetworkManager (Steam wizard-configured) — verify NM reconnects on thaw on its own; if not, ship an
  NM-flavored resume hook. Don't leave release without a Wi-Fi resume path.

- [x] **Long-press power = clean shutdown (in `novadeck-waked`).** ✅ **DONE.** The agent times the
  press from its libinput pressed→released edges: a tap fires `novadeck-suspend toggle`; a hold
  ≥ `NOVADECK_WAKE_LONGPRESS_MS` (default 2000ms, well under the PMIC ~8s+ hardware reset) thaws if
  suspended then `systemctl poweroff`. Gives short/long/very-long = suspend / clean-shutdown /
  hardware-off. Knob in `rest.conf`; 0 disables long-press. **HW-validated 2026-06-24 (IP .188):
  long-press → clean poweroff works.**

- [x] **`do_resume` must not call systemctl while userland is frozen.** ✅ **DONE + HW-validated
  2026-06-24 (IP .188).** Surfaced validating the power-key trigger: a wake tap froze, but `do_resume`
  ran `systemctl stop novadeck-autothaw.timer` BEFORE the thaw, so it blocked ~90s on the frozen
  system D-Bus daemon (in `system.slice`) before resume continued — the device looked dead. Fix:
  thaw (`freeze 0`) first, then call systemctl; power-restore stays before the thaw (pure sysfs, safe
  while frozen). Resume now ~2-3s. The wake agent itself was never at fault. See `suspend-systemctl-
  while-frozen-blocks` memory.

- [ ] **No system clock / NTP on the device.** RTC starts near epoch and nothing syncs it (logs read
  `1970-…`). Harmless for the suspend timing (it uses deltas) but ship a `systemd-timesyncd` config
  (or chrony) so timestamps and TLS are sane. Low priority, unrelated to suspend.
