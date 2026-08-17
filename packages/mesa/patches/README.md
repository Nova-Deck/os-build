# mesa patches

novadeck patches applied on top of the upstream mesa release source (currently `26.2.0`), in
the order listed by `patches:` in [`../source.pin`](../source.pin). Each is applied with
`patch -p1` from the mesa source root (the `mesa-<version>/` tree inside makepkg's `$srcdir`)
by [`packages/build-overlay.sh`](../../build-overlay.sh), inserted right after the first `cd`
in the PKGBUILD's `prepare()`.

## Present

```
0001-add-a830-chip-id.patch                                          # SM8750 / a830 enablement
0002-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch  # ADOPTED WORKAROUND, not upstream
```

- **0001** (a830-specific) — register the Adreno 830 (a8xx) `chip_id`s in
  `src/freedreno/common/freedreno_devices.py` so freedreno/Turnip recognise the SM8750 GPU (adds
  the msm `0xffff4405…` and KGSL `0x4405…` variants).
- **0002** (NOT a8xx-specific — applies to all freedreno/Adreno gens) — in ir3's UBO-range
  analysis (`ir3_nir_analyze_ubo_ranges.c`), only treat a bindless UBO load as a constant range
  when the **offset** (`instr->src[1]`) is also constant, not just the resource handle.

  **It is an adopted WORKAROUND, not an upstream fix, and it is a REMOVAL CANDIDATE.** An earlier
  revision of this file called it "a general ir3 const-lowering correctness fix", which reads as
  upstream-blessed. It is not: it came from ROCKNIX (added 2026-05-12, scoped to their SM8550
  target), was never upstreamed, and **ROCKNIX removed it on 2026-08-11** as "no longer needed"
  (`ROCKNIX/distribution#3167` — an unfilled PR template: no stated reason, no test notes, no
  review).

  Checked before keeping it, 2026-08-18: upstream has **not** absorbed it — `mesa-26.2.0`, the
  version we pin, still reads `if (rsrc && nir_src_is_const(rsrc->src[0]))` at that site. But the
  surrounding analysis WAS reworked between 26.0.0 and 26.2.0 (`nir_intrinsic_has_range_base()`,
  `offset_shift`/`has_offset_shift` replacing the `load_global_ir3` special-casing), which is a
  credible reason for the workaround to have become redundant even though nobody wrote it down.

  We keep it for now because being wrong costs miscompiled shaders — a hang or corruption in a
  Vulkan title, found by a player, not by a build — and we run it on more GPUs than ROCKNIX scoped
  it to (a740, a750, a650, plus a830 via 0001).

  **DROP IT AT THE NEXT MESA BUMP.** That rebuild is being paid for anyway, and it is the natural
  moment to play the Vulkan titles and compare. If they are clean without it, delete the patch and
  its `patches:` entry in `../source.pin`; if anything hangs or corrupts, restore it and record
  what reproduced — which is the note that has been missing from this patch since May.

Patches apply `-p1` against the upstream mesa tree, in the order listed in
[`../source.pin`](../source.pin)'s `patches:` line. If a declared patch is missing or fails to
apply, `build-overlay.sh` / `makepkg` fails fast before the package is built.
