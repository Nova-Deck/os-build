#!/usr/bin/env bash
# Offline check for the GPU clock split in rootfs/overlay/usr/bin/novadeck-powerd.
#
#   tests/test-power-gpu.sh
#
# WHY THIS EXISTS. The auto profiles express their GPU limits as ratios, and a ratio is only as
# meaningful as what it is taken of. On SM8250 the kernel ladder runs past the A650's factory
# 587 MHz (650-750 MHz overclock OPPs), and taken of the top OPP the ratios silently drifted:
# eco (0.80) landed ON stock instead of below it, balanced and performance ran the overclock by
# default. Nothing errored; the clocks were just not what the profile names promise.
#
# So the ratios are taken of a per-class factory ceiling ([gpu.<class>] stock_max_mhz), while
# Steam's manual GPU clock keeps the whole ladder: overclock is a manual choice. This drives the
# real parse and limit maths against the SHIPPED factory config and the real OPP ladders.
#
# NOT covered: the devfreq writes on a device and the D-Bus surface (needs gi and a bus).
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERD="$ROOT/rootfs/overlay/usr/bin/novadeck-powerd"
FACTORY="$ROOT/rootfs/overlay/usr/share/novadeck/power-profiles.conf"

[[ -f $POWERD ]]  || { echo "novadeck-powerd missing: $POWERD" >&2; exit 1; }
[[ -f $FACTORY ]] || { echo "power-profiles.conf missing: $FACTORY" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Keep the module's bytecode out of rootfs/overlay/usr/bin (the assembler copies it verbatim).
export PYTHONPYCACHEPREFIX="$TMP/pycache"

NOVADECK_POWERD_FACTORY="$FACTORY" NOVADECK_POWERD_ETC="$TMP/etc" \
python3 - "$POWERD" "$ROOT" "$TMP" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import pathlib
import sys

powerd_path, root, tmp = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

sys.path.insert(0, os.path.join(root, "rootfs/overlay/usr/lib/novadeck"))
spec = importlib.util.spec_from_loader(
    "powerd", importlib.machinery.SourceFileLoader("powerd", powerd_path))
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

results = []
def check(name, got, want):
    results.append(("PASS" if got == want else f"FAIL (got {got!r}, want {want!r})", name))

MHZ = 1_000_000
# The GPU OPP ladders of the kernel we ship (arch/arm64/boot/dts/qcom/sm8250.dtsi with our
# patch 1120, sm8550.dtsi), in MHz. Only SM8250 runs past its factory 587.
SM8250 = [305, 400, 441.6, 490, 525, 587, 650, 670, 700, 725, 750]
SM8550 = [220, 295, 348, 401, 475, 550, 615, 680]

fake_gpus = 0
def fake_gpu(ladder):
    global fake_gpus
    fake_gpus += 1
    gpu = tmp / "devfreq" / f"gpu{fake_gpus}"
    gpu.mkdir(parents=True)
    (gpu / "available_frequencies").write_text(
        " ".join(str(int(mhz * MHZ)) for mhz in ladder) + "\n")
    return gpu

# __init__ globs sysfs; build the object bare and point it at a fabricated devfreq node.
def fresh(soc_class, ladder):
    obj = pd.NovadeckPower.__new__(pd.NovadeckPower)
    obj.env = {"NOVADECK_SOC_CLASS": soc_class} if soc_class else {}
    obj.gpu = fake_gpu(ladder)
    obj.gpu_level = "auto"
    obj.manual_gpu_clock = 0
    obj.discover = lambda: None
    obj.apply_profile = lambda: None
    obj.load_config()
    obj.profile = obj.default_profile
    return obj

def auto_mhz(obj, profile):
    obj.profile = profile
    lo, hi = obj.resolved_gpu_auto_limits()
    return (lo / MHZ, hi / MHZ)

# ------------------------------------------------------------------ factory config ---
power = fresh("SM8250", SM8250)
check("factory config anchors SM8250 at the A650's 587 MHz", power.gpu_stock_config, {"SM8250": 587})
check("the ratios are of the factory ceiling, not the top OPP",
      power.gpu_stock_max(power.gpu_freqs()), 587 * MHZ)

# ------------------------------------------------------------------ SM8250 auto profiles ---
# What the three shipped profiles resolve to on the overclock ladder. These are the numbers
# this change exists for: eco below stock, the other two AT stock, none above it.
check("SM8250 eco stops below stock (0.80 of 587 -> the 441.6 step)", auto_mhz(power, "eco"), (305, 441.6))
check("SM8250 balanced tops out at stock", auto_mhz(power, "balanced"), (305, 587))
check("SM8250 performance pins stock, not the overclock", auto_mhz(power, "performance"), (587, 587))
for profile in pd.PROFILES:
    check(f"SM8250 {profile} never exceeds stock under auto", auto_mhz(power, profile)[1] <= 587, True)

# ------------------------------------------------------------------ manual keeps the ladder ---
# Overclock is a manual choice: the Steam slider's range is the whole ladder and a manual
# clock above stock is honoured as-is.
power.profile = "eco"
check("manual clock reaches the top of the ladder", power.set_gpu_manual_clock(750), 750)
check("manual clock wrote the overclock step as max_freq",
      pd.read_text(power.gpu / "max_freq").strip(), str(750 * MHZ))
check("manual clock pinned min_freq to the same step",
      pd.read_text(power.gpu / "min_freq").strip(), str(750 * MHZ))
check("manual clock snaps to the nearest OPP", power.set_gpu_manual_clock(660), 650)

# ------------------------------------------------------------------ classes without a section ---
# No [gpu.<class>] means the top OPP is the factory ceiling, which it is on the other SoCs. The
# ratios must then resolve exactly as they did before the anchor existed.
other = fresh("SM8550", SM8550)
check("SM8550 has no stock anchor", other.gpu_stock_max(other.gpu_freqs()), 680 * MHZ)
check("SM8550 eco is 0.80 of the top OPP (544 -> the 475 step)", auto_mhz(other, "eco"), (220, 475))
check("SM8550 performance pins the top OPP", auto_mhz(other, "performance"), (680, 680))

# An unknown board (no SOC class, see device-env) gets no anchor either, even on the SM8250
# ladder. That is the fall-through test-stage2-grub.sh guards against at the device-env end.
unknown = fresh("", SM8250)
check("no SOC class -> no anchor, the ratio is of the top OPP", auto_mhz(unknown, "balanced"), (305, 750))

# ------------------------------------------------------------------ parsing edges ---
# A truncated MHz still selects its own step: 441 names the 441.6 MHz OPP, not 400.
power.gpu_stock_config = {"SM8250": 441}
check("a truncated stock MHz selects its own OPP", power.gpu_stock_max(power.gpu_freqs()), int(441.6 * MHZ))
# An operator drop-in overriding the anchor is read like any other key.
dropin = tmp / "etc" / "power-profiles.conf.d"
dropin.mkdir(parents=True, exist_ok=True)
(dropin / "90-operator.conf").write_text("[gpu.SM8250]\nstock_max_mhz=750\n")
power.load_config()
check("an operator drop-in can move the anchor", power.gpu_stock_config, {"SM8250": 750})
(dropin / "90-operator.conf").write_text("[gpu.SM8250]\nstock_max_mhz=junk\n")
power.load_config()
check("a junk anchor is dropped, not fatal", power.gpu_stock_config, {})

for status, name in results:
    print(f"{status} {name}")
failed = [name for status, name in results if status != "PASS"]
if failed:
    print(f"test-power-gpu: {len(failed)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("test-power-gpu: all checks passed")
PYEOF
