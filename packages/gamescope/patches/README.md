# gamescope patches

novadeck patches applied on top of the holo gamescope PKGBUILD source (Valve gamescope
`3.16.17`), in the order listed by `patches:` in [`../source.pin`](../source.pin). Each is
applied with `patch -p1` from the gamescope source root (the `gamescope/` checkout inside
makepkg's `$srcdir`) by [`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-rotate-portrait-panel-in-composite.patch
```

Rotate the portrait-native Pocket S2 panel in gamescope's **GPU composite** step and scan out
a `ROTATE_0` buffer, instead of asking the msm DPU for a plane `ROTATE_90` it cannot do on
LINEAR buffers (root cause in `devices/sm8650/bringup-phase2.md` step 1e). Tested on ROCKNIX.

Drop the patch file here with that exact name (or rename it and update `source.pin`'s
`patches:` line). **Until the patch is present, `make overlay` / `make base` fail fast** with
a clear "missing patch" message from `build-overlay.sh`.
