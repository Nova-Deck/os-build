"""The GOG session around a launch: Comet (Galaxy client emulation), then the cloud-save upload.

    start(appid)                                            called by game-launch, just before exec
    novadeck_gogsession.py watch PID START APPID PREFIX -- [COMET ARGV]   the unit's own process

A GOG game built on the Galaxy SDK signs in through the Galaxy client service on 127.0.0.1:9977.
We ship no client, so without Comet answering there the sign-in never completes; Another World
20th Anniversary then dies at its first achievement unlock. The game's pressure-vessel container
shares the host network namespace, so a host Comet is what the game reaches. And a game with
cloud saves on, Galaxy SDK or not, has its saves uploaded once it exits
(.claude/plans/gog-galaxy-comet.plan.md, phase 3 step 7).

WHY A USER UNIT. game-launch EXECS the launch chain, so nothing of it runs after the game exits,
and a child it left behind would sit in the game's process tree, where Steam's reaper waits for
it and the game would read as running after it stopped. So start() hands everything to one
transient systemd user unit, UNIT, and returns. The unit runs this file's `watch`, which:
  1. opens a pidfd on game-launch's pid — after exec that pid IS the launch chain, alive until the
     game exits — and checks its start time, so a pid already reused is never mistaken for it;
  2. runs Comet as its child, for a Galaxy game;
  3. when the pidfd fires, sends Comet SIGINT (the only signal it does its final sync on) and
     kills it if it overruns STOP_GRACE;
  4. then hands the upload to a unit of its own, UPLOAD_UNIT-<pid>, which runs
     `novadeck_savesync.py post-exit` and outlives this one.
The watcher owns Comet's lifetime. Comet's own --quit is not used: it exits only after a client
has connected, so a game that never connects would leave it running forever.

COMET FIRST, THE UPLOAD APART. gogdl may refresh the GOG token and rewrite auth.json, which Comet
read once at start, so Comet's final sync goes before gogdl runs. And the upload is NOT in this
unit: a relaunch stops this unit (its name and port 9977 are one per device), and that stop must
never wait on an upload (the next game would start late) nor kill one (the cloud left
half-written). The upload's own unit is serialised with the next launch's sync by
novadeck_savesync's lock instead.

STOPPING THIS UNIT (a relaunch, a logout) signals the WATCHER only (KillMode=mixed), which stops
Comet itself, once. While the game runs that means no upload: the game is being torn down
mid-write, and the next exit uploads. After the game exited, a stop is ignored: what is left is
Comet's grace and the hand-off.

CREDENTIALS NEVER REACH ARGV (/proc/<pid>/cmdline is world-readable). Comet's --from-heroic reads
$XDG_CONFIG_PATH(sic)/heroic/gog_store/auth.json, the format gogdl writes, so a private config dir
holds a symlink there to the gogdl auth file. Both XDG_CONFIG_PATH and XDG_CONFIG_HOME point at it,
which keeps working if upstream fixes the variable name; Comet's config.toml lands there too.

Like the rest of game-launch, nothing here may stop the game: every failure returns.
"""
import os
import pathlib
import select
import signal
import subprocess
import sys

from novadeck_storeenv import read_json, store_env

try:
    import novadeck_savesync
except ImportError:  # a missing helper costs the upload, not Comet
    novadeck_savesync = None

GALAXY_FILE = "galaxy.json"
COMET = "/usr/bin/comet"
PYTHON = "/usr/bin/python3"
SELF = os.path.abspath(__file__)
UNIT = "novadeck-gog-session"
UPLOAD_UNIT = "novadeck-gog-upload"  # + "-<watcher pid>": one per exit, never colliding
# Set in the launch's environment once the unit is started, so a second game-launch in the same
# chain (launch options AND the in-tool shim of a baked Proton) does not restart it.
STARTED_ENV = "NOVADECK_COMET_STARTED"
STOP_GRACE = 15          # seconds Comet gets after SIGINT for its final sync
UNIT_STOP_TIMEOUT = STOP_GRACE + 15  # the unit's TimeoutStopSec: more than STOP_GRACE
# Stopping an earlier launch's unit waits for it to let go of port 9977, at most its own stop
# timeout; that is a relaunch inside the previous game's final sync, and nothing else waits here.
STOP_CALL_TIMEOUT = UNIT_STOP_TIMEOUT + 5
# The upload unit's TimeoutStopSec: a whole upload, its lock wait included, so a logout never
# SIGKILLs one.
UPLOAD_STOP_TIMEOUT = (novadeck_savesync.POST_EXIT_LIMIT if novadeck_savesync is not None else 0) + 15
START_CALL_TIMEOUT = 10  # systemd-run returns once the unit is started; a hung user bus costs this
PROG = "game-launch"


def log(message):
    print(f"{PROG}: comet: {message}", file=sys.stderr, flush=True)


def comet_row(home, appid):
    """This appid's galaxy.json row when the game ships the Galaxy SDK, else None."""
    table = read_json(pathlib.Path(home) / GALAXY_FILE)
    row = table.get(str(appid)) if isinstance(table, dict) else None
    return row if isinstance(row, dict) and row.get("comet") is True else None


def username(path):
    data = read_json(path)
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


def comet_command(home, paths):
    """(config dir, Comet argv) for a Galaxy game, or None (logged) when Comet cannot run."""
    user = username(paths.get("NOVADECK_GOG_USER", ""))
    if user is None:
        log("no GOG username recorded (sync the GOG library once); Comet not started")
        return None
    try:
        cfg = prepare_config(home, paths["NOVADECK_GOGDL_AUTH"])
    except (OSError, KeyError) as exc:
        log(f"config dir not prepared ({exc}); Comet not started")
        return None
    # --username=U, one token: a name starting with '-' must not parse as a flag.
    return cfg, [COMET, "--from-heroic", f"--username={user}"]


def unit_argv(pid, started, appid, prefix, comet):
    """The systemd-run argv. comet: (config dir, argv) or None; prefix: the upload's, or None."""
    argv = ["systemd-run", "--user", "--quiet", "--collect", f"--unit={UNIT}",
            "-p", "KillSignal=SIGINT", "-p", "KillMode=mixed",
            "-p", f"TimeoutStopSec={UNIT_STOP_TIMEOUT}"]
    command = []
    if comet is not None:
        cfg, command = comet
        argv += [f"--setenv=XDG_CONFIG_PATH={cfg}", f"--setenv=XDG_CONFIG_HOME={cfg}"]
    return argv + ["--", PYTHON, SELF, "watch", str(pid), str(started), str(appid),
                   prefix or "-", "--", *command]


def wants_upload(home, appid, prefix):
    return (bool(prefix) and novadeck_savesync is not None
            and novadeck_savesync.cloud_row(home, appid) is not None)


def start(appid, paths=None, run=subprocess.run, prefix=None):
    """Start the unit for this launch when it is a Galaxy game or has cloud saves on. Returns the
    unit argv, or None."""
    if not appid or os.environ.get(STARTED_ENV):
        return None
    paths = store_env() if paths is None else paths
    home = paths.get("NOVADECK_STORE_HOME")
    if not home:
        return None
    if prefix is None:
        compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
        prefix = os.path.join(compat, "pfx") if compat else None
    upload_prefix = prefix if wants_upload(home, appid, prefix) else None
    comet = comet_command(home, paths) if comet_row(home, appid) is not None else None
    if comet is None and upload_prefix is None:
        return None
    pid = os.getpid()
    started = start_time(pid)
    if started is None:
        log("own start time unreadable; the GOG session is not started")
        return None
    argv = unit_argv(pid, started, appid, upload_prefix, comet)
    try:
        # One unit per device: Comet's port is fixed, and so is the unit name. One left from an
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
    log(f"started for {appid} as {UNIT}.service"
        f" ({'Comet' if comet else 'no Comet'}, {'upload after exit' if upload_prefix else 'no upload'})")
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
    the upload after the game's exit does not depend on Comet."""
    comet_fd = os.pidfd_open(comet.pid) if comet is not None else None
    try:
        watched = [pidfd] if comet_fd is None else [pidfd, comet_fd]
        while True:
            ready, _, _ = select.select(watched, [], [])
            if pidfd in ready:
                return
            log(f"Comet exited while the game runs (status {comet.wait()}); see its journal")
            watched = [pidfd]
    finally:
        if comet_fd is not None:
            os.close(comet_fd)


def upload_unit_argv(appid, prefix, pid):
    return ["systemd-run", "--user", "--quiet", "--collect", f"--unit={UPLOAD_UNIT}-{pid}",
            "-p", "KillMode=mixed", "-p", f"TimeoutStopSec={UPLOAD_STOP_TIMEOUT}",
            "--", PYTHON, novadeck_savesync.SELF, "post-exit", str(appid), prefix]


def hand_off_upload(appid, prefix, run=subprocess.run):
    """Start the upload's own unit. Never raises: a hand-off that fails is logged, and the next
    exit uploads what this one could not."""
    if novadeck_savesync is None or not prefix:
        return
    try:
        result = run(upload_unit_argv(appid, prefix, os.getpid()), capture_output=True, text=True,
                     timeout=START_CALL_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"saves not uploaded: the upload unit did not start ({exc})")
        return
    if result.returncode != 0:
        log(f"saves not uploaded: systemd-run exited {result.returncode}: "
            f"{(result.stderr or '').strip()}")


def _start_comet(comet_argv):
    try:
        return subprocess.Popen(comet_argv, stdin=subprocess.DEVNULL)
    except OSError as exc:
        log(f"Comet not started ({exc}); the game runs without it")
        return None


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def _ignore_stops():
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def watch(pid, started, appid, prefix, comet_argv, grace=STOP_GRACE, upload=None):
    """While the process (pid, started) lives, run comet_argv (if any). Once it exits, stop Comet
    with SIGINT, then hand the upload off: upload(appid, prefix), by default hand_off_upload.

    SIGINT (the unit's KillSignal) and SIGTERM while the game runs end the wait early, with no
    upload; from the moment Comet is being stopped, both are ignored, so a second one cannot cut
    Comet's final sync or the hand-off short."""
    signal.signal(signal.SIGTERM, _interrupt)
    comet = pidfd = None
    exited = False
    try:
        try:
            pidfd = os.pidfd_open(pid)
        except OSError:
            log(f"launch {pid} already gone; nothing started")
            return 0
        if start_time(pid) != started:
            log(f"pid {pid} is no longer the launch; nothing started")
            return 0
        if comet_argv:
            comet = _start_comet(comet_argv)
        _wait_for_launch(pidfd, comet)
        exited = True
    except KeyboardInterrupt:  # the unit is being stopped while the game runs
        pass
    finally:
        _ignore_stops()
        if comet is not None:
            _stop(comet, grace)
        if pidfd is not None:
            os.close(pidfd)
    if exited:
        try:
            (upload or hand_off_upload)(appid, prefix)
        except Exception as exc:  # noqa: BLE001 - the watcher always exits cleanly
            log(f"saves not uploaded ({exc})")
    return 0


def main(argv):
    if len(argv) < 7 or argv[1] != "watch" or argv[6] != "--":
        print("usage: novadeck_gogsession.py watch PID START APPID PREFIX|- -- [COMMAND [ARGS...]]",
              file=sys.stderr)
        return 1
    try:
        pid, started = int(argv[2]), int(argv[3])
    except ValueError:
        print("novadeck_gogsession.py: PID and START must be integers", file=sys.stderr)
        return 1
    return watch(pid, started, argv[4], None if argv[5] == "-" else argv[5], argv[7:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
