#!/usr/bin/env bash
# Offline check for the CachyOS DXVK capability-probe widening.
#
#   images/test-proton-dxvk.sh
#
# WHY THIS EXISTS. assemble-rootfs.sh rewrites a THIRD-PARTY python script that is not in this
# tree — the `proton` script inside the pinned proton-cachyos tarball. Everything about that is
# fragile in a way nothing else here would notice:
#
#   - the rewrite is a regex against upstream source that moves on every Proton bump;
#   - it only matters on Adreno 650, so an SM8550/SM8650 test pass proves nothing about it;
#   - and its failure mode on the affected device is a game that will not start, days after the
#     build that broke it.
#
# So the substitution is exercised here against fixtures instead of being trusted to a build log.
# The fixture in case 1 is the real assignment from our pinned build (cachyos-11.0-20260703-slr,
# proton line 1543), copied verbatim.
#
# WHAT THIS CANNOT SHOW. Only that the edit lands correctly. Whether it HELPS is a hardware
# question — the probe fails open when it enumerates no GPU, and proton runs inside SLR4 where the
# ICD arrives through the graphics-provider path. See widen_dxvk_probe's header.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$ROOT/images/assemble-rootfs.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

[[ -f $ASSEMBLE ]] || { echo "missing input: $ASSEMBLE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run the assembler's OWN embedded rewriter rather than a copy of it: a test carrying its own
# duplicate of the regex would keep passing after the shipped one drifted.
awk '/<<.PYDXVK./{flag=1; next} /^PYDXVK$/{flag=0} flag' "$ASSEMBLE" > "$TMP/widen.py"
[[ -s $TMP/widen.py ]] || { echo "could not extract the PYDXVK block from $ASSEMBLE" >&2; exit 1; }

# usage: run_widen <fixture-file>  -> prints nothing, returns the rewriter's exit status
run_widen() { python3 -B "$TMP/widen.py" "$1" >"$TMP/err" 2>&1; }

echo "the probe rewrite lands on upstream's real shape"

# 1. THE fixture: the assignment and its call site verbatim from our pinned build, wrapped in a
#    def so the whole file is parseable python (case 2 needs that). Indented four spaces inside a
#    function, no trailing comment -- exactly what the regex has to survive.
printf '%s\n' \
    "def make_compat_config(ret, utilities):" \
    "    ret.add('gamedrive')" \
    "" \
    "    MODERN_DXVK_FEATURES = ['descriptorIndexing']" \
    "    if not utilities.primary_gpu_supports_vulkan(" \
    "        1, 3," \
    "        device_features=MODERN_DXVK_FEATURES" \
    "    ):" \
    "        ret.add('dxvksarek')" > "$TMP/proton"

if run_widen "$TMP/proton"; then
    if grep -qF "MODERN_DXVK_FEATURES = ['descriptorIndexing', 'storageBuffer8BitAccess']" "$TMP/proton"; then
        ok "the pinned build's probe gains storageBuffer8BitAccess"
    else
        bad "the rewrite ran but produced: $(grep -F 'MODERN_DXVK_FEATURES' "$TMP/proton")"
    fi
else
    bad "the rewrite failed on the shape our own pin ships: $(cat "$TMP/err")"
fi

# 2. The result is fed to a python interpreter on device, so a rewrite that lands valid TEXT but
#    invalid SYNTAX would break every game launch rather than just the a6xx ones.
if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP/proton" 2>"$TMP/err"; then
    ok "the rewritten script still parses as python"
else
    bad "the rewrite produced unparseable python: $(cat "$TMP/err")"
fi

# 3. The surrounding lines must be untouched -- the sarek fallback is what the probe selects, and
#    a regex that ate it would leave a device with no DXVK at all.
if grep -qF "ret.add('dxvksarek')" "$TMP/proton" && grep -qF "device_features=MODERN_DXVK_FEATURES" "$TMP/proton"; then
    ok "the fallback branch and the call site are left intact"
else
    bad "the rewrite disturbed the lines around the assignment"
fi

echo
echo "unrecognised upstream shapes stop the build"

# 4. Upstream widening its own probe must FAIL, not silently succeed: at that point this rewrite is
#    dead weight shadowing their logic, and the bump should delete it.
printf '%s\n' "    MODERN_DXVK_FEATURES = ['descriptorIndexing', 'storageBuffer8BitAccess']" > "$TMP/already"
if run_widen "$TMP/already"; then
    bad "an already-widened probe was accepted -- the dead rewrite would ride along unnoticed"
else
    grep -q "upstream fixed this" "$TMP/err" \
        && ok "an already-widened probe fails and says to drop the rewrite" \
        || bad "an already-widened probe fails, but not with a message that says what to do: $(cat "$TMP/err")"
fi

# 5. A probe that no longer checks descriptorIndexing is a probe whose meaning we no longer know.
printf '%s\n' "    MODERN_DXVK_FEATURES = ['somethingElse']" > "$TMP/moved"
if run_widen "$TMP/moved"; then
    bad "a probe with an unknown feature list was rewritten anyway"
else
    ok "an unrecognised feature list stops the build"
fi

# 6. Two assignments means the file is not the file we think it is. Positional matching on an
#    ambiguous target is how a rewrite lands in the wrong place and stays green.
printf '%s\n' \
    "    MODERN_DXVK_FEATURES = ['descriptorIndexing']" \
    "    MODERN_DXVK_FEATURES = ['descriptorIndexing']" > "$TMP/twice"
if run_widen "$TMP/twice"; then
    bad "two MODERN_DXVK_FEATURES assignments were accepted"
else
    ok "an ambiguous (duplicated) assignment stops the build"
fi

# 7. And the probe disappearing entirely -- the shape change most likely to look like success,
#    since a rewrite with nothing to do trivially "works".
printf '%s\n' "    ret.add('gamedrive')" > "$TMP/gone"
if run_widen "$TMP/gone"; then
    bad "a proton script with no probe at all was accepted"
else
    ok "a missing probe stops the build"
fi

echo
echo "the rewrite is wired where it belongs"

# 8. CachyOS only. GE ships DXVK 3 too but has NO probe and NO sarek to fall back to, so calling
#    this on GE would fail the build for a tool it cannot help.
if grep -q 'widen_dxvk_probe "\$PROTON_CACHY_TOOL"' "$ASSEMBLE"; then
    ok "the CachyOS tool gets the widened probe"
else
    bad "nothing calls widen_dxvk_probe on the CachyOS tool -- the rewrite never runs"
fi

if grep -q 'widen_dxvk_probe "\$PROTON_GE_TOOL"' "$ASSEMBLE"; then
    bad "widen_dxvk_probe is called on the GE tool, which has no probe and no sarek -- it will fail the build"
else
    ok "the GE tool is left alone (no probe, no fallback to select)"
fi

# 9. The reasoning is the only thing standing between this and a future reader deleting it as an
#    unexplained patch of somebody else's python.
if grep -q 'storage_8bit' "$ASSEMBLE" && grep -q 'fails OPEN' "$ASSEMBLE"; then
    ok "the assembler still records why (a7xx-only feature) and the known limit (fails open)"
else
    bad "widen_dxvk_probe lost its rationale -- the next reader has no reason to keep it"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
