#!/usr/bin/env bash
# Offline check for the per-board runtime quirks helper.
#
#   tests/test-device-quirks.sh
#
# WHY THIS EXISTS. A quirk is a write to a sysfs knob that nothing else reads back, applied on a
# board most builds never run on. Every failure mode is silent: the knob moves to a new path, the
# idle-state numbering shifts, device-env stops reporting the SoC — and the script still exits 0
# and still logs nothing alarming. The workaround is simply gone, and the symptom it prevented
# comes back looking like a fresh hardware bug.
#
# So this drives the REAL rootfs/overlay/usr/lib/novadeck/device-quirks against a fabricated sysfs
# tree and a fabricated device-env, and asserts on the knob's contents afterwards rather than on
# the script's exit status. It also asserts the negatives: a non-SM8550 board must not touch the
# knob, and a renamed idle state must be reported, not skipped in silence.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIRKS="$ROOT/rootfs/overlay/usr/lib/novadeck/device-quirks"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

[[ -x $QUIRKS ]] || { echo "device-quirks is missing or not executable: $QUIRKS" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A fake cpu0 with the two idle states the SM8550 devicetree declares: the generic WFI the PSCI
# driver adds as state0, then the DT state whose idle-state-name lands in sysfs as `desc`.
make_sysfs() {
    local desc=$1 dir="$TMP/sys/devices/system/cpu/cpu0/cpuidle"
    rm -rf "$TMP/sys"; mkdir -p "$dir/state0" "$dir/state1"
    printf 'WFI\n'     >"$dir/state0/desc"; printf '0\n' >"$dir/state0/disable"
    printf '%s\n' "$desc" >"$dir/state1/desc"; printf '0\n' >"$dir/state1/disable"
}

make_env() {  # make_env <soc-class> [device-id]
    local env="$TMP/device-env"
    { printf '#!/bin/bash\n'
      printf 'echo NOVADECK_SOC_CLASS=%s\n' "${1:-}"
      printf 'echo NOVADECK_DEVICE_ID=%s\n' "${2:-ayaneo-pocket-ace}"
    } >"$env"
    chmod 755 "$env"
    printf '%s' "$env"
}

run() {  # run <device-env> [skip-list] -> stderr on stdout
    local env=$1 conf="$TMP/quirks.conf"
    if [[ -n ${2:-} ]]; then printf 'NOVADECK_SKIP_QUIRKS=%q\n' "$2" >"$conf"; else : >"$conf"; fi
    NOVADECK_DEVICE_ENV="$env" NOVADECK_QUIRKS_CONF="$conf" NOVADECK_SYSFS_ROOT="$TMP/sys" \
        bash "$QUIRKS" 2>&1
}

knob() { cat "$TMP/sys/devices/system/cpu/cpu0/cpuidle/state1/disable" 2>/dev/null; }

echo "device-quirks:"

# 1. The case that matters: SM8550 disables the silver-rail power-collapse state on CPU0.
make_sysfs silver-rail-power-collapse
out=$(run "$(make_env SM8550)")
check "SM8550 disables cpu0 silver-rail-power-collapse" "$(knob)" "1"
[[ $out == *"sm8550-gmu-oob-cpuidle applied"* ]] \
    && ok "SM8550 quirk reports that it applied" \
    || bad "SM8550 quirk did not report applying: $out"

# 2. It must key off the state's description, not its index — state0 is the generic WFI and
#    disabling it would be both wrong and invisible.
check "shallow WFI state left alone" \
    "$(cat "$TMP/sys/devices/system/cpu/cpu0/cpuidle/state0/disable")" "0"

# 3. A board on another SoC must not be touched by an SM8550 workaround.
make_sysfs silver-rail-power-collapse
run "$(make_env SM8650 ayn-thor)" >/dev/null
check "non-SM8550 board leaves the knob alone" "$(knob)" "0"

# 4. The renamed-state case: a kernel that renames or drops the state must produce a complaint,
#    not a silent no-op. This is the one that keeps the quirk honest across kernel bumps.
make_sysfs some-future-rail-state
out=$(run "$(make_env SM8550)")
check "renamed idle state leaves the knob alone" "$(knob)" "0"
[[ $out == *"NOT applied"* ]] \
    && ok "renamed idle state is reported, not silently skipped" \
    || bad "renamed idle state produced no complaint: $out"

# 5. The operator escape hatch actually opts out ([[devices-are-operator-reachable]]).
make_sysfs silver-rail-power-collapse
out=$(run "$(make_env SM8550)" sm8550-gmu-oob-cpuidle)
check "NOVADECK_SKIP_QUIRKS opts out" "$(knob)" "0"
[[ $out == *"skipped"* ]] && ok "opt-out is logged" || bad "opt-out was not logged: $out"

# 6. A broken device-env must not fail the boot -- and must not have its explanation swallowed.
#    Without the stderr assertion, redirecting device-env to /dev/null would still pass every
#    other check here while leaving an unbootable-looking board with no way to say what broke.
broken="$TMP/broken-env"
printf '#!/bin/bash\necho "device-env: unreadable devicetree model" >&2\nexit 1\n' >"$broken"
chmod 755 "$broken"
make_sysfs silver-rail-power-collapse
out=$(run "$broken"); rc=$?
check "broken device-env still exits 0" "$rc" "0"
check "broken device-env applies nothing" "$(knob)" "0"
[[ $out == *"unreadable devicetree model"* ]] \
    && ok "device-env's own reason survives to the journal" \
    || bad "device-env's stderr was swallowed: $out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
