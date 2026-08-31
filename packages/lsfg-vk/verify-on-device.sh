#!/usr/bin/env bash
# Phase 6 hardware gate for issue #81 — does the frame-generation layer actually engage?
#
#   packages/lsfg-vk/verify-on-device.sh root@<ip> [appid]
#
# Phase 1 measured the generation pipeline in ISOLATION and said it fits a frame budget. This
# asks the different question that benchmark could not: with the layer staged in the guest, the
# session defaulting it off, the plugin turning it on for one game, and a real game running under
# gamescope -- does any of that plumbing actually connect?
#
# WHY NOT JUST LOOK AT AN FPS COUNTER. Upstream documents that performance overlays frequently
# cannot see generated frames: Vulkan layer load order is not deterministic, and an overlay loaded
# BEFORE lsfg-vk sits on the wrong side of it. MangoHud is therefore not evidence here, in either
# direction. gamescope's stats.pipe is independently unreliable on this device (it once read 58
# while the game was at 44). So this script does not ask how fast anything is: it asks whether the
# layer is LOADED, whether it CHOSE our profile, and whether the GPU is doing more work than it
# would otherwise -- three things that can be read directly and are hard to misinterpret.
#
# Run it with the game ALREADY RUNNING. Nothing here launches anything: a game started over ssh
# renders behind SteamUI and would not be a fair test.
set -euo pipefail

PROG="${0##*/}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEVICE="${1:-}"
[ -n "$DEVICE" ] || { echo "usage: $PROG <user@host> [appid]" >&2; exit 2; }
WANT_APPID="${2:-}"

SSHKEY="${SSHKEY:-$ROOT/work/dev-ssh/id_ed25519}"
# accept-new, not because host keys do not matter but because this probe exists to be pointed at
# a FRESHLY FLASHED card: host keys are generated per device on first boot, so a reflash always
# presents a new one, and BatchMode would otherwise refuse rather than prompt. It still refuses a
# CHANGED key for a host already known, which is the case worth refusing.
SSHOPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
# IdentitiesOnly: without it ssh offers every key the agent holds first and the card drops the
# connection with "Too many authentication failures" before reaching this one -- which reads like
# a dead device rather than a key-selection problem.
[ -f "$SSHKEY" ] && SSHOPTS+=(-i "$SSHKEY" -o IdentitiesOnly=yes)
dssh() { ssh "${SSHOPTS[@]}" "$DEVICE" "$@"; }

# TOTAL GPU nanoseconds for a pid, across every DRM client it owns.
#
# NOT `sort -rn | head -1`. That took the single BUSIEST fd, which is correct only while the
# process has one DRM client -- and lsfg-vk creates its OWN device, so switching frame generation
# on splits the work across two clients and the max-of-one figure silently DROPS. Measured: a
# GPU-bound title read 92.6% with the layer off and 57% with it on, while presenting MORE frames.
# That is not physical; it was this measurement, and it would have been read as frame generation
# somehow costing less than nothing.
#
# Dedupe by drm-client-id before summing: dup'd descriptors give one fdinfo entry EACH for the
# same client, so a naive sum over files double-counts as readily as the max under-counted.
gpu_ns() {
  dssh "python3 - '$1' <<'PY'
import glob, re, sys
pid = sys.argv[1]
seen = {}
for f in glob.glob('/proc/' + pid + '/fdinfo/*'):
    try:
        t = open(f).read()
    except Exception:
        continue
    cid = re.search(r'^drm-client-id:\s*(\d+)', t, re.M)
    eng = re.search(r'^drm-engine-gpu:\s*(\d+)', t, re.M)
    if cid and eng:
        seen[cid.group(1)] = int(eng.group(1))
print(sum(seen.values()))
PY" 2>/dev/null || echo 0
}

PASS=0; FAIL=0; INFO=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  --    %s\n' "$1"; INFO=$((INFO+1)); }
say()  { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------------------------------------
say "device"
dssh '
  m=$(tr -d "\0" </sys/firmware/devicetree/base/model 2>/dev/null); echo "  model:   ${m:-unknown}"
  c=$(tr "\0" " " </sys/firmware/devicetree/base/compatible 2>/dev/null); echo "  soc:     ${c:-unknown}"
  echo "  release: $(sed -n "s/^NOVADECK_VERSION=//p" /etc/novadeck-release 2>/dev/null)  $(sed -n "s/^NOVADECK_GIT=//p" /etc/novadeck-release 2>/dev/null)"
'

# ---------------------------------------------------------------------------------------------
# 1. The image half. If these fail nothing downstream can work, and the fix is a rebuild, not
#    anything the user did.
# ---------------------------------------------------------------------------------------------
say "image"
for f in /usr/share/novadeck/guestos-x86-mesa/usr/lib/liblsfg-vk-layer.so \
         /usr/share/novadeck/guestos-x86-mesa/usr/lib/liblsfg-vk-layer.x86.so \
         /usr/share/novadeck/guestos-x86-mesa/usr/bin/lsfg-vk-cli; do
  dssh "test -s '$f'" && ok "staged: ${f##*/}" || bad "missing from the payload: $f"
done

# THE HOST (aarch64) HALF. Everything above is the GUEST payload, which covers native x86-64
# Linux titles only. A Proton title presents through the HOST's aarch64 Vulkan stack and never
# sees the guest tree at all -- /run/gfx and /usr/share/guestos are not even mounted in its
# container. So these two files are the entire Proton path, and until 2026-08-30 this script
# could not see them: it reported a clean green run for an image in which they were absent.
for f in /usr/lib/liblsfg-vk-layer.so \
         /usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json; do
  dssh "test -s '$f'" && ok "host layer installed: $f" || bad "the aarch64 host layer is missing: $f -- Proton titles CANNOT get frame generation"
done

# ASSERT THE HOST LIBRARY IS ACTUALLY aarch64. The guest and host libraries share a filename, so
# a staging slip that copied the x86 build to /usr/lib would satisfy every check above and then
# be rejected by the loader at runtime with nothing in the log -- the layer would simply never
# appear. e_machine lives at offset 18 of the ELF header: 183 is AArch64, 62 is x86-64. od is
# used rather than readelf because the device image carries coreutils, not binutils.
mach="$(dssh "od -An -tu2 -j18 -N2 /usr/lib/liblsfg-vk-layer.so 2>/dev/null | tr -d ' '" || true)"
case "$mach" in
  183) ok "the host layer is aarch64, matching the driver it sits in front of" ;;
  "")  bad "could not read the ELF header of the host layer" ;;
  62)  bad "the host layer is x86-64, NOT aarch64 -- the wrong build was staged at /usr/lib" ;;
  *)   bad "the host layer has an unexpected ELF machine ($mach)" ;;
esac

# The merged mount is the one that matters at runtime: the payload can be perfect and the overlay
# still not be there, because the fstab row is `nofail` by design (a broken guest must cost x86
# games, never a boot). That makes this exact failure SILENT.
if dssh 'test -s /usr/share/guestos/fex-mesa/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json'; then
  ok "the layer manifest is visible through the merged guest mount"
else
  bad "the merged guest mount does not expose the manifest -- the overlay is nofail, so this is silent"
fi

# The relative library_path is what lets one manifest resolve under both our overlay and Valve's
# /run/gfx republish. Read it off the DEVICE, not the build tree.
lp="$(dssh "sed -n 's/.*\"library_path\": \"\\(.*\\)\".*/\\1/p' /usr/share/guestos/fex-mesa/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json" || true)"
case "$lp" in
  ../../../lib/*) ok "library_path is manifest-relative on device ($lp)" ;;
  "")             bad "could not read library_path from the staged manifest" ;;
  *)              bad "library_path is not manifest-relative ($lp) -- the loader will drop the layer silently" ;;
esac

# ---------------------------------------------------------------------------------------------
# 2. The default-off half. The layer is implicit; without this it loads into everything, and its
#    constructor writes a config file into the user's home as a side effect.
# ---------------------------------------------------------------------------------------------
say "default off"
# pgrep -x, NOT pgrep -f. `-f` matches full command lines, and the remote shell running this very
# check has "gamescope-wl" in its own -- so -f returns THAT pid, whose environ has no session
# variables at all, and the check reports a failure that is entirely its own doing. (Measured: it
# did exactly that on the first run.) `-x` matches the process NAME and cannot match the shell.
# environ is NUL-separated, so it has to be translated before grep can see line boundaries.
gs_pid="$(dssh 'pgrep -x gamescope-wl | head -1' || true)"
if [ -z "$gs_pid" ]; then
  bad "no gamescope-wl process -- is the session up?"
elif dssh "tr '\0' '\n' </proc/$gs_pid/environ 2>/dev/null | grep -q '^DISABLE_LSFGVK=1$'"; then
  ok "gamescope (pid $gs_pid) carries DISABLE_LSFGVK=1 -- the session default reached the compositor"
else
  bad "gamescope (pid $gs_pid) does not carry DISABLE_LSFGVK=1 -- the session export did not take"
fi

# ---------------------------------------------------------------------------------------------
# 3. What the plugin wrote. Both files, because they are different files with different owners
#    and either can be right while the other is wrong.
# ---------------------------------------------------------------------------------------------
say "configuration"
dssh 'echo "  --- conf.toml"; sed "s/^/    /" /home/deck/.config/lsfg-vk/conf.toml 2>/dev/null || echo "    (absent)"'
# NO BACKSLASHES IN THIS HEREDOC, and no nested same-quotes in a format string. The delimiter is
# unquoted, so the remote shell unescapes \" before python ever sees it -- which turned
# f"...{g.get(\"enabled\")}..." into an f-string containing bare double quotes and a SyntaxError
# on any python below 3.12. With stderr discarded that surfaced as "(absent or unreadable)", and
# the next reader went looking for a missing file that was in fact present and correct. Percent
# formatting keeps every quote single-level. stderr is NOT discarded any more: a reader who is
# told a file is unreadable is entitled to the reason.
dssh 'echo "  --- game-tweaks.json env sections"; python3 - <<PY || echo "    (absent or unreadable)"
import json
d = json.load(open("/etc/novadeck/game-tweaks.json"))
for appid, g in sorted((d.get("games") or {}).items()):
    env = g.get("env") or {}
    if "DISABLE_LSFGVK" in env or "LSFGVK_PROFILE" in env:
        print("    %s: enabled=%s env=%s" % (appid, g.get("enabled"), env))
PY'

# ---------------------------------------------------------------------------------------------
# 4. The running game. This is the part nothing offline can answer.
# ---------------------------------------------------------------------------------------------
say "running game"
# Find the process that owns the GPU rather than guessing by name: the executable is one thing for
# a native title and <Game>.exe for a Proton one, and under FEX the comm is neither.
# PICK THE PROCESS DOING THE MOST GPU WORK, not the first one holding a DRM fd. Several system
# processes hold one without rendering: seatd (it brokers the device), gamescope itself, mangoapp
# (the overlay), the reaper. Taking the first match found seatd on one run and mangoapp on
# another, and then reported three confident failures about "the game" -- including "the game
# still carries DISABLE_LSFGVK", which for the overlay is CORRECT behaviour.
#
# A real game is the largest consumer of GPU time by a wide margin, so ranking by the
# drm-engine-gpu counter picks it out without needing to know its name -- which is just as well,
# since the name is the binary for a native title, <Game>.exe for a Proton one, and neither under
# FEX. The exclusion list is belt-and-braces for an idle session where nothing is rendering.
gpid="$(dssh 'best=""; bestv=0
              for f in /proc/*/fdinfo/*; do
                v=$(sed -n "s/^drm-engine-gpu:[[:space:]]*\([0-9]*\).*/\1/p" "$f" 2>/dev/null | head -1)
                [ -n "$v" ] || continue
                p=${f#/proc/}; p=${p%%/*}
                case "$(tr -d "\0" </proc/$p/comm 2>/dev/null)" in
                  gamescope-wl|gamescopereaper|mangoapp|steamwebhelper|steam|seatd|sddm*|Xwayland) continue ;;
                esac
                [ "$v" -gt "$bestv" ] 2>/dev/null && { bestv=$v; best=$p; }
              done
              [ "$bestv" -gt 0 ] 2>/dev/null && echo "$best"' || true)"

if [ -z "$gpid" ]; then
  note "nothing is rendering except the compositor -- start a game, then re-run"
  printf '\n%d passed, %d failed, %d informational\n' "$PASS" "$FAIL" "$INFO"
  [ "$FAIL" -eq 0 ]
  exit
fi
note "GPU client pid $gpid ($(dssh "tr -d '\0' </proc/$gpid/comm" 2>/dev/null || echo '?'))"
# A near-idle top consumer means nothing is really rendering -- say so rather than letting the
# reader assume the lines below describe a game.
iba="$(gpu_ns "$gpid")"; sleep 1; ibb="$(gpu_ns "$gpid")"
gbusy=""
[ "${iba:-0}" -gt 0 ] 2>/dev/null && [ "${ibb:-0}" -gt 0 ] 2>/dev/null && gbusy=$(( (ibb-iba)/10000000 ))
if [ -n "$gbusy" ] && [ "$gbusy" -lt 3 ] 2>/dev/null; then
  note "...but it is using ~${gbusy}% of the GPU, so no game is actually rendering right now"
fi

appid="$(dssh "tr '\0' '\n' </proc/$gpid/environ 2>/dev/null | sed -n 's/^SteamAppId=//p' | head -1" || true)"
[ -n "$appid" ] && note "SteamAppId=$appid" || note "no SteamAppId in the client environ"
if [ -n "$WANT_APPID" ] && [ -n "$appid" ] && [ "$WANT_APPID" != "$appid" ]; then
  bad "the running game is $appid, not the $WANT_APPID this run was meant to check"
fi

# ESTABLISH WHETHER FRAME GENERATION IS EVEN TURNED ON FOR THIS TITLE **BEFORE** JUDGING ANYTHING.
# This used to be computed further down, after the layer-mapped verdict had already been banked --
# so a deliberate FG-off baseline run reported "the layer genuinely did not load" as a FAIL, while
# the env section a few lines later correctly called the very same state expected. An unmapped
# layer is the CORRECT outcome when the session default is tombstoning it; it is only a failure
# for a game FG is enabled for.
is_enabled=""
if [ -n "$appid" ]; then
  is_enabled="$(dssh "python3 -c \"
import json,sys
try: d=json.load(open('/etc/novadeck/game-tweaks.json'))
except Exception: sys.exit()
env=((d.get('games') or {}).get('$appid') or {}).get('env') or {}
print('yes' if 'DISABLE_LSFGVK' in env and env['DISABLE_LSFGVK'] is None else '')
\" 2>/dev/null" || true)"
fi
[ "$is_enabled" = "yes" ] || note "frame generation is NOT enabled for this appid -- this is a baseline run, not a test of the layer"

# IS THIS EVEN A FAIR TEST? Establish the game's presentation path BEFORE judging the layer,
# because "no layer in maps" has two completely different causes and only one of them is a bug.
#
# lsfg-vk is a Vulkan layer, so it engages for anything that PRESENTS through Vulkan -- which is
# far wider than "a Vulkan game": D3D9/10/11 through DXVK and D3D12 through VKD3D-Proton all
# translate to Vulkan, and the layer sits below them. What it cannot touch is a title presenting
# through OpenGL (native GL, or Wine on the WineD3D path). Reporting "the layer never loaded" for
# a GL title would be true and completely misleading.
vk_maps="$(dssh "grep -oE 'lib(vulkan|dxvk|vkd3d)[^ /]*' /proc/$gpid/maps 2>/dev/null | sort -u | tr '\n' ' '" || true)"
gl_maps="$(dssh "grep -oE 'lib(GL|GLX_[a-z]*|gallium[^ /]*)\.so[^ /]*' /proc/$gpid/maps 2>/dev/null | sort -u | tr '\n' ' '" || true)"
if [ -n "$vk_maps" ]; then
  note "presentation path looks VULKAN: $vk_maps"
else
  note "no Vulkan libraries in the game's maps${gl_maps:+ (GL instead: $gl_maps)}"
fi

# THE definitive engagement check: the layer either is in the address space or it is not.
layer_mapped=""
if dssh "grep -q liblsfg-vk-layer /proc/$gpid/maps"; then
  layer_mapped=yes
  ok "liblsfg-vk-layer is mapped into the game (NECESSARY, not sufficient -- see the log below)"
  dssh "grep -o '/[^ ]*liblsfg-vk-layer[^ ]*' /proc/$gpid/maps | sort -u | sed 's/^/    /'"
elif [ -z "$vk_maps" ]; then
  # Not a failure of ours. Say so plainly rather than banking a FAIL that sends the next reader
  # looking at the packaging.
  note "liblsfg-vk-layer is not mapped, and neither is Vulkan -- this title does not present"
  note "through Vulkan, so it CANNOT use frame generation. Pick another game; this run proves"
  note "nothing either way about the layer."
elif [ "$is_enabled" != "yes" ]; then
  note "liblsfg-vk-layer is not mapped -- CORRECT, frame generation is switched off for this title"
else
  bad "liblsfg-vk-layer is NOT mapped into a Vulkan game -- the layer genuinely did not load"
fi

# IS THIS A PROTON TITLE, AND DID PRESSURE-VESSEL IMPORT OUR LAYER? These are different questions
# from "is the layer mapped", and on 2026-08-30 they were the whole failure: the env half worked
# perfectly and the layer was simply not there to import, because it did not exist for aarch64.
#
# pressure-vessel PINS the layer search path to its own overrides directory and populates it by
# importing from the HOST's /usr/share/vulkan/implicit_layer.d. That import is the single step the
# Proton path depends on, it happens inside the container's mount namespace, and it is silent when
# it finds nothing. /proc/<pid>/root reaches into that namespace from the host, so the result of
# the import can be read directly rather than inferred.
pv_path="$(dssh "tr '\0' '\n' </proc/$gpid/environ 2>/dev/null | sed -n 's/^VK_IMPLICIT_LAYER_PATH=//p' | head -1" || true)"
if [ -n "$pv_path" ]; then
  # A PRESSURE-VESSEL CONTAINER IS NOT THE SAME THING AS A PROTON TITLE, and conflating the two
  # cost this script a false FAIL on a run that was entirely correct. Valve's FEX compat tool puts
  # NATIVE x86-64 Linux titles in a pressure-vessel container as well; that path resolves the
  # layer from the guest republish at /run/gfx and never needs the host import at all. So detect
  # Windows-ness from the process itself rather than from the container.
  is_proton=""
  exe="$(dssh "readlink /proc/$gpid/exe" 2>/dev/null || true)"
  gcomm="$(dssh "tr -d '\0' </proc/$gpid/comm" 2>/dev/null || true)"
  case "$exe$gcomm" in *[Pp]roton*|*wine*|*.exe) is_proton=yes ;; esac
  dssh "grep -qE '(wine|dxvk|vkd3d)' /proc/$gpid/maps" 2>/dev/null && is_proton=yes
  if [ -n "$is_proton" ]; then
    note "PROTON title in a pressure-vessel container (exe=${exe##*/} comm=$gcomm)"
  else
    note "native title in a pressure-vessel container (exe=${exe##*/}) -- the guest path, not Proton"
  fi

  # PRESSURE-VESSEL RENAMES WHAT IT IMPORTS. Manifests arrive in the overrides directory as
  # <NN>-<arch>-linux-gnu.json, never under their original filename -- so looking for
  # VkLayer_LSFGVK_frame_generation.json there can never match, for any title, however healthy.
  # (That is precisely the false FAIL referred to above.) Match on the layer NAME inside the
  # file instead, and record which arch each import was for, because the arch is the whole
  # question: a Proton title presents through the host aarch64 driver and can only be served by
  # the aarch64 import.
  imported="$(dssh "python3 - '$gpid' '$pv_path' <<'PY'
import json, glob, os, sys
pid, paths = sys.argv[1], sys.argv[2]

def load(f):
    # pressure-vessel imports a HOST layer as a SYMLINK to /run/host/... , which is a path that
    # only resolves INSIDE the container's mount namespace. Read from outside via /proc/<pid>/root
    # and the kernel resolves that absolute target against the HOST root, where /run/host does not
    # exist -- so the manifest reads as missing and the layer reads as never imported. That is a
    # false negative on the one file the Proton path depends on, and it reported FAIL on a run in
    # which frame generation was demonstrably working. /run/host IS the host root, so strip the
    # prefix and read the file directly.
    try:
        return (json.load(open(f)) or {}).get('layer') or {}
    except Exception:
        pass
    try:
        t = os.readlink(f)
    except OSError:
        return {}
    if t.startswith('/run/host/'):
        try:
            return (json.load(open(t[len('/run/host'):])) or {}).get('layer') or {}
        except Exception:
            return {}
    return {}

found = {}
for d in paths.split(':'):
    for f in sorted(glob.glob('/proc/' + pid + '/root' + d + '/*.json')):
        layer = load(f)
        if not layer:
            continue
        if 'LSFGVK' not in (layer.get('name') or '').upper():
            continue
        base = os.path.basename(f)
        # Imports that pressure-vessel COPIES are named <NN>-<arch>-linux-gnu.json, so the arch is
        # in the filename. Imports it SYMLINKS to the host keep a bare <NN>.json with no arch in
        # it at all -- and those are exactly the host aarch64 ones, which is the case that matters
        # most here. Fall back to the symlink target rather than reporting '?' for the only layer
        # a Proton title can use.
        arch = next((a for a in ('aarch64', 'x86_64', 'i386') if a in base), '')
        if not arch:
            arch = 'aarch64' if os.path.islink(f) and os.readlink(f).startswith('/run/host/') else '?'
        found[arch] = (base, layer.get('name') or '?', layer.get('library_path') or '?')
for a in sorted(found):
    print('    %-8s %s  %s -> %s' % (a, found[a][0], found[a][1], found[a][2]))
print('ARCHES=' + ','.join(sorted(found)))
PY" || true)"
  printf '%s\n' "$imported" | grep -v '^ARCHES=' | grep . || true
  arches="$(printf '%s' "$imported" | sed -n 's/^ARCHES=//p')"

  if [ -n "$is_proton" ]; then
    case ",$arches," in
      *,aarch64,*) ok "pressure-vessel imported the aarch64 host layer -- the Proton path is served" ;;
      *)           bad "no aarch64 LSFGVK layer was imported (${arches:-none}) -- a Proton title presents through the HOST driver, so it gets no frame generation" ;;
    esac
  elif [ -n "$arches" ]; then
    note "imported arches: $arches (informational -- a native title loads the guest x86 layer from /run/gfx)"
  else
    note "no LSFGVK layer was imported into this container"
  fi
else
  note "not a pressure-vessel container -- the layer is resolved directly, not via an import"
fi

# The env half, read from the process that actually got it rather than from the file we wrote.
#
# THESE ARE ONLY FAILURES FOR A GAME FRAME GENERATION IS TURNED ON FOR. For anything else,
# carrying DISABLE_LSFGVK is exactly right -- it is the session default doing its job -- and
# asserting its absence unconditionally turns correct behaviour into a red FAIL.
env_dump="$(dssh "tr '\0' '\n' </proc/$gpid/environ 2>/dev/null | grep -E '^(DISABLE_)?LSFGVK' || true")"
if [ "$is_enabled" != "yes" ]; then
  note "frame generation is NOT enabled for this title, so the env below is expected, not a fault"
  printf '%s\n' "$env_dump" | sed 's/^/    /' 
  note "enable it in the Frame Gen plugin, relaunch the game, and re-run to test the real path"
else
  if printf '%s' "$env_dump" | grep -q '^DISABLE_LSFGVK='; then
    bad "the game still carries DISABLE_LSFGVK -- the per-game tombstone did not survive to exec"
  else
    ok "DISABLE_LSFGVK is absent from the game's environ (the tombstone survived)"
  fi
  if printf '%s' "$env_dump" | grep -q '^LSFGVK_PROFILE=novadeck-'; then
    ok "LSFGVK_PROFILE reached the game: $(printf '%s' "$env_dump" | sed -n 's/^LSFGVK_PROFILE=//p')"
  else
    bad "LSFGVK_PROFILE did not reach the game -- it would fall back to name matching, or to nothing"
  fi
fi

# THE LAYER BEING MAPPED IS NECESSARY, NOT SUFFICIENT -- and this section exists because that
# distinction cost a hardware run. On 2026-08-30 the probe reported 9 passed / 0 failed with
# liblsfg-vk-layer.so mapped from /run/gfx, both env vars delivered and the profile named. The
# layer was doing nothing: it had rejected the config ("Unsupported configuration version (must
# be 2)"), failed to initialise, and the loader had SKIPPED it -- leaving the library mapped and
# inert. The only evidence anywhere was four lines in the session log.
#
# So the log is not a nicety here. It is the difference between "loaded" and "working", and an
# error in it is a FAILURE regardless of how green everything above looks.
say "layer log"
SESSION_LOG=/home/deck/.local/share/sddm/wayland-session.log
# BOUND THE LOG TO THE CURRENT LAUNCH. The session log spans the whole session, so a failure
# from an earlier launch sits there for ever -- and reading the whole tail turned a working run
# into a FAIL on exactly the errors the previous run had already fixed. The layer prints
# "Using profile with name" once per initialisation, so the last one marks where this game's
# layer activity begins; anything above it belongs to a previous launch and is history, not
# evidence. (This is the mirror of the failure that made this section necessary: first a stale
# PASS, then a stale FAIL. Neither is worth trusting without a boundary.)
lsfg_log="$(dssh "grep -a -i lsfg '$SESSION_LOG' 2>/dev/null | awk '/Using profile with name/ {buf=\"\"} {buf = buf \$0 \"\\n\"} END {printf \"%s\", buf}'" || true)"
if [ -z "${lsfg_log//[[:space:]]/}" ]; then
  # No profile line at all yet: fall back to the raw tail so a first-launch failure is still seen.
  lsfg_log="$(dssh "grep -a -i lsfg '$SESSION_LOG' 2>/dev/null | tail -40" || true)"
fi
for f in /tmp/lsfg-vk.log /home/deck/lsfg-vk.log; do
  extra="$(dssh "[ -s '$f' ] && tail -40 '$f'" 2>/dev/null || true)"
  [ -n "$extra" ] && lsfg_log="$lsfg_log
$extra"
done

# A LOG BLOCK IS ONLY EVIDENCE ABOUT THIS RUN IF THE LAYER IS IN THIS RUN. The session log
# outlives individual launches, so when the layer did not load at all -- a GL title, say -- the
# newest block belongs to some earlier Vulkan launch and reads as a clean success for a run in
# which nothing happened. That is the third stale-log verdict this section has produced (a stale
# PASS, then a stale FAIL, now a stale ok), so it is gated on the layer actually being mapped
# rather than on the log being non-empty.
if [ -z "${lsfg_log//[[:space:]]/}" ]; then
  note "the layer has logged nothing -- it may never have been asked to initialise"
elif [ -z "$layer_mapped" ]; then
  note "the log below is from an EARLIER launch -- the layer is not in this process, so none of"
  note "it describes the run being examined. Shown for context only, and asserted on nothing."
  printf '%s\n' "$lsfg_log" | sed 's/^/    | /'
else
  printf '%s\n' "$lsfg_log" | sed 's/^/    /'
  if printf '%s' "$lsfg_log" | grep -qi 'ERROR'; then
    bad "the layer logged an ERROR -- it is mapped but NOT running (see the lines above)"
  elif printf '%s' "$lsfg_log" | grep -qi 'Skipping layer'; then
    bad "the Vulkan loader SKIPPED the layer -- mapped, but never in the chain"
  else
    ok "the layer logged no errors"
  fi
  if printf '%s' "$lsfg_log" | grep -q 'Using profile'; then
    ok "the layer selected a profile: $(printf '%s' "$lsfg_log" | sed -n "s/.*Using profile with name '\([^']*\)'.*/\1/p" | tail -1)"
  else
    note "no 'Using profile' line yet -- relaunch the game after any config change"
  fi
fi

# GPU cost, as a sanity check rather than a verdict. Frame generation is extra compute, so an
# engaged layer should show up as MORE gpu time for the same scene -- but scenes vary, so this is
# reported and not asserted.
say "gpu time (2s sample, informational)"
ga="$(gpu_ns "$gpid")"; sleep 2; gb="$(gpu_ns "$gpid")"
if [ "${ga:-0}" -gt 0 ] 2>/dev/null && [ "${gb:-0}" -gt 0 ] 2>/dev/null; then
  awk -v d=$((gb-ga)) 'BEGIN{printf "    game GPU busy: %.1f%% of wall (summed over all DRM clients)\n", d/2e9*100}'
else
  echo '    (no drm-engine-gpu counter)'
fi
dssh "python3 - '$gpid' <<'PY'
import glob, re, sys
pid = sys.argv[1]
seen = {}
for f in glob.glob('/proc/' + pid + '/fdinfo/*'):
    try:
        t = open(f).read()
    except Exception:
        continue
    cid = re.search(r'^drm-client-id:\s*(\d+)', t, re.M)
    eng = re.search(r'^drm-engine-gpu:\s*(\d+)', t, re.M)
    if cid and eng:
        seen[cid.group(1)] = int(eng.group(1))
# More than one client is the NORMAL shape with frame generation on -- the layer runs its
# generation pass on a device of its own. Printing the split makes that visible instead of
# leaving a reader to wonder why the total moved.
print('    DRM clients: %d' % len(seen))
PY" 2>/dev/null || true
# NOTE: there is deliberately no scanout/flip-counter read here. SM8650 exposes no
# .../crtc-0/total_framecount (checked on device: the path does not exist), so the line that used
# to live here could only ever print "(no counter)" -- and reading it as a frame rate on a device
# where it DID exist would report the PANEL refresh, not the game's rate, which is the specific
# confusion that made 144 look like a frame-generation result earlier.

printf '\n%d passed, %d failed, %d informational\n' "$PASS" "$FAIL" "$INFO"
[ "$FAIL" -eq 0 ]
