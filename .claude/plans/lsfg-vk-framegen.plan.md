# Plan: lsfg-vk frame generation (issue #81)

**Issue**: #81 — "Frame generation: package lsfg-vk and wire a per-game toggle"
**Branch**: `feat/lsfg-vk-framegen`
**Reference clone**: `_reference/lsfg-vk` @ `9d10aae` (tag `2.0.0-rc1`)
**Complexity**: Medium
**Status**: both layers BUILT FROM SOURCE and **both HW-PROVEN on SM8650** (2026-08-31). Every Vulkan presentation path engages: native x86-64, Proton native-Vulkan, Proton D3D11/DXVK, Proton D3D12/VKD3D. OpenGL cannot and never will. Open question is no longer *whether* it works but *whether it is a good trade on a GPU-bound title* — see "HW round 2026-08-31"

---

## Summary

Package upstream's prebuilt x86 lsfg-vk Vulkan layer into the FEX guest tree, default it OFF, and
expose per-game settings through a new `novadeck-framegen` Decky plugin. Frame generation is an
opt-in that only does something for users who own Lossless Scaling on Steam, so it is never a
default and never surfaced prominently.

The decisive unknown is whether the frame-generation pass fits in the frame budget on Adreno.
Phase 1 answers that with a synthetic benchmark before any packaging work happens.

---

## What #81 gets wrong (it was written against a superseded upstream)

The issue cites two ROCKNIX PRs and a peer distro's Arch packaging. All three package a **v1-era**
tree (a single `liblsfg-vk.so`, `VkLayer_LS_frame_generation.json`). `lsfg-vk-cli/src/healthcheck.cpp`
enumerates the project's own install-shape history — `LD_PRELOAD` → `VK_LAYER` → `V1` → `V2_DEV` →
`V2` — and those references sit two eras back. **Drop them from the issue rather than porting them.**

Upstream also moved off GitHub entirely (2026-08-27):

| | |
|---|---|
| Git | `https://git.lsfg-vk.dev/lsfg-vk.git` (cgit; the `/lsfg-vk/` in the web URL is not part of the clone path) |
| Prebuilts | `https://builds.lsfg-vk.dev/` — per-commit + per-tag, nginx autoindex, no checksum sidecar |
| Docs | `https://lsfg-vk.dev/docs` |
| Codeberg mirror | **removed** — their TOS prohibits hosting code under the new license |

---

## License

**CC-BY-NC-ND-4.0** (42 of 57 source files + `LICENSE.txt`). Changed from MIT (v1) → GPLv3 → CC,
deliberately, to block AI-slop forks.

- **NonCommercial** — **CLEARED**: novadeck will never be a commercial product (operator decision,
  2026-08-30).
- **NoDerivatives** — binding. **We cannot ship a patched build.** Any Adreno or FEX fix must land
  upstream first. There is no `packages/lsfg-vk/patches/` in this design, and there cannot be one.
- The author explicitly permits "use/reupload" of the unmodified work, so shipping upstream's own
  prebuilt is squarely blessed — and avoids the "is a compiled binary an adaptation?" question that
  building from source would raise.
- The author invites integrators to make contact: *"If you want to integrate lsfg-vk, perhaps
  maintain a fork, reach out to me and we can discuss it."* Worth doing early (Phase 2).

---

## Why the prebuilts, not a source build

`https://builds.lsfg-vk.dev/lsfg-vk-2.0.0-rc1.tar.xz`
sha256 `cbe7c96176efcc30585b9e2c010c62b082dbb14a7fcf3a7aa6ac72eb53e3b2d9`

| Check | Result |
|---|---|
| Contents | `lib/liblsfg-vk-layer.so` (x86-64), `lib/liblsfg-vk-layer.x86.so` (i686), both manifests, `bin/lsfg-vk-cli`, `bin/lsfg-vk-ui` |
| arm64 | **none published** — matches the decision to drop arm64 |
| `library_path` | `../../../lib/liblsfg-vk-layer.so` — **relative** |
| `DT_NEEDED` | `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6` — nothing else |
| Symbol ceiling | `GLIBC_2.34` / `GLIBCXX_3.4.29` / `CXXABI_1.3.11` (built on Ubuntu 22.04) |

Building it ourselves in the pinned Arch container would produce a **higher** glibc ceiling than
upstream's own artifact, and would cost a toolchain pin coupled to `fex-rootfs` plus a
`-fconstexpr-ops-limit=4290000000` build. The prebuilt is strictly better here.

**The `.tar.xz` name is a lie — it is an uncompressed tar.** `dist/podman/build.sh` runs `tar cf`
without `J`. Any fetch step must not assume xz.

**arm64 is dropped.** The only arm64 Vulkan clients on this device are the Steam shell and
gamescope, neither of which we want frame-generating. Note `LSFGVK_LAYER_MULTILIB_X86` is the
*32-bit i686* axis, a different question from arm64-vs-x86_64 — we ship both x86 arches.

---

## Why x86-only works: both paths read one tree

`rootfs/assemble-rootfs.sh:654` mounts an overlay at `/usr/share/guestos/fex-mesa` with
`lowerdir=/usr/share/novadeck/guestos-x86-mesa:/run/novadeck/guestos-lower` — our payload over the
pinned FEX guest. Valve's compat tool republishes it as the `/run/gfx` graphics provider; system
FEX reads it as `RootFS:`. **One x86 payload covers Proton titles and system-FEX titles both.**

`packages/mesa-x86` is the established payload precedent (`usr/lib` + `usr/lib32`, staged from
`work/`, gated by the NEEDED-closure check at `assemble-rootfs.sh:604`).

### Two traps for the staging step

1. **Do not relocate the 32-bit `.so` into `lib32`.** The tarball puts both arches in `lib/`, and
   the manifests hardcode `../../../lib/`. Moving the i686 library to match our `lib32` convention
   silently breaks the manifest's relative path. The filenames already differ, so both belong in
   `usr/lib/`. 32-bit `DT_NEEDED` resolution in the guest is already proven by `mesa-x86`'s i686
   Turnip.
2. **`packages/*/prebuilt.pin` is auto-discovered** (`rootfs/customize-base.sh:234`,
   `Makefile:222`) and extracted into the **base**. A bare pin would install the layer as a host
   package, which is wrong — it belongs in the guest payload. The pin format does support
   `kind`/`dest`/`strip`/`mode`/`deps` (`customize-base.sh:246-256`), so a pin with `dest:` under
   `/usr/share/novadeck/guestos-x86-mesa/usr` is viable; otherwise follow the `mesa-x86` shape
   (no pin file, staged from `work/`). **Decide in Phase 3.**

### One trap that turned out to be pre-solved

`mesa-x86`'s absolute-`library_path` workaround (`container-build.sh:83-98`) has no analogue:
upstream already builds with a relative `LSFGVK_LAYER_LIBRARY_PATH`, which the Vulkan loader
resolves against the manifest directory — correct under our overlay *and* under the `/run/gfx`
republish. Keep a grep-assert anyway; it is a build flag upstream could change without knowing it
matters to us.

---

## Default-off wiring

The layer is **implicit** with only `disable_environment: {"DISABLE_LSFGVK": "1"}`. Staged
unqualified it loads into every x86 Vulkan app on the device. `identifyProcess()` returns
`nullopt` with no matching profile so it no-ops, but "loads into everything and no-ops" is the
wrong default for a feature gated behind a third-party purchase.

**Invert it:** set `DISABLE_LSFGVK=1` session-wide (`device-env`), then *remove* it per enabled
game. `game-launch`'s `apply_env` already applies an arbitrary per-game `env` dict verbatim, and
`None` is already a tombstone that unsets rather than sets-empty (`game-launch:325`). So:

```json
"env": { "DISABLE_LSFGVK": null }
```

is a complete opt-in with **zero changes to `game-launch`**.

`VK_ADD_LAYER_PATH` is the wrong tool — it governs explicit layers, not implicit ones.

---

## Configuration model

Config file, not env-only. `LSFGVK_ENV=1` can carry the whole configuration through environment
variables alone, but then there is no config file and therefore **no hot reload** — and
`multiplier`, `flow_scale` and `performance_mode` hot-reload from `conf.toml` via the inotify
`ConfigWatcher`, applying to a running game. Tuning while the game runs is most of a QAM plugin's
value, so: **`conf.toml` for settings, `LSFGVK_PROFILE` to select, env only for the on/off gate.**

Config path: `$XDG_CONFIG_HOME`/`$HOME/.config/lsfg-vk/conf.toml` (`config.cpp:35`). `HOME` passes
through pressure-vessel, so the file is visible inside the container.

**TOML keys are snake_case and do not match the C++ field names:**

| TOML | Scope | Default | Notes |
|---|---|---|---|
| `dll` | `[global]` | auto-detect | path to `lsfg-vk.dll` |
| `allow_fp16` | `[global]` | `true` | 2x-3x on 2:1-FP16 parts — **Adreno is full-rate fp16** |
| `log_level` / `log_file` | `[global]` | `info` / unset | hidden options |
| `name` | `[[profile]]` | — | also the `LSFGVK_PROFILE` selector |
| `active_in` | `[[profile]]` | — | linux binary / windows exe / process name / path suffix |
| `multiplier` | `[[profile]]` | `2` | hot-reloadable |
| `flow_scale` | `[[profile]]` | `1.0` | hot-reloadable; 0.25–1.0 |
| `performance_mode` | `[[profile]]` | `false` | hot-reloadable; lighter model |
| `pacing` | `[[profile]]` | `vsync` | only mode that exists |
| `override_present_mode` | `[[profile]]` | `true` | forces FIFO; do not expose a way to turn this off |

Process identification order (`config.cpp` `identifyProcess`): `LSFGVK_ENV` → `LSFGVK_PROFILE` →
executable suffix → wine exe from `/proc/self/maps` → `/proc/self/comm` → `SteamAppId`. Selecting
by `LSFGVK_PROFILE` is deterministic; prefer it over relying on `active_in` matching under
pressure-vessel.

**The DLL requirement changed in v2**: `lsfg-vk.dll` inside `steamapps/common/Lossless Scaling/`,
not `Lossless.dll` (`config.cpp:465`). `fixDllPath` remaps the old names onto the new one in the
same directory. Still requires owning the product — #81's P3 rationale is unchanged.

### There is a SECOND prerequisite: a Steam beta branch (found on HW, 2026-08-30)

`lsfg-vk.dll` is **not in the default Lossless Scaling depot**. Upstream's install page: *"Make
sure you have switched to the `lsfg-vk` branch!"* — Lossless Scaling publishes the v2 shader DLL
only on a dedicated Steam beta branch of that name.

Confirmed on a Pocket ACE: depot buildid 19655272 (default branch) ships `Lossless.dll` and
`LosslessScaling.dll`, no `lsfg-vk.dll` anywhere.

**Do not fall back to `Lossless.dll`.** It parses, so the CLI gets far enough to look like it is
working, then fails every case with `Unable to find base shader 'mipmaps' in DLL` — which reads
like a broken pipeline rather than a missing prerequisite. v2 wants PE resource `0x80005008`
(`library.cpp:73`), which the default-branch DLL does not carry.

**Product consequence for Phase 5:** this is a second user-visible prerequisite on top of owning
Lossless Scaling, and nothing detects it. The plugin must check for `lsfg-vk.dll` and say "switch
Lossless Scaling to the `lsfg-vk` beta branch" rather than failing opaquely.

### Upstream bug: `LSFGVK_DLL_PATH` is ignored on a first run

`getOrDefault()` calls `parseGlobalEnv()` on the `LSFGVK_ENV` branch and on the
config-file-exists branch, but **not** on the branch that writes a fresh default config and
returns it. With no `~/.config/lsfg-vk/conf.toml` yet, every `LSFGVK_*` variable is dropped and
`findDll()` runs instead. Harmless for us in production (the plugin writes `conf.toml`), but it
means env-only configuration is unreliable on first launch — another point for the `conf.toml`
decision. The CLI's `-d` / `-a` flags bypass it (`benchmark.cpp:45`).

---

## Feasibility: what the docs moved

**In our favour**

- **FP16 is the v2 headline.** "On systems with a 2:1 FP16 ratio, such as most AMD laptops and
  handhelds, performance will be 2x-3x as fast as before, without losing any quality at all."
  Adreno is full-rate fp16.
- **Vulkan requirement dropped 1.3 → 1.2**, deliberately, to cover "every Vulkan-capable GPU ever".
  That puts SM8250 / Adreno 650 in scope too, not just 750.
- **The 32-bit layer "works seamlessly"** per the release notes.

**Against**

- **Vsync/FIFO is the entire mechanism and the only pacing mode.** The layer force-enables FIFO via
  `override_present_mode`, and vsync must *also* be on in the game or frames are skipped. Under
  gamescope — nested compositor, its own limiter, plus our fps-limiter atom patch — this is the
  interaction that has to be proven, and there is no fallback mode to retreat to.
- **Both of our FPS instruments are untrustworthy here.** Upstream states plainly that MangoHud and
  Steam's overlay will often report the wrong framerate: layer load order is nondeterministic, and
  an overlay loaded *before* lsfg-vk cannot see the generated frames. Combined with the known
  `stats.pipe` misread (58 reported vs 44 actual), **the HW gate must measure via the DRM flip
  counter / `drm-engine-gpu` fdinfo**, not an overlay.

---

## The existing Decky plugin

`github.com/xXJSONDeruloXx/decky-lsfg-vk` — BSD-3-Clause, 1,795 stars, upstream-recommended for Big
Picture Mode. **We still write our own**, because:

- Last commit 2026-08-03; v2.0.0-rc1 landed 2026-08-27. It targets the **v1** config layout.
- Its release asset is a 17 MB zip that **bundles its own lsfg-vk binaries** — host x86_64 for a
  real SteamOS, colliding with our sealed root and with a payload that must live in the FEX guest
  tree, not on the host.
- It carries arm64 / launch-wrapping work contributed from a peer distro — useful prior art, and
  the permissive license makes borrowing clean. That provenance goes in the commit message and
  memory, never in shipped source.

Read it before writing Phase 5.

---

## Phases

### Phase 1 — feasibility probe (**do this before anything else**)

`lsfg-vk-cli benchmark -w <W> -h <H> -f <flow> -m <mult> -t <secs>` is a synthetic benchmark of the
frame-generation pipeline alone — no game, no Steam, no gamescope, no packaging. It reports
`Time per iteration`, `Base FPS` and `Output FPS`.

Run the prebuilt x86_64 CLI under system FEX on a dev card, at the real panel resolution, and read
whether the pass fits the frame budget. Needs Lossless Scaling owned and `lsfg-vk.dll` reachable
(`LSFGVK_DLL_PATH`); needs nothing else.

**This is the kill-switch.** If the pass costs more than the budget, #81 closes here for a cost of
one afternoon rather than a plugin.

**RESULT 2026-08-30 — Pocket ACE (SM8550/Adreno 740), panel 1620x1080, idle GPU, lsfg-vk 2.0.0-rc1
prebuilt x86_64 under system FEX:**

| case | 1620x1080 | 1280x720 |
|---|---|---|
| m2 flow 1.00 | 39.64 ms | 21.79 ms |
| m2 flow 1.00 **no-fp16** | **149.17 ms** | 79.44 ms |
| m2 flow 0.85 | 29.67 ms | 16.32 ms |
| m2 flow 0.50 | 11.27 ms | 6.48 ms |
| **m2 flow 1.00 perf-mode** | **3.11 ms** | 1.95 ms |
| m2 flow 0.85 perf-mode | 2.52 ms | 1.65 ms |
| m3 flow 1.00 | 65.91 ms | 36.79 ms |
| m4 flow 0.85 perf-mode | 5.60 ms | 3.66 ms |

**Verdict: PASS on this part, conditionally. ONE SAMPLE — not yet a platform default.**

These are SM8550/Adreno 740 numbers. novadeck ships three GPU generations (SM8250/Adreno 650,
SM8550/Adreno 740, SM8650/Adreno 750) and the fp16 ratio and compute throughput differ across
them, so **no shipping default may be set from this table alone.** The shape of the findings below
is expected to hold, but the magnitudes — and specifically whether the quality model is hopeless
everywhere or only here — need SM8250 and SM8650 before anything is defaulted.
**Pending: SM8250, SM8650.**

1. **Performance mode is the only viable mode on THIS part.** Same flow scale,
   39.64 ms → 3.11 ms: a **12.7x** difference. The quality model cannot hit any frame budget at
   panel resolution (39.64 ms against 16.67 ms for 60fps); the performance model clears it with
   room to spare.
2. **fp16 is worth 3.76x here** (39.64 vs 149.17 ms). Adreno 650 is the one to watch: an older
   part may not carry the same 2:1 ratio, so this multiplier is not assumed to transfer. Upstream's "2x-3x on 2:1-fp16 parts" claim
   lands here and then some. `allow_fp16` must never be exposed as an ordinary user toggle —
   turning it off does not degrade quality, it disables the feature in practice.
3. **Do not reach for flow scale first.** perf-mode at flow **1.00** (3.11 ms) is cheaper than
   quality-mode at flow **0.50** (11.27 ms) *and* keeps full-resolution motion vectors. Exactly
   parallel to `fexProfile: fast` FIRST in [[per-game-tweaks]]: the big lever first, the
   quality-degrading lever last.
4. **Multipliers above 2 are affordable in perf-mode** (m4 flow 0.85 = 5.60 ms) and hopeless
   outside it (m3 flow 1.00 = 65.91 ms).

**What this does NOT establish** — none of it is measured yet, and the numbers above flatter the
feature:

- **Idle GPU.** A game saturating the GPU has no spare 3.11 ms. Under contention the real cost is
  higher than the isolated figure, possibly much higher.
- **GPU cost only.** The layer's CPU-side work runs emulated under FEX, on the present path, and
  is not in these numbers at all.
- **No gamescope.** The Vsync/FIFO coupling — the entire pacing mechanism, and the one with no
  fallback — is untested.
- **No quality judgement.** "Performance mode" is a lighter model; whether 2x perf-mode looks
  acceptable on this panel is a subjective call nobody has made.
- **One GPU generation.** SM8250 (Adreno 650) and SM8650 (Adreno 750) are unmeasured. A per-SoC
  default may turn out to be necessary rather than one global one.

**RESULT 2026-08-30 (2) — AYN Thor Lite, `qcom,sm8250` / Adreno 650, GPU max 800 MHz, panel
1920x1080, idle GPU. Same probe, same artifact.**

| case | 1920x1080 | 1280x720 |
|---|---|---|
| m2 flow 1.00 | 795.21 ms | 391.83 ms |
| m2 flow 1.00 no-fp16 | 1066.61 ms | 541.49 ms |
| m2 flow 0.85 | 607.24 ms | 294.35 ms |
| m2 flow 0.50 | 232.54 ms | 111.12 ms |
| m2 flow 1.00 perf-mode | 25.38 ms | 11.57 ms |
| m2 flow 0.85 perf-mode | 19.50 ms | 8.85 ms |
| **m2 flow 0.50 perf-mode** | **8.78 ms** | 3.82 ms |
| m2 flow 0.25 perf-mode | 4.17 ms | — |
| m3 flow 1.00 | 1325.09 ms | 656.73 ms |
| m4 flow 0.85 perf-mode | 28.74 ms | 13.46 ms |

Re-run on the performance power profile changed nothing (391.83 vs 396.70 ms), and the run is
**GPU-bound, not emulation-bound**: GPU pinned at max 800 MHz for the whole run, system CPU 0.6%
busy against a 0.7% idle baseline. These numbers are real.

### The two parts disagree, and that settles the default question

At 1280x720, the directly comparable point:

| | SM8550 / A740 | SM8250 / A650 | ratio |
|---|---|---|---|
| m2 flow 1.00 quality | 21.79 ms | 391.83 ms | **18.0x** |
| m2 flow 1.00 perf-mode | 1.95 ms | 11.57 ms | 5.9x |
| **fp16 gain** | **3.76x** | **1.38x** | — |

**The fp16 gap is the mechanism.** Adreno 650 gets 1.38x from half precision where Adreno 740 gets
3.76x, so the quality model — which leans hardest on fp16 — collapses on the older part. The 18x
quality-mode gap against a 5.9x perf-mode gap is that difference, not a clock difference (800 vs
1000 MHz is only 1.25x).

**The SM8550 finding "do not reach for flow scale first" DOES NOT TRANSFER.** On SM8250 flow scale
is exactly the lever you must reach for. Cheapest config clearing the 60fps budget at each part's
own panel, idle GPU:

| part | config | cost | headroom vs 16.67 ms |
|---|---|---|---|
| SM8550 @ 1620x1080 | perf-mode, flow **1.00** | 3.11 ms | 5.4x |
| SM8250 @ 1920x1080 | perf-mode, flow **0.50** | 8.78 ms | 1.9x |

So **a per-SoC default is required, not optional**, and the operator was right to refuse a default
set from one sample. SM8250 is viable but tight and quality-degraded; SM8550 has room to spare.
On SM8250, perf-mode at full flow scale (25.38 ms) does not fit the 60fps budget *on an idle GPU*,
before the game renders anything.

**RESULT 2026-08-30 (3) — KONKR Pocket FIT, `qcom,sm8650` / Adreno 750, GPU max 1050 MHz, panel
1920x1080 (same panel as the Thor Lite, so this is like-for-like against SM8250).**

| case | 1920x1080 | 1280x720 |
|---|---|---|
| m2 flow 1.00 | 23.97 ms | 12.03 ms |
| m2 flow 1.00 no-fp16 | 161.83 ms | 80.71 ms |
| m2 flow 0.85 | 18.50 ms | 9.41 ms |
| m2 flow 0.50 | 7.62 ms | 4.31 ms |
| **m2 flow 1.00 perf-mode** | **2.99 ms** | 1.65 ms |
| m2 flow 0.85 perf-mode | 2.42 ms | 1.38 ms |
| m3 flow 1.00 | 38.52 ms | 19.49 ms |
| m4 flow 0.85 perf-mode | 5.42 ms | 3.18 ms |

---

## Phase 1 complete — all three parts

At 1280x720, the point common to all three:

| | A650 / SM8250 | A740 / SM8550 | A750 / SM8650 |
|---|---|---|---|
| m2 flow 1.00 quality | 391.83 ms | 21.79 ms | 12.03 ms |
| m2 flow 1.00 **no-fp16** | 541.49 ms | **79.44 ms** | **80.71 ms** |
| m2 flow 1.00 perf-mode | 11.57 ms | 1.95 ms | 1.65 ms |
| **fp16 gain** | **1.38x** | **3.76x** | **6.71x** |

**The fp16 gain scales monotonically with generation — it is not a cliff.** 1.38x → 3.76x → 6.71x.
And the mechanism is now unambiguous: **without fp16, A740 and A750 are the same part for this
workload** (79.44 vs 80.71 ms, within noise). The 750's entire advantage over the 740 is fp16
throughput. A650 is ~6.8x slower than both even at fp32, which is why nothing rescues it in
quality mode.

### Shipping defaults (perf-mode always; flow scale per-SoC)

Cheapest config clearing the 60fps budget (16.67 ms) at each part's own panel, idle GPU:

| part | panel | flow | cost | headroom |
|---|---|---|---|---|
| SM8250 / A650 | 1920x1080 | **0.50** | 8.78 ms | 1.9x |
| SM8550 / A740 | 1620x1080 | **1.00** | 3.11 ms | 5.4x |
| SM8650 / A750 | 1920x1080 | **1.00** | 2.99 ms | 5.6x |

Two of three parts run flow 1.00 comfortably; **SM8250 is the sole exception** and the only reason
the default has to be per-SoC at all. Quality mode is off everywhere: it misses the budget at panel
resolution on all three (23.97 ms even on the 750).

**Phase 1 verdict: PASS on SM8550 and SM8650 with wide margin; PASS but TIGHT and
quality-degraded on SM8250.** The remaining risk is no longer the GPU — it is contention with a
real game, the FEX-side CPU cost on the present path, and the Vsync/FIFO coupling under gamescope.

### Phase 2 — re-baseline #81; contact upstream — **DONE (outreach drafted, not sent)**

Issue #81 body rewritten 2026-08-30: the three stale v1-era references removed, new upstream
locations recorded, both user-visible prerequisites documented, licence position stated, x86-only
shape explained, and the per-SoC defaults given. Full measurement tables posted as a comment
(`#issuecomment-5470709344`). Kept at P3 — two prerequisites, one of them a paid third-party
product.

Upstream outreach drafted at `.claude/plans/lsfg-vk-upstream-outreach.md`. **Not sent** — speaking
to a third party on the project's behalf is the operator's call. Channels are Discord or the
archived repo's GitHub Discussions.

### Phase 3 — `packages/lsfg-vk` + payload staging — **DONE**

`packages/lsfg-vk/{payload.pin,fetch.sh}`, staged by `assemble-rootfs.sh` into the same guest
overlay payload as the Turnip. `make lsfg-vk`; `$(LSFG_VK_STAMP)` is a `$(ROOTFS)` prerequisite.
Nine new assertions in `tests/test-graphics-provider.sh`; full offline suite green.

**Resolved: NOT a `prebuilt.pin`.** Two independent reasons. `dest:` places into the BASE, and the
guest payload directory already has exactly one owner (`assemble-rootfs.sh`, staging from `work/`);
and a pin cannot express selective extraction — `strip` only removes leading path components —
while we drop `bin/lsfg-vk-ui` (319 KB of Qt6 that the guest cannot run) plus its `.desktop` and
icon. So it follows the `mesa-x86` shape. The pin file is named `payload.pin`: `source.pin` and
`prebuilt.pin` are both load-bearing globs, and `artifact.pin` names a *retired* mechanism whose
history is written up in `rootfs/fetchlock.sh`.

**The NEEDED gate now picks its comparison libdir by ELF class, not by directory.** It had to:
upstream's manifests resolve `../../../lib/` relative to themselves, so the i686 layer must sit in
`usr/lib` beside the 64-bit one, and ND says we do not rewrite their manifest to move it. Judging a
32-bit ELF against the guest's 64-bit `/usr/lib` would still have passed — the sonames it needs
exist in both libdirs — so the gate would have been right by luck, and stayed right by luck until
some payload needed a soname present in only one arch.

### Phase 4 — default-off wiring — **DONE**

`DISABLE_LSFGVK=1` exported from `novadeck-session`, next to `ENABLE_GAMESCOPE_WSI`. Both gamescope
and `$NOVADECK_SESSION_CMD` are its children, so the export reaches Steam and every game it
launches. Three assertions in `tests/test-graphics-provider.sh`; no `game-launch` change, as
planned.

**Not `device-env`, despite the plan saying so.** That helper emits per-board `NOVADECK_*` facts
and its consumers `eval` it expecting exactly that namespace; a session-wide third-party toggle is
not a per-board fact and does not belong there.

**Written `: "${DISABLE_LSFGVK=1}"` — `=`, not `:=`.** The colon form re-defaults an *empty*
value, which would silently swallow `DISABLE_LSFGVK=` in `session.conf` and remove the bring-up
lever. Verified in `sh`: unset → `1`, empty → stays empty, explicit → respected. The device stays
operator-reachable.

**Why this was a correctness fix and not tidying:** the layer's constructor calls
`utils::getOrDefault()` (`lsfg-vk-layer/src/hooks.cpp:27`), which **writes a default
`~/.config/lsfg-vk/conf.toml`** seeded with upstream's sample profiles when none exists. Without
the export, the first game launched on an image drops a config file into the user's home for a
feature they never enabled.

### Phase 5 — `novadeck-framegen` Decky plugin — **DONE (untested on HW)**

`apps/decky/novadeck-framegen/`. Backend: `prereq.py` (the four ways this can be unavailable),
`conf.py` (lsfg-vk's `conf.toml`), `tweaks.py` (the env tombstone in `game-tweaks.json`),
`device.py` (per-SoC flow-scale default), `steam.py` (library listing, duplicated from
novadeck-control by the established convention). Frontend is one panel, no tabs.

All three lists updated (`Makefile:296`, `assemble-rootfs.sh:1050`, `guard-rootfs.sh:673`) plus
`tests/test-decky.sh`. `tsc --noEmit` clean, rollup build clean, full offline suite green.

**A real bug the round-trip test caught before it shipped.** `[global]` is a TOML *table*, so
`tomllib` returns it nested under that key — the first renderer treated top-level scalars as the
globals and **dropped every one of them**, including `dll` (how a user points at a Lossless
Scaling install we cannot find) and `allow_fp16`. The round trip is now a permanent assertion:
valid TOML, foreign globals and foreign profiles preserved, clamping applied, `flow_scale` stays
a float, removal surgical.

**Design decisions worth carrying:**
- **Profiles selected by `LSFGVK_PROFILE`, not matched.** Upstream can identify a process by
  executable, wine exe, `comm` or `SteamAppId`; all can hit the wrong binary (UE titles ship
  several) or miss under pressure-vessel. One profile per game named `novadeck-<appid>`,
  `active_in` left empty.
- **The plugin also applies the launch wrapper.** `game-launch` only runs for a game whose launch
  options were wrapped, so without this the env would never be applied and the toggle would read
  "on" while doing nothing. `launchWrapper.ts` is duplicated from novadeck-control.
- **Performance mode is stated, not offered.** It is the only mode that fits a frame budget on
  any of the three parts, so exposing it as a choice would be offering a setting whose other
  value never works.
- **Profiles survive a disable.** Turning frame generation off leaves the tuning on disk, so an
  off/on cycle is a toggle rather than a reset.

### Phase 6 — HW gate — **PASSED on SM8650**

KONKR Pocket FIT, dev card, PGRC (appid 2737300, native x86-64, Vulkan), 60 fps internal cap,
144 Hz panel, gamescope limiter empty. **11 passed, 0 failed.** Observed: ~120 fps output from a
60 fps render.

**The open question from planning is ANSWERED: the implicit layer manifest IS visible through
Valve's `/run/gfx` republish.** The layer loaded from
`/run/gfx/main/usr/lib/liblsfg-vk-layer.so` inside pressure-vessel — which is what the relative
`library_path` bought, and the assumption the whole packaging design rested on.

The layer's own log is the evidence:

```
Using profile with name 'novadeck-2737300' (identified via environment)
  Multiplier: 2   Flow scale: 1.00   Performance mode: true
Hooked new Vulkan instance creation
Hooked new Vulkan device creation
Initializing lsfg-vk instance with half precision enabled
```

Profile selected **via environment**, so `LSFGVK_PROFILE` beat every ambiguous matcher; settings
match what the plugin wrote; fp16 active — the path worth 6.71x on this part.

Also confirmed on HW: the `DISABLE_LSFGVK` tombstone survives Steam → compat tool →
pressure-vessel → FEX, and the session default reaches gamescope.

**Two false verdicts from the probe itself, both worth remembering.** It first reported
9 passed / 0 failed while the layer was mapped but *inert* — "mapped" is necessary, not
sufficient. Then, once fixed, it reported a FAIL on ERROR lines left in the session log by the
*previous* launch. A log that spans a session needs a boundary before it is evidence; it now cuts
at the last `Using profile` line.

**Still unmeasured:** frame-time consistency over a long session, image quality under motion, and
behaviour on SM8250 (1.9x headroom, flow 0.50 default) and SM8550.

## HW finding 2026-08-30: the Proton path needs an aarch64 layer we do not have

Phase 6 passed on a native x86-64 Linux title. Testing the SAME game's **Windows build under
Proton** shows the feature does not reach it, and the reason is architectural rather than a
packaging slip.

**There are THREE x86 paths, not two, and they do not share a Vulkan stack:**

| path | Vulkan stack | our x86 layer |
|---|---|---|
| system FEX (non-Steam / manual) | guest x86 Turnip, from the merged guest tree | works |
| Valve FEX compat tool, **native x86-64 Linux** title | guest x86, republished at `/run/gfx` (`libvulkan.so.1.4.357`) | **works — proven** |
| **Proton (Windows) title** | **HOST aarch64**, from `/run/host/usr/lib` (`libvulkan.so.1.4.328`, `freedreno_icd.aarch64.json`) | **cannot work** |

Evidence from the Proton run (`garagerally.exe`, appid 2737300):

- `VK_IMPLICIT_LAYER_PATH=/usr/lib/pressure-vessel/overrides/share/vulkan/implicit_layer.d` —
  pressure-vessel **pins** the search path to its own overrides directory.
- It populates that directory by importing from the **HOST's**
  `/usr/share/vulkan/implicit_layer.d/` (MangoHud, gamescope WSI and MESA_device_select all
  arrived there). Our layer is not on the host — it is in the guest payload.
- `/run/gfx`, `/usr/share/guestos/fex-mesa` are **not visible inside that container at all**.
- The env half worked perfectly: the tombstone survived and `LSFGVK_PROFILE` arrived. Only the
  layer was missing.

So the fix is not a path or an env var. A Vulkan layer must match the driver it sits in front of,
and that driver is **aarch64** here — while upstream publishes **no arm64 build**.

**Consequence: as it stands the feature covers native x86-64 Linux titles and not Windows/Proton
titles, which are most of the library.** This reverses the "arm64 is dropped and that is not a
limitation" reasoning recorded above: that conclusion was drawn from the guest-tree architecture
and never checked against the Proton container, which does not use the guest tree.

### Resolved 2026-08-30: both halves are now built from source

`packages/lsfg-vk` (aarch64 host, overlay package) and `packages/lsfg-vk-x86` (x86_64 + i686 guest
payload, pinned x86 container). Both build the upstream tag unmodified, with no patches list and a
test on each that fails if one appears. The x86 build reads its tag from the host PKGBUILD so the
two arches cannot drift.

**One cost, recorded deliberately:** our x86 build needs `GLIBC_2.38` where upstream's prebuilt
needed `2.34`. Safe — the container is pinned to the guest's own glibc generation (2.44) — but it
is strictly less headroom than the prebuilt had, traded for a single build path and one licence
posture. If the guest glibc ever moves below what the container emits, the prebuilt is a supported
fallback.

### Options as they stood

1. **Build lsfg-vk for aarch64 ourselves** from unmodified source and install it host-side
   (`/usr/lib` + `/usr/share/vulkan/implicit_layer.d`), where pressure-vessel will import it.
   Compiling unmodified source is reproduction rather than adaptation, so ND is arguably
   satisfied — and the author explicitly invites integrators to make contact, which is the
   cleaner way to settle it than a unilateral reading. Cost: a real build, and it drops the
   "prebuilt only" simplicity Phase 3 was designed around.
2. **Ship as-is**, covering native x86-64 Linux titles only, and say so in the plugin rather than
   letting a user enable it for a Proton title and see nothing happen. Cheap, honest, narrow.

**Either way the plugin must not offer frame generation for a title it cannot affect** — the
current UI would let a user enable it for a Windows game and report success.

## Risks

| Risk | Severity | Note |
|---|---|---|
| FG pass too slow on Adreno | **HIGH** | Phase 1 answers it directly, before any spend |
| Vsync/FIFO vs gamescope pacing | **HIGH** | Only pacing mode; no fallback |
| Overlays misreport FPS | MEDIUM | Upstream-documented; forces flip-counter instrumentation |
| CC-BY-NC-ND blocks patching | MEDIUM | NC cleared; ND means every fix goes upstream first |
| Layer CPU-side runs emulated under FEX | MEDIUM | Per-frame Vulkan bookkeeping in x86 through FEX, on the present path |
| `2.0.0-rc1` is a release candidate | MEDIUM | HEAD moves daily; pin the tag, never `master` |
| `builds.lsfg-vk.dev` retention | LOW | Bare autoindex, no checksum sidecar, no retention guarantee. `_reference/lsfg-vk` is the fallback |
| Loader may not scan the provider's `implicit_layer.d` | LOW | Unproven under pressure-vessel; first check in Phase 6 |

---

## Decisions taken

| Date | Decision |
|---|---|
| 2026-08-30 | NonCommercial clause cleared — novadeck will never be a commercial product |
| 2026-08-30 | Ship in-image (~1.5 MB once `lsfg-vk-ui` is dropped), not fetched on demand |
| 2026-08-30 | x86-only; arm64 dropped (no upstream arm64 prebuilt, and no arm64 client we want to frame-generate) |
| 2026-08-30 | Use upstream prebuilts rather than building from source |
| 2026-08-30 | `conf.toml` + `LSFGVK_PROFILE`, not `LSFGVK_ENV=1` — hot reload is the plugin's value |
| 2026-08-30 | Write `novadeck-framegen` rather than adopt `decky-lsfg-vk` |
| 2026-08-30 | Probe with CLI flags (`-d`/`-a`), never `LSFGVK_*` env — env is dropped on a first run |
| 2026-08-30 | Perf-mode always on. Flow scale **per-SoC**: 1.00 on SM8550/SM8650, 0.50 on SM8250. Quality mode never |

## HW round 2026-08-31 — the aarch64/Proton half works, and the coverage boundary is the RENDERER

KONKR Pocket FIT (SM8650/A750), dev card at `5c6ed5c` + the relock in `b5d9c6f`, panel
1080x1920@144Hz. Games: PGRC (2737300, Godot) and Black The Fall (308060, Unity).

**The 2026-08-30 blocker is closed.** pressure-vessel DOES import our host manifest into a Proton
container, and the layer engages through the host aarch64 driver. The Vulkan loader says so
directly, with `VK_LOADER_DEBUG=layer`:

    Insert instance layer "VK_LAYER_LSFGVK_frame_generation"
        (/usr/lib/pressure-vessel/overrides/lib/aarch64-linux-gnu/liblsfg-vk-layer.so)
    Inserted device layer  "VK_LAYER_LSFGVK_frame_generation"

| path | verdict | evidence |
|---|---|---|
| native x86-64, compat tool | works, no regression from building x86 from source | layer from `/run/gfx`, 14/0 |
| Proton, native Vulkan | **works** | 60 cap -> locked 120 |
| Proton, D3D11 / DXVK | **works** | `d3d11.dll`+`dxgi.dll` -> host `libvulkan 1.4.328`, 15/0 |
| Proton, D3D12 / VKD3D | **works** | 15/0 |
| OpenGL, native or Proton | **cannot** | no Vulkan in maps; nothing to hook |

**The limit is the renderer, not the architecture.** Anything presenting through Vulkan is
covered, D3D included, because the layer sits below DXVK/VKD3D. A GL title has no Vulkan
swapchain and never will. The plan's earlier framing — "covers native x86-64 Linux titles and not
Windows/Proton titles" — is now wrong in both halves.

### The real precondition is FIFO, not a frame cap

First read was "the game needs its internal limiter on": PGRC uncapped left the layer mapped but
never initialised (144 = the vsync ceiling, identical with FG on and off), while PGRC at 60
engaged and gave 120. Black The Fall then falsified the cap theory — **uncapped, vsync ON, and the
layer engaged**. The limiter had been forcing FIFO as a side effect. Record the precondition as
FIFO/vsync; it is also the thing to tell a user whose game "does nothing".

### On a GPU-bound title it buys smoothness with real frames

Every earlier number came from PGRC at ~12.5% GPU, which is not a game so much as a screensaver.
Black The Fall is the first realistic load, and it is GPU-saturated before frame generation is
involved.

| | D3D11 | D3D12 |
|---|---|---|
| baseline, FG off | ~60fps, GPU-bound | ~100% GPU, 4 DRM clients |
| FG on | ~90 presented | ~81% GPU, 6 DRM clients |

90 presented at multiplier 2 is **~45 really rendered**, down from 60. The generation pass has no
headroom to come out of, so it comes out of the game's own rendering: better motion, worse
latency. That GPU *falls* rather than pins suggests the title stops being GPU-bound and becomes
FIFO-paced once the layer is in the chain.

**This is a tuning question and it belongs to the user, not to us.** Multiplier and flow scale are
exposed; the plugin does not measure headroom and does not warn or gate on it. See
[[no-speculative-gating-or-guards]] and [[devices-are-operator-reachable]].

### Still unmeasured

Frame-time consistency over a long session, image quality under motion, latency as a number rather
than an inference, and behaviour on SM8250 (1.9x headroom, flow 0.50) and SM8550.

### The gate script was the least reliable instrument in the room

Six defects, all fixed in `32a8df5`, each of which produced a wrong verdict during this very run —
including a `FAIL` on a run where frame generation was demonstrably working, and a GPU reading
that had frame generation costing less than nothing. Details in that commit message. The load-
bearing lesson: **a green gate proved nothing until the gate itself was checked against a case
whose answer was already known.** The pre-launch log-line snapshot is what caught it; without it
the stale block from the previous launch read as a clean pass for a launch that logged nothing.

## Verified 2026-08-31 (fresh card, `20a0e75`)

Flashed clean — no games, no tweaks, no `game-tweaks.json` — so the reported bug had a case that
PGRC and Black The Fall can no longer provide, both carrying an `enabled: true` the old code
wrote. Enabling frame generation now writes `framegen: true` and NOT `enabled`, and the control
plugin no longer shows the game as tuned.

**Hot reload confirmed on hardware**: changing `multiplier` applies to a RUNNING game.

### Two invariants hot reload silently depends on

It works because of two independent choices on opposite sides of the boundary that happen to fit.
Break either and the panel still says it saved while the game keeps its old settings — no error
anywhere.

1. **Upstream watches the PARENT DIRECTORY** for `IN_CLOSE_WRITE | IN_MOVED_TO`
   (`lsfg-vk-config/src/config.cpp:385`), and `conf.py:_atomic_write` swaps the file with
   `os.replace`. A rename installs a NEW INODE, so a watch armed on the FILE would go stale after
   the first save and never fire again — the classic atomic-write-vs-inotify trap. Watching the
   directory for `IN_MOVED_TO` is what catches the rename. **Do not "simplify" that writer to an
   in-place write**, and re-check this if the watcher changes upstream.
2. **The watcher is not armed at all when `LSFGVK_ENV` is set** (`lsfg-vk-layer/src/hooks.cpp:62`,
   "No need to watch an environment variable"). This is the concrete reason the configuration
   model is `conf.toml` + `LSFGVK_PROFILE` rather than env-only: adding `LSFGVK_ENV` as a
   shortcut would kill hot reload silently.

What does NOT hot reload, by construction: the on/off toggle (`DISABLE_LSFGVK`, read by the Vulkan
loader at layer-load time) and the profile selection (`LSFGVK_PROFILE`, applied at exec). Both
need a relaunch; the three tuning keys do not.

**Evidence to demand, not the code reading.** `hooks.cpp:77` logs `Configuration file has changed,
reloading...` on an actual reload — that line is what separates a real hot reload from a
coincidence, and after this session's stale-log episode it is the only thing worth trusting.
