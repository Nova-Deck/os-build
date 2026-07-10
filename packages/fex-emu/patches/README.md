# FEX patches

Both are **build fixes for aarch64 + clang**, not behaviour changes, and both are still required
at FEX-2607 (`1cc4b93`). Neither is upstream — verified absent from FEX `main` on 2026-07-10.

They are numbered `0001`/`0005` to match the numbering of the upstream patch series they came from
(a Qualcomm-handheld distro's FEX package); the gap is not a missing file.

## `0001-fexcore-aarch64-workaround-llvm18-ice.patch`

Compiles `InterpreterFallbacks.cpp` at `-O0 -fno-lto`. Without it clang hits an internal compiler
error building FEXCore for aarch64. Named for LLVM 18, but the ICE was still reproducing on a
clang-21 toolchain: the peer this came from bumped to FEX-2607, removed both patches, and had to
add them straight back.

The cost is real but contained — one translation unit of the *interpreter fallback* path drops to
`-O0`. That path only runs for instructions the JIT declines to compile.

## `0005-host-thunks-aarch64-char-signed-char.patch`

`char` is **unsigned** on aarch64, so `guest_layout<char*>` template specialisations do not satisfy
overload resolution when a thunked function is declared with `signed char*`. Adds the two missing
conversion operators to `ThunkLibs/include/common/Host.h`.

Only bites when building the thunks (`BUILD_THUNKS=ON`), which we do — so it is not optional here
even though a thunk-less FEX would compile without it.

## Bumping FEX

Re-verify both against the new tree before changing the pin:

```sh
git -C <fex-checkout> checkout FEX-<ver>
git apply --check -p1 packages/fex-emu/patches/*.patch
```

Drop a patch only once it is genuinely upstream (`grep` the tree), not merely because a newer
compiler *should* have fixed it — that is precisely the mistake that had to be reverted above.
