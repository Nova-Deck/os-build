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
| `patches/grub/` | Our delta on it: Valve's `steamenv` module, and the `Makefile.core.def` stanza that builds it. Applied lexically, like `kernel/patches/`. |
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
| `root=` `novadeck.var=` `novadeck.efi=` | per slot, from `images/partition-table.txt` |

## steamenv is built but not invoked

`grubaa64.efi` embeds Valve's `steamenv` module; the generated `grub.cfg` calls neither
`steamenv_init` nor `steamenv_boot`. That is deliberate, and it is the thing to know before
turning it back on:

**`steamenv_init` — not `steamenv_boot` — is what increments `boot-attempts`, and it overwrites
`timeout` and `timeout_style` unconditionally afterwards** (`timeout=0` unless stage 1 asked for a
menu). Invoked after the config sets its own timeout, it wins: a fresh card boots menu entry 0 —
one specific board — instantly, on every device, and the counter it just bumped is never cleared
because that board does not come up. At three attempts steamcl's failsafe asks for a menu and the
device parks there for good.

Reintroducing it is therefore a config change against an identical binary: call `steamenv_init`
**first**, guard the timeout block with `if [ "$timeout" != "-1" ]` so stage 1's menu request still
wins, and switch `linux` to `steamenv_boot linux`. Until then, `boot-attempts` is never
incremented — see `docs/phase5.md` for what that costs.

## Building

Both stages run in the build container:

```sh
make steamcl      # stage 1
make grub         # stage 2 + both grub.cfg files
```

The stage-1/2 binaries reach a card through `images/make-sdcard.sh`, and reach an updated slot
through the RAUC post-install hook, which takes them from `/usr/lib/novadeck/boot/` inside the root
it just installed — so a root and the software that boots it always come from one build.
