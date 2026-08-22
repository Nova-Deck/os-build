#!/usr/bin/env bash
# Phase 5 hardware validation of the installer's PRE-FLIGHT SCREEN — READ ONLY, on a real device.
#
#   install/hw-preflight.sh root@<device>
#
# Renders the screen install/ui would draw before the consent gate, against the device's own disk.
# Everything it shows is derived by the programs that would perform the install, so this is the
# only way to see the real numbers: select-target.sh picks the target, carve.sh `plan` says what
# the carve would do to it, device-env names the board, sysfs gives the model and size.
#
# NOTHING HERE WRITES TO THE DISK. Three claims, each checkable rather than promised:
#   * select-target.sh is pure by construction (plan §3) — hw-select-target.sh, its peer, is run
#     against boards carrying installs somebody cares about for exactly that reason.
#   * `carve.sh plan` stops before the first delete. install/test-carve.sh asserts it by dumping
#     the partition table before and after, on a stock disk AND on one that already carries our
#     eight ("plan on a stock disk wrote nothing at all").
#   * the UI code reached here is gather_preflight() + PreflightScreen.describe(), which run those
#     two and read /sys/block. There is no write path in it, and the spine is never invoked.
# Staged files live in /run/novadeck/probe — tmpfs, gone at the next boot.
#
# WHAT THIS CANNOT SHOW FROM A DEV CARD, so nobody plans the trip twice: the `REPLACES_OURS=1`
# screen — a disk that ALREADY carries novadeck, whose destroy list names novadeck-home. Reaching it
# needs a device booted from removable media with our eight on internal, and a dev card carries the
# SAME `novadeck-*` filesystem labels as the install, so /esp and /home cross-mount onto the target
# (seen during the §4a gate, 2026-08-21). The installer image gets its own labels; until then that
# path is Phase 6 hardware step 6 and its only coverage is install/test-carve.sh, against a fixture
# that has been carved for real. A device booted FROM internal cannot be its own target either —
# select-target rule 1/2 refuses it, confirmed on a Pocket ACE 2026-08-22:
# "select-target: /dev/sda is the disk the running system is on".
#
# WHY IT IS WORTH RUNNING AT ALL, given install/test-ui.sh drives the same code offline: the suite
# feeds it stub tools and a synthetic GPT at 512-byte sectors. A real UFS LUN reports 4096, the
# partition list is the board's own, and the destroy list comes from a carve plan over real
# geometry. Every install defect this project has found so far was found by hardware after the
# suite was green.
set -euo pipefail

host="${1:-}"
[ -n "$host" ] || { echo "usage: ${0##*/} <user@host>   (e.g. root@192.168.1.143)" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE=/run/novadeck/probe

# shellcheck source=lib-hwstage.sh
. "$ROOT/install/lib-hwstage.sh"
hwstage_init "$ROOT"

# sgdisk for carve.sh and select-target.sh; mdir because select-target FAILS CLOSED without it
# (rule 3b reads a foreign ESP's content with it, and its absence used to answer "not bootable"
# for every ESP on the disk). Neither is in the shipped rootfs — both are installer-image packages.
hwstage_fetch sgdisk mdir
hwstage_ssh_opts

ssh "${SSHOPTS[@]}" "$host" "mkdir -p $PROBE"
# ONE FLAT DIRECTORY, because every component resolves $SELFDIR first: carve.sh finds genpart.sh,
# lib-gpt.sh and lib-slotwrite.sh beside itself, and install/ui finds its sibling modules by
# dirname(__file__). The same rule install/hw-install.sh follows, for the same reason — a card
# carries baked copies of the shipped ones and the working tree must beat them.
scp "${SSHOPTS[@]}" -q \
  "$(hwstage_path sgdisk)" "$(hwstage_path mdir)" \
  "$ROOT/install/select-target.sh" \
  "$ROOT/install/carve.sh" \
  "$ROOT/install/netcfg" \
  "$ROOT/install/ui" \
  "$ROOT/install/uipad.py" \
  "$ROOT/install/uiflow.py" \
  "$ROOT/images/genpart.sh" \
  "$ROOT/images/lib-gpt.sh" \
  "$ROOT/images/partition-table.txt" \
  "$ROOT/fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh" \
  "$host:$PROBE/"
ssh "${SSHOPTS[@]}" "$host" "chmod +x $PROBE/sgdisk $PROBE/mdir $PROBE/*.sh $PROBE/ui"

ssh "${SSHOPTS[@]}" "$host" 'bash -s' <<'REMOTE'
set -u
P=/run/novadeck/probe
export PATH="$P:$PATH"
export NOVADECK_SELECT_TARGET="$P/select-target.sh"
export NOVADECK_CARVE="$P/carve.sh"
export NOVADECK_DEVICE_ENV=/usr/lib/novadeck/device-env
# Left EMPTY on purpose. The pre-flight screen refuses to start an install with no bundle
# configured, and seeing that refusal is part of what this run is checking — a probe that supplied
# a bundle would be a probe one keystroke away from being an installer.
export NOVADECK_INSTALL_BUNDLE=""
export NOVADECK_INSTALL_SEED=""
export NOVADECK_NETCFG="$P/netcfg"

# §4b, and DIAGNOSE ONLY. `netcfg join` is the mode that talks to NetworkManager; it is deliberately
# not run here, so this stays a probe rather than something that reconfigures a device's network
# out from under whoever is using it. `diagnose` runs `ip`, `curl` and reads wifi.conf.
echo "=== network (netcfg diagnose, read-only)"
"$P/netcfg" diagnose
echo

python3 - <<'PY'
import os, sys
sys.path.insert(0, "/run/novadeck/probe")
import uiflow

print("=" * 78)
net = uiflow.net_diagnose()
print("network state: %s" % net.get("STATE"))
ns = uiflow.NetworkScreen(net).describe()
print("  %s" % ns["title"])
for head, body in ns["blocks"]:
    print("    %-22s %s" % (head + ":", body))
print("  buttons: %s" % [b["label"] for b in ns["buttons"]])
print("=" * 78)

facts = uiflow.gather_preflight()
if facts is None:
    print("NO TARGET: select-target.sh found nothing installable on this device.")
    print("(That is a legitimate outcome -- the UI then serves consent only.)")
    raise SystemExit(0)

for k in ("device", "disk", "mode", "ud_index"):
    print("%-12s %s" % (k, facts[k]))
print("%-12s %s" % ("disk_facts", facts["disk_facts"]))
print("=" * 78)

def render(pf):
    d = pf.describe()
    print("\n#### %s" % d["title"])
    for head, body in d["blocks"]:
        print("\n  %s" % head)
        for line in body.split("\n"):
            print("    %s" % line)
    print("\n  buttons: %s" % [b["label"] for b in d["buttons"]])
    print("  note:    %s" % d["note"])

pf = uiflow.PreflightScreen(facts)
render(pf)

# The knob. Every adjustment re-asks carve.sh rather than interpolating, so these are the figures
# the carve would actually produce for each choice -- on this board's real geometry.
print("\n" + "=" * 78)
print("the size knob, on real geometry")
for token in ("RIGHT", "RIGHT", "LEFT"):
    pf.handle(token)
    print("  %-6s -> android %3s GiB   novadeck %s GiB   destroys %d"
          % (token, pf.gib, pf.plan["NOVADECK_GIB"], len(pf.plan["destroy"])))

# And the refusal, which is the reason no bundle was supplied above.
pf.handle("S")
print("\n  continue with no bundle configured -> result=%r (nothing started)" % (pf.result,))
PY
REMOTE

echo "[novadeck] staged files remain under $PROBE (tmpfs); they vanish at reboot" >&2
