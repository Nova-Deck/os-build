"""Panel frame-length calibration — measure the REAL scanout rate and trim the DDIC to it.

WHY. Several of our panels (ICNA35xx on the Odin 3 today; the same family drives other boards)
self-time their refresh from a DDIC frame-length word whose stock constants land measurably off
the nominal rate — an Odin 3 measured 118.35 Hz on its "120 Hz" mode. gamescope's fps limiter
computes its vblank divisor by integer division against the refresh, so a panel running UNDER
nominal makes every cap land one divisor high: ask 30, get real/3 ≈ 40; ask 20, get real/5 ≈ 24
(HW-measured 2026-10-20 on an Odin 3, Darksiders 2). The kernel exposes per-rate trim knobs
(frame_len_<rate> on the mipi-dsi device, carried as kernel patch 0533 for the Odin 3, from
ROCKNIX); this module is the userspace that measures, trims, persists and re-applies.

THE SETTLE CRITERION IS ASYMMETRIC ON PURPOSE: a value is accepted only when the measured rate
is AT OR ABOVE nominal (0 <= measured - target <= tolerance), never below — below nominal is the
exact floor-division failure this exists to fix. Same policy as ROCKNIX's calibrator.

CALIBRATION IS PER UNIT, NOT PER MODEL. Two boards of the same model carry different panel
samples; the state file is keyed by the SoC serial so a card moved between two units keeps a
separate entry for each and never applies one unit's trim to the other. apply() silently does
nothing for a serial with no entry.

WHAT THIS DOES NOT DO: switch display modes. The calibrate entry point trims the RATE THE PANEL
IS SCANNING NOW — gamescope owns the DRM master, so mode choice stays with the session (in-game
QAM = the game-presence refresh, SteamUI = the steam-mode refresh). Calibrating the other rate
is "switch refresh in Steam's display settings, press the button again".

Measurement is DRM_IOCTL_WAIT_VBLANK timestamps — needs no DRM master and works as any user with
/dev/dri access; only the sysfs knob writes need root.

Testability: every filesystem root is overridable through the environment (see _env defaults
below), and calibrate() takes an injectable rate function, so tests/test-panel-calibration.sh
drives the real loop against a fabricated sysfs and a simulated panel.
"""

import fcntl
import glob
import json
import os
import struct
import time

DRM_IOCTL_WAIT_VBLANK = 0xC018643A

STEP = 4
MEASURE_S = 0.5
SETTLE_S = 0.5
DEADLINE_S = 60.0
ADJUST_WINDOW_S = 15.0
VERIFY_WINDOW_S = 3.75
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


def serial_file():
    # qcom socinfo, not the DT's /serial-number: the SM8750 DT has no such node (HW, Odin 3).
    return _env("NOVADECK_PANEL_SERIAL", "/sys/devices/soc0/serial_number")


def drm_glob():
    return _env("NOVADECK_PANEL_DRM_GLOB", "/dev/dri/card*")


def tolerance_for(rate):
    # ROCKNIX's values: the 60 Hz window is tight because a +0.2 Hz error is proportionally
    # 4x worse there, and the knob's per-step effect is finer at the longer frame.
    return 0.05 if rate == 60 else 0.2


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


def read_knob(path):
    with open(path) as f:
        return int(f.read().strip(), 0)


def write_knob(path, value):
    with open(path, "w") as f:
        f.write(str(value))


class NoDisplay(Exception):
    pass


def _open_vblank():
    for card in sorted(glob.glob(drm_glob())):
        try:
            fd = os.open(card, os.O_RDWR)
        except OSError:
            continue
        for pipe in range(4):
            try:
                _wait_vblank(fd, pipe)
                return fd, pipe
            except OSError:
                pass
        os.close(fd)
    raise NoDisplay("no CRTC answers DRM_IOCTL_WAIT_VBLANK (display off?)")


def _wait_vblank(fd, pipe):
    # struct drm_wait_vblank: request.type = RELATIVE(1) | pipe<<1 (secondary high bits unused
    # for pipe<4), sequence = 1.
    buf = bytearray(struct.pack("IIqq", 1 | pipe << 1, 1, 0, 0))
    fcntl.ioctl(fd, DRM_IOCTL_WAIT_VBLANK, buf)
    _, _, sec, usec = struct.unpack("IIqq", buf)
    return sec + usec / 1e6


def measure_rate(seconds=MEASURE_S):
    """The panel's REAL scanout rate in Hz, from vblank timestamps over `seconds`."""
    fd, pipe = _open_vblank()
    try:
        stamps = []
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            stamps.append(_wait_vblank(fd, pipe))
        if len(stamps) < 8 or stamps[-1] <= stamps[0]:
            raise NoDisplay("too few vblanks to measure (display idle?)")
        return (len(stamps) - 1) / (stamps[-1] - stamps[0])
    finally:
        os.close(fd)


def infer_nominal(measured, rates):
    """Which knob's nominal rate the panel is scanning now, or None."""
    best = min(rates, key=lambda r: abs(measured - r), default=None)
    if best is None or abs(measured - best) > best * INFER_TOLERANCE:
        return None
    return best


def load_state():
    try:
        with open(state_file()) as f:
            state = json.load(f)
            return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    path = state_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def status(measure=True):
    dev, knobs = panel_knobs()
    serial = device_serial()
    saved = load_state().get(serial, {})
    result = {
        "supported": bool(knobs),
        "serial": serial,
        "rates": sorted(knobs),
        "current": {str(r): read_knob(p) for r, p in knobs.items()},
        "saved": {r: v for r, v in saved.items() if r in {str(x) for x in knobs}},
        "measuredHz": None,
        "nominalHz": None,
    }
    if measure:
        try:
            measured = measure_rate()
            result["measuredHz"] = round(measured, 3)
            result["nominalHz"] = infer_nominal(measured, sorted(knobs))
        except NoDisplay as e:
            result["measureError"] = str(e)
    return result


def apply_saved():
    """Boot-time re-apply: write this unit's persisted values. Values for other serials (a
    card that travelled) are left alone. -> {rate: value} actually written."""
    _, knobs = panel_knobs()
    saved = load_state().get(device_serial(), {})
    applied = {}
    for rate, path in knobs.items():
        value = saved.get(str(rate))
        if isinstance(value, int):
            write_knob(path, value)
            applied[str(rate)] = value
    return applied


def calibrate(rate_fn=None, sleep=time.sleep, clock=time.monotonic, deadline_s=DEADLINE_S):
    """Trim the currently-scanning rate's frame length until the panel measures at or just
    above nominal, persist the value for this unit, and leave it applied.

    The loop is ROCKNIX's, which is field-proven on these DDICs: walk in STEPs of 4 during an
    adjust window, then hold a verify window; a verify miss re-opens adjustment. On failure the
    original value is restored. rate_fn/sleep/clock are injectable for the offline tests —
    the real measure path spends wall time per sample, so the windows only make sense against
    the same clock the fakes advance.
    """
    if rate_fn is None:
        rate_fn = measure_rate
    _, knobs = panel_knobs()
    if not knobs:
        raise RuntimeError("this panel has no frame_len calibration knobs")

    start_rate = rate_fn()
    target = infer_nominal(start_rate, sorted(knobs))
    if target is None:
        raise RuntimeError(
            "measured %.2f Hz matches no calibratable rate (%s)" % (start_rate, sorted(knobs))
        )
    knob = knobs[target]
    tol = tolerance_for(target)
    big_error = tol * 2

    try:
        os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(10))
    except (PermissionError, OSError):
        pass  # best effort; jitter only widens the measurement, never corrupts it

    start_value = read_knob(knob)
    value = start_value // STEP * STEP

    def set_value(v):
        write_knob(knob, v)
        sleep(SETTLE_S)

    now = clock
    deadline = now() + deadline_s
    adjust_until = now() + ADJUST_WINDOW_S
    try:
        set_value(value)
        while now() < deadline:
            measured = rate_fn()
            delta = measured - target
            settled = 0 <= delta <= tol
            if now() < adjust_until:
                if not settled:
                    step = STEP if abs(delta) < big_error else 2 * STEP
                    # rate too fast -> lengthen the frame; too slow -> shorten it
                    value += step if delta > 0 else -step
                    set_value(value)
            elif settled:
                serial = device_serial()
                state = load_state()
                state.setdefault(serial, {})[str(target)] = value
                save_state(state)
                return {
                    "rate": target,
                    "value": value,
                    "startValue": start_value,
                    "startHz": round(start_rate, 3),
                    "endHz": round(target + delta, 3),
                }
            else:
                adjust_until = now() + VERIFY_WINDOW_S
    except OSError as e:
        write_knob(knob, start_value)
        raise RuntimeError("knob write failed at %d: %s" % (value, e))
    write_knob(knob, start_value)
    raise RuntimeError(
        "no stable value within %.0fs (target %d Hz, started %.2f Hz)"
        % (deadline_s, target, start_rate)
    )
