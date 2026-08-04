#!/usr/bin/env bash
# novadeck OTA publishing principal — RUNS ON THE INSTANCE, as root. Creates the unprivileged user
# GitHub Actions publishes as, and hands it the docroot. Ship the whole ota/ tree and run it from
# there, the same way setup-server.sh is run:
#
#   tar cz ota | ssh -i <admin key> ubuntu@updates.novadeck.cloud-ip.cc \
#                    'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-ci-user.sh'
#
# Idempotent and re-runnable: a second run is a no-op that still re-reports the state it found.
#
# WHY A SEPARATE USER AT ALL, since a key is a key. The key that publishes from the workstation logs
# in as `ubuntu`, who is in the `sudo` group with NOPASSWD. Putting that key in a CI secret does not
# grant "may write one directory" — it grants root on the host every device in the field fetches
# from, and there is no clean recovery from that. Contrast the signing key, where a leak is answered
# by minting a new release cert from the offline root: no device change, no keyring update, no
# reflash. So CI gets its own principal, and the blast radius of a leaked CI secret is exactly the
# set of bytes CI is allowed to publish anyway.
#
# WHY NOT A FORCED COMMAND, which is the reflex answer and is what TODO.md originally proposed.
# `command="rrsync /srv/novadeck-ota"` covers rsync and nothing else, and publish-bundle.sh is not
# an rsync wrapper: it runs `mkdir -p`, `df -kP`, `mv -f && chmod`, `sha256sum` and a `bash -s`
# prune over ssh, in that order, with the pointer flip LAST. Every one of those would have to be
# whitelisted by a wrapper that then becomes a second, unversioned copy of the publish protocol —
# two things that must change together and will therefore eventually disagree. A user with no sudo
# and no group memberships beyond its own is the same bound, enforced by the kernel instead of by a
# shell script, and it does not constrain what publish-bundle.sh may grow into.
#
# WHAT THIS USER CANNOT DO, and it is worth being precise because "unprivileged" is doing real work
# here: no sudo (it is in no groups but its own), no password (login is by key only), no shell
# beyond what an ssh command needs, and no write access anywhere outside $DOCROOT. It can serve
# arbitrary bytes to the fleet under $DOCROOT — that is its whole job, and it is why the DEVICE
# verifies the RAUC signature rather than trusting the server it fetched from.
#
# THE SHARED-GROUP DETAIL. `ubuntu` stays able to publish by hand (docs/ota.md's rollback path is
# `ssh ubuntu@... mv`, and `make publish-bundle` from the workstation must keep working), so the
# docroot is owned by $OWNER but group-shared with `ubuntu` and setgid, so files created by either
# principal land in the group the other can act on. Without the setgid bit a directory created by
# one is unwritable by the other, and the symptom arrives months later as a publish that fails on
# `mkdir` for a NEW channel while the existing one works fine.
set -euo pipefail

DOCROOT="${NOVADECK_OTA_DOCROOT:-/srv/novadeck-ota}"
OWNER="${NOVADECK_OTA_OWNER:-otapub}"
# Who else may write the docroot. The human admin account, so the workstation publish path and the
# documented by-hand rollback keep working after this script re-owns the tree.
COPUBLISHER="${NOVADECK_OTA_COPUBLISHER:-ubuntu}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PUBKEY_SRC="${NOVADECK_OTA_CI_PUBKEY:-$HERE/ci-publish.pub}"

say()  { printf '[ci-user] %s\n' "$*"; }
warn() { printf '[ci-user] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ci-user] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$PUBKEY_SRC" ] || die "no public key beside this script: $PUBKEY_SRC
  Ship the whole tree, not just this file:
    tar cz ota | ssh <host> 'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-ci-user.sh'"

# Validated before anything is created: a malformed authorized_keys line locks nothing out but
# publishes nothing either, and sshd reports it only in its own log on the next connection attempt.
ssh-keygen -l -f "$PUBKEY_SRC" >/dev/null 2>&1 || die "$PUBKEY_SRC is not a valid ssh public key"
KEYLINE="$(grep -v '^[[:space:]]*\(#.*\)\?$' "$PUBKEY_SRC" | head -1)"
[ "$(grep -c -v '^[[:space:]]*\(#.*\)\?$' "$PUBKEY_SRC")" -eq 1 ] \
  || die "$PUBKEY_SRC holds more than one key. One principal, one key: two keys in here means two
  things can publish and only one of them is in a secret anyone remembers rotating."

# --- 1. the user ----------------------------------------------------------------------------------
# A system account (--system): no aging, no password, and outside the normal uid range so it does not
# collide with a human added later. /usr/sbin/nologin is NOT used — it would refuse `ssh host cmd`
# too, which is the entire protocol here. /bin/bash with no password and no sudo is the bound.
if id "$OWNER" >/dev/null 2>&1; then
  say "user $OWNER already exists (uid $(id -u "$OWNER"))"
else
  say "creating system user $OWNER"
  adduser --system --group --shell /bin/bash --home "/home/$OWNER" --disabled-password "$OWNER" \
    >/dev/null || die "could not create $OWNER"
fi

# Asserted, not assumed. This is the one property the whole design rests on, and a user quietly
# added to `sudo` later would make every comment above this line a lie while everything kept working.
groups_of="$(id -nG "$OWNER")"
for g in sudo admin adm wheel root lxd docker; do
  case " $groups_of " in
    *" $g "*) die "$OWNER is in the '$g' group. That defeats the point of this account: the CI key
  would grant more than docroot write. Remove it (deluser $OWNER $g) and re-run." ;;
  esac
done
say "$OWNER groups: $groups_of (no privilege escalation path)"

# Password login disabled outright, not merely unset. `adduser --disabled-password` leaves `!` in
# the shadow field, which is already unusable; `passwd -l` is belt-and-braces and idempotent.
passwd -l "$OWNER" >/dev/null 2>&1 || true

# The co-publisher needs the OWNER's group to write the setgid docroot.
if id "$COPUBLISHER" >/dev/null 2>&1; then
  if id -nG "$COPUBLISHER" | tr ' ' '\n' | grep -qx "$OWNER"; then
    say "$COPUBLISHER is already in group $OWNER"
  else
    adduser "$COPUBLISHER" "$OWNER" >/dev/null
    say "added $COPUBLISHER to group $OWNER (workstation publishing keeps working)"
    warn "$COPUBLISHER's EXISTING ssh sessions still have the old group set — a publish from an
  already-open session will fail on permissions until it reconnects. Log out and back in."
  fi
else
  warn "no such user '$COPUBLISHER' — skipping the co-publisher group. 'make publish-bundle' from
  the workstation will not be able to write $DOCROOT."
fi

# --- 2. the key -----------------------------------------------------------------------------------
# RESTRICTIONS, and what each one is actually for. `restrict` is the allowlist form: it turns off
# port forwarding, agent forwarding, X11, pty and user-rc in one word, and — the reason to prefer it
# over spelling out today's four `no-*` options — it turns off whatever OpenSSH adds NEXT, instead of
# silently permitting it. Nothing here needs a pty: rsync, `bash -s` over stdin and every `ssh host
# cmd` in publish-bundle.sh run fine without one.
#
# No `command=` for the reason in the header. No `from=` either: GitHub's hosted runners have no
# stable egress range, so a source restriction would be either useless (0.0.0.0/0) or a publish that
# breaks the first time Azure reassigns a prefix, with a log that says only "Permission denied".
#
# The 0755 on the home directory is not cosmetic: sshd REFUSES an authorized_keys under a
# group- or world-writable home and says so only in its own log, so the symptom at the CI end is a
# bare "Permission denied (publickey)" that looks like a wrong key.
HOMEDIR="$(getent passwd "$OWNER" | cut -d: -f6)"
[ -n "$HOMEDIR" ] || die "$OWNER has no home directory in passwd"
SSHDIR="$HOMEDIR/.ssh"
AUTH="$SSHDIR/authorized_keys"
install -d -o "$OWNER" -g "$OWNER" -m 0755 "$HOMEDIR"
install -d -o "$OWNER" -g "$OWNER" -m 0700 "$SSHDIR"
ENTRY="restrict $KEYLINE"
if [ -f "$AUTH" ] && grep -qxF "$ENTRY" "$AUTH"; then
  say "authorized_keys already carries this key with the same restrictions"
else
  # Written whole rather than appended: this account has exactly one key by design, and an append
  # that runs twice with a rotated key leaves the OLD one authorized — the precise failure a key
  # rotation is performed to prevent.
  printf '# novadeck CI publishing key. Installed by ota/setup-ci-user.sh from ota/ci-publish.pub.\n' >"$AUTH"
  printf '# The matching PRIVATE key is the OTA_SSH_KEY secret in the release-signing environment.\n' >>"$AUTH"
  printf '%s\n' "$ENTRY" >>"$AUTH"
  chown "$OWNER:$OWNER" "$AUTH"
  chmod 0600 "$AUTH"
  say "installed the CI key: $(ssh-keygen -l -f "$PUBKEY_SRC" | awk '{print $2}')"
fi

# --- 3. the docroot -------------------------------------------------------------------------------
# 2775: setgid, so everything created under it inherits the group both principals share. nginx reads
# it as www-data through o+rx, so the owner never needs to be www-data and publishing never needs
# sudo — the same property setup-server.sh relies on, with the owner changed.
[ -d "$DOCROOT" ] || die "no $DOCROOT — run ota/setup-server.sh first; this script re-owns a docroot,
  it does not create the server."
chown -R "$OWNER:$OWNER" "$DOCROOT"
chmod 2775 "$DOCROOT"
# -type d only. The bundles themselves stay 0644 (publish-bundle.sh sets that explicitly after the
# rename); a setgid bit on a regular file means something else entirely and must not be sprayed on.
find "$DOCROOT" -type d -exec chmod 2775 {} +
say "docroot $DOCROOT is $OWNER:$OWNER, mode 2775 (setgid, group-writable by $COPUBLISHER)"

say "done. Verify from OUTSIDE the instance, with the CI PRIVATE key, which is the only test that
  means anything — 'it works as root' proves nothing about the principal CI will be:"
say "  ssh -i <ci key> $OWNER@\$(hostname -f) 'id; touch $DOCROOT/.probe && rm $DOCROOT/.probe && echo WRITABLE'"
say "  ssh -i <ci key> $OWNER@\$(hostname -f) 'sudo -n true' # must FAIL"
