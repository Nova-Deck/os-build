"""The powerd half of the Monitor's frame — READ ONLY, and deliberately a subset.

novadeck-control owns the full org.novadeck.Power1 surface (every setter, the fan curve
editor, the capability lists that populate its dropdowns). This plugin only ever displays,
so it takes the nine properties the panel actually renders and nothing else. A monitor with
setters in reach is a monitor one typo away from writing a profile.

The duplication with novadeck-control's power.py is _clean_env + _busctl, ~25 lines, and it
is deliberate: two Decky plugins are two processes with two independent py_modules trees,
and the alternative (a shared package staged in by the build) hides the module from the
offline suite, which imports straight from the repo checkout.

busctl, not a Python D-Bus binding: the plugin backend runs inside Decky's bundled Python,
which ships no dbus module -- and busctl is already on every image (systemd).

Subprocesses get a SANITIZED env. PluginLoader is a PyInstaller bundle, and PyInstaller exports
LD_LIBRARY_PATH=<its extraction dir> to every child. busctl then loads the bundle's
libcrypto.so.3 instead of the rootfs's own and dies on a symbol mismatch (HW-observed on the
Power tab: "version OPENSSL_3.4.0 not found ... libsystemd-shared" -> exit 1). Stripping the
variable -- restoring the _ORIG value PyInstaller saves, when there is one -- is the documented
PyInstaller pattern for spawning anything that is not the bundled app itself. tests/test-decky.sh
asserts it HERE as well as on the control plugin: the duplication is the whole reason it can
regress in one copy and not the other.
"""
import asyncio
import json
import os
import subprocess

BUS_NAME = "org.novadeck.Power"
OBJECT_PATH = "/org/novadeck/Power"
IFACE = "org.novadeck.Power1"
# Seconds, and an ORDINARY safety net again -- a local GetAll is milliseconds. It is not tuned
# against anything else, and that is the point of the rewrite below.
TIMEOUT = 5


def _clean_env():
    env = dict(os.environ)
    orig = env.pop("LD_LIBRARY_PATH_ORIG", None)
    if orig is not None:
        env["LD_LIBRARY_PATH"] = orig
    else:
        env.pop("LD_LIBRARY_PATH", None)
    return env


async def _busctl(*args):
    """AWAITED, not run on a worker thread, and that is a shutdown fix rather than a style choice.

    This used to be subprocess.run() called through asyncio.to_thread(). Those workers come from
    the default executor and are NON-DAEMON: concurrent.futures registers an atexit hook that
    JOINS them, so the interpreter cannot exit while one is parked in busctl. At shutdown the
    service being polled -- novadeck-powerd -- is itself being stopped, so a GetAll issued in that
    window blocks for the full timeout, and the panel polls at 1 Hz, so one usually is in flight.
    Decky SIGKILLs a plugin "still alive 5 seconds after stop request": HW, 2026-09-07, "Plugin
    NovaDeck Monitor has been stopped in 5.2s" against 0.1s for the other two, eating a third of
    plugin_loader.service's 15s TimeoutStopSec.

    Lowering the timeout only shortens that stall; it does not remove it, and it leaves the next
    blocking call to reintroduce it. An awaited child has no worker thread to join and IS
    cancellable: when the loop tears the plugin's tasks down, this raises CancelledError, the
    child is killed and reaped in the finally, and the process exits immediately.
    """
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/busctl", "--system", "--json=short", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
        env=_clean_env(),
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), TIMEOUT)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        # Both paths must reap: an unreaped child of a plugin process that is itself exiting is
        # precisely the orphan that holds a mount open at shutdown.
        proc.kill()
        await proc.wait()
        raise
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, "busctl")
    return out.decode()


async def _get_all():
    """One GetAll instead of a busctl per property -- the panel polls every second."""
    out = await _busctl("call", BUS_NAME, OBJECT_PATH,
                        "org.freedesktop.DBus.Properties", "GetAll", "s", IFACE)
    payload = json.loads(out)["data"][0]
    return {name: value["data"] for name, value in payload.items()}


def _empty_snapshot(message):
    return {
        "profile": "", "activeProfile": "",
        "cpuScheduler": "", "activeCpuScheduler": "",
        "fanPwm": 0, "fanRpm": 0, "fanCurveMaxPwm": 0, "temperature": 0,
        "error": message,
    }


async def power_snapshot():
    """The nine properties the Monitor renders; a dead powerd is a visible error string.

    Same degrade-not-raise rule as telemetry.py: powerd going away must cost the fan and
    profile rows, never the whole panel.
    """
    try:
        props = await _get_all()
        return {
            # The system-wide choice, and what is in force now. They differ only while a
            # running game's per-game tweak overrides one -- the panel says so rather than
            # reporting a number that disagrees with the machine.
            "profile": str(props.get("Profile", "")),
            "activeProfile": str(props.get("ActiveProfile", "")),
            "cpuScheduler": str(props.get("CpuScheduler", "")),
            "activeCpuScheduler": str(props.get("ActiveCpuScheduler", "")),
            "fanPwm": int(props.get("FanPwm", 0)),
            "fanRpm": int(props.get("FanRpm", 0)),
            # The ACTIVE profile's curve ceiling, which is what the fan bar is scaled
            # against -- not the silicon's. The panel falls back to 255 on a zero.
            "fanCurveMaxPwm": int(props.get("FanCurveMaxPwm", 0)),
            # powerd's blended, EWMA-smoothed curve input. Deliberately a DIFFERENT number
            # from telemetry.py's raw per-zone maxima, and labelled as such: this is the one
            # the fan curve is evaluated against, so it is what explains the fan.
            "temperature": int(props.get("Temperature", 0)),
            "error": "",
        }
    except (OSError, ValueError, KeyError, subprocess.SubprocessError,
            asyncio.TimeoutError) as exc:
        return _empty_snapshot(f"powerd unreachable: {exc}")
