# gamescope patches

novadeck patches applied on top of the local gamescope PKGBUILD source (Valve gamescope
`3.16.23.2`, see [`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the gamescope source
root (the `gamescope/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-composite-rotation-pr2228.patch
0002-sanitize-nightmode-atom.patch
0003-rotate-output-phys-dims.patch
```

`0001` — rotate the portrait-native Pocket S2 panel in gamescope's **GPU composite** step
(the msm DPU cannot `ROTATE_90` a LINEAR plane; root cause in
`devices/sm8650/bringup-phase2.md` step 1e). This is upstream PR
[#2228](https://github.com/ValveSoftware/gamescope/pull/2228): the scene stays in logical
(landscape) space and only the final store coordinate is rotated, so sampling/blending/input/
cursor/EDID stay coherent. It replaces the earlier ROCKNIX `--use-rotation-shader` patch and
needs no launch flag: gamescope reads the panel orientation from the DRM connector (our DTS
declares `rotation=<90>`) and auto-engages compositor rotation when the primary plane can't
rotate at scanout (`--force-composition-rotation` can force it; we rely on auto-detect — see
`session/usr/bin/novadeck-session`).

`0002` — sanitize the night-mode color atom.

`0003` — report a **landscape physical size** on the composite-rotation path. `0001` transposes
the logical output to landscape when `g_bRotated`, but `wlserver_set_output_info()` still gets the
connector's raw **portrait** `mmWidth/mmHeight`, so `wl_output` advertises a landscape resolution
over a portrait physical size. The EDID that would carry the swap is absent (internal DSI panels
ship no EDID; `PatchEdid()` bails on empty input), so this incoherent physical size is the only one
Steam sees — and SteamUI's **automatic UI scale** derives a wrong, asymmetric DPI from it. `0003`
swaps `phys_width/phys_height` when `g_bRotated`. Intended as a coherence fix; **HW showed it does
NOT move SteamUI's auto-scale** (the swap is diagonal-invariant, and Steam keys off mm *magnitude* —
the actual UI-scale fix is the panel-mm bump in `kernel/patches/0062`, see `TODO.md`). Kept for now
as a defensible coherence change, slated for removal in a later session.

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
