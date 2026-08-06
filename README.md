# novadeck

**A Steam Deck–style gaming OS for Qualcomm Snapdragon handhelds.**

Turn an AYANEO Pocket, AYN Odin, Retroid Pocket or KONKR handheld into a console-like machine:
boot straight into the Steam UI, browse your library with the gamepad, and play — including
Windows games, translated to ARM on the fly.

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

### Honest status

novadeck is **early**. It boots, plays games, and updates itself on real hardware — but it is a
project under active development, not a finished product. Expect rough edges, expect to read the
docs, and expect to be able to recover a device you have unlocked.

You need an **unlockable bootloader** and a spare **SD card**. novadeck runs from the card and
does not touch your Android install.

## Supported devices

<!-- AUTO-GENERATED from fs-overlay/usr/lib/novadeck/devices/*.conf — regenerate with /ecc:update-docs -->

| Board | SoC | Profile | HW-validated |
|---|---|---|---|
| AYANEO Pocket S2 | SM8650 | `ayaneo-pocket-s2` | yes |
| KONKR Pocket FIT | SM8650 | `konkr-pocket-fit` | yes |
| AYANEO Pocket ACE | SM8550 | `ayaneo-pocket-ace` | yes |
| AYN Odin 2 | SM8550 | `ayn-odin-2` | yes |
| AYN Thor | SM8550 | `ayn-thor` | yes |
| Retroid Pocket Nova | SM8550 | `retroid-pocket-nova` | yes (120 Hz mode selection open) |
| AYANEO Pocket DMG | SM8550 | `ayaneo-pocket-dmg` | — |
| AYANEO Pocket DS | SM8550 | `ayaneo-pocket-ds` | no - panel stays black |
| AYANEO Pocket EVO | SM8550 | `ayaneo-pocket-evo` | no - panel stays black |
| AYANEO Pocket S 1K | SM8550 | `ayaneo-pocket-s1k` | — |
| AYANEO Pocket S 2K | SM8550 | `ayaneo-pocket-s2k` | — |
| AYN Odin 2 Mini | SM8550 | `ayn-odin-2-mini` | — |
| AYN Odin 2 Portal | SM8550 | `ayn-odin-2-portal` | yes |
| Retroid Pocket 6 | SM8550 | `retroid-pocket-6` | — |

<!-- END AUTO-GENERATED -->

**"HW-validated"** means someone has actually booted novadeck on that unit. The rest ship support
data that looks right but has never met the hardware — they may work, and reports either way are
genuinely useful.

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
mobile silicon (**SM8550 / SM8650 / SM8750**). The root is read-only, bootstrapped from packages
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
| `ESP` | *(unset)* | Mounted EFI System Partition, the install target for `make deploy` |
| `PKIDIR` | *(unset)* | Signing PKI, mounted read-only at `/pki`; makes `bundle` sign for real and adds `test-signing`'s keyring check. Unset, `bundle` mints an ephemeral dev cert |
| `RAUC_CERT` / `RAUC_KEY` | `/pki/release.{cert,key}.pem` when `PKIDIR` is set | Override the signing pair with paths the *container* can see |
| `OVERLAY_ARCH` | `aarch64` | Scopes the built overlay pacman repo at `work/repo/<arch>/` |
| `BUILD_IMG` | `novadeck-build` | Name of the cross-compile Docker image |

<!-- END AUTO-GENERATED -->

### Repository layout

| Path | Purpose |
|---|---|
| `images/` | Image assembly (A/B layout, Btrfs, RAUC bundles) |
| `packages/` | From-source overlay: PKGBUILDs + source pins for what we patch or version-bump, plus the builder that turns them into a local pacman repo |
| `kernel/` | Unified kernel: config fragments, patches, all device trees, firmware embed list |
| `firmware/` | Vendor firmware fetch/verify recipes + their pins |
| `fs-overlay/` | Rootfs overlay payload — one filesystem-mirror tree injected with a single `cp -a` |
| `steam-seed/` | Native arm64 Steam client seed fetcher + pin |
| `boot/` | Two-stage UEFI boot: steamcl (stage 1) + GRUB (stage 2), both built from pinned sources |
| `ci/` | Signing-CA generator + notes for `.github/workflows/` |
| `build/` | `Dockerfile` for the cross-compile image |

Each of those directories carries its own `README.md` documenting it file-by-file. `TODO.md` holds
the OPEN items; `DONE.md` holds the closed ones and is the decision record — resolved entries keep
their measurements, HW-validation dates and dead ends, because several are the only written record
of why something is shaped the way it is.

### Adding a board

Three pieces of data, all discovered automatically: a DTS under `kernel/dts/qcom/`, a device
profile under `fs-overlay/usr/lib/novadeck/devices/` plus its `model` case in `device-env`, and —
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
| [`docs/base-pin.md`](docs/base-pin.md) | What we pin of the upstream aarch64 Arch port, and how |
| [`docs/windows-games-fex.md`](docs/windows-games-fex.md) | Running x86/x86-64 games: the two independent Proton/FEX paths |
| [`docs/FEX_README.md`](docs/FEX_README.md) | The FEX runtime configuration itself (rationale for the comment-less JSON) |
| [`docs/remote-access.md`](docs/remote-access.md) | SSH on a release image: key-only sshd, and what the devkit toggle actually gates |

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
