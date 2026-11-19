#!/usr/bin/env bash
# Offline check for the gpu-worker placement (rootfs/overlay/usr/lib/novadeck/gpu-worker-cpus).
#
#   tests/test-gpu-worker-cpus.sh
#
# WHY THIS EXISTS. The script turns a core layout and an interrupt mask into a CPU list at boot,
# and every way it can go wrong is silent: a wrong pick still writes a valid affinity, and a layout
# it does not understand writes nothing. So this drives the REAL script against fabricated sysfs and
# procfs trees (today's four SoCs plus the edge cases) and asserts on what it would have handed to
# taskset, through a stub that records its arguments instead of touching a real thread.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/rootfs/overlay/usr/lib/novadeck/gpu-worker-cpus"
[[ -x $SCRIPT ]] || { echo "script missing or not executable: $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()    { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

STUB="$TMP/taskset"
cat >"$STUB" <<'EOF'
#!/bin/sh
echo "$*" >>"$NOVADECK_TEST_CALLS"
EOF
chmod +x "$STUB"

# world <name> <online> <irq-mask> <cpu:cap>...  -> fabricated /sys/devices/system/cpu + /proc
world() {
  local name=$1 online=$2 mask=$3; shift 3
  local sys="$TMP/$name/sys" proc="$TMP/$name/proc" pair
  mkdir -p "$sys" "$proc/irq"
  echo "$online" >"$sys/online"
  echo "$mask" >"$proc/irq/default_smp_affinity"
  for pair in "$@"; do
    mkdir -p "$sys/cpu${pair%%:*}"
    echo "${pair#*:}" >"$sys/cpu${pair%%:*}/cpu_capacity"
  done
  : >"$TMP/$name/calls"
}
# thread <name> <pid> <comm> <allowed>  -> a fake /proc/<pid>
thread() {
  local d="$TMP/$1/proc/$2"
  mkdir -p "$d"
  echo "$3" >"$d/comm"
  printf 'Name:\t%s\nCpus_allowed_list:\t%s\n' "$3" "$4" >"$d/status"
}
# run <name> [tries] [delay]
run() {
  NOVADECK_SYS_CPU="$TMP/$1/sys" NOVADECK_PROC="$TMP/$1/proc" NOVADECK_TASKSET="$STUB" \
  NOVADECK_TEST_CALLS="$TMP/$1/calls" \
  NOVADECK_GPU_WORKER_TRIES="${2:-1}" NOVADECK_GPU_WORKER_DELAY="${3:-0}" \
    "$SCRIPT" 2>"$TMP/$1/stderr"
  echo $? >"$TMP/$1/rc"
}
calls() { cat "$TMP/$1/calls"; }
rc()    { cat "$TMP/$1/rc"; }

echo "== today's SoCs"
world sm8550 0-7 07 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
thread sm8550 168 gpu-worker 0-7
run sm8550
check "SM8550 (irqaffinity=0-2): big cores without the prime" "$(calls sm8550)" "-pc 3-6 168"

world sm8650 0-7 03 0:286 1:286 2:839 3:839 4:839 5:870 6:870 7:1024
thread sm8650 170 gpu-worker 0-7
run sm8650
check "SM8650 (irqaffinity=0-1): the A720s, prime excluded"  "$(calls sm8650)" "-pc 2-6 170"

world sm8750 0-7 03 0:836 1:836 2:836 3:836 4:836 5:836 6:1024 7:1024
thread sm8750 168 gpu-worker 0-7
run sm8750
check "SM8750 (irqaffinity=0-1): Oryon M cores 2-5"         "$(calls sm8750)" "-pc 2-5 168"

world sm8250 0-7 ff 0:250 1:250 2:250 3:250 4:782 5:782 6:782 7:1024
thread sm8250 150 gpu-worker 0-7
run sm8250
check "SM8250 (no irqaffinity): left alone"                 "$(calls sm8250)" ""
check "SM8250: exits 0"                                     "$(rc sm8250)" "0"

echo "== behaviour"
world placed 0-7 07 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
thread placed 168 gpu-worker 3-6
run placed
check "already on its cores: no write"                      "$(calls placed)" ""

world missing 0-7 07 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
thread missing 99 kworker/0:1 0-7
run missing 3 0
check "no gpu-worker thread: no write"                      "$(calls missing)" ""
check "no gpu-worker thread: exits 0, never fails the boot" "$(rc missing)" "0"
grep -q 'gpu-worker' "$TMP/missing/stderr" && ok "no gpu-worker thread: says so" \
  || bad "no gpu-worker thread: says so (stderr: $(cat "$TMP/missing/stderr"))"

world late 0-7 07 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
( sleep 1.5; thread late 171 gpu-worker 0-7 ) &
run late 5 1
wait
check "GPU bound late: found on a retry"                    "$(calls late)" "-pc 3-6 171"

world symmetric 0-7 03 0:1024 1:1024 2:1024 3:1024 4:1024 5:1024 6:1024 7:1024
thread symmetric 168 gpu-worker 0-7
run symmetric
check "equal capacities: every online CPU but the IRQ ones" "$(calls symmetric)" "-pc 2-7 168"

world nocap 0-7 07
thread nocap 168 gpu-worker 0-7
run nocap
check "no cpu_capacity at all: every online CPU but the IRQ ones" "$(calls nocap)" "-pc 3-7 168"

world words 0-7 00000000,00000007 0:283 1:283 2:283 3:700 4:700 5:690 6:690 7:1024
thread words 168 gpu-worker 0-7
run words
check "comma-grouped mask is read as one number"            "$(calls words)" "-pc 3-6 168"

world allirq 0-7 07 0:283 1:283 2:283 3:1024 4:1024 5:1024 6:1024 7:1024
thread allirq 168 gpu-worker 0-7
run allirq
check "IRQ cores cover every candidate: left alone"         "$(calls allirq)" ""

echo "test-gpu-worker-cpus.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
