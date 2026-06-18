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

## Deploy (ROCKNIX custom ABL)
This target runs the ROCKNIX ABL (https://github.com/ROCKNIX/abl), which boots from an
ESP (SD or internal): it loads `/EFI/BOOT/bootaa64.efi` if present, else falls back to
the ESP-root file `KERNEL` — an Android boot image. novadeck's `android-bootimg` artifact
is exactly that, so Phase 1 deploy is a file copy (no fastboot):

```
boot/deploy.sh sm8650 sm8650-ayaneo-ps2 <esp-mountpoint>   # -> <esp>/KERNEL
```

The board DTB is embedded in the image (Android header v2) and the cmdline mounts
`root=LABEL=novadeck-root`. The UEFI/GRUB (`bootaa64.efi`) path is reserved for the
Phase 4 A/B layout (`efi-a`/`efi-b` + RAUC).

_Phase 1 scaffold._
