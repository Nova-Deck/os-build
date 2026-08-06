# gamescope patches

novadeck patches applied on top of the local gamescope PKGBUILD source (Valve gamescope
`3.16.25`, see [`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the gamescope source
root (the `gamescope/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-composite-rotation-pr2228.patch
0002-sanitize-nightmode-atom.patch
```

`0001` — rotate the portrait-native Pocket S2 panel in gamescope's **GPU composite** step
(the msm DPU cannot `ROTATE_90` a LINEAR plane; root cause in
`docs/bringup-phase2.md` step 1e). This is upstream PR
[#2228](https://github.com/ValveSoftware/gamescope/pull/2228): the scene stays in logical
(landscape) space and only the final store coordinate is rotated, so sampling/blending/input/
cursor/EDID stay coherent. It replaces the earlier ROCKNIX `--use-rotation-shader` patch and
needs no launch flag: gamescope reads the panel orientation from the DRM connector (our DTS
declares `rotation=<90>`) and auto-engages compositor rotation when the primary plane can't
rotate at scanout (`--force-composition-rotation` can force it; we rely on auto-detect — see
`session/usr/bin/novadeck-session`).

`0002` — sanitize the night-mode color atom.

(A former `0003` swapped `wl_output`'s `phys_width/phys_height` on the rotated path as a coherence
fix, but HW showed it does NOT move SteamUI's auto-scale — the swap is diagonal-invariant and Steam
keys off mm *magnitude*; the actual UI-scale fix is the panel-mm bump in `kernel/patches/0062`. It
was dropped once the incremental overlay build made a gamescope-only recompile cheap.)

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
