#!/usr/bin/env bash
# Offline check for the Sunshine game-stream host service.
#
#   tests/test-sunshine.sh
#
# WHY THIS EXISTS. Sunshine listens on the LAN, injects input and holds a capability, and hosting is
# the user's choice: the Decky plugin starts it and stops it. Two ways to break that are silent. A
# preset, an [Install] section or a .wants link added later would start it on every boot, and it
# would look like a feature. And `sunshine --creds` exits 0 even when it could not write the file,
# in which case Sunshine serves a page where anyone who can reach it picks the password.
#
# So this asserts that nothing enables the unit, and drives the REAL credentials helper against a
# stub sunshine, including one that fails the way the real one does.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVL="$ROOT/rootfs/overlay"
UNIT="$OVL/usr/lib/systemd/system/novadeck-sunshine.service"
CONF="$OVL/etc/novadeck/sunshine.conf"
APPS="$OVL/usr/share/novadeck/sunshine-apps.json"
CREDS="$OVL/usr/lib/novadeck/sunshine-creds"

PASS=0; FAIL=0
ok()    { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }
unitkey() { sed -n "s/^$1=//p" "$UNIT"; }
confkey() { sed -nE "s/^$1 *= *//p" "$CONF"; }

for f in "$UNIT" "$CONF" "$APPS" "$CREDS"; do
    [[ -f $f ]] || { echo "missing: $f" >&2; exit 1; }
done
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "1. never started at boot"
check "the unit has no [Install] section" "$(grep -c '^\[Install\]' "$UNIT")" 0
# Preset patterns are globs, so match them the way systemd does rather than grepping for the name.
enabling=""
while read -r verb pattern _; do
    [[ $verb == enable ]] || continue
    for u in novadeck-sunshine.service app-dev.lizardbyte.app.Sunshine.service sunshine.service; do
        # shellcheck disable=SC2053  # the pattern is meant to glob
        [[ $u == $pattern ]] && enabling+="$pattern "
    done
done < <(cat "$OVL"/usr/lib/systemd/*-preset/*.preset)
check "no preset pattern enables a sunshine unit" "$enabling" ""
check "no .wants/.requires link or alias points at a sunshine unit" \
    "$(find "$OVL" -type l \( -iname '*sunshine*' -o -lname '*[Ss]unshine*' \) | wc -l)" 0
check "no other overlay unit pulls it in" \
    "$(grep -rlE '^(Wants|Requires|BindsTo|Upholds|OnSuccess|OnFailure|Also)=.*sunshine' "$OVL"/usr/lib/systemd "$OVL"/etc/systemd | wc -l)" 0

echo "2. privileges"
check "runs as deck" "$(unitkey User)" deck
check "ambient capability is CAP_SYS_ADMIN alone" "$(unitkey AmbientCapabilities)" CAP_SYS_ADMIN
check "bounding set is CAP_SYS_ADMIN alone" "$(unitkey CapabilityBoundingSet)" CAP_SYS_ADMIN
check "no new privileges" "$(unitkey NoNewPrivileges)" yes
# No file capability on the binary either: rootfs/guard-rootfs.sh checks the built tree for that.
check "the VA driver is named" "$(grep -c '^Environment=.*LIBVA_DRIVER_NAME=qcom' "$UNIT")" 1
check "pulse is reachable" "$(grep -c '^Environment=.*XDG_RUNTIME_DIR=/run/user/1000' "$UNIT")" 1
check "state files are private" "$(unitkey UMask)" 0077
check "runtime directory is private" "$(unitkey RuntimeDirectoryMode)" 0700
check "a crash keeps its log across the restart" "$(unitkey RuntimeDirectoryPreserve)" restart

echo "3. what it exposes"
check "web UI answers the device only" "$(confkey origin_web_ui_allowed)" pc
check "a guest cannot type on the host" "$(confkey keyboard)" disabled
check "a guest cannot move the host's pointer" "$(confkey mouse)" disabled
# The controller is the point of hosting a co-op game, so it stays at Sunshine's default, on.
check "a guest's controller is left on" "$(confkey controller)" ""
check "a client cannot mute the host" "$(confkey keep_host_audio)" enabled
# The option is ours: without the patch Sunshine only logs an unknown key, and the host goes silent.
check "the patch that reads that option is in the package" \
    "$(grep -lE '^\+.*"keep_host_audio"' "$ROOT"/packages/sunshine/patches/*.patch | wc -l)" 1
check "the pin applies that patch" \
    "$(grep -c "^patches:.*$(basename "$(grep -lE '^\+.*"keep_host_audio"' "$ROOT"/packages/sunshine/patches/*.patch)")" "$ROOT/packages/sunshine/source.pin")" 1
check "log level leaves request headers out" "$(confkey min_log_level)" info
check "credentials live in the runtime directory" \
    "$(confkey credentials_file)" "/run/$(unitkey RuntimeDirectory)/credentials.json"
check "pairings stay in the default state file, on /home" "$(confkey file_state)" ""
check "the app list is ours" "$(confkey file_apps)" /usr/share/novadeck/sunshine-apps.json
check "the app list offers the whole session and runs no command" \
    "$(python3 -c 'import json,sys; print([sorted(a) for a in json.load(open(sys.argv[1]))["apps"]], [a["name"] for a in json.load(open(sys.argv[1]))["apps"]])' "$APPS")" \
    "[['image-path', 'name']] ['Desktop']"

echo "4. the unit, the config and the helper agree"
check "the unit starts Sunshine on our config" "$(unitkey ExecStart)" "/usr/bin/sunshine /etc/novadeck/sunshine.conf"
check "credentials are made before the port opens" "$(unitkey ExecStartPre)" /usr/lib/novadeck/sunshine-creds
[[ -x $CREDS ]] && ok "the helper is executable" || bad "the helper is not executable"

echo "5. the credentials helper"
mkdir -p "$TMP/bin"
# Stub sunshine: records its arguments and, unless told to fail, writes the file the way the real
# one does. Failing still exits 0, like the real one.
cat >"$TMP/bin/sunshine" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGS"
echo "stub log: $*"
[[ ${STUB_FAIL:-} ]] && exit 0
printf '{"username":"%s","salt":"s","password":"h"}\n' "$3" >"$RUNTIME_DIRECTORY/credentials.json"
STUB
chmod +x "$TMP/bin/sunshine"
run() {  # run [VAR=value...]: one start in a fresh runtime directory
    rm -rf "$TMP/run"; mkdir -p "$TMP/run"
    env STUB_ARGS="$TMP/args" RUNTIME_DIRECTORY="$TMP/run" SUNSHINE="$TMP/bin/sunshine" "$@" \
        bash "$CREDS" >"$TMP/out" 2>&1
}
run; check "succeeds" "$?" 0
check "passes our config first" "$(sed -n 1p "$TMP/args")" /etc/novadeck/sunshine.conf
check "then --creds" "$(sed -n 2p "$TMP/args")" --creds
PW=$(sed -n 4p "$TMP/args")
check "the saved password is the one set" "$(cat "$TMP/run/webui-password")" "$PW"
check "the password file is 0600" "$(stat -c %a "$TMP/run/webui-password")" 600
[[ ${#PW} -ge 32 && $PW =~ ^[A-Za-z0-9]+$ ]] && ok "32+ shell-safe characters" || bad "weak password: length ${#PW}"
check "the password is not printed" "$(grep -cF -- "$PW" "$TMP/out")" 0
run; check "a new password every start" "$([[ $(sed -n 4p "$TMP/args") != "$PW" ]] && echo new)" new
run STUB_FAIL=1; rc=$?
check "refuses to start when the credentials were not written" "$([[ $rc -ne 0 ]] && echo refused)" refused
env -u RUNTIME_DIRECTORY SUNSHINE="$TMP/bin/sunshine" STUB_ARGS="$TMP/args" bash "$CREDS" >/dev/null 2>&1; rc=$?
check "refuses to start without a runtime directory" "$([[ $rc -ne 0 ]] && echo refused)" refused

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
