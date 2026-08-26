#!/usr/bin/env bash
# novadeck unified kernel build. Requires an aarch64 build host (or CROSS_COMPILE) + toolchain.
#
# One Image serves EVERY supported SoC/board: a single arm64 kernel built with the union of all
# config fragments, all out-of-tree patches, and all device trees. Every board DTB is staged
# alongside it and the stage-2 grub.cfg picks one per menu entry.
#
# UNCOMPRESSED, deliberately. This used to build Image.gz for the android-bootimg boot artifact.
# The stage-2 GRUB boots ($slotroot)/boot/Image, and grubaa64.efi's module set has no gzio filter
# to unpack a .gz with -- so a compressed kernel here would simply not load. Building both and
# shipping one is how the unused half goes stale, so only Image is built.
#
# Steps: fetch+verify pinned tarball -> apply all patches -> inject all device trees ->
# merge all config fragments -> build Image + every dtb + modules -> stage for image assembly.
#
#   kernel/build.sh           # no SoC argument — the build is unified
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Unified kernel home: config fragments (kernel/*.config), out-of-tree patches
# (kernel/patches/) and device trees (kernel/dts/qcom/) — all SoCs folded into one tree.
KDIR_REPO="$ROOT/kernel"
FRAGMENTS=("$KDIR_REPO"/*.config)   # every fragment is merged (union across SoCs)
# BASE_CONFIG: path to a complete .config to use verbatim (copied in, then olddefconfig).
# When set, the defconfig+fragment merge is skipped entirely — used to build a known-good
# vendor config (e.g. ROCKNIX) exactly as-is rather than as a fragment overlay.
BASE_CONFIG="${BASE_CONFIG:-}"

# Source is pinned in kernel/SOURCE.pin (tarball URL + sha256 = canonical pin).
PIN="$ROOT/kernel/SOURCE.pin"
[ -f "$PIN" ] || { echo "missing pin: $PIN" >&2; exit 1; }
pin() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }
KVER="$(pin version)"; KURL="$(pin url)"; KSHA="$(pin sha256)"
WORK="${WORK:-$ROOT/work/kernel}"
TARBALL="$WORK/linux-${KVER}.tar.xz"

if [ -n "$BASE_CONFIG" ]; then
  echo "[novadeck] base-config=$BASE_CONFIG (verbatim) kernel=$KVER"
  [ -f "$BASE_CONFIG" ] || { echo "missing base config: $BASE_CONFIG" >&2; exit 1; }
else
  [ "${#FRAGMENTS[@]}" -gt 0 ] || { echo "no config fragments in $KDIR_REPO/*.config" >&2; exit 1; }
  echo "[novadeck] fragments=${FRAGMENTS[*]#"$ROOT"/} kernel=$KVER"
fi

# Fetch + verify the pinned tarball (idempotent), then extract a clean tree.
mkdir -p "$WORK"
[ -f "$TARBALL" ] || curl -fSL -o "$TARBALL" "$KURL"
echo "${KSHA}  ${TARBALL}" | sha256sum -c - || { echo "sha256 mismatch — refusing to build" >&2; exit 1; }
SRCDIR="$WORK/linux-${KVER}"
rm -rf "$SRCDIR"
tar -C "$WORK" -xf "$TARBALL"
echo "[novadeck] source ready at $SRCDIR"

# --- Apply out-of-tree patches in lexical order (rename files to reorder) ---
for p in "$KDIR_REPO"/patches/*.patch; do
  echo "[novadeck] applying $(basename "$p")"
  patch -p1 -d "$SRCDIR" --no-backup-if-mismatch <"$p" \
    || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
done

# --- Inject novadeck device trees + register every board dtb in the qcom Makefile ---
# Boards are DISCOVERED from the top-level .dts files (one per board); .dtsi are includes.
QCOM_DTS="$SRCDIR/arch/arm64/boot/dts/qcom"
cp "$KDIR_REPO"/dts/qcom/*.dtsi "$KDIR_REPO"/dts/qcom/*.dts "$QCOM_DTS"/
BOARDS=()
for dts in "$KDIR_REPO"/dts/qcom/*.dts; do BOARDS+=( "$(basename "${dts%.dts}")" ); done
[ "${#BOARDS[@]}" -gt 0 ] || { echo "no board .dts in kernel/dts/qcom/" >&2; exit 1; }
for b in "${BOARDS[@]}"; do
  grep -q "${b}\.dtb" "$QCOM_DTS/Makefile" \
    || echo "dtb-\$(CONFIG_ARCH_QCOM) += ${b}.dtb" >> "$QCOM_DTS/Makefile"
done
echo "[novadeck] ${#BOARDS[@]} board(s): ${BOARDS[*]}"

# --- Stage built-in firmware (CONFIG_EXTRA_FIRMWARE) ---
# Like ROCKNIX, bake firmware into the Image so the blobs are present before the SD-card
# rootfs mounts. The embed set is the UNION of every SoC's early-boot blobs, listed one
# /lib/firmware-relative path per line in kernel/embed.list (single source of truth — add a
# SoC/board by appending there, no edit here). Each path is resolved against the open
# linux-firmware tree (firmware/linux-fw, fetch-linux-fw.sh) then the device-proprietary tree
# (firmware/qcom-fw, fetch-qcom-fw.sh); it is copied into the kernel tree's firmware/ dir (the
# pinned CONFIG_EXTRA_FIRMWARE_DIR) under that exact path, and CONFIG_EXTRA_FIRMWARE is DERIVED
# from the list after configuring (below) — works on both the fragment and BASE_CONFIG paths.
LFW="$ROOT/firmware/linux-fw"
FWX="$ROOT/firmware/qcom-fw"
EMBED_LIST="$KDIR_REPO/embed.list"
[ -f "$EMBED_LIST" ] || { echo "missing embed list: $EMBED_LIST" >&2; exit 1; }
echo "[novadeck] staging built-in firmware (CONFIG_EXTRA_FIRMWARE) into firmware/"
EMBED_REL=""   # accumulates the /lib/firmware-relative paths -> CONFIG_EXTRA_FIRMWARE list
while read -r rel _rest; do
  case "$rel" in ''|'#'*) continue ;; esac
  if   [ -f "$LFW/$rel" ]; then src="$LFW/$rel"
  elif [ -f "$FWX/$rel" ]; then src="$FWX/$rel"
  else
    echo "missing embed firmware: $rel" >&2
    echo "  run firmware/fetch-linux-fw.sh (open blobs) + firmware/fetch-qcom-fw.sh (device blobs)" >&2
    exit 1
  fi
  install -Dm0644 "$src" "$SRCDIR/firmware/$rel"
  EMBED_REL="${EMBED_REL:+$EMBED_REL }$rel"
done < "$EMBED_LIST"

# --- Configure + build ---
# Cross-compile unless the build host is itself aarch64. Default to the standard GNU
# aarch64 prefix when unset, and fail fast if the toolchain is missing — otherwise the
# build silently uses the host gcc and dies deep in with a cryptic '-mlittle-endian'
# error. Override CROSS_COMPILE to use a different toolchain.
if [ "$(uname -m)" != "aarch64" ]; then
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi
if [ -n "${CROSS_COMPILE:-}" ]; then
  command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || {
    echo "cross compiler not found: ${CROSS_COMPILE}gcc" >&2
    echo "  install the aarch64 toolchain or set CROSS_COMPILE to its prefix" >&2
    exit 1
  }
  echo "[novadeck] cross-compiling with ${CROSS_COMPILE}gcc"
fi
CC=(${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE})
( cd "$SRCDIR"
  if [ -n "$BASE_CONFIG" ]; then
    # Verbatim full config: copy it in and let olddefconfig resolve any symbols that
    # differ between the vendor build and this pinned tree (new/removed Kconfig options).
    cp "$BASE_CONFIG" .config
    make ARCH=arm64 "${CC[@]}" olddefconfig
  else
    # Merge defconfig with EVERY novadeck fragment (union across SoCs).
    scripts/kconfig/merge_config.sh -m arch/arm64/configs/defconfig "${FRAGMENTS[@]}"
    make ARCH=arm64 "${CC[@]}" olddefconfig
  fi
  # Embed the staged blobs into the Image. Derive CONFIG_EXTRA_FIRMWARE from the embed
  # list above (single source of truth), so neither the fragment nor a verbatim
  # BASE_CONFIG has to carry the per-file list. Pin EXTRA_FIRMWARE_DIR to the kernel
  # tree's "firmware/" dir where the staging loop installs the blobs — the Kconfig
  # default is "/lib/firmware" (absolute, not present in the build container), so it
  # MUST be overridden or the embed can't find the files. Re-run olddefconfig to settle.
  scripts/config --file .config --set-str EXTRA_FIRMWARE "$EMBED_REL"
  scripts/config --file .config --set-str EXTRA_FIRMWARE_DIR firmware
  make ARCH=arm64 "${CC[@]}" olddefconfig

  # Assert the symbols whose VALUE is load-bearing actually survived olddefconfig, in both
  # directions. kconfig silently promotes a module to built-in when some =y symbol selects it,
  # and it silently DROPS a =y symbol whose dependencies are unmet -- merge_config.sh warns in
  # that case but does not fail (see kernel.config's header). Either way the only symptom is at
  # runtime, on a device with no serial console. Fail loudly here instead of shipping it.
  #
  #   =m  the wireless stack: built-in, cfg80211 requests regulatory.db at kernel init, before
  #       any rootfs exists, and the load always fails.
  #   =m  TOUCHSCREEN_CHIPONE_TDDI: a TDDI controller powered off the PANEL rails. Built-in, it
  #       probes from the initcall at ~0.97s, ~18.8s before the msm DRM panel driver binds and
  #       powers it -- so every I2C write times out (-110), the driver's three 5.1s retries burn
  #       ~18.6s with the rest of device probing (PCIe, UFS, DRM) stuck behind it, and touch is
  #       then absent for the session. =m moves it off the initcall path to udev autoload, after
  #       the panel is up. A silent promotion back to =y costs the touchscreen AND the boot.
  #   =y  dm-verity: rauc installs a format=verity bundle from the sealed root; a module on the
  #       update path can be missing exactly when an update is applied.
  #   =y  vfat + loop: image/initramfs/init mounts the ESP to read the A/B slot state. Losing
  #       vfat makes every boot silently fall back to the cmdline root= instead.
  #   =y  zram + the zstd backend: the ONLY swap device on this image comes from zram-generator,
  #       and a kernel without it produces no zram0, no swap and no error — while
  #       60-novadeck-gaming.conf's vm.swappiness=180 quietly does nothing. The backend is checked
  #       separately from ZRAM because losing just that one leaves zram working but rejecting the
  #       `compression-algorithm = zstd` the shipped generator config asks for.
  #
  # The block below guards the Qualcomm platform path against kernel/trim-platforms.config.
  # That fragment disables ~47 non-Qualcomm ARCH_* platform gates and lets kconfig's dependency
  # closure prune the drivers behind them. Removals are safe by construction TODAY (verified
  # bit-identical across every QCOM|MSM|ADRENO|SNAPDRAGON symbol), but nothing stops a future
  # kernel bump from re-parenting one of these under a gate we now cut -- at which point the
  # symbol vanishes silently and the device fails to display, boot or mount. Assert, don't hope.
  #
  #   =y  DRM_MSM: the display. Losing it is a black panel with no other symptom.
  #   =y  PCIE_QCOM + PCI_PWRCTRL_GENERIC: the USB3 hub hangs off &pcie1_port0; without the
  #       pwrctrl driver the port never powers up and every USB3 device is simply absent.
  #   =y  MMC_SDHCI_MSM: the SD card IS the boot medium. A module here cannot mount the rootfs
  #       that contains it.
  #   =y  SCSI_UFSHCD: internal UFS -- the install-to-UFS target and the only other bulk store.
  #   =y  ARM_SMMU: the IOMMU the GPU and peripherals sit behind.
  #   =y  ARM64_4K_PAGES: FEX-Emu / x86 game compat assumes 4K pages (see kernel/README.md).
  #       kconfig picks a page size unconditionally, so a silent flip here is a silent ABI change.
  #   =y  SCHED_CLASS_EXT + DEBUG_INFO_BTF: kernel.config's header says to verify both by hand
  #       after every merge because the BTF dep chain is fragile (DEBUG_INFO_REDUCED, pahole).
  #       A declared invariant that nothing checks is not a guard -- so check it here.
  #   =y  SQUASHFS + OVERLAY_FS: the /etc overlay mounts a squashfs seed. Losing either leaves
  #       a root that boots with an empty or read-only /etc.
  #   =m  VIDEO_QCOM_IRIS: the video decoder on ALL THREE SoCs, and the hinge of an interlock
  #       that is invisible from either side on its own. venus/core.c hides its
  #       qcom,sm8250-venus entry behind #if !IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS), so with iris
  #       enabled it is the sole claimant of that node and firmware/LINUX_FW.pin ships the blob
  #       under IRIS's name (qcom/vpu/vpu20_p4.mbn). Drop iris to =n and venus silently takes
  #       the node back, asks for qcom/vpu-1.0/venus.mbn, and finds nothing -- and we have
  #       dropped VIDEO_QCOM_VENUS anyway, so the node would simply go unclaimed. Either way
  #       the only symptom is video decode quietly not working on a device with no console.
  for pair in CFG80211=m MAC80211=m TOUCHSCREEN_CHIPONE_TDDI=m VIDEO_QCOM_IRIS=m \
              BLK_DEV_DM=y DM_VERITY=y VFAT_FS=y BLK_DEV_LOOP=y \
              ZRAM=y ZRAM_BACKEND_ZSTD=y \
              DRM_MSM=y PCIE_QCOM=y PCI_PWRCTRL_GENERIC=y MMC_SDHCI_MSM=y SCSI_UFSHCD=y \
              ARM_SMMU=y ARM64_4K_PAGES=y SCHED_CLASS_EXT=y DEBUG_INFO_BTF=y \
              SQUASHFS=y OVERLAY_FS=y; do
    sym=${pair%=*}; want=${pair#*=}
    got="$(scripts/config --file .config --state "$sym")"
    [ "$got" = "$want" ] || {
      echo "CONFIG_$sym resolved to '$got', expected '$want'" >&2
      if [ "$want" = m ]; then
        echo "  something built-in selects it; find it with: grep -rn \"select $sym\" ." >&2
      else
        echo "  a dependency is unmet, so kconfig dropped it; check: grep -rn \"config $sym\" -A5 ." >&2
      fi
      exit 1
    }
  done

  # Verify kernel/trim-platforms.config actually TOOK EFFECT. That fragment is subtractive --
  # it is a list of `# CONFIG_x is not set` directives -- and subtractive config has a failure
  # mode additive config does not: when a directive is malformed, nothing errors. The symbol
  # simply keeps its defconfig value, the build succeeds, and the image ships the drivers you
  # believe you cut. There is no runtime symptom to notice either, because the result is just
  # the old, larger kernel.
  #
  # It is an easy line to malform. merge_config.sh matches these with
  #   notset_regex = "^# CONFIG_[a-zA-Z0-9_]+ is not set$"
  # and that trailing `$` means an inline trailing comment silently demotes the directive to a
  # plain comment (cost one wasted kernel build on 2026-08-03 -- see the fragment's header).
  #
  # So re-derive the directives with merge_config's OWN anchored regex and assert each one
  # resolved to unset. Two extra guards, because a parse that finds nothing would otherwise
  # "pass" an empty loop: a floor on the directive count, and an explicit scan for the
  # trailing-text form that merge_config would ignore.
  TRIM="$KDIR_REPO/trim-platforms.config"
  if [ -f "$TRIM" ]; then
    # The exact form merge_config would ignore: a directive with anything trailing "is not set".
    if grep -nE '^# CONFIG_[A-Za-z0-9_]+ is not set.+' "$TRIM" >&2; then
      echo "trim-platforms.config: the lines above have trailing text after 'is not set'," >&2
      echo "  so merge_config.sh treats them as comments and the symbols stay enabled." >&2
      echo "  Move the description to its own line above the directive." >&2
      exit 1
    fi
    TRIM_SYMS="$(sed -n 's/^# CONFIG_\([A-Za-z0-9_]\+\) is not set$/\1/p' "$TRIM")"
    TRIM_N="$(printf '%s\n' "$TRIM_SYMS" | grep -c . || true)"
    [ "$TRIM_N" -ge 40 ] || {
      echo "trim-platforms.config: parsed only $TRIM_N directives, expected >= 40" >&2
      echo "  the file is present but nearly nothing in it is a valid directive" >&2
      exit 1
    }
    for sym in $TRIM_SYMS; do
      got="$(scripts/config --file .config --state "$sym")"
      case "$got" in
        n|undef) ;;
        *) echo "CONFIG_$sym is '$got' but kernel/trim-platforms.config asks for it to be unset" >&2
           echo "  something we still enable selects it; find it with: grep -rn \"select $sym\" ." >&2
           exit 1 ;;
      esac
    done
    echo "[novadeck] trim-platforms: $TRIM_N symbols confirmed disabled"
  fi

  make ARCH=arm64 "${CC[@]}" -j"$(nproc)" Image dtbs modules
)

# --- Stage artifacts for image assembly ---
OUT="$ROOT/out"; mkdir -p "$OUT/dtbs"
cp "$SRCDIR/arch/arm64/boot/Image" "$OUT/"
rm -f "$OUT/Image.gz"   # a leftover from a pre-phase-5 out/ would be stale, and nothing reads it
for b in "${BOARDS[@]}"; do cp "$QCOM_DTS/${b}.dtb" "$OUT/dtbs/"; done

# Install loadable modules into a staging tree consumed by rootfs/assemble-rootfs.sh.
# INSTALL_MOD_PATH yields a self-contained /lib/modules/<kver> (with depmod metadata)
# and never writes the host's /lib. The =m drivers (e.g. handheld panels needed for
# display bring-up) live here. Drop the build/source symlinks — they point back into
# this throwaway source tree and would dangle in the rootfs.
MODROOT="$OUT/modroot"
rm -rf "$MODROOT"
( cd "$SRCDIR"
  make ARCH=arm64 "${CC[@]}" INSTALL_MOD_PATH="$MODROOT" INSTALL_MOD_STRIP=1 modules_install
)
find "$MODROOT/lib/modules" -maxdepth 2 -type l \( -name build -o -name source \) -delete
echo "[novadeck] staged Image + ${#BOARDS[@]} dtbs + modules in $OUT"
