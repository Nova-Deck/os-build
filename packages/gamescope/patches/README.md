# gamescope patches

novadeck patches applied on top of the local gamescope PKGBUILD source (Valve gamescope
`3.16.28`, see [`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the gamescope source
root (the `gamescope/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0002-sanitize-nightmode-atom.patch
0003-drmbackend-fake-output-mm.patch
0004-fps-limit-atom-persist.patch
0005-steamcontrolled-steam-focus-fallback.patch
0006-focus-candidate-instrumentation.patch   (present but NOT in source.pin — diagnostic, see below)
0007-vendor-wayland-protocols-wrap.patch
0008-focus-title-beats-steam-baselayer.patch
```

`0001` — **GONE, and deliberately not replaced: it is UPSTREAM as of 3.16.28.** It rotated the
portrait-native Pocket S2 panel in gamescope's **GPU composite** step (the msm DPU cannot
`ROTATE_90` a LINEAR plane; root cause in `docs/bringup-phase2.md` step 1e), and it was upstream PR
[#2228](https://github.com/ValveSoftware/gamescope/pull/2228), merged verbatim as `38fb50fc`
("Add composited output rotation for displays that can't rotate at scanout"). Verified before
dropping: the shipped tree carries the same `drm_plane_supported_rotations()` helper and the same
`g_bForceCompositionRotation || !bScanoutCanRotate` condition our patch tested, so the autodetect
behaviour our session depends on is byte-for-byte the one we had. Still needs no launch flag —
gamescope reads the panel orientation from the DRM connector (our DTS declares `rotation=<90>`) and
auto-engages compositor rotation when the primary plane can't rotate at scanout;
`--force-composition-rotation` remains available for hardware that advertises a rotation it cannot
actually present. The `0002`-`0008` numbering is kept as-is rather than renumbered, so old commit
messages and memories still resolve.

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
confirmed it on HW, and that caught the baselayer-appid reorder `0008` fixes, which is why it is kept
rather than deleted — the next focus mystery should not have to re-derive it.

To use it: add it back to `source.pin`, rebuild, and `export GAMESCOPE_DEBUG_FOCUS=1` in
`/etc/novadeck/session.conf` (the only way to catch a defect at boot, before SSH is up), or
`gamescopectl debug_focus_candidates 1` live once a session is reachable. Output goes to
`~/.local/share/sddm/wayland-session.log` — NOT the journal — so grep that for `cand:`.

`0007` — declares a `subprojects/wayland-protocols.wrap` so meson vendors wayland-protocols. Needed
by the 3.16.28 bump: it moved the wlroots submodule to 0.20, which requires
`wayland-protocols >= 1.47`, and the pinned holo snapshot ships 1.45 — the build failed at configure
time. Paired with `wayland-protocols` in `-Dforce_fallback_for` in `../PKGBUILD`; **both halves are
required**, the wrap alone does nothing while a system copy is visible. Cheap to carry because
wayland-protocols is data (XML protocol definitions + a pkg-config file), not a library we link.
Full rationale, and why this beats bumping `build/snapshot.pin`, is in the patch header.

**The 3.16.28 dependency ladder, and why it stops at one patch.** gamescope 3.16.26+ needs
wlroots 0.20, which needs wayland-protocols ≥ 1.47, and the pinned holo base ships 1.45. That is the
whole problem, and `0007` is the whole fix — *provided the vendored protocols are pinned to 1.48*.
Reaching for the newest (1.49) adds two more links that do not otherwise exist: 1.49 uses a `frozen=`
attribute the base's wayland-scanner 1.24.0 cannot parse, which forces vendoring a newer wayland for
its scanner, which then fails against gamescope's own `protocol/meson.build`
(`get_variable(pkgconfig:)` cannot read an InternalDependency). **Take the oldest version that clears
the floor, not the newest that exists** — the rule that would have saved three builds here.

There is no intermediate gamescope tag that avoids this: 3.16.25 is the last release on wlroots 0.19,
and 3.16.26 — the first with composite rotation upstream — is already on 0.20. Any version new enough
to let us drop `0001` needs `0007`.

**While it is in `source.pin`, `fetchlock.sh` reports the gamescope row as built from UNADOPTED
sources.** That is expected on a dev card and is exactly why it must come back out, with a
`make relock`, before any commit or release build.

`0008` — stop Steam's own window from outranking a native-Wayland title. Under `SteamControlled`,
`pick_primary_focus_and_override()` takes the first `GAMESCOPECTRL_BASELAYER_APPID` entry any
candidate carries, and Steam publishes `769` (itself) ahead of a Lepton title's appid — so an Android
guest that maps a healthy `xdg_toplevel` renders forever behind Steam's Big Picture window. Steam
demotes the title because `GAMESCOPE_FOCUSABLE_APPS` is built from XWayland windows only, so it is
never told the title has a window: the list order carries no information about native-Wayland
windows. The patch defers a Steam-client match and lets an XDG window matching a later published
appid take it; an XWayland match restores the deferred Steam window, so XWayland-only sessions and
both local passes are bit-identical. Trade-off and the real fix (report XDG windows to Steam) in the
patch header.

(A patch that once held the `0003` slot swapped `wl_output`'s `phys_width/phys_height` on the rotated
path as a coherence fix, but HW showed it does NOT move SteamUI's auto-scale — the swap is
diagonal-invariant and Steam keys off mm *magnitude*; the actual UI-scale fix is the panel-mm bump in
`kernel/patches/0062`. It was dropped once the incremental overlay build made a gamescope-only
recompile cheap, and the number was later reused by the `GAMESCOPE_FAKE_OUTPUT_MM` patch above.)

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
