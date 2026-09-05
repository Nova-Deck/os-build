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
0009-drm-known-display-profiles-for-edidless-panels.patch
0010-drm-compose-gamma22-hdr-without-hw-color-management.patch
0011-wsi-filter-hdr-formats-by-underlying-support.patch
0012-color-scale-sdr-white-on-gamma22-hdr-output.patch
0013-expose-client-sampleable-formats.patch
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

`0009`-`0013` — **the HDR half of #77**, same third-party series as `0008` (virtudude and enjihn),
same verbatim-with-attribution treatment. `0008` gives an EDID-less panel an *identity*; these give
it *capability*. They only do anything on a board that declares `NOVADECK_PANEL_HDR_NITS`, and on
every other board the session's gamescope argv is byte-identical to before they existed.

* `0009` passes connector name, `GAMESCOPE_INTERNAL_DEVICE_ID`, internal-ness and *has-physical-EDID*
  into `known_displays` `matches()`, so a Lua profile can claim an EDID-less panel. This is the
  hinge: our panels carry no colorimetry on the wire, so the profile is the only place real primaries
  and a peak luminance can come from. Ours live in
  `rootfs/overlay/usr/share/gamescope/scripts/10-novadeck/`, keyed by **panel** rather than by board.
* `0010` stops direct scanout for HDR when the DPU has no hardware colour management. On a gamma-2.2
  HDR panel even a single PQ layer has to go through the Vulkan pipeline to reach the panel's native
  encoding. **This is the one with a real perf cost** — HDR frames can no longer take the scanout
  fast path — so measure a title with HDR on *and* off before believing a regression is elsewhere.
* `0011` advertises only those synthetic PQ/scRGB surface formats whose `VkFormat` the underlying
  surface actually supports, so a client cannot pick one the driver will reject.
* `0012` makes the SDR-on-HDR white level actually apply on a gamma-2.2 HDR output, by scaling SDR
  input against the panel peak. Without it that brightness control is a no-op on exactly our panels.
* `0013` lets the inner Wayland server advertise DMA-BUF formats Vulkan can *sample* even when KMS
  planes cannot scan them out — required once `0010` routes HDR through composition.

**HW result, AYN Thor Lite, dev card 4ea9467, 2026-09-05.** The chain works end to end:

```
drm: Got known display: novadeck_internal_amoled (novadeck internal AMOLED)
drm: [colorimetry]: r 0.680000 0.320000          <- profile primaries, not the EDID's sRGB
GAMESCOPE_DISPLAY_SUPPORTS_HDR = 1
GAMESCOPE_DISPLAY_HDR_ENABLED  = 1
```

`os.getenv` really is reachable in gamescope's Lua sandbox, so the peak reaches the profile from the
device conf with no Lua edit. The dual-screen gate holds on real connector names: `DSI-2` (the
`ch13726a` secondary) gets a synthetic EDID but **no** profile match and keeps its own sRGB
primaries.

Two titles judged by eye, deliberately opposite in content:

* **Trine Enhanced Edition** (bright, painterly, saturated) — good: no oversaturation, no highlight
  clipping, no full-screen dimming. Tests the assumed wide-gamut primaries hardest.
* **Black the Fall** (dark, high-contrast, Unity 2017) — **blacks stay deep**, highlights probably
  punchier. This is the title that tests the ITM floor, and the failure it exists to catch — shadows
  lifted milky, greys where blacks should be — did **not** happen. The highlight impression is
  recorded as the operator gave it, unconfirmed: without a side-by-side it is not judgeable by eye.

Between them they cover the two ways ITM usually goes visibly wrong on a panel like this, and
neither showed.

**What that does NOT establish.** One title, judged by eye, is not colorimetric validation: it says
the assumed primaries and the inherited 650 are not obviously wrong, not that they are right. Trine
is an SDR 2009 game, so it exercised the **ITM** path and not native HDR output. Nothing has been
looked at on Thor, Pocket EVO, Pocket DS, Odin 2 Portal or Pocket Max — and Pocket Max and the
icna3512 boards carry a different peak (800) from the one that was actually looked at.

**There is no HDR toggle in the Steam UI, and there cannot be one on this client.** The client's HDR
row is gated on `GamescopeService` state, which arrives over the gamescope_control **Wayland**
protocol; our arm64 client never connects to that socket (verified: only `gamescope-wl` holds it,
even though Steam has `GAMESCOPE_WAYLAND_DISPLAY` in its environment). The row returns `null` before
it ever checks display capability, which is why it is absent rather than greyed out. Same
architectural gap that forced `0004` to drive the fps cap through an X atom. Consequence: HDR is
**on permanently** wherever a peak is declared, and the only off switch is
`NOVADECK_PANEL_HDR_NITS=0` in `/etc/novadeck/session.conf`. `STEAM_GAMESCOPE_HDR_SUPPORTED` is set
but is **inert** — that string does not appear anywhere in this client build; it is kept because
Valve's own gamescope sets it and the client may one day read it.

**Always-on HDR costs no measurable frames — A/B'd, not just argued.** `0010` forces composition
whenever HDR output is enabled, which sounded like it might make every frame more expensive on boards
that cannot turn HDR off. It does not, and the reason is that composition was **already mandatory on
every frame**: each panel is portrait-native and driven landscape, and the msm DPU cannot `ROTATE_90`
a LINEAR plane, so gamescope has always rotated in the GPU composite step. HDR adds colour maths
inside a pass that already runs, not a new pass.

Measured on the Thor Lite (SM8250 / Adreno 650) with Trine Enhanced Edition under Proton, which is
GPU-bound on this board and so cannot hide a cost behind idle headroom: **same fps with HDR on and
off**. The off arm was verified to be a genuinely different configuration rather than the same one
twice — no HDR flags in gamescope's argv, `Got known display` never logged, colorimetry back to the
synthetic EDID's sRGB `r 0.639648`, and `GAMESCOPE_DISPLAY_SUPPORTS_HDR` at 0.

Caveats on that reading: one title, one board, MangoHud read by eye rather than logged, and a
handheld throttles, so "same" means within a couple of fps and not literally zero. It settles the
ship-default question — HDR staying on by default is defensible — without proving the cost is exactly
nil. (`GAMESCOPE_DISPLAY_HDR_ENABLED` stays 1 in the off arm and is not a contradiction: that atom is
the *preference* convar, "enabled if it is available", while `SUPPORTS_HDR` is the capability that
actually gates.)

**Adaptations, all forced.** `0010`'s call site had to change or it would not compile: 3.16.28 moved
to `pFrameInfo->layers.count()` / `.get( 0 )` where the published patch used `layerCount` and
`layers[0]`, and `count()` returns `int` against a `uint32_t` parameter, so the port casts explicitly.
The `tests/meson.build` hunk in `0009`, `0010`, `0011` and `0013` was re-rolled for the same reason as
`0008`'s. While re-rolling, two registrations were **added** that the originals omit — the `[display]`,
`[drm]` and `[dmabuf]` tags were never registered, and `0011` builds a separate
`test_wsi_hdr_surface_formats` executable but then registers `gamescope_tests` under its name, so the
new binary would never have run. Everything else under `src/` and `layer/` is byte-for-byte as
published.

**Which titles can reach native HDR — and the two x86 paths are NOT the same.** The gamescope WSI
layer, which is what advertises PQ/scRGB swapchain formats to a client, ships aarch64-only. What
that excludes is narrower than it first appears, because we run x86 code by two independent routes:

* **Proton (arm64 build) — the layer LOADS, and native HDR is reachable.** Proton's WoW64 FEX
  emulates the game's x86 code but runs the graphics stack natively, so DXVK and the Vulkan client
  are aarch64 and the layer attaches normally. HW-observed on an AYN Thor Lite 2026-09-05, Trine
  Enhanced Edition under `proton-cachyos-11.0-arm64`: `libVkLayer_FROG_gamescope_wsi_aarch64.so` is
  mapped in `trine1_game.exe`, whose exe is the **aarch64** `wine-preloader`, and the layer logs
  `server hdr output enabled: true` / `hdr formats exposed to client: true`. So `0011` and `0013`
  are load-bearing for the Proton catalogue, not dead weight. A title still has to actually emit
  HDR — a DX11/12 game needs `DXVK_HDR=1`, which we do not currently set.
* **A native x86 Linux binary under system FEX — the layer does NOT load.** There the Vulkan client
  is x86 and has nothing to attach; `ENABLE_GAMESCOPE_WSI` is inert. Those titles get ITM only.

**`--hdr-itm-enabled` covers everything either way**, because it inverse-tone-maps SDR content in the
compositor after the game has rendered — independent of the game's Vulkan path, and the only thing
that happens for an SDR title like Trine.

This paragraph previously claimed no FEX/Proton title could reach native HDR. That was wrong: it
generalised the system-FEX result to Proton, which is the opposite case. The two x86 paths have to
be named separately every time, because the answer differs between them.

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
