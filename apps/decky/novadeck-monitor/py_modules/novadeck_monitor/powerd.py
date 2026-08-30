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
import json
import os
import subprocess

BUS_NAME = "org.novadeck.Power"
OBJECT_PATH = "/org/novadeck/Power"
IFACE = "org.novadeck.Power1"
TIMEOUT = 5


def _clean_env():
    env = dict(os.environ)
    orig = env.pop("LD_LIBRARY_PATH_ORIG", None)
    if orig is not None:
        env["LD_LIBRARY_PATH"] = orig
    else:
        env.pop("LD_LIBRARY_PATH", None)
    return env


def _busctl(*args):
    return subprocess.run(
        ["/usr/bin/busctl", "--system", "--json=short", *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=TIMEOUT,
        env=_clean_env(),
    ).stdout


def _get_all():
    """One GetAll instead of a busctl per property -- the panel polls every second."""
    out = _busctl("call", BUS_NAME, OBJECT_PATH,
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


def power_snapshot():
    """The nine properties the Monitor renders; a dead powerd is a visible error string.

    Same degrade-not-raise rule as telemetry.py: powerd going away must cost the fan and
    profile rows, never the whole panel.
    """
    try:
        props = _get_all()
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
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        return _empty_snapshot(f"powerd unreachable: {exc}")
