#!/usr/bin/env bash
# Offline check for the power-button LED writer.
#
#   tests/test-power-led.sh
#
# WHY THIS EXISTS. This script's whole job is two sysfs writes on a device nothing reads back, and
# every way it can break is silent. The LED node gets renamed and the script logs a tidy "no
# power-led on this board" on hardware that has one. The driver reorders multi_index and a
# positional write lights red instead of green — still exit 0, still a lit LED, just the colour
# that means "fault" on every other handheld. multi_max_intensity moves off 511 and the mix scales
# to a quarter of what was asked for, which reads as a failing LED rather than a wrong constant.
#
# So this drives the REAL rootfs/overlay/usr/lib/novadeck/power-led against a fabricated
# /sys/class/leds tree and asserts on the ATTRIBUTE CONTENTS afterwards, never on exit status —
# the script exits 0 on every path by design, including the ones where it did nothing.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEDSCRIPT="$ROOT/rootfs/overlay/usr/lib/novadeck/power-led"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

[[ -x $LEDSCRIPT ]] || { echo "power-led is missing or not executable: $LEDSCRIPT" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A fake power-led matching the Pocket S2's real geometry: an LPG multicolor device with a 511-step
# master scale and a 511-step maximum on each channel. `order` lets a case shuffle multi_index to
# prove the script places colours by NAME rather than by position.
make_led() {  # make_led [order] [max_brightness] [chan_max]
    local order=${1:-"red green blue"} maxb=${2:-511} cmax=${3:-"511 511 511"}
    local d="$TMP/sys/class/leds/power-led"
    rm -rf "$TMP/sys"; mkdir -p "$d"
    printf '%s\n' "$order" >"$d/multi_index"
    printf '%s\n' "$cmax"  >"$d/multi_max_intensity"
    printf '%s\n' "$maxb"  >"$d/max_brightness"
    printf '0 0 0\n'       >"$d/multi_intensity"
    printf '0\n'           >"$d/brightness"
}

# A board with no power_led node at all — every sm8250 handheld.
make_no_led() { rm -rf "$TMP/sys"; mkdir -p "$TMP/sys/class/leds"; }

run() {  # run [conf-lines...] -> stderr on stdout
    local conf="$TMP/power-led.conf"
    : >"$conf"
    for line in "$@"; do printf '%s\n' "$line" >>"$conf"; done
    NOVADECK_SYSFS_ROOT="$TMP/sys" NOVADECK_POWER_LED_CONF="$conf" bash "$LEDSCRIPT" 2>&1
}

mi() { cat "$TMP/sys/class/leds/power-led/multi_intensity" 2>/dev/null; }
br() { cat "$TMP/sys/class/leds/power-led/brightness" 2>/dev/null; }

echo "power-led:"

# --- the default: green, at a quarter of the master scale, mix at each channel's own maximum.
make_led
out=$(run)
check "default lights green"                 "$(mi)" "0 511 0"
check "default is quarter brightness"        "$(br)" "127"
[[ $out == *applied* ]] && ok "default logs that it applied" \
                        || bad "default logs that it applied (got: $out)"

# --- placement is by channel NAME. A driver that reorders multi_index must not silently swap the
# colour; this is the case that would light red on a green request.
make_led "blue green red"
run >/dev/null
check "shuffled multi_index still lights green" "$(mi)" "0 511 0"

# --- the mix scales to the hardware maximum, not to the 0-255 the colour is written in.
make_led "red green blue" 255 "255 255 255"
run >/dev/null
check "255-step channel scales down"         "$(mi)" "0 255 0"
check "255-step master quarters"             "$(br)" "63"

# --- absent node: write nothing, and SAY so. A board with no LED must not look like a failure, and
# must not look like a success either.
make_no_led
out=$(run)
[[ $out == *"no power-led on this board"* ]] && ok "absent node is reported" \
                                             || bad "absent node is reported (got: $out)"

# --- operator overrides.
make_led
run "NOVADECK_POWER_LED=off" >/dev/null
check "NOVADECK_POWER_LED=off leaves it dark" "$(mi)" "0 0 0"
check "NOVADECK_POWER_LED=off leaves brightness 0" "$(br)" "0"

make_led
run "NOVADECK_POWER_LED_COLOR='255 191 0'" >/dev/null
check "custom colour is honoured"            "$(mi)" "511 382 0"

make_led
run "NOVADECK_POWER_LED_BRIGHTNESS=100" >/dev/null
check "brightness override reaches full"     "$(br)" "511"

# --- malformed overrides are refused loudly and change nothing. A typo'd colour must not land as a
# half-written mix.
make_led
out=$(run "NOVADECK_POWER_LED_COLOR='0 255'")
check "short colour writes nothing"          "$(mi)" "0 0 0"
[[ $out == *"NOT applied"* ]] && ok "short colour is reported" \
                             || bad "short colour is reported (got: $out)"

make_led
out=$(run "NOVADECK_POWER_LED_BRIGHTNESS=250")
check "out-of-range percent writes nothing"  "$(br)" "0"
[[ $out == *"NOT applied"* ]] && ok "out-of-range percent is reported" \
                              || bad "out-of-range percent is reported (got: $out)"

# --- a node that is not multicolor (mono LED, or a driver that dropped the attrs) must be skipped
# rather than half-written.
make_led
rm -f "$TMP/sys/class/leds/power-led/multi_index"
out=$(run)
check "non-multicolor node writes nothing"   "$(br)" "0"
[[ $out == *"NOT applied"* ]] && ok "non-multicolor node is reported" \
                              || bad "non-multicolor node is reported (got: $out)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
