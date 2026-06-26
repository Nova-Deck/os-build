# novadeck

An **immutable, A/B-updatable aarch64 Linux distribution** that forks SteamOS 3 "Holo"
onto Qualcomm mobile silicon (**SM8550 / SM8650 / SM8750**). x86/x86_64 games run via
**Proton → Wine → FEX-Emu**, with native Vulkan via **Mesa Turnip** on Adreno.

> Status: **Phase 0 — scaffolding.** Nothing here boots yet.

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
| `firmware/` | Vendor firmware **extraction/bundling recipes** (no blobs committed) |
| `devices/` | Shared device enablement: firmware manifest, InputPlumber config, bring-up notes |
| `boot/` | Pluggable boot stage (android-bootimg / edk2-UEFI backends) |
| `ci/` | GitHub Actions matrix builds + cosign signing |
| `docs/` | Design notes (see [`docs/base-pin.md`](docs/base-pin.md)) |
| `build/` | `Dockerfile` for the `novadeck-build` cross-compile image used by every container stage |
| `Makefile` | Master build orchestrator — wires every stage into one incremental graph |

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
The reference clone lives in `_vendor/` (git-ignored).

## Licensing & firmware

Proprietary Qualcomm firmware is **never** committed. `firmware/` holds only recipes that
extract blobs from a user's own device partitions. Respect per-device bootloader-unlock
terms and upstream package licenses.
