"""novadeck_cpuset — hold a game to a set of cpus with a cgroup cpuset.

An affinity mask is the thread's own to change, and Wine does change it: wineserver sets its recorded
mask on every thread as the thread starts. A cpuset is the kernel's: whatever a thread asks for is
cut down to it, for threads and child processes that do not exist yet too. Lifting it gives every
thread its own mask back, so there is nothing to record and nothing to repair.

The layout, inside the login scope the game already runs in:

    session-N.scope/                 no processes of its own once prepared
        novadeck-main/               everything else in the session
        novadeck-game/               the held processes; cpuset.cpus is the pin

It stays INSIDE the scope on purpose. Suspend freezes session-*.scope and the freeze is inherited,
logind still sees the session, and the scope still stops as one unit.

It has two ordinary (domain) children on purpose too. cpuset may be enabled over a scope that keeps
its processes, but then the child must be `threaded`, and a threaded cgroup.procs cannot be read.
systemd takes that error as "nothing to wait for" when it stops the scope, and follows SIGTERM with
SIGKILL at once: Steam would lose the moment it needs to flush saves at every poweroff. Domain
children need the scope itself empty, hence novadeck-main.

Needs `Delegate=cpuset` on the scope (session-.scope.d/20-novadeck-delegate-cpuset.conf), which is
also what makes writing below it ours to do. Without it, hold() answers False and changes nothing.
"""
import os
import pathlib
import re
import sys

CGROUP_ROOT = pathlib.Path(os.environ.get("NOVADECK_CGROUP_ROOT", "/sys/fs/cgroup"))
PROC_ROOT = pathlib.Path(os.environ.get("NOVADECK_PERF_PROC", "/proc"))

SESSION_SCOPE = re.compile(r"/user\.slice/user-\d+\.slice/session-[^/]+\.scope(?=/|$)")
MAIN, GAME = "novadeck-main", "novadeck-game"
# Processes fork while they are being moved. Each pass moves what the last one missed; a session
# that still is not drained is simply tried again on the next tick.
DRAIN_PASSES = 5


def _read(path):
    return path.read_text(encoding="ascii")


def _write(path, text):
    path.write_text(text, encoding="ascii")


def cgroup_of(pid):
    """The pid's cgroup v2 path ("/user.slice/..."), or "" once it has exited."""
    try:
        text = _read(PROC_ROOT / str(pid) / "cgroup")
    except (OSError, ValueError):
        return ""
    for line in text.splitlines():
        if line.startswith("0::"):
            return line[len("0::"):]
    return ""


def _move(pids, cgroup):
    for pid in pids:
        try:
            _write(cgroup / "cgroup.procs", str(pid))
        except ProcessLookupError:  # exited on the way
            continue


def _prepare(scope):
    """Make `scope` able to hold a game. False when the cpuset controller is not ours to use."""
    if "cpuset" not in _read(scope / "cgroup.controllers").split():
        return False
    for name in (MAIN, GAME):
        (scope / name).mkdir(exist_ok=True)
    if "cpuset" in _read(scope / "cgroup.subtree_control").split():
        return True
    for _ in range(DRAIN_PASSES):
        pids = _read(scope / "cgroup.procs").split()
        if not pids:
            break
        _move(pids, scope / MAIN)
    _write(scope / "cgroup.subtree_control", "+cpuset")  # EBUSY when not drained
    return True


class GameCpuset:
    """The one held game."""

    def __init__(self):
        self._last_error = None

    def hold(self, cpulist, pids):
        """Hold `pids`, and everything they start from now on, to `cpulist`. True when that is in
        force; False means the caller still has to pin them some other way."""
        paths = {pid: cgroup_of(pid) for pid in pids}
        paths = {pid: path for pid, path in paths.items() if path}  # the rest have exited
        matches = [SESSION_SCOPE.match(path) for path in paths.values()]
        # All of them in one session or none: a process elsewhere is not ours to move out of there.
        if None in matches or len({match.group(0) for match in matches}) != 1:
            return False
        relative = matches[0].group(0)
        scope = CGROUP_ROOT / relative.lstrip("/")
        game = scope / GAME
        try:
            if not _prepare(scope):
                return self._failed("cpuset is not delegated to the session scope")
            if _read(game / "cpuset.cpus").strip() != cpulist:
                _write(game / "cpuset.cpus", cpulist)
            _move([pid for pid, path in paths.items() if path != f"{relative}/{GAME}"], game)
        except (OSError, ValueError) as exc:
            return self._failed(str(exc))
        self._last_error = None
        return True

    def release(self):
        """Give every held thread its own mask back. The processes stay where they are: the cgroup
        restricts nothing any more, and it goes with the session.

        The cgroups say what is held, not this object: a daemon that died mid-game left its pin
        behind, and the one that replaced it has to lift it."""
        for cpus in CGROUP_ROOT.glob(f"user.slice/user-*.slice/session-*.scope/{GAME}/cpuset.cpus"):
            try:
                if _read(cpus).strip():
                    _write(cpus, "\n")  # an empty write is no write at all
            except (OSError, ValueError):
                continue  # the session is gone, and the cgroup with it

    def _failed(self, reason):
        # Once per reason: this is retried on every tick.
        if reason != self._last_error:
            print(f"novadeck-powerd: cannot hold the game in a cpuset, pinning its threads instead: "
                  f"{reason}", file=sys.stderr)
            self._last_error = reason
        return False
