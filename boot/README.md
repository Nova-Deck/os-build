# boot/

Pluggable boot stage. Interface: `(kernel, DTB, initramfs, cmdline) -> flashable
artifact`. The kernel/DTB inputs are backend-agnostic — swapping backend changes only
the artifact format, never the image content.

| File | Purpose |
|---|---|
| `package.sh <soc> [backend]` | Read the staged kernel (`out/<soc>/Image.gz` + `dtbs/`), package one artifact per board DTB via the selected backend into `out/<soc>/boot/`. |
| `deploy.sh <soc> <board> <esp>` | Phase 1 deploy: copy `out/<soc>/boot/<board>-boot.img` onto a mounted ESP as `/KERNEL` (atomic). Host-side; no fastboot. |
| `backends/android-bootimg.sh` | **Default.** Android boot image (kernel + dtb [+ initramfs]) via AOSP `mkbootimg`; flash with `fastboot flash boot` / test with `fastboot boot`. |
| `backends/edk2.sh` | edk2/UEFI — Phase 5 stretch, not yet implemented (selectable, fails loudly). |

Backend is chosen by (in order): the `[backend]` arg, `$BOOT_BACKEND`, `device.yaml`
`boot.backend`, else `android-bootimg`. The kernel command line comes from
`devices/<soc>/cmdline`; page size from `device.yaml` `kernel.page_size`. An initramfs
is optional (supplied by Phase 4 image assembly) — absent, the kernel+dtb are packaged
alone. Android header version defaults to v2 (dtb in-image); set `$BOOT_HEADER_VERSION`
for a v3/v4 (vendor_boot) bootloader.

`mkbootimg` lives in the build image, so run there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild boot/package.sh sm8650
```

_Phase 5._
