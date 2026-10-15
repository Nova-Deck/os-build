#!/usr/bin/env bash
# Offline check for the CPU-affinity generator
# (rootfs/overlay/usr/lib/systemd/system-generators/novadeck-cpu-affinity).
#
#   tests/test-cpu-affinity.sh
#
# WHY THIS EXISTS. The generator turns a core layout into CPU numbers at boot, and every way it can
# go wrong is silent: a wrong cluster pick still writes a valid CPUAffinity=, and a topology it does
# not understand writes nothing. So this drives the REAL generator against fabricated sysfs trees
# (today's three SoCs, plus layouts we do not ship yet) and asserts on the drop-ins it writes.
# Capacities are the post-cpufreq values (dmips rescaled by max frequency), which is what the
# generator sees at boot.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/rootfs/overlay/usr/lib/systemd/system-generators/novadeck-cpu-affinity"
CONF="$ROOT/rootfs/overlay/usr/lib/novadeck/cpu-affinity.conf"
[[ -x $GEN ]] || { echo "generator missing or not executable: $GEN" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

# topo <name> <online> <cpu:cap>...  -> fabricated /sys/devices/system/cpu
topo() {
  local d="$TMP/$1/sys"; shift
  mkdir -p "$d"; echo "$1" >"$d/online"; shift
  local pair
  for pair in "$@"; do
    mkdir -p "$d/cpu${pair%%:*}"
    echo "${pair#*:}" >"$d/cpu${pair%%:*}/cpu_capacity"
  done
}
# run <name> [conf]  -> generator output dir
run() {
  local out="$TMP/$1/out"; mkdir -p "$out"
  NOVADECK_SYS_CPU="$TMP/$1/sys" NOVADECK_CPU_AFFINITY_CONF="${2:-$CONF}" \
    sh "$GEN" "$out" 2>"$TMP/$1/stderr"
  echo $? >"$TMP/$1/rc"
}
aff() { sed -n 's/^CPUAffinity=//p' "$TMP/$1/out/$2.d/50-novadeck-cpus.conf" 2>/dev/null; }

echo "== today's SoCs"
topo sm8250 0-7 0:250 1:250 2:250 3:250 4:782 5:782 6:782 7:1024
run sm8250
check "SM8250 background = the four A55"           "$(aff sm8250 novadeck-powerd.service)" "0 1 2 3"
check "SM8250 interactive = all but the prime A77" "$(aff sm8250 inputplumber.service)"    "0 1 2 3 4 5 6"

topo sm8550 0-7 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
run sm8550
check "SM8550 background = the three A510"         "$(aff sm8550 novadeck-vpower.service)" "0 1 2"
check "SM8550 interactive: two mid levels kept"    "$(aff sm8550 plugin_loader.service)"   "0 1 2 3 4 5 6"

topo sm8650 0-7 0:286 1:286 2:839 3:839 4:839 5:870 6:870 7:1024
run sm8650
check "SM8650 background = the two A520 only"      "$(aff sm8650 novadeck-pairingd.service)" "0 1"
check "SM8650 interactive = all but the X4"        "$(aff sm8650 novadeck-steamos-manager.service)" "0 1 2 3 4 5 6"

echo "== every listed unit gets a drop-in, with its class named"
n_conf=$(grep -cE '^[a-z].*\.service[[:space:]]+(interactive|background)' "$CONF")
n_out=$(find "$TMP/sm8650/out" -name 50-novadeck-cpus.conf | wc -l)
check "one drop-in per cpu-affinity.conf line" "$n_out" "$n_conf"
check "drop-in names its class" \
  "$(grep -c 'class background' "$TMP/sm8650/out/novadeck-powerd.service.d/50-novadeck-cpus.conf")" "1"
check "drop-in is a [Service] section" \
  "$(sed -n 2p "$TMP/sm8650/out/inputplumber.service.d/50-novadeck-cpus.conf")" "[Service]"

echo "== layouts we do not ship yet"
topo twoprime 0-7 0:300 1:300 2:300 3:300 4:800 5:800 6:1024 7:1024
run twoprime
check "two prime cores: interactive drops both"    "$(aff twoprime inputplumber.service)"    "0 1 2 3 4 5"
check "two prime cores: background = little four" "$(aff twoprime novadeck-powerd.service)" "0 1 2 3"

topo twocluster 0-5 0:400 1:400 2:400 3:400 4:1024 5:1024
run twocluster
check "big.LITTLE: interactive = the little cluster" "$(aff twocluster inputplumber.service)" "0 1 2 3"
check "big.LITTLE: background = the little cluster"  "$(aff twocluster novadeck-powerd.service)" "0 1 2 3"

topo cpu0big 0-3 0:1024 1:300 2:300 3:700
run cpu0big
check "cpu0 joins background even when it is not little" "$(aff cpu0big novadeck-powerd.service)" "0 1 2"
check "cpu0 joins interactive even when it is prime"    "$(aff cpu0big inputplumber.service)"    "0 1 2 3"

topo hotplug 0-3,5-7 0:250 1:250 2:250 3:250 5:782 6:782 7:1024
run hotplug
check "offline CPU (cpu4) is not listed"           "$(aff hotplug inputplumber.service)" "0 1 2 3 5 6"

echo "== nothing to decide: write nothing, every service keeps every CPU"
topo uniform 0-3 0:1024 1:1024 2:1024 3:1024
run uniform
check "uniform capacity writes no drop-in" "$(find "$TMP/uniform/out" -type f | wc -l)" "0"
check "uniform capacity exits 0"           "$(cat "$TMP/uniform/rc")" "0"

topo nocap 0-3
run nocap
check "no cpu_capacity writes no drop-in"  "$(find "$TMP/nocap/out" -type f | wc -l)" "0"

topo partial 0-3 0:300 1:300 2:800
run partial
check "a CPU missing cpu_capacity writes no drop-in" "$(find "$TMP/partial/out" -type f | wc -l)" "0"

echo "== bad config lines are skipped, never fatal"
printf '%s\n' '# comment' '' 'inputplumber.service interactive' 'foo.service turbo' \
  'bar.slice background' 'novadeck-powerd.service background' >"$TMP/bad.conf"
topo badconf 0-7 0:286 1:286 2:839 3:839 4:839 5:870 6:870 7:1024
run badconf "$TMP/bad.conf"
check "generator still exits 0"            "$(cat "$TMP/badconf/rc")" "0"
check "good lines still written"           "$(find "$TMP/badconf/out" -type f | wc -l)" "2"
check "unknown class is reported"          "$(grep -c "unknown class 'turbo'" "$TMP/badconf/stderr")" "1"
check "non-service unit is reported"       "$(grep -c "'bar.slice' is not a .service" "$TMP/badconf/stderr")" "1"

echo
echo "test-cpu-affinity.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
