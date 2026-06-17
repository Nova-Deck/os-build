# Plan: novadeck — Immutable aarch64 SteamOS for Qualcomm SoCs

**Source**: Conversational `/plan` session (no PRD file)
**Selected Target**: SM8650 (Snapdragon 8 Gen 3) lead bring-up; SM8550 + SM8750 follow
**Complexity**: Very High (research-grade, multi-quarter distro + hardware-enablement program)

## Summary

novadeck is an immutable, A/B-updatable aarch64 Linux distribution that forks SteamOS 3
"Holo" onto Qualcomm SM8550/8650/8750 mobile silicon. It runs x86/x86_64 Windows + Linux
games via Proton -> Wine -> FEX-Emu, with native Vulkan via Mesa Turnip on Adreno (no GPU
emulation). SM8650 is the first device brought up end-to-end to a full gaming session.

## Confirmed Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Base/build strategy | Fork SteamOS Holo for aarch64 | Maximum SteamOS UX fidelity (gamescope session, Deck UI, atomic updater) |
| x86 game support | FEX-Emu + Proton | Standard aarch64 gaming approach; native Vulkan passthrough to Turnip |
| Boot path | Pluggable per-device | Resolve fastboot/bootimg vs edk2/UEFI during per-SoC bring-up |
| Lead device | SM8650 (Adreno 750) | Good balance of performance + mainline/Turnip momentum |
| Update model | RAUC + casync + Btrfs (SteamOS-native) | Consistent with fork-Holo choice; matches iliana blueprint |
| CI/build | ublue-style: GH Actions matrix + cosign | Modern build ergonomics without adopting bootc runtime |

## Key Reference Audit

### holo-core-aarch64-preview (Valve GitLab) — cloned & audited
- **What it is**: official Arch Linux `aarch64` port (NOT SteamOS itself) — package sources +
  published binary pacman repo + Docker `base`/`base-devel` images at
  `registry.gitlab.steamos.cloud/holo/holo-core-aarch64-preview`.
- **Built by**: Collabora for Valve; Arch snapshot `2025-11-18` (`mash-squashed_2025-11-18.3`).
- **Size**: 3,586 package source dirs (core-aarch64, core-any, extra-aarch64, extra-any).
- **Status**: explicit technology preview, NOT for production, no stability/support guarantees,
  read-only. Pin by digest; expect it to move or disappear.
- **`missing.lst`**: license/packaging reconciliation bookkeeping, NOT a "doesn't build" list.
- **Present & building for aarch64**: gamescope (3.16.17), mesa, rauc, casync, grub,
  linux-firmware, mkinitcpio, ostree, vulkan-tools, wine.
- **Confirmed absent (= our real work)**: steam, proton, FEX-Emu, box64, device kernel
  (`linux` — only linux-firmware ships), Qualcomm SoC firmware, SteamOS `jupiter-*` layer,
  assembled bootable image.
- **Impact**: Phase 2 mostly collapses — consume the prebuilt base instead of rebuilding
  Holo userspace for arm64.

### iliana.fyi — SteamOS atomic update internals (informs Phase 4)
- 8-partition A/B layout: ESP + A/B GRUB + A/B rootfs + A/B `/var` + shared `/home`.
- Btrfs read-only subvolumes (zstd) for root; overlayfs on `/etc` for persistence.
- RAUC (signed bundle verify + partition writes) + casync (chunked image download) +
  steamos-atomupd-client (Python update checker).
- Bootstrap trick: pull rootfs from Valve casync servers, rewrite JSON manifest to point at
  custom images. (Note: RAUC/casync/Btrfs, NOT frzr.)

### ublue-os/image-template — alternative immutability model (CI patterns only)
- bootc/OCI: Containerfile -> GHCR -> bootc, cosign signing, bootc-image-builder.
- Decision: borrow CI patterns (Actions matrix + cosign) for build pipeline only; keep
  SteamOS-native RAUC runtime. bootc/OCI documented as fallback if RAUC arm64 bring-up stalls.

## Files / Repo Layout to Create (Phase 0)

| Path | Action | Why |
|---|---|---|
| `images/` | CREATE | Image assembly recipes (A/B, Btrfs, RAUC bundles) |
| `packages/` | CREATE | novadeck-specific + ported jupiter-* package builds |
| `kernel/` | CREATE | Kernel config, patches, per-SoC build |
| `firmware/` | CREATE | Vendor firmware extraction/bundling recipes (no blob redistribution) |
| `devices/{sm8550,sm8650,sm8750}/` | CREATE | Per-SoC DT, config, firmware manifest, boot backend |
| `boot/` | CREATE | Pluggable boot stage: android-bootimg, edk2/UEFI backends |
| `ci/` | CREATE | GH Actions matrix builds + cosign signing |
| `_vendor/holo-core-aarch64-preview/` | EXISTS | Cloned reference base (audited) |

## Phases

### Phase 0 — Foundation
- **Action**: `git init`; create repo layout; pin aarch64 base by digest (pacman repo
  `holo-packages.steamos.cloud/holo-core-aarch64-preview` + Docker `base`/`base-devel`);
  map iliana casync-bootstrap as rootfs acquisition path; document firmware/license notes.
- **Validate**: repo scaffolded; base image pulled & pinned reproducibly.

### Phase 1 — SM8650 generic bring-up [HARD GO/NO-GO GATE]
- **Action**: boot plain aarch64 rootfs on hardware; bring up UART -> UFS -> USB -> display
  -> input -> Adreno/Turnip Vulkan -> audio -> Wi-Fi -> thermals; assemble firmware bundle
  from vendor partitions.
- **Validate**: `vulkaninfo` + `vkcube` on Turnip; a native arm64 Vulkan title runs.

### Phase 2 — Adopt base + add SteamOS layer [now small]
- **Action**: layer on prebuilt base; package/port jupiter-* + gamescope-session; replace
  jupiter-hw-support with novadeck Qualcomm HW-support package.
- **Validate**: gamescope session launches on SM8650.

### Phase 3 — Gaming stack (FEX-Emu + Proton) [HARD GO/NO-GO GATE]
- **Action**: package FEX-Emu (+binfmt_misc, thunk/RootFS); bring up Steam (x86_64 under FEX)
  + Proton; validate x86 game -> Proton -> FEX -> Turnip.
- **Validate**: one real Proton (Windows) title interactive on SM8650.

### Phase 4 — Immutability & atomic A/B updates [now concretely specified]
- **Action**: implement iliana model on base's rauc+casync: 8-part A/B + Btrfs-ro +
  overlayfs /etc + steamos-atomupd; atomic rollback on failed boot.
- **Validate**: install -> OTA update -> forced-failure auto-rollback to previous slot.

### Phase 5 — Pluggable boot stage
- **Action**: define `(kernel,DTB,initramfs,image) -> flashable artifact` interface; backends:
  android-bootimg+fastboot (default), edk2/UEFI (stretch); wire A/B slot selection per bootloader.
- **Validate**: `make device=sm8650 boot=android-bootimg image` produces flashable artifact;
  swapping backend needs no image-content change.

### Phase 6 — Port to SM8550 then SM8750
- **Action**: SM8550 (Adreno 740, mature) via DT/firmware deltas; SM8750 (Adreno 830, newest)
  last — expect kernel/DT/Turnip gaps, vendor cherry-picks, Mesa patches.
- **Validate**: all three SoCs boot to gaming session; SM8750 documented with known gaps.

### Phase 7 — Hardening, CI & release
- **Action**: ublue-borrowed CI — GH Actions matrix (8550/8650/8750) + cosign-signed artifacts
  + published update manifests; thermal/power profiles; recovery/reflash docs.
- **Validate**: CI builds all images; boot-test + smoke-test gamescope + Proton title.

## Risks

| Risk | Sev | Mitigation |
|---|---|---|
| Mobile SoC enablement mainline-immature (esp. SM8750) | CRITICAL | Lead with SM8650; reuse Linaro/pmOS branches; SM8750 last w/ known-gaps |
| GPU firmware / Turnip feature gaps on Adreno 8xx | HIGH | Validate Vulkan early (Phase 1 gate); contribute Mesa fixes; pin known-good Turnip |
| FEX perf/thunk coverage under mobile thermals | HIGH | Native GPU thunking; per-title tuning; thermal profiles; accept some titles unplayable |
| 16K vs 4K page size breaks FEX/Proton/Wine | HIGH | Decide kernel page size early; standardize across devices |
| Base is unsupported preview pinned to 2025-11-18 snapshot | MEDIUM | Pin by digest; plan for it to move/vanish; mirror locally |
| Firmware redistribution / bootloader unlock legality | MEDIUM | No proprietary blob redistribution; document per-device extraction; respect licenses |
| No upstream arm64 Steam guarantee | MEDIUM | Steam runs x86_64 under FEX; native arm64 Steam is a non-goal |

## Acceptance
- [ ] Phase 1 gate: SM8650 boots generic arm64 with Turnip Vulkan
- [ ] Phase 3 gate: one Proton title interactive on SM8650
- [ ] Immutable A/B with working OTA + auto-rollback
- [ ] Pluggable boot stage produces per-device flashable artifacts
- [ ] All three SoCs boot to a gaming session
- [ ] CI matrix builds cosign-signed images + update manifests
- [ ] Patterns mirrored from upstream (base, iliana, ublue), not reinvented

## Effort Concentration
~80% of real effort is kernel/DT/firmware enablement (Phases 1, 6) + FEX/Proton/Turnip
gaming (Phase 3) — both gated by upstream maturity more than novadeck recipes. The Holo
userspace rebuild was dropped: Valve/Collabora already shipped the aarch64 base.
