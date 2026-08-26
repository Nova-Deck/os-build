#!/usr/bin/env bash
# Offline test for the remote-access path: /usr/bin/novadeck-pairingd and the switch that drives
# it, /usr/bin/steamos-polkit-helpers/steamos-devkit-mode.
#
#   tests/test-pairingd.sh
#
# WHY THIS FILE EXISTS. The pairing agent listens on an unauthenticated port and its answer to a
# single POST decides whether a stranger on the same Wi-Fi gets a shell on the device. Its
# sharpest guarantee is the kind that reads as obviously true and fails silently: a submitted
# line cannot carry authorized_keys options (command=, permitopen=) that would turn "install a
# key" into "install a forced command". That is not observable on hardware without deliberately
# attacking the device, so it is pinned here instead. The design intentionally has NO time window
# — the switch starts and stops the daemon, and the daemon accepts keys for exactly as long as it
# runs — so the switch verbs and the daemon's structural guarantees are pinned here too.
#
# Everything runs on the host with no root and no device: the agent is imported by path and its
# one privileged effect (writing another account's home) is exercised against a scratch home.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/rootfs/overlay/usr/bin/novadeck-pairingd"
SWITCH="$ROOT/rootfs/overlay/usr/bin/steamos-polkit-helpers/steamos-devkit-mode"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/system/novadeck-pairingd.service"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$DAEMON" "$SWITCH" "$UNIT"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# --- 1. the agent: key parsing, key install, HTTP surface ----------------------------------------
#
# Driven from python because that is where the code is. The harness prints the same "ok"/"FAIL"
# lines this script does and exits nonzero if any case failed, so the two tallies stay one report.
CASE="agent"
if ! command -v ssh-keygen >/dev/null 2>&1; then
  skip "ssh-keygen not on PATH — cannot generate or validate test keys"
else
  # -B is load-bearing: importing the daemon by path writes __pycache__ NEXT TO IT, i.e. inside
  # rootfs/overlay/usr/bin, which assemble-rootfs.sh copies wholesale into the image. Without this,
  # running the tests silently bakes a stale .pyc of the pairing agent into the shipped rootfs.
  agent_out="$(python3 -B - "$DAEMON" <<'PY'
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

# A key file written on Windows arrives CRLF-terminated. docs/remote-access.md promises that
# works, so it is checked here rather than left as a claim.
if pd.parse_public_key((KEY + "\r\n").encode()) is not None:
    ok("accepts a CRLF-terminated key file")
else:
    bad("rejected a CRLF-terminated key — Windows pairing would fail")

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

# --- HTTP surface --------------------------------------------------------------------------------
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

# There is no window: if the daemon answers at all, it is accepting keys, so /status is always
# open. (A closed daemon is a closed port, which the client sees as connection-refused instead.)
code, body = req(base + "/status")
if code == 200 and json.loads(body)["pairing_open"] is True:
    ok("GET /status reports pairing open while the daemon runs")
else:
    bad(f"GET /status returned {code} {body!r}")

code, _ = req(base + "/nope")
if code == 404:
    ok("unknown path is 404")
else:
    bad(f"unknown path returned {code}")

os.remove(akeys)
code, body = req(base + "/register", data=KEY.encode())
if code == 200 and os.path.exists(akeys):
    ok("a registration installs the key")
else:
    bad(f"registration: {code} {body!r} installed={os.path.exists(akeys)}")

# A hostile line must install nothing — the key install is the only privileged effect now, so
# "did it install?" is the whole question.
os.remove(akeys) if os.path.exists(akeys) else None
code, _ = req(base + "/register", data=b"command=\"/bin/sh\" " + KEY.encode())
if code == 400 and not os.path.exists(akeys):
    ok("a rejected key installs nothing")
else:
    bad(f"rejected key still wrote a file (code={code}, installed={os.path.exists(akeys)})")

code, _ = req(base + "/register", data=b"x" * (pd.MAX_BODY_BYTES + 1))
if code == 400:
    ok("oversized body is refused")
else:
    bad(f"oversized body returned {code}")

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

  # The switch gates the pairing DAEMON, never sshd (which ships always-on, key-only). So each
  # verb must touch novadeck-pairingd and nothing else — a stray `disable sshd` here would be the
  # bug this pins against.
  calls="$(run_switch --enable)"
  if [ "$calls" = "systemctl start novadeck-pairingd.service" ]; then
    ok "--enable starts the pairing daemon (and only that)"
  else
    bad "--enable ran: ${calls:-<nothing>}"
  fi

  calls="$(run_switch --disable)"
  if [ "$calls" = "systemctl stop novadeck-pairingd.service" ]; then
    ok "--disable stops the pairing daemon (and does NOT touch sshd)"
  else
    bad "--disable ran: ${calls:-<nothing>}"
  fi
  rm -rf "$SB"
fi

# --- 4. the unit: structural guarantees ----------------------------------------------------------
CASE="unit"
if ! grep -q '^\[Install\]' "$UNIT"; then
  ok "no [Install] section — systemd cannot start the daemon on its own"
else
  bad "unit has [Install]: systemd could start pairing without the switch"
fi

# Restart=on-failure keeps the running daemon matching the switch after a crash; a clean stop by
# the switch helper is not a failure, so --disable still stops it for good. (The old Restart=no
# existed only to protect a time window that no longer exists.)
if grep -qE '^Restart=on-failure[[:space:]]*$' "$UNIT"; then
  ok "Restart=on-failure — a crash does not leave the switch showing on with the port shut"
else
  bad "unit is not Restart=on-failure: a crash would silently drop pairing while the switch shows on"
fi

if grep -q '^ExecStopPost=.*rm -f /etc/avahi/services/' "$UNIT"; then
  ok "withdraws its network advertisement on stop"
else
  bad "unit leaves its advertisement published after it stops"
fi

# The advertisement must never decide whether remote access works. It shipped once as a FATAL
# ExecStartPre writing into /etc under ProtectSystem=full -- which mounts /etc read-only -- so
# the install failed EROFS and took the entire pairing path down with it: port closed, on-screen
# switch apparently dead, and no way to see why on a device with no shell and no serial console.
# Both halves are asserted because either one alone would have prevented that.
if grep -qE '^ExecStartPre=-' "$UNIT"; then
  ok "publishing the advertisement is non-fatal — it cannot block pairing"
else
  bad "ExecStartPre is fatal: a failure to advertise would stop the agent starting at all"
fi

# ProtectSystem=full/strict makes /etc read-only, so anything the unit genuinely has to write
# there needs an explicit carve-out. Without this the line above would silently degrade to
# "mDNS never works" instead of failing loudly.
if grep -qE '^ProtectSystem=(full|strict)' "$UNIT"; then
  if grep -qE '^ReadWritePaths=-?/etc/avahi' "$UNIT"; then
    ok "ProtectSystem=full is carved out for /etc/avahi so the advertisement can be written"
  else
    bad "ProtectSystem makes /etc read-only but nothing grants /etc/avahi: advertisement cannot be published"
  fi
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
