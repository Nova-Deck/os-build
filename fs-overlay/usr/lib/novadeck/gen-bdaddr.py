#!/usr/bin/env python3
"""novadeck stable Bluetooth address — WITHOUT THIS THERE IS NO BLUETOOTH AT ALL.

The wcn7850 bluetooth node in our DTS carries no `local-bd-address`, and hci_qca sets
HCI_QUIRK_USE_BDADDR_PROPERTY — so the HCI core looks for that property, does not find one, and marks
the controller HCI_UNCONFIGURED. An unconfigured controller lives in a SEPARATE mgmt index list,
invisible to the normal one: `btmgmt info` reports "Index list with 0 items", `bluetoothctl show` says
"No default controller available", and bluetoothd logs no error at all because from its side nothing
ever appeared. No controllers, no BT audio, no BLE. Meanwhile dmesg says `QCA setup on UART is
completed` and /sys/class/bluetooth/hci0 exists, so everything looks healthy from below
(HW-diagnosed 2026-08-19, AYANEO Pocket ACE).

Handing mgmt a public address is what moves the controller into the configured list. The kernel
re-runs QCA setup (~1.6s, firmware re-downloads) and the adapter appears for real.

WHY NOT `btmgmt`, WHICH IS WHAT A HUMAN WOULD TYPE: it HANGS FOREVER without a controlling terminal,
and a systemd unit has none. Measured on device — `btmgmt info` with a tty returns 10 lines rc=0;
under `setsid ... </dev/null`, or with stdin closed, it produces ZERO output and never returns. Two
shipped attempts died on this: the first hung past TimeoutStartSec and was SIGTERM'd with no log line
at all, the second "retried" 15 times against a wrapper timeout, each attempt guaranteed to fail
identically. Every manual reproduction succeeded because ssh gave it a pty. No arrangement of waits or
retries around that tool can work, so this speaks the mgmt protocol itself: an AF_BLUETOOTH /
HCI_CHANNEL_CONTROL socket, no subprocess, no terminal, real status codes.

WHY NOT `local-bd-address` IN THE DTS: one image serves every board, so a DTS literal is ONE address
shared by every unit ever flashed — the exact collision the Wi-Fi MAC generator exists to avoid.
Derive per-unit from the same seed, and persist write-once. See gen-mac.sh.
"""
import ctypes
import hashlib
import os
import pathlib
import socket
import struct
import sys
import time

STATE = pathlib.Path("/var/lib/novadeck")
SYSFS = pathlib.Path("/sys/class/bluetooth/hci0")
INDEX = 0            # hci0
DEV_WAIT = 30.0      # seconds for the controller node the QCA setup creates
CONF_WAIT = 20.0     # seconds for it to re-appear CONFIGURED after we set the address

AF_BLUETOOTH = 31
BTPROTO_HCI = 1
HCI_DEV_NONE = 0xFFFF
HCI_CHANNEL_CONTROL = 3

MGMT_OP_READ_INDEX_LIST = 0x0003
# From the kernel's own mgmt.h, not from counting down a table: 0x0044 is GET_PHY_CONFIGURATION,
# which the handler table does NOT mark HCI_MGMT_UNCONFIGURED — so an unconfigured controller
# rejects it with INVALID_INDEX (0x11), the one status that reads like "no such controller" on the
# one controller we can see. Shipped wrong once; cost a card flash to catch, because the
# already-configured no-op path above never sends it.
MGMT_OP_SET_PUBLIC_ADDRESS = 0x0039
MGMT_EV_CMD_COMPLETE = 0x0001
MGMT_EV_CMD_STATUS = 0x0002


def log(msg):
    print(f"[novadeck-bdaddr] {msg}", file=sys.stderr, flush=True)


class Mgmt:
    """The kernel's Bluetooth management socket."""

    def __init__(self):
        self.sock = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW, BTPROTO_HCI)
        # Python's socket module cannot express a raw sockaddr_hci, so bind through libc.
        # struct sockaddr_hci { sa_family_t hci_family; unsigned short hci_dev, hci_channel; }
        addr = struct.pack("<HHH", AF_BLUETOOTH, HCI_DEV_NONE, HCI_CHANNEL_CONTROL)
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        if libc.bind(self.sock.fileno(), addr, len(addr)) != 0:
            err = ctypes.get_errno()
            raise OSError(err, f"bind(HCI_CHANNEL_CONTROL): {os.strerror(err)}")
        self.sock.settimeout(5.0)

    def request(self, opcode, index=HCI_DEV_NONE, payload=b""):
        """Send one command, return (status, params) from its completion.

        Every read is bounded by the socket timeout, so a controller that never answers surfaces as
        an exception rather than the indefinite hang that sank the btmgmt version.
        """
        self.sock.send(struct.pack("<HHH", opcode, index, len(payload)) + payload)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            data = self.sock.recv(1024)
            if len(data) < 6:
                continue
            event, _idx, plen = struct.unpack("<HHH", data[:6])
            params = data[6:6 + plen]
            # Unsolicited events (index added/removed) arrive on this socket too; skip anything that
            # is not the completion of the command we just sent.
            if event == MGMT_EV_CMD_COMPLETE and len(params) >= 3:
                done, status = struct.unpack("<HB", params[:3])
                if done == opcode:
                    return status, params[3:]
            elif event == MGMT_EV_CMD_STATUS and len(params) >= 3:
                done, status = struct.unpack("<HB", params[:3])
                if done == opcode:
                    return status, b""
        raise TimeoutError(f"no completion for mgmt opcode 0x{opcode:04x}")

    def configured_indices(self):
        """Indices in the NORMAL list. An unconfigured controller is absent from it — that absence is
        the whole bug this script exists to fix, and its disappearance is how we prove the fix."""
        status, params = self.request(MGMT_OP_READ_INDEX_LIST)
        if status != 0 or len(params) < 2:
            return []
        (count,) = struct.unpack("<H", params[:2])
        return list(struct.unpack(f"<{count}H", params[2:2 + count * 2]))


def derive_address():
    """Per-unit, from the same seed ladder as gen-mac.sh: machine-id (random per unit on first boot,
    stable after), then the Qualcomm SoC serial, then a one-time random value — which the write-once
    store below makes stable. Salted 'bt' so it can never collide with the Wi-Fi address."""
    seed = ""
    for path in ("/etc/machine-id", "/sys/devices/soc0/serial_number"):
        try:
            seed = pathlib.Path(path).read_text().strip()
        except OSError:
            seed = ""
        if seed:
            break
    if not seed:
        seed = os.urandom(16).hex()

    digest = hashlib.sha256(f"{seed}-bt".encode()).digest()
    octets = bytearray(digest[:6])
    # Locally-administered bit set, multicast bit cleared: we are not claiming an IEEE OUI, and a
    # multicast BD address is not a valid device identity.
    octets[0] = (octets[0] | 0x02) & 0xFE
    return ":".join(f"{b:02X}" for b in octets)


def stable_address():
    """Write-once: keep the FIRST address ever chosen, so a machine-id reset cannot re-identify the
    device and orphan every phone pairing."""
    store = STATE / "bdaddr"
    try:
        existing = store.read_text().strip()
        if existing:
            return existing
    except OSError:
        pass
    address = derive_address()
    STATE.mkdir(parents=True, exist_ok=True)
    store.write_text(address + "\n")
    store.chmod(0o644)
    return address


def main():
    # The controller is created by the QCA setup a few seconds into boot, not by us. Wait rather than
    # race it. A board with no bluetooth node never produces one — not this unit's failure, so say so
    # and leave rather than blocking the boot.
    deadline = time.monotonic() + DEV_WAIT
    while not SYSFS.exists():
        if time.monotonic() >= deadline:
            log(f"no {SYSFS} after {DEV_WAIT:.0f}s — no BT controller on this board, nothing to do")
            return 0
        time.sleep(0.5)

    mgmt = Mgmt()

    if INDEX in mgmt.configured_indices():
        log(f"hci{INDEX} is already configured — leaving its address alone")
        return 0

    address = stable_address()
    # mgmt takes the address little-endian, i.e. reversed from display order.
    packed = bytes(int(b, 16) for b in reversed(address.split(":")))
    status, _ = mgmt.request(MGMT_OP_SET_PUBLIC_ADDRESS, INDEX, packed)
    if status != 0:
        log(f"ERROR: Set Public Address {address} rejected with mgmt status 0x{status:02x}")
        return 1
    log(f"set public address {address}")

    # The kernel tears the controller down and re-runs QCA setup, so the configured controller appears
    # a second or two LATER. Confirm it actually arrived — a silent success here would look identical
    # to the bug this whole unit exists to fix.
    deadline = time.monotonic() + CONF_WAIT
    while INDEX not in mgmt.configured_indices():
        if time.monotonic() >= deadline:
            log(f"ERROR: hci{INDEX} still absent from the mgmt index list {CONF_WAIT:.0f}s after "
                f"setting {address}")
            return 1
        time.sleep(0.5)
    log(f"hci{INDEX} configured as {address}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
