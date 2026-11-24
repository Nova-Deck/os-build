"""novadeck_perf — per-game perf policy helpers for novadeck-powerd.

Owns three things:

  1. The cpulist grammar ("3-5,7") plus the named core presets (all / big /
     prime / little), resolved from sysfs cpu_capacity so no per-device core
     table has to be maintained.
  2. The game-tweaks read path: /etc/novadeck/game-tweaks.json, the same file
     game-launch reads the FEX keys from. Every game setting is per game, in a
     per-appid section gated on "enabled": true. The "global" section carries
     the compositor's keys only (SYSTEM_WIDE_KEYS), and a game may override
     those. The per-game-only overrides of system-wide settings, scheduler and
     autoHdr, are resolved here for powerd to apply (see per_game_choice).
     There is no per-game power profile here: Steam's own per-game performance
     settings own that, through the steamos-manager shim.
  3. The enforcement tick novadeck-powerd runs: find gamescope, find the
     running game's appid (walk the Steam client's process tree via
     /proc/<pid>/task/<tid>/children and read the game's environ — root only),
     and idempotently apply the merged gamescope thread policy.

Everything degrades to a no-op: a missing tweaks file, an absent gamescope, a
kernel without CONFIG_PROC_CHILDREN, or an unreadable environ must never take
the daemon down. All /proc and /sys access goes through PROC_ROOT/SYS_CPU_ROOT
so the offline suite (tests/test-perf.sh) can drive this against a fabricated
tree with no root and no device.
"""
import json
import os
import pathlib
import re

import novadeck_cpuset

TWEAKS_CONFIG = pathlib.Path("/etc/novadeck/game-tweaks.json")
PROC_ROOT = pathlib.Path(os.environ.get("NOVADECK_PERF_PROC", "/proc"))
SYS_CPU_ROOT = pathlib.Path(
    os.environ.get("NOVADECK_PERF_SYSCPU", "/sys/devices/system/cpu"))

# The keys "global" may carry: the compositor runs whether a game does or not.
SYSTEM_WIDE_KEYS = ("gamescopeNice", "gamescopeCores")
CORE_PRESETS = ("all", "big", "prime", "little")
# The CPU schedulers a tweak may select. novadeck-powerd imports this as its own
# CPU_SCHEDULERS so the D-Bus enum and the tweaks-file domain cannot drift apart.
# "none" is the stock in-kernel scheduler; "lavd" is scx_lavd via scx.service.
SCHEDULERS = ("none", "lavd")
GAMESCOPE_COMMS = ("gamescope", "gamescope-wl")
STEAM_COMMS = ("steam",)
# Preference order matters: STEAM_COMPAT_APP_ID is set only on compat-tool
# launches (Proton / FEX — everything x86), SteamAppId also appears on native
# launches, SteamGameId is the shortcut fallback.
APPID_ENV_KEYS = ("STEAM_COMPAT_APP_ID", "SteamAppId", "SteamGameId")
NICE_MIN, NICE_MAX = -20, 19
# A Proton launch names the script and its verb in the argv of EVERY process of the chain, from
# Steam's own wrapper on, so it is recognisable before Python or Wine exists. The quote is for
# launch options, which Steam runs as one `sh -c` string.
PROTON_LAUNCH = re.compile(rb"/proton['\"]?[\0 ]+(?:waitforexitandrun|runinprefix|run)[\0 ]")


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


def resolve_cores(value, single=False):
    """None/"" = unset. "all" is explicit: a per-game gamescopeCores "all" must
    clear a restrictive system-wide one (a game's own `cores` goes through
    game_cores). Unknown CPUs are an error, not a truncation.

    `single` NARROWS whatever the preset or cpulist resolved to down to exactly
    one cpu: the highest-capacity member, ties broken by lowest cpu number. It
    composes with the selection rather than replacing it, which is the whole
    point — "little" + single pins one LITTLE core (enough for a cheap title
    that merely needs to stop racing), "all" + single pins the prime one.

    Why a modifier and not a "single" PRESET: a preset would have to pick the
    capacity class for you, and the only defensible pick is the prime core —
    which needlessly burns the fastest core on a game that does not need it.

    Ties are the reason this exists at all. `prime` returns the whole
    top-capacity CLASS, so on a SoC with two matched top cores it yields TWO
    cpus; a one-core workaround that silently becomes two-core is exactly the
    failure this must not have. With no `cores` at all it narrows the full
    online set, so ticking the box on its own is still meaningful.
    """
    if value in (None, ""):
        if not single:
            return None
        cpus = list(online_cpus())
    elif value in CORE_PRESETS:
        cpus = preset_cpus(value)
    else:
        cpus = parse_cpulist(value)
        online = set(online_cpus())
        unknown = [c for c in cpus if c not in online]
        if unknown:
            raise ValueError(f"unknown cpus: {unknown}")
    if single and cpus:
        # A cpu with no cpu_capacity sorts below every real one, so a genuine
        # big core still wins wherever capacities are exposed at all.
        caps = cpu_capacities()
        cpus = [max(cpus, key=lambda c: (caps.get(c, -1), -c))]
    return cpus


def game_cores(settings):
    """The cpus a game's `cores` and `singleCore` pin it to, or None for no pin.

    "all" is no pin: there is nothing for a game to override, and enforcing it
    would widen the threads a game pins itself, on every tick. With singleCore
    it still means "the fastest of all of them". ValueError as resolve_cores."""
    value = settings.get("cores")
    # A MODIFIER on `cores`, and meaningful on its own (it then narrows the full
    # online set). Deliberately NOT applied to gamescopeCores: pinning the
    # compositor to one cpu is never the workaround being asked for.
    single = settings.get("singleCore") is True
    if value == "all" and not single:
        return None
    return resolve_cores(value, single=single)


def clamp(value, low, high):
    return max(low, min(high, int(value)))


def _is_int(value):
    """bool is a subclass of int; `"singleCore": true` must not read as a count."""
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
    """This game's settings, over the system-wide compositor ones. A game section
    only applies when it is explicitly "enabled": true."""
    wide = tweaks.get("global")
    wide = wide if isinstance(wide, dict) else {}
    settings = {key: wide[key] for key in SYSTEM_WIDE_KEYS if key in wide}
    game = (tweaks.get("games") or {}).get(str(appid)) if appid else None
    if isinstance(game, dict) and game.get("enabled") is True:
        settings.update(game)
    return settings


def sanitize_perf(settings):
    """Validated subset of the perf keys; a bad value drops that key alone."""
    clean = {}
    if _is_int(settings.get("nice")):
        clean["nice"] = clamp(settings["nice"], NICE_MIN, NICE_MAX)
    try:
        cores = game_cores(settings)
        if cores is not None:
            clean["cores"] = cores
    except ValueError:
        pass
    # Only the opt-out means anything here, and only with a pin to time: see pinnable_pids.
    if "cores" in clean and settings.get("wineTopology") is False:
        clean["wineTopology"] = False
    if _is_int(settings.get("gamescopeNice")):
        clean["gamescopeNice"] = clamp(settings["gamescopeNice"], NICE_MIN, NICE_MAX)
    if "gamescopeCores" in settings:
        try:
            cores = resolve_cores(settings.get("gamescopeCores"))
            if cores is not None:
                clean["gamescopeCores"] = cores
        except ValueError:
            pass
    return clean


def per_game_choice(tweaks, appid, key, domain):
    """A per-game override of a SYSTEM-WIDE setting: the running game's value for
    `key`, or None for "no opinion".

    Deliberately NOT part of sanitize_perf/settings_for: each setting reached through here already
    has exactly one system-wide home — a persisted novadeck-powerd property that
    a CLI and the plugin both drive. A `global.<key>` would be a second place to
    set the same value, with no way for either to show the other's state. So
    these keys are per-game only, they are overrides that last as long as the
    game does, and a value equal to the shipped default is still meaningful: it
    spells out "stock for this title" against a different persisted choice.

    Unlike every other perf key, powerd applies these itself (it owns the units
    and the sysfs writes); novadeck_perf only resolves them."""
    game = (tweaks.get("games") or {}).get(str(appid)) if appid else None
    if not isinstance(game, dict) or game.get("enabled") is not True:
        return None
    value = game.get(key)
    return value if value in domain else None


def scheduler_for(tweaks, appid):
    """The per-game CPU scheduler, against powerd's persisted CpuScheduler.
    "none" forces stock for one title on a device whose choice is lavd."""
    return per_game_choice(tweaks, appid, "scheduler", SCHEDULERS)


def auto_hdr_for(tweaks, appid):
    """The per-game AutoHDR switch, against what gamescope was started with
    (session.conf's gamescope_auto_hdr). False forces it off for one title on a
    session that turns it on for everything.

    A JSON bool only: `1 in (True, False)` is true in Python, so the domain test
    alone would let a number through and hand powerd a non-bool."""
    value = per_game_choice(tweaks, appid, "autoHdr", (True, False))
    return value if isinstance(value, bool) else None


def parse_convar_bool(text):
    """A bool ConVar value the way gamescope parses it (convar.h Parse<bool>): a
    leading unsigned number is its truth, otherwise only "true" is true."""
    digits = ""
    for char in text:
        if not char.isdigit():
            break
        digits += char
    if digits:
        return int(digits) != 0
    return text == "true"


def environ_convar_bool(pid, name):
    """gamescope's exec-time value of ConVar `name`, from the gamescope_<name>
    variable in /proc/<pid>/environ. gamescope reads ConVars from that variable
    once at startup, so this is the value it was launched with. Absent or
    unreadable is False, the shipped default of every ConVar we read here."""
    try:
        raw = (PROC_ROOT / str(pid) / "environ").read_bytes()
    except OSError:
        return False
    prefix = f"gamescope_{name}=".encode()
    for entry in raw.split(b"\0"):
        if entry.startswith(prefix):
            return parse_convar_bool(entry[len(prefix):].decode("utf-8", "replace"))
    return False


# -------------------------------------------------------------- /proc walk ---

def _read_comm(pid):
    try:
        return (PROC_ROOT / str(pid) / "comm").read_text().strip()
    except OSError:
        return ""


def comm_index(comms):
    """{comm: [pid, ...]} for the comms of interest, from ONE listdir of /proc.

    The walk — a readdir plus a `comm` read per process — is the tick's dominant
    cost (~7 ms at 675 processes), and a tick needs two different comm sets
    (steam, gamescope). Collecting them together is what keeps that at one walk;
    see Enforcer.tick(), which builds the index and hands it to both consumers.
    """
    index = {}
    for entry in os.listdir(PROC_ROOT):
        if not entry.isdigit():
            continue
        comm = _read_comm(entry)
        if comm in comms:
            index.setdefault(comm, []).append(int(entry))
    return index


def pids_by_comm(comms, index=None):
    """Pids whose comm is in `comms`. Walks /proc unless handed an `index` from
    comm_index() that already covers those comms."""
    if index is None:
        index = comm_index(comms)
    return sorted(pid for comm in comms for pid in index.get(comm, ()))


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
        # as the running game, in place of the real one.
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


def scan_games(cache=None, index=None):
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

    `index` is an optional comm_index() covering STEAM_COMMS, so a caller that
    also needs another comm set this tick pays for one /proc walk, not two.
    """
    if cache is None:
        cache = {}
    tagged = []
    for steam in pids_by_comm(STEAM_COMMS, index):
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


def running_appid(cache=None, index=None):
    """Appid of the running game, or None. Thin view over scan_games()."""
    return scan_games(cache, index)[0]


# ------------------------------------------------------------ enforcement ---

def _policy(tid):
    try:
        return os.sched_getscheduler(tid) & ~os.SCHED_RESET_ON_FORK
    except OSError:
        return -1


def _get_affinity(tid):
    """The thread's current cpu mask, or None if it has already exited."""
    try:
        return set(os.sched_getaffinity(tid))
    except OSError:
        return None


def _set_affinity(tid, mask):
    """Write affinity only when it differs — repairs a stale restrictive mask
    after the config goes away without churning syscalls every tick."""
    try:
        if set(os.sched_getaffinity(tid)) != mask:
            os.sched_setaffinity(tid, mask)
    except OSError:
        pass


def apply_gamescope(values, index=None):
    """Idempotent per-tick enforcement of the gamescope thread policy.

    RESET_ON_FORK covers negative nice leaking into children but NOT affinity,
    hence the explicit reset of gamescope's non-gamescope children back to all
    CPUs whenever a restrictive mask is in force.

    Scheduling POLICY is never touched. gamescope sets its own under --rt,
    before its render threads exist so they inherit it; a per-tick promoter
    cannot reproduce that from outside, and flipping a running compositor's
    threads between SCHED_RR and SCHED_OTHER is a different, riskier thing.
    Threads that are not SCHED_OTHER/SCHED_BATCH are left entirely alone.

    `index` is an optional comm_index() covering GAMESCOPE_COMMS; see scan_games.
    """
    nice = clamp(values.get("gamescopeNice", 0), NICE_MIN, NICE_MAX)
    cores = values.get("gamescopeCores") or None
    all_cpus = set(online_cpus())
    mask = set(cores) & all_cpus if cores else all_cpus
    if not mask:
        mask = all_cpus
    for pid in pids_by_comm(GAMESCOPE_COMMS, index):
        for tid in process_tids(pid):
            policy = _policy(tid)
            try:
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


def _adopt(pid, state):
    """Record, once per process, what it looked like BEFORE we touched it.

    This is the reference point for threads that do not exist yet. It reads the
    main thread (tid == pid) because that is the one thread guaranteed to
    predate us; per-thread tuning is captured per-thread elsewhere.
    """
    baseline = state["baseline"].get(pid)
    if baseline is None:
        try:
            nice = os.getpriority(os.PRIO_PROCESS, pid)
        except OSError:
            nice = 0
        affinity = _get_affinity(pid)
        baseline = {"nice": nice,
                    "affinity": affinity if affinity is not None else set(online_cpus())}
        state["baseline"][pid] = baseline
    return baseline


def _remember(store, key, pid, tid, current, enforced, fresh, state):
    """Record a thread's pre-novadeck value, once, the first time we touch it.

    THE SUBTLETY, and the whole reason this is not `setdefault(tid, current)`:
    fork inherits both nice and affinity, so a thread SPAWNED WHILE OUR TWEAK
    IS IN FORCE is born already carrying it. Recording what it currently has
    would record OUR value as its original, and "repair" would then restore the
    tweak — HW-observed 2026-08-09, where removing a tweak left 11 of Super Meat
    Boy's 15 threads still at nice -5 / cpus 2-7 because they were born after
    the first apply.

    So the question is not what the thread has, it is where that value CAME
    from. Two cases, and `fresh` (this process's first apply in this call) is
    what separates them:
      - a thread that predates us -> its value is its own, record it verbatim;
      - a thread born during our tenure -> if it still carries exactly what we
        enforce, it inherited it, and the honest reference is the process
        baseline. If it carries something else it set that itself (a game's own
        SCHED_BATCH disk thread at nice 19 is the real case), so record that.
    """
    if tid in store:
        return
    if fresh or current != enforced:
        store[tid] = current
    else:
        store[tid] = state["baseline"][pid][key]


def _read_proc(pid, name):
    try:
        return (PROC_ROOT / str(pid) / name).read_bytes()
    except OSError:
        return b""


def keeps_topology(values, pids):
    """Is this a Proton launch whose `cores` must not show in what the game sees?"""
    return (values.get("wineTopology") is False
            and any(PROTON_LAUNCH.search(_read_proc(pid, "cmdline")) for pid in pids))


def _is_wineserver(pid):
    # argv[0], or argv[1] when an x86 one runs under an interpreter.
    return any(os.path.basename(arg) == b"wineserver"
               for arg in _read_proc(pid, "cmdline").split(b"\0")[:2])


def pinnable_pids(pids, state):
    """The processes of a keeps_topology() launch that may be pinned now.

    "wineTopology": false promises the game still sees every cpu, and the pin itself can break it.
    wineserver records the affinity of any Wine process that has no Wine parent, every child
    inherits the record, and a game cannot set an affinity outside it. So the mask must not be
    in place when that first process registers — and it inherits its mask from the launch chain
    (Proton's python, the runtime container). Proton also derives a topology from its own mask.

    Hence: never pin the launch chain, and pin a Wine process only once it has registered. The
    proof of that is ntdll.dll in its maps. Wine loads it after the request that records the
    mask, where the unix half (ntdll.so) comes before it. "A wineserver is running" would prove
    nothing: preparing the prefix starts one of its own, before the game's.

    wineserver itself may be pinned at any time. The masks it records are its clients', never its
    own, and it starts no Wine process that would inherit one. Left out, it would be the one busy
    part of the game still running on the cores the user excluded.
    """
    # Both are one-way, so a process is looked at only until it qualifies.
    known = state.get("wine", set()) & set(pids)
    state["wine"] = known | {pid for pid in pids if pid not in known
                             and (_is_wineserver(pid)
                                  or b"/ntdll.dll" in _read_proc(pid, "maps"))}
    return [pid for pid in pids if pid in state["wine"]]


def apply_game_tree(values, pids, state):
    """Apply the game-tree keys (`nice`, `cores`) to every thread of `pids`.

    Deliberately narrower than apply_gamescope, and the asymmetry is the point:
    gamescope is ours to own, so an unset key there means "restore the default".
    A game tree is NOT ours — Proton, FEX and the game itself set their own
    affinities and priorities — so here an unset key means "don't touch", and
    only threads THIS function changed are ever repaired — each back to the nice
    and cpu mask IT had before we touched it, both recorded in `state` on first
    write. Otherwise every tick would quietly undo a game's own thread tuning.
    See _remember() for what "before we touched it" means for a thread that did
    not exist when we arrived.

    Works on every launch path, because it keys off the tagged pids from
    scan_games() rather than off anything a launch wrapper had to inject.
    """
    all_cpus = set(online_cpus())
    tids_by_pid = {pid: process_tids(pid) for pid in pids}
    tids = [tid for pid in pids for tid in tids_by_pid[pid]]
    live = set(tids)
    # a tid we touched that has since exited cannot be repaired; forgetting it
    # is what keeps `state` from growing for the daemon's whole uptime
    for touched in (state["affinity"], state["nice"]):
        for gone in [tid for tid in touched if tid not in live]:
            del touched[gone]
    live_pids = set(pids)
    for gone in [pid for pid in state["baseline"] if pid not in live_pids]:
        del state["baseline"][gone]
    # Which processes are meeting us for the first time in THIS call: all their
    # threads predate us, so none of them can have inherited anything from us.
    fresh_pids = {pid for pid in pids if pid not in state["baseline"]}
    for pid in pids:
        _adopt(pid, state)

    cores = values.get("cores") or None
    mask = None
    if cores:
        mask = set(cores) & all_cpus
        if not mask:  # every requested cpu is offline: not enforceable
            mask = None

    # Wine gives every new thread the mask it recorded, which keeps_topology() makes all cpus, so an
    # affinity pin would leak each thread until the next tick. A cpuset holds them from birth. Where
    # there is none to be had, the affinity pin is still better than nothing.
    pin_pids, held = pids, False
    cpuset = state.get("cpuset")
    if mask and keeps_topology(values, pids):
        pin_pids = pinnable_pids(pids, state)
        if cpuset is not None and pin_pids:
            held = cpuset.hold(format_cpulist(sorted(mask)), pin_pids)
    else:
        state.pop("wine", None)
    if cpuset is not None and not held:
        cpuset.release()

    if mask and not held:
        for pid in pin_pids:
            fresh = pid in fresh_pids
            for tid in tids_by_pid[pid]:
                if tid not in state["affinity"]:
                    # remember the thread's OWN mask before the first overwrite,
                    # so repair restores what the game/FEX chose rather than
                    # widening it to every cpu (same contract as `nice` below)
                    original = _get_affinity(tid)
                    if original is None:
                        continue  # exited between process_tids() and here
                    _remember(state["affinity"], "affinity", pid, tid,
                              original, mask, fresh, state)
                _set_affinity(tid, mask)
    elif state["affinity"]:
        for tid, original in state["affinity"].items():
            # a cpu that went offline while we held the mask is not restorable;
            # falling back to all_cpus beats setting an empty (EINVAL) mask
            _set_affinity(tid, (original & all_cpus) or all_cpus)
        state["affinity"].clear()

    nice = values.get("nice")
    if nice is not None:
        for pid in pids:
            fresh = pid in fresh_pids
            for tid in tids_by_pid[pid]:
                try:
                    current = os.getpriority(os.PRIO_PROCESS, tid)
                    _remember(state["nice"], "nice", pid, tid,
                              current, nice, fresh, state)
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
        # baseline: what each process looked like before we first touched it —
        # the reference for threads spawned while a tweak is in force (_remember)
        self.game_state = {"affinity": {}, "nice": {}, "baseline": {},
                           "cpuset": novadeck_cpuset.GameCpuset()}
        # The compositor found by the last tick, None when there is none. powerd
        # reads it to drive gamescope's ConVars without a second /proc walk.
        self.gamescope_pid = None

    def tick(self):
        tweaks = load_tweaks()
        # ONE /proc walk for both consumers: scan_games wants steam,
        # apply_gamescope wants gamescope, and the walk is the tick's dominant cost.
        index = comm_index(STEAM_COMMS + GAMESCOPE_COMMS)
        compositors = pids_by_comm(GAMESCOPE_COMMS, index)
        self.gamescope_pid = compositors[0] if compositors else None
        appid, pids = scan_games(self.appid_cache, index)
        values = sanitize_perf(settings_for(tweaks, appid))
        apply_gamescope(values, index)
        apply_game_tree(values, pids, self.game_state)
        # Carried on the return, not applied here — powerd owns scx.service. Left absent
        # rather than set to None so "no opinion" and an explicit value that happens to
        # equal the default stay distinguishable.
        scheduler = scheduler_for(tweaks, appid)
        if scheduler is not None:
            values["scheduler"] = scheduler
        # Same shape, and powerd applies it too: gamescopectl, not a thread policy.
        auto_hdr = auto_hdr_for(tweaks, appid)
        if auto_hdr is not None:
            values["autoHdr"] = auto_hdr
        return values
