# boot-attempts — replacing Valve's steamenv with a minimal counter module

> **Status: design only, nothing implemented.** Written 2026-08-02 after `steamenv_init` was
> tried on hardware and failed. `dd8bec5` (the `steamenv_init` call) is still in the tree and
> **makes the device unbootable** — revert it before flashing anything.

## What happened, so nobody re-derives it

The recorded decision in `TODO.md` — "call `steamenv_init`, keep plain `linux`" — was reasoned
entirely from reading Valve's source. It was HW-tested 2026-08-02 on a fresh card and failed twice
over:

* **Black screen.** Nothing painted at all, no message before it. In our config `steamenv_init` sat
  before `loadfont`/`insmod gfxterm`/`terminal_output gfxterm` and before any `menuentry` was
  defined, so if the call never returns nothing is ever drawn and no menu exists to draw.
* **The conf was never written.** Read offline from the card afterwards, `SteamOS/conf/A.conf` was
  still `boot-attempts: 0`, `boot-count: 0`, `comment: seeded by images/make-sdcard.sh` — i.e.
  untouched by anything.

Note the module does **not** apply a video mode; that hypothesis was checked and is wrong.
`choose_verbose_video_modes()` only calls `driver->iterate()` to enumerate GOP modes and build
`steamenv_noisy_*_mode` strings, and the source says outright that it "doesn't actually poke the
framebuffer(s) or initialise the screen in any way". `grub_cls()` is the only screen-touching call
and it is confined to the `mode_grub_menu` branch.

Two things in Valve's code explain the silence, and both are avoidable:

1. **`load_steamenv` discovers everything at runtime.** It reads this image's name and the ESP's
   uuid out of `SteamOS/partsets/*` on the chainloaded volume, enumerates every
   `SIMPLE_FILE_SYSTEM` handle, and matches the ESP by uuid. That depends on the firmware
   publishing *every* partition as a filesystem handle. Minimal UEFI implementations such as ABL
   commonly expose only the volume they were booted from, which would make the lookup fail.
2. **`process_boot_config()` swallows the failure.** It acts only `if( rv == GRUB_ERR_NONE )` and
   then returns `GRUB_ERR_NONE` regardless — no `grub_error`, no message. A total failure to find
   the conf is indistinguishable from success, which is exactly what we observed.

## The design

A new minimal module, **`novadeck`** (`grub-core/commands/efi/novadeck.c`), providing one command.
Everything Valve's does beyond the counter is dropped: partsets parsing, `get_os_image_name`,
`get_esp_uuid`, uuid matching, video-mode scoring, verbosity, the timeout overwrite,
`steamenv_boot`, and the UEFI `ChainLoader*` variable poking.

    novadeck_bootattempts <image-name>        # e.g. novadeck_bootattempts A

**It REPLACES steamenv rather than joining it.** `boot/patches/grub/0001-add-Valve-steamenv-*.patch`
and `0002-build-the-steamenv-module.patch` both go, and `steamenv` comes out of `MODULES` in
`boot/grub.sh`. Nothing else in the tree invokes a `steamenv_` command, so the removal is clean —
and it drops ~2000 lines of vendor code we would otherwise be carrying to use ~30 of it. Note the
build trap recorded in [[grub-module-needs-autogen]] still applies to the replacement: patch
`Makefile.core.def`, not the generated `.am`, and re-run `autogen.sh`.

**The image name is an argument, not a discovery.** `boot/gen-grub-cfg.sh` already generates one
config per slot and already knows `$SLOT`, so the module never has to work out which image it is.
That deletes the partsets path entirely — the most likely thing to be failing on ABL.

**Finding the conf: try, don't match.** Enumerate `SIMPLE_FILE_SYSTEM` handles and attempt to open
`\SteamOS\conf\<name>.conf` read/write on each, taking the first that succeeds. No uuid comparison.
This is both simpler and more tolerant of whatever ABL does or does not publish.

**Fail loudly.** If no handle yields the file, return `grub_error(GRUB_ERR_FILE_NOT_FOUND, ...)`.
The whole cost of the first attempt was that failure looked identical to success.

**The edit.** The conf is plain `key: value\n` text. Read it whole, find the `boot-attempts:` line,
increment the integer, write the buffer back from offset 0 and set the file size. `holo-bootconf`
already tolerates rewriting the file wholesale — that is what `steamos-bootconf` does on every
`set-mode`.

## Why this also simplifies grub.cfg

The module does not touch `timeout` or `timeout_style`, so:

* the `if [ "$timeout" != "-1" ]` guard added in `dd8bec5` is no longer needed, and
* the ordering constraint disappears — the call can sit **after** `terminal_output gfxterm`, where
  any `grub_error` it raises is actually visible on the panel.

Both of those were only ever there to work around `steamenv_init` overwriting the timeout.

`steamenv_boot` goes with the rest of the module, and so do the things defending against it. Once
no `steamenv_` command exists, these are guarding a command that cannot be called and should be
deleted rather than left to rot:

* the comment block in `boot/gen-grub-cfg.sh` explaining why plain `linux` is kept instead of
  `steamenv_boot` — the reasons (UEFI `ChainLoader*` poking meaningless on ABL, cmdline juggling, a
  redundant `steamos.efi=PARTUUID=` append) are recorded here and in `dd8bec5`, so nothing is lost;
* the `grub-*.cfg boots with plain linux, not steamenv_boot` assertion in
  `images/test-stage2-grub.sh`, along with the `steamenv_init` presence and ordering assertions
  added in `dd8bec5` — all three describe a module that will not exist.

What replaces them is one assertion that the config invokes `novadeck_bootattempts` with this
slot's image name, which is the only claim still worth enforcing.

## Open question this does not answer

Whether ABL publishes the ESP as a filesystem handle *at all*. If it publishes only the volume it
booted from — the slot's efi partition — then no module can reach p1 through the EFI file protocol
and the counter cannot live in the ESP conf. In that case the honest fallbacks are, in order of
preference:

1. **Bump it from the initramfs.** Trivial there (real tools, real filesystems, correct format) and
   needs no GRUB code at all. Covers a slot whose kernel and initramfs come up but where systemd
   never does — a real part of the gap, though not a kernel or DTB that never reaches the
   initramfs.
2. **Leave the bootloader half unwired** and document that such a slot is recovered through the
   stage-2 board menu, which is what ships today.

A grubenv counter stays rejected: `boot-attempts` is per-image state that lives in the bootconf
beside `image-invalid`/`boot-count`, where RAUC and `novadeck-bootctl` already read it, and
`save_env` cannot write the bootconf's format anyway — grubenv is its own 1024-byte block format,
not `key: value` lines. It would be a second store in a second format needing new OS-side tooling.

## First implementation step

Build the module and call it from a config where `gfxterm` is already up, with `echo` markers
either side and a `sleep`. That one boot distinguishes "dies inside the call" from "returns cleanly
but finds no conf", which is the fact the first attempt failed to establish.
