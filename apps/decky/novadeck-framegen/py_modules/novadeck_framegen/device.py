"""The per-SoC default flow scale — measured, not derived.

Frame generation costs a fixed slice of every frame, and how big that slice is differs by more
than clock across the three GPUs this image runs on. Measured with `lsfg-vk-cli benchmark` at
each device's own panel resolution, performance mode, 2x, on an IDLE GPU (issue #81):

    SM8250 / Adreno 650   flow 1.00 -> 25.38 ms   flow 0.50 -> 8.78 ms
    SM8550 / Adreno 740   flow 1.00 ->  3.11 ms
    SM8650 / Adreno 750   flow 1.00 ->  2.99 ms

The 60fps frame budget is 16.67 ms. So flow 1.00 is comfortable on the 740 and 750 and does NOT
fit on the 650 -- with the GPU doing nothing else at all, before the game draws a single frame.
Adreno 650 gets only 1.38x from fp16 where the 740 gets 3.76x and the 750 gets 6.71x, and this
pipeline leans hard on half precision; that gap, not the 800-vs-1000 MHz clock, is the reason.

So the default is per-SoC. It is a DEFAULT, not a cap: the slider still goes to 1.00 on an
Adreno 650, because a user willing to drop to 30fps output has every right to try it, and a
device the operator cannot overrule is a worse device. It just does not start there.
"""
from pathlib import Path

COMPATIBLE = Path("/sys/firmware/devicetree/base/compatible")

# Keyed on the SoC compatible string, which is what the devicetree actually publishes -- the
# board name is not the interesting axis here, the GPU is, and boards share SoCs.
FLOW_SCALE_BY_SOC = {
    "qcom,sm8250": 0.5,
    "qcom,sm8550": 1.0,
    "qcom,sm8650": 1.0,
}
DEFAULT_FLOW_SCALE = 0.5  # unknown SoC: start conservative, since the cost of guessing high is
                          # a feature that makes the game slower rather than faster


def soc():
    try:
        raw = COMPATIBLE.read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return ""
    for entry in raw.split("\0"):
        if entry.startswith("qcom,sm") or entry.startswith("qcom,qcs"):
            # A board declares e.g. "ayaneo,pocketace qcom,qcs8550 qcom,sm8550"; the sm entry is
            # the one the table is keyed on, so keep looking past a qcs alias.
            if entry.startswith("qcom,sm"):
                return entry
    return ""


def default_flow_scale():
    return FLOW_SCALE_BY_SOC.get(soc(), DEFAULT_FLOW_SCALE)


def defaults():
    """What a game with no profile yet should start at."""
    return {
        "multiplier": 2,
        "flowScale": default_flow_scale(),
        # Not a preference: the quality model misses the 60fps budget at panel resolution on
        # ALL THREE parts, including the fastest (23.97 ms on the Adreno 750).
        "performanceMode": True,
        "soc": soc(),
    }
