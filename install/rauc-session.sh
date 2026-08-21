#!/usr/bin/env bash
# novadeck internal-install RAUC session — Phase 4a of .claude/plans/internal-install.plan.md.
#
#   install/rauc-session.sh <target-root-dev> <bundle-url-or-path>
#
# Streams a signed bundle into ONE partition on a disk that carries no novadeck, from an installer
# medium that is not a slot of the system being built. Everything here exists because `rauc install`
# cannot be pointed at a foreign disk from the command line.
#
# WHY A WHOLE SESSION AND NOT A FLAG. With the service enabled -- and ours is, the OTA path is a
# D-Bus conversation (fs-overlay/usr/bin/novadeck-update) -- the install subcommand's `-c/--conf`
# and `--override-boot-slot` are compiled OUT: _reference/rauc/src/main.c's entries_install puts
# both behind `#if ENABLE_SERVICE == 0`, and the client half just forwards a bundle path to
# whatever already owns de.pengutronix.rauc. So the config the install runs under is the config of
# the SERVICE process, and the only way to choose it is to be the one who started the service.
# entries_service keeps --override-boot-slot unconditionally, which is the seam this uses.
#
# THE THREE PROPERTIES THE SYNTHESIZED CONFIG BUYS, none of them cosmetic:
#
#   no bootname=     determine_boot_states() `continue`s on a slot with no bootname, and
#                    get_bootname_slot() (install.c:1267) skips it when choosing which slot to
#                    activate -- so boot_mark_slot comes back NULL and r_mark_active() is never
#                    called. No bootloader backend runs, which is right: the boot state this
#                    install will have does not exist yet. The orchestrator arms A.conf itself,
#                    last, once the disk is genuinely bootable.
#   no bootloader=   belt to that brace. With no bootname there is no call to make; with no
#                    bootloader configured there is no backend to make it with either.
#   no data-         `adaptive=block-hash-index` in the manifest needs a data directory to reuse
#   directory=       blocks from, and a virgin slot has nothing to reuse. rauc says so at
#                    g_message level and falls through to raw_copy (update_handler.c:1003). Plan
#                    for the full stream; a retry is cheap because it re-lays and re-streams.
#   exactly one      select_inactive_slot_class_member() iterates a GHashTable, so with two
#   slot             inactive slots the pick is hash-order nondeterministic. There is no B to
#                    install into on a fresh disk anyway -- the first OTA fills it.
#
# --override-boot-slot=_external_ is rauc's own external-medium mode: determine_slot_states()
# marks every slot ST_INACTIVE and does not require a booted one (install.c:210). The alternative
# is `rauc.external` on the kernel cmdline (context.c:91), which would work too -- but that puts
# the property in the installer image's grub.cfg, where nothing in this script could assert it.
# Passing it here means the process that depends on it is the process that set it.
set -euo pipefail

PROG=${0##*/}
log() { printf '[%s] %s\n' "$PROG" "$1"; }
die() { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

# Test seams. install/test-install.sh executes THIS file, so what it asserts is the artifact that
# ships; overriding these points it at a sandbox run directory and stub binaries. DEVTEST is the
# assertion a sandbox cannot keep -- an unprivileged test has no block device to offer -- and it is
# the same pair post-install.sh documents: everything a wrong answer destroys lives behind the
# device argument, so treat RUNDIR and DEVTEST as related.
RUNDIR=${NOVADECK_INSTALL_RUN:-/run/novadeck/install}
RAUC=${RAUC:-rauc}
DBUS_DAEMON=${DBUS_DAEMON:-dbus-daemon}
GDBUS=${GDBUS:-gdbus}
KEYRING=${KEYRING:-/etc/rauc/keyring.pem}
POST_INSTALL=${POST_INSTALL:-/usr/lib/novadeck/install/post-install-fresh.sh}
DEVTEST=${DEVTEST:--b}
COMPATIBLE=${COMPATIBLE:-novadeck}
# How long to wait for the service to take the bus name. Generous: a cold installer medium is
# reading rauc and glib off squashfs on flash storage.
OWN_TIMEOUT=${OWN_TIMEOUT:-30}

BUS_NAME=de.pengutronix.rauc

[ $# -eq 2 ] || die "usage: $PROG <target-root-dev> <bundle-url-or-path>"
TARGET_DEV="$1"; BUNDLE="$2"

# --- fail closed on every tool, before anything starts ------------------------------------------
# The shipped image carries few of these and the installer image is a different root again, so a
# missing one is a live possibility rather than a theoretical one. Asserted HERE, together, rather
# than discovered at three different use sites -- the last of which would be after the service is
# up and a bundle is half-streamed. See the 2026-08-21 Pocket FIT finding: a missing binary and a
# missing file are indistinguishable to a caller that does not check.
for t in "$RAUC" "$DBUS_DAEMON" "$GDBUS"; do
  command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH -- the installer image is missing it"
done
[ -r "$KEYRING" ] || die "no readable RAUC keyring at $KEYRING -- nothing would be verified"
[ -x "$POST_INSTALL" ] || die "no post-install handler at $POST_INSTALL"
# shellcheck disable=SC2086  # DEVTEST is a predicate, not a path
[ $DEVTEST "$TARGET_DEV" ] || die "$TARGET_DEV is not a block device"
[ -n "$BUNDLE" ] || die "no bundle given"

mkdir -p "$RUNDIR" || die "cannot create $RUNDIR"

# --- the slot device, behind a stable name ------------------------------------------------------
# The config names $RUNDIR/target-root-a and this symlink is what points it at the real partition.
# Two reasons, and the second is the load-bearing one:
#
#   the config is then the same text on every board, so what the offline suite asserts about it is
#   what runs; and
#
#   the real path is a /dev/disk/by-partuuid/<uuid> minted minutes ago by genpart.sh --append. The
#   spine resolves it; nothing here concatenates a disk and an index, per the plan's §4c
#   requirement. `ln -sfn` rather than a fresh mkdir so a retry after a failed stream is clean.
SLOT_LINK="$RUNDIR/target-root-a"
ln -sfn "$TARGET_DEV" "$SLOT_LINK" || die "cannot point $SLOT_LINK at $TARGET_DEV"

CONF="$RUNDIR/rauc.conf"
cat >"$CONF" <<EOF || die "cannot write $CONF"
# Synthesized by $PROG. Not a copy of /etc/rauc/system.conf and deliberately not derived from it:
# that file describes a RUNNING novadeck with two slots and a bootloader, and this describes one
# partition on a disk that has never booted. See the header of $PROG for what each omission buys.
[system]
compatible=$COMPATIBLE
bundle-formats=verity

[keyring]
path=$KEYRING
check-purpose=codesign

[handlers]
post-install=$POST_INSTALL

[slot.rootfs.0]
device=$SLOT_LINK
type=raw
EOF

# --- a private system bus -----------------------------------------------------------------------
# Started BEFORE anything else touches the bus, so the service we are about to run is the only
# thing that can ever own $BUS_NAME here. The installer image runs systemd and may well have a
# stock system bus up on /run/dbus/system_bus_socket; this listens somewhere else entirely and
# every client below is handed the address, so the two never meet.
#
# NO <servicedir> AND NO <standard_system_servicedirs/>, which is the actual guarantee. Without an
# activation directory dbus-daemon cannot start anything at all, so a stock rauc.service cannot be
# activated onto this bus and win the name with /etc/rauc/system.conf -- the failure that would put
# the bundle in /dev/disk/by-partlabel/novadeck-root-A, i.e. on the INSTALLER'S OWN medium.
#
# The policy is open because the socket is not: it lives in $RUNDIR on a tmpfs, and the installer
# runs as root and only as root. (Do not write `--` inside these comments. dbus' XML parser treats
# it as an error inside a comment and rejects the whole file, which reads as a bus that will not
# start for no stated reason.)
BUS_SOCKET="$RUNDIR/bus"
BUS_CONF="$RUNDIR/dbus.conf"
cat >"$BUS_CONF" <<EOF || die "cannot write $BUS_CONF"
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$BUS_SOCKET</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
EOF

BUS_PID=""; SVC_PID=""
cleanup() {
  local st=$?
  [ -n "$SVC_PID" ] && kill "$SVC_PID" 2>/dev/null || true
  [ -n "$BUS_PID" ] && kill "$BUS_PID" 2>/dev/null || true
  # The socket outliving the daemon is what makes a retry connect to nothing and hang.
  rm -f "$BUS_SOCKET"
  return $st
}
trap cleanup EXIT

PIDFILE="$RUNDIR/dbus.pid"
rm -f "$PIDFILE" "$BUS_SOCKET"
"$DBUS_DAEMON" --config-file="$BUS_CONF" --fork --print-pid="$PIDFILE" \
  || die "the private system bus would not start"
BUS_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
[ -n "$BUS_PID" ] || die "the private system bus started but printed no pid"
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$BUS_SOCKET"
log "private system bus at $BUS_SOCKET (pid $BUS_PID)"

# --- the service, and proof that it is OURS -----------------------------------------------------
"$RAUC" -c "$CONF" service --override-boot-slot=_external_ &
SVC_PID=$!

# Poll for the name, then check WHO holds it. The name alone is not the assertion worth making:
# "something owns de.pengutronix.rauc" is true of the failure this is here to exclude. Matching the
# owner's pid against the process we started is what makes it a proof. GetConnectionUnixProcessID
# is answered by the bus daemon itself from SO_PEERCRED, so it cannot be spoofed by the peer.
own_pid() {
  local unique
  unique="$("$GDBUS" call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
             --method org.freedesktop.DBus.GetNameOwner "$BUS_NAME" 2>/dev/null)" || return 1
  unique="${unique#(\'}"; unique="${unique%\',)}"
  [ -n "$unique" ] || return 1
  local pid
  pid="$("$GDBUS" call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
          --method org.freedesktop.DBus.GetConnectionUnixProcessID "$unique" 2>/dev/null)" || return 1
  pid="${pid#(uint32 }"; pid="${pid%,)}"
  printf '%s\n' "$pid"
}

owner=""
for _ in $(seq 1 "$OWN_TIMEOUT"); do
  kill -0 "$SVC_PID" 2>/dev/null || die "the rauc service exited before it took $BUS_NAME"
  # Spelled as an `if` rather than an `&&` chain on purpose: under `set -e` the exemption for a
  # failing member of a && list depends on which member it is, and this loop is not the place to
  # be relying on that reading.
  if owner="$(own_pid)" && [ -n "$owner" ]; then break; fi
  owner=""
  sleep 1
done
[ -n "$owner" ] || die "nothing owns $BUS_NAME after ${OWN_TIMEOUT}s -- the rauc service never came up"
[ "$owner" = "$SVC_PID" ] \
  || die "$BUS_NAME is owned by pid $owner, not our service ($SVC_PID) -- refusing to install through a service whose config we do not know"
log "service $SVC_PID owns $BUS_NAME with $CONF"

# --- the install --------------------------------------------------------------------------------
# No -c here, and that is not an oversight: with the service enabled the install subcommand is a
# thin D-Bus client and its own --conf is compiled out. The config that matters is the service's,
# asserted above. Passing -c anyway would read as if it did something.
log "installing $BUNDLE into $TARGET_DEV"
"$RAUC" install "$BUNDLE" || die "rauc install failed"
log "installed"
