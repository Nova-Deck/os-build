#!/bin/sh
# novadeck stable Bluetooth address — WITHOUT THIS THERE IS NO BLUETOOTH AT ALL.
#
# This is not a nicety like the Wi-Fi MAC next door. The wcn7850 bluetooth node in our DTS carries no
# `local-bd-address`, and `hci_qca` sets HCI_QUIRK_USE_BDADDR_PROPERTY — so the HCI core looks for that
# property, does not find one, and marks the controller HCI_UNCONFIGURED. An unconfigured controller
# lives in a SEPARATE mgmt index list, invisible to the normal one: `btmgmt info` reports
# "Index list with 0 items", `bluetoothctl show` says "No default controller available", and bluetoothd
# logs no error at all because from its side nothing ever appeared. No controllers, no BT audio, no
# BLE. Meanwhile dmesg says `QCA setup on UART is completed` and /sys/class/bluetooth/hci0 exists, so
# everything looks healthy from below (HW-diagnosed 2026-08-19, AYANEO Pocket ACE).
#
# Handing mgmt a public address is what moves the controller into the configured list. The kernel
# re-runs QCA setup (~1.6s, firmware re-downloads) and the adapter appears for real.
#
# WHY NOT PUT `local-bd-address` IN THE DTS: one image serves every board, so a DTS literal is ONE
# address shared by every unit ever flashed — the exact collision the Wi-Fi MAC generator exists to
# avoid. Derive per-unit instead, from the same seed, and persist write-once. See gen-mac.sh.
set -eu

STATE=/var/lib/novadeck
DEV_WAIT=15   # seconds to wait for the controller to be created by the QCA setup
SET_TRIES=15  # attempts at handing it the address (it may not reach mgmt until setup finishes)
CFG_WAIT=10   # seconds to wait for it to re-appear CONFIGURED after we set the address

log() { echo "[novadeck-bdaddr] $*" >&2; }

# EVERY btmgmt call goes through this, and the reason is a real failure: at boot this unit hung past
# its TimeoutStartSec and was SIGTERM'd, having produced NO output at all — so it blocked before its
# first log line, on a btmgmt that returns instantly by hand. The race is that
# /sys/class/bluetooth/hci0 appears when hci_register_dev() runs, ~2s BEFORE the QCA firmware download
# finishes, so the sysfs node is not a promise that mgmt knows about the controller yet. Nothing here
# may block indefinitely on a controller that is still coming up.
mgmt() { timeout 10 btmgmt "$@" 2>/dev/null; }

# The controller is created by the QCA setup, not by us, and that lands a few seconds into boot. Wait
# rather than race it. A board with no bluetooth node never produces one — that is not this unit's
# failure, so say so and leave rather than blocking the boot.
n=0
while [ ! -e /sys/class/bluetooth/hci0 ]; do
  n=$((n + 1))
  [ "$n" -ge "$DEV_WAIT" ] && { log "no /sys/class/bluetooth/hci0 after ${DEV_WAIT}s — no BT controller on this board, nothing to do"; exit 0; }
  sleep 1
done

# Already configured (a board whose DTS or bootloader DOES supply an address) — leave it alone. Its
# address is the hardware's, and ours would be a downgrade.
if mgmt info | grep -q '^hci0:'; then
  log "hci0 is already configured — leaving its address alone"
  exit 0
fi

# --- per-unit seed ------------------------------------------------------------------------------
# Same ladder as gen-mac.sh: machine-id (random per unit on first boot, stable after), then the
# Qualcomm SoC serial, then a one-time random value — which the write-once store below makes stable.
seed=$(cat /etc/machine-id 2>/dev/null || true)
[ -n "$seed" ] || seed=$(cat /sys/devices/soc0/serial_number 2>/dev/null || true)
[ -n "$seed" ] || seed=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')

# Salted '-bt' so this address can never collide with the Wi-Fi one derived from the same seed.
# First octet gets the locally-administered bit (0x02) set and the multicast bit (0x01) cleared: we
# are not claiming an IEEE OUI, and a multicast BD address is not a valid device identity.
h=$(printf '%s-bt' "$seed" | sha256sum | cut -c1-12)
o1=$(printf '%02X' "$(( (0x$(printf '%s' "$h" | cut -c1-2) | 0x02) & 0xfe ))")
BDADDR="$o1:$(printf '%s' "$h" | cut -c3-4):$(printf '%s' "$h" | cut -c5-6):$(printf '%s' "$h" | cut -c7-8):$(printf '%s' "$h" | cut -c9-10):$(printf '%s' "$h" | cut -c11-12)"
BDADDR=$(printf '%s' "$BDADDR" | tr 'a-f' 'A-F')

# Write-once, on the writable side (/var stays rw under the immutable root): keep the FIRST address
# ever chosen so a machine-id reset cannot re-identify the device and orphan every phone pairing.
mkdir -p "$STATE"
if [ -s "$STATE/bdaddr" ]; then
  BDADDR=$(cat "$STATE/bdaddr")
else
  ( umask 022; printf '%s\n' "$BDADDR" >"$STATE/bdaddr" )
fi

# Retry the set itself rather than assuming one shot lands: until setup completes, index 0 may not
# exist in either list. Each attempt is bounded, so the worst case is SET_TRIES*(10+1)s, well inside
# the unit's TimeoutStartSec.
n=0
until mgmt --index 0 public-addr "$BDADDR" >/dev/null; do
  n=$((n + 1))
  [ "$n" -ge "$SET_TRIES" ] && { log "ERROR: btmgmt public-addr $BDADDR did not succeed in $SET_TRIES tries — controller never reached mgmt"; exit 1; }
  [ "$n" = 1 ] && log "controller not ready for a public address yet; retrying"
  sleep 1
done
log "set public address $BDADDR (attempt $((n + 1)))"

# Setting the address makes the kernel tear the controller down and re-run QCA setup, so the
# configured controller appears a second or two LATER. Confirm it actually arrived — a silent success
# here would look identical to the bug this whole unit exists to fix.
n=0
while ! mgmt info | grep -q '^hci0:'; do
  n=$((n + 1))
  [ "$n" -ge "$CFG_WAIT" ] && { log "ERROR: hci0 still not in the mgmt index list ${CFG_WAIT}s after setting $BDADDR"; exit 1; }
  sleep 1
done
log "hci0 configured as $BDADDR"
