# Phase 4 — sealed manifest rootfs + A/B atomic updates

> **Superseded in Phase 5 (`docs/phase5.md`).** The 4b slot-state design this document
> describes — the `/KERNEL` Android boot image on the shared ESP, the `/NOVADECK/STATE.*`
> files, design-C slot selection in the initramfs, and the post-install `/KERNEL` rotation —
> has been replaced by the SteamDeck-style chain (ABL → steamcl stage 1 → per-slot GRUB
> stage 2 → kernel in the slot root) and the corresponding `steamos-bootconf` RAUC backend.
> The 4a sealed-rootfs and 4c bootstrap halves still describe the current build. Kept as
> the design record for what preceded Phase 5; nothing here reflects the boot path the tree
> builds today.

Phase 4 turns the image from "a rootfs we assembled with a package manager" into "a
declared artifact that can be replaced atomically and rolled back". It splits into three
parts, two of them independent:

| Part | Scope | Can it brick a device? |
|---|---|---|
| **4a** — sealed manifest rootfs | how the root is *built* and what it still contains | No. A bad build fails to boot a card you reflash. |
| **4b** — A/B atomic updates | how a built root is *shipped and switched* | Yes. Touches the boot path. |
| **4c** — bootstrap from packages | where the root's content *comes from* | No. Same failure mode as 4a. |

4a lands first, alone. It is the prerequisite that makes an A/B update meaningful: there
is no point atomically replacing a root that still carries a live package manager able to
mutate it in place. 4c is independent of 4b and sequenced before the CI work, because a
from-packages root makes the image pipeline's provenance story uniform.

---

## 4a — sealed manifest rootfs

### Where we are

`images/customize-base.sh` pulls the digest-pinned base image (`base.digest`) and runs
`pacman -Sy` over it under emulation. The mirror is a **frozen snapshot**
(`…/mash-20251118/$repo/os/$arch`), so the resolved set is already stable build-to-build —
reproducibility is not the pressing problem.

**The mirror pin is not actually a pin.** Three snapshot revisions are published
(`mash-20251118`, `.2`, `.3`). Measured 2026-07-26:

| path | `system.rootfs.zst` | last-modified | ETag |
|---|---|---|---|
| `mash-20251118` (unsuffixed — **what we point at**) | 384971555 | 2026-07-10 | `6a510539-16f23323` |
| `mash-20251118.2` | 384650724 | 2026-06-05 | `6a23593e-16ed4de4` |
| `mash-20251118.3` | 384971555 | 2026-07-10 | `6a510539-16f23323` |

The unsuffixed path is an **alias that tracks the newest revision** — it is byte-identical
to `.3` today, and `.3` differs from `.2`. Our `mirrorlist` points at that alias, so the
repo we build against moves under us. It has not bitten us yet only because the package
*databases* happen to match: all three revisions list an identical 4560-package set
(byte-identical sorted name-version lists across `core` + `extra`). That is a weaker
guarantee than it looks — identical versions do not prove identical package files, since a
rebuild can produce a different artifact under the same version.

Two consequences for 4a:

- **Step 0: re-pin the mirror to an explicit `mash-20251118.3`.** One line, no package
  changes (the set is identical to what we resolve today), and it stops the base tracking
  upstream rebuilds silently.
- It is the direct argument for step 1 recording **sha256 per package**, not just
  name-version: the hash is what actually detects a same-version rebuild.

The pressing problem is what stays behind. The shipped root carries the entire
package-manager runtime: `pacman`, `gnupg` (and therefore `dirmngr`), the keyring package
and its vendor-enabled weekly refresh timer, `/var/lib/pacman/`, `/etc/pacman.d/gnupg`.
Nothing in `fs-overlay/usr/bin` or `fs-overlay/usr/lib` uses any of it at runtime — it is
pure dead weight on a sealed read-only root, and it is not inert: the weekly key-refresh
timer is a vendor enable-symlink under `/usr/lib/systemd/system/timers.target.wants/`,
which no preset can disable. When it fires it activates `dirmngr@etc-pacman.d-gnupg`,
which then ignores `SIGTERM` at shutdown and burns its full 90s stop timeout before
systemd kills it. That is the "a stop job is running for GnuPG network certificate
management daemon" stall.

Three sources feed the image and a manifest has to cover all three, or it is not a
manifest: the snapshot repo (`PKGS`), the local `[novadeck]` repo built from source
(`packages/build-overlay.sh`), and the precompiled pins (`packages/*/prebuilt.pin`).

### Steps

**1. Record — `images/manifest.lock` (committed).**
Emit one sorted line per installed package: `name version repo sha256`, covering all
three sources. No behaviour change; the value is that a base rebuild becomes a reviewable
diff instead of a 267-package black box. Land this by itself.

**2. Install from the lock.** *(landed)*
Replace `pacman -Sy <names>` with an explicit install of lock-resolved package files
(sha256-verified host-side, reusing the persistent `work/pacman-cache`). Dependency
resolution stops happening implicitly at build time; the lock is regenerated only by an
explicit `make relock`.

`images/fetchlock.sh` materializes the lock's 274 installable rows on the host — snapshot rows
from the pinned repo via the cache, `novadeck` rows from the overlay repo, never fetched — and
verifies every one against the committed sha256 before the container starts. The container then
runs one `pacman -U` over that list and syncs no database at all, which pacman itself reports:
*"database file for 'core' does not exist"*. That warning is the proof the step works.

The sha256 check is the real gate, not a belt-and-braces extra: the snapshot repo is served
`SigLevel = Optional` and the cache carries no detached `.sig` files, so pacman's signature check
is a no-op here. A reviewed hash in a committed artifact is what pins these bytes.

**Decision: two modes, and the mode is part of the reuse key.** The lock cannot be regenerated by
a build that installs from it, so `NOVADECK_RESOLVE=1` keeps the old `pacman -Sy` path and
`make relock` is the only thing that uses it. A resolve-built tree must never ship, so
`mode:resolve|locked` and the lock's own sha256 are folded into the base reuse marker: a
resolve tree can never satisfy a locked build, and editing the lock rebuilds the base. `relock`
therefore *deletes* the base stamp rather than touching it — the next build re-installs in locked
mode, so what ships is always a tree verified against the lock.

**Decision: dev-only tooling stays out of the lock and installs by name.** `DEV_PKGS` (`evtest`,
`usbutils`) are `pacman -Sy`'d under `NOVADECK_DEV=1` even in locked mode. The lock describes the
*release* image — the tree the step-4 guard runs against — so locking test tooling would overstate
what ships. `customize-base.sh` records `dev:1` in the marker and `genmanifest.sh` refuses to
relock a test base, rather than filtering by a package-name blocklist that would drift from
`DEV_PKGS`.

The lock is a resolved closure, so a leaf package dropping *out* of it leaves no unsatisfied
dependency for `pacman -U` to trip over — it would just be absent on the device. So the container
also asserts the tree against the declaration with `pacman -T` over `PKGS` + prebuilt deps
(`-T` honours provides, `-Q` does not). Same discipline as step 4: assert the built tree.

A side benefit worth keeping: our patched overlay packages no longer win by pacman **repo order**.
The lock names a file per row, so `mesa`, `gamescope`, `sddm` and the rest install from
`/novarepo/…` by path — the `[novadeck]`-must-precede-`[core]` ordering trick, and the higher
pkgrel that propped it up, stop being load-bearing at install time. The pacman cache holds both
`mesa 1:26.1.4` (upstream) and `1:26.1.5-1.1` (ours); locked mode cannot pick the wrong one.

Also: nothing syncs, so the exported base now ships an **empty** `/var/lib/pacman/sync/` — a small
head start on step 3.

**3. Seal — strip the package manager.** *(landed)*
After install, remove `pacman`, `gnupg`/`dirmngr`, the keyring package and its timer,
`/var/lib/pacman/` and `/etc/pacman.d/gnupg` from the release root. The local package DB
is preserved as provenance under `/usr/lib/novadeck/`, outside any path the package
manager would consult. This is the step that removes the shutdown stall — by deleting the
daemon rather than masking it.

`images/seal.list` declares it (4 packages, 2 paths) and `images/seal-rootfs.sh` executes it,
expanding each declared package through its own DB file list and then `rmdir`-ing only the
directories that end up empty — so a path another package still occupies survives by
construction. Measured on the release tree: 471 files and 30 empty directories removed, 20 MiB
freed, zero dangling symlinks introduced (48 before, 48 after — all pre-existing absolute
links), and `/var` down from 12.7 MB to 1.6 MB, which is 11 MB back on a 256 MB partition.
`timers.target.wants/` is left holding only `shadow.timer` and `systemd-tmpfiles-clean.timer`;
the keyring's weekly refresh timer, and with it the shutdown stall, is gone.

**Decision: the seal runs in `assemble-rootfs.sh` on the staged tree, not in
`customize-base.sh` on `work/base`.** The base then stays a faithful record of what was
*installed* — `genmanifest.sh` keeps reading its `/var/lib/pacman/local` unchanged and `make
relock` is untouched — while the seal applies to what *ships*, once per build. It also means
no sealed tree is ever left lying around for a later build to reuse, which the base's reuse
cache would otherwise make possible.

One cost worth naming: the class rename moves 4 rows in the lock, the lock's sha256 is part of
the base reuse marker, so the first build after this change re-runs the full emulated install.
That is the reuse key working as designed (any lock edit rebuilds the base), not a regression.

`pacman` and the keyring package arrive as **dependencies of the `base` metapackage**
(`base-3-2` is installed in the base tree), so sealing cannot be `pacman -R pacman` — that
leaves the `base` dependency unsatisfied and the transaction refused. It has to be file
removal after the last install, which is sound precisely because there is no package
manager left afterward to observe the inconsistency. The removal list therefore has to be
explicit and asserted (step 4), not derived from the package database.

**Decision: the removal list is an explicit, committed artifact, and the lock marks what it
removes.** Sealing deletes files while preserving the package DB as provenance, so the DB —
which `images/genmanifest.sh` reads — keeps listing packages the shipped image no longer has.
Left alone the lock and the image diverge silently. So the removal list is declared rather
than derived, and those rows are emitted in the lock under a `stripped` class instead of
`base`/`snapshot`. One artifact then describes the real image, and a change to what we strip
shows up in the same reviewable diff as a change to what we install. `genmanifest.sh` gains
one input (the removal list); it does not gain knowledge of the sealing step itself.

Rejected alternatives: generating the lock post-seal from the preserved DB minus the removal
list (same result, more moving parts), and letting the lock describe the pre-seal tree with
the removal list living separately (then neither file alone says what shipped).

**Decision: on-device `pacman` is kept under `NOVADECK_DEV=1` and stripped from release.**
It is a genuine bring-up affordance and the divergence is confined to *tooling* — it does
not touch the boot or session path, so it does not repeat the "verify OOBE on a release
build, not the test image" trap. The step-4 guard runs against the **release** tree.

**Validator — diff against the published sealed image.**
Each revision publishes a `system.rootfs.zst` (~367 MiB) alongside the repo. Do **not**
build on it — mutating an opaque prebuilt image is the worst option for reproducibility,
and it is not our package set. Use it as a **diff target**: extract it, list what it
actually contains, and diff against `manifest.lock` and against our sealed tree. It is the
only direct evidence of upstream's *assembly* decisions, which the package repo cannot
show — and the revisions differ precisely there (identical package databases, different
sealed images), so the delta between `.2` and `.3` is assembly-layer, not package-layer.

Two specific questions it answers cheaply: whether upstream's own sealed image still
carries the package-manager runtime (informs step 3), and whether we are missing files
that come from image assembly rather than from a package.

**4. Guard.** *(landed)*
Assert on the **built tree**, not on the source diff. This repo has already been bitten once by
trusting a built tree it never inspected (a file-mode regression that reached hardware), so the
assertion is the deliverable, not a nicety — and steps 1–3 are all *declarations*, which is
exactly what a declaration that is never checked against its artifact degrades into.

`images/guard-rootfs.sh` runs from `assemble-rootfs.sh` at the last point the tree is both
complete and still a directory: after every injection and after the seal, before section 5 carves
`/var` out into `var.img`. What `mkfs.btrfs --rootdir` bakes in section 6 is that directory,
unmodified. Release-only, mirroring the seal — a test tree keeps the package manager on purpose
and carries `DEV_PKGS` the lock does not describe.

Five assertions; the first four fail the build. Measured on the release tree:

| | assertion | measured |
|---|---|---|
| 1 | every file the stripped packages own is gone, expanded through the preserved DB | 4 packages, 471 files, 2 paths |
| 2 | the named entry points are gone (`pacman`, `pacman-key`, `makepkg`, `gpg`, `dirmngr`, `etc/pacman.conf`, `var/lib/pacman`, the keyring timer) | 14 paths |
| 3 | no dangling systemd enable-symlink | 108 links, all resolve |
| 4 | `images/manifest.lock` still describes the tree | 394 packages, name+version |
| 5 | size delta against the previous build | report only |

**Decision: read `seal.list` and the package DB from the IMAGE, not from the repo.** The sealer
already copies both to `/usr/lib/novadeck/`, so the guard checks what the image claims about
itself. Checking the repo copies instead would let a stale tree pass against a freshly edited
declaration — the exact drift the artifact exists to prevent.

**Decision: assertion 2 is deliberately redundant with assertion 1, and self-checking.** Assertion
1 trusts the preserved database to say what a package owned; a truncated or wrong database makes
it pass vacuously. The named list trusts nothing. The cost of a hand-kept list of paths-that-must-
be-absent is that a typo is absent from every tree ever built, so the line asserts nothing forever
— so each name must also be *owned by a stripped package or under a declared path row*, else the
guard reports it as a dead assertion. That uses the database to validate the list, never to make
the assertion.

**Decision: assertion 3 is scoped to `*.wants`/`*.requires`, not the whole tree.** Deleting a
package's files deletes its units but not the symlinks pointing at them, and a vendor
enable-symlink is how the keyring timer stayed on in the first place — so a dangling link there is
systemd reporting an incomplete removal. A whole-tree dangling-symlink check would instead fail
every build on ~48 pre-existing absolute links inherited from the base image. Note this is weaker
than the earlier sketch of "no vendor units left in `timers.target.wants`": `shadow.timer` and
`systemd-tmpfiles-clean.timer` legitimately remain there, so the assertion is that nothing points
at a unit that is *gone*, plus the keyring timer by name in assertion 2.

**Decision: assertion 4 checks set equality in both directions, and 5 can never fail a build.** A
locked-mode build cannot drift from the lock, which is the argument for checking it rather than
for not bothering: if it ever differs, something outside the locked install path put a package on
the image. Conversely there is no defensible size threshold, and a guard that blocks on growth
gets disabled the first time a package legitimately gets bigger — so 5 prints per-top-level-dir
deltas (`usr` grew, not "the image" grew) and its record write is best-effort.

**Gap worth naming:** this asserts the staged tree, not the image bytes. Reading a btrfs image
back would need a mount, which the unprivileged build deliberately avoids; `mkfs.btrfs --rootdir`
is the only step between the two.

**5. Trim — the seal's size counterpart.** *(landed)*
The seal removes what a sealed root must not be able to *do*; the trim removes what it does not
need to *weigh*. `images/trim.list` declares it, `images/trim-rootfs.sh` applies it right after
the seal, and guard assertion 5 re-expands the image's own copy of the list and fails the build if
anything it names survived — the same declare/apply/assert shape as the seal, for the same reason
(a declaration nothing checks is a comment).

Removed: headers, static libraries, cmake/pkgconfig files, `.gir` XML (the runtime format is the
`.typelib`), man/info/doc trees, locale *sources* (`locale-gen` already ran at build time and a
read-only root can never run it again), non-English gettext catalogues, and the gcc-libs language
runtimes nothing on the image links (Go, D, Fortran, the sanitizers). Kept deliberately:
`usr/share/licenses`, `usr/lib/locale`, `usr/lib/gconv`, and `libgomp` — which looks like the same
kind of dead runtime but is linked by libb2, libsoxr, libvidstab and ffmpeg's fftw variants.

Two package-set changes land with it, both in overlay recipes rather than in the trim list, because
the right way to not ship a package is to stop depending on it:

- `packages/mesa/PKGBUILD` builds with `-D llvm=disabled`. `gallium-drivers=freedreno` never
  selected llvmpipe, so the 151 MB `libLLVM` was serving only gallium's `draw` module, which
  freedreno does not use. No software-GL fallback is lost — there was none.
- `packages/scx-scheds/PKGBUILD` drops `bpf`, `protobuf`, `libbpf`, `libseccomp` and `jq` from
  `depends`. The three shipped schedulers embed their BPF skeletons and link only
  libelf/libz/libgcc_s/libm/libc. Dropping `bpf` is what removes **binutils** — an assembler and a
  linker — from a sealed read-only root.

Why it is a Phase 4 concern rather than housekeeping: under 4b every megabyte is paid in both
slots *and* in every RAUC bundle downloaded over Wi-Fi. Measured on the release tree at
zstd:3 (what `mkfs.btrfs --compress zstd` actually stores): ~225 MB off the image.

Explicitly **not** trimmed, with their measured compressed cost, so the decision is revisitable
with numbers instead of re-measurement: the second Proton compat tool (~524 MB — user choice of
compat tool is deliberate), the FEX x86 guest rootfs (1305 MB — gated on the native-x86 guest-thunk
work), and the CJK font weights (~226 MB — font coverage is a first-boot UX property).

---

## 4b — A/B atomic updates

4b is split into two passes. **Pass 1 (the boot path) is implemented**; pass 2 (RAUC) is not.

| pass | scope | why this cut |
|---|---|---|
| **1** | slot state on the ESP, selection + rollback in the initramfs, both slots populated, `novadeck-bootctl`, a trial-boot health check | The initramfs is the one component that can leave a no-serial-console device unbootable. It should be the only variable the first time hardware sees it. |
| **2** | `rauc` on the device, `system.conf` + keyring, bundle install, the `/var` migration hook, the D-Bus/`steamos-update` wiring | Lands on a boot path hardware has already signed off, so a failure is attributable. |

### What already exists

The partition layout is in place and documented (`images/partition-table.txt`): shared
ESP, `efi-a`/`efi-b`, `rootfs-a`/`rootfs-b` (7G, read-only btrfs), `var-a`/`var-b`, shared
`home`. `make sdcard` now populates **both** slots. Bundle generation exists —
`images/genbundle.sh`, `images/rauc/manifest.raucm.in`, `make bundle` — and `rauc` **is** in
the build image (`build/Dockerfile`, 1.15.1), which an earlier draft of this document doubted.

**Measured 2026-07-27: `rauc-1.14-1` is in the pinned snapshot's `extra` repo.** Every one of
its dependencies is already in `images/manifest.lock` except `json-glib`.

**Overturned on hardware 2026-07-28: the snapshot's 1.14 is unusable here.** It cannot install a
dm-verity bundle on a kernel `>= 6.19` — a DM/verity handling bug upstream fixed first in
`v1.15.1` — and we ship 7.1.x, so *every* `rauc install` of our bundle format fails. Pass 2
therefore *does* need a `packages/rauc/` from-source recipe. It exists: the holo 1.14-1 PKGBUILD
with the version bumped to **1.15.2** and nothing else redesigned (see `packages/rauc/PKGBUILD`
for the two mechanical deviations the overlay builder forces). Being a higher `pkgver` than
holo's 1.14, pacman prefers the overlay build regardless of repo order.

Note the two rauc binaries are unrelated and must not be conflated: the one in `build/Dockerfile`
(Ubuntu, 1.15.1) only *creates* bundles on the host and never touches this bug; the one this
recipe builds is the device-side *installer*.

What does **not** exist: `rauc` on the device (not in `PKGS`), `/etc/rauc/system.conf`, and the
device keyring (the CA is minted, `images/rauc/novadeck-ca.pem`, but nothing installs it yet).

### The actual problem: no A/B-aware bootloader

ABL loads `/KERNEL` off the shared ESP (p1) and reads nothing else. There is no
bootloader stage we can point at a second partition, and none that can fall back on its
own. Every A/B design has to answer "who switches, and who reverts when the new slot does
not come up" without help from the boot firmware.

Three designs were considered:

- **A** — per-slot boot images in `efi-a`/`efi-b`, a post-install hook copying the new
  slot's image over `/KERNEL`. Simple, but a slot that fails to boot leaves nothing
  running to copy the previous image back: recovery is a reflash.
- **B** — a single slot-agnostic `/KERNEL`; the initramfs picks the slot from a
  try-counter state file on the ESP. We own `images/initramfs/init`, so this yields real
  rollback with zero bootloader support. The kernel is shared across slots, so kernel
  updates need separate care.
- **C** — B, plus a `KERNEL.bak` on the ESP so a failed health check restores the previous
  kernel as well as the previous slot.

**Decision: C.** It puts the switch and the revert in the one component we fully control,
and it covers both the dominant failure mode (root mounts, session or health check fails)
and a bad kernel, without depending on firmware behaviour we cannot change.

> **Fallback if C hits a wall:** adding a real bootloader stage (GRUB) is a legitimate
> option and should be reconsidered rather than worked around, if the state-file design
> turns out to be unworkable. It is the well-trodden path for A/B on this layout; we are
> avoiding it only because ABL gives us no UEFI stage to chainload it from today.

Consequence to settle before writing code: under C the boot image is slot-agnostic, so
`boot/package.sh` does **not** need the per-slot cmdline argument the older TODO note
assumed — slot selection moves out of the baked cmdline and into the initramfs.

### Pass 1 decisions

**The state is two files with a generation counter, not write-then-rename.** There is no `sync`
in the initramfs and no shell can fsync, so a rename guarantees nothing on FAT: the directory
entry can reach the card before the data does. Making rename safe would mean staging `mv` *and*
`sync` — two more binaries — for a *weaker* guarantee. Alternating writes only ever overwrite the
copy that is already stale, so a torn write is rejected by the reader and the previous generation
still wins; there is no window in which both copies are invalid, and the durability barrier comes
free from the `umount` before `switch_root`. The asymmetry is what decides it: the write that
matters happens on the first boot of an unproven root — the likeliest moment for someone to yank
power on a handheld — and losing it means an old root under a new kernel with no matching
`ath12k`, so no Wi-Fi, on a device with no serial console. That is a reflash, not a retry.

A corollary: **every ESP read and write in the init is a shell builtin.** That is a constraint
the format was chosen to satisfy, not a coincidence.

**`boot/cmdline` keeps `root=`/`novadeck.var=`.** They are read by the *kernel*, not only by us:
if the initramfs never executes — a missing library after an `mkinitramfs.sh` edit, a truncated
cpio — the kernel mounts `root=` itself and boots, which is the configuration this device shipped
in for months. Deleting them would turn every initramfs packaging bug into an unconditional panic
loop. Design C is still honoured in that the cmdline is *never* consulted when the slot state is
readable; it is a degrade path, and taking it logs loudly.

**Three cases that are easy to get wrong**, all covered at the time by
`images/initramfs/test-slot-state.sh` — deleted in phase 5 (`0d714ed`) along with the /KERNEL flow
it exercised; the equivalent coverage now lives in the `images/test-*.sh` suites that `make test`
runs:
honouring `pending` without a durable decrement would retry a broken slot *forever* (the counter
never reaches zero, so the rollback never fires), so a read-only ESP boots `active` instead; a
slot that will not mount clears `pending` as it fails over, so the next boot does not burn a
second try on it; and `gen` is validated all-digits *before* any `-gt`, since a lexical compare
silently breaks at generation 10.

**The health signal is gamescope's startup handshake, re-checked 30s later.** Reaching it proves
in one shot that `drm/msm` took DRM master, the panel modeset, mesa initialised, both nested
Xwaylands came up, libseat got an active seat through logind, and SDDM's autologin worked — the
earliest instant at which "the screen is showing something" is true. *Rejected:* `graphical.target`
reached (proves only that `sddm.service` was started — confirms a black screen), an active logind
session (same problem one layer up), and SteamUI ready (too strict and too coupled: an OOBE, an
offline first boot or a Steam-side outage would each roll back a healthy OS). The 30s re-check is
load-bearing because autologin sets `Relogin=true`, so a session dying in a loop would otherwise
confirm itself on its first iteration. **There is deliberately no timeout that confirms anyway.**

**`KERNEL.bak` restore is reserved in the format but not implemented in the initramfs.** It is
untestable in pass 1 (there is one kernel), bash cannot copy binary data so it would cost `cp`,
`mv` and `sync`, and it would re-introduce the fsync-less FAT rename problem on the very file the
device boots from — where a torn write is a reflash. The rollback boot runs the old root under
the new kernel, so a root-side oneshot can do the restore properly, with real fsync, and reboot.
`kernel=` and `bak=` are in the grammar from day one so pass 2 does not change the format.
*(Pass 2 implements both, in the initramfs after all — see below.)*

**The two roots must not be identical bytes.** `mkfs.btrfs` bakes an fsid into the superblock and
every image we build has `devid=1` — exactly the pair btrfs keys its in-kernel device list on. Two
such filesystems on one disk make the second one scanned look like the first having *moved*, so
mounting p5 can hand you p4, on the one test whose purpose is proving which slot booted.
`images/make-sdcard.sh` gives slot B a fresh fsid with `btrfstune -U`. **RAUC will hit this too** —
every `rauc install` writes identical bytes into the inactive slot — so its post-install hook needs
the same treatment. Done: `fs-overlay/usr/lib/rauc/post-install.sh` runs `btrfstune -f -U`.

### Hard prerequisite, independent of the design

`/var` is per-slot, and both the `/etc` overlay upperdir (`/var/lib/overlays/etc/upper`)
and the Wi-Fi MAC derived from `machine-id` ride on it. Booting the other slot therefore
presents a *different* `/etc`: no saved Wi-Fi, a fresh `machine-id`, and hence a silently
different MAC. The post-install hook must reformat the target slot's `/var`, copy the
running slot's `/var` across, and write network connections into both slots' overlay
uppers. This is required under A, B and C alike.

**Measured 2026-07-28, and the result is misleading until you know why.** Booting slot B produced
the *same* MAC and the same DHCP lease as A — apparently contradicting the paragraph above. It does
not. `machine-id` is supposed to be absent from the shipped image (`images/assemble-rootfs.sh`
states the invariant explicitly, so that systemd runs `preset-all` on first boot), but the built
`rootfs.img` **ships a populated one**, and it therefore lives in the shared read-only lower layer
where both slots see the identical value. With that bug fixed, each slot generates its own id into
its own per-slot overlay on first boot and the divergence above appears exactly as described. So
the prerequisite is not weakened by this measurement — it is currently *masked* by it, and fixing
`machine-id` makes the `/var` hook more necessary, not less. The `machine-id` defect is not a 4b
problem; it was closed separately and is recorded in `DONE.md`.

A second reason this pass could not exercise the prerequisite: the test image injects Wi-Fi
credentials into the **shared rootfs** (`images/assemble-rootfs.sh`), not the per-slot `/etc`
overlay, so "the other slot has no saved Wi-Fi" cannot reproduce on a `NOVADECK_DEV=1` card at
all. Validating the `/var` migration hook needs a release image — the same trap as the OOBE work.

### Pass 1 — the boot path (implemented, HW-VALIDATED 2026-07-28)

**Validated on device 2026-07-27/28**, following the least-to-most-destructive order. Passed: the
offline card verify (fsids distinct, slot witnesses, ESP seed, cpio contents); the regression gate
(`slot=a source=state`, no `duplicate device`, exactly one vfat mount); the read-only tool check
(`bootctl` agrees with the handoff, `STATE.0` byte-identical before and after); the rollback branch
without booting B (`try b --tries 0` → `source=rollback`, `pending` cleared); **the actual switch**
(`slot=b`, `root=/dev/mmcblk0p5`, and `/var/lib/novadeck/slot` independently said `b` — the fsid
hazard is really defeated, not just distinct on paper); **rollback from a slot that boots but never
confirms** (health check masked in B's per-slot `/etc`, one try consumed, next boot reverted to A
with `pending` cleared); and a **torn-write rejection on real hardware** — a *higher* generation
(`gen=13 active=b`) truncated before its `end` terminator was rejected in favour of the older valid
`gen=12 active=a`, so the device booted A. A discriminating `active=` value was used deliberately:
had the reader accepted the torn file it would have booted the *other* slot, which no same-slot
assertion could have caught.

The generation counter crossed 10 during the run, so the "validate all-digits before `-gt`" guard
was exercised for real — a lexical compare ranks `"10"` below `"9"` and would have booted the stale
copy.

Two properties fell out that were argued for but never demonstrated: the mask applied in B's `/etc`
was invisible from A, confirming the overlay really is per-slot; and the next write after the torn
file **reclaimed it**, because the writer always targets the non-winner. A torn copy self-heals.

One bug was found and fixed here: `novadeck-boot-good.service` was a bare `Type=oneshot`, and since
`PathExists=` is level-triggered a `.path` unit re-arms as soon as its triggered unit goes inactive
— so it retriggered every 30s for the whole uptime of the device. `RemainAfterExit=yes` fixes it
while keeping the failure path retryable. See the unit's own comment.

The state file grammar, normative. `images/initramfs/init` is the reference implementation.

```
/KERNEL                 the running boot image — ABL reads only this
/NOVADECK/STATE.0       gen=N active=a|b pending=''|a|b tries=N kernel=''|a|b bak= end
/NOVADECK/STATE.1       the alternate copy; the higher valid gen wins
/NOVADECK/KERNEL.BAK    the previous boot image, when `bak=` names it
```

`kernel=` names the slot whose boot image is at `/KERNEL`, and **empty means no claim** — a card
no update has rotated, where both slots carry the same build and no mismatch is possible. A letter
is written only by a rotation (the RAUC post-install hook) or by the rollback that undoes one, so
the field is either silent or true. It is not decoration: `/KERNEL` is *shared* while
`/lib/modules/<ver>` ships *inside* a root, so a root can run under the other build's kernel —
`novadeck-bootctl try <other>` after an update reaches it with no second update involved, and with
`CFG80211`/`ATH12K` at `=m` the symptom is "Wi-Fi broke", not "wrong kernel". The initramfs logs it
at boot and `novadeck-bootctl status`/`try` say it before the fact; nothing refuses to boot on it,
because the alternative to a mismatched pair is no pair.

`end` must be the last non-blank line — that is the torn-write detector. **Unknown keys are
ignored by the reader and preserved verbatim by the writer**: this reader ships inside `/KERNEL`
on the *shared* ESP while its writer (`novadeck-bootctl`) is *per-slot*, so after a rollback an
older writer and a newer reader coexist by design. The format is a compatibility contract.

It is also a **trust boundary** — plain text on a FAT partition anyone with a screwdriver can
edit, parsed by PID 1 as root. Every field is validated against a strict pattern before use and
none is ever word-split into a command position. Being hand-editable is deliberate: it is the
recovery mechanism when you have the card in a reader.

| what | where |
|---|---|
| slot selection, decrement, rollback, failover | `images/initramfs/init` |
| offline test of the decision table (109 checks) | `images/initramfs/test-slot-state.sh` |
| offline test of the RAUC backend contract (101 checks) | `images/test-bootctl.sh` |
| both suites, host-side, no build needed | `make test` |
| `umount` + `/esp` staged into the cpio | `images/mkinitramfs.sh` |
| both slots populated, distinct fsid, state seeded | `images/make-sdcard.sh`, `images/assemble-rootfs.sh` |
| `status` / `try` / `mark-good` / `rollback` + RAUC's custom-bootloader contract | `fs-overlay/usr/bin/novadeck-bootctl` |
| trial-boot confirmation | `novadeck-boot-good.{path,service}`, marker from `novadeck-session` |
| dm-verity, declared vfat/loop | `kernel/kernel.config`, asserted in `kernel/build.sh` |
| signing CA; only the CA cert is committed | `ci/gen-signing-ca.sh`, `images/rauc/novadeck-ca.pem` |
| release cert profile, defined once and read by both the CA script and the self-test | `images/rauc/release.ext` |

### Pass 2 — RAUC (core install path IMPLEMENTED, not yet HW-validated)

Scope taken: the install path only. `steamos-update`, the `novadeck-steamos-manager` D-Bus surface
and the bundle server are deliberately a follow-up — an update is CLI-driven for now, so a failure
in this pass is attributable to the update machinery rather than to the UI wiring on top of it.

**The kernel travels inside the rootfs, not in the bundle.** The plan for this pass was to add the
boot image to the bundle as a second payload the post-install hook consumes. It ships at
`/usr/lib/novadeck/boot.img` instead, installed by `images/assemble-rootfs.sh`, and the hook copies
it out of the slot it just wrote. Two reasons, and the second is the one that decided it:

- It removes a dependency on RAUC's handler environment. A bundle-side payload has to be located
  through `RAUC_BUNDLE_MOUNT_POINT`, whose exact availability differs between *handlers* and
  manifest *hooks*; the root-side copy needs none of that, and the hook derives its target slot
  from our own `/run/novadeck/boot` handoff (cross-checking `RAUC_TARGET_SLOTS` when set, and
  refusing on disagreement rather than preferring either).
- **It makes kernel/module coherence true by construction.** `/lib/modules/<ver>` ships in a
  specific root; the kernel that matches it is that root's kernel. Carried this way there is no
  bundle layout to keep in sync and no way to install a root whose modules do not match the kernel
  that will boot it. `CFG80211`/`ATH12K` are `=m`, so getting that pairing wrong means a device
  with no Wi-Fi and no serial console. It costs ~30 MB per slot, which is the price of the
  guarantee. A consequence worth noting: `$(ROOTFS)` now depends on `$(BOOTIMG)` in the Makefile.

**The `/var` migration copies `machine-id`, not `/var`.** SteamOS reformats the target's `/var` and
rsyncs the running one over it. We reformat too, but populate deliberately: `machine-id` alone,
plus NetworkManager connections. `/var/lib/novadeck/mac-wifi` is write-once and takes precedence
over the seed, so copying it would pin the old MAC forever regardless of `machine-id` — the
original machine-id bug relocated rather than fixed. Migrating the seed and letting the MAC
re-derive is the smaller primitive, and it keeps one source of truth.

**Order inside the hook is load-bearing:** fsid first. Until `btrfstune -U` has run, the target and
the running root share an fsid *and* `devid=1`, and mounting the target can silently hand you the
running root — so every later step, all of which mount the target, has to come after it.

**Kernel restore on rollback** is in the initramfs (`cp` is now staged for it), and reboots via
`exit 1` → panic → `panic=5`, reusing the mechanism the no-bootable-root path already relies on
because `MAGIC_SYSRQ` is not in `kernel/kernel.config`. `bak=` is cleared in the *same* generation
that clears `pending`, so an interrupted copy cannot leave a state that retries a restore forever —
and `kernel=` is re-pointed at the slot being restored to in that same generation, because the two
fields describe one event. The write necessarily precedes the copy, so a copy that *fails* has left
a record claiming a rotation that did not happen: the init then spends a second generation taking it
back. A field maintained on the happy path only is the defect this one was fixed for.

> **Honest limit.** This covers "the new kernel boots far enough to run our initramfs, but the
> system is not healthy". A kernel that does not boot at all leaves nothing running to restore
> anything — that is still a reflash, and design C never claimed otherwise.

Verified offline: `images/initramfs/test-slot-state.sh` (109 checks, up from 56) covers restore, a
missing backup file, a read-only ESP, a *failed* restore's correcting write, and the kernel/slot
mismatch warning in all three of its states (mismatched, matching, unrecorded). Guard assertion 7
asserts the built tree can actually perform an update: `rauc`, keyring, `system.conf`, `boot.img`,
`btrfstune`, an *executable* hook — the exec-bit half because this project has already paid for a
shipped script that lost it — and that every `novadeck-bootctl` subcommand the hook invokes is one
the shipped tool dispatches, since a rename in one file is what makes the other fail at its last
step, on a card whose root has already been replaced.

#### Original checklist


1. `PKGS += rauc` and `make relock` (it is in the pinned snapshot; `json-glib` comes with it).
2. `/etc/rauc/system.conf`: two slot groups, `bootloader=custom` pointed at `novadeck-bootctl`
   (whose `get-primary`/`set-primary`/`get-state`/`set-state` already implement that contract),
   and `keyring=/etc/rauc/keyring.pem` installed from `images/rauc/novadeck-ca.pem`.
3. Post-install hook: randomise the target slot's btrfs fsid (see the decision above), then the
   `/var` migration below.
4. The kernel half of design C: install the new boot image, keep `KERNEL.BAK`, and restore it
   from a root-side oneshot on the rollback boot. **Settle first:** promoting `/KERNEL` at the
   same time the new root goes on trial makes a bad kernel unrecoverable (see accepted risks);
   *not* promoting it means the trial boot runs the new root under the old kernel, whose
   `/lib/modules/<oldver>` that root does not carry. Neither is free.
5. Wire `steamos-update` and the `novadeck-steamos-manager` D-Bus surface so the UI's update
   path is real. Note the manager must own the name on the **deck session bus**, not the system
   bus, or SteamUI will not see it.
6. A bundle server. The bundle is signed by the release cert; the device trusts the CA.

### Accepted risks

- **A bad boot image is unrecoverable, and design C cannot fix it.** If `/KERNEL` panics before
  the initramfs runs, `panic=5` loops forever, the try counter never decrements, and no state
  file can help. Design C covers everything downstream of "the initramfs executed" and nothing
  upstream of it. This is the strongest concrete argument for the GRUB fallback noted above, and
  it is what makes pass-2 item 4 load-bearing rather than cosmetic.
- **An unreadable ESP on a device whose `active=b` boots A** — a silent downgrade in *content*,
  though a loud one in the journal. The alternative is not booting at all.
- **The health signal confirms a blank compositor** if gamescope is up but Steam is wedged.
  Pass 2 tightens it with a second marker from `novadeck-steamos-manager`.
- **Power-off inside the 30s confirm window rolls back a healthy update.** The cost is a
  rollback, not a brick; `tries` is the tunable. Pass 1 uses `tries=1` so tests are deterministic.
- **`degrade()` remounts the root rw** (`images/initramfs/init`), which under A/B mutates a slot
   — possibly the one on trial, which breaks any "is this slot still the bytes we installed"
  reasoning and, once verity bundles are normal, the invariant `CONFIG_DM_VERITY` exists to
  check. The right fix is a tmpfs upperdir instead of a writable root. Worth doing, but as its
  own change *after* the slot machinery is HW-validated: it alters a path hardware already
  signed off, and this pass's discipline is one variable at a time.
- **The SD card's behaviour under abrupt power loss is UNTESTED, and untestable on this device.**
  The planned power-cut test cannot be run on battery-powered hardware: there is no interruptible
  supply, and a long-press force-off takes ~8–10s against a write window of ~1s. What *is* proven
  is the reader's rejection logic, offline (`test-slot-state.sh`) and on hardware (a truncated
  higher generation was rejected, above) — but that covers a torn *file*, not a card whose
  controller lost an erase block or an uncommitted FTL mapping mid-write. The two-file scheme is
  designed against exactly that, and the design argument stands on its own; it has not been
  demonstrated. Recorded as untested rather than passed. The tractable substitute is a test-gated
  hook in the init that writes half the state and then `exit 1`s — the kernel panics, `panic=5`
  reboots, and the `umount` durability barrier never runs, reproducing an interrupted write at the
  exact instant, deterministically. That needs no `MAGIC_SYSRQ` (which `kernel/kernel.config` does
  not declare) and is strictly more repeatable than a power yank. Never transcribed into the issue
  tracker — this paragraph is the only record of the idea.
- **`/run/novadeck/boot` was internally inconsistent on any boot that rewrites state — FIXED
  2026-07-28, after HW validation.** `write_state()` updated `STATE_GEN` but left
  `STATE_ACTIVE`/`STATE_PENDING`/`STATE_TRIES` at their pre-write values, and the handoff is emitted
  from those same variables — so a rollback boot reported the new `gen` alongside the *old*
  `pending`, reading as "a trial is still armed" when the ESP said otherwise. Reproduced on the
  destroy-B failover boot (`gen=10` beside `pending=b`, ESP correctly `pending=<none>`), so it was
  never rollback-specific: any path that wrote state showed it. Never functional — `novadeck-bootctl`
  takes `pending` from the ESP and only `slot`/`source` from the handoff — but the init header calls
  this file the first evidence to check when debugging a boot offline, and it misled on exactly the
  boots that most need debugging. Held until after HW validation on purpose, one variable at a time.

  The fix advances all four parsed fields on a successful write, so the handoff describes the ESP
  *as it stands at switch_root*. Two things fell out of it. The try branch had to capture `pending`
  and the decremented count **before** the call, or it would have decremented twice — the hazard
  the old code avoided only by never updating those variables. And the standalone `TRIES_LEFT` is
  gone: it existed to carry a value the state itself now holds, and a second variable tracking the
  same fact is how the skew got in. On the boots that write nothing (`esp=ro`, `esp=none`) the
  read values are still what is on the card, so the invariant holds there without a special case.
  `images/initramfs/test-slot-state.sh` asserts handoff-mirrors-ESP on every write path; reverting
  the one-line fix fails 6 of its 56 checks, including the exact `pending=b` vs `pending=''` skew
  that hardware showed.

---

## 4c — bootstrap the root from packages

### Where we are

4a changed what the root still *contains*; it never changed where the root *comes from*.
The tree still originates as `docker export` of the digest-pinned vendor image
(`base.digest`), and everything after that layers on top. The lock records the
consequence honestly: **116 of its 398 rows are class `base`** — packages that arrived as
image content, with no package file to install and therefore no sha256 to verify.
`images/fetchlock.sh` can only check the other 282.

That is not a reproducibility hole. `base.digest` is a real byte-level pin, and a rebuild
gets the same bytes. It is an **opacity** hole and an **inherited-content** one: ~29% of
the shipped image sits outside the reviewable lock as wholesale trust, and whatever else
the vendor's pipeline put in that image ships with us. `images/provenance.list` exists
only to name the parts of that inheritance we have found and delete
(`/.dockerenv`, `repos`, `etc/mash-ci-tracking.job_id`) — it is the maintenance tax of the
export bootstrap, and it can only ever cover what an audit has already noticed.

### Target

`pacman -r <empty-dir> -Sy` against the pinned snapshot, so:

- every row becomes `snapshot` / `novadeck` / `prebuilt` and the lock covers 398/398;
- `base.digest`, `sanitize_base_provenance()` and `images/provenance.list` are all deleted
  rather than maintained;
- `/.dockerenv` never exists in the target root to begin with.

Docker stays the **execution environment** — the install runs arm64 binaries under qemu
binfmt, so a container is still how we get an arm64 userspace on an x86 host. It just
stops being the **content source**. The pinned `base-devel` image already plays that role
for `packages/build-overlay.sh`; 4c points `customize-base.sh` at the same pin, which is
what lets `base.digest` go away entirely rather than being renamed.

### Feasibility — measured 2026-07-26

**Unowned-file sweep of the pinned base.** A bootstrap reproduces only what packages lay
down, so anything in the base that no package owns would vanish silently. 31,203 files,
30,012 package-owned, **917 unowned** after filtering runtime/DB noise. Of those, ~896 are
`etc/ssl/certs/**` plus `etc/udev/hwdb.bin`, regenerated by the same install hooks a
bootstrap runs — not losses. The rest are `passwd-`/`group-`/`.pwd.lock` backups
(recreated), `etc/pacman.d/gnupg/**` (stripped by the seal anyway), and two probable
`tar -t` escaping artifacts (`system-systemd\x2d{crypt,verity}setup.slice`).

**The genuine must-handle set is three**, all identity files the vendor wrote by hand and
no package owns: `etc/os-release`, `etc/locale.conf`, `etc/hostname`.

**Closure check.** `pacman -r <empty> -Sy base <PKGS> libiio` against the pinned snapshot
plus the local `[novadeck]` repo resolves **394 packages that match `images/manifest.lock`
name-for-name and version-for-version** — the exact set the export-plus-install path
produces today. The bootstrap is not an approximation of the current image; it is the same
image by a reviewable route.

That check found the one real blocker, now fixed
(`fix(overlay): keep makepkg's downloaded sources out of the local repo`): the overlay repo
had six x86_64 packages in it — the sysroot `packages/fex-emu` downloads in `prepare()` —
indexed as installable `[novadeck]` packages. Invisible on the export path because those
names arrive already installed, but a bootstrap resolved the overlay's glibc 2.43 over the
snapshot's 2.42.

### Decisions

**The bootstrap declaration is the `base` metapackage plus the existing `PKGS`.** `base` is
what the vendor image's own root is built from, so declaring it keeps the shipped set
identical (measured above) instead of hand-reconstructing a "minimal" list that would drift
from upstream on every bump. It also means `pacman` and `archlinux-keyring` still arrive —
they are `base` dependencies — and the 4a seal still removes them. 4c changes where content
comes from, not what it contains.

*Rejected:* declaring `base`'s dependencies individually minus `pacman`, so the package
manager is never installed and the seal becomes unnecessary. It is tempting and it would be
smaller on disk, but it trades a reviewed 116-row diff for a hand-maintained fork of
upstream's base set, and it deletes the seal's defence-in-depth (the guard's assertions 1
and 2) rather than satisfying it. Worth revisiting only if the seal ever becomes the thing
that is hard to maintain.

**`stripped` rows become installable.** Today a `stripped` row is a `base` row the seal
deletes, so `fetchlock.sh` skips it — there is no file. After 4c the four of them
(`pacman`, `pacman-mirrorlist`, `gnupg`, `archlinux-keyring`) are ordinary snapshot
downloads that get installed and then deleted from the release tree. So the class keeps
meaning "in the build tree, not on the image" but now also carries a real sha256, and
`fetchlock.sh` installs it exactly like `snapshot`. `genmanifest.sh` loses its refusal to
mark an installable row `stripped`; that refusal existed to stop the lock hiding a package
that was never fetched, and the fetch path is what changes here.

**The `base` class is deleted, not left empty.** A row with no package file now means
something reached the tree outside the install path, so `genmanifest.sh` fails on it rather
than recording `-`. That is the whole point of the phase: after 4c there is no legitimate
way for a file to be on the image without a package that put it there.

**We own the three identity files.** `filesystem` ships `/usr/lib/os-release` and points
`/etc/os-release` at it, so a bootstrap that does nothing would ship holo's identity string
— which is arguably a bug in what we ship today, independent of 4c. `images/os-release`
becomes a committed declaration installed over the symlink at bootstrap time (the `/etc`
override is exactly what os-release's spec is for), alongside a one-line `/etc/locale.conf`
and an `/etc/hostname` that finally says `novadeck` instead of being a 0-byte stub the
vendor left behind.

**`images/provenance.list` and the guard's assertion 4 are both deleted.** Nothing is
inherited any more, so `sanitize_base_provenance()` goes — and so does the declaration it
consumed, along with the assertion that checked it.

Keeping the assertion as cheap regression insurance was considered and rejected. This repo's
standard for an assertion is that something can trip it: `provenance.list`'s own header made
the point ("a typo'd path — absent from every tree, so asserted by nobody, forever"), and
assertion 2 is deliberately self-checking for exactly that reason. Post-4c no marker can be
present in any tree, which removes the mechanism that kept these entries honest and leaves a
check that can only ever pass. The `/.dockerenv` failure is genuinely expensive
(`systemd-detect-virt` reports a container on the real device and systemd silently skips ~13
`ConditionVirtualization=!container` units) — but it had exactly one producer, `docker
export`, and reintroducing it would be an architectural change, not an accident.

**Named, because 4c does not close it:** `packages/inputplumber`'s prebuilt tarball is still
unpacked at `/` with `strip-components=1`, so a third-party archive can still place arbitrary
paths in the root. Two marker names were never a guard for that. The real guard is an
assertion that every file in the tree is package-owned or declared — tracked as
[#35](https://github.com/Nova-Deck/os-build/issues/35) and
[#36](https://github.com/Nova-Deck/os-build/issues/36).
