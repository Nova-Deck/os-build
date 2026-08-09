#!/usr/bin/env bash
# Offline check for the editable fan curve (fs-overlay/usr/bin/novadeck-powerd).
#
#   images/test-fan-curve.sh
#
# WHY THIS EXISTS. The curve is a three-layer config (/usr factory -> the operator's /etc
# file -> our own drop-in) whose failure modes are all SILENT. A drop-in that stops
# overriding, a resample that disagrees with what the fan tick actually runs, a reset that
# leaves the file in place, a quarantine path that drops the wrong layer -- every one of
# those exits 0 and simply blows the wrong amount of air. There is no error anyone sees.
#
# So this drives the REAL parse, resample, write and reset paths against fabricated config
# trees and asserts on the answers.
#
# NOT covered here: pwm1 writes and the D-Bus surface itself -- those need gi, a bus and a
# device. The property handlers are thin wrappers over the functions checked here.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERD="$ROOT/fs-overlay/usr/bin/novadeck-powerd"
FACTORY="$ROOT/fs-overlay/usr/share/novadeck/power-profiles.conf"

[[ -f $POWERD ]]  || { echo "novadeck-powerd missing: $POWERD" >&2; exit 1; }
[[ -f $FACTORY ]] || { echo "power-profiles.conf missing: $FACTORY" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

NOVADECK_POWERD_FACTORY="$FACTORY" NOVADECK_POWERD_ETC="$TMP/etc" \
python3 - "$POWERD" "$ROOT" "$TMP" <<'PYEOF'
import configparser
import importlib.machinery
import importlib.util
import os
import pathlib
import sys

powerd_path, root, tmp = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

# novadeck-powerd does `sys.path.insert(0, "/usr/lib/novadeck"); import novadeck_perf` at
# module scope. That path does not exist on the host, so point at the repo's copy first.
sys.path.insert(0, os.path.join(root, "fs-overlay/usr/lib/novadeck"))
spec = importlib.util.spec_from_loader(
    "powerd", importlib.machinery.SourceFileLoader("powerd", powerd_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

results = []
def check(name, got, want):
    results.append(("PASS" if got == want else f"FAIL (got {got!r}, want {want!r})", name))

def raises(name, fn):
    try:
        fn()
    except Exception:
        results.append(("PASS", name))
        return
    results.append(("FAIL (no exception)", name))

etc = pathlib.Path(os.environ["NOVADECK_POWERD_ETC"])
etc.mkdir(parents=True, exist_ok=True)

# __init__ globs sysfs and writes pwm1, so build the object without it and stub the
# device-touching half of the reload path. What stays real is everything this suite is
# about: the config layering, the curve maths, and the drop-in read/write.
def fresh():
    obj = pd.NovadeckPower.__new__(pd.NovadeckPower)
    obj.env = {}                      # no NOVADECK_SOC_CLASS -> underclock refs no-op
    obj.gpu_level = "auto"
    obj.manual_gpu_clock = 0
    obj.discover = lambda: None
    obj.apply_profile = lambda: None
    obj.load_config()
    obj.profile = obj.default_profile
    return obj

# ------------------------------------------------------------------ pure curve maths ---
# The factory "moderate" curve, as shipped.
moderate = pd.parse_fan_curve("96:255,90:204,84:153,78:102,72:77,0:51")
check("parse keeps every point", len(moderate), 6)
check("curve_pwm clamps below the floor", pd.curve_pwm(moderate, -5), 51)
check("curve_pwm clamps above the top", pd.curve_pwm(moderate, 130), 255)
check("curve_pwm hits a point exactly", pd.curve_pwm(moderate, 84), 153)
# 81 is the midpoint of 78:102 -> 84:153, so the interpolation must land on 127.5 -> 128.
check("curve_pwm interpolates", pd.curve_pwm(moderate, 81), 128)
check("curve_pwm on an empty curve", pd.curve_pwm([], 80), 0)

check("stops parse", pd.parse_curve_stops("60,70,80,90,100"), [60, 70, 80, 90, 100])
raises("stops must rise", lambda: pd.parse_curve_stops("60,80,70"))
raises("stops reject duplicates", lambda: pd.parse_curve_stops("60,60"))
raises("stops reject one point", lambda: pd.parse_curve_stops("60"))
raises("stops reject junk", lambda: pd.parse_curve_stops("60,abc"))
raises("stops reject out of range", lambda: pd.parse_curve_stops("60,130"))

# Resampling must be LOSSLESS at the stops: this is the promise the UI makes when it shows
# a factory curve on the sliders and claims that is what the fan is doing.
stops = [60, 70, 80, 90, 100]
sampled = pd.resample_curve(moderate, stops)
for stop, pwm in zip(stops, sampled):
    check(f"resample matches the curve at {stop}C", pwm, pd.curve_pwm(moderate, stop))
check("resample keeps one value per stop", len(sampled), len(stops))
check("resample of a round trip is stable",
      pd.resample_curve(list(zip(stops, sampled)), stops), sampled)

check("pwms clamp into range", pd.clean_curve_pwms([0, 0, 0, 0, 300], stops, 51, 255),
      [51, 51, 51, 51, 255])
check("pwms are forced to not fall", pd.clean_curve_pwms([200, 100, 150, 90, 255], stops, 51, 255),
      [200, 200, 200, 200, 255])
raises("pwms must match the stop count",
       lambda: pd.clean_curve_pwms([51, 77], stops, 51, 255))

# ------------------------------------------------------------------ layering ---
power = fresh()
check("factory stops are read from the config", power.fan_config["curve_stops"], stops)
check("factory profile starts on a factory curve", power.active_curve_name(), "moderate")
check("FanCurveIsCustom is false on factory",
      power.active_curve_name().startswith(pd.CUSTOM_CURVE_PREFIX), False)
check("factory curve resamples to the shipped moderate curve",
      power.fan_curve_pwms(), pd.resample_curve(moderate, stops))

# An operator's own /etc file must still win over factory and survive everything below.
(etc / "power-profiles.conf").write_text(
    "# operator notes that must never be eaten\n"
    "[fan_curve.operator]\n"
    "curve=95:255,60:51\n"
    "[profile.balanced]\n"
    "fan_curve=operator\n"
)
power = fresh()
check("operator /etc file overrides factory", power.active_curve_name(), "operator")
check("operator curve is what resamples", power.fan_curve_pwms(),
      pd.resample_curve(pd.parse_fan_curve("95:255,60:51"), stops))

# ------------------------------------------------------------------ write + reset ---
power.set_fan_curve([60, 90, 120, 180, 240])
check("write lands in the drop-in dir", pd.FAN_CURVE_DROPIN.exists(), True)
check("the drop-in outranks the operator file",
      power.active_curve_name(), f"{pd.CUSTOM_CURVE_PREFIX}balanced")
check("FanCurveIsCustom is true after a write",
      power.active_curve_name().startswith(pd.CUSTOM_CURVE_PREFIX), True)
check("what was written is what reads back", power.fan_curve_pwms(), [60, 90, 120, 180, 240])
check("and it is what the fan tick would run at a stop",
      pd.curve_pwm(power.active_curve(), 80), 120)
check("the operator's comments survived",
      "operator notes that must never be eaten" in (etc / "power-profiles.conf").read_text(),
      True)

# A second profile's curve must not clobber the first.
power.profile = "performance"
power.set_fan_curve([100, 130, 160, 200, 255])
check("second profile written", power.fan_curve_pwms(), [100, 130, 160, 200, 255])
power.profile = "balanced"
check("first profile untouched by the second", power.fan_curve_pwms(), [60, 90, 120, 180, 240])

# Only the shipped `temp:pwm` grammar goes to disk -- no new format to keep in step.
saved = configparser.ConfigParser()
saved.read(pd.FAN_CURVE_DROPIN)
check("drop-in uses the shipped curve grammar",
      saved.get(f"fan_curve.{pd.CUSTOM_CURVE_PREFIX}balanced", "curve"),
      "100:240,90:180,80:120,70:90,60:60")

power.reset_fan_curve()
check("reset drops only the active profile", power.active_curve_name(), "operator")
check("reset falls back to the operator curve, not factory", power.fan_curve_pwms(),
      pd.resample_curve(pd.parse_fan_curve("95:255,60:51"), stops))
check("the other profile's curve survives a single reset",
      sorted(pd.read_fan_dropin()), ["performance"])

power.reset_fan_curve(every=True)
check("resetting everything removes the file", pd.FAN_CURVE_DROPIN.exists(), False)
check("and the operator layer is still in charge", power.active_curve_name(), "operator")

# ------------------------------------------------------------------ quarantine ---
# A bad DROP-IN must be quarantined too. Dropping only the /etc file would leave the real
# culprit in place and re-break on the next boot, forever, with no visible error.
pd.CONFIG_DROPIN_DIR.mkdir(parents=True, exist_ok=True)
pd.FAN_CURVE_DROPIN.write_text("[fan]\nmin_pwm=not-a-number\n")
power = fresh()
check("a bad drop-in is quarantined", pd.FAN_CURVE_DROPIN.exists(), False)
check("quarantine renames out of the glob's reach",
      any(p.name.startswith("50-fan-curves.conf.invalid-")
          for p in pd.CONFIG_DROPIN_DIR.iterdir()), True)
check("and the daemon comes up on factory", power.fan_config["min_pwm"], 51)
check("quarantine took the /etc layer with it",
      (etc / "power-profiles.conf").exists(), False)

for status, name in results:
    print(f"{status} {name}")
sys.exit(1 if any(s.startswith("FAIL") for s, _ in results) else 0)
PYEOF
py_rc=$?

if [[ $py_rc -eq 0 ]]; then
  echo "test-fan-curve: all checks passed"
else
  echo "test-fan-curve: FAILURES above" >&2
fi
exit "$py_rc"
