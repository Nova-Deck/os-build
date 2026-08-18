# kernel/

arm64 kernel build for novadeck target SoCs.

The upstream base ships only `linux-firmware`, **not** a device kernel — so we build
our own. Mainline/Linaro `sm8x50` base with vendor cherry-picks as needed.

The build is **unified**: one `Image.gz` for every supported SoC/board, built from the
union of all fragments, patches and device trees. There is no SoC argument.

| Path | Purpose |
|---|---|
| `*.config` | Kconfig fragment(s), all merged onto an arm64 base defconfig (union across SoCs) |
| `kernel.config` | The **additive** fragment: everything novadeck turns on |
| `trim-platforms.config` | The **subtractive** fragment: non-Qualcomm platform gates turned off |
| `patches/` | Out-of-tree patches applied before build (lexical order) |
| `dts/qcom/` | Device trees injected into the kernel source before build; boards are **discovered** from the top-level `.dts` files |
| `embed.list` | `/lib/firmware`-relative paths baked into the Image (`CONFIG_EXTRA_FIRMWARE`), the union of every SoC's early-boot blobs |
| `build.sh` | Fetch pinned source → patch → inject DTs → merge configs → build `Image.gz` + all dtbs + modules; stage to `out/` |

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
- ✅ Source pinned: currently linux 7.2 — `kernel/SOURCE.pin` is the authority (tarball
  URL + sha256 + the bump history, including what 7.2 took over from `patches/`).
- ✅ Config symbols validated against that tree (see header of `kernel.config`).
- ✅ Builds `Image.gz` + all board dtbs and stages loadable modules to `out/modroot`
  for the rootfs assembler — the `=m` handheld-panel drivers (display) ride along.
- ✅ Boots on real SM8650 hardware; display, input, and Turnip Vulkan validated
  (Phase 1 gate cleared) — see `docs/bringup.md`.
