#!/usr/bin/env bash
# Offline test for the remote-access path: /usr/bin/novadeck-pairingd and the switch that drives
# it, /usr/bin/steamos-polkit-helpers/steamos-devkit-mode.
#
#   images/test-pairingd.sh
#
# WHY THIS FILE EXISTS. The pairing agent listens on an unauthenticated port and its answer to a
# single POST decides whether a stranger on the same Wi-Fi gets a shell on the device. Two of its
# guarantees are the kind that read as obviously true and fail silently: that a registration
# arriving after the window is refused BEFORE anything is installed, and that a submitted line
# cannot carry authorized_keys options (command=, permitopen=) that would turn "install a key"
# into "install a forced command". Neither is observable on hardware without deliberately
# attacking the device, so both are pinned here instead.
#
# Everything runs on the host with no root and no device: the agent is imported by path and its
# two privileged effects (writing another account's home, enabling a system unit) are replaced
# with recorders, so the HTTP layer and the window arithmetic are exercised for real.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/fs-overlay/usr/bin/novadeck-pairingd"
SWITCH="$ROOT/fs-overlay/usr/bin/steamos-polkit-helpers/steamos-devkit-mode"
UNIT="$ROOT/fs-overlay/usr/lib/systemd/system/novadeck-pairingd.service"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$DAEMON" "$SWITCH" "$UNIT"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# --- 1. the agent: key parsing, key install, window enforcement, HTTP surface ---------------------
#
# Driven from python because that is where the code is. The harness prints the same "ok"/"FAIL"
# lines this script does and exits nonzero if any case failed, so the two tallies stay one report.
CASE="agent"
if ! command -v ssh-keygen >/dev/null 2>&1; then
  skip "ssh-keygen not on PATH — cannot generate or validate test keys"
else
  agent_out="$(python3 - "$DAEMON" <<'PY'
import importlib.machinery, importlib.util
import json, os, pwd, stat, subprocess, sys, tempfile, threading, time
import urllib.request, urllib.error

daemon_path = sys.argv[1]
spec = importlib.util.spec_from_loader(
    "pairingd", importlib.machinery.SourceFileLoader("pairingd", daemon_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

P = F = 0
def ok(m):
    global P; P += 1; print(f"  ok   agent -- {m}")
def bad(m):
    global F; F += 1; print(f"  FAIL agent -- {m}")

tmp = tempfile.mkdtemp()
home = os.path.join(tmp, "home")
os.makedirs(home)

# Real keys, so validation is tested against the same tool that runs on the device.
def genkey(kind="ed25519"):
    p = os.path.join(tmp, f"k_{kind}_{time.time_ns()}")
    subprocess.run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-C", "tester@host", "-f", p],
                   check=True)
    return open(p + ".pub").read().strip()

KEY = genkey()
KEY2 = genkey()

# --- key parsing -------------------------------------------------------------------------------
if pd.parse_public_key(KEY.encode()) is not None:
    ok("accepts a well-formed ed25519 public key")
else:
    bad("rejected a valid ed25519 public key")

# The pairing clients append a marker after the comment; it must survive as a plain label.
if pd.parse_public_key((KEY + " 900b919520e4cf601998a71eec318fec").encode()) is not None:
    ok("accepts a key carrying a trailing client marker")
else:
    bad("rejected a key with a trailing client marker")

# THE ONE THAT MATTERS: authorized_keys options must never be smuggled in ahead of the key.
for hostile, label in [
    (f'command="/bin/sh" {KEY}',              "command= option prefix"),
    (f'no-pty,permitopen="10.0.0.1:22" {KEY}', "permitopen option prefix"),
    (f'environment="LD_PRELOAD=/tmp/x" {KEY}', "environment= option prefix"),
]:
    if pd.parse_public_key(hostile.encode()) is None:
        ok(f"rejects {label}")
    else:
        bad(f"ACCEPTED {label} — a registration could install a forced command")

if pd.parse_public_key((KEY + "\n" + KEY2).encode()) is None:
    ok("rejects a body carrying two keys")
else:
    bad("accepted two keys in one registration")

for junk, label in [
    (b"", "empty body"),
    (b"not a key at all", "non-key text"),
    (b"\x00\x01\x02\xff", "binary garbage"),
    (b"ssh-dss AAAAB3NzaC1kc3M= x", "disallowed key type"),
    ("ssh-ed25519 not-actually-base64 c".encode(), "malformed key blob"),
]:
    if pd.parse_public_key(junk) is None:
        ok(f"rejects {label}")
    else:
        bad(f"accepted {label}")

parsed = pd.parse_public_key((KEY + " tab\there\x07bell").encode())
if parsed is not None and "\t" not in parsed and "\x07" not in parsed:
    ok("strips control characters from the comment field")
else:
    bad("comment field kept control characters")

# --- key install -------------------------------------------------------------------------------
# getpwnam is replaced so the test writes into a scratch home as the invoking user; ownership is
# set to our own uid/gid, which is the same call the daemon makes as root.
fake = pwd.struct_passwd((pd.SESSION_USER, "x", os.getuid(), os.getgid(), "", home, "/bin/sh"))
pd.pwd.getpwnam = lambda n: fake if n == pd.SESSION_USER else (_ for _ in ()).throw(KeyError(n))

akeys = os.path.join(home, ".ssh", "authorized_keys")
if pd.install_key(pd.parse_public_key(KEY.encode())) and os.path.exists(akeys):
    ok("installs the key into the session user's authorized_keys")
else:
    bad("did not install the key")

m_dir = stat.S_IMODE(os.stat(os.path.join(home, ".ssh")).st_mode)
m_file = stat.S_IMODE(os.stat(akeys).st_mode)
if m_dir == 0o700 and m_file == 0o600:
    ok("creates .ssh 0700 and authorized_keys 0600")
else:
    bad(f"wrong modes: .ssh={oct(m_dir)} authorized_keys={oct(m_file)} (sshd would refuse these)")

pd.install_key(pd.parse_public_key(KEY.encode()))
if open(akeys).read().count(KEY.split()[1]) == 1:
    ok("re-registering the same key does not duplicate it")
else:
    bad("duplicate key appended on re-registration")

# A pre-existing file with no trailing newline must not have its last key joined to the new one.
with open(akeys, "w") as f:
    f.write(KEY)
pd.install_key(pd.parse_public_key(KEY2.encode()))
lines = [l for l in open(akeys).read().splitlines() if l.strip()]
if len(lines) == 2 and KEY.split()[1] in lines[0] and KEY2.split()[1] in lines[1]:
    ok("appends without corrupting a file that lacked a trailing newline")
else:
    bad(f"append corrupted the file: {lines!r}")

# --- HTTP surface + the window -------------------------------------------------------------------
enabled = []
pd.enable_sshd = lambda: (enabled.append(True), True)[1]

def serve():
    srv = pd.PairingServer(("127.0.0.1", 0), pd.PairingHandler)
    threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05},
                     daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"

def req(url, data=None, method=None):
    r = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

srv, base = serve()

code, body = req(base + "/login-name")
if code == 200 and body.strip() == pd.SESSION_USER:
    ok("GET /login-name names the session account")
else:
    bad(f"GET /login-name returned {code} {body!r}")

code, body = req(base + "/status")
if code == 200 and json.loads(body)["pairing_open"] is True:
    ok("GET /status reports the window open while it is")
else:
    bad(f"GET /status returned {code} {body!r}")

code, _ = req(base + "/nope")
if code == 404:
    ok("unknown path is 404")
else:
    bad(f"unknown path returned {code}")

os.remove(akeys)
code, body = req(base + "/register", data=KEY.encode())
if code == 200 and os.path.exists(akeys) and enabled:
    ok("registration inside the window installs the key and enables sshd")
else:
    bad(f"in-window registration: {code} {body!r} installed={os.path.exists(akeys)} "
        f"sshd_enabled={bool(enabled)}")

# An invalid key must not enable sshd, even inside the window: opening the port is a
# consequence of a SUCCESSFUL pairing, never of an attempted one.
enabled.clear()
code, _ = req(base + "/register", data=b"command=\"/bin/sh\" " + KEY.encode())
if code == 400 and not enabled:
    ok("a rejected key inside the window does not enable sshd")
else:
    bad(f"rejected key still enabled sshd (code={code}, enabled={bool(enabled)})")

code, _ = req(base + "/register", data=b"x" * (pd.MAX_BODY_BYTES + 1))
if code == 400:
    ok("oversized body is refused")
else:
    bad(f"oversized body returned {code}")

srv.shutdown()

# Now the closed window. Reaching back in monotonic time is the only honest way to test this
# without sleeping for the real duration.
pd.PAIRING_WINDOW_SECONDS = -1
enabled.clear()
os.remove(akeys)
srv, base = serve()
code, body = req(base + "/register", data=KEY.encode())
if code == 403 and not os.path.exists(akeys) and not enabled:
    ok("registration after the window is refused, installs nothing, enables nothing")
else:
    bad(f"post-window registration: {code} {body!r} installed={os.path.exists(akeys)} "
        f"sshd_enabled={bool(enabled)}")

code, body = req(base + "/status")
if code == 200 and json.loads(body)["pairing_open"] is False:
    ok("GET /status reports the window closed once it is")
else:
    bad(f"GET /status after window: {code} {body!r}")
srv.shutdown()

print(f"__TALLY__ {P} {F}")
sys.exit(1 if F else 0)
PY
)"
  agent_rc=$?
  # Reprint the harness's lines, then fold its tally into ours.
  printf '%s\n' "$agent_out" | grep -v '^__TALLY__' || true
  tally="$(printf '%s\n' "$agent_out" | sed -n 's/^__TALLY__ //p')"
  if [ -n "$tally" ]; then
    PASS=$((PASS + ${tally%% *}))
    FAIL=$((FAIL + ${tally##* }))
  else
    bad "agent harness did not report a tally (rc=$agent_rc) — it crashed before finishing"
  fi
fi

# --- 2. the switch: argument contract ------------------------------------------------------------
#
# The verb check runs BEFORE the privilege escalation, so this part is testable as an ordinary
# user. An unknown verb must be EINVAL and must not fall through to either branch.
CASE="switch"
for verb in "--status" "" "enable-please" "--Enable"; do
  out="$(bash "$SWITCH" $verb 2>&1)"; rc=$?
  if [ "$rc" -eq 22 ]; then
    ok "unknown verb '${verb:-<none>}' is EINVAL (22), not a silent disable"
  else
    bad "unknown verb '${verb:-<none>}' exited $rc: $out"
  fi
done

# --- 3. the switch: what each verb actually runs --------------------------------------------------
#
# Needs uid 0 for the script to take its own branch instead of re-execing pkexec. A user
# namespace supplies that without real privilege; where it is unavailable the cases are skipped
# rather than faked, because a fake pkexec that re-execs the script would loop forever.
CASE="switch-root"
if ! unshare -r true 2>/dev/null; then
  skip "no unprivileged user namespaces — cannot exercise the root branch"
else
  SB="$(mktemp -d)"
  cat >"$SB/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >>"$SBLOG"
EOF
  chmod 0755 "$SB/systemctl"

  run_switch() {
    SBLOG="$SB/calls" ; : >"$SBLOG"
    SBLOG="$SBLOG" unshare -r env PATH="$SB:$PATH" SBLOG="$SB/calls" bash "$SWITCH" "$1" >/dev/null 2>&1
    cat "$SB/calls"
  }

  calls="$(run_switch --enable)"
  if [ "$calls" = "systemctl restart novadeck-pairingd.service" ]; then
    ok "--enable restarts the agent (a second flip opens a FRESH window)"
  else
    bad "--enable ran: ${calls:-<nothing>}"
  fi

  calls="$(run_switch --disable)"
  stopped="$(printf '%s\n' "$calls" | grep -c 'stop novadeck-pairingd')"
  disabled="$(printf '%s\n' "$calls" | grep -c 'disable --now sshd')"
  if [ "$stopped" -eq 1 ] && [ "$disabled" -eq 1 ]; then
    ok "--disable stops the agent AND closes sshd"
  else
    bad "--disable ran: ${calls:-<nothing>}"
  fi
  # Ordering is load-bearing: a registration landing between the two would re-enable sshd
  # immediately after we disabled it.
  if [ "$(printf '%s\n' "$calls" | grep -n 'stop novadeck-pairingd' | cut -d: -f1)" = "1" ]; then
    ok "--disable stops the agent BEFORE disabling sshd"
  else
    bad "--disable disabled sshd before stopping the agent"
  fi
  rm -rf "$SB"
fi

# --- 4. the unit: structural guarantees ----------------------------------------------------------
#
# Two properties the agent's own comments rely on but cannot enforce from inside itself.
CASE="unit"
if ! grep -q '^\[Install\]' "$UNIT"; then
  ok "no [Install] section — the agent cannot be enabled at boot"
else
  bad "unit has [Install]: a device could boot straight into pairing mode"
fi

if grep -qE '^Restart=no[[:space:]]*$' "$UNIT"; then
  ok "Restart=no — a crash cannot silently re-open a pairing window"
else
  bad "unit is restartable: a crash loop would keep re-opening the window"
fi

if grep -q '^ExecStopPost=.*rm -f /etc/avahi/services/' "$UNIT"; then
  ok "withdraws its network advertisement on stop"
else
  bad "unit leaves its advertisement published after it stops"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
