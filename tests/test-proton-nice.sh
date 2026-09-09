#!/usr/bin/env bash
# Offline check for the Proton niceness ceiling, rootfs/overlay/etc/security/limits.d/.
#
#   tests/test-proton-nice.sh
#
# WHY THIS FILE EXISTS. Proton maps a game's Windows thread base-priority classes onto Linux
# niceness with setpriority(2), per thread, from inside the game process. An unprivileged process
# cannot lower its nice at all by default, so without a limits drop-in every one of those calls
# fails EACCES and every game thread runs at nice 0 — and NOTHING SAYS SO. There is no log line, no
# degraded mode, no symptom you could name; the game merely does not get the scheduling it was
# written to expect, forever, on hardware, silently.
#
# That is not a hypothetical failure. SteamOS shipped this exact file to /etc/limits.d — the same
# name, one directory off — in November 2022, and pam_limits reads only /etc/security/limits.d, so
# the feature was inert until they moved it in August 2026. Three years and nine months of a config
# file that existed, was correct, was installed, and did nothing. The number in the file is not
# what needs guarding; the PATH is, and after it the fact that pam_limits runs at all.
#
# So this suite asks the three questions no device test can ask in time: is the drop-in on the only
# path pam_limits reads, does our PAM stack still pull pam_limits in, and does the line parse into
# the four fields pam_limits wants (it skips malformed lines in silence, which is the same failure
# wearing the same face).
#
# Runs on the host: it is a config file, no root, no bus, no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/rootfs/overlay"
CONF="$OVERLAY/etc/security/limits.d/15-proton-nice.conf"
PAMFILE="$OVERLAY/etc/pam.d/sddm-autologin"

# PipeWire asks module-rt for nice.level -11 (upstream pipewire.conf default; rootfs/customize-base.sh
# covers why rtkit has to be on the bus before that request means anything). Our ceiling has to stay
# NUMERICALLY ABOVE it — a game thread that outranks the audio graph is the one regression a bigger
# number would buy. -20 is the kernel's floor and 0 is "this file does nothing".
PIPEWIRE_NICE=-11
NICE_FLOOR=-20

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$CONF" ] || { echo "missing: $CONF" >&2; exit 1; }

# 1. THE PATH. pam_limits opens /etc/security/limits.conf and /etc/security/limits.d/*.conf and
# nothing else. Assert the full tail of the directory chain rather than just the leaf, because
# "limits.d" alone is satisfied by the broken /etc/limits.d that cost SteamOS four years.
rel="${CONF#"$OVERLAY"/}"
case "$rel" in
  etc/security/limits.d/*.conf)
    ok "drop-in is at etc/security/limits.d/ — the only directory pam_limits opens" ;;
  *)
    bad "drop-in is at $rel: pam_limits reads etc/security/limits.d/ and will never open this" ;;
esac

# The decoy, asserted as absent. A file here looks right in a diff, greps right, reviews right, and
# is read by nothing at all.
if [ -e "$OVERLAY/etc/limits.d" ]; then
  bad "etc/limits.d exists in the overlay: nothing reads it — this is the SteamOS 2022-2026 bug"
else
  ok "no etc/limits.d decoy in the overlay"
fi

# 2. PAM. The drop-in is inert unless something in the session's stack runs pam_limits, and on this
# image the only login is SDDM autologin. Its session phase includes system-login, which is what
# carries pam_limits.so. Rewrite that file without the include and this whole feature goes quiet.
if [ ! -f "$PAMFILE" ]; then
  bad "missing $PAMFILE: nothing establishes the session that would apply this limit"
elif grep -qE '^session[[:space:]]+include[[:space:]]+system-login[[:space:]]*$' "$PAMFILE"; then
  ok "sddm-autologin session includes system-login — pam_limits runs, so the drop-in applies"
else
  bad "sddm-autologin no longer includes system-login in its session phase: pam_limits never runs"
fi

# 3. THE LINE. pam_limits wants exactly <domain> <type> <item> <value> and SKIPS anything it cannot
# parse without a word of complaint, so a typo here is indistinguishable from the file being absent.
# Take the last effective line, the way pam_limits' last-match-wins would.
line="$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | tail -1)"
if [ -z "$line" ]; then
  bad "no effective line in $(basename "$CONF"): the file is all comment and grants nothing"
else
  read -r domain type item value _rest <<<"$line"

  [ "$domain" = "*" ] \
    && ok "domain is * — applies to the session user whatever it is called" \
    || bad "domain is '${domain}': the Steam session user must be covered, use *"

  [ "$type" = "hard" ] \
    && ok "type is hard — raises the ceiling a process may lift its own soft limit to" \
    || bad "type is '${type}': expected hard (a soft-only grant cannot exceed a hard 0)"

  [ "$item" = "nice" ] \
    && ok "item is nice — the RLIMIT_NICE ceiling setpriority(2) is checked against" \
    || bad "item is '${item}': expected nice"

  if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
    bad "value '${value}' is not an integer: pam_limits skips the line and grants nothing"
  elif [ "$value" -ge 0 ]; then
    bad "value ${value} is not negative: the ceiling stays at the default and Proton still fails"
  elif [ "$value" -lt "$NICE_FLOOR" ]; then
    bad "value ${value} is below the kernel's -20 floor"
  elif [ "$value" -le "$PIPEWIRE_NICE" ]; then
    bad "value ${value} reaches PipeWire's nice.level ${PIPEWIRE_NICE}: a game thread could outrank the audio graph"
  else
    ok "value ${value} — negative enough to matter, above PipeWire's ${PIPEWIRE_NICE}"
  fi

  [ -z "${_rest:-}" ] \
    && ok "line is exactly four fields, the shape pam_limits parses" \
    || bad "trailing text '${_rest}' after the value: pam_limits has no comment syntax mid-line"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
