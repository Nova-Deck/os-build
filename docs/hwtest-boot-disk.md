# HW test — boot-disk-scoped partition links (`fix/boot-disk-scoping`)

Checklist for the one configuration nothing has ever been tested in: **a novadeck SD card and a
novadeck internal install attached to the same device at the same time.** Every novadeck medium
carries the same eight GPT names, so until this branch the running system resolved `/esp`, `/home`,
`grow-home`'s repart target and rauc's slot devices to whichever disk udev enumerated first.

What is being tested is not "does the card boot" — it is **which disk each of those four names
lands on**, in both directions, and that nothing writes to the disk it did not boot from.

---

## Before anything

- [ ] `make test` green (29 offline suites; `test-verify-signing` is container-only, `make test-signing`).
- [ ] Build is a **DEV** image. Every check below needs root over SSH, and a RELEASE build has no
      `sudo`/`su` — the dev key is baked for root. Source `dev.env` before the build.
- [ ] The device's ABL is in **Linux mode with "force external" available**. Linux mode tries
      internal first and takes it whenever the internal ESP carries `bootaa64.efi`, so without
      force-external the card is never reached and none of Group 1 can run.
- [ ] `journalctl -b -1` is unreliable here (stale RTC). Record `journalctl --list-boots` and query
      by `_BOOT_ID=` when comparing across reboots.

### Baseline — capture BEFORE the card ever goes in

This is the evidence every "did it touch the other disk" check compares against. Take it while
booted from internal, with **no card inserted**.

**`sgdisk` is NOT on the image** — gptfdisk is not in the package list, so every `sgdisk -p` below
has to be `sfdisk -d`, which is in util-linux and is equally sector-exact (it prints `start=` and
`size=` per partition). Confirmed missing on a 2026-09-01 DEV card.

```
lsblk -o NAME,PARTLABEL,SIZE,PARTUUID,FSTYPE
sfdisk -d /dev/<internal>            # partition table, sector-exact
sfdisk -d /dev/<internal> | sha256sum
```

- [ ] Baseline saved off-device. The number that matters most is the **end sector of the internal
      `novadeck-home` partition** — that is the only thing `systemd-repart` would move.
- [ ] Copy `/esp/SteamOS/conf/A.conf` off the internal ESP (contents + mtime).

---

## Group 0 — regression: no second medium

The common case, and the one that must not have moved. Run on a board with **no internal install**
(the S2 / ACE / Odin 2 fall through to the card unaided) or with the internal ESP not yet armed.

- [ ] **0.1 Fresh card, first boot.** Session comes up.
- [ ] `ls -l /dev/novadeck/` → **8 links**, all resolving to partitions of the booted disk.
- [ ] `findmnt -no SOURCE /home /esp` → both on the booted disk.
- [ ] `/home` filled the card (`df -h /home` ≈ card size, not the flashed ~1G) — `grow-home` ran.
- [ ] **0.2 Second boot.** `cat /esp/SteamOS/conf/A.conf` → `boot-attempts: 0` once the session
      has been up 30s (mark-good cleared it), and `boot-count` incremented.
      > Read the file, do NOT use `steamos-bootconf --conf-dir /esp/SteamOS/conf config --image A`:
      > that invocation prints nothing and exits 0, so it looks like a pass no matter what.

> If Group 0 regresses, stop. Everything below is about *which* disk; this is about whether the
> mechanism broke the only configuration that already worked.

---

## Group 1 — card booted, internal install present

**The target scenario.** Needs ABL force-external. Use a **fresh** card — `grow-home` only reparts
on a first boot, so a card that has already grown cannot exercise the destructive direction.

- [ ] **1.1** ABL force-external → the card boots, session comes up.
- [ ] `cat /run/novadeck/boot` → `root=` names a **card** partition. (If this file is missing,
      everything below is running in the fail-open path and proves nothing — see Group 3.)
- [ ] `ls -l /dev/novadeck/` → **8 links, all on the card.** Sixteen means it fell open; zero means
      the rule or its PROGRAM is missing.
- [ ] **1.2** `findmnt -no SOURCE /home` → the **card's** home, not the internal one.
- [ ] `findmnt -no SOURCE /esp` → the **card's** ESP.
- [ ] **1.3 The internal disk was not written.** Re-run the baseline `sfdisk -d /dev/<internal>`
      and diff. **Must be byte-identical** — in particular the internal `novadeck-home` end sector.
      > This is the check that matters most. Before this branch, `grow-home` resolved home by label,
      > took its parent disk, and ran `systemd-repart --dry-run=no` on it.
- [ ] **The internal `/home` was never mounted.** From the card (which has root),
      `dumpe2fs -h /dev/<internal-home> | grep -E 'Last mount time|Mount count'`. A `Last mount
      time` predating the card's boot proves it, and needs no baseline — the timestamp interprets
      itself. This is the check that actually carries 1.3; see the ESP note below for why.
- [ ] `journalctl -b 0 -u novadeck-grow-home | grep -oE '/dev/[a-z0-9]+'` → **only booted-disk
      devices.** Before this branch `grow-home` resolved home by label, took its parent disk, and
      ran `systemd-repart --dry-run=no` on it, so this is the destructive path named directly.
- [ ] Internal `/esp/SteamOS/conf/A.conf` unchanged — mount it read-only by PARTUUID, not by label.
      > **Compare contents only; the mtime is NOT an instrument, and a baseline read from a live
      > rw mount is worse than none.** Observed 2026-09-01: `SteamOS/conf` still carried an Aug 22
      > dirent timestamp while its contents were from that day, and an `A.conf` read from inside the
      > running internal session showed `boot-attempts: 0` where the disk held `1` — the reset was
      > still in page cache and never flushed. Take this baseline from a read-only mount, from a
      > system that is not the one writing it.
- [ ] **1.4 Boot accounting stays on the card.** Card's `A.conf` shows `boot-attempts: 0` after the
      session settles; the internal one still shows its baseline value.
- [ ] **1.5** Reboot (force-external again) → still boots the card, counter still clears. Two clean
      cycles, because a counter that climbs takes several boots to become visible.

---

## Group 2 — internal booted, card inserted

**The regression-risk direction**, and the one where a mistake damages something you care about:
here it is the *card* that must be left alone, and the internal install is the live system.

- [ ] **2.1** Boot internal normally (no force-external) with the card inserted.
- [ ] `cat /run/novadeck/boot` → `root=` names an **internal** partition.
- [ ] `ls -l /dev/novadeck/` → 8 links, all **internal**.
- [ ] **2.2** `findmnt -no SOURCE /home /esp` → both internal. Confirm `/home` is the internal
      library, not the card's.
- [ ] **2.3 The card was not written.** `sfdisk -d /dev/<card>` matches what was flashed; the
      card's `A.conf` untouched.
- [ ] The card's ext4 was **not** resized (`dumpe2fs -h /dev/<card-home> | grep 'Block count'`
      against the flashed image).

---

## Group 3 — fail-open, live, no reboot

The mechanism silently reverts to the old behaviour whenever the boot disk cannot be determined.
That is deliberate, but it is invisible, so prove it does what it claims — and prove you can tell
the two states apart, since a fallen-open system looks exactly like the original bug.

With both media attached, booted either way:

- [ ] `mv /run/novadeck/boot /run/novadeck/boot.bak`
- [ ] `udevadm trigger --subsystem-match=block --action=add && udevadm settle`
- [ ] `ls -l /dev/novadeck/` → still **8 links**, but one or more now pointing at the **non-booted**
      disk. That is the old `by-partlabel` behaviour, reproduced on demand.
      > It can never be 16. The names collide, and udev keeps exactly ONE symlink per name — which
      > is the whole bug: the loser gets no link at all, so it is invisible rather than ambiguous.
      > Observed 2026-09-01 booted from the card with an internal install present: all 8 flipped to
      > `sda`, including `novadeck-home -> sda19`. Count is not the signal; `readlink -f` is.
- [ ] `mv /run/novadeck/boot.bak /run/novadeck/boot` and re-trigger → back to **8**, all on the
      booted disk.

> Do not reboot while the handoff file is moved aside, and do not run this on a fresh card that has
> not yet grown — a fail-open `grow-home` is the destructive case.

---

## Group 4 — read-only, do not install

No OTA is planned in this configuration. These only confirm rauc *resolves* the right devices.

- [ ] `rauc status` → both slots resolve, and to **booted-disk** partitions.
- [ ] `readlink -f /dev/novadeck/novadeck-root-A /dev/novadeck/novadeck-root-B` → booted disk.
- [ ] **Do not run `rauc install` / `novadeck-update` with two media attached.** The install is
      performed by the *running* system's `post-install.sh`; on an image predating this branch that
      is still `by-partlabel` and still ambiguous.

---

## What has actually been run

Executed 2026-09-01 on an sm8650 board, DEV card, `NOVADECK_GIT=0d1a284`. The device had **no
internal novadeck install** — its `sda`–`sde` are the stock Android/UFS stack, and the only
`novadeck-*` GPT names anywhere on it were on `mmcblk0`. So this run retires the regression risk and
leaves the branch's actual purpose untested.

| Group | Result |
| --- | --- |
| 0 — single medium, two boots | **PASS** |
| 1 — card booted, internal present | **PASS** — see below |
| 2 — internal booted, card inserted | **BUG REPRODUCED** pre-branch, then **PASS** after OTA — see below |
| 3 — fail-open | **PASS**, both variants |
| 4 — rauc resolves, read-only | **PASS** |

**Group 1 — the configuration this branch exists for — PASSES.** Run against a v0.3.0 RELEASE
internal install (`NOVADECK_GIT=9f13131`, i.e. an image PREDATING this branch) with a freshly
flashed DEV card booted via ABL force-external. Sixteen duplicate GPT names were visible, 8 on
`sda` and 8 on `mmcblk0`:

- `/dev/novadeck/` held 8 links, **every one on `mmcblk0`**; `/`, `/home`, `/esp` and `/efi` all
  resolved to the card.
- **`grow-home` referenced only `/dev/mmcblk0` and `/dev/mmcblk0p8`. Zero `sda` references.**
- The internal home was never mounted: `sda19` ext4 `Last mount time` was the internal's own boot,
  12 minutes before the card booted, `Mount count 2`. Nothing from `sda` was mounted at all.
- The whole boot referenced `sda` exactly once — the kernel enumerating partitions.
- Internal partition extents identical to baseline (weak, see below).

**Group 3, run properly with both media, is the clearest demonstration of the original bug.**
Moving `/run/novadeck/boot` aside and re-triggering flipped **all 8** links to `sda`, including
`novadeck-home -> sda19`. So a pre-branch system booted from that card would have mounted the
internal home and aimed `systemd-repart` at `/dev/sda`. Restoring the file returned all 8 to
`mmcblk0` with `/home` and `/esp` unmoved.

**Group 2 against the PRE-BRANCH v0.3.0 internal reproduced the bug in full**, and is the reason
this branch matters beyond convenience. Booted from internal with the card inserted:

```
/          /dev/sda15      internal, correct — GRUB resolves root off $bootdisk
/home      /dev/mmcblk0p8  THE CARD
/esp       /dev/mmcblk0p1  THE CARD
grow-home  targeted /dev/mmcblk0p8 (no write: the card had no free tail)
```

The internal's own home was never mounted (`sda19` mount count unchanged); the card's was
(`Last mount time` = this boot). **The race also flipped direction between two consecutive boots on
the same hardware** — `sda` won all eight on the card's boot, `mmcblk0` won all eight here — so
label resolution across two novadeck media is nondeterministic, not merely wrong.

The damaging consequence is in the boot accounting. The internal's bootloader incremented
`boot-attempts` on its OWN ESP, then `mark-good` wrote `boot-ok` to the **card's** ESP instead, so
the internal's counter is never reset and climbs on every boot with a card inserted (observed
0 -> 1 -> 2). Left alone that marks a healthy slot bad and triggers a rollback. The card meanwhile
inherits the internal's `boot-count`/`boot-time`, so **a card used for a Group 2 run is polluted and
should be reflashed before any further Group 1 work.**

**Group 2 was then re-run after delivering the fix to the internal by OTA, and PASSES** — the same
hardware, the same card, both media attached, differing only in that the internal now carries the
branch:

```
16 duplicate novadeck GPT names visible (8 sda + 8 card)
/dev/novadeck/ -> 8 links, ALL sda
/  /home  /esp -> sda16, sda19 (65G), sda12
grow-home targeted /dev/sda19 (the internal); repart wrote nothing
```

The OTA path itself is therefore also proven end to end, on a RELEASE device, and is worth
recording because two steps of it looked like they might block:

- The v0.3.0 keyring still trusts the current signing cert — `ota/rauc/` is unchanged since
  `9f13131`, and the device reported `Verified inline signature by 'CN = novadeck OTA release'`.
- **`rauc install` of a LOCAL bundle succeeds as the unprivileged `deck` user**, no sudo and no
  polkit action required, so this test is repeatable without publishing anything to the OTA server.
- `post-install.sh` wrote `B.conf` onto an internal ESP that had only ever held `A.conf`. A slot
  written without its conf is what kills a boot candidate, so this was the substantive check.
- After the reboot, rauc on the internal resolves its slots as
  `/dev/novadeck/novadeck-root-{A,B}` — the last consumer that was still on labels there.

One trap when reading any of this: **probe after the session settles.** Immediately post-boot,
`rauc status` showed a slot `bad` and `B.conf` held `boot-attempts: 2, boot-count: 0`; ~75s later
both slots were `good` with `boot-attempts: 0, boot-count: 1`. Neither early reading meant anything.

**Two checks in this document could not fail, and were rewritten:** the `sgdisk` baseline (hashing
empty input) and the A.conf mtime comparison. A third was impossible as written (Group 3's "16
links"). On the tested hardware the internal `novadeck-home` also ends 16 sectors from the end of
the disk — the installer grows it at repartition time — so there is **no free tail for a
mistakenly-targeted `systemd-repart` to consume**, and the partition-extent check passes vacuously
even in the failure case. Weight `dumpe2fs` mount count and the `grow-home` journal instead.

Group 0, both boots: `/run/novadeck/boot` named `root=/dev/mmcblk0p4`; `ls /dev/novadeck/` gave 8
links, all `mmcblk0`; `/home` and `/esp` mounted `mmcblk0p8`/`p1`; `systemd-repart` applied to
`/dev/mmcblk0` — the booted disk — and `/home` grew to 13.8G (`3622651` 4k blocks). Second boot:
`boot-attempts: 0`, `boot-count` 1 → 2, and **`grow-home` wrote nothing** (zero occurrences of
`Writing new partition table` / `Growing existing partition` / `Applying changes`; resize2fs a
no-op; block count unchanged). Zero udev worker errors naming `on-boot-disk` on either boot.

`/usr/lib/novadeck/on-boot-disk` ships **0755** on the device. Note that this cannot be checked
offline the obvious way: `btrfs restore -m` errors out on this image's small/inline-extent files
(`system.conf`, `fstab` and the `.rules` all come back 0 bytes with `-m`, and correct without it),
so the built image yields content but not modes.

**Group 3 was weaker than written.** With only one novadeck medium attached, moving
`/run/novadeck/boot` aside and re-triggering gives 8 links, not 16 — it proves the fail-open path
still *produces* links, but not that it spans both disks. The 16-link discrimination needs Group 1's
hardware.

**`guard-rootfs.sh` assertion 7b has still never run.** The sealed-root guard is release-only —
`rootfs/assemble-rootfs.sh` skips it when `NOVADECK_DEV=1` — so the DEV card that proved everything
above skipped it by construction. It needs a RELEASE build.

---

## Abort conditions

Stop and capture evidence rather than continuing:

- Any diff in the non-booted disk's `sfdisk -d` output. **This is the failure the branch exists to
  prevent** — capture the full journal for the boot (`journalctl _BOOT_ID=<id>`), especially
  `novadeck-grow-home`.
- `ls -l /dev/novadeck/` empty on a device booted from a novadeck medium — the rule or
  `/usr/lib/novadeck/on-boot-disk` did not ship, which `guard-rootfs.sh` assertion 7b should have
  caught at build time.
- `/home` not mounted at all. Falls back cleanly by design (`nofail`), but it means no link was
  produced for a partition that exists.

## Offline recovery

These boards have no UART. If a boot wedges, pull the card and read its journal from the host:

```
journalctl -D <mnt>/var/log/journal --list-boots
journalctl -D <mnt>/var/log/journal _BOOT_ID=<id> -u novadeck-grow-home -u systemd-udevd
```
