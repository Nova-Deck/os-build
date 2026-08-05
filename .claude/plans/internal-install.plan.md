# Plan: internal (UFS/eMMC) installation via a standalone installer/recovery image

## Context

NovaDeck runs only from a `dd`'d SD card today. The long-standing goal
(`TODO.md:246`, `[[install-to-ufs-sdcard-library-goal]]`) is a real install to the
device's internal storage, after which the SD card becomes a Steam game library.

The obvious implementation — an `install_to_internal.sh` shipped in the image — is
rejected, and for a good reason: it would be the **only** feature on the device
requiring root. Today there is no `sudo` anywhere in the rootfs, and even OTA installs
run fully unprivileged (rauc's open bus policy plus a signature gate — HW-proven
2026-07-29). Adding a privileged whole-block-device writer to the shipped OS would
undo that property for one rarely-used feature.

Instead we ship a **second, small bootable SD image** — the SteamOS-recovery analogue.
It is a dedicated single-purpose OS, so it is root by definition and the shipped
NovaDeck image gains no privileged surface at all. It doubles as the recovery medium
the design already assumes exists (`partition-table.txt`: "an internal UFS install is
recovered by booting a separate SD-card image").

**Not a separate repository.** It shares the kernel, DTBs, initramfs, steamcl/GRUB,
`images/partition-table.txt`, the RAUC keyring and the signing PKI, and roughly a third
of the work below is *changes to the main image*. A split would duplicate all of that or
make os-build a submodule, and would reintroduce exactly the drift class this repo
designs against. The seam already exists: `.github/workflows/image.yml` is a
`workflow_call` with `artifact: sdcard|bundle` — `installer` becomes a third value, and a
new top-level `install/` stage directory sits as a peer of `boot/`, `images/`, `ota/`.

### Decisions taken

| Axis | Choice |
|---|---|
| Medium | Standalone lightweight image, no full NovaDeck rootfs |
| Source | **Network only** — the medium is version-independent and always installs current stable |
| Android | **Preserve a dual boot** — Android stays bootable, but its `userdata` is **destroyed**. Accepted 2026-08-05: there is no mechanically sound alternative. The obligation this creates is an informed consent gate (§4d), not a mitigation |
| PARTUUID work | Folded in as Phase 1 rather than shipped standalone |

### One refinement to the medium

The chosen shape was "ESP + a fat `initramfs.cpio.gz`". I propose the same image but with
the userspace as a **zstd squashfs on a second partition** instead of inside the cpio:

```
p1  esp   64M  ef00  bootaa64.efi (steamcl) + grubaa64.efi + grub.cfg
                     Image + dtbs/ + initramfs-novadeck.img
                     novadeck/wifi.conf   <- optional, user-supplied
p2  root  ~900M 8300 installer.squashfs (zstd)   <- pacman-resolved userspace
```

Reason: `images/mkinitramfs.sh` stages **6 binaries** and resolves `DT_NEEDED` with
`readelf`. That walker cannot discover the non-ELF runtime state a network installer
needs — NSS modules for `getpwnam`, `/etc/ssl/certs` for TLS, `/etc/dbus-1/system.d/`,
glib schemas, udev rules, `/etc/machine-id`. Every one of those is a silent failure on a
device with no serial console. Staging a pacman-resolved tree brings them along *by
construction*. A squashfs is also demand-paged rather than fully resident, and
`CONFIG_SQUASHFS=y` / `CONFIG_SQUASHFS_ZSTD=y` are already in `kernel/kernel.config` and
asserted at `kernel/build.sh:187` — this finally makes that assertion's stated rationale
true (it currently claims "the /etc overlay mounts a squashfs seed", which is stale).

Total image ≈ 1 GB, ≈ 400 MB compressed (the graphics stack for the GUI dominates — see
Phase 5). It carries no bundle and needs no reflash per release; the release card is ~9 GiB
compressed by comparison.

---

## Phase 0 — Hardware reconnaissance (BLOCKING, no code ships)

Nothing below can be committed to without these answers. **The dual-boot go/no-go that used
to head this list is closed** — the ROCKNIX ABL is a chooser, not a fixed branch (below).

A read-only `install/probe-internal.sh`, run from a dev card over SSH, dumping to
`docs/internal-storage.md`:

1. **LUN topology** — `lsblk`, and for every internal disk `sgdisk -p`, `sfdisk --dump`,
   `/sys/block/*/{removable,ro,size}`, the UFS `wwid` and LUN number. Which LUN carries
   `super`/`userdata`/`metadata`, and whether it is exclusively Android data.
2. **The exact OEM partition name set** per SoC, so `install/disk-rules.conf` is written
   against reality and not against recalled AOSP naming. At least one SM8550 and one
   SM8650 device.
3. **Whether Linux sees internal storage at all.** `docs/bringup.md:9` still says "UFS
   itself unverified". `CONFIG_SCSI_UFSHCD` is in the config; that is not the same thing.
4. **ABL fallback when the stored default names a medium that is absent** — specifically,
   default = "Linux / SD" with no card inserted: does ABL fall back to internal, or stop?
   This is the one ABL question that still changes the product: it decides whether the
   post-install flow ends with "reboot, done" or must end with "hold Volume Up and change
   your default", and whether "install complete" should power off or reboot.
5. **Where in `devinfo` the boot choice lives, and its size** — capture the partition raw,
   *for backup only*. The choice is persisted in `devinfo` (user-confirmed 2026-08-05).
   `devinfo` is already in the `deny` list at §3, and **the installer must never write it**
   (see "Explicitly out of scope"). This item is a capture, not a risk.

   > **Closed, was the dual-boot go/no-go.** ABL is a chooser: a *configurable default boot
   > target* (Linux internal / SD / USB, or Android) plus a *temporary override by holding
   > Volume Up at startup*. Confirmed by the user 2026-08-05 and corroborated by the upstream
   > README in `_reference/abl`. So an ESP on internal cannot strand Android, and an internal
   > install stays recoverable by booting the installer medium on demand — which is exactly
   > the mechanism `images/partition-table.txt` already assumes. Two further facts from
   > upstream's `update.sh`: ABL is a **signed, per-device ELF** (`abl_signed-<HW_DEVICE>.elf`
   > flashed to `abl_a`/`abl_b`), so we consume it and cannot rebuild it; and it is addressed
   > via `/dev/disk/by-partlabel/`, so internal storage enumerates with partlabels from Linux
   > under ROCKNIX's kernel — evidence for (3), not proof for ours.
6. **LUN enumeration stability across boots** — if `/dev/sdX` is not stable, target
   selection must key on `wwid`/LUN, not the kernel name.
7. **gamescope without a logind session.** The main image gets an active `seat0` via SDDM
   autologin, and `[[sm8650-gamescope-session-plumbing]]` says gamescope MUST use the libseat
   logind backend there. The installer has no user session — confirm gamescope comes up as
   root over `seatd` (already in `PKGS`) or `LIBSEAT_BACKEND=builtin`, on-panel, with
   `--use-rotation-shader`. Blocks Phase 5.

   **And in the same run, confirm the pad enumerates.** §4d takes *consent* on the pad and §5 has
   no text entry to fall back to, so input is load-bearing beyond the GUI. **The installer ships
   InputPlumber** (below), so what is being confirmed is the same stack the main image already
   validated — not a new one. Blocks §4d and Phase 5.
8. **UFS write throughput** for a ~3.5 GB raw slot write, plus whether to refuse an
   install below a battery threshold.
9. **Side effects of removing/shrinking `userdata`** on ABL or the modem — some vendor
   ABLs read `misc`/`metadata`. Test on a sacrificial device *before* writing anything.

**Deliverable:** `docs/internal-storage.md` with captured GPTs, plus the real `userdata` sizes
per device — §4d's consent screen quotes them, so they are a product input, not just recon.

---

## Phase 1 — Partition identity: kill the PARTLABEL coin flip

Once internal is installed, an inserted card presents the **same** PARTLABELs. `findfs` is
then nondeterministic across **five** sites, not one:

| site | today |
|---|---|
| `boot/gen-grub-cfg.sh` cmdline | `root=PARTLABEL=novadeck-root-A` (+ `.var=`, `.efi=`) |
| `images/assemble-rootfs.sh:327` | `PARTLABEL=NOVADECK-ESP /esp` in `/etc/fstab` |
| `images/assemble-rootfs.sh:336` | `LABEL=novadeck-home /home` in `/etc/fstab` |
| `assemble-rootfs.sh` → `grow-home.sh` | `/dev/disk/by-label/novadeck-home`, then `systemd-repart` on its parent disk |
| `fs-overlay/etc/rauc/system.conf:87,92` | `/dev/disk/by-partlabel/novadeck-root-{A,B}` |

The `grow-home` one is the worst: it would run `systemd-repart` + `resize2fs` on the
**wrong disk**. One mechanism must cover all five.

### 1a. Boot-time PARTUUID derivation in stage 2

`probe --part-uuid` exists in our tree (`work/grub/src-grub/grub-core/commands/probe.c:50`),
formats lowercase via `%pG` — exactly the form `findfs PARTUUID=` and the kernel want — and
is simply **absent from `MODULES` at `boot/grub.sh:101`**.

In `boot/gen-grub-cfg.sh`, after the existing `$bootdisk` derivation:

```
insmod probe
probe --part-uuid --set=rootuuid ($slotroot)
probe --part-uuid --set=varuuid  ($bootdisk,gpt$P_VAR)
probe --part-uuid --set=efiuuid  $root
```

and emit `root=PARTUUID=$rootuuid … novadeck.var=PARTUUID=$varuuid novadeck.efi=PARTUUID=$efiuuid
novadeck.slot=A`. This derives from the disk GRUB was chainloaded off, at boot, so it is
immune to OTA — `post-install.sh` reinstalling the build-time `grub.cfg` is exactly what we
want. Keep the existing `else` arm loud and falling back to the `PARTLABEL=` form, so a
`probe` regression is a visible message rather than a black screen.

`images/initramfs/init` currently derives the slot letter by matching the root PARTLABEL;
that becomes the explicit `novadeck.slot=` (stage 2 knows it statically). `/var/lib/novadeck/slot`
stays the independent witness.

### 1b. Variable partition indices, for dual boot

Our 8 partitions will not be at indices 1..8 on a disk that keeps Android. GRUB has no
arithmetic and `probe` has **no `--part-label`** (verified: only `driver/partmap/fs/fs-uuid/label/part-uuid`),
so indices cannot be discovered in stage 2.

Mechanism: the installer writes the eight indices into the ESP's existing grubenv, which
stage 2 already loads for `saved_entry`:

```
load_env -f ($esp)/EFI/steamos/grubenv saved_entry nd_esp nd_efi_a nd_efi_b nd_root_a nd_root_b nd_var_a nd_var_b nd_home
if [ -z "$nd_root_a" ]; then set nd_esp=1; set nd_efi_a=2; … ; fi   # defaults from partition-table.txt
set slotroot="$bootdisk,gpt$nd_root_a"
```

Defaults come from `partition-table.txt` at generation time, so an SD card is unchanged and
never reads the new keys. `post-install.sh` does not rewrite grubenv, so the values survive
OTA. Testable offline in `images/test-stage2-grub.sh`.

### 1c. A disk-scoped device map in the initramfs

In `images/initramfs/init`, after `ROOTDEV` resolves, walk **the boot disk's own** partitions
via sysfs and publish `/run/novadeck/dev/<gpt-name> -> /dev/<part>`:

```sh
part=${ROOTDEV#/dev/}
disk=$(basename "$(readlink -f /sys/class/block/$part/..)")
mkdir -p /run/novadeck/dev
for p in /sys/class/block/"$disk"/*/partition; do
  n=$(basename "$(dirname "$p")")
  l=$(blkid -p -s PART_ENTRY_NAME -o value "/dev/$n" 2>/dev/null) || continue
  case "$l" in novadeck-*|NOVADECK-ESP) ln -sfn "/dev/$n" "/run/novadeck/dev/$l" ;; esac
done
```

~15 lines, no udev, index-agnostic, works for `sda4` and `mmcblk0p4` alike, disk-scoped by
construction. Adds `blkid` to `BINS` in `images/mkinitramfs.sh` (util-linux, shares
`libblkid` with the `findfs` already staged). Note this is *more* deterministic than
`by-label`, which waits on an asynchronous udev probe — which is why `grow-home.sh` has a
settle-and-poll block today.

Then repoint the four remaining consumers at `/run/novadeck/dev/…`:
`assemble-rootfs.sh` (both fstab lines + `grow-home.sh`'s `HOME_DEV`),
`fs-overlay/etc/rauc/system.conf`, and `post-install.sh`'s `DEVDIR` seam.

### Tests

- `images/test-stage2-grub.sh` — assert `insmod probe`, the three `probe --part-uuid --set=`
  lines, `root=PARTUUID=$rootuuid`, `novadeck.slot=<S>`, the grubenv default block, and that
  the fallback arm still emits the PARTLABEL form. Follow the existing precedent of
  *executing* the emitted regexp rather than grepping for it.
- New `images/test-initramfs-init.sh` — run the real `init`'s map block against a fake
  `/sys/class/block` with **two** disks carrying identical PARTLABELs and `blkid` stubbed.
  Assert every symlink points at a partition of the boot disk and that the second disk's
  identically-named partition is never linked.
- `images/test-post-install.sh` — re-point `DEVDIR`, stays green.
- Grep assertion: no shipped file references `/dev/disk/by-partlabel/novadeck-*` or
  `by-label/novadeck-home` outside a documented fallback.

**Gate: HW boot on both slots + one successful OTA before Phase 3 lands.**

---

## Phase 2 — Extract the reusable install primitives

The installer must write everything a RAUC bundle does not carry. Almost all of that logic
exists twice-over already; the goal is one copy.

New `fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh`, sourced by
`fs-overlay/usr/lib/rauc/post-install.sh` so the OTA path and the install path cannot drift:
`mint_partsets`, `write_efi_partition <mnt> <slot> <bootdir>`, `refresh_esp_stage1`,
`seed_var <dev> <slot> <seedtar>`, `mkfs_esp`.

| artifact | source of truth |
|---|---|
| GPT | `images/partition-table.txt` + `images/genpart.sh`, both **shipped verbatim** into `/usr/lib/novadeck/install/` |
| ESP stage 1 (`bootaa64.efi`, `steamcl-version`, `steamcl-restricted`, `fonts/`) | `/usr/lib/novadeck/boot/` of the **freshly written internal root** — `post-install.sh`'s `refresh_if_diff` block, factored out |
| ESP `grubenv` | **new**: `boot/grub.sh` emits a pristine `grub-editenv`-created grubenv into `out/boot/`; the device just `cp`s it (removes a `grub-editenv` dependency from the device) |
| ESP `SteamOS/conf/A.conf` | `steamos-bootconf` (`bc create --image A` + `set-mode reboot`) — reuse, don't re-emit `make-sdcard.sh`'s heredoc |
| efi-a/efi-b stage 2 | `/usr/lib/novadeck/boot/` of the installed root — `post-install.sh` step 3, factored out |
| efi partsets | **minted from the NEW partition UUIDs** — `post-install.sh` copies them from the *running* `/efi`, which is a different disk here. `make-sdcard.sh`'s `mkpartset`/`mkefi` is the logic; extract it |
| var-a / var-b | **new**: `assemble-rootfs.sh` also writes its `$varstage` to `/usr/lib/novadeck/var-seed.tar.zst` inside the root (`work/base/var` is ~13 MB, negligible in a 7 G slot) |
| rootfs-a | the signed RAUC bundle (Phase 4) |
| rootfs-b | nothing — left empty and **no `B.conf`**, matching the release-card shape so steamcl sees one image and retries A rather than switching (`make-sdcard.sh`'s `mkconf` site explains why). First OTA fills B |
| `/home` Steam seed (~1 GB) | **new published artifact** `steam-seed-<pin>.tar.zst`, sha256 verified against the pin **baked into the installer image**, not against `latest.json` (explicitly not a trust boundary). Folding it into the bundle instead does not fit: rootfs-a is 7 G with ~0.9 G margin |

Also in this phase:
- `images/customize-base.sh:190` — no change (installer tooling must **not** enter the shipped
  image). `gptfdisk` + `dosfstools` go into the installer package list only.
- `images/genpart.sh` — two seams: `TABLE="${NOVADECK_PARTITION_TABLE:-<next to the script>}"`,
  and a new `--append <target>` mode emitting `sgdisk -n 0:0:+<size>` (index 0 = first free
  number, sector 0 = first aligned free sector) so partitions can be added to an existing GPT
  without `-Z`. Same idiom as `post-install.sh`'s `ESP=`/`EFI=` seams.
- `images/guard-rootfs.sh` — assert the four new files exist in the built tree.
- New host test: the shipped `partition-table.txt` / `genpart.sh` are **byte-identical** to the
  repo copies.
- `images/test-post-install.sh` stays green — that is what proves the extraction is
  behaviour-preserving.

---

## Phase 3 — Target selection and the dual-boot carve

### The carve

`super` (Android dynamic partitions) is sized to its contents and cannot be shrunk.
`userdata` is typically f2fs with FBE and cannot be shrunk in place either. The only
mechanically sound "preserve dual boot" is therefore:

> **Delete `userdata`, recreate it smaller at the front of its old span, and append our 8
> partitions into the remainder.** Android survives as a bootable but **factory-reset**
> system. Everything else — `xbl`, `abl`, `tz`, `modemst*`, `persist`, `devinfo`, `super`,
> `boot` — is never touched.

**This is the whole safety model, and it is deliberately the entire safety model** (2026-08-05):
**exactly one pre-existing partition is modified — `userdata` — and everything we create goes
into space that partition gave up. Nothing else on the disk is read for content, written, moved,
or resized.** Two mechanisms enforce it and nothing else is relied upon:

1. The `deny` gate below, checked twice by independent rules (§ `select-target.sh` items 4 and 5),
   so a typo widening one rule still cannot open a write path.
2. A **big, unmissable consent screen** (§4d) naming the one partition and its real size.

There are no backups, no restore path, and no undo — see rule 10 for why each was rejected
rather than merely skipped. A blast radius this narrow is worth more than a backup of it.

The new `userdata` size is a user choice on the confirm screen (default 16 GiB, floor 8 GiB),
with our minimum from `genpart.sh --min` (~15 GiB) plus a `HOME_FLOOR` of 8 GiB enforced
against the remainder.

### `install/disk-rules.conf` — the brick gate

Glob-matched against GPT partition names (case-folded, `_a`/`_b`/`bak` suffixes normalised),
written against the Phase-0 captures:

```
deny     xbl*|abl*|tz|hyp|aop|devcfg|keymaster|cmnlib*|uefi*|xbl_config*
deny     modemst*|fsg|fsc|persist|frp|misc|devinfo|dtbo|vbmeta*
deny     boot*|init_boot*|recovery*|logfs|toolsfv|multiimgoem|storsec
deny     super|super_?          # preserved for dual boot, never resized
sacrifice userdata              # deleted and recreated smaller
require  userdata               # positive proof this is the Android data LUN
```

This file is the thing to review as if it were the whole feature.

### `install/select-target.sh` — pure, no side effects

1. Target ≠ the disk backing the running root (parent of `root=` in `/run/novadeck/boot`).
2. `/sys/block/X/removable == 0`, `ro == 0`. **The SD card is never written** — assert it.
3. `sgdisk -v` reports zero problems and both GPT headers are present. A damaged backup GPT
   is refused: we cannot distinguish "damaged" from "not what we think it is".
4. Every partition name matches an `allow`/`deny`/`sacrifice` rule. Any unmatched name → refuse
   and print it.
5. No `deny` match in the span we intend to write — evaluated **independently** of (4), so a
   typo widening a rule still cannot open the brick path.
6. `require` satisfied.
7. Free space after the shrunk `userdata` ≥ `genpart.sh --min` + `HOME_FLOOR`.
8. **Idempotency:** if the disk already carries the NovaDeck 8, skip 4–6 — it is already ours,
   and a re-run is a re-lay + re-write, which is the correct semantics for "reinstall".
   **`/home` is the user's choice on this path, not a consequence.** A reinstall offers *keep*
   (rootfs slots, `/var`, ESP and EFI rewritten; `/home` left untouched, games and saves intact)
   or *erase and recreate*. **Keep is the default and erase must be explicitly selected** —
   never the other way round, since the failure mode of getting this wrong is destroying a
   library the user may have spent days filling over Wi-Fi. Erasing takes the §4d sequence gate
   in its own right: measured in what the user would actually miss, a game library outranks a
   factory-reset Android. Keeping `/home` still requires no consent gate at all.
9. Exactly one disk passes. Zero → name what was rejected and why. Two+ → refuse and list;
   never pick.
10. **A record, not a backup — and never a refusal condition.** Decided 2026-08-05: the
    installer takes no backups. Reasoning, so this is not reintroduced:

    - There is nowhere to put one. The only durable location is the installer medium, which
      means mutating the user's card to hold something nobody restores from;
      `/run/novadeck/install/` is tmpfs and evaporates at reboot.
    - A restored GPT would point at a `userdata` we have already destroyed by design, so it
      buys nothing in the expected path. It helps only in a narrow bug window — table modified
      before data writes, or a wrong-LUN pick — and in the wrong-LUN case the user is in no
      state to run a restore anyway.
    - **No `devinfo` backup.** The ABL boot choice is a preference with a UI: if it is lost the
      user holds Volume Up and re-sets it. The irreplaceable part of `devinfo` is unlock/verity
      state, where restoring a stale copy is no remedy. And a backup would create a code path
      that addresses `devinfo` by name, degrading the invariant from "the installer never opens
      `devinfo`" to "…opens it read-only" — after which one `if=`→`of=` edit is a brick.
    - The earlier "refuse if the backups cannot be written" was an outright defect: a full or
      write-protected medium would block an install to protect a file nobody reads.

    What is kept is a plain-text **install record**, appended to the installer medium if it is
    writable and skipped silently if not: `sfdisk --dump` of the target's pre-state, the chosen
    target and `wwid`, the rules that matched, and the §4d acknowledgement. It is forensics for
    a field failure and a record of what the user agreed to — a few lines of text, never a
    restore source, and never able to stop an install.
11. Sources verified before the first `sgdisk`: `rauc info --conf … --keyring /etc/rauc/keyring.pem`
    on the bundle, and the home-seed sha256 against the baked pin.

### Tests

`install/test-select-target.sh` — this is where the assertion budget goes, ≥60 cases against
the **real captured GPTs** from Phase 0: data LUN accepted; the same tree with `abl` present
→ refused; unnamed GPT → refused; damaged backup GPT → refused; the boot SD → refused;
too-small remainder → refused; two eligible LUNs → refused; already-NovaDeck → accepted via
(8); every `deny` name individually → refused.

### Blast radius, stated plainly

**The recovery model, stated once: for a bricked device there is exactly one recovery, and it is
EDL/QFIL with a vendor firehose programmer.** There is no software undo, no backup to restore
(rule 10), and no on-device repair — the installer medium can reinstall NovaDeck, but it cannot
resurrect a device whose boot firmware is gone. Every other safety property in this phase exists
because that is the only backstop.

This is *why* the blast radius is one partition rather than a matter of taste. The risk is low
precisely because we touch `userdata` and nothing else — but it is low by construction, not by
luck, so the construction is the thing under test:

- **Wrong LUN carrying `xbl`/`abl`** → hard brick, EDL only. Rule 5 is the sole thing preventing
  it, which is why selection is a separate side-effect-free script with its own test suite. This
  single failure mode justifies the entire `disk-rules.conf` + double-check design.
- **Right LUN, interrupted** → recoverable by re-running, *provided* the internal ESP is
  written and the bootconf armed **last**. Order the installer exactly as `post-install.sh`
  orders itself: nothing points at the new install until the new install is real. This is the
  one failure class with a genuine software recovery, which is why the ordering is not
  negotiable.
- **Completed** → Android's user data is gone permanently, by design and with consent. Nothing
  restores it. Do not imply reversibility anywhere in the UI.

**EDL is genuinely available to users, not just to a vendor** (confirmed 2026-08-05): the
upstream bootloader project maintains EDL restore images for every device it supports, our two
boards included. So "recoverable via EDL" is an honest statement rather than a technicality, and
the earlier Phase 0 item asking whether a firehose is obtainable at all is closed — no
investigation needed.

Two caveats it does not remove. The restore images live on third-party cloud storage, so they
cannot be pinned by URL and sha256 the way every other external artifact in this repo is
(`packages/*/prebuilt.pin`, the kernel tarball) — the recovery path is the one dependency we
cannot make reproducible, and documentation must not imply we control it. And we should not
mirror or redistribute the images ourselves: firehose programmers are vendor-proprietary and
signed.

**None of this belongs on the consent screen** — a brick is a bug in our gate, not an expected
outcome of installing, and putting EDL in front of every user would misrepresent the risk of the
normal path while diluting the one message that screen must land. Recovery goes in the
installer's documentation.

> **Decided 2026-08-05 — name the source explicitly in `docs/`.** `[[no-armada-refs-in-source]]`
> bars naming peer distros in shipped files; this is its **second granted exception** (the first
> being the root `README.md` acknowledgements). The recovery doc names ROCKNIX as the maintainer
> of the EDL images rather than describing it obliquely, because a brick is the wrong moment for
> discretion. The exception covers pointing users at recovery images and nothing wider.

---

## Phase 4 — The installer runtime

### 4a. Retargeting RAUC

`rauc install` with the service enabled ignores `-c` and has no `--override-boot-slot` (those
exist only under `#if ENABLE_SERVICE == 0`), so **the installer owns the service process**.
`install/rauc-session.sh`:

1. Synthesize `/run/novadeck/install/rauc.conf` — no `bootloader=` (optional, and omitting it
   means no bootchooser call can fire against boot state that does not exist here), no
   `data-directory=` (a virgin slot has nothing for `adaptive=block-hash-index` to reuse; it
   falls through to `raw_copy`), and **exactly one** slot, with no `bootname=`:

   ```ini
   [system]
   compatible=novadeck
   bundle-formats=verity
   [keyring]
   path=/etc/rauc/keyring.pem
   check-purpose=codesign
   [handlers]
   post-install=/usr/lib/novadeck/install/post-install-fresh.sh
   [slot.rootfs.0]
   device=/run/novadeck/install/target-root-a
   type=raw
   ```

   One slot is load-bearing: `select_inactive_slot_class_member()` iterates a `GHashTable`, so
   with two inactive slots the pick is hash-order nondeterministic.
2. Start a private system bus (`dbus-daemon --system --fork`) **before anything else touches
   the bus**, then `rauc -c … service --override-boot-slot=_external_` (rauc's own
   external-medium mode: all slots `ST_INACTIVE`, no booted slot required). Assert ownership of
   `de.pengutronix.rauc` before proceeding, so D-Bus activation of the stock unit can never
   race in with the wrong config.
3. `rauc install <https url>` then talks to that service.

Plan for the **full ~3.5 GB stream** — no dedupe on a virgin slot. A failed attempt is cheap
to retry because a re-run re-lays and re-streams.

### 4b. Network

Network-only means Wi-Fi must be joined inside the installer on a device with **no keyboard and
no guarantee of a working touchscreen** (decision 2026-08-05). So there is no on-device credential
entry at all:

1. **`novadeck/wifi.conf` on the installer ESP — the mechanism, not a fallback.** The user drops
   `SSID=`/`PSK=` from their PC before booting. Mirrors the tracked `dev.env` idiom. Read once,
   never written back, and **never copied into the installed system** — the PSK is plaintext on a
   FAT partition the user controls, and it should not outlive the install.
   Ship a commented **`novadeck/wifi.conf.example`** on the medium so there is something to copy.
2. **USB-C Ethernet / USB keyboard** — free, and the zero-config path: NetworkManager handles a
   wired carrier itself, so an adapter needs no file at all. SDL delivers keyboard events
   alongside controller events if one happens to be attached.

**The GUI no longer renders an SSID picker or an on-screen keyboard.** Both are deleted.

**What this costs, and the obligation it creates.** A wrong or missing file means power off, pull
the card, edit it on another computer, reboot — an expensive retry loop. A generic "network
failed" is therefore not acceptable here; the installer must name which of these it is, because
each has a different fix:

| Diagnosis | The user's fix |
|---|---|
| no `wifi.conf` on the ESP | create it — point at `wifi.conf.example` |
| present but unparseable | show the offending line number |
| SSID not in scan results | typo, or 5 GHz-only AP out of range |
| associated, auth failed | wrong PSK |
| associated, no DHCP lease | AP/DHCP problem, not ours |
| lease held, OTA host unreachable | upstream or DNS, not ours |

Each is a distinct screen with the SSID quoted back. This table is the acceptance criterion for
§4b, not a nicety — it is the whole UX of a network-only installer that cannot be reconfigured
in place.

**A confirm screen before connecting.** Once `wifi.conf` is parsed, show the SSID it names and
wait for `A` to join, `B` to abort. Nothing destructive happens here, so a plain button press is
the right weight — deliberately *not* the §4d sequence gate. Its job is to catch the stale-file
case: a card that has been round-tripped through a previous install, or edited for a different
network, names the wrong SSID and the user sees it before a connection attempt rather than after
a failure. The PSK is never displayed.

Then `curl -fsSL <OTA_URL>/<channel>/latest.json`, reusing `novadeck-update`'s hardening
verbatim: every manifest field is attacker-controlled, and `bundle` is forced to a bare
filename (urlparse plus `/`, `\`, leading-dot checks).

### 4c. Orchestration

`install/novadeck-install` — the ordered spine, each step a named function, nothing before the
confirm:

```
recon → select-target → BACKUP GPTs → verify sources → [CONFIRM]
  → shrink userdata → genpart.sh --append → mkfs (esp, efi-a/b, var-a/b, home)
  → rauc install (rootfs-a)  → seed /home  → write efi-a/efi-b + partsets
  → write ESP stage 1 + grubenv (incl. nd_* indices) → arm A.conf  ← LAST
```

`install/post-install-fresh.sh` is a distinct handler from `/usr/lib/rauc/post-install.sh`
(which needs `/esp`, `/efi`, `steamos-bootconf this-image` and a running `/var` to rsync,
none of which apply here) but sources the same `lib-slotwrite.sh`.

### 4d. The consent gate — `[CONFIRM]` in the spine above

Android's `userdata` is destroyed by design and that is accepted. The whole obligation
therefore lands here: the user must understand *specifically* what they are losing, and say so
deliberately. A generic "this will erase data, continue?" does not discharge it.

**It is a screen, generated from what `select-target.sh` actually found — never a fixed
string.** It quotes the real device: which disk and LUN, the current `userdata` size and the
size it will be recreated at, and the resulting free space. Vague totals invite "sure,
whatever"; a concrete "your Android data partition, 96.4 GiB, will be deleted" does not.

It must state, in the user's terms and not ours:

- Everything stored in **Android** — apps, saves, photos, downloads, accounts — is gone, and
  is **not recoverable** by us or by them.
- Android itself **still boots**, and arrives factory-reset. `super` is untouched.
- The **SD card is never written** (§3 rule 2 already asserts this). Say so — it is the one
  reassurance that is both true and load-bearing, since the card is the user's game library.
- Which medium the device will boot by default afterwards, and that Volume Up at startup
  switches back to Android at any time.

**The acknowledgement must cost something to give — with gamepad input only.** No keyboard, no
guaranteed touchscreen, and after §4b no text-entry widget exists to borrow. A single `A` on a
focused "Continue" is one thumb-twitch from an accidental wipe, so it cannot be that either.

**Mechanism: a random button sequence, echoed back.** The screen shows four face buttons in a
random order generated per run — e.g. `B  X  A  Y` — and the user presses them in that order.
It is the gamepad analogue of typing `ERASE`, and it is the strongest option actually available
here:

- No keyboard, no touchscreen, no text entry, no new widget.
- **Randomised per run, so it cannot become muscle memory.** This is the property hold-to-confirm
  lacks: a 3-second hold can be performed while looking away, and a user who has done it once
  will do it faster the second time. A sequence that changes cannot be performed without reading
  the screen at that moment.
- Cheap — a few lines against SDL2 controller events.
- A wrong press **re-randomises and redraws** rather than locking out. This is a recovery tool;
  it should not punish a slip, and re-randomising means a mistake cannot be brute-forced by
  repetition.

Hold-to-confirm stays documented as the fallback if controller event handling turns out to be
unreliable on this hardware — it proves intent, just not attention.

**Input availability is itself a gate.** If no controller is detected, fall back to a typed
phrase on a USB keyboard if one is attached. If neither input exists, the installer **stops and
says so** — it must never auto-proceed, and there is no bypass. An installer that cannot take
consent cannot install.

**Non-negotiables:**

- No env var, flag, or config on the medium may pre-satisfy it. Note this now cuts against §4b:
  the medium legitimately carries `wifi.conf`, so there is an established "drop a file to
  configure it" idiom — and **consent must never join it.** No `consent.txt`, no `--yes`. If an
  unattended path is ever wanted it is a separate, deliberately-named artifact, never a quiet
  bypass of this screen.
- The ack is **recorded** into §3 rule 10's plain-text install record: timestamp, target disk
  `wwid`, the `userdata` before/after sizes, and the exact text shown. Best-effort — if the
  medium is not writable it is skipped, never blocking the install. It is the evidence if a user
  later reports being wiped without warning.
- `install/test-install.sh` already asserts the orchestrator refuses without a completed
  confirm. Extend it: assert the screen's text is **derived** (feed two different captured GPTs,
  assert the quoted sizes differ); that no environment variable and no file on the medium
  satisfies the gate; that the sequence is not constant across runs (seed it, assert two runs
  differ); and that a wrong press re-randomises rather than advancing.

**The reinstall case has its own screen — resolved 2026-08-05.** §3 rule 8 accepts an
already-NovaDeck disk via the idempotency path. There is no Android `userdata` there to destroy,
so the wipe warning above would be flatly false; instead that screen offers **keep `/home`
(default) or erase and recreate it**, and only the erase branch arms a gate. Consequences:

- Choosing *keep* is non-destructive to user data — no sequence gate, a plain `A` is right.
- Choosing *erase* takes the full sequence gate, with its own derived text quoting the current
  `/home` size and, if cheaply available, the installed game count or used space. "Erase 214 GiB
  of games and saves" is the number that stops someone; "erase /home" is not.
- The two consent paths must not share a code path that could let the Android-wipe text render
  on a reinstall, or vice versa. Assert both renderings in `install/test-install.sh` from
  captured GPTs: an Android disk produces the `userdata` text, a NovaDeck disk produces the
  `/home` choice, and neither can produce the other.

`install/verify-install.sh` runs the **same check list** as `images/verify-card.sh`, against
real mounts — it has root and real block devices, so it needs no mtools. That shared list is
what binds the two, since `make-sdcard.sh` works unprivileged on image files at byte offsets
and genuinely cannot share code.

### Tests

`install/test-install.sh` — same sandbox doctrine as `images/test-post-install.sh`: execute the
real script with `sgdisk`/`mkfs.*`/`mount`/`rauc`/`nmcli` stubbed. Assert the **order** above;
assert it refuses without a completed confirm; assert it never issues a write against the boot
disk or against any `deny`-matched partition.

**Then hardware, over SSH from a dev card, before any UI exists.** Success criterion: the
device boots from internal with the SD removed, Android still boots, `novadeck-bootctl status`
reads sane, and one OTA installs into B and switches.

---

## Phase 5 — Gamepad GUI

### Display stack: gamescope + an SDL2 Wayland client

Two candidates. **Take gamescope.**

| | gamescope + SDL2 Wayland client | SDL2 on KMSDRM |
|---|---|---|
| Panel bring-up | The exact stack HW-validated on these panels | A cold, unvalidated display path |
| Portrait rotation | `--use-rotation-shader`, already the proven fix | Ours to solve in the client |
| Flips | `[[sm8650-gamescope-flip-blocker]]` already resolved | Re-litigate it |
| Input | gamescope + libinput, plus SDL_GameController | SDL's own evdev backend |
| Size | mesa + vulkan-freedreno + wayland + gamescope | mesa + libdrm (SDL2's KMSDRM needs GBM+EGL anyway) |

The size delta between them is small — SDL2's KMSDRM backend pulls GBM/EGL/mesa regardless,
so the saving is roughly gamescope and libwayland. The *risk* delta is large: the display has
historically been the hardest part of this port (blue panel with three distinct causes, DCS
ordering, the `cont_splash` carve-out, `efifb:off`), and every one of those fights was won
against the gamescope path. Spending ~200 MB to not re-fight them in an installer that runs
on a device with no serial console is the right trade. Record SDL2/KMSDRM in `TODO.md` as the
documented fallback if Phase 0 item 7 goes badly.

Consequences:
- **Phase 0 item 7 replaces the old `fbcon=rotate:` item** — gamescope owns rotation, so no
  `boot/boards.map` column and no kernel console rotation is needed at all.
- **No Plymouth in the installer.** `[[boot-splash-plymouth]]`: plymouthd starves gamescope's
  DRM master. The installer boots to a black panel for a few seconds instead.
- The installer squashfs gains mesa, vulkan-freedreno, wayland, gamescope, seatd, SDL2 — all
  already built by the overlay and pinned in `images/manifest.lock`, so no new package work.
  Mind `[[mesa-freedreno-depends-libdisplay-info]]`: runtime depends must match each `.so`'s
  `NEEDED`.
- **It also ships InputPlumber** (`packages/inputplumber/prebuilt.pin`, auto-discovered by
  `customize-base.sh`). ~10 MB installed — 9.2 MB binary, 532 KB share, 196 KB `libiio` — i.e.
  noise at this image size. The reason is not size: shipping it makes the installer's input path
  **identical to the HW-validated main-image path**, virtual Xbox device and all, instead of
  standing up a second raw-evdev stack in the one tool that must work when the device is broken.
  Four requirements come with it, all already available here but each able to fail silently:
  - `libiio` — declared `deps:` in the pin, pacman-resolves. No action.
  - A **system D-Bus** for `org.shadowblip.InputPlumber.conf`. §4a already starts
    `dbus-daemon --system --fork`; InputPlumber's policy must sit on *that* bus's config path and
    the unit must be ordered after it. `[[dbus-broker-policy-traps]]` applies — a `--` inside an
    XML comment voids the whole file.
  - **udev with a compiled hwdb.** It ships `59-inputplumber.hwdb` and
    `60-inputplumber-autostart.hwdb`, and hwdb files do nothing until `systemd-hwdb update` has
    run. This is the one that will no-op quietly: assert the hwdb binary exists in the squashfs
    at build time, the same way `kernel/build.sh` asserts CONFIG symbols.
  - Every board's InputPlumber config from `fs-overlay/usr/...`, since the installer is unified
    across boards exactly as the main image is.
  - Polkit files also ship (`.policy`, `.rules`); the installer runs as root, so confirm during
    Phase 0 whether polkit is needed at all here rather than dragging it in speculatively.

### The client

`install/ui` — Python + SDL2 (`python-pygame`), matching the repo's existing Python idiom
(`novadeck-update`, `novadeck-hotkeyd`). Started by `install/units/novadeck-installer-ui.service`
after `novadeck-installer-gamescope.service`, and it drives `install/novadeck-install` rather
than reimplementing it — the orchestrator stays the testable spine and the GUI is a view.

- **Input**: `SDL_GameController` for the pads; SDL keyboard events mean a USB keyboard works
  for free if one is attached. **No text entry anywhere** — §4b moved Wi-Fi credentials to a file
  on the ESP, so no on-screen keyboard is built. Every screen is navigable with dpad + buttons
  alone. If neither a controller nor a keyboard is present, §4d says stop.
- **Screens**: network status (diagnosis only — the §4b table, no picker) → pre-flight → confirm
  → progress → result. Strictly smaller than the earlier draft: dropping the SSID picker and the
  key grid removes the only two widgets that needed text input.
- **Pre-flight**: device name (from `fs-overlay/usr/lib/novadeck/devices/`), target disk model
  and size, the **full list of partitions about to be destroyed**, the new Android `userdata`
  size (adjusted with left/right, not typed), and the bundle version about to be fetched.
- **Confirm**: the §4d random button sequence — four face buttons shown in a per-run random
  order, echoed back on the pad; `B`-then-abort at any point, and a wrong press re-randomises
  and redraws. Nothing writes before it completes. Hold-to-confirm is the documented fallback if
  controller events prove unreliable.
- **Progress**: a bar per phase. The rootfs percentage comes from RAUC's D-Bus `Progress`
  `(isi)` property — `fs-overlay/usr/bin/novadeck-update` already subscribes to exactly that;
  reuse its subscription code rather than re-deriving it.
- **Result**: on success, "Remove the SD card, then press A to power off" — power-off rather
  than reboot until Phase 0 item 4 answers the ABL scan order. On failure, the error plus an
  accurate statement of which of two states we are in ("nothing was written, the device is
  unchanged" vs "the disk was modified; re-run, or restore the GPT from `<path>`").

### The fallback path, which is not optional

A GUI that fails to start on a device with no serial console is a black screen and nothing
else. So:

- `install/novadeck-install` is fully driveable **headless over SSH** (that is how Phase 4 is
  validated), and the installer image ships sshd with the medium's own key.
- If `novadeck-installer-ui.service` fails, a `OnFailure=` unit starts a plain getty on tty1
  with the log on screen.
- Every run writes `/run/novadeck/install.log` and copies it to the installer medium's **FAT
  ESP**, so a failure is diagnosable on a PC by pulling the card. That single decision is worth
  more than the rest of the UI.
- `novadeck.install.debug` on the cmdline skips the GUI entirely and drops to a shell.

### Tests

Units under `install/units/` covered by `images/test-units.sh` — systemd's parser only *logs*
unknown directives, cf. `[[systemd-execonfailure-is-not-a-directive]]`. A headless test drives
the UI state machine (no SDL window; the model is separable from the view) with synthetic
events and asserts the destructive step is unreachable without a completed 3-second hold.

Touch (ChipOne TDDI) is a follow-up; gamepad + USB keyboard for v1.

---

## Phase 6 — The image artifact and CI

New `install/` stage directory, peer of `boot/`/`images/`/`ota/`:

```
install/README.md        pkgs.list       mkroot.sh        mkimage.sh
        disk-rules.conf  select-target.sh carve.sh        novadeck-install
        rauc-session.sh  post-install-fresh.sh  verify-install.sh
        netcfg  ui  units/  test-*.sh
```

- `install/mkroot.sh` — pacstrap the installer package set into `work/installer-base`, then
  `mksquashfs -comp zstd`. Set = systemd + udev (device nodes, unit ordering, journald),
  bash/coreutils/util-linux, **gptfdisk + dosfstools** (not in the shipped image),
  e2fsprogs/btrfs-progs, rauc + glib + openssl, curl + ca-certificates, dbus,
  NetworkManager + wpa_supplicant, openssh, python, and the Phase-5 graphics stack
  (mesa, vulkan-freedreno, wayland, gamescope, seatd, sdl2, python-pygame). Reuses the
  existing overlay repo and `images/manifest.lock` pinning — no new package builds.
- `install/mkimage.sh` — the 2-partition GPT above; ESP populated with steamcl + GRUB (a
  dedicated `grub.cfg` variant that boots `root=PARTUUID=` of p2, `rootfstype=squashfs`,
  `fbcon=rotate:`), plus `Image`/`dtbs`. Same unprivileged mtools/`dd`-at-offset technique as
  `images/make-sdcard.sh`.
- `Makefile` — `installer:` target → `out/images/installer.img`; add to `make test`.
- `images/verify-card.sh` gains installer-shape assertions, or a sibling
  `install/verify-image.sh`.
- `.github/workflows/image.yml` — `artifact:` gains `installer`; publish to R2 under
  `installer/vX.Y.Z/`. New `release-installer.yml` on `installer/v*` tags, mirroring
  `release-sdcard.yml`.
- `steam-seed-<pin>.tar.zst` published alongside, from the existing `steam-seed/` stage.
- Docs: `docs/install-internal.md`, plus a Recovery section update in `docs/RUNBOOK.md`.

---

## Verification

**Offline, in `make test`:** `test-stage2-grub.sh` (PARTUUID + grubenv index block),
`test-initramfs-init.sh` (two-disk identical-label map), `test-post-install.sh` (unchanged
behaviour post-extraction), `test-select-target.sh` (≥60 cases on real captured GPTs),
`test-install.sh` (step order, confirm gate, never-writes-the-boot-disk), `test-units.sh`
(new units), byte-identity of the shipped `partition-table.txt`/`genpart.sh`, and the
`by-partlabel`/`by-label` grep assertion.

**Hardware, in order — each gates the next:**
1. Phase 1 alone: boot both slots from SD, run one OTA. Nothing else proceeds until green.
2. `install/probe-internal.sh` read-only on one SM8550 and one SM8650.
3. `novadeck-install` over SSH from a dev card, on a **sacrificial device**: Android still
   boots, NovaDeck boots from internal with the SD removed, `novadeck-bootctl status` sane,
   one OTA installs into B and switches.
4. Same, with an old NovaDeck card left inserted — the case Phase 1 exists for.
5. The standalone installer image end-to-end, including `wifi.conf` and the picker.

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ABL cannot reach Android once our ESP exists → dual boot impossible | **High** | Phase 0 item 5 is a go/no-go; if negative, re-open the Android decision before Phase 3 |
| Wrong-LUN write → EDL-only brick | Low / catastrophic | `disk-rules.conf` deny list evaluated independently of the allow list; side-effect-free selection with its own suite; GPT backups before any write |
| `userdata` deletion upsets ABL or modem | Medium | Phase 0 item 9, on a sacrificial device, before anything of ours is written |
| Squashfs installer root misses non-ELF runtime state | Low | pacman-resolved tree rather than a readelf walk; a first-boot smoke unit asserting TLS, NSS, dbus and nmcli all work |
| gamescope will not start without a logind session → black screen | Medium | Phase 0 item 7 proves it over `seatd`/`LIBSEAT_BACKEND=builtin` before Phase 5 starts; SSH + the ESP `install.log` + the tty1 `OnFailure=` getty mean a failed GUI is still diagnosable and the install still runnable |
| Wi-Fi picker unusable on a gamepad | Medium | `wifi.conf` on the ESP is a first-class path, not a fallback; USB keyboard works free |
| Interrupted install leaves an unbootable internal disk | Medium | Arm the bootconf **last**; re-run is idempotent; the medium is also the recovery medium |
| ~3.5 GB stream over Wi-Fi on battery | Medium | Honest progress from RAUC's `Progress` property; refuse below a battery threshold (Phase 0 item 8) |

---

## Explicitly out of scope

SD-card-as-game-library and the `holo-fstab-repair` port (`TODO.md:246` sub-item) — they
follow the internal install, and the TODO is explicit that the fstab-repair unit must not ship
before the format helper that creates the bad entries.

**Writing `devinfo` to set ABL's default boot target.** The obvious convenience — "installed to
internal, so make internal the default" — is refused on purpose. The format is ABL-private, ABL
ships as a signed per-device ELF with no published source, and on Qualcomm parts `devinfo`
also carries unlock/verity state; a blind write risks the one component we can neither rebuild
nor recover. The installer's closing screen tells the user to hold Volume Up and set it in
ABL's own menu. This is recorded here because it is exactly the kind of nicety a later change
adds without knowing why it was left out.

**Rescuing Android's `userdata`.** Not a scope cut but a stated impossibility: `super` cannot
shrink and f2fs `userdata` cannot shrink in place, so there is no carve that preserves it. The
plan's answer is informed consent (§4d), not backup, migration, or partial preservation. Do not
reopen this as an optimisation.
