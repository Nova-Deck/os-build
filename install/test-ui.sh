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
  NOVADECK_UI_SOCK="$SOCK" NOVADECK_UI_EVENTS="$events" NOVADECK_UI_INPUT_DEVICES="${DEVFILE-}" \
    "$UI" >"$T/ui.log" 2>&1 &
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

# =================================================================================================
# §4b: the network table -- every row has a different fix
# =================================================================================================
# A generic "network failed" is not acceptable here and this is why: there is NO on-device
# credential entry, so the fix for every row below costs a power-off, a pulled card, an edit on
# another computer and a reboot. A user told only "it failed" pays that price per guess.
NETCFG="$ROOT/install/netcfg"
[ -x "$NETCFG" ] || { echo "no netcfg: $NETCFG" >&2; exit 1; }
# $T/bin is shared with the sections below, and this is the FIRST of them to write into it -- the
# stubs silently did not exist when it was not created here, so the real ip/curl ran and every
# diagnosis came back as whatever this build host's network happens to be.
mkdir -p "$T/net" "$T/bin"

# The stubs. Each case sets NET_* to steer them, and they record nothing the PSK could leak into.
cat >"$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
[ "${NET_LEASE:-0}" = 1 ] && echo "    inet 192.168.1.50/24 scope global wlan0"
exit 0
EOF
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${NET_CURL_CALLS:-/dev/null}"
exit "${NET_HOST_RC:-0}"
EOF
cat >"$T/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"device wifi list"*) [ "${NET_SCAN_HIT:-1}" = 1 ] && printf '%s\n' "${NET_SSID:-home-wifi}"; exit 0 ;;
  *"device wifi connect"*)
     # The PSK must never be echoed, logged or recorded. This stub asserts that by never seeing it.
     [ "${NET_JOIN_RC:-0}" = 0 ] && exit 0
     printf 'Error: Secrets were required, but not provided.\n' >&2; exit 4 ;;
esac
exit 0
EOF
chmod +x "$T/bin"/*

netcfg() {  # <mode> -- prints netcfg's key=value output
  PATH="$T/bin:$PATH" NOVADECK_WIFI_CONF="${CONF-$T/net/wifi.conf}" \
    NOVADECK_OTA_URL="https://ota.example" NOVADECK_NET_TIMEOUT=1 \
    "$NETCFG" "${1:-diagnose}" 2>/dev/null
}
state() { printf '%s\n' "$1" | sed -n 's/^STATE=//p'; }

printf 'SSID=home-wifi\nPSK=hunter2\n' >"$T/net/wifi.conf"

CASE="§4b: netcfg names which failure this is"
NET_LEASE=1 NET_HOST_RC=0; export NET_LEASE NET_HOST_RC
[ "$(state "$(netcfg)")" = online ] \
  && ok "a lease plus a reachable update server is 'online' -- and it never looks at wifi.conf" \
  || bad "a working network was not reported as online"
NET_HOST_RC=7
[ "$(state "$(netcfg)")" = no-host ] \
  && ok "a lease with an unreachable server is 'no-host', not a Wi-Fi problem" \
  || bad "an unreachable server was misdiagnosed"
printf '%s' "$(NET_HOST_RC=7 netcfg)" | grep -qi 'nothing accepted a connection' \
  && ok "and it says WHICH failure -- curl's exit code, mapped to something a person can act on" \
  || bad "no-host does not distinguish DNS from a refused connection"
printf '%s' "$(NET_HOST_RC=6 netcfg)" | grep -qi 'could not be resolved' \
  && ok "a name that does not resolve says so, because that is a different fix" \
  || bad "a DNS failure reads the same as a dead host"
# THE REGRESSION THIS FILE EXISTS TO HOLD. `curl -f` turns a 404 into a failure, and the OTA root
# legitimately 404s -- it serves <channel>/latest.json, not an index. netcfg shipped with -f and
# called a reachable server unreachable on a Pocket S2, on the very network the probe ran over.
NET_CURL_CALLS="$T/net/curl-calls"; export NET_CURL_CALLS; : >"$NET_CURL_CALLS"
NET_HOST_RC=0 netcfg >/dev/null
grep -qE '(^| )-[a-zA-Z]*f' "$NET_CURL_CALLS" \
  && bad "netcfg passes -f to curl, so any 4xx reads as an unreachable host" \
  || ok "reachability is curl's EXIT code, never its HTTP status -- no -f is passed"
grep -q 'ota.example' "$NET_CURL_CALLS" \
  && ok "and it probes the OTA base URL it was configured with" \
  || bad "it probed something other than the configured URL: $(cat "$NET_CURL_CALLS")"
unset NET_CURL_CALLS
NET_LEASE=0 NET_HOST_RC=0
CONF="$T/net/absent.conf" ; [ "$(state "$(netcfg)")" = no-conf ] \
  && ok "no wifi.conf on the card is its own state, with the path quoted" \
  || bad "a missing wifi.conf was not diagnosed"
unset CONF
printf 'SSID=home-wifi\nthis is not a setting\n' >"$T/net/bad.conf"
out="$(CONF="$T/net/bad.conf" netcfg)"
[ "$(state "$out")" = unparsable ] && printf '%s' "$out" | grep -qx 'LINE=2' \
  && ok "an unparseable file reports the OFFENDING LINE -- 'unparseable' alone is the same dead end" \
  || bad "the bad line was not located: $out"
[ "$(state "$(netcfg join)")" = no-lease ] \
  && ok "associated but no address is the access point's DHCP, not ours" \
  || bad "a missing lease was misdiagnosed"
NET_JOIN_RC=4; export NET_JOIN_RC
[ "$(state "$(netcfg join)")" = auth-failed ] \
  && ok "a rejected key is 'auth-failed' -- the fix is the PSK and nothing else" \
  || bad "a wrong PSK was not diagnosed"
unset NET_JOIN_RC
NET_SCAN_HIT=0; export NET_SCAN_HIT
[ "$(state "$(netcfg join)")" = not-found ] \
  && ok "an SSID missing from the scan is a typo or an AP out of range, not a bad password" \
  || bad "a missing SSID was not diagnosed"
unset NET_SCAN_HIT
[ "$(state "$(netcfg)")" = need-join ] \
  && ok "and before any attempt it asks -- the stale-file case §4b wants caught" \
  || bad "it joined without confirming"
# The one thing that must never appear anywhere in the output.
netcfg join | grep -q 'hunter2' \
  && bad "the PSK was printed" \
  || ok "the PSK appears in no state, on any path"
unset NET_LEASE NET_HOST_RC

CASE="§4b: netcfg and novadeck-update agree on which host 'reachable' means"
# THE URL IS WRITTEN TWICE -- shell here, Python in fs-overlay/usr/bin/novadeck-update -- and this
# assertion is the only thing that keeps them the same URL. It is not hypothetical: netcfg shipped
# for an hour with an invented default (`ota.novadeck.org`), which would have reported every
# healthy network as `no-host`, the exact misdiagnosis §4b's table exists to prevent. Same shape as
# test-update.sh's identity-rules-agree, and for the same reason.
net_default="$(sed -n 's/^OTA_DEFAULT_URL=//p' "$NETCFG" | head -1)"
upd_default="$(sed -n 's/^DEFAULT_URL = "\(.*\)"$/\1/p' "$ROOT/fs-overlay/usr/bin/novadeck-update" | head -1)"
[ -n "$net_default" ] && [ "$net_default" = "$upd_default" ] \
  && ok "both default to $net_default" \
  || bad "netcfg says '$net_default', novadeck-update says '$upd_default'"
# And the config file the running system actually carries wins over both.
printf 'OTA_URL=https://from-the-conf.example\n' >"$T/net/ota.conf"
NET_LEASE=1 NET_HOST_RC=0 NOVADECK_OTA_CONFIG="$T/net/ota.conf" PATH="$T/bin:$PATH" \
  NOVADECK_WIFI_CONF="$T/net/wifi.conf" "$NETCFG" diagnose 2>/dev/null \
  | grep -q 'from-the-conf.example' \
  && ok "and /etc/novadeck/ota.conf overrides the built-in, as it does for the OTA client" \
  || bad "the config file was ignored"

CASE="§5: the button that says Power off powers off"
# A screen that says "Power off" and merely exits is worse than one that says nothing: the UI dies,
# gamescope dies with it, and the device sits at a black panel having promised otherwise. That is
# what it did until 2026-08-22.
powercheck() {  # <state-or-rc> -- prints the result tuple the screen produces for SELECT / S
  WHICH="$1" python3 -c '
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uiflow
w = os.environ["WHICH"]
if w.startswith("net:"):
    s = uiflow.NetworkScreen({"STATE": w[4:], "SSID": "x"}); s.handle("BACK")
else:
    class R: tail = []
    s = uiflow.ProgressScreen(R()); s.finish(int(w)); s.handle("S")
print(json.dumps(s.result))'
}
[ "$(powercheck 0)" = '["poweroff"]' ] \
  && ok "a finished install powers the device off, as its button says" \
  || bad "the success screen's Power off button does not power off: $(powercheck 0)"
[ "$(powercheck 1)" = '["quit"]' ] \
  && ok "a FAILED one does not -- its button says Continue, and the user still has a log to read" \
  || bad "a failed install powered the device off"
[ "$(powercheck net:no-conf)" = '["poweroff"]' ] \
  && ok "and a network failure's SELECT, labelled Power off, does too" \
  || bad "the network failure screen's Power off button does not power off"
[ "$(powercheck net:need-join)" = '["quit"]' ] \
  && ok "while the join prompt's SELECT is Cancel, and only cancels" \
  || bad "cancelling a join offer powered the device off"
# The guard that keeps this suite from halting the machine it runs on.
grep -q 'isinstance(source, ScriptedInput)' "$UI" \
  && ok "a scripted run refuses to power off, rather than trusting every case to set the seam" \
  || bad "nothing stops a scripted run from halting the build host"
# NOT asserted here: the guard firing end to end. Reaching it through the loop needs a completed
# install, i.e. the spine, and a case that passes whether or not the path was reached asserts
# nothing at all -- which is the failure mode this suite exists to avoid. The guard is read out of
# the source above; the four result tuples are the behaviour.

CASE="§4b: the screen turns each state into a different fix"
netscreen() {  # <key=value...>
  FACTS="$1" python3 -c '
import importlib.util, json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uiflow
s = uiflow.NetworkScreen(uiflow.kv(os.environ["FACTS"].replace(";", "\n")))
print(json.dumps(s.describe()))'
}
n="$(netscreen 'STATE=no-conf;PATH_=/esp/novadeck/wifi.conf')"
printf '%s' "$n" | grep -q 'wifi.conf.example' \
  && ok "no-conf points at the example file that is on the card for exactly this" \
  || bad "no-conf does not say how to create the file"
printf '%s' "$n" | grep -qi 'Ethernet' \
  && ok "and names the adapter path that needs no file at all" \
  || bad "no-conf hides the zero-config alternative"
n="$(netscreen 'STATE=unparsable;PATH_=/esp/novadeck/wifi.conf;LINE=2')"
printf '%s' "$n" | grep -q 'line 2' \
  && ok "unparsable quotes the line number the user has to go and look at" \
  || bad "the line number is not on the screen"
n="$(netscreen 'STATE=auth-failed;SSID=home-wifi')"
printf '%s' "$n" | grep -q "home-wifi" \
  && ok "auth-failed quotes the SSID back" \
  || bad "the SSID is not quoted back"
printf '%s' "$n" | grep -qi 'PSK' \
  && ok "and names the one field to change" \
  || bad "it does not say what to fix"
n="$(netscreen 'STATE=no-lease;SSID=home-wifi')"
printf '%s' "$n" | grep -qi 'not the installer\|access point' \
  && ok "no-lease says the problem is the access point, so the user stops debugging us" \
  || bad "no-lease blames nobody"
n="$(netscreen 'STATE=need-join;SSID=home-wifi')"
printf '%s' "$n" | grep -q 'Join' \
  && ok "need-join offers a plain button press -- nothing destructive happens here" \
  || bad "the join confirmation has no join button"
printf '%s' "$n" | grep -qi 'never shown' \
  && ok "and says the password is never displayed" \
  || bad "it does not reassure about the PSK"
printf '%s' "$n" | grep -qi 'earlier install' \
  && ok "naming the stale-card case that is the whole reason this screen exists" \
  || bad "the stale-file case is not mentioned"
# Every state must produce a fix, or the table has a hole in it.
for st in no-conf unparsable not-found auth-failed no-lease no-host netcfg-failed; do
  if [ "$(netscreen "STATE=$st;SSID=x;LINE=1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["blocks"]))')" = 2 ]; then
    :
  else
    bad "$st does not render both what happened and what to do"
  fi
done
ok "every state in the table renders both what happened and what to do"

# =================================================================================================
# §4d: no controller and no keyboard -> stop
# =================================================================================================
# Both fixtures are shaped like the real file, and both traps in them were measured on a device:
# InputPlumber ALWAYS publishes a virtual keyboard that DECLARES the whole alphabet while carrying
# only a couple of quick-access buttons (KeyHome/KeyF1 -- no letters), and pmic_pwrkey/gpio-keys
# carry `Handlers=kbd` while being unable to type a letter.
cat >"$T/devices-none" <<'EOF'
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="pmic_pwrkey"
S: Sysfs=/devices/platform/soc@0/c400000.spmi/spmi-0/0-00/input/input0
H: Handlers=kbd event0
B: EV=3
B: KEY=10000000000000 0

I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="gpio-keys"
S: Sysfs=/devices/platform/gpio-keys/input/input4
H: Handlers=kbd event3
B: EV=3
B: KEY=8000000000000 0

I: Bus=0003 Vendor=1234 Product=5678 Version=0111
N: Name="InputPlumber Keyboard"
S: Sysfs=/devices/virtual/input/input10
H: Handlers=sysrq kbd event8
B: EV=3
B: KEY=300000c07 ff9f207ac07057ff fabeffdfffefffff fffffffffffffffe
EOF
{ cat "$T/devices-none"; cat <<'EOF'

I: Bus=0003 Vendor=413c Product=2113 Version=0111
N: Name="Dell KB216 Wired Keyboard"
S: Sysfs=/devices/platform/soc@0/1c08000.pcie/usb1/1-3/1-3:1.0/input/input14
H: Handlers=sysrq kbd event12
B: EV=120013
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe
EOF
} >"$T/devices-kbd"

keycheck() {  # <devices-file> -> prints True/False
  NOVADECK_UI_INPUT_DEVICES="$1" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uipad
print(uipad.typing_keyboard_present())'
}

CASE="§4d: what counts as something to answer with"
[ "$(keycheck "$T/devices-kbd")" = True ] \
  && ok "a USB keyboard counts" \
  || bad "a real keyboard was not detected"
[ "$(keycheck "$T/devices-none")" = False ] \
  && ok "and a machine with only power/volume keys and InputPlumber's virtual keyboard does not" \
  || bad "something that cannot type a letter was counted as a keyboard"
# The two exclusions, named individually so a regression says which one broke.
grep -q 'devices/virtual' install/uipad.py \
  && ok "the virtual keyboard is excluded by sysfs path -- it declares letters it never carries" \
  || bad "nothing excludes InputPlumber's own keyboard"
[ "$(keycheck "$T/nonexistent-devices-file")" = True ] \
  && ok "an unreadable device list reports PRESENT -- the gate is the safety property, not this" \
  || bad "a missing /proc file made the installer refuse to run"

CASE="§4d: with nothing to answer with, consent is refused rather than drawn"
# The screen alone would leave the spine blocked on an answer that can never come.
printf 'SHOWN\n' >"$T/ev-noinput"
DEVFILE="$T/devices-none" ui_ask "$T/ev-noinput" "$T/facts-wipe" SWNE \
  && bad "consent was granted on a machine with no input device" \
  || ok "the shim exits non-zero, which the spine reads as an abort"
[ -z "$OUT" ] \
  && ok "and nothing reaches stdout, so nothing can be mistaken for an answer" \
  || bad "it put something on stdout: $(printf '%q' "$OUT")"
grep -q 'no input device to take consent on' "$T/ui.log" \
  && ok "the journal says which of the two failures this is" \
  || bad "the refusal is not explained: $(cat "$T/ui.log")"
# And it must be the refusal, not a crash: a machine that gets a keyboard back must recover.
DEVFILE="$T/devices-kbd" ui_ask "$T/ev-noinput" "$T/facts-wipe" SWNE \
  && ok "the same run with a keyboard attached takes consent normally" \
  || bad "a machine WITH a keyboard was also refused: $ERR"
[ "$OUT" = SWNE ] \
  && ok "so the stop is about the input device and nothing else" \
  || bad "the answer was wrong with a keyboard present: $OUT"

CASE="§4d: the screen says what is wrong and what to do"
noinput="$(python3 -c '
import importlib.util, json, os, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvui", os.path.join(os.environ["ROOT"], "install/ui"))
spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(json.dumps(ui.NoInputScreen().describe()))')"
printf '%s' "$noinput" | grep -qi 'controller or .*keyboard' \
  && ok "it names both things it looked for" \
  || bad "the screen does not say what is missing"
printf '%s' "$noinput" | grep -qi 'USB keyboard' \
  && ok "and tells the user the one thing that fixes it" \
  || bad "the screen offers no way out"
printf '%s' "$noinput" | grep -qi 'Nothing has been written' \
  && ok "while saying the device is untouched, which is the question a stuck installer raises" \
  || bad "it does not say whether anything was written"

CASE="§6: the pygame wheel is pinned to the Python the image actually ships"
# A WHEEL IS ABI-LOCKED. install/pygame-ce.pin carries a cp313 build because images/manifest.lock
# ships python 3.13; a python bump in the lock makes that wheel unimportable, and the symptom would
# be an installer that comes up to a black panel with an ImportError in a child's stderr -- which
# is exactly how the pygame.controller bug presented. Two files, one fact, so assert they agree.
PIN="$ROOT/install/pygame-ce.pin"
[ -f "$PIN" ] || bad "no pygame pin at $PIN"
pin_py="$(sed -n 's/^python:[[:space:]]*//p' "$PIN" | head -1)"
lock_py="$(awk '$1 == "python" {print $2}' "$ROOT/images/manifest.lock" | head -1)"
want="cp$(printf '%s' "$lock_py" | cut -d. -f1)$(printf '%s' "$lock_py" | cut -d. -f2)"
[ -n "$pin_py" ] && [ "$pin_py" = "$want" ] \
  && ok "the wheel is $pin_py and the lock ships python $lock_py" \
  || bad "the wheel is '$pin_py' but the lock ships python '$lock_py' (wants $want)"
# The extraction target has to name that same python, or the wheel lands where nothing imports it.
grep -q "^dest:.*python3\.$(printf '%s' "$lock_py" | cut -d. -f2)/" "$PIN" \
  && ok "and it is extracted into that interpreter's site-packages" \
  || bad "the pin's dest does not name python3.$(printf '%s' "$lock_py" | cut -d. -f2): $(grep '^dest:' "$PIN")"
# It is deliberately NOT under packages/, which images/customize-base.sh auto-discovers into the
# RELEASE base -- 39 MB of SDL bindings on every shipped device, for a program that does not ship.
[ -f "$ROOT/packages/pygame-ce/prebuilt.pin" ] \
  && bad "the pygame pin is under packages/, so customize-base will put it in the release image" \
  || ok "and it is not under packages/, where it would land in every shipped image"

CASE="ui: the game-controller API is the one pygame actually has"
# `pygame.controller` does not exist as a top-level module in either pygame or pygame-ce -- it is
# pygame._sdl2.controller. Written from the docs rather than the library, that line took the whole
# UI down with an AttributeError the first time it ran against a real pygame (Pocket S2,
# 2026-08-22), AFTER gamescope had come up, so the symptom was a black panel. Nothing offline could
# catch it: the suite never imports pygame, by design.
grep -q 'from pygame._sdl2 import controller' "$ROOT/install/uipad.py" \
  && ok "the controller module is imported from pygame._sdl2, where it lives" \
  || bad "uipad.py does not import the controller API from pygame._sdl2"
# Comments stripped first -- the file EXPLAINS the trap at length, and an assertion that could not
# tell the warning from the thing warned about would fail on its own documentation.
if sed 's/#.*$//' "$ROOT/install/uipad.py" | grep -qE '(^|[^_.])pygame\.controller'; then
  bad "something still reaches for the top-level pygame.controller, which does not exist"
else
  ok "and nothing reaches for the top-level name that does not exist"
fi

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
# EMITTED THE WAY THE REAL ONE EMITS IT: device-env uses `printf '%s=%q\n'`, and bash's %q escapes
# rather than quotes when it can, so a board name arrives as `AYANEO\ Pocket\ ACE`. The stub used to
# emit the single-quoted form -- the other thing %q produces -- and a parser that only stripped
# quotes passed here while putting a backslash on the panel of a real Pocket S2.
cat >"$T/bin/device-env" <<'EOF'
#!/usr/bin/env bash
printf '%s=%q\n' NOVADECK_DEVICE_NAME 'AYANEO Pocket ACE'
printf '%s=%q\n' NOVADECK_SOC_CLASS SM8550
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
facts, _why = uiflow.gather_preflight()
pf = uiflow.PreflightScreen(facts) if facts else None
exec(os.environ["SNIPPET"])
PY
}

CASE="pre-flight: every figure comes from the tool that will act on it"
out="$(flow 'print(json.dumps(pf.describe()))')"
printf '%s' "$out" | grep -q 'AYANEO Pocket ACE' \
  && ok "the board names itself, from device-env rather than from a guess" \
  || bad "the device name is missing: $out"
printf '%s' "$out" | grep -q 'AYANEO\\\\ Pocket' \
  && bad "the shell escaping reached the screen -- this is the Pocket S2 backslash" \
  || ok "and the shell escaping device-env applies is undone, not printed"
# THE OTHER PRODUCER. netcfg emits plain prose with spaces, and the parser that unescapes
# device-env's %q must not truncate it -- taking the first shlex token rendered a real device's
# "the installer can reach https://..." as the single word "the".
kvcheck="$(python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "install"))
import uiflow
d = uiflow.kv("DETAIL=the installer can reach https://x\nNAME=AYANEO\\ Pocket\\ S2\n")
print("%s|%s" % (d["DETAIL"], d["NAME"]))')"
[ "$kvcheck" = "the installer can reach https://x|AYANEO Pocket S2" ] \
  && ok "and a value with spaces survives whole, from either producer" \
  || bad "kv() mangled a value: $kvcheck"
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

# =================================================================================================
# the session — gamescope on the panel, with the UI as its only client
# =================================================================================================
SESSION="$ROOT/install/installer-session"
SAVELOG="$ROOT/install/save-log.sh"
[ -x "$SESSION" ] && [ -x "$SAVELOG" ] || { echo "session scripts missing" >&2; exit 1; }

cat >"$T/bin/device-env-panel" <<'EOF'
#!/usr/bin/env bash
printf "NOVADECK_DEVICE_NAME='AYANEO Pocket ACE'\n"
printf 'NOVADECK_PRIMARY_CONNECTOR=DSI-1\n'
printf 'NOVADECK_PANEL_NATIVE_WIDTH=1080\n'
printf 'NOVADECK_PANEL_NATIVE_HEIGHT=1620\n'
printf 'NOVADECK_PANEL_REFRESH_RATES=60,120\n'
EOF
printf '#!/bin/sh\nexit 1\n' >"$T/bin/no-seatd"        # "no seatd is running"
chmod +x "$T/bin"/*

session() {  # env overrides passed through
  NOVADECK_INSTALLER_DRYRUN=1 NOVADECK_XDG_RUNTIME_DIR="$T/xdg" NOVADECK_UI="$UI" NOVADECK_SEATD_PGREP="$T/bin/no-seatd" \
    NOVADECK_DEVICE_ENV="${DEVENV-$T/bin/device-env-panel}" \
    NOVADECK_SEATD_SOCK="${SOCKARG-$T/seatd.sock}" "$SESSION" 2>"$T/session.err"
}

CASE="session: the command line is the one bring-up validated on hardware"
cmd="$(session)"
printf '%s' "$cmd" | grep -q 'seatd-launch -- ' \
  && ok "gamescope runs under seatd-launch -- root, no logind session, which is the installer's case" \
  || bad "the seat launcher is missing: $cmd"
printf '%s' "$cmd" | grep -q -- '--backend drm' \
  && ok "the DRM backend, not a nested one" \
  || bad "no --backend drm: $cmd"
printf '%s' "$cmd" | grep -q -- '-W 1620 -H 1080' \
  && ok "the portrait panel is swapped to a landscape logical canvas (1080x1620 -> 1620x1080)" \
  || bad "the logical output was not swapped: $cmd"
printf '%s' "$cmd" | grep -q -- '-r 60' \
  && ok "and the refresh is the panel's first declared rate, not the whole list" \
  || bad "the refresh rate is wrong: $cmd"
printf '%s' "$cmd" | grep -q -- '--prefer-output DSI-1' \
  && ok "pinned to the board's own connector" \
  || bad "the connector is not pinned: $cmd"
printf '%s' "$cmd" | grep -q -- "-- $UI" \
  && ok "and the UI is gamescope's own child, so either half dying is one failure the unit sees" \
  || bad "the UI is not gamescope's child: $cmd"
# The ROCKNIX-era flag. Our gamescope carries upstream PR #2228 composite rotation and auto-engages
# it off the connector's panel orientation, so passing it would be passing a flag that no longer
# exists -- and the plan still mentions it, which is exactly how that would happen.
printf '%s' "$cmd" | grep -q -- '--use-rotation-shader' \
  && bad "it passes --use-rotation-shader, which our patched gamescope no longer has" \
  || ok "no --use-rotation-shader -- rotation is auto-engaged from the connector"

CASE="session: an unknown board still gets a screen"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/device-env-empty"; chmod +x "$T/bin/device-env-empty"
cmd="$(DEVENV="$T/bin/device-env-empty" session)"
printf '%s' "$cmd" | grep -q -- '-W 1920 -H 1080' \
  && ok "a board device-env does not know falls back to generic landscape" \
  || bad "an unknown board produced: $cmd"
printf '%s' "$cmd" | grep -q -- '--prefer-output' \
  && bad "it pinned a connector it was never told about" \
  || ok "and pins no connector, rather than inventing one"

CASE="session: it clears the socket seatd-launch leaks"
# docs/bringup-phase2.md: seatd-launch leaks /run/seatd.sock on an unclean exit and the next start
# dies "Socket file found ... refusing to start". An installer is a tool people re-run after a
# crash, so this would bite on exactly the second attempt.
: >"$T/seatd.sock"
session >/dev/null
[ ! -e "$T/seatd.sock" ] \
  && ok "a stale socket left by an earlier run is removed" \
  || bad "the stale socket survived; the next start would refuse"
grep -qi 'stale' "$T/session.err" \
  && ok "and it says so, rather than deleting a socket silently" \
  || bad "the removal is not logged"
# But only when nothing is listening: removing a LIVE seatd's socket breaks a running session.
: >"$T/seatd.sock"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/yes-seatd"; chmod +x "$T/bin/yes-seatd"
NOVADECK_INSTALLER_DRYRUN=1 NOVADECK_XDG_RUNTIME_DIR="$T/xdg" NOVADECK_UI="$UI" NOVADECK_SEATD_PGREP="$T/bin/yes-seatd" \
  NOVADECK_DEVICE_ENV="$T/bin/device-env-panel" NOVADECK_SEATD_SOCK="$T/seatd.sock" \
  "$SESSION" >/dev/null 2>&1
[ -e "$T/seatd.sock" ] \
  && ok "a socket with a live seatd behind it is left alone" \
  || bad "it removed a live seatd's socket"

CASE="the clock is its own network row, and it clears itself"
# HW 2026-08-24: these boards have no clock battery (the PMIC RTC probe defers forever, issue #38),
# so a cold boot starts at the epoch and OpenSSL rejects every certificate as not-yet-valid. That
# surfaced as "Connected, but the update server is unreachable" -- a row whose advice is to go and
# check your router, for a fault in neither the router nor the server. Then, with the message fixed,
# the operator still "had to retry a couple of times", pressing Check again at a condition that was
# already fixing itself.
clockrow="$(cd "$ROOT/install" && python3 -c '
import uiflow
t = uiflow.NetworkScreen.TABLE["no-clock"]
print(t[0]); print(t[1]); print(t[2])' 2>&1)"
printf '%s' "$clockrow" | grep -qiE 'waiting for the time|clock' \
  && ok "no-clock has its own row, not the unreachable one" \
  || bad "no dedicated clock row: $clockrow"
printf '%s' "$clockrow" | grep -qi 'no clock battery' \
  && ok "it explains WHY the device does not know the date" \
  || bad "it does not say why the clock is wrong"
printf '%s' "$clockrow" | grep -qiE 'nothing to fix|sets itself' \
  && ok "the advice is to change nothing (it is the only self-clearing row)" \
  || bad "it sends the operator to fix something that fixes itself"
# The no-host row must NOT be what a wrong clock lands on.
hostrow="$(cd "$ROOT/install" && python3 -c '
import uiflow
print(uiflow.NetworkScreen.TABLE["no-host"][2])' 2>&1)"
printf '%s' "$hostrow" | grep -qi 'upstream or DNS' \
  && ok "no-host still means what it meant (upstream or DNS)" \
  || bad "the no-host row drifted: $hostrow"
# netcfg has to EMIT the state, or the row is unreachable prose.
grep -q 'emit STATE no-clock' "$ROOT/install/netcfg" \
  && ok "netcfg emits STATE=no-clock" \
  || bad "nothing ever produces the state the row renders"
grep -qE 'CURL_RC" = 60|CURL_RC" = 35' "$ROOT/install/netcfg" \
  && ok "keyed on curl's TLS exit codes, not its HTTP status" \
  || bad "the clock state is not keyed on the exit code"
# The UI must re-probe it without a human, and ONLY it.
# NO ALLOWLIST. This was a tuple of "self-clearing" states, and hardware refuted the idea within the
# hour: the operator sat on "Connected, but the update server is unreachable" while the device had
# long since gone online, because `no-host` had been excluded BY NAME on the reasoning that it names
# something a human must change. At boot it usually means DNS is not up yet — the very shape the
# allowlist existed to catch. Re-probing is always safe (net_diagnose defaults to read-only
# `diagnose`), so the screen re-checks whatever it says and no state can be forgotten by omission.
grep -q 'SELF_CLEARING' "$ROOT/install/ui" \
  && bad "the allowlist is back — a state omitted from it strands the operator on a stale screen" \
  || ok "no allowlist: every network state re-diagnoses itself"
grep -q 'getattr(top, "name", "") == "network"' "$ROOT/install/ui" \
  && ok "the re-check is gated on being ON the network screen, not on which state it shows" \
  || bad "the periodic re-check is gated on something else"
# It must only redraw on a real change, or a stable fault becomes an unreadable flicker.
grep -q 'if fresh.get("STATE") != top.facts.get("STATE")' "$ROOT/install/ui" \
  && ok "and only acts when the state actually changes" \
  || bad "it redraws unconditionally, so a stable diagnosis would flicker"

CASE="every token a screen handles must be one the pad can produce"
# HW-FOUND 2026-08-24 (user): "left/right to change the android userdata size doesn't work".
# PreflightScreen has handled LEFT and RIGHT since it was written -- they are how the operator
# decides how much of the disk Android keeps -- and NOTHING COULD EVER PRODUCE THEM. uipad
# translated the four face buttons and BACK and stopped there, so those branches were unreachable
# code and the only symptom was a number that would not move.
#
# The specific fix is the d-pad mapping. The general check is this case: a screen that handles a
# token no input emits is a control that does not exist, and nothing else would notice.
produced="$(cd "$ROOT/install" && python3 -c '
import uipad
toks = set(uipad.BUTTON_TO_CARDINAL.values()) | set(uipad.KEY_TO_CARDINAL.values())
toks |= set(uipad.BUTTON_TO_NAV.values()) | set(uipad.KEY_TO_NAV.values())
toks |= {uipad.TOKEN_BACK, uipad.TOKEN_QUIT}
print(" ".join(sorted(toks)))' 2>&1)"
printf '%s' "$produced" | grep -q LEFT && printf '%s' "$produced" | grep -q RIGHT \
  && ok "the pad can produce LEFT and RIGHT ($produced)" \
  || bad "LEFT/RIGHT are still unreachable: $produced"
# Both input paths, because §4d names a USB keyboard as the fallback when no pad enumerates.
grep -q 'BUTTON_TO_NAV = {13: TOKEN_LEFT, 14: TOKEN_RIGHT}' "$ROOT/install/uipad.py" \
  && ok "from the d-pad (SDL CONTROLLER_BUTTON_DPAD_LEFT/RIGHT)" \
  || bad "the d-pad is not mapped"
grep -q 'KEY_TO_NAV' "$ROOT/install/uipad.py" \
  && ok "and from the arrow keys" || bad "no keyboard equivalent"
grep -q 'elif ev.button in BUTTON_TO_NAV' "$ROOT/install/uipad.py" \
  && ok "poll() actually consults the map" \
  || bad "the map exists but no event path reads it"
# The invariant itself: every literal token the screens compare against must be producible.
handled="$(grep -ohE 'token == "[A-Z]+"' "$ROOT/install/ui" "$ROOT/install/uiflow.py" \
          | grep -oE '"[A-Z]+"' | tr -d '"' | sort -u)"
unreachable=""
for t in $handled; do
  printf '%s' "$produced" | grep -qw "$t" || unreachable="$unreachable $t"
done
[ -z "$unreachable" ] \
  && ok "every token the screens handle is producible ($(printf '%s' "$handled" | wc -w) checked)" \
  || bad "screens handle tokens no input can emit:$unreachable"

CASE="associating: no wifi.conf is not the same as no configuration"
# User's catch, 2026-08-24. have_lease is false for the WHOLE association window, so anything
# without a lease fell through to `no-conf` -- "No Wi-Fi settings on this card" -- and told the
# operator to write a file on another computer while the radio was mid-handshake. On a TEST medium,
# whose network is a baked NM profile and which carries no wifi.conf at all, that was every cold
# boot rather than a corner case. NOTE the dev build cannot reach the state this protects, so
# `no-conf` itself still wants a release-image run before it is believed.
assoc="$(cd "$ROOT/install" && python3 -c '
import uiflow
t = uiflow.NetworkScreen.TABLE["associating"]
print(t[0]); print(t[1]); print(t[2])' 2>&1)"
printf '%s' "$assoc" | grep -qiE 'joining|associat' \
  && ok "there is a row for a network that is still being joined" \
  || bad "no associating row: $assoc"
printf '%s' "$assoc" | grep -qi 'address' \
  && ok "it says an address is what is being waited for" \
  || bad "it does not name what the wait is for"
printf '%s' "$assoc" | grep -qiE 'nothing to fix|by itself' \
  && ok "the advice is to change nothing" \
  || bad "it asks the operator to act on a state that clears itself"
grep -q 'emit STATE associating' "$ROOT/install/netcfg" \
  && ok "netcfg emits it" || bad "nothing produces the state"
grep -q 'has_wifi_profile' "$ROOT/install/netcfg" \
  && ok "it consults NM's own profiles, not just wifi.conf on the ESP" \
  || bad "a baked profile still reads as 'no Wi-Fi settings'"
grep -q 'wifi_busy' "$ROOT/install/netcfg" \
  && ok "and the radio's actual state" || bad "association is not detected"
# Ordering is the whole bug: the busy check must precede the no-conf branch.
awk '/emit STATE associating/{a=NR} /emit STATE no-conf/{b=NR} END{exit !(a && b && a<b)}' \
  "$ROOT/install/netcfg" \
  && ok "the associating check runs BEFORE the no-conf branch" \
  || bad "no-conf still wins during the association window, which is the defect"

CASE="online is not a screen, it is the reason to leave one"
# User's follow-on: once an address arrives, move on rather than showing a success message with a
# button. Pressing Continue and waiting for the same condition should not be two different things.
grep -q 'if fresh.get("STATE") == "online"' "$ROOT/install/ui" \
  && ok "reaching online advances instead of re-rendering the network screen" \
  || bad "the operator is left looking at a success message with a Continue button"
grep -A10 'if fresh.get("STATE") == "online"' "$ROOT/install/ui" | grep -q 'gather_preflight' \
  && ok "and it takes the same step Continue takes (pre-flight, still read-only)" \
  || bad "the auto-advance does not go where Continue goes"

CASE="no target: the screen says WHY, it does not just wait"
# HW-FOUND 2026-08-24 (user): the medium shipped without lib-gpt.sh, select-target.sh died with
# "cannot find lib-gpt.sh", gather_preflight() read that non-zero exit as the NORMAL no-target
# outcome, and the panel sat on "Waiting for the installer." with no other word. A person holding
# the device could not tell a broken build from a disk the installer refuses to touch. The reason
# was already being logged and then thrown away by returning a bare None.
noreason="$(cd "$ROOT/install" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
d = ui.IdleScreen("select-target: cannot find lib-gpt.sh").describe()
print(d["title"])
for h, b in d["blocks"]:
    print("%s|%s" % (h, b))
print("NOTE|%s" % d["note"])
' 2>&1)"
printf '%s' "$noreason" | grep -qi 'cannot find lib-gpt.sh' \
  && ok "the reason from the tool is on the screen, verbatim" \
  || bad "the reason is not shown: $noreason"
printf '%s' "$noreason" | grep -qiE 'no disk to install onto|nothing .* install' \
  && ok "it states plainly that there is no target" \
  || bad "the screen does not say what the situation is"
printf '%s' "$noreason" | grep -qi 'nothing has been written' \
  && ok "it says nothing has been written (the operator's first question)" \
  || bad "it does not reassure that the disk is untouched"
# The SSH-driven consent-renderer case is legitimate and must still be explained, not dropped.
printf '%s' "$noreason" | grep -qi 'ssh' \
  && ok "it still accounts for the consent-renderer case" \
  || bad "the legitimate 'driven over SSH' case is no longer explained"
# With no reason available the screen must still be useful rather than blank.
blank="$(cd "$ROOT/install" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(len(ui.IdleScreen().describe()["blocks"]))' 2>&1)"
[ "$blank" -ge 2 ] 2>/dev/null \
  && ok "it still renders $blank blocks when no reason was captured" \
  || bad "with no reason the screen degrades to nothing useful: $blank"
# It asks for nothing, so a scripted source must not spend a press on it.
noninter="$(cd "$ROOT/install" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(ui.IdleScreen().interactive)' 2>&1)"
[ "$noninter" = "False" ] && ok "still non-interactive (a screen that asks nothing takes no press)" \
  || bad "IdleScreen became interactive: $noninter"

CASE="session: XDG_RUNTIME_DIR is provided, because nothing else does"
# THE FIRST HARDWARE BOOT OF THE INSTALLER MEDIUM DIED HERE (Pocket S2, 2026-08-24). gamescope came
# all the way up -- seatd, DRM master, Turnip on an Adreno 750, DSI-1 at 1440x2560 -- then logged
# "XDG_RUNTIME_DIR is invalid or not set" 128 times, failed to open its wayland socket, and ABORTED
# with a core dump. libwayland will not create a socket without that variable, and it is LOGIND that
# normally makes /run/user/<uid> and exports it -- this session has no logind session by design.
#
# It passed by hand on the panel in August because that run came from an interactive root SSH login,
# where logind had already done both. Nothing in the command line differed. So this case checks the
# ENVIRONMENT, not the command: a dry run must still leave the directory there, 0700, because that
# is the side effect gamescope depends on.
rm -rf "$T/xdg2"
NOVADECK_INSTALLER_DRYRUN=1 NOVADECK_XDG_RUNTIME_DIR="$T/xdg2" NOVADECK_UI="$UI" \
  NOVADECK_SEATD_PGREP="$T/bin/yes-seatd" NOVADECK_DEVICE_ENV="$T/bin/device-env-panel" \
  NOVADECK_SEATD_SOCK="$T/seatd.sock" "$SESSION" >/dev/null 2>&1
[ -d "$T/xdg2" ] \
  && ok "the runtime directory is created" \
  || bad "no XDG_RUNTIME_DIR is created -- gamescope aborts on its wayland socket"
[ "$(stat -c%a "$T/xdg2" 2>/dev/null)" = 700 ] \
  && ok "it is 0700 (the wayland socket lives in it)" \
  || bad "the runtime directory is $(stat -c%a "$T/xdg2" 2>/dev/null), not 0700"
grep -q 'export XDG_RUNTIME_DIR=' "$SESSION" \
  && ok "and it is EXPORTED, so gamescope and the UI both inherit it" \
  || bad "the variable is set but never exported"
# /run/user/0 is logind's namespace; fabricating it would collide the day anything here starts a
# real session.
# Non-comment lines only: the script EXPLAINS at length why it avoids /run/user/0, and a plain grep
# matched that prose and failed on correct code the first time this case ran.
grep -vE '^[[:space:]]*#' "$SESSION" | grep -q '/run/user/0' \
  && bad "it fabricates /run/user/0, which belongs to logind" \
  || ok "it does not squat on logind's /run/user/0"

CASE="session: a seatd that is already running is used, not duplicated"
# seatd-launch starts its OWN seatd and refuses when the socket exists, and the shipped image
# enables seatd.service (Pocket S2, 2026-08-22: pid 710, /run/seatd.sock root:seat 0770). An
# installer-session that always reached for seatd-launch would die before gamescope started.
: >"$T/seatd.sock"
cmd="$(NOVADECK_INSTALLER_DRYRUN=1 NOVADECK_XDG_RUNTIME_DIR="$T/xdg" NOVADECK_UI="$UI" NOVADECK_SEATD_PGREP="$T/bin/yes-seatd" \
  NOVADECK_DEVICE_ENV="$T/bin/device-env-panel" NOVADECK_SEATD_SOCK="$T/seatd.sock" \
  "$SESSION" 2>"$T/session.err")"
grep -qi 'using the seatd already running' "$T/session.err" \
  && ok "it takes the seat from the running daemon instead of launching a second" \
  || bad "it did not notice a live seatd: $(cat "$T/session.err")"
rm -f "$T/seatd.sock"
cmd="$(session)"
printf '%s' "$cmd" | grep -q 'seatd-launch -- ' \
  && ok "and with no seat daemon there, it launches one -- the bring-up path" \
  || bad "it stopped using seatd-launch when nothing was running: $cmd"

CASE="session: it refuses rather than drawing nothing"
NOVADECK_INSTALLER_DRYRUN=1 NOVADECK_UI="$T/not-here" NOVADECK_DEVICE_ENV="$T/bin/device-env-panel" \
  "$SESSION" >/dev/null 2>&1 \
  && bad "it started a session with no UI to run" \
  || ok "a missing UI is a loud failure at second zero, not a black panel"

# =================================================================================================
# the fallback — the log has to be able to leave the machine
# =================================================================================================
cat >"$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'Aug 22 12:00:00 deck installer-session[1]: gamescope: could not open /dev/dri/card0\n'
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/mountpoint"      # "yes, it is mounted"
chmod +x "$T/bin"/*
mkdir -p "$T/esp" "$T/run/install"
printf 'consent: given at 2026-08-22T10:00:00Z, sequence SWNE, attempt 1\n' >"$T/run/install/record"

savelog() {
  PATH="$T/bin:$PATH" NOVADECK_INSTALL_RUNDIR="$T/run" NOVADECK_INSTALL_LOG="$T/run/install.log" \
    NOVADECK_INSTALLER_ESP="${ESPARG-$T/esp}" NOVADECK_INSTALL_RECORD="$T/run/install/record" \
    NOVADECK_INSTALL_CONSOLE="$T/console" JOURNALCTL="${JC-$T/bin/journalctl}" \
    "$SAVELOG" "$@" 2>"$T/savelog.err"
}

CASE="fallback: the log is written and copied where a PC can read it"
savelog && ok "it exits 0" || bad "save-log.sh failed"
grep -q 'could not open /dev/dri/card0' "$T/run/install.log" \
  && ok "the session's journal is in it -- the failure that produced a black panel" \
  || bad "the journal is not in the log"
grep -q 'consent: given' "$T/run/install.log" \
  && ok "and the spine's own install record, which the journal does not carry" \
  || bad "the install record is missing from the log"
cmp -s "$T/run/install.log" "$T/esp/novadeck-install.log" \
  && ok "copied to the installer medium's ESP -- pull the card, read it on a PC" \
  || bad "the log did not reach the ESP"

CASE="fallback: a log that cannot be saved never fails the unit"
# Every branch of this exits 0 on purpose: a missing journalctl, an unmounted ESP or a read-only
# medium must not turn a successful install into a failed one, nor mask a real failure.
JC="$T/bin/nonexistent-journalctl" savelog \
  && ok "no journalctl on the image is a line in the log, not an error" \
  || bad "a missing journalctl failed the unit"
grep -q 'no journalctl' "$T/run/install.log" \
  && ok "and it says which part is missing" \
  || bad "the log does not record why it is empty"
printf '#!/bin/sh\nexit 1\n' >"$T/bin/mountpoint"      # "not a mount point"
rm -f "$T/esp/novadeck-install.log"
savelog && ok "an ESP that is not mounted is not an error either" || bad "an unmounted ESP failed"
[ ! -e "$T/esp/novadeck-install.log" ] \
  && ok "and nothing is copied into a directory that is merely SHAPED like the mount" \
  || bad "it copied into an unmounted /esp, where nobody will ever find it"
grep -qi 'not a mount point' "$T/savelog.err" \
  && ok "saying so, so the operator knows to look at /run instead" \
  || bad "it did not say where the log actually is"

CASE="fallback: the panel shows what happened"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/mountpoint"
# The console stands in for /dev/tty1, which exists on the device. save-log.sh writes to it only if
# it is there and writable -- a machine with no VT at all is a skip, not a failure.
: >"$T/console"
savelog --console
grep -q 'could not open /dev/dri/card0' "$T/console" \
  && ok "the tail of the log reaches the console the OnFailure unit hands to a getty" \
  || bad "nothing was printed to the console"
grep -qi 'installer medium' "$T/console" \
  && ok "and it names where the full copy is, which is the only artefact that leaves the device" \
  || bad "the console does not say where the full log is"

CASE="units: the fallback is actually armed"
UNITDIR="$ROOT/install/units"
grep -q '^OnFailure=novadeck-installer-console.service' "$UNITDIR/novadeck-installer.service" \
  && ok "the session names the console unit on failure" \
  || bad "nothing starts the fallback console"
grep -q '^ConditionKernelCommandLine=!novadeck.install.debug' "$UNITDIR/novadeck-installer.service" \
  && ok "novadeck.install.debug skips the GUI entirely, as a condition" \
  || bad "the debug cmdline escape is missing"
# An OnFailure= activation still evaluates conditions, so a condition on the console unit would
# disarm the fallback on exactly the boots it exists for.
grep -q '^ConditionKernelCommandLine' "$UNITDIR/novadeck-installer-console.service" \
  && bad "the console unit carries a condition, which would disarm it on a normal boot" \
  || ok "and the console unit carries no condition of its own"
grep -qE '^(TTYPath|StandardInput=tty)' "$UNITDIR/novadeck-installer.service" \
  && bad "the session unit binds a TTY -- that made gamescope exit 0 at boot on the main image" \
  || ok "the session unit binds no TTY, which is what bring-up paid to learn"
grep -q '^ExecStopPost=-/usr/lib/novadeck/install/save-log.sh' "$UNITDIR/novadeck-installer.service" \
  && ok "and every stop, successful or not, tries to save the log" \
  || bad "the log is not collected on stop"

printf '\ntest-ui.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
