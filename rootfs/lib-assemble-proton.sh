#!/usr/bin/env bash
# novadeck read-only root assembler — baked Proton compat tools (stage 4b, pass 3).
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged, and the stage banner below is the same one the assembler
# carried (tests/test-mkroot.sh reads the stage IDs out of this file set).
#
# Defines rewrite_proton_tool() + widen_dxvk_probe() and applies both to the two baked tools.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# Rewrite the baked Proton compat tools. We bake TWO — proton-cachyos and proton-ge — so the user
# can pick whichever runs a given title better from the Steam UI. Both are the same self-contained
# arm64 Wine + Valve WoW64-FEX Proton and ship identical toolmanifest.vdf / compatibilitytool.vdf
# shapes, so a single rewrite serves both. Every edit FAILS LOUDLY if upstream changes shape — a
# silently un-rewritten tool would refuse to launch, bypass our FEX tuning, or unpin games on a bump.
#
# WE NO LONGER TOUCH toolmanifest.vdf AT ALL, and both edits that used to live there are worth
# their epitaphs:
#
#   `require_tool_appid` was STRIPPED, because it names Valve's arm64 SLR container (4185400) and an
#   older client never *registered* that as a compat tool even with its files installed — the launch
#   died before Proton ran (AppError_51). Once the account gate on Valve's FEX compat tool opened,
#   that stopped being true: the client registers 4185400, installs it on demand, and composes the
#   SLR4 entry point around a tool that asks for it. Stripping it now would opt us OUT of the
#   container Valve builds and tests against, for nothing.
#
#   This was written up as a property of the "Deckard client" — it is NOT. Proton has since been
#   tested on a non-deckard build and runs, so the fix rode the ACCOUNT GATE, not the launch flag or
#   the client channel. Corrected 2026-08-19, after the stale wording nearly blocked reverting
#   -deckard on the false belief that the revert would cost us Proton.
#
#   `commandline` was REPOINTED at an in-tool shim, so per-game FEX tuning ran in front of Proton
#   automatically. That shim exec'd /usr/lib/novadeck/game-launch — a path that does not exist
#   inside SLR4, where /usr is the container's. Keeping it would have meant a tool that cannot
#   launch at all (HW-observed: `exec: /usr/lib/novadeck/game-launch: not found`, game dead).
#   Tuning now arrives the way it does for EVERY other compat tool, ours or Valve's: Steam launch
#   options, `/usr/lib/novadeck/game-launch %command%`, written per game by novadeck-control, which
#   runs on the host side of pressure-vessel. novadeck-control is the user surface for these
#   settings anyway, so nothing is lost by routing them all through it.
#
# rewrite_proton_tool <tool_dir> <stable_internal_name> <display_name> now only touches
# compatibilitytool.vdf:
#     1. Replace the tool's INTERNAL name. Upstream's is the dated build string (e.g.
#        proton-cachyos-11.0-20260602-slr-arm64 / GE-Proton11-1-aarch64), and Steam records THAT
#        internal name — not the directory — against every game it is forced on. Left as-is, a Proton
#        bump changes the internal name and silently unpins every game. Rewrite it to a stable,
#        version-free id so a bump is transparent. (The directory is already version-free via the
#        pin's `dest`; that alone does NOT stabilise what Steam pins by.)
#     2. Give it a friendly display_name (upstream reuses the dated build string there too).
# The display version is parsed per-tool at each call site (the `version` file format differs) and
# passed in, so this function stays build-agnostic.
rewrite_proton_tool() {
  local tool_dir="$1" stable_name="$2" display="$3"
  local manifest="$tool_dir/toolmanifest.vdf"
  [ -f "$manifest" ] || { echo "ERROR: Proton tool has no toolmanifest.vdf at $manifest" >&2; exit 1; }

  # Asserted, not edited. The dependency is what puts this tool inside SLR4, and a Proton that
  # stopped declaring it would silently start running bare again — a different runtime than the
  # one it was built and tested against, with nothing to say so.
  grep -q 'require_tool_appid' "$manifest" \
    || { echo "ERROR: Proton toolmanifest ($tool_dir) declares no require_tool_appid — upstream changed shape" >&2; exit 1; }

  local ctool="$tool_dir/compatibilitytool.vdf"
  [ -f "$ctool" ] || { echo "ERROR: Proton tool has no compatibilitytool.vdf at $ctool" >&2; exit 1; }

  # The internal name is the first quoted string inside `compat_tools { ... }`; the display_name
  # is a `"display_name" "..."` pair. Both are matched positionally so an unexpected upstream shape
  # errors out rather than half-rewriting.
  python3 - "$ctool" "$stable_name" "$display" <<'PYVDF'
import re, sys
path, tool_name, display = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
text, n = re.subn(r'("compat_tools"\s*\{\s*(?://[^\n]*\n\s*)*)"[^"]+"', lambda m: m.group(1) + '"%s"' % tool_name, text, count=1)
if n != 1: sys.exit("compatibilitytool.vdf: could not find compat_tools internal name")
text, n = re.subn(r'("display_name"\s+)"[^"]+"', lambda m: m.group(1) + '"%s"' % display, text, count=1)
if n != 1: sys.exit("compatibilitytool.vdf: could not find display_name")
open(path, "w").write(text)
PYVDF

  echo "  wired Proton compat tool '$stable_name' ($display) — stable name, SLR4 dependency intact"
}

# widen_dxvk_probe <tool_dir> — teach the CachyOS DXVK selector about 8-bit storage.
#
# THE DEFECT. proton-cachyos now bundles DXVK 3 (our pin carries doitsujin/dxvk v3.0.2+2), and
# DXVK 3 REQUIRES storageBuffer8BitAccess: src/dxvk/dxvk_device_info.cpp lists it as
# `ENABLE_FEATURE(vk12, storageBuffer8BitAccess, true)`, right beside descriptorIndexing. Turnip
# only advertises that feature where freedreno_devices.py sets `storage_8bit`, and that appears
# exactly once in the whole device table — inside a7xx_base. So it is TRUE on Adreno 740/750
# (SM8550/SM8650) and FALSE on Adreno 650 (SM8250, the Pocket Max).
#
# Upstream's own capability probe would route around this, except it asks the wrong question: it
# probes ['descriptorIndexing'] alone, which a6xx passes. The device is then handed a DXVK it
# cannot initialise, and the dxvk-sarek fallback that ships right next to it (a full
# aarch64/x86_64/i386 DLL set in the arm64 tarball — checked, not assumed) is never selected.
#
# WHY A PROBE AND NOT A DEVICE LIST. We ship ONE image for every SoC, so the selection has to be
# made on the running GPU, not on a table we maintain. The probe is already runtime and already
# feature-based — utilities.primary_gpu_supports_vulkan() dlopens libvulkan.so.1, walks
# vkGetPhysicalDeviceFeatures2 over the Vulkan 1.1-1.4 feature structs, and reduces each device to
# a SET OF FEATURE NAMES that came back true. Adding a name to the list it checks is the whole fix;
# vulkan.py already declares the field. A7xx keeps DXVK 3 with no per-device knowledge anywhere,
# and the day Turnip gains 8-bit storage on a6xx, this corrects itself.
#
# KNOWN LIMIT, stated so a green build is not mistaken for a working device: the probe fails OPEN
# (`if not primary_category: return True`). proton runs inside SLR4, where the ICD arrives via the
# graphics-provider path, so if the probe's own loader enumerates no GPU it concludes modern DXVK
# is fine and we are back where we started. This edit is necessary; only hardware can show it is
# sufficient. Verify BOTH legs: that the probe sees the Adreno at all, and that a D3D11 title then
# loads the sarek DLLs.
#
# GE is deliberately not touched: its proton script has no probe and no sarek to fall back to.
widen_dxvk_probe() {
  local tool_dir="$1"
  local script="$tool_dir/proton"
  [ -f "$script" ] || { echo "ERROR: CachyOS Proton tool has no proton script at $script" >&2; exit 1; }

  python3 - "$script" <<'PYDXVK'
import re, sys

path = sys.argv[1]
NEEDED = "storageBuffer8BitAccess"
ANCHOR = "descriptorIndexing"

text = open(path).read()
# The assignment is matched positionally and must be unique: an upstream shape we do not recognise
# has to stop the build, not be half-rewritten into something that silently probes nothing.
pattern = re.compile(
    r"^([ \t]*MODERN_DXVK_FEATURES[ \t]*=[ \t]*)\[([^]\n]*)\]([ \t]*(?:#.*)?)$", re.MULTILINE)
matches = list(pattern.finditer(text))
if len(matches) != 1:
    sys.exit("proton: expected exactly one MODERN_DXVK_FEATURES assignment, found %d" % len(matches))

match = matches[0]
features = [f.strip() for f in match.group(2).split(",") if f.strip()]
names = [f.strip("'\"") for f in features]

if NEEDED in names:
    # Not a no-op success: if upstream widened its own probe, this whole function is dead weight
    # sitting on top of their logic and should be deleted, not left to shadow it.
    sys.exit("proton: MODERN_DXVK_FEATURES already probes %s — upstream fixed this; "
             "drop widen_dxvk_probe from assemble-rootfs.sh" % NEEDED)
if ANCHOR not in names:
    sys.exit("proton: MODERN_DXVK_FEATURES does not probe %s (found %r) — upstream changed the "
             "probe; re-derive what DXVK now requires before touching this" % (ANCHOR, names))

widened = ", ".join(features + ["'%s'" % NEEDED])
open(path, "w").write(
    text[:match.start()] + match.group(1) + "[" + widened + "]" + match.group(3) + text[match.end():])
PYDXVK

  echo "  widened the CachyOS DXVK probe with storageBuffer8BitAccess (a6xx falls back to dxvk-sarek)"
}

COMPAT_DIR="$stage/usr/share/steam/compatibilitytools.d"
BAKED_PROTON=0

# CachyOS. `version` file format: "<epoch> cachyos-<ver>-...", e.g. "cachyos-11.0-20260703-slr".
PROTON_CACHY_TOOL="$COMPAT_DIR/proton-cachyos-11.0-arm64"   # dir == stable internal id
if [ -d "$PROTON_CACHY_TOOL" ]; then
  [ -f "$PROTON_CACHY_TOOL/version" ] || { echo "ERROR: CachyOS Proton tool has no version file at $PROTON_CACHY_TOOL/version" >&2; exit 1; }
  PVER="$(sed -n 's/.*cachyos-\([0-9][0-9.]*-[0-9]\{6,\}\).*/\1/p' "$PROTON_CACHY_TOOL/version")"
  [ -n "$PVER" ] || { echo "ERROR: could not parse CachyOS Proton version from $(cat "$PROTON_CACHY_TOOL/version")" >&2; exit 1; }
  rewrite_proton_tool "$PROTON_CACHY_TOOL" "proton-cachyos-11.0-arm64" "Proton ${PVER} (CachyOS, arm64)"
  widen_dxvk_probe "$PROTON_CACHY_TOOL"
  BAKED_PROTON=1
fi

# GE (GloriousEggroll). `version` file format: "<epoch> GE-Proton<major>-<minor>", e.g. "GE-Proton11-1".
PROTON_GE_TOOL="$COMPAT_DIR/proton-ge-arm64"   # dir == stable internal id
if [ -d "$PROTON_GE_TOOL" ]; then
  [ -f "$PROTON_GE_TOOL/version" ] || { echo "ERROR: GE Proton tool has no version file at $PROTON_GE_TOOL/version" >&2; exit 1; }
  GEVER="$(sed -n 's/.*\(GE-Proton[0-9][0-9.-]*[0-9]\).*/\1/p' "$PROTON_GE_TOOL/version")"
  [ -n "$GEVER" ] || { echo "ERROR: could not parse GE Proton version from $(cat "$PROTON_GE_TOOL/version")" >&2; exit 1; }
  rewrite_proton_tool "$PROTON_GE_TOOL" "proton-ge-arm64" "${GEVER} (GloriousEggroll, arm64)"
  BAKED_PROTON=1
fi

[ "$BAKED_PROTON" = 1 ] || echo "  (no baked Proton compat tool — x86 Windows games will have no compat tool)" >&2
