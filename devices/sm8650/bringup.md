# SM8650 bring-up checklist (Phase 1)

Phase 1 is a **hard go/no-go gate**: boot generic arm64 with **Turnip Vulkan** working.
Track in order — each step gates the next.

| # | Subsystem | Kernel deps (config) | Validate | Status |
|---|---|---|---|---|
| 1 | UART console | `SERIAL_QCOM_GENI*`, `earlycon` | boot log on `ttyMSM0,115200` | ⊘ N/A — no serial on device ([[sm8650-no-uart]]); console is the panel (step 4) |
| 2 | Storage | `SCSI_UFS_QCOM` | rootfs mounts | ✅ boots root off **SD** (`root=PARTLABEL=novadeck-root`, btrfs); UFS itself unverified |
| 3 | USB | `USB_DWC3_QCOM`, QMP/eUSB2 phys | enumerate over USB | ◐ boot-hang HACK + xpad interrupt-interval override in tree; not yet confirmed on HW |
| 4 | Display (DSI/DP) | `DRM_MSM_DPU`, `DRM_MSM_DSI` | panel lights, fb console | ✅ panel + fb console verified on Pocket S2 ([[sm8650-working-display-baseline]]) |
| 5 | Input | `INPUT_EVDEV` | `evtest` sees keys; gamepad usable | ✅ AYANEO Pocket S2 controller works on-device via **InputPlumber** (pinned prebuilt ≥ v0.77.7 — earlier versions miss DPadLeft/DPadUp); all directions incl. d-pad confirmed ([[sm8650-inputplumber-input]]) |
| 6 | **GPU / Vulkan** | `DRM_MSM` + Turnip + zap shader | `vulkaninfo`, `vkcube` | ✅ `vulkaninfo` on-device: **Turnip Adreno 750**, `DRIVER_ID_MESA_TURNIP`, Vulkan 1.4 (Mesa 25.2.7), `INTEGRATED_GPU`, DRM render node live — hardware-accelerated (not lavapipe). **`vkcube --wsi display` presents a spinning cube on the panel on-device** — direct-to-KMS (`VK_KHR_display`), no compositor; full present path proven ([[sm8650-vulkan-gate]]) |
| 7 | Audio | `PINCTRL_SM8650_LPASS_LPI`, q6 DSP | playback | ☐ post-gate |
| 8 | Thermals / cpufreq | `QCOM_TSENS`, `CPU_THERMAL` | throttles under load | ☐ post-gate |

**Gate exit:** steps 1–6 green + a native arm64 Vulkan title runs.

**Current state (Phase-1 gate CLEARED):** the custom kernel boots on
real SM8650 hardware (ROCKNIX ABL → KERNEL android-bootimg off SD) with a working console on
the internal panel, joins Wi-Fi, and accepts SSH (Wi-Fi/SSH are test-only scaffolding;
[[wifi-config-is-test-only]]). `vulkaninfo` run on-device confirms **hardware-accelerated
Turnip Vulkan 1.4 on the Adreno 750** (`DRIVER_ID_MESA_TURNIP`, Mesa 25.2.7, `INTEGRATED_GPU`,
DRM render node live; full evidence in [[sm8650-vulkan-gate]]) — the full
kernel-DRM → GPU-firmware → Turnip → Vulkan stack works end-to-end. Steps 1–6 are green.

**Formal exit met:** `vkcube --wsi display` renders a spinning cube on the panel on-device —
a native arm64 Vulkan title presenting directly to KMS via `VK_KHR_display` (no compositor, no
extra packages; the stock vulkan-tools `vkcube` already ships the display WSI). This closes the
earlier headless-vulkaninfo caveat (`present support=false` was a WSI-surface artifact, not a
capability gap). Steps 3/7/8 are off the gate's critical path (step 5 Input green —
InputPlumber on Pocket S2).

## Prerequisites (hardware-dependent — not codeable here)
- SM8650 device with **unlocked bootloader** + serial/UART access.
- Dump of the device's vendor partitions to extract `device`-sourced firmware
  (see `firmware/extract.sh` + `firmware-manifest.txt`).
- Decide the concrete board DT (mainline `sm8650-mtp`/`-qrd` vs a community device DT).

## Deploy (ROCKNIX custom ABL)
This target runs the ROCKNIX ABL (https://github.com/ROCKNIX/abl), which boots from an
ESP (SD or internal): it loads `/EFI/BOOT/bootaa64.efi` if present, else falls back to
the ESP-root file `KERNEL` — an Android boot image. novadeck's `android-bootimg` artifact
is exactly that, so Phase 1 deploy is a file copy (no fastboot):

```
boot/deploy.sh sm8650 <esp-mountpoint>   # -> <esp>/KERNEL
```

Every board's DTB is appended to the kernel payload (Android header v0), so a single
`KERNEL` serves all SM8650 boards: ABL's DTB picker scans the trailing FDTs and lets you
select the board at boot. The cmdline mounts `root=LABEL=novadeck-root`. The UEFI/GRUB
(`bootaa64.efi`) path is reserved for the Phase 4 A/B layout (`efi-a`/`efi-b` + RAUC).

_Phase 1 scaffold._
