# Plan: adopt Valve's FEX compat tool, retire the system FEX

## Context

We build and ship our own FEX: `packages/fex-emu` (FEX-2607 from source, host+guest
thunks, an x86 sysroot assembled at build time) plus `packages/fex-rootfs` (a 1.82 GiB
`ArchLinux.ero` guest). It is by far the heaviest overlay package.

It serves exactly one purpose. Windows games run on the bundled arm64 Proton, which
carries its own WoW64 FEX and needs neither this package nor the guest rootfs — the two
x86 paths are independent (`docs/FEX_README.md`, `[[fex-two-paths-independent]]`). So the
system FEX exists only for **native x86 Linux ELFs**.

**Scope decision, 2026-08-05:** native x86 Linux binaries that do *not* come from Steam
are out of scope for NovaDeck. That collapses the system FEX's entire remaining job down
to "run x86 Linux games launched from Steam" — which is precisely the job Valve now ships
a first-party tool for.

On 2026-08-04 Valve published **FEX as Steam app `3127680`** alongside Lepton, as part of
making the Steam Frame software stack public. Frame is a Snapdragon 8 Gen 3 — the same
SoC as our SM8650 target.

---

## What Valve actually ships (verified 2026-08-05)

Verified by downloading the depot with an ordinary Steam account, on x86_64, via a
`steamcmd` copy in a scratchpad. Reproduction is in Appendix A.

`appid 3127680`, `common.type = Tool`, `oslist = linux`, `section_type = ownersonly`,
`config.installdir = FEX-Emu`. Two depots:

| depot | role | public | beta / gamma |
|---|---|---|---|
| `3127681` | guest rootfs | **0 bytes** | 3,945,426,115 (855 MiB dl) |
| `3127682` | FEX + thunks | 24,805,692 (5.75 MiB dl) | 27,867,164 |

### It is a Steam Play compat tool, not a system install

```
"manifest" {
  "commandline" "/fex-compat-tool %verb% --"
  "filter_exclusive_priority" "2"
  "compatmanager_layer_name" "fex"
  "use_tool_subprocess_reaper" "1"
  "version" "2"
}
```

Depot contents: `usr/bin/{FEX,FEXServer,FEXServerManager,FEXBash,FEXGetConfig,FEXOfflineCompiler,FEXpidof}`,
64- and 32-bit host thunks under `usr/lib/aarch64-linux-gnu/fex-emu/HostThunks{,_32}/`,
matching guest thunks, `ThunksDB.json`, `ConfigTemplate.json`, `emulator.json`,
`fex-compat-tool` (python), `FEXCompatTool`, `unshare.py`.

**No `FEXInterpreter`. No `binfmt.d`.** And `fex-compat-tool:130`:

```python
# Relatively new option to prevent FEX from checking system directories like /usr/share/fex-emu
os.environ["FEX_PORTABLE"] = '1'
```

It deliberately ignores a system FEX install. Our `fs-overlay/usr/share/fex-emu/Config.json`
would be bypassed entirely for Steam launches — keeping both is not "belt and braces", it
is dead weight.

Version: **`FEX-2607-76-g37265b1`** — 76 commits past the `FEX-2607` tag we pin. Same base,
no rebase risk.

### The guest rootfs is expected to come from the OS

`fex-compat-tool:13` (public branch):

```python
# OS provided fex + mesa combined arch linux install (the FEX-Emu/rootfs dir ends up not being needed at all in this case)
g_fex_rootfs_with_mesa = '/usr/share/guestos/fex-mesa'
```

`setup_rootfs()` returns that path unconditionally unless `STEAM_COMPAT_GRAPHICS_PROVIDER`
names a `graphics_provider.json`, in which case its dirname wins. There is no depot-rootfs
code path at all on public.

This is a recent, deliberate change. Ordered by `timeupdated`:

| branch | updated | rootfs depot | tool version |
|---|---|---|---|
| `previous` | ~Feb 2026 | 3,955,498,049 | — |
| `gamma` | ~Mar 2026 | 3,945,426,115 | — |
| `beta` | ~May 2026 | 3,945,426,115 | FEX-2604-97-ga04b024 |
| `public` | ~Jul 2026 | **0** | FEX-2607-76-g37265b1 |
| `bleeding-edge` | ~Aug 2026 | **0** | — |

The older `beta` tool still carries `mount_rootfs()` — overlayfs in a user namespace over a
depot-local `rootfs/`, optionally layering OS Mesa from `/usr/share/guestos/fex/rootfs`.
The newer `public` tool deleted that machinery, `g_fex_system_mesa`, and the `unshare`
import path along with it. The direction of travel is unambiguous: **the OS supplies the
guest.**

### Per-game tuning is already exposed

`generate_app_config()` reads `STEAM_FEX_TSOENABLED` / `STEAM_FEX_MULTIBLOCK` from appinfo,
plus a user override `STEAM_COMPAT_FEX_CONFIG` parsing `TSOEnabled:1`, `Multiblock:1`,
`ThunksDB_GL:1`, `ThunksDB_Vulkan:1`. That is our `fex-profiles.json` vocabulary — but
driven by a Valve-curated per-title database we cannot match.

### It is tuned for our GPU

`fex-compat-tool:133` defaults `tu_override_uncached_as_cache_coherent=true` — a
Turnip/Adreno workaround. Valve is tuning this path for our exact GPU family, and unlike
us it ships with thunks **enabled**.

---

## Decisions taken

| Axis | Choice |
|---|---|
| Adoption | Adopt Valve's compat tool as the native-x86-Linux path |
| Branch | **`public`**, not `beta` — see below |
| Guest rootfs | **OS-provided** at `/usr/share/guestos/fex-mesa` |
| Rootfs delivery | Mount the existing pinned `.ero` read-only; do **not** extract |
| `packages/fex-emu` | Drop entirely |
| `packages/fex-rootfs` | Keep pinned, relocate to the mount unit |
| `fs-overlay/usr/share/fex-emu/Config.json` | Drop — superseded by their `ConfigTemplate.json` |
| `fex-profiles.json` + `proton-wrapper` | **Keep** — they drive the Proton path, untouched here |

### Why not "tell users to opt into `beta`"

Considered and rejected. `beta` is the only branch still shipping a downloadable rootfs, so
it superficially lets us delete ours outright. But:

1. **It is older FEX** — `FEX-2604-97` against public's `FEX-2607-76`. We pin `FEX-2607`
   today, so it would ship users an *older* emulator than we currently build.
2. **It is the retired code path.** Public deleted `mount_rootfs()` and the depot-rootfs
   handling. Adopting the fallback as it is being removed is a guaranteed future migration.
3. **Disk gets worse.** 3.67 GiB extracted vs our 1.82 GiB compressed. It leaves the image
   (which is the binding constraint) but lands heavier on device storage, after we already
   fought for rootfs trim (`[[rootfs-trim-landed]]`).
4. **Unpinnable.** A Steam branch a user opts into cannot go in `manifest.lock`, cannot be
   verified in CI, and can change between our releases with no signal — against the whole
   pin discipline of this repo.
5. **A manual per-device opt-in** before native x86 Linux games work is the kind of step
   SteamOS parity rules out.

Both branches honour `STEAM_COMPAT_GRAPHICS_PROVIDER`, so the OS-provided approach is
stable across branches in a way that choosing `beta` specifically is not.

### Why the `.ero` can stay compressed

`mount_rootfs()` consumes the guest as a plain directory, and public's `RootFS` value is
`"@FEX_ROOTFS_PATH@/"` — a directory, not an image. But erofs is a *kernel* filesystem, and
`work/kernel/linux-7.1.6/.config` has:

```
CONFIG_EROFS_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_USER_NS=y
```

So a systemd mount unit can mount the pinned `.ero` read-only at
`/usr/share/guestos/fex-mesa` and satisfy the directory contract with no extraction, no
`erofsfuse`, and no image growth. The rootfs does not get deleted — it changes shape and
location, and stops being paired with 200 MB of our own emulator build.

---

## Phase 0 — Verification (BLOCKING)

Nothing below is committed to until these are answered. Four are already closed:

- ✅ **Not hardware-gated for download.** The depot pulled cleanly with an ordinary Steam
  account on x86_64, no Frame, no Deck. Licensing is not a blocker.
- ✅ **Kernel supports the mount.** `EROFS_FS` / `OVERLAY_FS` / `USER_NS` all `=y`.
- ✅ **`graphics_provider.json` schema is public.** No depot archaeology needed — it is a
  documented, versioned interface, `steam-runtime-graphics-provider.json(5)`. See
  References. `STEAM_COMPAT_GRAPHICS_PROVIDER` is a *pressure-vessel* variable; the FEX
  compat tool only sets it, PV consumes it. The man page's second example is explicitly
  "an Arch Linux derivative such as SteamOS" with `x86_64` + `i386`, which is very nearly
  what we need to author verbatim.

- ✅ **The pinned `ArchLinux.ero` already satisfies the graphics-provider contract, in
  full.** This was the item that could have invalidated the plan. Verified 2026-08-05 by
  mounting `work/prebuilt/fex-rootfs.blob` with `erofsfuse` in a throwaway Arch container
  (`erofsfuse` is its own Arch package — `erofs-utils` does not carry it):

  | required by `graphics_provider(5)` | result |
  |---|---|
  | `etc/ld.so.cache` | present |
  | `sbin/ldconfig`, `usr/sbin/ldconfig` | present |
  | x86-64 linker (`lib64/`, `usr/lib64/`) | present |
  | i386 linker (`lib/`, `usr/lib/`, `usr/lib32/`) | present |
  | merged-`/usr` layout | yes — `bin`→`usr/bin`, `lib`→`usr/lib`, `lib64`→`usr/lib`, `sbin`→`usr/bin` |

  Both architectures are fully populated: `usr/lib` and `usr/lib32` each carry a complete
  Mesa (`libGL`, `libEGL`, `libvulkan`, `libGLX_mesa`, `libgallium-25.3.3-arch1.1`,
  `libdrm`, `libwayland-client`), 66 `dri/` drivers each, plus `gbm/` and 255 `gconv/`.
  So "fex + **mesa** combined arch linux install" is already what we hold — no combined
  guest needs building. There is no `graphics_provider.json` in it; that is the one file
  we add.

  Superblock, for the size argument: 4,157,067,859 bytes of content stored in
  1,956,739,919 bytes (47.07%), 89,992 files. Valve's own beta rootfs depot is
  3,945,426,115 — the same order of magnitude uncompressed, which is precisely why keeping
  ours as a mounted `.ero` is the better shape.

Open:

1. **Is pressure-vessel actually live for native x86 Linux games on our device?**
   `fex-compat-tool:136-140` sets `STEAM_COMPAT_MACHINE_ARCHITECTURE=aarch64-linux-gnu` and
   `STEAM_COMPAT_EMULATOR=<emulator.json>`, commented *"Tell PV that we are an AArch64
   machine"*. We launch Steam raw on host with no pressure-vessel
   (`fs-overlay/usr/bin/novadeck-steam:31`, `images/customize-base.sh:115`), but
   `docs/FEX_README.md:71` says native x86-64 games do go through SLR scout-on-soldier.
   These may both be true; confirm which on hardware.
2. **Does the Steam client on our device offer the tool at all,** and does it select it for
   a native x86 Linux title, or fall through to our binfmt registration?

Both remaining items need hardware. Phase 1 can start without them.

---

## Phase 1 — Provide `/usr/share/guestos/fex-mesa`

- `graphics_provider.json` authored to the Phase 0 schema, delivered via `fs-overlay`.
  The verified layout means it is essentially the man page's SteamOS example verbatim —
  the paths below were all confirmed to exist in our `.ero`:

  ```json
  {
    "graphics_provider_v0": {
      "root": "./",
      "architectures": {
        "x86_64-linux-gnu": {
          "dri": "/usr/lib/dri", "gbm": "/usr/lib/gbm", "gconv": "/usr/lib/gconv"
        },
        "i386-linux-gnu": {
          "dri": "/usr/lib32/dri", "gconv": "/usr/lib32/gconv",
          "fallback_library_paths": ["/usr/lib32"]
        }
      }
    }
  }
  ```

  Decide `locales` deliberately: it defaults to `true`, and the guest does carry
  `usr/lib/gconv`, but if its locale data is thin PV should be told to take locales from
  the root instead.
- A systemd mount unit mounting the pinned `.ero` read-only at
  `/usr/share/guestos/fex-mesa`, ordered before the session.
- The `graphics_provider.json` has to appear *inside* that directory, so it needs an
  overlay or a bind on top of the read-only erofs mount. Settle which in Phase 1;
  overlayfs over a ro lower is the obvious shape and `CONFIG_OVERLAY_FS=y`.
- `packages/fex-rootfs/prebuilt.pin` keeps its pin; only `dest` and the consumer change.
- Assert the mount in `make test` — a declared invariant nothing checks is not a guard
  (`[[declared-invariants-need-assertions]]`).

## Phase 2 — A/B validation on hardware (GATE)

Nothing is deleted until this passes.

- Test titles: **Super Meat Boy** and **Garage Circuit Rally** — the two titles HW-proven
  under our thunkless system FEX on 2026-07-11, and the pair whose SIGSEGV under host GPU
  thunks forced the thunkless config in the first place.
- Run each three ways: our system FEX (baseline), Valve's tool with its default thunked
  config, and Valve's tool with `STEAM_COMPAT_FEX_CONFIG` forcing thunks off.
- Confirm whether host Turnip is genuinely in the path — `fdinfo drm-engine-gpu` plus crtc
  framecount, **not** debugfs `gpu`, which hitches the display
  (`[[sm8650-gpu-liveness-probing]]`).
- Expected upside: their thunks are Adreno-tuned and 32-bit sets ship too, so the thunked
  path may undo the concession we made in July. Expected risk: the same SIGSEGV.

## Phase 3 — Retire the system FEX

Only after Phase 2 is green.

- Drop `packages/fex-emu/` (PKGBUILD, 2 patches, `source.pin`, the pinned x86 sysroot).
- Drop `fex-emu` from `PKGS` in `images/customize-base.sh:190`.
- Drop `fs-overlay/usr/share/fex-emu/Config.json`.
- Re-check the `erofsfuse` / `squashfuse` / `fuse3` deps — they existed for FEXServer's
  rootfs mount and may now be orphaned.
- Measure and record: image size delta, and cold `make` wall-clock delta (this package
  compiles FEX with clang *and* cross-compiles x86/i686 guest thunks under arm64 qemu).

## Phase 4 — Docs and memory

- Rewrite `docs/FEX_README.md` — the two-column table survives, but the second column's
  mechanism changes completely.
- `docs/windows-games-fex.md` is unaffected; say so explicitly so the next reader does not
  re-derive it.
- Update `[[fex-two-paths-independent]]` and `[[fex-rearchitecture-pickup]]`.

---

## Risks and re-check triggers

- **Valve repopulates the public rootfs depot.** The whole OS-provided premise is inferred
  from depot sizes plus two scripts, not from a Valve statement. If they intend to ship a
  rootfs on public before Frame launches, Phase 1 becomes unnecessary. Re-run the appinfo
  query (Appendix A) before starting Phase 1 and again near Frame launch.
- **`bleeding-edge` becomes `public`.** It already shares public's empty rootfs manifest,
  so this is expected to be a no-op — but the tool version will move.
- **The tool is not offered on non-Frame hardware.** Download is not gated (proven), but
  client-side *selection* for a title may be. This is Phase 0 item 4.
- ~~Our `.ero` does not satisfy the graphics-provider contract~~ — **closed 2026-08-05**,
  it does, in full. This was the risk that could have made the plan more expensive than the
  status quo; it is retired. Retained here so it is not re-raised.

**Rollback:** `packages/fex-emu` and `packages/fex-rootfs` stay in the tree untouched
through Phases 0-2. Nothing is irreversible before Phase 3.

---

## Appendix A — reproducing the depot inspection

`steamcmd` with cached credentials. Our host has no 32-bit loader, so the `linux64` binary
must be invoked directly rather than through `steamcmd.sh`. The Steam root is `$HOME/Steam`,
so a copied login cache has to land there.

```sh
SP=<scratch>/steamroot
mkdir -p "$SP/Steam"
cp -r <steamcmd-data>/{config,appcache,depotcache} "$SP/Steam"/
cp -r <steamcmd-data>/steamcmd "$SP"/

cd "$SP/steamcmd"
env HOME="$SP" LD_LIBRARY_PATH="$SP/steamcmd/linux64" ./linux64/steamcmd \
    +login <account> +app_info_update 1 +app_info_print 3127680 +quit

# tool depot, public branch (5.75 MiB)
env HOME="$SP" LD_LIBRARY_PATH="$SP/steamcmd/linux64" ./linux64/steamcmd \
    +login <account> +download_depot 3127680 3127682 +quit

# tool depot, beta branch -- for comparing against the retired code path only
... +download_depot 3127680 3127682 2446860776614422387 +quit
```

Manifest GIDs are in the appinfo dump and will move; re-read rather than reusing these.

The `beta` **rootfs** depot (`3127681`, manifest `874797479366940863`, 855 MiB) is
deliberately **not** listed as a step. An earlier draft had Phase 0 pull it to reverse
engineer `graphics_provider.json` — unnecessary, since that file is a documented interface
(References). Fetch it only if a Valve-authored reference guest is wanted for comparison,
and never as a dependency.

---

## References

- `steam-runtime-graphics-provider.json(5)` — the `graphics_provider_v0` schema:
  `architectures` (multiarch tuples, per-arch `dri`/`gbm`/`gconv`/`fallback_library_paths`),
  `root`, `locales`, `va_api`, `vdpau`, and the required `root` contents.
- `steam-runtime-emulator.json(5)` — the `emulator_v0` schema Valve's `emulator.json`
  implements, and the exec chain PV builds around it.
- `docs/steam-compat-tool-interface.md` — `toolmanifest.vdf`, compat verbs, and the
  `STEAM_COMPAT_*` variables.

Canonical home is <https://gitlab.steamos.cloud/steamrt/steam-runtime-tools> (`docs/`).
There is no `ValveSoftware/steam-runtime-tools` on GitHub — only third-party forks, which
is what the copies in the scratchpad came from. Prefer the GitLab original when citing.
