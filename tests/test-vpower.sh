#!/usr/bin/env bash
# Offline check for the /run/vpower publisher (rootfs/overlay/usr/lib/novadeck/vpower).
#
#   tests/test-vpower.sh
#
# WHY THIS EXISTS. Steam parses these files by exact word and by sign, and every way to get them
# wrong is silent. A "0" written for "no estimate" reads as "zero seconds left". A charging ETA
# leaking into secs_until_shutdown_request reads as a battery about to die. A status word Steam does
# not know just blanks the line. None of it logs anything. So this drives the REAL script's
# vpower_values() and publish() and asserts on the file CONTENTS they leave behind.
#
# NOT covered: the UPower D-Bus query and the sd_notify handshake. Those need a system bus.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPOWER="$ROOT/rootfs/overlay/usr/lib/novadeck/vpower"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

[[ -x $VPOWER ]] || { echo "vpower is missing or not executable: $VPOWER" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Keep CPython's bytecode out of rootfs/overlay/ (see test-perf.sh).
export PYTHONPYCACHEPREFIX="$TMP/pycache"

# run STATE PERCENT TIME_TO_FULL TIME_TO_EMPTY ON_BATTERY [IS_PRESENT] -> publishes into $TMP/out
run() {
    local present=${6:-True}
    mkdir -p "$TMP/out"
    python3 - "$VPOWER" "$TMP/out" "$1" "$2" "$3" "$4" "$5" "$present" <<'EOF'
import importlib.machinery, importlib.util, sys
from pathlib import Path
path, out, state, pct, ttf, tte, on_batt, present = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("vpower", path)
spec = importlib.util.spec_from_loader("vpower", loader)
vpower = importlib.util.module_from_spec(spec)
loader.exec_module(vpower)
device = {"IsPresent": present == "True", "State": int(state), "Percentage": float(pct),
          "TimeToFull": int(ttf), "TimeToEmpty": int(tte)}
vpower.publish(Path(out), vpower.vpower_values(device, on_batt == "True"))
EOF
}
f() { cat "$TMP/out/$1" 2>/dev/null || printf '<absent>'; }

echo "vpower:"

# --- charging: the case this whole daemon exists for. TimeToFull goes to the FULL file only.
run 1 42.5 3600 0 False
check "charging status"                  "$(f battery_status)"              "Charging"
check "charging ac"                      "$(f ac_status)"                   "Connected"
check "charging percent"                 "$(f battery_percent)"             "42.50"
check "charging ETA published"           "$(f secs_until_battery_full)"     "3600"
check "charging has no shutdown ETA"     "$(f secs_until_shutdown_request)" "-1"

# --- discharging: TimeToEmpty goes to the SHUTDOWN file only.
run 2 80 0 7200 True
check "discharging status"               "$(f battery_status)"              "Discharging"
check "discharging ac"                   "$(f ac_status)"                   "Disconnected"
check "discharging ETA published"        "$(f secs_until_shutdown_request)" "7200"
check "discharging has no full ETA"      "$(f secs_until_battery_full)"     "-1"

# --- plugged in but still draining (HW-observed on a 5V/0.36A charger): "Connected slow", and the
# discharge ETA stays, since that is what is actually happening.
run 2 25 0 5542 False
check "draining on AC is Connected slow" "$(f ac_status)"                   "Connected slow"
check "draining on AC keeps empty ETA"   "$(f secs_until_shutdown_request)" "5542"

# --- UPower's 0 means "no estimate yet"; it must never reach Steam as "0 seconds".
run 1 50 0 0 False
check "charging, no estimate -> -1"      "$(f secs_until_battery_full)"     "-1"
run 2 50 0 0 True
check "discharging, no estimate -> -1"   "$(f secs_until_shutdown_request)" "-1"

# --- a stale opposite-direction estimate is ignored (UPower can briefly keep both on a transition).
run 1 50 1800 9000 False
check "charging ignores TimeToEmpty"     "$(f secs_until_shutdown_request)" "-1"

# --- full, and held at a charge limit (pending charge): plugged in, no ETA either way.
run 4 100 0 0 False
check "full status"                      "$(f battery_status)"              "Full"
check "full has no ETA"                  "$(f secs_until_battery_full)"     "-1"
run 5 80 0 0 False
check "pending-charge status"            "$(f battery_status)"              "Not charging"
run 0 80 0 0 False
check "unknown state"                    "$(f battery_status)"              "Unknown"

# --- no battery: the files are withdrawn so Steam falls back to its generic backend.
run 1 50 3600 0 False
run 0 0 0 0 False False
check "no battery removes status"        "$(f battery_status)"              "<absent>"
check "no battery removes full ETA"      "$(f secs_until_battery_full)"     "<absent>"

# --- atomic writes leave no temporaries behind.
run 1 50 3600 0 False
check "no temporaries left"              "$(find "$TMP/out" -name '.*' | wc -l)" "0"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
