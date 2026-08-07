#!/usr/bin/env bash
# Offline check for the per-game perf library (fs-overlay/usr/lib/novadeck/novadeck_perf.py).
#
#   images/test-perf.sh
#
# WHY THIS EXISTS. Every input to the perf tick is a file whose absence is legal: the tweaks
# json is operator-created, /proc/<pid>/task/<tid>/children only exists with
# CONFIG_PROC_CHILDREN, cpu_capacity only exists on DT platforms, and the appid lives in
# another process's environ. Each degrade path is deliberately silent, which is exactly how a
# regression would ship: a typo'd merge contract or a broken tree walk still exits 0 and
# simply enforces nothing. So this drives the REAL module against fabricated /proc and sysfs
# trees and asserts on the answers.
#
# NOT covered here: the sched_setscheduler/setpriority/sched_setaffinity effects of
# apply_gamescope — those need live tids and a device. The tick's value plumbing IS covered,
# with apply_gamescope stubbed to capture what it would enforce.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERF_DIR="$ROOT/fs-overlay/usr/lib/novadeck"

[[ -f $PERF_DIR/novadeck_perf.py ]] || { echo "novadeck_perf.py missing: $PERF_DIR" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- fabricated sysfs: 2 little (cap 300) + 5 big (cap 800) + 1 prime (cap 1024), all online
SYS="$TMP/sys-cpu"
for c in 0 1 2 3 4 5 6 7; do mkdir -p "$SYS/cpu$c"; done
printf '0-7\n' > "$SYS/online"
for c in 0 1; do printf '300\n'  > "$SYS/cpu$c/cpu_capacity"; done
for c in 2 3 4 5 6; do printf '800\n'  > "$SYS/cpu$c/cpu_capacity"; done
printf '1024\n' > "$SYS/cpu7/cpu_capacity"

# uniform-capacity variant: every preset must collapse to all online
SYSU="$TMP/sys-cpu-uniform"
for c in 0 1 2 3; do mkdir -p "$SYSU/cpu$c"; printf '1024\n' > "$SYSU/cpu$c/cpu_capacity"; done
printf '0-3\n' > "$SYSU/online"

# --- fabricated /proc: steam(1234) -> reaper(1300, appid 620, older) -> pv(1400, appid 620)
#     plus a second, NEWER launch chain steam -> reaper(1500, appid 990)
#     and gamescope(2000) with a non-gamescope child (2100)
PROC="$TMP/proc"
mk_proc() { # pid comm children starttime [environ]
  local pid=$1 comm=$2 children=$3 start=$4 environ=${5-}
  mkdir -p "$PROC/$pid/task/$pid"
  printf '%s\n' "$comm" > "$PROC/$pid/comm"
  printf '%s\n' "$children" > "$PROC/$pid/task/$pid/children"
  printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
    "$pid" "$comm" "$start" > "$PROC/$pid/stat"
  [[ -n $environ ]] && printf '%b' "$environ" > "$PROC/$pid/environ"
  return 0
}
mk_proc 1234 steam       "1300 1500" 100
mk_proc 1300 reaper      "1400"      200 'HOME=/home/deck\0STEAM_COMPAT_APP_ID=620\0'
mk_proc 1400 pv-bwrap    ""          210 'SteamAppId=620\0'
mk_proc 1500 reaper      ""          300 'STEAM_COMPAT_APP_ID=990\0'
mk_proc 2000 gamescope   "2100"      50
mk_proc 2100 steamcompmgr ""         60
# steam on a kernel WITHOUT CONFIG_PROC_CHILDREN: task dir exists, no children file
PROCNC="$TMP/proc-nochildren"
mkdir -p "$PROCNC/9000/task/9000"
printf 'steam\n' > "$PROCNC/9000/comm"

# --- tweaks: global + one enabled game, one entry missing "enabled" (must not apply)
cat > "$TMP/tweaks.json" <<'EOF'
{
  "global": {"gamescopeNice": 5, "gamescopeRr": false},
  "games": {
    "620": {"enabled": true, "gamescopeNice": -4, "gamescopeCores": "prime"},
    "990": {"gamescopeNice": -10}
  }
}
EOF

NOVADECK_PERF_SYSCPU="$SYS" NOVADECK_PERF_PROC="$PROC" \
TEST_TMP="$TMP" PERF_DIR="$PERF_DIR" SYSU="$SYSU" PROCNC="$PROCNC" \
python3 - <<'PYEOF'
import os, pathlib, sys

sys.path.insert(0, os.environ["PERF_DIR"])
import novadeck_perf as np

tmp = pathlib.Path(os.environ["TEST_TMP"])
results = []
def check(name, got, want):
    results.append(("PASS", name) if got == want else ("FAIL", f"{name} (want {want!r}, got {got!r})"))
def raises(name, fn):
    try:
        fn()
    except ValueError:
        results.append(("PASS", name))
    else:
        results.append(("FAIL", f"{name} (no ValueError)"))

# cpulist grammar
check("parse simple", np.parse_cpulist("0,3-5"), [0, 3, 4, 5])
check("format compact", np.format_cpulist([3, 4, 5, 7]), "3-5,7")
check("roundtrip", np.parse_cpulist(np.format_cpulist([0, 2, 3, 4])), [0, 2, 3, 4])
raises("reject duplicates", lambda: np.parse_cpulist("1,1"))
raises("reject reversed range", lambda: np.parse_cpulist("5-3"))
raises("reject garbage", lambda: np.parse_cpulist("two"))

# topology presets from the fabricated sysfs
check("online cpus", np.online_cpus(), [0, 1, 2, 3, 4, 5, 6, 7])
check("preset little", np.preset_cpus("little"), [0, 1])
check("preset prime", np.preset_cpus("prime"), [7])
check("preset big", np.preset_cpus("big"), [2, 3, 4, 5, 6, 7])
check("preset all", np.preset_cpus("all"), [0, 1, 2, 3, 4, 5, 6, 7])

np.SYS_CPU_ROOT = pathlib.Path(os.environ["SYSU"])
check("uniform capacity collapses", np.preset_cpus("little"), [0, 1, 2, 3])
np.SYS_CPU_ROOT = pathlib.Path(os.environ["NOVADECK_PERF_SYSCPU"])

# resolve_cores
check("unset inherits", np.resolve_cores(None), None)
check("empty inherits", np.resolve_cores(""), None)
check("explicit list", np.resolve_cores("2,7"), [2, 7])
raises("reject offline cpu", lambda: np.resolve_cores("12"))

# tweaks merge — the proton-wrapper contract
np.TWEAKS_CONFIG = tmp / "tweaks.json"
tweaks = np.load_tweaks()
check("global only", np.settings_for(tweaks, None).get("gamescopeNice"), 5)
check("enabled game overlays", np.settings_for(tweaks, "620").get("gamescopeNice"), -4)
check("missing enabled ignored", np.settings_for(tweaks, "990").get("gamescopeNice"), 5)
np.TWEAKS_CONFIG = tmp / "no-such-file.json"
check("absent tweaks empty", np.load_tweaks(), {})
np.TWEAKS_CONFIG = tmp / "tweaks.json"

# sanitize
clean = np.sanitize_perf({"gamescopeNice": -99, "gamescopeRr": True,
                          "gamescopeCores": "prime", "enabled": True})
check("nice clamped", clean.get("gamescopeNice"), -20)
check("rr kept", clean.get("gamescopeRr"), True)
check("cores resolved", clean.get("gamescopeCores"), [7])
check("stray keys dropped", "enabled" in clean, False)
check("bad cores dropped", "gamescopeCores" in np.sanitize_perf({"gamescopeCores": "99"}), False)
check("non-int nice dropped", "gamescopeNice" in np.sanitize_perf({"gamescopeNice": "fast"}), False)

# /proc tree walk + appid detection
check("find steam", np.pids_by_comm(np.STEAM_COMMS), [1234])
check("descendants", sorted(np.descendant_pids(1234)), [1300, 1400, 1500])
cache = {}
check("newest launch wins", np.running_appid(cache), "990")
cache[7777] = "555"  # dead pid planted in the cache
np.running_appid(cache)
check("dead pid pruned", 7777 in cache, False)

np.PROC_ROOT = pathlib.Path(os.environ["PROCNC"])
check("no PROC_CHILDREN degrades", np.running_appid({}), None)
np.PROC_ROOT = pathlib.Path(os.environ["NOVADECK_PERF_PROC"])

# tick plumbing with enforcement stubbed out
seen = {}
np.apply_gamescope = lambda values: seen.update(values)
values = np.perf_tick({})
check("tick merges newest game", values.get("gamescopeNice"), 5)  # 990 lacks enabled -> global
check("tick reaches enforcement", seen.get("gamescopeNice"), 5)

for status, name in results:
    print(f"{status} {name}")
sys.exit(1 if any(s == "FAIL" for s, _ in results) else 0)
PYEOF
py_rc=$?

if [[ $py_rc -eq 0 ]]; then
  echo "test-perf: all checks passed"
else
  echo "test-perf: FAILURES above" >&2
fi
exit "$py_rc"
