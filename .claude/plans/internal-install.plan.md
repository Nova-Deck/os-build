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
Phase 5). It carries no bundle and needs no reflash per release; the release card is ~5 GiB
compressed by comparison.

---

## Phase 0 — Hardware reconnaissance (BLOCKING, no code ships)

Nothing below can be committed to without these answers. **The dual-boot go/no-go that used
to head this list is closed** — the ROCKNIX ABL is a chooser, not a fixed branch (below).

A read-only `install/probe-internal.sh`, run from a dev card over SSH, dumping to
`docs/internal-storage.md`:

1. **LUN topology** — `lsblk`, and for every internal disk `sfdisk --dump`,
   `/sys/block/*/{removable,ro,size}`, the UFS `WWN` and LUN number (read off `lsblk`'s `HCTL`
   column, i.e. `Host:Channel:Target:Lun`, rather than guessed from the `sdX` letter). Which LUN
   carries `super`/`userdata`/`metadata`, and whether it is exclusively Android data.

   > **Not `sgdisk`.** An earlier draft of this item specified `sgdisk -p`; gptfdisk is absent
   > from the novadeck rootfs (it is one of the three packages the *installer* image must add), so
   > a probe built on it would fail on the very device it inspects — the `cmp`-in-`post-install.sh`
   > class of bug. `install/probe-internal.sh` therefore runs on an existing dev card with no
   > rebuild, using `sfdisk`/`lsblk`/`findmnt` only, and picks `sgdisk` up opportunistically if it
   > is ever present.
2. **The exact OEM partition name set** per SoC, so `install/disk-rules.conf` is written
   against reality and not against recalled AOSP naming. At least one SM8550 and one
   SM8650 device.
3. **Whether Linux sees internal storage at all.** `docs/bringup.md:9` still says "UFS
   itself unverified". `CONFIG_SCSI_UFSHCD` is in the config; that is not the same thing.
4. ~~**ABL fallback when the stored default names a medium that is absent.**~~ **ANSWERED
   2026-08-05 — and the question was posed backwards.** See "The ABL contract" below: the
   fallback runs internal→external, not the reverse, so with no card inserted ABL boots our
   internal install. **The post-install flow is "remove the card and reboot, done"** — no
   Volume-Up step, and no reason to prefer power-off over reboot.
5. **Where in `devinfo` the boot choice lives, and its size** — capture the partition raw,
   *for backup only*. The choice is persisted in `devinfo` (user-confirmed 2026-08-05).
   `devinfo` is already in the `deny` list at §3, and **the installer must never write it**
   (see "Explicitly out of scope"). This item is a capture, not a risk.

   > **Closed, was the dual-boot go/no-go.** An ESP on internal cannot strand Android. Two
   > further facts from upstream's `update.sh`: ABL is a **signed, per-device ELF**
   > (`abl_signed-<HW_DEVICE>.elf` flashed to `abl_a`/`abl_b`), so we consume it and cannot
   > rebuild it; and it is addressed via `/dev/disk/by-partlabel/`, so internal storage
   > enumerates with partlabels from Linux under ROCKNIX's kernel — evidence for (3).

### The ABL contract — corrected 2026-08-05, and it moves two design points

Stated by the user, who worked on the ROCKNIX ABL. An earlier draft of this plan described a
four-target chooser (Linux internal / SD / USB, or Android) with a Volume-Up override that
switched medium. **That model was wrong.** It is:

- **Two modes: Android, or Linux.** Android mode boots Android on internal, full stop.
- **Linux mode tries INTERNAL FIRST, then falls back to external.** "Internal" means an internal
  ESP carrying either `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. The test is on **content**, not on
  the partition existing.
- **A "force external" option** overrides that and always takes the external medium.
- **Volume Up is a ONE-TIME override to Android**, offered when Linux mode is selected. It does
  not choose a medium. (§4d's consent text happens to state this correctly already.)
- **The ESP is found by partition TYPE at any index** — ROCKNIX's own internal install on the
  Pocket FIT puts its ESP (`C12A7328-…`) at **p12** and boots. Appending our partitions to an
  existing OEM GPT is therefore safe, which Phase 2's `genpart.sh --append` depends on.

**Both arms were observed on hardware the same day, not merely described.** S2, ACE and Odin 2
have no internal ESP and fell through to the SD card unaided; the FIT has one at p12 and needed
force-external to reach the card at all.

**Consequence 1 — the recovery story in §3 is wrong as written.** It claims an internal install
"stays recoverable by booting the installer medium on demand". With internal-first that is false:
once our internal ESP exists, inserting the installer card boots *internal*. **Recovery requires
the force-external option**, and it must be named in `docs/install-internal.md` and
`docs/RUNBOOK.md` in the user's terms. The difference between naming it and not is the difference
between a recoverable device and one the user believes we bricked.

**Consequence 2 — "arm the bootconf last" now has a precise definition.** ABL's test is content-
based, so the last byte the installer writes is **`/EFI/BOOT/bootaa64.efi` on the internal ESP**.
Before it, an interrupted install still boots the card and re-running works; after it, internal
wins. The ESP partition itself, its `grubenv`, the partsets and `A.conf` can all be written
earlier — it is that one file that flips the device over.
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

   > **ANSWERED 2026-08-10 — ABL does not look at `userdata` at all.** The generic-vendor-ABL
   > worry does not apply to these boards: the chooser's inputs are the ones already documented
   > under "The ABL contract", and `userdata` is not among them. Nothing gates on it, so deleting
   > and recreating it smaller has no effect on the boot path.
   >
   > The modem half of the item falls with it. It was only ever a concern *via* ABL — `modemst*`,
   > `fsg`, `fsc` and `persist` are on the `deny` list and sit outside the carve span, so the
   > modem's own state is untouched by construction.
   >
   > **This was the item with teeth, and it is the last thing that blocked Phase 3.**

**Deliverable:** `docs/internal-storage.md` with captured GPTs, plus the real `userdata` sizes
per device — §4d's consent screen quotes them, so they are a product input, not just recon.

### CAPTURED 2026-08-05 — all four boards. What the recon actually returned

`docs/internal-storage.md` holds S2, ACE, Odin 2 and Pocket FIT. Items 1, 2, 3, 5 and 6-by-HCTL
above are answered by the probe; items 7 (gamescope without logind) and 8 (throughput/battery) are
**not** — neither is answerable read-only from one boot, and the probe says so in its own closing
section. Item 9 (`userdata` removal side effects) was closed separately on 2026-08-10, see above.

**Item 4 (ABL fallback) is answered, but not by the probe** — by the user's statement of the ABL
contract plus both arms being observed on hardware the same day (see "The ABL contract"). Read the
list above as *what the probe returned*, not as the state of Phase 0: the two are not the same set.

**Item 6 is answered only in the form the design needs.** HCTL and `wwid` were captured on all four
boards, which is what target selection keys on; `/dev/sdX` stability across *reboots* was never
tested, because one read-only boot cannot test it. That is fine and stays fine — the design does not
depend on it. Do not reopen this as a gap; reopen it only if something starts keying on `sdX`.

- **Linux sees internal storage.** 6–8 UFS LUNs per board. This closed `docs/bringup.md`'s step-2
  "UFS itself unverified", which has since been corrected to say so (2026-08-07).
- **Constant across all four:** data LUN is 0; `xbl` on LUN 1; `abl` + `devinfo` on LUN 4; zero
  unpartitioned space, so the carve must come out of `userdata`; and `userdata` carries that
  literal name and is the largest partition by a wide margin. **`require userdata` therefore
  survives as a constant** — the naming risk flagged below did not materialise — and rule 6's
  label/size cross-check and the dominance fallback agree on every board.
- **Sector size is 4096 on all four**, across two UFS vendors and two SoCs. The span arithmetic
  must READ the logical sector size, never assume 512: an 8× error puts writes outside the span,
  which is precisely what containment exists to catch. `test-select-target.sh` needs a 512-byte
  fixture anyway, since no real board will exercise that arm.
- **`zram0` enumerates as an install candidate** on every board — `removable=0`, `ro=0`, so rule 2
  does not exclude it. Harmless today (no GPT, so `require userdata` refuses it), but
  `select-target.sh` should exclude zram explicitly rather than rely on that.

### Layout variation is the normal case, not the exception

Four devices are available to capture — KONKR Pocket FIT and AYANEO Pocket S2 (SM8650), AYANEO
Pocket ACE and AYN Odin 2 (SM8550) — and their internal layouts are expected to differ. Two
consequences, both of which shape Phase 3 rather than Phase 0:

> **Confirmed by the captures, with the axis identified: layout tracks the VENDOR, not the SoC.**
> S2 vs ACE is a different SoC generation with the same table; ACE vs Odin 2 is the same SoC with
> different tables. Those two pairs cross-cut, which is what isolates the variable. `userdata` is
> `/dev/sda11` on the AYANEO-family boards (KONKR is an AYANEO sub-brand) and **`/dev/sda17`** on
> the Odin 2, which carries six names no AYANEO board has: `nvdata1/2`, `qpdata1/2`,
> `reserve1/2`. So **any rule keyed on partition index is already broken** — identification by
> label is not merely preferable, it is required. `reserve1`/`reserve2` are also exactly the kind
> of generic OEM name a deny list cannot anticipate on an uncaptured board, which is concrete
> support for span containment being the primary defence rather than the name list.

- **`docs/internal-storage.md` is a set of per-board sections, never one canonical table.**
  `probe-internal.sh` puts the board in its H1 so captures concatenate. `disk-rules.conf` is
  authored from the **union** of all captures, and `test-select-target.sh` must stay green against
  **every** captured GPT — a rule tightened for one board and silently breaking another is the
  failure this guards.
- **`fs-overlay/usr/lib/novadeck/devices/` already carries 14 boards.** Ten of them will have no
  capture, and the capture set will always be incomplete. This is why identification plus **span
  containment** replaced the name list as the primary defence (see Phase 3): an uncaptured board
  installs *correctly by construction* rather than being refused for lack of a fixture, because
  everything outside the identified `userdata` extent is protected geometrically regardless of what
  it is called. Captures still matter — they author the `deny` net, settle per-board naming, and
  serve as test fixtures — but the design no longer depends on having one per board. Since the
  probe is read-only, it is safe to hand to an owner of any uncaptured board.

**One naming risk to check across the four captures:** rule 6's `require userdata` assumes that
literal name. If any board calls its data partition something else, the rule refuses a device we
actually support — which is safe but wrong. If the captures disagree, `require` becomes a
per-board name rather than a constant, resolved from `devices/*.conf`.

> **Checked, 2026-08-05: it holds on all four.** `require` stays a constant. Re-open only if a
> fifth board disagrees.

### A disk already carrying a THIRD-PARTY install — an open Phase 3 decision

Found on the Pocket FIT, which has an internal ROCKNIX installation: `userdata` shrunk to 64 GiB
with `ROCKNIX` (2 GiB vfat) and `STORAGE` (380 GiB ext4) appended after it. The three sum to the
S2's stock `userdata` exactly, so that distribution performs the same carve this plan describes —
useful evidence that the mechanism is sound in the field, on this hardware.

**Policy, decided 2026-08-05: REFUSE, and the user removes the other distribution first.** Taking
over `STORAGE` was rejected — it would mean deleting a partition we did not create, which breaks
the "exactly one pre-existing partition is modified" invariant the whole safety model rests on.

**The mechanism does not yet implement that policy, and this is the part to build.** Today the FIT
is refused only by accident of proportions: rule 6 fires because `STORAGE` (380 GiB) is larger than
`userdata` (64 GiB), so label and size disagree. Reverse the proportions — an install that left
`userdata` at 300 GiB and took 100 — and `userdata` is still the largest, rule 6 passes, and we
**succeed**: `ROCKNIX`/`STORAGE` sit outside `[userdata_start, userdata_end]`, so span containment
protects them by construction and our eight partitions lay down inside the shrunken `userdata`
quite happily. The result is one disk carrying Android, another distro and NovaDeck, three of them
believing they own the boot chain, with no rule having objected.

### RESOLVED 2026-08-07 — refuse on a FOREIGN BOOTABLE ESP, and nothing wider

**If the target disk carries an ESP (type `C12A7328-…`) that is not ours and that holds either
`/EFI/BOOT/bootaa64.efi` or `/KERNEL` → refuse, and tell the user to remove the other OS first.**

The rule is worth stating in terms of *why it is the right one*: it is the exact test ABL performs.
Per "The ABL contract", Linux mode boots the internal ESP carrying either of those two files, and the
test is on **content**, not on the partition existing. So two such ESPs on one disk is not a
tidiness problem we are refusing on principle — **ABL has no way to choose between them**, and
whichever it picks, one of the two installations is unreachable. Refusing is the only honest answer,
and "remove the other distribution first" is the only instruction that fixes it.

That makes it strictly better than the earlier sketch ("any partition neither OEM-recognised nor
ours"), which needed a judgement call about what counts as a foreign rootfs, and better than the
accident of proportions the Pocket FIT is refused by today, which reverses the moment `userdata`
stays larger than the other distro's partitions.

It also **resolves the rule-4 tension rather than reconciling it**. There is no longer a spectrum
between "an unknown OEM partition" and "a foreign rootfs/boot pair": an unrecognised name outside
the span is still merely *reported*, so uncaptured boards install, and the only refusal is a second
bootable ESP. A foreign distro with no ESP of its own cannot be booted by ABL either, so it is not a
competing boot chain and is not our business.

**Two qualifiers.**

- **Ours is exempt** — on a reinstall our own ESP carries `/EFI/BOOT/bootaa64.efi` by construction.
  This falls out of rule 8's ordering, which already runs the already-NovaDeck identity check before
  anything else, but the exemption must be explicit rather than implied by order alone: identify our
  ESP by the `NOVADECK-ESP` GPT name plus its `SteamOS/conf` content, and skip it.
- **An empty ESP is not a refusal** — an OEM ESP carrying neither file is invisible to ABL, so
  appending ours beside it is safe. This is the same content-not-existence test, applied
  consistently, and it is what keeps `genpart.sh --append` viable on a board that ships an unused
  ESP.

The refusal message must say what is true — "this disk already carries another Linux installation
(partition N, `<label>`); remove it and retry" — never rule 6's "contradiction about a device we do
not understand".

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

### 1a. Boot-time PARTUUID derivation in stage 2 — LANDED + HW-VALIDATED (2026-08-05)

`probe` is in `MODULES`, the config derives all three PARTUUIDs with a `"none"`-aware guard and an
announced PARTLABEL fallback, `novadeck.slot=` is on the cmdline, and the initramfs reads it.
`test-stage2-grub.sh` covers it (167 assertions, incl. the module list).

**Validated on four boards** — Pocket S2, Pocket ACE, Odin 2, Pocket FIT — each booting
`root=PARTUUID=` / `novadeck.var=` / `novadeck.efi=` with `novadeck.slot=A`, `/run/novadeck/boot`
reporting `slot=A` with all three devices resolved, and **no fallback message on any of them**
(user-confirmed on-screen, corroborated by `/proc/cmdline`).

**THE PHASE 1 GATE BELOW IS MET — both slots plus one OTA, 2026-08-05.**

- **Slot B** booted on a Pocket S2 via `set-primary B`: `slot=B`, root/var/efi all on B's
  partitions, three PARTUUIDs distinct from A's, and `/var/lib/novadeck/slot` agreeing. It also
  auto-booted the saved board entry, so the shared-ESP grubenv survives a slot switch.
- **One OTA**, a dev bundle built from this tree, installed from B into A in 4m33s (full
  `raw_copy` — no adaptive reuse on this path, so the 61× figure is a WIRE saving against a
  served delta, not a local write saving). Post-install wrote `efi-A` a config with all three
  `probe --part-uuid` lines and `novadeck.slot=A`, and the rebooted slot came up on
  `root=PARTUUID=` — **which is the part a fresh-card boot cannot prove**, since it is
  `post-install.sh` rather than `make-sdcard.sh` that writes the config an updated slot boots.
- The `/var` copy carried the machine-id across, `mac-wifi` was correctly deleted so the MAC
  re-derived to the same value, and the device returned on the **same IP**.

**The PARTLABEL fallback arm has now FIRED on hardware — 2026-08-06, Pocket S2.** It was
offline-asserted only until then, and its whole job is to run when something has already gone wrong,
which is the worst time to discover it is broken. Forcing it turned out not to need the planned
`grubaa64.efi` built without `probe`: with 1b landed, setting `nd_var_a` in `parts.env` to a
nonexistent partition index makes `probe --part-uuid` return the literal `none`, the three-way guard
rejects it, and all three specs drop to PARTLABEL. The device booted, printed the two-line message,
and came up with `root=PARTLABEL=novadeck-root-A` on `/proc/cmdline` — no black screen.

1b has since landed and been HW-validated, and 1c is dropped by scope decision — see both below.
Phase 1 is closed.

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

### 1b. Variable partition indices, for dual boot — LANDED (2026-08-06), HW-VALIDATED (2026-08-07)

Our 8 partitions will not be at indices 1..8 on a disk that keeps Android. GRUB has no
arithmetic and `probe` has **no `--part-label`** (verified: only `driver/partmap/fs/fs-uuid/label/part-uuid`),
so indices cannot be discovered in stage 2.

Mechanism: whoever creates the partitions writes the eight indices into a GRUB env block, and
stage 2 reads them back before it addresses anything.

**Correction to this section's original sketch, and the reason it matters.** The map was to live in
the ESP's existing grubenv. **It cannot: stage 2 must locate the ESP before it can read that file,
and the ESP's index is one of the eight numbers in it.** The map therefore lives in its own block on
**the slot's own efi partition** — `($root)/EFI/steamos/parts.env`. `$root` is the partition steamcl
chainloaded stage 2 from, so it is the one place reachable with no index at all. Do not move this
back to the ESP.

Durability was checked rather than assumed: the efi partitions are **not RAUC slots** (`system.conf`
declares only `rootfs.0`/`rootfs.1`; `manifest.raucm.in` carries only `rootfs.img`), and
`post-install.sh` mounts the target efi partition and `cp`s named paths onto it — no `mkfs`, no
delete. `/var`, by contrast, is reformatted on every update, so nothing of ours could ever live
there. A comment at that site now records the constraint.

```
set esp_idx=1                    # defaults from partition-table.txt, per slot
set root_idx=4
set var_idx=6
if [ -f ($root)/EFI/steamos/parts.env ]; then
  load_env -f ($root)/EFI/steamos/parts.env nd_esp nd_efi_a … nd_home
  if [ -n "$nd_esp" -a -n "$nd_root_a" -a -n "$nd_var_a" ]; then   # ALL-OR-NOTHING
    set esp_idx="$nd_esp"; set root_idx="$nd_root_a"; set var_idx="$nd_var_a"
  else echo "…incomplete…"; sleep 3; fi
fi
set esp="$bootdisk,gpt$esp_idx"
```

Three properties worth keeping: the `[ -f ]` guard makes a medium without the file *silent* (that is
every card built before this landed); the upgrade is all-or-nothing, so a partial file can never mix
a root from one layout with a `/var` from another; and the loaded key names differ from the consumed
`*_idx` names because `load_env` cannot rename — loading straight into `esp_idx` would destroy the
default before it could be judged.

**`images/make-sdcard.sh` seeds it on both efi partitions with the card's real indices.** On a card
those equal the defaults, so it changes no behaviour — the point is that the card then exercises the
same lookup the internal install depends on, on every boot, rather than shipping that path untested
until the installer exists. `images/verify-card.sh` asserts the seeded values against
`partition-table.txt`, since a wrong value would otherwise be invisible at boot.

Offline coverage in `images/test-stage2-grub.sh` (195 assertions, was 167): the index variables in
the device specs, the defaults matching the table, the `[ -f ]`-guarded load from `($root)`, per-slot
key selection with the other slot's keys never consulted, the single all-or-nothing condition, and
both orderings (defaults before the load, load before the first use). Both a baked-index regression
and a wrong-slot-key regression were confirmed to fail the suite.

**HW-VALIDATED 2026-08-06 on a Pocket S2 — all four arms, from one card, no reflash.** `/efi` is
mounted `rw`, so `parts.env` is editable in place over SSH; the image ships no `grub-editenv`, so the
block was rewritten by hand, which road-tested the Phase 2 `write_parts_env` format on real hardware
through GRUB itself.

| arm | edit | result |
|---|---|---|
| normal | none | no message; `root=PARTUUID=5df235fc-…`, all three devices resolved, `novadeck.efi=` matching the build log's efi-A uuid |
| **file is authoritative** | `nd_var_a=9` (nonexistent) | `probe` → `none`, guard rejects, **all three specs drop to PARTLABEL** — a card whose map equals its defaults can only produce that by having READ the file |
| incomplete | `--unset nd_var_a` | the "incomplete" message, then **PARTUUID with the identical three uuids** — the all-or-nothing guard rejected the whole map rather than mixing a filed `nd_root_a` with a defaulted `var` |
| absent | `rm parts.env` | completely silent, PARTUUID — the `[ -f ]` guard, i.e. every card built before this change |

The poisoned-value arm is the one that carries the proof, and it doubles as the PARTLABEL fallback's
first hardware firing (§1a). The incomplete arm is the one that would have caught a partial map: a
leaked `nd_root_a` with a defaulted `var` would have shown a different `novadeck.var=` uuid, and it
showed the same one index 6 gives.

**One product finding, fixed the same day:** 3s is too short to read a message in the boot font on a
Pocket S2 panel. All four diagnostic arms now `sleep 10`, asserted by two new cases. Waiting for a
keypress instead was rejected — `sleep --interruptible` is ESC-only, the power button never reaches
GRUB's EFI console input, and these arms fire on users' devices, where blocking on input with no
keyboard makes a bootable device look bricked.

### 1c. A disk-scoped device map in the initramfs — DROPPED 2026-08-07, and here is why

The OS-side sites keep resolving by name: `assemble-rootfs.sh`'s two fstab lines
(`PARTLABEL=NOVADECK-ESP`, `LABEL=novadeck-home`), `grow-home.sh`'s `HOME_DEV`, and
`fs-overlay/etc/rauc/system.conf`'s `by-partlabel/novadeck-root-{A,B}`. **This is a decision, not an
omission.** A future reader will ask why the bootloader was moved to PARTUUID while the OS was not,
and without the answer recorded the natural move is to reinstate this section.

**No supported state puts two `novadeck-*` named disks in front of a running system.** Scoped by the
product owner 2026-08-07:

| medium | GPT names | collides? |
|---|---|---|
| installer / recovery card | `esp`, `root` (2-partition image) | no |
| SD game library card | freshly formatted by Steam's helper, ext4 | no |
| internal install | the `novadeck-*` eight | the only one |

The two arguments that seemed to require 1c are both out of scope. **Reusing the current novadeck
card as the library card is not a goal** — Steam games are re-downloadable and saves are cloud-synced,
so the library card is a fresh card the user inserts long after boot, not their old install medium.
And **recovery reuses the INSTALLER card**, not a novadeck card, so the recovery boot presents
`esp`/`root` and cannot collide either. A user who deliberately inserts an old novadeck card into an
internally-installed device is accepted as unsupported.

**What would reopen this,** and the reason the reasoning is preserved rather than deleted: any flow
that puts a second `novadeck-*` disk in front of a *running* system. The sharp edge is
`grow-home.sh` — it runs on **every boot** by design ("safe to run every boot"), resolves
`/dev/disk/by-label/novadeck-home`, takes the parent disk from `lsblk -no pkname`, and runs
`systemd-repart --dry-run=no` on it. With two candidates the symlink is an async udev coin flip and
the loser gets repartitioned. `system.conf` is the other: an OTA would write ~3.5 GB to whichever
disk udev picked, then mark the boot state updated.

The mechanism, if it is ever needed: walk the boot disk's own partitions in sysfs after `ROOTDEV`
resolves and publish `/run/novadeck/dev/<gpt-name> -> /dev/<part>` — ~15 lines, no udev,
index-agnostic, disk-scoped by construction, needing `blkid` in `images/mkinitramfs.sh`'s `BINS`.
It is also *more* deterministic than `by-label`, so it would let `grow-home.sh` drop its
settle-and-poll block.

### Tests

- `images/test-stage2-grub.sh` — assert `insmod probe`, the three `probe --part-uuid --set=`
  lines, `root=PARTUUID=$rootuuid`, `novadeck.slot=<S>`, the grubenv default block, and that
  the fallback arm still emits the PARTLABEL form. Follow the existing precedent of
  *executing* the emitted regexp rather than grepping for it.
- ~~New `images/test-initramfs-init.sh`~~ and ~~the `by-partlabel`/`by-label` grep assertion~~ —
  both belonged to 1c and are dropped with it.
- `images/test-post-install.sh` — unchanged, stays green.

**GATE MET — 2026-08-07. Phase 3 may proceed.**

- **1a** — PARTUUID on the cmdline: HW-validated on four boards, both slots, one OTA (see above).
- **1b** — `parts.env`: HW-validated on a Pocket S2, all four arms, and it fired the PARTLABEL
  fallback on hardware for the first time.
- **1c** — dropped by scope decision, with the reasoning and the reopen condition recorded above.

Nothing in Phase 1 is outstanding. The original gate was "HW boot on both slots + one successful OTA
before Phase 3 lands"; both were met 2026-08-05 and 1b has been validated since.

---

## Phase 2 — Extract the reusable install primitives — LANDED 2026-08-07

All six items are done and `make test` is green (`install/test-install.sh` 98 cases,
`images/test-post-install.sh` 127 — the same count as before the extraction, which is what proves it
was behaviour-preserving). **None of it has run on hardware**, and most of it cannot: the offline
suites drive plain directories, so what they establish is that the primitives ask for the right
things, not that a disk laid out this way boots. Phase 4 is where that gets answered.

Three things landed differently from the sketch below, each for a reason worth keeping:

- **`seed_var` takes `<dev> <slot> <mnt> <source>`**, not `<dev> <slot> <seedtar>`. The mountpoint is
  an argument because this file's own rule is that a primitive reaching for a global is right for
  exactly one of its two callers. `<source>` is a directory (OTA: the running `/var`) or a tarball
  (install: `var-seed.tar.zst`), because on a fresh disk the running system is the *installer*, whose
  `/var` describes the wrong device.
- **The /var finalization moved above the guard** in `images/assemble-rootfs.sh` (now section 4zy).
  `var-seed.tar.zst` goes inside the root, and `guard-rootfs.sh`'s contract is that the tree it
  inspects is the tree `mkfs.btrfs` bakes. Nothing may be added to `$stage` below the guard call.
- **`tar -p` on the extract is load-bearing.** Measured, not assumed: without it `/var/tmp` comes back
  0777 instead of 1777. `rsync -a` has no such mode, so the two paths would have agreed only by
  accident of who ran them.



The installer must write everything a RAUC bundle does not carry. Almost all of that logic
exists twice-over already; the goal is one copy.

New `fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh`, sourced by
`fs-overlay/usr/lib/rauc/post-install.sh` so the OTA path and the install path cannot drift:
`mint_partsets`, `write_efi_partition <mnt> <slot> <bootdir>`, `write_parts_env <mnt>`, `refresh_esp_stage1`,
`seed_var <dev> <slot> <seedtar>`, `mkfs_esp`.

| artifact | source of truth |
|---|---|
| GPT | `images/partition-table.txt` + `images/genpart.sh`, both **shipped verbatim** into `/usr/lib/novadeck/install/` |
| ESP stage 1 (`bootaa64.efi`, `steamcl-version`, `steamcl-restricted`, `fonts/`) | `/usr/lib/novadeck/boot/` of the **freshly written internal root** — `post-install.sh`'s `refresh_if_diff` block, factored out |
| ESP `grubenv` | **new**: `boot/grub.sh` emits a pristine `grub-editenv`-created grubenv into `out/boot/`; the device just `cp`s it (removes a `grub-editenv` dependency from the device) |
| ESP `SteamOS/conf/A.conf` | `steamos-bootconf` (`bc create --image A` + `set-mode reboot`) — reuse, don't re-emit `make-sdcard.sh`'s heredoc |
| efi-a/efi-b stage 2 | `/usr/lib/novadeck/boot/` of the installed root — `post-install.sh` step 3, factored out |
| efi-a/efi-b `parts.env` | **new**: written by hand as a raw env block from the indices `genpart.sh --append` just laid down — see below |
| efi partsets | **minted from the NEW partition UUIDs** — `post-install.sh` copies them from the *running* `/efi`, which is a different disk here. `make-sdcard.sh`'s `mkpartset`/`mkefi` is the logic; extract it |
| var-a / var-b | **new**: `assemble-rootfs.sh` also writes its `$varstage` to `/usr/lib/novadeck/var-seed.tar.zst` inside the root (`work/base/var` is ~13 MB, negligible in a 7 G slot) |
| rootfs-a | the signed RAUC bundle (Phase 4) |
| rootfs-b | nothing — left empty and **no `B.conf`**, matching the release-card shape so steamcl sees one image and retries A rather than switching (`make-sdcard.sh`'s `mkconf` site explains why). First OTA fills B |
| `/home` Steam seed (~1 GB) | **new published artifact** `steam-seed-<pin>.tar.zst`, sha256 verified against the pin **baked into the installer image**, not against `latest.json` (explicitly not a trust boundary). Folding it into the bundle instead does not fit: rootfs-a is 7 G with ~0.9 G margin |

### `write_parts_env` — emit the env block directly, do not reach for `grub-editenv`

`parts.env` (phase 1b) is the map stage 2 reads before it can address anything, and unlike every
other artifact here its contents are **per-disk**: the indices come from what `genpart.sh --append`
just laid down on this specific device. So the trick used for the ESP grubenv — build a pristine
block at image-build time and have the device `cp` it — does not transfer. It has to be generated
on the device, at install time.

**`grub-editenv` is not on the shipped image** (confirmed 2026-08-06: no `grub` in
`customize-base.sh`'s `PKGS`, no `/usr/bin/grub-editenv` in the built base). Adding it to the
*installer* package list would be free — that is a separate root — but it is not worth the
dependency, because the format is trivial and fixed:

```
# GRUB Environment Block\n     the signature — 24 chars + \n, byte-exact (envblk.c memcmp's it)
# WARNING: Do not edit …\n     what grub-editenv writes; a comment, so optional
nd_esp=12\n                    one key=value line each
…
####…                          '#' padding out to exactly 1024 bytes
```

`grub_envblk_iterate` starts immediately after the signature and skips any line beginning with `#`,
which is why both the warning line and the tail padding are inert. Only the signature is load-bearing
and it has to match byte for byte.

So `write_parts_env` is a `printf` plus a pad, with one assertion that the result is exactly 1024
bytes — anything else is silently unreadable to `load_env`. Writing it by hand also keeps the
installer's dependency list honest: it already needs `gptfdisk` and `dosfstools` that the shipped
image lacks, and this is one fewer.

`install/test-install.sh` gets a case: generate a block from a captured GPT's indices, and assert
the real `grub-editenv list` reads back every key — that is the check that the hand-rolled format
matches what GRUB actually parses, and it runs on the host where `grub-editenv` exists. Assert the
1024-byte length too: `grub_envblk_open` only requires the signature to fit, so a truncated block
still reads back fine here and would differ from what `make-sdcard.sh` writes on a card. Matching
the card's shape byte for byte is what keeps one reader honest about two writers.

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

### Carried in from the Phase 2 review — decide before wiring a real target

**`NOVADECK_APPEND_FLOOR` must become mandatory for `genpart.sh --append <target>`.** Today it is
opt-in (`images/genpart.sh:106` refuses only when a floor was supplied), which was correct while
every caller was a test invoking `--append` with no target. It stops being correct the moment a real
device is passed.

Unset, sgdisk places our eight in whatever the LARGEST FREE BLOCK is. The rule below — every sector
written lies inside `[userdata_start, userdata_end]` — then holds only because the carve happens to
have made the freed tail the largest free block, which `genpart.sh` cannot see and therefore cannot
verify. That makes the containment argument true by luck rather than by construction, and luck is
not what the geometric bound is for.

The asymmetry decides it: over-requiring the floor costs one relaxed line; forgetting it costs a
brick with EDL as the only recovery. So the safe path should be the default, and `--append` with a
device argument should refuse without a floor rather than accept one. Left unchanged in Phase 2
deliberately — it is a contract decision that belongs with the caller Phase 3 writes.

> **DONE 2026-08-10 (`3222b19`, `4669cfd`), and it needed more than the floor.** Running `--append`
> to completion for the first time showed `sgdisk -n 0:0:+size` re-resolving the largest free block
> on *every* call: the ESP and both roots landed in the freed tail, then var-A/var-B/home jumped
> past an OEM partition into a bigger hole, and the run reported success. A floor cannot see that —
> it only ever validates the first call.
>
> **The caller now passes both edges**, and `select-target.sh` owes both:
> - `NOVADECK_APPEND_FLOOR` — last sector of the shrunk `userdata`, plus one.
> - `NOVADECK_APPEND_CEIL` — last sector of the contiguous free run starting at the floor: the
>   sector before whatever follows the carve, or the end of the disk when `userdata` was last. That
>   second case is what keeps `home` absorbing trailing free space.
>
> genpart places every row at an explicit start chained from the floor, ends `home` at the ceiling,
> and refuses before the first `sgdisk -n` if the window is too small for the layout or if any
> existing partition overlaps it. That overlap test is the containment rule asserted directly
> against the GPT rather than inferred from arithmetic, so `select-target.sh` getting the window
> wrong cannot put us on top of a partition. It also removes a failure mode Phase 2 had: a short
> window used to create three partitions and refuse the fourth, leaving a half-appended GPT.

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

1. **Span containment** — every sector written lies inside the identified `userdata` extent, so
   everything else on the disk is protected geometrically rather than by being named. Independently
   corroborated by the `deny` list (§ `select-target.sh` items 4 and 5), so a typo widening one
   rule still cannot open a write path.
2. A **big, unmissable consent screen** (§4d) naming the one partition and its real size.

There are no backups, no restore path, and no undo — see rule 10 for why each was rejected
rather than merely skipped. A blast radius this narrow is worth more than a backup of it.

The new `userdata` size is a user choice on the confirm screen. **Revised 2026-08-10:** Android's
floor is **1 GiB** and NovaDeck's share must be **at least 32 GiB**, so the partition is eligible
at **33 GiB** and the user's choice is bounded by whatever is left above 32 for us. The earlier
"default 16 GiB, floor 8 GiB, plus `HOME_FLOOR`" is replaced by that pair of numbers.

> **Recreate `userdata` with its ORIGINAL type GUID.** Found 2026-08-05 in the captures: stock
> `userdata` is type `1B81E7E6-F50D-419B-A739-2AEEF8DA3335`, but on the Pocket FIT — where
> ROCKNIX performed this same carve — it came back as `0FC63DAF-…` (Linux filesystem data).
> Recreating it under a Linux type risks Android not recognising its own data partition, and
> "Android survives, factory-reset but working" is the *entire* justification for destroying it.
> So `select-target.sh` must capture the type GUID along with the extent, and the carve must
> restore it. `test-select-target.sh` gets a case: recreate from a captured GPT, assert the type
> GUID is byte-identical to the original.

### Identification, then geometry — the primary mechanism

Revised 2026-08-05. **Only one partition matters: `userdata`.** Everything else on the disk is
something we never touch, so the design identifies that one partition and then constrains
ourselves to its extent — rather than enumerating everything dangerous and allowing the rest.

**The paramount assertion is geometric, not nominal:**

> **Every sector written falls inside `[userdata_start, userdata_end]` of the partition we
> identified, or in space that was already unallocated.** The shrunk `userdata` and all 8 of our
> partitions are laid inside that span.

> **Measured 2026-08-10, and it is why `--append` needs no ceiling to match its floor.** `sgdisk
> -n 0:0:0` ends at the end of the *free block*, not the end of the disk: with any partition after
> `userdata`, `home` stops exactly at `userdata_end` (444415 in the fixture, with `oem-late` at
> 444416 untouched). The one case that goes further is `userdata` being the last partition with
> unallocated tail space, where `home` absorbs that tail — which is desirable, not a violation:
> `home` is meant to expand to the maximum allowed once the user has chosen the new `userdata`
> size. Hence the "or already unallocated" clause above. The property that carries the safety
> argument is that **no sector of a pre-existing partition is ever written**, and the floor plus
> the free-block rule deliver it without a second bound.

This protects `xbl`, `abl`, `devinfo`, `super` and every OEM partition *by construction, on any
layout* — captured or not — because they are outside the span. It is strictly stronger than a name
list, which can only protect what it knows to name, and it is what makes the ten uncaptured boards
in `devices/` safe rather than merely refused. Any write whose target sector range is not wholly
contained is a bug that aborts before issuing, not a rule that can be widened by a typo.

> **SUPERSEDED 2026-08-10 by the victim rule above: exact name `userdata`, at least 33 GiB, no
> fallback.** The three bullets below — label first, size as cross-check, dominant-partition offer —
> are kept because the reasoning about why size can never be a *substitute* still holds, but the
> offer in (3) is gone, and with it the case the deny list guarded.

**Identifying `userdata` uses two signals, and they are not interchangeable:**

1. **Label first** — `userdata`, plus any per-board aliases the Phase-0 captures reveal.
2. **Size as a cross-check, never a substitute.** Assert the label-matched partition is also the
   largest. If label and size disagree, that is a contradiction about a device we evidently do not
   understand → refuse and print the table. Corroboration is worth far more here than fallback.
3. **No label match → offer the dominant partition, gated on §4d** (decided 2026-08-05). Only when
   one partition is unambiguously dominant — **>50% of the disk and >2× the runner-up** —
   otherwise refuse. This is safe precisely because §4d already names the specific partition and
   its real size to the user: *"we believe your Android data is partition 23, 96.4 GiB; everything
   on it will be erased."* A human confirming a named partition is a stronger check than any rule
   we would write, and it is what lets a board we have never captured install at all.

**Ordering is load-bearing: the already-NovaDeck check (rule 8) runs BEFORE any size heuristic.**
On a reinstall the largest partition is our own `/home`, not `userdata`, so a size test reached
first would carve the user's game library. Identity of the disk is settled before size is
consulted.

### `install/disk-rules.conf` — DROPPED 2026-08-10, and the victim rule replaces it

**The user's call, and it removes the thing the list existed to backstop.** The victim is identified
by one rule with no fallback:

> A partition named **exactly `userdata`** (all four captures agree), **at least 33 GiB**. No label
> match → refuse. No size heuristic, no dominant-partition offer, no name list.

The 33 GiB is 32 for NovaDeck plus 1 kept for Android. Below 32 GiB a NovaDeck install is not worth
having, so a disk that cannot give it that is refused rather than half-served. Note this is a
*policy* minimum and is not the same number as `genpart.sh --min` (15233 MiB), which is the
*mechanical* one — the point below which the eight partitions do not physically fit. Both exist;
they must not be conflated, and neither should drift into the other.

Why the deny list goes with it: its whole job was guarding the *choice of victim* against the
dominant-partition heuristic picking something like `super`. With no heuristic there is no wrong
choice to guard — the name either is `userdata` or the install refuses. Everything else on the disk
is already protected geometrically by `genpart.sh`, which refuses to write into any span an existing
partition occupies. A name list would now be a second answer to a question that has one.

**No satisfying `userdata` is a BLOCKER, not a branch** (user's call, 2026-08-10). Wrong name, or
smaller than 33 GiB, and the installer stops: it does not offer another partition, does not fall
back to a heuristic, and does not proceed in a reduced mode. The screen says which disk was examined
and which of the two conditions failed, and that is the end of the run.

The consequence to keep in view: a board whose data partition is called something else is refused,
not carved wrongly. That is the intended trade — refusing an installable device is recoverable, and
the alternative failure is not. It also means the installer must say *why* precisely enough that the
user can tell "this device is not supported yet" apart from "this device is too small", since those
have completely different answers.

### ~~`install/disk-rules.conf` — the second net~~ (superseded, kept for the reasoning)

**Demoted 2026-08-05 from "the brick gate" to a second, independent net.** Span containment above
is what actually prevents a brick; this list catches the case where identification itself went
wrong, and it is deliberately redundant with it. Keep it — two mechanisms that fail differently
are the point — but do not let it drift back into being the primary defence, because a name list
cannot cover layouts nobody has captured.

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
3b. **No FOREIGN BOOTABLE ESP** — no partition of type `C12A7328-…`, other than ours, carrying
   `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. This is ABL's own content test: two of those on one disk
   and the firmware cannot choose, so one installation is unreachable whichever it picks. Refuse and
   name the partition. Read-only, via `mtype`/`mdir` on the partition at its byte offset — no mount,
   consistent with the rest of this script being side-effect-free. Ours is exempt (rule 8 identity
   plus the `NOVADECK-ESP` name); an ESP holding neither file is invisible to ABL and is not a
   refusal.
4. **Span containment** — every sector we intend to write lies inside the identified `userdata`
   extent. This is the assertion that actually prevents a brick; (5) and (6) are independent
   corroboration, not the defence. An unmatched partition name no longer refuses outright, since
   uncaptured boards are expected: it is reported, and it is harmless as long as it sits outside
   the span.
5. No `deny` match inside the span we intend to write — evaluated **independently** of (4), so a
   typo widening a rule still cannot open the brick path, and a containment bug still meets a
   name check.
6. `userdata` identified per "Identification, then geometry" above: label match cross-checked
   against largest-partition, or a §4d-gated offer of an unambiguously dominant partition.
   Contradiction between label and size → refuse.
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

   > **THE THREE MODES, settled 2026-08-10 (user's), and the reasoning collapses the design.** The
   > first sketch had reinstall drop all eight partitions, ask whether the `userdata` split should
   > change, and re-lay from scratch. The user's objection killed it in one line: *if the user does
   > not resize `userdata` there is no point recreating `/home` at all — and that is the only reason
   > reinstall mode exists.* Nobody reinstalls to get the same partitions back; they reinstall to
   > replace the OS **while keeping the library**. Once that is the purpose, resizing has no business
   > on the path, because resizing destroys the library and there is then nothing left to preserve —
   > at which point the operation is just a fresh install and should be run as one.
   >
   > So the modes are distinguished by what the user is trying to keep, and each one is short:
   >
   > | mode | `userdata` | our eight | Android data | `/home` |
   > |---|---|---|---|---|
   > | **fresh** | carved smaller (or already sized, on a re-run that resizes) | created | **factory reset** | created empty |
   > | **reinstall** | **untouched** | rootfs A/B, var A/B, ESP, EFI rewritten in place | untouched | **untouched — not even its GPT entry** |
   > | **uninstall** | grown back to its full span | **deleted** | **factory reset** | deleted |
   >
   > - **Reinstall writes no partition table at all.** Not "delete and recreate at the identical
   >   extent" — that was the previous sketch and it bought nothing except an arithmetic identity to
   >   assert. The eight are already where they belong; a reinstall opens filesystems, not the GPT.
   >   This is strictly safer than what it replaces and it is also less code.
   > - **"I want a different split" is a FRESH install, and the UI must name it that way.** It
   >   factory-resets Android *and* erases the library, which is exactly the fresh-install consent
   >   text — so it takes the §4d gate rather than a quieter one, and the user is never offered a
   >   resize that silently costs them a library.
   > - **Erasing `/home` on a reinstall stays available** (rule 8's opt-in above) and is now clearly
   >   what it always was: a `mkfs` on one partition, not a re-lay. Keep remains the default.
   >
   > **What reinstall is FOR, and therefore what to call it (2026-08-10).** Asked directly, the
   > use-case list comes out short and all of it is disaster recovery **for the update mechanism
   > itself** — which is the only situation where OTA cannot be the answer: both slots unbootable
   > (single-slot corruption is RAUC's job, not ours), a broken update chain on a disk that is
   > otherwise fine (keyring rotation, a bundle that wedges the updater, a device too far behind for
   > any bundle to apply), or crossing a boundary OTA will not cross such as dev↔release. The
   > tempting extras do not survive contact: a wedged `/etc` overlay and a bad `/var` both have
   > cheaper resets, a downgrade is already offered by OTA (`check` compares inequality), and a
   > layout change cannot be a reinstall at all because re-laying moves the floor.
   >
   > So it is **repair**, not convenience, and §4d's wording should say so: *"Repair NovaDeck — keeps
   > your games"* against *"Install NovaDeck — erases Android data and your games"*. Calling it
   > "reinstall" invites the expectation that it fixes partitioning, which is the one thing it
   > deliberately will not touch. And the erase-`/home` opt-in earns its place here rather than being
   > a courtesy: the faults that send someone to the installer often live partly in `/home` (Steam
   > config, shader caches, a library on a failing card), so a repair that preserves everything that
   > could be wrong is the right default and the wrong only option.
   >
   > **Uninstall — new, and it is the mode with the tidiest geometry.** Delete our eight, delete
   > `userdata`, recreate `userdata` at its original start running to `CEIL`, with its original type
   > GUID. No stored pre-state is needed and none is consulted: `CEIL` is *by construction* the last
   > sector before whatever followed `userdata`, so on a board where something does follow (the
   > Pocket FIT) the restored partition is byte-identical to the factory one, and on a board where
   > nothing does (S2, ACE, Odin 2) it additionally absorbs any trailing space that was unallocated
   > to begin with. Both are the right answer, and neither needs the install record that rule 10
   > deliberately refuses to make restorable.
   >
   > Android is factory-reset a second time by an uninstall — the partition changes size, so its
   > filesystem cannot survive. That is the same consent the install already took, and it must be
   > taken again rather than inherited.
   >
   > **`select-target.sh` already emits everything uninstall needs** — `UD_START`, `UD_TYPE` and
   > `CEIL` — which is a good sign the read-only/destructive split was cut in the right place. What
   > it does not yet have is a way to say *which* of the three the user asked for, and that is an
   > argument to the destructive half, not something to be inferred from the disk: the disk state
   > only distinguishes "ours" from "not ours". **Do not overload `MODE=` with intent.**

   > **CONSEQUENCE FOR THE VICTIM RULE, and it is a bug in `select-target.sh` as committed
   > (2026-08-10).** The ≥33 GiB size test runs on every path, but after a carve `userdata` is
   > legitimately as small as **1 GiB** — that is the Android floor the user was allowed to choose.
   > So a device installed with a minimal Android share cannot be reinstalled: it is refused with
   > "userdata is 1 GiB, and 33 is the minimum". The 33 GiB figure only ever meant "there is room to
   > *make* a NovaDeck install here", which on a disk that already has one is a question that has
   > been answered. **The size test belongs behind `MODE=fresh`** — which is precisely what rule 8's
   > "skip 4–6" was for, and what the code does not yet do.
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

> **WIRING, decided 2026-08-10 — BOTH installer suites hang off the INSTALLER-IMAGE target, not
> `make test`.** That target does not exist yet (Phase 6 adds `installer` as a third `artifact:`
> value in `image.yml`), so until it does they are run by hand inside `novadeck-build` and are wired
> to nothing. **Wire them when the installer target lands, and not before.**
>
> The two are `install/test-select-target.sh` (64 cases) and `install/test-carve.sh` (51), and they
> share `install/lib-gptfixture.sh` — the builder that rebuilds the four captured boards as real
> GPTs, extracted when the second suite needed it rather than copied, because a second copy of that
> awk is the obvious place for them to drift apart. Wiring either one wires the library, so they
> land together or not at all.
>
> The reason is scope, not runtime. Neither `select-target.sh` nor `carve.sh` is shipped into the
> rootfs — `images/assemble-rootfs.sh` installs `genpart.sh`, `partition-table.txt` and
> `lib-slotwrite.sh` and nothing else — and no OTA or card path carves anything, so a card or bundle
> build gaining a minute of CI for scripts it does not contain would be pure cost. **Nothing in the
> build references `carve.sh` at all today**, which is correct rather than an oversight, and is the
> one thing to check has changed when the installer target lands. They need `sgdisk`, `mtools` and
> `dosfstools`, which the host does not have; they skip with a reason there rather than failing.
>
> **`test-carve.sh` is the one to run after ANY change to the append path**, `genpart.sh --append`
> included: it is the only suite that drives a carve to completion against real captured geometry,
> so it is where a regression in placement surfaces as a moved partition rather than as a green run.
>
> **Keep the split clean:** `genpart.sh` DOES ship in the rootfs and its **create** mode is what
> `make-sdcard.sh` uses, so the genpart cases in `install/test-install.sh` stay in `make test`.
> Only `--append` and `select-target.sh` are installer-only. Do not move the genpart cases out
> along with this suite.
>
> Runtime, measured 2026-08-10: **47 s**, after building each fixture GPT in one `sgdisk` call
> instead of one per partition (~600 processes, over five minutes). What is left is filesystem
> allocation for a backup GPT at the end of a 479 GiB sparse file; user time is 1.7 s.

> **AT 64 CASES, 2026-08-10, and writing the last eight found two defects rather than confirming
> none.** (1) Rule 3 accepted a damaged GPT: `sgdisk -v` prints "No problems found" on a disk whose
> backup header is zeroed, whose main header is zeroed, *and* on a disk carrying no GPT at all,
> because it regenerates the missing half in memory and then verifies what it invented. It now reads
> the whole output — and the pattern names damage rather than severity, since a first attempt that
> refused on any `Caution` refused **all four captured boards**: stock Android tables are not
> 2048-aligned. (2) The 33 GiB size test ran on every path, so a device whose owner gave Android the
> minimum could never be reinstalled; it is now behind `MODE=fresh`, which is what rule 8's "skip
> 4–6" always meant.
>
> **`NOVADECK_SELECT_DISKS` exists for rule 9 and nothing else.** Two eligible disks must refuse
> rather than pick, and the explicit-target path cannot reach that rule — untested, "never pick" is
> an intention rather than a property. The seam is the same shape as `NOVADECK_SELECT_FIXTURE` and no
> wider: `examine()` still refuses anything that is not a block device unless the fixture flag is
> also set. Rule 1 is reached the same way, by shimming `findmnt`/`lsblk` so a temp file can be the
> running disk without writing into `/dev`.

`install/test-carve.sh` — organised around the two claims that stand between a user and an EDL
recovery, and both are asserted against the **resulting GPT** rather than against the arithmetic
that produced it:

- **Containment.** Each fixture's *foreign* rows — everything neither ours nor `userdata` — are
  captured before the carve and compared byte for byte after, on all four boards. The Odin 2 earns
  its place with sixteen partitions ahead of `userdata` at p17; the Pocket FIT is the only capture
  with anything *after* it, so it is the one board where a `home` overrunning the ceiling lands in a
  neighbour rather than in free space.
- **A refusal costs nothing.** Every refusal case asserts the table is unchanged. A run that deleted
  `userdata` and *then* discovered the eight would not fit is precisely what the check ordering
  exists to prevent, and "it refused" is not the property worth testing — "it refused having written
  nothing" is.

Plus the resize path (the case the effective ceiling exists for), an interrupted carve completed by
re-running — the entire recovery story, rule 10 having ruled out backups — reinstall writing nothing,
a partial set refusing, and uninstall restoring the span with its vendor type intact.

> **What a green run here does NOT establish.** No defect in `carve.sh` was found by writing these
> 51 cases, which is weaker evidence than it reads as: the code agrees with fixtures written
> alongside it, on image files where sgdisk sees **512-byte sectors**. Real UFS LUNs report 4096 and
> sgdisk only asks the kernel for that on a block device, so the whole sector-size path is untested
> off hardware. Do not treat this suite as the gate Phase 4's hardware run is.

`install/test-select-target.sh` — this is where the assertion budget goes, ≥60 cases against
the **real captured GPTs** from Phase 0, and green against **every** captured board rather than
one: data LUN accepted; the same tree with `abl` present → refused; unnamed GPT → refused; damaged
backup GPT → refused; the boot SD → refused; too-small remainder → refused; two eligible LUNs →
refused; already-NovaDeck → accepted via (8); every `deny` name individually → refused.

The identification and containment rules need their own cases, since they are now the primary
defence:

- **Containment is the one to attack.** Synthesise a layout where our 8 partitions would not fit
  inside `userdata`'s extent and assert the abort fires *before* any write is issued. Then mutate
  a start/length by one sector in each direction and assert it still fires — an off-by-one that
  escapes the span is the whole failure mode.
- Label present but **not** the largest partition → refused as a contradiction.
- Label absent, one partition >50% and >2× the runner-up → **offered**, and the §4d text quotes
  that partition's real name and size.
- Label absent, two partitions of similar size → refused, both listed.
- **Reinstall ordering:** an already-NovaDeck disk whose `/home` is the largest partition →
  accepted via (8) as a reinstall, and the size heuristic is never consulted. This is the case
  that destroys a game library if the ordering regresses, so it gets an explicit test rather than
  relying on rule order being read correctly.
- An OEM name absent from every capture, sitting outside the span → **accepted**, reported, not
  refused. This is the uncaptured-board case and it must not regress into a refusal.

Rule 3b (foreign bootable ESP) gets four, and the Pocket FIT capture is the real fixture for the
first — it is the only board we hold that actually carries another distribution's install:

- The FIT's GPT with `/KERNEL` present on its p12 ESP → **refused**, message naming p12. Then the
  same GPT with `userdata` left LARGER than `ROCKNIX`/`STORAGE` → still refused, which is the whole
  point: today that layout passes rule 6 and installs.
- An ESP of the right type carrying **neither** file → accepted. An OEM ESP that ABL ignores must
  not block an install.
- `/EFI/BOOT/bootaa64.efi` and `/KERNEL` each independently trigger it — ABL accepts either, so a
  check that only knew one would miss half the distributions.
- A reinstall: our own `NOVADECK-ESP` carrying `bootaa64.efi` → **accepted**, not refused as
  foreign. This is the case that breaks if the exemption is left implicit in rule ordering.

### Hardware — `select-target.sh` on the boards

**One board of four done, 2026-08-21: AYANEO Pocket ACE.** `install/hw-select-target.sh
root@<device>` stages a pinned `sgdisk` plus the script into `/run/novadeck/probe` (tmpfs) and
captures the run; the output is committed as `docs/internal-select-target.md`, one section per
board, the same shape as the Phase 0 recon capture. Nothing it does writes outside `/run`, so it
is safe against a board carrying an install somebody cares about.

What the run establishes that the 66 offline cases structurally cannot:

- **`SECTOR=4096`.** Every fixture case runs at 512, because sgdisk asks the kernel for the
  logical size only on a block device. The ACE's `sda` reports 4096 and the script carried it
  through — the sector-size path now has one real reading behind it.
- **Rules 1/2 unshimmed, and the ordering trap with them.** `/dev/mmcblk0` — the dev card, an
  *already-NovaDeck* disk carrying all eight of our partitions — was refused as *"the disk the
  running system is on"* rather than accepted as a reinstall. That is the ordering the plan calls
  its sharpest design point, firing on live hardware instead of behind a `findmnt` shim.
- **Real LUN enumeration.** Six UFS LUNs, exactly one picked, the other five refused by name.
- **Agreement with the Phase 0 capture, to the sector.** `UD_INDEX=11`, `UD_START=4794920`,
  `UD_END=30150650`, type `1B81E7E6-…` against the committed dump's `start=4794920,
  size=25355731` and `last-lba: 30150650`. `CEIL == UD_END` because `userdata` ends on the last
  usable sector: on this board `home` absorbs no trailing free space.

**Board two, KONKR Pocket FIT — and it found the defect the ACE could not.** The FIT is the only
board carrying another distribution, and rule 3b **did not fire**: `sda`, with `ROCKNIX` on a
genuine `EF00` ESP at p12 and `STORAGE` at p13, came back `TARGET=/dev/sda MODE=fresh`.

The mechanism is not in the rule, it is under it. `esp_is_bootable()` reads ESP content with
`mdir`, **mtools is not in the shipped image** (an installer package, exactly like gptfdisk), and
`mdir` reports a missing file and a missing binary the same way — non-zero. So the rule answered
"not bootable" for every ESP on the disk and the check silently did not happen. All 66 offline
cases were green throughout, because the build container has mtools on its PATH — an offline suite
proves logic, never the image's tool inventory, and that is the whole shape of this bug.

Fixed by making it **fail closed**: `select-target.sh` now requires `mdir` up front the way it
already required `sgdisk`, so a check that cannot run refuses instead of degrading. With mtools
staged onto the device the rule fires correctly and names the partition —
*"partition 12 (ROCKNIX) is a bootable ESP that is not ours"* — and the scan refuses the whole
board. That is rule 3b's first exercise against a real foreign install rather than a synthesised
fixture, and the reason the FIT was worth running for more than a second data point.

Two cases guard the regression (`install/test-select-target.sh`): PATH rebuilt without `mdir` must
refuse **naming the tool**, and the same fixture with `mdir` restored must still be refused by 3b
itself — otherwise the first case would pass against a fixture that had quietly stopped being
refusable.

**Board three, MANGMI Pocket Max — a FIFTH board, and it was not in the recon set.** Captured with
`probe-internal.sh` and added to `docs/internal-storage.md`, so both suites now drive five boards
rather than four. It contributes `userdata` at **p15** (a third distinct index alongside the ACE's
p11 and the Odin 2's p17) and exercises live the case the plan says must not regress into a
refusal: an OEM layout absent from every capture is **accepted**, not refused. `SECTOR=4096`,
`UD_INDEX=15`, `UD_START=1735208`, `UD_END=27540474`, 98.4 GiB, `CEIL == UD_END` again.

It was run expecting eMMC — internal storage that would appear as `mmcblk*` and finally make rules
1/2 load-bearing rather than true by naming. **That premise does not hold for this unit:** its
internal storage is UFS (`sda`–`sdh`, every LUN reporting 4096) and the only `mmcblk` present is
the boot SD.

**And there is no eMMC board to fall back on — the fleet is entirely UFS** (five captures plus a
Thor Lite, UFS 3.1, checked 2026-08-21). So *"an `mmcblk` device selected as a target"* is not a
test still queued; it is one no hardware here can run. Two things make that acceptable rather than
an open hole. Selection and the carve are **name-agnostic by construction** — an index is emitted,
indices are what reach sgdisk, and rule 1 resolves the running disk through `findmnt`/`lsblk
PKNAME`, spelled identically either way — and the name-shaped half is now asserted offline: the
scan glob names `mmcblk`, and the same image under an `mmcblk` name and an `sdX` name must emit
identical geometry, so a rule that started reading the device name fails a case. What remains
genuinely untestable is narrow and stated: that an eMMC disk reports `removable=0`, and rules 1/2
discriminating when boot medium and target are *both* `mmcblk`. **Phase 4's orchestrator is where
this has to be maintained deliberately** — see the PARTUUID requirement in §4c.

> **AND THE `removable` CHECK IS NOT WHAT PROTECTS THE BOOT MEDIUM.** Measured across all five
> captures: the boot SD reports **`removable=0`** on every board — the SD host controller is not
> marked removable — so that check never fires for the card. **Rule 1 (the running disk) is the
> sole thing keeping the installer off the medium it booted from**, and the code comment claiming
> otherwise was corrected. What `removable` does catch is USB media, which is worth having and is
> a different guarantee. This matters because the blast-radius argument reads as though two
> independent nets cover the card; only one does.

### `carve.sh` on hardware — DONE 2026-08-21, AYANEO Pocket ACE

**The first destructive operation this project has performed on a real disk, and all three modes
ran in one sitting: `fresh` → `uninstall` → `fresh`, exit 0 each.** A GPT backup was taken first
(`sgdisk --backup`, kept off-device) because `carve.sh` takes none — the plan puts "BACKUP GPTs" in
the §4c spine, which does not exist yet, so running the carve directly skips it. **Give the
orchestrator that step; it is the difference between an exact restore and an equivalent one.**

The board's `userdata` was p11, 96.72 GiB, last on the disk. Carved to 16 GiB:

```
userdata    4794920..8989223    16.00 GiB   type 1B81E7E6-… preserved
ESP         8989224..9054759     0.25 GiB   ← starts exactly at the floor
efi-A/B     9054760..9087527     0.06 GiB each
root-A/B    9087528..12757543    7.00 GiB each
var-A/B    12757544..12888615    0.25 GiB each
home       12888616..30150650    65.85 GiB  ← ends exactly at the ceiling
```

- **Containment held, asserted against the disk.** `p1`–`p10` are byte-identical to the pre-carve
  `sfdisk --dump` after the *entire* cycle — three destructive operations, not one. `sgdisk -v`
  reports no problems and **0 free sectors**: the eight chain with zero gaps from the floor, and
  `home` ends exactly on the ceiling.
- **4096-byte sectors, for the first time.** Every offline case runs at 512, so the `--append`
  arithmetic — floor, ceiling, explicit chained starts — had never executed at the sector size real
  UFS reports. It placed all eight correctly on the first attempt.
- **`uninstall` restores the extent exactly.** The only difference across the whole 20-row table is
  `userdata`'s unique GUID: same start, same 25,355,731 sectors, same vendor type, same name, every
  other row untouched. The PARTUUID is freshly minted and that is inherent — `uninstall` consults
  no stored pre-state by design. A GPT backup is what restores the original GUID, which is the
  second reason the orchestrator should take one.
- **It is deterministic.** The re-carve after `uninstall` reproduced the first layout to the sector.
- **`MODE` tracked the disk correctly throughout**, `fresh` → `reinstall` → `fresh` → `reinstall`,
  and the documented `CEIL` quirk reproduced live: on a disk we own it comes back as `UD_END`, a
  zero-sector window, because the partition after `userdata` is our own ESP. That is exactly why
  `carve.sh` computes its own ceiling and refuses to trust that one.

> **A CARVED-BUT-EMPTY INTERNAL ESP DOES NOT DIVERT ABL — MEASURED, and it refines the
> force-external rule rather than confirming it.** The expectation going in was that the board might
> now need *force external* to reach the card, since the carve leaves an ESP-typed p12 and ABL
> prefers internal. It does not: the ACE rebooted with the card in and came straight back to
> NovaDeck, unattended, and the GPT was byte-identical afterwards — nothing on the boot path
> rewrote it.
>
> The distinction is **content, not partition type**, which is the same thing rule 3b already tests
> for: ABL wants `/EFI/BOOT/bootaa64.efi`, and an ESP with no filesystem at all offers nothing to
> chainload, so it falls through. **Force-external becomes necessary only once that file exists** —
> which the spine writes LAST, deliberately.
>
> That turns the ordering rule into a stronger guarantee than it was written as: an install
> interrupted anywhere before the final ESP write leaves a device that **still boots the installer
> medium by itself**. The recovery instructions should say force-external is needed after a *failed
> late* install, not after any interruption — telling every user to reach for a bootloader option
> they do not need is its own failure.

#### The defect booting Android found: a carve alone does not stop Android using our span

**Only the other OS could have found this, and the carve had already been declared green.** After
the 16 GiB carve above, the ACE booted Android, which came up looking perfectly healthy and reported
**92 GB free of 97** — on a partition that is now 16 GiB. It had mounted the filesystem that was
there *before* the shrink and believed it owned every sector up to 30150650: our ESP, both roots,
both vars, `/home`. One large download would have eaten the install, silently, with no error on
either side. The decisive evidence that it had not reformatted was the user's: **setup-wizard did
not re-run**.

Three things this turns on, all measured on the board rather than reasoned about:

- **`userdata` is f2fs under metadata encryption** (`dm-default-key`). `blkid /dev/sda11` reports a
  PARTLABEL and PARTUUID and **no filesystem type at all**, while `metadata` beside it is plain
  f2fs. The stale filesystem is *inside* the encrypted mapping.
- **So `wipefs -a` is the wrong tool** — the obvious one, and it would find no signature, erase
  nothing, and exit 0. Unconditional `dd` is required, and it works because `dm-default-key` is a
  1:1 offset-preserving mapping: the inner superblock's ciphertext sits where a plaintext one would.
- **f2fs does not check its superblock size against the device at mount.** ext4 does and would have
  refused. The quiet mount is a property of the filesystem Android happens to use, not something to
  rely on staying true.

**Fix, in `carve.sh`: zero the head of `userdata` after the resize, in `fresh` and `uninstall`
alike.** 8 MiB, bounded to the partition, run before any of our partitions exist. `uninstall` needs
it for the opposite reason — the filesystem left behind describes the *shrunk* volume, so Android
would mount 16 GiB on a 96 GiB partition and quietly keep the difference from its owner. The
partition node is resolved **by PARTUUID**, and the function refuses rather than guessing a device
name if that lookup fails.

**Verified on hardware, both directions.** Re-carved to 8 GiB: the first 8 MiB of `/dev/sda11` read
back as **0 non-zero bytes** while 8–9 MiB still held 36728 non-zero bytes — the wipe stopped
exactly where it should, rather than running into the span where the ESP now lives. Android then
booted **straight into setup-wizard reporting 8 GB**, with no trip to recovery. That is the
consent screen's promise — "Android still boots, and arrives factory-reset" — actually delivered.

**Two further facts worth having, both from this session:**

- **A factory reset from recovery does NOT rewrite the GPT.** It formats `metadata` and `userdata`
  and leaves the table alone; the carve was byte-identical afterwards. **An internal NovaDeck
  install survives the user factory-resetting Android**, which is a property §4d may state.
- **A reset does repair the size** — Android formats using the true partition geometry. But nothing
  prompts a user to perform one, so it is not a substitute for the wipe: without it the danger
  window runs from the carve until a reset that may never happen.

**Still unreached on hardware, and honestly so.** Rule 9 (two eligible disks → refuse rather than
pick) cannot fire where only one LUN has a `userdata`, so it keeps `NOVADECK_SELECT_DISKS` and
stays a fixture-only property. `carve.sh` is **no longer on this list** — see the section above.

The already-NovaDeck **reinstall** path is the one thing left. `select-target.sh` now reports
`MODE=reinstall` against the carved ACE, so identification is proven; what has never run is the
`reinstall` *mode of the carve* on a disk carrying a real install, and it cannot be judged
meaningfully until Phase 4 has put filesystems and a slot into those eight partitions — its whole
contract is that it writes no partition table and leaves `/home` alone, which is only observable
when there is a `/home` worth leaving.

**The generalisation, which is the part that outlives this bug.** Every gate in the installer that
shells out to a tool absent from the shipped image has this failure shape, and none of them can be
caught by a suite that runs where the tool exists. For each external command, decide whether its
absence must refuse — and assert that decision as its own case, because the default is to degrade
quietly.

`carve.sh` was audited the same day and is **clean**: `sgdisk` is required up front, `genpart.sh`
is ours, and `partprobe`/`udevadm` are best-effort by explicit `|| true` — a visible decision
rather than an accident, which is the distinction that matters. **Phase 4's orchestrator still
owes this audit**, and it is the one with the longest tool list (`mkfs.vfat` from dosfstools,
`mkfs.ext4`, `mkfs.btrfs`, `rauc`, `curl`, `nmcli`), every one of them a tool the shipped image
does not fully carry.

### Blast radius, stated plainly

**The recovery model, stated once: for a bricked device there is exactly one recovery, and it is
EDL/QFIL with a vendor firehose programmer.** There is no software undo, no backup to restore
(rule 10), and no on-device repair — the installer medium can reinstall NovaDeck, but it cannot
resurrect a device whose boot firmware is gone. Every other safety property in this phase exists
because that is the only backstop.

This is *why* the blast radius is one partition rather than a matter of taste. The risk is low
precisely because we touch `userdata` and nothing else — but it is low by construction, not by
luck, so the construction is the thing under test:

- **Wrong LUN carrying `xbl`/`abl`** → hard brick, EDL only. **The victim rule is what prevents
  it** — not a deny list, which was dropped with `disk-rules.conf` on 2026-08-10. A boot LUN has
  no partition named `userdata`, so it is refused before any geometry is computed, and this
  single failure mode is why selection is a separate side-effect-free script with its own suite.
  **Confirmed on hardware 2026-08-21** (`docs/internal-select-target.md`, Pocket ACE): `sdb`/`sdc`
  (`xbl_a`, `xbl_config_a`) and `sde` (`abl_a`/`abl_b`) were each refused with *"no partition named
  'userdata'"*. Refusing by name-of-victim rather than by name-of-danger is the stronger property —
  a board whose firmware partitions are spelled differently is still refused, where a deny list
  would have had to know the spelling.
- **Right LUN, interrupted** → recoverable by re-running, *provided* `/EFI/BOOT/bootaa64.efi` on
  the internal ESP is the **last** thing written. Order the installer exactly as
  `post-install.sh` orders itself: nothing points at the new install until the new install is
  real. This is the one failure class with a genuine software recovery, which is why the ordering
  is not negotiable — and per "The ABL contract" in Phase 0 that one file, not the bootconf, is
  the point of no easy return.

  **Re-running requires the force-external option**, because by then the internal ESP may exist
  and ABL prefers it. So the failure screen and the docs must say so: "insert the installer card,
  select force external in the bootloader, and re-run." An interrupted install whose recovery
  instructions omit that step is, from the user's side, indistinguishable from a brick.
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

> **REQUIREMENT — address the new partitions by PARTUUID, never by name arithmetic.** Every step
> after `genpart.sh --append` needs a path to a partition it just created, and the tempting form is
> `${disk}${n}` or `${disk}p${n}`. **Do not.** The `p` infix depends on the disk's kind —
> `mmcblk0p11` against `sda11` — so a spine written against one is broken on the other, and
> **we cannot test the difference**: every device in the fleet is UFS (five captures plus a Thor
> Lite, all UFS 3.1; the only `mmcblk` present anywhere is the boot SD). A naming bug of this shape
> would therefore first appear on a customer's eMMC device, mid-install, on a disk whose `userdata`
> is already gone.
>
> Read the uuid back out of `sgdisk -i <n>` and use `/dev/disk/by-partuuid/<uuid>`, which is what
> the stage-2, initramfs and card paths already do — nothing on the device concatenates a disk and
> an index today, and the spine must not be the first. Lower-cased, per `mint_partsets`' rule:
> sgdisk prints GUIDs upper case and steamcl string-compares them.
>
> This is why Phase 3 closing without an `mmcblk` target is acceptable rather than a gap left open.
> Selection and the carve are index-based and name-agnostic by construction — `select-target.sh`
> emits an index, `carve.sh` and `genpart.sh` pass indices to sgdisk against the whole-disk path,
> and rule 1 resolves the running disk through `findmnt`/`lsblk PKNAME`, which is spelled the same
> either way. `install/test-select-target.sh` asserts both halves of that: the scan glob names
> `mmcblk`, and the same image under an `mmcblk` name and an `sdX` name emits identical geometry.
> The orchestrator is the one place the property has to be maintained deliberately.

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
  bash/coreutils/util-linux, **gptfdisk + dosfstools + mtools** (none of them in the shipped
  image — and `mtools` is not optional: `dosfstools` ships `mkfs.vfat`/`fsck.vfat`, NOT `mdir`,
  which is what rule 3b reads a foreign ESP's content with. Leaving it out reproduces the
  2026-08-21 Pocket FIT finding on the installer image itself),
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

**Offline, in `make test`:** `test-stage2-grub.sh` (PARTUUID + the `parts.env` index map, 199
assertions), `test-post-install.sh` (unchanged behaviour post-extraction), `test-select-target.sh`
(≥60 cases on real captured GPTs), `test-install.sh` (step order, confirm gate,
never-writes-the-boot-disk, and the hand-written env block round-tripping through `grub-editenv`),
`test-units.sh` (new units), and byte-identity of the shipped `partition-table.txt`/`genpart.sh`.

**Hardware, in order — each gates the next:**
1. ~~Phase 1 alone: boot both slots from SD, run one OTA.~~ **DONE** — 2026-08-05 (both slots + OTA)
   and 2026-08-06 (`parts.env`, all four arms).
2. ~~`install/probe-internal.sh` read-only on one SM8550 and one SM8650.~~ **DONE** — four boards,
   2026-08-05.
3. `novadeck-install` over SSH from a dev card, on a **sacrificial device**: Android still
   boots, NovaDeck boots from internal with the SD removed, `novadeck-bootctl status` sane,
   one OTA installs into B and switches.
4. ~~Same, with an old NovaDeck card left inserted.~~ **DROPPED with 1c** — an old novadeck card in
   an internally-installed device is out of scope (see 1c). The supported inserted media are the
   installer/recovery card and a Steam-formatted library card, neither of which carries `novadeck-*`
   names.
5. The standalone installer image end-to-end, including `wifi.conf` and the picker.

**Note on the SD game library:** it cannot be exercised before step 3. These devices have ONE SD
slot and novadeck occupies it, so there is no free slot to insert a library card into until the
install lives on internal storage. The whole chain — udisks2 (absent from `manifest.lock` today,
so nothing mounts a hot-inserted card), the `steamos-format-device`/`steamos-format-sdcard` port,
and then `holo-fstab-repair` — sits behind Phase 4, not beside it.

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| ABL cannot reach Android once our ESP exists → dual boot impossible | **High** | Phase 0 item 5 is a go/no-go; if negative, re-open the Android decision before Phase 3 |
| Wrong-LUN write → EDL-only brick | Low / catastrophic | `disk-rules.conf` deny list evaluated independently of the allow list; side-effect-free selection with its own suite; GPT backups before any write |
| ~~`userdata` deletion upsets ABL or modem~~ | **Retired** | Phase 0 item 9 answered 2026-08-10: ABL does not read `userdata`, and the modem's own partitions are outside the carve span |
| Squashfs installer root misses non-ELF runtime state | Low | pacman-resolved tree rather than a readelf walk; a first-boot smoke unit asserting TLS, NSS, dbus and nmcli all work |
| gamescope will not start without a logind session → black screen | Medium | Phase 0 item 7 proves it over `seatd`/`LIBSEAT_BACKEND=builtin` before Phase 5 starts; SSH + the ESP `install.log` + the tty1 `OnFailure=` getty mean a failed GUI is still diagnosable and the install still runnable |
| Wi-Fi picker unusable on a gamepad | Medium | `wifi.conf` on the ESP is a first-class path, not a fallback; USB keyboard works free |
| Interrupted install leaves an unbootable internal disk | Medium | Write `/EFI/BOOT/bootaa64.efi` on the internal ESP **last** — it is what flips ABL to internal; re-run is idempotent; the medium is also the recovery medium, reached with **force external** |
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
