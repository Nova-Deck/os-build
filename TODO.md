# novadeck — follow-up TODO

Deferred work. Closed items keep a one-line resolution + HW-validation date; the full
rationale lives in the linked memories and commit history.

## Open

- [x] **OOBE timezone not set — polkit denies `timedate1.set-timezone`** — RESOLVED, HW-confirmed
  2026-07-02. The real fix was giving the shell a real ACTIVE seat0 logind session: boot via **SDDM
  autologin** and let gamescope use libseat's **logind** backend (NOT forced `LIBSEAT_BACKEND=seatd`,
  which keeps the session inactive). Then the stock `subject.active && isInGroup("wheel")` rule
  (`50-novadeck-timezone.rules`, deck∈wheel) grants it, and NM's OOBE Wi-Fi rides `allow_active` with
  no rule at all — so the old broad `50-novadeck-steamos.rules` "no-active" bypass was deleted. Journal
  proof: the OOBE tz picker set every zone (…→`Europe/Paris`) with ZERO "Permission denied". Also fixed
  in the same pass: `/etc` was deck-owned (overlay `cp -a` preserved the build uid) → assemble-rootfs
  now normalizes overlay ownership to root. See [[sm8650-gamescope-session-plumbing]],
  [[wifi-connect-fails-after-list]].

- [x] **OOBE update-check error after Wi-Fi/timezone** — RESOLVED, HW-confirmed 2026-07-03. Past the
  Wi-Fi/timezone screens SteamUI shells to update-check helpers (confirmed in `steamui.so`):
  `steamos-update` + `jupiter-biosupdate` via the polkit-helpers wrapper, and `steamos-mandatory-update`
  + `jupiter-initial-firmware-update` on PATH. We bake no jupiter-hw-support and have no Phase-1 OS
  updater, so those were missing and OOBE errored. Fix: no-op stubs under `steam/usr/bin/` that report
  "up to date" (exit 7 on `check`, else 0), matching Valve's/Armada's contract. First boot now clears
  the update screen (the one post-Wi-Fi reboot is normal SteamOS first-run). Commit `8aa5283`.

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

- [ ] **Stable Wi-Fi + Bluetooth MAC addresses (first-boot)** — the WCN7850 comes up without a
  persistent MAC (no vendor NVRAM/`nvmem` MAC path on this SM8650 port), so the Wi-Fi and BT
  addresses are non-deterministic across boots (random/locally-administered, and identical across
  units flashed from the same image). Generate a **stable per-device MAC once on first boot** —
  derive it from a hardware-unique seed (SoC serial / `machine-id`) with the locally-administered
  bit set, persist it, and apply it: Wi-Fi via a NetworkManager `ethernet.cloned-mac-address` /
  `wifi.cloned-mac-address` (or `.link` `MACAddress=`) keyfile, Bluetooth via a `btmgmt public-addr`
  (or `hci0` `.link`) one-shot before `bluetoothd`. Must be idempotent (write-once, survive reboots)
  and land on the writable side, not the RO root. Relates to [[wifi-config-is-test-only]].

- [ ] 🍒 **Cherry on top: install to internal UFS + SD card as game library** — today NovaDeck
  runs from a dd'd SD-card image (Phase 1). Ultimately we want a real **installer that lays the
  image down on the device's internal UFS** (like SteamOS on the Deck's internal drive), and then
  repurposes the **SD card as an external Steam game library**. SteamOS already ships the format
  helpers for the library step — `steamos-format-sdcard` / `steamos-format-device` (seen in the
  baked `steamui.so` strings next to the OOBE update helpers), called by Settings > Storage — which
  we have NOT wired up yet (candidate to port). Our ext4 `novadeck-home` already matches SteamOS
  (plain-dir libraries, no btrfs nodatacow dance — Armada's `steamapps` subvolume is Armada-only, do
  not port). Fits the Phase-4 manifest/immutable model. See
  [[install-to-ufs-sdcard-library-goal]], [[grow-home-repart-no-initramfs]], [[rootfs-build-approach]].

- [ ] **MangoHud performance overlay via `--mangoapp`** — ship the Deck-style FPS/perf overlay.
  Add `mangohud` (+ its `mangoapp` companion) to the image (`customize-base.sh` PKGS if it resolves
  in the holo repo, else a `packages/` overlay build), and pass `--mangoapp` to gamescope in the
  novadeck session launch (`session/` gamescope-session). This is how SteamOS/Armada/ROCKNIX drive
  the overlay: gamescope spawns `mangoapp` as an in-session overlay window and SteamUI's
  Performance settings toggle its level — so it wires up to the existing Deck UI, no extra config.
  Confirm the arm64 `mangohud`/`mangoapp` packages exist in holo before adding (cf.
  [[holo-pacman-no-gtk2]] — don't assume a package resolves), and that gamescope was built with
  mangoapp support. See [[sm8650-gamescope-session-plumbing]].

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
