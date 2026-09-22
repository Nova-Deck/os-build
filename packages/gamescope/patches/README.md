# gamescope patches

novadeck patches applied on top of the local gamescope PKGBUILD source (the Valve gamescope tag
named by `pkgver` in [`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the gamescope source
root (the `gamescope/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-drmbackend-rotated-output-max-height.patch
0002-sanitize-nightmode-atom.patch
0003-drmbackend-fake-output-mm.patch
0004-fps-limit-atom-persist.patch
0005-steamcontrolled-steam-focus-fallback.patch
0006-focus-candidate-instrumentation.patch   (present but NOT in source.pin — diagnostic, see below)
0007-vendor-wayland-protocols-wrap.patch
0014-drm-color-manage-direct-scanout-via-the-dpu-ctm.patch
0015-color-p3-red-is-wide-gamut.patch
0016-steamcompmgr-arm64-virtual-white.patch
0017-color-neutral-virtual-white-keeps-scanout.patch
0018-drm-sdr-color-management-through-the-dpu-output-luts.patch
```

`0008`-`0013` are **retired** (see below). The numbering is kept as-is rather than compacted, so
older commit messages and memories still resolve.

`0001` — **REUSED 2026-09-12 for `--rotated-output-max-height`** (the number was freed when the
original 0001 went upstream; that history is kept below). Adds an opt-in flag that clamps the
LOGICAL output height when a panel is scanned out rotated, aspect-preserving with both axes even,
and scales the CRTC rects back up to the real mode so the plane upscales for free. `SRC_W/H` stay
at texture size. 90/270 only — 0/180 do not transpose, so the rotator limit does not apply.

Why: the DPU inline rotator caps the PRE-ROTATION source at **1088 lines**, but the plane
advertises `ROTATE_90` as a STATIC capability it cannot qualify per-mode. On Pocket S2 (1440 wide)
gamescope therefore believes it can rotate at scanout, stops compositing the rotation, and every
atomic commit is refused — a black panel. Rendering the session at 1920x1080 instead of 2560x1440
puts every layer under the cap, so the board keeps scanout rotation instead of paying a GPU
composite per present. HW-validated on Pocket S2 2026-09-12: idle UI and in-game both **0 ms**
gamescope GPU (was 21% in game), **-834 mW**, the game→UI transition no longer wedges, touch still
lands correctly (virtual-keyboard test), and the operator could not distinguish the upscaled UI
from native. Cost: UI at 1080p upscaled to a 1440p panel, and games cap at 1080p.

**`drm_set_refresh()` closed on Pocket FIT 2026-09-12**, from the card built off this tree. Forced
the clamp on a board that does not need it (`--rotated-output-max-height 720`, logical output
1920x1080 -> 1280x720) and drove mode changes with a game running: **three modesets, 144 -> 120 ->
144 Hz**, each re-applying the clamp, each landing on a real rate from the panel's
`{60, 90, 120, 144}`, panel lit throughout, plane still `1280x720 / rotation=8`, zero underruns and
zero rotator rejections. That is the path that would have broken: 1280x720 matches no mode on this
connector, so without the fix the first mode change would have generated a timing the panel cannot
display. Not shown: 60 or 90 specifically — gamescope picks the rate by its own policy and ignored
the requested values, so only the transitions it chose could be observed.

**Regression check, same card, same board, stock config:** the gate (`native width > 1088`) does not
fire on the FIT's 1080-wide panel, gamescope gets NO flag, the clamp log is empty, and planes stay
`1920x1080 -> 1080x1920 rotation=8`. The patch is invisible on boards that do not need it.

Set from `rootfs/overlay/etc/novadeck/session.conf` on panels over the cap. An unknown argument
makes gamescope EXIT, so if this patch is ever dropped, that session.conf line must change back to
`--force-composition-rotation` in the same commit.

---

The ORIGINAL `0001` — **GONE, and deliberately not replaced: it is UPSTREAM as of 3.16.28.** It rotated the
portrait-native Pocket S2 panel in gamescope's **GPU composite** step (the msm DPU cannot
`ROTATE_90` a LINEAR plane; root cause in `docs/archive/bringup-phase2.md` step 1e), and it was upstream PR
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

`0008`-`0013` — **RETIRED 2026-09-14 when HDR was dropped (issue #93).** The EDID-synthesis +
HDR series (third-party, by virtudude and enjihn) is gone from the tree and from `source.pin`, along
with `rootfs/overlay/usr/share/gamescope/scripts/10-novadeck/` and `tests/test-display-profile.sh`.

**Why, in one line: `--hdr-itm-enabled` maps nothing.** In gamescope 3.16.28 the shader branch is
guarded by `c_itm_enable`, specialization constant 7, which is only ever set from
`PipelineInfo_t::itm_enable` — and **no call site passes it**, so it is permanently false and
`bt2446a_inverse_tonemapping()` can never execute. `g_bHDRItmEnable` has exactly three consumers in
the whole tree, all of them `bNeedsFullComposite |= g_bHDRItmEnable`. The flag's only real effect is
to force a full Vulkan composite on every present. Verified against the pristine 3.16.28 source —
this is upstream behaviour, not something our patches broke. Confirmed by eye on a Pocket Max:
toggling `GAMESCOPE_HDR_ITM_ENABLE` live on a dark scene in Trine changed nothing visible.

That forced composite costs any board with a working DPU inline rotator its scanout rotation:
**~0.2 W idle and 650-830 mW in game**, measured. Paying that for a no-op ended the argument.

`--hdr-enabled` (output HDR, the gamma-2.2 path) *did* change the image — a visibly lifted black
floor — but it was never judged worth its own composite cost, and with ITM inert there was no reason
to keep the pair. `0011` and `0013` went with them: both exist to feed HDR formats to clients.

**Consequence for `0014`, `0015` and `0018`: all three were RE-ROLLED**, because they had been built
on top of the series and carried HDR-introduced context — `create_color_mgmt_luts`'s
`bTraditionalHDROutput` parameter, the `DrmHdrOutputRequiresVulkanComposition` call site, and
test-list entries for tests that no longer exist. Their intent is unchanged; the hunks now sit on the
pristine signatures. Regenerated with `git diff` against a clean 3.16.28 checkout, never hand-edited
— see the per-patch RE-ROLLED notes in their headers. `0018`'s test additions went with the series
because every one of them tested `DrmHdrOutputRequiresVulkanComposition` itself.

`0015` — **make `BIsWideGamut()` inclusive at the threshold.** It uses the red primary as its
sentinel and wants `r.y < 0.320f`. DCI-P3 red is exactly `(0.680, 0.320)`, which is what the
(now-retired) `novadeck.internal-amoled.lua` display profile declared for the whole DDIC family, so
every one of our panels landed on the wrong side by a rounding-free tie and was classified
**narrow**. The profile is gone with `0008`-`0013`, but the off-by-a-tie is a general fix worth
keeping: any panel whose red sits exactly on the threshold hits it.

**It does not make the slider dead — it points it at the wrong branch,** and the difference matters
when reading the symptom. `buildSDRColorimetry()` has two, and both respond to the slider:

| branch | SDR *source* colorimetry the slider sweeps | saturation remap |
|---|---|---|
| narrow (what we got) | panel native → **generic wide gamut** | full blend to unit cube from 70% sat |
| wide (what we want) | **Rec.709** → panel native | none (`blendAmountMax = 0`) |

So on a panel that genuinely has P3 to spend, the slider was declaring the content *wider than the
display* and then spending itself compressing the excess back in, and the panel's own measured
primaries were never an endpoint. At the shipped default of 0.5 that is the worst case: source =
generic wide gamut plus the full smooth remap, where it should be halfway between 709 and the panel
with no remap. One character, plus a `[color]` test that pins the boundary so a future re-roll
cannot quietly reintroduce it. Note the test declares `BIsWideGamut()` itself: the function is not
in `color_helpers.h`, and adding it there is a bigger change than this deserves.

**Testing this on hardware needs a COMPOSITED frame.** `calcScanoutLinearScale()` (patch `0014`)
deliberately ignores the gamut mapping and lets the frame scan out, so on the direct-scanout path
the wideness slider has no effect *either way* and an A/B there shows nothing. Use a board that
composites (Pocket Max) or force one with `GAMESCOPE_COMPOSITE_FORCE=1`.

`0016` — **recover the virtual white point's `y` on arm64.** `GAMESCOPE_DISPLAY_VIRTUAL_WHITE` is the
colour temperature slider's wire format and the arm64 Steam client packs it through **the same Xlib
`format=32` LP64 fault documented on `0002`**: it hands `XChangeProperty` a `float[2] {x, y}` — 8
bytes — and Xlib reads two 8-byte longs off it, transmitting the low half of each. Element 0 is `x`;
element 1 is an out-of-bounds read of the client's stack.

This one is worse than `0002`'s in a specific way. `calcColorTransform()` engages the chromatic
adaptation on `destVirtualWhite.y > 0.01f`, so the overread is not merely ignored: a large positive
stack value builds an adaptation to a **nonsense white point** and a small or negative one disables
the slider outright, and `0002`'s investigation showed that element re-rolling per install rather
than sitting at a constant. Both failures look like a panel problem from the outside.

The pair is recoverable because Steam does not choose it freely — both coordinates come off the CIE
daylight locus and the client's 6500 K `x` is D65's — so `x` alone fixes `y` to within 0.002 across
the slider's range via the locus quadratic `-3x² + 2.87x - 0.275`. Element 1 is taken whenever it
decodes as a plausible daylight `y` (0.20–0.45), which is what a **fixed** client would send, and
derived otherwise. That makes the workaround self-disarming instead of something to remember to
remove. `#if defined(__aarch64__)` — this is a defect in one client build, not in the property.

Unlike `0002`'s hue, nothing here is destroyed beyond recovery: `x` alone determines the answer, so
the slider genuinely works after this rather than merely stopping doing harm.

**Knowing this costs a frame is part of the deal.** `calcScanoutLinearScale()` returns `nullopt`
when a virtual white is set and is not the panel's own — a white-point adaptation is a real matrix
and the DPU cannot carry it — so a colour temperature anywhere off neutral **forces a composite**
and gives up direct scanout for as long as it is set. That is correct rather than regrettable; the
alternative is applying it wrong. It also made this patch a regression until `0017` landed — see
there, and read it before touching either.

**Do NOT use the live plane count as the test signal for this** (an earlier draft of this file
said to, and it is wrong). On a single-layer Steam UI, a composited frame and a directly scanned-out
one BOTH present exactly one plane with `rotation=8`, because the composite output is itself scanned
out rotated. The two are indistinguishable that way. The discriminator is the CRTC's **CTM**: with
night mode on it reads a non-identity diagonal on the scanout path and snaps to identity the moment
a frame composites. Plane count only separates the two when there are genuinely two layers to scan
out, which is where the "2 planes" readings elsewhere in this project come from.

`0017` — **a virtual white equal to the panel's own white keeps direct scanout.** `0014`'s
expressibility test refuses whenever *any* virtual white point is set. Correct for an adaptation
between two different white points; wrong for the one that ships, because the Steam client publishes
the panel's own white whenever the colour temperature slider sits at neutral — where it sits out of
the box — and adapting a white point to itself is the identity, which is a diagonal and therefore
expressible. Without this, the default configuration composited **every frame** to apply a transform
that does nothing.

**It was latent in `0014` from the start and `0016` is what made it reachable**: before `0016` the
arm64 client's `y` arrived as a zero overread, so the gate never fired. Any correctly-packing client
would have tripped it too. Caught on Pocket ACE 2026-09-13 — night mode at 0.5/0.95 with the client's
own virtual white left the CTM at identity, and clearing the virtual white *alone* brought back
`diag(1.0, 0.72315, 0.52500)`, matching `hsv_to_rgb(25°, 0.475, 1.0) = (1.0, 0.72292, 0.525)` to 2e-4.

**The tolerance is measured, and both bounds are pinned in a test.** An exact comparison does not
work: on a board with no display profile the panel white is the synthetic EDID's 10-bit quantised
D65, `0.3125000`, against the client's neutral `0.3127789` — a gap of **2.8e-4**. One notch of the
slider moves x by **7.4e-3**, twenty-six times that. `0.001` sits 3.6× above the gap and 7.4× below a
notch. Do not widen it toward the notch or narrow it toward the quantisation gap without re-measuring;
`tests/test_drm_color_pipeline.cpp` asserts the neutral value is expressible and the one-notch value
is not, using the measured numbers.

`0018` — **the whole SDR chain in the DPU's own LUTs, not just a diagonal.** Third-party
(virtudude), carried with one addition of ours. `0014` exists because the DPU exposes no degamma
block, which leaves only a per-channel diagonal expressible — so a colour temperature change, a
gamut mapping or a look LUT each cost a full composite on every frame they are live. That limit is
mainline's, not the hardware's: on DPU 9.0+ the colour LUT blocks sit behind a LUT bus with no
memory-mapped write path, reachable only by the LUTDMA engine, which mainline does not drive.
Kernel patches `0530`-`0532` port that engine and expose the DSPP inverse gamma as a 256-entry
CRTC `DEGAMMA_LUT` and the 17³ gamut block as a `DPU_3D_LUT` blob. This patch drives them: the
shader leaves its gamma 2.2 shaper and 3D LUT unbound and the DPU applies the same pair post-blend,
on the scanout path *and* the composite path.

**`0014` is not superseded — it is the fallback**, and the two are ordered rather than merged. Only
a kernel with the LUTDMA engine offers `DPU_3D_LUT`, and the SM8250 boards have no such engine, so
both can be present at once. When the output LUTs are applied: the CTM is held at the **identity**
(`drm_update_crtc_ctm()` is given `false`, exactly as for a composited frame and for the same
reason — the transform is already being applied elsewhere); `drm_scanout_is_color_managed()` returns
true outright, skipping the expressibility test entirely; and `drm_scanout_ctm_is_active()` returns
false, so partial composition stays available, because the post-blend LUTs correct both halves and
there is no split to manage.

**One hunk of the author's patch is deliberately not carried**, and the measurement that justifies
it is worth keeping. It forced a full composite for every SDR layer whenever the output LUTs were
not carrying the chain — correct in a tree without `0014`, redundant here, and strictly the more
conservative of the two tests, so keeping both let it win everywhere and made `0014` unreachable.
On Pocket FIT with `drm_output_luts 0` and night mode at maximum that read **one live content
plane and an identity CTM** — the composite, not the diagonal — and on the SM8250 boards, which
have no `DPU_3D_LUT` at all, it would have been the permanent state. Dropping it loses nothing:
with the LUTs on both tests allow scanout, with an inexpressible transform both composite, and
only the diagonal case differs.

**HW PASS, Pocket FIT (SM8650, engine v3), 2026-09-13.** A non-neutral colour temperature — a
Bradford white-point adaptation, non-diagonal, so it cost a full composite on *every frame it was
live* — now scans out: **2 live content planes** with the adaptation in `DPU_3D_LUT` and the CTM at
identity, against **1 plane** with the LUTs off. Night mode at maximum reprograms the 3D LUT while
the CTM stays identity, and with the LUTs off falls back to `diag(1.0, 0.41667, 0)` on scanout.
Sixteen enable/disable transitions — each one a modeset — with zero LUTDMA / `CTL_FLUSH` /
underrun / SMMU-fault lines.

**Pocket S2 (SM8650, engine v3) is the board that mattered**, because
`--rotated-output-max-height` clamps its 1440x2560 panel to a 1080 render the DPU upscales, putting
the pre-rotation height 8 lines under the inline rotator's 1088 cap — so anything that grew a layer
would re-open the black-UI failure. It did not: in all four states (LUTs on/off under night mode,
colour temperature, and the restore) it held **two live content planes both at `rotation=8`**,
inline rotation and the DPU upscale intact, with **zero `invalid height for inline rot` rejections**
in dmesg and zero in the session log. Same A/B answers as the other two boards.

**Pocket ACE (qcs8550, engine v2) gives identical answers**, on all three states: LUTs on + night
mode max = 2 planes / identity CTM / populated 3D LUT; LUTs off + night mode max = 2 planes /
`diag(1.0, 0.41667, 0)` / cleared; LUTs on + colour temperature = 2 planes / identity / populated.
That board is the author's own verified engine revision, so it re-gates their leg against our
re-roll rather than testing new silicon. Zero display or LUTDMA errors after boot — its 10
arm-smmu faults in the first second are the pre-existing splash handoff, unchanged in count.

**The two paths are not pixel-identical, by construction, and an operator can see it.** `0014`'s
`calcScanoutLinearScale()` deliberately ignores the SDR gamut mapping, because direct scanout never
applied it; the 3D LUT runs the full `calcColorTransform()` chain and does. At the default
`sdrGamutWideness` of 0.5 that mapping is live, so toggling `drm_output_luts` under a fixed night
mode gives *"subtle differences in some colours, nothing completely off"* — saturated content moves,
neutrals do not. **Forcing `sdrGamutWideness` to 0 makes the two indistinguishable to the eye**,
which is the measurement that identifies the cause; do that before chasing anything else here. It
is a **fix, not a regression**: the composite path always applied the gamut mapping, so the LUTs
make scanout and composite agree, where `0014` left them differing by exactly this and let the
difference appear and disappear as frames switched paths.

**Being post-blend has a real consequence**: a translucent overlay is corrected as the blended
pixel, not per layer. Per-plane offload is the follow-up. Turning the LUTs on or off changes which
display blocks the CRTC owns and therefore needs a **modeset** — the kernel asks for one, and the
patch keeps them on across a composited frame rather than toggling. The runtime switch is the
convar `drm_output_luts` (default on); set it explicitly (`gamescopectl drm_output_luts 0`), since
a bare convar name *sets it false*.

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
