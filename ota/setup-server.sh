#!/usr/bin/env bash
# novadeck OTA server bootstrap — Phase 3. RUNS ON THE INSTANCE, as root. Ship the whole ota/ tree
# and run it from there, in one command:
#
#   tar cz ota | ssh -i <key> ubuntu@updates.novadeck.cloud-ip.cc \
#                    'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-server.sh'
#
# NOT `ssh 'sudo bash -s' < setup-server.sh`, even though that is the tidier-looking invocation: this
# script has to install ota/nginx-novadeck-ota.conf, and a lone stdin stream cannot carry it. The
# alternative is embedding a copy of the vhost in a heredoc here, which makes two files that must be
# edited together and will therefore eventually disagree — the exact drift the vhost's own header
# refuses --nginx over. One source of truth: the conf next to this script.
#
# It is a bootstrap, not a config manager: idempotent, re-runnable, and a second run is a no-op that
# still re-reports the state it found.
#
# IT NEVER OPENS A PORT. This is a public host on a public IP, and a script that quietly widens a
# firewall is how a host ends up more exposed than anyone chose. It DETECTS both layers and reports
# what is blocking; opening a port is a decision a person makes, with the exact command printed here.
#
# THE TWO FIREWALL LAYERS, and why both have to be checked separately (this cost a session):
#
#   1. OCI VCN security lists / NSGs, in Oracle's console, outside this machine entirely. They DROP,
#      silently. A blocked port therefore TIMES OUT after ~10s.
#   2. The instance-local iptables. Oracle's Ubuntu images ship an INPUT chain whose last rule is
#      `REJECT --reject-with icmp-host-prohibited`. That REJECT answers, so a blocked port fails
#      FAST — in one RTT, with EHOSTUNREACH (the kernel's rendering of ICMP admin-prohibited).
#
# So the errno from outside is the cheap discriminator, and it distinguishes three states with no
# console access at all: timeout = VCN, EHOSTUNREACH = local iptables, ECONNREFUSED = both layers
# open and nothing is listening yet. Only the third means "your problem is on this box".
#
# The iptables trap specifically: the ACCEPT rules must be INSERTED BEFORE the trailing REJECT
# (`-I INPUT <n>`), not appended (`-A`). An appended ACCEPT lands after the REJECT, is never reached,
# and changes nothing while looking exactly like a fix in `iptables -S`.
set -euo pipefail

DOMAIN="${NOVADECK_OTA_DOMAIN:-updates.novadeck.cloud-ip.cc}"
DOCROOT="${NOVADECK_OTA_DOCROOT:-/srv/novadeck-ota}"
# Who owns the docroot, i.e. who publish-bundle.sh rsyncs in as. nginx reads it as www-data through
# the o+rx below, so the owner never needs to be www-data and publishing never needs sudo.
#
# `otapub`, not `ubuntu`, and this script does not create it — ota/setup-ci-user.sh does, and dies
# below if it has not run. The two are ordered that way because the CI account is the thing that
# must NOT have sudo, and a server bootstrap that silently invents privileged-adjacent accounts is
# how that property gets lost. Set NOVADECK_OTA_OWNER=ubuntu to bring up a server without a CI
# principal at all; publishing then only works from the workstation.
OWNER="${NOVADECK_OTA_OWNER:-otapub}"
# Mode 2775, not 0755: setgid so files created by EITHER publishing principal (otapub from CI,
# ubuntu by hand) land in a group the other can act on. Dropping this back to 0755 does not break
# anything until the next by-hand rollback or the next new channel, which is the worst possible
# time to discover it — so it is set here as well as in setup-ci-user.sh, and both must agree.
DOCROOT_MODE=2775
# Certbot's registration address. Not cosmetic: it is the only warning anybody gets if the renewal
# timer breaks, and an expired cert takes every device's update check offline with no device-side
# symptom beyond "unreachable".
EMAIL="${NOVADECK_OTA_EMAIL:-simons.philippe@gmail.com}"
# THE CHANNELS A DEVICE CAN BE POINTED AT. There is no picker in Settings — that work was dropped
# with PR #82 — so a device reaches a channel through OTA_CHANNEL: the environment, then
# /etc/novadeck/ota.conf (root, and only a dev card ships one), then ~/.config/novadeck/ota.conf,
# which is the only one a user on a release device can write. Keep this list and what
# release-bundle.yml can publish in step; a channel a device can name and the server does not have
# is a 404. This is not what MAKES a channel work (publish-bundle.sh runs `mkdir -p` on the
# destination, so the first publish to a new channel creates it either way); it is what makes a
# freshly bootstrapped server look like the fleet's, so `ls $DOCROOT` answers "which channels exist"
# with the same list a device believes in.
#
# An empty channel directory is the correct resting state — see the note below the loop that creates
# them: a device fetching a channel with no latest.json gets a 404, fails closed and exits 7.
CHANNELS="${NOVADECK_OTA_CHANNELS:-stable beta}"

HERE="$(cd "$(dirname "$0")" && pwd)"
VHOST_SRC="${NOVADECK_OTA_VHOST:-$HERE/nginx-novadeck-ota.conf}"
SITE=/etc/nginx/sites-available/novadeck-ota
LIVE="/etc/letsencrypt/live/$DOMAIN"

say()  { printf '[ota-setup] %s\n' "$*"; }
warn() { printf '[ota-setup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[ota-setup] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$VHOST_SRC" ] || die "no vhost beside this script: $VHOST_SRC
  Ship the whole tree, not just this file:
    tar cz ota | ssh <host> 'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-server.sh'"

# --- 1. the firewall, reported and not touched ---------------------------------------------------

check_iptables() {
  command -v iptables >/dev/null 2>&1 || { warn "no iptables binary — cannot check the local layer"; return 0; }

  # Rule POSITION is the whole point, so walk the chain in order rather than grepping for a match:
  # an ACCEPT that sits after the catch-all reads identically to a working one in an unordered grep,
  # and that is precisely the bug this check exists to catch.
  local n=0 reject_at=0 port
  local -A open=()
  while IFS= read -r rule; do
    n=$((n + 1))
    # A rule only counts as "open" if it ACCEPTs and is reached, i.e. sits before the catch-all.
    # Matching on --dport alone would score a `--dport 80 -j DROP` as open.
    if [ "$reject_at" -eq 0 ] && [[ $rule == *"-j ACCEPT"* ]]; then
      for port in 80 443; do
        # The trailing space is load-bearing: without it `--dport 8080` matches the 80 pattern.
        [[ $rule == *"--dport $port "* ]] && open[$port]=$n
      done
    fi
    if [ "$reject_at" -eq 0 ] && [[ $rule == *"-j REJECT"* || $rule == *"-j DROP"* ]]; then
      # A catch-all only: a REJECT that names a port blocks that port, not everything after it.
      [[ $rule != *"--dport "* ]] && reject_at=$n
    fi
  done < <(iptables -S INPUT 2>/dev/null | tail -n +2)

  local blocked=0
  for port in 80 443; do
    if [ -n "${open[$port]:-}" ]; then
      say "iptables: tcp/$port ACCEPT at rule ${open[$port]} (before the catch-all at ${reject_at:-none}) — ok"
    elif [ "$reject_at" -gt 0 ]; then
      warn "iptables: tcp/$port is NOT accepted before the catch-all REJECT at rule $reject_at"
      warn "  fix, and note -I not -A (an appended rule lands after the REJECT and does nothing):"
      warn "    iptables -I INPUT $reject_at -p tcp -m state --state NEW --dport $port -j ACCEPT"
      warn "    netfilter-persistent save"
      blocked=1
    else
      say "iptables: no catch-all REJECT in INPUT; tcp/$port is not blocked locally"
    fi
  done
  return $blocked
}

say "checking the instance-local firewall (the VCN layer is in Oracle's console, not here)"
if ! check_iptables; then
  die "the local firewall would block this server. Nothing was changed — apply the rules above and re-run.
  If the ports look open here but the host is still unreachable, the block is the OTHER layer:
  a probe that TIMES OUT is the VCN dropping silently; EHOSTUNREACH is this chain."
fi

# --- 2. packages ---------------------------------------------------------------------------------
# python3-certbot-nginx is installed but NOT used as an installer (see the vhost's header on why
# --nginx is refused). It is here because certbot's nginx plugin is also what `certbot renew` uses to
# reload the service after a successful renewal without a separate deploy hook.
need=()
for pkg in nginx certbot python3-certbot-nginx rsync; do
  dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
done
if [ ${#need[@]} -gt 0 ]; then
  say "installing: ${need[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}"
else
  say "nginx, certbot and rsync are already installed"
fi

# --- 3. the docroot ------------------------------------------------------------------------------
id "$OWNER" >/dev/null 2>&1 || die "no such user '$OWNER' to own the docroot.
  If that is 'otapub', it is the CI publishing account and this script does not create it:
    bash $HERE/setup-ci-user.sh    # then re-run this one
  To stand up a server with no CI principal, re-run with NOVADECK_OTA_OWNER=ubuntu."
install -d -o "$OWNER" -g "$OWNER" -m "$DOCROOT_MODE" "$DOCROOT"
install -d -o "$OWNER" -g "$OWNER" -m "$DOCROOT_MODE" "$DOCROOT/.well-known" "$DOCROOT/.well-known/acme-challenge"
for ch in $CHANNELS; do
  install -d -o "$OWNER" -g "$OWNER" -m "$DOCROOT_MODE" "$DOCROOT/$ch"
  say "channel: $DOCROOT/$ch"
done
# A channel with no latest.json is the CORRECT resting state between releases, not a gap: the client
# gets a 404, fails closed and exits 7 silently. A placeholder pointing at a bundle that is not there
# would be worse — it would offer an update whose download 404s after the user said yes.

# --- 4. the certificate, and the ordering problem it creates --------------------------------------
#
# The real vhost cannot load until the certificate exists (nginx refuses to start on a missing
# ssl_certificate), and the certificate cannot be issued until something answers HTTP-01 on port 80.
# So: a minimal HTTP-only vhost first, issue, then swap in the real one.
if [ -s "$LIVE/fullchain.pem" ]; then
  say "certificate already present at $LIVE — skipping issuance"
else
  say "no certificate yet; bringing up a temporary HTTP-only vhost for the ACME challenge"
  cat >"$SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $DOCROOT;
    location /.well-known/acme-challenge/ { }
    location / { return 404; }
}
EOF
  ln -sfn "$SITE" /etc/nginx/sites-enabled/novadeck-ota
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || die "the temporary vhost does not parse — this is a bug in $0"
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx

  say "requesting a certificate for $DOMAIN (HTTP-01 over port 80)"
  certbot certonly --webroot -w "$DOCROOT" -d "$DOMAIN" \
    --email "$EMAIL" --agree-tos --no-eff-email --non-interactive || die "certbot failed.
  HTTP-01 validates over PLAIN HTTP from the internet, so the usual causes are, in order:
    - the A record for $DOMAIN does not point at this instance
    - tcp/80 is blocked at the VCN layer (a probe from outside TIMES OUT rather than being refused)
    - rate limit: 5 failures per account per hostname per hour"
fi

# --- 5. the real vhost ---------------------------------------------------------------------------
# Copied from the repo file, never generated here. The domain and docroot are substituted so a
# non-default NOVADECK_OTA_DOMAIN yields a coherent vhost rather than one that silently still names
# the committed default in half its directives.
install -m 0644 "$VHOST_SRC" "$SITE"
sed -i "s|updates\.novadeck\.cloud-ip\.cc|$DOMAIN|g; s|/srv/novadeck-ota|$DOCROOT|g" "$SITE"

ln -sfn "$SITE" /etc/nginx/sites-enabled/novadeck-ota
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "the installed vhost does not parse; nothing was reloaded, the previous config is still serving"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx
say "nginx reloaded with the novadeck-ota vhost"

# --- 6. renewal ----------------------------------------------------------------------------------
#
# TWO SEPARATE THINGS HAVE TO WORK, and only the first is automatic.
#
# 1. certbot renews the certificate on disk. Its own timer does this, twice a day, acting at 30 days
#    remaining — so there are ~60 attempts before expiry and a transient failure is harmless.
#
# 2. nginx starts SERVING the renewed certificate. This does NOT happen by itself. nginx reads its
#    certificates at startup and holds them in memory, and `certonly` — which is what this script
#    uses, so that certbot never rewrites the committed vhost — installs nothing and reloads
#    nothing. Without a deploy hook the renewal succeeds, the log says so, and the server keeps
#    presenting the OLD certificate until it expires 30 days later. Every device then fails its
#    update check on a TLS error, and the only warning anyone got was the renewal SUCCEEDING.
#
# The hook runs only on an actual renewal, not on every timer tick.
HOOK=/etc/letsencrypt/renewal-hooks/deploy/10-reload-nginx.sh
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >"$HOOK" <<'HOOK_EOF'
#!/bin/sh
# Installed by novadeck's ota/setup-server.sh. certbot runs this after a successful renewal.
# nginx caches certificates in memory at startup; without this reload it would keep serving the
# expiring one for another 30 days despite a renewal that reported success.
set -e
# nginx -t writes its SUCCESS message to stderr, and certbot reports any hook stderr as "ran with
# error output" — so echoing it unconditionally trains you to ignore the one line that would matter.
# Speak only on failure.
if ! out=$(nginx -t 2>&1); then
    printf '%s\n' "$out" >&2
    exit 1
fi
systemctl reload nginx
HOOK_EOF
chmod 0755 "$HOOK"
say "deploy hook installed: ${HOOK##*/} (reloads nginx after a renewal)"

# Certbot's own timer, not a cron line of ours. Asserted rather than assumed: a disabled timer is
# silent for ~60 days and then takes the whole fleet's update check down at once.
if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
  say "certbot.timer is enabled; next run: $(systemctl show certbot.timer -p NextElapseUSecRealtime --value)"
else
  warn "certbot.timer is NOT enabled — the certificate will expire in ~90 days with no warning"
  warn "  fix: systemctl enable --now certbot.timer"
fi

# --- 7. cap the journal --------------------------------------------------------------------------
# Ubuntu ships journald with NO SystemMaxUse, so the default applies: 10% of the filesystem, capped
# at 4G. On this 96G disk that is 4G of logs on a box whose entire job is serving static files — and
# it is the only thing here that grows without bound. Found 2026-08-03 at 242M.
#
# Why it matters more here than the raw number suggests: the free space on this instance is the
# retention budget for published bundles. NOVADECK_OTA_KEEP=3 at ~4G each is ~12G, and
# publish-bundle.sh does a df check BEFORE it uploads and REFUSES if the room is not there. An
# uncapped journal is therefore not just untidy; it is a slow leak pointed at the one resource a
# publish needs, and it would surface as a refused release rather than as a disk-space alert.
#
# A drop-in rather than an edit to journald.conf, so a distribution upgrade cannot silently revert
# it and so this script stays idempotent. 200M keeps weeks of history on a machine this quiet.
JOURNALD_DROPIN=/etc/systemd/journald.conf.d/10-novadeck-cap.conf
install -d -m 0755 /etc/systemd/journald.conf.d
cat >"$JOURNALD_DROPIN" <<'JOURNALD_EOF'
# Installed by novadeck's ota/setup-server.sh. See the rationale there.
[Journal]
SystemMaxUse=200M
JOURNALD_EOF
chmod 0644 "$JOURNALD_DROPIN"
# journald applies the new cap on restart and vacuums to it immediately; --vacuum-size does the same
# to what is already on disk without waiting for the next rotation.
systemctl restart systemd-journald
journalctl --vacuum-size=200M >/dev/null 2>&1 || true
say "journal capped at 200M (now: $(journalctl --disk-usage | sed 's/^Archived and active journals take up //'))"

say "done. Verify from OUTSIDE the instance, which is the only place the answer means anything:"
say "  curl -I https://$DOMAIN/healthz"
