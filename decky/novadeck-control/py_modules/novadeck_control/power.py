"""Power profile access — straight to novadeck-powerd on the system bus.

This is the point of the Power tab: profile changes go to powerd's own org.novadeck.Power1
interface, the same code path every other setter lands in, with none of the SteamUI /
steamos-manager property-cache machinery in between. powerd re-emits PropertiesChanged on
every change, so the SteamUI Performance tab (whose shim listens for exactly that) stays in
sync with what we set here.

busctl, not a Python D-Bus binding: the plugin backend runs inside Decky's bundled Python,
which ships no dbus module — and busctl is already on every image (systemd). The backend runs
as root, so the system bus is reachable. org.novadeck.Power1's Profile property speaks the UI
LABELS ("Eco", "Balanced", "Performance") — AvailableProfiles enumerates them, so nothing here
hardcodes the set.

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


def _error_status(message):
    return {
        "profiles": [], "activeProfile": "",
        "gpuLevels": [], "gpuLevel": "",
        "manualGpuClock": 0, "manualGpuClockMin": 0, "manualGpuClockMax": 0,
        "error": message,
    }


def power_status():
    """Everything the Power tab shows, in one call; a dead powerd is a visible error string.

    gpuLevels comes straight from AvailableGpuPerformanceLevels, which powerd serves as [] on a
    device without a controllable GPU — the tab hides the section on an empty list, the same
    capability-by-enumeration rule the SteamOS API uses.
    """
    try:
        props = _get_all()
        return {
            "profiles": [str(p) for p in props.get("AvailableProfiles", [])],
            "activeProfile": str(props.get("Profile", "")),
            "gpuLevels": [str(l) for l in props.get("AvailableGpuPerformanceLevels", [])],
            "gpuLevel": str(props.get("GpuPerformanceLevel", "")),
            "manualGpuClock": int(props.get("ManualGpuClock", 0)),
            "manualGpuClockMin": int(props.get("ManualGpuClockMin", 0)),
            "manualGpuClockMax": int(props.get("ManualGpuClockMax", 0)),
            "error": "",
        }
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        return _error_status(f"powerd unreachable: {exc}")


def _set_property(prop, signature, value):
    # set-property has no --json; a failure surfaces as CalledProcessError -> error string.
    subprocess.run(
        ["/usr/bin/busctl", "--system", "set-property",
         BUS_NAME, OBJECT_PATH, IFACE, prop, signature, str(value)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=TIMEOUT,
        env=_clean_env(),
    )


def set_active_profile(label):
    try:
        _set_property("Profile", "s", label)
    except (OSError, subprocess.SubprocessError) as exc:
        return _error_status(f"set profile failed: {exc}")
    return power_status()


def set_gpu_level(level):
    try:
        _set_property("GpuPerformanceLevel", "s", level)
    except (OSError, subprocess.SubprocessError) as exc:
        return _error_status(f"set GPU level failed: {exc}")
    return power_status()


def set_manual_gpu_clock(mhz):
    try:
        _set_property("ManualGpuClock", "u", int(mhz))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return _error_status(f"set GPU clock failed: {exc}")
    return power_status()
