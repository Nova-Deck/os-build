#!/usr/bin/env bash
# Reboot a dev-card device until a boot-time reset is caught in its RAM console.
# See ../ramoops-crash-debug.md. Usage (from the repo root):
#   HOST=root@<ip> OUT=<dir> [MAX_ITER=n] docs/ramoops-crash-debug/reboot-loop.sh
#
# Slot safety: every boot that is not confirmed good bumps A.conf boot-attempts; at 3 steamcl
# stops at its (invisible) failsafe menu. So the loop never reboots until mark-good has put
# boot-attempts back to 0, and it stops as soon as it sees a reset (boot-attempts >= 2 at first
# contact = a boot before this one never got confirmed).
set -u

HOST=${HOST:?set HOST=root@<device ip>}
KEY=${KEY:-$(cd "$(dirname "$0")/../.." && pwd)/work/dev-ssh/id_ed25519}
OUT=${OUT:?set OUT=<directory for the captures>}
MAX_ITER=${MAX_ITER:-60}
UP_TIMEOUT=300      # s to wait for SSH after a reboot
GOOD_TIMEOUT=240    # s to wait for mark-good once up

mkdir -p "$OUT"
LOG="$OUT/loop.log"
ssh_() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes "$HOST" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
attempts() { ssh_ 'sed -n "s/^boot-attempts: //p" /esp/SteamOS/conf/A.conf' 2>/dev/null; }

# Deadlines are wall-clock: an unreachable host makes ssh fail instantly, so counting loop
# turns as seconds ran a "300 s" wait out in 40 s.
wait_up() {
	local end=$(( $(date +%s) + UP_TIMEOUT ))
	while ! ssh_ true 2>/dev/null; do
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 5
	done
}

# Pull this boot's archive of the PREVIOUS boot's console (systemd-pstore moved it to /var).
save_pstore() {
	local tag=$1
	# The archive is removed once saved: a boot whose zone header was beyond repair archives
	# nothing, and a leftover file would pass for its console.
	ssh_ 'ls -la --time-style=+%H:%M:%S /var/lib/systemd/pstore/; dmesg | grep -i "ramoops: .*header"' > "$OUT/$tag.ls" 2>/dev/null
	ssh_ 'f=/var/lib/systemd/pstore/console-ramoops-0; [ -f "$f" ] && cat "$f" && rm -f "$f"' > "$OUT/$tag.console" 2>/dev/null
	[ -s "$OUT/$tag.console" ] || rm -f "$OUT/$tag.console"
}

log "start: max $MAX_ITER reboots"
wait_up || { log "FIT not reachable at start"; exit 1; }

for i in $(seq 1 "$MAX_ITER"); do
	# Before rebooting: this boot must be confirmed good (boot-attempts back to 0).
	end=$(( $(date +%s) + GOOD_TIMEOUT ))
	while [ "$(attempts)" != "0" ]; do
		sleep 5
		if [ "$(date +%s)" -ge "$end" ]; then
			log "iter $i: boot-attempts=$(attempts) not 0 after ${GOOD_TIMEOUT}s; NOT rebooting, stopping"
			exit 2
		fi
	done
	bid_before=$(ssh_ 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
	log "iter $i: confirmed good (boot $bid_before), rebooting"
	ssh_ 'systemctl reboot' >/dev/null 2>&1

	# Wait for the old boot to go away, then for the new one to answer.
	end=$(( $(date +%s) + 120 ))
	while [ "$(ssh_ 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" = "$bid_before" ]; do
		sleep 2; [ "$(date +%s)" -ge "$end" ] && { log "iter $i: reboot did not happen"; exit 3; }
	done
	start=$(date +%s)
	if ! wait_up; then
		log "iter $i: FIT DID NOT COME BACK in ${UP_TIMEOUT}s (hang with panic=0, or steamcl menu); stopping"
		exit 4
	fi
	a=$(attempts)
	up=$(ssh_ 'cut -d" " -f1 /proc/uptime')
	save_pstore "iter$(printf %03d "$i")"
	took=$(( $(date +%s) - start ))
	c="$OUT/iter$(printf %03d "$i").console"
	if [ -f "$c" ]; then
		last="$(wc -c < "$c") bytes, ends: $(tr -c '[:print:]\n' '.' < "$c" | grep -v '^ECC' | grep -v '^$' | tail -1 | cut -c1-90)"
	else
		last="NO console (zone header beyond repair)"
	fi
	log "iter $i: up after ${took}s (uptime ${up}s), boot-attempts=$a, console: $last"

	if [ -n "$a" ] && [ "$a" -ge 2 ]; then
		log "iter $i: RESET CAUGHT (boot-attempts=$a): an unconfirmed boot happened before this one"
		log "console of the reset boot: $OUT/iter$(printf %03d "$i").console"
		exit 0
	fi
done
log "done: $MAX_ITER reboots, no reset seen"
