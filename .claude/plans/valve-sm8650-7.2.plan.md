# Plan: take what we can from Valve's Steam Frame kernel (`sm8650-7.2`)

**Branch**: `kernel/valve-sm8650-7.2` (off main `faaaed6`)
**Reference clone**: `_reference/deckard-linux` (mainline `v7.2` at depth 1 + `origin/sm8650-7.2` @ `e5fd17767590`,
1282 non-merge commits, `https://github.com/evlaV/deckard-linux-no-oopsies`)
**Our base**: 7.3.4 + the stack in `kernel/patches/`; the patched build tree is `work/kernel/linux-7.3.4`
**Status**: triaged 2026-11-16, nothing ported yet. Phase 1 next.

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
| `1100` | `60415b4a4` core lock around the instance-list scan (UAF at STREAMON); `e286f5725` fail boot on invalid uc_region; `20d42f6ba` cancel sys-error work on remove | upstream (Baryshkov, Hungyu Lin) | clean |
| `1101` | `1b6de77b4` CAPTURE stride/size on S_FMT(OUTPUT); `e36a8c68e` EOS only at the end of a drain; `bac0a5707` let a resolution change drain before CAPTURE STREAMOFF | Christian Cortner, posted `20261028034335.26075-*`, Cc stable | `bac0a5707`'s `iris_instance.h` hunk must be redone over `1094` |
| `1102` | `c0290ecaa` reject START/STOP after session failure (NULL deref); `0203f1508` return buffers QUEUED when start_streaming will fail (vb2 WARN); `e4bad43d6` publish min capture buffers whenever the count changes | Gabe Rowe (Valve), never posted | clean; `e4bad43d6` needs `1b6de77b4` |

`5b2e4b230` (Cortner `-2`) is the same code as our `1093`. Optionally swap `1093` for the posted version
for provenance. It is not a code change.

**Gate**:
- [ ] stack applies `--fuzz=0`, kernel builds
- [ ] gen2 (Pocket S2 or FIT): Remote Play stream starts, survives a host resolution change mid-stream, no client restart loop, `dmesg | grep -i iris` clean
- [ ] gen1 (Pocket Max): same, plus confirm `1094`'s gen1 deferral still behaves
- [ ] ffmpeg `-c:v h264_v4l2m2m` / `hevc_v4l2m2m` on a clip with a mid-stream resolution change: decodes past the change, ends with EOS

Result: _not run_

## Phase 2: ath12k fixes (WCN7850/7860: SM8550, SM8650, SM8750 boards)

| slot | content | source | applies |
|---|---|---|---|
| `1031` | `b847b0743` restore the country code on resume | Stian Knudsen, lore-posted (same approach as ath11k `7f0343b7b871`) | clean |
| `1032` | `4ed1ce3fa` no firmware DIAG stream without a sink; `9f9eb662a` complete `regd_update_completed` on dropped reg events; `a498f595a` u64 cached BSS change flags | Aaron N (Valve) | clean |
| `1033` | `1460e32c9` PSD flag is BIT(0), not BIT(2) | Aaron N (Valve) | clean |

`1033` is separate because it changes 6 GHz transmit power.

**Gate**:
- [ ] builds, applies
- [ ] after suspend/wake, `iw reg get` shows our country, not `00`, and reconnect time is shorter than before (measure both)
- [ ] the WMI event/IRQ rate at idle is lower (before/after `/proc/interrupts` sample over 60 s)
- [ ] `1033`: 6 GHz throughput/RSSI A/B, but only if a 6 GHz AP is available. Otherwise hold `1033` back
- [ ] no new `ath12k` warnings over a day of use

Result: _not run_

## Phase 3: msm VM_BIND submit hole

| slot | content | source | applies |
|---|---|---|---|
| `0271` | `2a4a03976` reject a `submit_bo` table on VM_BIND contexts (`Fixes: 2e6a8a1fe2b2`, Cc stable) | Matthew Brost | one-line rebase: Valve's hunk carries an LPAC context line |

**Gate**:
- [ ] builds
- [ ] a Turnip (Vulkan) title and a freedreno GL title run on SM8250 + SM8650, with no submit errors in dmesg

Result: _not run_

## Phase 4: Wi-Fi power save (ordered: needs the `1026` verdict first)

Finding: in 7.3.4 `ath12k_mac_op_vif_cfg_changed()` handles only SSID + ASSOC. The `BSS_CHANGED_PS` →
`ath12k_mac_vif_setup_ps()` block sits in the per-link `ath12k_mac_bss_info_changed()`, but mac80211 sends
PS through `ieee80211_vif_cfg_change_notify()`. So NetworkManager's power-save setting never reaches the
firmware. The DTIM STICK policy that `1026` reverts is set in `ath12k_bss_assoc` regardless, but it should
only matter while the station sleeps. That weakens `1026`'s premise.

1. [ ] Read the beacon-loss counts from the dev cards that carry `1026` (CTRL-EVENT-BEACON-LOSS per `_BOOT_ID`) and decide: keep or drop `1026`.
2. [ ] `1034` = `e7d3595a7` (Gabe Rowe / Neil Armstrong) with its bare `printk` turned back into `ath12k_dbg`.
3. [ ] A/B with PS really on: idle battery drain over a fixed time; ping latency/jitter; a Remote Play session (latency-sensitive); beacon loss over days, now with STICK live if `1026` is dropped.

Result: _not run_

---

## Backlog: MAYBE, only with a reason or a measurement

| sha | what | why not now |
|---|---|---|
| `f0dcb8d3d`+`8fee13ca9` (+`ecc8ac966`, `74286cb87`) | iris: suppress a no-op source change and restart the firmware in place; could remove Steam's frame-0 decoder restart | ~190 lines, Valve-only, unposted; needs Phase 1 first; `f0dcb8d3d` alone does not build (squash with `8fee13ca9`); `ecc8ac966` overlaps `1094` |
| `00b93c80c`+`e01f24c3b`+`8ffc0b632` | devfreq: skip IDLE with IFPC, upthreshold 40 (A740/A750/A830) | needs an A/B; makes `0268` moot on those GPUs |
| `960261446`+`901fcbb19`+`a60133f0a` | gpuvm two-pass extobj locking + `RESV_PROTECTED` | ~630 lines, posted not merged; pays off only under eviction |
| `f1b75cd8f`+`30616ecbb` | mm opportunistic-compaction hint, msm shrinker honours it | core vmscan; only if we see GPU working sets evicted (we carry THP for GEM, `0220`) |
| `84acfefd9` | a6xx BCL (battery current limit) | ~10 lines, gated per catalog; brownout safety vs. throttling on battery |
| `082802d79`+`d3a08cd6f`+`965376963` | RT workqueue for nonblocking atomic commits | the idea is good, but the code is a workqueue hack (flag collides with `__WQ_DEPRECATED`); re-implement |
| `e433c7710`+`a4969c246` | seamless refresh switch (vtotal-only change, no modeset) | built on Valve's timing-hack stack; re-implement for icna35xx 60/120 |
| 1c2d10015 series | per-ring preemption-aware hangcheck | tangled with LPAC; only on false or missed hangchecks |
| `d36695feb`, `3a6df24af` | GMU wait sleeps instead of spinning; IFPC perf-counter workaround | low value |
| `5fec1140b`, `0474b709c`, `14c854215` | ath12k thermal-read deadlock; replayed country hint; mac80211 STA bandwidth limit before chanctx (oops on 320 MHz APs) | rare paths |
| `1dbd90a10` series | ath12k per-vdev / 6 GHz TPC rework | large, `1dbd90a10` fails 2/19 hunks |
| `676feb49b`, `53eb0fc17`, `5c6283567`, `d2025651a` | wcd938x/939x port read-back; headphone pop (PA into `mute_stream`) | read-back is cosmetic; 939x versions conflict with `0860`–`0863`; only on pop reports |
| `77c78ba4d`+`013851e94` | va-macro DMIC unmute delay | only on mic pop reports |
| `c8f23023c`, `efee89c32` | LPG LED blink only lit channels; `default-state = "keep"` | only if we use blink / want no probe flash |
| bcm-voter AMC vote cache (final diff of `49f668d05`…`01720d1ea`, minus the MM0 keepalive) | fewer identical RPMh writes | unmeasured |
| `7ab3f57ab`, `a1190a326` | cpufreq-hw: unvote offline CPUs; suspend frequency | low |
| `8cf0e2426`/`54fccc4a9`, `83c45678b` | UFS retries / PHY poll 100 ms; blk-mq NULL tags on CPU offline | only on `phy initialization timed-out` |
| `2fb051b4e` | SM8650 LLCC: GPU slice 4 MB prio 2, CPUSS 1 MB | tuning; needs a benchmark |
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
- Debug only: iris debugfs/logging, gpuvis tracing, gemstat/perf nodes.
- Upstream for 7.4 anyway: the AR50LT iris enablement series, `9d3ff5d10` (IB = AB voting change on every SoC).

---

## Decision log

- 2026-11-16: triaged by subsystem (GPU/display, video, everything else) against `work/kernel/linux-7.3.4`. Work goes on this branch and is tracked here, not as issues.
- 2026-11-16: verified by hand that ath12k's PS handling lives only in the link callback (Phase 4 finding).
