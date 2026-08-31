#!/usr/bin/env bash
# Phase 1 feasibility probe for issue #81 (frame generation via lsfg-vk).
#
# THIS IS A PROBE, NOT A BUILD STEP. Nothing in the image build reads it. It answers one question
# before we spend a package, a payload and a Decky plugin on the feature:
#
#     does the lsfg-vk frame-generation pass fit in the frame budget on Adreno?
#
# `lsfg-vk-cli benchmark` is a SYNTHETIC benchmark of the generation pipeline alone -- it needs no
# game, no Steam, no gamescope and no packaging. It allocates input images at a given resolution,
# runs the pipeline in a loop, and reports how long one iteration takes. That is exactly the
# number that decides the feature, and it is reachable with a scp and an ssh.
#
# WHAT IT STILL NEEDS: Lossless Scaling owned on Steam and installed on the device, because the
# generation shaders live in `lsfg-vk.dll` inside its depot (v2 renamed this from `Lossless.dll`;
# see .claude/plans/lsfg-vk-framegen.plan.md). Without the dll the CLI exits saying so, and that
# is a setup failure rather than a measurement.
#
# WHY THE BINARY RUNS AT ALL: it is x86_64, and this is an aarch64 device. It runs under the
# system FEX binfmt, the same path as native x86 Linux games, and renders through the guest x86
# Turnip. So the number this prints is the number a game would actually get -- emulation overhead
# on the CPU side included. That is the point; a host-arm64 measurement would flatter the result
# and would not correspond to anything we can ship (upstream publishes no arm64 build).
#
# Usage:
#   packages/lsfg-vk/probe-benchmark.sh root@192.168.1.103 [WIDTHxHEIGHT ...]
#
# Resolutions default to the panel resolution plus a lower one, so the scaling behaviour is
# visible rather than a single point.

set -euo pipefail

PROG="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/work/lsfg-vk"

# The artifact comes from payload.pin -- ONE pin, so a bump cannot move the image and leave the
# probe measuring the previous build (or the reverse, which is worse: numbers attributed to a
# version that never shipped). fetch.sh reads the same file.
PIN="$(dirname "${BASH_SOURCE[0]}")/payload.pin"
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
VERSION="$(pin_field "$PIN" version)"
URL="$(pin_field "$PIN" url)"
SHA256="$(pin_field "$PIN" sha256)"
: "${URL:?payload.pin: missing url}"; : "${SHA256:?payload.pin: missing sha256}"
# ... and it is NOT xz despite the name: dist/podman/build.sh archives with `tar cf`, no `J`.
# Extracting with `tar xJf` fails outright, so unpack format-agnostically and never assume.

DEVICE="${1:-}"
[ -n "$DEVICE" ] || { echo "usage: $PROG <user@host> [WxH ...]" >&2; exit 2; }
shift || true

RESOLUTIONS=("$@")
[ "${#RESOLUTIONS[@]}" -gt 0 ] || RESOLUTIONS=(1620x1080 1280x720)

DURATION="${DURATION:-5}"

# Dev cards bake work/dev-ssh/id_ed25519.pub into root's authorized_keys (see dev.env), so that
# is the key to offer -- and the ONLY one. Without IdentitiesOnly, ssh offers every key the agent
# holds first and the card drops the connection with "Too many authentication failures" before it
# ever reaches this one, which reads like a dead device rather than a key-selection problem.
SSHKEY="${SSHKEY:-$ROOT/work/dev-ssh/id_ed25519}"
SSHOPTS=(-o ConnectTimeout=10 -o BatchMode=yes)
if [ -f "$SSHKEY" ]; then
  SSHOPTS+=(-i "$SSHKEY" -o IdentitiesOnly=yes)
fi
# One connection reused for every benchmark case. Each `ssh` otherwise costs a fresh TCP + key
# exchange, and the sweep makes ~16 of them.
SSHOPTS+=(-o ControlMaster=auto -o ControlPath="$WORK/.ssh-%r@%h:%p" -o ControlPersist=120)

dssh() { ssh "${SSHOPTS[@]}" "$DEVICE" "$@"; }
dscp() { scp "${SSHOPTS[@]}" "$@"; }

say() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------
# 1. Fetch + verify + unpack on the host.
# ---------------------------------------------------------------------------------------------
say "fetching pinned lsfg-vk prebuilt ($VERSION)"
mkdir -p "$WORK"
tarball="$WORK/${URL##*/}"
if [ -s "$tarball" ] && printf '%s  %s\n' "$SHA256" "$tarball" | sha256sum -c --status; then
  echo "  cached, sha256 ok: ${tarball#"$ROOT"/}"
else
  curl -fsSL --retry 3 -o "$tarball" "$URL"
  printf '%s  %s\n' "$SHA256" "$tarball" | sha256sum -c --status || {
    echo "ERROR: sha256 mismatch on $URL" >&2
    echo "       got $(sha256sum <"$tarball" | cut -d' ' -f1)" >&2
    echo "       The tagged artifact should be immutable. If upstream re-rolled it, re-pin" >&2
    echo "       deliberately -- do not just update the constant." >&2
    exit 1; }
  echo "  fetched, sha256 ok"
fi

rm -rf "$WORK/unpacked"
mkdir -p "$WORK/unpacked"
tar xf "$tarball" -C "$WORK/unpacked"

cli="$WORK/unpacked/bin/lsfg-vk-cli"
[ -x "$cli" ] || { echo "ERROR: no bin/lsfg-vk-cli in the artifact (upstream changed the layout?)" >&2; exit 1; }

# The whole probe rests on this binary being the x86_64 one -- an arm64 build would measure a
# stack we cannot ship. Say so out loud rather than assuming.
file "$cli" | grep -q 'x86-64' || {
  echo "ERROR: bin/lsfg-vk-cli is not x86-64: $(file -b "$cli")" >&2; exit 1; }
echo "  cli: $(file -b "$cli" | cut -d, -f1-2)"

# ---------------------------------------------------------------------------------------------
# 2. Stage onto the device.
# ---------------------------------------------------------------------------------------------
say "staging onto $DEVICE"
dssh 'mkdir -p /tmp/lsfg-probe'
dscp -q "$cli" "$DEVICE:/tmp/lsfg-probe/lsfg-vk-cli"
dssh 'chmod +x /tmp/lsfg-probe/lsfg-vk-cli'

# ---------------------------------------------------------------------------------------------
# 3. Locate lsfg-vk.dll on the device.
#
# The CLI searches a hardcoded list of Steam library paths under $HOME/$XDG_DATA_HOME. Our games
# live on the home partition under the `deck` user, and this probe runs as root over ssh, so the
# search would come up empty even when the depot is installed. Find it ourselves and hand it over
# with LSFGVK_DLL_PATH rather than relying on the search.
# ---------------------------------------------------------------------------------------------
# ---------------------------------------------------------------------------------------------
# 2b. Identify what we are measuring.
#
# novadeck ships three GPU generations (SM8250/Adreno 650, SM8550/Adreno 740, SM8650/Adreno 750)
# and a number from one of them is not a platform default -- fp16 ratio and compute throughput
# differ across them. A results table with no SoC on it is a table nobody can safely reuse, so
# stamp every run with what produced it.
# ---------------------------------------------------------------------------------------------
say "device identity"
dssh '
  m=$(tr -d "\0" </sys/firmware/devicetree/base/model 2>/dev/null); echo "  model:      ${m:-unknown}"
  c=$(tr "\0" " " </sys/firmware/devicetree/base/compatible 2>/dev/null); echo "  compatible: ${c:-unknown}"
  for g in /sys/class/devfreq/*.gpu; do [ -e "$g" ] && echo "  gpu node:   $(basename "$g")  max=$(cat "$g/max_freq" 2>/dev/null)"; done
  for d in /sys/class/drm/card*-DSI-1/modes /sys/class/drm/card*-eDP-1/modes; do
    [ -s "$d" ] && echo "  panel:      $(head -1 "$d")"
  done
  echo "  kernel:     $(uname -r)"
'

say "locating lsfg-vk.dll"
# steamapps can also live on an added library folder, so search rather than guess the root.
dll="$(dssh 'find /home -maxdepth 8 -name "lsfg-vk.dll" -path "*Lossless Scaling*" 2>/dev/null | head -1')"

if [ -z "$dll" ]; then
  # DO NOT fall back to Lossless.dll. It parses, so the CLI gets far enough to look like it is
  # working, and then every case fails with "Unable to find base shader 'mipmaps' in DLL" -- which
  # reads like a broken pipeline rather than a setup gap. (Measured 2026-08-30: a full sweep of
  # that, twice.) v2 needs PE resource 0x80005008 (library.cpp:73), which the default-branch
  # Lossless.dll does not carry at all.
  legacy="$(dssh 'find /home -maxdepth 8 -name "Lossless.dll" -path "*Lossless Scaling*" 2>/dev/null | head -1')"
  echo "ERROR: no lsfg-vk.dll in the Lossless Scaling depot." >&2
  echo "" >&2
  if [ -n "$legacy" ]; then
    echo "  Lossless Scaling IS installed, but on its default branch:" >&2
    echo "    $legacy" >&2
    echo "" >&2
    echo "  lsfg-vk v2 ships its shaders in a separate DLL that Lossless Scaling publishes only" >&2
    echo "  on a dedicated Steam beta branch. Per upstream's install page: \"Make sure you have" >&2
    echo "  switched to the 'lsfg-vk' branch!\"" >&2
    echo "" >&2
    echo "  On the device: Steam -> Lossless Scaling -> Properties -> Betas -> 'lsfg-vk'," >&2
    echo "  let it update, then re-run this probe." >&2
    echo "" >&2
    echo "  NOTE FOR THE PRODUCT: this is a second user-visible prerequisite beyond owning" >&2
    echo "  Lossless Scaling, and nothing detects it for the user. Phase 5 has to surface it." >&2
  else
    echo "  Lossless Scaling does not appear to be installed under /home at all." >&2
    echo "  Install it, switch it to the 'lsfg-vk' beta branch, then re-run." >&2
  fi
  exit 1
fi
echo "  $dll"

# ---------------------------------------------------------------------------------------------
# 4. Sweep.
#
# Two axes that matter for a verdict, plus the fp16 A/B:
#   multiplier   2 is the honest baseline; 3/4 only matter if 2 already fits
#   flow scale   the documented quality/perf lever (1.0 .. 0.25)
#   perf mode    the "significantly lighter model"
#   fp16         v2's headline is 2x-3x on 2:1-fp16 parts, and Adreno is full-rate fp16.
#                -a turns it off, so the pair measures whether that claim lands here.
#
# `benchmark` prints Base FPS / Output FPS / Time per iteration; the iteration time is the one to
# reason with, because it compares directly against a frame budget.
# ---------------------------------------------------------------------------------------------
# Pass the dll with -d, NOT with LSFGVK_DLL_PATH.
#
# The env var is silently ignored on a first run, and that cost this probe one full sweep of
# "Unable to find lsfg-vk.dll". getOrDefault() (config.cpp) calls parseGlobalEnv() on the
# LSFGVK_ENV branch and on the config-file-exists branch -- but NOT on the branch that writes a
# fresh default config and returns it. So with no ~/.config/lsfg-vk/conf.toml yet, every
# LSFGVK_* variable is dropped on the floor and findDll() runs instead, which looks only for the
# v2 filename. benchmark checks opts.dll FIRST (benchmark.cpp:45), so -d bypasses all of it.
# Same reasoning for -a over LSFGVK_NO_FP16.
run() { # run <label> <extra-flags> <args...>
  local label="$1"; shift
  local flags="$1"; shift
  local out
  out="$(dssh "cd /tmp/lsfg-probe && ./lsfg-vk-cli benchmark -d '$dll' $flags $* -t $DURATION" 2>&1)" || {
    printf '  %-38s FAILED\n' "$label"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 0; }
  local iter base outfps
  iter="$(printf '%s' "$out"   | sed -n 's/.*Time per iteration *: *\([0-9.]*\).*/\1/p' | head -1)"
  base="$(printf '%s' "$out"   | sed -n 's/.*Base FPS *: *\([0-9.]*\).*/\1/p' | head -1)"
  outfps="$(printf '%s' "$out" | sed -n 's/.*Output FPS *: *\([0-9.]*\).*/\1/p' | head -1)"
  if [ -z "$iter" ]; then
    printf '  %-38s (unparsed)\n' "$label"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 0
  fi
  printf '  %-38s %8s ms/iter %10s base %10s out\n' "$label" "$iter" "$base" "$outfps"
}

for res in "${RESOLUTIONS[@]}"; do
  w="${res%x*}"; h="${res#*x}"
  say "benchmark @ ${w}x${h} (${DURATION}s each)"
  printf '  %-38s %11s %15s %14s\n' "case" "iteration" "base" "output"

  run "m2 flow1.00"            ""                 "-w $w -h $h -m 2 -f 1.0"
  run "m2 flow1.00 no-fp16"    "-a"               "-w $w -h $h -m 2 -f 1.0"
  run "m2 flow0.85"            ""                 "-w $w -h $h -m 2 -f 0.85"
  run "m2 flow0.50"            ""                 "-w $w -h $h -m 2 -f 0.5"
  run "m2 flow1.00 perf-mode"  ""                 "-w $w -h $h -m 2 -f 1.0 -p"
  run "m2 flow0.85 perf-mode"  ""                 "-w $w -h $h -m 2 -f 0.85 -p"
  run "m3 flow1.00"            ""                 "-w $w -h $h -m 3 -f 1.0"
  run "m4 flow0.85 perf-mode"  ""                 "-w $w -h $h -m 4 -f 0.85 -p"
done

# ---------------------------------------------------------------------------------------------
# 5. How to read it.
#
# Deliberately NOT a pass/fail verdict. The budget depends on the target framerate and on how much
# of the GPU the game itself is already using, and this benchmark measures the pass in ISOLATION
# on an otherwise idle GPU -- so it is an upper bound on what is available, never a promise. A
# case that does not fit here cannot fit under a game; one that does fit here still has to be
# proven with a game on top (Phase 6).
# ---------------------------------------------------------------------------------------------
cat <<'EOF'

== reading this
  ms/iter is the cost of generating one frame, on an IDLE GPU, with no game competing.
  Frame budget at the output rate: 60fps = 16.67ms, 90fps = 11.11ms, 120fps = 8.33ms.

  For an Nx multiplier the generated frames must ALSO fit alongside the game's own rendering,
  so a case whose ms/iter already approaches the budget here has no room left once a game is
  running. Treat these numbers as an upper bound on what is available, not as achievable fps.

  Next: record the table in issue #81 (Phase 2) before any packaging work.
EOF
