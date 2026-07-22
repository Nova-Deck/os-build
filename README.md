# novadeck

An **immutable, A/B-updatable aarch64 Linux distribution** that forks SteamOS 3 "Holo"
onto Qualcomm mobile silicon (**SM8550 / SM8650 / SM8750**). x86/x86_64 games run via
**Proton → Wine → FEX-Emu**, with native Vulkan via **Mesa Turnip** on Adreno.

> Status: **Phase 3 cleared — native arm64 Steam shell + Proton/FEX games.** SM8650
> boots on real hardware with Turnip Vulkan (Phase 1 gate cleared), a gamescope session
> + Qualcomm HW-support layer (Phase 2 cleared), a GamepadUI Steam shell, and an x86
> **Windows** title running under Valve's Proton 11 ARM64 + FEX (Phase 3 gate cleared,
> HW-validated 2026-07-07). Next: Phase 4 A/B atomic updates.

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
| `packages/` | novadeck-specific + ported SteamOS `jupiter-*` package builds |
| `kernel/` | Unified kernel: config fragments, patches, all device trees, firmware embed list |
| `firmware/` | Vendor firmware **extraction/bundling recipes** + `manifest.txt` (required firmware, union of all boards) |
| `fs-overlay/` | Unified rootfs overlay payload — one filesystem-mirror tree (session, HW-support, InputPlumber, audio UCM2, FEX config, Steam shell) injected with a single `cp -a` |
| `steam-seed/` | Native arm64 Steam client SEED fetcher + pin (build machinery; pre-seeded into `/home`, not rootfs content) |
| `boot/` | Pluggable boot stage (android-bootimg / edk2-UEFI backends) |
| `ci/` | GitHub Actions matrix builds + cosign signing |
| `docs/` | Design notes, architecture review, and phase bring-up notes ([`docs/architecture-review.md`](docs/architecture-review.md), [`docs/bringup.md`](docs/bringup.md), [`docs/base-pin.md`](docs/base-pin.md), [`docs/windows-games-fex.md`](docs/windows-games-fex.md)) |
| `build/` | `Dockerfile` for the `novadeck-build` cross-compile image used by every container stage |
| `Makefile` | Master build orchestrator — wires every stage into one incremental graph |

## Supported SoCs

Board/SoC enablement is consumed **collectively** by the unified build — there is no per-SoC
image. Add a SoC by dropping its content into the shared trees (kernel fragment, patches, DTS,
`firmware/manifest.txt` entries, `fs-overlay/etc/inputplumber/` config); the build discovers it.

| SoC | Snapdragon | GPU | Status |
|---|---|---|---|
| SM8650 | 8 Gen 3 | Adreno 750 | HW-validated (boards: AYANEO Pocket S2, KONKR Pocket FIT) |
| SM8550 | 8 Gen 2 | Adreno 740 | HW-validated (boards: AYN Odin2/Thor, AYANEO Pocket ACE) |
| SM8750 | 8 Elite | Adreno 830 | Planned — drop fragment/DTS/firmware in to enable |

The kernel command line is split: common args in `boot/cmdline`, board/SoC-specific args
(e.g. `irqaffinity`, controller quirks) in each board's DTS `/chosen/bootargs`.

## Building

The whole pipeline is driven from the top-level **`Makefile`**, which wires the per-stage
scripts under `kernel/ firmware/ images/ boot/` into one incremental dependency graph. It
also pins **where** each stage runs: kernel, rootfs assembly, boot packaging, SD-card and
RAUC bundling all cross-compile **inside the `novadeck-build` Docker image** (the repo is
bind-mounted at `/src`); base customization and firmware/base fetches run on the host
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

Targets only rebuild when their inputs (source pins, patches, dts, config, firmware)
change. Key knobs: `BASE_CONFIG=` (verbatim kernel `.config`, e.g. a ROCKNIX config),
`VERSION=` (RAUC bundle), `ESP=` (deploy target), and `NOVADECK_TEST=1` + Wi-Fi/SSH creds
for a test card. Device firmware is fetched from the pinned Nova-Deck/qcom-firmwares repo
(`make fw-qcom`), so no device dump is needed.

## Upstream base

novadeck builds **on top of** Valve/Collabora's official aarch64 Arch port
(`holo-core-aarch64-preview`) rather than rebuilding userspace. It is an unsupported
technology preview pinned to a snapshot — see [`docs/base-pin.md`](docs/base-pin.md).
Upstream and peer-distro reference clones live in `_reference/` (untracked, local-only).

## Licensing & firmware

Proprietary Qualcomm firmware is **never** committed. `firmware/` holds only recipes that
extract blobs from a user's own device partitions. Respect per-device bootloader-unlock
terms and upstream package licenses.
