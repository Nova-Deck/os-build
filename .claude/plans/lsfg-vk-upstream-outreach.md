# Draft: upstream outreach to PancakeTAS (lsfg-vk)

**NOT SENT.** Speaking to a third party on the project's behalf is the operator's call, and
neither channel is one an agent should post to unattended.

**Channels** (from lsfg-vk.dev): Discord `https://discord.gg/5cCP6aACgT`, or GitHub Discussions on
the archived repo `https://github.com/PancakeTAS/lsfg-vk/discussions`. Discord is where the author
says they are reachable; Discussions is public and durable. Discord is probably the better first
contact.

**Why bother:** the license asks integrators to make contact ("If you want to integrate lsfg-vk,
perhaps maintain a fork, reach out to me and we can discuss it"), and we have data they almost
certainly do not — three Adreno generations, measured. It costs nothing and it is the difference
between shipping under a licence that forbids derivatives with the author's knowledge and without
it.

---

## Draft

Hi — I maintain Nova-Deck, a SteamOS-style distro for aarch64 Qualcomm handhelds (SM8250 / SM8550 /
SM8650, Adreno 650/740/750). It's a non-commercial hobby project: https://github.com/Nova-Deck/os-build

I'd like to ship lsfg-vk 2.0 in the image, and your licence page asks integrators to get in touch,
so — getting in touch.

What we'd be doing, concretely:

- Shipping lsfg-vk 2.0.0-rc1 **unmodified** — no patches, no fork, the tag as you cut it. We started
  from your prebuilt for exactly the NoDerivatives reason, and it works; the question further down is
  about the one architecture you do not publish.
- The layer stays **off by default** (`DISABLE_LSFGVK=1` session-wide, lifted per-game), since it
  needs Lossless Scaling and the `lsfg-vk` beta branch and does nothing for anyone who lacks either.
- A small Decky plugin to write `conf.toml`, because the Qt UI can't run in a gamescope session.

Our games are all x86, running under FEX. One detail worth passing on: the manifest-relative
`library_path` your build uses (`../../../lib/...`) is what makes the layer resolve correctly
across our overlay mounts and through Valve's graphics-provider republish. An absolute path would
have resolved against the wrong root and the loader would have dropped the layer with no error at
all. Thank you for that — it was load-bearing and we did not have to patch anything.

You may find the numbers interesting, since I doubt many people have run this on Adreno. All
`lsfg-vk-cli benchmark`, 2.0.0-rc1, idle GPU, m2, ms per iteration:

| | Adreno 650 (SM8250) | Adreno 740 (SM8550) | Adreno 750 (SM8650) |
|---|---|---|---|
| flow 1.00, quality | 391.83 | 21.79 | 12.03 |
| flow 1.00, quality, `-a` (no fp16) | 541.49 | 79.44 | 80.71 |
| flow 1.00, performance mode | 11.57 | 1.95 | 1.65 |
| **fp16 gain** | **1.38x** | **3.76x** | **6.71x** |

(all at 1280x720, the resolution common to all three panels)

Two things that might be useful to you:

1. **Without fp16, the 740 and 750 are the same part for this workload** (79.44 vs 80.71 ms). The
   750's entire advantage is fp16 throughput. Your "2-3x on 2:1-fp16 parts" claim is if anything
   conservative on recent Adreno — we measured 6.7x on the 750.
2. **Adreno 650 barely benefits from fp16 at all (1.38x)**, and is ~6.8x slower than the 740 even at
   fp32. Quality mode is unusable there; performance mode at flow 0.5 is the only configuration that
   fits a 60fps budget. So we're shipping a per-SoC default rather than one global one.

Two small things I hit, in case they're useful — no bug reports needed, just noting them:

- `LSFGVK_DLL_PATH` (and the other `LSFGVK_*` globals) are silently ignored on a first run:
  `getOrDefault()` calls `parseGlobalEnv()` on the `LSFGVK_ENV` and config-exists branches, but not
  on the branch that writes a fresh default config and returns it. Cost me a confusing "Unable to
  find lsfg-vk.dll" until I switched to `-d`.
- `dist/podman/build.sh` archives with `tar cf` but names the output `.tar.xz`, so the published
  artifacts are uncompressed tars with an xz extension. `tar xJf` fails on them.

## The reason I'm actually writing

I hit something that needs your call rather than my reading of the licence.

Our handhelds run x86 games two different ways, and they do not share a Vulkan stack:

- **Native x86-64 Linux titles** render on a guest x86 Turnip. Your x86_64 layer drops straight in
  and works — I have it generating frames right now, 60fps in / 120fps out on an Adreno 750.
- **Windows titles under Proton** are different. Valve's FEX compat tool thunks the game's x86
  Vulkan calls out to the **host arm64** driver, and pressure-vessel pins the implicit-layer
  search path to its own overrides directory, which it populates from the host's
  `/usr/share/vulkan/implicit_layer.d`. So a layer there has to be **aarch64**.

Since that is most of the library, lsfg-vk currently reaches the smaller half of our games.

The fix is an aarch64 build of the layer, which you do not publish. I would rather ask than
decide unilaterally, because CC BY-NC-ND is genuinely ambiguous on this point — compiling your
unmodified source is arguably reproduction in another format rather than Adapted Material, but
Creative Commons say themselves their licences are not meant for software and I do not want to
lean on my own reading of yours.

So, concretely: **would you be OK with us building lsfg-vk for aarch64 from your unmodified
source and shipping that binary?** No patches, no fork, same version you tagged, and I would
rather carry any Adreno or FEX fix to you than hold one locally. If you would prefer to publish
an aarch64 artifact yourself, that works even better for us and I am happy to help test it — I
have three Adreno generations on the desk.

Happy to be told no, or to change anything about how we package it. Mainly I wanted you to know
it's happening rather than find out later.

Thanks for lsfg-vk — the porting write-up was a great read.
