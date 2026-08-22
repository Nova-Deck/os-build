#!/usr/bin/env bash
# Offline test for install/ui and install/confirm-ui — the gamepad half of §4d's consent contract.
#
#   install/test-ui.sh
#
# WHY THIS FILE EXISTS. §4d has one trap that every stubbed gate case passes without: THE
# RENDERER'S STDOUT IS THE ANSWER AND NOTHING ELSE. A renderer that also writes its screen there
# makes every attempt read as a wrong answer — an installer that can never take consent, with a
# symptom ("that was not the sequence shown") pointing nowhere near the cause. The tty renderer paid
# for that finding once; the plan requires the gamepad renderer to have its own case against the
# real thing rather than inherit the confidence.
#
# HOW IT RUNS WITH NO SDL, NO PANEL AND NO PAD. install/ui imports pygame lazily, inside its view
# only, and takes its input from a file of tokens when NOVADECK_UI_EVENTS is set. So the real
# shipped file — not a copy, not a mangled variant — runs here as its own state machine, answers a
# real unix socket, and is driven by the real install/confirm-ui. What is NOT covered is anything
# with a pixel in it: the drawing is asserted through describe(), which is what the view is handed.
#
# The end-to-end against the SPINE lives in install/test-install.sh, next to its sandbox, for the
# same reason the tty renderer's does: the sandbox that stubs sgdisk/mkfs/rauc is that file's, and
# a second copy of it here would be a regression rather than a convenience.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UI="$ROOT/install/ui"
SHIM="$ROOT/install/confirm-ui"
VIEW="$ROOT/install/uiview.py"
for f in "$UI" "$SHIM"; do
  [ -x "$f" ] || { echo "not executable: $f" >&2; exit 1; }
done
[ -f "$VIEW" ] || { echo "no view module: $VIEW" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"; pkill -f "$UI" 2>/dev/null' EXIT
# Loading install/ui as a module writes a __pycache__ next to it, which the installer image build
# would then copy verbatim. Keep the bytecode in the sandbox. Same reason as images/test-update.sh.
export PYTHONPYCACHEPREFIX="$T/pycache"
export NOVADECK_UI_DEADLINE=30

cat >"$T/facts-wipe" <<'EOF'
SCREEN=android-wipe
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
UD_INDEX=11
UD_GIB_NOW=96
UD_GIB_AFTER=16
NOVADECK_GIB=80
REPLACES_OURS=0
HOME_ACTION=create
EOF
cat >"$T/facts-reinst" <<'EOF'
SCREEN=reinstall
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
HOME_ACTION=keep
HOME_GIB=214
EOF
cat >"$T/facts-replaces" <<'EOF'
SCREEN=android-wipe
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
UD_INDEX=11
UD_GIB_NOW=96
UD_GIB_AFTER=16
NOVADECK_GIB=90
REPLACES_OURS=1
HOME_GIB=180
HOME_ACTION=create
EOF

# --- the harness -----------------------------------------------------------------------------
# Start the real UI with a scripted input source, wait for its socket, then ask it for consent
# through the real shim. $OUT is the shim's stdout ALONE and $ERR everything else, because keeping
# those two apart is the property most of this file is about.
ui_ask() {  # <events-file> <facts> <sequence>
  local events="$1" facts="$2" seq="$3" i=0
  SOCK="$T/sock.$RANDOM"
  NOVADECK_UI_SOCK="$SOCK" NOVADECK_UI_EVENTS="$events" "$UI" >"$T/ui.log" 2>&1 &
  UI_PID=$!
  while [ ! -S "$SOCK" ]; do
    i=$((i+1)); [ "$i" -gt 300 ] && { echo "the UI never created its socket" >&2; return 9; }
    sleep 0.02
  done
  NOVADECK_UI_SOCK="$SOCK" "$SHIM" --facts "$facts" --sequence "$seq" >"$T/out" 2>"$T/err"
  local rc=$?
  wait "$UI_PID" 2>/dev/null
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
  return $rc
}

# describe() for a given facts file, as JSON, straight out of the shipped file.
describe() {  # <facts> <sequence> [pressed]
  FACTS="$1" SEQ="$2" PRESSED="${3:-}" python3 - <<'PY'
import importlib.util, json, os
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvui", os.path.join(os.environ["ROOT"], "install/ui"))
spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
s = ui.ConsentScreen(ui.read_facts(os.environ["FACTS"]), os.environ["SEQ"])
for t in os.environ.get("PRESSED", ""):
    s.handle(t)
print(json.dumps({"desc": s.describe(), "result": s.result}))
PY
}
export ROOT

# =================================================================================================
CASE="confirm-ui: stdout is the answer and nothing else"
# THE CASE THE PLAN DEMANDS. The spine reads this in a command substitution and compares it to the
# sequence it asked for; one stray line and consent can never be given.
printf 'SHOWN\n' >"$T/ev-ok"
if ui_ask "$T/ev-ok" "$T/facts-wipe" SWNE; then
  ok "the shim exits 0 when the sequence is pressed"
else
  bad "the shim failed: $ERR"
fi
[ "$OUT" = SWNE ] \
  && ok "and its stdout is exactly the pressed sequence" \
  || bad "stdout was not the answer: $(printf '%q' "$OUT")"
[ "$(printf '%s' "$OUT" | wc -l)" -le 1 ] \
  && ok "one line, nothing else -- no screen text, no log line, no progress" \
  || bad "stdout carried more than the answer"
# And the structural half of the same property: the UI writes a line about this very request, and
# that line does not and cannot land on the shim's stdout. The tty renderer had to keep its whole
# screen off one file descriptor; here the renderer is a different process entirely.
grep -q "consent requested for /dev/sda (android-wipe), sequence SWNE" "$T/ui.log" \
  && ok "while the UI logs the request it was given, on its own descriptor, harmlessly" \
  || bad "the UI did not log the request: $(cat "$T/ui.log")"

CASE="confirm-ui: a wrong press is returned as a wrong answer, immediately"
printf 'S\nS\n' >"$T/ev-wrong"
ui_ask "$T/ev-wrong" "$T/facts-wipe" SWNE
[ "$OUT" = SS ] \
  && ok "the second press ends the attempt rather than collecting two more that cannot matter" \
  || bad "a wrong press did not end the attempt: $(printf '%q' "$OUT")"
[ "$OUT" != SWNE ] \
  && ok "and what it returns is not the sequence, so the spine re-randomises and asks again" \
  || bad "a wrong press produced the right answer"

CASE="confirm-ui: SELECT cancels, and a cancel is not an answer"
printf 'BACK\n' >"$T/ev-abort"
if ui_ask "$T/ev-abort" "$T/facts-wipe" SWNE; then
  bad "an abort exited 0, which the spine would read as consent"
else
  ok "an abort exits non-zero, which the spine reads as 'the install was cancelled'"
fi
[ -z "$OUT" ] \
  && ok "and it prints nothing at all on stdout" \
  || bad "an abort put something on stdout: $(printf '%q' "$OUT")"

CASE="confirm-ui: it fails closed when there is no UI to ask"
NOVADECK_UI_SOCK="$T/nothing-here.sock" NOVADECK_UI_CONNECT_TIMEOUT=1 \
  "$SHIM" --facts "$T/facts-wipe" --sequence SWNE >"$T/out" 2>"$T/err" \
  && bad "the shim exited 0 with no UI running" \
  || ok "no UI means a non-zero exit -- 'we could not ask' must never look like 'they said yes'"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it printed something without an answer"
grep -qi 'cannot reach the installer UI' "$T/err" \
  && ok "and it says so on stderr, where the operator can read it" \
  || bad "the failure is silent: $(cat "$T/err")"

CASE="confirm-ui: a UI that dies mid-wait is not consent either"
python3 - "$T/dead.sock" <<'PY' &
import socket, sys, os
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p); s.listen(1)
c, _ = s.accept()
c.recv(4096)
c.close(); s.close(); os.unlink(p)
PY
DEAD=$!
for _ in $(seq 1 100); do [ -S "$T/dead.sock" ] && break; sleep 0.02; done
NOVADECK_UI_SOCK="$T/dead.sock" "$SHIM" --facts "$T/facts-wipe" --sequence SWNE \
  >"$T/out" 2>"$T/err" \
  && bad "a connection that closed without answering exited 0" \
  || ok "a UI that goes away mid-wait exits non-zero"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it printed something"
wait "$DEAD" 2>/dev/null

CASE="confirm-ui: it refuses facts it cannot render, rather than inventing a screen"
printf 'SCREEN=something-else\nDISK=/dev/sda\n' >"$T/facts-bogus"
printf 'SHOWN\n' >"$T/ev-ok2"
ui_ask "$T/ev-ok2" "$T/facts-bogus" SWNE \
  && bad "an unknown screen was rendered and answered" \
  || ok "an unknown screen is refused"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it answered anyway"

# =================================================================================================
CASE="ui: the buttons are POSITIONS, and the mapping is the only place a letter exists"
python3 - <<'PY' && ok "SDL's positional constants map to N/E/S/W at the event boundary" \
                 || bad "the button mapping is not positional"
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uipad
# SDL_CONTROLLER_BUTTON_A/B/X/Y are 0/1/2/3 and are defined by POSITION: bottom, right, left, top.
want = {0: "S", 1: "E", 2: "W", 3: "N"}
sys.exit(0 if uipad.BUTTON_TO_CARDINAL == want and set(uipad.CARDINALS) == {"N","E","S","W"} else 1)
PY
# The silkscreen differs between boards (`A` is EAST on the Pocket ACE, SOUTH on the Pocket S2), so
# a button letter must not survive into anything drawn. This reads what describe() actually returns
# rather than trusting the source.
for facts in "$T/facts-wipe" "$T/facts-reinst" "$T/facts-replaces"; do
  text="$(describe "$facts" SWNE | python3 -c 'import json,sys; d=json.load(sys.stdin)["desc"]; print(d["title"], d["prompt"], d["note"], d["abort"], " ".join(h+" "+b for h,b in d["blocks"]), " ".join(x["name"] for x in d["diamonds"]))')"
  if printf '%s' "$text" | grep -qE '\b(button|press(es|ed)?) *[ABXY]\b|\b[ABXY] button\b'; then
    bad "a face-button letter reached the screen for $(basename "$facts")"
  else
    ok "no face-button letter on the screen for $(basename "$facts")"
  fi
done
d="$(describe "$T/facts-wipe" NESW | python3 -c 'import json,sys; print(" ".join(x["pos"]+":"+x["name"] for x in json.load(sys.stdin)["desc"]["diamonds"]))')"
[ "$d" = "N:NORTH E:EAST S:SOUTH W:WEST" ] \
  && ok "the diamonds follow the sequence, in order, named by position" \
  || bad "the diamonds do not follow the sequence: $d"

CASE="ui: the screen is DERIVED from the facts, never a fixed string"
a="$(describe "$T/facts-wipe" SWNE)"
b="$(describe "$T/facts-reinst" SWNE)"
printf '%s' "$a" | grep -q '96 GiB' && printf '%s' "$a" | grep -q '16 GiB' \
  && ok "the wipe screen quotes both the size lost and the size kept" \
  || bad "the wipe screen does not quote the measured sizes"
printf '%s' "$a" | grep -qi 'NOT recoverable' \
  && ok "and says the loss is permanent, in the user's terms" \
  || bad "the wipe screen does not say the loss is permanent"
printf '%s' "$a" | grep -qi 'Volume Up' \
  && ok "and names how to get back to Android" \
  || bad "the wipe screen does not say how to reach Android afterwards"

CASE="ui: the two consent screens cannot render each other"
printf '%s' "$b" | grep -qi 'deletes Android' \
  && bad "the reinstall screen renders the Android-wipe warning, which is flatly false there" \
  || ok "no Android-wipe text on the reinstall path"
printf '%s' "$b" | grep -q '214 GiB' \
  && ok "it quotes the /home figure instead" \
  || bad "the reinstall screen does not quote the /home size"
printf '%s' "$a" | grep -qi 'asked to erase /home' \
  && bad "the wipe screen rendered the reinstall's erase text" \
  || ok "and the wipe screen cannot produce the reinstall wording"

CASE="ui: it never reassures about the thing it is deleting"
# The finding of 2026-08-21, which cost the tty screen a hardware run: `fresh` on a disk that is
# already ours destroys the novadeck /home, and "your game library is safe" is true only when the
# games are on the SD card.
r="$(describe "$T/facts-replaces" SWNE)"
printf '%s' "$r" | grep -q 'your game library is safe' \
  && bad "it still reassures 'your game library is safe' while erasing the disk holding it" \
  || ok "the SD-card reassurance drops its second clause when /home is being replaced"
printf '%s' "$r" | grep -qi 'deletes the NovaDeck install already here' \
  && ok "and it says outright that the existing install is going" \
  || bad "it does not disclose that an existing novadeck install is destroyed"
printf '%s' "$r" | grep -q '180 GiB' \
  && ok "quoting what that /home is using today" \
  || bad "it does not quote the /home size at risk"
printf '%s' "$a" | grep -q 'your game library is safe' \
  && ok "while a stock Android disk still gets it -- there the games really are on the card" \
  || bad "the reassurance was lost on the disk where it is true"

CASE="ui: the model is separable from the view"
# Everything above ran with no SDL, no display and no pad, and that is only true while the state
# machine cannot reach pygame at all. The separation is physical: install/ui names pygame nowhere,
# install/uiview.py is the only file that imports it, and install/ui loads that module inside
# build_io() -- i.e. only once something has decided to open a display.
if grep -nE '^[[:space:]]*(import pygame|from pygame)' "$UI"; then
  bad "install/ui imports pygame"
else
  ok "install/ui never imports pygame -- it only ever holds a handle the view gave it"
fi
[ "$(grep -c 'import pygame' "$VIEW")" -eq 1 ] \
  && ok "install/uiview.py imports it exactly once" \
  || bad "uiview.py imports pygame more than once"
grep -qE '^\s+import pygame' "$VIEW" \
  && ok "and that import is inside the view class, not at module scope" \
  || bad "uiview.py imports pygame at module scope"
grep -q 'import uiview' "$UI" \
  && ok "install/ui loads the view lazily, in build_io()" \
  || bad "install/ui does not load the view module"

CASE="ui: the consent socket is root-only"
printf 'SHOWN\n' >"$T/ev-perm"
SOCK="$T/perm.sock"
NOVADECK_UI_SOCK="$SOCK" NOVADECK_UI_EVENTS="$T/ev-perm" "$UI" >/dev/null 2>&1 &
p=$!
for _ in $(seq 1 200); do [ -S "$SOCK" ] && break; sleep 0.02; done
mode="$(stat -c %a "$SOCK" 2>/dev/null)"
[ "$mode" = 600 ] \
  && ok "mode 0600 -- nothing else on the medium has business answering for the user" \
  || bad "the socket is mode $mode"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

# =================================================================================================
# pre-flight — §5's screen before the gate
# =================================================================================================
# Stubs for the three read-only tools the screen derives from. The carve stub RECORDS its calls, so
# a case can assert the screen re-asks rather than interpolating between answers.
mkdir -p "$T/bin"
cat >"$T/bin/select-target.sh" <<'EOF'
#!/usr/bin/env bash
printf 'TARGET=/dev/sda\nMODE=fresh\nSECTOR=512\nUD_INDEX=11\nUD_START=100\nUD_END=200\nCEIL=999\n'
EOF
cat >"$T/bin/carve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CARVE_CALLS"
printf 'CEIL=999\nNEW_END=500\nNOVADECK_MIB=81920\nNOVADECK_GIB=%s\nREPLACES_OURS=1\n' "$(( 96 - $3 ))"
printf 'DESTROY=11 userdata data-erased\n'
printf 'DESTROY=17 novadeck-home replaced\n'
EOF
cat >"$T/bin/device-env" <<'EOF'
#!/usr/bin/env bash
printf "NOVADECK_DEVICE_NAME='AYANEO Pocket ACE'\nNOVADECK_SOC_CLASS=SM8550\n"
EOF
chmod +x "$T/bin"/*
export CARVE_CALLS="$T/carve-calls"; : >"$CARVE_CALLS"

flow() {  # <python snippet reading `pf` (a PreflightScreen)>
  NOVADECK_SELECT_TARGET="$T/bin/select-target.sh" NOVADECK_CARVE="$T/bin/carve.sh" \
  NOVADECK_DEVICE_ENV="$T/bin/device-env" NOVADECK_INSTALL_BUNDLE="${BUNDLE_OVERRIDE-https://x/b.raucb}" \
  NOVADECK_INSTALL_SEED="${SEED_OVERRIDE-/seed.tar.zst}" SNIPPET="$1" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uiflow
facts = uiflow.gather_preflight()
pf = uiflow.PreflightScreen(facts) if facts else None
exec(os.environ["SNIPPET"])
PY
}

CASE="pre-flight: every figure comes from the tool that will act on it"
out="$(flow 'print(json.dumps(pf.describe()))')"
printf '%s' "$out" | grep -q 'AYANEO Pocket ACE' \
  && ok "the board names itself, from device-env rather than from a guess" \
  || bad "the device name is missing: $out"
printf '%s' "$out" | grep -q '/dev/sda' \
  && ok "and the target is the one select-target.sh chose" \
  || bad "the target is not what select-target returned"
printf '%s' "$out" | grep -q 'p11' && printf '%s' "$out" | grep -q 'p17' \
  && ok "the full list of partitions about to be destroyed is on the screen, by index" \
  || bad "the destroy list is not rendered: $out"
printf '%s' "$out" | grep -qi 'novadeck-home' \
  && ok "including /home, which is the one that costs a user their games" \
  || bad "/home is not named in the destroy list"
printf '%s' "$out" | grep -qi 'Nothing has been written yet' \
  && ok "and it says nothing has happened yet, because nothing has" \
  || bad "the screen does not say the disk is still untouched"

CASE="pre-flight: the size knob re-asks carve.sh, it does not interpolate"
: >"$CARVE_CALLS"
out="$(flow '
pf.handle("RIGHT"); a = pf.describe()
pf.handle("LEFT"); pf.handle("LEFT"); b = pf.describe()
print(json.dumps({"gib": pf.gib, "a": a, "b": b}))')"
[ "$(grep -c . "$CARVE_CALLS")" -ge 4 ] \
  && ok "every adjustment asks carve.sh again ($(grep -c . "$CARVE_CALLS") calls)" \
  || bad "the screen adjusted without re-asking carve: $(cat "$CARVE_CALLS")"
grep -q 'plan /dev/sda 20' "$CARVE_CALLS" && grep -q 'plan /dev/sda 12' "$CARVE_CALLS" \
  && ok "and it asks about the size it is showing, not the one it started with" \
  || bad "carve was not asked about the adjusted sizes: $(cat "$CARVE_CALLS")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["gib"]==12 else 1)' \
  && ok "left and right move it by a step each, with a floor under them" \
  || bad "the adjustment did not land where it should"

CASE="pre-flight: it cannot start an install it has no bundle for"
out="$(BUNDLE_OVERRIDE= flow 'pf.handle("S"); print(json.dumps({"r": pf.result, "d": pf.describe()}))')"
printf '%s' "$out" | grep -q '"r": null' \
  && ok "pressing continue with no bundle configured does nothing at all" \
  || bad "it started an install with no bundle: $out"
printf '%s' "$out" | grep -qi 'NO BUNDLE CONFIGURED' \
  && ok "and the screen says why, rather than looking broken" \
  || bad "the screen does not explain why it will not start"

# =================================================================================================
# progress
# =================================================================================================
progress() {  # <python snippet with `p` (a ProgressScreen) and `feed(lines)`>
  SNIPPET="$1" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uiflow
class FakeRun:
    tail = ["mkfs.ext4: No such file or directory", "novadeck-install: ERROR: the carve failed"]
p = uiflow.ProgressScreen(FakeRun())
def feed(*lines):
    for l in lines: p.feed(l)
exec(os.environ["SNIPPET"])
PY
}

CASE="progress: the phases are the spine's own step markers"
out="$(progress '
feed("[novadeck-install] == recon ==", "[novadeck-install] == carve ==")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | python3 -c '
import json,sys
rows = json.load(sys.stdin)["rows"]
active = [r for r in rows if r["state"] == "active"]
sys.exit(0 if len(active) == 1 and active[0]["label"] == "Repartitioning" else 1)' \
  && ok "the step the spine last printed is the one shown as running" \
  || bad "the active phase does not follow the spine: $out"
out="$(progress '
feed("[novadeck-install] == root slot ==", "  42% Copying image to rootfs.0")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -q '42' \
  && ok "and rauc's own percentage is read off the same pipe -- no second bus client in the installer" \
  || bad "the rauc percentage was not picked up: $out"
out="$(progress '
feed("[novadeck-install] == recon ==", "  42% something")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | python3 -c '
import json,sys
rows = json.load(sys.stdin)["rows"]
sys.exit(0 if all(r["percent"] is None for r in rows if r["state"] != "active") else 1)' \
  && ok "a percentage belongs to the phase that is running, and to no other" \
  || bad "a stale percentage leaked onto another phase"

CASE="progress: a failure says WHICH of two states the device is in"
# The one thing a failure owes the user. "It failed" is not actionable; "nothing was written" and
# "Android's data is already gone" are different situations and only one needs anything done.
out="$(progress '
feed("[novadeck-install] == verify sources ==")
p.finish(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'Nothing was written' \
  && ok "a failure before the carve says the device is exactly as it was" \
  || bad "it does not tell the user the disk is untouched: $out"
printf '%s' "$out" | grep -qi 'was modified' \
  && bad "it claims the disk was modified when the carve never ran" \
  || ok "and it does not claim otherwise"
out="$(progress '
feed("[novadeck-install] == carve ==", "[novadeck-install] == filesystems ==")
p.finish(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'disk WAS modified' \
  && ok "a failure after the carve says so, and that Android's data is already gone" \
  || bad "a failure past the carve still claims nothing was written: $out"
printf '%s' "$out" | grep -q 'the carve failed' \
  && ok "and it shows the tail of what the spine actually said" \
  || bad "the error text is not on the screen"
out="$(progress 'p.finish(0); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'Remove the SD card' \
  && ok "success tells the user the one thing they must do next" \
  || bad "the success screen does not say to remove the card"
printf '%s' "$out" | grep -qiE '\bpress [ABXY]\b' \
  && bad "the result screen names a face-button letter" \
  || ok "and it still names no face-button letter"

printf '\ntest-ui.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
