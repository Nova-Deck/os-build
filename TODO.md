# novadeck — follow-up TODO

Tracking work that is understood but deliberately deferred. Each item links to the
investigation that produced it.

## Phase 2 — gamescope session

- [x] **Clean gamescope teardown (root-cause fix for the re-launch wedge).** ✅ **CLOSED —
  WON'T-FIX, investigated + HW-disproven 2026-06-25.** The premise (make teardown clean → drop
  `ENABLE_GAMESCOPE_WSI=0` → recover HDR) does not hold. On HW (`192.168.1.186`), the re-launch
  path was re-measured with a **graceful SIGTERM** teardown (the real `systemctl restart` /
  target-switch path, not the old SIGKILL harness), WSI **on**:
  - **WSI on + graceful SIGTERM:** L2 re-launch wedged **4/8** — the *same* ~50% wedge as the
    SIGKILL harness (step 1e's 7/10). **Teardown cleanliness is irrelevant** — a clean gamescope
    exit leaves the same contamination.
  - **WSI off (`ENABLE_GAMESCOPE_WSI=0`) on the identical path:** **8/8 SPIN, 0 wedge.**
  - **dmesg across every trial: zero GPU faults / hangcheck / recovery / syncobj-timeout.** The
    GPU never hangs and DRM-master is not stale (either would log and/or clear on a clean exit).
    The wedge is an intermittent **never-signaling syncobj fence in gamescope's `linux-drm-syncobj`
    WSI handshake on re-launch** — a userspace logical deadlock, not driver/HW state.
  - **Conclusion (HW characterization):** the wedge is a userspace WSI explicit-sync syncobj race,
    bites only re-launch (L2), and `ENABLE_GAMESCOPE_WSI=0` (implicit sync) makes re-launch 8/8 clean.
  - **DECISION REVISED 2026-06-26 — keep `ENABLE_GAMESCOPE_WSI=1` (do NOT ship =0).** Upstream
    gamescope + ChimeraOS `gamescope-session-plus` keep WSI on; the FROG WSI layer is the standard
    present path (framerate limiter / frame pacing, latency, adaptive-sync hints AND HDR), so
    disabling it is NOT only an HDR loss — it degrades all of those. The release product launches
    gamescope ONCE per power-on (the clean L1 case, 10/10), so the re-launch wedge should not bite.
    `=0` is the env-overridable **fallback** if `Restart=on-failure` / a session restart ever wedges
    in the field. Launcher + smoke now default `ENABLE_GAMESCOPE_WSI=${...:-1}`. **Residual risk: OPEN.**
  - Re-validation harness now lives on the test device at `/root/freeze-trial-graceful.sh`
    (`WSI=0|ON TEARDOWN=TERM|KILL N=<trials>`; client-GPU oracle = `drm-engine-*` fdinfo delta).
    DHCP IP drifts — `192.168.1.186` as of 2026-06-25.

- [ ] **`--ready-fd` ready-then-launch handshake (candidate mitigation for the residual L2 wedge).**
  Run gamescope bare and launch the client only after it signals ready via `--ready-fd`. Prototyped
  but never proven to reliably dodge the re-launch wedge. Only relevant now as a possible fix for the
  residual-risk path (session restart with WSI on) — not needed unless that bites in the field.

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
  already ships (assemble-rootfs.sh block 3b). ✅ **HW-VALIDATED 2026-06-25:** `bluetoothctl list`
  shows the adapter up — `Controller 00:03:7F:65:52:07 archlinux [default]` (00:03:7F = Qualcomm/
  Atheros OUI = WCN7850 BT radio), so bluetoothd runs, firmware loaded, and the overlay enablement
  took. **Pairing sub-check — accepted as low-risk, no dedicated test (2026-06-26):** the WCN7850
  radio + identical BlueZ stack already pair/connect controllers under ROCKNIX on this hardware, and
  our adapter is confirmed up, so controller pairing is a known-good path rather than an open unknown.
  It will be exercised for real in the Phase-3 Steam shell (gamepadui Bluetooth); no separate
  bring-up test ships.

- [x] **Release Wi-Fi resume after userspace suspend.** ✅ **DONE + HW-validated 2026-06-25 (.186) —
  no hook needed.** NetworkManager re-associates Wi-Fi **unaided** after a `novadeck-suspend` cycle
  (freeze + rfkill soft-block → unblock + thaw); no resume-time nudge ships. The generic `resume.d`
  drop-in point in `novadeck-suspend` remains for future fix-ups, just empty by default.
  - ✅ **Resolved the test-vs-release stack split (2026-06-25):** `networkmanager` added to
    `customize-base.sh` PKGS, and the TEST Wi-Fi injection rewritten to use NM (drops an
    `.nmconnection` keyfile + enables `NetworkManager.service`) instead of `wpa_supplicant@wlan0` +
    `systemd-networkd`. The throwaway card now runs the **same manager as release**, so the real
    release Wi-Fi stack (incl. suspend recovery) is exercisable on HW. A plain release base still
    leaves NM inactive (no auto-enable preset); enabling it for release is the Phase-3 Steam-UI step.
  - ✅ **HW-VALIDATED 2026-06-25 (IP 192.168.1.186):** the NM-based test card joined the LAN and
    accepts SSH — the `.nmconnection` + `NetworkManager.service` injection works on real hardware, so
    the test-vs-release stack is unified and the no-UART lockout risk of the rewrite is cleared.
  - ✅ **`50-nm-reup` dropped as moot 2026-06-25 (.186):** isolated the hook by disabling it and
    re-running a real freeze+rfkill suspend/resume from an un-frozen `wake.slice` driver — NM came back
    `connected` with a live gateway route in ~1s, no nudge. The suspend path pokes sysfs rfkill
    directly and never flips NM's `WirelessEnabled` flag, so `nmcli radio wifi on` was a no-op anyway;
    forcing `connection up` even bounced a healthy link. Hook removed from the overlay. (An established
    SSH session rides through the cycle untouched — only NEW connections fail while frozen; see
    `suspend-ssh-survives-established` memory.)
  - ✅ **Docs reconciled to NetworkManager (2026-06-25):** the old iwd-stack mentions
    (`/var/lib/iwd/<SSID>.psk`) in `images/README.md` + `build-image.sh` are gone — both now describe
    the NM `.nmconnection` keyfile path. No stale iwd refs remain anywhere in the tree.

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
