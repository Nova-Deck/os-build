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
| `kernel/` | Kernel config, patches, per-SoC build |
| `firmware/` | Vendor firmware **extraction/bundling recipes** (no blobs committed) |
| `devices/{sm8550,sm8650,sm8750}/` | Per-SoC device tree, config, firmware manifest, boot backend |
| `boot/` | Pluggable boot stage (android-bootimg / edk2-UEFI backends) |
| `ci/` | GitHub Actions matrix builds + cosign signing |
| `docs/` | Design notes (see [`docs/base-pin.md`](docs/base-pin.md)) |

## Upstream base

novadeck builds **on top of** Valve/Collabora's official aarch64 Arch port
(`holo-core-aarch64-preview`) rather than rebuilding userspace. It is an unsupported
technology preview pinned to a snapshot — see [`docs/base-pin.md`](docs/base-pin.md).
The reference clone lives in `_vendor/` (git-ignored).

## Licensing & firmware

Proprietary Qualcomm firmware is **never** committed. `firmware/` holds only recipes that
extract blobs from a user's own device partitions. Respect per-device bootloader-unlock
terms and upstream package licenses.
