# kernel/

arm64 kernel build for novadeck target SoCs.

The upstream base ships only `linux-firmware`, **not** a device kernel — so we build
our own. Mainline/Linaro `sm8x50` base with vendor cherry-picks as needed.

The build is **unified**: one `Image.gz` for every supported SoC/board, built from the
union of all fragments, patches and device trees. There is no SoC argument.

| Path | Purpose |
|---|---|
| `*.config` | Kconfig fragment(s), all merged onto an arm64 base defconfig (union across SoCs) |
| `patches/` | Out-of-tree patches applied before build (lexical order) |
| `dts/qcom/` | Device trees injected into the kernel source before build; boards are **discovered** from the top-level `.dts` files |
| `embed.list` | `/lib/firmware`-relative paths baked into the Image (`CONFIG_EXTRA_FIRMWARE`), the union of every SoC's early-boot blobs |
| `build.sh` | Fetch pinned source → patch → inject DTs → merge configs → build `Image.gz` + all dtbs + modules; stage to `out/` |

## Key decision: 4K pages
`CONFIG_ARM64_4K_PAGES=y` is set deliberately — **FEX-Emu / x86 game compat (Phase 3)
assumes 4K pages.** Standardized across all three SoCs.

## Status (Phase 1)
- ✅ Source pinned: linux 7.1.3 (tarball URL + sha256 in `kernel/SOURCE.pin`).
- ✅ Config symbols validated against that tree (see header of `kernel.config`).
- ✅ Builds `Image.gz` + all board dtbs and stages loadable modules to `out/modroot`
  for the rootfs assembler — the `=m` handheld-panel drivers (display) ride along.
- ✅ Boots on real SM8650 hardware; display, input, and Turnip Vulkan validated
  (Phase 1 gate cleared) — see `docs/bringup.md`.
