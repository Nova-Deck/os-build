# kernel/

arm64 kernel build for novadeck target SoCs.

The upstream base ships only `linux-firmware`, **not** a device kernel — so we build
our own. Mainline/Linaro `sm8x50` base with vendor cherry-picks as needed.

| Path | Purpose |
|---|---|
| `config/<soc>.config` | Per-SoC Kconfig fragment, merged onto an arm64 base defconfig |
| `patches/` | Out-of-tree patches applied before build |
| `build.sh <soc>` | Fetch pinned source → patch → inject DTs → merge config → build `Image.gz` + dtbs + modules; stage to `out/<soc>/` |

## Key decision: 4K pages
`CONFIG_ARM64_4K_PAGES=y` is set deliberately — **FEX-Emu / x86 game compat (Phase 3)
assumes 4K pages.** Standardized across all three SoCs.

## Status (Phase 1)
- ✅ Source pinned: linux 7.0.11 (tarball URL + sha256 in `kernel/SOURCE.pin`).
- ✅ Config symbols validated against that tree (see header of `config/sm8650.config`).
- ✅ Builds `Image.gz` + board dtbs and stages loadable modules to `out/<soc>/modroot`
  for the rootfs assembler — the `=m` handheld-panel drivers (display) ride along.
- ⏳ Remaining work is on-hardware: serial console (`ttyMSM0`) is the first milestone —
  see `devices/sm8650/bringup.md`.

_Phase 1 scaffold._
