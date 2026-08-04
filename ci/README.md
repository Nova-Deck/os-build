# ci/

## Today: `.github/workflows/ci.yml`

Two jobs, no secrets, on every push and pull request:

| job | what it runs | needs |
|---|---|---|
| `test` | `make test` — 354 checks across the initramfs slot-state reader, `novadeck-bootctl`, and the RAUC post-install hook | nothing (host shell) |
| `signing` | `make test-signing` — every case a negative against `images/rauc/verify-signing.sh` | `build/Dockerfile`'s `signing` stage (rauc + openssl + mksquashfs, ~66 MB) |

## Today: `.github/workflows/overlay.yml` — the package compile pass

Builds the from-source overlay packages a **pull request** touches, to prove they still compile.
It publishes nothing and needs no secrets. Triggered by a change to any overlay input
(`packages/*/source.pin`, its patches, a local `PKGBUILD`, `build-overlay.sh`, `inputhash.sh`,
`base-devel.digest`), plus `workflow_dispatch`.

| job | runner | what it runs |
|---|---|---|
| `plan` | x86 | `verify-lock-rows.sh`, then a `git diff` against the base ref → the build matrix |
| `build` | `ubuntu-24.04-arm` | one job per *changed* package: `build-overlay.sh --only <pkg> --no-index` |

Three properties this leans on:

- **Native aarch64, so no emulation.** `build-overlay.sh`'s own binfmt probe passes and it never
  registers qemu or needs `--privileged`. `vars.OVERLAY_RUNNER` overrides the label; do **not**
  point it at a self-hosted runner while this repo is public.
- **Fork PRs run it fine**, now that nothing is published: `contents: read`, no secrets, no registry.
- **Unknown scope widens the check.** A dispatch with no diff base, or a change to the builder
  itself, selects every package rather than none.

Not triggered by a push to `main`: a PR already built what it changed, and a direct-to-`main` package
edit is caught by the next release build. `workflow_dispatch` forces a pass over a branch that never
saw a PR.

### What used to be here

Until 2026-08-04 this workflow was a build-once-and-cache pipeline: it published every package to
GHCR keyed by `packages/inputhash.sh`, ran a `verify` job asserting a cold machine could reconstitute
the repo with zero compiles, and opened a **pin-bump PR** carrying each artifact's sha256 into
`packages/*/artifact.pin` — which a release build then enforced. It needed two PATs (`PIN_BUMP_PAT`,
`GHCR_PRUNE_TOKEN`), a pinned `oras`, and a prune job.

It was retired because its premise was a **dev-box** number. An overlay build costs ~4h under arm64
emulation on a workstation (`fex-emu` alone ~2h), and the store existed so nothing paid that twice.
CI never paid it: on `ubuntu-24.04-arm` the eight packages measured `gtk2 7m, sddm 5m, mesa 5m,
fex-emu 5m, gamescope 4m, scx-scheds 4m, mangohud 3m, rauc 1m` — **~34 minutes for the set**, against
a release card build that already ran 33–41 minutes. Both PAT secrets can be deleted; nothing reads
them. If reintroducing a cache is ever proposed, re-measure those figures first.

The signing job checks the committed keyring (`images/rauc/novadeck-ca.pem`) against the committed
release certificate (`images/rauc/release.cert.pem`). Both are public, so it runs on a fork's PR
with access to nothing. The private half — does the signing *key* match that cert — announces
itself as skipped there and runs wherever a PKI is mounted:

    PKIDIR=~/novadeck-pki make test-signing

## Today: the release image builds

`.github/workflows/image.yml` is a `workflow_call`-only builder: `make overlay` (~34 min, compiled
in-run) → `make toolchain` → `make sdcard` or `make bundle`, with `df -h` into the step summary.
work/ peaks near 30 GB and out/ near 21 GB against ~109 G free on the runner, measured by
`preflight.yml` — there is room, and an earlier design that deleted each stage's inputs as it went
was reverted as cleverness bought against a limit that is not there. Two thin callers invoke it on
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
the Release carries only `sha256sums.txt`, `manifest.lock` and the link.

**CI is the only thing that PUBLISHES a release image**, because the R2 and signing credentials live
here. Building one is not restricted: `make sdcard` with no `NOVADECK_DEV` produces a real release
image on a dev box, which is how OOBE gets tested on hardware. That was not true until 2026-08-04,
when the artifact-pin gate was retired along with the store.

The blocker that once made a release build impossible on a clean runner is worth recording. A clean
runner has no `work/`, so it rebuilt the overlay, and because our builds are not bit-reproducible
`images/fetchlock.sh` failed every run — the lock pinned those rows to artifact bytes only the last
`make relock` machine could reproduce. The lock now pins them to their **sources**, which is the
claim that survives crossing a machine. A release image's overlay is compiled in the same run that
publishes it, so those source pins are also its byte provenance. See `packages/README.md`.

## Not here yet, and why

**Bundle signing.** `release-bundle.yml` builds, but with an ephemeral dev cert — it proves the
bundle assembles and the verity hashes compute, while producing something every device will
reject. The remaining decision is whether the release private key belongs in GitHub at
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
