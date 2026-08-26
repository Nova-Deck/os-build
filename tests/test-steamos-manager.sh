#!/usr/bin/env bash
# Offline test for the SteamOS-Manager compatibility shim, /usr/bin/novadeck-steamos-manager.
#
#   tests/test-steamos-manager.sh
#
# WHAT THE SHIM IS NOW. It carries no settings. PerformanceProfile1, GpuPerformanceLevel1 and
# finally CpuScheduler1 all moved to the novadeck-control Decky plugin, which talks straight to
# powerd; what is left is the two interfaces STEAMUI CALLS — SessionManagement1 and Manager2 —
# which by definition cannot move to a plugin, because only the owner of this bus name can
# answer them.
#
# WHY IT STILL EXISTS AT ALL, and the failure this file now guards. SteamUI's power menu offers
# "Switch to Desktop" unconditionally: it does not consult ValidDesktopSessions and it does not
# care whether this service is running. When the call fails it sits on a "Switching to Desktop…"
# popup forever. That was HW-observed 2026-08-09 twice over — with the whole service masked, and
# with the interface present but raising NotImplementedError. So a shim that merely EXPORTS the
# interface is not enough; the switch has to actually resolve. On a device with one session the
# only resolution available is to restart it, which is what switch_session does.
#
# That makes "switch_session must never raise, and must schedule a restart" the load-bearing
# assertion here — a regression to a raise gives a wedged shell that no device test tells apart
# from a slow one.
#
# Everything runs on the host: the shim is imported by path and driven against a recording
# connection, so no bus, no session and no root are involved.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/fs-overlay/usr/bin/novadeck-steamos-manager"
USER_UNIT="$ROOT/fs-overlay/usr/lib/systemd/user/novadeck-steamos-manager.service"
SYS_UNIT="$ROOT/fs-overlay/usr/lib/systemd/system/novadeck-steamos-manager.service"
USER_WANTS="$ROOT/fs-overlay/usr/lib/systemd/user/default.target.wants/novadeck-steamos-manager.service"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$SHIM" "$USER_UNIT" "$SYS_UNIT"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

CASE="shim"
# gi is in the image (the shim would not start without it), but an offline suite inherits the HOST
# PATH and proves logic only -- it can never stand in for the image's tool inventory. Skipping
# keeps a host without python-gi from reading as a shim regression.
if ! python3 -c 'import gi; gi.require_version("Gio","2.0"); from gi.repository import GLib, Gio' \
     >/dev/null 2>&1; then
  skip "python-gi not on the host — cannot drive the shim's GLib.Variant paths"
else
  # -B is load-bearing: importing the shim by path writes __pycache__ NEXT TO IT, i.e. inside
  # fs-overlay/usr/bin, which assemble-rootfs.sh copies wholesale into the image. Without this,
  # running the tests silently bakes a stale .pyc of the manager into the shipped rootfs.
  shim_out="$(python3 -B - "$SHIM" <<'PY'
import importlib.machinery, importlib.util
import subprocess
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import GLib

spec = importlib.util.spec_from_loader(
    "shim", importlib.machinery.SourceFileLoader("shim", sys.argv[1]))
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)

P = F = 0
def ok(m):
    global P; P += 1; print(f"  ok   shim -- {m}")
def bad(m):
    global F; F += 1; print(f"  FAIL shim -- {m}")


class FakeConnection:
    """Records emit_signal instead of putting anything on a bus."""
    def __init__(self):
        self.emitted = []
    def emit_signal(self, dest, path, iface, name, params):
        self.emitted.append((dest, path, iface, name, params))


def manager():
    """A manager with no __init__: the real one shells out to device-env."""
    m = sm.NovadeckSteamOSManager.__new__(sm.NovadeckSteamOSManager)
    m.connection = FakeConnection()
    m.last_emitted = {}
    m.valid_desktop_sessions = ()
    m.device_id, m.device_name = "novadeck", "NovaDeck"
    m.default_login_mode, m.default_desktop_session = "game", ""
    return m


# --- THE SETTINGS SURFACES STAY GONE -------------------------------------------------------
#
# Each moved to the Decky plugin for its own reason (see the shim's header). Re-exporting one
# would resurrect a second live surface for a setting the plugin owns — and for the profile that
# meant the client's property cache going silently stale, which is what this file was originally
# written about.
xml = manager().node_xml()
for gone in ("PerformanceProfile1", "GpuPerformanceLevel1", "CpuScheduler1"):
    if gone in xml:
        bad(f"{gone} is exported again — the plugin owns that setting")
    else:
        ok(f"{gone} stays unexported")
for const in ("IFACE_PROFILE", "IFACE_GPU", "IFACE_SCHED", "PROFILE_PROPS", "GPU_PROPS",
              "SCHED_PROPS", "POWERD_TO_STEAM"):
    if getattr(sm, const, None) is not None:
        bad(f"{const} exists again — the settings machinery is creeping back")
if not any(getattr(sm, c, None) is not None for c in ("IFACE_PROFILE", "IFACE_GPU", "IFACE_SCHED")):
    ok("no settings-interface constants remain")

# No powerd client remains: with every settings interface gone there is nothing to read from it,
# and a live subscription would be a bus connection kept open to serve nobody.
if getattr(sm, "PowerClient", None) is None and not hasattr(sm.NovadeckSteamOSManager, "on_power_changed"):
    ok("no powerd client and no re-emit path — the shim reads nothing")
else:
    bad("a powerd client survived the settings move — dead weight holding a bus connection")

# --- THE SWITCH MUST RESOLVE, NOT RAISE ----------------------------------------------------
#
# The one that matters. An exception of any kind is what wedges SteamUI on its popup.
m = manager()
scheduled = []
real_timeout = GLib.timeout_add
GLib.timeout_add = lambda ms, fn, *a: (scheduled.append((ms, fn)), 1)[1]
try:
    for target in ("desktop", "gamemode"):
        try:
            m.switch_session(target)
            ok(f"switch_session({target}) does not raise — the popup cannot wedge")
        except Exception as exc:
            bad(f"switch_session({target}) raised {exc!r} — SteamUI wedges on its popup")
    if len(scheduled) == 2 and all(fn == m._restart_session for _ms, fn in scheduled):
        ok("each switch schedules the session restart (the thing that clears the popup)")
    else:
        bad(f"switch did not schedule _restart_session: {scheduled}")
    # Deferred, not inline: killing the session from inside the call takes our own bus
    # connection down before the reply is written, and the caller sees the error path again.
    if scheduled and all(ms > 0 for ms, _fn in scheduled):
        ok("the restart is deferred, so the D-Bus reply is delivered first")
    else:
        bad("the restart runs inline — the reply would never reach the caller")
finally:
    GLib.timeout_add = real_timeout

# The session it kills is the compositor's: the seat0 one. Picking the wrong row (a root SSH
# session, the user manager) would kill nothing and leave the popup up.
real_check = subprocess.check_output
subprocess.check_output = lambda *a, **k: (
    "2 1000 deck -     822  manager       -    no -\n"
    "4    0 root -     2235 user          -    no -\n"
    "6 1000 deck seat0 2266 user          tty1 no -\n")
try:
    got = sm.NovadeckSteamOSManager.graphical_session()
    if got == "6":
        ok("graphical_session picks the seat0 row, not the manager or an SSH session")
    else:
        bad(f"graphical_session picked {got!r}, expected the seat0 session")
finally:
    subprocess.check_output = real_check

def _boom(*a, **k):
    raise OSError("no loginctl")
subprocess.check_output = _boom
try:
    if sm.NovadeckSteamOSManager.graphical_session() == "":
        ok("a failing loginctl yields no session rather than an exception")
    else:
        bad("graphical_session did not degrade when loginctl failed")
finally:
    subprocess.check_output = real_check

# --- WHAT THE SHIM STILL ANSWERS -----------------------------------------------------------
m = manager()
if m.get_property(sm.IFACE_MANAGER, "DeviceModel").unpack() == ("novadeck", "NovaDeck"):
    ok("Manager2.DeviceModel answers (SteamUI asks the manager, so only we can)")
else:
    bad("DeviceModel does not answer")
if m.get_property(sm.IFACE_SESSION, "DefaultLoginMode").get_string() == "game":
    ok("SessionManagement1 properties answer")
else:
    bad("SessionManagement1 properties do not answer")

# The session properties are the last emits-change surface, so the dedupe still has a job.
m = manager()
m.emit_properties(sm.IFACE_SESSION, {"DefaultLoginMode": GLib.Variant("s", "game")})
before = len(m.connection.emitted)
m.emit_properties(sm.IFACE_SESSION, {"DefaultLoginMode": GLib.Variant("s", "game")})
if len(m.connection.emitted) == before:
    ok("an unchanged value is not re-announced")
else:
    bad("emitted a duplicate PropertiesChanged")
m.emit_properties(sm.IFACE_SESSION, {"DefaultLoginMode": GLib.Variant("s", "desktop")})
if len(m.connection.emitted) == before + 1:
    ok("a genuine change is announced")
else:
    bad("dedupe swallowed a genuine change")

print(f"__TALLY__ {P} {F}")
PY
)"
  printf '%s\n' "$shim_out" | grep -v '^__TALLY__'
  read -r _ p f <<<"$(printf '%s\n' "$shim_out" | grep '^__TALLY__')"
  PASS=$((PASS + ${p:-0})); FAIL=$((FAIL + ${f:-0}))
  [ -n "${p:-}" ] || bad "the python harness died before printing its tally"
fi

CASE="units"

if grep -qE '^ExecStart=.*novadeck-steamos-manager[[:space:]]*$' "$USER_UNIT"; then
  ok "user unit starts the session-bus instance (no --system)"
else
  bad "user unit does not start a session-bus instance — SteamUI's bus would have no daemon"
fi

if grep -qE '^ExecStart=.*novadeck-steamos-manager --system[[:space:]]*$' "$SYS_UNIT"; then
  ok "system unit starts the system-bus instance (--system)"
else
  bad "system unit is not passing --system"
fi

# Presets are applied on first boot only. The shipped wants symlink is what makes the session-bus
# instance come up on EVERY boot regardless, so SteamUI never faces an empty bus name — which,
# for the desktop switch, is the difference between a restart and a wedged popup.
if [ -L "$USER_WANTS" ]; then
  ok "user unit ships a default.target.wants symlink — starts without depending on presets"
else
  bad "no default.target.wants symlink: the session-bus instance relies on presets alone"
fi

# That symlink lives under /usr/lib, so it applies to every user manager -- and one starts for
# anyone who logs in, root over SSH included. ConditionUser is what keeps the pair honest: without
# it each SSH login spawned a shim owning the bus name on a session bus nobody reads.
if grep -qE '^ConditionUser=deck[[:space:]]*$' "$USER_UNIT"; then
  ok "user unit is gated on ConditionUser=deck — one instance, in the session SteamUI reads"
else
  bad "no ConditionUser=deck: the vendor wants symlink starts a shim in EVERY user manager"
fi

# Restart=on-failure matters more here than usual: the shim holds a bus name the client resolves
# once. If it dies and stays dead, the desktop switch goes back to wedging with nothing in a log.
for unit in "$USER_UNIT" "$SYS_UNIT"; do
  if grep -qE '^Restart=on-failure[[:space:]]*$' "$unit"; then
    ok "$(basename "$(dirname "$unit")")/$(basename "$unit"): Restart=on-failure"
  else
    bad "$(basename "$(dirname "$unit")")/$(basename "$unit"): a crash would leave the bus name unowned"
  fi
done

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
