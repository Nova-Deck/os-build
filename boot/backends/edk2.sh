# novadeck boot backend: edk2 / UEFI (Phase 5 stretch — not yet implemented).
#
# Placeholder that conforms to the backend interface so it is already selectable
# (`boot/package.sh edk2`), proving the boot stage is pluggable. Wiring a real
# UEFI flow (edk2 FD + ESP-embedded kernel/dtb, A/B via UEFI boot entries) is future
# work; until then it fails loudly rather than producing a bogus artifact.
#
# Contract: backend_package <kernel> <dtb> <cmdline> <pagesize> <initramfs> <out>
backend_package() {
  echo "edk2/UEFI backend not yet implemented (Phase 5 stretch); use android-bootimg" >&2
  return 3
}
