# mesa patches

novadeck patches applied on top of the upstream mesa release source (currently `26.2.0`), in
the order listed by `patches:` in [`../source.pin`](../source.pin). Each is applied with
`patch -p1` from the mesa source root (the `mesa-<version>/` tree inside makepkg's `$srcdir`)
by [`packages/build-overlay.sh`](../../build-overlay.sh), inserted right after the first `cd`
in the PKGBUILD's `prepare()`.

## Present

```
0001-add-a830-chip-id.patch                                          # SM8750 / a830 enablement
0002-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch  # general ir3 correctness fix
```

- **0001** (a830-specific) — register the Adreno 830 (a8xx) `chip_id`s in
  `src/freedreno/common/freedreno_devices.py` so freedreno/Turnip recognise the SM8750 GPU (adds
  the msm `0xffff4405…` and KGSL `0x4405…` variants).
- **0002** (NOT a8xx-specific — applies to all freedreno/Adreno gens) — in ir3's UBO-range
  analysis (`ir3_nir_analyze_ubo_ranges.c`), only treat a bindless UBO load as a constant range
  when the **offset** (`instr->src[1]`) is also constant, not just the resource handle. A general
  ir3 const-lowering correctness fix on the Vulkan/Turnip path.

Patches apply `-p1` against the upstream mesa tree, in the order listed in
[`../source.pin`](../source.pin)'s `patches:` line. If a declared patch is missing or fails to
apply, `build-overlay.sh` / `makepkg` fails fast before the package is built.
