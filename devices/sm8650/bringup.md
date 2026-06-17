# SM8650 bring-up checklist (Phase 1)

Phase 1 is a **hard go/no-go gate**: boot generic arm64 with **Turnip Vulkan** working.
Track in order — each step gates the next.

| # | Subsystem | Kernel deps (config) | Validate | Status |
|---|---|---|---|---|
| 1 | UART console | `SERIAL_QCOM_GENI*`, `earlycon` | boot log on `ttyMSM0,115200` | ☐ |
| 2 | Storage (UFS) | `SCSI_UFS_QCOM` | rootfs mounts from UFS | ☐ |
| 3 | USB | `USB_DWC3_QCOM`, QMP/eUSB2 phys | enumerate over USB | ☐ |
| 4 | Display (DSI/DP) | `DRM_MSM_DPU`, `DRM_MSM_DSI` | panel lights, fb console | ☐ |
| 5 | Input | `INPUT_EVDEV` | `evtest` sees touch/keys | ☐ |
| 6 | **GPU / Vulkan** | `DRM_MSM` + Turnip + zap shader | `vulkaninfo`, `vkcube` | ☐ |
| 7 | Audio | `PINCTRL_SM8650_LPASS_LPI`, q6 DSP | playback | ☐ |
| 8 | Thermals / cpufreq | `QCOM_TSENS`, `CPU_THERMAL` | throttles under load | ☐ |

**Gate exit:** steps 1–6 green + a native arm64 Vulkan title runs.

## Prerequisites (hardware-dependent — not codeable here)
- SM8650 device with **unlocked bootloader** + serial/UART access.
- Dump of the device's vendor partitions to extract `device`-sourced firmware
  (see `firmware/extract.sh` + `firmware-manifest.txt`).
- Decide the concrete board DT (mainline `sm8650-mtp`/`-qrd` vs a community device DT).

_Phase 1 scaffold._
