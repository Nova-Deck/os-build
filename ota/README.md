# ota/

Getting a built image **onto a device that is already in someone's hands**: the signed RAUC
bundle, the server that serves it, and the publishing paths that put artefacts in the bucket.
What is inside the root is `rootfs/`; laying it onto a disk is `image/`.

Updates are A/B and atomic (RAUC + Btrfs read-only root). A slot switch carries `/etc` with it,
because `/etc` is an overlay whose upper dir lives on the per-slot `/var` — which is why the
post-install hook rsyncs `/var` across on update
(`fs-overlay/usr/lib/rauc/post-install.sh`; rationale and HW evidence in `DONE.md`).

## The bundle

| File | Purpose |
|---|---|
| `genbundle.sh [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Dev builds mint an ephemeral cert; release builds pass `RAUC_CERT`/`RAUC_KEY`. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@VERSION@`; `compatible=novadeck`). |
| `rauc/verify-signing.sh` | The signing self-test. Every case is a negative — it feeds a deliberately broken config or cert profile through the shipped `system.conf` and asserts the verification refuses it. `make test-signing` (container-only: it signs real bundles, so it needs rauc). Covered in turn by `tests/test-verify-signing.sh`, which proves those negatives still bite. |
| `rauc/release.cert.pem`, `release.ext` | The release signing profile. Note the `.gitignore` carve-out: every PEM under `rauc/` is asserted to carry no PRIVATE KEY by `tests/test-verify-signing.sh`, so the exception is policed by a test rather than by care. |

## Publishing

| File | Purpose |
|---|---|
| `publish-bundle.sh` | Publish a signed bundle plus its update index, so a device's `novadeck-update` can see it. |
| `publish-card.sh` | Publish a full card image (the download a new user flashes), with its bucket prefix and prune policy. |
| `lib-rclone.sh` + `rclone.pin` | Sourced, never executed. The pinned rclone and the one place that builds its arguments, so a publish cannot differ between the two publishers. |
| `r2-preflight.sh` | Check the bucket credentials and layout answer before a release run starts uploading. |

## The server

| File | Purpose |
|---|---|
| `setup-server.sh` | Provision the OTA host from scratch. |
| `setup-ci-user.sh` | Provision the restricted account CI publishes as. |
| `nginx-novadeck-ota.conf` | The vhost that serves bundles and the update index. |
| `ci-publish.pub` | The public half of the CI publishing key. |

Note that a green release workflow run does **not** by itself mean anything was published —
check the bucket.

_Phase 5._
