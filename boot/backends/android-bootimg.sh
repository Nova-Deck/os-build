# novadeck boot backend: android-bootimg (default).
#
# Packages the kernel + ALL board DTBs (+ optional initramfs) into ONE Android boot
# image. The ROCKNIX ABL has a DTB picker that scans the FDT blobs appended to the
# kernel payload (magic 0xd00dfeed) and lets the user select the board at boot — so a
# single `KERNEL` image serves every board on a SoC. We therefore `cat Image.gz
# <board>.dtb …` into the kernel payload (the classic appended-DTB scheme) instead of
# using mkbootimg's --dtb field. Flashable with `fastboot {flash boot,boot} <img>`,
# or for ABL copied to the ESP root as `KERNEL` (see boot/deploy.sh).
# Uses AOSP mkbootimg (vendored into the build image).
#
# Header v0 (kernel + ramdisk, no dtb field) matches the appended-DTB scheme: the
# DTBs ride inside the kernel payload, so there is no separate dtb section to fill —
# and mkbootimg rejects an empty --dtb on v2+. (v2's dedicated dtb field is the
# mutually-exclusive alternative we are NOT using.) Override with $BOOT_HEADER_VERSION
# only if a bootloader needs a newer header.
#
# Contract: backend_package <kernel> <dtbdir> <cmdline> <pagesize> <initramfs> <out>
backend_package() {
  local kernel="$1" dtbdir="$2" cmdline="$3" pagesize="$4" initramfs="$5" out="$6"
  command -v mkbootimg >/dev/null 2>&1 \
    || { echo "mkbootimg not found — run inside novadeck-kbuild" >&2; return 1; }

  # Build the kernel payload: Image.gz with every board DTB appended. ABL scans the
  # trailing FDTs to build its device-select menu; glob order (sorted) sets the menu
  # order. Cleaned up on return whether mkbootimg succeeds or fails.
  local payload; payload="$(mktemp)"
  trap 'rm -f "$payload"' RETURN
  cat "$kernel" >"$payload"
  local dtb n=0
  for dtb in "$dtbdir"/*.dtb; do
    [ -e "$dtb" ] || continue
    cat "$dtb" >>"$payload"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "no DTBs in $dtbdir to append" >&2; return 1; }
  echo "  appended $n DTB(s) to the kernel payload"

  local args=(
    --kernel "$payload"
    --base "${BOOT_BASE:-0x10000000}"
    --kernel_offset "${BOOT_KERNEL_OFFSET:-0x00008000}"
    --ramdisk_offset "${BOOT_RAMDISK_OFFSET:-0x06000000}"
    --tags_offset "${BOOT_TAGS_OFFSET:-0x00000100}"
    --pagesize "$pagesize"
    --header_version "${BOOT_HEADER_VERSION:-0}"
    --os_version "${BOOT_OS_VERSION:-12.0.0}"
    --cmdline "$cmdline"
    -o "$out"
  )
  [ -f "$initramfs" ] && args+=( --ramdisk "$initramfs" )

  mkbootimg "${args[@]}"
}
