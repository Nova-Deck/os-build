# kernel/

arm64 kernel build for novadeck target SoCs.

The upstream base ships only `linux-firmware`, **not** a device kernel — so we build
our own. Mainline/Linaro `sm8x50` base with vendor cherry-picks as needed.

The build is **unified**: one `Image` for every supported SoC/board, built from the
union of all fragments, patches and device trees. There is no SoC argument.

The kernel is staged **uncompressed**, deliberately. Stage-2 GRUB boots
`($slotroot)/boot/Image`, and `grubaa64.efi`'s module set carries no gzio filter, so a
compressed kernel would simply not load. `build.sh` deletes any stale `out/Image.gz` for
that reason — nothing reads it.

| Path | Purpose |
|---|---|
| `*.config` | Kconfig fragment(s), all merged onto an arm64 base defconfig (union across SoCs) |
| `kernel.config` | The **additive** fragment: everything novadeck turns on |
| `trim-platforms.config` | The **subtractive** fragment: non-Qualcomm platform gates turned off |
| `patches/` | Out-of-tree patches applied before build (lexical order) |
| `dts/qcom/` | Device trees injected into the kernel source before build; boards are **discovered** from the top-level `.dts` files |
| `embed.list` | `/lib/firmware`-relative paths baked into the Image (`CONFIG_EXTRA_FIRMWARE`), the union of every SoC's early-boot blobs |
| `build.sh` | Fetch pinned source → patch → inject DTs → merge configs → build `Image` + all dtbs + modules; stage to `out/` |

## Key decision: cut platform gates, not drivers
The base `defconfig` is deliberately "boots every arm64 board", so it enabled all 48 top-level
platform gates in `arch/arm64/Kconfig.platforms`. `trim-platforms.config` negates 47 of them
(everything but `ARCH_QCOM`); vendor drivers depend on those gates, so kconfig's dependency
closure removes ~1591 symbols from 49 directives — `Image` −19%, `out/modroot` −35%.

Two rules when editing it:
- **Never expand it into a per-driver list.** At gate level the file maintains itself: a vendor
  driver added upstream is born disabled. A per-driver list rots.
- **Never put a trailing comment on a directive.** `merge_config.sh` anchors on
  `is not set$`, so `# CONFIG_ARCH_TEGRA is not set  # Tegra` is silently just a comment — no
  warning, and the drivers ship anyway. Descriptions go on their own line. `build.sh` asserts
  the fragment took effect precisely because this failure is otherwise invisible.

## Key decision: 4K pages
`CONFIG_ARM64_4K_PAGES=y` is set deliberately — **FEX-Emu / x86 game compat (Phase 3)
assumes 4K pages.** Standardized across all three SoCs.

## Status (Phase 1)
- ✅ Source pinned to the 7.2 series — `kernel/SOURCE.pin` is the authority for the exact
  version (tarball URL + sha256 + dereferenced tag + the bump history). Do not restate the
  version here; one source of truth.
- ✅ Config symbols validated against that tree (see header of `kernel.config`).
- ✅ Builds `Image` + all board dtbs and stages loadable modules to `out/modroot`
  for the rootfs assembler — the `=m` handheld-panel drivers (display) ride along.
- ✅ The patch stack applies with **zero rejects and zero fuzz**. Fuzz is not cosmetic: a
  hunk that lands on approximate context has drifted from what it was written against and
  can silently attach to the wrong place on a later bump. Dry-run a bump with `--fuzz=0`,
  cumulatively in lexical order — a per-patch run against a clean tree reports failures the
  real sequential apply does not have, because the patches build on each other.
- ✅ Boots on real hardware across all three SoC generations; display, input, and Turnip
  Vulkan validated (Phase 1 gate cleared) — see `docs/archive/bringup.md`.

### Per-board HW gate

Each board proves something the others cannot, which is why a kernel bump is not validated
by one of them. Recorded state as of the 7.2.7 bump (2026-09-22):

| Board | SoC | LUTDMA | Rotation | Wi-Fi | Notes |
|---|---|---|---|---|---|
| AYANEO Pocket ACE | SM8550 | engine v2, dspp0 | DPU inline (`rotation=8`) | ath12k / WCN7850 | 10 boot SMMU faults are a PRE-EXISTING cohort, not a regression |
| AYN Thor Lite | SM8250 | **none in hardware** | composite (no inline rotator) | ath11k | Dual touchscreen; second panel unbound is a known open issue |
| KONKR Pocket FIT | SM8650 | engine v3, dspp0+dspp1 | DPU inline (`rotation=8`) | — | Its panel drawing at all is what proves patch 0525 |
| AYANEO Pocket S2 | SM8650 | engine v3 | inline, 8 lines under the 1088 cap | — | Bonded panel (0534); the tightest gate — **not yet run on 7.2.7** |

What to read, and the instrument traps:

- **Scanout vs composite**: `grep -c "allocated by = gamescope" /sys/kernel/debug/dri/0/state`.
  Two content planes is direct scanout. Do NOT read this as a universal pass/fail — on a board
  with no inline rotator (SM8250) gamescope must composite-rotate, and one LINEAR plane is the
  correct answer there.
- **Colour management**: `/sys/kernel/debug/dri/*/debug/lutdma`. `dspp0 igc opcode 0x100` and
  `gamut opmode 0x1` with non-zero buffer indices means the LUTs are programmed. `no engine`
  means the SoC has no LUTDMA block, so those patches are inert by hardware, not failing.
  Sample `ctl0 ... done` only once the session has settled: read at uptime 0 it is legitimately
  `done 0`, before the first transaction completes.
- **`gamescopectl <convar>` with no value SETS IT FALSE — it is never a read.** Reading
  `drm_output_luts` that way disarms the output LUTs. Re-arming restores them bit-identical,
  but only on the next repaint. Use `gamescopectl help` to confirm a convar exists.
- **Liveness**: `gamescopectl backend_info` → `Total Presents Queued`. Zero-vs-non-zero is all
  it answers. gamescope flips on demand on a static UI, so ~1 flip per 10s while idle is normal
  and is not a stall.
