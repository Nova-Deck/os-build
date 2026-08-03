# Runbook — flash, reach, update, recover

The operational path, end to end. Design rationale lives elsewhere: [`phase4.md`](phase4.md) for
why A/B looks like this, [`remote-access.md`](remote-access.md) for why SSH is shaped the way it
is, `TODO.md` for the open items and the hardware-validation record each step here rests on.

Every `make` invocation below runs from the repo root. A dev build needs its environment sourced
**before every one of them** (`set -a; . ./dev.env; set +a`) — see the README's Building section.

## The disk it all operates on

<!-- AUTO-GENERATED from images/partition-table.txt — regenerate with /ecc:update-docs -->

| # | Partition | Size | FS | Label |
|---|---|---|---|---|
| 1 | `esp` | 256M | vfat | `NOVADECK-ESP` |
| 2 | `efi-a` | 64M | vfat | `novadeck-efi-A` |
| 3 | `efi-b` | 64M | vfat | `novadeck-efi-B` |
| 4 | `rootfs-a` | 7G | btrfs | `novadeck-root-A` |
| 5 | `rootfs-b` | 7G | btrfs | `novadeck-root-B` |
| 6 | `var-a` | 256M | ext4 | `novadeck-var-A` |
| 7 | `var-b` | 256M | ext4 | `novadeck-var-B` |
| 8 | `home` | rest | ext4 | `novadeck-home` |

<!-- END AUTO-GENERATED -->

`images/partition-table.txt` is the single source of truth for sizes, typecodes and labels;
`images/genpart.sh` emits the `sgdisk` script from it. Three facts drive most of what follows:

- **The shared ESP carries the bootconf, not a kernel.** SteamOS/conf/{A,B}.conf on the ESP decide
  which image boots and how many failed attempts it is allowed; the stage-1 steamcl (as
  `/EFI/BOOT/bootaa64.efi`) is what ABL chainloads. Each slot's *own* efi partition (efi-a/efi-b)
  carries that slot's stage-2 GRUB and its identity partset (`SteamOS/partsets/self`). ABL reads
  partition 1 only.
- **`/var` is per-slot, and `/etc` rides on it** (an overlayfs whose upper dir is
  `/var/lib/overlays/etc/upper`). A slot switch therefore carries `/etc` with it.
- **`/home` is shared and survives everything** — including the paired SSH keys in
  `/home/deck/.ssh`, and the offloaded `/var/log`. This is why an OTA does not lock you out.

## Get a release card

**A release card can only be built by CI**, and that is deliberate: `make sdcard` on a dev box fails
the artifact-pin gate (`packages/verify-pins.sh`), because locally compiled overlay bytes will never
match a published sha. So verifying OOBE on a real release image means flashing what
`release-sdcard.yml` produced.

Cards are served from Cloudflare R2, not from a GitHub release asset — the image is ~9 GiB against
GitHub's 2 GiB per-asset cap. The GitHub Release for a `card/v*` tag carries the checksums, the
provenance pins, and the link:

```sh
curl -LO https://<R2_PUBLIC_BASE>/cards/v1.3.0/sdcard.img.gz
curl -LO https://github.com/Nova-Deck/os-build/releases/download/card/v1.3.0/sha256sums.txt
sha256sum -c sha256sums.txt                   # do this BEFORE writing 19G to a card
gzip -dc sdcard.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

`.gz` rather than `.zst` on purpose: every option lands 8.5-9.0 GiB (the payload is already
compressed — both btrfs roots carry `compress=zstd`), so the wrapper is a compatibility choice, not
a size one, and `.gz` is what balenaEtcher and Raspberry Pi Imager open.

To cut a card: tag `card/vX.Y.Z`. To cut an update instead, tag `ota/vX.Y.Z` — the two ship on
independent cadences and a bundle is expected far more often than a card. **Check before tagging**
that `main`'s artifact pins match the store: between an overlay republish and its pin-bump PR
merging, `make verify-pins` will fail the build.

The version and commit a card was built from are stamped into `/etc/novadeck-release` on the device
(`NOVADECK_VERSION`, `NOVADECK_GIT`), so a running system can name where it came from.

## Build and flash a dev card

```sh
set -a; . ./dev.env; set +a                   # NOVADECK_DEV=1 + optional Wi-Fi creds
make sdcard                                   # -> out/images/sdcard.img
make verify-card                              # GPT, ESP, per-slot filesystem identities
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

`make-sdcard.sh` lays the **full** GPT and populates **both** slots — ESP + root-A/-B + var-A/-B +
home, with `/home` pre-seeded with the native arm64 Steam client and root-B carrying a distinct
btrfs fsid. Each `efi-*` partition carries that slot's stage-2 GRUB, its `grub.cfg` and the
partsets that identify it. B is populated rather than left empty because a slot switch cannot
be proven against a slot that does not boot; set `NOVADECK_SLOT_B=0` for a faster local loop, at the
cost of a card whose first slot switch can only exercise the failover path.

Run `verify-card` before you commit a card to a device — it asserts the built image rather than
the source tree, which is the only place the GPT, the ESP contents and the per-slot filesystem
identities are checked at all.

**The first boot stops at the stage-2 board menu and waits.** One image serves all 15 boards, so
the DTB is the one thing the card cannot know. The choice is written to `/EFI/steamos/grubenv` on
the shared ESP, and every boot after that takes it automatically behind a 3-second visible menu —
including across a slot switch and an update, since the grubenv is on the ESP rather than in a
slot. Picking the wrong board gives a card that does not come up; the menu stays visible
(rather than hidden) precisely so there is a way back on a device with no keyboard.

To install a freshly built stage-1 steamcl onto an already-flashed card's ESP without rebuilding
the image:

```sh
make deploy ESP=/run/media/$USER/NOVADECK
```

## Reach the device

**These devices have no UART.** If you cannot reach a device over the network, your only
instrument is the offline card mount — see [Recovery](#recovery-when-it-does-not-boot).

### Release image

sshd ships **always-on and key-only**, with no host keys baked in and no account with a password.
Access is granted at runtime by whoever is holding the device:

1. On the device: **Settings → System → Enable Developer Mode**, then the developer page's
   remote-access switch. That starts the pairing daemon on port 32000.
2. From the machine you want to connect from:
   ```sh
   curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://<device>:32000/register
   ```
3. `ssh deck@<device>` — immediately, no password.
4. **Turn the switch off.** Installed keys stay; they live on `/home` and survive updates, so an
   already-paired machine never re-pairs.

The switch gates only *pairing*, never sshd itself. Full protocol notes, the Windows invocations
and what persists across an update: [`remote-access.md`](remote-access.md).

### Dev card

`dev.env` bakes `NOVADECK_SSH_PUBKEY` into `root`'s `authorized_keys` and generates a throwaway
identity for it:

```sh
ssh -i work/dev-ssh/id_ed25519 root@<device>
```

That key survives `make distclean`, so your `known_hosts` entry keeps working across rebuilds. A
dev card built with no Wi-Fi credentials (or `NOVADECK_WIFI=0`) has no network and no SSH by
design — that is the shipping first-boot condition, and the only honest way to exercise OOBE.

## Ship an update

### Build and sign a bundle

```sh
NOVADECK_VERSION=<version> PKIDIR=$HOME/novadeck-pki make bundle
```

**The version has to be set before the rootfs is built, not at bundling time.** `NOVADECK_VERSION`
is stamped into the image's `/etc/novadeck-release`, and `genbundle.sh` reads it back out of the
image to name the bundle — so the bundle can never claim a version its payload does not carry. That
equality is what the device's update check compares, so it is not cosmetic. Changing the version
re-assembles the rootfs (a few minutes; not a base or kernel rebuild).

Omit it and the image calls itself `dev`; the bundle is then named after its build timestamp, which
is still unique per build but is not a release. There is no separate bundle-version knob — the old
`VERSION=` was removed on 2026-08-03 precisely because it could disagree with the image.

`PKIDIR` is not optional for anything a device will accept. Without it `genbundle.sh` mints an
**ephemeral 7-day dev cert**, deleted with its tempdir, which the device keyring rejects on
signature — that reads as a rauc failure and is not one. The PKI lives outside the repo and is
invisible to the build container unless `PKIDIR` mounts it.

**`make bundle` does not verify its own output.** rauc logs `No keyring given, skipping signature
verification` at creation, so a green `make` is not evidence the bundle is validly signed. Check
it yourself, **through the shipped config**:

```sh
rauc --conf=fs-overlay/etc/rauc/system.conf info out/images/novadeck-<version>.raucb
```

Do not use `rauc info --keyring <ca>` — that applies rauc's default `smimesign` purpose, which
accepts only `emailProtection` or no EKU, and therefore rejects our `codeSigning` release cert
with `unsuitable certificate purpose`. It is a false red. The shipped `system.conf` sets
`check-purpose=codesign`.

### Publish it

```sh
NOVADECK_OTA_SSH_KEY=~/.ssh/<key> ota/publish-bundle.sh out/images/novadeck-<version>.raucb
```

Puts the bundle on `updates.novadeck.cloud-ip.cc`, where devices fetch it from, and flips the channel
pointer at it. **Install it on a device first** (below) — nothing on the device ends an unconfirmed
trial boot, so a bundle that comes up to a black screen costs ~6 manual power-cycles to recover on
hardware with no serial console. Every published bundle gets a hardware install before it ships.

The publisher verifies the signature against the CA baked into every device's keyring before it moves
a byte, and there is no override: a bundle built without `PKIDIR` carries an ephemeral 7-day cert and
would be a ~4 GB download the fleet discards at the last step. Server contract, retention, rollback
and cert renewal are in **`docs/ota.md`**.

### Install it

Drive the install **as `deck` over SSH** — rauc's D-Bus service authorizes it with no `sudo` on the
box and no password anywhere. (The mechanism is rauc's *open bus policy*, not polkit: 1.15.2 ships
no polkit policy, and its `de.pengutronix.rauc.conf` allows any local user to call the installer. The
signature is the gate. See `docs/ota.md` and `TODO.md`.)

```sh
ssh deck@<device> rauc install /path/to/novadeck-<version>.raucb
```

Not as `root`: `/root` is on the read-only root and does not survive the slot write. Watch for
`Verifying signature done` (~20%) — that is the device's own keyring accepting the bundle.

Every install writes the whole slot today (`[image.rootfs]` names `rootfs.img` and nothing else),
so budget minutes of SD-card writes for a one-package bump.

The post-install hook makes the freshly written slot bootable: it re-randomises the target's btrfs
fsid (both slots otherwise share an fsid *and* `devid=1`, and mounting one can hand you the other),
copies `/var` across, installs this build's stage-2 GRUB + grub.cfg + font onto the target's efi
partition and re-points its partsets, refreshes the shared ESP's stage-1 steamcl if it changed, and
finally arms the target for its trial boot through steamos-bootconf. Reboot to land on the new slot.

## Read and steer the boot state

```sh
novadeck-bootctl status               # what booted, and what the ESP/efi say
novadeck-bootctl get-state B          # is slot B fit to boot? (good|bad)
novadeck-bootctl set-primary B        # boot slot B next (starts its trial boot)
novadeck-bootctl set-state B bad      # demote B; the next boot goes to the other slot
novadeck-bootctl mark-good            # confirm THIS boot — ends its trial, clears boot-attempts
```

**All of these need root, and a release image ships no `sudo`.** As `deck` the tool cannot answer
any of it. On a dev card, `ssh -i work/dev-ssh/id_ed25519 root@<device>`; on a release device,
read the state off the card offline (below). `rauc install` is the deliberate exception — it goes
through rauc's D-Bus service and polkit, which is why it works as `deck`.

These are Valve's SteamOS semantics, surfaced through the same steamos-bootconf that RAUC uses, so
`novadeck-bootctl` and `rauc status` agree by construction. The state that decides a boot lives in
the ESP conf of each image:

- **`image-invalid`** — a hard demote. `set-state <slot> bad` sets it (and the boot-health unit's
  failure path does exactly that, via `novadeck-boot-bad.service`); only a completed install clears
  it, because the post-install hook is the only place that knows an install completed. **This is
  the only rollback trigger that is live today.**
- **`boot-attempts`** — the trial counter. The stage-2 `novadeck` module bumps it on every kernel
  boot (`novadeck_bootattempts <slot>` in the generated `grub.cfg`), `mark-good` clears it after a
  healthy session, and steamcl's failsafe offers a menu at ≥3 and auto-picks the other slot at ≥6.
  **HW-validated 2026-08-02.** Two traps when checking it by hand: a healthy boot runs `set-mode
  booted`, which *clears* the counter — so mask `novadeck-boot-good.{path,service}` before the test
  reboot or a working counter and a dead one both read `0`. And GRUB prints
  `novadeck: A boot-attempts 0 -> 1` just before the board menu paints over it, so on a 3s boot you
  will usually miss it; the conf is the evidence, not the panel.

> **What that means in practice.** A slot that boots but comes up broken IS demoted — the health
> unit fails and the next boot goes to the other slot. A slot that never gets far enough to run
> systemd at all is demoted by the counter above, at ≥6 attempts. Recovery is the stage-2 board
> menu, which is why
> it stays visible rather than hidden.

Three traps, each of which has inverted a conclusion on real hardware:

- **`rauc status` cannot tell promoted from still-on-trial.** It reports the slot `good` in both
  states. Only the ESP conf distinguishes them — and while `boot-attempts` is unwired, not even
  that does: read `image-invalid` and whether the health unit succeeded this boot
  (`systemctl status novadeck-boot-good`).
- **A slot that never booted answers `good`.** `get-state` reads `boot-attempts ≥ 1` or
  `image-invalid > 0`; a freshly installed slot has neither, so it is indistinguishable from a
  confirmed one until its first boot. That is by design — a new slot must not report bad before it
  has ever tried.
- **A trial that is never confirmed does not revert on its own.** With the counter unwired, the
  automatic revert is the health unit failing and demoting the running image. If the session never
  comes up at all, nothing fires; `set-primary` back to the good slot by hand.

`set-primary` is the manual equivalent of the old `try`: it arms the other slot for its trial boot.
There is no manual `rollback` — `set-primary` back to the good slot is it. `self` is accepted anywhere an image name is, and resolves to
the booted image; that is what the boot-health unit's failure path uses to demote (`set-state self
bad`).

## Recovery: when it does not boot

There is no serial console. Power off, pull the card, and read it on your workstation.

**The journal is not on the slot's `/var`.** `/var/log` is bind-mounted onto
`/home/.novadeck/offload/var/log`, so it lives on the shared **home** partition and survives both
slots:

```sh
sudo mount /dev/sdX8 /mnt                     # novadeck-home
sudo journalctl -D /mnt/.novadeck/offload/var/log/journal -e
```

**Do not trust `-b -1` on these devices.** The RTC comes up stale, so the boot index is unreliable
and relative boot offsets silently select the wrong boot. List the boot IDs and query one
explicitly instead:

```sh
sudo journalctl -D /mnt/.novadeck/offload/var/log/journal --list-boots
sudo journalctl -D /mnt/.novadeck/offload/var/log/journal _BOOT_ID=<id>
```

The ESP carries the bootconf that decided the boot, and the booted slot's efi partition carries
its identity:

```sh
sudo mount /dev/sdX1 /mnt-esp                 # NOVADECK-ESP
cat /mnt-esp/SteamOS/conf/A.conf /mnt-esp/SteamOS/conf/B.conf
sudo mount /dev/sdX2 /mnt-efi                 # novadeck-efi-A (the booted slot's efi)
cat /mnt-efi/SteamOS/partsets/self            # which image this efi partition IS
```

`image-invalid: 1` on the conf of the image that just failed means it was demoted — by the health
unit's failure path, by hand, or by an interrupted install. `boot-attempts:` will read 0 whatever
happened, until the stage-2 counter is wired up.
`steamos-bootconf` is the authoritative tool; `images/test-bootctl.sh` documents the semantics.

The initramfs is written to **degrade loudly rather than brick**: if it cannot assemble the
`/etc` overlay it falls back to a writable un-overlaid root and says so via `/dev/kmsg`. A device
that boots to a shell with a strange `/etc` is that path, not a corrupt image.

A torn write to the ESP or to a slot's efi partition — a lost partset, a missing stage-2 GRUB — is
a **reflash**; the post-install hook refuses to update a card whose booted efi has no partsets.
That is the acknowledged failure mode of the design, not a bug to work around.

## Before a push

```sh
make verify-lock                # lock's novadeck rows vs packages/ (seconds)
make test                       # slot-state + bootctl + post-install + pairingd suites
make test-signing               # RAUC signing self-test (container)
make verify-pins                # overlay artifact bytes vs packages/*/artifact.pin (release gate)
```

CI runs `make test` and `make test-signing` on every push and pull request. `make test` needs no
build, no container, no root and no device — it executes the shipped artifacts against a sandbox.
