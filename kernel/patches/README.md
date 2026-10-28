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

Totals: 5 `mainline`, 17 `posted`, 23 `novadeck`, 106 `community`. (`0310` and `0430` were
deleted at the 7.2.8 bump: stable backported both, byte-identical; the `0430` slot is reused
by the SM8750 DSI reparent-on-power-off patch, a different change.) Half the stack will
never land upstream, which is why provenance is a table and not a number band.

SM8750 port (2026-10-19, issue #121): 36 patches added from ROCKNIX SM8750 + armada, all
audited against 7.2.11 — NOT taken because already upstream at this pin: ROCKNIX `0050`
(gdsc_gx_disable), `0055` (aw99706 fixes), `0517` (typec-mux EPROBE_DEFER), the sgm3804
regulator, the vpu35/gen80000 firmware (LINUX_FW.pin); NOT taken by policy: the whole
suspend-to-RAM set (ROCKNIX `0504`/`0508`/`0603`, armada's S2R layer, SoCCP), the stick-ring
RGB half of konkr_sysbtn, rsinput `1300` global-default recalibration (per-board module
params on the Odin 3 boards.map row instead). The hv-haptics HAP530/V5 driver generation
was deferred at first (it swaps the rumble stack under every shipping board) and then
taken for issue #122 — see the `0780`–`0796` rows.

| Patch | Origin | Source | Drop when |
|---|---|---|---|
| `0010` | community | Sergio Lopez, Asahi downstream (muvm/FEX); same as ROCKNIX `0504`. Never posted. | never — downstream prctl ABI |
| `0020` | community | Billy Laws, FEX downstream handler. A cut-down RFC (André Almeida, v2 `<20251117160841.334224-2-andrealmeid@igalia.com>`) was opposed by Will Deacon: arm64 will not carry x86 unaligned-atomic emulation. We fixed a missing exception-table entry on `Load128`'s `stlxp` (kernel oops on SM8250, which lacks LSE2 and traps every unaligned atomic), and made backpatch cache maintenance fault-safe (`caches_clean_inval_user_pou()` instead of `flush_icache_range()` on user code; from Kettle Linux `1389`). | never |
| `0110` | posted | Lucid Ole hunk = Esteban Urrutia "SM8450 QoL (dispcc)" v3 3/3 `<20260713-sm8450-qol-dispcc-v3-0-56fd05822270@proton.me>`, re-applied to qcom `clk-for-7.4` as `eb34e2804ce4` (2026-09-23; the earlier `2295d6a84179` never reached mainline), no Cc: stable. The sm8550 mdp-ops hunk is our retarget of v3 1/3 and was never sent — Dmitry asked for exactly this on other dispcc controllers. | guard: when `eb34e2804ce4` reaches our pin (v7.4); mdp ops: when sent and merged |
| `0120` | community | Body replaced 2026-10-19 with armada `0121` (was ROCKNIX `ef264a238d`, sunshineinabox): armada scopes presync_floor/skip_retention_level via private descriptors (`gfx_gmu` for sm8550+sm8750, `gmxc_sm8750`) instead of flagging the shared gfx/gmxc structs, which leaks onto every SoC sharing them in a combined kernel like ours; also adds the sm8750 rails. Never posted. | never |
| `0130` | community | map220v via ROCKNIX `0122`. Never posted. The same change for x1e80100 is being reverted in 7.3 (hard resets) — high-risk to post. | never |
| `0140` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 24/42 + 25/42 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, applied to qcom `clk-for-7.4` (sm8550 `fe2a50974f4a`, sm8650 `e4e6177235c6`). `.use_rpm = true`: runtime PM on GCC, so CX can drop once every GCC consumer has released its clocks and GDSCs. Needs `1150`'s `power-domains` in DT. | v7.4 |
| `0150` | community | Teguh Sobirin, ROCKNIX SM8750 `0044` (`Fixes: 3267c774f3ff`). Suspend-motivated upstream fix (PWRSTS_RET_ON so PCIe GDSCs survive gdsc_disable()); kept for GDSC-policy parity with sm8550/sm8650, whose upstream GCCs already use RET_ON — inert here without kernel sleep. | when 7.2.y/7.3 takes the fix |
| `0210` | community | map220v via ROCKNIX `0004`. Never posted; reuses `a750_ifpc_reglist` (unverified for A740). | when A740 IFPC lands upstream |
| `0220` | posted | Rob Clark v2 `<20260912145922.24115-1-robin.clark@oss.qualcomm.com>` (+ `-2-`), applied to msm-next 2026-09-27 as `bbe4401e118c` (THP) + `8eeca96ad138` (shrinker modparam), code identical to ours. Patchwork still says `new`. | v7.4 |
| `0230` | mainline | Rob Clark v7 context/VM hardening `<20260729155609.20190-*>`, 12 of 17 squashed: 2–4, 9–17/18 (`ae88499d71ce` … `a6d87a272b2c`; list in the header). Not carried: 5–8, 18. | v7.3 |
| `0240` | novadeck | Written here, from GPU runtime-PM traces on the Pocket S2. Works around the trigger (suspend soon after resume); why the A750 GMU never reaches IFPC is not known. Never posted; no prior report found on linux-arm-msm, patchwork or drm/msm issues. | when upstream fixes the A750 GMU idle wait, or sets its own A750 `inactive_period` |
| `0250` | community | gennro, kettlelinux `1350` via armada `0620` (PR #662). Not posted. Masks `a6xx_hfi_irq()`'s clear to CM3_FAULT, as kgsl does; the root cause of the A740 `GPU_SET` OOB timeout wedge. | when mainline stops the HFI handler clearing polled bits |
| `0255` | community | gennro, kettlelinux `1351` via armada `0621` (PR #662). Not posted. Bounds the `fault_coredump_done` wait (2 s) that deadlocks against `recover_worker`. | when mainline bounds that wait |
| `0260` | community | armada `0622` (PR #662). Not posted. Masks `GMU2HOST_INTR_MASK` before the GMU boots, so resume replies do not raise the HFI irq. | with `0250`, or when mainline programs the mask before `a6xx_hfi_start()` |
| `0265` | community | gennro, Kettle Linux `1180`, body byte-identical. On GMU-bandwidth-voting GPUs (A740, A750) the boot bus vote set at resume was never dropped, holding DDR at the boot OPP's bandwidth while the GPU stays powered (measured on the Pocket FIT: GPU `ebi` peak 8.17 GB/s whenever active). | when mainline drops the boot vote |
| `0270` | community | virtudude, via Kettle Linux `1210`, body byte-identical. `msm_gpu_convert_priority()` inverts the within-ring order (userspace 2 → `DRM_SCHED_PRIORITY_KERNEL`, 0 → `NORMAL`), so on one ring a Turnip queue (a game) outranks freedreno GL (Xwayland, the Steam UI) and can starve it. Matters most on the single-ring A650, where the game-priority layer cannot move games to another ring. | when upstreamed |
| `0280` | community | ROCKNIX SM8750 `0049`: the A830 (A8xx gen80000) catalog entry. Upstream A8xx support exists; this catalog row does not (as of the pin). | when the A830 catalog lands upstream |
| `0330` | posted | Dmitry Baryshkov v4 `<20261003-fd-kms-fix-smmu-v4-0-2a44d4d8ac77@oss.qualcomm.com>` (we take 1–3, 5–9 of 10; skip MDP5-only 4 and drm/ci 10), latest. Replaced v3 on 2026-10-12: 3/10 now queues and schedules a retired framebuffer under one lock so vblank-off cannot free it in between; 5/6 add CWB/CDM reservation clears. v4 names a prerequisite, "KMS destroy fixes" `<20261003-msm-kms-destroy-fixes-v1-*>` (init/teardown error paths), which we do not carry. Not in msm-next. | when merged |
| `0340` | community | tiopex, ROCKNIX `ec3d53baac` (generic part split into ROCKNIX `0013-drm-msm-dpu-fix-inline-rotation`). Never posted; the width/height check, `test_bit` and CW/CCW fixes are real mainline bugs. | when the generic fixes are sent and merged |
| `0341` | community | enij90 (armada-tb321fu `ee94cd65` `0818`), taken via ROCKNIX PR #3508 (`0018`); header renumbered to our `0340`. Never posted. Measured by writeback on SM8650; only affects pipes that rotate inline. | with `0340`, or when mainline programs a rotation-aware QSEED4 preload |
| `0342` | community | Content-equivalent of ROCKNIX SM8750 `0068`, re-expressed on `0340`'s core: the four SM8750 VIG pipes get `VIG_SM8550_MASK_SDMA` + a scaler-3.4 rot_v2 sblk reusing the shared `dpu_rot_sm8550_cfg_v201` (ROCKNIX mints byte-identical SM8750-named copies; armada `0066` merged all three SoCs the same way). | with `0340` |
| `0350` | community | tiopex, ROCKNIX `60bb58c1db`. Never posted. | never |
| `0351` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0208`), hand-merged onto `0350` with `0350`'s values as the defaults; the PR's own set is in the header as a cmdline profile. Never posted. | never |
| `0352` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0210`), rebased onto `0351`. Never posted. | never |
| `0360` | community | armada `7e9147a` + `12366dc` (virtudude), a port of the downstream SDE reg-dma engine. Never posted. | never |
| `0365` | community | armada `0069`. Never posted. | with `0360` |
| `0370` | community | sunshineinabox (ROCKNIX). Subject says v2, but no posting was found. | never |
| `0380` | community | sunshineinabox, ROCKNIX PR #3377 (`0012`, `0014`, `0015`, squashed). Vendor-DT catalog values, never posted. | never |
| `0385` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0201` + `0202` as of `566a53ef`, squashed), plus our no-rotator guard for inline-rotation SoCs and the 0330 `msm_framebuffer_cleanup()` / 0230 `msm_gem_new()` signatures. Never posted. Enabled per board by `dts/qcom/sm8250-sde-rotator.dtsi`. | never |
| `0390` | community | armada `0078` (PR #629). Never posted. Command-mode only: the INTF TE path read the video timing engine's line counter, which does not run there; it now reads the tear-check counter, as the pingpong TE path already did. Video-mode panels are untouched. | when mainline fixes the INTF-TE scanout position |
| `0392` | community | Teguh Sobirin, RetroidPocket/linux `b547718c91db`. Never posted. Command-mode only: a single-interface panel wider than 1080 without DSC gets two layer mixers, and the command encoder never programmed or flushed MERGE_3D, so the panel got half of every line (`CMD_MDP_FIFO_UNDERFLOW`, kickoff timeouts). Only the Nova (`0560`) hits it. | when mainline programs MERGE_3D on command-mode encoders |
| `0395` | novadeck | Issue #110: on a dual-interface video-mode panel, per-interface CTL flushes that straddle the programmable fetch start underrun the next frame (black blink). One wait per kickoff, on the master, keeps them on one side. Never posted; generic, worth sending once HW-proven. | when mainline guards the kickoff against the fetch start |
| `0396` | novadeck | A command-mode frame is sent to the panel at kickoff and shown from the first TE after its transfer starts, but the page flip event went out after the transfer stamped with the PREVIOUS TE. gamescope schedules from that stamp, one refresh early, so a limited frame missed every second refresh (Pocket Max: 60 fps @ 120 Hz ran 40). The event is now armed from the CTL start irq for the next vblank, as on video mode. HW: Pocket FIT all caps solid; Pocket Max solid except where the `0385` rotator fence delays the kickoff (cap = refresh). Never posted; generic. | when mainline reports command-mode flips at the vblank they show at |
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
| `0530` | community | Teguh Sobirin via ROCKNIX `0057`, plus our levels/linear scale, plus gennro's no-backlight-DSI-while-off fix (Kettle Linux `1386`, adapted to our levels map; drops `.get_brightness`). Mainline has its own `f747473a838e` (same file, per-board compatibles, no Mangmi/EVO); fix pending: Aaron Kling "Fix picture parameter set". | **v7.3 hard conflict** — rebase as a delta on the mainline driver |
| `0531` | community | gennro, Kettle Linux `1330`, body byte-identical: the Odin 2 Portal's ICNA3512 60/120 Hz setup bytes made exactly what AYN's Android DT sends. | never |
| `0532` | community | gennro, Kettle Linux `1340`, body byte-identical: 50, 145 and 165 Hz modes on the Portal (register 0x48 values measured from TE-driven vblanks). | never |
| `0533` | community | Jacob Cook, ROCKNIX SM8750 `0518`, rebased onto our `0530`-`0532` driver (live-reprogram guard uses `panel.prepared`; their tree has a local `enabled` flag). sysfs `frame_len_120`/`frame_len_60` on the Odin 3 panel, applied live and persisted for later inits; the per-device calibration quirk writes them. | never — calibration knob |
| `0534` | community | armada `0518a`/`0518b` (PR #794), adapted: one mutex serialises backlight, frame-length and init/disable DSI traffic (held across the whole init, where they use an `enabled` flag plus a pending write from `enable()`); a failed B3 restores the page and the old value; per-model frame-length ranges; ICNA3512 (Portal) knobs on our `0531` Android bytes (defaults `0xB9`/`0xFF`), with the `0532` 50/145/165 Hz modes left on Android's constants. | never — calibration knob |
| `0535` | community | Teguh Sobirin via ROCKNIX, plus the 120 ms sleep-out wait (Kettle Linux `21-sm8250/0058`). Mainline 7.2 has a different driver, `panel-chipwealth-ch13726a` (`3ee01b8647b5`), Thor only, same `.name` as ours. | when the Retroid variants are added to the mainline driver |
| `0540` | community | KancyJoe via ROCKNIX SM8650 `0062`. Superseded by mainline `1190fc8d7b8a` (`panel-renesas-r63419`, same compatibles). | v7.3 — DT supplies become `vsp`/`vsn`; width is 78 mm there, 79 here |
| `0545` | novadeck | Also ROCKNIX SM8650 `0063`. Never posted. | never |
| `0550` | community | ROCKNIX. Never posted; possibly an R63419 variant (unverified). | never |
| `0555` | community | Teguh Sobirin via ROCKNIX `0104`. Aaron Kling posted a different version (`<20260814-rp6-panel-v1-4-111c1aeccf0f@gmail.com>`, `retroidpocket,rp6-panel`); v2 owed after Neil's review. | when Aaron's series lands — switch compatible |
| `0560` | community | Teguh Sobirin, RetroidPocket/linux `9bfe85be2179` (binding) + `32d07e207d8c` (driver), squashed; command-mode Nova and Duo-bottom panels. Replaced the ROCKNIX `0105` video-mode driver. Needs `0392`. Never posted. | never |
| `0610` | community | Teguh Sobirin via ROCKNIX `0058`. Never posted. | never |
| `0620` | mainline | Neil Armstrong v5 `<20260529-topic-sm8650-ayaneo-pocket-s2-sy7758-v5-1-03aacd49747c@linaro.org>` → `110d67699a43` (same driver file) | v7.3 |
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
| `0795` | community | armada `1003`, rsinput struct + suspend hunks regenerated: fixes the reproduced "scheduling while atomic" hard-lock on rumble stop (issue #128; ROCKNIX still carries the bug). Bridge is mutex-serialized process context; rsinput playback defers to a work item. The original's rsinput dev-PM suspend hunk is dropped — our rsinput has no PM ops and sleep is a userspace cgroup freeze. Supersedes gh123man's deferral (ROCKNIX PR #3116) this slot used to carry. | with `0780` |
| `0796` | community | armada `1004` (virtudude), byte-identical. A zero-amplitude update erases the effect at once instead of braking 5 s later; balances the V5 driver's transient runtime-PM reference on in-place gain updates. | with `0780` |
| `0800` | mainline | Kumar Anurag v1 `<20260616151252.3599089-2-kumar.singh@oss.qualcomm.com>` → `d858770e86e7` (v7.3-rc1). No `Fixes:`/stable tag, so 7.2.y will not get it. Also in ROCKNIX PR #3396. | v7.3 |
| `0805` | novadeck | Written here, after the downstream DP codec's startup cable check (msm-4.19 techpack/audio `msm_ext_disp_audio_codec_rx_dai_startup`). Adds the `dp_audio_startup` msm_dp never implemented, so on SM8250 only (`qcom,sm8250-dp`) an unplugged DP open fails before q6afe starts port 0x6020 (a 3 s no-reply timeout there). Never posted. | when upstream msm_dp refuses an unplugged DP audio open itself |
| `0810` | community | KancyJoe via ROCKNIX SM8650 `0007`. Superseded by mainline `62dc2554d36d` (WSA2 channel map + `ayaneo,pocket-s2-sndcard`); will not apply on 7.3. | v7.3 — S2 moves to the new compatible; FIT needs its own card entry |
| `0820` | novadeck | Also ROCKNIX SM8550 `0036`. Superseded by mainline `088c4404b3d7` + `cc8495c1d45a` (MI2S clock control). | v7.3 — clocks move to `dai@PRIMARY_MI2S_RX` (`mclk`/`bclk`) |
| `0825` | community | Teguh Sobirin, ROCKNIX SM8750 `0060`, rebased as a delta on our `0820` (which already carries the clk handle + optional get + ops wiring): the MI2S bit-clock enable widens from PRIMARY-only to every MI2S BE, refcounted — the Odin 3 amps sit on SECONDARY, the Elite's aw88261 on QUATERNARY ("check pll lock fail" without BCLK). | v7.3, with `0820` |
| `0830` | novadeck | Teguh Sobirin's AYN series; its firmware-name part went upstream as `fc1fbafc18a0` (v7.1). Remainder never posted. | never |
| `0835` | community | ROCKNIX SM8750 `0059`: aw88395-lib skips monitor sections in V1 ACF parse — the Elite's aw88261 calibration blob carries them. | when upstreamed |
| `0840` | community | Luke Johnson, ROCKNIX `0200`. Never posted; generic, worth sending. | when upstreamed |
| `0845` | community | seilent, Kettle Linux `1230`, body byte-identical. Never posted; generic, worth sending. | when upstreamed |
| `0846` | novadeck | The `0845` fix for `wcd939x`, whose ramp error has the same shape (and a right ramp that inherits the left value). Never posted; generic, worth sending. | when upstreamed |
| `0847` | novadeck | The `wcd939x` HPH and ADC volume dB scales were wrong (`line_gain` 0 dB + 0.07 dB steps, i.e. 1.4 dB over 21 steps); declared as `wcd938x` does: -30..0 dB in 1.5 dB steps, ADC 0..30 dB. Never posted; generic, worth sending. | when upstreamed |
| `0848` | community | ROCKNIX SM8750 `0063`: wcd939x routes the USBSS analog-audio switch on integrated-jack insert. | when upstreamed |
| `0850` | novadeck | Also ROCKNIX `0612`. Related RFC: Jorijn van der Graaf `<20260705033830.305907-1-jorijnvdgraaf@catcrafts.net>`; Srinivas reproduced the missing clock but no fix yet. 2026-10-19: folded in armada `0613`'s scoping — the prepare-time start now applies to playback MI2S DAIs only, so it cannot change prepare/trigger ordering for unrelated LPASS DAIs (ours started every playback DAI early). | when upstream fixes MI2S clocking before graph start |
| `0855` | community | Kettle Linux `1240` (written for the KONKR Pocket FIT), body byte-identical. Never posted. Preventive: no stale-jack report on record here. | when upstreamed |
| `0856` | community | ROCKNIX SM8750 `0072`: lpass-rx-macro HPH PCM mode. First of the HPH PCM HiFi trio (`0856`-`0858`); benefits every wcd939x board, not just SM8750. | when upstreamed |
| `0857` | community | ROCKNIX SM8750 `0073`: wcd939x HPH PCM HiFi mode. | with `0856` |
| `0858` | community | ROCKNIX SM8750 `0074`: soundwire qcom PCM data-port format enable. | with `0856` |
| `0865` | posted | Marek Szyprowski v1 `<20261022090923.769464-1-m.szyprowski@samsung.com>`, applied to broonie `sound for-7.4` as `c80f86ed857e`; no Cc: stable. Requests the shared powerdown line asserted so the `GPIO_SHARED` proxy's default is powerdown and any one powered amp holds it de-asserted — the Pocket Max deadlock (both amps on TLMM 127). Upstream's 4th hunk dropped: its `regcache_sync()` error path is not in 7.2. Replaced ROCKNIX `0860` (`GPIOD_FLAGS_BIT_NONEXCLUSIVE`), inert since `ARCH_QCOM` selects `HAVE_SHARED_GPIOS` and gpiolib proxies the line itself; mainline dropped that flag too (`d01fbee5c0d3`). | v7.4 |
| `0870` | community | ROCKNIX. Effectively reverts `89be3c15a58b`. | never |
| `0880` | community | Teguh Sobirin, ROCKNIX `0012`. | never |
| `0890` | community | Daniel Martin (Batocera), ROCKNIX `0300`. Never posted; generic, worth sending. | when upstreamed |
| `0893` | novadeck | Written here for issue #94: `q6core_is_adsp_ready()` reported "ready" on any non-answer; only `ADSP_EUNSUPPORTED` means that now, and it polls every 50 ms as downstream does. Never posted. | with `0895` |
| `0895` | novadeck | Written here for issue #94, after the downstream `q6core_is_avs_up()` gate and `afe_callback()` vote handling. Needs `0893`. Never posted. | when upstream gates q6afe on DSP readiness |
| `0910` | community | ROCKNIX `0011`, with the charger-status fix from ROCKNIX PR #3396 (the SMB5 `BATTERY_CHARGER_STATUS_1` enum and the BAT_OV bit; ours had SMB2's) and the pm8150b float-voltage scale plus the charge current from ROCKNIX PR #3382 (xenocideend). Charger alternative posted: `qcom_smbx` SMB5 v4 `<20260820-submit-qcom-smbx-send-v1-v4-*@snyders.xyz>` (under review). | charger: when SMB5 lands; FG: never |
| `0915` | community | gennro, Kettle Linux `21-sm8250/0116`, body byte-identical: the PM8150B fuel gauge (`0910`) reports `charge_now` (capacity x design) and `charge_full` (design), so time-remaining from charge / current is no longer 0. | with `0910` |
| `0920` | community | ROCKNIX `0063` (sunshineinabox). Never posted. | never |
| `0930` | posted | Jan-Michael Brummer `<20260829054546.86210-2-jan.brummer@tabos.org>`. Konrad asked for `CHARGE_EMPTY` gating; v2 expected. | when merged |
| `0940` | posted | Same series, `-3-`. | when merged |
| `0970` | community | ROCKNIX `0500`. A hack. | never |
| `0980` | novadeck | Never posted. | never |
| `0990` | community | ROCKNIX SM8750 `0026` + `0027` squashed (Teguh Sobirin): the CQ8725S SoC-ID (SM8750 gaming SKU, AYN Odin 3) in dt-bindings + socinfo. | when the ID lands upstream |
| `1002` | community | ROCKNIX SM8750 `0039`: ath12k WCN7860 hardware definition. The chip is not in upstream ath12k (nor its firmware in linux-firmware — blobs live in qcom-firmwares). | when WCN7860 lands upstream |
| `1003` | community | ROCKNIX SM8750 `0040`: send the QDSS config when the firmware signals CNSS_QDSS_CFG_MISS (`qdss.cfg` ships with the WCN7860 firmware set). | with `1002` |
| `1004` | community | ROCKNIX SM8750 `0041`: do not take the QDSS_CFG_MISS path on chips whose firmware does not want it. | with `1002` |
| `1006` | community | ROCKNIX SM8750 `0045`: Bluetooth qca support for WCN7860 (`qca/gngbt*` blobs in qcom-firmwares). | when WCN7860 BT lands upstream |
| `1010` | community | Edouard Durand. Never posted; the bug is still in v7.3-rc4. | when sent and merged |
| `1015` | posted | Runyu Xiao, "[PATCH v4 ath-current] wifi: ath12k: convert scan timeout to wiphy delayed work", via Kettle Linux `1280`, body byte-identical: stop (wiphy mutex held) synchronously cancelled a scan-timeout worker that waits for the same mutex — a deadlock. | when it lands in 7.2.y |
| `1020` | novadeck | Written here, mirroring ath11k's `device_get_mac_address()`: the WCN7850 has no OTP address, so the firmware's is random per boot and Steam-saved networks stop matching. Consumes the `local-mac-address` stage-2 GRUB writes (`boot/patches/grub/0005`). Never posted; generic, worth sending. | when upstreamed |
| `1021` | community | armada `1021`: ath12k single-pdev frequency-range fix, under our `1010`/`1015` scan stack. | when upstreamed |
| `1022` | community | armada `1022`: split WCN7860 scans by firmware-reported ranges. | with `1002` |
| `1023` | community | armada `1023`: protect TX during associated-range scans. | when upstreamed |
| `1030` | community | spycat88, ROCKNIX `0071`. A hack. | never |
| `1040` | community | Kars Mulder's Linux-Pollrate-Patch via ROCKNIX `0506`. | never |
| `1042` | community | Anze, ROCKNIX SM8750 `0509`: restore the pre-`0c8ee850572` ucsi behaviour — clear the USB role when the partner advertises no USB data — on ports without the USB4_IMPLIES_USB quirk (our pmic_glink UCSI ports on every SoC). Peer motivation is a suspend hard-hang we cannot hit; the stale role on charger-only partners is wrong regardless. | when the upstream regression is fixed |
| `1044` | community | armada `0509` (was the ungated ROCKNIX SM8750 `0509` (soc), 2026-10-19): pmic_glink_altmode defers until the typec mux/switch is ready — gated to SM8750, whose wcd_usbss supplier registers late. Ungated it black-screens every board whose DT declares no mode-switch (the AYANEO SM8550 family): the permanent defer blocks the DP aux bridges and the msm DRM aggregate never binds. | when upstreamed |
| `1050` | community | Jacob Cook, ROCKNIX `5e52df2b9fba` (SM8250 `0018`, merged with PR #3382), written from the vendor smb5 `smblib_set_prop_pr_swap_in_progress` sequence. Never posted. | when mainline `qcom_pmic_typec_port` handles PR swap termination |
| `1052` | community | ROCKNIX SM8750 `0043`: power-sequencing qcom-wcn entry for WCN7860. | when WCN7860 lands upstream |
| `1053` | community | ROCKNIX SM8750 `0042`: PCI pwrctrl-pwrseq match for WCN7860. | with `1052` |
| `1056` | community | ROCKNIX SM8750 `0606`: the 7.2 merge window rewrote `clk_regmap_phy_mux_ops` (enable/disable -> rate ops) and no caller was added, so the PCIe pipe-clk mux never leaves XO; qmp-pcie now does `clk_set_rate(ULONG_MAX)` to select the PHY source. Without it the WCN7860 LTSSM parks in Poll.Active ("Device found, but not active"). Generic — our other SoCs' PCIe presumably survives via a different mux path; re-check on the next bump. | when upstream adds the set_rate call |
| `1060` | posted | Manivannan Sadhasivam `<20260907143349.317495-1-mani@kernel.org>`, applied to the PCI tree as `626acf6efc69`, in pci `next` (not `for-linus`), so v7.4-rc1. Not in v7.3-rc7 or 7.2.y, no Cc: stable — yet 7.2.6+ needs it. | when we pin ≥ v7.4 |
| `1065` | community | gennro, Kettle Linux `1390`, body byte-identical: `1060` read the first iommu-map entry before checking the property holds one. | with `1060` (check the applied `626acf6efc69` has the bound) |
| `1066` | community | armada `0514a`: `parse_iommu_maps()` in of/property walks `iommu-map` with a fixed four-cell stride, wrong for the SM8750 PCIe's `#iommu-cells = <2>` (five-cell entries since 7.2.6's `366a540432a3`) — fw_devlink then links the controller to garbage phandles. Complements our `1060`/`1065`, which fixed the same stride bug inside pcie-qcom. | when upstream honours `#iommu-cells` there |
| `1070` | community | gennro, Kettle Linux `1160`, body byte-identical: the lane clocks were enabled twice per runtime resume (hibern8 setup + resume) and disabled once, so the UFS clocks never gate. | when mainline guards `ufs_qcom_enable_lane_clks()` |
| `1075` | community | jaewun, Kettle Linux `20-sm8550/0207`, body byte-identical: `ufs_qcom_host_reset()` left the IRQ disabled on its error exits. | when upstreamed |
| `1080` | mainline | Udit Tiwari, v9 as merged: `6f5569203bb6`, cherry-picked clean onto v7.2.7 (replaced v6 `<20260210061437.2293654-1-quic_utiwari@quicinc.com>`). | v7.3 |
| `1081` | community | jaewun, Kettle Linux `20-sm8550/1007`, body byte-identical: `ufs_qcom_clk_scale_notify()` dropped a hibern8-exit failure and returned 0, bypassing the clock-scaling rollback. | when upstreamed |
| `1082` | community | jaewun, Kettle Linux `20-sm8550/1008`, body byte-identical: HW auto-hibern8 and SW clk-gating hibern8 both park the link; the redundant SW enter on an already-parked link can time out and mark it broken. Keeps the SW path. | when upstreamed |
| `1083` | community | jaewun, Kettle Linux `20-sm8550/1010`, body byte-identical: on `no_phy_retention` hosts (SM8550/SM8650) keep the M-PHY powered while the link is only parked in HIBERN8. | when upstreamed |
| `1084` | community | jaewun, Kettle Linux `20-sm8550/1015`, body byte-identical: RX LineCfg on for link startup, off right after, as downstream does. | when upstreamed |
| `1085` | community | gennro, Kettle Linux `1385`, body byte-identical: fixes `1083`'s PHY power count when the link state differs between clocks-off and clocks-on. | with `1083` |
| `1086` | community | gh123man, Kettle Linux `1401`, body byte-identical: recover a failed clock-gating hibern8 enter inline instead of leaving the link unusable. Kettle's `1400` (clock-gating hold across system PM) is NOT taken: we never enter system suspend. | when upstreamed |
| `1087` | community | gennro, Kettle Linux `40-kettle/1402`, body byte-identical: gives the SM8550 UFS PHY a `vdda-qref` supply at downstream's 30 mA, so LDO L1E (the QREF reference-clock buffer) stays in HPM with the screen off. Wired to `vreg_l1e_0p88` in `qcs8550-ayaneo-pocket-common.dtsi` and `qcs8550-ayn-common.dtsi`. Kettle's trigger is a PHY recalibration on resume from s2idle, which we never reach; ours is the fake suspend, which blanks the DSI PHY (L1E's only declared load) while `1083` keeps the UFS PHY powered in HIBERN8 parking. Untested on hardware by Kettle or us; needs a UFS-booted SM8550 board. | when upstreamed |
| `1088` | community | ROCKNIX SM8750 `0066`: ufs-qcom `sm8750` compatible. | when upstreamed |
| `1090` | community | Diogo Trindade, armada `1030` (PR #718), body identical. Iris gen2 (SM8550/SM8650): send the POC type the firmware reported instead of 0, so a decoder restart after a source change does not raise it again (Steam Remote Play stayed green). Never posted. | when upstreamed |
| `1095` | community | Diogo Trindade, armada `1031` (PR #718), body identical. Drops `TIER_AV1`'s setter, which overwrote the HEVC tier on every codec; `iris_hfi_gen2_set_tier()` already sends the AV1 tier. Never posted. | when upstreamed |
| `1105` | posted | Krishna Chaitanya Chundru root_port v2 15/15 `<20260917-root_port_v2-v2-15-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `bbc442a64823`. 7.3 renames `pcieport0` → `pcie0_port0`. | v7.4; rework at 7.3 either way |
| `1110` | posted | Same series, 12/15 `<20260917-root_port_v2-v2-12-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `c51818ded215`. | v7.4 |
| `1115` | community | ROCKNIX SM8250 `0005`. Never posted. | never |
| `1117` | community | Kettle Linux `21-sm8250/0110`, body byte-identical: the A650 had no interconnect path and never voted DDR bandwidth (`qnm_gpu` 0/0, Pocket Max); adds `gfx-mem` and the stock per-OPP peak votes. | never |
| `1120` | community | Our A650 overclock ladder, in the shape of Kettle Linux `21-sm8250/0111` (from ROCKNIX `9998-gpu-tuning`): 650/670 `NOM_L1`, 700 `TURBO`, 725/750 `TURBO_L1`, each with the 587 MHz DDR vote of `1117`. Replaced ROCKNIX `9998-gpu-opp-table`, which ran 650-800 MHz all at `NOM_L1`; 800 dropped. Unlike Kettle, the steps stay reachable by the governor. | never |
| `1125` | community | ROCKNIX SM8250 `0004`; nodes for the out-of-tree `0770`/`0910` drivers. | with `0770`/`0910` |
| `1130` | community | spycat88, ROCKNIX `0102`. Upstream wants `rtc_offset` in board DTS, not the PMIC dtsi. | never |
| `1135` | posted | Krishna Chaitanya Chundru "Fix wake-gpios polarity" v2 06/18 `<20260917-root_port-v2-6-0d627d0856d5@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `adf55ad00669`; no Fixes:/Cc: stable, so 7.3.y will not get it. | v7.4 |
| `1140` | posted | Konrad Dybcio RFC v1 `<20250728-topic-gpucc_power_plumbing-v1-0-09c2480fe3e6@oss.qualcomm.com>` (modified). Ulf asked for a rebase in 2025-08; never resent. | never, unless Konrad resends |
| `1145` | community | armada `0070` (virtudude). | with `0360` |
| `1150` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, the six patches for our SoCs: bindings 3/7/8 (`clk-for-7.4`, sm8250 `98e936c9d46a`) and DTS 36/39/40 (`arm64-for-7.4`: sm8250 `389a0144c511`, sm8550 `df50f5c5690a`, sm8650 `108a8d51fba8`). Replaced Neil Armstrong's v1 (sm8450/8550/8650, abandoned after v2) on 2026-10-12, which also ADDS sm8250. The gcc driver halves 24/25 (`.use_rpm`, sm8550/sm8650 only — v5 has none for sm8250) are `0140`, in the clk band. | v7.4 |
| `1155` | mainline | Neil Armstrong v2 `<20260420-topic-sm8650-upstream-cpu-props-v2-*>`; v3 merged as `bb016ddb9061`, `884ff1172a70`, `c0bec4b58b8e` (identical code). | v7.3 |
| `1160` | community | ROCKNIX SM8750 `0033`: sm8750.dtsi gpucc + gxclkctl (kaanapali) clock-controller nodes. | when upstream adds the nodes |
| `1165` | community | ROCKNIX SM8750 `0038`: sm8750.dtsi GPU + GMU nodes (A830), 0x60000 register span. | when upstream adds the GPU node |
| `1166` | community | armada `0038a`, regenerated against `1165` (its base still had 0x40000): widen the GPU mapping to 0x6c000 so the A8xx recovery path reaches RSCC at offset 0x50000, matching upstream A8xx devicetrees. | with `1165` |
| `1170` | posted | ROCKNIX SM8750 `0034`; upstream posting `<20260605-sm8750-uart15-v1-1-93e660722e61@gmail.com>`. UART15 is the Odin 3 rsinput link. | when merged |
| `1175` | community | ROCKNIX SM8750 `0076`: sm8750 CPU `capacity-dmips-mhz`. | when upstreamed |
| `1178` | community | ROCKNIX SM8750 `0075`: sm8750 CPU thermal cooling maps. | when upstreamed |

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
