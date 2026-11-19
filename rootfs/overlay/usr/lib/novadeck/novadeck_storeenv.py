"""The store paths game-launch's GOG helpers share: store-env's assignments, and a JSON reader.

Its own module because both novadeck_savesync (the cloud-save sync) and novadeck_gogsession (the
unit that runs Comet and the upload after exit) need them, and the session imports the sync.
"""
import json
import pathlib
import shlex
import subprocess

STORE_ENV = "/usr/lib/novadeck/store-env"


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


def read_json(path):
    """The parsed file, or None when it is missing or not JSON."""
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
