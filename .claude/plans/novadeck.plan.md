# Plan: novadeck — Immutable aarch64 SteamOS for Qualcomm SoCs

**Source**: Conversational `/plan` session (no PRD file)
**Selected Target**: SM8650 (Snapdragon 8 Gen 3) lead bring-up; SM8550 + SM8750 follow
**Complexity**: Very High (research-grade, multi-quarter distro + hardware-enablement program)

## Summary

novadeck is an immutable, A/B-updatable aarch64 Linux distribution that forks SteamOS 3
"Holo" onto Qualcomm SM8550/8650/8750 mobile silicon. The Steam client / Deck UI runs
**native arm64** (see Confirmed Decisions); x86/x86_64 Windows + Linux *games* run via
Proton → Wine → FEX-Emu, with native Vulkan via Mesa Turnip on Adreno (no GPU emulation).
SM8650 is the first device brought up end-to-end to a full gaming session.

## Fidelity bar (the end goal, stated explicitly)

The target is **UX-equivalence with official SteamOS handheld mode** — boot straight into the
gamescope session / Deck UI, Quick Access menu, suspend/resume, power & refresh controls,
atomic updates surfaced in-UI. **Library-equivalence is an explicit non-goal**: anti-cheat
(EAC/BattlEye) and per-title FEX coverage mean some x86 titles will never run, so the library
cannot match a native-x86 Deck. Measure novadeck against the *experience*, not the catalogue.

**Desktop mode is an explicit non-goal.** SteamOS's "switch to desktop" drops to a full KDE
Plasma DE; novadeck ships **handheld/gamescope mode only** and will not pull Plasma (or any
desktop environment). The scope cost — Plasma's package weight, an X/Wayland desktop session,
and the SteamOS desktop-mode integration glue — isn't worth it for a gaming-first appliance.
The Deck UI's in-session affordances (Quick Access, settings) stay; the desktop escape hatch
does not.

### What "SteamOS" decomposes into, and where fidelity is won/lost

SteamOS-the-experience is five layers stacked on the Arch/Holo base. Fidelity = how faithfully
each is reproduced on Adreno/aarch64:

| # | SteamOS layer | Gives the user | On Qualcomm |
|---|---|---|---|
| A | Holo userspace (mesa, gamescope, wine, rauc, casync, grub) | the substrate | ✅ ships in the aarch64 base |
| B | gamescope session + Deck UI | boot → Steam Big Picture, Quick Access, OSK/OSD | Phase 2 — portable but Turnip/Wayland-feature gated |
| C | `jupiter-*` (steamos-manager, hw-support, powerbuttond, oobe) | TDP/fan/refresh/suspend/brightness/gyro/rotation/OOBE | Phase 2 — **AMD/Deck-specific; the real porting work** |
| D | Gaming stack (Steam shell + Proton + FEX) | the library actually runs | Phase 3 — shell native; FEX only for x86 games |
| E | Atomic A/B + in-Steam updater | immutable root, OTA, rollback, "System Update" in UI | Phase 4 |

### Layer-C fidelity matrix (Deck-UI affordances → Qualcomm backing)

The Deck UI's polish lives in `jupiter-hw-support` + `steamos-manager`, which assume AMD APU
knobs. Each affordance needs a Qualcomm backing or an honest stub — this is the Phase-2/3
fidelity backlog:

| Deck-UI affordance | SteamOS backing | Qualcomm equivalent / risk |
|---|---|---|
| TDP / power slider | AMD ryzenadj/pstate | cpufreq + GPU **devfreq**; no 1:1 TDP — shim maps slider → clocks/thermal |
| Refresh-rate / VRR switch | gamescope + amdgpu | Turnip + DSI panel modes; VRR likely a **gap** |
| Suspend / resume | s2idle | Qualcomm **s2idle** maturity = top HW risk after GPU |
| Brightness / backlight | jupiter | ✅ SY7758 backlight driver in tree (kernel patch 0060) |
| Gyro / haptics / rotation | jupiter-hw-support | gyro via IIO (libiio already pulled); **panel rotation** (Pocket S2 portrait-native) needs Deck-style handling |
| Battery / charge | jupiter | fuel-gauge driver + UPower |
| First-boot OOBE | steamos-oobe | adapt; SteamOS owns first-boot networking (network config is test-only today) |

## Confirmed Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Base/build strategy | Fork SteamOS Holo for aarch64 | Maximum SteamOS UX fidelity (gamescope session, Deck UI, atomic updater) |
| **Steam client / shell** | **Native arm64** (Valve build) | A native arm64 Steam exists (`repo.steampowered.com/steam/archive/stable/`) → Deck UI runs native, NOT under FEX. **Verify the archive serves arm64 client/runtime bits, not just the amd64-named launcher bootstrapper.** |
| x86 game support | FEX-Emu + Proton (games only) | Standard aarch64 gaming approach; native Vulkan passthrough to Turnip. FEX is scoped to x86 game payloads, not the shell. |
| **Kernel page size** | **4K** | FEX/Proton/Wine + most x86 game assets assume 4K pages; 16K breaks them. Cheap kernel-config choice now, catastrophic to retrofit — fix before Phase 3. |
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
- **Status**: ✅ done (repo scaffolded, base pinned by digest, build orchestrated via Makefile).

### Phase 1 — SM8650 generic bring-up [HARD GO/NO-GO GATE]
- **Action**: boot plain aarch64 rootfs on hardware; bring up UART -> UFS -> USB -> display
  -> input -> Adreno/Turnip Vulkan -> audio -> Wi-Fi -> thermals; assemble firmware bundle
  from vendor partitions.
- **Validate**: `vulkaninfo` + `vkcube` on Turnip; a native arm64 Vulkan title runs.
- **Status**: ✅ **CLEARED (2026-06-21)**. On real SM8650 (AYANEO Pocket S2): ROCKNIX ABL boot,
  panel + fb console, Wi-Fi + SSH (test-only), input via InputPlumber (controller incl. d-pad),
  hardware Turnip Vulkan 1.4 (vulkaninfo), and `vkcube --wsi display` presenting a spinning cube
  via KMS (`VK_KHR_display`, no compositor). Audio (step 7) and thermals (step 8) are post-gate;
  USB-on-HW (step 3) and UFS are off the gate's critical path. See `devices/sm8650/bringup.md`.

### Phase 2 — Adopt base + add SteamOS layer [now small] ← IN PROGRESS (branch `phase-2/steamos-layer`)
- **Status**: started 2026-06-21. Step 1 (de-risk) ✅ CLOSED on HW: patched gamescope (composite
  rotation, from-source overlay) + `--use-rotation-shader --immediate-flips` renders a client through
  Turnip's Wayland WSI, upright-landscape on the Pocket S2 panel. Step 2 (session plumbing) IN
  PROGRESS: `session/` overlay ships `novadeck-session` launcher + `novadeck-session.service` +
  `/etc/novadeck/session.conf` (release block 4d in assemble-rootfs.sh), installed-but-disabled —
  validate by hand on HW (`systemctl start novadeck-session`), boot-enable deferred with the vsync
  follow-up. Tracked in `devices/sm8650/bringup-phase2.md`.
- **Action**: layer on prebuilt base; package/port jupiter-* + gamescope-session; replace
  jupiter-hw-support with a novadeck Qualcomm HW-support package (back the layer-C matrix above
  with cpufreq/devfreq/IIO/UPower/backlight; stub honestly where no Qualcomm equivalent exists).
- **De-risk first**: bring up **bare gamescope on Turnip** in a test build before the jupiter-*
  port — isolates the Turnip↔gamescope Vulkan-feature question (present_wait, DMA-BUF modifiers,
  HDR/VRR) from the porting work. The `vkcube --wsi display` KMS proof is gamescope's exact path.
- **Validate**: gamescope session launches on SM8650; Deck UI renders; Quick Access + suspend
  reach the layer-C affordances that have a Qualcomm backing (others documented as stubbed).

### Phase 3 — Gaming stack (native Steam + FEX/Proton for games) [HARD GO/NO-GO GATE]
- **Action**: stand up the **native arm64 Steam shell**; package FEX-Emu (+binfmt_misc,
  thunk/RootFS) and Proton for x86 game payloads; validate x86 game -> Proton -> FEX -> Turnip.
- **Validate**: native arm64 Steam UI interactive on SM8650, **and** one real Proton (Windows)
  x86 title playable through FEX → Turnip.
- **Note**: anti-cheat / per-title FEX limits cap *library* parity (the fidelity-bar non-goal),
  not the shell.

### Phase 4 — Immutability & atomic A/B updates [now concretely specified]
- **Action**: implement iliana model on base's rauc+casync: 8-part A/B + Btrfs-ro +
  overlayfs /etc + steamos-atomupd; atomic rollback on failed boot. For full fidelity, surface
  updates **in the Steam UI** ("System Update"), not just a CLI rauc.
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
| gamescope needs Turnip features that may be absent (VRR/HDR/present timing/modifiers) | HIGH | De-risk in Phase 2 with bare gamescope before jupiter-*; contribute Mesa fixes |
| GPU firmware / Turnip feature gaps on Adreno 8xx | HIGH | Validate Vulkan early (Phase 1 gate ✅); contribute Mesa fixes; pin known-good Turnip |
| Qualcomm s2idle suspend/resume immaturity | HIGH | Suspend is core to the handheld feel; validate on SM8650 HW early in Phase 2 |
| FEX perf/thunk coverage under mobile thermals (games) | HIGH | Native GPU thunking; per-title tuning; thermal profiles; accept some titles unplayable |
| Panel rotation / portrait-native handling (Deck UI assumes landscape) | MEDIUM | Pocket S2 panel orientation; handle like Deck/handhelds in HW-support layer |
| Native arm64 Steam runtime parity (the build exists, coverage unproven) | MEDIUM | Verify archive serves arm64 client/runtime bits, not just amd64 launcher; fall back to x86 Steam under FEX if gaps |
| Base is unsupported preview pinned to 2025-11-18 snapshot | MEDIUM | Pin by digest; plan for it to move/vanish; mirror locally |
| Firmware redistribution / bootloader unlock legality | MEDIUM | No proprietary blob redistribution; document per-device extraction; respect licenses |

## Acceptance
- [x] Phase 1 gate: SM8650 boots generic arm64 with Turnip Vulkan (vkcube presents via KMS, 2026-06-21)
- [ ] Fidelity bar: UX-equivalent to SteamOS handheld mode (library parity is a non-goal)
- [ ] Phase 2: gamescope session + Deck UI on SM8650; layer-C affordances backed or stubbed
- [ ] Phase 3 gate: native arm64 Steam shell interactive + one Proton x86 title playable on SM8650
- [ ] Immutable A/B with working OTA + auto-rollback (updates surfaced in-UI)
- [ ] Pluggable boot stage produces per-device flashable artifacts
- [ ] All three SoCs boot to a gaming session
- [ ] CI matrix builds cosign-signed images + update manifests
- [ ] Patterns mirrored from upstream (base, iliana, ublue), not reinvented

## Effort Concentration
~80% of real effort is kernel/DT/firmware enablement (Phases 1, 6) + FEX/Proton/Turnip
gaming (Phase 3) + the jupiter-*/Qualcomm HW-support port (Phase 2, layer C) — gated by upstream
maturity more than novadeck recipes. The Holo userspace rebuild was dropped: Valve/Collabora
already shipped the aarch64 base, and a native arm64 Steam build removes the need to emulate the
shell. FEX is now scoped to x86 *game* payloads, not the UI.
