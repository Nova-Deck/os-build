#!/usr/bin/env bash
# Guard against re-enabling CEF's V4L2 video decode on iris.
#
#   images/test-video-decode.sh
#
# WHY THIS EXISTS. Everything in Valve's binaries points at turning this on, and the hardware says
# no. `strings` on the arm64 libcef.so shows a full ChromeOS V4L2 stack built in
# (use_v4l2_codec=true); steamclient.so has a switch literally described as "Enable VA-API video
# decoding on Linux"; the kernel driver works and decodes at ~34x realtime under ffmpeg. Follow all
# of that and you ship a UI that is VISIBLY SLOWER and burns ~2.5x the CPU — measured on the
# MANGMI Pocket Max 2026-08-19, see docs/video-decode.md for the numbers.
#
# So this file guards a NEGATIVE result. Both assertions are things we removed after measuring, and
# both are things a reasonable person re-derives from the binaries in an afternoon. The failure
# messages carry the reason, because a bare "do not add this" gets overridden by the next person
# holding what looks like proof.
#
# The kernel side is deliberately NOT guarded here: iris works and stays available to anything that
# wants it (ffmpeg, a media player). Only the CEF integration is bad.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEAM_SH="$ROOT/fs-overlay/usr/bin/novadeck-steam"
RULE="$ROOT/fs-overlay/usr/lib/udev/rules.d/70-novadeck-iris-video-dec.rules"
DOC="$ROOT/docs/video-decode.md"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$STEAM_SH" "$DOC"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done

echo "CEF V4L2 decode stays off"

# 1. THE switch. Not a Steam flag, not a Chromium feature — the ChromeOS-style symlink. Chromium's
#    legacy V4L2VideoDecodeAccelerator finds the decoder only via the /dev/video-dec prefix, and
#    iris registers plain /dev/videoN. With no symlink, zero CEF processes open the decoder
#    (verified by fd count on device); create it and the slow legacy path takes over.
if [[ -e $RULE ]]; then
    bad "$(basename "$RULE") is back -- that symlink is what makes CEF decode on iris, and it is SLOWER than CPU decode (docs/video-decode.md)"
else
    ok "no /dev/video-dec0 udev rule in the overlay"
fi

# 2. Any other rule that hands CEF a ChromeOS decoder name does the same damage, so match on the
#    symlink target rather than on our old filename.
stray=$(grep -rlE 'SYMLINK\+="video-(dec|enc)' "$ROOT/fs-overlay/usr/lib/udev/rules.d" 2>/dev/null || true)
if [[ -n $stray ]]; then
    bad "a udev rule still creates a ChromeOS video-dec/enc name: $stray"
else
    ok "no udev rule creates a ChromeOS-style decoder name"
fi

# 3. -cef-enable-vaapi is a NO-OP, measured by diffing the webhelper argv with and without it: the
#    sole difference is adding VaapiVideoDecodeLinuxGL to --enable-features, and this libcef has no
#    VA-API at all. Harmless in itself, but it is the flag someone adds while believing it enables
#    decode, so it should not sit in the args implying it does something.
if sed -n 's/^: "${NOVADECK_STEAM_ARGS:=\(.*\)}"$/\1/p' "$STEAM_SH" | grep -qw -- '-cef-enable-vaapi'; then
    bad "-cef-enable-vaapi is in NOVADECK_STEAM_ARGS -- it is a no-op (adds only VaapiVideoDecodeLinuxGL to a libcef with no VA-API)"
else
    ok "-cef-enable-vaapi is not in the launch args"
fi

# 4. Chromium does not shell-parse --gpu-launcher, so steamclient's `--gpu-launcher='%s'` delivers
#    the quotes literally and the path never resolves. Confirmed on device.
if grep -qE '^[^#]*STEAM_CEF_GPU_CMD_PREFIX=' "$STEAM_SH"; then
    bad "novadeck-steam sets STEAM_CEF_GPU_CMD_PREFIX -- Chromium cannot exec the quoted path it becomes"
else
    ok "STEAM_CEF_GPU_CMD_PREFIX is not set"
fi

echo
echo "the reasoning stays attached"

# 5. The assertions above are worthless without the measurements behind them -- a future reader with
#    the same strings and no numbers will just delete the guard. Keep the doc, and keep the part of
#    it that is hardest to re-derive: that the hardware path is SLOWER.
if grep -q 'slower than plain CPU decode' "$DOC" && grep -q 'video-dec0' "$DOC"; then
    ok "docs/video-decode.md still records the measured result"
else
    bad "docs/video-decode.md no longer states the measured result -- the guards above lose their justification"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
