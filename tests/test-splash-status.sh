#!/usr/bin/env bash
# Offline check for the splash status producers: splash-progress and splash-stall.
#
#   tests/test-splash-status.sh
#
# WHY THIS EXISTS. Both scripts are best-effort by design — every failure path in them ends in
# `|| true`, and splash-progress exits 0 on every path including the ones where it wrote nothing.
# That is the right behaviour (a status line must never fail the unit that emitted it) and it is
# also why exit status proves nothing here. So this asserts on the FILE CONTENTS and on what
# lands on the (fake) splash, never on whether the script succeeded.
#
# The stall narrator is the interesting one. It has a feedback loop that is easy to get wrong:
# it decides "nothing is happening" from the status file's mtime, and it reports by WRITING the
# status file — so a naive implementation silences itself forever after its first report, or
# never stops republishing. Both are tested below.
#
# WHAT A GREEN RUN DOES NOT PROVE: `systemctl` here is a stub on PATH. This exercises the
# scripts' logic, not the image's tool inventory and not one real systemd job
# ([[offline-suite-inherits-host-path]]).
#
# Runs on the host, no root, no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS="$ROOT/rootfs/overlay/usr/lib/novadeck/splash-progress"
STALL="$ROOT/rootfs/overlay/usr/lib/novadeck/splash-stall"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/system/novadeck-splash-stall.service"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

for f in "$PROGRESS" "$STALL"; do
    [[ -x $f ]] || { echo "missing or not executable: $f" >&2; exit 1; }
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RUN="$TMP/run/novadeck/splash"
STATUS="$RUN/status"
TAKEOVER="$RUN/takeover"

# A stub systemctl, so the narrator can be driven through states a real boot would take minutes
# to reach. $TMP/jobs holds the "list-jobs" output; $TMP/desc maps unit -> Description.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemctl" <<'STUB'
#!/bin/sh
case "$1 $2" in
    "list-jobs --plain") cat "$STUB_JOBS" 2>/dev/null ;;
    "show -p")
        # `systemctl show -p Description --value <unit>`: the unit is $5, not $4.
        grep "^$5 " "$STUB_DESC" 2>/dev/null | cut -d' ' -f2- ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/systemctl"
: >"$TMP/jobs"; : >"$TMP/desc"
export STUB_JOBS="$TMP/jobs" STUB_DESC="$TMP/desc"
export PATH="$TMP/bin:$PATH"

# ---------------------------------------------------------------------------------------------
# splash-progress
# ---------------------------------------------------------------------------------------------
echo "splash-progress:"
export NOVADECK_SPLASH_STATUS="$STATUS"

"$PROGRESS" Preparing NovaDeck
check "writes the message" "$(cat "$STATUS" 2>/dev/null)" "Preparing NovaDeck"

# It has to create its own directory: the first caller in a boot may well arrive before anything
# else has made /run/novadeck/splash.
rm -rf "$TMP/run"
"$PROGRESS" Early caller
[[ -f $STATUS ]] && ok "creates the run directory when it is missing" \
                 || bad "did not create $RUN"

# REPLACES, never appends. A status file that grows would make the drawer show the first line
# forever (it reads one line).
"$PROGRESS" Second line
check "replaces rather than appends" "$(wc -l <"$STATUS")" "1"
check "  and the content is the new line" "$(cat "$STATUS")" "Second line"

"$PROGRESS" --error Update failed
check "--error prefixes the red marker" "$(cat "$STATUS")" "!Update failed"

# The marker is a prefix on the line, not a word in it: an ordinary message that happens to start
# with a word must not be mistaken for one.
"$PROGRESS" Installing Steam
check "a normal line carries no marker" "$(cat "$STATUS")" "Installing Steam"

# No message at all must not blank a line that is currently on screen — an empty status is how
# the drawer is told to show nothing, and no caller means that by calling with no arguments.
"$PROGRESS"
check "an empty call leaves the previous line alone" "$(cat "$STATUS")" "Installing Steam"

# The temp file must not survive: a directory filling with .status.XXXXXX is a leak on a tmpfs.
"$PROGRESS" Another line
leftovers=$(find "$RUN" -name '.status.*' 2>/dev/null | wc -l)
check "leaves no temp files behind" "$leftovers" "0"

# Written by rename, which is what makes a torn read impossible. Proven structurally: the file
# the reader sees must be a DIFFERENT inode after each publish. An in-place rewrite keeps it.
ino1=$(stat -c %i "$STATUS")
"$PROGRESS" Yet another
ino2=$(stat -c %i "$STATUS")
[[ $ino1 != "$ino2" ]] && ok "publishes by rename (new inode), so a reader cannot see a torn line" \
                       || bad "status file kept inode $ino1 — it is being rewritten in place"

check "the published file is world-readable (the session drawer runs as deck)" \
      "$(stat -c %a "$STATUS")" "644"

# ---------------------------------------------------------------------------------------------
# splash-stall
# ---------------------------------------------------------------------------------------------
echo
echo "splash-stall:"
export NOVADECK_SPLASH_TAKEOVER="$TAKEOVER"
export NOVADECK_SPLASH_PROGRESS="$PROGRESS"
export NOVADECK_SPLASH_STALL_SECS=2
export NOVADECK_SPLASH_STALL_MAX=25

mkdir -p "$RUN"
printf 'Starting NovaDeck\n' >"$STATUS"
printf '4242\n' >"$TAKEOVER"          # the drawer's own pid: it still owns the display
printf '1 systemd-repart.service start running\n' >"$TMP/jobs"
printf 'systemd-repart.service Repartition Root Disk\n' >"$TMP/desc"

"$STALL" & stall_pid=$!
# Silence for STALL_SECS, then it should name the running job.
for _ in $(seq 1 20); do
    [[ "$(cat "$STATUS")" != "Starting NovaDeck" ]] && break
    sleep 0.5
done
check "names the running job after the stall window" \
      "$(cat "$STATUS")" "Waiting for Repartition Root Disk"

# It must NOT keep republishing. Its own write bumps the mtime it reads to decide whether anything
# is happening, so a republishing loop would permanently silence itself — and would also spam the
# journal once a second for the rest of a stuck boot.
before=$(stat -c %Y "$STATUS")
sleep 4
after=$(stat -c %Y "$STATUS")
check "does not republish the same job" "$before" "$after"

# A NEW job must be reported, though: the boot has moved on, and that is the difference between a
# slow boot and a stuck one.
printf '2 systemd-growfs-root.service start running\n' >"$TMP/jobs"
printf 'systemd-growfs-root.service Grow File System on /\n' >>"$TMP/desc"
for _ in $(seq 1 20); do
    [[ "$(cat "$STATUS")" == *"Grow File System"* ]] && break
    sleep 0.5
done
check "reports a job that changes" "$(cat "$STATUS")" "Waiting for Grow File System on /"

# Someone else publishing progress must re-arm the silence timer rather than be overwritten.
printf '3 some-other.service start running\n' >"$TMP/jobs"
printf 'Installing Steam\n' >"$STATUS"
sleep 1
check "yields to another producer's line" "$(cat "$STATUS")" "Installing Steam"

# Handover: the drawer's pid is replaced by a NAME, which is how a successor announces itself.
# Nothing hardcodes who that successor is.
printf 'sddm\n' >"$TAKEOVER"
gone=0
for _ in $(seq 1 20); do
    kill -0 "$stall_pid" 2>/dev/null || { gone=1; break; }
    sleep 0.5
done
[[ $gone -eq 1 ]] && ok "exits once a successor claims the display" \
                  || { bad "still running after the handover"; kill "$stall_pid" 2>/dev/null; }
wait "$stall_pid" 2>/dev/null

# A missing Description must fall back to the unit name rather than printing "Waiting for".
printf 'Starting NovaDeck\n' >"$STATUS"
printf '4242\n' >"$TAKEOVER"
printf '9 mystery.service start running\n' >"$TMP/jobs"
: >"$TMP/desc"
"$STALL" & stall_pid=$!
for _ in $(seq 1 20); do
    [[ "$(cat "$STATUS")" != "Starting NovaDeck" ]] && break
    sleep 0.5
done
check "falls back to the unit name when it has no Description" \
      "$(cat "$STATUS")" "Waiting for mystery.service"
printf 'sddm\n' >"$TAKEOVER"; wait "$stall_pid" 2>/dev/null

# ---------------------------------------------------------------------------------------------
# The unit
# ---------------------------------------------------------------------------------------------
echo
echo "novadeck-splash-stall.service:"
# DefaultDependencies=no is the whole reason this unit can see a first-boot repart stall. With
# default dependencies it would get an implicit After=sysinit.target and could only ever narrate
# boots that already went fine.
grep -q '^DefaultDependencies=no' "$UNIT" \
    && ok "runs with DefaultDependencies=no (so it starts inside sysinit)" \
    || bad "missing DefaultDependencies=no — it cannot narrate a sysinit stall"
grep -q '^Before=sysinit.target' "$UNIT" && ok "ordered before sysinit.target" \
    || bad "not ordered before sysinit.target"
grep -q '^Conflicts=shutdown.target' "$UNIT" && ok "stopped on shutdown" \
    || bad "missing Conflicts=shutdown.target (DefaultDependencies=no units need it explicitly)"
grep -q '^ConditionKernelCommandLine=!novadeck.splash=0' "$UNIT" \
    && ok "honours the same novadeck.splash=0 switch the initramfs does" \
    || bad "does not honour novadeck.splash=0"
[[ -L "$ROOT/rootfs/overlay/etc/systemd/system/sysinit.target.wants/novadeck-splash-stall.service" ]] \
    && ok "enabled via sysinit.target.wants" \
    || bad "not enabled — the unit ships but never runs"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
