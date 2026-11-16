# Plan: take what we can from Valve's Steam Frame kernel (`sm8650-7.2`)

**Branch**: `kernel/valve-sm8650-7.2` (off main `faaaed6`)
**Reference clone**: `_reference/deckard-linux` (mainline `v7.2` at depth 1 + `origin/sm8650-7.2` @ `e5fd17767590`,
1282 non-merge commits, `https://github.com/evlaV/deckard-linux-no-oopsies`)
**Our base**: 7.3.4 + the stack in `kernel/patches/`; the patched build tree is `work/kernel/linux-7.3.4`
**Status**: Phase 1 (`1100`–`1103`) HW gate PASSED 2026-11-16 on dev card `20261116T142807Z` (Pocket FIT + Pocket Max). That card came from a throwaway merge with the audio branch (`test/valve-p1+audio` 98e9164, local only). Phase 2 (`1031`–`1033`, `5ba2475`) A/B done on the FIT; the "day of use" check and the 1033 6 GHz A/B are open. Phase 3 (`0271`) HW gate PASSED 2026-11-16 on card `20261116T180915Z` (FIT + Pocket Max). Phase 4 CLOSED 2026-11-16 with no patch (keep `1026`, `e7d3595a7` parked).

Update this file as work lands: tick the checklist, fill the result cells, and add a line to the
decision log for anything decided. If Valve's branch moves, re-fetch and triage only `e5fd17767590..`.

---

## Already decided (before this plan)

| what | outcome |
|---|---|
| `298a38874fa0` + `c4e54b0d6701` iris 600/650 MHz OPPs | TAKEN as `1112`, on **main** (`faaaed6`), not on this branch. With `1092`'s low-latency default every SM8650 decode session ≤4096x2160 runs at 650 MHz TURBO_L1. HW-test owed (power/thermal unmeasured). |
| `63f43443fd29` iris gen2 10-bit capture → QC10C | DECLINED: breaks generic V4L2 clients; revisit only if a 10-bit stream to an S2/FIT shows garbage. |
| Washed-out Remote Play colours | NOT a kernel bug: both Pocket Max and S2, only with the game in HDR → the host's HDR→SDR path. |

---

## How each patch is made

Never hand-author a `.patch`. In a git tree of pristine 7.3.4 with our stack applied (`--fuzz=0`),
cherry-pick from `_reference/deckard-linux`, fix conflicts against our patches, squash where the plan says, and
`git format-patch`. Keep the original `From:` and keep bodies identical where the code is identical; say
"adapted" in the README row otherwise. Each new patch gets a README row and a totals line. Then the whole
stack must apply with `--fuzz=0`, and the kernel and DTBs must build, before any HW test.

---

## Phase 1: iris decode fixes (Remote Play client path)

| slot | content | source | applies to 7.3.4 |
|---|---|---|---|
| `1100` | `e286f5725` fail boot on invalid uc_region; `60415b4a4` core lock around the instance-list scan (UAF at STREAMON) | upstream, Baryshkov series (bod `f301102c17f2`, `428e6f95e685`) | clean |
| `1101` | `20d42f6ba` cancel sys-error work on remove | upstream, Hungyu Lin (bod `452480931648`) | clean |
| `1102` | `1b6de77b4` CAPTURE stride/size on S_FMT(OUTPUT); `e36a8c68e` EOS only at the end of a drain; `bac0a5707` let a resolution change drain before CAPTURE STREAMOFF | Christian Cortner, posted `20261028034335.26075-*`, Cc stable | `bac0a5707`'s `iris_instance.h` placed by hand over `1094` |
| `1103` | `c0290ecaa` reject START/STOP after session failure (NULL deref); `e4bad43d6` publish min capture buffers whenever the count changes; `0203f1508` return buffers QUEUED when start_streaming will fail (vb2 WARN) | Gabe Rowe (Valve), never posted | `e4bad43d6`'s helper hunk placed by hand (Valve dropped `IRIS_FMT_*`); needs `1102` |

Upstream fixes are split by series (`1100` and `1101`), per the squash-only-a-series rule. The plan's
original three slots became four.

`5b2e4b230` (Cortner `-2`) is the same code as our `1093`. Optionally swap `1093` for the posted version
for provenance. It is not a code change.

**Gate**:
- [x] stack applies `--fuzz=0` (238/238 on a fresh tarball; iris files byte-identical to the compiled tree)
- [x] iris module builds with `W=1` in `novadeck-build`: 32 objects, 0 warnings, modpost clean
- [x] full kernel + DTBs build, dev card: `20261116T142807Z`, from local `test/valve-p1+audio` (this branch + `audio/headphone-class-h`), all 241 patches applied
- [x] gen2 (Pocket S2 or FIT): Remote Play stream starts, survives a host resolution change mid-stream, no client restart loop, `dmesg | grep -i iris` clean. Pocket FIT 2026-11-16, user: "resolution change worked"; no iris kernel lines in that boot (`bcbb589d`)
- [x] gen1 (Pocket Max): same, plus confirm `1094`'s gen1 deferral still behaves. 2026-11-16, user: "remote play resolution change worked"; no iris kernel lines in that boot (`6ec7501f`)
- [x] ffmpeg `-c:v h264_v4l2m2m` / `hevc_v4l2m2m` on a clip with a mid-stream resolution change: decodes past the change, ends with EOS

Result (ffmpeg leg, 2026-11-16, Pocket FIT, card `20261116T142807Z`, ffmpeg n8.1.1): the clip goes 720p → 1080p → 720p,
60 unique frames per segment. H.264 and HEVC, 3 runs each, all pass: both changes decoded, a clean exit, and no new
`dmesg` lines. Every frame output matches a software decode bit for bit, in order. Some frames are lost at each change:
the last 15 before 1080p→720p on every run, and 0–8 before 720p→1080p. That is ffmpeg's: `v4l2_handle_event()` →
`ff_v4l2_m2m_codec_reinit()` STREAMOFFs capture on SOURCE_CHANGE without draining up to LAST. ffmpeg also deadlocks
in that reinit unless a `format` filter copies frames out. Neither is an iris finding.
No pre-Phase-1 baseline was taken, so this does not show `1102` changed anything.

Result (Remote Play, 2026-11-16, same card moved between devices): a host resolution change mid-stream worked
on the Pocket FIT (gen2) and the Pocket Max (gen1), by the user's report. Neither boot logged an iris line.
The Steam streaming client leaves no decoder trace on the device: `streaming_log.txt` holds only the
host-side capture stub written at each Steam start. **Phase 1 HW gate: PASSED.**

## Phase 2: ath12k fixes (WCN7850/7860: SM8550, SM8650, SM8750 boards)

| slot | content | source | applies |
|---|---|---|---|
| `1031` | `b847b0743` restore the country code on resume | Stian Knudsen, lore-posted (same approach as ath11k `7f0343b7b871`) | clean |
| `1032` | `4ed1ce3fa` no firmware DIAG stream without a sink; `9f9eb662a` complete `regd_update_completed` on dropped reg events; `a498f595a` u64 cached BSS change flags | Aaron N (Valve) | clean |
| `1033` | `1460e32c9` PSD flag is BIT(0), not BIT(2) | Aaron N (Valve) | clean |

`1033` is separate because it changes 6 GHz transmit power.

Made 2026-11-16 (`5ba2475`): all five cherry-pick clean onto the stack below `1031`. Bodies identical. Valve's commits carry
no Signed-off-by, so the patches have none either.

Findings while making them:
- `1031` is **inert here**. `ath12k_core_resume()` runs only from the PM resume path, and our suspend is a cgroup freeze
  that never enters s2idle (memory: suspend). Carried for correctness, like `0826`. The original gate
  ("after suspend/wake `iw reg get` …") cannot fire, so it is dropped.
- `1032`'s DIAG part is a real change for us: `CONFIG_ATH12K_TRACING` is off, so `ath12k_wmi_diag_event()` hands every
  DIAG event to a no-op tracepoint. With the patch the firmware is no longer asked for the stream.
- `1033`: ath11k reads the same `psd_power_info` word with `BIT(0)`. ath12k's EIRP mask is wider (`0xffff0000`
  against `0xff0000`), so the layouts may really differ. Hold it back unless a 6 GHz A/B is run.

**Gate**:
- [x] builds, applies: 241/241 at `--fuzz=0` on a fresh tarball; `make W=1 drivers/net/wireless/ath/ath12k/` in
  `novadeck-build`, 41 objects, 0 warnings
- [x] the WMI event/IRQ rate at idle is lower (`ce2` −34 %, see below). Sample the ath12k lines of `/proc/interrupts` over 60 s idle, on the
  SAME ath12k device (Odin 2 / FIT / S2 / Odin 3). **Take the BEFORE leg first**, on card `20261116T142807Z`,
  which has no `1032`.
- [x] `9f9eb662a`: zero "Timeout while waiting for regulatory update" per boot: 0 before, 0 after (null, the trigger never fired)

BEFORE leg (2026-11-16, Pocket FIT, card `20261116T142807Z`, idle, screen on, 5 GHz ch 44 80 MHz). The ath12k MSI deltas
summed over CPUs, three 60 s samples starting at 116/176/236 s uptime. `ce2` is the target→host WMI pipe, where DIAG
events arrive:
`ce2` 904 / 942 / 913 (≈15/s), `ce3` 20 / 20 / 20, `ce0`/`ce1`/`ce5`/`mhi` 0, DP rings ≈ 120–185 in total.
Reg-update timeouts this boot: 0.
AFTER leg (card `20261116T173202Z`, built from `95618eb`, this branch only; same FIT, network, channel and procedure,
samples starting at 122/182/242 s): `ce2` **602 / 602 / 602** (exactly 10/s), `ce3` 20 / 20 / 20, DP rings ≈ 240–390
in total. Reg-update timeouts 0, ath12k warnings 0.
Verdict for `1032`'s DIAG part: WMI events at idle drop by a third, from ≈15.3/s to 10.0/s. What is left is perfectly
periodic, so the variable ≈300–340/min removed was the DIAG stream. The DP rings carry LAN traffic, which differs
between the two runs; this A/B doesn't attribute it. The reg-timeout check is null on both cards: the trigger
(a dropped reg reply) never fired, so that shows no harm, not a fix.
- [ ] `1033`: 6 GHz throughput/RSSI A/B, but only if a 6 GHz AP is available. Otherwise hold `1033` back
- [ ] no new `ath12k` warnings over a day of use

Result: _not run_

## Phase 3: msm VM_BIND submit hole

| slot | content | source | applies |
|---|---|---|---|
| `0271` | `2a4a03976` reject a `submit_bo` table on VM_BIND contexts (`Fixes: 2e6a8a1fe2b2`, Cc stable) | Matthew Brost | one-line rebase: Valve's hunk carries an LPAC context line |

Made 2026-11-16 (`75b01ce`). Not found posted (one search). Checked against Mesa 26.3.0 before taking it:
`MSM_PARAM_EN_VM_BIND` is set only by Turnip (`tu_knl_drm_msm.cc:52`). Turnip calls `tu_bo_add_to_bo_list()` only
`if (!has_vm_bind)` (line 607) and `tu_bo_list_del()` only on the non-VM_BIND branches (898–903), so `nr_bos` stays 0.
freedreno GL (`msm_ringbuffer_sp.c`) always sends a table but never enables VM_BIND. The rejection can only hit a
client that breaks the documented uapi.

**Gate**:
- [x] builds: 242/242 at `--fuzz=0`; `make W=1 drivers/gpu/drm/msm/`, 135 objects, 0 warnings
- [x] a Turnip (Vulkan) title and a freedreno GL title run on SM8250 + SM8650, with no submit errors in dmesg
  (`grep "submit_bo table not allowed"` must be empty)

Result: PASSED 2026-11-16 on dev card `20261116T180915Z` (`2b70f6d`, this branch only, no audio set). Title: Parking
Garage Rally Circuit (native x86_64 under FEX), once on Vulkan and once with `--rendering-driver opengl3`.

| SoC | GPU | Vulkan (Turnip, VM_BIND) | GL (freedreno) | `submit_bo table not allowed` | msm errors |
|---|---|---|---|---|---|
| SM8650 (Pocket FIT) | A750 | `libvulkan_freedreno.so`, ~7.5 s GPU time | `libgallium-26.3.0`, ~1 s and climbing | 0 | none |
| SM8250 (Pocket Max) | A650 | `libvulkan_freedreno.so`, ~5 s GPU time | `libgallium-26.3.0`, ~1.8 s and climbing | 0 | none |

VM_BIND checked on both with `vulkaninfo` (`sparseBinding = true`), so the Vulkan submits went through the new check.
GPU time read from the game's drm fdinfo (`drm-engine-gpu`). The only boot WARNs were the Pocket Max's DSI
`PLL(0) lock failed` + `dsi0_phy_pll_out_dsiclk already disabled` at 0.39 s, which predate this branch.

## Phase 4: Wi-Fi power save (CLOSED 2026-11-16: no patch; keep `1026`, park `e7d3595a7`)

Finding: in 7.3.4 `ath12k_mac_op_vif_cfg_changed()` handles only SSID + ASSOC. The `BSS_CHANGED_PS` →
`ath12k_mac_vif_setup_ps()` block sits in the per-link `ath12k_mac_bss_info_changed()`, but mac80211 sends
PS through `ieee80211_vif_cfg_change_notify()`. So NetworkManager's power-save setting never reaches the
firmware. The DTIM STICK policy that `1026` reverts is set in `ath12k_bss_assoc` regardless, but it should
only matter while the station sleeps. That weakens `1026`'s premise.

Upstream history (read 2026-11-16): this exact fix was merged as `4b66d18918f8` ("Fix missing station power save
configuration", Sep 2025) and REVERTED as `a7716c9d922d` (Oct 2025, also in 6.17 stable), "temporarily ... until
the issue is resolved". The report (Ross Brown, ath12k list 2025-10-14, NCM865 = WCN7850, kernel 6.16.11): speedtest
35.88 down / 64.41 up Mbit/s at 90 ms ping, against 551.98 / 605.40 at 8.7 ms for an AX210 on the same AP. No
re-enable on lore through 2026-11-16. Valve carries both halves: `6b7e0769b` (= `af50baccaa5f`, STICK) and `e7d3595a7`.
Our image ships no NetworkManager `wifi.powersave` setting, so with `1034` PS would go live on every boot (NM default 3).

Odin 3 field data (internal install journal, read 2026-11-16, 105 boots; grouped by kernel build time vs `5ebe437`):

| kernel | boots | hours | boots ≥ 1 h | boots with BEACON-LOSS |
|---|---|---|---|---|
| 7.2.11 | 45 | 39.4 | 7 | 0 |
| 7.3.1 without `1026` | 22 | 7.3 | 1 | 6 (all on 11-02, in three clusters: 00:28–01:01, 07:18–07:27, 23:13) |
| 7.3.1/7.3.3/7.3.4 with `1026` | 38 | 9.2 | 1 | 0 |

Same AP and channel on both sides of `1026` (NETGEAR77-5G, 5220 MHz). The same pre-`1026` build then ran 10 more boots
clean (11-02 15:43 to 11-04). Read: consistent with `1026` helping, but weak: one bad day of reboot clusters, and
only 9.2 h of mostly short boots after it. Against the code, STICK should be inert with PS off.

1. [x] Read the beacon-loss counts from the dev cards that carry `1026` (CTRL-EVENT-BEACON-LOSS per `_BOOT_ID`) and decide: keep or drop `1026`. KEEP (see Result).
2. [-] NOT TAKEN (moved to the backlog): `1034` = `e7d3595a7` (Gabe Rowe / Neil Armstrong) with its bare `printk` turned back into `ath12k_dbg`.
3. [-] Moot without `1034`. A/B with PS really on: throughput (the upstream revert's symptom); idle battery drain over a fixed time; ping latency/jitter; a Remote Play session (latency-sensitive); beacon loss over days, now with STICK live if `1026` is dropped.

Result: CLOSED 2026-11-16 with no new patch.
- `1026` stays. It only removes a setting that is inert while the firmware keeps PS off, so it costs nothing; the
  2026-11-02 bad day (the user confirms the three clusters were one episode, rebooted through) and about two weeks
  clean since fit it, but do not prove it. The 7.3 wedge stays OPEN: on a recurrence, note the time and read that boot.
- `e7d3595a7` parked in the backlog: upstream merged the same fix and reverted it for a 10x throughput loss, and our
  image would turn PS on everywhere.

---

## Backlog: MAYBE, only with a reason or a measurement

| sha | what | why not now |
|---|---|---|
| `f0dcb8d3d`+`8fee13ca9` (+`ecc8ac966`, `74286cb87`) | iris: suppress a no-op source change and restart the firmware in place; could remove Steam's frame-0 decoder restart | ~190 lines, Valve-only, unposted; needs Phase 1 first; `f0dcb8d3d` alone does not build (squash with `8fee13ca9`); `ecc8ac966` overlaps `1094` |
| `00b93c80c`+`e01f24c3b`+`8ffc0b632` | devfreq: skip IDLE with IFPC, upthreshold 40 (A740/A750/A830) | needs an A/B; makes `0268` moot on those GPUs. Upstream dropped both (Akhil withdrew skip-IDLE; a tester reported stutter at 90). Partial A/B 2026-11-16 on the Odin 3 (A830), threshold via debugfs: idle = no difference possible (160 MHz, 0.1 % busy); Steam library scroll, 2 passes each: 40 ≈ 705 MHz, 50 ≈ 580, 90 ≈ 420, power the same within noise (4.4–4.9 W), time at FMAX ~17 % at every threshold. No power case for 90; game frame-time leg not run (user stopped it) |
| `960261446`+`901fcbb19`+`a60133f0a` | gpuvm two-pass extobj locking + `RESV_PROTECTED` | ~630 lines, posted not merged; pays off only under eviction |
| `f1b75cd8f`+`30616ecbb` | mm opportunistic-compaction hint, msm shrinker honours it | core vmscan; only if we see GPU working sets evicted (we carry THP for GEM, `0220`) |
| `84acfefd9` | a6xx BCL (battery current limit) | ~10 lines, gated per catalog; brownout safety vs. throttling on battery |
| `082802d79`+`d3a08cd6f`+`965376963` | RT workqueue for nonblocking atomic commits | the idea is good, but the code is a workqueue hack (flag collides with `__WQ_DEPRECATED`); re-implement |
| `e433c7710`+`a4969c246` | seamless refresh switch (vtotal-only change, no modeset) | built on Valve's timing-hack stack; re-implement for icna35xx 60/120 |
| 1c2d10015 series | per-ring preemption-aware hangcheck | tangled with LPAC; only on false or missed hangchecks |
| `d36695feb`, `3a6df24af` | GMU wait sleeps instead of spinning; IFPC perf-counter workaround | low value |
| `e7d3595a7` | ath12k: apply `BSS_CHANGED_PS` from `vif_cfg_changed` (station power save actually reaches the firmware) | = upstream `4b66d18918f8`, reverted upstream (`a7716c9d922d`) for a 10x throughput loss on WCN7850; take only with an A/B on our WCN7860 vendor firmware showing no throughput or latency loss, plus an idle battery gain |
| `5fec1140b`, `0474b709c`, `14c854215` | ath12k thermal-read deadlock; replayed country hint; mac80211 STA bandwidth limit before chanctx (oops on 320 MHz APs) | rare paths |
| `1dbd90a10` series | ath12k per-vdev / 6 GHz TPC rework | large, `1dbd90a10` fails 2/19 hunks |
| `676feb49b`, `53eb0fc17`, `5c6283567`, `d2025651a` | wcd938x/939x port read-back; headphone pop (PA into `mute_stream`) | read-back is cosmetic; 939x versions conflict with `0860`–`0863`; only on pop reports |
| `77c78ba4d`+`013851e94` | va-macro DMIC unmute delay | only on mic pop reports |
| `c8f23023c`, `efee89c32` | LPG LED blink only lit channels; `default-state = "keep"` | only if we use blink / want no probe flash |
| bcm-voter AMC vote cache (final diff of `49f668d05`…`01720d1ea`, minus the MM0 keepalive) | fewer identical RPMh writes | unmeasured |
| `7ab3f57ab`, `a1190a326` | cpufreq-hw: unvote offline CPUs; suspend frequency | low |
| `8cf0e2426`/`54fccc4a9`, `83c45678b` | UFS retries / PHY poll 100 ms; blk-mq NULL tags on CPU offline | only on `phy initialization timed-out` |
| `d0fd1a758`, `14503d7d3` | schedutil uclamp-rise rate limit; sched_ext set_cpus_allowed rq | only with clamped RT threads / scx_lavd on |
| config | `HZ=1000` (ours 250), `SCSI_UFS_HWMON`, `QCOM_SPMI_ADC5_GEN3` | separate decision |

## Do not take (so we don't re-triage)

- Already in 7.3.4 or our stack:
  - UFS `e5fd17767` + `78bb75d94`
  - most iris backports (`936edd488` … `e97dcf5e3`, incl. encoder `c04e4e44b` + `f71158659`)
  - msm `385800bed` `c27ffa3b0` `de0c04706` `57ac3a0a4` `5cd851b80` `f25c9d282` `9dc4ae0ae` `8871e9cb3` `bf0f4651a` `e9a12506c` `5f19c05c2` `7a8dbc01d`
  - THP/shrinker = `0220`; single CTL; FEX prctl = `0010`, atomics ⊂ `0020`; DT MAC = `1020`
  - `5268861091a8` videocc GDSC; ath12k survey index; SM8650 DT capacity/cache/ICC tags
- Superseded or ours does it: `4ce7d47c3` (stage-1 default, `1092`); `199c39626` (`1099` reverts the root cause); `1229d3be1` (reverted by `1099`).
- Wrong for our config: `f5f94df90` / workqueue uclamp: without Valve's lowered RT uclamp default it lowers gpu-worker's floor from 1024 to 512.
- **`3fe2ca05e` comments out the `DRM_MASTER` check: never.**
- Frame-only:
  - display/GPU: CAC, CWB, quad-pipe, LPAC, panels, timing hacks, SMMU bypass, zap/SCM hacks
  - other hardware: camss/ICP/CVP, hexagon-baremetal, max34417, mpq3367, fpga, pm8550b charger, typec rework
  - firmware and boot: iris no-TZ firmware loading, Valve's own audio stack, EL2/QHEE hacks
- `2fb051b4e` SM8650 LLCC (GPU slice 4 MiB prio 2, CPUSS 1 MiB): A/B'd 2026-11-16 on the FIT with llccbench
  (pointer chase + streaming reads, CPU and GPU, alone and against the other side streaming 16 MiB; carried as `0180`
  in `83aa8a5`, reverted). GPU: within 2 % at every size. CPU latency rose in the 8-14 MiB band: prime 10 MiB +25 %,
  mid 8 MiB +49 %; with the GPU streaming, prime 12 MiB +76 % (72 -> 127 ns), mid 10 MiB +113 % (51 -> 110 ns).
  The CPU does use its slice; the GPU already borrows ways past its 3 MiB cap (~400 GB/s up to 8 MiB).
- Debug only: iris debugfs/logging, gpuvis tracing, gemstat/perf nodes.
- Upstream for 7.4 anyway: the AR50LT iris enablement series, `9d3ff5d10` (IB = AB voting change on every SoC).

---

## Decision log

- 2026-11-16: triaged by subsystem (GPU/display, video, everything else) against `work/kernel/linux-7.3.4`. Work goes on this branch and is tracked here, not as issues.
- 2026-11-16: verified by hand that ath12k's PS handling lives only in the link callback (Phase 4 finding).
- 2026-11-16: Phase 1 split into four slots (`1100`–`1103`), one per upstream series plus Valve's own. Two hunks were placed by hand: `bac0a5707`'s `iris_instance.h` (context from `1094`) and `e4bad43d6`'s helper (context from Valve's `IRIS_FMT_*` removal). Kept `1093` rather than swapping it for Cortner's posted `-2`: same code, no gain worth a churn.
- 2026-11-16: Phase 4 closed by the user: keep `1026`, park `e7d3595a7` (upstream reverted the same fix for a 10x throughput loss). Odin 3 field data in the Phase 4 section.
- 2026-11-16: devfreq upthreshold A/B stopped by the user after the scroll scene: no power difference between 40/50/90; nothing taken.
- 2026-11-16: `2fb051b4e` (LLCC split) A/B on the FIT: no GPU gain, CPU latency loss at 8-14 MiB; reverted, moved to Do not take.
