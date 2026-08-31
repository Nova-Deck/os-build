#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-suspend's PANEL BLANK path.
#
#   tests/test-suspend.sh
#
# WHY THIS FILE EXISTS, and why it does not run the engine. novadeck-suspend freezes cgroups and
# offlines CPUs; running do_suspend on a workstation would freeze the workstation. So this covers the
# one part that is pure logic and was the actual defect (#41): what happens to the screen when
# gamescope cannot be reached.
#
# THE DEFECT, HW 2026-07-26: entering suspend by any path that is not Steam's own sleep flow left the
# panel LIT for the whole frozen window. novadeck-suspend runs as systemd-suspend.service (root,
# system.slice) and cannot resolve the live gamescope socket from there, so the KMS blank never
# happened -- and `panel()` reported success anyway, so nothing noticed. Steam's client blank was the
# only thing turning the screen off.
#
# HOW IT WORKS: the two functions are extracted from the SHIPPED script by name and sourced into a
# sandbox, with NOVADECK_BL_GLOB pointed at a fake backlight tree. What runs under test is the text
# that ships; nothing is reimplemented here. The wiring between them (do_suspend falling back,
# do_resume unblanking unconditionally) cannot be executed safely, so it is asserted structurally
# against the same file, and that limit is stated rather than papered over.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUSPEND="$ROOT/rootfs/overlay/usr/bin/novadeck-suspend"
[ -f "$SUSPEND" ] || { echo "no novadeck-suspend: $SUSPEND" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Pull the functions out of the shipped file rather than copying them. A rename breaks the extract
# and fails the suite, which is the intended behaviour: this file must not drift into testing a
# private copy of logic that no longer ships.
extract() { sed -n "/^$1() {/,/^}/p" "$SUSPEND"; }
for fn in bl_power panel; do
  [ -n "$(extract "$fn")" ] || { echo "could not extract $fn() from the shipped script" >&2; exit 1; }
done

{ echo 'log() { :; }'; extract bl_power; } > "$W/bl.sh"

# =================================================================================================
CASE="bl_power-writes-every-backlight"
mkdir -p "$W/bl/panel0" "$W/bl/panel1"
echo 0 >"$W/bl/panel0/bl_power"; echo 0 >"$W/bl/panel1/bl_power"
sh -c ". $W/bl.sh; NOVADECK_BL_GLOB=\"$W/bl/*\"; bl_power 4"
got="$(cat "$W/bl/panel0/bl_power")$(cat "$W/bl/panel1/bl_power")"
[ "$got" = "44" ] && ok "4 (FB_BLANK_POWERDOWN) reaches every device" \
                  || bad "devices read '$got', expected '44'"
sh -c ". $W/bl.sh; NOVADECK_BL_GLOB=\"$W/bl/*\"; bl_power 0"
got="$(cat "$W/bl/panel0/bl_power")$(cat "$W/bl/panel1/bl_power")"
[ "$got" = "00" ] && ok "0 restores every device" || bad "devices read '$got', expected '00'"

CASE="bl_power-reports-when-it-did-nothing"
# The return value is what decides whether the suspend log says "SLEEPING WITH THE PANEL LIT". A
# fallback that silently no-ops is the same defect as the one this fixes, one layer down.
mkdir -p "$W/empty"
sh -c ". $W/bl.sh; NOVADECK_BL_GLOB=\"$W/empty/*\"; bl_power 4"
[ $? -ne 0 ] && ok "returns non-zero when no writable bl_power exists" \
             || bad "returned 0 with nothing to write to"

CASE="panel-reports-an-unreachable-gamescope"
# THE ORIGINAL BUG. panel() used to `return 0` when gamescopectl was missing -- "nothing to do" --
# which is indistinguishable from "the screen is off" to every caller. With no gamescopectl on PATH
# it must now FAIL, because that is what arms the fallback.
{ echo 'log() { :; }'; echo 'gs_resolve_display() { return 1; }'; extract panel; } > "$W/panel.sh"
# The interpreter is invoked by ABSOLUTE PATH and PATH is emptied INSIDE it. Emptying PATH for `env`
# instead makes `sh` itself unfindable, and the test then passes on env's 127 -- which it did on the
# first run of this file. A marker on stdout proves the function actually ran.
mkdir -p "$W/nothing"
out="$(env -i NOVADECK_REST_SCREEN=external /bin/sh -c \
  ". $W/panel.sh; PATH=$W/nothing; panel 1; echo \"rc=\$?\"" 2>/dev/null)"
case "$out" in
  rc=0) bad "reported success with no gamescopectl -- the caller would freeze with the panel lit" ;;
  rc=*) ok "no gamescopectl on PATH is a failure, not a no-op ($out)" ;;
  *)    bad "panel() never ran (output: '${out:-<nothing>}') -- the case proves nothing" ;;
esac

CASE="the-wiring"
# STRUCTURAL, and deliberately so: do_suspend freezes cgroups, so executing it here would freeze the
# machine running the tests. These assert that the two call sites exist at all -- weaker than running
# them, and the honest limit of an offline suite for this file.
if grep -qE '^\s*if panel 1 && wait_panel disabled; then' "$SUSPEND"; then
  ok "the blank waits on the connector only when gamescope actually answered"
else
  bad "do_suspend no longer short-circuits the wait on an unreachable gamescope"
fi
if grep -qE 'bl_power 4' "$SUSPEND"; then
  ok "the suspend path has a backlight fallback"
else
  bad "no bl_power 4 in the suspend path"
fi
# Unconditional on resume: if the blank came from the fallback, gamescope never knew the screen was
# off and nothing else will turn it back on. A woken device stuck dark is worse than one that slept lit.
if grep -qE '^\s*bl_power 0\s*$' "$SUSPEND"; then
  ok "the resume path unblanks the backlight unconditionally"
else
  bad "bl_power 0 is missing or conditional in do_resume -- a wake could stay dark"
fi

echo
echo "test-suspend.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
