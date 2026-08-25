#!/usr/bin/env bash
# Offline test for ota/publish-seed.sh — the /home seed the network installer downloads.
#
#   images/test-publish-seed.sh
#
# WHY THIS FILE EXISTS. A bundle is signed, so publish-bundle.sh can gate on a signature and every
# device re-checks it. A seed is NOT signed: install/novadeck-install hashes what it downloads and
# compares it against a sha256 baked into the medium, and install/release-info builds the download
# URL out of that same pin. So the artifact's NAME is the whole contract, and the one thing this
# publisher must never do is put bytes at a name they do not hash to — a file that either serves
# nobody, or answers a medium's pin with the wrong tree and is caught only after a 3 GB download on
# a device that is already mid-install. That is the gate this suite is about.
#
# THE SECOND PROPERTY IS THAT NOTHING IS EVER OVERWRITTEN OR QUIETLY DELETED. Seeds are not
# superseded: an installer medium names exactly one, by hash, forever. A publisher that replaced a
# name in place, or pruned by default, would break media in the field rather than inconvenience
# them — and the failure lands at the seed step, after the carve.
#
# HOW IT WORKS: the real, shipped script is executed — not a copy. Its seams are the NOVADECK_OTA_*
# variables it already documents, plus PATH: ssh, rsync, curl and df are stubbed on disk. The
# "server" is a local directory, so the ssh stub runs the remote command with bash -c and every
# remote-side effect (mv, chmod, sha256sum, the prune) is real shell against real files. Same
# sandbox shape as images/test-publish-bundle.sh, deliberately.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/ota/publish-seed.sh"
[ -f "$PUBLISH" ] || { echo "no publish-seed.sh: $PUBLISH" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/bin" "$W/srv"

cat >"$W/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-i) shift 2 ;;
    *@*)   shift; break ;;
    *)     shift ;;
  esac
done
printf '%s\n' "$*" >> "$SSHLOG"
bash -c "$*"
STUB

# A stub BINARY rather than a case in the ssh stub, because the script pipes df into awk and a stub
# answering the whole command string would swallow the pipeline. Stubbed at all so the space check
# does not make this suite pass or fail on how full the machine running it happens to be.
cat >"$W/bin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 999999999 1%% /\n'
STUB

# NOVADECK_TEST_CORRUPT changes the landed bytes WITHOUT changing the size: a truncation would be
# caught by the size check, and the point of the server-side hash is the corruption that is not.
cat >"$W/bin/rsync" <<'STUB'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("$a"); done
n=${#args[@]}
src="${args[$((n-2))]}"; dest="${args[$((n-1))]}"
dest="${dest#*:}"
printf 'rsync %s -> %s\n' "$src" "$dest" >> "$SSHLOG"
cp "$src" "$dest" || exit 1
if [ "${NOVADECK_TEST_CORRUPT:-0}" = 1 ]; then
  printf 'X' | dd of="$dest" bs=1 seek=3 conv=notrunc status=none
fi
STUB

# 206 for the Range probe, so a published file reads as publicly served. NOVADECK_TEST_UNSERVED
# models the bytes being on disk and nginx not serving them.
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*|https*) url="$a" ;; esac; done
printf '%s\n' "$url" >> "$CURLLOG"
path="${url#*://}"; path="${path#*/}"
[ "${NOVADECK_TEST_UNSERVED:-0}" = 1 ] && exit 22
[ -f "$DOCROOT/$path" ] || exit 22
printf '206'
STUB
chmod +x "$W/bin/ssh" "$W/bin/df" "$W/bin/rsync" "$W/bin/curl"

# A seed with real bytes, named the way steam-seed/pack-seed.sh names it: from its own sha256.
pack() {  # <path-without-name> -> echoes the artifact path
  # ONE ASSIGNMENT PER LINE. bash expands every word of a command before performing any of its
  # assignments, so `local dir="$1" f="$dir/seed.tmp"` reads $dir while it is still unset -- which
  # under this file's `set -u` is a hard error, and the first symptom is an empty $SEED four cases
  # later rather than anything pointing here.
  local dir="$1"
  local f="$dir/seed.tmp"
  local sha
  mkdir -p "$dir"
  head -c 4096 /dev/urandom >"$f"
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  mv "$f" "$dir/steam-seed-$sha.tar.zst"
  printf '%s\n' "$dir/steam-seed-$sha.tar.zst"
}

SEED="$(pack "$W/art")"
NAME="$(basename "$SEED")"

run() {  # [env assignments...] [artifact]
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  local art="${1:-$SEED}"
  : >"$W/ssh.log"; : >"$W/curl.log"
  OUT="$(env PATH="$W/bin:$PATH" \
      SSHLOG="$W/ssh.log" CURLLOG="$W/curl.log" DOCROOT="$W/srv" \
      NOVADECK_OTA_HOST="updates.example" \
      NOVADECK_OTA_USER="tester" \
      NOVADECK_OTA_DOCROOT="$W/srv" \
      NOVADECK_OTA_URL="https://updates.example" \
      NOVADECK_OTA_SSH_KEY="" \
      "${envs[@]}" bash "$PUBLISH" "$art" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

reset_server() { rm -rf "$W/srv"; mkdir -p "$W/srv"; }

# =================================================================================================
CASE="happy-path"
reset_server
run
[ "$RC" = 0 ] && ok "exit 0 when the landed bytes match" || bad "exit $RC, expected 0: $ERR"
[ -f "$W/srv/seed/$NAME" ] \
  && ok "the seed lands in seed/, which is not a channel" \
  || bad "nothing was published to $W/srv/seed/"
grep -q "sha256sum .*$NAME" "$W/ssh.log" \
  && ok "hashed the file ON THE SERVER, not just locally" \
  || bad "no server-side sha256sum was ever run"
grep -q "seed/$NAME" "$W/curl.log" \
  && ok "and proved it is readable at the URL a medium would derive from its pin" \
  || bad "the public URL was never probed: $(cat "$W/curl.log")"
printf '%s' "$ERR" | grep -q 'hashes to its own name' \
  && ok "the name gate ran before anything moved" \
  || bad "the name was never checked against the bytes"

# =================================================================================================
CASE="a file that does not hash to its own name is refused"
# THE GATE. There is no signature on this artifact: the name IS the pin, and release-info builds the
# URL from the pin baked into the medium. Bytes published under a name they do not hash to would
# answer a medium's request with a tree the spine then refuses -- after a 1.5 GB download, and for
# every operator who tries. It refuses SAFELY (verify_sources runs before consent, so nothing is
# written), which bounds it to a wasted trip rather than a wasted device -- and a wasted trip per
# medium is still the most expensive kind of bug this publisher can ship.
reset_server
liar="$W/art/steam-seed-$(printf 'a%.0s' $(seq 64)).tar.zst"
cp "$SEED" "$liar"
run "$liar"
[ "$RC" != 0 ] && ok "exit $RC -- refused" || bad "exit 0: it published bytes under a foreign hash"
printf '%s' "$ERR" | grep -q 'does not hash to its own name' \
  && ok "and says which of the two is which" \
  || bad "the refusal does not name the mismatch: $ERR"
[ ! -s "$W/ssh.log" ] \
  && ok "nothing was uploaded, and nothing on the server was touched" \
  || bad "it reached the server before checking the name: $(cat "$W/ssh.log")"

CASE="a name that is not a seed artifact is refused"
reset_server
for n in "steam-seed-notahash.tar.zst" "steam-seed-DEADBEEF.tar.zst" "novadeck-1.0.raucb"; do
  cp "$SEED" "$W/art/$n"
  run "$W/art/$n"
  [ "$RC" != 0 ] && ok "$n is refused" || bad "$n was published"
done

# =================================================================================================
CASE="republishing the same seed is a no-op, not a re-upload"
# pack-seed.sh is deterministic, so an unchanged tree packs to the same name on every build. A
# publisher that re-sent 1.5 GB to overwrite a file with itself is one people learn to skip.
reset_server
run
: >"$W/ssh.log"
run
[ "$RC" = 0 ] && ok "exit 0" || bad "a republish failed: $ERR"
printf '%s' "$ERR" | grep -q 'already published and byte-identical' \
  && ok "it says the bytes are already there" \
  || bad "it did not recognise its own artifact: $ERR"
grep -q rsync "$W/ssh.log" \
  && bad "it re-uploaded a file that was already correct" \
  || ok "and sent nothing"

CASE="a name collision with DIFFERENT bytes is refused, never overwritten"
# Two different trees cannot share a content-addressed name, so this is corruption on one side or
# the other. Overwriting would swap the tree under every medium that pins that hash.
reset_server
run
printf 'X' | dd of="$W/srv/seed/$NAME" bs=1 seek=3 conv=notrunc status=none
before="$(sha256sum "$W/srv/seed/$NAME" | cut -d' ' -f1)"
run
[ "$RC" != 0 ] && ok "exit $RC -- refused" || bad "exit 0: it overwrote a published seed"
[ "$(sha256sum "$W/srv/seed/$NAME" | cut -d' ' -f1)" = "$before" ] \
  && ok "and the file on the server is untouched" \
  || bad "the published bytes were replaced"

# =================================================================================================
CASE="corrupt-upload-is-caught"
reset_server
run NOVADECK_TEST_CORRUPT=1
[ "$RC" != 0 ] && ok "exit $RC -- refuses bytes that changed in flight" \
               || bad "exit 0: a corrupt seed was published"
printf '%s' "$ERR" | grep -q 'CORRUPT UPLOAD' \
  && ok "and says so in those words" \
  || bad "the failure does not name the cause: $ERR"

CASE="bytes on disk that nginx does not serve are a failure"
reset_server
run NOVADECK_TEST_UNSERVED=1
[ "$RC" != 0 ] && ok "exit $RC -- present in the docroot and served to the world are different claims" \
               || bad "exit 0: it reported success for a seed nobody can fetch"

# =================================================================================================
CASE="nothing is pruned unless asked"
# The one that matters most in a year. An old seed is not stale: a medium built against it names it
# by hash and always will, so deleting it does not make that medium fetch a newer one -- it retires
# every copy of that medium. Bundles supersede each other; seeds do not.
reset_server
OLD="$(pack "$W/old")"; OLDNAME="$(basename "$OLD")"
run "$OLD"
run
[ -f "$W/srv/seed/$OLDNAME" ] \
  && ok "publishing a new seed leaves the old one in place" \
  || bad "the previous seed was deleted by default"

CASE="NOVADECK_SEED_KEEP prunes, and only when set"
reset_server
run "$OLD"
sleep 1   # ls -t orders by mtime, and both files are seconds old
run NOVADECK_SEED_KEEP=1
[ -f "$W/srv/seed/$NAME" ] \
  && ok "the seed just published survives its own prune" \
  || bad "it pruned the file it had just uploaded"
[ ! -f "$W/srv/seed/$OLDNAME" ] \
  && ok "and the older one is gone, as asked" \
  || bad "NOVADECK_SEED_KEEP=1 kept two seeds"
printf '%s' "$ERR" | grep -q 'can no longer complete an install' \
  && ok "having said out loud what that costs" \
  || bad "it pruned without warning what it breaks"

# =================================================================================================
CASE="the publisher and the installer agree on where seeds live"
# TWO HALVES OF ONE URL, WRITTEN IN TWO FILES. ota/publish-seed.sh chooses the directory under the
# docroot; install/release-info builds the URL a medium fetches from its baked pin. A drift between
# them is invisible in both files and shows up as every install 404ing on the seed, on every medium
# ever published. Same shape as the OTA URL literal that
# install/test-ui.sh binds across netcfg, novadeck-update and release-info.
pub_dir="$(sed -n 's/^DEST="\$DOCROOT\/\(.*\)"$/\1/p' "$PUBLISH" | head -1)"
rel_dir="$(sed -n 's/^SEED_PATH = "\(.*\)"$/\1/p' "$ROOT/install/release-info" | head -1)"
[ -n "$pub_dir" ] && [ "$pub_dir" = "$rel_dir" ] \
  && ok "both say '$pub_dir'" \
  || bad "publish-seed.sh publishes to '$pub_dir', release-info fetches from '$rel_dir'"
# And the same host, since the medium's pin only names the FILE.
pub_host="$(sed -n 's/^HOST="\${NOVADECK_OTA_HOST:-\(.*\)}"$/\1/p' "$PUBLISH" | head -1)"
rel_host="$(sed -n 's|^DEFAULT_URL = "https://\(.*\)"$|\1|p' "$ROOT/install/release-info" | head -1)"
[ -n "$pub_host" ] && [ "$pub_host" = "$rel_host" ] \
  && ok "and the same host by default ($pub_host)" \
  || bad "publish-seed.sh defaults to '$pub_host', release-info to '$rel_host'"

# =================================================================================================
printf '\ntest-publish-seed.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
