"""The Panel tab's panel-calibration access — subprocess over /usr/lib/novadeck/panel-calibration.

A subprocess, not an import: the tool lives on the rootfs and owns its own python (Decky bundles
its own interpreter, whose sys.path must not leak in), and the calibrate verb blocks for up to
~3 s of vblank measurements — asyncio.to_thread in main.py keeps that off Decky's loop either way. The backend runs
as root, so the tool's sysfs writes work without any daemon in between.

The env is sanitized for the same reason power.py documents at length: PyInstaller exports
LD_LIBRARY_PATH into children, which breaks any rootfs binary that links differently.
"""

import json
import subprocess

from .power import _clean_env

TOOL = "/usr/lib/novadeck/panel-calibration"
STATUS_TIMEOUT = 15
# calibrate measures at most 2 + 2 + 8 quarter-second samples; give it generous headroom.
CALIBRATE_TIMEOUT = 60


def _run(*args, timeout):
    try:
        proc = subprocess.run(
            [TOOL, *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            env=_clean_env(),
        )
        result = json.loads(proc.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        return {"error": str(e)}
    if proc.returncode != 0 and "error" not in result:
        result["error"] = "panel-calibration exited %d" % proc.returncode
    return result


def panel_status():
    return _run("status", timeout=STATUS_TIMEOUT)


def panel_calibrate():
    return _run("calibrate", timeout=CALIBRATE_TIMEOUT)


def panel_set(rate, value):
    return _run("set", str(int(rate)), str(int(value)), timeout=STATUS_TIMEOUT)


def panel_save(rate):
    return _run("save", str(int(rate)), timeout=STATUS_TIMEOUT)


def panel_revert(rate):
    return _run("revert", str(int(rate)), timeout=STATUS_TIMEOUT)
