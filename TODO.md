# novadeck — follow-up TODO

Deferred work. Closed items keep a one-line resolution + HW-validation date; the full
rationale lives in the linked memories and commit history.

## Open

- [ ] **OOBE timezone not set — polkit denies `timedate1.set-timezone`** (cosmetic; clock only).
  HW logs: Steam calls systemd-timedated directly (not our helper) → `Failed to set time zone:
  Permission denied` → Steam logs `JSSetTimeZone: system() failed, errno 11` (errno is STALE — the
  real cause is the polkit deny; NOT a resource limit, all NPROC/pid_max/TasksMax ceilings are huge).
  Puzzle: `50-novadeck-steamos.rules` grants `deck` and NM `connection-add` succeeds for the same
  process, yet the structurally-identical `timedate1.set-timezone` clause is denied. `polkit.log()`
  from a rule is NOT captured in our journal stream (even on the granted NM path), so it gave no data
  on `subject.user`. Next step needs heavier instrumentation: run `polkitd --debug` with
  `G_MESSAGES_DEBUG=all` to see the actual subject/decision. Suspect a short-lived-caller subject
  resolution difference (timedatectl exits fast vs the long-lived NM caller). Low priority — Wi-Fi
  (the real blocker) is fixed. See [[wifi-connect-fails-after-list]].

- [ ] **Preseed `/home/deck` in the image instead of first-boot copy** — today the baked Steam seed
  ships at `/usr/share/novadeck/steam-seed` on the RO root and `novadeck-steam-bootstrap.service`
  copies it into the writable `/home/deck` on first boot (offline; see [[steam-must-be-baked-offline]],
  [[steam-offline-sdl3-seed]]). Instead, stage the seed directly into the `/home` partition image at
  build time (`images/assemble-rootfs.sh` / the home genpart) so first boot has nothing to copy —
  faster first boot, and it drops the duplicate ~75M+ seed from the root. Watch: `/home` grows to
  fill the card on first boot (`novadeck-grow-home`), and ownership must be `deck:deck`.

- [ ] **Audio works on test build but not release** — REGRESSION / OPEN. Sound played once
  when the SteamUI session was started from a **test-build** SD card (deck user-session: ADSP
  loaded, per-user PipeWire + UCM ok). On a **release build there is no sound**. Stack is shipped
  (PipeWire / wireplumber / pipewire-pulse / -alsa + alsa-ucm-conf in PKGS; device UCM2 profiles in
  the `audio/` overlay — cards SM8650-APS2 Pocket S2, SM8650-KPF Konkr), so the gap is in
  release-vs-test session/runtime wiring, not the audio packages themselves. Diff the test session
  path (what made it work once) against the release path. See [[audio-l4-deferred-to-user-session]].

- [ ] **`--ready-fd` ready-then-launch handshake** — candidate mitigation for the residual
  Phase-2 gamescope re-launch wedge (below). Run gamescope bare, launch the client only after
  it signals ready via `--ready-fd`. Prototyped, never proven to reliably dodge the wedge. Only
  relevant if a session restart (WSI on) actually wedges in the field.

## Phase 2 — gamescope session (closed)

- [x] **Clean gamescope teardown / re-launch wedge** — WON'T-FIX (HW-disproven 2026-06-25).
  The re-launch (L2) wedge is a userspace never-signaling syncobj fence in gamescope's
  `linux-drm-syncobj` WSI handshake, not stale GPU/DRM state — a clean SIGTERM teardown doesn't
  prevent it (~50% either way; dmesg shows zero GPU faults). **Decision: keep
  `ENABLE_GAMESCOPE_WSI=1`** (upstream/ChimeraOS default; FROG WSI gives frame pacing, latency,
  adaptive-sync, HDR). Release launches gamescope once per power-on (clean L1, 10/10), so it
  should not bite. `=0` (implicit sync, 8/8 clean re-launch) is the env-overridable fallback.
  **Residual risk OPEN**: `Restart=on-failure` / a deliberate session restart takes the L2 path.
  Dead ends (do not retry): `--immediate-flips` (KMS-unsupported on msm), a Turnip/Mesa bump.
  Re-validation harness on the test device: `/root/freeze-trial-graceful.sh`. See [[sm8650-gamescope-flip-blocker]].

## Phase 2 — HW-support layer C (closed)

- [x] **Fold power ops into the suspend path** — DONE + HW-validated 2026-06-24. Reversible
  primitives (cpu-offline, rfkill, cpu+gpu powersave governor) extracted to
  `hw-support/usr/lib/novadeck/power-ops.sh` (`power_enter`/`power_leave`); applied after the
  freeze, restored before the thaw. Guard: `NOVADECK_SUSPEND_SKIP`.
- [x] **Power-key suspend trigger** — DONE. `novadeck-waked` (logind `HandlePowerKey=ignore` +
  libinput on the power key): tap → `novadeck-suspend toggle`. Enabled at boot via overlay preset.
- [x] **Long-press power = clean shutdown** — DONE + HW-validated 2026-06-24. Hold ≥
  `NOVADECK_WAKE_LONGPRESS_MS` (default 2000ms) thaws then `systemctl poweroff`. Knob in `rest.conf`.
  See [[waked-holdtime-background-dispatch]].
- [x] **`do_resume` must not call systemctl while frozen** — DONE + HW-validated 2026-06-24. The
  system D-Bus daemon is in the frozen `system.slice`, so a pre-thaw systemctl blocked ~90s. Thaw
  first, then systemctl; power-restore stays pre-thaw (pure sysfs). See [[suspend-systemctl-while-frozen-blocks]].
- [x] **Bluetooth stack** — DONE + adapter HW-validated 2026-06-25. `bluez`/`bluez-utils` in PKGS,
  `bluetoothd` enabled via overlay; WCN7850 BT firmware ships. Controller pairing exercised in the
  Phase-3 Steam shell (known-good ROCKNIX path).
- [x] **Release Wi-Fi resume after suspend** — DONE + HW-validated 2026-06-25, no hook needed.
  NetworkManager re-associates unaided after a freeze+rfkill cycle. Test card rewritten to NM
  (`.nmconnection` keyfile) so test == release stack; `50-nm-reup` dropped as moot; docs reconciled
  off iwd. See [[wifi-config-is-test-only]], [[suspend-ssh-survives-established]].
- [x] **System clock / NTP** — DONE + HW-validated 2026-06-25. `systemd-timesyncd` config +
  enablement in overlay. The epoch-stuck clock root cause was `/.dockerenv` (→
  `systemd-detect-virt=docker` skipped the unit's `ConditionVirtualization`); fixed by
  `sanitize_base_provenance()`. See [[dockerenv-systemd-container-misdetect]].
