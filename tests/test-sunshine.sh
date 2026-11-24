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
# What CAP_SYS_ADMIN would open to whoever gets code to run in here, none of which capture or encoding uses.
check "no namespaces" "$(unitkey RestrictNamespaces)" yes
for call in bpf perf_event_open fanotify_init unshare setns @mount @keyring @swap; do
    check "$call is refused" "$(unitkey SystemCallFilter | grep -cE "^~(.* )?$call( |\$)")" 1
done
check "refused with an error, not by killing the host" "$(unitkey SystemCallErrorNumber)" EPERM
# Refusing capset too would take down the capture thread, which raises its own capability.
check "the filter is a list of what is refused" "$(grep -c '^SystemCallFilter=[^~]' "$UNIT")" 0
check "Sunshine may still change its own capabilities" "$(unitkey SystemCallFilter | grep -cE '@privileged|capset')" 0
check "and nothing runs as root but the guest pads' device and the advert" \
    "$(grep -E '^Exec[A-Za-z]*=[-:!@]*\+' "$UNIT" | sed -E 's/^Exec[A-Za-z]*=[-:!@]*\+//' | sort | tr '\n' '|')" \
    "/usr/bin/setfacl -m u:deck:rw /dev/uhid|/usr/bin/setfacl -x u:deck /dev/uhid|/usr/lib/novadeck/sunshine-advert start|/usr/lib/novadeck/sunshine-advert stop|"
# The package opens /dev/uhid to the whole session at every boot; only a host needs it, for its guests' pads.
UHID="$OVL/usr/lib/udev/rules.d/71-novadeck-uhid.rules"
check "after the package's rule, and before the one that acts on uaccess" "$(printf '%s\n' 60-sunshine.rules "$(basename "$UHID")" 73-seat-late.rules | sort -c 2>&1)" ""
check "uhid is closed while nobody hosts" "$(grep -E '^[^#]' "$UHID" 2>/dev/null)" 'KERNEL=="uhid", GROUP="root", MODE="0600", TAG-="uaccess"'
check "opened before Sunshine starts, and the start fails if it cannot be" "$(unitkey ExecStartPre | head -1)" "+/usr/bin/setfacl -m u:deck:rw /dev/uhid"
check "closed again however Sunshine ends" "$(unitkey ExecStopPost | grep -c '^-+/usr/bin/setfacl -x u:deck /dev/uhid$')" 1
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
# Upstream, a stream belongs to whoever was verified last on ANY connection, so a guest could be streaming under
# another guest's name, where Disconnect misses them.
client_patch="$(grep -lE '^\+.*launch_session->client_cert = client\.cert' "$ROOT"/packages/sunshine/patches/*.patch)"
check "a stream belongs to the guest whose connection asked for it" "$(grep -c . <<<"$client_patch")" 1
check "launch and resume both" "$(grep -cE '^\+.*make_launch_session\(host_audio, args, client_of\(request\)\)' "$client_patch")" 2
check "the pin applies that patch before the one for Quit, which needs it" \
    "$(grep -oE '000[45]-nvhttp-[a-z]+' "$ROOT/packages/sunshine/source.pin" | tr '\n' ' ')" "0004-nvhttp-take 0005-nvhttp-a "
# Upstream, any guest's Quit ends every guest's stream.
quit_patch="$(grep -lE '^\+.*terminate_sessions_by_cert\(client_of\(request\)\.cert\)' "$ROOT"/packages/sunshine/patches/*.patch)"
check "a guest's quit ends that guest's stream first" "$(grep -c . <<<"$quit_patch")" 1
check "and everything only when no stream is left" "$(grep -cE '^\+.*session_count\(\) > 0' "$quit_patch")" 1
check "the pin applies that patch too" "$(grep -c "^patches:.*$(basename "$quit_patch")" "$ROOT/packages/sunshine/source.pin")" 1
check "every patch in the folder is in the pin" \
    "$(for p in "$ROOT"/packages/sunshine/patches/*.patch; do grep -qE "^patches:.*$(basename "$p")( |$)" "$ROOT/packages/sunshine/source.pin" || basename "$p"; done)" ""
check "log level leaves request headers out" "$(confkey min_log_level)" info
check "credentials live in the runtime directory" \
    "$(confkey credentials_file)" "/run/$(unitkey RuntimeDirectory)/credentials.json"
check "pairings stay in the default state file, on /home" "$(confkey file_state)" ""
check "the app list is ours" "$(confkey file_apps)" /usr/share/novadeck/sunshine-apps.json
check "the app list offers the whole session and runs no command" \
    "$(python3 -c 'import json,sys; print([sorted(a) for a in json.load(open(sys.argv[1]))["apps"]], [a["name"] for a in json.load(open(sys.argv[1]))["apps"]])' "$APPS")" \
    "[['image-path', 'name']] ['Desktop']"

echo "4. the unit, the config and the helper agree"
check "the unit starts Sunshine through the name helper" "$(unitkey ExecStart)" "/usr/lib/novadeck/sunshine-start"
check "credentials are made before the port opens" "$(unitkey ExecStartPre | tail -1)" /usr/lib/novadeck/sunshine-creds
[[ -x $CREDS ]] && ok "the helper is executable" || bad "the helper is not executable"

echo "4b. the host's name"
START="$OVL/usr/lib/novadeck/sunshine-start"
[[ -x $START ]] && ok "the helper is executable" || bad "the helper is missing or not executable"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' >"$TMP/echo-args"; chmod +x "$TMP/echo-args"
named() {  # named <model bytes> [conf line]: what Sunshine is started with
    printf "$1" >"$TMP/model"; printf '%s\n' "${2:-}" >"$TMP/conf"
    env SUNSHINE="$TMP/echo-args" MODEL="$TMP/model" CONF="$TMP/conf" bash "$START" 2>&1 | tr '\n' '|'
}
check "Sunshine is named after the device" "$(named 'KONKR Pocket FIT\0')" "$TMP/conf|sunshine_name=KONKR Pocket FIT|"
check "a name set in the config wins" "$(named 'KONKR Pocket FIT\0' 'sunshine_name = Couch')" "$TMP/conf|"
check "a commented-out name is no name" "$(named 'X\0' '# sunshine_name = Couch')" "$TMP/conf|sunshine_name=X|"
check "no model, no name: Sunshine keeps its own" "$(named '\0')" "$TMP/conf|"
check "a model cannot bring another option or a comment" "$(named 'A\nencoder = x # y\0')" "$TMP/conf|sunshine_name=A encoder x y|"
check "it replaces itself with Sunshine, which must be the main process" "$(grep -cE '^ *exec ' "$START")" 2

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

echo "6. the mDNS advert"
ADVERT="$OVL/usr/lib/novadeck/sunshine-advert"
[[ -x $ADVERT ]] && ok "the helper is executable" || bad "the helper is missing or not executable"
# '+': registering wants root (polkit), and the service is deck. '-': an advert is a convenience, and
# must never decide whether hosting starts or stops.
check "the unit publishes once Sunshine runs, as root, and never fails over it" "$(unitkey ExecStartPost)" "-+/usr/lib/novadeck/sunshine-advert start"
check "and withdraws however Sunshine ends" "$(unitkey ExecStopPost | head -1)" "-+/usr/lib/novadeck/sunshine-advert stop"
check "the responder is systemd-resolved" "$(unitkey Wants)" systemd-resolved.service
cat >"$TMP/bin/busctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BUS_LOG"
[[ $* == *UnregisterService* && ${STUB_NONE:-} ]] && exit 1
[[ $* == *" RegisterService "* && ${STUB_REFUSE:-} ]] && exit 1
exit 0
STUB
printf '#!/usr/bin/env bash\necho 0123456789abcdef0123456789abcdef\n' >"$TMP/bin/systemd-id128"
# Sunshine's port, as ss reports it: up, or not there.
printf '#!/usr/bin/env bash\n[[ ${STUB_PORT:-up} == up ]] && echo "LISTEN 0 4096 0.0.0.0:47989 0.0.0.0:*"\nexit 0\n' >"$TMP/bin/ss"
chmod +x "$TMP"/bin/*
advert() {  # advert <verb> [VAR=value...]
    : >"$TMP/bus"; local verb="$1"; shift
    env PATH="$TMP/bin:$PATH" BUS_LOG="$TMP/bus" ADVERT_WAIT=1 "$@" bash "$ADVERT" "$verb" >"$TMP/out" 2>&1
}
OBJ=/org/freedesktop/resolve1/dnssd/novadeck_2dsunshine
advert start; check "start succeeds" "$?" 0
check "a registration left by a crash is cleared first" "$(sed -n 1p "$TMP/bus" | grep -c "UnregisterService o $OBJ\$")" 1
check "then Moonlight's service type and Sunshine's port are registered" \
    "$(sed -n 2p "$TMP/bus" | grep -cE ' RegisterService sssqqqaa\{say\} novadeck-sunshine [^ ]+ _nvstream\._tcp 47989 0 0 0$')" 1
NAME=$(sed -n 2p "$TMP/bus" | sed -E 's/.* novadeck-sunshine ([^ ]+) .*/\1/')
check "every device is called novadeck, so the instance is not just the hostname" "$([[ $NAME =~ ^novadeck-[0-9a-f]{8}$ ]] && echo unique)" unique
check "the machine id itself is not what is published" "$(grep -c -- '--app-specific=\|-a ' "$ADVERT")" 1
advert start STUB_NONE=1; check "nothing to clear is normal" "$? $(grep -c ' RegisterService ' "$TMP/bus")" "0 1"
advert start STUB_PORT=down; check "a port that never opens is not advertised" "$? $(grep -c ' RegisterService ' "$TMP/bus")" "0 0"
check "and the log says so" "$(grep -c 'not advertising' "$TMP/out")" 1
advert start STUB_REFUSE=1; check "a refused registration does not fail the start" "$?" 0
check "and the log says that too" "$(grep -c 'could not advertise' "$TMP/out")" 1
advert stop; check "stop withdraws the one registration" "$? $(cat "$TMP/bus" | grep -c "UnregisterService o $OBJ\$") $(wc -l <"$TMP/bus")" "0 1 1"
advert bogus; check "any other verb is refused" "$([[ $? -ne 0 ]] && echo refused)" refused
check "nothing writes a .dnssd file" "$(grep -rlE '[^ ]+\.dnssd' "$ADVERT" "$UNIT" | wc -l)" 0
# The object path is the escaped id: rename one and the advert outlives the service.
check "the path withdrawn is the id registered" "$(python3 -c 'print("novadeck-sunshine".replace("-","_2d"))')" "${OBJ##*/}"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
