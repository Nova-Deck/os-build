#!/usr/bin/env bash
# Offline check for the panel frame-length calibration library
# (rootfs/overlay/usr/lib/novadeck/novadeck_panel.py).
#
#   tests/test-panel-calibration.sh
#
# WHY THIS EXISTS. The calibration's whole job is a convergence policy — land in a narrow window
# just ABOVE nominal (below it is the gamescope floor-division failure the feature fixes) without
# ever landing on a value that grays the picture (ICNA3520 120 Hz: 2 mod 4, HW Odin 3) — and
# policies regress silently: a flipped comparison still exits 0. The per-unit serial stamping is
# the other sharp edge: a card moved between two boards must never apply one unit's trim to the
# other. And the measurement must not read a panel slow when a wakeup misses a vblank. All of it
# is decision logic, so this drives the REAL module against a fabricated sysfs and a simulated
# panel (1/rate linear in the frame-length knob) and asserts on the answers.
#
# NOT covered here: the DRM ioctls themselves (need a live display — exercised on hardware
# whenever the Panel tab shows a rate) and the kernel-side range check, which the tests stand
# in for by wrapping write_knob.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/rootfs/overlay/usr/lib/novadeck"

[[ -f $LIB_DIR/novadeck_panel.py ]] || { echo "novadeck_panel.py missing: $LIB_DIR" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Keep import bytecode out of rootfs/overlay/ (same trap as test-perf.sh: the assembler copies
# the tree verbatim).
export PYTHONPYCACHEPREFIX="$TMP/pycache"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

# Common prelude: the module, plus a simulated panel whose rate follows the live knob value
# through 1/rate = intercept + slope * value (the DDIC's frame = fixed lines + the knob).
# odin3() is fitted to the HW numbers: frame_len_120 76 -> 118.27 Hz, 44 -> 120.17 Hz.
run_py() { python3 - "$@" <<PYEOF
import json, os, sys
sys.path.insert(0, "$LIB_DIR")
import novadeck_panel as np

def panel(knob, intercept, slope, calls=None):
    def rate(seconds=None):
        if calls is not None:
            calls.append(int(open(knob).read()))
        return 1 / (intercept + slope * int(open(knob).read()))
    return rate

ODIN3_SLOPE = (1 / 118.27 - 1 / 120.17) / 32
ODIN3_INTERCEPT = 1 / 118.27 - 76 * ODIN3_SLOPE

def odin3(knob, calls=None):
    return panel(knob, ODIN3_INTERCEPT, ODIN3_SLOPE, calls)

def hz(intercept, slope, value):
    return 1 / (intercept + slope * value)

def in_window(rate, nominal):
    return nominal * (1 + np.MARGIN) <= rate <= nominal * (1 + np.CEILING)

REAL_WRITE = np.write_knob

def refuse_below(floor):
    def write(path, value):
        if value < floor:
            raise OSError(22, "Invalid argument")
        REAL_WRITE(path, value)
    np.write_knob = write

$PY_BODY
PYEOF
}

reset_knobs() {
  echo 76 > "$SYS/ae94000.dsi.0/frame_len_120"
  echo 2006 > "$SYS/ae94000.dsi.0/frame_len_60"
}

# --- fabricated panel: one mipi-dsi device with 120/60 knobs, plus a knobless neighbour
SYS="$TMP/sys"
mkdir -p "$SYS/ae94000.dsi.0" "$SYS/ae94000.dsi.1"
reset_knobs
printf 'SERIAL-A\0' > "$TMP/serial"

export NOVADECK_PANEL_SYSFS_GLOB="$SYS/*"
export NOVADECK_PANEL_STATE="$TMP/state/panel-calibration.json"
export NOVADECK_PANEL_DEFAULTS="$TMP/run/panel-defaults.json"
export NOVADECK_PANEL_SERIAL="$TMP/serial"

# ---------- knob discovery + serial + status (unmeasured) ----------
PY_BODY='
dev, knobs = np.panel_knobs()
assert dev.endswith("ae94000.dsi.0"), dev
assert sorted(knobs) == [60, 120], knobs
assert np.device_serial() == "SERIAL-A", np.device_serial()
s = np.status(measure=False)
assert s["supported"] is True
assert s["rates"] == [60, 120]
assert s["current"] == {"120": 76, "60": 2006}, s["current"]
assert s["saved"] == {} and s["defaults"] == {}
assert s["measuredHz"] is None
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "knob discovery / status"

# ---------- nominal inference ----------
PY_BODY='
assert np.infer_nominal(118.35, [60, 120]) == 120   # the Odin 3 field case
assert np.infer_nominal(59.97, [60, 120]) == 60
assert np.infer_nominal(90.0, [60, 120]) is None    # between modes: refuse, do not guess
assert np.infer_nominal(50.0, []) is None
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "nominal inference"

# ---------- the measurement counts vblanks by SEQUENCE, so a missed wakeup does not read slow ----------
PY_BODY='
# A 120 Hz panel, and a reader that oversleeps: every third wait returns two vblanks later.
state = {"seq": 1000, "n": 0}
def wait(fd, pipe):
    state["n"] += 1
    state["seq"] += 2 if state["n"] % 3 == 0 else 1
    return state["seq"], state["seq"] / 120.0
clock = {"t": 0.0}
np._wait_vblank = wait
np.time.monotonic = lambda: clock.__setitem__("t", clock["t"] + 0.004) or clock["t"]
rate = np._measure(None, 0, 1.0)
assert abs(rate - 120.0) < 1e-6, rate
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "sequence-based measurement survives missed wakeups"

# ---------- calibration lands INSIDE the window, from below, and does not save ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
result = np.calibrate(rate_fn=odin3(knob))
assert result["rate"] == 120 and result["startValue"] == 76, result
final = int(open(knob).read())
assert final == result["value"], (final, result)
assert in_window(hz(ODIN3_INTERCEPT, ODIN3_SLOPE, final), 120), final
# No compatible on this fabricated panel: no gray rule, so the plain model answer stands.
assert not os.path.exists(os.environ["NOVADECK_PANEL_STATE"])   # live, unsaved
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration converges into the window, unsaved"

# ---------- an ICNA3520 never lands on (or steps onto) a gray value: 2 mod 4 at 120 Hz ----------
reset_knobs
mkdir -p "$SYS/ae94000.dsi.0/of_node"
printf 'chipone,icna3520\0' > "$SYS/ae94000.dsi.0/of_node/compatible"
PY_BODY='
knob = np.panel_knobs()[1][120]
calls = []
result = np.calibrate(rate_fn=odin3(knob, calls))
# The window holds only 46 (HW: gray). 47 is below 120, so the clean value just above wins: 45.
assert result["value"] == 45, result
assert hz(ODIN3_INTERCEPT, ODIN3_SLOPE, 45) >= 120
assert not [v for v in calls if v % 4 == 2], calls      # not even measured on the way
open(knob, "w").write("47")
assert np.step(120, "faster", rate_fn=odin3(knob))["value"] == 45
assert np.step(120, "slower", rate_fn=odin3(knob))["value"] == 47
knob60 = np.panel_knobs()[1][60]
assert np.usable_fn(knob60)(2006)                       # the 60 Hz knob has no gray rule
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "ICNA3520 120 Hz skips the gray values"
rm -rf "$SYS/ae94000.dsi.0/of_node"

# ---------- 60 Hz, from ABOVE nominal ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][60]
slope = 1 / 60.9 / 2006 * 0.5          # a finer knob than the 120 one
intercept = 1 / 60.9 - 2006 * slope
result = np.calibrate(rate_fn=panel(knob, intercept, slope))
assert result["rate"] == 60, result
assert in_window(hz(intercept, slope, result["value"]), 60), result
assert int(open(knob).read()) == result["value"]
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration converges from above (60 Hz)"

# ---------- the window is out of range: the closest value still at or above nominal wins ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
refuse_below(70)                  # 70 scans ~118.6 Hz: nothing reachable is above nominal
try:
    np.calibrate(rate_fn=odin3(knob))
    print("no-error")
except RuntimeError as e:
    assert "did not reach" in str(e), e
    assert int(open(knob).read()) == 76   # restored
    # Floor just at nominal: 120.005 Hz is below the window but at or above 120, so it is kept.
    intercept = 1 / 120.005 - 44 * ODIN3_SLOPE
    open(knob, "w").write("50")
    refuse_below(44)
    result = np.calibrate(rate_fn=panel(knob, intercept, ODIN3_SLOPE))
    assert result["value"] == 44 and 120 <= result["endHz"] < 120 * (1 + np.MARGIN), result
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "out-of-range window: refuse below nominal, keep the at-nominal floor"

# ---------- a rate that does not follow the knob is the wrong CRTC: abort, restore ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
try:
    np.calibrate(rate_fn=lambda seconds=None: 118.3)
    print("no-error")
except RuntimeError as e:
    assert "did not follow" in str(e), e
    assert int(open(knob).read()) == 76
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "a rate that does not follow the knob aborts"

# ---------- a display that is still settling is refused ----------
reset_knobs
PY_BODY='
seq = iter([116.0, 118.3])
try:
    np.calibrate(rate_fn=lambda seconds=None: next(seq))
    print("no-error")
except RuntimeError as e:
    assert "not steady" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "an unsteady display is refused"

# ---------- a mode switch during the probe aborts and restores ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
real = odin3(knob)
n = {"i": 0}
def rate(seconds=None):
    n["i"] += 1
    return real() if n["i"] <= 3 else 60.0   # after the probe reading, the panel drops to 60
try:
    np.calibrate(rate_fn=rate)
    print("no-error")
except RuntimeError as e:
    assert "changed during calibration" in str(e), e
    assert int(open(knob).read()) == 76
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "a mode switch during the probe aborts"

# ---------- a rate matching no knob refuses instead of guessing ----------
PY_BODY='
try:
    np.calibrate(rate_fn=lambda seconds=None: 90.0)
    print("no-error")
except RuntimeError as e:
    assert "matches no calibratable rate" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "unmatchable rate refuses"

# ---------- manual step: one value, lower is faster, the range end is reported ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
r = np.step(120, "faster", rate_fn=odin3(knob))
assert r["value"] == 75 and r["limit"] is None and int(open(knob).read()) == 75, r
assert r["measuredHz"] > 118.27, r
r = np.step(120, "slower", rate_fn=odin3(knob))
assert r["value"] == 76, r
refuse_below(76)
r = np.step(120, "faster", rate_fn=odin3(knob))
assert r["value"] == 76 and r["limit"] == "range", r
def broken(path, value):
    raise OSError(5, "Input/output error")
np.write_knob = broken
try:
    np.step(120, "faster", rate_fn=odin3(knob))
    print("no-error")
except OSError as e:
    assert e.errno == 5     # a DSI failure is not reported as the range end
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "manual step"

# ---------- a guess past the SLOW end of the range walks back into it ----------
reset_knobs
PY_BODY='
knob = np.panel_knobs()[1][120]
def write(path, value):
    if value > 80:
        raise OSError(22, "Invalid argument")
    REAL_WRITE(path, value)
np.write_knob = write
# Fast panel: 76 scans ~120.5 Hz, the window needs ~84, beyond the 80 ceiling of the range.
intercept = 1 / 120.5 - 76 * ODIN3_SLOPE
calls = []
result = np.calibrate(rate_fn=panel(knob, intercept, ODIN3_SLOPE, calls))
# Even the slowest value is above the window: it is the closest to nominal, so it wins, after
# walking back INTO the range from the out-of-range guess.
assert result["value"] == 80 and int(open(knob).read()) == 80, result
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "out-of-range guess on the slow side"

# ---------- apply records the driver defaults FIRST, then writes this unit's values ----------
reset_knobs
PY_BODY='
knobs = np.panel_knobs()[1]
np.save_state({"SERIAL-A": {"120": 48, "60": 1996}, "SERIAL-B": {"120": 999}})
applied = np.apply_saved()
assert applied == {"120": 48, "60": 1996}, applied
assert int(open(knobs[120]).read()) == 48
assert np.load_defaults() == {"120": 76, "60": 2006}, np.load_defaults()
np.apply_saved()                      # a second apply must not record 48 as the default
assert np.load_defaults() == {"120": 76, "60": 2006}, np.load_defaults()
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "apply records defaults, then writes this unit's values"

# ---------- save / revert: saving the default clears the entry ----------
PY_BODY='
knob = np.panel_knobs()[1][120]
np.set_value(120, 52)
assert np.save(120) == {"rate": 120, "saved": 52}
assert np.load_state()["SERIAL-A"]["120"] == 52
assert np.load_state()["SERIAL-B"] == {"120": 999}    # other units untouched
np.set_value(120, 60)
np.revert(120)
assert int(open(knob).read()) == 52                  # back to the saved value
np.set_value(120, 76)
assert np.save(120)["saved"] is None                 # the driver default = no entry
assert "120" not in np.load_state()["SERIAL-A"]
np.set_value(120, 60)
np.revert(120)
assert int(open(knob).read()) == 76                  # no entry: back to the default
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "save / revert"

# ---------- apply on the OTHER unit: nothing written (the stamped-to-device contract) ----------
PY_BODY='
open(os.environ["NOVADECK_PANEL_SERIAL"], "wb").write(b"SERIAL-C\x00")
knob = np.panel_knobs()[1][120]
open(knob, "w").write("76")
applied = np.apply_saved()
assert applied == {}, applied
assert int(open(knob).read()) == 76
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "apply is inert on a different unit"
printf 'SERIAL-A\0' > "$TMP/serial"

# ---------- the measured CRTC is the primary connector's, from device-env ----------
DRM="$TMP/drm"
mkdir -p "$DRM/card1-DSI-1" "$DRM/card1-DSI-2" "$DRM/card1-DP-1"
echo 31 > "$DRM/card1-DSI-1/connector_id"; echo connected > "$DRM/card1-DSI-1/status"
echo 33 > "$DRM/card1-DSI-2/connector_id"; echo connected > "$DRM/card1-DSI-2/status"
printf '#!/bin/sh\necho "NOVADECK_DEVICE_ID=ayn-thor"\necho "NOVADECK_PRIMARY_CONNECTOR=DSI-2"\n' > "$TMP/device-env"
chmod +x "$TMP/device-env"
printf '#!/bin/sh\necho "NOVADECK_PRIMARY_CONNECTOR=\x27\x27"\n' > "$TMP/device-env-none"
chmod +x "$TMP/device-env-none"
PY_BODY='
os.environ["NOVADECK_PANEL_DRM_SYSFS"] = "'"$DRM"'"
os.environ["NOVADECK_PANEL_DEVICE_ENV"] = "'"$TMP/device-env"'"
assert np._connector_node() == ("card1", 33), np._connector_node()       # not the first DSI
os.environ["NOVADECK_PANEL_CONNECTOR"] = "DSI-1"
assert np._connector_node() == ("card1", 31)                            # operator override
del os.environ["NOVADECK_PANEL_CONNECTOR"]
os.environ["NOVADECK_PANEL_DEVICE_ENV"] = "'"$TMP/device-env-none"'"
try:
    np._connector_node()
    print("no-error")
except np.NoDisplay as e:
    assert "several DSI panels" in str(e), e                            # refuse, do not guess
    open("'"$DRM"'/card1-DSI-2/status", "w").write("disconnected\n")
    assert np._connector_node() == ("card1", 31)                        # the only connected one
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "panel connector resolution"

# ---------- no knobs: status degrades, calibrate refuses ----------
PY_BODY='
os.environ["NOVADECK_PANEL_SYSFS_GLOB"] = os.environ["NOVADECK_PANEL_SYSFS_GLOB"].replace("*", "ae94000.dsi.1")
s = np.status(measure=False)
assert s["supported"] is False and s["rates"] == []
assert np.apply_saved() == {}
try:
    np.calibrate(rate_fn=lambda seconds=None: 120.0)
    print("no-error")
except RuntimeError as e:
    assert "no frame_len" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "knobless board degrades cleanly"

# ---------- the CLI wrapper emits JSON and the right exit codes ----------
CLI="$LIB_DIR/panel-calibration"
out=$("$CLI" status --quick) && echo "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["supported"] is True' && ok || fail "CLI status --quick"
out=$("$CLI" set 120 64) && [[ $(cat "$SYS/ae94000.dsi.0/frame_len_120") == 64 ]] && ok || fail "CLI set"
out=$("$CLI" bogus 2>/dev/null); [[ $? -eq 1 && $out == *'"error"'* ]] && ok || fail "CLI unknown command errors"
out=$("$CLI" step 120 sideways 2>/dev/null); [[ $? -eq 1 && $out == *'"error"'* ]] && ok || fail "CLI step validates its direction"

# ---------- the boot unit is enabled without waiting for preset-all, and runs uncalibrated ----------
# The preset only fires on a first boot. A unit that arrives by OTA never gets one (the /etc
# overlay upper carries over), so without the shipped symlink it stays disabled and every reboot
# comes back uncalibrated (HW, Odin 3 internal install, 2026-10-23).
[[ -L $ROOT/rootfs/overlay/etc/systemd/system/multi-user.target.wants/novadeck-panel-calibration.service ]] \
  && ok || fail "novadeck-panel-calibration.service has no multi-user.target.wants symlink: enablement rides on first-boot presets alone"
# It must also run on a board that never saved a value: it records the driver defaults.
! grep -q '^ConditionPathExists=/var/lib/novadeck' "$ROOT/rootfs/overlay/usr/lib/systemd/system/novadeck-panel-calibration.service" \
  && ok || fail "the boot unit is gated on a saved calibration: the driver defaults never get recorded"

echo
echo "panel-calibration: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
