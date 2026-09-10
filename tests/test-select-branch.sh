#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-select-branch — the Steam client's OS Update Channel picker.
#
#   tests/test-select-branch.sh
#
# WHY THIS FILE EXISTS, and it is the same reason as test-update.sh: the caller is the Steam client
# and NOT ONE PART of this contract is ours to choose. It was read out of the baked seed's
# steamclient.so — not steamui.so, which carries only the error string, and that distinction cost
# issue #89 a wrong premise for a release cycle. Three jobs, and they do not share a path:
#
#   CSystemManagerGetOSBranchListJob      steamos-select-branch -l
#   CSystemManagerGetCurrentOSBranchJob   steamos-select-branch -c
#   CSystemManagerSelectOSBranchJob       /usr/bin/steamos-polkit-helpers/steamos-select-branch %s
#
# THE TOKEN SET IS THE PART MOST LIKELY TO ROT SILENTLY. The client validates the -l output against
# the EOSBranch enum — rel rc beta bc preview pc main staging, EIGHT, and reading the strings next
# to CSystemManagerGetOSBranchListJob instead gives seven and drops `staging`. Our channels are
# called `stable` and `beta`, so `stable` is not sayable in a LIST. If someone later "simplifies" the mapping away and
# returns our own channel names, the client's answer is not an error the user sees: it is
# "Command '%s' returned more than %zu known branch names" in a log nobody reads, and a dropdown
# that is empty or missing. That is precisely the failure mode #89 spent a cycle on, so the token
# vocabulary is asserted here as a literal.
#
# The dev-card refusal is the other load-bearing case. /etc/novadeck/ota.conf outranks the file the
# picker writes, so a card that accepted the write would show the user a channel it was not using.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$ROOT/rootfs/overlay/usr/bin/novadeck-select-branch"
UP="$ROOT/rootfs/overlay/usr/bin/novadeck-update"
LINK="$ROOT/rootfs/overlay/usr/bin/steamos-select-branch"
HELPER="$ROOT/rootfs/overlay/usr/bin/steamos-polkit-helpers/steamos-select-branch"
[ -f "$SB" ] || { echo "no novadeck-select-branch: $SB" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
# Same reason as test-update.sh: a __pycache__ under rootfs/overlay/usr/bin would be copied into
# the rootfs verbatim by the assembler.
export PYTHONPYCACHEPREFIX="$W/pycache"

export NOVADECK_UPDATE_BIN="$UP"
export NOVADECK_OTA_USER_CONFIG="$W/user-ota.conf"
export NOVADECK_OTA_CONFIG="$W/etc-ota.conf"
export NOVADECK_RELEASE_FILE="$W/novadeck-release"
: > "$NOVADECK_RELEASE_FILE"

# stdout only, and the exit code separately: the client reads one and branches on the other.
sb() { "$SB" "$@" 2>/dev/null; }
user_channel() { sed -n 's/^OTA_CHANNEL=//p' "$NOVADECK_OTA_USER_CONFIG" 2>/dev/null; }
reset_state() { rm -f "$NOVADECK_OTA_USER_CONFIG" "$NOVADECK_OTA_CONFIG"; }

# =================================================================================================
CASE="the two entry points the client actually calls"
# Both must exist, because the client asks for the list and the selection in DIFFERENT places. A
# single file in either location leaves half the picker dead, and the dead half is invisible: the
# dropdown populates and the selection silently does nothing, or the reverse.
[ -L "$LINK" ] && ok "/usr/bin/steamos-select-branch is present (the -l and -c path)" \
  || bad "no /usr/bin/steamos-select-branch — GetOSBranchList and GetCurrentOSBranch call the bare name off PATH"
[ "$(readlink "$LINK")" = "novadeck-select-branch" ] \
  && ok "and points at the implementation" \
  || bad "the symlink does not resolve to novadeck-select-branch"
[ -x "$HELPER" ] && ok "steamos-polkit-helpers/steamos-select-branch is present (the write path)" \
  || bad "no polkit-helpers entry — CSystemManagerSelectOSBranchJob calls that ABSOLUTE path and nothing else"
grep -q 'exec /usr/bin/novadeck-select-branch' "$HELPER" \
  && ok "and hands off to the same implementation" \
  || bad "the helper does not exec novadeck-select-branch — the two paths would drift"
# THE LOGGING LIVES IN THE IMPLEMENTATION, NOT THE WRAPPER, and the placement is the assertion.
# A logger call in the wrapper covers the write path only, because -l and -c reach the
# implementation through the /usr/bin symlink and never run the wrapper — which is why
# `journalctl -t steamos-select-branch` came back EMPTY on a device whose dropdown was populated
# (2026-09-10). The two calls the picker depends on were the invisible ones.
grep -q 'logger' "$SB" \
  && ok "the implementation logs every invocation, so -l and -c are visible too" \
  || bad "novadeck-select-branch does not log — the read paths leave no trace, which is the hole #89 could not see into"
grep -q '^logger' "$HELPER" \
  && bad "the wrapper logs as well — the write path would produce duplicate journal lines" \
  || ok "and the wrapper does not log again (one line per invocation)"

# =================================================================================================
CASE="-l, the branch list"
reset_state
mapfile -t tokens < <(sb -l)
# THE LIST IS STATE-DEPENDENT, and that is forced by two client rules pulling opposite ways.
#
#   be() keeps an entry only if `(current || !advanced || advancedMode)`, and Bv() counts exactly
#   Release, Beta and Preview as not-advanced. Our `Stable` is an UNKNOWN branch, so it qualifies
#   ONLY while current — which is why selecting Beta made Stable vanish and left no way back
#   (HW, 2026-09-10). A permanently visible Stable entry therefore has to be a real, non-advanced
#   branch: `rel`.
#
#   But reporting `rel` as the CURRENT branch pairs with our stable Steam client and swaps the
#   whole OS row for the combined `System Update Channel`.
#
# Pairing reads -c only, never the list. So `rel` is listed exactly when we are NOT on it.
[ "${tokens[*]}" = "beta" ] \
  && ok "on stable, -l offers only [beta] — the current branch supplies the Stable entry itself" \
  || bad "on stable the list is [${tokens[*]}], not [beta]; listing 'rel' here duplicates the appended current"
[ "$(sb -c)" = "Stable" ] && ok "and -c is 'Stable', an unknown branch, so nothing pairs" \
  || bad "-c is [$(sb -c)] on stable"

printf 'OTA_CHANNEL=beta\n' > "$NOVADECK_OTA_USER_CONFIG"
mapfile -t tokens < <(sb -l)
[ "${tokens[*]}" = "rel beta" ] \
  && ok "on beta, -l adds 'rel' so a NON-ADVANCED Stable entry stays listed and is selectable" \
  || bad "on beta the list is [${tokens[*]}], not [rel beta] — without 'rel' there is no way back to stable"
# The whole point: the way home must exist while we are away from it.
printf '%s\n' "${tokens[@]}" | grep -qx rel \
  && ok "and that entry is a real EOSBranch branch, so it survives the advanced filter" \
  || bad "the Stable entry is not 'rel' — an unknown branch is filtered out unless it is current"
reset_state

CASE="-c, the current branch"
reset_state
# `stable`, NOT `rel`, and this is the assertion the whole feature hangs on.
#
# SteamUI renders EITHER a combined `System Update Channel` (which also moves the Steam CLIENT's
# branch) OR a dedicated `OS Update Channel`, never both — `d && <combined/>` against
# `!d && <os-only/>`, where `d = currentCombinedChannel && !showAdvanced`. That combined channel
# resolves for exactly two pairings: OS Release + client Stable, or OS Beta + client on beta.
#
# We ship a STABLE client, so answering `rel` here lands on the first pairing and the OS row is
# replaced by the conflated control. It is also simply untrue: a NovaDeck release on our `stable`
# channel is not SteamOS Release. `stable` is outside EOSBranch, parses as Unknown, matches neither
# pairing, and leaves the dedicated row on screen.
[ "$(sb -c)" = "Stable" ] \
  && ok "a stock release device reports 'Stable' — our channel name, not a SteamOS branch" \
  || bad "-c is [$(sb -c)], not Stable — reporting 'rel' pairs with the stable client and hides the OS row behind the combined control"
# Non-empty is a contract, not a nicety: the client's failure string for this job is
# "Command '%s' returned an empty string".
[ -n "$(sb -c)" ] && ok "and is never empty (the client rejects an empty answer)" || bad "-c returned nothing"

# =================================================================================================
CASE="selection round-trips"
reset_state
sb beta >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "selecting 'beta' succeeds" || bad "selecting beta exited $rc"
[ "$(user_channel)" = "beta" ] && ok "and writes OTA_CHANNEL=beta to the user file" || bad "the user file says [$(user_channel)]"
[ "$(sb -c)" = "beta" ] && ok "and -c reports it back" || bad "-c does not reflect the selection"
sb rel >/dev/null
[ "$(user_channel)" = "stable" ] && ok "'rel' maps back to our 'stable'" || bad "rel did not map to stable"
# The LIST still says `rel` (that is the token whose label reads "Stable"), but -c reports our own
# channel name. The two answer different questions and only the list has to be a client token.
[ "$(sb -c)" = "Stable" ] && ok "and -c round-trips to 'Stable'" || bad "-c does not round-trip"

# =================================================================================================
CASE="the file is the SAME one a human writes over SSH"
# THE WHOLE POINT of writing here rather than inventing a state file: on a release device this is
# the only channel source reachable at all (no sudo, root's authorized_keys never written), so the
# picker and the documented SSH override are one setting rather than two that disagree.
reset_state
printf 'OTA_CHANNEL=beta\n' > "$NOVADECK_OTA_USER_CONFIG"
[ "$(sb -c)" = "beta" ] && ok "a hand-written file is picked up by -c" || bad "-c ignores a hand-written channel"
# And the picker must not turn that file into a pile of superseded assignments.
sb rel >/dev/null; sb beta >/dev/null; sb rel >/dev/null
n=$(grep -c '^OTA_CHANNEL=' "$NOVADECK_OTA_USER_CONFIG")
[ "$n" -eq 1 ] && ok "and repeated selections REWRITE it — exactly one assignment survives" \
  || bad "the file has $n OTA_CHANNEL assignments — it is being appended to"

# =================================================================================================
CASE="every token the client owns maps somewhere"
# The client may hand back any of its seven. An "unknown OS branch" on a name IT owns would be our
# bug, and it surfaces to the user as a failed selection with no explanation.
reset_state
for t in rel rc beta bc preview pc main; do
  sb "$t" >/dev/null || bad "token '$t' was refused — the client owns it and may send it"
done
ok "all seven of rel/rc/beta/bc/preview/pc/main are accepted"
# And nothing else is. `stable` is refused HERE on purpose even though it is our own channel name:
# it is not a token, so the only way it arrives is a caller that is confused about which vocabulary
# it is speaking.
sb bogus >/dev/null && bad "an unknown token was accepted" || ok "an unknown token is refused (exit non-zero)"
# Our own names must come BACK too: the client hands back what it was given, so a selection
# arrives as `Stable`/`Beta`, not as a token. Case-insensitively, since the raw name is ours.
sb Stable >/dev/null && ok "our own name 'Stable' is accepted back (that is what the client returns)" \
  || bad "'Stable' was refused — the client hands back the raw name it was given, so selection would fail"
sb stable >/dev/null && ok "and matching is case-insensitive" || bad "lowercase 'stable' was refused"

# =================================================================================================
CASE="DEV CARD: the /etc pin outranks the picker, so the picker refuses"
reset_state
printf 'OTA_CHANNEL=dev\n' > "$NOVADECK_OTA_CONFIG"
# -c must tell the truth about what is in force. `dev` has no token of its own; `main` is the
# client's name for the least-baked branch, which is what a pinned dev card is.
# An unoffered channel answers with its OWN name too, capitalised so it does not appear in the
# dropdown as a lowercase oddity beside the properly cased entries.
[ "$(sb -c)" = "Dev" ] && ok "-c reports the pinned channel as 'Dev' rather than lying about it" \
  || bad "-c is [$(sb -c)] on a pinned dev card"
before="$(user_channel)"
sb beta >/dev/null && bad "the picker accepted a write that /etc outranks — the UI would show beta while the device checked dev" \
  || ok "selecting a channel FAILS loudly (non-zero) instead of silently doing nothing"
[ "$(user_channel)" = "$before" ] && ok "and the user file is left untouched" || bad "the user file was written despite the refusal"
# The list is still offered: the dropdown is not the thing that is wrong on a dev card.
# A pinned card is not on `stable`, so `rel` is listed and both channels stay reachable in the UI
# — the write is what refuses, not the list.
[ "$(sb -l | tr '\n' ' ')" = "rel beta " ] && ok "and -l still lists both channels" || bad "-l is [$(sb -l | tr '\n' ' ')] on a dev card"

# =================================================================================================
CASE="fail CLOSED when the channel cannot be read"
reset_state
# An exception here would reach the client as a command failure and empty the dropdown. Falling
# back to the built-in default is the same answer novadeck-update would give.
out="$(NOVADECK_UPDATE_BIN=/nonexistent-on-purpose sb -c)"
[ "$out" = "Stable" ] && ok "-c falls back to the built-in default instead of erroring" || bad "-c returned [$out] when novadeck-update was unreachable"

# =================================================================================================
CASE="novadeck-update owns the precedence, and still says so"
reset_state
# ONE place decides the order. If this subcommand goes away or changes shape, the picker starts
# guessing — and its guess and the fetch would disagree exactly on the dev card above.
printf 'OTA_CHANNEL=dev\n' > "$NOVADECK_OTA_CONFIG"
line="$("$UP" channel)"
[ "$(printf '%s' "$line" | cut -f1)" = "dev" ] \
  && ok "novadeck-update channel reports the winning channel" || bad "novadeck-update channel said [$line]"
[ "$(printf '%s' "$line" | cut -f2)" = "$NOVADECK_OTA_CONFIG" ] \
  && ok "and names the source that supplied it" || bad "the source field is [$(printf '%s' "$line" | cut -f2)]"
printf '%s' "$line" | grep -q $'\t' && ok "tab-separated, so a source with spaces stays parseable" \
  || bad "the two fields are not tab-separated"

# =================================================================================================
printf '\ntest-select-branch.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
