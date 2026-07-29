# ci/

## Today: `.github/workflows/ci.yml`

Two jobs, no secrets, on every push and pull request:

| job | what it runs | needs |
|---|---|---|
| `test` | `make test` — 354 checks across the initramfs slot-state reader, `novadeck-bootctl`, and the RAUC post-install hook | nothing (host shell) |
| `signing` | `make test-signing` — every case a negative against `images/rauc/verify-signing.sh` | the `novadeck-build` container, for `rauc` |

The signing job checks the committed keyring (`images/rauc/novadeck-ca.pem`) against the committed
release certificate (`images/rauc/release.cert.pem`). Both are public, so it runs on a fork's PR
with access to nothing. The private half — does the signing *key* match that cert — announces
itself as skipped there and runs wherever a PKI is mounted:

    PKIDIR=~/novadeck-pki make test-signing

## Not here yet, and why

**The image build.** The *lock* half of this is fixed. A clean runner has no `work/`, so it rebuilds
the from-source overlay packages, and those builds are not bit-reproducible — which used to fail
`images/fetchlock.sh` on every single run, because the lock pinned those rows to artifact bytes that
only the machine that last ran `make relock` could reproduce. `images/manifest.lock` now pins them to
their **sources** instead (`packages/inputhash.sh` over `source.pin` + patches + `PKGBUILD`), so a
rebuild from unchanged sources is not a lock change and a clean runner verifies exactly like the
machine that wrote the lock. CI never has to mutate a reviewed artifact to get green.

What is left is cost, not correctness: rebuilding every overlay package under qemu is the most
expensive thing in this build (`fex-emu` dominates), and a runner starts cold every time. So the open
question for landing `make sdcard` in CI is where the overlay artifacts come from — which is the
same question the successor TODO item answers by publishing them as sha-pinned `prebuilt` rows from
a separate package pipeline, restoring a byte-level claim as a side effect.

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
