#!/usr/bin/env bash
# Offline check for the per-game AutoHDR override: novadeck-powerd's apply_auto_hdr_tweak()
# (rootfs/overlay/usr/bin/novadeck-powerd) and novadeck_perf.environ_convar_bool().
#
#   tests/test-auto-hdr.sh
#
# The game-tweaks.json `autoHdr` key drives gamescope's auto_hdr ConVar over gamescopectl while
# the game runs, then puts back the value gamescope was LAUNCHED with (session.conf's
# gamescope_auto_hdr, read from the compositor's environ). What is decision logic, and so tests
# cleanly with gamescopectl stubbed:
#   - the HDR-panel gate (NOVADECK_PANEL_HDR_NITS > 0, the session's own HDR gate);
#   - the baseline is read per compositor, so a restarted session re-baselines;
#   - only a change spawns gamescopectl, and a failed set is retried on the next tick;
#   - a single tick where the /proc walk finds no game must not flip HDR under the game.
#
# NOT covered: that gamescope honours `gamescopectl auto_hdr` live, and the socket resolution
# (tests/test-gamescope-display.sh covers the resolver). Those need a device.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERD="$ROOT/rootfs/overlay/usr/bin/novadeck-powerd"

[[ -f $POWERD ]] || { echo "novadeck-powerd missing: $POWERD" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Keep the bytecode out of rootfs/overlay; see test-perf.sh.
export PYTHONPYCACHEPREFIX="$TMP/pycache"

python3 - "$POWERD" "$ROOT" "$TMP" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import pathlib
import sys

powerd_path, root, tmp = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

sys.path.insert(0, os.path.join(root, "rootfs/overlay/usr/lib/novadeck"))
spec = importlib.util.spec_from_loader(
    "powerd", importlib.machinery.SourceFileLoader("powerd", powerd_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)
np = pd.novadeck_perf

results = []
def check(name, got, want):
    results.append(("PASS" if got == want else f"FAIL (got {got!r}, want {want!r})", name))

# A fabricated /proc holding only what environ_convar_bool reads.
proc = tmp / "proc"
np.PROC_ROOT = proc
def compositor(pid, environ):
    (proc / str(pid)).mkdir(parents=True, exist_ok=True)
    (proc / str(pid) / "environ").write_bytes(environ)

compositor(100, b"HOME=/home/deck\0gamescope_auto_hdr=1\0")
compositor(200, b"HOME=/home/deck\0")
compositor(300, b"gamescope_auto_hdr_x=1\0gamescope_auto_hdr=true\0")
compositor(400, b"gamescope_auto_hdr=0\0")

# ------------------------------------------------------------ environ_convar_bool ---
check("launch value on", np.environ_convar_bool(100, "auto_hdr"), True)
check("absent is the ConVar default (off)", np.environ_convar_bool(200, "auto_hdr"), False)
check("a longer name with the same prefix is not it", np.environ_convar_bool(300, "auto_hdr"), True)
check("launch value 0 is off", np.environ_convar_bool(400, "auto_hdr"), False)
check("unreadable environ is off", np.environ_convar_bool(999, "auto_hdr"), False)

# ------------------------------------------------------------ panel_hdr_nits ---
check("declared peak", pd.panel_hdr_nits({"NOVADECK_PANEL_HDR_NITS": "650"}), 650)
check("SDR board declares 0", pd.panel_hdr_nits({"NOVADECK_PANEL_HDR_NITS": "0"}), 0)
check("absent is SDR", pd.panel_hdr_nits({}), 0)
check("malformed is SDR", pd.panel_hdr_nits({"NOVADECK_PANEL_HDR_NITS": "x"}), 0)


# __init__ globs sysfs and writes pwm1, so build the object without it. What stays real is the
# override bookkeeping in apply_auto_hdr_tweak; gamescopectl is the stub.
def fresh(hdr_panel=True, ok=True, first=False):
    obj = pd.NovadeckPower.__new__(pd.NovadeckPower)
    obj.hdr_panel = hdr_panel
    # first=False: a compositor came and went before, so the next one starts at its launch value.
    obj.auto_hdr_gamescope = pd._UNSEEN if first else None
    obj.auto_hdr_baseline = False
    obj.auto_hdr_applied = None
    obj.auto_hdr_override = None
    obj.auto_hdr_drop_seen = False
    obj.auto_hdr_retry_ticks = 0
    obj.auto_hdr_failing = False
    obj.calls = []
    obj.ok = ok

    def set_convar(name, value):
        obj.calls.append((name, value))
        return None if obj.ok else "no live gamescope socket"

    obj.set_gamescope_convar = set_convar
    return obj

ON = [("auto_hdr", "1")]
OFF = [("auto_hdr", "0")]

# ------------------------------------------------------------ the gate ---
o = fresh(hdr_panel=False)
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("SDR panel: the tweak is ignored", o.calls, [])

o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": True}, None)
check("no compositor: nothing to set", o.calls, [])

# ------------------------------------------------------------ on/off against the launch value ---
o = fresh()
o.apply_auto_hdr_tweak({}, 200)
check("no tweak, session off: no spawn", o.calls, [])
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("game on over a session that is off", o.calls, ON)
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("  ...a steady tweak spawns nothing more", o.calls, ON)
o.apply_auto_hdr_tweak({}, 200)
check("  ...one tick without the game is debounced", o.calls, ON)
o.apply_auto_hdr_tweak({}, 200)
check("  ...a second one restores the session value", o.calls, ON + OFF)
check("  ...and the override is gone", o.auto_hdr_override, None)

o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
o.apply_auto_hdr_tweak({}, 200)
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("the game coming back within the debounce: no flip", o.calls, ON)

o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": False}, 100)
check("game off over a session that is on", o.calls, OFF)
o.apply_auto_hdr_tweak({}, 100)
o.apply_auto_hdr_tweak({}, 100)
check("  ...the session's on comes back after the game", o.calls, OFF + ON)

o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": True}, 100)
check("game on over a session already on: no spawn", o.calls, [])

# ------------------------------------------------------------ a new compositor ---
o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
o.apply_auto_hdr_tweak({"autoHdr": True}, 210)
check("restarted session starts at its launch value: re-applied", o.calls, ON + ON)
check("  ...baseline re-read from the new compositor", o.auto_hdr_baseline, False)

o = fresh()
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
o.apply_auto_hdr_tweak({"autoHdr": True}, 100)
check("new compositor launched with it on: nothing to do", o.calls, ON)

# ------------------------------------------------------------ the first compositor powerd sees ---
# A previous powerd may have been stopped mid-game with its override still set, so the first
# decision is written even when it equals the launch value.
o = fresh(first=True)
o.apply_auto_hdr_tweak({}, 200)
check("first compositor: the launch value is asserted once", o.calls, OFF)
o.apply_auto_hdr_tweak({}, 200)
check("  ...and only once", o.calls, OFF)
o.apply_auto_hdr_tweak({}, None)
o.apply_auto_hdr_tweak({}, 210)
check("a later compositor is trusted at its launch value", o.calls, OFF)

# ------------------------------------------------------------ a failed set ---
o = fresh(ok=False)
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("failed set is not recorded", o.auto_hdr_applied, False)
check("  ...and starts the backoff", o.auto_hdr_retry_ticks, pd.AUTO_HDR_RETRY_TICKS)
for _ in range(pd.AUTO_HDR_RETRY_TICKS):
    o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("  ...no spawn while backing off", o.calls, ON)
o.ok = True
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
check("  ...retried once the backoff ends", o.calls, ON + ON)
check("  ...then recorded", o.auto_hdr_applied, True)
check("  ...and the failing streak is over", o.auto_hdr_failing, False)

o = fresh(ok=False)
o.apply_auto_hdr_tweak({"autoHdr": True}, 200)
o.apply_auto_hdr_tweak({"autoHdr": True}, 210)
check("a new compositor drops the backoff", o.calls, ON + ON)

# ------------------------------------------------------------ the real gamescopectl call ---
# set_gamescope_convar through a stub resolver and a stub gamescopectl on PATH: the arguments,
# the display the resolver exports, and the failure strings.
bindir = tmp / "bin"
bindir.mkdir()
log = tmp / "gamescopectl.log"
(bindir / "gamescopectl").write_text(
    "#!/bin/sh\n"
    f'echo "$GAMESCOPE_WAYLAND_DISPLAY $*" >> "{log}"\n'
    '[ "$1" = auto_hdr ] || { echo "unknown convar" >&2; exit 1; }\n')
(bindir / "gamescopectl").chmod(0o755)
lib_ok = tmp / "display-ok.sh"
lib_ok.write_text("gs_resolve_display() { GAMESCOPE_WAYLAND_DISPLAY=gamescope-1; "
                  "export GAMESCOPE_WAYLAND_DISPLAY; }\n")
lib_none = tmp / "display-none.sh"
lib_none.write_text("gs_resolve_display() { return 1; }\n")
os.environ["PATH"] = f"{bindir}:{os.environ['PATH']}"

o = pd.NovadeckPower.__new__(pd.NovadeckPower)
pd.GAMESCOPE_DISPLAY_LIB = str(lib_ok)
check("gamescopectl set succeeds", o.set_gamescope_convar("auto_hdr", "1"), None)
check("  ...on the resolved socket, with the ConVar and value",
      log.read_text().splitlines(), ["gamescope-1 auto_hdr 1"])
check("gamescopectl's own error is the reason", o.set_gamescope_convar("bogus", "1"),
      "unknown convar")
pd.GAMESCOPE_DISPLAY_LIB = str(lib_none)
check("no live socket: gamescopectl never runs",
      (o.set_gamescope_convar("auto_hdr", "0"), len(log.read_text().splitlines())),
      ("no live gamescope socket or exit 1", 2))

# ----------------------------------------------------------------------------------- report ---
failed = [n for s, n in results if s != "PASS"]
for status, name in results:
    print(f"{status} {name}")
print(f"\ntest-auto-hdr: {len(results) - len(failed)} passed, {len(failed)} failed")
sys.exit(1 if failed else 0)
PYEOF
