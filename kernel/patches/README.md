# kernel/patches/

Out-of-tree kernel patches applied on top of the pinned source by `kernel/build.sh`,
unified across all supported SoCs (no per-SoC subdir).

Apply order is **lexical**, which the numbering makes identical to numeric order. The
build applies them cumulatively with `--fuzz=0`: a hunk that lands on approximate context
has drifted from what it was written against and can silently attach to the wrong place on
a later bump, so approximate is treated as failure.

## Numbering: subsystem, not device

The number says **when a patch applies**, and it is keyed on subsystem.

| Range | Band | Contents |
|---|---|---|
| `0000-0099` | core | arch/arm64, syscall ABI, prctl — the FEX-adjacent core changes |
| `0100-0199` | clk | clk, pmdomain, interconnect |
| `0200-0299` | gpu | drm/msm GPU: adreno, GEM, VM_BIND, shrinker |
| `0300-0399` | dpu | drm/msm DPU: planes, flush, rotation, LUTDMA (+ its binding) |
| `0400-0479` | dsi | drm/msm DSI: host, PHY, byte clock |
| `0480-0499` | drmcore | drm core helpers that later patches build on |
| `0500-0599` | panel | drm/panel drivers, one per number |
| `0600-0699` | backlight / leds / pwm | backlight `0600s`, leds `0650s`, pwm `0680s` |
| `0700-0799` | input | touch `0700s`, joystick `0740s`, haptics + force-feedback `0770s` |
| `0800-0899` | audio | ASoC, qdsp6, codecs |
| `0900-0999` | power / misc | power-supply `0900s`, hwmon + misc devices `0970s` |
| `1000-1099` | net / usb / pci / crypto | |
| `1100-1199` | dts | arm64 `.dtsi` fixes to upstream SoC files — last, after their drivers |

Numbers are spaced by 10 (by 5 where a band is dense) so a new patch slots in without
touching its neighbours. The `0230-0260` run is spaced by 5 deliberately: that is one
upstream VM_BIND series, and the tight spacing is the signal that it moves as a unit.

**Device-keyed ranges were considered and rejected.** The patches do not partition by
device: `drivers/gpu/drm/panel/Kconfig` is co-edited by all twelve panel patches,
`0480-drm-panel-add-brightness-levels-helper` serves every panel,
`0340` covers two SoCs, and `0530-chipone-icna35xx-panel` is family-wide. A per-device
range forces an arbitrary pick for each shared patch, and those picks become the next mess.

## Adding or moving a patch

One invariant governs order, because the stack applies cumulatively:

> **Two patches that touch a common file must keep their relative order.**

Everything else is free to move. `./check-order.py` lints the convention (numbering,
naming, lexical-equals-numeric, band membership); the dependency invariant itself is proved
by the build, since `--fuzz=0` turns a wrong order into a hard failure rather than a hunk
landing quietly somewhere else.

Naming is `NNNN-lower-case-with-hyphens.patch`. Keep each patch focused and traceable to an
upstream submission or a clear bring-up reason.

## Provenance

The number cannot answer *"can I drop this on a bump?"* — that is what the trailer is for:

```
Novadeck-Origin: mainline | posted | community | novadeck | unknown
Novadeck-Link:   <lore URL, or the repo it came from>
Novadeck-Drop-When: <what makes this removable — e.g. "lands in v7.4">
```

**These trailers are not yet populated.** The `Origin` column below is inferred from
`From:` headers, and 46 of 93 patches have no `From:` at all — half the stack's provenance
is already lost and needs a human pass. Do not treat `unknown` as "ours".

Three categories matter here, not two: only 8 patches are mainline-track, 14 are ours, and
the largest identified bucket is 25 peer/community patches that will never land upstream.
That is why provenance is a trailer and not a number band.

## Mapping from the old numbering

The stack was renumbered from an ad-hoc scheme. This table resolves older references in
commits, docs and issues (`0518-0524`, `0525`, `0530-0532`, `0507`, …). The rename was
verified by applying both orderings to a clean 7.2.7 tree and diffing: the two patched
trees are byte-identical.

| New | Band | Origin | Was |
|---|---|---|---|
| `0010-enable-64-bit-processes-to-use-compat-input-syscalls.patch` | core | `mainline` | `0504-Enable-64-bit-processes-to-use-compat-input-syscalls.patch` |
| `0020-arm64-emulate-unaligned-atomics.patch` | core | `community` | `0505-arm64-emulate-unaligned-atomics.patch` |
| `0110-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` | clk | `novadeck` | `0002-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` |
| `0120-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` | clk | `unknown` | `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` |
| `0130-interconnect-qcom-sm8550-enable-qos-configuration.patch` | clk | `community` | `0122-interconnect__qcom__sm8550__Enable_QoS_configuration.patch` |
| `0210-drm-msm-a6xx-enable-ifpc-on-adreno-740.patch` | gpu | `community` | `0004-drm-msm-a6xx-Enable-IFPC-on-Adreno-740.patch` |
| `0220-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` | gpu | `mainline` | `0513-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` |
| `0230-drm-msm-fix-barriers-accessing-ctx-vm.patch` | gpu | `unknown` | `0518-drm-msm-fix-barriers-accessing-ctx-vm.patch` |
| `0235-drm-msm-rework-queuelock.patch` | gpu | `unknown` | `0519-drm-msm-rework-queuelock.patch` |
| `0240-drm-msm-synchronize-vm-creation-on-ctxlock.patch` | gpu | `unknown` | `0520-drm-msm-synchronize-vm-creation-on-ctxlock.patch` |
| `0245-drm-msm-add-helper-to-check-for-per-process-pgtables-vm.patch` | gpu | `unknown` | `0521-drm-msm-add-helper-to-check-for-per-process-pgtables-vm.patch` |
| `0250-drm-msm-allow-lazy-vm-creation-to-fail.patch` | gpu | `unknown` | `0522-drm-msm-allow-lazy-vm-creation-to-fail.patch` |
| `0255-drm-msm-dont-fallback-to-shared-vm-for-vm-bind.patch` | gpu | `unknown` | `0523-drm-msm-dont-fallback-to-shared-vm-for-vm-bind.patch` |
| `0260-drm-msm-fix-per-process-pgtables-check.patch` | gpu | `unknown` | `0524-drm-msm-fix-per-process-pgtables-check.patch` |
| `0310-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` | dpu | `unknown` | `0509-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` |
| `0320-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` | dpu | `unknown` | `0510-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` |
| `0330-drm-msm-fix-smmu-fault-dumps.patch` | dpu | `unknown` | `0515-drm-msm-fix-smmu-fault-dumps.patch` |
| `0340-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` | dpu | `unknown` | `0528-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` |
| `0350-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` | dpu | `unknown` | `0529-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` |
| `0360-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` | dpu | `community` | `0530-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` |
| `0365-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` | dpu | `community` | `0531-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` |
| `0370-dpu-quiesce-boot-scanout.patch` | dpu | `unknown` | `dpu-quiesce-boot-scanout.patch` |
| `0410-msm-dsi-restore-wide-bus-bpp-calculation.patch` | dsi | `novadeck` | `0003-msm-dsi-restore-wide_bus-bpp-calculation.patch` |
| `0420-msm-dsi-keep-link-clocks-up-while-display-active.patch` | dsi | `novadeck` | `0005-msm-dsi-keep-link-clocks-up-while-display-active.patch` |
| `0430-drm-msm-dsi-round-byte-clock-after-reparenting.patch` | dsi | `unknown` | `0525-drm-msm-dsi-round-byte-clock-after-reparenting.patch` |
| `0440-revert-revert-drm-msm-dsi-fix-pll-init-in-bonded-mode.patch` | dsi | `unknown` | `0534-Revert-Revert-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch` |
| `0480-drm-panel-add-brightness-levels-helper.patch` | drmcore | `community` | `0074-drm-panel-add-brightness-levels-helper.patch` |
| `0490-add-hw-params-callback-function-to-drm-connector-hdmi-audio-ops.patch` | drmcore | `mainline` | `0006-add-hw_params-callback-function-to-drm_connector_hdmi_audio_ops.patch` |
| `0505-gpu-panel-add-pocket-ace-panel-driver.patch` | panel | `novadeck` | `0051-gpu-panel-add-Pocket-ACE-panel-driver.patch` |
| `0510-gpu-panel-add-pocket-dmg-panel-driver.patch` | panel | `novadeck` | `0052-gpu-panel-add-Pocket-DMG-panel-driver.patch` |
| `0515-gpu-panel-add-pocket-ds-lower-panel-driver.patch` | panel | `unknown` | `0054-gpu-panel-add-Pocket-DS-lower-panel-driver.patch` |
| `0520-synaptics-td4328-lcd-panel.patch` | panel | `community` | `0056_Synaptics-TD4328-LCD-panel.patch` |
| `0525-xm-plus-xm91080g-panel.patch` | panel | `community` | `0057_Xm-Plus-XM91080G-panel.patch` |
| `0530-chipone-icna35xx-panel.patch` | panel | `community` | `0058_Chipone-ICNA35XX-panel.patch` |
| `0535-ddic-ch13726a-panel.patch` | panel | `community` | `0059_DDIC-CH13726A-panel.patch` |
| `0540-gpu-drm-panel-add-wt0630-panel.patch` | panel | `novadeck` | `0066-gpu-drm-panel-add-wt0630-panel.patch` |
| `0545-gpu-drm-panel-add-pocket-fit-panel.patch` | panel | `novadeck` | `0067-gpu-drm-panel-add-pocket-fit-panel.patch` |
| `0550-gpu-drm-panel-add-wt0600-1k-panel.patch` | panel | `community` | `0068-gpu-drm-panel-add-wt0600-1k-panel.patch` |
| `0555-drm-panel-add-retroid-pocket-6-panel.patch` | panel | `unknown` | `0104-drm-panel-Add-Retroid-Pocket-6-panel.patch` |
| `0560-drm-panel-add-retroid-pocket-nova-panel.patch` | panel | `unknown` | `0105-drm-panel-Add-Retroid-Pocket-Nova-panel.patch` |
| `0610-ayn-odin2-mini-backlight.patch` | backlight | `community` | `0060_AYN-Odin2-Mini--backlight.patch` |
| `0620-backlight-add-sy7758-6-channel-high-efficiency-led-driver-support.patch` | backlight | `mainline` | `0062-backlight-Add-SY7758-6-channel-High-Efficiency-LED-Driver-support.patch` |
| `0650-leds-add-driver-for-heroic-htr3212.patch` | leds | `community` | `0033_leds--Add-driver-for-HEROIC-HTR3212.patch` |
| `0660-leds-aw200xx-optional-vdd-supply.patch` | leds | `unknown` | `0040_leds--aw200xx-optional-vdd-supply.patch` |
| `0680-sn3112-pwm-driver.patch` | pwm | `community` | `0034_sn3112-pwm-driver.patch` |
| `0705-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` | touch | `novadeck` | `0015-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` |
| `0710-edt-ft5x06-add-no-regmap-bulk-read-option.patch` | touch | `community` | `0053-edt-ft5x06-add-no_regmap_bulk_read-option.patch` |
| `0715-input-goodix-override-resolution-from-dt.patch` | touch | `community` | `0055-input-goodix-override-resolution-from-dt.patch` |
| `0720-ayn-odin2-mini-hynitron-cstxxx.patch` | touch | `community` | `0061_AYN-Odin2-Mini--hynitron--cstxxx.patch` |
| `0725-rmi4-silence-spam-irq-errors.patch` | touch | `novadeck` | `0032-rmi4-silence-spam-irq-errors.patch` |
| `0730-input-touchscreen-add-synaptics-dsx-driver.patch` | touch | `novadeck` | `0063-input-touchscreen-add-synaptics-dsx-driver.patch` |
| `0735-input-touchscreen-add-synaptics-dsx-kconfig.patch` | touch | `unknown` | `0064-input-touchscreen-add-synaptics-dsx-kconfig.patch` |
| `0738-input-add-chipone-tddi-touchscreen.patch` | touch | `unknown` | `0069-input-add-chipone-tddi-touchscreen.patch` |
| `0745-input-add-driver-for-rsinput-gamepad.patch` | joystick | `novadeck` | `0031_input--Add-driver-for-RSInput-Gamepad.patch` |
| `0750-input-add-driver-for-retroid-pocket-gamepad.patch` | joystick | `unknown` | `0035_input--Add-driver-for-Retroid-Pocket-gamepad.patch` |
| `0755-input-add-driver-for-mangmi-pocket-max-spi-joypad.patch` | joystick | `unknown` | `0037_input--Add-driver-for-MANGMI-Pocket-Max-SPI-joypad.patch` |
| `0770-input-add-driver-for-qcom-spmi-haptics.patch` | haptics | `unknown` | `0038_input--Add-driver-for-qcom-spmi-haptics.patch` |
| `0775-input-retroid-gamepad-add-force-feedback.patch` | haptics | `community` | `0039_input--retroid-gamepad-add-force-feedback.patch` |
| `0780-add-qcom-haptics-driver.patch` | haptics | `unknown` | `1000-add-qcom-haptics-driver.patch` |
| `0785-haptics-driver-support-periodic-sine-and-fixes.patch` | haptics | `unknown` | `1002-haptics-driver-support-periodic-sine-and-fixes.patch` |
| `0790-rsinput-add-ff.patch` | haptics | `unknown` | `1003-rsinput-add-ff.patch` |
| `0795-input-qcom-haptics-defer-rsinput-playback.patch` | haptics | `community` | `1004-input-qcom-haptics-defer-rsinput-playback.patch` |
| `0810-audioreach-add-dedicated-wsa2-support.patch` | audio | `community` | `0007-audioreach-Add-dedicated-WSA2-support.patch` |
| `0820-asoc-qcom-sc8280xp-add-support-for-primary-i2s.patch` | audio | `novadeck` | `0036_ASoC--qcom--sc8280xp-Add-support-for-Primary-I2S.patch` |
| `0830-asoc-codecs-aw88166-ayn-odin2-specific-modifications.patch` | audio | `novadeck` | `0047_ASoC--codecs--aw88166--AYN-Odin2-Specific-modifica.patch` |
| `0840-asoc-wcd938x-add-dmic-dapm-inputs.patch` | audio | `community` | `0200-ASoC-wcd938x-add-DMIC-DAPM-inputs.patch` |
| `0850-asoc-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` | audio | `novadeck` | `0201-ASoC-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` |
| `0860-asoc-wsa881x-request-powerdown-gpio-non-exclusively.patch` | audio | `unknown` | `0202-ASoC-wsa881x-request-powerdown-gpio-non-exclusively.patch` |
| `0870-asoc-qcom-sm8250-force-s16-le-only-for-compressed.patch` | audio | `unknown` | `0203-ASoC-qcom-sm8250-force-S16_LE-only-for-compressed.patch` |
| `0880-asoc-qcom-q6asm-dai-change-default-periods.patch` | audio | `community` | `0204-ASoC-qcom-q6asm-dai-change-default-periods.patch` |
| `0890-asoc-wcd938x-guard-the-soundwire-interrupt-callback.patch` | audio | `unknown` | `0205-ASoC-wcd938x-guard-the-soundwire-interrupt-callback.patch` |
| `0910-power-supply-add-qcom-pm8150b-charger-and-fg.patch` | power | `unknown` | `0072-power-supply-add-qcom-pm8150b-charger-and-fg.patch` |
| `0920-power-supply-add-hl7139-charge-pump.patch` | power | `unknown` | `0073-power-supply-add-hl7139-charge-pump.patch` |
| `0930-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` | power | `unknown` | `0526-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` |
| `0940-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` | power | `unknown` | `0527-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` |
| `0970-rocknix-set-boot-fanspeed.patch` | misc | `unknown` | `0500-ROCKNIX-set-boot-fanspeed.patch` |
| `0980-misc-add-ayaneo-serial-mcu.patch` | misc | `unknown` | `1005-misc-add-ayaneo-serial-mcu.patch` |
| `1010-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` | net | `community` | `0507-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` |
| `1030-hack-fix-usb-boot-hang.patch` | usb | `unknown` | `0071-HACK-fix-usb-boot-hang.patch` |
| `1040-usbcore-add-interrupt-interval-override.patch` | usb | `unknown` | `0506-usbcore-add-interrupt-interval-override.patch` |
| `1060-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` | pci | `unknown` | `0535-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` |
| `1080-crypto-qce-add-runtime-pm-and-interconnect-bandwidth-scaling.patch` | crypto | `mainline` | `v6_20260210_quic_utiwari_crypto_qce_add_runtime_pm_and_interconnect_bandwidth_scaling_support.patch` |
| `1105-pcie-update-sm8550-dtsi.patch` | dts | `unknown` | `0000-pcie-update-sm8550-dtsi.patch` |
| `1110-pcie-update-sm8650-dtsi.patch` | dts | `unknown` | `0001-pcie-update-sm8650-dtsi.patch` |
| `1115-arm64-dts-qcom-sm8250-add-uart16.patch` | dts | `unknown` | `0008-arm64-dts-qcom-sm8250-add-uart16.patch` |
| `1120-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` | dts | `unknown` | `0009-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` |
| `1125-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` | dts | `unknown` | `0010-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` |
| `1130-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` | dts | `community` | `0011-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` |
| `1135-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` | dts | `unknown` | `0012-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` |
| `1140-arm64-dts-qcom-gpu-cc-power-requirements-reality-check.patch` | dts | `mainline` | `0120-20250728_konradybcio_gpu_cc_power_requirements_reality_check.patch` |
| `1145-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` | dts | `community` | `0532-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` |
| `1150-arm64-dts-qcom-sm8450-8550-8650-add-missing-cx-power-domain-to-gcc.patch` | dts | `mainline` | `20260424_neil_armstrong_arm64_dts_qcom_sm8_456_50_add_missing_cx_power_domain_to_gcc.patch` |
| `1155-arm64-dts-qcom-sm8650-misc-enhancements.patch` | dts | `mainline` | `v2_20260420_neil_armstrong_arm64_qcom_sm8650_misc_enhancements.patch` |
