# novadeck

**A Steam Deck–style gaming OS for Qualcomm Snapdragon handhelds.**

Turn an AYANEO Pocket, AYN Odin, Retroid Pocket, KONKR or MANGMI handheld into a console-like
machine: boot straight into the Steam UI, browse your library with the gamepad, and play —
including Windows games, translated to ARM on the fly.

[**Join the Discord →**](https://discord.com/invite/fqVfmjWc9y)

---

## What you get

- **Boots into Steam.** No desktop to fight, no launcher to configure. Power on, and you are in
  your library with the controller already working.
- **Your Windows games run.** x86 and x86-64 titles go through Proton and FEX-Emu, so a lot of
  your existing library works without the developer ever shipping an ARM build.
- **Real GPU acceleration.** Native Vulkan on Adreno via Mesa Turnip — not software rendering.
- **Updates that cannot brick it.** The system is read-only and installs to one of two slots. If
  an update fails to boot, the device rolls back to the version that worked.
- **Suspend and resume**, per-device power profiles, brightness and volume keys, and the
  Quick Access menu — the handheld things you would miss immediately if they were missing.
- **Tuning from inside the UI.** Every image ships Decky Loader and two first-party plugins:
  **novadeck-control** (power profile, GPU clocks, an editable fan curve, and performance
  settings you can pin *per game* rather than globally) and **novadeck-monitor** (live load,
  clocks, temperatures and fan speed while a game runs).

### Honest status

novadeck is **early**. It boots, plays games, and updates itself on real hardware — but it is a
project under active development, not a finished product. Expect rough edges, expect to read the
docs, and expect to be able to recover a device you have unlocked.

You need an **unlockable bootloader**, a spare **SD card**, and the device already running the
**[ROCKNIX ABL](https://github.com/ROCKNIX/abl)** — the custom bootloader that can start a Linux
system on these handhelds at all. novadeck does not ship one and cannot build one, so flashing
that comes first; on a stock Android bootloader a novadeck card simply does nothing. The
[runbook](docs/RUNBOOK.md#prerequisite-the-device-already-runs-the-rocknix-abl) covers it, and if
you already run ROCKNIX you have it.

novadeck runs from the card and does not touch your Android install.

## Supported devices

<!-- AUTO-GENERATED from rootfs/overlay/usr/lib/novadeck/devices/*.conf — regenerate with /ecc:update-docs -->

| Board | SoC | Profile | HW-validated |
|---|---|---|---|
| AYANEO Pocket S2 | SM8650 | `ayaneo-pocket-s2` | yes |
| KONKR Pocket FIT | SM8650 | `konkr-pocket-fit` | yes |
| AYANEO Pocket ACE | SM8550 | `ayaneo-pocket-ace` | yes |
| AYN Odin 2 | SM8550 | `ayn-odin-2` | yes |
| AYN Thor | SM8550 | `ayn-thor` | yes |
| Retroid Pocket Nova | SM8550 | `retroid-pocket-nova` | yes (120 Hz mode selection open) |
| AYN Thor Lite | SM8250 | `ayn-thor-lite` | yes |
| MANGMI Pocket Max | SM8250 | `mangmi-pocket-max` | yes |
| Retroid Pocket 5 | SM8250 | `retroid-pocket-5` | yes (user report) |
| Retroid Pocket Flip2 | SM8250 | `retroid-pocket-flip2` | yes (user report) |
| AYANEO Pocket DMG | SM8550 | `ayaneo-pocket-dmg` | — |
| AYANEO Pocket DS | SM8550 | `ayaneo-pocket-ds` | no - panel stays black |
| AYANEO Pocket EVO | SM8550 | `ayaneo-pocket-evo` | no - panel stays black |
| AYANEO Pocket S 1K | SM8550 | `ayaneo-pocket-s1k` | — |
| AYANEO Pocket S 2K | SM8550 | `ayaneo-pocket-s2k` | — |
| AYN Odin 2 Mini | SM8550 | `ayn-odin-2-mini` | — |
| AYN Odin 2 Portal | SM8550 | `ayn-odin-2-portal` | yes |
| Retroid Pocket 6 | SM8550 | `retroid-pocket-6` | — |
| Retroid Pocket Mini | SM8250 | `retroid-pocket-mini` | — |
| Retroid Pocket Mini V2 | SM8250 | `retroid-pocket-mini-v2` | — |

<!-- END AUTO-GENERATED -->

**"HW-validated"** means someone has actually booted novadeck on that unit; **"(user report)"**
marks the ones where that someone was a user rather than us, so we cannot debug them first-hand.
The rest ship support data that looks right but has never met the hardware — they may work, and
reports either way are genuinely useful.

> **SM8250 boards have no sensor DSP.** The `slpi.mbn` firmware for that SoC is published in no
> open source, so every Snapdragon 865 board is without its accelerometer — no auto-rotation.
> Everything else works; this one is blocked on a blob we cannot ship.

One image serves every device. There is no per-device download: the running system identifies the
board and configures itself.

## Getting it

Cards are published on the [**Releases**](https://github.com/Nova-Deck/os-build/releases) page.
Each release lists a download link plus a `sha256sums.txt` to check it against.

```sh
# download the card, verify it, write it
sha256sum -c sha256sums.txt
gzip -dc sdcard.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
```

Then follow [**the runbook**](docs/RUNBOOK.md) — it covers flashing, getting a shell on the
device, installing updates, and recovering one that will not boot. Read the recovery section
*before* you need it.

> The image is ~5 GiB compressed and it is served from object storage rather than as a GitHub
> release file, which caps attachments at 2 GiB. The release notes carry the link.

## Community

Questions, bug reports, device compatibility, or just watching it come together:

[**discord.com/invite/fqVfmjWc9y**](https://discord.com/invite/fqVfmjWc9y)

If you are reporting a problem, `/etc/novadeck-release` on the device names the exact build you
are running — include it.

## Acknowledgements

novadeck stands on work other people did first, and two projects deserve naming.

**[ROCKNIX](https://rocknix.org/)** — and this project would not exist without them, which is
meant literally rather than as a courtesy.

Their **ABL work is the foundation everything else here stands on.** These handhelds ship an
Android bootloader that will not load an ordinary Linux boot flow; solving how to get a kernel
started on them at all is the problem that gates every other problem. Without it there is no
display to bring up, no session to launch and no game to run — there is a device that does not
boot. novadeck boots the way it does because ROCKNIX worked that out first.

Beyond that: the kernel enablement, the device trees, and the patient device-by-device bring-up
that nobody sees and everybody depends on. Much of what makes this class of hardware usable under
Linux traces back to that effort.

**Armada** showed that a Steam-style handheld experience on this class of hardware was a real
target rather than a nice idea, and demonstrated a great deal about how the pieces fit together.

novadeck is its own project with its own choices, and any mistakes here are ours — but it would
be dishonest not to say that both made the path visible. Thank you.

Thanks also to Valve and Collabora, whose aarch64 Arch port novadeck builds on, and to the Mesa,
FEX-Emu, gamescope and RAUC projects.

---

## For developers

<details>
<summary><b>Building, contributing, and how the thing is put together</b></summary>

### What it actually is

An immutable, A/B-updatable aarch64 Linux distribution that forks SteamOS 3 "Holo" onto Qualcomm
mobile silicon (**SM8250 / SM8550 / SM8650**). The root is read-only, bootstrapped from packages
into a sealed Btrfs image; updates are RAUC bundles installed to the inactive slot behind a custom
`novadeck-bootctl` bootloader backend.

The build is **unified** — one image for every supported SoC, one kernel carrying the union of
drivers and DTBs. There is no `SOC` argument.

### Build

Everything goes through the top-level `Makefile`, which wires the per-stage scripts into one
incremental graph and pins where each stage runs. Kernel, rootfs assembly, boot packaging and
bundling all cross-compile inside the `novadeck-build` Docker image. **Never invoke the stage
scripts by hand.**

```sh
make help                       # every target and knob
make sdcard                     # full image -> out/images/sdcard.img
make kernel                     # Image + dtbs + modules
make test                       # offline suites: no build, no container, no root, no device
```

Dev vs release is selected by **environment**, not by a make knob, and it must be sourced before
*every* invocation — a bare `make` afterwards flips the mode and rebuilds the other one:

```sh
set -a; . ./dev.env; set +a
```

A **release** image (no `NOVADECK_DEV`) builds locally too — it just cannot be *published*, since
the R2 and OTA signing credentials only exist in CI. `NOVADECK_DEV=1` is the developer path: Wi-Fi
creds, an SSH key and the dev package set baked in.

<!-- AUTO-GENERATED from Makefile — regenerate with /ecc:update-docs -->

| Knob | Default | Effect |
|---|---|---|
| `BASE_CONFIG` | *(unset)* | Repo-relative path to a full verbatim kernel `.config` — skips the defconfig+fragment merge in `kernel/build.sh` |
| `NOVADECK_VERSION` | *(unset — renders `dev`)* | The release this build calls itself. Stamped into `/etc/novadeck-release` **and** read back out of the image to name the RAUC bundle, so the two cannot disagree. Set it before the rootfs is built; changing it re-assembles |
| `NOVADECK_SLOT_B` | *(follows the mode — dev populates B, release leaves it empty)* | Force slot B populated (`1`) or empty (`0`) on the card. `0` is a faster dev loop whose first slot switch can only exercise failover |
| `NOVADECK_DEBUG` | *(unset)* | Diagnostic build, **independent of `NOVADECK_DEV` and valid for release too**: persistent journald synced every 5s so a power-yank keeps the logs, no rate limit, plus a `/usr/lib/novadeck/debug` sentinel that turns on Steam's CEF DevTools. Never ship one — the constant fsync beats on the card |
| `ESP` | *(unset)* | Mounted EFI System Partition, the install target for `make deploy` |
| `BUNDLE` / `CHANNEL` | *(no default — `publish-bundle` refuses without `BUNDLE`)* / `stable` | The bundle `make publish-bundle` uploads, and the OTA channel it lands on. Needs `NOVADECK_OTA_SSH_KEY` |
| `PKIDIR` | *(unset)* | Signing PKI, mounted read-only at `/pki`; makes `bundle` sign for real and adds `test-signing`'s keyring check. Unset, `bundle` mints an ephemeral dev cert |
| `RAUC_CERT` / `RAUC_KEY` | `/pki/release.{cert,key}.pem` when `PKIDIR` is set | Override the signing pair with paths the *container* can see |
| `OVERLAY_ARCH` | `aarch64` | Scopes the built overlay pacman repo at `work/repo/<arch>/` |
| `BUILD_IMG` | `novadeck-build` | Name of the cross-compile Docker image |
| `SIGN_IMG` | `novadeck-sign` | Name of the signing-only image `test-signing` builds and runs |

<!-- END AUTO-GENERATED -->

### Repository layout

| Path | Purpose |
|---|---|
The tree follows the order a build happens in: assemble a root, lay it onto a disk, ship it to a
device.

| Path | Purpose |
|---|---|
| `rootfs/` | **What is inside a root.** The package closure (`manifest.lock` + its generator and materializer), the bootstrap that lays it down, and the seal/trim/guard trio that says what a release root must not be able to do |
| `rootfs/overlay/` | The payload injected into every root with a single `cp -a` — one tree mirroring the device's own filesystem |
| `rootfs/conf/` | The declarative inputs: `pacman.conf`, `os-release`, `trim.list`, `seal.list` |
| `image/` | **Turning a root into partitions.** The A/B layout and its `sgdisk` emitter, the initramfs, the card assembler, and the verifier that reads the result back |
| `ota/` | **Getting an image onto a device already in the field.** Signed RAUC bundles and the signing CA that mints their cert, the publishers, and the nginx/CI-user setup for the OTA host |
| `installer/` | The standalone installer medium: the read-only board probe, the partition carve, and the on-device UI |
| `packages/` | From-source overlay: PKGBUILDs + source pins for what we patch or version-bump, plus the builder that turns them into a local pacman repo |
| `kernel/` | Unified kernel: config fragments, patches, all device trees, firmware embed list |
| `firmware/` | Vendor firmware fetch/verify recipes + their pins |
| `boot/` | Two-stage UEFI boot: steamcl (stage 1) + GRUB (stage 2), both built from pinned sources |
| `apps/decky/` | The first-party Decky plugins: `novadeck-control` (per-game tweaks, power, fan curve) and `novadeck-monitor` (the live panel) |
| `tests/` | Every offline suite. `make test` runs the host ones; the signing and disk suites need a container |
| `build/` | Where the build itself is pinned: the cross-compile `Dockerfile`, the builder digest, the repo snapshot, and the Steam seed fetcher |

`dev.env` stays at the root: it is sourced by hand before every `make`, so it is the one path that
earns its place there.

Most of those directories carry their own `README.md` documenting them file-by-file.

**Open work lives in [GitHub issues](https://github.com/Nova-Deck/os-build/issues)**, prioritised
`P0`–`P3` and grouped by `area/*` label. `docs/worklog/DONE.md` is the decision record for work closed before
2026-08-18 — resolved entries keep their measurements, HW-validation dates and dead ends, because
several are the only written record of why something is shaped the way it is. Work closed after
that date keeps its reasoning in the closed issue instead.

### Adding a board

Three pieces of data, all discovered automatically: a DTS under `kernel/dts/qcom/`, a device
profile under `rootfs/overlay/usr/lib/novadeck/devices/` plus its `model` case in `device-env`, and —
if the gamepad is not already covered — an InputPlumber config. An unmatched board falls through
to `defaults.conf` and still boots.

### Documentation

<!-- AUTO-GENERATED from docs/ — regenerate with /ecc:update-docs -->

| Doc | Covers |
|---|---|
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | **Operations** — flash a card, reach the device, ship and install an update, steer the A/B slot state, recover a device that will not boot |
| [`docs/bringup.md`](docs/bringup.md) | Phase 1 — boot generic arm64 with Turnip Vulkan working (the hardware gate) |
| [`docs/bringup-phase2.md`](docs/bringup-phase2.md) | Phase 2 — the SteamOS layers: gamescope session, HW-support, InputPlumber, audio |
| [`docs/bringup-phase3.md`](docs/bringup-phase3.md) | Phase 3 — the native arm64 Steam Deck UI inside the Phase-2 session |
| [`docs/phase4.md`](docs/phase4.md) | Phase 4 — sealed manifest rootfs (4a), A/B atomic updates (4b), bootstrap from packages (4c) |
| [`docs/phase5.md`](docs/phase5.md) | Phase 5 — the SteamDeck-style boot chain: steamcl + GRUB, update path, demote-on-failure |
| [`docs/phase5-bootattempts.md`](docs/phase5-bootattempts.md) | The `boot-attempts` GRUB module that replaces Valve's steamenv counter |
| [`docs/ota.md`](docs/ota.md) | The update *server*: publishing a bundle, and how the OTA host is set up |
| [`docs/decky.md`](docs/decky.md) | Decky Loader + the `novadeck-control` and `novadeck-monitor` plugins — the in-UI surface for everything below |
| [`docs/per-game-perf.md`](docs/per-game-perf.md) | `game-tweaks.json` — the per-game performance keys and which launch path enforces each |
| [`docs/fan-curve.md`](docs/fan-curve.md) | The temperature→PWM curve, why it belongs to the power profile, and how a user edits it |
| [`docs/install-internal.md`](docs/install-internal.md) | **The installer medium** — putting NovaDeck on the device's internal storage alongside Android: what it destroys, the Wi-Fi file it needs, and how a release is cut |
| [`docs/internal-storage.md`](docs/internal-storage.md) | Per-board internal-storage captures — the fixtures the install target's rules are written against |
| [`docs/base-pin.md`](docs/base-pin.md) | What we pin of the upstream aarch64 Arch port, and how |
| [`docs/windows-games-fex.md`](docs/windows-games-fex.md) | Running x86/x86-64 games: the two independent Proton/FEX paths |
| [`docs/FEX_README.md`](docs/FEX_README.md) | The FEX runtime configuration itself (rationale for the comment-less JSON) |
| [`docs/remote-access.md`](docs/remote-access.md) | SSH on a release image: key-only sshd, and what the devkit toggle actually gates |
| [`docs/ci.md`](docs/ci.md) | What each workflow under `.github/workflows/` runs, what it needs, and the signing PKI behind the release jobs |

<!-- END AUTO-GENERATED -->

</details>

## Licensing & firmware

Proprietary Qualcomm firmware is **never** committed to this repo. `firmware/` holds only
fetch-and-verify recipes against two pinned sources, both landing in gitignored trees: open
firmware from upstream `linux-firmware`, and device-proprietary vendor blobs — extracted from each
device's Android vendor image and republished to
[Nova-Deck/qcom-firmwares](https://github.com/Nova-Deck/qcom-firmwares) — at a pinned commit,
verified against that repo's `sha256sums.txt`.

Respect per-device bootloader-unlock terms and upstream package licenses.
