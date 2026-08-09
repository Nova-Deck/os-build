"""Live numbers for the Monitor tab.

Split by WHO OWNS THE TRUTH rather than by where the bytes live:

  * Fan speed and the CURVE INPUT come from novadeck-powerd (power.power_status), because
    powerd is what decides them. Its Temperature is a blended top-3 average across the
    CPU/GPU/video/memory zones, EWMA-smoothed -- the exact number the fan curve is
    evaluated against, and the only one that explains why the fan is where it is.
  * Per-zone CPU and GPU temperatures are read here, straight from /sys/class/thermal.
    They are deliberately a SECOND, different number from the one above: raw, unsmoothed
    and per-domain. That is the reading a person actually wants ("is the GPU hot?"), and
    the blend cannot answer it. The UI labels which is which rather than pretending they
    are interchangeable.
  * Everything else (load, clocks, governors, memory) has no owner but the kernel, so it
    is read straight from /proc and /sys.

Every read degrades to a zero. A monitor that takes the tab down because one sysfs file
moved between kernels is worse than a monitor showing a dash.
"""
import pathlib

CPUFREQ_ROOT = pathlib.Path("/sys/devices/system/cpu/cpufreq")
DEVFREQ_ROOT = pathlib.Path("/sys/class/devfreq")
THERMAL_ROOT = pathlib.Path("/sys/class/thermal")
PROC = pathlib.Path("/proc")

# Zone `type` prefixes, matching how the SoC names them ("cpu-1-0-usr", "gpuss-0-usr").
# Deliberately narrower than powerd's own set, which also sweeps video and memory zones: it
# is picking a number to cool the whole package, this is answering "how hot is the CPU".
CPU_ZONE_PREFIXES = ("cpu",)
GPU_ZONE_PREFIXES = ("gpu",)

# /proc/stat is a counter, so a percentage needs two samples. Module-level because the
# plugin backend is a single long-lived process and the tab polls it once a second; the
# first call after load has nothing to diff against and honestly reports 0.
_last_cpu_sample = None
# Fields 4 and 5 of the cpu line (idle, iowait) are the not-working ones.
_IDLE_FIELDS = (3, 4)


def _read(path, default=""):
    try:
        return path.read_text().strip()
    except OSError:
        return default


def _read_int(path, default=0):
    value = _read(path)
    try:
        return int(value)
    except ValueError:
        return default


def _cpu_percent():
    global _last_cpu_sample
    try:
        fields = [int(v) for v in _read(PROC / "stat").split("\n", 1)[0].split()[1:]]
    except (IndexError, ValueError):
        return 0.0
    if not fields:
        return 0.0
    previous, _last_cpu_sample = _last_cpu_sample, fields
    if not previous:
        return 0.0
    deltas = [max(0, now - old) for now, old in zip(fields, previous)]
    total = sum(deltas)
    if not total:
        return 0.0
    idle = sum(deltas[i] for i in _IDLE_FIELDS if i < len(deltas))
    return round(100.0 * (total - idle) / total, 1)


def _compact_cpus(text):
    """"0 1 2 3" -> "0-3", "0 1 4" -> "0-1,4".

    `affected_cpus` spells out every core, which on a 4-core cluster is a label wider than
    the QAM panel. This is the same range form the kernel uses everywhere else, so it reads
    as a cpulist rather than as an abbreviation.
    """
    try:
        cpus = sorted({int(v) for v in text.split()})
    except ValueError:
        return text
    if not cpus:
        return text
    parts, start, previous = [], cpus[0], cpus[0]
    for cpu in cpus[1:] + [None]:
        if cpu == previous + 1:
            previous = cpu
            continue
        parts.append(str(start) if start == previous else f"{start}-{previous}")
        start = previous = cpu
    return ",".join(parts)


def _cpu_clusters():
    """One row per cpufreq policy — which is what a cluster IS on this hardware."""
    clusters = []
    try:
        policies = sorted(CPUFREQ_ROOT.glob("policy*"),
                          key=lambda p: int(p.name.removeprefix("policy")))
    except (OSError, ValueError):
        return clusters
    for policy in policies:
        maximum = _read_int(policy / "scaling_max_freq") or _read_int(policy / "cpuinfo_max_freq")
        clusters.append({
            "cores": _compact_cpus(_read(policy / "affected_cpus")
                                   or policy.name.removeprefix("policy")),
            "khz": _read_int(policy / "scaling_cur_freq"),
            # scaling_max_freq, not cpuinfo_max_freq: the profile's cap is the ceiling that
            # actually applies, so a bar against it shows headroom the user really has.
            "maxKhz": maximum,
            "governor": _read(policy / "scaling_governor"),
        })
    return clusters


def _gpu():
    for device in sorted(DEVFREQ_ROOT.glob("*")):
        if "gpu" not in device.name.lower() or not (device / "cur_freq").exists():
            continue
        available = [int(v) for v in _read(device / "available_frequencies").split() if v.isdigit()]
        return {
            "hz": _read_int(device / "cur_freq"),
            "maxHz": max(available) if available else 0,
            "governor": _read(device / "governor"),
        }
    return {"hz": 0, "maxHz": 0, "governor": ""}


def _temperatures():
    """Hottest CPU zone and hottest GPU zone, in °C.

    The MAX rather than an average: these SoCs expose one zone per core cluster, and an
    average across an idle little cluster and a saturated prime core reports a device that
    is comfortable while the part doing the work throttles.
    """
    hottest = {"cpuC": 0.0, "gpuC": 0.0}
    try:
        zones = sorted(THERMAL_ROOT.glob("thermal_zone*"))
    except OSError:
        return hottest
    for zone in zones:
        kind = _read(zone / "type").lower()
        if kind.startswith(CPU_ZONE_PREFIXES):
            key = "cpuC"
        elif kind.startswith(GPU_ZONE_PREFIXES):
            key = "gpuC"
        else:
            continue
        # millidegrees; a zone reading exactly 0 is a disabled sensor, not a cold one.
        millicelsius = _read_int(zone / "temp")
        if millicelsius:
            hottest[key] = max(hottest[key], round(millicelsius / 1000, 1))
    return hottest


def _memory():
    total = available = 0
    for line in _read(PROC / "meminfo").splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[1].isdigit():
            continue
        if parts[0] == "MemTotal:":
            total = int(parts[1])
        elif parts[0] == "MemAvailable:":
            available = int(parts[1])
    if not total:
        return {"usedMb": 0, "totalMb": 0, "percent": 0.0}
    used = total - available
    return {
        "usedMb": round(used / 1024),
        "totalMb": round(total / 1024),
        "percent": round(used * 100 / total, 1),
    }


def _load_average():
    try:
        return [float(v) for v in _read(PROC / "loadavg").split()[:3]]
    except (IndexError, ValueError):
        return []


def telemetry():
    return {
        "cpuPercent": _cpu_percent(),
        "cpuClusters": _cpu_clusters(),
        "gpu": _gpu(),
        "temperatures": _temperatures(),
        "memory": _memory(),
        "loadAverage": _load_average(),
    }
