#!/usr/bin/env bash
# Offline check for the per-game perf library (rootfs/overlay/usr/lib/novadeck/novadeck_perf.py).
#
#   tests/test-perf.sh
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
# with the apply_* functions stubbed to capture what they would enforce, and so is
# apply_game_tree's touched-thread bookkeeping (which threads it writes, and that it puts
# them back) since that is decision logic rather than kernel effect.
#
# It also covers game-launch's apply_env, the launch-time half of the same settings file.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERF_DIR="$ROOT/rootfs/overlay/usr/lib/novadeck"

[[ -f $PERF_DIR/novadeck_perf.py ]] || { echo "novadeck_perf.py missing: $PERF_DIR" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Importing novadeck_perf makes CPython write a __pycache__ NEXT TO THE SOURCE — inside
# rootfs/overlay/, which rootfs/assemble-rootfs.sh copies into the rootfs verbatim. Redirect the
# bytecode into the sandbox so merely running the tests cannot dirty the tree. (The assembler
# prunes it and guard-rootfs.sh asserts on it; this is the near end of the same problem.)
export PYTHONPYCACHEPREFIX="$TMP/pycache"

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

# TIED-TOP variant: 2 little (300) + TWO matched top cores (1024). This is the topology
# `prime` gets wrong -- it returns the whole top-capacity class, i.e. 2 cpus -- and the
# reason singleCore is a modifier that guarantees exactly one.
SYST="$TMP/sys-cpu-tied"
for c in 0 1 2 3; do mkdir -p "$SYST/cpu$c"; done
for c in 0 1; do printf '300\n'  > "$SYST/cpu$c/cpu_capacity"; done
for c in 2 3; do printf '1024\n' > "$SYST/cpu$c/cpu_capacity"; done
printf '0-3\n' > "$SYST/online"

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
mk_proc 1234 steam       "1300 1500 1600" 100
mk_proc 1300 reaper      "1400"      200 'HOME=/home/deck\0STEAM_COMPAT_APP_ID=620\0'
mk_proc 1400 pv-bwrap    ""          210 'SteamAppId=620\0'
mk_proc 1500 reaper      ""          300 'STEAM_COMPAT_APP_ID=990\0'
# Observed on device: Steam runs the compat tool with appid 0 (prefix setup /
# tool probing). NEWEST of the lot, so an unfiltered sentinel would win.
mk_proc 1600 python3     ""          400 'STEAM_COMPAT_APP_ID=0\0'
mk_proc 2000 gamescope   "2100"      50
mk_proc 2100 steamcompmgr ""         60
# A Proton launch and a native one, as they look while the game runs. Not children of steam(1234):
# the pin tests hand apply_game_tree the pids themselves.
mk_launch() { # pid comm argv maps
  mk_proc "$1" "$2" "" 500
  printf '%b' "$3" > "$PROC/$1/cmdline"
  printf '%b' "$4" > "$PROC/$1/maps"
}
PROTON_ARGV='/opt/reaper\0SteamLaunch\0AppId=77\0--\0/opt/GE Proton/proton\0waitforexitandrun\0/g/game.exe\0'
WINE_LIB='7f0000000000-7f0000100000 r-xp 00000000 08:01 11 /opt/GE Proton/files/lib/wine'
mk_launch 3000 reaper      "$PROTON_ARGV" '7f00-7f10 r-xp 00000000 08:01 10 /usr/lib/libc.so.6\n'
mk_launch 3010 python3     'python3\0/opt/GE Proton/proton\0waitforexitandrun\0/g/game.exe\0' ''
mk_launch 3020 wineserver  '/opt/GE Proton/files/bin/wineserver\0' ''
mk_launch 3025 FEX         '/usr/bin/FEX\0/opt/GE Proton/files/bin/wineserver\0' ''
mk_launch 3026 sh          '/bin/sh\0-c\0/opt/GE Proton/files/bin/wineserver\0' ''
mk_launch 3027 pv-adverb   '/usr/bin/pv-adverb\0--\0/opt/GE Proton/files/bin/wineserver\0' ''
mk_launch 3028 run         '/opt/wineserver-tools/run\0' ''
# Mid-start: the unix half is loaded, wineserver has not been told about the process yet.
mk_launch 3030 wine        'wine\0c:\\\\windows\\\\system32\\\\steam.exe\0' "$WINE_LIB/aarch64-unix/ntdll.so\n"
mk_launch 3040 game.exe    'Z:\\\\g\\\\game.exe\0' "$WINE_LIB/aarch64-unix/ntdll.so\n$WINE_LIB/aarch64-windows/ntdll.dll\n"
mk_launch 3100 reaper      '/opt/reaper\0SteamLaunch\0AppId=78\0--\0/g/native-proton/game\0run\0' ''
# Launch options go through `sh -c`, which carries the whole command as one quoted argument.
mk_launch 3200 sh          "/bin/sh\0-c\0FOO=1 '/opt/GE Proton/proton' waitforexitandrun '/g/game.exe'\0" ''
# steam on a kernel WITHOUT CONFIG_PROC_CHILDREN: task dir exists, no children file
PROCNC="$TMP/proc-nochildren"
mkdir -p "$PROCNC/9000/task/9000"
printf 'steam\n' > "$PROCNC/9000/comm"

# --- tweaks: global + one enabled game, one entry missing "enabled" (must not apply)
cat > "$TMP/tweaks.json" <<'EOF'
{
  "global": {"gamescopeNice": 5},
  "games": {
    "620": {"enabled": true, "gamescopeNice": -4, "gamescopeCores": "prime",
            "nice": -3, "cores": "big"},
    "990": {"gamescopeNice": -10}
  }
}
EOF

NOVADECK_PERF_SYSCPU="$SYS" NOVADECK_PERF_PROC="$PROC" NOVADECK_CGROUP_ROOT="$TMP/cgroup" \
TEST_TMP="$TMP" PERF_DIR="$PERF_DIR" ROOT_DIR="$ROOT" SYSU="$SYSU" SYST="$SYST" PROCNC="$PROCNC" \
python3 - <<'PYEOF'
import os, pathlib, shutil, sys

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
# ...but singleCore must still yield exactly one, not "all online".
check("single on uniform still narrows to one",
      np.resolve_cores("all", single=True), [0])
np.SYS_CPU_ROOT = pathlib.Path(os.environ["NOVADECK_PERF_SYSCPU"])

# singleCore: a MODIFIER on the selection, never a replacement for it. The class comes from
# the preset, the count comes from the flag -- so a cheap title can pin one LITTLE core.
check("single narrows all -> fastest", np.resolve_cores("all", single=True), [7])
check("single narrows big -> fastest big", np.resolve_cores("big", single=True), [7])
check("single narrows little -> one little", np.resolve_cores("little", single=True), [0])
check("single with no preset narrows all online", np.resolve_cores(None, single=True), [7])
check("single narrows an explicit cpulist", np.resolve_cores("2,3", single=True), [2])
check("ties break to the lowest cpu number", np.resolve_cores("4,5,6", single=True), [4])
# The flag must not change anything when it is off -- including the inherit contract.
check("no single leaves the preset alone", np.resolve_cores("big"), [2, 3, 4, 5, 6, 7])
check("no single still inherits", np.resolve_cores(None), None)
raises("single does not excuse an unknown cpu",
       lambda: np.resolve_cores("99", single=True))

# THE REGRESSION GUARD this key exists for: two matched top cores. `prime` yields TWO cpus
# there, so a one-core workaround built on it silently becomes a two-core pin and the races
# it was hiding come back. singleCore must yield exactly one on the same topology.
np.SYS_CPU_ROOT = pathlib.Path(os.environ["SYST"])
check("prime returns the whole tied top class", np.preset_cpus("prime"), [2, 3])
check("single beats the tie", np.resolve_cores("prime", single=True), [2])
check("single beats the tie via all", np.resolve_cores("all", single=True), [2])
np.SYS_CPU_ROOT = pathlib.Path(os.environ["NOVADECK_PERF_SYSCPU"])

# sanitize_perf wiring: the flag rides on `cores`, works alone, and never touches gamescope.
check("sanitize applies singleCore",
      np.sanitize_perf({"cores": "big", "singleCore": True})["cores"], [7])
check("sanitize honours singleCore with no cores key",
      np.sanitize_perf({"singleCore": True})["cores"], [7])
check("sanitize leaves cores wide without the flag",
      np.sanitize_perf({"cores": "big"})["cores"], [2, 3, 4, 5, 6, 7])
check("singleCore never narrows gamescopeCores",
      np.sanitize_perf({"gamescopeCores": "big", "singleCore": True})["gamescopeCores"],
      [2, 3, 4, 5, 6, 7])
check("a non-true singleCore is not a pin",
      "cores" in np.sanitize_perf({"singleCore": "yes"}), False)

# resolve_cores
check("unset inherits", np.resolve_cores(None), None)
check("empty inherits", np.resolve_cores(""), None)
check("explicit list", np.resolve_cores("2,7"), [2, 7])
raises("reject offline cpu", lambda: np.resolve_cores("12"))

# tweaks merge — the game-launch contract
np.TWEAKS_CONFIG = tmp / "tweaks.json"
tweaks = np.load_tweaks()
check("global only", np.settings_for(tweaks, None).get("gamescopeNice"), 5)
check("enabled game overlays", np.settings_for(tweaks, "620").get("gamescopeNice"), -4)
check("missing enabled ignored", np.settings_for(tweaks, "990").get("gamescopeNice"), 5)
np.TWEAKS_CONFIG = tmp / "no-such-file.json"
check("absent tweaks empty", np.load_tweaks(), {})
# Only the compositor keys are system-wide. A game setting in "global" reached some games and not
# others (cores as a pin with no topology, FEX only where game-launch runs) and a game could not
# undo it, so it is not read there at all.
game_keys = {"nice": -5, "cores": "big", "singleCore": True, "wineTopology": False}
wide = {"global": {**game_keys, "gamescopeNice": 5, "gamescopeCores": "big"},
        "games": {"620": {"enabled": True, "nice": -3}, "700": {"cores": "prime"}}}
check("global carries the compositor keys only", np.settings_for(wide, None),
      {"gamescopeNice": 5, "gamescopeCores": "big"})
check("a game inherits no game setting from global", np.settings_for(wide, "620"),
      {"gamescopeNice": 5, "gamescopeCores": "big", "enabled": True, "nice": -3})
check("a game that is not enabled gets the compositor keys only", np.settings_for(wide, "700"),
      {"gamescopeNice": 5, "gamescopeCores": "big"})
check("a malformed global is no settings", np.settings_for({"global": ["gamescopeNice"]}, None), {})
np.TWEAKS_CONFIG = tmp / "tweaks.json"

# sanitize
clean = np.sanitize_perf({"gamescopeNice": -99, "gamescopeRr": True,
                          "gamescopeCores": "prime", "enabled": True})
check("nice clamped", clean.get("gamescopeNice"), -20)
# gamescopeRr is a RETIRED key: the tick no longer touches scheduling policy, so a
# tweaks file left over from an image that had the toggle must drop it, not carry it.
check("retired rr key dropped", "gamescopeRr" in clean, False)
check("cores resolved", clean.get("gamescopeCores"), [7])
check("stray keys dropped", "enabled" in clean, False)
check("bad cores dropped", "gamescopeCores" in np.sanitize_perf({"gamescopeCores": "99"}), False)
check("non-int nice dropped", "gamescopeNice" in np.sanitize_perf({"gamescopeNice": "fast"}), False)
check("bool is not a nice", "gamescopeNice" in np.sanitize_perf({"gamescopeNice": True}), False)

# game-tree keys
game = np.sanitize_perf({"nice": -3, "cores": "big"})
check("game nice kept", game.get("nice"), -3)
check("game cores resolved", game.get("cores"), [2, 3, 4, 5, 6, 7])
check("game nice clamped", np.sanitize_perf({"nice": 99}).get("nice"), 19)
check("bad game cores dropped", "cores" in np.sanitize_perf({"cores": "nope"}), False)

# With nothing to override, "all" is no pin: enforcing it would undo the game's own thread pinning on
# every tick. It still names the set that singleCore narrows, and still clears a gamescope pin.
check("cores all is no pin", "cores" in np.sanitize_perf({"cores": "all"}), False)
check("cores all with singleCore pins one", np.sanitize_perf({"cores": "all", "singleCore": True})["cores"], [7])
check("gamescopeCores all still clears a system-wide pin",
      np.sanitize_perf({"gamescopeCores": "all"})["gamescopeCores"], [0, 1, 2, 3, 4, 5, 6, 7])

# scheduler: per-game ONLY, and never merged through settings_for/sanitize_perf. A global
# section must not be able to set it -- the system-wide value is powerd's CpuScheduler, and a
# second home for it is the bug this asserts against.
check("scheduler not a sanitize_perf key", "scheduler" in np.sanitize_perf({"scheduler": "lavd"}), False)
sched_tweaks = {
    "global": {"scheduler": "lavd"},
    "games": {
        "620": {"enabled": True, "scheduler": "none"},
        "700": {"enabled": True, "scheduler": "bogus"},
        "800": {"enabled": False, "scheduler": "lavd"},
        "900": {"enabled": True},
    },
}
check("global scheduler ignored", np.scheduler_for(sched_tweaks, None), None)
check("global not inherited by a game", np.scheduler_for(sched_tweaks, "900"), None)
check("per-game none is explicit", np.scheduler_for(sched_tweaks, "620"), "none")
check("bad scheduler dropped", np.scheduler_for(sched_tweaks, "700"), None)
check("disabled game ignored", np.scheduler_for(sched_tweaks, "800"), None)
check("unknown appid", np.scheduler_for(sched_tweaks, "12345"), None)
check("lavd accepted", np.scheduler_for({"games": {"1": {"enabled": True, "scheduler": "lavd"}}}, "1"), "lavd")
# powerd imports this as its D-Bus enum, so the two domains cannot drift.
check("scheduler domain", list(np.SCHEDULERS), ["none", "lavd"])

# autoHdr: per-game only, like scheduler, and a JSON bool only — `1 in (True, False)` is true in
# Python, so a number would otherwise reach powerd as a non-bool.
hdr_tweaks = {
    "global": {"autoHdr": True},
    "games": {
        "620": {"enabled": True, "autoHdr": False},
        "630": {"enabled": True, "autoHdr": True},
        "700": {"enabled": True, "autoHdr": 1},
        "710": {"enabled": True, "autoHdr": "on"},
        "800": {"enabled": False, "autoHdr": True},
        "900": {"enabled": True},
    },
}
check("autoHdr: global ignored", np.auto_hdr_for(hdr_tweaks, None), None)
check("autoHdr: global not inherited by a game", np.auto_hdr_for(hdr_tweaks, "900"), None)
check("autoHdr: per-game off is explicit", np.auto_hdr_for(hdr_tweaks, "620"), False)
check("autoHdr: per-game on", np.auto_hdr_for(hdr_tweaks, "630"), True)
check("autoHdr: a number is not a bool", np.auto_hdr_for(hdr_tweaks, "700"), None)
check("autoHdr: a string is not a bool", np.auto_hdr_for(hdr_tweaks, "710"), None)
check("autoHdr: disabled game ignored", np.auto_hdr_for(hdr_tweaks, "800"), None)
check("autoHdr not a sanitize_perf key", "autoHdr" in np.sanitize_perf({"autoHdr": True}), False)
# gamescope's own Parse<bool> (convar.h): a leading number is its truth, else only "true".
for text, want in (("1", True), ("0", False), ("2", True), ("true", True), ("True", False),
                   ("yes", False), ("", False), ("1x", True), ("0x", False)):
    check(f"convar bool {text!r}", np.parse_convar_bool(text), want)

# powerProfile is GONE: Steam's per-game performance settings own the profile now. A key left in
# an older tweaks file must stay inert, never a sanitize_perf key and never carried by the tick
# (asserted on the tick below).
check("powerProfile not a sanitize_perf key",
      "powerProfile" in np.sanitize_perf({"powerProfile": "performance"}), False)
check("no per-game profile resolver remains", hasattr(np, "profile_for"), False)

# /proc tree walk + appid detection
check("find steam", np.pids_by_comm(np.STEAM_COMMS), [1234])
# One walk answering both comm sets: the index must group by comm, and feeding it
# back to pids_by_comm must give exactly what a fresh walk would.
idx = np.comm_index(np.STEAM_COMMS + np.GAMESCOPE_COMMS)
check("index groups by comm", sorted(idx), ["gamescope", "steam"])
check("indexed steam", np.pids_by_comm(np.STEAM_COMMS, idx), [1234])
check("indexed gamescope", np.pids_by_comm(np.GAMESCOPE_COMMS, idx), [2000])
check("index omits unmatched comms", np.pids_by_comm(("nosuchcomm",), idx), [])
check("descendants", sorted(np.descendant_pids(1234)), [1300, 1400, 1500, 1600])
cache = {}
appid, tree = np.scan_games(cache)
check("newest launch wins", appid, "990")
check("game tree is that launch only", sorted(tree), [1500])
check("steam itself never tagged", 1234 in tree, False)
check("appid 0 sentinel ignored", 1600 in tree, False)
cache[7777] = (1, "555")  # dead pid planted in the cache
np.scan_games(cache)
check("dead pid pruned", 7777 in cache, False)
# pid reuse: same pid, different starttime -> the cached answer must be dropped
cache[1500] = (999999, "111")
check("pid reuse re-reads environ", np.scan_games(cache)[0], "990")

np.PROC_ROOT = pathlib.Path(os.environ["PROCNC"])
check("no PROC_CHILDREN degrades", np.running_appid({}), None)
np.PROC_ROOT = pathlib.Path(os.environ["NOVADECK_PERF_PROC"])

# game-tree bookkeeping: what it touches, and that it puts it back.
# The syscalls themselves are stubbed; only the decisions are under test.
real_getpri, real_setpri = os.getpriority, os.setpriority
applied, pinned = {}, []
os.getpriority = lambda which, tid: applied.get(tid, 0)
os.setpriority = lambda which, tid, value: applied.__setitem__(tid, value)
np._set_affinity = lambda tid, mask: pinned.append((tid, sorted(mask)))
# every thread starts unpinned unless a case below says otherwise
masks = {}
np._get_affinity = lambda tid: set(masks.get(tid, range(8)))
state = {"affinity": {}, "nice": {}, "baseline": {}}

np.apply_game_tree({"nice": -3, "cores": [2, 3]}, [1500], state)
check("game tree nice applied", applied.get(1500), -3)
check("game tree pinned", pinned, [(1500, [2, 3])])
check("state records the tid", 1500 in state["affinity"], True)
check("state records the ORIGINAL mask", sorted(state["affinity"][1500]), [0, 1, 2, 3, 4, 5, 6, 7])

pinned.clear()
np.apply_game_tree({}, [1500], state)  # tweak removed
check("affinity repaired to all", pinned, [(1500, [0, 1, 2, 3, 4, 5, 6, 7])])
check("nice restored to original", applied.get(1500), 0)
check("state cleared after repair", (len(state["affinity"]), len(state["nice"])), (0, 0))
# The baseline deliberately SURVIVES a repair: it is what this process looked like before
# novadeck ever touched it, and that stays true until the process exits.
check("baseline survives the repair", 1500 in state["baseline"], True)

# a thread the GAME pinned itself must be restored to ITS mask, not widened
masks[1500] = {4, 5}
selfpin = {"affinity": {}, "nice": {}, "baseline": {}}
pinned.clear()
np.apply_game_tree({"cores": [2, 3]}, [1500], selfpin)
check("self-pinned thread is overridden", pinned, [(1500, [2, 3])])
check("self-pinned original remembered", sorted(selfpin["affinity"][1500]), [4, 5])
pinned.clear()
np.apply_game_tree({}, [1500], selfpin)  # tweak removed
check("self-pinned thread restored, not widened", pinned, [(1500, [4, 5])])

# an original mask whose cpus all went offline cannot be restored verbatim
masks[1500] = {6, 7}
offline = {"affinity": {}, "nice": {}, "baseline": {}}
np.apply_game_tree({"cores": [2, 3]}, [1500], offline)
real_online = np.online_cpus
np.online_cpus = lambda: [0, 1, 2, 3]
pinned.clear()
np.apply_game_tree({}, [1500], offline)
check("unrestorable mask falls back to online cpus", pinned, [(1500, [0, 1, 2, 3])])
np.online_cpus = real_online
masks.clear()

# A THREAD BORN WHILE THE TWEAK IS IN FORCE. fork inherits nice AND affinity, so it arrives
# already carrying our values — recording "what it has now" as its original would record OUR
# tweak and make repair restore the tweak. HW-observed 2026-08-09: removing a tweak left 11 of
# Super Meat Boy's 15 threads at nice -5 / cpus 2-7 for exactly this reason.
# The fixture grows a second task dir between the two applies to be that new thread.
born = {"affinity": {}, "nice": {}, "baseline": {}}
np.apply_game_tree({"nice": -3, "cores": [2, 3]}, [1500], born)   # first apply: 1500 only
newtid = 1501
(np.PROC_ROOT / "1500" / "task" / str(newtid)).mkdir(parents=True, exist_ok=True)
applied[newtid] = -3                 # inherited our nice at fork
masks[newtid] = {2, 3}               # inherited our mask at fork
pinned.clear()
np.apply_game_tree({"nice": -3, "cores": [2, 3]}, [1500], born)   # second apply sees it
check("newborn thread's recorded nice is the process baseline, not our tweak",
      born["nice"][newtid], 0)
check("newborn thread's recorded mask is the process baseline, not our tweak",
      sorted(born["affinity"][newtid]), [0, 1, 2, 3, 4, 5, 6, 7])
applied[newtid], pinned[:] = -3, []
np.apply_game_tree({}, [1500], born)                              # tweak removed
check("newborn thread is repaired to the baseline, not left tweaked",
      applied.get(newtid), 0)
check("newborn thread's affinity is repaired too",
      sorted(dict(pinned).get(newtid, [])), [0, 1, 2, 3, 4, 5, 6, 7])

# ...but a thread born during our tenure that sets its OWN value keeps it: the value differs
# from what we enforce, so it cannot have come from us. (A game's SCHED_BATCH disk thread at
# nice 19 is the real case — HW-confirmed those return to 19, not 0.)
own = {"affinity": {}, "nice": {}, "baseline": {}}
(np.PROC_ROOT / "1500" / "task" / str(newtid)).rmdir()   # it must be born DURING this tenure
applied.pop(newtid, None)
np.apply_game_tree({"nice": -3}, [1500], own)
(np.PROC_ROOT / "1500" / "task" / str(newtid)).mkdir()
applied[newtid] = 19                 # born, then deprioritised itself
np.apply_game_tree({"nice": -3}, [1500], own)
check("a newborn thread's OWN nice is remembered verbatim", own["nice"][newtid], 19)
np.apply_game_tree({}, [1500], own)
check("a newborn thread's OWN nice is restored, not flattened", applied.get(newtid), 19)
(np.PROC_ROOT / "1500" / "task" / str(newtid)).rmdir()
applied.pop(newtid, None); masks.pop(newtid, None)
pinned.clear()

# wineTopology false: wineserver records the mask of any Wine process without a Wine parent, and
# every child inherits that record. So the launch chain is never pinned (the first Wine process
# inherits its mask), and a Wine process is pinned only once it has registered. wineserver itself is
# pinned: it records its clients' masks, never its own, and no Wine process inherits from it.
PROTON_TREE = [3000, 3010, 3020, 3030, 3040]
KEEP_TOPOLOGY = {"cores": [2, 3], "wineTopology": False}
def fresh_state():
    return {"affinity": {}, "nice": {}, "baseline": {}}
def pinned_pids(values, pids, state):
    pinned.clear()
    np.apply_game_tree(values, pids, state)
    return sorted(tid for tid, _mask in pinned)

check("sanitize carries wineTopology false with cores",
      np.sanitize_perf({"cores": "2,3", "wineTopology": False}), KEEP_TOPOLOGY)
check("sanitize drops wineTopology with nothing to pin",
      np.sanitize_perf({"wineTopology": False}), {})
check("sanitize drops the default", np.sanitize_perf({"cores": "2,3", "wineTopology": True}),
      {"cores": [2, 3]})

check("the default pins the whole Proton tree",
      pinned_pids({"cores": [2, 3]}, PROTON_TREE, fresh_state()), PROTON_TREE)
check("wineTopology false pins only registered Wine processes and wineserver",
      pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, fresh_state()), [3020, 3040])
check("...wineserver under an interpreter too",
      pinned_pids(KEEP_TOPOLOGY, [3000, 3025], fresh_state()), [3025])
check("...but not a launch chain that only names it",
      pinned_pids(KEEP_TOPOLOGY, [3000, 3026, 3027, 3028], fresh_state()), [])
check("...and nothing before Wine exists",
      pinned_pids(KEEP_TOPOLOGY, [3000, 3010], fresh_state()), [])
check("...nor when Steam ran the launch through sh -c",
      pinned_pids(KEEP_TOPOLOGY, [3200], fresh_state()), [])
check("a native game is pinned at once", pinned_pids(KEEP_TOPOLOGY, [3100], fresh_state()), [3100])
check("a tree with no readable argv is pinned at once",
      pinned_pids(KEEP_TOPOLOGY, [1500], fresh_state()), [1500])

# The process that was mid-start registers: the next tick pins it, and repair puts its own mask back.
late = fresh_state()
pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, late)
maps_3030 = np.PROC_ROOT / "3030" / "maps"
before = maps_3030.read_text()
maps_3030.write_text(before + (np.PROC_ROOT / "3040" / "maps").read_text())
check("a process is pinned on the tick after it registers",
      pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, late), [3020, 3030, 3040])
check("its own mask is what repair will restore",
      sorted(late["affinity"][3030]), [0, 1, 2, 3, 4, 5, 6, 7])
# Registering is one-way, and a loaded game's maps are large: a known process is not read again.
real_read, maps_read = np._read_proc, []
np._read_proc = lambda pid, name: (maps_read.append(pid) if name == "maps" else None) or real_read(pid, name)
check("a registered process stays pinned", pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, late), [3020, 3030, 3040])
check("...without its maps being read again", sorted(maps_read), [3000, 3010])
np._read_proc = real_read
maps_3030.write_text(before)
pinned_pids(KEEP_TOPOLOGY, [3000], late)
check("an exited process is forgotten", sorted(late["wine"]), [])
# Its pid may come back as another game's launch chain, which must not count as registered.
pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, late)
pinned_pids({}, [], late)
check("every process is forgotten when the game exits", late.get("wine"), None)
check("removing the tweak repairs the pinned processes only",
      (pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, late), pinned_pids({}, PROTON_TREE, late)),
      ([3020, 3040], [3020, 3040]))
# Those pins are the fallback. With a cpuset to be had, it holds the same processes and no thread
# is pinned one by one.
class FakeCpuset:
    def __init__(self, works=True):
        self.works, self.calls = works, []
    def hold(self, cpulist, pids):
        self.calls.append((cpulist, sorted(pids)))
        return self.works
    def release(self):
        self.calls.append("release")

held = {**fresh_state(), "cpuset": FakeCpuset()}
check("a cpuset replaces the thread pins", pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, held), [])
check("it holds the registered processes and wineserver", held["cpuset"].calls, [("2-3", [3020, 3040])])
check("turning the topology back on releases it and pins the tree",
      (pinned_pids({"cores": [2, 3]}, PROTON_TREE, held), held["cpuset"].calls[-1]),
      (PROTON_TREE, "release"))
check("...and off again hands those threads back",
      (pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, held), held["cpuset"].calls[-1], held["affinity"]),
      (PROTON_TREE, ("2-3", [3020, 3040]), {}))
np.apply_game_tree({}, PROTON_TREE, held)
check("removing the tweak releases it", held["cpuset"].calls[-1], "release")
np.apply_game_tree(KEEP_TOPOLOGY, PROTON_TREE, held)
np.apply_game_tree({}, [], held)
check("the game exiting releases it", held["cpuset"].calls[-1], "release")
early = {**fresh_state(), "cpuset": FakeCpuset()}
check("before Wine exists nothing is held", (pinned_pids(KEEP_TOPOLOGY, [3000, 3010], early),
      early["cpuset"].calls), ([], ["release"]))
broken = {**fresh_state(), "cpuset": FakeCpuset(works=False)}
check("no cpuset: the thread pin stands in", pinned_pids(KEEP_TOPOLOGY, PROTON_TREE, broken), [3020, 3040])
native = {**fresh_state(), "cpuset": FakeCpuset()}
check("a native game never uses the cpuset",
      (pinned_pids(KEEP_TOPOLOGY, [3100], native), native["cpuset"].calls), ([3100], ["release"]))
check("the daemon's own state carries one",
      type(np.Enforcer().game_state["cpuset"]).__name__, "GameCpuset")

# The cpuset itself, against a fake cgroupfs that moves processes the way the kernel does.
import novadeck_cpuset as nc
REL = "/user.slice/user-1000.slice/session-3.scope"
nc.CGROUP_ROOT, nc.PROC_ROOT = tmp / "cgroup", tmp / "cgproc"
class FakeKernel:
    def __init__(self, controllers, where):
        self.where, self.gone, self.forks, self.writes = dict(where), set(), [], []
        self.scope = nc.CGROUP_ROOT / REL[1:]
        shutil.rmtree(nc.CGROUP_ROOT, ignore_errors=True)
        self.scope.mkdir(parents=True)
        for name, text in (("cgroup.controllers", controllers), ("cgroup.subtree_control", "")):
            (self.scope / name).write_text(text)
    def read(self, path):
        if path.name == "cgroup":
            pid = int(path.parent.name)
            if pid not in self.where:
                raise FileNotFoundError
            return f"0::{self.where[pid]}\n"
        if path.name == "cgroup.procs":
            rel = "/" + str(path.parent.relative_to(nc.CGROUP_ROOT))
            return "".join(f"{p}\n" for p, w in self.where.items() if w == rel)
        return path.read_text() if path.exists() else ""
    def write(self, path, text):
        self.writes.append((path.parent.name, path.name, text))
        if path.name == "cgroup.procs":
            if int(text) in self.gone:
                self.where.pop(int(text), None)
                raise ProcessLookupError
            self.where[int(text)] = "/" + str(path.parent.relative_to(nc.CGROUP_ROOT))
            if self.forks:
                self.where[self.forks.pop()] = REL
            return
        if path.name == "cgroup.subtree_control":
            if REL in self.where.values():
                raise OSError(16, "Device or resource busy")
            text = "cpuset"
        path.write_text(text)
def boot(controllers="cpuset cpu memory pids", where=None):
    kernel = FakeKernel(controllers, where or {10: REL, 11: REL, 12: REL})
    nc._read, nc._write = kernel.read, kernel.write
    return kernel, nc.GameCpuset()
in_main, in_game = f"{REL}/novadeck-main", f"{REL}/novadeck-game"

k, c = boot()
check("hold succeeds", c.hold("2-3", [12]), True)
check("the game is held and the rest of the session is not", k.where,
      {10: in_main, 11: in_main, 12: in_game})
check("the pin is set before the game moves in",
      k.writes.index(("novadeck-game", "cpuset.cpus", "2-3"))
      < k.writes.index(("novadeck-game", "cgroup.procs", "12")), True)
k.writes.clear()
check("a hold already in force writes nothing", (c.hold("2-3", [12]), k.writes), (True, []))
check("changed cores are one write", (c.hold("6-7", [12]), k.writes),
      (True, [("novadeck-game", "cpuset.cpus", "6-7")]))
k.where[13] = in_main
c.hold("6-7", [12, 13])
check("a process that registers later joins", k.where[13], in_game)
c.release()
check("release lifts the restriction", k.writes[-1], ("novadeck-game", "cpuset.cpus", "\n"))
k.writes.clear()
c.release()
check("a second release writes nothing", k.writes, [])
check("a released cgroup is held again", (c.hold("2-3", [12]), k.where[12]), (True, in_game))
restarted = nc.GameCpuset()
restarted.release()
check("a restarted daemon lifts what the previous one set",
      nc._read(k.scope / "novadeck-game" / "cpuset.cpus"), "\n")
shutil.rmtree(nc.CGROUP_ROOT)
check("releasing after the session ended does not raise", c.release(), None)
k, c = boot()
c.hold("2-3", [12])
nc._write = lambda path, text: (_ for _ in ()).throw(OSError(19, "No such device"))
check("...nor when it ends during the release", c.release(), None)

k, c = boot(controllers="cpu memory pids")
check("no delegation: refused, and nothing is touched",
      (c.hold("2-3", [12]), k.writes, sorted(p.name for p in k.scope.iterdir())),
      (False, [], ["cgroup.controllers", "cgroup.subtree_control"]))
k, c = boot(); k.forks = [20, 21]
check("processes born while the session is moved are moved too",
      (c.hold("2-3", [12]), k.where[20], k.where[21]), (True, in_main, in_main))
k, c = boot(); k.forks = list(range(30, 200))
check("a session that will not drain is refused", c.hold("2-3", [12]), False)
k.forks = []
check("...and held on a later tick", (c.hold("2-3", [12]), k.where[12]), (True, in_game))
k, c = boot(); k.gone = {11, 12}
check("a process that exits while being moved is skipped", (c.hold("2-3", [12]), k.where), (True, {10: in_main}))
k, c = boot(where={10: REL, 12: "/user.slice/user-1000.slice/user@1000.service/app.slice/x.scope"})
check("a game outside a login session is refused", (c.hold("2-3", [12]), k.writes), (False, []))
k, c = boot(where={10: REL, 12: REL, 13: "/user.slice/user-1000.slice/user@1000.service/app.slice/x.scope"})
check("a game partly outside the session is refused whole", (c.hold("2-3", [12, 13]), k.writes), (False, []))
k, c = boot()
check("an exited process does not refuse the rest", (c.hold("2-3", [12, 99]), k.where[12]), (True, in_game))
k, c = boot()
check("a game that has exited is refused", (c.hold("2-3", [99]), k.writes), (False, []))

nice_state = fresh_state()
np.apply_game_tree({**KEEP_TOPOLOGY, "nice": -3}, PROTON_TREE, nice_state)
check("nice still reaches the whole tree", sorted(nice_state["nice"]), PROTON_TREE)
np.apply_game_tree({}, PROTON_TREE, nice_state)

pinned.clear()
np.apply_game_tree({}, [1500], state)
check("unconfigured tree is never written", pinned, [])

np.apply_game_tree({"nice": -3}, [1500], state)
np.apply_game_tree({"nice": -3}, [], state)  # game exited
check("dead tids forgotten", len(state["nice"]), 0)
os.getpriority, os.setpriority = real_getpri, real_setpri

# tick plumbing with enforcement stubbed out
seen = {}
np.apply_gamescope = lambda values, index=None: seen.update(values, _gs_index=index)
np.apply_game_tree = lambda values, pids, state: seen.update({"_pids": sorted(pids)})
# The tick must walk /proc exactly ONCE: both consumers share one comm_index.
# Only the root listdir counts -- the per-pid task/ listdirs are a different walk.
real_listdir = os.listdir
walks = []
os.listdir = lambda path: (walks.append(path)
                           if str(path) == str(np.PROC_ROOT) else None) or real_listdir(path)
values = np.Enforcer().tick()
os.listdir = real_listdir
check("tick walks /proc once", len(walks), 1)
check("tick shares the walk with gamescope", sorted(seen.get("_gs_index") or {}),
      ["gamescope", "steam"])
check("tick merges newest game", values.get("gamescopeNice"), 5)  # 990 lacks enabled -> global
check("tick reaches enforcement", seen.get("gamescopeNice"), 5)
check("tick hands the game tree over", seen.get("_pids"), [1500])
# 990 is the running game and it lacks "enabled", so the system-wide override may not appear --
# absence is what powerd reads as "restore the persisted choice".
check("no scheduler override for a disabled game", "scheduler" in values, False)

# ...and the same tick with 990 enabled carries the scheduler, keyed off the running game alone,
# while a leftover powerProfile key from an older file is not carried at all.
(tmp / "tweaks-override.json").write_text(
    '{"global": {"gamescopeNice": 5},'
    ' "games": {"990": {"enabled": true, "scheduler": "lavd", "powerProfile": "performance"}}}')
np.TWEAKS_CONFIG = tmp / "tweaks-override.json"
values = np.Enforcer().tick()
np.TWEAKS_CONFIG = tmp / "tweaks.json"
check("tick carries the scheduler override", values.get("scheduler"), "lavd")
check("tick ignores a leftover powerProfile", "powerProfile" in values, False)

# --- game-launch's half of the split: Wine-only env, applied before exec.
# Loaded by path because it ships without a .py extension. It imports
# novadeck_perf itself, which resolves to the fake-configured module above.
import importlib.machinery
import importlib.util
pw_path = os.path.join(os.environ["PERF_DIR"], "game-launch")
spec = importlib.util.spec_from_loader(
    "pw", importlib.machinery.SourceFileLoader("pw", pw_path))
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)

# The topology is exported under BOTH names: Proton keeps a table of titles it hands a fixed
# core count, and for those it overwrites WINE_CPU_TOPOLOGY with its own value unless
# PROTON_CPU_TOPOLOGY is set. A lone Wine name is silently discarded on exactly those games.
def clear_topology():
    for key in pw.TOPOLOGY_KEYS:
        os.environ.pop(key, None)


def topology():
    return tuple(os.environ.get(key) for key in pw.TOPOLOGY_KEYS)


clear_topology()
os.environ["TOMBSTONE_ME"] = "yes"
pw.apply_env({"cores": "2,3", "env": {"DXVK_HUD": "fps", "TOMBSTONE_ME": None}})
check("topology derived from cores, under both names", topology(), ("2:2,3", "2:2,3"))
check("per-game env applied", os.environ.get("DXVK_HUD"), "fps")
check("null env entry unsets", "TOMBSTONE_ME" in os.environ, False)

# wineTopology false must leave Wine with every CPU. Exporting nothing does not: on aarch64 Proton
# fills the gap from its own affinity. This is Proton's branch order (both baked Protons), run on
# what apply_env leaves behind -- `pinned_to` is Proton's own sched_getaffinity.
def proton_topology(appid, pinned_to, limits={"4000": "4"}, host=8):
    env = {key: os.environ[key] for key in pw.TOPOLOGY_KEYS if key in os.environ}
    if "PROTON_CPU_TOPOLOGY" in env:
        return env["PROTON_CPU_TOPOLOGY"]
    if appid in limits:
        return limits[appid]
    if "WINE_CPU_TOPOLOGY" not in env and len(pinned_to) < host:
        return f"{len(pinned_to)}:{','.join(map(str, pinned_to))}"
    return env.get("WINE_CPU_TOPOLOGY")


clear_topology()
check("the trap: no variable at all, and Proton derives from the pin",
      proton_topology("77", [2, 3]), "2:2,3")
# A bare count that is not below the host's CPU count is "no override" to Wine, so it stops the
# derivation without putting an identity mapping in front of the real topology.
pw.apply_env({"cores": "2,3", "wineTopology": False})
check("wineTopology false: Proton does not derive from the pin", proton_topology("77", [2, 3]), "8")
check("wineTopology false: Proton's own per-title limit still applies",
      proton_topology("4000", [2, 3]), "4")

clear_topology()
pw.apply_env({"singleCore": True, "wineTopology": False})
check("wineTopology false covers singleCore too", topology(), ("8", None))

clear_topology()
pw.apply_env({"wineTopology": False})
check("wineTopology false with nothing to pin exports nothing", topology(), (None, None))

clear_topology()
os.environ["PROTON_CPU_TOPOLOGY"] = "user-set"
pw.apply_env({"cores": "2,3", "wineTopology": False})
check("wineTopology false: an inherited value still wins", proton_topology("77", [2, 3]), "user-set")

clear_topology()
pw.apply_env({"cores": "2,3", "wineTopology": False, "env": {"WINE_CPU_TOPOLOGY": "1:2"}})
check("wineTopology false: a profile's value still wins", topology(), ("1:2", "1:2"))

clear_topology()
os.environ["WINE_CPU_TOPOLOGY"] = "user-set"
pw.apply_env({"cores": "2,3"})
check("inherited Wine topology wins, and carries over", topology(), ("user-set", "user-set"))

clear_topology()
os.environ["PROTON_CPU_TOPOLOGY"] = "user-set"
pw.apply_env({"cores": "2,3"})
check("inherited Proton topology wins, and carries over", topology(), ("user-set", "user-set"))

clear_topology()
pw.apply_env({"cores": "2,3", "env": {"WINE_CPU_TOPOLOGY": "1:2"}})
check("a profile naming one name sets both", topology(), ("1:2", "1:2"))

clear_topology()
pw.apply_env({"cores": "2,3", "env": {"PROTON_CPU_TOPOLOGY": "1:2"}})
check("...from either side", topology(), ("1:2", "1:2"))

clear_topology()
pw.apply_env({"cores": "2,3",
              "env": {"WINE_CPU_TOPOLOGY": "1:2", "PROTON_CPU_TOPOLOGY": "1:3"}})
check("a profile naming both is left verbatim", topology(), ("1:2", "1:3"))

clear_topology()
pw.apply_env({"cores": "2,3", "env": {"PROTON_CPU_TOPOLOGY": None}})
check("a tombstone on one unsets the pair", topology(), (None, None))

clear_topology()
clear_topology()
pw.apply_env({"cores": "all"})
check("cores all exports no topology", topology(), (None, None))
pw.apply_env({"cores": "all", "singleCore": True})
check("cores all with singleCore exports the one cpu", topology(), ("1:7", "1:7"))
clear_topology()

# game-launch reads this game's entry and nothing else: it only runs for games that have one.
launch = {"global": {"fexProfile": "fast", "cores": "big", "thunks": {"GL": True}, "env": {"A": "1"}},
          "games": {"620": {"enabled": True, "nice": -3}, "630": {"framegen": True, "env": {"B": "2"}}}}
pw.TWEAKS = tmp / "launch-tweaks.json"
import json as _launch_json
pw.TWEAKS.write_text(_launch_json.dumps(launch))
loaded = pw.load_tweaks({"games": {}})
check("a game takes nothing from global", pw.settings_for(loaded, "620"), {"enabled": True, "nice": -3})
check("a framegen-only game takes its env alone", pw.settings_for(loaded, "630"), {"env": {"B": "2"}})
check("a game with no entry takes nothing", pw.settings_for(loaded, "990"), {})

pw.apply_env({"cores": "bogus", "env": {"STILL": "applied"}})
check("bad cores does not block env", os.environ.get("STILL"), "applied")

# --- write_config: WHERE the config lands, and what it must not carry there.
# Both are silent failures in production — FEX skips an unreadable FEX_APP_CONFIG without a word,
# and a stray RootFS/Thunk*Libs points a foreign FEX at our tree instead of erroring.
import json as _json
fex_home = tmp / "fexhome"
fex_home.mkdir(exist_ok=True)
base_fex = tmp / "base-fex.json"
base_fex.write_text(_json.dumps(
    {"Comment": "the system FEX's own",
     "Config": {"RootFS": "ArchLinux.ero", "ThunkHostLibs": "/usr/lib/fex-emu/HostThunks",
                "ThunkGuestLibs": "/usr/share/fex-emu/GuestThunks", "TSOEnabled": "1",
                "MaxInst": "5000", "ProfileStats": "0", "SilentLog": "1"},
     "ThunksDB": {"Vulkan": 0, "GL": 0}}))
pw.BASE_CONFIG = base_fex
fake_profiles = {"strict": {"config": {"TSOEnabled": "1"}}, "fast": {"config": {"TSOEnabled": "0"}}}

os.environ["XDG_CACHE_HOME"] = str(fex_home)
os.environ["XDG_RUNTIME_DIR"] = str(tmp / "runtimedir")
written = pw.write_config({"fexProfile": "fast"}, "620", fake_profiles)
check("config lands under XDG_CACHE_HOME", written.parent, fex_home / "novadeck-fex")
check("config does not land in the runtime dir", (tmp / "runtimedir").exists(), False)
generated = _json.loads(written.read_text())
for key in ("RootFS", "ThunkHostLibs", "ThunkGuestLibs"):
    check(f"{key} is not handed to another FEX", key in generated["Config"], False)
check("tuning still applied", generated["Config"]["TSOEnabled"], "0")
# The system FEX's OTHER settings stay out as well. FEX_APP_CONFIG is the top layer, so a key copied
# from our base overrides the running FEX's own: Proton's MaxInst 500 became our 5000, for a user who
# only picked a profile or a thunk. What is written is exactly what was chosen.
check("a profile writes the profile's keys and nothing else", generated, {"Config": {"TSOEnabled": "0"}})
# REGRESSION GUARD, and the reason it is an ABSENCE rather than a value. FEX applies ThunksDB per
# library name across every config layer, FEX_APP_CONFIG last and therefore winning, and skips a
# layer that has no ThunksDB property at all (FileManagement.cpp). So writing the key here SEIZES
# every thunk from the FEX actually running the game -- which is usually not ours: Valve's compat
# tool curates ThunksDB per title, and FEX has its own Steam_<appid>_<exe> config mechanism.
# Until 2026-08-18 this wrote all-ON, reverting the thunkless base config on every launch and
# SIGSEGV'ing Valve's FEX on a native x86-64 Linux title (Parking Garage Rally Circuit, three
# launches for three crashes). Writing the base values instead would fix the crash but keep the
# seizure, so with no override we emit nothing.
check("no override writes no ThunksDB at all", "ThunksDB" in generated, False)

# resolve_thunks directly: EXPLICIT overrides only, honoured on ANY profile. The override used to
# be gated behind fexProfile == "custom", which no UI could ever select and which is not a profile
# in fex-profiles.json -- so it was unreachable and the "on" default was the only behaviour the
# product had. `base_thunks` now bounds the namespace and nothing else.
base_thunks = {"Vulkan": 0, "GL": 0, "asound": 1}
check("absent override defers entirely", pw.resolve_thunks({}, base_thunks), {})
check("override emits ONLY the named thunk",
      pw.resolve_thunks({"fexProfile": "fast", "thunks": {"Vulkan": True}}, base_thunks),
      {"Vulkan": 1})
check("override can also turn one off",
      pw.resolve_thunks({"fexProfile": "strict", "thunks": {"asound": False}}, base_thunks),
      {"asound": 0})
# The base config decides which thunks EXIST; a stray name cannot inject one, the same rule the
# `allowed` filter enforces for Config keys.
check("unknown thunk name is ignored",
      pw.resolve_thunks({"thunks": {"NotAThunk": True, "GL": True}}, base_thunks), {"GL": 1})
check("malformed thunks block is not a launch failure",
      pw.resolve_thunks({"thunks": "nonsense"}, base_thunks), {})

# --- issue #50: FEX_APP_CONFIG is ONE SLOT. Valve's compat tool and Proton generate Steam's
# curated per-title config only when the variable is unset, so a config we write "for
# completeness" ERASES that curation. Nothing explicit must therefore write nothing at all, and
# an explicit override must carry the curation along, reproduced from the same env vars.
for var in ("STEAM_FEX_TSOENABLED", "STEAM_FEX_MULTIBLOCK", "STEAM_COMPAT_FEX_CONFIG"):
    os.environ.pop(var, None)

check("nothing explicit claims no slot (perf-only tweaks leave Steam's curation alive)",
      pw.write_config({"nice": -5, "cores": "big"}, "620", fake_profiles), None)
# A profile name no profile declares is not an explicit choice either — falling back to some
# profile here is exactly the old clobber in disguise. "default" is such a name since it was
# dropped, and older tweaks files carry it.
check("bogus profile name is not an explicit choice",
      pw.write_config({"fexProfile": "bogus"}, "620", fake_profiles), None)
check("the dropped default profile is not an explicit choice",
      pw.write_config({"fexProfile": "default"}, "620", fake_profiles), None)

# Curation seeds the config; an explicit thunk override rides ON TOP of it, not instead of it.
os.environ["STEAM_FEX_TSOENABLED"] = "0"
written = pw.write_config({"thunks": {"GL": True}}, "620", fake_profiles)
generated = _json.loads(written.read_text())
check("appinfo curation survives a thunks-only override", generated["Config"]["TSOEnabled"], "0")
check("the explicit thunk override is carried", generated["ThunksDB"], {"GL": 1})
check("a thunks-only override carries curation and the thunk, no base key",
      generated, {"Config": {"TSOEnabled": "0"}, "ThunksDB": {"GL": 1}})
os.environ.pop("STEAM_FEX_TSOENABLED")
generated = _json.loads(pw.write_config({"thunks": {"GL": True}}, "620", fake_profiles).read_text())
check("with no curation either, only the thunk is written", generated, {"Config": {}, "ThunksDB": {"GL": 1}})
os.environ["STEAM_FEX_TSOENABLED"] = "0"

# An explicit profile is the user's deliberate choice and beats the curated value.
written = pw.write_config({"fexProfile": "strict"}, "620", fake_profiles)
generated = _json.loads(written.read_text())
check("explicit profile beats appinfo curation", generated["Config"]["TSOEnabled"], "1")

# Steam's own per-title UI (STEAM_COMPAT_FEX_CONFIG) keys are TRI-STATE, matching upstream
# CompatTool.cpp after 2b0d94536: Key:1 sets, Key:0 clears, an ABSENT key contributes nothing.
# The release python tool still pins absent keys to 0; upstream declared that a bug, and
# reproducing it would pin values the user never touched. Our explicit thunk states overlay the
# curated ones per name: their Vulkan choice survives, our GL choice wins.
os.environ["STEAM_COMPAT_FEX_CONFIG"] = "TSOEnabled:1,Multiblock:1,ThunksDB_Vulkan:1"
written = pw.write_config({"thunks": {"GL": True, "Vulkan": False}}, "620", fake_profiles)
generated = _json.loads(written.read_text())
check("Steam-UI curation seeds the config", generated["Config"]["Multiblock"], "1")
check("curated thunks merge with ours, ours winning per name",
      generated["ThunksDB"], {"GL": 1, "Vulkan": 0})
written = pw.write_config({"fexProfile": "fast"}, "620", fake_profiles)
generated = _json.loads(written.read_text())
check("curated thunks survive a profile-only override, absent names left unpinned",
      generated["ThunksDB"], {"Vulkan": 1})
os.environ["STEAM_COMPAT_FEX_CONFIG"] = "ThunksDB_Vulkan:0"
written = pw.write_config({"fexProfile": "fast"}, "620", fake_profiles)
generated = _json.loads(written.read_text())
check("a curated :0 is an explicit clear, not an absence", generated["ThunksDB"], {"Vulkan": 0})
check("tri-state: keys the Steam UI never named stay unpinned",
      generated["Config"]["TSOEnabled"], "0")  # fast profile's value, not a curated pin

for var in ("STEAM_FEX_TSOENABLED", "STEAM_FEX_MULTIBLOCK", "STEAM_COMPAT_FEX_CONFIG"):
    os.environ.pop(var, None)

# A relative XDG_CACHE_HOME is invalid per XDG and portable FEX would re-anchor it.
os.environ["XDG_CACHE_HOME"] = "relative/cache"
os.environ["HOME"] = str(fex_home)
check("relative XDG_CACHE_HOME falls back to ~/.cache",
      pw.config_dir(), fex_home / ".cache" / "novadeck-fex")

# --- fex-profiles.json: the presets a user actually picks between.
# Nothing else reads these values until a game launches, so a preset that lost its point is
# invisible until someone plays the title it was supposed to rescue.
profiles_path = os.path.join(os.environ["ROOT_DIR"], "rootfs/overlay/usr/share/novadeck/fex-profiles.json")
contract = _json.loads(pathlib.Path(profiles_path).read_text())
profs = contract["profiles"]
# No "default" preset: it forced the usual values over Steam's own per-title ones, where choosing
# nothing is what leaves them alone.
check("the presets are the two that differ from choosing none", sorted(profs), ["compatible", "fast"])
pw.PROFILES = pathlib.Path(profiles_path)
check("game-launch accepts the shipped contract", sorted(pw.load_profiles()["profiles"]), ["compatible", "fast"])
check("fast keeps Multiblock on", profs["fast"]["config"]["Multiblock"], "1")
# The escape hatch: at least one preset must stay conservative, or "try Compatible" stops meaning
# anything for a title that miscompiles under the aggressive JIT.
check("compatible keeps the conservative JIT settings",
      (profs["compatible"]["config"]["Multiblock"], profs["compatible"]["config"]["X87ReducedPrecision"]),
      ("0", "0"))

# --- game-launch: the launch-options entry point, end to end.
# Steam expands `%command%` to the whole chain it assembled, so this must exec argv[1] with the
# rest verbatim -- anything else silently drops the game. Run as a SUBPROCESS through the symlink,
# because the two things worth proving (the symlink resolves, and exec actually happens) cannot be
# observed by importing the module.
import subprocess
launch_link = os.path.join(os.environ["PERF_DIR"], "game-launch")
check("game-launch ships as one executable file (both callers run the same code)",
      os.path.isfile(launch_link) and not os.path.islink(launch_link)
      and os.access(launch_link, os.X_OK), True)

# The subprocess runs the REAL script, which reads /usr/share/novadeck/fex-profiles.json — absent
# on a build host. That is the point: this asserts the contract that matters at launch time, that
# a game still starts when tuning cannot be resolved. The config-writing half is covered above,
# against a monkeypatched BASE_CONFIG.
marker = tmp / "launched.txt"
fake_game = tmp / "fake-game.sh"
fake_game.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$MARKER"\nexit 0\n')
fake_game.chmod(0o755)
env = dict(os.environ)
env.update({"MARKER": str(marker), "SteamAppId": "620", "XDG_CACHE_HOME": str(fex_home)})
env.pop("FEX_APP_CONFIG", None)
rc = subprocess.call([launch_link, str(fake_game), "--verb=waitforexitandrun", "arg with space"],
                     env=env, stderr=subprocess.DEVNULL)
check("game-launch exits through the command it exec'd", rc, 0)
check("game-launch passes the whole chain through verbatim",
      marker.read_text().splitlines() if marker.exists() else [],
      ["--verb=waitforexitandrun", "arg with space"])

# Same entry point, nothing to exec: it must refuse rather than exit 0 having launched nothing.
rc = subprocess.call([launch_link], env=env, stderr=subprocess.DEVNULL)
check("game-launch with no command is an error", rc != 0, True)

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
