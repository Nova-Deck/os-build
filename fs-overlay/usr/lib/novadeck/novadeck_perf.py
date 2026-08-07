"""novadeck_perf — per-game perf policy helpers for novadeck-powerd.

Owns three things:

  1. The cpulist grammar ("3-5,7") plus the named core presets (all / big /
     prime / little), resolved from sysfs cpu_capacity so no per-device core
     table has to be maintained.
  2. The game-tweaks read path: /etc/novadeck/game-tweaks.json, the SAME file
     and merge contract proton-wrapper uses for FEX profiles (global section,
     per-appid sections gated on "enabled": true). This module consumes the
     perf keys: gamescopeNice, gamescopeRr, gamescopeCores.
  3. The enforcement tick novadeck-powerd runs: find gamescope, find the
     running game's appid (walk the Steam client's process tree via
     /proc/<pid>/task/<tid>/children and read the game's environ — root only),
     and idempotently apply the merged gamescope thread policy.

Everything degrades to a no-op: a missing tweaks file, an absent gamescope, a
kernel without CONFIG_PROC_CHILDREN, or an unreadable environ must never take
the daemon down. All /proc and /sys access goes through PROC_ROOT/SYS_CPU_ROOT
so the offline suite (images/test-perf.sh) can drive this against a fabricated
tree with no root and no device.
"""
import json
import os
import pathlib

TWEAKS_CONFIG = pathlib.Path("/etc/novadeck/game-tweaks.json")
PROC_ROOT = pathlib.Path(os.environ.get("NOVADECK_PERF_PROC", "/proc"))
SYS_CPU_ROOT = pathlib.Path(
    os.environ.get("NOVADECK_PERF_SYSCPU", "/sys/devices/system/cpu"))

CORE_PRESETS = ("all", "big", "prime", "little")
GAMESCOPE_COMMS = ("gamescope", "gamescope-wl")
STEAM_COMMS = ("steam",)
# Preference order matters: STEAM_COMPAT_APP_ID is set only on compat-tool
# launches (Proton / FEX — everything x86), SteamAppId also appears on native
# launches, SteamGameId is the shortcut fallback.
APPID_ENV_KEYS = ("STEAM_COMPAT_APP_ID", "SteamAppId", "SteamGameId")
RR_PRIORITY = 40
NICE_MIN, NICE_MAX = -20, 19


# --------------------------------------------------------------- cpulists ---

def parse_cpulist(text):
    """Kernel-style cpulist ("0,3-5") to an ordered list of ints."""
    cpus = []
    for part in str(text).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = part.split("-", 1)
            if not (low.strip().isdigit() and high.strip().isdigit()):
                raise ValueError(f"invalid cpulist range: {part}")
            low, high = int(low), int(high)
            if high < low:
                raise ValueError(f"invalid cpulist range: {part}")
            cpus.extend(range(low, high + 1))
        elif part.isdigit():
            cpus.append(int(part))
        else:
            raise ValueError(f"invalid cpulist entry: {part}")
    if len(set(cpus)) != len(cpus):
        raise ValueError("duplicate cpus in cpulist")
    return cpus


def format_cpulist(cpus):
    """Inverse of parse_cpulist, compact form: [3,4,5,7] -> "3-5,7"."""
    parts, start, prev = [], None, None
    for cpu in sorted(cpus):
        if start is None:
            start = prev = cpu
            continue
        if cpu == prev + 1:
            prev = cpu
            continue
        parts.append(f"{start}-{prev}" if prev > start else f"{start}")
        start = prev = cpu
    if start is not None:
        parts.append(f"{start}-{prev}" if prev > start else f"{start}")
    return ",".join(parts)


def online_cpus():
    """CPUs currently online, from sysfs; affinity of self as a fallback."""
    try:
        return parse_cpulist((SYS_CPU_ROOT / "online").read_text().strip())
    except (OSError, ValueError):
        return sorted(os.sched_getaffinity(0))


def cpu_capacities():
    """{cpu: capacity} for every possible cpu that exposes cpu_capacity."""
    caps = {}
    for path in SYS_CPU_ROOT.glob("cpu[0-9]*"):
        suffix = path.name[len("cpu"):]
        if not suffix.isdigit():
            continue
        try:
            caps[int(suffix)] = int((path / "cpu_capacity").read_text().strip())
        except (OSError, ValueError):
            continue
    return caps


def preset_cpus(name):
    """Resolve a named core preset against live topology.

    little = the lowest-capacity cluster, prime = the highest, big = everything
    that is not little (mid + prime). Uniform capacity — or no cpu_capacity at
    all (non-DT hosts, the test suite unless it fabricates one) — collapses
    every preset to all online CPUs, which is the only honest answer there.
    """
    online = online_cpus()
    if name == "all":
        return list(online)
    caps = cpu_capacities()
    levels = sorted({caps[c] for c in online if c in caps})
    if len(levels) < 2:
        return list(online)
    if name == "little":
        keep = {levels[0]}
    elif name == "prime":
        keep = {levels[-1]}
    else:  # big
        keep = set(levels[1:])
    return [c for c in online if caps.get(c) in keep]


def resolve_cores(value):
    """None/"" = unset (inherit). "all" is explicit: a per-game "all" must
    clear a restrictive global. Unknown CPUs are an error, not a truncation."""
    if value in (None, ""):
        return None
    if value in CORE_PRESETS:
        return preset_cpus(value)
    cpus = parse_cpulist(value)
    online = set(online_cpus())
    unknown = [c for c in cpus if c not in online]
    if unknown:
        raise ValueError(f"unknown cpus: {unknown}")
    return cpus


def clamp(value, low, high):
    return max(low, min(high, int(value)))


def _is_int(value):
    """bool is a subclass of int; `"gamescopeRr": true` must not read as a nice."""
    return isinstance(value, int) and not isinstance(value, bool)


# ----------------------------------------------------------------- tweaks ---

def load_tweaks():
    """Absent or malformed means 'no tweaks', never a daemon failure."""
    try:
        with TWEAKS_CONFIG.open(encoding="utf-8") as f:
            loaded = json.load(f)
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def settings_for(tweaks, appid):
    """Global settings overlaid with this game's — the proton-wrapper contract:
    a game section only applies when it is explicitly "enabled": true."""
    settings = dict(tweaks.get("global") or {})
    game = (tweaks.get("games") or {}).get(str(appid)) if appid else None
    if isinstance(game, dict) and game.get("enabled") is True:
        settings.update(game)
    return settings


def sanitize_perf(settings):
    """Validated subset of the perf keys; a bad value drops that key alone."""
    clean = {}
    if _is_int(settings.get("nice")):
        clean["nice"] = clamp(settings["nice"], NICE_MIN, NICE_MAX)
    if "cores" in settings:
        try:
            cores = resolve_cores(settings.get("cores"))
            if cores is not None:
                clean["cores"] = cores
        except ValueError:
            pass
    if _is_int(settings.get("gamescopeNice")):
        clean["gamescopeNice"] = clamp(settings["gamescopeNice"], NICE_MIN, NICE_MAX)
    if isinstance(settings.get("gamescopeRr"), bool):
        clean["gamescopeRr"] = settings["gamescopeRr"]
    if "gamescopeCores" in settings:
        try:
            cores = resolve_cores(settings.get("gamescopeCores"))
            if cores is not None:
                clean["gamescopeCores"] = cores
        except ValueError:
            pass
    return clean


# -------------------------------------------------------------- /proc walk ---

def _read_comm(pid):
    try:
        return (PROC_ROOT / str(pid) / "comm").read_text().strip()
    except OSError:
        return ""


def pids_by_comm(comms):
    pids = []
    for entry in os.listdir(PROC_ROOT):
        if entry.isdigit() and _read_comm(entry) in comms:
            pids.append(int(entry))
    return pids


def process_tids(pid):
    try:
        return [int(t) for t in os.listdir(PROC_ROOT / str(pid) / "task")
                if t.isdigit()]
    except OSError:
        return []


def child_pids(pid):
    """Direct children via /proc/<pid>/task/<tid>/children (CONFIG_PROC_CHILDREN).
    On a kernel without it every open fails and the walk finds nothing."""
    children = []
    for tid in process_tids(pid):
        try:
            text = (PROC_ROOT / str(pid) / "task" / str(tid) / "children").read_text()
        except OSError:
            continue
        children.extend(int(c) for c in text.split())
    return children


def descendant_pids(pid):
    seen, stack = [], [pid]
    while stack:
        for child in child_pids(stack.pop()):
            if child not in seen:
                seen.append(child)
                stack.append(child)
    return seen


def _environ_appid(pid):
    """First appid-looking env entry of pid, else None. Root-only read."""
    try:
        raw = (PROC_ROOT / str(pid) / "environ").read_bytes()
    except OSError:
        return None
    env = {}
    for chunk in raw.split(b"\0"):
        key, sep, value = chunk.partition(b"=")
        if sep:
            env[key.decode("ascii", "replace")] = value
    for key in APPID_ENV_KEYS:
        value = env.get(key, b"").decode("ascii", "replace").strip()
        # 0 is Valve's "no app" sentinel, and it appears in practice: Steam runs
        # the compat tool as `proton run` with STEAM_COMPAT_APP_ID=0 for prefix
        # setup and tool probing. Treating it as an appid would tag those helpers
        # as a game tree and tune them with the global settings.
        if value.isdigit() and value != "0":
            return value
    return None


def _start_ticks(pid):
    """starttime (field 22) from /proc/<pid>/stat; 0 when unreadable."""
    try:
        stat = (PROC_ROOT / str(pid) / "stat").read_text()
        return int(stat.rpartition(")")[2].split()[19])
    except (OSError, ValueError, IndexError):
        return 0


def scan_games(cache=None):
    """One walk of the Steam client's descendants, two answers:
    (appid of the newest launch, pids belonging to that launch's tree).

    Every process Steam launches for a game inherits the appid in its
    environment — the compat tool, FEX, the game itself — so the tagged set IS
    the game tree, on the Proton, system-FEX and native paths alike. The Steam
    client and its own helpers carry no appid and are never tagged, which is
    what keeps enforcement off the client.

    `cache` (caller-owned dict) memoises the per-pid environ read across ticks
    as {pid: (starttime, appid)}; the starttime guards against a recycled pid
    inheriting a dead process's answer. Dead pids are pruned each call.
    """
    if cache is None:
        cache = {}
    tagged = []
    for steam in pids_by_comm(STEAM_COMMS):
        for pid in descendant_pids(steam):
            start = _start_ticks(pid)
            entry = cache.get(pid)
            if entry is None or entry[0] != start:
                entry = cache[pid] = (start, _environ_appid(pid))
            if entry[1]:
                tagged.append((start, pid, entry[1]))
    for stale in [p for p in cache if not (PROC_ROOT / str(p)).exists()]:
        del cache[stale]
    if not tagged:
        return None, []
    appid = max(tagged)[2]  # newest starttime wins
    return appid, [pid for _start, pid, tag in tagged if tag == appid]


def running_appid(cache=None):
    """Appid of the running game, or None. Thin view over scan_games()."""
    return scan_games(cache)[0]


# ------------------------------------------------------------ enforcement ---

def _policy(tid):
    try:
        return os.sched_getscheduler(tid) & ~os.SCHED_RESET_ON_FORK
    except OSError:
        return -1


def _set_affinity(tid, mask):
    """Write affinity only when it differs — repairs a stale restrictive mask
    after the config goes away without churning syscalls every tick."""
    try:
        if set(os.sched_getaffinity(tid)) != mask:
            os.sched_setaffinity(tid, mask)
    except OSError:
        pass


def apply_gamescope(values):
    """Idempotent per-tick enforcement of the gamescope thread policy.

    RESET_ON_FORK covers RR/negative nice leaking into children but NOT
    affinity, hence the explicit reset of gamescope's non-gamescope children
    back to all CPUs whenever a restrictive mask is in force.
    """
    nice = clamp(values.get("gamescopeNice", 0), NICE_MIN, NICE_MAX)
    want_rr = bool(values.get("gamescopeRr"))
    cores = values.get("gamescopeCores") or None
    all_cpus = set(online_cpus())
    mask = set(cores) & all_cpus if cores else all_cpus
    if not mask:
        mask = all_cpus
    for pid in pids_by_comm(GAMESCOPE_COMMS):
        for tid in process_tids(pid):
            policy = _policy(tid)
            try:
                # the nice block must see the post-promotion policy, or RR +
                # negative nice would promote then demote every tick
                if want_rr and policy == os.SCHED_OTHER:
                    os.sched_setscheduler(
                        tid, os.SCHED_RR | os.SCHED_RESET_ON_FORK,
                        os.sched_param(RR_PRIORITY))
                    policy = os.SCHED_RR
                elif not want_rr and policy == os.SCHED_RR:
                    os.sched_setscheduler(
                        tid, os.SCHED_OTHER | os.SCHED_RESET_ON_FORK,
                        os.sched_param(0))
                    policy = os.SCHED_OTHER
                if policy in (os.SCHED_OTHER, os.SCHED_BATCH):
                    if nice < 0 and policy == os.SCHED_OTHER:
                        os.sched_setscheduler(
                            tid, os.SCHED_OTHER | os.SCHED_RESET_ON_FORK,
                            os.sched_param(0))
                    if os.getpriority(os.PRIO_PROCESS, tid) != nice:
                        os.setpriority(os.PRIO_PROCESS, tid, nice)
            except OSError:
                continue
            _set_affinity(tid, mask)
        if mask != all_cpus:
            for child in child_pids(pid):
                if _read_comm(child) in GAMESCOPE_COMMS:
                    continue
                for tid in process_tids(child):
                    _set_affinity(tid, all_cpus)


def apply_game_tree(values, pids, state):
    """Apply the game-tree keys (`nice`, `cores`) to every thread of `pids`.

    Deliberately narrower than apply_gamescope, and the asymmetry is the point:
    gamescope is ours to own, so an unset key there means "restore the default".
    A game tree is NOT ours — Proton, FEX and the game itself set their own
    affinities and priorities — so here an unset key means "don't touch", and
    only threads THIS function changed (recorded in `state`) are ever repaired.
    Otherwise every tick would quietly undo a game's own thread tuning.

    Works on every launch path, because it keys off the tagged pids from
    scan_games() rather than off anything a launch wrapper had to inject.
    """
    all_cpus = set(online_cpus())
    tids = [tid for pid in pids for tid in process_tids(pid)]
    live = set(tids)
    # a tid we touched that has since exited cannot be repaired; forgetting it
    # is what keeps `state` from growing for the daemon's whole uptime
    state["affinity"] &= live
    for gone in [tid for tid in state["nice"] if tid not in live]:
        del state["nice"][gone]

    cores = values.get("cores") or None
    mask = None
    if cores:
        mask = set(cores) & all_cpus
        if not mask:  # every requested cpu is offline: not enforceable
            mask = None

    if mask:
        for tid in tids:
            _set_affinity(tid, mask)
            state["affinity"].add(tid)
    elif state["affinity"]:
        for tid in state["affinity"]:
            _set_affinity(tid, all_cpus)
        state["affinity"].clear()

    nice = values.get("nice")
    if nice is not None:
        for tid in tids:
            try:
                current = os.getpriority(os.PRIO_PROCESS, tid)
                state["nice"].setdefault(tid, current)
                if current != nice:
                    os.setpriority(os.PRIO_PROCESS, tid, nice)
            except OSError:
                continue
    elif state["nice"]:
        for tid, original in state["nice"].items():
            try:
                os.setpriority(os.PRIO_PROCESS, tid, original)
            except OSError:
                continue
        state["nice"].clear()


class Enforcer:
    """Per-tick enforcement, plus the state that has to survive between ticks.
    novadeck-powerd holds one for its lifetime and calls tick()."""

    def __init__(self):
        self.appid_cache = {}
        self.game_state = {"affinity": set(), "nice": {}}

    def tick(self):
        tweaks = load_tweaks()
        appid, pids = scan_games(self.appid_cache)
        values = sanitize_perf(settings_for(tweaks, appid))
        apply_gamescope(values)
        apply_game_tree(values, pids, self.game_state)
        return values
