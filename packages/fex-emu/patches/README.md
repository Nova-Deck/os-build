# FEX patches

`0001`/`0005` are **build fixes for aarch64 + clang**, not behaviour changes, and both are still
required at FEX-2608 (`e869aa6`). Neither is upstream — re-verified absent from the FEX-2608 tree
on 2026-08-06 (`FEXCore/Source/CMakeLists.txt` has no `set_source_files_properties` for
`InterpreterFallbacks.cpp`; `ThunkLibs/include/common/Host.h` has no `signed char*` conversion).
`0006` is our one **behaviour fix** (issue #49), an upstream candidate.

`0001`/`0005` are numbered to match the upstream patch series they came from (a Qualcomm-handheld
distro's FEX package); the gaps are not missing files.

## `0001-fexcore-aarch64-workaround-llvm18-ice.patch`

Compiles `InterpreterFallbacks.cpp` at `-O0 -fno-lto`. Without it clang hits an internal compiler
error building FEXCore for aarch64. Named for LLVM 18, but the ICE was still reproducing on a
clang-21 toolchain: the peer this came from bumped to FEX-2607, removed both patches, and had to
add them straight back. FEX-2608 touches this file (it adds `SharedCodeBufferManager.cpp` to
`SRCS`), but nowhere near the hunk — the patch still applies at its recorded offset.

The cost is real but contained — one translation unit of the *interpreter fallback* path drops to
`-O0`. That path only runs for instructions the JIT declines to compile.

## `0005-host-thunks-aarch64-char-signed-char.patch`

`char` is **unsigned** on aarch64, so `guest_layout<char*>` template specialisations do not satisfy
overload resolution when a thunked function is declared with `signed char*`. Adds the two missing
conversion operators to `ThunkLibs/include/common/Host.h`.

Only bites when building the thunks (`BUILD_THUNKS=ON`), which we do — so it is not optional here
even though a thunk-less FEX would compile without it.

## `0006-thunk-overlays-arch-style-lib-prefixes.patch`

Behaviour fix (issue #49), HW-diagnosed 2026-08-19. On a **non-multiarch** guest rootfs,
`FileManager::LoadThunkDatabase` generates thunk overlay path prefixes Fedora-style only
(`lib64/` for 64-bit, `lib/` for 32-bit). Our guest is Arch-layout: `/usr/lib` is the canonical
64-bit dir (`lib64` is a symlink) and 32-bit lives in `/usr/lib32` — so the guest ld.so never
opens a path the overlay map keys, and **every enabled 64-bit thunk is a silent no-op**. Proven
both ways on Super Meat Boy amd64 under system-FEX: `ThunksDB {"GL": 1}` delivered with no
engagement; the same launch with `LD_LIBRARY_PATH=/usr/lib64` (forcing the Fedora spelling)
loaded `libGL-guest.so` and forwarded to the host.

The patch generates both spellings in both bitness modes. Extra prefixes are harmless where the
layout doesn't use them: overlay keys nothing ever opens are never consulted.

Upstream candidate — it also fixes Steam's own per-title thunk toggles (Valve's compat tool) for
any Arch-layout guest, though only once Valve's FEX builds carry it. Drop when upstream takes it.

## Bumping FEX

Re-verify both against the new tree before changing the pin:

```sh
git -C <fex-checkout> checkout FEX-<ver>
git apply --check -p1 packages/fex-emu/patches/*.patch
```

Drop a patch only once it is genuinely upstream (`grep` the tree), not merely because a newer
compiler *should* have fixed it — that is precisely the mistake that had to be reverted above.
