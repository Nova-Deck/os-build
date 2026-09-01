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
- [ ] Internal `/esp/SteamOS/conf/A.conf` unchanged (contents **and** mtime) — mount it read-only
      by PARTUUID to check, not by label.
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
- [ ] `ls -l /dev/novadeck/` → now **16 links**, spanning both disks (or 8 with an arbitrary mix).
      That is the old `by-partlabel` behaviour, reproduced on demand.
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
| 1 — card booted, internal present | **NOT RUN** — no device with both media |
| 2 — internal booted, card inserted | **NOT RUN** — same |
| 3 — fail-open | **PASS**, single-disk variant only (see below) |
| 4 — rauc resolves, read-only | **PASS** |

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
