#!/usr/bin/env bash
# Offline checks for the image's sysctl drop-ins (rootfs/overlay/usr/lib/sysctl.d).
#
#   tests/test-sysctl.sh
#
# WHY THIS FILE EXISTS. systemd-sysctl skips a line it cannot parse and boots on, so a typo turns a
# setting off without a word. Every drop-in must be comments and key=value lines, and the settings a
# fix depends on must keep the value it was measured with.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/rootfs/overlay/usr/lib/sysctl.d"
PASS=0 FAIL=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The value the drop-ins give <key>, the last one read winning (systemd-sysctl reads them in order).
value() { cat "$DIR"/*.conf | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" | tail -n1; }

echo "== syntax"
for f in "$DIR"/*.conf; do
  if grep -vE '^[[:space:]]*(#.*)?$' "$f" | grep -vqE '^-?[a-z0-9_.*/-]+[[:space:]]*=[[:space:]]*[^[:space:]].*$'; then
    bad "$(basename "$f"): a line is neither a comment nor key=value"
  else
    ok "$(basename "$f"): every line is a comment or key=value"
  fi
done

echo "== network"
[ "$(value net.ipv4.tcp_mtu_probing)" = 1 ] \
  && ok "tcp_mtu_probing=1: a connection whose full-size packets vanish retries smaller instead of timing out" \
  || bad "tcp_mtu_probing is '$(value net.ipv4.tcp_mtu_probing)', not 1"

grep -q 'test-sysctl.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-sysctl.sh is not in the Makefile test target"

echo
echo "test-sysctl.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
