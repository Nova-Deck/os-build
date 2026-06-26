# Plan: Unified image (collapse the per-SoC build axis)

**Complexity**: Medium
**Branch**: `refactor/unified-image`

## Summary
Originally every script took a mandatory `SOC` argument and produced per-SoC artifacts
(`out/<soc>/…`). novadeck now builds **one unified image**: a single arm64 kernel with the
union of all SoCs' drivers, every board DTB bundled into one boot artifact (the ABL DTB
picker selects at boot), and all required firmware embedded/staged. `SOC` is no longer a
build axis, and the per-SoC directories are flattened.

## What changed

### Directory flattening
- `kernel/sm8650/{sm8650.config,patches,dts}` → `kernel/{kernel.config,patches,dts}`
- `devices/sm8650/{firmware-manifest.txt,inputplumber,*.md}` → `devices/*`
- `devices/sm8650/cmdline` → split (see below); `devices/{sm8550,sm8750}/` placeholders removed
- `devices/device.yaml` deleted — fragments/patches/dts/boards are now discovered, cmdline
  moved to `boot/cmdline`, and its only remaining scalars (`page_size`, `backend`) are
  platform-wide constants baked into `boot/package.sh`.
- Output/work trees flattened: `out/`, `work/base/`, `firmware/linux-fw/`.

### Kernel (`kernel/build.sh`)
- No SoC arg. Globs every `kernel/*.config` (merged via `merge_config.sh`), every
  `kernel/patches/*.patch`, every `kernel/dts/qcom/*`. **Boards discovered** from the
  top-level `.dts` files. Builds `out/Image.gz` + all dtbs + modules.
- Embedded firmware (`CONFIG_EXTRA_FIRMWARE`) is the **union** listed in `kernel/embed.list`
  (one `/lib/firmware`-relative path per line), resolved against `firmware/linux-fw/` then
  `firmware/qcom-fw/` — add a SoC/board by appending to the list, no code change.

### cmdline split (decided with user)
- **Common** args (`root=`, `rootfstype=`, `console=`, `panic=`, `cgroup.*`, …) live in the
  single baked `boot/cmdline` (the Android boot-image cmdline).
- **Board/SoC-specific** args live in each board's DTS `/chosen/bootargs`. Moved
  `irqaffinity=0-1` (CPU-topology specific) and `usbcore.interrupt_interval_override=…`
  (controller quirk) into `sm8650-ayaneo-common.dtsi`'s `chosen` node.
- ABL appends the boot-image cmdline to the DT bootargs, so the kernel sees board args +
  common. **Verification gate (no UART):** `cat /proc/cmdline` on the booted sm8650 must show
  both sets. If ABL *replaces* instead of appends, fall back to full per-board DTS bootargs.

### Everything else
- `firmware/{fetch-linux-fw,manifest}.sh`, `boot/{package,deploy}.sh`,
  `images/{fetch-base,customize-base,assemble-rootfs,build-image,make-sdcard,genpart,genbundle}.sh`,
  `images/rauc/manifest.raucm.in` — SoC arg dropped, paths flattened, all boards' inputplumber
  configs injected. RAUC `compatible=novadeck`. Boot artifact: `out/boot/novadeck-boot.img`.
- `Makefile` — `SOC`/`SOC_EXEMPT` gate removed; flat paths; `$(SOC)` dropped from recipes;
  overlay arch-scoping kept. `make sdcard` (no SOC) is the full build.

## Validation
```bash
bash -n <every script>          # done — all pass
make help                       # done — no SOC, unified banner
grep -rn '$SOC' Makefile kernel/build.sh boot images firmware   # done — none
make sdcard                     # done — full unified build, out/images/sdcard.img (2840M)
cat /proc/cmdline               # done — on sm8650, DT bootargs + common cmdline both present:
#   irqaffinity=0-1 usbcore.interrupt_interval_override=045e:028e:2 \  (DTS chosen/bootargs)
#   quiet video=efifb:off console=tty0 root=PARTLABEL=novadeck-root rootfstype=btrfs \
#   rootwait rw cgroup.memory=nokmem,nosocket nosoftlockup panic=5      (boot/cmdline, common)
# ABL APPENDS common after board args (disjoint, in order) — top risk retired.
```

## Risks
| Risk | Mitigation |
|---|---|
| ~~ABL replaces (not appends) chosen/bootargs → board args lost~~ | **RETIRED** — on-device `/proc/cmdline` confirms ABL appends common after board args (both present, disjoint, in order) |
| Future SoC config-fragment / patch conflicts | `merge_config.sh -m` reports overrides; only sm8650 populated today |
| Embedded-firmware union inflates Image.gz | `embed.list` keeps the set curated, not the whole manifest |
| On-device regression vs per-SoC image | sm8650 HW boot is the gate; kernel/dtb content for sm8650 is byte-equivalent |

## Acceptance
- [x] SoC argument removed from all scripts + Makefile
- [x] Per-SoC dirs flattened; placeholders + device.yaml removed
- [x] Kernel discovers boards/fragments/patches/dts; firmware embed unioned
- [x] cmdline split (common → boot/cmdline, board → DTS chosen/bootargs)
- [x] `bash -n` + `make help` pass; no residual `$SOC`
- [x] `make sdcard` full build → `out/images/sdcard.img` (2840M: 256M ESP + 2.5G root)
- [x] On-device sm8650 boot + `/proc/cmdline` verification — CONFIRMED (board+common args both present, in order)
