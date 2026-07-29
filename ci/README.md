# ci/

## Today: `.github/workflows/ci.yml`

Two jobs, no secrets, on every push and pull request:

| job | what it runs | needs |
|---|---|---|
| `test` | `make test` — 354 checks across the initramfs slot-state reader, `novadeck-bootctl`, and the RAUC post-install hook | nothing (host shell) |
| `signing` | `make test-signing` — every case a negative against `images/rauc/verify-signing.sh` | the `novadeck-build` container, for `rauc` |

## Today: `.github/workflows/overlay.yml` — the package pipeline

Builds the from-source overlay packages and publishes them so nothing else has to build them.
Triggered by a change to any overlay input (`packages/*/source.pin`, its patches, a local
`PKGBUILD`, `base-devel.digest`), plus `workflow_dispatch` and `workflow_call`.

| job | runner | what it runs |
|---|---|---|
| `plan` | x86 | `overlay-store.sh plan` — the input hash of every package, against what the store already holds. Emits the build matrix. |
| `build` | `ubuntu-24.04-arm` | one job per *missing* package: `build-overlay.sh --only <pkg> --no-index`, then publish |
| `verify` | `ubuntu-24.04-arm` | `make overlay-pull && make overlay` on a clean workspace, asserting **zero compiles**, a real repo db, and that `fetchlock.sh` still verifies the untouched lock |
| `prune` | x86 | optional housekeeping; needs a `GHCR_PRUNE_TOKEN` PAT, announces itself as skipped without one |

Three properties this leans on:

- **The trigger key and the artifact key are the same value** — `packages/inputhash.sh`, which the
  lock already records. "Has this changed?" and "which artifact do I want?" have one answer, so an
  unchanged package is not a fast build but *no* build.
- **Native aarch64, so no emulation.** `build-overlay.sh`'s own binfmt probe passes and it never
  registers qemu or needs `--privileged`. `vars.OVERLAY_RUNNER` overrides the label; do **not**
  point it at a self-hosted runner while this repo is public.
- **Fork PRs do not run it.** A fork's token is read-only and could not publish; triggering on
  `push` means a fork PR skips the pipeline and its packages get built on merge.

`verify` is the job that matters to everything downstream: it is the automated form of "a cold
machine can reconstitute the overlay repo from the store without compiling", tested every run
rather than assumed.

The signing job checks the committed keyring (`images/rauc/novadeck-ca.pem`) against the committed
release certificate (`images/rauc/release.cert.pem`). Both are public, so it runs on a fork's PR
with access to nothing. The private half — does the signing *key* match that cert — announces
itself as skipped there and runs wherever a PKI is mounted:

    PKIDIR=~/novadeck-pki make test-signing

## Not here yet, and why

**The image build.** Both of its old blockers are now gone, and what remains is smaller than either.

The *lock* half was fixed first. A clean runner has no `work/`, so it rebuilds the from-source
overlay packages, and those builds are not bit-reproducible — which used to fail
`images/fetchlock.sh` on every single run, because the lock pinned those rows to artifact bytes that
only the machine that last ran `make relock` could reproduce. `images/manifest.lock` now pins them to
their **sources** instead (`packages/inputhash.sh` over `source.pin` + patches + `PKGBUILD`), so a
rebuild from unchanged sources is not a lock change and a clean runner verifies exactly like the
machine that wrote the lock. CI never has to mutate a reviewed artifact to get green.

The *cost* half is what the package pipeline above answers. A runner still starts cold, but it no
longer compiles: `make overlay-pull` retrieves the packages some earlier run already built, keyed by
the input hash the lock records, and `make overlay` then only re-indexes. The `verify` job proves
that path on every run. So an image build in CI is now a matter of wiring `overlay-pull` ahead of
`make sdcard` and finding out what the rest of the pipeline costs — not a hard block.

What is still genuinely open is the **byte** claim, not the cost. The lock attests these artifacts'
sources, not their bytes: anyone who can write `work/repo` can substitute one, and the store does
not change that (`oras pull` verifies what the registry holds, which is a different question from
what the lock reviewed). Closing it is the TODO item on promoting overlay output to sha-pinned rows
that `fetchlock.sh` fetches and verifies like `snapshot` — for which the store is the prerequisite,
now in place.

**Bundle signing.** `make bundle` needs the built rootfs, so it is blocked by the same thing. When
it lands, the shape is already settled by the PKI:

- **one secret**, the release signing key, scoped to a protected *environment* (not the repo, where
  any workflow on any branch can read it). Write it to `$RUNNER_TEMP`, never the workspace — the
  repo tree gets uploaded as artifacts and cached.
- `PKIDIR=$RUNNER_TEMP/pki make bundle` mounts it read-only at `/pki` and points `RAUC_CERT` /
  `RAUC_KEY` at it. Copy the committed `images/rauc/release.cert.pem` in alongside the key.
- `verify-signing.sh` then asserts the key matches the committed cert *as public-key digests*, so a
  stale or truncated secret fails there instead of producing bundles no device accepts.
- **the CA key never reaches a runner.** That is what the two-level PKI is for: if the release key
  leaks, mint a new cert offline under the same CA, commit it, update the one secret — no device is
  affected. See `ci/gen-signing-ca.sh`.
- worth considering before real releases: signing off-CI, or via an HSM/KMS the runner reaches by
  OIDC, so the key never exists as a file. A key that can push arbitrary code to devices with no
  serial console is a large thing to keep in a CI secret store.

**cosign-signed artifacts and published update manifests** — the original Phase 7 scope, CI
patterns borrowed from ublue-os/image-template, for the single unified image (SM8550 / SM8650 /
SM8750 in one kernel + boot artifact). All of it sits on top of a working image build. Runtime
stays SteamOS-native (RAUC / Btrfs).

## The standing caveat

CI green is not evidence about the device. The self-test runs the **build container's** rauc
against the shipped config; the device runs its own (`packages/rauc`). A 1.14-on-device /
1.15-in-container skew is exactly how the dm-verity install bug reached hardware. Only an on-device
`rauc install` is evidence about the device.
