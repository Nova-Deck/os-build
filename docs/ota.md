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
| Disk | ~94G; a bundle is ~4G — free space is the retention budget, see *Disk budget* |
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
`OTA_CHANNEL` selects it, from the first of these that has one:

| source | who can write it | note |
|---|---|---|
| `NOVADECK_OTA_CHANNEL` | whoever runs the command | one invocation only — SteamUI's own checks carry no environment of ours |
| `/etc/novadeck/ota.conf` | root | only a **dev** card ships this file, pinned to `dev` so the card is never offered a stable release |
| `~/.config/novadeck/ota.conf` | the user, no root needed | `/home/deck/.config/novadeck/ota.conf`; the only one reachable on a release device |
| built-in `stable` | — | |

`/etc` outranks `$HOME` on purpose: a file in `$HOME` must not silently undo the dev card's pin. On
a release image `/etc/novadeck/ota.conf` does not exist, so the user's file is the only entry in the
chain. It may set `OTA_CHANNEL` **only** — `OTA_URL` is read from `/etc` and the environment, never
from `$HOME`, because which host a device fetches from is an operator decision and one writable file
under `$HOME` must not repoint every future update.

`novadeck-update status` prints which of them supplied the channel in effect, which is the fastest
answer to "why is it checking that channel".

A choice made in `~/.config` survives an OTA and a slot switch on its own: `/home` is one partition
shared by both slots. The copy in `/etc` needs `post-install.sh` to carry it, because that one lives
in the per-slot `/var` overlay upper.

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

**`rsync` must be installed on the publishing workstation.** `publish-bundle.sh` uses it for both
the bundle upload and the `latest.json` flip, and it is *not* in the Arch base install — a
workstation without it fails at the upload step. The server has it. The script now refuses up front
rather than discovering this minutes in; see its own comment for why the check sits where it does.

```sh
# 1. build and sign — the version must be set BEFORE the rootfs, see docs/RUNBOOK.md
NOVADECK_VERSION=0.2.0 PKIDIR=$HOME/novadeck-pki make bundle

# 2. install it on a device and confirm it boots, BEFORE anyone else gets it
ssh deck@<device> rauc install /path/to/novadeck-0.2.0.raucb

# 3. publish
NOVADECK_OTA_SSH_KEY=~/.ssh/<key> ota/publish-bundle.sh out/images/novadeck-0.2.0.raucb
```

Step 2 installs from a **local file**, and that is still exactly the test it always was. The device
itself STREAMS (below), but a local `rauc install <file>` is unaffected: rauc's adaptive path is
best-effort with an unconditional fall-through to a plain full-slot copy, so a workstation install
writes the same bytes it always did. It simply gains nothing from adaptive — there is no download
to shrink.

Step 2 is not optional and is not ceremony. Nothing on the device ends an unconfirmed trial boot
([#34](https://github.com/Nova-Deck/os-build/issues/34)), so a bundle that comes up to a black
screen needs about six manual power-cycles to
recover — on a device with no serial console. Every published bundle gets a hardware install first.
That is the entire mitigation, and it was accepted as such on 2026-08-03.

### The device streams; it does not download

`novadeck-update` hands rauc the bundle's **https URL**, not a downloaded file. rauc creates an NBD
device backed by an unprivileged helper (user `nobody`) that turns block reads into HTTP `Range`
requests, so a bundle never occupies storage on the device — there is no staging directory to fill
and no free-space precondition on an update.

Because `ota/rauc/manifest.raucm.in` marks the image `adaptive=block-hash-index`, the bundle also
carries a SHA256 index of every 4 KiB block. rauc looks each block up in **both** slots and fetches
only what it cannot find locally. Measured 2026-08-04 across two independent pairs of real
consecutive bundles: **96.1% of non-zero blocks are reused, ~125 MB crosses the wire instead of
3.90 GB.** Matching is content-addressed, and every local hit is re-hashed against the index inside
the signed bundle before use — a corrupt or tampered local index can only cost bandwidth.

**The server must speak HTTP/2 for that to be quick.** rauc's NBD helper turns block reads into many
concurrent Range requests, which is the request pattern HTTP/1 serialises — and rauc warns about it
at the start of every stream (`using HTTP/1 for streaming, expect slow installation`), observed on a
Pocket ACE installing from this server. The vhost disabled HTTP/2 until 2026-08-25 on the stated
reasoning that "the only client is curl fetching one large file with a Range header", which was
never true of this server: **the bundle has always been fetched by rauc**, and the only thing curl
fetches is `<channel>/latest.json` — a few hundred bytes, for which the protocol is irrelevant.
`listen 443 ssl http2` (the pre-1.25 spelling, which is what Ubuntu 24.04's nginx 1.24 understands)
is now in `ota/nginx-novadeck-ota.conf`.

Three consequences worth knowing before reading a slow first result:

- **Getting here takes two hops, and the first one measures nothing.** rauc runs from the RUNNING
  slot, so it is that slot's `system.conf` and that slot's `novadeck-update` which decide whether an
  install is adaptive — not the bundle's. A device on a pre-adaptive release therefore installs an
  adaptive bundle as a plain full-slot write: no `data-directory` means `goto raw_copy`, and the old
  client passes a local path rather than a URL. Only once that build is RUNNING does the next update
  exercise any of this. Install the first hop by hand (`rauc install <file>`, which is the mandated
  pre-publish step anyway) and there is nothing to publish for it.
- **The first adaptive install still saves; it is just slower.** With no stored index for either
  slot rauc generates them on demand, which costs one pass of hashing both slots. Matching — and so
  the download saving — applies from that install onward. Indices are then kept in the data
  directory on `/home`, which is shared, so they survive the slot switch.
- **The progress bar tracks the INSTALL, not the transfer.** With most blocks coming from local
  slots, it advances through stretches where nothing crosses the network.
- **A failed stream is cheap to retry.** The correct blocks already written into the target slot are
  exactly what the next attempt finds locally. There is no resume, and there is no way to cancel an
  install once accepted — rauc's D-Bus API has no `Cancel` method. A broken connection is bounded
  (5 range-request retries, then the install fails); a merely stalled one is bounded only by TCP.

Both halves fail *silently* if lost — a rauc built without streaming, or a kernel without `nbd.ko`,
degrades to a full download that still succeeds. `rootfs/guard-rootfs.sh` asserts both at build time.

`publish-bundle.sh` does, in order: verify the signature against the device keyring, read the version
back out of the bundle, check free space on the server, upload to a `.part` name and rename, **hash
the uploaded file on the server and compare it to the local one**, prove the bundle is readable at
its public URL with a `Range` request, **flip `latest.json` last**, read that back over HTTPS, and
prune to `KEEP`. Everything before the flip is invisible to devices; the flip is the publish.

The server-side hash is not redundant with rsync's own checksum. `$SHA` is computed from the local
file *before* the transfer, so without this step the `sha256` published in `latest.json` describes a
file on the workstation, not the one being served. rsync covers a transfer it knows it made; it does
not cover a `.part` a second concurrent publish was also writing (two runs both `rsync --inplace` to
the same path and neither fails — they just interleave), a resume whose earlier half came from a
different build, or a bad disk on the far end. And because the client does **not** check `sha256`
(above), a corrupt bundle would otherwise be caught no earlier than each device's own signature
verification — after a ~4G download, per device. Caught here it costs one re-upload.

### Validating a release on hardware, before anything is published

This looks circular the first time you meet it — a boot-flow change wants a new card, and you do not
want to cut a card until the update path is proven — and it is not. **Proving the update path needs
no published card and no published bundle.** It needs a device on the boot flow you are shipping and
a bundle that device will accept, and both are buildable locally.

There are two questions here, they are not the same one, and the second answers strictly more:

| | Question | What it decides |
|---|---|---|
| **a** | Does an OTA work *on* the new boot flow? | Whether the update path is sound at all |
| **b** | Can a device on the **previous** boot flow be OTA'd *across* to the new one? | Whether the next card is a convenience or a **mandatory reflash for every device in the field** |

**(b) was ANSWERED on 2026-08-03, and the answer is no: `card/v0.2.0` is a mandatory reflash.** It
was settled by reading both ends rather than by running it, because the two halves name the same
missing file:

- The phase-5 build ships **no** `/usr/lib/novadeck/boot.img` — `rootfs/assemble-rootfs.sh:202`, the
  boot *directory* replaces it.
- A `card/v0.1.0` device's own `post-install.sh:194` hard-fails without exactly that file:
  `die "the installed root carries no boot image at /usr/lib/novadeck/boot.img"`.

**The reason this cannot be fixed in the bundle is the part worth remembering: RAUC runs the BOOTED
slot's post-install handler, not the bundle's.** A v0.1.0 device runs v0.1.0's Phase-4b handler,
which rotates `/KERNEL` and knows nothing of stage-2 GRUB, per-slot efi partitions or partsets. No
change to a future bundle reaches that handler retroactively. Every device on a pre-phase-5 card is
a reflash, once.

The failure is safe for the running system but is **not a dry run**: the handler disarms the target
(`:109`), re-randomises its fsid (`:115`) and reformats its `/var` (`:131`) *before* reaching the
kernel step, so slot B is left overwritten and unbootable while slot A keeps running. It never
re-arms (`:246-247`), so the device simply stays where it was.

So **run (a)** — it no longer subsumes anything, and it is the path that actually ships. Both the
card and the bundle are built locally, below.

```sh
# 1. the device: build the new boot flow locally and flash it. Give the CARD a version too, or
#    both ends render `dev` and the client has no version change to detect.
set -a; . ./dev.env; set +a
NOVADECK_VERSION=<base> PKIDIR=$HOME/novadeck-pki make sdcard    # dev card, new boot flow

# 2. a bundle the device will accept: a DEV image with a REAL signature.
#    rauc gates on the signature, so this installs exactly like a release bundle.
NOVADECK_VERSION=<bumped> PKIDIR=$HOME/novadeck-pki make bundle

# 3. hand-seed it into a TEST channel — not stable
scp out/images/novadeck-<bumped>.raucb ubuntu@updates.novadeck.cloud-ip.cc:/srv/novadeck-ota/test/
#    then write /srv/novadeck-ota/test/latest.json by hand (schema above; size must be exact)

# 4. point the device at it, and drive the update FROM THE STEAM UI
#    No sudo: this is the user-writable channel file, which is also the only one that works on a
#    release device (no sudo package on the image, and pairingd only ever gives you `deck`).
ssh deck@<device> 'mkdir -p ~/.config/novadeck && echo OTA_CHANNEL=test > ~/.config/novadeck/ota.conf'
#    On a DEV card /etc/novadeck/ota.conf pins the channel to `dev` and outranks this file, so
#    there you have to edit that one instead (you have root on a dev card).
```

Step 4 is the gate: Settings → check → offer → download → install → restart → confirm the new slot
booted and `/etc/novadeck-release` changed. Then check again — it must report up-to-date and **not**
re-offer. Verify from the **seat session**, not over SSH: those are different D-Bus subjects even
though rauc's policy is open to both on paper.

**`ota/publish-bundle.sh` refuses dev bundles, and that does not obstruct this.** The mode gate
protects `stable` from a test image reaching the fleet; hand-placing a bundle in a channel of your
own, on your own server, is you doing something explicit. The gate is on publishing, not installing.

**Reset the channel when you are done.** `OTA_CHANNEL=test` **survives the update** either way you
set it: `~/.config` is on `/home`, one partition shared by both slots, and `/etc` is an overlayfs on
the per-slot `/var` that `post-install.sh` migrates to the new slot. A device left pointing at the
test channel silently keeps reading it forever — `novadeck-update status` names the file it came
from, so a device that has been forgotten will say so.

Only once that passes: tag `card/vX.Y.Z`, then `ota/vX.Y.Z`.

**`ota/vX.Y.Z` now publishes by itself.** Since 2026-08-04 `release-bundle.yml`'s `publish` job is
live, so the tag builds the bundle, signs it with the release cert and pushes it to `stable/` —
`make publish-bundle` from the workstation is the fallback, not the route. The tag asks for **two
approvals**, not one: `build` waits for a reviewer to reach the signing key and `publish` waits
again to reach the publishing key. That is deliberate — signing produces an artifact that still goes
nowhere; publishing is the step that puts bytes in front of the fleet.

A publish now ends in exactly one of two states, **published** or **red**. Before that date a
missing credential was a `::notice::` and a skipped step, so `ota/v0.2.1` was cut, built, signed and
published nowhere while the run went green; no one reads a skipped step at the bottom of an
hour-long success.

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
# 1. the CI publishing account (creates `otapub`, installs ota/ci-publish.pub, re-owns the docroot)
tar cz ota | ssh -i <admin key> ubuntu@updates.novadeck.cloud-ip.cc \
  'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-ci-user.sh'

# 2. stand it up, or re-run it — idempotent, and a second run reports state without changing it
tar cz ota | ssh -i <admin key> ubuntu@updates.novadeck.cloud-ip.cc \
  'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-server.sh'

# is it alive?
curl -I https://updates.novadeck.cloud-ip.cc/healthz
```

**Order matters, and only in one direction.** `setup-server.sh` defaults the docroot owner to
`otapub` and *dies* if that account does not exist — it will not create a login itself, because the
one property this account exists to have is *no privileges*, and a server bootstrap that quietly
invents accounts is how that gets lost. Run `setup-ci-user.sh` first, or pass
`NOVADECK_OTA_OWNER=ubuntu` to stand up a server with no CI principal at all.

### The two publishing principals

| | logs in as | key | may |
|---|---|---|---|
| workstation, by hand | `ubuntu` | the instance admin key | anything — it has passwordless sudo |
| GitHub Actions | `otapub` | `OTA_SSH_KEY`, in the `release-signing` environment | write the docroot, nothing else |

`otapub` is a system account with no password, no sudo, and no group but its own; its sole
`authorized_keys` entry is prefixed `restrict`, so no pty and no forwarding of any kind. The public
half is committed at `ota/ci-publish.pub`; the private half exists only as the CI secret.

**A forced command was considered and rejected.** `command="rrsync /srv/novadeck-ota"` covers rsync,
and `publish-bundle.sh` is not an rsync wrapper — it also runs `mkdir`, `df`, `mv`, `chmod`,
`sha256sum` and a `bash -s` prune over ssh. A wrapper whitelisting those becomes a second,
unversioned copy of the publish protocol: two things that must change together and will eventually
disagree. An account with no sudo is the same bound enforced by the kernel instead.

The docroot is therefore `otapub:otapub` mode **2775** — setgid, with `ubuntu` in the `otapub`
group, so both principals can act on each other's files and the by-hand rollback below keeps
working. Adding `ubuntu` to a group does not affect sessions that are already open; reconnect.

**Rotating the CI key** needs no device involvement and no keyring change: `ssh-keygen` a new pair,
replace `ota/ci-publish.pub`, re-run `setup-ci-user.sh` — it *rewrites* `authorized_keys` rather than
appending, so the old key stops working — and `gh secret set OTA_SSH_KEY --env release-signing`.

`/healthz` exists because `stable/` is legitimately empty between releases, so every other probe
answers 404 and a dead server looks exactly like a quiet one.

The vhost is `ota/nginx-novadeck-ota.conf` and **the repo is authoritative** — `setup-server.sh`
copies it. This is why certbot is run as `certonly --webroot` and never `--nginx`: the `--nginx`
installer edits the vhost in place, and the running config would stop matching the committed one
with nothing to signal the drift.

### Disk budget

Free space on this instance is not spare capacity — it **is** the retention budget. Keeping the
previous releases is what makes a bad update recoverable fleet-wide by re-pointing `latest.json`
(see *Rolling back a bad release*), and that only works while those bytes are still on the server.

The arithmetic: ~94G of disk, a bundle is ~4G, `NOVADECK_OTA_KEEP=3` per channel — so roughly 12G
in use per channel against 94G. Comfortable, and deliberately so.

`publish-bundle.sh` protects it from the front. Before it moves a single byte it runs
`df -kP` on the destination **over ssh** and requires the bundle's exact size plus 512 MiB of
headroom, then dies telling you to lower `NOVADECK_OTA_KEEP` or prune by hand. This is checked
first because the alternative is discovering it after a 4G transfer to Frankfurt.

That check is only as good as the free space it measures, which is why the journal is capped.
Ubuntu ships journald with no `SystemMaxUse`, so the built-in default applies — 10% of the
filesystem, up to 4G — and this box would spend it slowly on logs for a server that only hands
out static files. `setup-server.sh` installs
`/etc/systemd/journald.conf.d/10-novadeck-cap.conf` with `SystemMaxUse=200M` and vacuums once, so
the cap applies to what has already accumulated and not just to new writes.

Note the failure this prevents is *not* corruption. An unbounded journal makes a future publish
refuse to start, at a confusing distance from the cause — the disk quietly filled weeks earlier.

```sh
# what is actually being used
ssh -i <key> ubuntu@updates.novadeck.cloud-ip.cc \
  'df -h /srv/novadeck-ota; journalctl --disk-usage; du -sh /srv/novadeck-ota/*'
```

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
install", and it is not polkit. Accepted as a design choice; recorded in `docs/worklog/DONE.md`.
