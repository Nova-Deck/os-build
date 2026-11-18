"""Run Comet (GOG Galaxy client emulation) around a Galaxy game's launch.

    start(appid)                                   called by game-launch, just before it execs
    novadeck_gogsession.py watch PID START -- ARGV  the unit's own process (below)

A GOG game built on the Galaxy SDK signs in through the Galaxy client service on 127.0.0.1:9977.
We ship no client, so without Comet answering there the sign-in never completes; Another World
20th Anniversary then dies at its first achievement unlock. The game's pressure-vessel container
shares the host network namespace, so a host Comet is what the game reaches
(.claude/plans/gog-galaxy-comet.plan.md).

WHY A USER UNIT. game-launch EXECS the launch chain, so nothing of it runs after the game exits,
and a child it left behind would sit in the game's process tree, where Steam's reaper waits for
it and the game would read as running after it stopped. So start() hands everything to one
transient systemd user unit, UNIT, and returns. The unit runs this file's `watch`, which:
  1. opens a pidfd on game-launch's pid — after exec that pid IS the launch chain, alive until the
     game exits — and checks its start time, so a pid already reused is never mistaken for it;
  2. runs Comet as its child;
  3. when the pidfd fires, sends Comet SIGINT (the only signal it does its final sync on) and
     kills it if it overruns STOP_GRACE.
The watcher owns Comet's lifetime. Comet's own --quit is not used: it exits only after a client
has connected, so a game that never connects would leave it running forever.

CREDENTIALS NEVER REACH ARGV (/proc/<pid>/cmdline is world-readable). Comet's --from-heroic reads
$XDG_CONFIG_PATH(sic)/heroic/gog_store/auth.json, the format gogdl writes, so a private config dir
holds a symlink there to the gogdl auth file. Both XDG_CONFIG_PATH and XDG_CONFIG_HOME point at it,
which keeps working if upstream fixes the variable name; Comet's config.toml lands there too.

Like the rest of game-launch, nothing here may stop the game: every failure returns.
"""
import json
import os
import pathlib
import select
import shlex
import signal
import subprocess
import sys

STORE_ENV = "/usr/lib/novadeck/store-env"
GALAXY_FILE = "galaxy.json"
COMET = "/usr/bin/comet"
PYTHON = "/usr/bin/python3"
SELF = os.path.abspath(__file__)
UNIT = "novadeck-comet"
# Set in the launch's environment once Comet is started, so a second game-launch in the same chain
# (launch options AND the in-tool shim of a baked Proton) does not restart it.
STARTED_ENV = "NOVADECK_COMET_STARTED"
STOP_GRACE = 15          # seconds Comet gets after SIGINT for its final sync
UNIT_STOP_TIMEOUT = 30   # the unit's TimeoutStopSec: more than STOP_GRACE, so the watcher finishes
# Stopping an earlier launch's unit waits for it to let go of port 9977, at most its own stop
# timeout; that is a relaunch inside the previous game's final sync, and nothing else waits here.
STOP_CALL_TIMEOUT = UNIT_STOP_TIMEOUT + 5
START_CALL_TIMEOUT = 10  # systemd-run returns once the unit is started; a hung user bus costs this
PROG = "game-launch"


def log(message):
    print(f"{PROG}: comet: {message}", file=sys.stderr, flush=True)


def store_env():
    """store-env's assignments as a dict, or {} when it cannot run. It quotes with printf %q."""
    try:
        out = subprocess.run([STORE_ENV], capture_output=True, text=True, timeout=10,
                             check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    values = {}
    for line in out.splitlines():
        key, _, raw = line.partition("=")
        parts = shlex.split(raw) if raw else []
        if parts:
            values[key] = parts[0]
    return values


def _read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def comet_row(home, appid):
    """This appid's galaxy.json row when the game ships the Galaxy SDK, else None."""
    table = _read_json(pathlib.Path(home) / GALAXY_FILE)
    row = table.get(str(appid)) if isinstance(table, dict) else None
    return row if isinstance(row, dict) and row.get("comet") is True else None


def username(path):
    data = _read_json(path)
    name = data.get("username") if isinstance(data, dict) else None
    return name if isinstance(name, str) and name else None


def prepare_config(home, auth):
    """The private config dir, with heroic/gog_store/auth.json a symlink to gogdl's auth file."""
    cfg = pathlib.Path(home) / "comet" / "config"
    store = cfg / "heroic" / "gog_store"
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    link = store / "auth.json"
    if not (link.is_symlink() and os.readlink(link) == str(auth)):
        tmp = store / ".auth.json.tmp"
        if tmp.is_symlink() or tmp.exists():
            tmp.unlink()
        tmp.symlink_to(auth)
        os.replace(tmp, link)
    return cfg


def start_time(pid):
    """The process's start time in clock ticks (/proc/<pid>/stat field 22), or None."""
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    # The command name (field 2) may hold spaces and parentheses; the fields after it do not.
    fields = stat[stat.rfind(")") + 2:].split()
    return int(fields[19]) if len(fields) > 19 else None


def unit_argv(cfg, user, pid, started):
    return ["systemd-run", "--user", "--quiet", "--collect", f"--unit={UNIT}",
            "-p", "KillSignal=SIGINT", "-p", f"TimeoutStopSec={UNIT_STOP_TIMEOUT}",
            f"--setenv=XDG_CONFIG_PATH={cfg}", f"--setenv=XDG_CONFIG_HOME={cfg}",
            "--", PYTHON, SELF, "watch", str(pid), str(started),
            # --username=U, one token: a name starting with '-' must not parse as a flag.
            "--", COMET, "--from-heroic", f"--username={user}"]


def start(appid, paths=None, run=subprocess.run):
    """Start Comet for this launch when it is a Galaxy game. Returns the unit argv, or None."""
    if not appid or os.environ.get(STARTED_ENV):
        return None
    paths = store_env() if paths is None else paths
    home = paths.get("NOVADECK_STORE_HOME")
    if not home or comet_row(home, appid) is None:
        return None
    user = username(paths.get("NOVADECK_GOG_USER", ""))
    if user is None:
        log("no GOG username recorded (sync the GOG library once); Comet not started")
        return None
    try:
        cfg = prepare_config(home, paths["NOVADECK_GOGDL_AUTH"])
    except (OSError, KeyError) as exc:
        log(f"config dir not prepared ({exc}); Comet not started")
        return None
    pid = os.getpid()
    started = start_time(pid)
    if started is None:
        log("own start time unreadable; Comet not started")
        return None
    argv = unit_argv(cfg, user, pid, started)
    try:
        # One Comet per device: the port is fixed, and so is the unit name. One left from an
        # earlier launch (a relaunch inside its stop window) is stopped first; a no-op otherwise.
        run(["systemctl", "--user", "stop", f"{UNIT}.service"], capture_output=True, text=True,
            timeout=STOP_CALL_TIMEOUT, check=False)
        result = run(argv, capture_output=True, text=True, timeout=START_CALL_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"not started ({exc})")
        return None
    if result.returncode != 0:
        log(f"not started: systemd-run exited {result.returncode}: {(result.stderr or '').strip()}")
        return None
    os.environ[STARTED_ENV] = str(appid)
    log(f"started for {appid} as {UNIT}.service")
    return argv


def _stop(proc, grace):
    if proc.poll() is not None:
        return
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        log(f"Comet did not exit {grace}s after SIGINT; killed")
        proc.kill()
        proc.wait()


def _wait_for_launch(pidfd, comet):
    """Block until the launch exits. A Comet that exits first is logged, and the wait goes on:
    what follows the game's exit (the save upload, phase 3) does not depend on Comet."""
    comet_fd = os.pidfd_open(comet.pid)
    try:
        watched = [pidfd, comet_fd]
        while True:
            ready, _, _ = select.select(watched, [], [])
            if pidfd in ready:
                return
            log(f"Comet exited while the game runs (status {comet.wait()}); see its journal")
            watched = [pidfd]
    finally:
        os.close(comet_fd)


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def watch(pid, started, comet_argv, grace=STOP_GRACE):
    """Run comet_argv while the process (pid, started) lives; stop it with SIGINT after.

    SIGINT (the unit's KillSignal) and SIGTERM both end the wait early and take the same path
    out, so Comet is always stopped the same way."""
    signal.signal(signal.SIGTERM, _interrupt)
    comet = pidfd = None
    try:
        try:
            pidfd = os.pidfd_open(pid)
        except OSError:
            log(f"launch {pid} already gone; Comet not started")
            return 0
        if start_time(pid) != started:
            log(f"pid {pid} is no longer the launch; Comet not started")
            return 0
        comet = subprocess.Popen(comet_argv, stdin=subprocess.DEVNULL)
        _wait_for_launch(pidfd, comet)
    except KeyboardInterrupt:  # the unit is being stopped
        pass
    finally:
        if comet is not None:
            _stop(comet, grace)
        if pidfd is not None:
            os.close(pidfd)
    return 0


def main(argv):
    if len(argv) < 6 or argv[1] != "watch" or argv[4] != "--":
        print("usage: novadeck_gogsession.py watch PID START -- COMMAND [ARGS...]", file=sys.stderr)
        return 1
    try:
        pid, started = int(argv[2]), int(argv[3])
    except ValueError:
        print("novadeck_gogsession.py: PID and START must be integers", file=sys.stderr)
        return 1
    return watch(pid, started, argv[5:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
