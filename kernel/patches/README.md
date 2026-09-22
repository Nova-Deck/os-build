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
touching its neighbours. Consecutive backports from one upstream series are one patch file,
not one per commit: the series moves and drops as a unit, and the header lists each upstream
commit (`0230` carries twelve).

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

The number cannot answer *"can I drop this on a bump?"* — that is what provenance is for:

- **Origin** — `mainline` (the same change is in mainline; the commit is cited), `posted`
  (on a kernel list, not in mainline yet), `community` (a peer tree — ROCKNIX, armada, a
  vendor/CAF driver — never posted), `novadeck` (written here, never posted).
- **Source** — msgid of the posting we carry, or the tree it came from, plus the upstream
  state that decides its fate.
- **Drop when** — what makes it removable.

Audited 2026-09-22 against v7.3-rc4 (merge status from git, review state from patchwork
replies — lore was not reachable, so "never posted" means no patchwork hit). Re-audit on
every bump: this table is a snapshot, the `Drop when` column is what to re-check.

Totals: 6 `mainline`, 16 `posted`, 14 `novadeck`, 50 `community`. Half the stack will
never land upstream, which is why provenance is a table and not a number band.

| Patch | Origin | Source | Drop when |
|---|---|---|---|
| `0010` | community | Sergio Lopez, Asahi downstream (muvm/FEX); same as ROCKNIX `0504`. Never posted. | never — downstream prctl ABI |
| `0020` | community | Billy Laws, FEX downstream handler. A cut-down RFC (André Almeida, v2 `<20251117160841.334224-2-andrealmeid@igalia.com>`) was opposed by Will Deacon: arm64 will not carry x86 unaligned-atomic emulation. | never |
| `0110` | posted | Lucid Ole hunk = Esteban Urrutia "SM8450 QoL (dispcc)" v3 3/3 `<20260713-sm8450-qol-dispcc-v3-0-56fd05822270@proton.me>`, applied to the qcom clk tree (`2295d6a84179`), not in mainline. The sm8550 mdp-ops hunk is our retarget of v3 1/3 and was never sent — Dmitry asked for exactly this on other dispcc controllers. | guard: when `2295d6a84179` reaches mainline (≈7.4); mdp ops: when sent and merged |
| `0120` | community | ROCKNIX `ef264a238d` (sunshineinabox). Never posted. | never |
| `0130` | community | map220v via ROCKNIX `0122`. Never posted. The same change for x1e80100 is being reverted in 7.3 (hard resets) — high-risk to post. | never |
| `0210` | community | map220v via ROCKNIX `0004`. Never posted; reuses `a750_ifpc_reglist` (unverified for A740). | when A740 IFPC lands upstream |
| `0220` | posted | Rob Clark v2 `<20260912145922.24115-1-robin.clark@oss.qualcomm.com>` (+ `-2-`), latest, under review. | when merged |
| `0230` | mainline | Rob Clark v7 context/VM hardening `<20260729155609.20190-*>`, 12 of 17 squashed: 2–4, 9–17/18 (`ae88499d71ce` … `a6d87a272b2c`; list in the header). Not carried: 5–8, 18. | v7.3 |
| `0310` | mainline | Saim Shujah `<20260828065440.140410-1-saimzst@gmail.com>` → `a5b5cc909931` (Cc: stable) | v7.3, or the 7.2.y that backports it |
| `0330` | posted | Dmitry Baryshkov v3 `<20260912-fd-kms-fix-smmu-v3-0-a7ddc6fe2032@oss.qualcomm.com>` (we take 1, 2, 4–7 of 8), latest, no review yet. | when merged |
| `0340` | community | tiopex, ROCKNIX `ec3d53baac` (generic part split into ROCKNIX `0013-drm-msm-dpu-fix-inline-rotation`). Never posted; the width/height check, `test_bit` and CW/CCW fixes are real mainline bugs. | when the generic fixes are sent and merged |
| `0350` | community | tiopex, ROCKNIX `60bb58c1db`. Never posted. | never |
| `0360` | community | armada `7e9147a` + `12366dc` (virtudude), a port of the downstream SDE reg-dma engine. Never posted. | never |
| `0365` | community | armada `0069`. Never posted. | with `0360` |
| `0370` | community | sunshineinabox (ROCKNIX). Subject says v2, but no posting was found. | never |
| `0410` | novadeck | From ROCKNIX SM8250 `0001`. Partial revert of mainline `2d51cfb77daa` (bpc×3 for video mode). | when no shipped panel needs it, or upstream fixes it |
| `0420` | novadeck | v1 was ROCKNIX SM8250 `0016`; the xfer/modeset race fix is ours. Never posted. | when upstreamed |
| `0430` | mainline | Dmitry Baryshkov `<20260903-fix-eliza-dsi-v1-1-3474a6c9f2e0@oss.qualcomm.com>` → `2028280686f4` | v7.3 |
| `0440` | posted | Re-applies Neil Armstrong `93c97bc8d85d` (`<20251027-topic-sm8x50-fix-dsi-bonded-v1-1-…@linaro.org>`), reverted by `44784327815b` in 7.3-rc1 / 7.2.6 because it broke non-bonded panels. Neil's rework not posted. | when Neil's bonded-mode rework lands |
| `0480` | community | armada `0059` (virtudude). Not submitted; needs a panel-common binding first. | never |
| `0490` | posted | Jianfeng Liu v2 `<20250925040530.20731-1-liujianfeng1994@gmail.com>`. NAKed by Dmitry Baryshkov on design; he points to `b54a38af7138` (in 7.1, already in our tree) as the real fix. | now, if DP audio works without it on SM8550/SM8650 |
| `0505` | novadeck | Also ROCKNIX SM8550 `0051`. Driver-generator output, FIXME authorship. | never |
| `0510` | novadeck | Also ROCKNIX SM8550 `0052`. Same as `0505`. | never |
| `0515` | community | ROCKNIX. Superseded by mainline `4c0fe6422f3a` (st7703, `ayaneo,pocket-ds-lower-panel`). | v7.3 — change the DT compatible |
| `0520` | posted | Xilin Wu "AYN Odin 2 support" v1 04/10 `<20240424-ayn-odin2-initial-v1-4-e0aa05c991fd@gmail.com>`. v2 never sent. | never, unless mainline `panel-synaptics-tddi` can take TD4328 |
| `0525` | community | Teguh Sobirin via ROCKNIX `0056`. Never posted. | never |
| `0530` | community | Teguh Sobirin via ROCKNIX `0057`, plus our levels/linear scale. Mainline has its own `f747473a838e` (same file, per-board compatibles, no Mangmi/EVO); fix pending: Aaron Kling "Fix picture parameter set". | **v7.3 hard conflict** — rebase as a delta on the mainline driver |
| `0535` | community | Teguh Sobirin via ROCKNIX. Mainline 7.2 has a different driver, `panel-chipwealth-ch13726a` (`3ee01b8647b5`), Thor only, same `.name` as ours. | when the Retroid variants are added to the mainline driver |
| `0540` | community | KancyJoe via ROCKNIX SM8650 `0062`. Superseded by mainline `1190fc8d7b8a` (`panel-renesas-r63419`, same compatibles). | v7.3 — DT supplies become `vsp`/`vsn`; width is 78 mm there, 79 here |
| `0545` | novadeck | Also ROCKNIX SM8650 `0063`. Never posted. | never |
| `0550` | community | ROCKNIX. Never posted; possibly an R63419 variant (unverified). | never |
| `0555` | community | Teguh Sobirin via ROCKNIX `0104`. Aaron Kling posted a different version (`<20260814-rp6-panel-v1-4-111c1aeccf0f@gmail.com>`, `retroidpocket,rp6-panel`); v2 owed after Neil's review. | when Aaron's series lands — switch compatible |
| `0560` | community | Teguh Sobirin via ROCKNIX `0105`. Never posted. | never |
| `0610` | community | Teguh Sobirin via ROCKNIX `0058`. Never posted. | never |
| `0620` | mainline | Neil Armstrong v5 `<20260529-topic-sm8650-ayaneo-pocket-s2-sy7758-v5-1-03aacd49747c@linaro.org>` → `110d67699a43` (same driver file) | v7.3 |
| `0650` | community | Teguh Sobirin via ROCKNIX `0033`. Never posted. | never |
| `0660` | community | ROCKNIX SM8250 `0061`. Never posted; clean enough to send with a binding hunk. | when upstreamed |
| `0680` | posted | BigfootACA, in Xilin Wu's Odin 2 v1 02/10 `<20240424-ayn-odin2-initial-v1-2-e0aa05c991fd@gmail.com>`. v2 never sent. **Missing ROCKNIX fix `4609c5017f`** (`set_bit()` on a `u8[3]`: alignment fault + overflow). | never |
| `0705` | novadeck | Also ROCKNIX `0015`. Aaron Kling posted an equivalent (patchwork 14518751); Dmitry Torokhov pushed back. | never |
| `0710` | community | Teguh Sobirin via ROCKNIX `0053`. The DT property was rejected by Conor Dooley (series 1133142) — the fix belongs in an I2C adapter quirk. | never |
| `0715` | community | ROCKNIX (Pocket S 1K/2K). Never posted. | never |
| `0720` | community | Teguh Sobirin via ROCKNIX `0059`. Never posted. | never |
| `0725` | novadeck | Also ROCKNIX `0032`. A hack. | never |
| `0730` | novadeck | Port of the SynapticsHostSW `synaptics_dsx` vendor driver. | never |
| `0735` | novadeck | Kconfig for `0730`. | with `0730` |
| `0738` | community | Chipone vendor driver via kevinkreiser/chipone_tddi → ROCKNIX. ROCKNIX SM8750 has a ~380-line clean-room replacement (`0061-input-touchscreen-add-chipone-tddi`). | never |
| `0745` | novadeck | Driver by Teguh Sobirin; ROCKNIX SM8550 `0031`. Never posted. | never |
| `0750` | community | ROCKNIX SM8250 `0008` (Molly Sophia, BigfootACA, Teguh Sobirin). Never posted. | never |
| `0755` | community | ROCKNIX SM8250 `0060` (sunshineinabox). ROCKNIX has since added Air Y Pro support. | never |
| `0770` | posted | Caleb Connolly v7 `<20221015172915.1436236-3-caleb@connolly.tech>`, stalled since 2022. Fenglin Wu's PMIH driver (v7, 2026-08-28) uses the same file and the generic `qcom,spmi-haptics` compatible. | when David Heidelberg's pmi8998 haptics lands |
| `0775` | community | spycat88, ROCKNIX SM8250 `0013`. | never |
| `0780` | community | CAF/CLO downstream `qcom-hv-haptics` via ROCKNIX `1000`. | never |
| `0785` | community | ROCKNIX `1002`. | with `0780` |
| `0790` | community | ROCKNIX `1003`. | with `0780` |
| `0795` | community | gh123man, ROCKNIX PR #3116. | with `0780` |
| `0810` | community | KancyJoe via ROCKNIX SM8650 `0007`. Superseded by mainline `62dc2554d36d` (WSA2 channel map + `ayaneo,pocket-s2-sndcard`); will not apply on 7.3. | v7.3 — S2 moves to the new compatible; FIT needs its own card entry |
| `0820` | novadeck | Also ROCKNIX SM8550 `0036`. Superseded by mainline `088c4404b3d7` + `cc8495c1d45a` (MI2S clock control). | v7.3 — clocks move to `dai@PRIMARY_MI2S_RX` (`mclk`/`bclk`) |
| `0830` | novadeck | Teguh Sobirin's AYN series; its firmware-name part went upstream as `fc1fbafc18a0` (v7.1). Remainder never posted. | never |
| `0840` | community | Luke Johnson, ROCKNIX `0200`. Never posted; generic, worth sending. | when upstreamed |
| `0850` | novadeck | Also ROCKNIX `0612`. Related RFC: Jorijn van der Graaf `<20260705033830.305907-1-jorijnvdgraaf@catcrafts.net>`; Srinivas reproduced the missing clock but no fix yet. | when upstream fixes MI2S clocking before graph start |
| `0860` | community | ROCKNIX SM8250 `0062`. Mainline removed this flag (`d01fbee5c0d3`) in favour of `GPIO_SHARED`. | if a HW test without it passes |
| `0870` | community | ROCKNIX. Effectively reverts `89be3c15a58b`. | never |
| `0880` | community | Teguh Sobirin, ROCKNIX `0012`. | never |
| `0890` | community | Daniel Martin (Batocera), ROCKNIX `0300`. Never posted; generic, worth sending. | when upstreamed |
| `0910` | community | ROCKNIX `0011`. Charger alternative posted: `qcom_smbx` SMB5 v4 `<20260820-submit-qcom-smbx-send-v1-v4-*@snyders.xyz>` (under review). | charger: when SMB5 lands; FG: never |
| `0920` | community | ROCKNIX `0063` (sunshineinabox). Never posted. | never |
| `0930` | posted | Jan-Michael Brummer `<20260829054546.86210-2-jan.brummer@tabos.org>`. Konrad asked for `CHARGE_EMPTY` gating; v2 expected. | when merged |
| `0940` | posted | Same series, `-3-`. | when merged |
| `0970` | community | ROCKNIX `0500`. A hack. | never |
| `0980` | novadeck | Never posted. | never |
| `1010` | community | Edouard Durand. Never posted; the bug is still in v7.3-rc4. | when sent and merged |
| `1030` | community | spycat88, ROCKNIX `0071`. A hack. | never |
| `1040` | community | Kars Mulder's Linux-Pollrate-Patch via ROCKNIX `0506`. | never |
| `1060` | posted | Manivannan Sadhasivam `<20260907143349.317495-1-mani@kernel.org>`, applied to the PCI tree as `626acf6efc69`. Not in v7.3-rc4 or 7.2.y, no Cc: stable — yet 7.2.6+ needs it. | when `626acf6efc69` reaches our pinned release |
| `1080` | mainline | Udit Tiwari, v9 as merged: `6f5569203bb6`, cherry-picked clean onto v7.2.7 (replaced v6 `<20260210061437.2293654-1-quic_utiwari@quicinc.com>`). | v7.3 |
| `1105` | posted | Krishna Chaitanya Chundru root_port v2 15/15 `<20260917-root_port_v2-v2-15-6272b7caae9a@oss.qualcomm.com>`. 7.3 renames `pcieport0` → `pcie0_port0`. | when merged; rework at 7.3 either way |
| `1110` | posted | Same series, 12/15 `<20260917-root_port_v2-v2-12-6272b7caae9a@oss.qualcomm.com>`. | when merged |
| `1115` | community | ROCKNIX SM8250 `0005`. Never posted. | never |
| `1120` | community | ROCKNIX `9998-gpu-opp-table` (overclock). ROCKNIX has moved on to `9998-gpu-tuning`. | never |
| `1125` | community | ROCKNIX SM8250 `0004`; nodes for the out-of-tree `0770`/`0910` drivers. | with `0770`/`0910` |
| `1130` | community | spycat88, ROCKNIX `0102`. Upstream wants `rtc_offset` in board DTS, not the PMIC dtsi. | never |
| `1135` | posted | Krishna Chaitanya Chundru "Fix wake-gpios polarity" v2 06/18 `<20260917-root_port-v2-6-0d627d0856d5@oss.qualcomm.com>`. | when merged |
| `1140` | posted | Konrad Dybcio RFC v1 `<20250728-topic-gpucc_power_plumbing-v1-0-09c2480fe3e6@oss.qualcomm.com>` (modified). Ulf asked for a rebase in 2025-08; never resent. | never, unless Konrad resends |
| `1145` | community | armada `0070` (virtudude). | with `0360` |
| `1150` | posted | We carry Neil Armstrong v1 `<20260424-topic-sm8x50-tie-gcc-to-cx-v1-*>`; v2 `<20260615-topic-sm8x50-tie-gcc-to-cx-v2-0-6b5752dd4747@linaro.org>` has identical DTS hunks. v3 owed. | when merged |
| `1155` | mainline | Neil Armstrong v2 `<20260420-topic-sm8650-upstream-cpu-props-v2-*>`; v3 merged as `bb016ddb9061`, `884ff1172a70`, `c0bec4b58b8e` (identical code). | v7.3 |

## Mapping from the old numbering

The stack was renumbered from an ad-hoc scheme. This table resolves older references in
commits, docs and issues (`0518-0524`, `0525`, `0530-0532`, `0507`, …). The rename was
verified by applying both orderings to a clean 7.2.7 tree and diffing: the two patched
trees are byte-identical.

| New | Band | Was |
|---|---|---|
| `0010-enable-64-bit-processes-to-use-compat-input-syscalls.patch` | core | `0504-Enable-64-bit-processes-to-use-compat-input-syscalls.patch` |
| `0020-arm64-emulate-unaligned-atomics.patch` | core | `0505-arm64-emulate-unaligned-atomics.patch` |
| `0110-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` | clk | `0002-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` |
| `0120-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` | clk | `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` |
| `0130-interconnect-qcom-sm8550-enable-qos-configuration.patch` | clk | `0122-interconnect__qcom__sm8550__Enable_QoS_configuration.patch` |
| `0210-drm-msm-a6xx-enable-ifpc-on-adreno-740.patch` | gpu | `0004-drm-msm-a6xx-Enable-IFPC-on-Adreno-740.patch` |
| `0220-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` | gpu | `0513-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` |
| `0230-drm-msm-context-vm-hardening.patch` (folded) | gpu | `0518` … `0524` (seven files, one per commit) |
| `0310-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` | dpu | `0509-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` |
| *(dropped — regresses IGT upstream)* | dpu | `0510-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` |
| `0330-drm-msm-fix-smmu-fault-dumps.patch` | dpu | `0515-drm-msm-fix-smmu-fault-dumps.patch` |
| `0340-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` | dpu | `0528-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` |
| `0350-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` | dpu | `0529-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` |
| `0360-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` | dpu | `0530-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` |
| `0365-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` | dpu | `0531-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` |
| `0370-dpu-quiesce-boot-scanout.patch` | dpu | `dpu-quiesce-boot-scanout.patch` |
| `0410-msm-dsi-restore-wide-bus-bpp-calculation.patch` | dsi | `0003-msm-dsi-restore-wide_bus-bpp-calculation.patch` |
| `0420-msm-dsi-keep-link-clocks-up-while-display-active.patch` | dsi | `0005-msm-dsi-keep-link-clocks-up-while-display-active.patch` |
| `0430-drm-msm-dsi-round-byte-clock-after-reparenting.patch` | dsi | `0525-drm-msm-dsi-round-byte-clock-after-reparenting.patch` |
| `0440-revert-revert-drm-msm-dsi-fix-pll-init-in-bonded-mode.patch` | dsi | `0534-Revert-Revert-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch` |
| `0480-drm-panel-add-brightness-levels-helper.patch` | drmcore | `0074-drm-panel-add-brightness-levels-helper.patch` |
| `0490-add-hw-params-callback-function-to-drm-connector-hdmi-audio-ops.patch` | drmcore | `0006-add-hw_params-callback-function-to-drm_connector_hdmi_audio_ops.patch` |
| `0505-gpu-panel-add-pocket-ace-panel-driver.patch` | panel | `0051-gpu-panel-add-Pocket-ACE-panel-driver.patch` |
| `0510-gpu-panel-add-pocket-dmg-panel-driver.patch` | panel | `0052-gpu-panel-add-Pocket-DMG-panel-driver.patch` |
| `0515-gpu-panel-add-pocket-ds-lower-panel-driver.patch` | panel | `0054-gpu-panel-add-Pocket-DS-lower-panel-driver.patch` |
| `0520-synaptics-td4328-lcd-panel.patch` | panel | `0056_Synaptics-TD4328-LCD-panel.patch` |
| `0525-xm-plus-xm91080g-panel.patch` | panel | `0057_Xm-Plus-XM91080G-panel.patch` |
| `0530-chipone-icna35xx-panel.patch` | panel | `0058_Chipone-ICNA35XX-panel.patch` |
| `0535-ddic-ch13726a-panel.patch` | panel | `0059_DDIC-CH13726A-panel.patch` |
| `0540-gpu-drm-panel-add-wt0630-panel.patch` | panel | `0066-gpu-drm-panel-add-wt0630-panel.patch` |
| `0545-gpu-drm-panel-add-pocket-fit-panel.patch` | panel | `0067-gpu-drm-panel-add-pocket-fit-panel.patch` |
| `0550-gpu-drm-panel-add-wt0600-1k-panel.patch` | panel | `0068-gpu-drm-panel-add-wt0600-1k-panel.patch` |
| `0555-drm-panel-add-retroid-pocket-6-panel.patch` | panel | `0104-drm-panel-Add-Retroid-Pocket-6-panel.patch` |
| `0560-drm-panel-add-retroid-pocket-nova-panel.patch` | panel | `0105-drm-panel-Add-Retroid-Pocket-Nova-panel.patch` |
| `0610-ayn-odin2-mini-backlight.patch` | backlight | `0060_AYN-Odin2-Mini--backlight.patch` |
| `0620-backlight-add-sy7758-6-channel-high-efficiency-led-driver-support.patch` | backlight | `0062-backlight-Add-SY7758-6-channel-High-Efficiency-LED-Driver-support.patch` |
| `0650-leds-add-driver-for-heroic-htr3212.patch` | leds | `0033_leds--Add-driver-for-HEROIC-HTR3212.patch` |
| `0660-leds-aw200xx-optional-vdd-supply.patch` | leds | `0040_leds--aw200xx-optional-vdd-supply.patch` |
| `0680-sn3112-pwm-driver.patch` | pwm | `0034_sn3112-pwm-driver.patch` |
| `0705-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` | touch | `0015-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` |
| `0710-edt-ft5x06-add-no-regmap-bulk-read-option.patch` | touch | `0053-edt-ft5x06-add-no_regmap_bulk_read-option.patch` |
| `0715-input-goodix-override-resolution-from-dt.patch` | touch | `0055-input-goodix-override-resolution-from-dt.patch` |
| `0720-ayn-odin2-mini-hynitron-cstxxx.patch` | touch | `0061_AYN-Odin2-Mini--hynitron--cstxxx.patch` |
| `0725-rmi4-silence-spam-irq-errors.patch` | touch | `0032-rmi4-silence-spam-irq-errors.patch` |
| `0730-input-touchscreen-add-synaptics-dsx-driver.patch` | touch | `0063-input-touchscreen-add-synaptics-dsx-driver.patch` |
| `0735-input-touchscreen-add-synaptics-dsx-kconfig.patch` | touch | `0064-input-touchscreen-add-synaptics-dsx-kconfig.patch` |
| `0738-input-add-chipone-tddi-touchscreen.patch` | touch | `0069-input-add-chipone-tddi-touchscreen.patch` |
| `0745-input-add-driver-for-rsinput-gamepad.patch` | joystick | `0031_input--Add-driver-for-RSInput-Gamepad.patch` |
| `0750-input-add-driver-for-retroid-pocket-gamepad.patch` | joystick | `0035_input--Add-driver-for-Retroid-Pocket-gamepad.patch` |
| `0755-input-add-driver-for-mangmi-pocket-max-spi-joypad.patch` | joystick | `0037_input--Add-driver-for-MANGMI-Pocket-Max-SPI-joypad.patch` |
| `0770-input-add-driver-for-qcom-spmi-haptics.patch` | haptics | `0038_input--Add-driver-for-qcom-spmi-haptics.patch` |
| `0775-input-retroid-gamepad-add-force-feedback.patch` | haptics | `0039_input--retroid-gamepad-add-force-feedback.patch` |
| `0780-add-qcom-haptics-driver.patch` | haptics | `1000-add-qcom-haptics-driver.patch` |
| `0785-haptics-driver-support-periodic-sine-and-fixes.patch` | haptics | `1002-haptics-driver-support-periodic-sine-and-fixes.patch` |
| `0790-rsinput-add-ff.patch` | haptics | `1003-rsinput-add-ff.patch` |
| `0795-input-qcom-haptics-defer-rsinput-playback.patch` | haptics | `1004-input-qcom-haptics-defer-rsinput-playback.patch` |
| `0810-audioreach-add-dedicated-wsa2-support.patch` | audio | `0007-audioreach-Add-dedicated-WSA2-support.patch` |
| `0820-asoc-qcom-sc8280xp-add-support-for-primary-i2s.patch` | audio | `0036_ASoC--qcom--sc8280xp-Add-support-for-Primary-I2S.patch` |
| `0830-asoc-codecs-aw88166-ayn-odin2-specific-modifications.patch` | audio | `0047_ASoC--codecs--aw88166--AYN-Odin2-Specific-modifica.patch` |
| `0840-asoc-wcd938x-add-dmic-dapm-inputs.patch` | audio | `0200-ASoC-wcd938x-add-DMIC-DAPM-inputs.patch` |
| `0850-asoc-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` | audio | `0201-ASoC-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` |
| `0860-asoc-wsa881x-request-powerdown-gpio-non-exclusively.patch` | audio | `0202-ASoC-wsa881x-request-powerdown-gpio-non-exclusively.patch` |
| `0870-asoc-qcom-sm8250-force-s16-le-only-for-compressed.patch` | audio | `0203-ASoC-qcom-sm8250-force-S16_LE-only-for-compressed.patch` |
| `0880-asoc-qcom-q6asm-dai-change-default-periods.patch` | audio | `0204-ASoC-qcom-q6asm-dai-change-default-periods.patch` |
| `0890-asoc-wcd938x-guard-the-soundwire-interrupt-callback.patch` | audio | `0205-ASoC-wcd938x-guard-the-soundwire-interrupt-callback.patch` |
| `0910-power-supply-add-qcom-pm8150b-charger-and-fg.patch` | power | `0072-power-supply-add-qcom-pm8150b-charger-and-fg.patch` |
| `0920-power-supply-add-hl7139-charge-pump.patch` | power | `0073-power-supply-add-hl7139-charge-pump.patch` |
| `0930-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` | power | `0526-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` |
| `0940-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` | power | `0527-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` |
| `0970-rocknix-set-boot-fanspeed.patch` | misc | `0500-ROCKNIX-set-boot-fanspeed.patch` |
| `0980-misc-add-ayaneo-serial-mcu.patch` | misc | `1005-misc-add-ayaneo-serial-mcu.patch` |
| `1010-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` | net | `0507-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` |
| `1030-hack-fix-usb-boot-hang.patch` | usb | `0071-HACK-fix-usb-boot-hang.patch` |
| `1040-usbcore-add-interrupt-interval-override.patch` | usb | `0506-usbcore-add-interrupt-interval-override.patch` |
| `1060-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` | pci | `0535-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` |
| `1080-crypto-qce-add-runtime-pm-and-interconnect-bandwidth-scaling.patch` | crypto | `v6_20260210_quic_utiwari_crypto_qce_add_runtime_pm_and_interconnect_bandwidth_scaling_support.patch` |
| `1105-pcie-update-sm8550-dtsi.patch` | dts | `0000-pcie-update-sm8550-dtsi.patch` |
| `1110-pcie-update-sm8650-dtsi.patch` | dts | `0001-pcie-update-sm8650-dtsi.patch` |
| `1115-arm64-dts-qcom-sm8250-add-uart16.patch` | dts | `0008-arm64-dts-qcom-sm8250-add-uart16.patch` |
| `1120-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` | dts | `0009-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` |
| `1125-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` | dts | `0010-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` |
| `1130-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` | dts | `0011-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` |
| `1135-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` | dts | `0012-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` |
| `1140-arm64-dts-qcom-gpu-cc-power-requirements-reality-check.patch` | dts | `0120-20250728_konradybcio_gpu_cc_power_requirements_reality_check.patch` |
| `1145-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` | dts | `0532-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` |
| `1150-arm64-dts-qcom-sm8450-8550-8650-add-missing-cx-power-domain-to-gcc.patch` | dts | `20260424_neil_armstrong_arm64_dts_qcom_sm8_456_50_add_missing_cx_power_domain_to_gcc.patch` |
| `1155-arm64-dts-qcom-sm8650-misc-enhancements.patch` | dts | `v2_20260420_neil_armstrong_arm64_qcom_sm8650_misc_enhancements.patch` |
