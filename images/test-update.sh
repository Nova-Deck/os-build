#!/usr/bin/env bash
# Offline test for /usr/bin/novadeck-update — the OTA client SteamUI drives.
#
#   images/test-update.sh
#
# WHY THIS FILE EXISTS. The caller is the Steam client and the contract is not ours to choose: it
# was read out of the baked steamui.so. Steam PARSES STDOUT. `check` printing the wrong thing is not
# a cosmetic bug — anything on stdout that is not a version string becomes "an update is available,
# called <that>", and a stray traceback would offer the fleet an update named `Traceback`. Every
# case below is really one assertion: does the shipped file honour a contract we do not control.
#
# The second reason is duplicate detection. Steam refuses to re-offer a version it already applied,
# so an identity that changes between two calls makes one update look like two, and an identity
# that never changes makes a real update invisible. That rule is written TWICE — in shell in
# images/genbundle.sh and in Python here — and `identity-rules-agree` below is the only thing that
# makes them stay the same rule. Phase 2 exists because those two strings had drifted apart.
#
# HOW IT WORKS: the real, shipped fs-overlay/usr/bin/novadeck-update is executed — not a copy, not a
# sed-mangled variant. It exposes the environment seams documented in its own header
# (NOVADECK_RELEASE_FILE, NOVADECK_OTA_CONFIG, NOVADECK_OTA_STAGE, NOVADECK_STEAM_LOGINUSERS,
# NOVADECK_CURL, NOVADECK_OTA_URL) and they exist for this file. curl is stubbed on disk so no test
# touches the network. Nothing here needs rauc, a bus, a server or a device.
#
# WHAT THIS CANNOT COVER: the install half. `apply`'s D-Bus conversation with rauc needs a bus, and
# the only evidence that matters about a real install is a hardware one (see TODO.md). What is
# covered is everything up to InstallBundle, which is where every decision gets made.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/fs-overlay/usr/bin/novadeck-update"
GENBUNDLE="$ROOT/images/genbundle.sh"
[ -f "$CLIENT" ] || { echo "no novadeck-update: $CLIENT" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# --- the sandbox ---------------------------------------------------------------------------------
#
# A curl stub rather than a real server: it answers from files under $W/www, keyed by the URL path,
# which is enough to exercise every branch the client has. It also RECORDS each request, so a case
# can assert that a fetch did NOT happen — that is the only way to prove the disk-space guard runs
# before the download rather than after it, which is the whole point of that guard.
mkdir -p "$W/bin" "$W/www" "$W/stage"
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Faithful enough for the two shapes the client uses: a plain GET to stdout, and -o <dest> for the
# bundle. Exits 22 like the real curl's -f on a missing document.
url=""; dest=""
# The FULL argv, not just the path: the stall-abort case asserts which flags the download carries
# and the manifest fetch does not, and those are invisible in requests.log.
printf '%s\n' "$*" >> "$WWW/../argv.log"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#*://}"; path="${path#*/}"
printf '%s\n' "$path" >> "$WWW/../requests.log"
src="$WWW/$path"
[ -f "$src" ] || exit 22
if [ -n "$dest" ]; then cp "$src" "$dest"; else cat "$src"; fi
STUB
chmod +x "$W/bin/curl"

# Steam is logged in unless a case says otherwise: the login gate is tested explicitly, and every
# other case would otherwise pass for the wrong reason.
printf '"users"\n{\n"7656119"\n{\n"AccountName" "someone"\n}\n}\n' >"$W/loginusers.vdf"

release_file() { # <version> [build] [mode] -> path
  local f="$W/release-$1"
  { echo "NOVADECK_VARIANT=unified"
    echo "NOVADECK_BUILD=${2:-20260101T000000Z}"
    echo "NOVADECK_VERSION=$1"
    echo "NOVADECK_GIT=abc1234"
    echo "NOVADECK_MODE=${3:-release}"
  } >"$f"
  printf '%s' "$f"
}

manifest() { # <channel> <json>
  mkdir -p "$W/www/$1"
  printf '%s\n' "$2" >"$W/www/$1/latest.json"
}

bundle_file() { # <channel> <name> <bytes>
  mkdir -p "$W/www/$1"
  head -c "$3" /dev/zero >"$W/www/$1/$2"
}

# Runs the SHIPPED client. Sets OUT/ERR/RC. Extra env comes in as VAR=VAL arguments.
run() { # <arg...> -- with env assignments allowed before the first non-assignment
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  : >"$W/requests.log"
  : >"$W/argv.log"
  OUT="$(env PATH="$W/bin:$PATH" WWW="$W/www" \
      NOVADECK_CURL="$W/bin/curl" \
      NOVADECK_OTA_URL="https://updates.example" \
      NOVADECK_OTA_CONFIG="$W/nonexistent.conf" \
      NOVADECK_OTA_STAGE="$W/stage" \
      NOVADECK_STEAM_LOGINUSERS="$W/loginusers.vdf" \
      "${envs[@]}" python3 "$CLIENT" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

requests() { wc -l <"$W/requests.log" | tr -d ' '; }

# =================================================================================================
CASE="probe"
# --supports-duplicate-detection is how Steam asks whether it may dedupe by the printed version.
# Exit 0 opts in. Getting this wrong silently disables the mechanism the rest of the file protects.
run --supports-duplicate-detection
[ "$RC" = 0 ] && ok "exits 0 (opts in to duplicate detection)" \
              || bad "exit $RC, expected 0 — Steam would not dedupe"

# =================================================================================================
CASE="no-update"
manifest stable '{"version":"1.0.0","bundle":"novadeck-1.0.0.raucb","size":100}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=stable check
[ "$RC" = 7 ] && ok "exit 7 when the server offers what we run" \
              || bad "exit $RC, expected 7"
# "Prints nothing" is a separate assertion from the exit code, and the more important one: Steam
# reads stdout regardless of the status.
[ -z "$OUT" ] && ok "stdout is empty" \
              || bad "printed '$OUT' — Steam parses stdout as an available version"

# =================================================================================================
CASE="update-available"
manifest stable '{"version":"1.1.0","bundle":"novadeck-1.1.0.raucb","size":100}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=stable check
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC, expected 0"
[ "$OUT" = "1.1.0" ] && ok "prints exactly the version" \
                     || bad "printed '$OUT', expected '1.1.0'"

# =================================================================================================
CASE="duplicate-detection"
# The same check twice must print the SAME string. A version derived from anything time-varying
# would make one update look like two, and Steam would re-offer it forever.
first="$OUT"
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=stable check
[ "$OUT" = "$first" ] && ok "two checks print the same identity ('$OUT')" \
                      || bad "identity changed between calls: '$first' then '$OUT'"

# =================================================================================================
CASE="not-logged-in"
# The OOBE gate. The stub this client replaced existed to keep the update screen from blocking
# onboarding, and a multi-gigabyte download before the user reaches the library is the wrong first
# impression. No login -> no update, and no request either.
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=stable \
    NOVADECK_STEAM_LOGINUSERS="$W/absent.vdf" check
[ "$RC" = 7 ] && [ -z "$OUT" ] && ok "exit 7, silent, before any login exists" \
                              || bad "exit $RC out='$OUT', expected a silent 7"
[ "$(requests)" = 0 ] && ok "made no request at all" \
                      || bad "fetched $(requests) URL(s) before a login existed"

# =================================================================================================
CASE="unreachable-server"
# Fail CLOSED. A check that cannot reach the server must not answer "yes", and must not crash: an
# unhandled traceback on stdout would be read as a version string.
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=missing check
[ "$RC" = 7 ] && ok "exit 7 when the manifest 404s" || bad "exit $RC, expected 7"
[ -z "$OUT" ] && ok "stdout stays empty" || bad "printed '$OUT'"
case "$ERR" in *Traceback*) bad "leaked a traceback" ;; *) ok "reported the reason on stderr" ;; esac

# =================================================================================================
CASE="malformed-manifest"
manifest broken '{"version": "1.1.0", oops'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=broken check
[ "$RC" = 7 ] && [ -z "$OUT" ] && ok "unparseable JSON -> silent 7" \
                              || bad "exit $RC out='$OUT'"

# =================================================================================================
CASE="bundle-name-is-a-redirect-primitive"
# `bundle` is concatenated into a URL the client then fetches. Left unchecked it aims the device at
# another host or another path. The signature would still reject whatever came back, but a manifest
# must not be able to point this device anywhere at all.
i=0
for evil in '../../etc/passwd' 'http://elsewhere/x.raucb' '/etc/passwd' 'a/b.raucb' '.hidden'; do
  i=$((i+1))
  manifest "evil$i" "{\"version\":\"9.9.9\",\"bundle\":\"$evil\",\"size\":100}"
  run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL="evil$i" check
  [ "$RC" = 7 ] && [ -z "$OUT" ] && ok "rejected bundle=$evil" \
                                || bad "ACCEPTED bundle=$evil (exit $RC, out='$OUT')"
done

# =================================================================================================
CASE="missing-size"
# The size guard is what makes the disk check possible at all; a manifest without one must not be
# treated as "zero bytes needed".
manifest nosize '{"version":"9.9.9","bundle":"novadeck-9.9.9.raucb"}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=nosize check
[ "$RC" = 7 ] && ok "manifest with no usable size -> 7" || bad "exit $RC, expected 7"

# =================================================================================================
CASE="insufficient-disk"
# BEFORE the download, not after. Discovering this at the end costs the whole transfer, over Wi-Fi,
# after the user said yes. The request log is what proves the ordering.
bundle_file big novadeck-9.9.9.raucb 1024
manifest big '{"version":"9.9.9","bundle":"novadeck-9.9.9.raucb","size":999999999999999}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=big
[ "$RC" = 7 ] && ok "exit 7 when the bundle cannot fit" || bad "exit $RC, expected 7"
# One request: the manifest. A second would mean the bundle download started anyway.
[ "$(requests)" = 1 ] && ok "did not start the download" \
                      || bad "made $(requests) requests — the space guard ran after the fetch"

# =================================================================================================
CASE="download-stall-abort"
# The download runs with --max-time 0, because a 4G transfer must not die at the 30s that suits a
# small manifest. That lifts the only thing that would ever end a WEDGED transfer, so the stall
# guard has to replace it: without it a dead connection hangs forever, Steam sits on a frozen
# progress bar, and a device with no serial console has nothing left but a power-cycle.
# Asserted on the argv the client actually ran, since neither flag is visible in requests.log.
bundle_file stall novadeck-9.9.9.raucb 4096
manifest stall '{"version":"9.9.9","bundle":"novadeck-9.9.9.raucb","size":4096}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=stall
dl="$(grep -- ' -o ' "$W/argv.log" | head -1)"
mf="$(grep -v -- ' -o ' "$W/argv.log" | grep -- 'latest.json' | head -1)"
case "$dl" in
  *"--speed-limit 1024"*"--speed-time 120"*) ok "the download aborts on a sustained stall" ;;
  "") bad "no download request was recorded — the case proves nothing" ;;
  *) bad "the download carries no stall abort: $dl" ;;
esac
# The manifest keeps its own 30s cap. A throughput rule sized for a 4G file is the wrong shape for
# a 200-byte document, where "under 1 KiB/s for two minutes" is not a stall, it is arithmetic.
case "$mf" in
  *--speed-limit*) bad "the manifest fetch inherited the download's throughput rule: $mf" ;;
  "") bad "no manifest request was recorded — the case proves nothing" ;;
  *) ok "the manifest fetch keeps its own timeout" ;;
esac

# =================================================================================================
CASE="apply-progress"
# Steam's bar reads stdout. Every line must be N%, forward-only. The install then fails here (no
# bus), which is expected and must still leave stdout clean.
bundle_file ok novadeck-9.9.9.raucb 4096
manifest ok '{"version":"9.9.9","bundle":"novadeck-9.9.9.raucb","size":4096}'
run NOVADECK_RELEASE_FILE="$(release_file 1.0.0)" NOVADECK_OTA_CHANNEL=ok
badline=""; last=-1; mono=1
while read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    *%) n="${line%\%}"; case "$n" in ''|*[!0-9]*) badline="$line" ;;
          *) [ "$n" -le "$last" ] && mono=0; last="$n" ;; esac ;;
    *) badline="$line" ;;
  esac
done <<<"$OUT"
[ -z "$badline" ] && ok "stdout carries only N% lines" \
                  || bad "non-progress line on stdout: '$badline'"
[ "$mono" = 1 ] && ok "percentages are forward-only" || bad "progress went backwards"
[ "$last" -ge 0 ] && ok "emitted progress (reached ${last}%)" || bad "emitted no progress at all"

# =================================================================================================
CASE="bundle-not-left-behind"
# The staged bundle is unlinked on failure as well as success. Leaving multi-gigabyte files behind
# fills /home silently, and the user never asked to keep them.
left="$(find "$W/stage" -name '*.raucb' 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "no bundle left in the staging directory after a failed install" \
               || bad "$left bundle(s) left behind in $W/stage"

# =================================================================================================
CASE="identity-rules-agree"
#
# THE ONE CASE THAT IS NOT ABOUT THE CLIENT. The rule "version when it is real, build timestamp
# otherwise" is implemented twice — in shell in images/genbundle.sh and in Python in the client —
# and nothing but this makes them the same rule. Phase 2 exists because they drifted: the bundle was
# named from a date while the image called itself something else, so the comparison the entire
# update path rests on was between two unrelated strings, and a device could be offered its own
# build forever or never be offered a real one.
#
# genbundle.sh is not run (it needs rauc and a 6G image); its rule is extracted and evaluated the
# same way the shell would. If that extraction stops matching the file, this case must be updated
# WITH it — which is the point at which someone re-reads both rules.
shell_identity() { # <version> <build>
  if [ -n "$1" ] && [ "$1" != dev ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
grep -q 'IMG_VERSION" != dev' "$GENBUNDLE" \
  && ok "genbundle.sh still keys on version!=dev (the rule mirrored below)" \
  || bad "genbundle.sh's identity rule changed shape — re-read it against identity_of() and update this test"

for pair in "1.4.0|20260101T000000Z" "dev|20260102T030405Z" "|20260103T000000Z" "1.4.0-rc.1|20260104T000000Z"; do
  v="${pair%%|*}"; b="${pair##*|}"
  want="$(shell_identity "$v" "$b")"
  # The client's answer for the same release file, taken through `status` — the only subcommand
  # that prints the device's own identity without needing a server.
  run NOVADECK_RELEASE_FILE="$(release_file "$v" "$b")" NOVADECK_OTA_CHANNEL=missing status
  got="$(printf '%s\n' "$OUT" | sed -n 's/^device: *\([^ ]*\).*/\1/p')"
  [ "$got" = "$want" ] && ok "identity('${v:-<empty>}','$b') = '$got' in both" \
                       || bad "DRIFT for version='${v:-<empty>}' build='$b': genbundle says '$want', client says '$got'"
done

# =================================================================================================
printf '\ntest-update.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
