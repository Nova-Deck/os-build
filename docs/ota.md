# The update server

Where a device in the field gets its OS updates from. The device half — the client SteamUI drives,
the RAUC A/B install, the trial boot and rollback — is in `docs/RUNBOOK.md` and `docs/phase5.md`;
this file is the server and the act of publishing.

| | |
|---|---|
| Host | `updates.novadeck.cloud-ip.cc` → `130.61.37.34`, OCI Frankfurt |
| OS | Ubuntu 24.04 LTS, aarch64, login `ubuntu`, passwordless sudo |
| Serves | nginx 1.24, TLS via Let's Encrypt |
| Docroot | `/srv/novadeck-ota`, owned `ubuntu`, **read-only to the internet** |
| Retention | 3 bundles per channel (`NOVADECK_OTA_KEEP`) |
| Repo | `ota/` — vhost, bootstrap, publisher |

## Layout

**The docroot is the URL root.** The client's `DEFAULT_URL` carries no path prefix, so a *channel* is
the first path segment:

```
/srv/novadeck-ota/
  stable/
    latest.json               -> https://updates.novadeck.cloud-ip.cc/stable/latest.json
    novadeck-0.2.0.raucb      -> https://updates.novadeck.cloud-ip.cc/stable/novadeck-0.2.0.raucb
  .well-known/acme-challenge/ (certbot)
```

Adding a `beta` channel is a directory, not a migration. Only `stable` exists today; the client's
`OTA_CHANNEL` (in `/etc/novadeck/ota.conf`, or `NOVADECK_OTA_CHANNEL`) selects it.

**A channel with no `latest.json` is the correct resting state, not an outage.** The client gets a
404, fails closed and exits 7 — "no update available". That is exactly right between releases. A
placeholder pointing at a bundle that is not there would be worse: it would *offer* an update whose
download 404s after the user has already said yes.

### `latest.json`

```json
{ "version": "0.2.0", "build": "20260803T120000Z", "git": "abc1234",
  "bundle": "novadeck-0.2.0.raucb", "size": 3758096384, "sha256": "…" }
```

`version` is the identity Steam sees and dedupes on; it is read out of the bundle's own manifest, not
chosen at publish time. `bundle` must be a **bare filename** — the client rejects a scheme, a host, a
`/`, a `\` or a leading dot. `build` and `git` are for a human reading the file. `size` is checked
before and after the download. `sha256` is not checked by the client: the RAUC signature is the
integrity gate, and a hash in a file fetched from the same server proves nothing an attacker could
not also rewrite.

## Cutting an update

```sh
# 1. build and sign — the version must be set BEFORE the rootfs, see docs/RUNBOOK.md
NOVADECK_VERSION=0.2.0 PKIDIR=$HOME/novadeck-pki make bundle

# 2. install it on a device and confirm it boots, BEFORE anyone else gets it
ssh deck@<device> rauc install /path/to/novadeck-0.2.0.raucb

# 3. publish
NOVADECK_OTA_SSH_KEY=~/.ssh/<key> ota/publish-bundle.sh out/images/novadeck-0.2.0.raucb
```

Step 2 is not optional and is not ceremony. Nothing on the device ends an unconfirmed trial boot
(`TODO.md`), so a bundle that comes up to a black screen needs about six manual power-cycles to
recover — on a device with no serial console. Every published bundle gets a hardware install first.
That is the entire mitigation, and it was accepted as such on 2026-08-03.

`publish-bundle.sh` does, in order: verify the signature against the device keyring, read the version
back out of the bundle, check free space on the server, upload to a `.part` name and rename, prove
the bundle is readable at its public URL with a `Range` request, **flip `latest.json` last**, read
that back over HTTPS, and prune to `KEEP`. Everything before the flip is invisible to devices; the
flip is the publish.

### Rolling back a bad release

The previous bundles are still on the server — that is what `KEEP=3` is for. Edit
`stable/latest.json` to name an older one:

```sh
ssh ubuntu@updates.novadeck.cloud-ip.cc \
  "cd /srv/novadeck-ota/stable && sed -i 's/novadeck-0.2.0.raucb/novadeck-0.1.0.raucb/' latest.json"
```

`size` and `sha256` must be updated to match, or the client will refuse the download at its size
check. This only helps devices that have not updated yet; one that already installed the bad bundle
recovers through the boot failsafe, not through the server.

## The server

```sh
# stand it up, or re-run it — idempotent, and a second run reports state without changing it
tar cz ota | ssh -i <key> ubuntu@updates.novadeck.cloud-ip.cc \
  'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-server.sh'

# is it alive?
curl -I https://updates.novadeck.cloud-ip.cc/healthz
```

`/healthz` exists because `stable/` is legitimately empty between releases, so every other probe
answers 404 and a dead server looks exactly like a quiet one.

The vhost is `ota/nginx-novadeck-ota.conf` and **the repo is authoritative** — `setup-server.sh`
copies it. This is why certbot is run as `certonly --webroot` and never `--nginx`: the `--nginx`
installer edits the vhost in place, and the running config would stop matching the committed one
with nothing to signal the drift.

### Certificate renewal

Two things have to work and only the first is automatic:

1. **certbot renews it on disk.** `certbot.timer`, twice daily, acting at 30 days remaining — about
   60 attempts before expiry, so a transient failure is harmless. Verify with
   `sudo certbot renew --dry-run`.
2. **nginx starts serving the new one.** This does *not* happen by itself. nginx reads certificates
   at startup and holds them in memory, and `certonly` installs nothing and reloads nothing. Without
   a deploy hook the renewal succeeds, the log says so, and the server keeps presenting the old
   certificate until it expires — every device then failing its update check on a TLS error, with
   the only prior warning being a renewal that *succeeded*.

`setup-server.sh` installs `/etc/letsencrypt/renewal-hooks/deploy/10-reload-nginx.sh` for exactly
that. If you rebuild this host from scratch by hand, that hook is the step that gets forgotten.

Expiry notices go to `simons.philippe@gmail.com`.

## Diagnosing an unreachable server

There are three layers and the **errno tells them apart without any console access**:

| Symptom from outside | Layer | Fix |
|---|---|---|
| Times out (~10 s) | OCI VCN security list / NSG — it DROPs silently | Oracle console |
| `EHOSTUNREACH`, fails in one RTT | instance iptables — the chain ends in `REJECT --reject-with icmp-host-prohibited`, which *answers* | `iptables -I INPUT <n> …` — see below |
| `ECONNREFUSED`, fails in one RTT | both layers open, nothing listening | `systemctl status nginx` |
| TLS error | nginx is up | certificate — see renewal above |

The iptables trap: the ACCEPT rules must be **inserted before** the trailing REJECT (`-I INPUT <n>`),
not appended (`-A`). An appended rule lands after the REJECT, is never reached, and changes nothing
while looking exactly like a fix in `iptables -S`. `setup-server.sh` walks the chain in order and
reports position rather than presence, and it never opens a port itself — that is a decision a person
makes on a public host.

## Trust model

**`latest.json` is a hint, never a trust boundary.** It says which bundle to fetch and nothing else.
It cannot select a keyring, a verification mode or an install flag, and the client forces `bundle` to
a bare filename so a manifest can never redirect a device to another host. The gate is the RAUC
signature: the device installs a bundle only if it chains to `/etc/rauc/keyring.pem` with
`check-purpose=codesign`.

That is also why `ota/publish-bundle.sh` verifies against that same keyring before it uploads, with
no override. A dev-cert bundle on this server is not a near miss — `make bundle` without `PKIDIR`
mints an *ephemeral 7-day* certificate that is deleted with its tempdir, so the result is a ~4 GB
download that every device in the field discards at the last step, over Wi-Fi, after the user agreed
to it.

**The hostname is not ours.** `cloud-ip.cc` is somebody else's apex; whoever runs it can repoint the
name, and DNS control is TLS control — HTTP-01 would issue them a valid certificate. The signature
still bounds the damage to "serves a bundle every device rejects", which is a denial of updates, not
a compromise. A domain owned at the registrar is the fix if the name itself needs to be trustworthy;
it needs no device-side change.

**rauc's bus policy is open to every local process.** `de.pengutronix.rauc.conf` ships
`<policy context="default"><allow send_destination="de.pengutronix.rauc"/></policy>` and 1.15.2 has
no polkit policy at all, so any local process can call `InstallBundle`. Bounded by signature
verification, so not arbitrary code execution — but it is the actual mechanism behind "unprivileged
install", and it is not polkit. Tracked in `TODO.md`.
