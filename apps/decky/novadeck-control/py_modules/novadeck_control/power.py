"""The Power tab's powerd access — straight to novadeck-powerd on the system bus.

The tab carries the CPU scheduler and the fan curve, the two power settings Steam has no control
for. The profile and the GPU clock are NOT here: Steam's own Performance panel owns both, through
the steamos-manager shim, globally and per game. The tab only READS the profile, because the fan
curve it edits belongs to whichever profile is in force.

busctl, not a Python D-Bus binding: the plugin backend runs inside Decky's bundled Python,
which ships no dbus module — and busctl is already on every image (systemd). The backend runs
as root, so the system bus is reachable. org.novadeck.Power1's Profile property speaks the UI
LABELS ("Eco", "Balanced", "Performance").

Subprocesses get a SANITIZED env. PluginLoader is a PyInstaller bundle, and PyInstaller exports
LD_LIBRARY_PATH=<its extraction dir> to every child. busctl (resolved from the FEX guest rootfs
here) then loads the bundle's libcrypto.so.3 instead of the rootfs's own and dies on a symbol
mismatch (HW-observed: "version OPENSSL_3.4.0 not found ... libsystemd-shared" -> exit 1, which
the Power tab surfaced as "AvailableProfiles returned non-zero exit status 1"). Stripping the
variable — restoring the _ORIG value PyInstaller saves, when there is one — is the documented
PyInstaller pattern for spawning anything that is not the bundled app itself.
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
    """One GetAll instead of a busctl per property — the tab polls every 2s."""
    out = _busctl("call", BUS_NAME, OBJECT_PATH,
                  "org.freedesktop.DBus.Properties", "GetAll", "s", IFACE)
    payload = json.loads(out)["data"][0]
    return {name: value["data"] for name, value in payload.items()}


def _call(method):
    subprocess.run(
        ["/usr/bin/busctl", "--system", "call", BUS_NAME, OBJECT_PATH, IFACE, method],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=TIMEOUT,
        env=_clean_env(),
    )


def _error_status(message):
    return {
        "profile": "",
        "cpuSchedulers": [], "cpuScheduler": "", "activeCpuScheduler": "",
        "fanCurve": [], "fanCurveStops": [], "fanCurveMinPwm": 0, "fanCurveMaxPwm": 0,
        "fanCurveCustom": False, "fanPwm": 0, "fanRpm": 0, "temperature": 0,
        "error": message,
    }


def power_status():
    """Everything the Power tab shows, in one call; a dead powerd is a visible error string."""
    try:
        props = _get_all()
        return {
            # Read-only here: it names the profile whose fan curve the tab is editing.
            "profile": str(props.get("Profile", "")),
            # Capability-by-enumeration, the rule the SteamOS API uses: a kernel without
            # sched_ext (or an image without the scx binary) serves ["none"] alone, and the tab
            # hides the control.
            "cpuSchedulers": [str(s) for s in props.get("AvailableCpuSchedulers", [])],
            "cpuScheduler": str(props.get("CpuScheduler", "")),
            # What is actually loaded. Differs from cpuScheduler only while a running game's
            # per-game `scheduler` tweak overrides it — the tab says so rather than showing
            # the dropdown disagreeing with the machine.
            "activeCpuScheduler": str(props.get("ActiveCpuScheduler", "")),
            # The editable fan curve: PWM per FIXED temperature stop, scoped to the profile
            # in force right now — including one Steam switched to for a game. It comes down
            # this same GetAll, so the tab's poll follows a profile change with no extra call.
            # An empty stops list means a powerd too old to serve it -- hide the section,
            # the same capability-by-enumeration rule the lists above use.
            "fanCurve": [int(v) for v in props.get("FanCurve", [])],
            "fanCurveStops": [int(v) for v in props.get("FanCurveStops", [])],
            "fanCurveMinPwm": int(props.get("FanCurveMinPwm", 0)),
            "fanCurveMaxPwm": int(props.get("FanCurveMaxPwm", 0)),
            "fanCurveCustom": bool(props.get("FanCurveIsCustom", False)),
            "fanPwm": int(props.get("FanPwm", 0)),
            "fanRpm": int(props.get("FanRpm", 0)),
            "temperature": int(props.get("Temperature", 0)),
            "error": "",
        }
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        return _error_status(f"powerd unreachable: {exc}")


def _set_property(prop, signature, *values):
    # Varargs because busctl spells a container as SEPARATE argv words, not one string: an
    # `au` is "<count> <v1> <v2> ...". A scalar is just the one-value case of that.
    # set-property has no --json; a failure surfaces as CalledProcessError -> error string.
    subprocess.run(
        ["/usr/bin/busctl", "--system", "set-property",
         BUS_NAME, OBJECT_PATH, IFACE, prop, signature, *(str(v) for v in values)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=TIMEOUT,
        env=_clean_env(),
    )


def set_cpu_scheduler(scheduler):
    """The SYSTEM-WIDE scheduler. This is the only place it lives — there is no
    `global.scheduler` in game-tweaks.json — so this and `novadeck-scheduler` write the
    same property. A per-game tweak temporarily overrides it without changing it."""
    try:
        _set_property("CpuScheduler", "s", scheduler)
    except (OSError, subprocess.SubprocessError) as exc:
        return _error_status(f"set CPU scheduler failed: {exc}")
    return power_status()


def set_fan_curve(pwms):
    """The whole curve in one write — powerd rewrites its drop-in and reloads per set, so
    sending one slider at a time would mean one config rewrite per frame of a drag."""
    try:
        values = [int(v) for v in pwms]
        # powerd clamps into range and enforces the non-falling rule itself, so nothing here
        # needs to second-guess the values — only the count, which busctl needs up front.
        _set_property("FanCurve", "au", len(values), *values)
    except (OSError, TypeError, ValueError, subprocess.SubprocessError) as exc:
        return _error_status(f"set fan curve failed: {exc}")
    return power_status()


def reset_fan_curve(every=False):
    try:
        _call("ResetAllFanCurves" if every else "ResetFanCurve")
    except (OSError, subprocess.SubprocessError) as exc:
        return _error_status(f"reset fan curve failed: {exc}")
    return power_status()
