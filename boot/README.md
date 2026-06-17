# boot/

Pluggable boot stage. Interface: `(kernel, DTB, initramfs, image) -> flashable
artifact`. Backends: `android-bootimg` + fastboot (default), `edk2`/UEFI (stretch).
A/B slot selection wired per bootloader.

_Phase 0 placeholder — populated in Phase 5._
