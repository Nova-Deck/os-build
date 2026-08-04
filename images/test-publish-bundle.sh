#!/usr/bin/env bash
# Offline test for ota/publish-bundle.sh — specifically its INTEGRITY GATE (step 3b).
#
#   images/test-publish-bundle.sh
#
# WHY THIS FILE EXISTS. publish-bundle.sh had three gates and only two of them looked at the bundle:
# the signature (step 1) and the mode stamp (step 2). Everything after the upload asked "is this
# being served" — a Range request, a latest.json read-back — and nothing asked "are these the bytes
# we sent". $SHA is computed from the LOCAL file before the transfer, so the hash published in
# latest.json was a claim about the workstation's copy, not the server's.
#
# That gap has no downstream backstop. The client does not check sha256 at all (docs/ota.md: the
# RAUC signature is the integrity gate, since a hash fetched from the same server proves nothing an
# attacker could not also rewrite), so corrupt bytes would surface no earlier than each device's own
# signature verification — after a ~4G download, once per device. Step 3b is the only thing standing
# between a bad upload and the fleet, and it was added after two concurrent publishes were observed
# writing the same .part with rsync --inplace, which neither detects nor refuses.
#
# THE ASSERTION THAT MATTERS is not "a mismatch is detected" but "a mismatch leaves latest.json
# ALONE". Detection that still flipped the pointer would be worse than no gate at all: it would
# publish the corrupt bundle AND report failure. Every failure case below checks the pointer.
#
# HOW IT WORKS: the real, shipped ota/publish-bundle.sh is executed — not a copy. Its seams are the
# NOVADECK_OTA_* environment variables it already documents, plus PATH: ssh, rsync, curl and rauc
# are stubbed on disk. The "server" is a local directory, so the ssh stub runs the remote command
# with bash -c and every remote-side effect (mv, chmod, sha256sum, the prune) is real shell against
# real files. Nothing here needs a network, a key, a container or a 4G bundle.
#
# WHAT THIS CANNOT COVER: that a real rsync-over-ssh to Frankfurt preserves bytes, and that a real
# rauc accepts the signature. Both are covered where they belong — the first by step 3b itself in
# production, the second by images/test-verify-signing.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH="$ROOT/ota/publish-bundle.sh"
[ -f "$PUBLISH" ] || { echo "no publish-bundle.sh: $PUBLISH" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

VERSION="9.9.9"
NAME="novadeck-$VERSION.raucb"

# --- the sandbox ---------------------------------------------------------------------------------
mkdir -p "$W/bin" "$W/srv"

# ssh: strip the option soup and the user@host, then run the command locally. $DOCROOT points into
# $W, so a remote path IS a local path and mv/chmod/sha256sum/prune all execute for real.
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

# df: a stub BINARY rather than a case in the ssh stub, because the script pipes df into awk
# (`df -kP | awk NR==2{print $4}`) and a stub that answers the whole command string swallows the
# pipeline and hands back the raw table. Stubbed at all so the space check does not make this suite
# pass or fail on how full the machine running it happens to be.
cat >"$W/bin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nx 1 1 999999999 1%% /\n'
STUB

# rsync: last two args are src and dest. Strip user@host: and copy. NOVADECK_TEST_CORRUPT makes the
# landed file differ from the source WITHOUT changing its size -- a truncation would be caught by
# the existing size check, and the point of step 3b is the corruption that is not.
cat >"$W/bin/rsync" <<'STUB'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("$a"); done
n=${#args[@]}
src="${args[$((n-2))]}"; dest="${args[$((n-1))]}"
dest="${dest#*:}"
printf 'rsync %s -> %s\n' "$src" "$dest" >> "$SSHLOG"
cp "$src" "$dest" || exit 1
if [ "${NOVADECK_TEST_CORRUPT:-0}" = 1 ] && [ "${src##*.}" = raucb ]; then
  printf 'X' | dd of="$dest" bs=1 seek=3 conv=notrunc status=none
fi
STUB

# curl: 206 for the Range probe, the file's contents for the latest.json read-back.
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""; range=0
for a in "$@"; do
  case "$a" in -r) range=1 ;; http*|https*) url="$a" ;; esac
done
printf '%s\n' "$url" >> "$CURLLOG"
path="${url#*://}"; path="${path#*/}"
src="$DOCROOT/$path"
[ -f "$src" ] || exit 22
if [ "$range" = 1 ]; then printf '206'; else cat "$src"; fi
STUB

# rauc: the signature gate and the manifest read. Both are real gates with their own coverage; here
# they only need to say yes so the cases below can reach step 3b.
cat >"$W/bin/rauc" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *--output-format=shell*)
    echo "RAUC_MF_VERSION='$VERSION'"
    echo "RAUC_MF_COMPATIBLE='novadeck'"
    echo "RAUC_META_NOVADECK_BUILD='20260101T000000Z'"
    echo "RAUC_META_NOVADECK_GIT='abc1234'"
    echo "RAUC_META_NOVADECK_MODE='release'"
    ;;
  *) echo "Verified inline signature by 'O = novadeck, CN = novadeck OTA release'" ;;
esac
STUB
chmod +x "$W/bin/ssh" "$W/bin/df" "$W/bin/rsync" "$W/bin/curl" "$W/bin/rauc"

# A bundle with real bytes, so the local sha256sum and stat are real.
BUNDLE="$W/$NAME"
head -c 4096 /dev/urandom >"$BUNDLE"

# Runs the SHIPPED publisher against the sandbox. Sets OUT/ERR/RC.
run() { # <env assignments...>
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  : >"$W/ssh.log"; : >"$W/curl.log"
  OUT="$(env PATH="$W/bin:$PATH" \
      SSHLOG="$W/ssh.log" CURLLOG="$W/curl.log" DOCROOT="$W/srv" \
      NOVADECK_OTA_HOST="updates.example" \
      NOVADECK_OTA_USER="tester" \
      NOVADECK_OTA_DOCROOT="$W/srv" \
      NOVADECK_OTA_URL="https://updates.example" \
      NOVADECK_OTA_SSH_KEY="" \
      "${envs[@]}" bash "$PUBLISH" "$BUNDLE" test 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

pointer() { cat "$W/srv/test/latest.json" 2>/dev/null; }
reset_server() { rm -rf "$W/srv"; mkdir -p "$W/srv"; }

# =================================================================================================
CASE="happy-path"
reset_server
run
[ "$RC" = 0 ] && ok "exit 0 when the landed bytes match" || bad "exit $RC, expected 0: $ERR"
printf '%s' "$ERR" | grep -q 'server-side sha256 matches' \
  && ok "says the server-side hash was checked" \
  || bad "never reported checking the uploaded bytes"
# The gate must actually reach across, not just log. Proven by the remote command, not the message.
grep -q "sha256sum .*$NAME" "$W/ssh.log" \
  && ok "hashed the file ON THE SERVER, not just locally" \
  || bad "no server-side sha256sum was ever run"
pointer | grep -q "\"bundle\": \"$NAME\"" \
  && ok "latest.json names the published bundle" \
  || bad "latest.json does not name $NAME"
# The published hash must describe the served file. This is the claim step 3b exists to make true.
served_sha="$(pointer | sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p')"
actual_sha="$(sha256sum "$W/srv/test/$NAME" | cut -d' ' -f1)"
[ -n "$served_sha" ] && [ "$served_sha" = "$actual_sha" ] \
  && ok "the sha256 in latest.json is the hash of the file on the server" \
  || bad "published sha256 '$served_sha' != served file '$actual_sha'"

# =================================================================================================
CASE="corrupt-upload-is-caught"
# The bytes change in flight and the size does not, so nothing before step 3b can notice.
reset_server
run NOVADECK_TEST_CORRUPT=1
[ "$RC" != 0 ] && ok "exit $RC -- refuses to publish bytes that changed in flight" \
               || bad "exit 0: a corrupt upload was published"
printf '%s' "$ERR" | grep -q 'CORRUPT UPLOAD' \
  && ok "names the failure as corruption, not a transport error" \
  || bad "did not say CORRUPT UPLOAD"
# THE assertion. Detection that still flipped the pointer would be worse than no gate.
[ -z "$(pointer)" ] \
  && ok "latest.json was NOT written -- the fleet is never offered the bad bundle" \
  || bad "latest.json exists after a corrupt upload: $(pointer)"
# Ordering, proven rather than assumed: step 3b sits before the readability probe, so a corrupt
# upload must die without ever asking the public URL anything.
[ ! -s "$W/curl.log" ] \
  && ok "died before the public-readability probe -- the gate is ahead of step 4" \
  || bad "reached curl despite corrupt bytes: $(cat "$W/curl.log")"

# =================================================================================================
CASE="corrupt-upload-leaves-the-previous-release"
# A channel that already serves something is the real-world case: the cost of getting this wrong is
# not a failed publish, it is taking a working update path down.
reset_server
mkdir -p "$W/srv/test"
prev='{"version":"1.0.0","bundle":"novadeck-1.0.0.raucb","size":10,"sha256":"deadbeef"}'
printf '%s\n' "$prev" >"$W/srv/test/latest.json"
head -c 10 /dev/zero >"$W/srv/test/novadeck-1.0.0.raucb"
run NOVADECK_TEST_CORRUPT=1
[ "$RC" != 0 ] && ok "still fails" || bad "exit 0 on corrupt bytes"
[ "$(pointer)" = "$prev" ] \
  && ok "the previous release is still pointed at, byte for byte" \
  || bad "latest.json was modified: $(pointer)"
[ -f "$W/srv/test/novadeck-1.0.0.raucb" ] \
  && ok "the previous bundle was not pruned by a failed publish" \
  || bad "the failed publish pruned the release the fleet is running"

# =================================================================================================
CASE="unreadable-upload-is-a-failure-not-a-shrug"
# An empty hash is the case that would quietly wave everything through if the gate tested only for
# inequality. It must fail closed.
reset_server
# Make the landed file vanish between the rename and the hash: rsync writes it, a wrapper removes it.
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
case "$*" in
  mv\ *)        bash -c "$*"; rm -f "$DOCROOT"/test/*.raucb ;;
  sha256sum\ *) exit 1 ;;
  *)            bash -c "$*" ;;
esac
STUB
chmod +x "$W/bin/ssh"
run
[ "$RC" != 0 ] && ok "exit $RC when the uploaded file cannot be hashed" \
               || bad "exit 0: published a pointer at bytes nobody could read"
printf '%s' "$ERR" | grep -q 'nobody has checked' \
  && ok "says why: it refuses to publish unverified bytes" \
  || bad "did not explain the refusal"
[ -z "$(pointer)" ] \
  && ok "latest.json was NOT written" \
  || bad "latest.json exists: $(pointer)"

# =================================================================================================
printf '\ntest-publish-bundle.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
