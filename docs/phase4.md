# Phase 4 — sealed manifest rootfs + A/B atomic updates

Phase 4 turns the image from "a rootfs we assembled with a package manager" into "a
declared artifact that can be replaced atomically and rolled back". It splits into two
independent halves, deliberately sequenced:

| Half | Scope | Can it brick a device? |
|---|---|---|
| **4a** — sealed manifest rootfs | how the root is *built* and what it still contains | No. A bad build fails to boot a card you reflash. |
| **4b** — A/B atomic updates | how a built root is *shipped and switched* | Yes. Touches the boot path. |

4a lands first, alone. It is the prerequisite that makes an A/B update meaningful: there
is no point atomically replacing a root that still carries a live package manager able to
mutate it in place.

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

**Decision: test-only tooling stays out of the lock and installs by name.** `TEST_PKGS` (`evtest`,
`usbutils`) are `pacman -Sy`'d under `NOVADECK_TEST=1` even in locked mode. The lock describes the
*release* image — the tree the step-4 guard runs against — so locking test tooling would overstate
what ships. `customize-base.sh` records `test:1` in the marker and `genmanifest.sh` refuses to
relock a test base, rather than filtering by a package-name blocklist that would drift from
`TEST_PKGS`.

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

**Decision: on-device `pacman` is kept under `NOVADECK_TEST=1` and stripped from release.**
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
and carries `TEST_PKGS` the lock does not describe.

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

---

## 4b — A/B atomic updates

### What already exists

The partition layout is in place and documented (`images/partition-table.txt`): shared
ESP, `efi-a`/`efi-b`, `rootfs-a`/`rootfs-b` (7G, read-only btrfs), `var-a`/`var-b`, shared
`home`. `make sdcard` populates the A side only; the B slots and both `efi-*` partitions
are created, formatted and left empty. Bundle generation exists too —
`images/genbundle.sh`, `images/rauc/manifest.raucm.in`, `make bundle`.

What does **not** exist: `rauc` on the device (not in `PKGS`, no `/etc/rauc/system.conf`,
no keyring), and confirmation that `rauc` is present in the build image.

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

### Hard prerequisite, independent of the design

`/var` is per-slot, and both the `/etc` overlay upperdir (`/var/lib/overlays/etc/upper`)
and the Wi-Fi MAC derived from `machine-id` ride on it. Booting the other slot therefore
presents a *different* `/etc`: no saved Wi-Fi, a fresh `machine-id`, and hence a silently
different MAC. The post-install hook must reformat the target slot's `/var`, copy the
running slot's `/var` across, and write network connections into both slots' overlay
uppers. This is required under A, B and C alike.

### Sketch of the work

1. `rauc` available in the build image and on the device (repo package if one exists in
   the snapshot, otherwise a from-source `packages/rauc/` like the other overlay builds).
2. Device config: `/etc/rauc/system.conf` describing the two slot groups, plus the release
   keyring. Signing keys live in CI, never the tree.
3. Slot-state file on the ESP (vfat, writable from both the initramfs and the running
   system): active slot, pending slot, try counter, previous kernel marker.
4. `images/initramfs/init`: read the state file, select root/var, decrement the try
   counter, fall back to the other slot at zero. Keep the existing degrade-loudly
   discipline — this device has no serial console, so every new failure path must log to
   `/dev/kmsg` and continue rather than die silently.
5. Health-check unit that marks the boot good (session up), and restores `KERNEL.bak` +
   the previous slot when it does not.
6. `/var` migration hook (above).
7. Wire an update entry point to the system-manager D-Bus surface so the UI's software
   update path is real rather than stubbed.
