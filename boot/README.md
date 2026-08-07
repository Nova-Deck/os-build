# boot/

The two-stage UEFI boot chain (Phase 5; `docs/phase5.md`):

```
ABL  →  steamcl (stage 1, shared ESP)  →  GRUB (stage 2, the slot's efi-a/b)  →  kernel in the slot root
        picks the image (A|B) from            picks the BOARD from its menu,
        /SteamOS/conf/{A,B}.conf              loads Image + initramfs + that board's DTB
```

Two independent choices, made by two different stages. Which **slot** boots is stage 1's, driven
by the boot confs on the shared ESP and steered by `novadeck-bootctl` / RAUC. Which **board** this
is — one image serves all 15 — is stage 2's, and it is the one thing the card cannot work out for
itself, so it is a menu on first boot and a saved answer afterwards.

| File | Purpose |
|---|---|
| `steamos-efi.pin` | Pinned source for stage 1: the arm64 fork of Valve's `steamos-efi`. |
| `steamcl.sh` | Cross-build it → `out/boot/{steamcl.efi, holo-bootconf, steamcl-version, fonts/default.pf2}`. `holo-bootconf` ships on-device as `/usr/bin/steamos-bootconf`. |
| `grub.pin` | Pinned source for stage 2: the **GNU GRUB 2.14 release tarball** from ftp.gnu.org. |
| `patches/grub/` | Our delta on it: framebuffer rotation, the `novadeck` boot-attempts module, and the `Makefile.core.def` stanza that builds it. Applied lexically, like `kernel/patches/`. |
| `grub.sh` | Cross-build stage 2 → `out/boot/grubaa64.efi` + `fonts/dejavu-mono.pf2`, then generate both configs. |
| `gen-grub-cfg.sh <A\|B> <out>` | Generate one slot's `grub.cfg`. No toolchain — `images/test-stage2-grub.sh` runs it directly. |
| `boards.map` | Build-time board catalog: `id⇥name⇥dtb⇥bootargs`. Cross-checked against the runtime device profiles by that test. |
| `deploy.sh <esp>` | Dev helper: write the stage-1 tree to a mounted ESP. Stage 2 comes from `make sdcard` or a RAUC install. |

## The kernel command line

There is no `boot/cmdline` any more. The EFI stub **overwrites** `/chosen/bootargs` with the
loader's command line, so every argument has to be on the `linux` line or it is silently dropped —
which is why the board args moved out of the DTS `/chosen/bootargs` too. They come together in
`gen-grub-cfg.sh`:

| Part | Source |
|---|---|
| common args | `BOOT_CMDLINE` in `gen-grub-cfg.sh` |
| board args | the fourth column of `boards.map` |
| `root=` `novadeck.var=` `novadeck.efi=` | per slot, as `PARTUUID=` read out of the GPT at boot with `probe --part-uuid`; `PARTLABEL=` from `images/partition-table.txt` is the announced fallback |
| `novadeck.slot=` | per slot, stated outright — a PARTUUID carries no slot letter for the initramfs to match |

The specs are `PARTUUID=` because every novadeck medium carries the same eight GPT names: with a
card inserted on a device installed to internal storage, `PARTLABEL=` resolves to whichever disk
enumerates first. The UUIDs are derived from the disk stage 2 was chainloaded off, at boot, so
they name that disk by construction and no update has to rewrite them. This needs `probe` in the
embedded `MODULES` — an unembedded module is an "unknown command" that leaves the variable unset
and takes the fallback on every boot, so `images/test-stage2-grub.sh` asserts the module list.

## The novadeck module

`grubaa64.efi` embeds one module of ours, providing one command:

```
novadeck_bootattempts <image-name>       # e.g. novadeck_bootattempts A
```

It opens `\SteamOS\conf\<image-name>.conf` on the ESP through the firmware's `EFI_FILE_PROTOCOL`,
increments `boot-attempts:` and writes it back. `novadeck-boot-good` clears the counter once the
session proves healthy; `novadeck-bootctl` and RAUC read it to decide a slot is bad. That is the
whole module — it touches no GRUB variable, no video mode and no kernel command line.

**It needs to be a module because GRUB's own `fat` driver is read-only.** The EFI file protocol is
the only way to write the ESP from stage 2.

Three things to know before changing it:

* **It does not do its own `ConnectController` sweep, on purpose.** steamcl does one over `BLOCK_IO`
  handles for firmware that skips FAT driver binding under fastboot, and it cannot reach efi-A to
  chainload us without the resulting filesystem handles. Those bindings persist into us — it uses
  `LoadImage`/`StartImage` and never calls `ExitBootServices` — so repeating the sweep would be
  dead code. That is also why the ESP is reachable at all from a binary loaded off efi-A.
* **The image name is an argument, not a discovery.** `gen-grub-cfg.sh` emits one config per slot
  and already knows the slot, so the module never has to work out which image it is.
* **The call sits AFTER `terminal_output gfxterm`,** which its predecessor could not. That
  predecessor was Valve's `steamenv`, whose `steamenv_init` bumped the same counter but overwrote
  `timeout`/`timeout_style` afterwards — so it had to run before any `menuentry` existed, and when
  it wedged on this hardware nothing had been painted and nothing could be. The post-mortem, and
  the three failure modes this module was shaped to avoid, are in `docs/phase5-bootattempts.md`.

## Building

Both stages run in the build container:

```sh
make steamcl      # stage 1
make grub         # stage 2 + both grub.cfg files
```

The stage-1/2 binaries reach a card through `images/make-sdcard.sh`, and reach an updated slot
through the RAUC post-install hook, which takes them from `/usr/lib/novadeck/boot/` inside the root
it just installed — so a root and the software that boots it always come from one build.
