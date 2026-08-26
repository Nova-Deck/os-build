#!/usr/bin/env bash
# Offline systemd unit check for everything under fs-overlay.
#
#   tests/test-units.sh
#
# WHY THIS EXISTS. systemd's parser is permissive about directives it does not recognise: it logs
# "Unknown key name '<X>' in section [<Y>], ignoring" and starts the unit anyway. A unit carrying
# an invented directive therefore looks correct in review, passes every test that only reads it as
# text, and simply does not do the thing it says it does.
#
# novadeck shipped exactly that: novadeck-boot-good.service used `ExecOnFailure=`, which is not a
# systemd directive, so the failed-boot demote -- the OS half of the A/B rollback design, and the
# ONLY rollback trigger while the stage-2 counter is unwired -- never ran. Nothing caught it,
# because nothing ever asked systemd what it thought of the file.
#
# This asks. Every unknown key, unknown section and syntax error is a failure. Host-only noise is
# filtered: the device's binaries are not installed here, so "is not executable" and the ordering
# advice systemd emits about units it cannot see are expected and ignored.
#
# Runs on the host with no root and no device. Skips (does not fail) where systemd-analyze is
# absent, since the check is only as good as the systemd that runs it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# System and user units. Deliberately NOT fs-overlay/usr/share/dbus-1/**/*.service -- those are
# D-Bus activation files, a different format that happens to share the extension. The enable
# symlinks under fs-overlay/etc/systemd/system point back into these, so they add no coverage.
#
# install/units/ is here too, and not because it is convenient: those units ship on the INSTALLER
# image, which has no suite of its own until Phase 6 and which is the one artifact that has to work
# when the device is broken. An invented directive there fails on a machine with no serial console.
UNITDIRS=("$ROOT/fs-overlay/usr/lib/systemd/system" "$ROOT/fs-overlay/usr/lib/systemd/user"
          "$ROOT/install/units")

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }

[ -d "${UNITDIRS[0]}" ] || { echo "no unit dir: ${UNITDIRS[0]}" >&2; exit 1; }

if ! command -v systemd-analyze >/dev/null 2>&1; then
  skip "systemd-analyze not installed -- unit syntax unverified"
  printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Only these are real complaints about the FILE. Everything else systemd-analyze says on a host
# that is not the device (missing binaries, unresolvable dependencies, unit-file-in-a-weird-path
# advice) is noise here.
FATAL='Unknown key|Unknown section|Failed to parse|Invalid |missing|Assignment outside of section'

shopt -s nullglob
n=0
for d in "${UNITDIRS[@]}"; do
for u in "$d"/*.service "$d"/*.path "$d"/*.timer "$d"/*.socket "$d"/*.target "$d"/*.mount; do
  n=$((n+1))
  name="$(basename "$u")"
  systemd-analyze verify "$u" >"$T/out" 2>&1 || true
  # "is not executable: No such file" is the device's own binaries being absent from this host.
  if grep -Ev 'is not executable' "$T/out" | grep -Eq "$FATAL"; then
    bad "$name"
    grep -Ev 'is not executable' "$T/out" | grep -E "$FATAL" | sed 's/^/         /'
  else
    ok "$name"
  fi
done
done
[ "$n" -gt 0 ] || bad "no units found under fs-overlay/usr/lib/systemd"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
