"""Run a store title's one-time setup steps on its first launch, inside the chain Steam composed.

The novadeck-stores plugin writes `<store home>/first-run.json` (appid → {id, steps}); its
first_run.py says what the steps are and why. game-launch fronts every launch and calls run()
before it tunes and execs, so a title's steps reach a prefix through exactly the door the game
itself uses: the launch's own argv, cut after Proton's verb, with the game swapped for the step.
SLR, Proton, its FEX and Steam's compat environment are all the ones the game is about to get,
and Proton creates the prefix on the first step if it does not exist yet.

The outcome is recorded IN THE PREFIX (MARKER). A deleted prefix lost what the steps wrote, so it
runs them again; a recorded id that matches means done. A FAILED step is recorded too and not
retried on every launch — a hung installer would otherwise stall every Play by STEP_TIMEOUT — so
deleting the marker is the retry.

Like the rest of game-launch, nothing here may stop the game: every failure returns.
"""
import json
import os
import pathlib
import subprocess
import sys

STORE_ENV = "/usr/lib/novadeck/store-env"
STEPS_FILE = "first-run.json"
MARKER = "novadeck-first-run.json"
STEP_TIMEOUT = 600  # a first step also builds the prefix under FEX
PROTON_VERBS = ("waitforexitandrun", "run")
PROG = "game-launch"


def log(message):
    print(f"{PROG}: first-run: {message}", file=sys.stderr, flush=True)


def store_home():
    """store-env's answer, the one declaration of where the store tree lives."""
    try:
        out = subprocess.run([STORE_ENV], capture_output=True, text=True, timeout=10, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        key, _, value = line.partition("=")
        if key == "NOVADECK_STORE_HOME" and value:
            return pathlib.Path(value)
    return None


def chain_prefix(argv):
    """argv up to and including Proton's verb, or None when this launch has no Proton in it."""
    for i, arg in enumerate(argv[:-1]):
        if os.path.basename(arg) == "proton" and argv[i + 1] in PROTON_VERBS:
            return argv[:i + 2]
    return None


def valid_steps(entry):
    """The entry's steps when every one is well-formed, else None — data from a file the user owns,
    about to be executed."""
    if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
        return None
    steps = entry.get("steps")
    if not isinstance(steps, list) or not steps:
        return None
    for step in steps:
        argv = step.get("argv") if isinstance(step, dict) else None
        if (not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv)
                or not os.path.isabs(argv[0]) or not isinstance(step.get("cwd", ""), str)
                or not isinstance(step.get("env", {}), dict)):
            return None
    return steps


def read_marker(marker):
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def run_step(prefix, step):
    """Exit status of one step, or a string saying why there is none."""
    env = {**os.environ, **{str(k): str(v) for k, v in step.get("env", {}).items()}}
    cwd = step.get("cwd") or None
    try:
        return subprocess.run(prefix + step["argv"], env=env, cwd=cwd, timeout=STEP_TIMEOUT,
                              stdin=subprocess.DEVNULL, check=False).returncode
    except subprocess.TimeoutExpired:
        return f"timed out after {STEP_TIMEOUT}s"
    except OSError as exc:
        return f"could not start: {exc}"


def run(argv, appid, home=None):
    """Run this launch's pending first-run steps, if any. Returns what was recorded, or None."""
    compat = os.environ.get("STEAM_COMPAT_DATA_PATH")
    if not appid or not compat:
        return None
    home = home or store_home()
    if home is None:
        return None
    try:
        table = json.loads((home / STEPS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    entry = table.get(str(appid)) if isinstance(table, dict) else None
    steps = valid_steps(entry)
    if steps is None:
        return None
    marker = pathlib.Path(compat) / MARKER
    done = read_marker(marker)
    if done is not None and done.get("id") == entry["id"]:
        return None
    prefix = chain_prefix(argv)
    if prefix is None:
        log(f"{entry['id']}: no Proton in this launch, steps skipped")
        return None
    results = []
    for step in steps:
        log(f"{entry['id']}: running {os.path.basename(step['argv'][0])}")
        result = run_step(prefix, step)
        log(f"{entry['id']}: {os.path.basename(step['argv'][0])} -> {result}")
        results.append({"exe": step["argv"][0], "result": result})
    record = {"id": entry["id"], "results": results}
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps(record, indent=1), encoding="utf-8")
    except OSError as exc:
        log(f"{entry['id']}: outcome not recorded ({exc}); the steps run again next launch")
    return record
