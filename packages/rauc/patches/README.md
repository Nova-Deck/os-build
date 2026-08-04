# CI smoke test — DO NOT MERGE

This file exists to exercise `.github/workflows/overlay.yml`'s compile pass end to end:
it matches the workflow's `packages/*/patches/**` path filter and the `plan` job's
`git diff` selection, so the PR should build **rauc and nothing else**.

It is deliberately NOT declared in `packages/rauc/source.pin`'s (absent) `patches:` field,
so `packages/inputhash.sh` does not see it and `images/manifest.lock` stays valid. A real
package change moves the input hash and must carry a `make relock` in the same commit.

rauc genuinely has no novadeck patches — see the header of `packages/rauc/source.pin`.
