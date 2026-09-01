# boot-attempts — replacing Valve's steamenv with a minimal counter module

> **Status: IMPLEMENTED AND HARDWARE-VALIDATED 2026-08-02** on an AYANEO Pocket S2. With
> `novadeck-boot-good` masked so it could not clear the counter, a reboot took `A.conf` from
> `boot-attempts: 0` to `1` while `boot-count`/`boot-time` stayed on the previous boot's values —
> so the increment can only have come from the bootloader. Unmasking and `mark-good` cleared it
> again (`boot-count` 1 → 2). Designed the same day after `steamenv_init`
> was tried on hardware and failed; built the same day. The module is
> `boot/patches/grub/0002-add-the-novadeck-stage-2-module.patch`, the call site is
> `boot/gen-grub-cfg.sh`, and `tests/test-stage2-grub.sh` asserts it. `steamenv` is gone from the
> tree. The question this doc originally left open — whether ABL publishes the ESP as a filesystem
> handle — is now **answered from steamcl's source**, not deferred to a boot: see "Why the ESP is
> reachable" below.

## What happened, so nobody re-derives it

The recorded decision — "call `steamenv_init`, keep plain `linux`" (now in `docs/worklog/DONE.md`) — was reasoned
entirely from reading Valve's source. It was HW-tested 2026-08-02 on a fresh card and failed twice
over:

* **Black screen.** Nothing painted at all, no message before it. In our config `steamenv_init` sat
  before `loadfont`/`insmod gfxterm`/`terminal_output gfxterm` and before any `menuentry` was
  defined, so if the call never returns nothing is ever drawn and no menu exists to draw.
* **The conf was never written.** Read offline from the card afterwards, `SteamOS/conf/A.conf` was
  still `boot-attempts: 0`, `boot-count: 0`, `comment: seeded by image/make-sdcard.sh` — i.e.
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
That deletes the partsets path entirely. (When this was written the partsets path was the prime
suspect for the failure. Reading steamcl afterwards showed handle enumeration works fine here, so
this is a simplification rather than a fix — still the right call, but not for the stated reason.)

**Finding the conf: try, don't match — but only on our own disk.** Enumerate `SIMPLE_FILE_SYSTEM`
handles and attempt to open `\SteamOS\conf\<name>.conf` read/write on each, taking the first that
succeeds. No uuid comparison. This is both simpler and more tolerant of whatever ABL does or does
not publish, and it is the same shape steamcl uses to find the loader on efi-A. The sweep is
scoped to the disk this stage 2 was loaded from — see [Scoping the sweep to our own
disk](#scoping-the-sweep-to-our-own-disk-issue-84) below, which is the one thing this design got
wrong on the first pass.

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
  `tests/test-stage2-grub.sh`, along with the `steamenv_init` presence and ordering assertions
  added in `dd8bec5` — all three describe a module that will not exist.

What replaces them is one assertion that the config invokes `novadeck_bootattempts` with this
slot's image name, which is the only claim still worth enforcing.

## Why the ESP is reachable — answered from steamcl's source, not from a boot

This section used to be an open question: whether ABL publishes the ESP as a `SIMPLE_FILE_SYSTEM`
handle at all, or only the volume it booted from. It is answered, and the answer was in
`_reference/steamos-efi` the whole time.

**GRUB is chainloaded from the SLOT's efi partition, not from the ESP**, so unlike stage 1 we
cannot simply ask our own loaded image for it. steamcl can: `find_loaders()` takes the ESP from
`get_self_device_handle()` → `HandleProtocol(SIMPLE_FILE_SYSTEM)`, because `bootaa64.efi` lives on
the ESP. That trick does not transfer.

But steamcl **also** loops over `LocateHandle(ByProtocol, SIMPLE_FILE_SYSTEM_PROTOCOL)` and
`efi_mount`s each handle in turn — that is how it reaches `\EFI\steamos\grubaa64.efi` on efi-A to
chainload us at all. So if the device gets far enough to run this module, non-boot partitions are
bound, and the ESP — steamcl's own boot volume — is bound *a fortiori*. Enumeration works here;
that was never the thing that broke.

There is one real hazard, and stage 1 already handles it. `chainloader.c` retries after
`connect_block_controllers()`, which walks `BLOCK_IO` handles calling `ConnectController(…, TRUE)`:

> Some UEFI implementations may skip binding drivers, including the FAT filesystem driver, when
> running with fastboot enabled. This results in handles to the filesystems not being returned and
> boot failing. Bind all block handles to drivers, which should trigger binding of filesystems.

**We deliberately do not repeat that sweep.** Whichever path stage 1 took, the bindings persist
into us: steamcl chainloads through `LoadImage`/`StartImage` and never calls `ExitBootServices`, so
the handle database we enumerate is the one it left behind. A sweep of our own would be dead code
on every real boot path, against a module whose whole point is that it is small.

If the counter ever *does* fail to find the conf, the error reports the handle count, and that
number is the diagnosis. The fallbacks then, in order of preference:

1. **Bump it from the initramfs.** Trivial there (real tools, real filesystems, correct format) and
   needs no GRUB code at all. Covers a slot whose kernel and initramfs come up but where systemd
   never does — a real part of the gap, though not a kernel or DTB that never reaches the
   initramfs.
2. **Leave the bootloader half unwired** and document that such a slot is recovered through the
   stage-2 board menu.

A grubenv counter stays rejected: `boot-attempts` is per-image state that lives in the bootconf
beside `image-invalid`/`boot-count`, where RAUC and `novadeck-bootctl` already read it, and
`save_env` cannot write the bootconf's format anyway — grubenv is its own 1024-byte block format,
not `key: value` lines. It would be a second store in a second format needing new OS-side tooling.

## Scoping the sweep to our own disk (issue #84)

The original sweep took the first handle that yielded the conf, on this reasoning, quoted from the
module header as it shipped:

> The conf lives only on the ESP (`image/make-sdcard.sh`), so the first hit is the right one.

That holds for exactly **one** novadeck medium. Every novadeck medium carries the same nine
partitions and the same `\SteamOS\conf\A.conf`, so with an internal install and a card both
present, "the first hit" is whichever volume the firmware chooses to publish first — which need
not be the one being booted. **Observed on hardware 2026-09-01**: booting a card left the *internal*
install's `A.conf` at `boot-attempts: 1` over a `boot-count` and `boot-ok` comment that were
demonstrably written by that install's own `mark-good`. The card's stage 2 had counted the boot on
the internal ESP.

The OS cannot undo this. `novadeck-bootctl mark-good` clears the counter through `/esp`, which is
`/dev/novadeck/NOVADECK-ESP` — scoped to the *booted* disk. So a count landing on the other disk is
never cleared: it climbs once per boot for as long as two media are present, until steamcl's
failsafe marks a healthy slot bad and rolls it back. It is the pre-Linux twin of the wrong-ESP bug
that `/dev/novadeck/*` fixed on the Linux side, and the udev fix does not reach it.

**The fix.** A partition's EFI device path is the disk's path with a `MEDIA`/`HARD_DRIVE` node
appended, so two partitions are on the same disk exactly when everything *before* that node is
byte-identical. That prefix is the whole comparison: no GUIDs, no partition numbers, no assumption
about how the firmware spells a disk. Our own path comes from
`grub_efi_get_loaded_image(grub_efi_image_handle)->device_handle` — the slot's efi partition, which
is on the same GPT as the ESP we want (`image/partition-table.txt`), so it names our disk even
though it is not the volume we are looking for.

Two decisions worth keeping explicit:

* **No conf on our own disk is an ERROR**, not a licence to write to a neighbour's. A slot that
  goes uncounted fails safe; a slot counted on the wrong disk does not, and it damages a second
  install as it goes. `gen-grub-cfg.sh`'s else-arm already holds that error on screen.
* **The unscoped sweep survives as a fallback**, taken only when the firmware will not say which
  disk we came from at all, and it prints a warning naming that as the reason. Losing the counter
  outright on such firmware would be worse than the single-medium behaviour we had before.

The error message now reports tried-of-published rather than a single count, because those two
numbers separate "this firmware publishes only the volume it booted from" from "our own disk has no
ESP" — which need opposite fixes.

## What shipped, and what the first boot confirms

The module is ~640 lines including its header, builds warning-free under `-Wall -W`, and is
embedded in `grubaa64.efi`. The config calls it after `terminal_output gfxterm`, wrapped so a
failure is held on screen:

```
insmod novadeck
if novadeck_bootattempts A; then
  true
else
  echo "novadeck: boot-attempts NOT counted for slot A — this slot cannot fail safe"
  sleep 5
fi
```

**A HEALTHY BOOT PRINTS NOTHING.** The module used to print `novadeck: A boot-attempts 0 -> 1` on
success. That line has been removed, because nobody could ever read it: the success arm of the
config above is a bare `true` with no dwell, so GRUB draws the menu and clears the screen the
instant the module returns. **HW-confirmed 2026-09-01** — not seen even on a fresh card's first
boot, where the menu waits for input, because *drawing* the menu is what clears it. Giving the
healthy path a dwell would tax every boot on every device to report nothing, so the line went
instead.

So **grade the counter by reading the conf, never the panel**: from the booted system inside the
first ~60s (`boot-attempts: 1`, before `mark-good` clears it), and offline afterwards
(`boot-attempts: 0`, `boot-count` incremented). To read it at leisure, mask
`novadeck-boot-good.{service,path}` first and the value survives the whole session.

What is left on the panel is failure, and **the menu reaching the screen at all is the divider**:

| What the panel shows | What it means | Next |
|---|---|---|
| The menu, nothing above it | Healthy. This is also what a counter that silently did nothing looks like, which is why the conf is the instrument. | Read the conf, per above. |
| `novadeck: no volume carries \SteamOS\conf\A.conf (N of M ... handles tried, scoped to the boot disk)`, held 10s | The module ran and returned an error, so the else-arm caught it. N-of-M is the diagnosis: `N=0` means the scoping rejected every handle, `N>0` means our own disk really has no conf. | `N=0`: check the loaded-image device path. Otherwise fall back to bumping from the initramfs. |
| `novadeck: WARNING: this firmware does not say which disk stage 2 was loaded from` | The scoping could not run and the sweep fell back to first-hit-wins. Harmless with one medium, wrong with two. **This line is only readable when the module ALSO fails** — on its own it is cleared by the menu like any success-path output, so it is a companion to the row above, not an independent signal. | Only matters on a device that boots with a card inserted. If you suspect it, mask `mark-good` and compare both disks' confs across a boot. |
| No menu at all — a hang or a black screen | Dies inside the call. | Unlike the steamenv failure this replaced, this is distinguishable: the terminal is up and the menu is already defined before the call, so reaching the menu proves the module returned. |

That last row is the whole reason the call moved after `gfxterm`. The first attempt could not tell
"dies inside the call" from "returns cleanly but finds no conf" — now the first shows no menu, the
second shows an error above one, and a healthy boot shows a clean menu.
