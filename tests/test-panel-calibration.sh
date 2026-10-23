#!/usr/bin/env bash
# Offline check for the panel frame-length calibration library
# (rootfs/overlay/usr/lib/novadeck/novadeck_panel.py).
#
#   tests/test-panel-calibration.sh
#
# WHY THIS EXISTS. The calibration loop's whole job is a convergence policy — settle AT OR ABOVE
# nominal, never below, because a panel under nominal is exactly the gamescope floor-division
# failure the feature fixes — and policies regress silently: a flipped comparison still exits 0
# and "calibrates" every unit 0.2 Hz slow. The per-unit serial stamping is the other sharp edge:
# a card moved between two boards must never apply one unit's trim to the other. Both are pure
# decision logic, so this drives the REAL module against a fabricated sysfs and a simulated
# panel (rate as a linear function of the frame-length knob) and asserts on the answers.
#
# NOT covered here: the DRM vblank measurement (needs a live display — the ioctl path is
# exercised on hardware whenever the Panel tab shows a rate) and the sysfs knob's kernel-side
# range clamping.
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

run_py() { python3 - "$@" <<PYEOF
import json, os, sys
sys.path.insert(0, "$LIB_DIR")
import novadeck_panel as np

$PY_BODY
PYEOF
}

# --- fabricated panel: one mipi-dsi device with 120/60 knobs, plus a knobless neighbour
SYS="$TMP/sys"
mkdir -p "$SYS/ae94000.dsi.0" "$SYS/ae94000.dsi.1"
echo 76 > "$SYS/ae94000.dsi.0/frame_len_120"
echo 2006 > "$SYS/ae94000.dsi.0/frame_len_60"
printf 'SERIAL-A\0' > "$TMP/serial"

export NOVADECK_PANEL_SYSFS_GLOB="$SYS/*"
export NOVADECK_PANEL_STATE="$TMP/state/panel-calibration.json"
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
assert s["saved"] == {}
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

# ---------- calibration converges from BELOW nominal and settles at-or-above ----------
# Simulated panel: 0.05 Hz per knob count, stock value 76 scans 118.4 Hz (the measured Odin 3
# shape). Lower frame length -> faster. The fake clock advances on every sleep and measure.
PY_BODY='
class Panel:
    def __init__(self, stock, stock_hz, slope, knob):
        self.stock, self.stock_hz, self.slope, self.knob = stock, stock_hz, slope, knob
        self.t = 0.0
    def rate(self):
        self.t += np.MEASURE_S
        value = int(open(self.knob).read())
        return self.stock_hz + (self.stock - value) * self.slope
    def sleep(self, s):
        self.t += s
    def clock(self):
        return self.t

knob = np.panel_knobs()[1][120]
panel = Panel(76, 118.4, 0.05, knob)
result = np.calibrate(rate_fn=panel.rate, sleep=panel.sleep, clock=panel.clock)
assert result["rate"] == 120, result
final = int(open(knob).read())
assert final == result["value"], (final, result)
hz = panel.stock_hz + (panel.stock - final) * panel.slope
assert 0 <= hz - 120 <= np.tolerance_for(120), hz   # AT OR ABOVE nominal, never below
state = json.load(open(os.environ["NOVADECK_PANEL_STATE"]))
assert state["SERIAL-A"]["120"] == final, state
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration convergence from below"

# ---------- calibration from ABOVE nominal, 60 Hz knob, tighter tolerance ----------
PY_BODY='
knob = np.panel_knobs()[1][60]
class Panel:
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 60.9 + (2006 - int(open(knob).read())) * 0.01
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
result = np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock)
assert result["rate"] == 60, result
hz = 60.9 + (2006 - result["value"]) * 0.01
assert 0 <= hz - 60 <= np.tolerance_for(60), hz
state = json.load(open(os.environ["NOVADECK_PANEL_STATE"]))
assert state["SERIAL-A"]["60"] == result["value"]
assert state["SERIAL-A"]["120"] is not None   # the earlier rate survives the merge
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "calibration convergence from above (60 Hz)"

# ---------- an unreachable target restores the stock value and raises ----------
PY_BODY='
knob = np.panel_knobs()[1][120]
open(knob, "w").write("76")
class Panel:                       # knob has no effect: a broken DDIC never settles
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 110.0
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
try:
    np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock, deadline_s=30.0)
except RuntimeError:
    assert int(open(knob).read()) == 76   # restored, not left at the last wild guess
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "failure restores the stock value"

# ---------- a rate matching no knob refuses instead of guessing ----------
PY_BODY='
class Panel:
    t = 0.0
    def rate(self):
        Panel.t += np.MEASURE_S
        return 90.0
    def sleep(self, s):
        Panel.t += s
    def clock(self):
        return Panel.t
p = Panel()
try:
    np.calibrate(rate_fn=p.rate, sleep=p.sleep, clock=p.clock)
    print("no-error")
except RuntimeError as e:
    assert "matches no calibratable rate" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "unmatchable rate refuses"

# ---------- apply: this unit's values land, another unit's never do ----------
PY_BODY='
knobs = np.panel_knobs()[1]
open(knobs[120], "w").write("76")
open(knobs[60], "w").write("2006")
json.dump({"SERIAL-A": {"120": 48, "60": 1996}, "SERIAL-B": {"120": 999}},
          open(os.environ["NOVADECK_PANEL_STATE"], "w"))
applied = np.apply_saved()
assert applied == {"120": 48, "60": 1996}, applied
assert int(open(knobs[120]).read()) == 48
assert int(open(knobs[60]).read()) == 1996
print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "apply writes this unit's values"

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

# ---------- no knobs: status degrades, calibrate refuses ----------
PY_BODY='
os.environ["NOVADECK_PANEL_SYSFS_GLOB"] = os.environ["NOVADECK_PANEL_SYSFS_GLOB"].replace("*", "ae94000.dsi.1")
s = np.status(measure=False)
assert s["supported"] is False and s["rates"] == []
try:
    np.calibrate(rate_fn=lambda: 120.0)
    print("no-error")
except RuntimeError as e:
    assert "no frame_len" in str(e), e
    print("ok")
'
[[ $(run_py) == ok ]] && ok || fail "knobless board degrades cleanly"

# ---------- the CLI wrapper emits JSON and the right exit codes ----------
CLI="$LIB_DIR/panel-calibration"
out=$("$CLI" status --quick) && echo "$out" | python3 -c 'import json,sys; s=json.load(sys.stdin); assert s["supported"] is True' && ok || fail "CLI status --quick"
out=$("$CLI" bogus 2>/dev/null); [[ $? -eq 1 && $out == *'"error"'* ]] && ok || fail "CLI unknown command errors"

# ---------- the boot re-apply unit is enabled without waiting for preset-all ----------
# The preset only fires on a first boot. A unit that arrives by OTA never gets one (the /etc
# overlay upper carries over), so without the shipped symlink it stays disabled and every reboot
# comes back uncalibrated (HW, Odin 3 internal install, 2026-10-23).
[[ -L $ROOT/rootfs/overlay/etc/systemd/system/multi-user.target.wants/novadeck-panel-calibration.service ]] \
  && ok || fail "novadeck-panel-calibration.service has no multi-user.target.wants symlink: enablement rides on first-boot presets alone"

echo
echo "panel-calibration: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
