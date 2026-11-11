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
| `0100-0199` | clk | clk, pmdomain, interconnect, iommu |
| `0200-0299` | gpu | drm/msm GPU: adreno, GEM, VM_BIND, shrinker |
| `0300-0399` | dpu | drm/msm DPU: planes, flush, rotation, LUTDMA (+ its binding) |
| `0400-0479` | dsi | drm/msm DSI: host, PHY, byte clock |
| `0480-0499` | drmcore | drm core helpers that later patches build on |
| `0500-0599` | panel | drm/panel drivers, one per number |
| `0600-0699` | backlight / leds / pwm | backlight `0600s`, leds `0650s`, pwm `0680s` |
| `0700-0799` | input | touch `0700s`, joystick `0740s`, haptics + force-feedback `0770s` |
| `0800-0899` | audio | ASoC, qdsp6, codecs |
| `0900-0999` | power / misc | power-supply `0900s`, hwmon + misc devices `0970s` |
| `1000-1089` | net / usb / pci / storage / crypto | |
| `1090-1099` | media | V4L2 / iris video decode |
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
replies — lore was not reachable, so "never posted" means no patchwork hit). `posted` and
`mainline` rows re-audited 2026-10-12 against v7.3-rc7, the 7.2.10 pin and the maintainer
trees (msm-next, qcom `clk-for-7.4` / `arm64-for-7.4`, pci `next`). Re-audit on
every bump: this table is a snapshot, the `Drop when` column is what to re-check.

Totals (7.3.1 bump, 2026-10-30): 0 `mainline`, 18 `posted`, 24 `novadeck`, 120 `community` = 162.
Since then (2026-11-03, iris Remote Play `1091`–`1094`, ath12k DTIM revert `1026`, andrebraga SM8750 backports, Pocket S2/FIT headphone cap `0825`, wcd939x HPH volume controls `0849`, iris gen2 encoder frame type `1096`, iris encoder frame rate `1097`): 32 `posted`, 27 `novadeck`, 121 `community` = 180.
Then (2026-11-05, andrebraga `Kernel_7.3` @ `16b48205d6` triage: `0285 0397 0859 0897 0950 1007 1027 1028 1099 1171`): 2 `mainline`, 39 `posted`, 27 `novadeck`, 122 `community` = 190.
Then (2026-11-05, gen1 encoder rate control `1098`): 2 `mainline`, 39 `posted`, 28 `novadeck`, 122 `community` = 191.
Then (2026-11-05, Pocket S2/FIT headphone PCM route `0860`–`0863`): 2 `mainline`, 39 `posted`, 28 `novadeck`, 126 `community` = 195.
Then (2026-11-07, andrebraga `Kernel_7.3` @ `1c1c374bdc` ports `1024 1029 1170`, then bandwidth/frequency scaling `0160 0165 0170 0175 0286 0288 0289 1180 1182 1184` for an A/B): 2 `mainline`, 40 `posted`, 28 `novadeck`, 138 `community` = 208.
Then (2026-11-09, sm8550 CPU7 3.36 GHz OPP `1155`): 2 `mainline`, 41 `posted`, 28 `novadeck`, 138 `community` = 209.
Then (2026-11-09, sm8250 active-only CPU interconnect tags `1137`): 2 `mainline`, 42 `posted`, 28 `novadeck`, 138 `community` = 210.
Then (2026-11-09, SM8550/SM8650 MDSS identity domain at boot `0190`/`0195`): 2 `mainline`, 43 `posted`, 29 `novadeck`, 138 `community` = 212.
Then (2026-11-09, ufs-qcom checks for its PHY before powering up, the Pocket FIT reset `1089`): 2 `mainline`, 43 `posted`, 30 `novadeck`, 138 `community` = 213.
Then (2026-11-10, DPU returns `-EINVAL` when no SSPP is free `0386`): 2 `mainline`, 43 `posted`, 30 `novadeck`, 139 `community` = 214.
The 7.3 bump deleted every `mainline` row (`0230 0620 0800 1080 1155`), the two `posted` ones
that landed (`0275 1170`), and `0810`/`0825` with the old `0820`, whose jobs mainline's
`ayaneo,pocket-s2-sndcard` and per-DAI MI2S clocks now do; `0820` is reused for the sm8750
bclk enable and `0825` for the Pocket S2 headphone cap. (`0310` and `0430` were
deleted at the 7.2.8 bump: stable backported both, byte-identical; the `0430` slot is reused
by the SM8750 DSI reparent-on-power-off patch, a different change.) Half the stack will
never land upstream, which is why provenance is a table and not a number band.

SM8750 port (2026-10-19, issue #121): 36 patches added from ROCKNIX SM8750 + armada, all
audited against 7.2.11 — NOT taken because already upstream at this pin: ROCKNIX `0050`
(gdsc_gx_disable), `0055` (aw99706 fixes), `0517` (typec-mux EPROBE_DEFER), the sgm3804
regulator, the vpu35/gen80000 firmware (LINUX_FW.pin); NOT taken by policy: the whole
suspend-to-RAM set (ROCKNIX `0504`/`0508`, armada's S2R layer, SoCCP), the stick-ring
RGB half of konkr_sysbtn, rsinput `1300` global-default recalibration (per-board module
params on the Odin 3 boards.map row instead). The hv-haptics HAP530/V5 driver generation
was deferred at first (it swaps the rumble stack under every shipping board) and then
taken for issue #122 — see the `0780`–`0796` rows.

| Patch | Origin | Source | Drop when |
|---|---|---|---|
| `0010` | community | Sergio Lopez, Asahi downstream (muvm/FEX); same as ROCKNIX `0504`. Never posted. | never — downstream prctl ABI |
| `0020` | community | Billy Laws, FEX downstream handler. A cut-down RFC (André Almeida, v2 `<20251117160841.334224-2-andrealmeid@igalia.com>`) was opposed by Will Deacon: arm64 will not carry x86 unaligned-atomic emulation. We fixed a missing exception-table entry on `Load128`'s `stlxp` (kernel oops on SM8250, which lacks LSE2 and traps every unaligned atomic), and made backpatch cache maintenance fault-safe (`caches_clean_inval_user_pou()` instead of `flush_icache_range()` on user code; from Kettle Linux `1389`). | never |
| `0110` | posted | Lucid Ole hunk = Esteban Urrutia "SM8450 QoL (dispcc)" v3 3/3 `<20260713-sm8450-qol-dispcc-v3-0-56fd05822270@proton.me>`, re-applied to qcom `clk-for-7.4` as `eb34e2804ce4` (2026-09-23; the earlier `2295d6a84179` never reached mainline), no Cc: stable. The sm8550 mdp-ops hunk is our retarget of v3 1/3 and was never sent — Dmitry asked for exactly this on other dispcc controllers. | guard: when `eb34e2804ce4` reaches our pin (v7.4); mdp ops: when sent and merged |
| `0120` | posted | Oleg Keri, "pmdomain: qcom: rpmhpd: don't clamp gfx and gmxc before sync_state" `<20261021080517.2161-1-okerixx@gmail.com>`, Acked-by Akhil P Oommen, Tested-by on SM8750; via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0052`. Replaced 2026-11-03 the armada-scoped presync floor (armada `0121`, ex-ROCKNIX `ef264a238d`). Unlike that one it is GLOBAL: the shared `gfx`/`gmxc` domains skip the pre-sync_state clamp on every SoC, so SM8250/SM8550/SM8650 GPUs also boot unclamped now (HW check owed on each). | when merged |
| `0130` | community | map220v via ROCKNIX `0122`. Never posted. The same change for x1e80100 is being reverted in 7.3 (hard resets) — high-risk to post. | never |
| `0140` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 24/42 + 25/42 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, applied to qcom `clk-for-7.4` (sm8550 `fe2a50974f4a`, sm8650 `e4e6177235c6`). `.use_rpm = true`: runtime PM on GCC, so CX can drop once every GCC consumer has released its clocks and GDSCs. Needs `1150`'s `power-domains` in DT. | v7.4 |
| `0150` | community | Teguh Sobirin, ROCKNIX SM8750 `0044` (`Fixes: 3267c774f3ff`). Suspend-motivated upstream fix (PWRSTS_RET_ON so PCIe GDSCs survive gdsc_disable()); kept for GDSC-policy parity with sm8550/sm8650, whose upstream GCCs already use RET_ON — inert here without kernel sleep. | when 7.2.y/7.3 takes the fix |
| `0160` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0515` @ `1c1c374bdc`, not posted, body identical. scmi-cpufreq builds the CPU OPP tables from firmware and never sets an OPP, so `opp-peak-kBps` in a CPU's DT OPP table cast no interconnect vote; it now adds the DT table and sets the OPP on each frequency change (fast switches hand the vote to a worker through irq_work). Inert without the `1182` tables. Runtime switch: `/sys/devices/system/cpu/cpufreq/policy*/bandwidth_votes`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0165` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0526` @ `1c1c374bdc`, not posted, body identical. icc-bwmon votes the measured CPU traffic as peak only, which aggregates as a max and never adds to the GPU's traffic; it now also votes it as average, as downstream bwmon does. Affects every SoC with bwmon (SM8550, SM8650, SM8750). Runtime switch: `icc_bwmon.vote_avg`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0170` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0517` + its binding `0516` @ `1c1c374bdc`, not posted; MAINTAINERS hunk dropped. Perf PMU for the SM8750 LLCC's per-CPU read-miss counters (downstream llcc-pmu-ver2), the miss source for `0175`. | when upstreamed, or with `0175` |
| `0175` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0523` + its binding `0522` @ `1c1c374bdc`, not posted; MAINTAINERS hunk dropped. CPU memory latency voter: while a CPU misses often per instruction it votes the LLCC/DDR frequency its DT table maps the CPU frequency to (downstream memlat runs in the kernel on SM8750). Binds only from the `1180` DT nodes. Runtime switch: the driver's sysfs `enable`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0190` | posted | Nizat Mikayilli, "iommu/arm-smmu-qcom: Add SM8550 MDSS compatible" v1 `<20261107-b4-smmu-sm8550-v1-1-777d0a41170b@dxdmail.cc>`, body byte-identical (b4); no replies as of 2026-11-09. Gives SM8550 MDSS an identity domain at boot, so the bootloader splash still scanning out at kernel entry does not fault on an empty translating domain before `0370` stops it. Aimed at the Pocket ACE's 10 boot-time `cbfrsynra=0x1c00` context faults (`kernel/SOURCE.pin`, KNOWN BOOT NOISE). HW gate: that count goes to 0. | when merged |
| `0195` | novadeck | `0190` for `qcom,sm8650-mdss`: same splash handoff on the SM8650 boards (ayaneo-common's `cont_splash_region`, chainloaded EFI). Taken while the Pocket FIT reboots now and then during kernel boot, with no trace of why. It works on the FIT (2026-11-09: the `ae00000` iommu group is `identity`), but the FIT still reset during kernel boot with it in, so it is NOT the reboot fix. The FIT never showed the splash faults, so it has no measured effect there. Never posted. | with `0190`, or when posted and merged |
| `0210` | community | map220v via ROCKNIX `0004`. Never posted; reuses `a750_ifpc_reglist` (unverified for A740). | when A740 IFPC lands upstream |
| `0220` | posted | Rob Clark v2 `<20260912145922.24115-1-robin.clark@oss.qualcomm.com>` (+ `-2-`), applied to msm-next 2026-09-27 as `bbe4401e118c` (THP) + `8eeca96ad138` (shrinker modparam), code identical to ours. Patchwork still says `new`. | v7.4 |
| `0240` | novadeck | Written here, from GPU runtime-PM traces on the Pocket S2. Works around the trigger (suspend soon after resume); why the A750 GMU never reaches IFPC is not known. Never posted; no prior report found on linux-arm-msm, patchwork or drm/msm issues. | when upstream fixes the A750 GMU idle wait, or sets its own A750 `inactive_period` |
| `0250` | community | gennro, kettlelinux `1350` via armada `0620` (PR #662). Not posted. Masks `a6xx_hfi_irq()`'s clear to CM3_FAULT, as kgsl does; the root cause of the A740 `GPU_SET` OOB timeout wedge. | when mainline stops the HFI handler clearing polled bits |
| `0255` | community | gennro, kettlelinux `1351` via armada `0621` (PR #662). Not posted. Bounds the `fault_coredump_done` wait (2 s) that deadlocks against `recover_worker`. | when mainline bounds that wait |
| `0260` | community | armada `0622` (PR #662). Not posted. Masks `GMU2HOST_INTR_MASK` before the GMU boots, so resume replies do not raise the HFI irq. | with `0250`, or when mainline programs the mask before `a6xx_hfi_start()` |
| `0265` | community | gennro, Kettle Linux `1180`, body byte-identical. On GMU-bandwidth-voting GPUs (A740, A750) the boot bus vote set at resume was never dropped, holding DDR at the boot OPP's bandwidth while the GPU stays powered (measured on the Pocket FIT: GPU `ebi` peak 8.17 GB/s whenever active). | when mainline drops the boot vote |
| `0268` | posted | Jie Zhang, "drm/msm/devfreq: Record idle_time at GPU idle onset" `<20261024-assorted-fixes-oct-v1-4-2977f974ddb7@oss.qualcomm.com>` (Cc stable, Reviewed-by Konrad Dybcio), body as posted. `df->idle_time` was stamped in the idle work, so a cancelled idle work left a stale timestamp; idle time then accumulated across idle cycles and could trigger a spurious devfreq boost. Every GPU. | when it reaches the pinned release (stable or v7.4+) |
| `0270` | posted | Jie Zhang, "drm/msm: Fix sched_prio inversion within a ring" `<20261024-assorted-fixes-oct-v1-5-2977f974ddb7@oss.qualcomm.com>` (Cc stable, Acked-by Konrad Dybcio), body as posted. Replaced virtudude's Kettle Linux `1210`, which produced the same code. `msm_gpu_convert_priority()` inverts the within-ring order (userspace 2 → `DRM_SCHED_PRIORITY_KERNEL`, 0 → `NORMAL`), so on one ring a Turnip queue (a game) outranks freedreno GL (Xwayland, the Steam UI) and can starve it. Matters most on the single-ring A650, where the game-priority layer cannot move games to another ring. | when it reaches the pinned release (stable or v7.4+) |
| `0280` | posted | Jie Zhang, "drm/msm/a8xx: Add support for Adreno 830 GPU" (pakala-gpu v1 1/4) `<20260809-pakala-gpu-v1-1-207ad1fac1c7@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0034` (peer: in mainline for 7.4). Replaced 2026-11-03 the community catalog row (ROCKNIX SM8750 `0049`). Chip ID `0x44050001`, which our Mesa `0001` already lists. | v7.4 |
| `0281` | posted | Konrad Dybcio, "drm/msm/a6xx: Send AB GMU votes on A8xx" `<20261030-topic-a8xx_ab_vote-v1-1-66afb5bc50b9@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0083` (linux-arm-msm queue). | when merged |
| `0282` | posted | Connor Abbott, "drm/msm: Fix GMEM_BASE on a8xx" v2 `<20261029-drm-msm-gmem-base-fix-v2-1-26b338471b46@gmail.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0084`. | when merged |
| `0283` | posted | Rahul Pon, "drm/msm/a8xx: report the GMEM size of the active slices" v2 `<20260930183840.1171-1-theflyingrahul@gmail.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0085`; one context line regenerated after `0282`. | when merged |
| `0285` | mainline | Akhil P Oommen, Hawi GPU series `<20260923-hawi-gpu-v1-*-0c3c79a1a470@oss.qualcomm.com>`: `128a0edde507`, `eab0aff8965e`, `b5269bf0e1ad`, `86f80884fb7f`, all v7.4-rc1. `eab0aff8965e` alone (andrebraga ROCKNIX SM8750 `Kernel_7.3` `2010`) makes a GPU corner above the top MX corner fail GMU init on every GMU GPU; `86f80884fb7f` clamps it and needs `b5269bf0e1ad`. `020b8eaa1db8` (BX rail) skipped. | v7.4 |
| `0286` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2291` + its binding `2290` @ `1c1c374bdc`, not posted. The GMU voted DDR for the GPU OPP's bandwidth, so DDR rose only with the GPU clock; it now floats the vote within a per-OPP `qcom,opp-peak-kBps-range` from the GBIF traffic counters, as downstream gpubw_mon does, and votes AB as the measured traffic. Rebased onto our `0265` instead of upstream's "Fix stale boot up BW vote" (his `2011`). The bandwidth-table rewrite runs on every bcms GPU (A740/A750 too), and only A8xx measures. Runtime switch: `msm.gpu_bus_dcvs`. HW A/B owed; SM8550/SM8650 GPU regression check owed. | when upstreamed, or dropped on a failed A/B |
| `0288` | posted | Akhil P Oommen, "drm/msm/a6xx: Add HFI support for CLX feature" `<20260516-a8xx-clx-support-v1-1-62508bf651ac@oss.qualcomm.com>` (msm-next, v7.4) + "drm/msm/a6xx: Request CLX enable from secure world" `<20261024-assorted-fixes-oct-v1-7-2977f974ddb7@oss.qualcomm.com>` (posted, reviewed), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2295` + `2296`. GPU peak-current limiting on the GX/MX rails; inert without a catalog table (`0289`). | when both are in the pinned release |
| `0289` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2297` @ `1c1c374bdc`, not posted, body identical. A830 CLX catalog table, values from downstream kgsl gen8_0_0. A current limiter: may cap peak GPU clocks, so it is in the A/B. | when upstreamed, or dropped on a failed A/B |
| `0330` | posted | Dmitry Baryshkov v4 `<20261003-fd-kms-fix-smmu-v4-0-2a44d4d8ac77@oss.qualcomm.com>` (we take 1–3, 5–9 of 10; skip MDP5-only 4 and drm/ci 10), latest. Replaced v3 on 2026-10-12: 3/10 now queues and schedules a retired framebuffer under one lock so vblank-off cannot free it in between; 5/6 add CWB/CDM reservation clears. v4 names a prerequisite, "KMS destroy fixes" `<20261003-msm-kms-destroy-fixes-v1-*>` (init/teardown error paths), which we do not carry. Not in msm-next. | when merged |
| `0340` | community | tiopex, ROCKNIX `ec3d53baac` (generic part split into ROCKNIX `0013-drm-msm-dpu-fix-inline-rotation`). Never posted; the width/height check, `test_bit` and CW/CCW fixes are real mainline bugs. | when the generic fixes are sent and merged |
| `0341` | community | enij90 (armada-tb321fu `ee94cd65` `0818`), taken via ROCKNIX PR #3508 (`0018`); header renumbered to our `0340`. Never posted. Measured by writeback on SM8650; only affects pipes that rotate inline. | with `0340`, or when mainline programs a rotation-aware QSEED4 preload |
| `0342` | community | Content-equivalent of ROCKNIX SM8750 `0068`, re-expressed on `0340`'s core: the four SM8750 VIG pipes get `VIG_SM8550_MASK_SDMA` + a scaler-3.4 rot_v2 sblk reusing the shared `dpu_rot_sm8550_cfg_v201` (ROCKNIX mints byte-identical SM8750-named copies; armada `0066` merged all three SoCs the same way). | with `0340` |
| `0343` | posted | Rob Clark, "drm/msm/dpu: Fix GAMMA LUT for sm8750 related DPUs" `<20260930152645.22194-1-robin.clark@oss.qualcomm.com>`, Reviewed-by Dmitry Baryshkov, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0082`: the SM8750 DSPP gains its register GC block, so CRTCs expose GAMMA_LUT. `0360` was rebased onto it (its note that SM8750 GC is a LUT-bus block is superseded). | when merged |
| `0350` | community | tiopex, ROCKNIX `60bb58c1db`. Never posted. | never |
| `0351` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0208`), hand-merged onto `0350` with `0350`'s values as the defaults; the PR's own set is in the header as a cmdline profile. Never posted. | never |
| `0352` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0210`), rebased onto `0351`. Never posted. | never |
| `0360` | community | armada `7e9147a` + `12366dc` (virtudude), a port of the downstream SDE reg-dma engine. Never posted. | never |
| `0365` | community | armada `0069`. Never posted. | with `0360` |
| `0370` | community | sunshineinabox (ROCKNIX). Subject says v2, but no posting was found. | never |
| `0380` | community | sunshineinabox, ROCKNIX PR #3377 (`0012`, `0014`, `0015`, squashed). Vendor-DT catalog values, never posted. | never |
| `0385` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0201` + `0202` as of `566a53ef`, squashed), plus our no-rotator guard for inline-rotation SoCs and the 0330 `msm_framebuffer_cleanup()` / 0230 `msm_gem_new()` signatures. Never posted. Enabled per board by `dts/qcom/sm8250-sde-rotator.dtsi`. | never |
| `0386` | community | hashtagbasit, Zaviya `0078` (sm8650-74), body byte-identical, only re-offset. Never posted. With virtual planes (the default), a plane that finds no free SSPP failed the atomic check with `-ENODEV`. The atomic contract is `-EINVAL` for a state the hardware can't do: libliftoff takes only `-EINVAL`/`-ERANGE`/`-ENOSPC` as "this layout doesn't fit" and stops searching on anything else, and gamescope caches only `-EINVAL` failures, so it retried the same layout every frame. `0385`'s rotator path already returned `-EINVAL`. | when upstreamed |
| `0390` | community | armada `0078` (PR #629). Never posted. Command-mode only: the INTF TE path read the video timing engine's line counter, which does not run there; it now reads the tear-check counter, as the pingpong TE path already did. Video-mode panels are untouched. | when mainline fixes the INTF-TE scanout position |
| `0392` | community | Teguh Sobirin, RetroidPocket/linux `b547718c91db`. Never posted. Command-mode only: a single-interface panel wider than 1080 without DSC gets two layer mixers, and the command encoder never programmed or flushed MERGE_3D, so the panel got half of every line (`CMD_MDP_FIFO_UNDERFLOW`, kickoff timeouts). Only the Nova (`0560`) hits it. | when mainline programs MERGE_3D on command-mode encoders |
| `0395` | novadeck | Issue #110: on a dual-interface video-mode panel, per-interface CTL flushes that straddle the programmable fetch start underrun the next frame (black blink). One wait per kickoff, on the master, keeps them on one side. Never posted; generic, worth sending once HW-proven. | when mainline guards the kickoff against the fetch start |
| `0396` | novadeck | A command-mode frame is sent to the panel at kickoff and shown from the first TE after its transfer starts, but the page flip event went out after the transfer stamped with the PREVIOUS TE. gamescope schedules from that stamp, one refresh early, so a limited frame missed every second refresh (Pocket Max: 60 fps @ 120 Hz ran 40). The event is now armed from the CTL start irq for the next vblank, as on video mode. HW: Pocket FIT all caps solid; Pocket Max solid except where the `0385` rotator fence delays the kickoff (cap = refresh). Never posted; generic. | when mainline reports command-mode flips at the vblank they show at |
| `0397` | posted | Michael Burch v2 `<20261013172703.12273-1-me@michaelburch.net>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2020`. `frame_pending` counted after kickoff could leak, keeping a video-mode encoder out of idle and its vsync interrupt on. The commit's BW-release leg is inert here: `enable_bw_release` is a debugfs knob, off by default. | when merged |
| `0410` | novadeck | From ROCKNIX SM8250 `0001`. Partial revert of mainline `2d51cfb77daa` (bpc×3 for video mode). | when no shipped panel needs it, or upstream fixes it |
| `0420` | novadeck | v1 was ROCKNIX SM8250 `0016`; the xfer/modeset race fix is ours. Never posted. | when upstreamed |
| `0430` | community | Teguh Sobirin, ROCKNIX SM8750 `0048`, rebased to 7.2.11 (one struct context line drifted). Reparents the byte/pixel RCGs back to their original (XO) parent in `msm_dsi_host_power_off()` — the SM8750 dispcc stalls its RCG update when the selected source (the powered-down PHY PLL) is dead. NOT the same patch as the old `0430` (stable took that one, "round byte clock after reparenting"). | when upstream restores the RCG parent on disable |
| `0440` | community | armada `0048b` (virtudude). Never posted. Replaces our re-apply of Neil Armstrong `93c97bc8d85d`, reverted by `44784327815b` in 7.3-rc1 / 7.2.6 because it broke non-bonded panels; this keeps the revert and adds the missing slave-PHY mux write. Neil's rework not posted. | when Neil's bonded-mode rework lands |
| `0480` | community | armada `0059` (virtudude). Not submitted; needs a panel-common binding first. | never |
| `0490` | posted | Jianfeng Liu v2 `<20250925040530.20731-1-liujianfeng1994@gmail.com>`. NAKed by Dmitry Baryshkov on design; he points to `b54a38af7138` (in 7.1, already in our tree) as the real fix. | now, if DP audio works without it on SM8550/SM8650 |
| `0505` | novadeck | Also ROCKNIX SM8550 `0051`. Driver-generator output, FIXME authorship. | never |
| `0510` | novadeck | Also ROCKNIX SM8550 `0052`. Same as `0505`. | never |
| `0515` | community | ROCKNIX. Superseded by mainline `4c0fe6422f3a` (st7703, `ayaneo,pocket-ds-lower-panel`). | v7.3 — change the DT compatible |
| `0520` | posted | Xilin Wu "AYN Odin 2 support" v1 04/10 `<20240424-ayn-odin2-initial-v1-4-e0aa05c991fd@gmail.com>`. v2 never sent. | never, unless mainline `panel-synaptics-tddi` can take TD4328 |
| `0525` | community | Teguh Sobirin via ROCKNIX `0056`. Never posted. | never |
| `0530` | community | Teguh Sobirin via ROCKNIX `0057`, plus our levels/linear scale, plus gennro's no-backlight-DSI-while-off fix (Kettle Linux `1386`, adapted to our levels map; drops `.get_brightness`). Since 7.3 a delta on mainline's own `f747473a838e` (same file, per-board compatibles, no Mangmi/EVO): `.c` only, the Kconfig/Makefile entries are mainline's; the file it produces is byte-identical to the 7.2 stack's. Fix pending upstream: Aaron Kling "Fix picture parameter set". | when mainline's driver carries the levels table, the Mangmi desc and the multi-mode init |
| `0531` | community | gennro, Kettle Linux `1330`, body byte-identical: the Odin 2 Portal's ICNA3512 60/120 Hz setup bytes made exactly what AYN's Android DT sends. | never |
| `0532` | community | gennro, Kettle Linux `1340`, body byte-identical: 50, 145 and 165 Hz modes on the Portal (register 0x48 values measured from TE-driven vblanks). | never |
| `0533` | community | Jacob Cook, ROCKNIX SM8750 `0518`, rebased onto our `0530`-`0532` driver (live-reprogram guard uses `panel.prepared`; their tree has a local `enabled` flag). sysfs `frame_len_120`/`frame_len_60` on the Odin 3 panel, applied live and persisted for later inits; the per-device calibration quirk writes them. | never — calibration knob |
| `0534` | community | armada `0518a`/`0518b` (PR #794), adapted: one mutex serialises backlight, frame-length and init/disable DSI traffic (held across the whole init, where they use an `enabled` flag plus a pending write from `enable()`); a failed B3 restores the page and the old value; per-model frame-length ranges; ICNA3512 (Portal) knobs on our `0531` Android bytes (defaults `0xB9`/`0xFF`), with the `0532` 50/145/165 Hz modes left on Android's constants. | never — calibration knob |
| `0535` | community | Teguh Sobirin via ROCKNIX, plus the 120 ms sleep-out wait (Kettle Linux `21-sm8250/0058`). Mainline 7.2 has a different driver, `panel-chipwealth-ch13726a` (`3ee01b8647b5`), Thor only, same `.name` as ours — so `DRM_PANEL_CHIPWEALTH_CH13726A` must stay off (it is, in our fragment and in defconfig). | when the Retroid variants are added to the mainline driver |
| `0540` | community | KancyJoe via ROCKNIX SM8650 `0062`. Superseded by mainline `1190fc8d7b8a` (`panel-renesas-r63419`, same compatibles). | v7.3 — DT supplies become `vsp`/`vsn`; width is 78 mm there, 79 here |
| `0545` | novadeck | Also ROCKNIX SM8650 `0063`. Never posted. | never |
| `0550` | community | ROCKNIX. Never posted; possibly an R63419 variant (unverified). | never |
| `0555` | community | Teguh Sobirin via ROCKNIX `0104`. Aaron Kling posted a different version (`<20260814-rp6-panel-v1-4-111c1aeccf0f@gmail.com>`, `retroidpocket,rp6-panel`); v2 owed after Neil's review. | when Aaron's series lands — switch compatible |
| `0560` | community | Teguh Sobirin, RetroidPocket/linux `9bfe85be2179` (binding) + `32d07e207d8c` (driver), squashed; command-mode Nova and Duo-bottom panels. Replaced the ROCKNIX `0105` video-mode driver. Needs `0392`. Never posted. | never |
| `0610` | community | Teguh Sobirin via ROCKNIX `0058`. Never posted. | never |
| `0630` | community | ROCKNIX SM8750 `0056`. The AW99706 driver itself is upstream in 7.2.11 and ROCKNIX's `0055` fixes are already in; this one (enable HWEN before the chip-id read) is not. | when upstreamed |
| `0635` | community | ROCKNIX SM8750 `0057`: the KONKR Pocket FIT Elite's cfg7 wiring for AW99706. | never |
| `0650` | community | Teguh Sobirin via ROCKNIX `0033`. Never posted. | never |
| `0660` | community | ROCKNIX SM8250 `0061`. Never posted; clean enough to send with a binding hunk. | when upstreamed |
| `0680` | posted | BigfootACA, in Xilin Wu's Odin 2 v1 02/10 `<20240424-ayn-odin2-initial-v1-2-e0aa05c991fd@gmail.com>`. v2 never sent. ROCKNIX fix `4609c5017f` folded in (`set_bit()` on a `u8[3]`: alignment fault + overflow, #74). | never |
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
| `0760` | community | ROCKNIX SM8750 `0058`: clean-room reimplementation of the stock `tc_mcu_joystick.ko` — the AYANEO-family SPI register-map MCU gamepad (regs 0x8080-0x8088, ASCII "AYANEO" magic) on the KONKR Pocket FIT Elite. Protocol unrelated to the Mangmi SPI joypad (`0755`), reuse investigated and rejected 2026-10-19. | never |
| `0765` | community | ROCKNIX SM8750 `0069`, STRIPPED of its RGB-LED half (multicolor LED, `effect` sysfs, LED PM notifier + `tx_inhibited`): novadeck has no stick-ring LED surface and no kernel sleep. Buttons + key-remap sysfs only. Armada `0069a` (same driver also binds the SM8650 Pocket FIT MCU, whose Menu/Equals/K + LC/RC may be dead on our KPF today) is NOT taken — pending the KPF hardware check; it also carries a `gamepad_mode` attr because it displaces `0980` on that board. | never |
| `0770` | posted | Caleb Connolly v7 `<20221015172915.1436236-3-caleb@connolly.tech>`, stalled since 2022. Fenglin Wu's PMIH driver (v7, 2026-08-28) uses the same file and the generic `qcom,spmi-haptics` compatible. | when David Heidelberg's pmi8998 haptics lands |
| `0775` | community | spycat88, ROCKNIX SM8250 `0013`. | never |
| `0776` | community | gennro, Kettle Linux `1380`, byte-identical body. Never posted. Fixes `0750`'s RX stack overflow and frame loss, and its ops-after-open oops. | with `0750` |
| `0780` | community | CAF/CLO downstream `qcom-hv-haptics`, HAP530/HAP_CFG_V5 generation, via ROCKNIX SM8750 `1000` (issue #122; replaced the HAP525-only generation from ROCKNIX SM8550 `1000`, which rejected the Odin 3's PMIH0108 block at probe). Kconfig hunk regenerated against this tree; the per-play boost-status debug line demoted from dev_err to dev_dbg (it logged twice per rumble event). | never |
| `0781` | community | armada `1001-input-qcom-haptics-update-assign-str`: Linux 7.1's one-argument `__assign_str()` in the driver's tracepoint header. | with `0780` |
| `0785` | community | ROCKNIX SM8750 `1001`, the V5 rebase of the old SM8550 `1002` sine support; body regenerated here against `0780` (same hunks, git-diff format). | with `0780` |
| `0790` | community | Gianni Spadoni's rsinput FF bridge as rebased by armada (`1002-input-rsinput-sm8750-ff`), byte-identical: gated on the `rumble-haptics` DT property (set in `qcs8550-ayn-common.dtsi` + `cq8725s-ayn-common.dtsi`) so a combined kernel does not hand FF to rsinput boards without the Qualcomm haptics block. ROCKNIX's own SM8750 `1002` has a malformed final hunk — do not take it. | with `0780` |
| `0791` | novadeck | Written here for `0745`, after Kettle Linux `1100` (armada `0515`) and `1380`; resyncs a byte on a bad checksum instead of skipping the claimed frame length. Never posted. | with `0745` |
| `0792` | community | armada `0515a` (PR #801), regenerated on `0791`: take a serdev batch only as far as the buffer has room and return that count, instead of dropping an oversized batch (or the buffered partial frame) while reporting it consumed. Never posted. | with `0745` |
| `0795` | community | armada `1003`, rsinput struct + suspend hunks regenerated: fixes the reproduced "scheduling while atomic" hard-lock on rumble stop (issue #128; ROCKNIX still carries the bug). Bridge is mutex-serialized process context; rsinput playback defers to a work item. The original's rsinput dev-PM suspend hunk is dropped — our rsinput has no PM ops and sleep is a userspace cgroup freeze. Supersedes gh123man's deferral (ROCKNIX PR #3116) this slot used to carry. | with `0780` |
| `0796` | community | armada `1004` (virtudude), byte-identical. A zero-amplitude update erases the effect at once instead of braking 5 s later; balances the V5 driver's transient runtime-PM reference on in-place gain updates. | with `0780` |
| `0805` | novadeck | Written here, after the downstream DP codec's startup cable check (msm-4.19 techpack/audio `msm_ext_disp_audio_codec_rx_dai_startup`). Adds the `dp_audio_startup` msm_dp never implemented, so on SM8250 only (`qcom,sm8250-dp`) an unplugged DP open fails before q6afe starts port 0x6020 (a 3 s no-reply timeout there). Never posted. | when upstream msm_dp refuses an unplugged DP audio open itself |
| `0820` | novadeck | Written here at the 7.3 bump (2026-10-30). Sets `mi2s_bclk_enable` in the sm8750 card data, as mainline already does for sm8450/8550/8650, so the per-DAI `bclk` (`dai@12` under `&q6apmbedai`) is driven for the Odin 3 and FIT Elite amps. Replaces the old `0820` (card-level `i2s_clk`, PRIMARY only) + `0825` (widened to every MI2S BE), superseded by mainline `088c4404b3d7` + `cc8495c1d45a`. Never posted. | when mainline's sm8750 card data enables the MI2S bclk |
| `0825` | community | armada `0539` (PR #834, Rafał Rojek), adapted: also caps `konkr,pocket-fit`, which loads the same APS2 UCM and would otherwise get a +40 dB slider top. Caps `RX_RX0/1 Digital Volume` at 84 (0 dB) on `ayaneo,pocket-s2` and `konkr,pocket-fit`, so the UCM can hand the headphone slider to the RX digital volume (`HP Digital`), since `HPHL/HPHR Volume` was a dead control (`0849`) that left the top half of the slider dead. The cap was 59 (-25 dB), tuned on the old PDM route with the compander on, where 72 saturated; on the PCM route (`0860`–`0863`), compander off with the PA pinned at 0 dB, 59 left the slider top too quiet. 84 passed by ear on the FIT; the S2 has not run it. Never posted. | never — board tuning |
| `0830` | novadeck | Teguh Sobirin's AYN series; its firmware-name part went upstream as `fc1fbafc18a0` (v7.1). Remainder never posted. | never |
| `0835` | community | ROCKNIX SM8750 `0059`: aw88395-lib skips monitor sections in V1 ACF parse — the Elite's aw88261 calibration blob carries them. | when upstreamed |
| `0840` | community | Luke Johnson, ROCKNIX `0200`. Never posted; generic, worth sending. | when upstreamed |
| `0845` | community | seilent, Kettle Linux `1230`, body byte-identical. Never posted; generic, worth sending. | when upstreamed |
| `0846` | novadeck | The `0845` fix for `wcd939x`, whose ramp error has the same shape (and a right ramp that inherits the left value). Never posted; generic, worth sending. | when upstreamed |
| `0847` | novadeck | The `wcd939x` ADC volume dB scale was wrong (0.25 dB steps, 5 dB over 20); declared as `wcd938x` does, 0..30 dB. Its HPH half (re-scaling `line_gain`) went to `0849`, which retargets the controls themselves. Never posted; generic, worth sending. | when upstreamed |
| `0849` | community | armada `0081` (Diogo Trindade), body identical, rebased onto `0847`. `HPHL/HPHR Volume` wrote the SPARE bits of `HPH_L_EN`/`HPH_R_EN` (`WCD939X_L_EN_SPARE_BITS`), so they never changed anything; retargeted to `HPH_NEW_INT_PA_GAIN_CTL_L/R` (+6..-30 dB, 1.5 dB steps). Only acts with the compander off (gain source = register), which is how the APS2 UCM runs the headphones; it pins the PA at 0 dB (20) through these controls, register code `0x04` read back on the FIT. The old control was confirmed dead on the Pocket S2 (2026-11-03, 7 <-> 1 inaudible); the old `0847` note that stepping it was audible on the FIT contradicts the register map and is unexplained. Never posted. | when upstreamed |
| `0848` | community | ROCKNIX SM8750 `0063`: wcd939x routes the USBSS analog-audio switch on integrated-jack insert. | when upstreamed |
| `0850` | novadeck | Also ROCKNIX `0612`. Related RFC: Jorijn van der Graaf `<20260705033830.305907-1-jorijnvdgraaf@catcrafts.net>`; Srinivas reproduced the missing clock but no fix yet. 2026-10-19: folded in armada `0613`'s scoping — the prepare-time start now applies to playback MI2S DAIs only, so it cannot change prepare/trigger ordering for unrelated LPASS DAIs (ours started every playback DAI early). | when upstream fixes MI2S clocking before graph start |
| `0855` | community | Kettle Linux `1240` (written for the KONKR Pocket FIT), body byte-identical. Never posted. Preventive: no stale-jack report on record here. | when upstreamed |
| `0856` | community | ROCKNIX SM8750 `0072`: lpass-rx-macro HPH PCM mode. First of the HPH PCM HiFi trio (`0856`-`0858`); benefits every wcd939x board, not just SM8750. | when upstreamed |
| `0857` | community | ROCKNIX SM8750 `0073`: wcd939x HPH PCM HiFi mode. Body refreshed to armada's `0073` (`c1cda0a`): ours skipped the crosstalk writes with the compander off and let the PCM remap hit TX. | with `0856` |
| `0858` | community | ROCKNIX SM8750 `0074`: soundwire qcom PCM data-port format enable. | with `0856` |
| `0859` | community | Anze, ROCKNIX SM8750 `0603` (armada carries the same code), body byte-identical. Never posted. A runtime-suspended wcd939x lets the SoundWire link stop its clock, so MBHC's interrupt never reaches the host: `pm_runtime_forbid()` both slaves while a jack is set. Replaces the SM8650-only udev rule, which never covered SM8750. | when upstreamed |
| `0860` | community | mrdidit, armada PR #817, squashed (`0081b`–`d`). First of the Pocket S2/FIT headphone PCM series (`0860`–`0863`), which clears their crackle. Class-H sink declared FULL so SoundWire programs its window and packing fields, plus optional master channel masks and an SSP period. The S2/FIT values are in `sm8650-ayaneo-common.dtsi`. Never posted. | when upstreamed |
| `0861` | community | mrdidit, armada PR #817, squashed (`0081e`–`i`): revision-specific bias and RCO init, PCM headphone setup and shutdown order, shared supplies sequenced once. Never posted. | with `0860` |
| `0862` | community | mrdidit, armada PR #817, squashed (`0081j`–`q`): jack leakage lifecycle, USBSS impedance measurement on an independent jack, MBHC worker drain, USBSS protection across codec reset. `usbss-measurement` cannot coexist with the Type-C audio graph, so USB-C analog audio stays out, as on stock. The PR's 15 s USBSS recovery worker is not carried: on the FIT it restored on every cycle without clearing what it detected, and leaving it out changed nothing audible. Never posted. | with `0860` |
| `0863` | community | mrdidit, armada PR #817 (`0081r`), adapted to 7.3.1: rebased over the error handling 7.3 added to `wcd939x_sdw_runtime_resume()`, keeping `regcache_mark_dirty()` on failure. Recovers the SoundWire cache and a failed runtime resume. Never posted. | when upstreamed |
| `0865` | posted | Marek Szyprowski v1 `<20261022090923.769464-1-m.szyprowski@samsung.com>`, applied to broonie `sound for-7.4` as `c80f86ed857e`; no Cc: stable. Requests the shared powerdown line asserted so the `GPIO_SHARED` proxy's default is powerdown and any one powered amp holds it de-asserted — the Pocket Max deadlock (both amps on TLMM 127). Upstream's 4th hunk dropped: its `regcache_sync()` error path is not in 7.2. Replaced ROCKNIX `0860` (`GPIOD_FLAGS_BIT_NONEXCLUSIVE`), inert since `ARCH_QCOM` selects `HAVE_SHARED_GPIOS` and gpiolib proxies the line itself; mainline dropped that flag too (`d01fbee5c0d3`). | v7.4 |
| `0870` | community | ROCKNIX. Effectively reverts `89be3c15a58b`. | never |
| `0880` | community | Teguh Sobirin, ROCKNIX `0012`. | never |
| `0890` | community | Daniel Martin (Batocera), ROCKNIX `0300`. Never posted; generic, worth sending. | when upstreamed |
| `0893` | novadeck | Written here for issue #94: `q6core_is_adsp_ready()` reported "ready" on any non-answer; only `ADSP_EUNSUPPORTED` means that now, and it polls every 50 ms as downstream does. Never posted. | with `0895` |
| `0895` | novadeck | Written here for issue #94, after the downstream `q6core_is_avs_up()` gate and `afe_callback()` vote handling. Needs `0893`. Never posted. | when upstream gates q6afe on DSP readiness |
| `0897` | posted | Mohit Sharma, "Fix GPR callback registration race during probe" 1/2 + 2/2 `<20261022144130.2443667-2-mohit.sharma@oss.qualcomm.com>` (+ `-3-`), Cc stable, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2039` + `2128`. Should end the `CMD timeout for [1001021]` 5 s stall in q6apm probe, unproven here. | when merged |
| `0910` | community | ROCKNIX `0011`, with the charger-status fix from ROCKNIX PR #3396 (the SMB5 `BATTERY_CHARGER_STATUS_1` enum and the BAT_OV bit; ours had SMB2's) and the pm8150b float-voltage scale plus the charge current from ROCKNIX PR #3382 (xenocideend). Charger alternative posted: `qcom_smbx` SMB5 v4 `<20260820-submit-qcom-smbx-send-v1-v4-*@snyders.xyz>` (under review). | charger: when SMB5 lands; FG: never |
| `0915` | community | gennro, Kettle Linux `21-sm8250/0116`, body byte-identical: the PM8150B fuel gauge (`0910`) reports `charge_now` (capacity x design) and `charge_full` (design), so time-remaining from charge / current is no longer 0. | with `0910` |
| `0920` | community | ROCKNIX `0063` (sunshineinabox). Never posted. | never |
| `0930` | posted | Jan-Michael Brummer `<20260829054546.86210-2-jan.brummer@tabos.org>`. Konrad asked for `CHARGE_EMPTY` gating; v2 expected. | when merged |
| `0940` | posted | Same series, `-3-`. | when merged |
| `0945` | posted | Xu Qianhui, "power: supply: qcom_battmgr: do not report power_now on SM8750" `<20261027132949.242685-1-xiaqinghuan@mail.ustc.edu.cn>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0086`: SM8750 gets its own variant + battery descriptor without POWER_NOW (the QBG firmware publishes its max-load value there). Probe hunk regenerated around our `0930`. The peer's companion battery RENAME (`0503`) is deliberately NOT taken. | when merged |
| `0950` | mainline | Georgi Djakov `<20260928132823.1426513-1-djakov@kernel.org>`, `51c262cf2aa9` in v7.4-rc1, no stable tag, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2216`. `temp_map` was indexed as a row when it points at the whole map: out-of-bounds read at every PMIC temp-alarm probe. | v7.4 |
| `0970` | community | ROCKNIX `0500`. A hack. | never |
| `0980` | novadeck | Never posted. | never |
| `0990` | community | ROCKNIX SM8750 `0026` + `0027` squashed (Teguh Sobirin): the CQ8725S SoC-ID (SM8750 gaming SKU, AYN Odin 3) in dt-bindings + socinfo. | when the ID lands upstream |
| `1002` | community | ROCKNIX SM8750 `0039`: ath12k WCN7860 hardware definition. The chip is not in upstream ath12k (nor its firmware in linux-firmware — blobs live in qcom-firmwares). | when WCN7860 lands upstream |
| `1003` | community | ROCKNIX SM8750 `0040`: send the QDSS config when the firmware signals CNSS_QDSS_CFG_MISS (`qdss.cfg` ships with the WCN7860 firmware set). | with `1002` |
| `1004` | community | ROCKNIX SM8750 `0041`: do not take the QDSS_CFG_MISS path on chips whose firmware does not want it. | with `1002` |
| `1006` | community | ROCKNIX SM8750 `0045`: Bluetooth qca support for WCN7860 (`qca/gngbt*` blobs in qcom-firmwares). | when WCN7860 BT lands upstream |
| `1007` | posted | Birk Skyum v2 `<20261014180201.57109-1-birk.skyum@pm.me>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2147`. In-band sleep state survived power-off, so a Bluetooth off/on inside 2 s ended in `-110` and a controller crash dump. | when merged |
| `1010` | community | Edouard Durand. Never posted; the bug is still in v7.3-rc4. | when sent and merged |
| `1015` | posted | Runyu Xiao, "[PATCH v4 ath-current] wifi: ath12k: convert scan timeout to wiphy delayed work", via Kettle Linux `1280`, body byte-identical: stop (wiphy mutex held) synchronously cancelled a scan-timeout worker that waits for the same mutex — a deadlock. | when it lands in 7.2.y |
| `1020` | novadeck | Written here, mirroring ath11k's `device_get_mac_address()`: the WCN7850 has no OTP address, so the firmware's is random per boot and Steam-saved networks stop matching. Consumes the `local-mac-address` stage-2 GRUB writes (`boot/patches/grub/0005`). Never posted; generic, worth sending. | when upstreamed |
| `1021` | community | armada `1021`: ath12k single-pdev frequency-range fix, under our `1010`/`1015` scan stack. | when upstreamed |
| `1022` | community | armada `1022`: split WCN7860 scans by firmware-reported ranges. | with `1002` |
| `1023` | community | armada `1023`: protect TX during associated-range scans. | when upstreamed |
| `1024` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0513` @ `1c1c374bdc`, not posted, body identical (offsets only). `ath12k_pci_power_down()` keyed on INIT_DONE, which stays clear while firmware boots, so a device removed mid-boot or mid-recovery kept MHI up; the next probe oopsed in `mhi_queue` through the stale QRTR endpoint. Tracks the power state with its own flag. | when upstreamed |
| `1025` | community | Teguh Sobirin, RetroidPocket/linux `5c301a42fc1d` + `ecda60ed15f6` + `1877d7230554`, squashed, via armada `1154`–`1156` (PR #801), bodies identical. NULL/use-after-free guards on the firmware-crash recovery path (srngs after HAL teardown, thermal hwmon cleanup, link-peer table). Not on linux-wireless patchwork. | when upstreamed |
| `1026` | novadeck | `git revert` of `af50baccaa5f` (7.3): station vdevs back on the listen interval instead of DTIM "stick" mode. That commit was tested on WCN7850 with upstream HMT firmware; the WCN7860 runs vendor GNG firmware and `1002` sets `supports_sta_ps`, so with power save on every connection got the new policy. Suspected cause of the Odin 3 7.3.1 Wi-Fi wedge: beacon loss, re-association with no DHCP, `failed to flush transmit queue`, recovery only by reboot (6 of 20 boots on 7.3.1, 0 of 44 on 7.2.11). A test, not a fix yet. | when the wedge is shown to survive it (drop), or traced to the firmware |
| `1027` | posted | Baochen Qiang `<20261029-ath12k-mcs15-v1-1-3bcfab101f00@oss.qualcomm.com>`, accepted to ath-current, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2247`. WCN7850 firmware cannot TX EHT-MCS15; with a peer advertising it, TX stops for minutes while still associated. | when merged |
| `1028` | posted | Birk Skyum `<20261020213505.31624-1-birk.skyum@pm.me>`, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2271`. A vdev restart counted as a start, so every later station-stats request blocked 3 s under the wiphy lock. | when merged |
| `1029` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0511` @ `1c1c374bdc`, not posted. Recovery finished a RUNNING scan as completed, so userspace connected off partial results while the firmware was down; it is now ABORTING. Context regenerated on `1015`; composes with `1022` (noted under the patch's `---`). | when upstreamed |
| `1030` | community | spycat88, ROCKNIX `0071`. A hack. | never |
| `1040` | community | Kars Mulder's Linux-Pollrate-Patch via ROCKNIX `0506`. | never |
| `1042` | community | Anze, ROCKNIX SM8750 `0509`: restore the pre-`0c8ee850572` ucsi behaviour — clear the USB role when the partner advertises no USB data — on ports without the USB4_IMPLIES_USB quirk (our pmic_glink UCSI ports on every SoC). Peer motivation is a suspend hard-hang we cannot hit; the stale role on charger-only partners is wrong regardless. | when the upstream regression is fixed |
| `1044` | community | armada `0509` (was the ungated ROCKNIX SM8750 `0509` (soc), 2026-10-19): pmic_glink_altmode defers until the typec mux/switch is ready — gated to SM8750, whose wcd_usbss supplier registers late. Ungated it black-screens every board whose DT declares no mode-switch (the AYANEO SM8550 family): the permanent defer blocks the DP aux bridges and the msm DRM aggregate never binds. | when upstreamed |
| `1050` | community | Jacob Cook, ROCKNIX `5e52df2b9fba` (SM8250 `0018`, merged with PR #3382), written from the vendor smb5 `smblib_set_prop_pr_swap_in_progress` sequence. Never posted. | when mainline `qcom_pmic_typec_port` handles PR swap termination |
| `1052` | community | ROCKNIX SM8750 `0043`: power-sequencing qcom-wcn entry for WCN7860. | when WCN7860 lands upstream |
| `1053` | community | ROCKNIX SM8750 `0042`: PCI pwrctrl-pwrseq match for WCN7860. | with `1052` |
| `1056` | community | ROCKNIX SM8750 `0606`: the 7.2 merge window rewrote `clk_regmap_phy_mux_ops` (enable/disable -> rate ops) and no caller was added, so the PCIe pipe-clk mux never leaves XO; qmp-pcie now does `clk_set_rate(ULONG_MAX)` to select the PHY source. Without it the WCN7860 LTSSM parks in Poll.Active ("Device found, but not active"). Generic — our other SoCs' PCIe presumably survives via a different mux path; re-check on the next bump. | when upstream adds the set_rate call |
| `1057` | posted | Michael Burch, Revert "phy: qcom: qmp-pcie: Skip PHY reset if already up" `<20261013-qmp-pcie-skip-reset-revert-v1@michaelburch.net>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2199`: 7.3's skip-reset relies on 2/4-4/4 of the link-retention series, which did not land. | when the link-retention series lands, or the skip is reverted upstream |
| `1060` | posted | Manivannan Sadhasivam `<20260907143349.317495-1-mani@kernel.org>`, applied to the PCI tree as `626acf6efc69`, in pci `next` (not `for-linus`), so v7.4-rc1. Not in v7.3-rc7 or 7.2.y, no Cc: stable — yet 7.2.6+ needs it. | when we pin ≥ v7.4 |
| `1066` | community | armada `0514a`: `parse_iommu_maps()` in of/property walks `iommu-map` with a fixed four-cell stride, wrong for the SM8750 PCIe's `#iommu-cells = <2>` (five-cell entries since 7.2.6's `366a540432a3`) — fw_devlink then links the controller to garbage phandles. Complements our `1060`, which fixed the same stride bug inside pcie-qcom. | when upstream honours `#iommu-cells` there |
| `1067` | posted | Krishna Chaitanya Chundru + Manivannan Sadhasivam, "PCI: qcom: shutdown" v7 1/3-3/3 `<20261029-shutdown-v7-0-3fd7a76a6991@oss.qualcomm.com>`, squashed, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0077`-`0079` (backported to 7.3 there): the link goes to L2 on shutdown/reboot. 3/3's ECAM hunk regenerated for our tree. | when merged |
| `1070` | community | gennro, Kettle Linux `1160`, body byte-identical: the lane clocks were enabled twice per runtime resume (hibern8 setup + resume) and disabled once, so the UFS clocks never gate. | when mainline guards `ufs_qcom_enable_lane_clks()` |
| `1075` | community | jaewun, Kettle Linux `20-sm8550/0207`, body byte-identical: `ufs_qcom_host_reset()` left the IRQ disabled on its error exits. | when upstreamed |
| `1081` | community | jaewun, Kettle Linux `20-sm8550/1007`, body byte-identical: `ufs_qcom_clk_scale_notify()` dropped a hibern8-exit failure and returned 0, bypassing the clock-scaling rollback. | when upstreamed |
| `1082` | community | jaewun, Kettle Linux `20-sm8550/1008`, body byte-identical: HW auto-hibern8 and SW clk-gating hibern8 both park the link; the redundant SW enter on an already-parked link can time out and mark it broken. Keeps the SW path. | when upstreamed |
| `1083` | community | jaewun, Kettle Linux `20-sm8550/1010`, body byte-identical: on `no_phy_retention` hosts (SM8550/SM8650) keep the M-PHY powered while the link is only parked in HIBERN8. | when upstreamed |
| `1084` | community | jaewun, Kettle Linux `20-sm8550/1015`, body byte-identical: RX LineCfg on for link startup, off right after, as downstream does. | when upstreamed |
| `1085` | community | gennro, Kettle Linux `1385`, body byte-identical: fixes `1083`'s PHY power count when the link state differs between clocks-off and clocks-on. | with `1083` |
| `1086` | community | gh123man, Kettle Linux `1401`, body byte-identical: recover a failed clock-gating hibern8 enter inline instead of leaving the link unusable. Kettle's `1400` (clock-gating hold across system PM) is NOT taken: we never enter system suspend. | when upstreamed |
| `1087` | community | gennro, Kettle Linux `40-kettle/1402`, body byte-identical: gives the SM8550 UFS PHY a `vdda-qref` supply at downstream's 30 mA, so LDO L1E (the QREF reference-clock buffer) stays in HPM with the screen off. Wired to `vreg_l1e_0p88` in `qcs8550-ayaneo-pocket-common.dtsi` and `qcs8550-ayn-common.dtsi`. Kettle's trigger is a PHY recalibration on resume from s2idle, which we never reach; ours is the fake suspend, which blanks the DSI PHY (L1E's only declared load) while `1083` keeps the UFS PHY powered in HIBERN8 parking. Untested on hardware by Kettle or us; needs a UFS-booted SM8550 board. | when upstreamed |
| `1088` | community | ROCKNIX SM8750 `0066`: ufs-qcom `sm8750` compatible. | when upstreamed |
| `1089` | novadeck | The UFS PHY takes its reset from the host, so fw_devlink demotes host->PHY to sync-state-only, and the host probes before the PHY. It powers up the clocks and the device supplies, defers in `ufs_qcom_init()`, then powers them down 24 ms later. On the Pocket FIT that overlaps SDC2's async probe (the boot card) and resets the board in a third to a half of the boots. The supply cut is the trigger: VCC drops under a UFS device the bootloader left running. Keeping the supplies on through the teardown gave 0 resets in 24 reboots, keeping the clocks on still gave 1 in 19, against 3 in 8 stock (2026-11-10, `docs/ramoops-crash-debug.md`). This patch checks for the PHY at the top of probe instead, so nothing is powered up. A deferral from anything later in `ufs_qcom_init()` would still cut the supplies. | when upstream orders the probe or fixes the cycle |
| `1090` | community | Diogo Trindade, armada `1030` (PR #718), body identical. Iris gen2 (SM8550/SM8650): send the POC type the firmware reported instead of 0, so a decoder restart after a source change does not raise it again (Steam Remote Play stayed green). Never posted. | when upstreamed |
| `1091` | posted | Sachin Kumar Garg v9 1/3 `<20260801-iris_multi_slice-v9-1-bddf1449c280@oss.qualcomm.com>` (latest; b4 `-c` 2026-11-03), via armada (PR #752). We take 1/3 only; 2/3–3/3 are encoder multi-slice. `iris_set_stage()` now caches the stage it sends, so clock and buffer sizing see the stage in use — `1092`'s stage-1 default depends on it. | when merged |
| `1092` | community | virtudude, armada `1032`–`1037` (PR #752), squashed, bodies identical. Low latency decode for game streaming: CABAC-aware VSP clock, gen2 DISPLAY_DELAY (decode order) controls, decode order → stage 1 + top OPP, power rescale only on bitstream QBUF, and sessions ≤ 4096x2160 default to stage 1 at the top OPP (`qcom_iris.low_latency=0` reverts). Measured by a peer on SM8550 HEVC 1728x1080@120: 3.05 → 1.94 ms/frame decode. Gen1 (SM8250) stage 1 above 720p once looked like it froze a stream; that was Steam's frame-0 restart loop, fixed by `1094`. `mb_cycles_vsp` must exist in every gen2 platform's caps (SM8650/SM8750 share SM8550's). Never posted. | when upstreamed |
| `1093` | community | gennro, Kettle Linux `1370`, body byte-identical. A resolution change's empty PSC_LAST capture buffer was also flagged ERROR, so Steam's arm64 Remote Play client (which starts both queues before the first frame) restarted the decoder every frame. Gen2 only. Never posted. | when upstreamed |
| `1094` | community | shuuri-labs, pocknix `1087`–`1089`, via armada (PR #831), squashed, bodies identical except `1087`'s `iris_buffer.c` context, regenerated for 7.3. Gen1 (SM8250) only: release input internal buffers on a stop before capture setup (~64 MB leaked per Steam restart, OOM reset); defer capture setup until the first source change (firmware SYS_ERROR, green stream); never return a capture buffer stamped 0 (Steam reads it as a failed decode). Never posted. | (3) when Steam stops treating timestamp 0 as a failure; the rest when upstreamed |
| `1095` | community | Diogo Trindade, armada `1031` (PR #718), body identical. Drops `TIER_AV1`'s setter, which overwrote the HEVC tier on every codec; `iris_hfi_gen2_set_tier()` already sends the AV1 tier. Never posted. | when upstreamed |
| `1096` | novadeck | Subscribes the gen2 encoder to `HFI_PROP_PICTURE_TYPE` on its bitstream port, so encoded buffers carry `KEYFRAME`/`PFRAME`. Without it they carry neither. Never posted. | when upstreamed |
| `1097` | novadeck | `VIDIOC_S_PARM` on the encoder's OUTPUT queue also sets `frame_rate`, as `dev-encoder.rst` requires. Without it the firmware's rate control stays at 30 fps. Both HFI generations. Never posted. | when upstreamed |
| `1098` | novadeck | Sends `HFI_PROPERTY_PARAM_VENC_DISABLE_RC_TIMESTAMP` = 1 on gen1, the counterpart of gen2's `TIME_DELTA_BASED_RC` = 0. iris hands the firmware nanosecond timestamps, so timestamp-based rate control overshoots the target. Never posted. | when upstreamed, or iris sends microseconds |
| `1099` | posted | Vishnu Reddy 1/2 `<20261007-fix-disable-irq-safely-v1-1-45746f9a92de@oss.qualcomm.com>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2050`. `disable_irq()` under `core->lock` deadlocks against the threaded handler; this returns to `disable_irq_nosync()` as on 7.2. 2/2 is NOT taken: it reworks `core->lock` across six files and a question from the 2026-11-02 review is unanswered. | with 2/2 when merged |
| `1105` | posted | Krishna Chaitanya Chundru root_port v2 15/15 `<20260917-root_port_v2-v2-15-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `bbc442a64823`. 7.3 renames `pcieport0` → `pcie0_port0`. | v7.4; rework at 7.3 either way |
| `1110` | posted | Same series, 12/15 `<20260917-root_port_v2-v2-12-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `c51818ded215`. | v7.4 |
| `1115` | community | ROCKNIX SM8250 `0005`. Never posted. | never |
| `1117` | community | Kettle Linux `21-sm8250/0110`, body byte-identical: the A650 had no interconnect path and never voted DDR bandwidth (`qnm_gpu` 0/0, Pocket Max); adds `gfx-mem` and the stock per-OPP peak votes. | never |
| `1120` | community | Our A650 overclock ladder, in the shape of Kettle Linux `21-sm8250/0111` (from ROCKNIX `9998-gpu-tuning`): 650/670 `NOM_L1`, 700 `TURBO`, 725/750 `TURBO_L1`, each with the 587 MHz DDR vote of `1117`. Replaced ROCKNIX `9998-gpu-opp-table`, which ran 650-800 MHz all at `NOM_L1`; 800 dropped. Unlike Kettle, the steps stay reachable by the governor. | never |
| `1125` | community | ROCKNIX SM8250 `0004`; nodes for the out-of-tree `0770`/`0910` drivers. | with `0770`/`0910` |
| `1130` | community | spycat88, ROCKNIX `0102`. Upstream wants `rtc_offset` in board DTS, not the PMIC dtsi. | never |
| `1135` | posted | Krishna Chaitanya Chundru "Fix wake-gpios polarity" v2 06/18 `<20260917-root_port-v2-6-0d627d0856d5@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `adf55ad00669`; no Fixes:/Cc: stable, so 7.3.y will not get it. | v7.4 |
| `1137` | posted | Konrad Dybcio "Straighten out CPU votes" 7/7 `<20261020-topic-icc_defines_ao-v1-7-cae8d22649ac@oss.qualcomm.com>`, body byte-identical (b4), reviewed by Abel Vesa, applied to qcom `arm64-for-7.5` as `dd68b2a63e89`. Tags the CPU→DDR path of all eight sm8250 CPUs `QCOM_ICC_TAG_ACTIVE_ONLY`, so the cpufreq bandwidth vote drops when the CPU subsystem power-collapses. 1/7–6/7 are other SoCs, not taken. Fixes: but no Cc stable. | v7.5, or 7.3.y if stable picks it |
| `1140` | posted | Konrad Dybcio RFC v1 `<20250728-topic-gpucc_power_plumbing-v1-0-09c2480fe3e6@oss.qualcomm.com>` (modified). Ulf asked for a rebase in 2025-08; never resent. | never, unless Konrad resends |
| `1145` | community | armada `0070` (virtudude). | with `0360` |
| `1150` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, the six patches for our SoCs: bindings 3/7/8 (`clk-for-7.4`, sm8250 `98e936c9d46a`) and DTS 36/39/40 (`arm64-for-7.4`: sm8250 `389a0144c511`, sm8550 `df50f5c5690a`, sm8650 `108a8d51fba8`). Replaced Neil Armstrong's v1 (sm8450/8550/8650, abandoned after v2) on 2026-10-12, which also ADDS sm8250. The gcc driver halves 24/25 (`.use_rpm`, sm8550/sm8650 only — v5 has none for sm8250) are `0140`, in the clk band. | v7.4 |
| `1155` | posted | Nizat Mikayilli, "arm64: dts: qcom: sm8550: Add missing CPU7 3.36GHz OPP" v1 `<20261104-sm8550-prime-3p36ghz-v1-1-c72630265379@dxdmail.cc>`, body byte-identical (b4), applied to qcom `arm64-for-7.5` as `2fd7a169faf3`; Fixes: but no Cc stable. The cpufreq-hw LUT offers 3.36 GHz on CPU7 with no matching OPP, so the step was dropped (`cpu cpu7: Voltage update failed freq=3360000`, seen on the Pocket ACE). Konrad: a superset OPP table is fine, the LUT decides what is reachable. | v7.5, or 7.3.y if stable picks it |
| `1160` | community | ROCKNIX SM8750 `0033`: sm8750.dtsi gpucc + gxclkctl (kaanapali) clock-controller nodes. | when upstream adds the nodes |
| `1165` | posted | Jie Zhang, "arm64: dts: qcom: sm8750: Add GPU and GMU nodes" (pakala-gpu v1 3/4), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0035`. Replaced 2026-11-03 ROCKNIX `0038` and armada's RSCC widening (old `1166`): the upstream node maps 0x6d000, which already covers RSCC at 0x50000, and the GMU no longer overlaps gxclkctl. GPU node re-placed in address order before gxclkctl. | v7.4 |
| `1167` | posted | Gaurav Kohli, "arm64: dts: qcom: sm8750: Add GPU cooling" (pakala-gpu v1 4/4), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0036`. | v7.4 |
| `1168` | posted | Krishna Chaitanya Chundru, "arm64: dts: qcom: sm8750: Add t-power-on-us property for PCIe root port" `<20260911-t_pwr_on-v1-7-c9eee197d082@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0080`: programs T_POWER_ON for L1.2 exit. | when merged |
| `1169` | posted | Peter Chen, "arm64: dts: qcom: sm8750: Set snps,resume-hs-terminations for USB controller" `<20261019021547.1694088-3-peter.chen@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0081`: GUCTL1 RESUME_OPMODE_HS_HOST, required with the M31 eUSB2 PHY. | when merged |
| `1170` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0512` @ `1c1c374bdc`, not posted, body identical. sm8750.dtsi left uart14's CTS/RTS out of the default state (sm8550/sm8650 include it), so the WCN7860 Bluetooth UART ran 3.2 Mbaud with no flow control. Only the Elite dts overrode pinctrl-0 (dropped with this); the Odin 3 had none. | when upstream sm8750.dtsi carries `qup_uart14_cts_rts` |
| `1171` | posted | Jianping Li, "Make ADSP remote heaps no-map" v1 3/4 + 4/4 `<20261015071511.977-4-jianping.li@oss.qualcomm.com>` (+ `-5-`), reviewed; 4/4 via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2052`, 3/4 from the list. Applied 2026-11-08 to qcom `arm64-fixes-for-7.4` (3/4 `c5e78d1c30a5`, 4/4 `730aae8cf388`); both hunks identical to what we carry (re-checked with b4). **LOAD-BEARING SINCE 7.3.4:** stable took ONLY the driver half, "misc: fastrpc: Allocate entire reserved memory for Audio PD in probe" (`827cf4797be4`, upstream `9e47ad9c562e`), which assigns the whole region to the ADSP at rpmsg probe whenever it is declared (our SM8250 and SM8750 ADSP nodes both set `qcom,vmids`). The two dts halves are not in 7.3.4, so without this patch those pages would stay CMA-reusable while the DSP owns them. Dropping it before v7.4 brings the kernel synchronous external aborts. The same commit removes `ADSP_MMAP_REMOTE_HEAP_ADDR` and its userspace alloc/free path, so the gap the sashiko bot raised on the list (`fastrpc_req_munmap_impl()` freeing a remote-heap buffer without assigning it back to HLOS) no longer exists in our tree. SM8550/SM8650 declare no ADSP remote heap and are untouched. | v7.4 (the dts halves) |
| `1175` | community | ROCKNIX SM8750 `0076`: sm8750 CPU `capacity-dmips-mhz`. | when upstreamed |
| `1178` | community | ROCKNIX SM8750 `0075`: sm8750 CPU thermal cooling maps. | when upstreamed |
| `1180` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0524` @ `1c1c374bdc`, not posted, body identical. sm8750 LLCC PMU and memlat nodes, monitors and tables from the Odin 3 vendor DT and post_boot tunables. Feeds `0170`/`0175`. | with `0175` |
| `1182` | community | Aaron Kling, "arm64: dts: qcom: sm8750: add cpu OPP table with DDR and LLCC bandwidths" v1 `<20260605-sm8750-ddr-bw-scaling-v1-1-f39f918c95a7@gmail.com>`, as reworked in andrebraga ROCKNIX SM8750 `Kernel_7.3` `2289` @ `1c1c374bdc` (LLCC on CPU→LLCC, DDR on LLCC→EBI, per the vendor qcom,dcvs nodes; levels from the Odin 3 memlat tables; cpu6 4204800/4320000 kHz turbo OPPs added). Not droppable on the v1 landing as-is. Feeds `0160`. | when an equivalent lands, or dropped on a failed A/B |
| `1184` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2292` @ `1c1c374bdc`, not posted, body identical. sm8750 GPU OPP bandwidth ranges from the Odin 3 vendor gpu-pwrlevels bus-min/bus-max. Feeds `0286`. | with `0286` |

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
| `0780-input-add-qcom-hv-haptics-hap530-v5-driver.patch` | haptics | `1000-add-qcom-haptics-driver.patch` |
| `0785-haptics-driver-support-periodic-sine-and-fixes.patch` | haptics | `1002-haptics-driver-support-periodic-sine-and-fixes.patch` |
| `0790-input-rsinput-add-scoped-haptics-ff-bridge.patch` | haptics | `1003-rsinput-add-ff.patch` |
| `0795-input-haptics-fix-rumble-bridge-atomic-sleep.patch` | haptics | `1004-input-qcom-haptics-defer-rsinput-playback.patch` |
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
| `1150-arm64-dts-qcom-sm8250-8550-8650-add-gcc-cx-power-domain.patch` | dts | `20260424_neil_armstrong_arm64_dts_qcom_sm8_456_50_add_missing_cx_power_domain_to_gcc.patch` |
| `1155-arm64-dts-qcom-sm8650-misc-enhancements.patch` | dts | `v2_20260420_neil_armstrong_arm64_qcom_sm8650_misc_enhancements.patch` |
