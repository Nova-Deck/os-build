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
0008-drm-synthesize-edid-for-edidless-internal-panels.patch
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
actually present. The `0002`-`0006` numbering is kept as-is rather than renumbered, so old commit
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
confirmed it on HW, which is why it is kept rather than deleted — the next focus mystery should not
have to re-derive it.

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

`0008` — synthesize a client-facing EDID for internal connectors that expose none (third-party
patch by virtudude and enjihn, not in any gamescope release; the `From:`/`Subject:` header in the
file is theirs and is kept verbatim). **Every DSI panel we ship is EDID-less** — the panel drivers
in `kernel/patches/0058` (`chipone,icna35xx`) and `0070` (`mangmi,pocket-max-panel`) set
`display_info.width_mm/height_mm` but there is no EDID blob on the connector at all — so gamescope
has had no display identity, no colorimetry, and nothing to hand a client. This builds a valid
baseline EDID out of the connector's preferred kernel mode and feeds it through the existing
`libdisplay-info` parser.

Three properties worth knowing before touching it:

* **It is panel-agnostic.** Any internal connector with no EDID blob gets one; there is no
  per-device list and nothing to add when a new board lands.
* **The synthesized EDID is deliberately plain sRGB, with no HDR block.** `GenerateSimpleEdid()`
  overwrites the template's Deck-OLED wide-gamut primaries with sRGB precisely so a generic panel
  does not get colorimetry it never had. Real panel primaries are a *separate* concern (a
  `known_displays` Lua profile keyed on `GAMESCOPE_INTERNAL_DEVICE_ID`), deliberately not part of
  this patch — see issue #77.
* **A physical EDID always wins, and the synthetic one is never committed to KMS.** It exists only
  to give the parser and clients something to read.

**On the chipone boards the size it emits is wrong — see issue #88.** The EDID's image size comes
from the connector's mm while its detailed timing comes from the preferred kernel mode, and the two
`chipone,icna35xx` descs in `kernel/patches/0058` declare landscape mm (`160x89`, `136x68`) against
a portrait `1080x1920` mode list, so the synthesized EDID contradicts itself on `ayn-thor-lite`,
`ayn-thor`, `ayaneo-pocket-ds`, `ayaneo-pocket-evo` and `ayn-odin-2-portal`. `mangmi,pocket-max-panel`
in `0070` gets it right and is the control. This does not block anything here — an EDID with a wrong
mm still beats no EDID, and SteamUI's scale does not read it — but the fix belongs in the panel desc,
not in this patch.

**Its physical-size field overlaps `0003` — MEASURED, and `0003` stays.** The synthetic EDID carries
the connector's mm (icna3520: 136x68, icna3512: 160x89, Pocket Max: 87x155), while `0003` overrides
only what `wl_output` reports, so the two channels now carry different numbers. HW-checked on an AYN
Thor Lite 2026-09-05 (dev card a296142): gamescope logs both on one line —

```
drm: GAMESCOPE_FAKE_OUTPUT_MM: wl_output 177x100 mm (connector reported 136x68 mm)
```

— and **SteamUI's scale is unchanged**, so the client did not start preferring the EDID it had never
previously been given.

**Which channel Steam actually reads was then measured directly, not inferred.** Setting
`NOVADECK_GAMESCOPE_FAKE_OUTPUT_MM=88x50` in `/etc/novadeck/session.conf` (sourced after device-env,
writable /etc overlay, no rebuild) and rebooting — half of `177x100` at the same aspect, so 21.6
px/mm instead of 10.8 — made the UI **much bigger**, i.e. Steam scales up to hold physical size as
DPI rises. So `wl_output` is read and `0003` is the lever; the panel-driver mm arriving via the EDID
is **inert for scale**. Repeat that one-reboot test rather than re-deriving this.

Cross-checked on a MANGMI Pocket Max, whose driver mm (`87x155`) are *coherent* with its portrait
mode where the icna35xx values are not: same `177x100`, and **the same UI layout in pixels**, despite
an EDID that is self-consistent where Thor Lite's contradicts itself. That is the control for #88 —
the transposed mm have no user-visible effect.

Say *pixels*, not "density": the two panels are physically different sizes (Pocket Max is the bigger
one), so identical pixel layout means UI elements are physically **larger** on Pocket Max. That is
the intended consequence of `177x100` being a fleet-wide constant — it buys every board the same
layout in pixels, deliberately *not* the same physical size. It is also what makes this a sharp
control: had Steam read the per-board EDID mm instead, Thor Lite would sit at 1920/136 = 14.1 px/mm
and Pocket Max at 1920/87 = 22.1, a 57% difference that could not be mistaken for identical. Both boards also log the parsed primaries as
`r 0.639648 0.330078 / g 0.299805 0.599609`, i.e. sRGB to within 10-bit EDID quantisation,
confirming `GenerateSimpleEdid()` really does overwrite the template's Deck-OLED wide-gamut values.

Third board, AYANEO Pocket ACE — the non-OLED control, and the one that stresses paths the two 16:9
OLED boards do not: SM8550, a **3:2 `1080x1620`** mode, a **per-board** `150x100` rather than the
fleet constant, and a **single** refresh rate.

```
drm: Generated synthetic EDID for EDID-less internal connector DSI-1 from mode 1080x1620
drm: GAMESCOPE_FAKE_OUTPUT_MM: wl_output 150x100 mm (connector reported 63x95 mm)
```

Scale correct. Four things this one closes: the EDID encoder handles a non-16:9 detailed timing
(it *rejects* timings EDID cannot represent, so this was a real unknown); the per-board override
path works and not just the shared value; `ValidRefreshRates: 60` stays single, so the synthetic
EDID did not invent modes through the dynamic-rate fallback this patch also touches; and the full
primaries log out as sRGB including `w 0.312500 0.329102`, D65.

It also confirms the density convention independently — `1620/150` and `1080/100` are both 10.8
px/mm, the same figure `177x100` gives the 16:9 boards, so "hold the vertical 100 mm and derive the
width" really does produce matching pixel layout across a different aspect. And its mm are coherent
(`63x95` against a portrait `1080x1620`), making it a second correct board either side of the
chipone transposition in #88.

Do **not** retire `0003` or `NOVADECK_GAMESCOPE_FAKE_OUTPUT_MM` on the strength of this patch. They
answer different questions: `177x100` is a fleet-wide UI-density constant (16 of 20 device confs
share it, for a uniform ~10.8 px/mm), not a panel size, and the Steam client stopped honouring panel
mm for gamepad-UI scale in 2026-07. See #77 for the full refutation.

Carried with one deviation from the patch as published: the `tests/meson.build` hunk was re-rolled
against 3.16.28 (whose test list already carries `test_utils_parsers.cpp` / `test_utils_string.cpp`,
so the original context did not apply), and while re-rolling it we added the missing
`test('edid', gamescope_tests, args: ['[edid]'])` registration — without it the four `[edid]` cases
in `tests/test_edid.cpp` build but `meson test` never runs them. Everything under `src/` is
byte-for-byte as published.

**Those tests do not run in our build, and have not been run.** `../PKGBUILD` passes
`-Denable_tests=false` (a release image has no use for unit tests, and they are pure build cost
under arm64 emulation), so `subdir('tests')` is never entered and `tests/test_edid.cpp` is never
compiled. What our build proves is that the patched `src/` compiles; the EDID encoder's *behaviour*
is so far vouched for only by its authors. To actually exercise it, rebuild once with
`-Denable_tests=true` and run `meson test -C build edid`. Worth doing before the HW measurement
below, since a bad DTD encoding and a bad `wl_output` mm look identical from the SteamUI side.

(A patch that once held the `0003` slot swapped `wl_output`'s `phys_width/phys_height` on the rotated
path as a coherence fix, but HW showed it does NOT move SteamUI's auto-scale — the swap is
diagonal-invariant and Steam keys off mm *magnitude*; the actual UI-scale fix is the panel-mm bump in
the Pocket S2 panel patch — which was itself later overturned: HW showed the Steam client stopped
honouring panel mm for gamepad-UI scale entirely, and `GAMESCOPE_FAKE_OUTPUT_MM` above is the lever
that replaced it. **That `kernel/patches/0062` citation is stale** — renumbering moved 0062 onto the
SY7758 backlight driver, which has nothing to do with panel size. It was dropped once the incremental overlay build made a gamescope-only
recompile cheap, and the number was later reused by the `GAMESCOPE_FAKE_OUTPUT_MM` patch above.)

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
