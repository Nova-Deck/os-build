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

**2. Install from the lock.**
Replace `pacman -Sy <names>` with an explicit install of lock-resolved package files
(sha256-verified host-side, reusing the persistent `work/pacman-cache`). Dependency
resolution stops happening implicitly at build time; the lock is regenerated only by an
explicit `make relock`.

**3. Seal — strip the package manager.**
After install, remove `pacman`, `gnupg`/`dirmngr`, the keyring package and its timer,
`/var/lib/pacman/` and `/etc/pacman.d/gnupg` from the release root. The local package DB
is preserved as provenance under `/usr/lib/novadeck/`, outside any path the package
manager would consult. This is the step that removes the shutdown stall — by deleting the
daemon rather than masking it.

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

**4. Guard.**
Assert on the **built tree**, not on the source diff: no `usr/bin/pacman`, no `dirmngr`,
no vendor units left in `timers.target.wants`, plus a size-delta report. This repo has
already been bitten once by trusting a built tree it never inspected (a file-mode
regression that reached hardware), so the assertion is the deliverable, not a nicety.

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
