# boot/

Pluggable boot stage. Interface: `(kernel, DTBs, initramfs, cmdline) -> flashable
artifact`. The kernel/DTB inputs are backend-agnostic — swapping backend changes only
the artifact format, never the image content.

| File | Purpose |
|---|---|
| `package.sh [backend]` | Read the staged kernel (`out/Image.gz` + `dtbs/`), package **one** artifact holding every board DTB (all SoCs) via the selected backend into `out/boot/novadeck-boot.img`. |
| `deploy.sh <esp>` | Phase 1 deploy: copy `out/boot/novadeck-boot.img` onto a mounted ESP as `/KERNEL` (atomic). Host-side; no fastboot. ABL's DTB picker selects the board at boot. |
| `backends/android-bootimg.sh` | **Default.** Android boot image; every board DTB is appended to the kernel payload (ABL scans the trailing FDTs) via AOSP `mkbootimg`. Flash with `fastboot flash boot` / test with `fastboot boot`. |
| `backends/edk2.sh` | edk2/UEFI — Phase 5 stretch, not yet implemented (selectable, fails loudly). |

Backend is chosen by (in order): the `[backend]` arg, `$BOOT_BACKEND`, else
`android-bootimg`. The **common** kernel command line comes from `boot/cmdline`
(board-specific args live in each board's DTS `/chosen/bootargs`, which ABL appends to);
page size is the `4k` constant (`$BOOT_PAGESIZE` to override). An initramfs
is optional (supplied by Phase 4 image assembly) — absent, the kernel+DTBs are packaged
alone. Android header version defaults to v0 (no dtb field — the DTBs live in the kernel
payload); set `$BOOT_HEADER_VERSION` only if a bootloader needs a newer header.

`mkbootimg` lives in the build image, so run there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-build boot/package.sh
```

_Phase 5._
