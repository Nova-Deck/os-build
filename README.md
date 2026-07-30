# novadeck

An **immutable, A/B-updatable aarch64 Linux distribution** that forks SteamOS 3 "Holo"
onto Qualcomm mobile silicon (**SM8550 / SM8650 / SM8750**). x86/x86_64 games run via
**Proton → Wine → FEX-Emu**, with native Vulkan via **Mesa Turnip** on Adreno.

> Status: **Phase 4 landed — A/B atomic updates on a sealed, from-packages root.** SM8650
> boots on real hardware with Turnip Vulkan (Phase 1 gate cleared), a gamescope session
> + Qualcomm HW-support layer (Phase 2 cleared), a GamepadUI Steam shell, and an x86
> **Windows** title running under Valve's Proton 11 ARM64 + FEX (Phase 3 gate cleared,
> HW-validated 2026-07-07). Phase 4 then made the image replaceable rather than merely
> buildable: a sealed manifest rootfs bootstrapped from packages (4a + 4c, HW-validated
> 2026-07-26) and RAUC A/B updates over the custom `novadeck-bootctl` bootloader backend
> (4b, HW-validated 2026-07-28). Updates are **CLI-driven** for now — the `steamos-update`
> D-Bus surface and a bundle server are the two deliberately deferred steps. See
> [`docs/phase4.md`](docs/phase4.md) and `TODO.md`.

## Plan

The full roadmap, decisions, and risk analysis live in
[`.claude/plans/novadeck.plan.md`](.claude/plans/novadeck.plan.md).

Lead bring-up target: **SM8650** (Adreno 750). Two hard go/no-go gates:
1. **Phase 1** — SM8650 boots generic arm64 with Turnip Vulkan working.
2. **Phase 3** — one real Proton (Windows) title runs interactively under FEX-Emu.

## Repository layout

| Path | Purpose |
|---|---|
| `images/` | Image assembly recipes (A/B layout, Btrfs, RAUC bundles) |
| `packages/` | The from-source overlay: PKGBUILDs + source/artifact pins for the packages we patch or version-bump (gamescope, mesa/Turnip, FEX, Proton, RAUC, InputPlumber, MangoHud, scx-scheds, SDDM), plus the pipeline that builds and pins them |
| `kernel/` | Unified kernel: config fragments, patches, all device trees, firmware embed list |
| `firmware/` | Vendor firmware **extraction/bundling recipes** + `manifest.txt` (required firmware, union of all boards) |
| `fs-overlay/` | Unified rootfs overlay payload — one filesystem-mirror tree (session, HW-support, InputPlumber, audio UCM2, FEX config, Steam shell) injected with a single `cp -a` |
| `steam-seed/` | Native arm64 Steam client SEED fetcher + pin (build machinery; pre-seeded into `/home`, not rootfs content) |
| `boot/` | Pluggable boot stage (android-bootimg / edk2-UEFI backends) |
| `ci/` | Signing-CA generator + the notes for `.github/workflows/` (offline test suites, the overlay package pipeline, image and release-artifact builds) |
| `docs/` | Design notes + phase bring-up notes — see [Documentation](#documentation) below |
| `build/` | `Dockerfile` for the `novadeck-build` cross-compile image used by every container stage |
| `Makefile` | Master build orchestrator — wires every stage into one incremental graph |

Each of `images/ packages/ kernel/ firmware/ fs-overlay/ boot/ ci/` carries its own `README.md`
documenting that stage file-by-file; those are the detailed reference, this table is the map.

## Documentation

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

`TODO.md` is the working log — open items, and the decision record for closed ones.

## Supported SoCs

Board/SoC enablement is consumed **collectively** by the unified build — there is no per-SoC
image. Add a SoC by dropping its content into the shared trees (kernel fragment, patches, DTS,
`firmware/manifest.txt` entries, `fs-overlay/etc/inputplumber/` config); the build discovers it.

| SoC | Snapdragon | GPU | Status |
|---|---|---|---|
| SM8650 | 8 Gen 3 | Adreno 750 | HW-validated |
| SM8550 | 8 Gen 2 | Adreno 740 | HW-validated |
| SM8750 | 8 Elite | Adreno 830 | Planned — drop fragment/DTS/firmware in to enable |

The kernel command line is split: common args in `boot/cmdline`, board/SoC-specific args
(e.g. `irqaffinity`, controller quirks) in each board's DTS `/chosen/bootargs`.

### Boards

A board needs three things, all of them data the unified build picks up on its own: a DTS under
[`kernel/dts/qcom/`](kernel/dts/qcom/), a device profile under
[`fs-overlay/usr/lib/novadeck/devices/`](fs-overlay/usr/lib/novadeck/devices/) plus its `model`
case in `device-env`, and — if its gamepad is not already covered — an InputPlumber composite
config under `fs-overlay/etc/inputplumber/devices.d/`. `device-env` resolves the devicetree
`model` string at runtime and exports the board's `NOVADECK_*` facts (panel geometry, primary
connector, SoC class, suspend mode); an unmatched board falls through to `defaults.conf` and
still boots.

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
| AYANEO Pocket DS | SM8550 | `ayaneo-pocket-ds` | — |
| AYANEO Pocket EVO | SM8550 | `ayaneo-pocket-evo` | — |
| AYANEO Pocket S 1K | SM8550 | `ayaneo-pocket-s1k` | — |
| AYANEO Pocket S 2K | SM8550 | `ayaneo-pocket-s2k` | — |
| AYN Odin 2 Mini | SM8550 | `ayn-odin-2-mini` | — |
| AYN Odin 2 Portal | SM8550 | `ayn-odin-2-portal` | — |
| Retroid Pocket 6 | SM8550 | `retroid-pocket-6` | — |

<!-- END AUTO-GENERATED -->

"HW-validated" means novadeck has been booted and exercised on that unit; the rest ship
enablement data that has not been confirmed against hardware.

## Building

The whole pipeline is driven from the top-level **`Makefile`**, which wires the per-stage
scripts under `kernel/ firmware/ images/ boot/` into one incremental dependency graph. It
also pins **where** each stage runs: kernel, rootfs assembly, boot packaging, SD-card and
RAUC bundling all cross-compile **inside the `novadeck-build` Docker image** (the repo is
bind-mounted at `/src`); the root bootstrap and the firmware fetches run on the host
because they drive Docker/qemu or the network themselves. Always go through `make` — don't
invoke the stage scripts by hand — and keep the Makefile in step when a stage is added or
its inputs change.

The build is **unified** — one image serves every supported SoC/board (SM8550 / SM8650 /
SM8750), with a single kernel carrying the union of drivers/DTBs and all firmware. There is
no `SOC` argument. `make help` lists every target.

```sh
make help                       # list targets + knobs
make sdcard                     # full bring-up image -> out/images/sdcard.img
make kernel                     # just Image.gz + all dtbs + modules
make image                      # just the read-only Btrfs root
make clean                      # drop out/ (clean-base / distclean go further)
```

Targets only rebuild when their inputs (source pins, patches, dts, config, firmware) change.
Device firmware is fetched from the pinned Nova-Deck/qcom-firmwares repo (`make fw-qcom`), so no
device dump is needed.

### Knobs

Passed on the command line (`make VAR=value target`).

<!-- AUTO-GENERATED from Makefile — regenerate with /ecc:update-docs -->

| Knob | Default | Effect |
|---|---|---|
| `BASE_CONFIG` | *(unset)* | Repo-relative path to a full verbatim kernel `.config` — skips the defconfig+fragment merge in `kernel/build.sh` |
| `VERSION` | date, inside `genbundle.sh` | RAUC bundle version for `make bundle` |
| `ESP` | *(unset)* | Mounted EFI System Partition, the install target for `make deploy` |
| `PKIDIR` | *(unset)* | Signing PKI, mounted read-only at `/pki`; makes `bundle` sign for real and adds `test-signing`'s keyring check. Unset, `bundle` mints an ephemeral dev cert |
| `RAUC_CERT` / `RAUC_KEY` | `/pki/release.{cert,key}.pem` when `PKIDIR` is set | Override the signing pair with paths the *container* can see |
| `OVERLAY_PULL` | `1` | Fetch prebuilt overlay packages before building. `make overlay` forces `0` (pure local build, no network) |
| `OVERLAY_ARCH` | `aarch64` | Scopes the built overlay pacman repo at `work/repo/<arch>/` |
| `BUILD_IMG` | `novadeck-build` | Name of the cross-compile Docker image |

<!-- END AUTO-GENERATED -->

Environment variables — not command-line knobs — select **dev vs release**. `NOVADECK_DEV=1`
plus the Wi-Fi/SSH credentials build a dev card, and it is the only way to build an image from
packages you compiled yourself (a release build requires reviewed artifact pins, `make
verify-pins`). Source them all at once, **before every invocation**:

```sh
set -a; . ./dev.env; set +a
```

`dev.env` is tracked and secret-free; it generates a throwaway dev-card SSH key under
`work/dev-ssh/` and sources the gitignored `dev.env.local` for Wi-Fi credentials. It documents
each variable inline. Chaining it into only the first invocation is a trap: `NOVADECK_DEV`
changes image *content*, so a bare `make bundle` afterwards flips the mode stamp and rebuilds
RELEASE over your dev image.

### Tests

`make test`'s suites need no build, no container, no root and no device — they run the shipped
artifacts (`images/initramfs/init`, `novadeck-bootctl`, the RAUC post-install hook) against a
sandbox, so there is no reason not to run them before a push. `test-signing` is the one that
cannot run on the host: it signs real bundles and verifies them through the shipped
`system.conf`.

```sh
make verify-lock                # lock's novadeck rows vs packages/ (seconds)
make test                       # slot-state + bootctl + post-install + pairingd suites
make test-signing               # RAUC signing self-test (container; PKIDIR= adds the keyring check)
make verify-card                # assert the built A/B card image: GPT, ESP, per-slot identities
make verify-pins                # overlay artifact BYTES vs packages/*/artifact.pin (release gate)
```

## Upstream base

novadeck builds **on top of** Valve/Collabora's official aarch64 Arch port
(`holo-core-aarch64-preview`) rather than rebuilding userspace — but on top of its
**packages**, not its container image. The root is bootstrapped with `pacman` into an empty
tree from a pinned repo snapshot, so every file on the image comes from a package that
`images/manifest.lock` names and sha256-pins. It is an unsupported technology preview pinned
to a snapshot — see [`docs/base-pin.md`](docs/base-pin.md).
Upstream and peer-distro reference clones live in `_reference/` (untracked, local-only).

## Licensing & firmware

Proprietary Qualcomm firmware is **never** committed to this repo. `firmware/` holds only
fetch-and-verify recipes against two pinned sources, both landing in gitignored trees: open
firmware from upstream `linux-firmware` (`LINUX_FW.pin`), and device-proprietary vendor blobs —
extracted from each device's Android vendor image and republished to
[Nova-Deck/qcom-firmwares](https://github.com/Nova-Deck/qcom-firmwares) — at a pinned commit
(`QCOM_FW.pin`), verified against that repo's `sha256sums.txt`. Respect per-device
bootloader-unlock terms and upstream package licenses.
