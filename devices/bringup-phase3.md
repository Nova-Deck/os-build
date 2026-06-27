# Phase 3 bring-up — native arm64 Steam shell (SteamOS layer D)

Goal of this slice: boot the device into the **native arm64 Steam Deck UI** running inside the
Phase-2 gamescope session. FEX/Proton (x86 games) and the Decky control layer come later in
Phase 3 — see `.claude/plans/novadeck.plan.md`.

## What ships (steam/ overlay)

| File | Role |
|------|------|
| `usr/lib/novadeck/steam-bootstrap.sh` | Stages the native arm64 client seed + arm64 runtime into the **writable** `/home/deck/.local/share/Steam` (channel `steamdeck_publicbeta`). Idempotent. |
| `usr/lib/systemd/system/novadeck-steam-bootstrap.service` | First-boot oneshot that runs the bootstrap before the session (needs network + synced clock). Self-skips once staged. |
| `usr/bin/novadeck-steam` | Launcher `NOVADECK_SESSION_CMD` points at: sets `HOME`/`LD_LIBRARY_PATH`, execs the native client in `-gamepadui -steamos3 -steampal -steamdeck`. |

No Steam blobs are baked into the sealed RO root — Steam self-updates in `/home` across A/B slots.
Runs as root (matches the Phase-2 session and ROCKNIX, which runs native arm Steam as root).

## Validate on HW (test card, session stays disabled by default)

1. Flash a `NOVADECK_TEST=1` sdcard (Wi-Fi/SSH), boot, SSH in.
2. Stage Steam by hand first (so a slow CDN fetch is observable, not racing the session):
   ```sh
   /usr/lib/novadeck/steam-bootstrap.sh
   ls /home/deck/.local/share/Steam/steamrtarm64/steam   # expect the native client
   ```
   (Or just `systemctl start novadeck-session` — it `Wants=` the bootstrap and orders after it.)
3. Launch the shell, watch the panel:
   ```sh
   systemctl start novadeck-session
   journalctl -fu novadeck-session
   ```
   Expect: Steam self-updates + downloads the UI on first launch, then Big Picture / Deck UI
   appears upright on the panel (same rotation path the Phase-2 vkcube smoke validated).
4. To fall back to the liveness placeholder: set `NOVADECK_SESSION_CMD="vkcube"` in
   `/etc/novadeck/session.conf` and restart the session.

## Open / next (later in Phase 3)

- Move the seed stage to **build time** (Armada's headless-Xvfb pre-bootstrap) once the on-device
  path is proven, so first boot is offline-fast. Keep the script usable in both modes.
- FEX-Emu + binfmt + Turnip-into-FEX thunks; one x86 Proton title end-to-end.
- Decky-pattern control layer (novadeck-own plugin) — TDP/fan/per-game FEX+Proton.
- Flip `novadeck-session.service` to boot-enabled (preset) once Steam is validated on HW.
- Proton stays a **user choice** (not baked) — see plan.
