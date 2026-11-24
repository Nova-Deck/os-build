"""The host service, which only this plugin starts and stops. Nothing here enables it: hosting never
starts at boot (it is the user's choice, every time).

Subprocesses get a clean environment: PluginLoader is a PyInstaller bundle and exports its own
LD_LIBRARY_PATH, which breaks the system's systemctl. They are awaited and reaped, never parked on a
worker thread, so stopping the plugin cancels them.
"""
import asyncio
import os

SYSTEMCTL = "/usr/bin/systemctl"
UNIT = "novadeck-sunshine.service"
STATES = {"active": "on", "inactive": "off", "activating": "starting", "reloading": "on",
          "deactivating": "stopping", "failed": "failed"}
SHOW_TIMEOUT = 5
# ExecStartPre makes the credentials; stopping waits for Sunshine to end its sessions.
CHANGE_TIMEOUT = 30


def clean_env(environ=None):
    env = dict(os.environ if environ is None else environ)
    original = env.pop("LD_LIBRARY_PATH_ORIG", None)
    env.pop("LD_LIBRARY_PATH", None)
    return env if original is None else {**env, "LD_LIBRARY_PATH": original}


def parse(text):
    fields = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    pid = fields.get("MainPID", "0")
    return {"state": STATES.get(fields.get("ActiveState"), "unknown"), "pid": int(pid) if pid.isdigit() else 0}


async def _systemctl(*args, timeout):
    """(exit code, output). 124 when it did not finish in time."""
    proc = await asyncio.create_subprocess_exec(
        SYSTEMCTL, *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        env=clean_env())
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        return proc.returncode, out.decode("utf-8", "replace")
    except asyncio.TimeoutError:
        return 124, ""
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()


async def status():
    _, out = await _systemctl("show", UNIT, "-p", "ActiveState", "-p", "MainPID", timeout=SHOW_TIMEOUT)
    return parse(out)


async def start():
    code, _ = await _systemctl("start", UNIT, timeout=CHANGE_TIMEOUT)
    return code == 0


async def stop():
    code, _ = await _systemctl("stop", UNIT, timeout=CHANGE_TIMEOUT)
    return code == 0
