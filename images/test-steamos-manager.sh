#!/usr/bin/env bash
# Offline test for the SteamOS-Manager compatibility shim, /usr/bin/novadeck-steamos-manager.
#
#   images/test-steamos-manager.sh
#
# WHY THIS FILE EXISTS. The shim's properties are declared without an EmitsChangedSignal
# annotation, so D-Bus's default applies and every client is entitled to CACHE them and to trust
# PropertiesChanged to keep that cache honest. The Steam client does exactly that: it does NOT
# re-read the performance profile when the QAM opens, and when its cache is stale it SKIPS writes
# it believes are redundant. So a missed signal does not degrade to "the UI lags" — it degrades to
# "the profile control silently stops working", with nothing in any log.
#
# That failure is invisible on hardware without a second machine on the bus, and it is exactly
# what shipped: the shim emitted only from its own set_property handlers, so a change arriving by
# any other route (PPD's ActiveProfile, powerd itself) left the client believing the old value.
# The re-emit path that fixes it is pinned here rather than left to a device test, because the
# device test cannot tell "no signal" apart from "signal the client ignored".
#
# Everything runs on the host: the shim is imported by path and driven with real GLib.Variants
# against a recording connection, so no bus, no powerd and no root are involved.
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

# --- 1. the re-emit path ------------------------------------------------------------------------
#
# Driven from python because that is where the code is. The harness prints the same "ok"/"FAIL"
# lines this script does and exits nonzero if any case failed, so the two tallies stay one report.
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
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import GLib

shim_path = sys.argv[1]
spec = importlib.util.spec_from_loader(
    "shim", importlib.machinery.SourceFileLoader("shim", shim_path))
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

    # (iface, {prop: printed-value}) for each PropertiesChanged, in order.
    def changes(self):
        out = []
        for _dest, _path, _iface, _name, params in self.emitted:
            body = params.get_child_value(1)
            props = {}
            for i in range(body.n_children()):
                e = body.get_child_value(i)
                props[e.get_child_value(0).get_string()] = \
                    e.get_child_value(1).get_variant().print_(True)
            out.append((params.get_child_value(0).get_string(), props))
        return out


def manager():
    """A manager with no __init__: the real one dials the system bus in PowerClient()."""
    m = sm.NovadeckSteamOSManager.__new__(sm.NovadeckSteamOSManager)
    m.connection = FakeConnection()
    m.last_emitted = {}
    return m


def powerd_signal(props, iface=None):
    """A PropertiesChanged as powerd emits it: (sa{sv}as)."""
    return GLib.Variant("(sa{sv}as)",
                        (iface if iface is not None else sm.POWER_IFACE, props, []))


def feed(m, props, iface=None):
    m.on_power_changed(None, None, None, None, None, powerd_signal(props, iface))


# --- the inversion is COMPLETE ------------------------------------------------------------------
#
# POWERD_TO_STEAM is built by inverting the three property maps. If a property is added to one of
# them and the inversion misses it, get_property() still works and only the re-announce goes
# quiet -- i.e. the exact silent-stale-cache failure this file exists for, reintroduced for one
# property. Checked structurally so a new property cannot land uncovered.
for iface, table, label in [
    (sm.IFACE_PROFILE, sm.PROFILE_PROPS, "PerformanceProfile1"),
    (sm.IFACE_GPU,     sm.GPU_PROPS,     "GpuPerformanceLevel1"),
    (sm.IFACE_SCHED,   sm.SCHED_PROPS,   "CpuScheduler1"),
]:
    missing = [p for p in table.values() if p not in sm.POWERD_TO_STEAM]
    if missing:
        bad(f"{label}: powerd props absent from POWERD_TO_STEAM: {missing} — changes go unannounced")
        continue
    wrong = [(pd, sm.POWERD_TO_STEAM[pd]) for ours, pd in table.items()
             if sm.POWERD_TO_STEAM[pd] != (iface, ours)]
    if wrong:
        bad(f"{label}: inversion maps to the wrong iface/name: {wrong}")
    else:
        ok(f"{label}: every powerd property inverts back to its own interface and name")

# --- a powerd-side change is re-announced under OUR names ----------------------------------------
#
# THE ONE THAT MATTERS. This is the whole fix: a change that never went through set_property still
# reaches the client, translated out of powerd's vocabulary into SteamOSManager1's.
m = manager()
feed(m, {"Profile": GLib.Variant("s", "performance")})
changes = m.connection.changes()
if changes == [(sm.IFACE_PROFILE, {"PerformanceProfile": "'performance'"})]:
    ok("a powerd-side Profile change is re-announced as PerformanceProfile1.PerformanceProfile")
else:
    bad(f"powerd-side Profile change did not re-announce correctly: {changes}")

# powerd's name must NOT leak: a client watching for SteamOSManager1 names would never see it.
if not changes:
    bad("nothing was emitted — cannot judge whether powerd's raw name leaks")
elif "Profile" not in changes[0][1]:
    ok("powerd's own property name does not leak into the emitted signal")
else:
    bad("emitted powerd's raw property name — no SteamOSManager1 client is watching for it")

# --- properties split across their real interfaces -----------------------------------------------
#
# One powerd signal can carry properties belonging to different SteamOSManager1 interfaces. They
# must go out as separate PropertiesChanged, because the interface name is part of the signal body
# and a client caches per interface.
m = manager()
feed(m, {"Profile": GLib.Variant("s", "balanced"),
         "GpuPerformanceLevel": GLib.Variant("s", "auto")})
by_iface = dict(m.connection.changes())
if (by_iface.get(sm.IFACE_PROFILE, {}).get("PerformanceProfile") == "'balanced'"
        and by_iface.get(sm.IFACE_GPU, {}).get("GpuPerformanceLevel") == "'auto'"):
    ok("properties from one powerd signal are split onto their own interfaces")
else:
    bad(f"properties were not split per interface: {m.connection.changes()}")

# --- powerd properties with no SteamOSManager1 equivalent ----------------------------------------
#
# powerd owns more than the shim exposes (fan, temperature...). Those must be dropped silently --
# not crash the handler, which would take the re-emit path down for every OTHER property too.
m = manager()
feed(m, {"FanSpeed": GLib.Variant("u", 2200), "Temperature": GLib.Variant("d", 47.5)})
if m.connection.emitted == []:
    ok("powerd properties with no SteamOSManager1 equivalent are dropped, not emitted")
else:
    bad(f"emitted a signal for properties the shim does not expose: {m.connection.changes()}")

m = manager()
feed(m, {"FanSpeed": GLib.Variant("u", 2200), "Profile": GLib.Variant("s", "performance")})
if dict(m.connection.changes()).get(sm.IFACE_PROFILE, {}).get("PerformanceProfile") == "'performance'":
    ok("an unmapped property alongside a mapped one does not suppress the mapped one")
else:
    bad("an unmapped property suppressed the mapped property in the same signal")

# --- signals from something other than powerd's interface ----------------------------------------
m = manager()
feed(m, {"Profile": GLib.Variant("s", "performance")}, iface="org.example.Other")
if m.connection.emitted == []:
    ok("a PropertiesChanged for a different interface is ignored")
else:
    bad("re-announced a change from an unrelated interface")

# --- the dedupe: a write through us must not announce twice --------------------------------------
#
# set_property emits directly AND the write comes back through the powerd subscription. Without
# dedupe the client sees the same change twice.
m = manager()
m.emit_properties(sm.IFACE_PROFILE, {"PerformanceProfile": GLib.Variant("s", "performance")})
feed(m, {"Profile": GLib.Variant("s", "performance")})
if len(m.connection.emitted) == 1:
    ok("a value already announced is not announced again by the powerd echo")
else:
    bad(f"the powerd echo double-announced: {m.connection.changes()}")

# THE SHARP ONE. A dedupe that remembers the last value can silently swallow a LATER genuine
# change if it is written carelessly -- and the symptom is identical to the bug this whole file
# exists for, so it would not be caught by the cases above. A->B->A must produce three signals.
m = manager()
for value in ("performance", "balanced", "performance"):
    feed(m, {"Profile": GLib.Variant("s", value)})
seen = [props["PerformanceProfile"] for _iface, props in m.connection.changes()]
if seen == ["'performance'", "'balanced'", "'performance'"]:
    ok("a value returning to a previously-seen one is still announced (A->B->A emits 3)")
else:
    bad(f"dedupe swallowed a genuine change: expected 3 alternating signals, got {seen}")

# A repeat of the CURRENT value is the one thing that must stay quiet.
m = manager()
for _ in range(3):
    feed(m, {"Profile": GLib.Variant("s", "balanced")})
if len(m.connection.emitted) == 1:
    ok("an unchanged value repeated by powerd is announced once, not once per signal")
else:
    bad(f"re-announced an unchanged value {len(m.connection.emitted)} times")

# Dedupe must be keyed per (interface, property): two interfaces can carry the same property name
# and the same value without masking each other.
m = manager()
m.emit_properties(sm.IFACE_PROFILE, {"Shared": GLib.Variant("s", "x")})
m.emit_properties(sm.IFACE_GPU, {"Shared": GLib.Variant("s", "x")})
if len(m.connection.emitted) == 2:
    ok("dedupe is keyed per interface — the same name and value on two interfaces both emit")
else:
    bad("dedupe collapsed the same property name across two different interfaces")

# --- never emit an empty PropertiesChanged -------------------------------------------------------
#
# If every property in a batch deduped away, the batch must vanish with them. An empty
# PropertiesChanged is a wakeup for every subscribed client that says nothing.
m = manager()
m.emit_properties(sm.IFACE_PROFILE, {"PerformanceProfile": GLib.Variant("s", "performance")})
before = len(m.connection.emitted)
m.emit_properties(sm.IFACE_PROFILE, {"PerformanceProfile": GLib.Variant("s", "performance")})
if len(m.connection.emitted) == before:
    ok("a fully-deduped batch emits no empty PropertiesChanged")
else:
    bad("emitted an empty PropertiesChanged after everything deduped away")

# --- a mixed batch keeps only what actually changed ----------------------------------------------
m = manager()
m.emit_properties(sm.IFACE_GPU, {"GpuPerformanceLevel": GLib.Variant("s", "auto"),
                                 "ManualGpuClock": GLib.Variant("u", 500)})
m.emit_properties(sm.IFACE_GPU, {"GpuPerformanceLevel": GLib.Variant("s", "auto"),
                                 "ManualGpuClock": GLib.Variant("u", 800)})
last = m.connection.changes()[-1][1]
if last == {"ManualGpuClock": "uint32 800"}:
    ok("a partly-changed batch announces only the property that moved")
else:
    bad(f"announced unchanged properties alongside the changed one: {last}")

# --- the signal body is a well-formed PropertiesChanged ------------------------------------------
#
# Emitted by hand rather than by GDBus, so the signature and destination are ours to get wrong. A
# malformed body is dropped by the client with no error anywhere on our side.
m = manager()
feed(m, {"Profile": GLib.Variant("s", "performance")})
if not m.connection.emitted:
    # Guarded rather than indexed blind: an empty list here is a real regression elsewhere, and
    # letting it raise would kill the harness before it printed its tally.
    bad("nothing was emitted — cannot inspect the signal body")
else:
    dest, path, iface, name, params = m.connection.emitted[0]
    checks = [
        (dest is None, "broadcast (no destination)"),
        (path == sm.OBJECT_PATH, f"path is {sm.OBJECT_PATH}"),
        (iface == "org.freedesktop.DBus.Properties", "interface is org.freedesktop.DBus.Properties"),
        (name == "PropertiesChanged", "member is PropertiesChanged"),
        (params.get_type_string() == "(sa{sv}as)", "signature is (sa{sv}as)"),
    ]
    wrong = [label for good, label in checks if not good]
    if wrong:
        bad(f"malformed signal — wrong: {wrong}")
    else:
        ok("the emitted signal is a well-formed broadcast PropertiesChanged on the shim's object")

print(f"__COUNTS__ {P} {F}")
PY
)"
  shim_rc=$?
  echo "$shim_out" | grep -v '^__COUNTS__'
  # Tally from the lines actually printed, NOT from the sentinel. If the harness dies partway the
  # sentinel never arrives, and crediting it with nothing would print a summary that contradicts
  # the FAIL lines immediately above it — the one number a CI reader is most likely to trust.
  PASS=$((PASS + $(echo "$shim_out" | grep -c '^  ok   shim --')))
  FAIL=$((FAIL + $(echo "$shim_out" | grep -c '^  FAIL shim --')))
  # The sentinel's remaining job: prove the harness reached the end, so a crash cannot pass as a
  # clean run just because everything printed before it happened to be green.
  if ! echo "$shim_out" | grep -q '^__COUNTS__'; then
    bad "the python harness died partway (rc=$shim_rc) — the cases after it never ran"
  fi
fi

# --- 2. the units that put it on the bus SteamUI reads --------------------------------------------
#
# The re-emit path is worth nothing if the instance the Steam client talks to is not running. The
# client connects on the USER session bus, so the user unit is the load-bearing one; the system
# unit is parity.
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
# instance come up on EVERY boot regardless, so SteamUI never faces an empty bus name.
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
# once. If it dies and stays dead, the QAM's power controls go inert with nothing in a log.
for unit in "$USER_UNIT" "$SYS_UNIT"; do
  if grep -qE '^Restart=on-failure[[:space:]]*$' "$unit"; then
    ok "$(basename "$(dirname "$unit")")/$(basename "$unit"): Restart=on-failure"
  else
    bad "$(basename "$(dirname "$unit")")/$(basename "$unit"): a crash would leave the bus name unowned"
  fi
done

# The subscription is established once, guarded on power_subscription being None. bus_acquired can
# fire again after a bus reconnect; a second subscription would double every re-announce.
if grep -q 'if self.power_subscription is None:' "$SHIM"; then
  ok "the powerd subscription is guarded — a bus reconnect cannot double-subscribe"
else
  bad "nothing guards the powerd subscription: a reconnect would announce every change twice"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
