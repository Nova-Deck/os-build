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
# with the apply_* functions stubbed to capture what they would enforce, and so is
# apply_game_tree's touched-thread bookkeeping (which threads it writes, and that it puts
# them back) since that is decision logic rather than kernel effect.
#
# It also covers game-launch's apply_env, the launch-time half of the same settings file.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERF_DIR="$ROOT/fs-overlay/usr/lib/novadeck"

[[ -f $PERF_DIR/novadeck_perf.py ]] || { echo "novadeck_perf.py missing: $PERF_DIR" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Importing novadeck_perf makes CPython write a __pycache__ NEXT TO THE SOURCE — inside
# fs-overlay/, which images/assemble-rootfs.sh copies into the rootfs verbatim. Redirect the
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
# steam on a kernel WITHOUT CONFIG_PROC_CHILDREN: task dir exists, no children file
PROCNC="$TMP/proc-nochildren"
mkdir -p "$PROCNC/9000/task/9000"
printf 'steam\n' > "$PROCNC/9000/comm"

# --- tweaks: global + one enabled game, one entry missing "enabled" (must not apply)
cat > "$TMP/tweaks.json" <<'EOF'
{
  "global": {"gamescopeNice": 5, "gamescopeRr": false},
  "games": {
    "620": {"enabled": true, "gamescopeNice": -4, "gamescopeCores": "prime",
            "nice": -3, "cores": "big"},
    "990": {"gamescopeNice": -10}
  }
}
EOF

NOVADECK_PERF_SYSCPU="$SYS" NOVADECK_PERF_PROC="$PROC" \
TEST_TMP="$TMP" PERF_DIR="$PERF_DIR" ROOT_DIR="$ROOT" SYSU="$SYSU" PROCNC="$PROCNC" \
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

# tweaks merge — the game-launch contract
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
check("bool is not a nice", "gamescopeNice" in np.sanitize_perf({"gamescopeNice": True}), False)

# game-tree keys
game = np.sanitize_perf({"nice": -3, "cores": "big"})
check("game nice kept", game.get("nice"), -3)
check("game cores resolved", game.get("cores"), [2, 3, 4, 5, 6, 7])
check("game nice clamped", np.sanitize_perf({"nice": 99}).get("nice"), 19)
check("bad game cores dropped", "cores" in np.sanitize_perf({"cores": "nope"}), False)

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

# powerProfile: the same per-game-only contract, against powerd's persisted Profile. Asserted
# separately from `scheduler` because the two share per_game_choice() -- a change that broke the
# gating for one would break it for both, and this is what says so.
check("powerProfile not a sanitize_perf key",
      "powerProfile" in np.sanitize_perf({"powerProfile": "performance"}), False)
profile_tweaks = {
    "global": {"powerProfile": "performance"},
    "games": {
        "620": {"enabled": True, "powerProfile": "eco"},
        "700": {"enabled": True, "powerProfile": "turbo"},
        "800": {"enabled": False, "powerProfile": "performance"},
        "900": {"enabled": True},
    },
}
check("global powerProfile ignored", np.profile_for(profile_tweaks, None), None)
check("global profile not inherited by a game", np.profile_for(profile_tweaks, "900"), None)
check("per-game profile applies", np.profile_for(profile_tweaks, "620"), "eco")
check("bad profile dropped", np.profile_for(profile_tweaks, "700"), None)
check("disabled game has no profile", np.profile_for(profile_tweaks, "800"), None)
check("unknown appid has no profile", np.profile_for(profile_tweaks, "12345"), None)
# A LABEL is not a profile: the file speaks ids, and an operator's renamed label must not resolve.
check("label is not an id",
      np.profile_for({"games": {"1": {"enabled": True, "powerProfile": "Eco"}}}, "1"), None)
# powerd imports this as its PROFILES, and every id needs a [profile.<id>] section to exist.
check("profile domain", list(np.POWER_PROFILES), ["eco", "balanced", "performance"])

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
# 990 is the running game and it lacks "enabled", so neither system-wide override may appear --
# absence is what powerd reads as "restore the persisted choice".
check("no scheduler override for a disabled game", "scheduler" in values, False)
check("no profile override for a disabled game", "powerProfile" in values, False)

# ...and the same tick with 990 enabled carries both, keyed off the running game alone.
(tmp / "tweaks-override.json").write_text(
    '{"global": {"gamescopeNice": 5},'
    ' "games": {"990": {"enabled": true, "scheduler": "lavd", "powerProfile": "performance"}}}')
np.TWEAKS_CONFIG = tmp / "tweaks-override.json"
values = np.Enforcer().tick()
np.TWEAKS_CONFIG = tmp / "tweaks.json"
check("tick carries the scheduler override", values.get("scheduler"), "lavd")
check("tick carries the profile override", values.get("powerProfile"), "performance")

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

os.environ.pop("WINE_CPU_TOPOLOGY", None)
os.environ["TOMBSTONE_ME"] = "yes"
pw.apply_env({"cores": "2,3", "env": {"DXVK_HUD": "fps", "TOMBSTONE_ME": None}})
check("WINE_CPU_TOPOLOGY derived from cores", os.environ.get("WINE_CPU_TOPOLOGY"), "2:2,3")
check("per-game env applied", os.environ.get("DXVK_HUD"), "fps")
check("null env entry unsets", "TOMBSTONE_ME" in os.environ, False)

os.environ.pop("WINE_CPU_TOPOLOGY", None)
pw.apply_env({"cores": "2,3", "wineTopology": False})
check("wineTopology false suppresses it", os.environ.get("WINE_CPU_TOPOLOGY"), None)

os.environ["WINE_CPU_TOPOLOGY"] = "user-set"
pw.apply_env({"cores": "2,3"})
check("explicit user topology wins", os.environ.get("WINE_CPU_TOPOLOGY"), "user-set")

os.environ.pop("WINE_CPU_TOPOLOGY", None)
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
    {"Config": {"RootFS": "ArchLinux.ero", "ThunkHostLibs": "/usr/lib/fex-emu/HostThunks",
                "ThunkGuestLibs": "/usr/share/fex-emu/GuestThunks", "TSOEnabled": "1"},
     "ThunksDB": {"Vulkan": 0, "GL": 0}}))
pw.BASE_CONFIG = base_fex
fake_profiles = {"default": {"config": {"TSOEnabled": "1"}}, "fast": {"config": {"TSOEnabled": "0"}}}

os.environ["XDG_CACHE_HOME"] = str(fex_home)
os.environ["XDG_RUNTIME_DIR"] = str(tmp / "runtimedir")
written = pw.write_config({"fexProfile": "fast"}, "620", fake_profiles)
check("config lands under XDG_CACHE_HOME", written.parent, fex_home / "novadeck-fex")
check("config does not land in the runtime dir", (tmp / "runtimedir").exists(), False)
generated = _json.loads(written.read_text())
for key in ("RootFS", "ThunkHostLibs", "ThunkGuestLibs"):
    check(f"{key} is not handed to another FEX", key in generated["Config"], False)
check("tuning still applied", generated["Config"]["TSOEnabled"], "0")
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
      pw.resolve_thunks({"fexProfile": "default", "thunks": {"asound": False}}, base_thunks),
      {"asound": 0})
# The base config decides which thunks EXIST; a stray name cannot inject one, the same rule the
# `allowed` filter enforces for Config keys.
check("unknown thunk name is ignored",
      pw.resolve_thunks({"thunks": {"NotAThunk": True, "GL": True}}, base_thunks), {"GL": 1})
check("malformed thunks block is not a launch failure",
      pw.resolve_thunks({"thunks": "nonsense"}, base_thunks), {})

# A relative XDG_CACHE_HOME is invalid per XDG and portable FEX would re-anchor it.
os.environ["XDG_CACHE_HOME"] = "relative/cache"
os.environ["HOME"] = str(fex_home)
check("relative XDG_CACHE_HOME falls back to ~/.cache",
      pw.config_dir(), fex_home / ".cache" / "novadeck-fex")

# --- fex-profiles.json: the presets a user actually picks between.
# Nothing else reads these values until a game launches, so a preset that lost its point is
# invisible until someone plays the title it was supposed to rescue.
profiles_path = os.path.join(os.environ["ROOT_DIR"], "fs-overlay/usr/share/novadeck/fex-profiles.json")
contract = _json.loads(pathlib.Path(profiles_path).read_text())
profs = contract["profiles"]
check("the three presets exist", sorted(profs), ["compatible", "default", "fast"])
check("default runs Multiblock (matches the system FEX config)",
      profs["default"]["config"]["Multiblock"], "1")
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
