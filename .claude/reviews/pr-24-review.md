# PR Review: #24 — Internal install, Phases 0–2

**Reviewed**: 2026-08-07
**Author**: Philippe Simons
**Branch**: `install/probe-internal` → `main`
**Decision**: COMMENT (self-review — see Independence below)

## Independence

This review was produced by the same agent that designed and wrote the change, chose what to
test, and reported the results. It is a checklist self-audit, not an independent read. It can
catch execution defects; it cannot catch the class of problem where the flaw is in the judgment
that produced both the code and its tests. Two examples from the implementation session where a
human caught what the agent did not: the decision to build a baseline card from `main` before
testing the branch (which turned out to be the run covering every device in the field), and an
overstated "finding" about a missing `parts.env` that was in fact designed behaviour. Weight this
document accordingly.

## Summary

No CRITICAL or HIGH findings. The change is additive — new files, a factored-out library, no
destructive operation. The extraction's behaviour-preservation is backed by an unchanged
`test-post-install.sh` count (127/0 before and after) and by two hardware OTA runs. Two MEDIUM
items are latent rather than live: both are traps set for Phase 4 rather than defects today.

## Findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM

**M1 — `seed_var` unconditionally clears the caller's EXIT trap.**
`fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh:226` runs `trap - EXIT` on its success path,
after setting its own at :169. If a caller already had an EXIT trap installed, `seed_var` destroys
it silently and the caller's cleanup never runs.

Not a live defect: the only caller today is `post-install.sh:168`, and that script's first `trap`
is at :175 — *after* the call. Verified by reading the call order, not assumed.

It will bite Phase 4. The installer works on a foreign disk with mountpoints under `/run` and will
almost certainly hold an EXIT trap for its own cleanup across the whole run; `seed_var` would
disarm it mid-install, and the symptom would be leaked mounts on a failure path — exactly when
cleanup matters. Fix is to save and restore rather than clear: capture `trap -p EXIT` on entry and
re-install it, or push the mount/unmount responsibility to the caller.

**M2 — `NOVADECK_APPEND_FLOOR` is opt-in, and it is the containment rail.**
`images/genpart.sh:106` refuses only when the caller supplied a floor. Unset, `--append` will place
partitions in whatever the largest free block is — which on a disk whose freed `userdata` tail is
*not* the largest free block means our ESP lands somewhere unintended. Phase 3's paramount assertion
(every sector written lies inside the old `userdata` span) then holds by luck.

Correct for the current callers, all of which are tests. Before Phase 3 wires a real target, the
floor should be mandatory whenever `--append` is given a device, so the safe path is the default
rather than a thing the caller must remember.

### LOW

**L1 — dead local.** `lib-slotwrite.sh:105` declares `local line name idx key`; `line` is never
used.

**L2 — `refresh_if_diff` reads the `$SHA256` global.** The file's own header states that primitives
"take explicit arguments and touch nothing implicitly", and this one does not. It is documented and
deliberate (it is the seam the offline suite drives), but it is an exception to a stated rule and
worth either parameterising or noting in the header as an acknowledged carve-out.

## Not defects — investigated and cleared

- **`set -e` on the guard's success-path `&&`.** `images/guard-rootfs.sh` ends its seed block with
  `[ "$seed_bad" = 0 ] && echo …`. Suspected this would abort the guard mid-run under
  `set -euo pipefail` when a bad seed was detected, skipping later assertions. Reproduced in
  isolation: it does not — the failing test is exempt as a non-final member of an `&&` list, the
  script continues, and `fail=1` propagates to the exit status. Raised because a related idiom has
  bitten this repo before (`compgen -G` on a guard success path); the mechanism differs.

## Validation

| Check | Result |
|---|---|
| Lint / typecheck | N/A — shell + make repo; `bash -n` clean on all changed scripts |
| Tests (`make test`, 9 suites) | **Pass** — exit 0; `test-install.sh` 98/0/0, `test-post-install.sh` 127/0 |
| Build (dev) | **Pass** — card + signed bundle |
| Build (release) | **Pass** — the only mode that runs `guard-rootfs.sh`; all four installer-artifact assertions green |
| CI | **Pass** — zero skipped cases, confirming `grub-common` and `zstd` took effect |
| Hardware | **Pass** — OTA main→branch (old hook), branch→branch (extracted hook), fresh branch card; all three slots booted |

## Coverage gaps carried forward

Stated in the PR body, repeated here so they are not lost:

- `seed_var`'s **tarball branch and `tar -p` have never executed** — the OTA path always takes the
  directory branch. Built, verified, listed and mode-checked; never unpacked.
- `mkfs_esp` and `mint_partsets` have **no caller** until Phase 4. `mkfs_esp` has no offline
  coverage by construction; its test asserts only that it is defined.
- No **release card** has been built or booted — only the release rootfs. The release-mode delta is
  four files plus `/var` pack ordering, both guard-verified, so risk is low but not zero.

## Files reviewed

| File | Change |
|---|---|
| `fs-overlay/usr/lib/novadeck/install/lib-slotwrite.sh` | Added (356) |
| `fs-overlay/usr/lib/rauc/post-install.sh` | Modified (−90 net) |
| `images/assemble-rootfs.sh` | Modified — `/var` block moved above the guard |
| `images/guard-rootfs.sh` | Modified — installer-artifact assertions |
| `images/genpart.sh` | Modified — table seam + `--append` |
| `images/make-sdcard.sh` | Modified — consumes `grubenv` instead of minting |
| `boot/grub.sh` | Modified — emits `grubenv` |
| `build/Dockerfile` | Modified — `zstd` |
| `install/test-install.sh` | Added/extended — 98 cases |
| `install/probe-internal.sh`, `docs/internal-storage.md` | Added — Phase 0 |
| `boot/gen-grub-cfg.sh`, `images/initramfs/init`, plan/docs | Modified — Phase 1 |
