"""Panel frame-length calibration — measure the REAL scanout rate and trim the DDIC to it.

WHY. Several of our panels (ICNA35xx on the Odin 3 and the Odin 2 Portal; the same family drives
other boards) self-time their refresh from a DDIC frame-length word whose stock constants land
measurably off the nominal rate — an Odin 3 measured 118.35 Hz on its "120 Hz" mode. gamescope's
fps limiter computes its vblank divisor by integer division against the refresh, so a panel
running UNDER nominal makes every cap land one divisor high: ask 30, get real/3 ≈ 40; ask 20, get
real/5 ≈ 24 (HW-measured 2026-10-20 on an Odin 3, Darksiders 2). The kernel exposes per-rate trim
knobs (frame_len_<rate> on the mipi-dsi device, kernel patches 0533/0534); this module is the
userspace that measures, trims, persists and re-applies.

THE TARGET WINDOW IS NARROW AND ABOVE NOMINAL ON PURPOSE: +0.01% to +0.08%. Below nominal is the
exact floor-division failure this exists to fix. Where no usable value lands in the window, the
usable value with the lowest rate still at or above nominal wins.

SOME VALUES GRAY THE PICTURE, and not by rate: on the ICNA3520's 120 Hz knob it is every value
that is 2 mod 4 (GRAY_VALUES). Nothing here can measure gray, so calibrate and step skip them.

THE MODEL. 1/rate is linear in the frame length (the frame is a fixed number of lines plus the
knob). calibrate() measures the current value, probes one value PROBE_STEP away, solves the line
for the window, then nudges one step at a time to land inside it. The probe doubles as a check
that the CRTC being measured is the one the knob drives: a rate that does not follow aborts.

CALIBRATE DOES NOT SAVE. It leaves its value live; save() persists the live value, revert() goes
back to the saved one (or the driver default). The manual step()/set_value() have no ceiling on
purpose: they are how an operator fixes a bad automatic result. set_value() writes any value,
gray ones included; step() skips them.

CALIBRATION IS PER UNIT, NOT PER MODEL. Two boards of the same model carry different panel
samples; the state file is keyed by the SoC serial so a card moved between two units keeps a
separate entry for each and never applies one unit's trim to the other. apply_saved() writes
nothing for a serial with no entry. Saving the driver default deletes the entry.

WHAT THIS DOES NOT DO: switch display modes. calibrate trims the RATE THE PANEL IS SCANNING NOW —
gamescope owns the DRM master, so mode choice stays with the session (in-game QAM = the
game-presence refresh, SteamUI = the steam-mode refresh).

MEASUREMENT. DRM_IOCTL_WAIT_VBLANK on the CRTC that drives the board's primary connector
(device-env NOVADECK_PRIMARY_CONNECTOR): needs no DRM master, any user with /dev/dri access. The
rate comes from the vblank SEQUENCE numbers over the elapsed time, not from counting our own
wakeups — a wakeup that misses a vblank would read the panel slow and push the trim too fast.
Only the sysfs knob writes need root.

Testability: every filesystem root is overridable through the environment (see _env defaults
below), and the entry points take an injectable rate function, so tests/test-panel-calibration.sh
drives the real logic against a fabricated sysfs and a simulated panel.
"""

import contextlib
import ctypes
import errno
import fcntl
import glob
import json
import os
import shlex
import struct
import subprocess
import time

DRM_IOCTL_WAIT_VBLANK = 0xC018643A
DRM_IOCTL_MODE_GETRESOURCES = 0xC04064A0
DRM_IOCTL_MODE_GETENCODER = 0xC01464A6
DRM_IOCTL_MODE_GETCONNECTOR = 0xC05064A7
MODEINFO_SIZE = 68
VBLANK_RELATIVE = 0x1

# Longer samples do not help: the spread is the panel's own drift (sd ~0.012 Hz, batch means
# wandering ~0.035 Hz), the same at 1 s and at 0.125 s (HW, Thor Lite), while one 120 Hz step is
# 0.06-0.1 Hz. Counting sequence numbers between vblank timestamps adds no quantisation.
MEASURE_S = 0.25
STATUS_MEASURE_S = 0.25
# Relative to nominal: land in [+MARGIN, +CEILING] (see the module docstring).
MARGIN = 0.0001
CEILING = 0.0008
# Two back-to-back measurements further apart than this: the compositor is still settling.
STABLE_HZ = 0.1
PROBE_STEP = 20
# A rate that moved less than this (relative) with the probe is not the knobbed panel's.
MIN_SHIFT = 0.002
CONVERGE_STEPS = 8
# Nominal-rate inference: the measured rate must sit within this relative distance of a knob's
# rate to be attributed to it. 10% keeps 118.35 -> 120 unambiguous while refusing to "calibrate
# 120" on a panel actually scanning 90.
INFER_TOLERANCE = 0.10


def _env(name, default):
    return os.environ.get(name, default)


def sysfs_glob():
    return _env("NOVADECK_PANEL_SYSFS_GLOB", "/sys/bus/mipi-dsi/devices/*")


def state_file():
    return _env("NOVADECK_PANEL_STATE", "/var/lib/novadeck/panel-calibration.json")


def defaults_file():
    return _env("NOVADECK_PANEL_DEFAULTS", "/run/novadeck/panel-defaults.json")


def serial_file():
    # qcom socinfo, not the DT's /serial-number: the SM8750 DT has no such node (HW, Odin 3).
    return _env("NOVADECK_PANEL_SERIAL", "/sys/devices/soc0/serial_number")


def drm_sysfs():
    return _env("NOVADECK_PANEL_DRM_SYSFS", "/sys/class/drm")


def device_env():
    return _env("NOVADECK_PANEL_DEVICE_ENV", "/usr/lib/novadeck/device-env")


def device_serial():
    """The SoC serial, NUL-stripped. 'unknown' when the SoC reports none — entries then still
    work, they just lose the move-the-card-between-units protection."""
    try:
        with open(serial_file(), "rb") as f:
            serial = f.read().replace(b"\x00", b"").decode("ascii", "replace").strip()
            return serial or "unknown"
    except OSError:
        return "unknown"


def panel_knobs():
    """-> (device_dir, {rate: knob_path}) for the first mipi-dsi device exposing frame_len_*
    attributes, or (None, {}) on a board whose panel has no calibration support."""
    for dev in sorted(glob.glob(sysfs_glob())):
        knobs = {}
        for path in glob.glob(os.path.join(dev, "frame_len_*")):
            suffix = os.path.basename(path).rsplit("_", 1)[1]
            if suffix.isdigit():
                knobs[int(suffix)] = path
        if knobs:
            return dev, knobs
    return None, {}


# Frame-length values that gray the picture, by the panel's first DT compatible and the knob's
# rate. ICNA3520 at 120 Hz: every value that is 2 mod 4 (HW, Odin 3: 46, 50, 54 and 58 gray,
# every neighbour clean, 44 at 120.2 Hz clean). It is not a rate threshold. A calibrator stepping
# in 4s from a multiple of 4 never meets one, which is why the old loop never grayed. The 60 Hz
# default, 2006, is 2 mod 4 and clean, so the rule is the 120 Hz knob's only.
GRAY_VALUES = {
    ("chipone,icna3520", 120): lambda value: value % 4 == 2,
}


def panel_compatible(knob):
    """The first compatible of the panel owning `knob`, or None."""
    try:
        with open(os.path.join(os.path.dirname(knob), "of_node", "compatible"), "rb") as f:
            return f.read().split(b"\0")[0].decode("ascii", "replace")
    except OSError:
        return None


def usable_fn(knob):
    """-> value -> bool: False for the values that gray this panel's picture."""
    rate = int(os.path.basename(knob).rsplit("_", 1)[1])
    gray = GRAY_VALUES.get((panel_compatible(knob), rate))
    return (lambda value: not gray(value)) if gray else (lambda value: True)


def read_knob(path):
    with open(path) as f:
        return int(f.read().strip(), 0)


def write_knob(path, value):
    # The kernel refuses a value outside the panel's range with EINVAL (an OSError here).
    with open(path, "w") as f:
        f.write(str(value))


class NoDisplay(Exception):
    pass


# --- measurement -------------------------------------------------------------------------------


def primary_connector():
    """The board's panel connector name (e.g. DSI-1) from device-env; NOVADECK_PANEL_CONNECTOR
    overrides it. None when neither names one."""
    override = os.environ.get("NOVADECK_PANEL_CONNECTOR")
    if override:
        return override
    try:
        out = subprocess.run([device_env()], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        key, _, value = line.partition("=")
        if key == "NOVADECK_PRIMARY_CONNECTOR" and value:
            words = shlex.split(value)
            return words[0] if words else None
    return None


def _connector_node():
    """-> (card name, connector id). A board with no declared connector falls back to its only
    connected DSI connector; two or more is a refusal, not a guess."""
    name = primary_connector()
    if name:
        paths = glob.glob(os.path.join(drm_sysfs(), "card*-" + name))
    else:
        paths = []
        for path in glob.glob(os.path.join(drm_sysfs(), "card*-DSI-*")):
            try:
                with open(os.path.join(path, "status")) as f:
                    if f.read().strip() == "connected":
                        paths.append(path)
            except OSError:
                pass
        if len(paths) > 1:
            raise NoDisplay("several DSI panels and no primary connector declared for this board")
    for path in sorted(paths):
        try:
            with open(os.path.join(path, "connector_id")) as f:
                return os.path.basename(path).split("-")[0], int(f.read())
        except (OSError, ValueError):
            continue
    raise NoDisplay("no panel connector found (%s)" % (name or "DSI-*"))


def _address(buffer):
    return ctypes.addressof(ctypes.c_char.from_buffer(buffer))


def _panel_pipe(fd, connector_id):
    """The CRTC index driving the connector, or None when it is off."""
    # One mode slot: with count_modes 0 the kernel would reprobe the connector.
    modes = bytearray(MODEINFO_SIZE)
    buf = bytearray(struct.pack("QQQQ12I", 0, _address(modes), 0, 0, 1, 0, 0, 0,
                                connector_id, 0, 0, 0, 0, 0, 0, 0))
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, buf)
    encoder_id = struct.unpack_from("I", buf, 44)[0]
    if not encoder_id:
        return None
    buf = bytearray(struct.pack("5I", encoder_id, 0, 0, 0, 0))
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETENCODER, buf)
    crtc_id = struct.unpack_from("I", buf, 8)[0]
    if not crtc_id:
        return None
    buf = bytearray(64)
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, buf)
    count = struct.unpack_from("I", buf, 36)[0]
    crtcs = bytearray(4 * count)
    buf = bytearray(struct.pack("QQQQ8I", 0, _address(crtcs), 0, 0, 0, count, 0, 0, 0, 0, 0, 0))
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, buf)
    ids = list(struct.unpack("%dI" % count, crtcs))
    return ids.index(crtc_id) if crtc_id in ids else None


def _wait_vblank(fd, pipe):
    # struct drm_wait_vblank: request.type = RELATIVE | pipe in the high-crtc bits, sequence = 1.
    buf = bytearray(struct.pack("IIqq", VBLANK_RELATIVE | (pipe << 1) & 0x3E, 1, 0, 0))
    fcntl.ioctl(fd, DRM_IOCTL_WAIT_VBLANK, buf)
    _, seq, sec, usec = struct.unpack("IIqq", buf)
    return seq, sec + usec / 1e6


def _measure(fd, pipe, seconds):
    s0, t0 = _wait_vblank(fd, pipe)
    s1, t1 = s0, t0
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        s1, t1 = _wait_vblank(fd, pipe)
    if t1 <= t0 or s1 == s0:
        raise NoDisplay("no vblanks to measure (display idle?)")
    return ((s1 - s0) & 0xFFFFFFFF) / (t1 - t0)


@contextlib.contextmanager
def panel_rate_fn():
    """Yields rate(seconds=MEASURE_S) -> Hz for the panel's CRTC; NoDisplay when it is off."""
    card, connector_id = _connector_node()
    try:
        fd = os.open(os.path.join(_env("NOVADECK_PANEL_DRI", "/dev/dri"), card), os.O_RDWR)
    except OSError as e:
        raise NoDisplay("cannot open %s: %s" % (card, e))
    try:
        try:
            pipe = _panel_pipe(fd, connector_id)
        except OSError as e:
            raise NoDisplay("cannot query the panel's CRTC: %s" % e)
        if pipe is None:
            raise NoDisplay("the display is off")

        def rate(seconds=MEASURE_S):
            try:
                return _measure(fd, pipe, seconds)
            except OSError as e:
                raise NoDisplay("the display went off: %s" % e)

        yield rate
    finally:
        os.close(fd)


def infer_nominal(measured, rates):
    """Which knob's nominal rate the panel is scanning now, or None."""
    best = min(rates, key=lambda r: abs(measured - r), default=None)
    if best is None or abs(measured - best) > best * INFER_TOLERANCE:
        return None
    return best


# --- persisted state ---------------------------------------------------------------------------


def _load_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def load_state():
    return _load_json(state_file())


def save_state(state):
    _save_json(state_file(), state)


def load_defaults():
    """The driver defaults recorded this boot before any saved value was written ({} if not)."""
    return _load_json(defaults_file())


def record_defaults(knobs):
    """Before the first apply of a boot the knobs hold the driver's defaults: keep them, so
    'reset' and 'saving the default deletes the entry' have something to compare against."""
    if os.path.exists(defaults_file()):
        return
    defaults = {}
    for rate, path in knobs.items():
        try:
            defaults[str(rate)] = read_knob(path)
        except (OSError, ValueError):
            pass
    _save_json(defaults_file(), defaults)


# --- entry points ------------------------------------------------------------------------------


def _knob(rate):
    _, knobs = panel_knobs()
    if not knobs:
        raise RuntimeError("this panel has no frame_len calibration knobs")
    if rate not in knobs:
        raise RuntimeError("no frame_len knob for %s Hz (%s)" % (rate, sorted(knobs)))
    return knobs[rate]


def status(measure=True):
    _, knobs = panel_knobs()
    serial = device_serial()
    saved = load_state().get(serial, {})
    defaults = load_defaults()
    rates = {str(r) for r in knobs}
    result = {
        "supported": bool(knobs),
        "serial": serial,
        "rates": sorted(knobs),
        "current": {str(r): read_knob(p) for r, p in knobs.items()},
        "saved": {r: v for r, v in saved.items() if r in rates},
        "defaults": {r: v for r, v in defaults.items() if r in rates},
        "measuredHz": None,
        "nominalHz": None,
    }
    if measure:
        try:
            with panel_rate_fn() as rate:
                measured = rate(STATUS_MEASURE_S)
            result["measuredHz"] = round(measured, 3)
            result["nominalHz"] = infer_nominal(measured, sorted(knobs))
        except NoDisplay as e:
            result["measureError"] = str(e)
    return result


def apply_saved():
    """Boot-time re-apply: record the driver defaults, then write this unit's persisted values.
    Values for other serials (a card that travelled) are left alone. A value the kernel refuses
    leaves the driver default. -> {rate: value} actually written."""
    _, knobs = panel_knobs()
    record_defaults(knobs)
    saved = load_state().get(device_serial(), {})
    applied = {}
    for rate, path in knobs.items():
        value = saved.get(str(rate))
        if not isinstance(value, int):
            continue
        try:
            write_knob(path, value)
            applied[str(rate)] = value
        except OSError:
            pass
    return applied


def _measured_now(rate_fn):
    """The live rate where it can be measured, else None (display off, or a test with none)."""
    try:
        if rate_fn is not None:
            return round(rate_fn(), 3)
        with panel_rate_fn() as rate:
            return round(rate(STATUS_MEASURE_S), 3)
    except NoDisplay:
        return None


def step(rate, direction, rate_fn=None):
    """Move the knob to the next usable value; a lower frame length is a faster refresh. No
    ceiling: this is the operator's way out of a bad automatic result."""
    knob = _knob(rate)
    value = read_knob(knob)
    new = _next(value, -1 if direction == "faster" else 1, usable_fn(knob))
    limit = None
    try:
        write_knob(knob, new)
    except OSError as e:
        # EINVAL is the driver's out-of-range refusal; anything else is a real failure.
        if e.errno != errno.EINVAL:
            raise
        new, limit = value, "range"
    return {"rate": rate, "value": new, "limit": limit, "measuredHz": _measured_now(rate_fn)}


def set_value(rate, value):
    try:
        write_knob(_knob(rate), value)
    except OSError as e:
        raise RuntimeError("%d is out of range for the %d Hz knob: %s" % (value, rate, e))
    return {"rate": rate, "value": value}


def save(rate):
    """Persist the live value for this unit; the driver default is the same as no entry."""
    value = read_knob(_knob(rate))
    serial = device_serial()
    state = load_state()
    entry = state.get(serial, {})
    if value == load_defaults().get(str(rate)):
        entry.pop(str(rate), None)
    else:
        entry[str(rate)] = value
    if entry:
        state[serial] = entry
    else:
        state.pop(serial, None)
    save_state(state)
    return {"rate": rate, "saved": entry.get(str(rate))}


def revert(rate):
    """Back to this unit's saved value, or the driver default when none is saved."""
    value = load_state().get(device_serial(), {}).get(str(rate))
    if not isinstance(value, int):
        value = load_defaults().get(str(rate))
    if not isinstance(value, int):
        raise RuntimeError("no saved value and no recorded driver default for %d Hz" % rate)
    return set_value(rate, value)


def _next(value, direction, usable):
    """The next value from `value` in `direction` (+1/-1) that does not gray the picture."""
    value += direction
    while not usable(value):
        value += direction
    return value


def _solve(points, target, usable):
    """The usable value whose modelled rate is the smallest at or above target (1/rate linear)."""
    (v0, r0), (v1, r1) = points
    slope = (1 / r1 - 1 / r0) / (v1 - v0)
    intercept = 1 / r0 - slope * v0
    exact = (1 / target - intercept) / slope
    candidates = [int(exact) + d for d in range(-2, 4) if usable(int(exact) + d)]
    above = [v for v in candidates if 1 / (intercept + slope * v) >= target]
    return min(above, key=lambda v: 1 / (intercept + slope * v))


def _probe(knob, base, before, nominal, rate_fn, usable):
    """-> (probe value, its rate). Raises when no probe value is accepted, when the rate does
    not follow the knob (the measured CRTC is not the knobbed panel's), or when the rate does
    not come back (a mode switch during the probe)."""
    for probe in (base - PROBE_STEP, base + PROBE_STEP):
        if not usable(probe):
            probe = _next(probe, 1, usable)
        try:
            write_knob(knob, probe)
        except OSError:
            continue
        try:
            after = rate_fn()
        finally:
            write_knob(knob, base)
        if abs(after - before) < nominal * MIN_SHIFT:
            raise RuntimeError("the panel's rate did not follow its frame-length control")
        if abs(rate_fn() - before) > nominal * MIN_SHIFT / 2:
            raise RuntimeError("the refresh rate changed during calibration")
        return probe, after
    raise RuntimeError("the %d Hz frame length cannot be adjusted on this panel" % nominal)


def _converge(knob, base, value, faster, nominal, rate_fn, usable):
    """Nudge from the model's answer into [target, ceiling] over usable values. When none
    lands there (skipping the gray values can empty the window: Odin 3, 46 was its only
    member), the measured usable value with the lowest rate still at or above nominal.
    -> (value, rate) or (None, None)."""
    target, ceiling = nominal * (1 + MARGIN), nominal * (1 + CEILING)
    seen = {}
    for _ in range(CONVERGE_STEPS):
        # Back to a measured value: the walk is oscillating around an empty window.
        if value in seen:
            break
        try:
            write_knob(knob, value)
        except OSError:
            # Past the panel's limit.
            if any(rate >= nominal for rate in seen.values()):
                break
            # The starting value is in range, so the range lies toward it.
            value = _next(value, 1 if value < base else -1, usable)
            continue
        rate = rate_fn()
        if abs(rate - nominal) > nominal * INFER_TOLERANCE:
            raise RuntimeError("the refresh rate changed during calibration")
        seen[value] = rate
        if target <= rate <= ceiling:
            return value, rate
        value = _next(value, faster if rate < target else -faster, usable)
    at_nominal = [(rate, value) for value, rate in seen.items() if rate >= nominal]
    if not at_nominal:
        return None, None
    rate, value = min(at_nominal)
    return value, rate


def _calibrate(knobs, rate_fn):
    first = rate_fn()
    start = rate_fn()
    # Right after a mode switch the compositor is still taking over the display.
    if abs(start - first) > STABLE_HZ:
        raise RuntimeError("the display is not steady yet; try again in a few seconds")
    nominal = infer_nominal(start, sorted(knobs))
    if nominal is None:
        raise RuntimeError(
            "measured %.2f Hz matches no calibratable rate (%s)" % (start, sorted(knobs))
        )
    knob = knobs[nominal]
    usable = usable_fn(knob)
    base = read_knob(knob)
    probe, probe_rate = _probe(knob, base, start, nominal, rate_fn, usable)
    value = _solve([(base, start), (probe, probe_rate)], nominal * (1 + MARGIN), usable)
    faster = 1 if (probe_rate - start) / (probe - base) > 0 else -1
    result = (None, None)
    try:
        result = _converge(knob, base, value, faster, nominal, rate_fn, usable)
    finally:
        write_knob(knob, result[0] if result[0] is not None else base)
    if result[0] is None:
        raise RuntimeError("the panel did not reach %d Hz within its range" % nominal)
    return {
        "rate": nominal,
        "value": result[0],
        "startValue": base,
        "startHz": round(start, 3),
        "endHz": round(result[1], 3),
    }


def calibrate(rate_fn=None):
    """Trim the currently-scanning rate's frame length into the target window and leave it
    applied, UNSAVED (save() persists it). On failure the starting value is restored."""
    _, knobs = panel_knobs()
    if not knobs:
        raise RuntimeError("this panel has no frame_len calibration knobs")
    if rate_fn is not None:
        return _calibrate(knobs, rate_fn)
    with panel_rate_fn() as rate:
        return _calibrate(knobs, rate)
