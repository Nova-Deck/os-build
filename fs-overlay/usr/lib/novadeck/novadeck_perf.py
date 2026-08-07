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
    if isinstance(settings.get("gamescopeNice"), int):
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
        if value.isdigit():
            return value
    return None


def _start_ticks(pid):
    """starttime (field 22) from /proc/<pid>/stat; 0 when unreadable."""
    try:
        stat = (PROC_ROOT / str(pid) / "stat").read_text()
        return int(stat.rpartition(")")[2].split()[19])
    except (OSError, ValueError, IndexError):
        return 0


def running_appid(cache=None):
    """Appid of the running game: the newest process under the Steam client
    whose environment names one. `cache` (caller-owned dict) memoises the
    per-pid environ answer across ticks; dead pids are pruned each call."""
    if cache is None:
        cache = {}
    candidates = []
    for steam in pids_by_comm(STEAM_COMMS):
        for pid in descendant_pids(steam):
            if pid not in cache:
                cache[pid] = _environ_appid(pid)
            if cache[pid]:
                candidates.append(pid)
    for stale in [p for p in cache if not (PROC_ROOT / str(p)).exists()]:
        del cache[stale]
    if not candidates:
        return None
    return cache[max(candidates, key=_start_ticks)]


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


def perf_tick(cache=None):
    """One enforcement pass: merged tweaks for the running game, applied to
    gamescope. The novadeck-powerd entry point."""
    tweaks = load_tweaks()
    values = sanitize_perf(settings_for(tweaks, running_appid(cache)))
    apply_gamescope(values)
    return values
