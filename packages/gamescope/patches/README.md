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
0003-drmbackend-fake-output-mm.patch
0004-fps-limit-atom-persist.patch
0005-steamcontrolled-steam-focus-fallback.patch
0006-focus-candidate-instrumentation.patch   (present but NOT in source.pin — diagnostic, see below)
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

`0003` — `GAMESCOPE_FAKE_OUTPUT_MM` env override for the reported output physical size (upstream
contribution by tiopex). This is the lever that fixes SteamUI's auto-scale on our panel — *not* the
`wl_output` mm swap described below.

`0004` — make the legacy `GAMESCOPE_FPS_LIMIT` X atom actually stick. Our arm64 Steam client never
connects to gamescope's Wayland socket, so that atom is the only channel QuickAccess's frame cap has;
upstream never exercises the path because Valve's x86 client drives the cap over `gamescope_control`.

`0005` — let a Steam window take **global** focus under `SteamControlled`. `--steam` selects that
strategy, which withholds the generic `vecPossibleFocusWindows[0]` fallback from the global pass and
leaves `focusControlWindow` / `ctxFocusControlAppIDs` as the only routes to focus — both published by
Steam, so neither exists while the bootstrapper is up. The client-update dialog is `window_is_steam()`
but `appID == 0`, so it matches neither, never gets focus, and the panel stays black for the whole
update (measured 13.5 min, zero flips). Adds a narrow last-resort route: global pass only,
`SteamControlled` only, only when focus is already NULL, and only ever selects a Steam window — never
a game — so a live client's choice can't be overridden. Full derivation in the patch header.

`0006` — **diagnostic, kept in the tree but deliberately ABSENT from `source.pin`'s `patches:` line,
so a stock build does not carry it.** It logs why each window is or is not a focus candidate, which
one wins, and the winner's commit-queue state. This is the instrument that localized `0005` and then
confirmed it on HW, which is why it is kept rather than deleted — the next focus mystery should not
have to re-derive it.

To use it: add it back to `source.pin`, rebuild, and `export GAMESCOPE_DEBUG_FOCUS=1` in
`/etc/novadeck/session.conf` (the only way to catch a defect at boot, before SSH is up), or
`gamescopectl debug_focus_candidates 1` live once a session is reachable. Output goes to
`~/.local/share/sddm/wayland-session.log` — NOT the journal — so grep that for `cand:`.

**While it is in `source.pin`, `fetchlock.sh` reports the gamescope row as built from UNADOPTED
sources.** That is expected on a dev card and is exactly why it must come back out, with a
`make relock`, before any commit or release build.

(A patch that once held the `0003` slot swapped `wl_output`'s `phys_width/phys_height` on the rotated
path as a coherence fix, but HW showed it does NOT move SteamUI's auto-scale — the swap is
diagonal-invariant and Steam keys off mm *magnitude*; the actual UI-scale fix is the panel-mm bump in
`kernel/patches/0062`. It was dropped once the incremental overlay build made a gamescope-only
recompile cheap, and the number was later reused by the `GAMESCOPE_FAKE_OUTPUT_MM` patch above.)

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
