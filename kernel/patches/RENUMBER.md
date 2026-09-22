# Renumbering the kernel patch stack — proposal

Status: **draft for review.** Nothing has been renamed yet. This file describes the target
layout, the full old -> new mapping, and the safety check that says the reorder is sound.
Delete this file once the renumber lands.

## Why

The stack is 93 patches and has drifted into three problems that compound:

- **Five files carry no number at all** (`dpu-quiesce-boot-scanout.patch`, three lore-derived
  `v2_…` / `20260424_…` filenames). They apply *last*, by accident of ASCII rather than intent.
- **Two naming conventions.** `0031_input--Add-driver-for-…` (underscore, double hyphen,
  title case) against `0051-gpu-panel-add-…` (single hyphen, lower case).
- **Related patches are scattered.** The rsinput/haptics chain currently runs
  `0031 -> 0039 -> 1000 -> 1002 -> 1003 -> 1004`, with 45 unrelated patches interleaved.
  `0074-drm-panel-add-brightness-levels-helper` — a helper the panel drivers use — sits
  *after* ten of them.

## Decision: subsystem in the number, provenance in a trailer

The rejected alternative was to encode provenance in the number (an upstream band and a
per-device band, 100 numbers per device). Two things killed it.

**Patches do not partition by device.** The stack's real ordering spine is shared files, and
the most co-edited file in the tree is `drivers/gpu/drm/panel/Kconfig` — touched by all twelve
panel patches. Other genuinely shared ones: `0074` (brightness helper, every panel),
`0015`+`0053` (two tweaks to one upstream touch driver, two boards),
`0528` (inline rotation, two SoCs in its own subject line), `0058` (ICNA35XX, family-wide
curve). A per-device range forces an arbitrary pick for each, and the arbitrary picks are
the next mess.

**Provenance is three categories, not two.** Only 8 patches come from mainline-track
addresses; 14 are ours; the largest identified bucket is 25 peer/community out-of-tree
patches that will never land upstream. An upstream-vs-ours number has no home for the
biggest group. And the axes cross: `0062-backlight-SY7758` is authored by a Linaro
maintainer but is pure handheld device support.

So: **the number answers "when does this apply", the trailer answers "can I drop this on a
bump".** A number cannot be validated; a trailer can, and `build.sh` can assert it. A patch
that lands upstream never has to move — you flip its trailer and delete it.

## Band map

| Range | Band | Contents |
|---|---|---|
| `0000-0099` | core | arch/arm64, syscall ABI, prctl — the FEX-adjacent core changes |
| `0100-0199` | clk | clk, pmdomain, interconnect |
| `0200-0299` | gpu | drm/msm GPU: adreno, GEM, VM_BIND, shrinker |
| `0300-0399` | dpu | drm/msm DPU: planes, flush, rotation, LUTDMA (+ its binding) |
| `0400-0479` | dsi | drm/msm DSI: host, PHY, byte clock |
| `0480-0499` | drmcore | drm core helpers that later patches build on |
| `0500-0599` | panel | drm/panel drivers, one per number |
| `0600-0699` | backlight / leds / pwm | backlight 0600s, leds 0650s, pwm 0680s |
| `0700-0799` | input | touch 0700s, joystick 0740s, haptics + force-feedback 0770s |
| `0800-0899` | audio | ASoC, qdsp6, codecs |
| `0900-0999` | power / misc | power-supply 0900s, hwmon + misc devices 0970s |
| `1000-1099` | net / usb / pci / crypto |  |
| `1100-1199` | dts | arm64 .dtsi fixes to upstream SoC files — applied last, after their drivers |

Numbers are spaced by 10 (by 5 where a band is dense) so a new patch slots in without
touching its neighbours. The `0230-0260` GPU run is spaced by 5 deliberately: that is one
upstream VM_BIND series and the tight spacing is the signal.

## The safety invariant

The reorder is only sound if it preserves textual dependencies. The rule applied:

> For any two patches that touch a **common file**, their relative order must not change.

Everything else is free to move. Checked mechanically over the whole stack:

```
patches: 93   files touched: 184   co-edited files: 35
ordered pairs constrained: 216
VIOLATIONS: 0
```

The checker parses every `+++` line (normalising the `b/` and `linux/` prefixes both
conventions use), builds the co-edit graph, and compares old against new index for all 216
constrained pairs. It should be committed alongside the rename so a future insertion is
checked the same way.

Lexical order under the new names is byte-identical to the intended numeric order, so
`build.sh`'s glob needs no change.

## Prerequisite — fix this before renaming anything

`kernel/build.sh:58` applies with a bare `patch -p1`: **no `--fuzz=0`.** `kernel/README.md`
claims zero fuzz is the standard and commit `e097cae` re-rolled 23 patches to earn it, but
the build does not enforce it — default fuzz is 2.

Reordering is exactly the operation where that matters: it turns a wrong order from a loud
failure into a hunk silently landing somewhere else. **Add `--fuzz=0` to `build.sh` first, in
its own commit**, so the renumber is self-checking and the fuzz-free property stops being
an unenforced claim.

## Provenance trailer

Appended to each patch below its commit message:

```
Novadeck-Origin: mainline | posted | community | novadeck | unknown
Novadeck-Link:   <lore URL, or the repo it came from>
Novadeck-Drop-When: <what makes this removable — e.g. "lands in v7.4">
```

Then `build.sh` asserts every patch has an `Origin`, and the bump question becomes a grep
instead of an archaeology session.

Current state, inferred from `From:` headers:

| Origin | Count |
|---|---|
| `mainline` | 8 |
| `novadeck` | 14 |
| `community` | 25 |
| `unknown` | 46 |

**46 patches have no `From:` header at all** — provenance for half the stack is already
lost. Those are marked `unknown` in the table and need a human pass; I am not going to guess
an author from a diff. Heaviest concentrations: gpu (7), dts (6), dpu (6), power (4),
haptics (4). Git history for when each was added is the obvious place to start.

**Also flagged:** the three LUTDMA patches (new `0360`, `0365`, `1145`) carry
`From: Armada <noreply@armada.local>` — a peer-distro name in shipped source, against the
standing rule that provenance goes in commits, not the tree. The renumber is the moment to
strip those author lines and record the origin in the trailer instead.

## Mapping

Sorted by new number — this is the resulting apply order.

| New | Band | Origin | Old name | New name |
|---|---|---|---|---|
| `0010` | core | `mainline` | `0504-Enable-64-bit-processes-to-use-compat-input-syscalls.patch` | `0010-enable-64-bit-processes-to-use-compat-input-syscalls.patch` |
| `0020` | core | `community` | `0505-arm64-emulate-unaligned-atomics.patch` | `0020-arm64-emulate-unaligned-atomics.patch` |
| `0110` | clk | `novadeck` | `0002-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` | `0110-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` |
| `0120` | clk | `unknown` | `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` | `0120-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` |
| `0130` | clk | `community` | `0122-interconnect__qcom__sm8550__Enable_QoS_configuration.patch` | `0130-interconnect-qcom-sm8550-enable-qos-configuration.patch` |
| `0210` | gpu | `community` | `0004-drm-msm-a6xx-Enable-IFPC-on-Adreno-740.patch` | `0210-drm-msm-a6xx-enable-ifpc-on-adreno-740.patch` |
| `0220` | gpu | `mainline` | `0513-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` | `0220-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` |
| `0230` | gpu | `unknown` | `0518-drm-msm-fix-barriers-accessing-ctx-vm.patch` | `0230-drm-msm-fix-barriers-accessing-ctx-vm.patch` |
| `0235` | gpu | `unknown` | `0519-drm-msm-rework-queuelock.patch` | `0235-drm-msm-rework-queuelock.patch` |
| `0240` | gpu | `unknown` | `0520-drm-msm-synchronize-vm-creation-on-ctxlock.patch` | `0240-drm-msm-synchronize-vm-creation-on-ctxlock.patch` |
| `0245` | gpu | `unknown` | `0521-drm-msm-add-helper-to-check-for-per-process-pgtables-vm.patch` | `0245-drm-msm-add-helper-to-check-for-per-process-pgtables-vm.patch` |
| `0250` | gpu | `unknown` | `0522-drm-msm-allow-lazy-vm-creation-to-fail.patch` | `0250-drm-msm-allow-lazy-vm-creation-to-fail.patch` |
| `0255` | gpu | `unknown` | `0523-drm-msm-dont-fallback-to-shared-vm-for-vm-bind.patch` | `0255-drm-msm-dont-fallback-to-shared-vm-for-vm-bind.patch` |
| `0260` | gpu | `unknown` | `0524-drm-msm-fix-per-process-pgtables-check.patch` | `0260-drm-msm-fix-per-process-pgtables-check.patch` |
| `0310` | dpu | `unknown` | `0509-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` | `0310-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` |
| `0320` | dpu | `unknown` | `0510-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` | `0320-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` |
| `0330` | dpu | `unknown` | `0515-drm-msm-fix-smmu-fault-dumps.patch` | `0330-drm-msm-fix-smmu-fault-dumps.patch` |
| `0340` | dpu | `unknown` | `0528-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` | `0340-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` |
| `0350` | dpu | `unknown` | `0529-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` | `0350-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` |
| `0360` | dpu | `community` | `0530-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` | `0360-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` |
| `0365` | dpu | `community` | `0531-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` | `0365-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` |
| `0370` | dpu | `unknown` | `dpu-quiesce-boot-scanout.patch` | `0370-dpu-quiesce-boot-scanout.patch` |
| `0410` | dsi | `novadeck` | `0003-msm-dsi-restore-wide_bus-bpp-calculation.patch` | `0410-msm-dsi-restore-wide-bus-bpp-calculation.patch` |
| `0420` | dsi | `novadeck` | `0005-msm-dsi-keep-link-clocks-up-while-display-active.patch` | `0420-msm-dsi-keep-link-clocks-up-while-display-active.patch` |
| `0430` | dsi | `unknown` | `0525-drm-msm-dsi-round-byte-clock-after-reparenting.patch` | `0430-drm-msm-dsi-round-byte-clock-after-reparenting.patch` |
| `0440` | dsi | `unknown` | `0534-Revert-Revert-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch` | `0440-revert-revert-drm-msm-dsi-fix-pll-init-in-bonded-mode.patch` |
| `0480` | drmcore | `community` | `0074-drm-panel-add-brightness-levels-helper.patch` | `0480-drm-panel-add-brightness-levels-helper.patch` |
| `0490` | drmcore | `mainline` | `0006-add-hw_params-callback-function-to-drm_connector_hdmi_audio_ops.patch` | `0490-add-hw-params-callback-function-to-drm-connector-hdmi-audio-ops.patch` |
| `0505` | panel | `novadeck` | `0051-gpu-panel-add-Pocket-ACE-panel-driver.patch` | `0505-gpu-panel-add-pocket-ace-panel-driver.patch` |
| `0510` | panel | `novadeck` | `0052-gpu-panel-add-Pocket-DMG-panel-driver.patch` | `0510-gpu-panel-add-pocket-dmg-panel-driver.patch` |
| `0515` | panel | `unknown` | `0054-gpu-panel-add-Pocket-DS-lower-panel-driver.patch` | `0515-gpu-panel-add-pocket-ds-lower-panel-driver.patch` |
| `0520` | panel | `community` | `0056_Synaptics-TD4328-LCD-panel.patch` | `0520-synaptics-td4328-lcd-panel.patch` |
| `0525` | panel | `community` | `0057_Xm-Plus-XM91080G-panel.patch` | `0525-xm-plus-xm91080g-panel.patch` |
| `0530` | panel | `community` | `0058_Chipone-ICNA35XX-panel.patch` | `0530-chipone-icna35xx-panel.patch` |
| `0535` | panel | `community` | `0059_DDIC-CH13726A-panel.patch` | `0535-ddic-ch13726a-panel.patch` |
| `0540` | panel | `novadeck` | `0066-gpu-drm-panel-add-wt0630-panel.patch` | `0540-gpu-drm-panel-add-wt0630-panel.patch` |
| `0545` | panel | `novadeck` | `0067-gpu-drm-panel-add-pocket-fit-panel.patch` | `0545-gpu-drm-panel-add-pocket-fit-panel.patch` |
| `0550` | panel | `community` | `0068-gpu-drm-panel-add-wt0600-1k-panel.patch` | `0550-gpu-drm-panel-add-wt0600-1k-panel.patch` |
| `0555` | panel | `unknown` | `0104-drm-panel-Add-Retroid-Pocket-6-panel.patch` | `0555-drm-panel-add-retroid-pocket-6-panel.patch` |
| `0560` | panel | `unknown` | `0105-drm-panel-Add-Retroid-Pocket-Nova-panel.patch` | `0560-drm-panel-add-retroid-pocket-nova-panel.patch` |
| `0610` | backlight | `community` | `0060_AYN-Odin2-Mini--backlight.patch` | `0610-ayn-odin2-mini-backlight.patch` |
| `0620` | backlight | `mainline` | `0062-backlight-Add-SY7758-6-channel-High-Efficiency-LED-Driver-support.patch` | `0620-backlight-add-sy7758-6-channel-high-efficiency-led-driver-support.patch` |
| `0650` | leds | `community` | `0033_leds--Add-driver-for-HEROIC-HTR3212.patch` | `0650-leds-add-driver-for-heroic-htr3212.patch` |
| `0660` | leds | `unknown` | `0040_leds--aw200xx-optional-vdd-supply.patch` | `0660-leds-aw200xx-optional-vdd-supply.patch` |
| `0680` | pwm | `community` | `0034_sn3112-pwm-driver.patch` | `0680-sn3112-pwm-driver.patch` |
| `0705` | touch | `novadeck` | `0015-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` | `0705-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` |
| `0710` | touch | `community` | `0053-edt-ft5x06-add-no_regmap_bulk_read-option.patch` | `0710-edt-ft5x06-add-no-regmap-bulk-read-option.patch` |
| `0715` | touch | `community` | `0055-input-goodix-override-resolution-from-dt.patch` | `0715-input-goodix-override-resolution-from-dt.patch` |
| `0720` | touch | `community` | `0061_AYN-Odin2-Mini--hynitron--cstxxx.patch` | `0720-ayn-odin2-mini-hynitron-cstxxx.patch` |
| `0725` | touch | `novadeck` | `0032-rmi4-silence-spam-irq-errors.patch` | `0725-rmi4-silence-spam-irq-errors.patch` |
| `0730` | touch | `novadeck` | `0063-input-touchscreen-add-synaptics-dsx-driver.patch` | `0730-input-touchscreen-add-synaptics-dsx-driver.patch` |
| `0735` | touch | `unknown` | `0064-input-touchscreen-add-synaptics-dsx-kconfig.patch` | `0735-input-touchscreen-add-synaptics-dsx-kconfig.patch` |
| `0738` | touch | `unknown` | `0069-input-add-chipone-tddi-touchscreen.patch` | `0738-input-add-chipone-tddi-touchscreen.patch` |
| `0745` | joystick | `novadeck` | `0031_input--Add-driver-for-RSInput-Gamepad.patch` | `0745-input-add-driver-for-rsinput-gamepad.patch` |
| `0750` | joystick | `unknown` | `0035_input--Add-driver-for-Retroid-Pocket-gamepad.patch` | `0750-input-add-driver-for-retroid-pocket-gamepad.patch` |
| `0755` | joystick | `unknown` | `0037_input--Add-driver-for-MANGMI-Pocket-Max-SPI-joypad.patch` | `0755-input-add-driver-for-mangmi-pocket-max-spi-joypad.patch` |
| `0770` | haptics | `unknown` | `0038_input--Add-driver-for-qcom-spmi-haptics.patch` | `0770-input-add-driver-for-qcom-spmi-haptics.patch` |
| `0775` | haptics | `community` | `0039_input--retroid-gamepad-add-force-feedback.patch` | `0775-input-retroid-gamepad-add-force-feedback.patch` |
| `0780` | haptics | `unknown` | `1000-add-qcom-haptics-driver.patch` | `0780-add-qcom-haptics-driver.patch` |
| `0785` | haptics | `unknown` | `1002-haptics-driver-support-periodic-sine-and-fixes.patch` | `0785-haptics-driver-support-periodic-sine-and-fixes.patch` |
| `0790` | haptics | `unknown` | `1003-rsinput-add-ff.patch` | `0790-rsinput-add-ff.patch` |
| `0795` | haptics | `community` | `1004-input-qcom-haptics-defer-rsinput-playback.patch` | `0795-input-qcom-haptics-defer-rsinput-playback.patch` |
| `0810` | audio | `community` | `0007-audioreach-Add-dedicated-WSA2-support.patch` | `0810-audioreach-add-dedicated-wsa2-support.patch` |
| `0820` | audio | `novadeck` | `0036_ASoC--qcom--sc8280xp-Add-support-for-Primary-I2S.patch` | `0820-asoc-qcom-sc8280xp-add-support-for-primary-i2s.patch` |
| `0830` | audio | `novadeck` | `0047_ASoC--codecs--aw88166--AYN-Odin2-Specific-modifica.patch` | `0830-asoc-codecs-aw88166-ayn-odin2-specific-modifications.patch` |
| `0840` | audio | `community` | `0200-ASoC-wcd938x-add-DMIC-DAPM-inputs.patch` | `0840-asoc-wcd938x-add-dmic-dapm-inputs.patch` |
| `0850` | audio | `novadeck` | `0201-ASoC-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` | `0850-asoc-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` |
| `0860` | audio | `unknown` | `0202-ASoC-wsa881x-request-powerdown-gpio-non-exclusively.patch` | `0860-asoc-wsa881x-request-powerdown-gpio-non-exclusively.patch` |
| `0870` | audio | `unknown` | `0203-ASoC-qcom-sm8250-force-S16_LE-only-for-compressed.patch` | `0870-asoc-qcom-sm8250-force-s16-le-only-for-compressed.patch` |
| `0880` | audio | `community` | `0204-ASoC-qcom-q6asm-dai-change-default-periods.patch` | `0880-asoc-qcom-q6asm-dai-change-default-periods.patch` |
| `0890` | audio | `unknown` | `0205-ASoC-wcd938x-guard-the-soundwire-interrupt-callback.patch` | `0890-asoc-wcd938x-guard-the-soundwire-interrupt-callback.patch` |
| `0910` | power | `unknown` | `0072-power-supply-add-qcom-pm8150b-charger-and-fg.patch` | `0910-power-supply-add-qcom-pm8150b-charger-and-fg.patch` |
| `0920` | power | `unknown` | `0073-power-supply-add-hl7139-charge-pump.patch` | `0920-power-supply-add-hl7139-charge-pump.patch` |
| `0930` | power | `unknown` | `0526-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` | `0930-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` |
| `0940` | power | `unknown` | `0527-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` | `0940-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` |
| `0970` | misc | `unknown` | `0500-ROCKNIX-set-boot-fanspeed.patch` | `0970-rocknix-set-boot-fanspeed.patch` |
| `0980` | misc | `unknown` | `1005-misc-add-ayaneo-serial-mcu.patch` | `0980-misc-add-ayaneo-serial-mcu.patch` |
| `1010` | net | `community` | `0507-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` | `1010-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` |
| `1030` | usb | `unknown` | `0071-HACK-fix-usb-boot-hang.patch` | `1030-hack-fix-usb-boot-hang.patch` |
| `1040` | usb | `unknown` | `0506-usbcore-add-interrupt-interval-override.patch` | `1040-usbcore-add-interrupt-interval-override.patch` |
| `1060` | pci | `unknown` | `0535-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` | `1060-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` |
| `1080` | crypto | `mainline` | `v6_20260210_quic_utiwari_crypto_qce_add_runtime_pm_and_interconnect_bandwidth_scaling_support.patch` | `1080-crypto-qce-add-runtime-pm-and-interconnect-bandwidth-scaling.patch` |
| `1105` | dts | `unknown` | `0000-pcie-update-sm8550-dtsi.patch` | `1105-pcie-update-sm8550-dtsi.patch` |
| `1110` | dts | `unknown` | `0001-pcie-update-sm8650-dtsi.patch` | `1110-pcie-update-sm8650-dtsi.patch` |
| `1115` | dts | `unknown` | `0008-arm64-dts-qcom-sm8250-add-uart16.patch` | `1115-arm64-dts-qcom-sm8250-add-uart16.patch` |
| `1120` | dts | `unknown` | `0009-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` | `1120-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` |
| `1125` | dts | `unknown` | `0010-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` | `1125-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` |
| `1130` | dts | `community` | `0011-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` | `1130-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` |
| `1135` | dts | `unknown` | `0012-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` | `1135-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` |
| `1140` | dts | `mainline` | `0120-20250728_konradybcio_gpu_cc_power_requirements_reality_check.patch` | `1140-arm64-dts-qcom-gpu-cc-power-requirements-reality-check.patch` |
| `1145` | dts | `community` | `0532-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` | `1145-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` |
| `1150` | dts | `mainline` | `20260424_neil_armstrong_arm64_dts_qcom_sm8_456_50_add_missing_cx_power_domain_to_gcc.patch` | `1150-arm64-dts-qcom-sm8450-8550-8650-add-missing-cx-power-domain-to-gcc.patch` |
| `1155` | dts | `mainline` | `v2_20260420_neil_armstrong_arm64_qcom_sm8650_misc_enhancements.patch` | `1155-arm64-dts-qcom-sm8650-misc-enhancements.patch` |

## Execution plan

1. Add `--fuzz=0` to `build.sh`. Build. Confirm the stack still applies clean *today*.
2. `git mv` all 93 in one commit, using the table above. History and blame survive a rename.
3. Run the order checker; it must stay at 0 violations.
4. Full `make` — the real gate is that a fuzz-zero build succeeds in the new order.
5. Rewrite `patches/README.md` around the band map; keep this mapping table reachable so
   older references (`0518-0524`, `0525`, `0530-0532`, `0507`) still resolve.
6. Fix the two in-repo references: `kernel/README.md:68` (`patch 0525` -> `0430`) and
   `docs/worklog/DONE.md:137` (`0121-pmdomain-…` -> `0120-pmdomain-…`).
7. Separately, as its own pass: add the trailers and triage the 46 `unknown`s.

## Open nits for review

- Lowercasing folds code identifiers in filenames: `wide_bus` -> `wide-bus`,
  `no_regmap_bulk_read` -> `no-regmap-bulk-read`, `S16_LE` -> `s16-le`. Cosmetic, but say so
  if you would rather preserve them.
- `0071-HACK-fix-usb-boot-hang` becomes `1030-hack-fix-usb-boot-hang`, losing the shouted
  HACK. Worth keeping visible?
- Four names had the author stripped out of the filename (`konradybcio`, `neil_armstrong`
  x2, `quic_utiwari`) and were renamed after their content, on the same
  provenance-goes-in-trailers logic. `0830`'s truncated `modifica` was completed to
  `modifications`.
- `0006` (drm HDMI audio helper) is filed under `drmcore` at `0490`, not audio — it is a
  `drivers/gpu/drm/display/` helper that the audio path consumes, and it must precede the
  audio band.

