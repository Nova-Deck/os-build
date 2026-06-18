# novadeck boot backend: android-bootimg (default).
#
# Packages kernel + dtb (+ optional initramfs) into an Android boot image, flashable
# with `fastboot flash boot <img>` or testable live with `fastboot boot <img>`.
# Uses AOSP mkbootimg (vendored into the build image).
#
# Header v2 keeps the dtb inside boot.img; v3+ moves it to a separate vendor_boot
# partition. v2 is the pragmatic choice for generic-arm64 bring-up — override with
# $BOOT_HEADER_VERSION when targeting a v3/v4 bootloader.
#
# Contract: backend_package <kernel> <dtb> <cmdline> <pagesize> <initramfs> <out>
backend_package() {
  local kernel="$1" dtb="$2" cmdline="$3" pagesize="$4" initramfs="$5" out="$6"
  command -v mkbootimg >/dev/null 2>&1 \
    || { echo "mkbootimg not found — run inside novadeck-kbuild" >&2; return 1; }

  local args=(
    --kernel "$kernel"
    --dtb "$dtb"
    --pagesize "$pagesize"
    --header_version "${BOOT_HEADER_VERSION:-2}"
    --cmdline "$cmdline"
    -o "$out"
  )
  [ -f "$initramfs" ] && args+=( --ramdisk "$initramfs" )

  mkbootimg "${args[@]}"
}
