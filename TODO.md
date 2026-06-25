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

- [ ] **Bring up audio (AudioReach TPLG + ALSA UCM2 + PipeWire/WirePlumber).** No sound path today —
  a layer-C affordance (Deck UI volume slider + game/BT audio). SM8650 routes audio through the
  Qualcomm DSP via the AudioReach (q6apm/q6prm) drivers, so the stack is:
  - **Kernel:** enable the AudioReach/ASoC SM8650 sound drivers (q6apm-dai, q6prm, the SoundWire +
    LPASS/audioreach bits) so a sound card actually probes. Add to the ROCKNIX-parity config audit.
  - **Topology:** ship the device's **AudioReach `.tplg`** topology binary under `/lib/firmware/...`
    (sourced like the other device firmware — pin it, don't hand-roll). Without the matching TPLG the
    q6apm card won't expose usable PCMs/mixers.
  - **ALSA UCM2:** ship a machine UCM2 profile (card-name-matched) so the userland knows the routing
    (speaker/headset/HDMI paths, jack handling). Lands as an overlay under `/usr/share/alsa/ucm2/...`.
  - **Userland:** add `pipewire wireplumber pipewire-pulse pipewire-alsa` (and `pipewire-jack` if
    needed) to the release PKGS; enable the per-user PipeWire/WirePlumber sockets. Ties into the
    Bluetooth work (BlueZ → `libspa-bluetooth` for A2DP/HFP) and the Steam gamepadui audio controls.
  - **Validate (HW):** a PCM enumerates (`aplay -l` / `wpctl status`), speaker + 3.5mm + BT output
    each play, and the Deck UI volume slider moves the right sink. Pairs with the Bluetooth HW test.

- [x] **Add a Bluetooth stack.** ✅ **DONE (code) — HW pairing UNVALIDATED.** `bluez` + `bluez-utils`
  added to `PKGS` in `images/customize-base.sh`; `bluetoothd` enabled via the hw-support overlay
  (`60-novadeck-bluetooth.preset` + build-time `bluetooth.target.wants/bluetooth.service` and the
  `dbus-org.bluez.service` alias that also lets D-Bus activate it on demand). WCN7850 BT firmware
  already ships (assemble-rootfs.sh block 3b). **TODO(HW):** boot a build, confirm `bluetoothctl`
  sees the adapter (`hci0`) and pair a controller; verify `bluetooth.target` is actually reached at
  boot (else rely on the D-Bus alias activation).

- [x] **Release Wi-Fi resume after userspace suspend.** ✅ **DONE (code) — HW UNVALIDATED.** Shipped a
  defensive NM resume hook in the release overlay: `hw-support/etc/novadeck/resume.d/50-nm-reup`
  (`nmcli radio wifi on` after thaw). It is **inert unless NM is the active manager**
  (`command -v nmcli` + `systemctl is-active NetworkManager`), so it stays a no-op on the TEST card
  where networkd + `wpa_supplicant` own wlan0; it sorts before the TEST-only `50-wlan-reup`, so that
  re-association still runs. **TODO(HW):** the suspend path rfkill-blocks the radio and NM usually
  re-enables Wi-Fi unaided on the unblock — confirm whether NM recovers on its own and drop this hook
  if the nudge proves moot.
  - ✅ **Resolved the test-vs-release stack split (2026-06-25):** `networkmanager` added to
    `customize-base.sh` PKGS, and the TEST Wi-Fi injection rewritten to use NM (drops an
    `.nmconnection` keyfile + enables `NetworkManager.service`) instead of `wpa_supplicant@wlan0` +
    `systemd-networkd`. The throwaway card now runs the **same manager as release**, so this NM path
    — and the `50-nm-reup` resume hook — is now exercisable on HW. A plain release base still leaves
    NM inactive (no auto-enable preset); enabling it for release is the Phase-3 Steam-UI step.
  - ✅ **HW-VALIDATED 2026-06-25 (IP 192.168.1.186):** the NM-based test card joined the LAN and
    accepts SSH — the `.nmconnection` + `NetworkManager.service` injection works on real hardware, so
    the test-vs-release stack is unified and the no-UART lockout risk of the rewrite is cleared.
    (Still HW-TODO on this card: confirm `timedatectl` clock-step, `bluetoothctl` sees `hci0`, and
    that `50-nm-reup` re-ups Wi-Fi across a suspend/resume.)
  - 🧹 **Stale docs:** `images/README.md` + a `build-image.sh` comment still describe an **iwd**
    Wi-Fi stack (`/var/lib/iwd/<SSID>.psk`) that the build never used in current code — reconcile to
    NetworkManager (release) / wpa_supplicant-was-the-prior-test-stack.

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

- [x] **No system clock / NTP on the device.** ✅ **DONE (code) — HW UNVALIDATED.** Shipped
  `systemd-timesyncd` config + enablement in the hw-support overlay: `etc/systemd/timesyncd.conf`
  (NTP=pool.ntp.org), `60-novadeck-timesyncd.preset`, and the build-time
  `sysinit.target.wants/systemd-timesyncd.service` + `dbus-org.freedesktop.timesync1.service`
  symlinks. ✅ **HW-VALIDATED 2026-06-25:** clock syncs after reflash. Initial boot showed time stuck
  at epoch — root cause was NOT timesyncd config but `/.dockerenv` baked in by `docker export`, which
  made `systemd-detect-virt`=`docker` so systemd skipped the unit's `ConditionVirtualization=!container`.
  Fixed by `sanitize_base_provenance()` in `assemble-rootfs.sh` (strips the marker). See
  [[dockerenv-systemd-container-misdetect]].
