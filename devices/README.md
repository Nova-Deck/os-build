# devices/

Board/SoC enablement data consumed **collectively** by the unified build — there is no
per-SoC image. Add a SoC by dropping its content into the shared trees (kernel fragment,
patches, DTS, firmware manifest entries, InputPlumber config); the build discovers it.

| File | Purpose |
|---|---|
| `firmware-manifest.txt` | Required firmware (union of all boards): `linux-fw` (open) vs `device` (qcom-fw) |
| `inputplumber/` | InputPlumber input config (gamepad/gyro) for all boards, synced to `/etc/inputplumber/` on release; matched by hardware at runtime |
| `bringup.md` | Phase 1 bring-up checklist + gate criteria (CLEARED) |
| `bringup-phase2.md` | Phase 2 (gamescope session + HW-support) bring-up notes (CLEARED) |
| `bringup-phase3.md` | Phase 3 (native arm64 Steam shell) bring-up notes |

## Supported SoCs

| SoC | Snapdragon | GPU | Status |
|---|---|---|---|
| SM8650 | 8 Gen 3 | Adreno 750 | Lead bring-up target (boards: AYANEO Pocket S2, KONKR Pocket FIT) |
| SM8550 | 8 Gen 2 | Adreno 740 | Planned — drop fragment/DTS/firmware in to enable |
| SM8750 | 8 Elite | Adreno 830 | Planned — drop fragment/DTS/firmware in to enable |

The kernel command line is split: common args in `boot/cmdline`, board/SoC-specific args
(e.g. `irqaffinity`, controller quirks) in each board's DTS `/chosen/bootargs`.
