# devices/sm8650 — Snapdragon 8 Gen 3 (lead target)

GPU: **Adreno 750** (kernel `msm`, userspace **Turnip** Vulkan).

| File | Purpose |
|---|---|
| `device.yaml` | SoC manifest: GPU, kernel page size, DT, boot backend, firmware ref |
| `cmdline` | Kernel command line (UART console + boot flags) |
| `firmware-manifest.txt` | Required firmware: `linux-fw` (from base) vs `device` (extract) |
| `inputplumber/` | Per-SoC InputPlumber input config (gamepad/gyro), synced to `/etc/inputplumber/` on release |
| `bringup.md` | Ordered bring-up checklist + Phase 1 gate criteria |

_Phase 1 scaffold._
