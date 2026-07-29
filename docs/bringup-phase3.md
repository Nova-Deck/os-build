# Phase 3 bring-up — native arm64 Steam shell (SteamOS layer D)

Goal of this slice: boot the device into the **native arm64 Steam Deck UI** running inside the
Phase-2 gamescope session. FEX/Proton (x86 games) and the Decky control layer come later in
Phase 3 — see `.claude/plans/novadeck.plan.md`.

## What ships (steam/ overlay)

| File | Role |
|------|------|
| `STEAM_SEED.pin` + `fetch-steam-seed.sh` | **Build host**: fetch the native arm64 client seed + SR3 runtime (channel `steamdeck_publicbeta`) into `work/steam-seed/`. `make-sdcard.sh` pre-seeds it **directly into the `/home` partition** — the only client copy in the image. |
| `usr/bin/novadeck-steam` | Launcher `NOVADECK_SESSION_CMD` points at: sets `HOME`/`LD_LIBRARY_PATH`, execs the native client **raw on the host** (no pressure-vessel) in `-gamepadui -steamos3 -steampal -steamdeck`. |

The native client is **pre-seeded directly into the `/home` partition** by `make-sdcard.sh` (a
ready-to-run `/home/deck/.local/share/Steam`, owned `deck:deck` via `mkfs.ext4 -d`), so a healthy
first boot does **no copy** and needs no network — Steam's own OOBE owns first-boot Wi-Fi. The
pre-seeded `/home` is the **only** client copy: there is no recovery seed baked into the root and no
in-place re-seeder. A factory reset is a **reflash of the card** (a UFS install is recovered by
booting a separate SD-card image). Steam self-updates the rest in `/home` on first launch.
**Storage**: `/home` is a dedicated ext4 partition (`LABEL=novadeck-home`) mounted via `/etc/fstab`,
sized at build to just fit the seed; `novadeck-grow-home.service` grows the partition + its fs to
fill the card on first boot. The `deck` user (uid 1000) is baked into the base `/etc`. The launcher
still runs as the session user (root today); moving the session to run as `deck` is a follow-up.

## Validate on HW (test card, session stays disabled by default)

1. Flash a `NOVADECK_DEV=1` sdcard (Wi-Fi/SSH), boot, SSH in.
2. Confirm the home grew and the pre-seeded client is present (offline — no CDN):
   ```sh
   df -h /home                                           # expect the full card, not ~2GiB
   ls /home/deck/.local/share/Steam/steamrtarm64/steam   # expect the native client (deck-owned)
   ```
   (The client ships pre-seeded in the image; only the grow runs on first boot —
   re-run by hand with `/usr/lib/novadeck/grow-home.sh` if needed. There is no in-place
   reset: reflash the card to factory-reset.)
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
