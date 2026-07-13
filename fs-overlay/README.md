# fs-overlay — the unified rootfs overlay payload

Every SoC-agnostic file that novadeck lays over the base rootfs lives here, in **one tree that
mirrors the target filesystem exactly**. `images/assemble-rootfs.sh` injects it with a single
`cp -a fs-overlay/. "$stage/"` (release path, step 4b). The tree carries final paths, executable
bits (tracked in git), and the systemd presets + `*.target.wants` symlinks that enable each
service — so the assembler generates and `chmod`s nothing. Ownership is normalized to `root:root`
afterwards (assemble step 4z).

This directory replaces the former per-subsystem trees (`session/ hw-support/ audio/ fex/usr
steam/usr devices/inputplumber`), which each mirrored `/` separately. There are **no path
collisions** between the merged layers; every file lands at a unique target path.

## Layers (what each backing does, and why)

**Input — `etc/inputplumber/`** (SteamOS layer, part of every build)
InputPlumber's device/profile config: the union of every supported board's config. InputPlumber
matches by hardware, so non-matching configs are inert. It overrides the package's
`/usr/share/inputplumber` defaults ONLY via the `.d` dirs it scans under `/etc` — composite
configs in `devices.d/` and capability maps in `capability_maps.d/`. Do **not** rename them to the
un-suffixed `devices`/`capability_maps` (those apply only under `/usr/share`) or the configs load
from nowhere and no composite device is built. Enabled by a shipped
`usr/lib/systemd/system-preset/60-novadeck.preset` (60 < the stock 99 "disable *") plus a
`multi-user.target.wants/inputplumber.service` symlink.

**Session (layer B) — gamescope-session plumbing**
The boot-to-compositor path: launcher `/usr/bin/novadeck-session` + its `/etc/novadeck/session.conf`,
SDDM autologin wiring, PAM drop-ins, and `default.target -> graphical.target`. The device boots
through SDDM autologin the SteamOS way, giving a REAL active `seat0` logind session (so stock polkit
authorizes Wi-Fi/timezone). `seatd.service` stays enabled — the launcher opens the DRM seat via the
persistent root seatd; SDDM only wraps it in a login session. See `docs/bringup-phase2.md` step 2.

**HW-support (layer C) — Qualcomm backings for Deck-UI affordances**
The stand-ins for AMD's `jupiter-hw-support`: `novadeck-rest` (userspace "rest mode"/fake-suspend),
the suspend engine (a `systemd-suspend.service` drop-in redirects logind `Suspend()` into
`novadeck-suspend`; `novadeck-powerbuttond` forwards the power key to Steam), Bluetooth, and
`systemd-timesyncd`. All enabled via shipped presets + `*.target.wants` symlinks. No Wi-Fi resume
hook ships (NM re-associates unaided). See `docs/bringup-phase2.md` step 3.

**Audio (layer C) — ALSA UCM2 machine profiles**
`usr/share/alsa/ucm2/Qualcomm/sm86{50,55}/<CARD>/` profiles, card-name-matched via relative symlinks
under `conf.d/sm86{50,55}/` (preserved by `cp -a`). They `Include` codec snippets that the base
`alsa-ucm-conf` package must provide (SM8550 uses wcd938x, SM8650 wcd939x).

**FEX (layer) — x86 emulation runtime config**
`usr/share/fex-emu/Config.json` + the Proton FEX profiles + `usr/lib/novadeck/proton-wrapper`. The
binaries come from pacman; this tree is config only. Two independent x86 paths: Windows games use
Proton's own bundled WoW64 FEX (no system FEX/rootfs); native x86 Linux ELFs use the `fex-emu`
package + guest rootfs (auto-registered with binfmt_misc). See `docs/FEX_README.md`.

**Steam shell (layer D) — native arm64 Steam plumbing**
`usr/bin/novadeck-steam` (the session launcher target), the OOBE update-check stubs
(`steamos-update`, `steamos-mandatory-update`, `jupiter-biosupdate`,
`jupiter-initial-firmware-update` — SteamUI shells to these past the Wi-Fi/timezone screens), and
`50-novadeck-timezone.rules` (the one polkit grant stock polkit still prompts for). The Steam client
SEED itself is build machinery, not rootfs content — it lives in `../steam-seed/` and is pre-seeded
into `/home` at image build time (`images/make-sdcard.sh`). See `docs/bringup-phase3.md`.
