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

- **The ESP is shared.** `/KERNEL` and the slot state (`/NOVADECK/STATE.{0,1}`) live there and
  serve both slots. ABL reads partition 1 only.
- **`/var` is per-slot, and `/etc` rides on it** (an overlayfs whose upper dir is
  `/var/lib/overlays/etc/upper`). A slot switch therefore carries `/etc` with it.
- **`/home` is shared and survives everything** — including the paired SSH keys in
  `/home/deck/.ssh`, and the offloaded `/var/log`. This is why an OTA does not lock you out.

## Build and flash a card

```sh
make sdcard                                   # -> out/images/sdcard.img
make verify-card                              # GPT, ESP, per-slot filesystem identities
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

`make-sdcard.sh` lays the **full** GPT but populates only the A side (ESP + root-A + var-A + home,
with `/home` pre-seeded with the native arm64 Steam client). The B slots and both `efi-*`
partitions are created empty, so moving to A/B updates never needs a reflash.

Run `verify-card` before you commit a card to a device — it asserts the built image rather than
the source tree, which is the only place the GPT, the ESP contents and the per-slot filesystem
identities are checked at all.

To install a freshly built kernel onto an already-flashed card's ESP without rebuilding the image:

```sh
make deploy ESP=/run/media/$USER/NOVADECK-ESP
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
PKIDIR=$HOME/novadeck-pki make bundle VERSION=<version>
```

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

### Install it

Drive the install **as `deck` over SSH** — rauc's D-Bus service plus polkit authorize it with no
`sudo` on the box and no password anywhere:

```sh
ssh deck@<device> rauc install /path/to/novadeck-<version>.raucb
```

Not as `root`: `/root` is on the read-only root and does not survive the slot write. Watch for
`Verifying signature done` (~20%) — that is the device's own keyring accepting the bundle.

Every install writes the whole slot today (`[image.rootfs]` names `rootfs.img` and nothing else),
so budget minutes of SD-card writes for a one-package bump.

The post-install hook rotates `/KERNEL` to the slot it just wrote, randomises the target slot's
btrfs fsid (both slots otherwise share an fsid *and* `devid=1`, and mounting one can hand you the
other), and copies `/var` across. Reboot to land on the new slot.

## Read and steer the slot state

```sh
novadeck-bootctl status               # what booted, and what the ESP says
novadeck-bootctl try b                # boot slot b next; revert after 1 failed attempt
novadeck-bootctl mark-good            # confirm the slot on trial — this is what ends a trial
novadeck-bootctl rollback             # abandon a trial, return to the active slot
```

**All of these need root, and a release image ships no `sudo`.** As `deck` the tool cannot answer
any of it. On a dev card, `ssh -i work/dev-ssh/id_ed25519 root@<device>`; on a release device,
read the state off the card offline (below). `rauc install` is the deliberate exception — it goes
through rauc's D-Bus service and polkit, which is why it works as `deck`.

**Three traps, each of which has inverted a conclusion on real hardware:**

- **`rauc status` cannot tell promoted from still-on-trial.** It reports the slot `good` in both
  states. Only the ESP slot state distinguishes them.
- **The `STATE.N` filename is not the slot.** `STATE.0` has held slot B's record. The higher
  `gen=` is the tiebreak; reading `STATE.0` as "slot A" inverts the answer.
- **A trial that is never confirmed reverts.** `try` arms a counter; `mark-good` is the only
  thing that ends the trial. Both branches of the abandon path — the trial slot failing to mount,
  and an explicit `rollback` — are hardware-validated, and both restore the previous kernel.

`set-kernel <a|b> [backup-name]` records which slot's boot image is currently on the shared ESP.
`try` warns (rather than refuses) when `/KERNEL` belongs to a different slot: that boot runs a
root whose `/lib/modules` came from another build, and `CFG80211`/`ATH12K` are `=m`, so it comes
up with no Wi-Fi on a device with no serial console.

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

The ESP carries the state that decided the boot:

```sh
sudo mount /dev/sdX1 /mnt-esp                 # NOVADECK-ESP
cat /mnt-esp/NOVADECK/STATE.0 /mnt-esp/NOVADECK/STATE.1
```

Higher `gen=` wins. `images/initramfs/init` is the authoritative description of the format.

The initramfs is written to **degrade loudly rather than brick**: if it cannot assemble the
`/etc` overlay it falls back to a writable un-overlaid root and says so via `/dev/kmsg`. A device
that boots to a shell with a strange `/etc` is that path, not a corrupt image.

A torn write to the ESP, or a `/KERNEL` that no slot's modules match, is a **reflash** — that is
the acknowledged failure mode of the design, not a bug to work around.

## Before a push

```sh
make verify-lock                # lock's novadeck rows vs packages/ (seconds)
make test                       # slot-state + bootctl + post-install + pairingd suites
make test-signing               # RAUC signing self-test (container)
make verify-pins                # overlay artifact bytes vs packages/*/artifact.pin (release gate)
```

CI runs `make test` and `make test-signing` on every push and pull request. `make test` needs no
build, no container, no root and no device — it executes the shipped artifacts against a sandbox.
