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
| `pin-bump` | x86 | `main` only: applies the pins `verify` recorded and opens the **pin-bump PR**. Needs a `PIN_BUMP_PAT` secret and **fails without one** |
| `prune` | x86 | optional housekeeping; needs a `GHCR_PRUNE_TOKEN` PAT, announces itself as skipped without one |

The two PATs are deliberately opposite about a missing secret. `prune` is housekeeping on packages
nothing meters, so it announces itself as skipped and lets the run pass. `pin-bump` *is* the
provenance mechanism, so an absent secret is an error — the failure mode to avoid is a green job that
pushed a branch and opened nothing, which this job has already produced twice (an inherited job skip,
then a `git diff` blind to untracked files).

`PIN_BUMP_PAT` should be a fine-grained PAT scoped to **this repo only**, with **Pull requests:
read+write** and nothing else; it is used for the single `gh pr create` call. The branch push uses
`GITHUB_TOKEN` (`contents: write`), so the stronger credential never touches the operation that
writes to the repo. The alternative — letting `GITHUB_TOKEN` open the PR — requires the *organisation*
setting "Allow GitHub Actions to create and approve pull requests", which cannot be narrowed: it is
org-wide, covers every repo, and grants **approve** as well as create, so any workflow in the org
could satisfy a required-review branch protection on its own. For a mechanism whose whole premise is
that a human reviewed the pins, that is the wrong trade. It also has a practical cost: a PR opened by
`GITHUB_TOKEN` triggers no workflows, so the pin PR arrives with no checks. A PAT-opened one runs `ci`.

A fine-grained PAT expires. When it does, `pin-bump` fails loudly on the next `main` run that changes
a pin — which is the intended behaviour, but budget for the renewal rather than being surprised by it.

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

## Today: the release image builds

`.github/workflows/image.yml` is a `workflow_call`-only builder — `overlay-pull --require-all` →
`make overlay` → `make verify-pins` → the build, walked **target by target** rather than as one
`make sdcard`: work/ peaks near 30 GB and out/ near 21 GB, so each stage's inputs are deleted once
its output exists (kernel tree ~14 G, base+prebuilt ~11 G, intermediate images ~13 G), with `df -h`
after each into the step summary. Two thin callers invoke it on
their own triggers, because a flashable card and a field update are wanted at different cadences:

| workflow | trigger | secrets | ships to |
|---|---|---|---|
| `release-sdcard.yml` | `card/v*` tag, or manual | `R2_*` (push-only, public bucket) | Cloudflare R2 + a GitHub Release carrying checksums/provenance |
| `release-bundle.yml` | `ota/v*` tag, or manual | none *yet* (unsigned smoke test; see below) | workflow artifact; the Oracle Cloud OTA host is not wired up yet |

**The tag namespaces are separate on purpose.** A bundle ships far more often than a card, so each
gets its own namespace rather than sharing a bare `v*`. That also fixes a real inversion: while
`release-sdcard.yml` owned `v*` alone and `release-bundle.yml` had no tag trigger, tagging a release
built a card and *never* a bundle. `card/v1.3.0` and `ota/v1.3.0` on one commit are the same OS
delivered two ways.

**A card is ~9 GiB, which is why it is not a release asset** — GitHub caps those at 2 GiB. It goes to
a public R2 bucket (`images/publish-card.sh`, retention N=1 to stay inside the 10 GB free tier) and
the Release carries only `sha256sums.txt`, the provenance pins and the link.

**CI is the only producer of a release image, and that is the point.** A release build enforces
`packages/*/artifact.pin` (via the Makefile's `PINNED` gate → `packages/verify-pins.sh`), and locally
built overlay bytes will never match a published sha because our builds are not bit-reproducible. So
`make sdcard` on a dev box now fails that gate by design; `NOVADECK_DEV=1 make sdcard` is the dev
path and is untouched by any of this. Verifying OOBE on a genuine release image means flashing the
artifact `release-sdcard.yml` produces.

Both of the old blockers are gone, and worth recording because they were different problems. The
*lock* half: a clean runner has no `work/`, so it rebuilt the overlay, and non-reproducible builds
failed `images/fetchlock.sh` every run because the lock pinned those rows to artifact bytes only the
last `make relock` machine could reproduce. The lock now pins them to their **sources**. The *cost*
half: the package store above means a cold runner retrieves rather than compiles. What used to be
listed here as the still-open **byte** claim is now closed from the other side — not by putting bytes
back in the lock, but by `artifact.pin` + the pin-bump PR, so the two claims live in separate files
with separate lifetimes. See `packages/README.md`.

## Not here yet, and why

**Bundle signing.** `release-bundle.yml` builds, but with an ephemeral dev cert — it proves the
bundle assembles, the verity hashes compute and the pin gate passed, while producing something every
device will reject. The remaining decision is whether the release private key belongs in GitHub at
all; `image.yml` already accepts `RAUC_CERT_PEM` / `RAUC_KEY_PEM` and signs when both are present,
warning loudly when they are not. The shape is settled by the PKI:

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
