# kernel/

arm64 kernel build for novadeck target SoCs.

The upstream base ships only `linux-firmware`, **not** a device kernel — so we build
our own. Mainline/Linaro `sm8x50` base with vendor cherry-picks as needed.

| Path | Purpose |
|---|---|
| `config/<soc>.config` | Per-SoC Kconfig fragment, merged onto an arm64 base defconfig |
| `patches/` | Out-of-tree patches applied before build |
| `build.sh <soc>` | Clone pinned source → patch → merge config → build `Image` + dtbs |

## Key decision: 4K pages
`CONFIG_ARM64_4K_PAGES=y` is set deliberately — **FEX-Emu / x86 game compat (Phase 3)
assumes 4K pages.** Standardized across all three SoCs.

## TODO (Phase 1)
- Pin a real kernel source (tag/commit + sha256) in `kernel/SOURCE.pin`.
- Validate config symbols against that tree (names drift by version).
- First milestone: serial console (`ttyMSM0`) on SM8650 — see `devices/sm8650/bringup.md`.

_Phase 1 scaffold._
