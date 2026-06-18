# boot/

Pluggable boot stage. Interface: `(kernel, DTBs, initramfs, cmdline) -> flashable
artifact`. The kernel/DTB inputs are backend-agnostic — swapping backend changes only
the artifact format, never the image content.

| File | Purpose |
|---|---|
| `package.sh <soc> [backend]` | Read the staged kernel (`out/<soc>/Image.gz` + `dtbs/`), package **one** artifact holding all board DTBs via the selected backend into `out/<soc>/boot/<soc>-boot.img`. |
| `deploy.sh <soc> <esp>` | Phase 1 deploy: copy `out/<soc>/boot/<soc>-boot.img` onto a mounted ESP as `/KERNEL` (atomic). Host-side; no fastboot. ABL's DTB picker selects the board at boot. |
| `backends/android-bootimg.sh` | **Default.** Android boot image; every board DTB is appended to the kernel payload (ABL scans the trailing FDTs) via AOSP `mkbootimg`. Flash with `fastboot flash boot` / test with `fastboot boot`. |
| `backends/edk2.sh` | edk2/UEFI — Phase 5 stretch, not yet implemented (selectable, fails loudly). |

Backend is chosen by (in order): the `[backend]` arg, `$BOOT_BACKEND`, `device.yaml`
`boot.backend`, else `android-bootimg`. The kernel command line comes from
`devices/<soc>/cmdline`; page size from `device.yaml` `kernel.page_size`. An initramfs
is optional (supplied by Phase 4 image assembly) — absent, the kernel+DTBs are packaged
alone. Android header version defaults to v0 (no dtb field — the DTBs live in the kernel
payload); set `$BOOT_HEADER_VERSION` only if a bootloader needs a newer header.

`mkbootimg` lives in the build image, so run there:

```
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild boot/package.sh sm8650
```

_Phase 5._
