# Phase 3 bring-up — native arm64 Steam shell (SteamOS layer D)

Goal of this slice: boot the device into the **native arm64 Steam Deck UI** running inside the
Phase-2 gamescope session. FEX/Proton (x86 games) and the Decky control layer come later in
Phase 3 — see `.claude/plans/novadeck.plan.md`.

## What ships (steam/ overlay)

| File | Role |
|------|------|
| `STEAM_SEED.pin` + `fetch-steam-seed.sh` | **Build host**: fetch the native arm64 client seed + SR3 runtime (channel `steamdeck_publicbeta`) into `work/steam-seed/`. `assemble-rootfs.sh` bakes that into the sealed root at `/usr/share/novadeck/steam-seed`. |
| `usr/lib/novadeck/steam-bootstrap.sh` | First-boot **seeder**: copies the baked seed into the **writable** `/home/deck/.local/share/Steam` **OFFLINE** (no CDN), then `chown deck:deck`. Idempotent. |
| `usr/lib/systemd/system/novadeck-steam-bootstrap.service` | First-boot oneshot, after `/home` is mounted + grown and the `deck` user exists. **No network dep.** Self-skips once seeded. |
| `usr/bin/novadeck-steam` | Launcher `NOVADECK_SESSION_CMD` points at: sets `HOME`/`LD_LIBRARY_PATH`, execs the native client **raw on the host** (no pressure-vessel) in `-gamepadui -steamos3 -steampal -steamdeck`. |

The native client **is baked into the sealed RO root** (as a seed under `/usr/share/novadeck`); the
seeder copies it into `/home` on first boot offline, and Steam self-updates the rest in `/home`
across A/B slots. **Storage**: `/home` is a dedicated ext4 partition (`LABEL=novadeck-home`) mounted
via `/etc/fstab`; `novadeck-grow-home.service` grows it + its fs to fill the card on first boot. The
`deck` user (uid 1000) is baked into the base `/etc`. The launcher still runs as the session user
(root today); moving the session to run as `deck` is a follow-up.

## Validate on HW (test card, session stays disabled by default)

1. Flash a `NOVADECK_TEST=1` sdcard (Wi-Fi/SSH), boot, SSH in.
2. Confirm the home grew + the seed copied (both run on first boot, offline — no CDN):
   ```sh
   df -h /home                                           # expect the full card, not ~1GiB
   ls /home/deck/.local/share/Steam/steamrtarm64/steam   # expect the native client (deck-owned)
   ```
   (Or re-run by hand: `/usr/lib/novadeck/novadeck-grow-home` then `/usr/lib/novadeck/steam-bootstrap.sh`.
   `novadeck-session` `Wants=` the seeder and orders after it + the grow.)
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
