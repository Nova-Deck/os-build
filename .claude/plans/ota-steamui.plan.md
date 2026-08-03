# Plan: OTA update integration with SteamUI

**Status**: Phases 1–2 landed (uncommitted, on `main`). Phases 3–5 open.
**Closes**: `TODO.md:1104-1158` "Phase 4b pass 2" steps 5–6.
**Complexity**: Medium-Large.

Everything below the UI is already built and hardware-validated: signed verity bundles,
`rauc install` unprivileged, slot switch, trial boot, rollback. This work is the button.

---

## 1. The contract (verified — do not re-derive)

Read out of the baked client, `work/steam-seed/steamrtarm64/steamui.so`. These are the literal
format strings it builds command lines from:

```
/usr/bin/steamos-polkit-helpers/steamos-update
%s --supports-duplicate-detection
steamos-update: using duplicate detection: %d
 check 2>&1
 --enable-duplicate-detection
```

- `--supports-duplicate-detection` → exit 0 opts in.
- `check` → **stdout is parsed as the available version**; exit 0 = available, 7 = none.
  Steam refuses to re-offer a version it already applied, so every exit-0 must print a *stable*
  per-build identity.
- apply → `N%` lines on stdout, forward-only; exit 0 = success. Everything else to stderr.
- Reprinting the **already-staged** version maps to "restart pending" in Steam's UI.

Corroborated independently by armada's working implementation over bootc:
`_reference/armada/system_files/usr/libexec/armada/armada-update` and `.../usr/lib/armada/update-lib`.
Their comments encode the same traps. Treat that pair as the reference reading, not as a template —
their privilege model differs (below).

**SteamOSManager1 needs no update interface.** The only update-adjacent members in `steamui.so` are
`UpdateBios1`/`UpdateDock1` (firmware — already stubbed via `jupiter-biosupdate`) and `Atomupd1`,
whose only strings are the *download-proxy* config (`YldSetAtomUpdateProxyConfig`). Armada ships no
`Atomupd1` and their updates work. **Step 5's `novadeck-steamos-manager` half is a no-op — delete it
from the TODO rather than build it.**

---

## 2. Landed in Phase 1 (uncommitted)

| File | Action |
|---|---|
| `fs-overlay/usr/bin/novadeck-update` | CREATE — the whole client, Python + `gi` |
| `fs-overlay/usr/bin/steamos-polkit-helpers/steamos-update` | UPDATE — stub → `exec` wrapper |
| `fs-overlay/usr/bin/steamos-update` | CREATE — symlink → `novadeck-update` |

Verified: `py_compile` clean; `--supports-duplicate-detection` → 0; `check` with no Steam login →
7 silent; `check` with unreachable server → 7 silent, reason on stderr.
**Not** verified: check-with-an-update, apply, install, progress. Those need Phase 2 + a server.

### Design decisions already made

- **Python, one file.** The install is a D-Bus conversation — `InstallBundle` is async, progress is
  `PropertiesChanged` on a `(isi)` tuple, completion is a signal. Shell needs a FIFO plus a second
  translator process; Python needs a main loop. `python-gobject` is already in `PKGS` and is how
  `novadeck-steamos-manager`/`novadeck-powerd` talk to the bus.
- **No privilege plumbing.** rauc 1.15.2's shipped bus policy (`data/de.pengutronix.rauc.conf`) is
  `<policy context="default"><allow send_destination="de.pengutronix.rauc"/></policy>` — *"This
  config allows anyone to control rauc"*. There is **no polkit policy** in the release. The
  signature is the gate. The polkit-helpers path is a *name*, not a boundary (SteamOS's real pkexec
  wrapper comes from jupiter-hw-support, which we do not bake).
- **Download-then-install, not streaming.** `rauc install https://…` needs NBD; `grep -E 'NBD'
  kernel/kernel.config` returns nothing. Consequence: **this blocks the adaptive/delta-bundle item
  (`TODO.md:533-553`)**, which requires an HTTP-served bundle. Every update stays a full ~3.5G
  download until NBD lands.
- **Staging on `/home`.** `/var` is 256M (`images/partition-table.txt`); `/home` is `rest`.
  `/home/deck/.local/share/novadeck/updates/`, deck-writable, free-space checked *before* download.
- **`latest.json` is a hint, never a trust boundary.** `bundle` is forced to a bare filename so a
  manifest can never redirect the device to another host. Nothing in it may select a keyring,
  verification mode, or install flag.
- **Defer until a Steam login exists** (`loginusers.vdf` contains `"AccountName"`). The OOBE update
  screen is exactly what the replaced stub existed to unblock.
- **One channel now, channel-shaped URLs.** `steamui.so` has only "Failed to select OS branch" — no
  `steamos-select-branch` invocation. Ship `stable`; keep `/<channel>/…` so adding `beta` later is
  not a migration.

---

## 3. Phase 2 — version identity (LANDED, uncommitted)

`check` compares the manifest identity against `/etc/novadeck-release`, and nothing kept the two in
sync: `make bundle`'s `VERSION` and the image's `NOVADECK_VERSION` were independent knobs and
`genbundle.sh` defaulted `VERSION` to today's date, so the comparison the whole update path rests on
was between two unrelated strings.

**Fixed by removing the second knob rather than reconciling the two.** The identity is stamped once,
by the assembler, and everything downstream reads it back:

| File | Change |
|---|---|
| `images/assemble-rootfs.sh` | copies the staged `/etc/novadeck-release` to `out/images/rootfs.release` after the image is written — the sidecar |
| `images/genbundle.sh` | takes **no version argument**; derives the identity from the sidecar, rejects a missing one and any version that would not survive as a filename/URL segment |
| `images/rauc/manifest.raucm.in` | `[meta.novadeck]` carries `build`/`git` beside `version`; reaches handlers as `RAUC_META_NOVADECK_*` |
| `Makefile` | `VERSION` **deleted**. `NOVADECK_VERSION` gains `$(VERSION_STAMP)`, so changing it re-assembles the rootfs (same pattern as `MODE_STAMP`) |
| `.github/workflows/image.yml`, `release-bundle.yml`, `README.md`, `docs/RUNBOOK.md` | the knob is `NOVADECK_VERSION`, set before the rootfs is built |

Verified offline against a stubbed `rauc`: release version → `1.4.0`; `dev` and empty → the build
timestamp; missing/garbage sidecar and a `../../`-shaped version → exit 1. And the rule was
cross-checked head-to-head against the shipped client's `identity_of()` over the same release file —
four shapes, all MATCH.

**The identity rule now exists twice**, in `genbundle.sh` (shell) and `novadeck-update`
(`identity_of`, Python). They agree today and each points at the other, but nothing enforces it —
that is a Phase 4 test case, listed below.

**Note for any tree built before this**: `out/images/rootfs.img` has no sidecar, so `make bundle`
fails loudly until the rootfs is re-assembled. Adding `$(VERSION_STAMP)` forces that re-assembly
once anyway.

---

## 4. Phase 3 — server (Oracle Cloud + nginx)

Host: `novadeck.cloud-ip.cc`. **As of 2026-08-03 that name has no A or AAAA record** — only the
apex `cloud-ip.cc` resolves (185.206.180.131/174, the DDNS provider, not the instance). Instance
reachability is therefore unverified.

### Prerequisites (operator, not agent)

1. A record `novadeck.cloud-ip.cc` → instance public IP.
2. VCN ingress (Security List or NSG): TCP 80 + 443.
3. **The instance-local firewall.** Oracle's Ubuntu/Oracle Linux images ship iptables/firewalld
   rules that DROP everything but 22, persisted in `/etc/iptables/rules.v4`. Opening the VCN alone
   leaves the port silently filtered, and the symptom is indistinguishable from a VCN
   misconfiguration. **Both layers must open.**
4. Port 80 open *and* the name resolving before certbot — HTTP-01 validates over plain HTTP.

Gate: `curl -I https://novadeck.cloud-ip.cc/` answers from the workstation.

### To build

- `images/ota/nginx-novadeck-ota.conf` — TLS, HSTS, `autoindex off`, `Range` on (free resume now,
  streaming later), `application/octet-stream` for `.raucb`, no upload surface, docroot
  `/srv/novadeck-ota`.
- `images/ota/setup-server.sh` — run **on the instance**: nginx + certbot, docroot, vhost, cert.
  Must *detect* both firewall layers and report what is blocking; must not silently open ports on a
  public host.
- `images/ota/publish-bundle.sh` — mirrors `images/publish-card.sh` (env-only credentials, explicit
  `KEEP` retention). Upload over SSH/rsync, not rclone — this is not S3. **Bytes first,
  `latest.json` flipped last**, so no device resolves a URL that 404s.
- `docs/ota.md` — server contract, docroot layout, runbook for cutting an update.
- `.github/workflows/release-bundle.yml` — wire the upload half. Its own header (lines 34-40)
  already scopes this. **Signing stays gated** on the protected-environment decision that header
  describes; do not move the release key into CI as part of this work.

### `latest.json` schema

```json
{ "version": "1.4.0", "build": "20260803T120000Z", "git": "abc1234",
  "bundle": "novadeck-1.4.0.raucb", "size": 3758096384, "sha256": "…" }
```

`bundle` must be a bare filename — the client rejects anything else.

### Hostname note (not a blocker)

`cloud-ip.cc` is someone else's apex; whoever runs it can repoint the name, and DNS control is TLS
control (HTTP-01 would issue them a valid cert). The RAUC signature still bounds the damage to
"serves a bundle every device rejects". This is exactly why `latest.json` is an untrusted hint. A
domain owned at the registrar is the fix if the name itself needs to be trustworthy — no
device-side change.

---

## 5. Phase 4 — tests

`images/test-update.sh`, mirroring `images/test-bootctl.sh:17-21`: execute the **shipped** file
through its documented env seams (`NOVADECK_RELEASE_FILE`, `NOVADECK_OTA_CONFIG`,
`NOVADECK_OTA_STAGE`, `NOVADECK_STEAM_LOGINUSERS`, `NOVADECK_CURL`, `NOVADECK_OTA_URL`), stub
`curl` and the rauc bus on disk. Add to `Makefile` `test:` alongside the existing five suites.

Cases:
- probe exits 0
- no update → exit 7 **and prints nothing**
- update available → exit 0 and a stable identity
- the same check twice prints the *same* identity (duplicate detection)
- apply emits monotonic `N%` on stdout, all tool chatter on stderr
- insufficient disk → exit 7 **without downloading**
- unreachable server → exit 7 (fail closed, never 0)
- malformed `latest.json` → exit 7
- `bundle` containing `/`, `..`, or a scheme → rejected
- staged stamp present + `GetPrimary != BootSlot` → reprints staged version (restart-pending)
- staged stamp present + `GetPrimary == BootSlot` → stamp cleared, offers the next update
- **the two identity rules agree** — drive `genbundle.sh`'s derivation and the client's
  `identity_of()` off one release file and require the same string, over at least: a real version,
  `dev`, empty, and a version with `-`/`.` in it. They are the same rule written twice in two
  languages, and Phase 2 exists because those two strings drifting is exactly what breaks the update
  check. A stubbed `rauc` on `PATH` is enough; no bundle needs to be built.

---

## 6. Phase 5 — hardware validation

Needs two genuinely different builds (bump `NOVADECK_VERSION`, rebuild). Publish, then from the
device UI: check → offer → download → install → restart → confirm the new slot booted and
`/etc/novadeck-release` changed. Then a second check must report up-to-date and **not** re-offer.

Verify explicitly: polkit/bus access works from the **seat session**, not just from SSH. An SSH
session and a seat session are not the same D-Bus subject, even though rauc's policy is open to
both on paper.

---

## 7. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Trial gap: install → reboot → black screen → unbounded wait (`TODO.md:194`) | High | High | **Accepted, not mitigated** — decision 2026-08-03. See §8. |
| `check` runs during OOBE and blocks onboarding again | Medium | High | Login gate + fail-closed 7 on any error (both implemented) |
| 3.5G download over first-boot Wi-Fi | High | Medium | `curl -C -` resume, space guard, no auto-download. Real fix is deltas, blocked on NBD |
| Steam's stdout parse differs from the reconstruction | Low | High | Read from the shipped `steamui.so`, corroborated by armada. Confirm in Phase 5 |
| `/home` fills; install fails after a full download | Medium | Medium | Guard before download; bundle unlinked on both success and failure |
| Manifest/bundle skew | Medium | Low | Publish bytes first, flip pointer last |
| First symlink in `fs-overlay/usr/bin/` | — | Low | `btrfs restore` needs `-S` or it vanishes from the extract; consider a `guard-rootfs.sh` assertion |

---

## 8. TODO.md items to write (findings from the 2026-08-03 session, not yet transcribed)

**A. Nothing ends an unconfirmed trial — expand the existing `TODO.md:194` item with two findings:**

1. *A display-based warning is not a mitigation.* The most likely cause of "session never came up"
   after an OS update is a display-stack regression — kernel, mesa, gamescope are exactly what a
   bundle carries. The thing that would draw the message is broken by the same fault that made it
   necessary. The mitigation fails **correlated** with the failure it reports.
2. *Phase 5 removed the signal a timer would need.* `images/initramfs/init:189` now writes
   `source=grub` on **every** boot, and the stage-2 GRUB module increments `boot-attempts` on every
   boot. From userspace a post-update trial is indistinguishable from an OOBE first boot, so a
   give-up timer cannot currently arm only on trials. The bootconf has an `update` bool but
   `_reference/steamos-efi/chainloader/config.c:44` marks the whole update group deprecated.
   **Fix sketch:** `post-install.sh` already runs after every install and already writes the
   bootconf — have it record "this slot is on trial from an update", and have `mark-good` clear it.

   Reframing that makes the timer defensible: it is not adjudicating "is this slot good", it is
   *supplying the boot attempts the failsafe already requires and nothing generates*. Recovery today
   needs ~6 human power-cycles (menu at ≥3, auto-pick other at ≥6); a timer makes them automatic, or
   makes it one if it calls `set-state self bad` directly. Misfire costs one reboot and a rolled-back
   good update; not firing costs an unbounded black screen and a flat battery.

**Decision 2026-08-03: ship the update button anyway.** The failure needs a bad bundle to trigger,
you control what is published, and every bundle gets a HW install before it reaches the server.
Tracked, not mitigated.

**B. rauc's bus policy is open to every local process.** `de.pengutronix.rauc.conf` allows any user
to call `InstallBundle`, and there is no polkit policy in 1.15.2. Any local process — including
anything Steam launches — can trigger a slot overwrite and arm a trial, or DoS by holding the
installer busy. Bounded by signature verification, so not arbitrary code execution. **Already
shipping today; not introduced by this work**, but it becomes reachable by design once the UI path
exists. Also correct `TODO.md:107`, which credits polkit for the unprivileged install — the
mechanism is the open bus policy, not polkit.

---

## 9. Pickup order

1. ~~**Phase 2** — version identity.~~ LANDED.
2. **Phase 4** — the test suite (`images/test-update.sh`). With Phase 2 done this makes the client
   verifiable with no server and no device. **Next.**
3. **Phase 3** — server, once the DNS record and both firewall layers are open (operator-side).
4. **Phase 5** — hardware.
5. ~~Transcribe §8 into `TODO.md`.~~ DONE — both items are in the working tree's `TODO.md`.
