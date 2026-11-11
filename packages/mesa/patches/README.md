# mesa patches

novadeck patches applied on top of the upstream mesa release source (currently `26.3.0`), in
the order listed by `patches:` in [`../source.pin`](../source.pin). Each is applied with
`patch -p1` from the mesa source root (the `mesa-<version>/` tree inside makepkg's `$srcdir`)
by [`packages/build-overlay.sh`](../../build-overlay.sh), inserted right after the first `cd`
in the PKGBUILD's `prepare()`.

## Present

None. mesa builds from the unmodified release tarball.

## Dropped

- **0001-add-a830-chip-id.patch** — dropped at the 26.3.0 bump. It registered extra Adreno 830
  (SM8750) `chip_id`s in `src/freedreno/common/freedreno_devices.py`: the msm `0xffff44050001`
  and the KGSL `0x44050000`. 26.3.0 registers `0xffff44050001` itself, which matches the
  `0x44050001` our kernel's a830 entry reports (kernel patch `0280`), so the patch no longer
  applied. The KGSL id it would still add is dead here: we run the msm DRM driver, never KGSL.
  Visible change: upstream names that entry `Adreno (TM) 830v1`, so the renderer string on SM8750
  is now `830v1` rather than `830`.

  **HW check owed:** Turnip and freedreno must still recognise the GPU on an SM8750 board
  (`vulkaninfo` shows `DRIVER_ID_MESA_TURNIP`, `glxinfo -B` names freedreno). If they do not, the
  kernel is reporting a chip_id upstream does not list; restore the patch from git history.

- **0002-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch** — dropped 2026-08-19
  (this file's history has the full write-up). It was a ROCKNIX-origin workaround (added there
  2026-05-12, never upstreamed) that made ir3's UBO-range analysis treat a bindless UBO load as a
  constant range only when the offset was also constant. ROCKNIX removed it on 2026-08-11 as "no
  longer needed" (`ROCKNIX/distribution#3167`), the UBO-range analysis it patched was reworked
  between mesa 26.0.0 and 26.2.0, and this file already marked it a removal candidate.

  **HW retest still owed:** being wrong costs miscompiled shaders — a hang or corruption in a
  Vulkan title, found by a player, not by a build. On the next flashed card, play the Vulkan test
  titles (Super Meat Boy, Garage Circuit Rally, plus at least one Proton title) and watch for
  corruption. If anything reproduces, restore the patch from git history AND record what
  reproduced — the note that was always missing from it.

Patches apply `-p1` against the upstream mesa tree, in the order listed in
[`../source.pin`](../source.pin)'s `patches:` line. If a declared patch is missing or fails to
apply, `build-overlay.sh` / `makepkg` fails fast before the package is built.
