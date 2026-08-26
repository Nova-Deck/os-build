#!/usr/bin/env bash
# Offline check for the systemd-coredump limits, rootfs/overlay/etc/systemd/coredump.conf.d/.
#
#   tests/test-coredump-limit.sh
#
# WHY THIS FILE EXISTS. /var/lib/systemd/coredump is an OFFLOAD path — bind-mounted from the shared
# /home tree, so it lands on the same card as the user's Steam library, root and /var. With the
# stock config systemd-coredump will read and write a crashing process's entire address space, and
# the process most likely to crash large here is steamwebhelper: healthy at 300-500 MB, but 1-2 GB
# routinely during the SteamUI freeze and once seen at 11 GB. A watchdog SIGTRAP on one of those
# dumps multi-GB onto a card the wedged UI is already stalling on, for a core nothing can symbolize.
#
# The limits are only worth anything if they are actually THERE and actually SMALL, and neither is
# visible on hardware until the day something crashes big. systemd's config parser is also quiet
# about keys it does not know, so a typo'd limit reads as protection and provides none. This asks
# the questions no device test can ask in time.
#
# Runs on the host: it is a config file, no root, no bus, no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="$ROOT/rootfs/overlay/etc/systemd/coredump.conf.d/10-novadeck-coredump-limit.conf"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$CONF" ] || { echo "missing: $CONF" >&2; exit 1; }

# systemd size suffixes -> bytes. Only the ones a sane limit uses; anything else is a failure
# rather than a silent 0, since "unparseable" is exactly how a limit stops limiting.
to_bytes() {
  local v="$1" n="${1%[KMG]}"
  case "$v" in
    *K) echo $((n * 1024)) ;;
    *M) echo $((n * 1024 * 1024)) ;;
    *G) echo $((n * 1024 * 1024 * 1024)) ;;
    *[0-9]) echo "$n" ;;
    *) echo "" ;;
  esac
}
val() { sed -n "s/^${1}=\(.*\)$/\1/p" "$CONF" | tail -1; }

if grep -qE '^\[Coredump\][[:space:]]*$' "$CONF"; then
  ok "[Coredump] section present — the keys are in a section systemd reads"
else
  bad "no [Coredump] section: every key below it is ignored"
fi

# ProcessSizeMax is the load-bearing one: it makes systemd-coredump bail BEFORE reading the core,
# so an oversized crash costs nothing instead of costing an I/O storm on the card. A limit that is
# merely present but generous would still let a runaway webhelper through.
CEIL=$((1024 * 1024 * 1024))   # 1G — above this and a runaway webhelper still gets dumped
FLOOR=$((128 * 1024 * 1024))   # 128M — below this and real crashes stop being debuggable
for key in ProcessSizeMax ExternalSizeMax MaxUse; do
  raw="$(val "$key")"
  if [ -z "$raw" ]; then
    bad "$key is not set: that limit is at systemd's default, which is a share of the whole card"
    continue
  fi
  b="$(to_bytes "$raw")"
  if [ -z "$b" ]; then
    bad "$key=$raw does not parse as a size — systemd ignores it and the limit silently vanishes"
  elif [ "$b" -gt "$CEIL" ]; then
    bad "$key=$raw exceeds 1G: a runaway steamwebhelper would still reach the card"
  elif [ "$key" != "MaxUse" ] && [ "$b" -lt "$FLOOR" ]; then
    bad "$key=$raw is under 128M: ordinary crashes stop producing anything debuggable"
  else
    ok "$key=$raw — bounded, and large enough to still capture our own daemons"
  fi
done

# Deliberately absent. KeepFree defaults to 15% of the filesystem, which SCALES with the card;
# pinning a fixed number would make the guarantee weaker on exactly the large cards that carry the
# biggest libraries. MaxUse is the binding limit, so this asserts nobody "helpfully" adds one.
if grep -qE '^KeepFree=' "$CONF"; then
  bad "KeepFree is pinned: a fixed floor is WEAKER than the default 15% on a large card"
else
  ok "KeepFree left at its default — the 15% floor scales with the card, MaxUse binds instead"
fi

# Storage=none would zero the risk and also throw away every core we DO want. The point is a
# bounded dump, not no dump.
storage="$(val Storage)"
if [ "$storage" = "external" ]; then
  ok "Storage=external — small cores are still captured, they are merely bounded"
else
  bad "Storage=${storage:-<unset>}: expected external, so our own daemons stay debuggable"
fi

# The drop-in directory name is the whole contract -- coredump.conf.d, not coredumps.conf.d or
# anything adjacent. A misnamed directory ships a file systemd never opens.
case "$(basename "$(dirname "$CONF")")" in
  coredump.conf.d) ok "drop-in sits in coredump.conf.d — systemd will actually read it" ;;
  *) bad "drop-in directory is not coredump.conf.d: systemd will never open this file" ;;
esac

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
