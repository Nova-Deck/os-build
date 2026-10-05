#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-session's gamescope TEARDOWN.
#
#   tests/test-session.sh
#
# THE DEFECT, HW 2026-10-04 (Pocket S2): the Steam client segfaulted mid-install, novadeck-session
# exited 139, and SDDM's autologin started the next session 14 ms later. cleanup() had only SENT
# gamescope a SIGTERM and returned, so the old gamescope was still alive holding /dev/dri/card0 for
# another ~0.7 s. The new gamescope's logind TakeDevice failed with EBUSY ("Could not open KMS
# device"), novadeck-session timed out on the startup handshake, and SDDM does not relogin after
# that: one client crash became a permanently black screen.
#
# HOW IT WORKS: cleanup() is extracted from the SHIPPED script by name and run against a fake
# gamescope started as a CHILD of the same shell -- which matters, because an exited child stays a
# zombie until reaped, and a zombie still answers `kill -0`. What runs under test is the text that
# ships; nothing is reimplemented here. The script as a whole cannot run on a host (it needs logind,
# a DRM device and gamescope), so only the teardown is executed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="$ROOT/rootfs/overlay/usr/bin/novadeck-session"
[ -f "$SESSION" ] || { echo "no novadeck-session: $SESSION" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

extract() { sed -n "/^$1() {/,/^}/p" "$SESSION"; }
for fn in gs_running cleanup; do
  [ -n "$(extract "$fn")" ] || { echo "could not extract $fn() from the shipped script" >&2; exit 1; }
done
{ extract gs_running; extract cleanup; } > "$W/cleanup.sh"

# Runs cleanup() in /bin/sh (the script's interpreter) against a fake gamescope whose SIGTERM
# handling is $1, with the stop bound set to $2 seconds. Prints "<elapsed ms> <fake state>", where
# the state is read BEFORE anything reaps the child: "gone" or "Z" means its fds are closed (DRM
# released), anything else means it is still running.
run_cleanup() {
  /bin/sh -c '
    . "$1"
    GS_RUNDIR="$2/rundir"; mkdir -p "$GS_RUNDIR"
    NOVADECK_GAMESCOPE_STOP_TIMEOUT="$4"
    /bin/sh -c "$3" &
    GS_PID=$!
    fake=$GS_PID   # cleanup() clears GS_PID once it is done with it
    sleep 0.3   # let the fake install its trap
    t0=$(date +%s%N)
    cleanup 2>/dev/null
    t1=$(date +%s%N)
    st=gone
    [ -e "/proc/$fake" ] && st=$(sed -n "s/^State:[[:space:]]*\([A-Z]\).*/\1/p" "/proc/$fake/status")
    echo "$(( (t1 - t0) / 1000000 )) $st"
    kill -KILL "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
    [ -d "$GS_RUNDIR" ] && echo "rundir-left" >&2
    exit 0
  ' sh "$W/cleanup.sh" "$W" "$1" "$2"
}

# =================================================================================================
CASE="cleanup-waits-for-gamescope-to-exit"
# THE ORIGINAL BUG. A gamescope that takes 1 s to wind down after SIGTERM -- the HW teardown took
# ~0.7 s -- must be GONE by the time cleanup() returns, or the next session races it for the DRM device.
read -r ms st < <(run_cleanup 'trap "sleep 1; exit 0" TERM; while :; do sleep 0.1; done' 10)
case "$st" in
  gone|Z) ok "the fake gamescope had exited when cleanup() returned (${ms} ms, state $st)" ;;
  *)      bad "cleanup() returned after ${ms} ms with gamescope still running (state $st) -- the next session gets EBUSY on card0" ;;
esac

CASE="cleanup-is-bounded-when-gamescope-ignores-sigterm"
# The known gamescope SIGTERM wedge (it can ignore TERM entirely) must not hang the session script
# forever: SDDM only relogins once novadeck-session has exited. Bound 1 s here.
read -r ms st < <(run_cleanup 'trap "" TERM; while :; do sleep 0.1; done' 1)
if [ "$ms" -ge 900 ] && [ "$ms" -lt 3000 ]; then
  ok "gave up after ${ms} ms with the 1 s bound"
else
  bad "returned after ${ms} ms with a 1 s bound -- expected ~1000"
fi
case "$st" in
  gone|Z) bad "the TERM-ignoring fake is gone (state $st) -- cleanup() escalated, which it must not" ;;
  *)      ok "it did not escalate past SIGTERM (fake still running, state $st)" ;;
esac

CASE="cleanup-is-idempotent"
# The power-off path calls cleanup() explicitly and the EXIT trap calls it again.
out="$(/bin/sh -c '
  . "$1"; GS_RUNDIR="$2/rundir2"; mkdir -p "$GS_RUNDIR"; NOVADECK_GAMESCOPE_STOP_TIMEOUT=10
  /bin/sh -c "exit 0" & GS_PID=$!
  cleanup && cleanup && echo twice-ok
' sh "$W/cleanup.sh" "$W" 2>&1)"
[ "$out" = "twice-ok" ] && ok "a second call is a clean no-op" || bad "second call misbehaved: '${out:-<nothing>}'"

# =================================================================================================
# gamescope patch 0024 commits further ahead of vblank while the planes rotate, at a latency cost
# paid only on rotated frames. Traced on the Pocket S2 (a DPU underrun after every late commit, a
# one-frame black blink) and seen on the Pocket ACE, so defaults.conf sets it for every board. It
# stays a device-env value rather than a session.conf line so one board can still turn it off.
CASE="scanout rotation lead time"
CONF="$ROOT/rootfs/overlay/etc/novadeck/session.conf"
DEVENV="$ROOT/rootfs/overlay/usr/lib/novadeck/device-env"
DEVDIR="$ROOT/rootfs/overlay/usr/lib/novadeck/devices"
devenv_var() {  # devenv_var <dt model> <var>
  NOVADECK_MODEL="$1" NOVADECK_DEVICE_DIR="$DEVDIR" bash "$DEVENV" | sed -n "s/^$2=//p"
}
n=0; wrong=""
while read -r model; do
  n=$((n+1))
  got="$(devenv_var "$model" NOVADECK_SCANOUT_ROTATION_TIME_US)"
  [ "$got" = 1000 ] || wrong+="$model='$got' "
done < <(sed -n 's/^ *"\([^"]*\)")[[:space:]]*profile=.*/\1/p' "$DEVENV")
[ "$n" -gt 0 ] || bad "found no board models in device-env"
[ -z "$wrong" ] && ok "all $n boards reserve 1000 us" || bad "boards not at the 1000 us default: $wrong"
grep -q 'export GAMESCOPE_SCANOUT_ROTATION_TIME_US="\$NOVADECK_SCANOUT_ROTATION_TIME_US"' "$SESSION" \
  && ok "novadeck-session hands it to gamescope as GAMESCOPE_SCANOUT_ROTATION_TIME_US" \
  || bad "novadeck-session does not export GAMESCOPE_SCANOUT_ROTATION_TIME_US from device-env"
if sed 's,#.*,,' "$CONF" | grep -q GAMESCOPE_SCANOUT_ROTATION_TIME_US; then
  bad "session.conf sets GAMESCOPE_SCANOUT_ROTATION_TIME_US -- keep it in device-env, where a board can override it"
else
  ok "session.conf does not set it; device-env owns it"
fi

# =================================================================================================
echo
echo "test-session: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
