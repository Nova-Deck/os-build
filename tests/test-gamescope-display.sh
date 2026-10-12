#!/usr/bin/env bash
# Offline test for gs_resolve_display() in /usr/lib/novadeck/gamescope-display.sh.
#
#   tests/test-gamescope-display.sh
#
# WHY THIS FILE EXISTS (#113). novadeck-suspend and novadeck-rest run as ROOT and find the live
# gamescope control socket through this resolver. It used to search only $XDG_RUNTIME_DIR, defaulted
# to /run/user/0 from when the session ran as root. The session runs as `deck` (uid 1000) now, so its
# socket is /run/user/1000/gamescope-0, every strategy missed, and every suspend fell back to
# bl_power: backlight off, crtc still scanning out. The resolver must find the socket under whichever
# /run/user/<uid>/ the LIVE gamescope holds its lock in, and hand back that directory.
#
# HOW IT WORKS: the shipped file is sourced as-is. GS_PROC_ROOT and GS_RUN_ROOT point it at a fake
# /proc (fd symlinks) and a fake /run/user (real AF_UNIX sockets, because the resolver tests -S).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/rootfs/overlay/usr/lib/novadeck/gamescope-display.sh"
SUSPEND="$ROOT/rootfs/overlay/usr/bin/novadeck-suspend"
REST="$ROOT/rootfs/overlay/usr/bin/novadeck-rest"
[ -f "$LIB" ] || { echo "no resolver: $LIB" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# A real socket file: the resolver checks `[ -S ]`, which a plain file or a fifo fails.
mksock() { python3 -I -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
# A process "holding" a lock: an fd symlink in the fake /proc pointing at it.
holds() {  # $1 = fake proc root, $2 = pid, $3 = fd, $4 = target
  mkdir -p "$1/$2/fd"; ln -s "$4" "$1/$2/fd/$3"
}
# Display slot: control socket + its lock, under a run dir.
slot() {  # $1 = run dir, $2 = name (e.g. gamescope-0)
  mkdir -p "$1"; mksock "$1/$2"; : >"$1/$2.lock"
}

# Run the resolver in a clean /bin/sh with only the given env; print "rc|XDG|DISPLAY".
resolve() {  # $1 = proc root, $2 = run root, rest = extra VAR=value
  local proc="$1" run="$2"; shift 2
  env -i PATH=/usr/bin:/bin GS_PROC_ROOT="$proc" GS_RUN_ROOT="$run" "$@" /bin/sh -c \
    ". '$LIB'; gs_resolve_display; rc=\$?; printf '%s|%s|%s' \"\$rc\" \"\${XDG_RUNTIME_DIR:-}\" \"\${GAMESCOPE_WAYLAND_DISPLAY:-}\""
}
expect() {  # $1 = got, $2 = want, $3 = what
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', want '$2'"; fi
}

# =================================================================================================
CASE="deck-session-from-a-root-service"
# THE #113 SHAPE: systemd-suspend.service, root, no XDG_RUNTIME_DIR at all; gamescope runs as deck.
T="$W/t1"; slot "$T/run/1000" gamescope-0; holds "$T/proc" 1515 7 "$T/run/1000/gamescope-0.lock"
expect "$(resolve "$T/proc" "$T/run")" "0|$T/run/1000|gamescope-0" \
  "finds the socket in deck's runtime dir and exports that dir"

CASE="root-ssh-env-does-not-win"
# Root over SSH: pam_systemd sets XDG_RUNTIME_DIR=/run/user/0, which holds no gamescope. A runtime
# dir alone is not an override; only a dir + display pair that names a real socket is.
mkdir -p "$T/run/0"
expect "$(resolve "$T/proc" "$T/run" XDG_RUNTIME_DIR="$T/run/0")" "0|$T/run/1000|gamescope-0" \
  "an inherited empty /run/user/0 does not stop the search"

CASE="explicit-pair-is-honoured"
T="$W/t2"; slot "$T/run/1000" gamescope-0; slot "$T/run/1000" gamescope-1
holds "$T/proc" 10 3 "$T/run/1000/gamescope-0.lock"
expect "$(resolve "$T/proc" "$T/run" XDG_RUNTIME_DIR="$T/run/1000" GAMESCOPE_WAYLAND_DISPLAY=gamescope-1)" \
  "0|$T/run/1000|gamescope-1" "XDG_RUNTIME_DIR + GAMESCOPE_WAYLAND_DISPLAY naming a socket wins"

CASE="stale-slot-is-skipped"
# The bug this resolver was first written for: an unclean exit leaves gamescope-0 on disk, the live
# compositor lands on gamescope-1. Only the live one has a process holding its lock.
T="$W/t3"; slot "$T/run/1000" gamescope-0; slot "$T/run/1000" gamescope-1
holds "$T/proc" 22 9 "$T/run/1000/gamescope-1.lock"
expect "$(resolve "$T/proc" "$T/run")" "0|$T/run/1000|gamescope-1" \
  "picks the slot whose lock is held, not the stale gamescope-0"

CASE="ei-lock-is-not-a-control-socket"
T="$W/t4"; mkdir -p "$T/run/1000"; mksock "$T/run/1000/gamescope-0-ei"; : >"$T/run/1000/gamescope-0-ei.lock"
holds "$T/proc" 30 4 "$T/run/1000/gamescope-0-ei.lock"
r="$(resolve "$T/proc" "$T/run")"
case "$r" in 1\|*) ok "a held gamescope-N-ei.lock is ignored ($r)" ;; *) bad "resolved to '$r' from an -ei lock" ;; esac

CASE="only-one-level-below-the-run-root"
T="$W/t5"; slot "$T/run/1000/nested" gamescope-0; holds "$T/proc" 40 5 "$T/run/1000/nested/gamescope-0.lock"
r="$(resolve "$T/proc" "$T/run")"
case "$r" in 1\|*) ok "a lock nested deeper than /run/user/<uid>/ is ignored" ;; *) bad "resolved to '$r' from a nested lock" ;; esac

CASE="single-socket-fallback-reports-its-dir"
# No lock holder visible (e.g. /proc unreadable): exactly one bare control socket anywhere is taken.
T="$W/t6"; slot "$T/run/1000" gamescope-0; mkdir -p "$T/proc"
expect "$(resolve "$T/proc" "$T/run")" "0|$T/run/1000|gamescope-0" \
  "one socket across all runtime dirs resolves, with its own dir"

CASE="ambiguous-fallback-fails"
T="$W/t7"; slot "$T/run/1000" gamescope-0; slot "$T/run/1001" gamescope-0; mkdir -p "$T/proc"
r="$(resolve "$T/proc" "$T/run")"
case "$r" in 1\|*) ok "two candidate sockets and no lock holder is a failure, not a guess" ;; *) bad "guessed '$r'" ;; esac

CASE="nothing-running"
T="$W/t8"; mkdir -p "$T/run/1000" "$T/proc"
r="$(resolve "$T/proc" "$T/run")"
case "$r" in 1\|*) ok "no gamescope at all returns non-zero ($r)" ;; *) bad "claimed '$r' with no gamescope" ;; esac

CASE="callers-do-not-pin-root-s-runtime-dir"
# STRUCTURAL: a `: "${XDG_RUNTIME_DIR:=/run/user/0}"` in a caller is exactly what hid the deck socket.
for f in "$SUSPEND" "$REST"; do
  if grep -qE 'XDG_RUNTIME_DIR:=/run/user/0' "$f"; then
    bad "$(basename "$f") still defaults XDG_RUNTIME_DIR to /run/user/0"
  else
    ok "$(basename "$f") leaves the runtime dir to the resolver"
  fi
done

echo
echo "test-gamescope-display.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
