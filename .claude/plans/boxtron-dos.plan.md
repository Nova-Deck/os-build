# Plan: GOG DOS games on native DOSBox (Boxtron), chosen by the user

**Branch**: `boxtron-dos`
**Complexity**: Medium-large. Two new packages, a launch-time target swap in `game-launch`, a
variant picker in the store plugin, and two store-plugin fixes.
**Depends on**: the alien-games launch path (model B, milestone 6) and the first-run hook's
pattern (`rootfs/overlay/usr/lib/novadeck/novadeck_firstrun.py`).

## Summary

GOG ships DOS games as Windows DOSBox, often behind a Windows launcher. Under Proton they run
**DOSBox → Wine → FEX**. DOSBox's dynamic core writes fresh x86 code at runtime, and FEX has to
re-translate all of it. Master of Magic on the Pocket FIT is slow. GOG's conf runs
`core=dynamic` at a fixed `cycles=100000`, which is about the worst case for that.

We bake **Boxtron** as a compat tool next to our two Protons. The user picks it per game in
Steam: *Properties → Compatibility → "Boxtron (native DOSBox)"*. Boxtron turns a `dosbox.exe`
command line into a native **arm64 DOSBox Staging** run, rewriting GOG's `.conf` files for Linux
on the way. No FEX, no Proton, no Wine.

**Proton CachyOS stays the default for every alien-store game, DOS ones included.** Nothing is
classified or mapped to Boxtron automatically; `launch.compat_tool()` is unchanged. Boxtron is an
opt-in the user makes per game, and our code must never undo it.

**The shortcut never changes.** For MoM it stays `Launcher.exe`, which is right under Proton.
When Boxtron is the chosen tool, **`game-launch` swaps the target** at launch time for the
recorded DOSBox command, exactly as the first-run hook swaps in a setup step:
- **GOG knowledge stays in the store plugin**, which records each game's DOSBox targets.
- **`game-launch` stays store-agnostic.** It only knows "tool is Boxtron → use the recorded
  DOSBox target".
- **Boxtron ships unpatched.**

**Where a game has several DOSBox builds** (MoM: Official Release and Community Patch), the user
picks one at launch. The dialog has a *remember my choice* box, like Steam's launch-option or
renderer prompt (e.g. Parking Garage Rally Circuit's OpenGL/Vulkan choice). The pick can be
changed later from the game page.

## Verified before planning

### The device: MoM on the Pocket FIT, read 2026-11-17

Install: `/home/deck/Games/GOG/Master of Magic/`. The shortcut Exe is `Launcher.exe`.

**Root `goggame-1207658855.info`, `playTasks`:**

| task | category | flags | path | arguments | workingDir |
|---|---|---|---|---|---|
| "Master of Magic" | launcher | **isPrimary** | `Launcher.exe` | none | none |
| "…launcher process … Official Release/DOSBOX/DOSBox_exe" | game | **isHidden** | `Master of Magic Official Release/DOSBOX/DOSBox.exe` | none | none |
| "…launcher process … Community Patch/DOSBOX/DOSBox_exe" | game | **isHidden** | `Master of Magic Community Patch/DOSBOX/DOSBox.exe` | none | none |
| "Master of Magic" | game | visible | `Master of Magic Official Release/DOSBOX/DOSBox.exe` | `-conf "../dosboxMOM.conf" -conf "../dosboxMOM_single.conf" -noconsole -c "exit"` | `DOSBOX` |
| "Graphic Mode Setup" | tool | | `…/DOSBOX/GOGDOSConfig.exe` | `1207658855` | `DOSBOX` |

**Nested `Master of Magic Community Patch/goggame-1207658855.info`:** an **isPrimary** game task
with path `DOSBOX\dosbox.exe` (backslash, **lower-case**; the file on disk is `DOSBox.exe`),
arguments `-conf "..\dosboxMOM.conf" -conf "..\dosboxMOM_single.conf" -noconsole -c "exit"` and
workingDir `DOSBOX`. Its paths are relative to the subdirectory.

**Path rules these force:**
- The root task's `workingDir: DOSBOX` does **not** exist relative to the install root (there is
  no `<install>/DOSBOX`). The right cwd is the exe's own dir.
  **Rule:** resolve workingDir against the info file's dir; if that isn't a directory, use the
  exe's dir.
- GOG paths mix `/` and `\` and have the wrong case.
  **Rule:** normalise separators and resolve each component case-insensitively.

**Conf and other variants:**
- `dosboxMOM_single.conf` autoexec is `mount C ".."` then `mount C "..\cloud_saves" -t overlay`
  then `magic.exe`. **`cloud_saves` does not exist** in either variant. Native behaviour of that
  overlay line is a HW check. The game should still run off the first mount.
- `Multi.config` also lists two DLC variants (Caster of Magic, Caster Windows) that are **not
  installed** here. Variants are discovered from disk, never from that list.

### Code and upstream

| Fact | Evidence |
|---|---|
| `game-launch` fronts every alien-store launch (`game-launch %command%`) and already rewrites the launch argv for a per-appid entry the store plugin writes to the store home (`first-run.json`) | `game-launch:375-412`, `novadeck_firstrun.py` |
| Valve's pinned snapshot ships no DOSBox | `extra.db`/`core.db` at `mash-20260528.1.pvt` |
| Boxtron is pure Python and needs no compile. Last commit `b3eb8c1` (2023-04-05) | `_reference/boxtron` |
| Boxtron's compat tool has the same shape as our Protons (`windows`→`linux`), so Steam lists it in the same dropdown. It names **no** `require_tool_appid`, so it runs bare on the host | `compatibilitytool.template`, `toolmanifest.vdf` |
| Boxtron handles `dosbox.exe <args>`. It splits mount params, maps Windows paths case-insensitively and keeps `-t overlay` as an option. `Launcher.exe` would be "Game not recognized", which is why we swap first | `run-dosbox:195-258`, `confgen.py:316-350` |
| Boxtron's toolmanifest is **v1** (`commandline_waitforexitandrun`, no `%verb%`). Whether the arm64 client honours v1, and **how Steam lays out the argv** around it, are unverified | `toolmanifest.vdf` |
| **`reassert_compat` overrides any user choice.** On every frontend start it re-sends our Proton to every registered entry. A pick of Boxtron, or Proton-GE today, is reset | `main.py:384-403,943` |
| **Our GOG resolver drops task arguments.** `_gog_primary_exe` returns `path` only, so a GOG title whose primary task is `DOSBox.exe -conf …` starts DOSBox with no config, **under Proton too** | `launch.py:_gog_primary_exe`, `_gog_target` |
| Steam's own launch-option chooser comes from Steam's app data. A shortcut has one launch entry, so **the picker must be ours** | — |
| DOSBox Staging **v0.83.1** (2026-11-14): CMake. Needs SDL2 + SDL2_image + iir + PNG + OpenGL + **MT32Emu (REQUIRED, unconditional)** + FluidSynth + ALSA + speexdsp. aarch64 uses **dynrec**. `main` is on SDL3, so pin the tag | `git show v0.83.1:CMakeLists.txt:281-307,459-470` |
| Snapshot has `sdl2-compat sdl2_image fluidsynth speexdsp opusfile libpng zlib-ng alsa-lib libglvnd cmake ninja libx11 inotify-tools`. It **lacks** `iir1`, `munt`, `timidity++`, `zenity` and any GM soundfont | snapshot db scan |

## Design

### 1. Packages
- **`packages/dosbox-staging/`**: local PKGBUILD (gogdl form), `arch=aarch64`, sources pinned by
  sha256:
  - `dosbox-staging-0.83.1`
  - `iir1`
  - `munt` (libmt32emu)

  Take the iir1 and munt versions from upstream's own pins. Build iir1 and libmt32emu
  **static** into a `$srcdir` prefix, then Staging against it with `OPT_TESTS=OFF` and the
  default `-march` (the SM8250 floor). Runtime depends: `sdl2-compat sdl2_image fluidsynth
  speexdsp libpng zlib-ng alsa-lib libglvnd`.
- **`packages/boxtron/`**: local PKGBUILD, `arch=any`, pinned to `b3eb8c1`.
  `make prefix=/usr DESTDIR=$pkgdir install` puts `boxtron.vdf` in
  `/usr/share/steam/compatibilitytools.d/` and `run-dosbox` and its modules in
  `/usr/share/boxtron/`. Depends `python dosbox-staging inotify-tools`. **Assert at build time
  that the internal tool name is `boxtron`**: Steam pins games by it, and `game-launch` detects the
  tool by its entry-point path.
- Add both to `PKGS` in `rootfs/customize-base.sh` and relock (both locks).

### 2. Store plugin: record DOSBox variants (`launch.py`, new `dos_targets.py`)
At register and finish-install, for a GOG Windows install, collect **variants**:
- each **visible** (`not isHidden`) `game` task in the root info whose exe resolves to
  `dosbox.exe`;
- the `isPrimary` DOSBox game task of each `goggame-*.info` **one directory down**, with its
  paths resolved against that directory.

Dedupe by the resolved exe path. Each variant is `{label, exe, args: [tokens], cwd}`:
- `label` is the variant's top-level directory name ("Master of Magic Official Release"), since
  the task names are identical.
- `args` are split with Windows rules (quotes; backslashes literal).
- `exe` and `cwd` follow the path rules above.

Order: root's visible task first, then the nested ones by label.

Write `<store home>/dos-targets.json`, keyed by appid like `first-run.json`:
`{appid: {token, launcher_exe, variants: [...], choice: null | <label>}}`. Zero variants means
no row. One variant means no prompt is ever needed.

### 3. `game-launch`: the swap (new `novadeck_dostarget.py`, called beside `novadeck_firstrun`)
1. Find Boxtron's entry point (`/usr/share/boxtron/run-dosbox`) in the argv.
   **Not Boxtron → return the argv untouched.** Proton launches never change.
2. Look up the appid's row. **No row → untouched** (Boxtron then behaves as stock).
3. Find, after the entry point, the argv element **equal to the row's `launcher_exe`**. An exact
   match, never a guess at which word is the game. Replace it and everything after it with the
   chosen variant's `exe + args`, and `chdir(cwd)`.
4. **The chosen variant is:**
   - the row's `choice` when set;
   - else the frontend's one-shot pick for this launch (step 4 below);
   - else the first variant.

As with all of `game-launch`, every failure leaves the argv as Steam built it and logs one line.
Unit-tested against fixtures **copied from the FIT's real info files**.

### 4. Store plugin: the variant picker (frontend)
When a launch of one of our entries starts, and **Boxtron is its tool**, and its row has **≥2
variants** and **no remembered `choice`**:
- intercept the launch;
- show a modal listing the variants by label, with a **"Remember my choice"** checkbox;
- store the pick (`choice` if remembered, else a one-shot pick consumed by `game-launch`);
- then let the launch proceed.

Mechanism to probe on device first: game-action start registration plus cancel-and-relaunch,
vs. a pre-launch hook. **If no reliable interception exists**, fall back to the game-page setting
alone, with the first variant as default.

**Game page:** a "DOSBox version" row (*Ask every time* / each label). It is shown only when the
entry has ≥2 variants. Choosing *Ask every time* clears `choice`.

### 5. Store plugin: stop overriding the user's compat choice
`reassert_compat` sets a tool **only when the entry has none mapped**. The bridge reads the
entry's current tool before setting. Which read to use (live app details vs. `config.vdf`
`CompatToolMapping`) is a device probe; prefer the live one. The picker (4) needs the same read,
to know Boxtron is selected. This fixes Proton-GE today too.

### 6. Store plugin: pass GOG task arguments (separate fix)
The **primary** task's `arguments` and `workingDir` go into the shortcut:
- `StartDir` follows the path rules above.
- The arguments go into `LaunchOptions` after `%command%`, `shlex.quote`d, because LaunchOptions
  goes through a shell.

GOG titles whose primary task is `DOSBox.exe -conf …` then launch correctly under Proton. Under
Boxtron those titles need no swap at all: their one variant **is** the shortcut. The swap then
matches nothing and leaves the argv alone, which is correct.

## Steps

Three phases, each ending in a HW gate on the Pocket FIT (dev card from the branch). One commit
per step; merge only after phase 3's gate.

0. ~~Device read~~ **Done 2026-11-17** (tables above).

### Phase 1 — Boxtron works (no picker, no plugin UI)
1. **`dosbox-staging` package** + an offline test that the three sources stay pinned;
   `make overlay`.
2. **`boxtron` package** + the vdf-name assertion.
3. **Variant discovery** (TDD, `tests/test-store-launch.sh`), using MoM's two real info files as
   fixtures:
   - MoM → 2 variants, Official first, correct exe/args/cwd;
   - the nested `dosbox.exe` resolves to `DOSBox.exe` case-insensitively;
   - the root's `workingDir` falls back to the exe's dir;
   - hidden tasks are ignored;
   - a non-DOS Windows game gets no row;
   - a single-DOSBox-task game gets one variant.
4. **`game-launch` swap** (TDD): non-Boxtron argv untouched; no row untouched; `choice` used
   when set; first variant otherwise; launcher exe not in argv → untouched; a missing variant
   exe → untouched plus a log line. (The one-shot pick arrives in phase 3.)
5. **Device probe:** Steam's argv for a v1 Boxtron launch. If v1 is not honoured, patch the
   toolmanifest to v2 here.
6. **HW gate:**
   - Boxtron is listed beside both Protons.
   - Select it by hand for MoM → the Official Release runs on native `dosbox` (`ps`: no
     `FEXInterpreter`/`wine`).
   - Write `choice: "Master of Magic Community Patch"` into `dos-targets.json` by hand → that
     variant runs.
   - Speed is normal; sound works.
   - Touch/trackpad mouse works.
   - Fullscreen under gamescope.
   - `cloud_saves` overlay line: what happens.
   - Saves persist.
   - Quitting returns to Steam.
   - Switch to CachyOS → GOG's launcher runs as before.

   (Within one session: `reassert_compat` may still reset the tool on the next boot until
   phase 2.)

   **RESULT, Pocket FIT, dev card 20261117T123847Z (4c233ff), 2026-11-17: PASSED except touch.**

   **Launch chain**
   - Steam honours Boxtron's v1 manifest. The argv is `pw-audio-namespace → reaper SteamLaunch
     AppId=… -- /usr/share/boxtron/run-dosbox --wait-before-run <exe>`.
   - Under Boxtron, Steam sets `STEAM_COMPAT_APP_ID=0`. game-launch's `appid()` skips 0 and falls
     through to `SteamAppId`, which is what keys the row. Keep that order.
   - The swap fired. Native aarch64 `/usr/bin/dosbox` ran in the variant's `DOSBOX` dir, with no
     FEX or wine in the tree, at ~79% of one core.

   **Play**
   - Fast, with Sound Blaster 16 + OPL3 sound through PipeWire. There is no soundfont, so
     Boxtron switches MIDI off; MoM doesn't need it.
   - Quitting the game exits DOSBox back to Steam.
   - A hand-written `choice` ran the Community Patch build. Its backslash `-conf` args are
     handled by Boxtron.
   - Proton CachyOS still runs GOG's launcher. Saves are shared, since both mount the build
     dir as C: (a Boxtron save loaded under Proton).
   - Steam also runs its `d3ddriverquery64.exe` probe through Boxtron. Boxtron rejects it and
     logs "zenity is missing": harmless, no dialog, no delay.

   **Mouse: right stick bound as a Steam Input mouse WORKS. TOUCH DOES NOT.**
   - gamescope's touch → pointer path was verified correct by logging `XQueryPointer` on the
     game's X display: corner taps land at 17,37 / 1902,59 / ~60,1040 and centre at 904,565,
     each with a button 1 press.
   - With `mouse_capture = onclick` (Staging's default; GOG's `autolock` is unknown to
     Staging), the first tap captures the mouse and later touches carry no relative motion.
   - With `seamless` (Staging's documented touch mode) the cursor sits at the bottom-right.
     MoM keeps its own cursor from relative motion, and Staging's help says seamless "does not
     work correctly with all the games".
   - gamescope's `Trackpad` touch mode (`STEAM_TOUCH_CLICK_MODE=6`) gives deltas from
     gamescope's own pointer, not the game's cursor, so the axes go wrong.
   - Not a Boxtron defect. It needs a touch → relative translation that follows the game's
     cursor. Not packaged: `seamless` does not help MoM.

   **Boxtron quirk:** a missing overlay dir (`..\cloud_saves`) becomes `mount C "None" -t
   overlay`. It is harmless, since the first mount already gives C:. Patch it in
   `packages/boxtron/` if it ever matters.

### Phase 2 — the store plugin keeps out of the way
7. **Device probe:** reading an entry's current compat tool.
8. **`reassert_compat` only fills an empty mapping** (TDD).
9. **GOG task arguments fix** (TDD: quoting with spaces in the path and backslashes and quotes in
   args).
10. **HW gate:** reboot → MoM still on Boxtron; a Proton-GE pick survives too.

    **RESULT, Pocket FIT, dev card 20261117T134943Z (afe7971), 2026-11-17: PASSED.**
    - MoM was reinstalled, set to Boxtron and rebooted. Both frontend-ready runs logged
      `compat re-asserted on 0 entries`; before the fix that count was 1.
    - `config.vdf` still maps the appid to `boxtron` (priority 250), and Properties shows
      Boxtron.
    - Play still goes straight into DOSBox, and the dos-targets row was rebuilt for the new appid.
    - The Proton-GE case is covered offline only: MoM was the only installed title.

### Phase 3 — the variant picker (last)

**Design decided 2026-11-17: the LAUNCH asks; Steam's launch is never intercepted.**
Cancel-and-relaunch through `RegisterForGameActionStart` / `CancelGameAction` / `RunGame` races
process spawn and re-triggers itself. `game-launch` is already in the chain and can wait, so it
asks over the spool the tile stub already uses (`store-launch` → `install_requests.py`):

- **`game-launch`** (novadeck_dostarget). Only on a Boxtron launch of a row with ≥2 variants and
  no remembered `choice`:
  - it creates `<store home>/requests/<appid>.dospick`; the filename is the whole message;
  - if the request is not taken in 10 s, the plugin is down: withdraw it and run the first
    variant;
  - once taken, it waits up to 120 s for `requests/<appid>.dosanswer`, which holds a label or
    nothing (cancel);
  - a label runs that variant; cancel exits 0 without exec (like dismissing Steam's own
    launch-option dialog); a timeout runs the first variant.
- **The backend** takes `.dospick` requests in the loop that takes `.install` ones:
  - same owner and no-follow checks, and the appid must have a dos-targets row;
  - it emits `dos_pick` {appid, title, labels};
  - `dos_pick_answer(appid, label | null, remember)` writes the answer file as the user, and with
    `remember` also sets the row's `choice`.
- **The frontend:** a modal titled "Which version?", one button per label plus Cancel, and a
  *Remember my choice* toggle (off by default). The game page's installed row gets a "DOSBox
  version" button, shown only with ≥2 variants, that opens the same list plus *Ask every time*
  (clears `choice`).

11. **Device probe:** a Decky modal is visible and controller-navigable while a launch is pending
    (game-launch blocked before exec). Checked at the HW gate.
12. **The picker:**
    - spool request and answer in `game-launch`;
    - backend take, emit and answer;
    - the modal, and the game-page "DOSBox version" setting.
13. **HW gate:** first Play → the picker shows both versions; *remember* → the next Play skips it;
    game page → *Ask every time* brings it back.
14. **Docs**: the alien-games launch doc and the per-game compatibility doc.

## Risks / open questions

- **v1 toolmanifest and argv layout** on the arm64 client: unverified; step 5. If v1 is not
  honoured, patch Boxtron's toolmanifest to v2 (`%verb%`) with a verb shim.
- **Launch interception** for the picker: unverified; step 11. The game-page setting is the
  fallback.
- **Boxtron vs Staging 0.83**: Boxtron targets Staging 0.76. Its generated conf may use renamed
  options. Fix with a patch in `packages/boxtron/`.
- **Mouse on a handheld**: DOSBox emulates a relative mouse. Touch is absolute.
- **GM soundfont**: none in the snapshot. MoM's OPL/Sound Blaster music needs none.
- **Boxtron is unmaintained since 2023**: we own any fix (~2k lines of Python).
- **Only our shortcuts get the swap.** A GOG game added through Heroic or by hand runs stock
  Boxtron, which handles a direct `DOSBox.exe` target but not a launcher.
