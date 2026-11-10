# Catching a reset during kernel boot (ramoops RAM console)

Use this when a board **resets during kernel boot**, there is no UART (SM8650 has none), and the
journal of the dead boot is empty because the boot never reached journald. Setting `panic=0` tells
you which kind of reset it is. If the board still resets with `panic=0`, the reset came from below
Linux: a firmware watchdog after a bus hang, the hypervisor, or the PMIC. Linux printed nothing
because it never got the chance.

Here is what the setup does:
- **The RAM console.** The kernel copies its console into a reserved RAM region as it prints.
- **The capture.** The next boot reads that region back, so you get the dead boot's log up to its
  last line.
- **The probe log.** With probe logging on the command line, that last line names the driver that
  was probing.

None of this ships. It lives here, outside `kernel/patches/`, and is applied only for a debug
session.

## Files

| File | What it is |
|---|---|
| [`ramoops-crash-debug/enable-ramoops-on-the-pocket-fit.diff`](ramoops-crash-debug/enable-ramoops-on-the-pocket-fit.diff) | `git apply`-able. It adds `CONFIG_PSTORE_RAM=y` and `CONFIG_PSTORE_CONSOLE=y` to `kernel/kernel.config`, the `ramoops` reserved-memory node to `sm8650-konkr-pf.dts`, and the pstore salvage patch as `kernel/patches/0985-…`. |
| [`ramoops-crash-debug/reboot-loop.sh`](ramoops-crash-debug/reboot-loop.sh) | Reboots the device until a reset is caught, without burning the slot, and saves each previous boot's console. |
| [`ramoops-crash-debug/decode-ramoops.py`](ramoops-crash-debug/decode-ramoops.py) | Reads a bit-decayed console by matching each line against a clean dmesg. It is only needed when the ECC could not repair the text. |
| [`ramoops-crash-debug/count-resets.py`](ramoops-crash-debug/count-resets.py) | Counts the resets in a run from the gaps between journal boots. This is the count to trust (§4). |
| [`ramoops-crash-debug/ufs-defer-hold.patch`](ramoops-crash-debug/ufs-defer-hold.patch) | The 2026-11-10 FIT A/B: `ufshcd_core.defer_hold=` keeps the UFS supplies or clocks on through a deferred probe. Kept as the example of an A/B switched from the boot line (§5). |

## 1. Build a card with the RAM console

```sh
git apply docs/ramoops-crash-debug/enable-ramoops-on-the-pocket-fit.diff
python3 kernel/patches/check-order.py      # 0985 must still be a free slot; renumber if not
set -a && . ./dev.env && set +a && make sdcard > build.log 2>&1
```

Add a `0985` row to `kernel/patches/README.md` while it is applied. Afterwards, drop it with
`git apply -R` or a `git restore` of the three files.

**For a board other than the FIT**, copy the `ramoops@…` node into that board's DTS and pick a
new address:
- It must be plain RAM according to the EFI memory map, outside every reserved-memory carve-out.
- Keep it well below the top of the 4 GB range, where the firmware allocates first.

`0xf3400000` (2 MB: 1 MB console, `ecc-size = <64>`) is right for SM8650 only.

**Why the salvage patch (`0985`) is needed:** the FIT's RAM loses bits across a warm reset. They
always flip 1→0, at anywhere from near zero up to ~40% of bytes. At `ecc-size` 16 the zone headers
were often beyond repair, and they still were at 64. ramoops then drops the whole zone. For the
console zone only, the patch does two things:
- It keeps the raw data area when the header is lost.
- It zeroes data and parity before each boot writes, so you can see where the log ends.

## 2. Set the boot line on the device

A **freshly flashed card resets the grub entry** to `quiet loglevel=3 … panic=5`. Edit it again
after every flash. Work on the ESP of the running slot (`/efi/EFI/steamos/grub.cfg`), find the
board's `menuentry … --id <board>`, and edit the `linux` line two lines below it:

- drop `quiet loglevel=3`
- `panic=5` → `panic=0` (a Linux panic now hangs instead of rebooting, which separates the two kinds of reset)
- add `ignore_loglevel initcall_debug dyndbg="file drivers/base/dd.c +p"` (logs every driver probe, with debug messages reaching the console)

Back up first (`cp grub.cfg grub.cfg.bak-<what>`) and `sync` after the edit. GRUB re-quotes the
`dyndbg` argument, so after the next boot `/proc/cmdline` shows `"dyndbg=file drivers/base/dd.c +p"`.
That is correct. To confirm the probe log works, check that `dmesg` shows `really_probe: probing driver …` lines.

## 3. Run the reboot loop

```sh
HOST=root@<ip> OUT=<capture dir> MAX_ITER=60 docs/ramoops-crash-debug/reboot-loop.sh
```

**Slot safety:**
- **The loop's own rule.** It only reboots once mark-good has set `A.conf` `boot-attempts` back to
  0, about 45 s after boot. It stops as soon as it sees `boot-attempts` ≥ 2 at first contact.
- **The limit no script can enforce.** A reset happens before Linux runs, so 3 resets in a row
  still reach steamcl's **invisible** failsafe menu. Recover by setting `boot-attempts: 0` in
  `SteamOS/conf/A.conf` on the card's ESP.

Each iteration saves `iterNNN.console`, the previous boot's console. The loop then deletes the
device's copy, because systemd-pstore archives nothing when pstore is empty, and a leftover file
would pass for a new capture.

**The loop's verdict is not the count.** It stops when it reads `boot-attempts` ≥ 2, but it reads
the value when SSH first answers. mark-good clears it about 30 s after gamescope is up. If SSH answers
late, for example while Steam checks files on a slow card, mark-good has already run and the loop
reads 0 after a reset. A large uptime at first contact does not mean a reset either: it is the same
late SSH. Count resets with `count-resets.py` (§4).

## 4. Count the resets and read the capture

```sh
ssh root@<ip> journalctl --list-boots -o json | python3 -I docs/ramoops-crash-debug/count-resets.py --since <first boot of the run>
```

A reset during kernel boot leaves no boot in the journal. It shows up as a longer gap between one
boot's last entry and the next boot's first. That gap covers only shutdown, firmware, GRUB and early
kernel, so nothing in the session can stretch it. On the FIT a clean reboot is 18–22 s and each
reset adds about 10 s. Don't count with `A.conf` `boot-count`: mark-good bumps it, so it counts
confirmed boots only and never moves on a reset.

Then read the console of each reset:

```sh
tr -c '[:print:]\n' '.' < iterNNN.console | grep -v '^ECC' | tail -70
```

- **`ECC: No errors detected` at the end:** the text is clean. A reset boot's console ends at the
  last thing printed.
- **Garbled text:** run `python3 -I docs/ramoops-crash-debug/decode-ramoops.py iterNNN.console
  <reference dmesg> --tail 60`. Use the next good boot's log as the reference (same kernel and
  cmdline). Lines flagged `!!` are ones a good boot does not print.
- **Compare with a good boot of the same card:** `journalctl -k -b 0 -o short-monotonic`. Don't
  use `dmesg`, because with `initcall_debug` the ring buffer overflows. Find the last line of the
  reset boot and read what a good boot prints next. The reset falls in that window.
- **The last printed line can lag the real hang** by a message or two. Look at every probe in
  flight, including async ones (`scheduling asynchronous probe`).

## 5. Prove the suspect with an A/B

Keep the suspect driver from probing, using only a cmdline change:

```sh
grep -E 'initcall.*<driver>' /proc/kallsyms     # __initcall__kmod_<obj>__<n>_<line>_<fn>6 → use <fn>
# boot line: initcall_blacklist=<fn>             # the boot log shows "initcall <fn> blacklisted"
```

This works only for built-in (`=y`) drivers. Then loop for N clean reboots with `MAX_ITER=N`:
- **Pick N from the reset rate.** At a 50% rate, 8 clean reboots in a row has a 0.4% chance by luck.
- **Count resets with `count-resets.py`** (§4), never with the loop's verdict or `boot-count`.
- **Then build the fix and run the same loop on it.**

**To tell which part of a suspect resets the board,** put the variants in one debug patch behind a
`module_param` and pick one per run from the boot line, so a single card covers every arm. Run the
stock behaviour as the control first, on the same card. For a built-in driver the prefix is the
object name (`ufshcd_core.`, not `ufshcd.`). Log a line when the variant takes effect and check it
on every arm. `ufs-defer-hold.patch` is the worked example. Size each arm for its rate: 8 clean
reboots looked conclusive for both of its arms, and 16 more showed one of them was luck.

## 6. Clean up

- Revert the diff (it never ships).
- Restore the boot line: put the `grub.cfg.bak-*` backup back, or flash a new card.
- Delete the `0985` README row.

## Known noise

- **`[Firmware Bug]: Unable to handle paging request in EFI runtime service` at shutdown.** EFI
  `ResetSystem` faults, and Linux falls back to PSCI and reboots fine. Only the RAM console shows it,
  since it prints after the journal stops.
- **A full boot's console reads back as the whole raw zone** (699047 bytes on the FIT), decayed at
  the end. That is the salvage path, not a capture of interest.

## Case record: Pocket FIT, 2026-11-09

The FIT reset in about half its boots, with `panic=0`. Both captures ended in the same window:
- the async `sdhci_msm` probe of SDC2 (the boot card);
- a `ufshcd-qcom` probe that powered the host for 24 ms, then deferred because its PHY was not bound.

The PHY takes its reset from the host, so fw_devlink demotes the link and doesn't order the two.
`initcall_blacklist=ufs_qcom_pltform_init` gave 8/8 clean reboots. Fixed by
`kernel/patches/1089` (check for the PHY before powering up), which also gave 8/8.

**2026-11-10: which half of the teardown resets the board.** The trigger came from a peer distro,
which found that removing the UFS host with the device still active, cutting VCC under it, resets the
FIT. The deferred probe does the same thing at boot. A card without 1089 and with
`ufs-defer-hold.patch` ran three arms, counted with `count-resets.py`:

| `defer_hold` | Kept on through the teardown | Reboots | Resets |
|---|---|---|---|
| 0 | nothing (stock) | 8 | 3 |
| 1 | device supplies: VCC (L17B), VCCQ (L1C) | 24 | 0 |
| 2 | the 8 host clocks | 19 | 1 |

The arm 2 reset's console ends at the deferral, right after the clock holds, so the clocks running did
not stop it. The supply cut is the trigger: the bootloader leaves the UFS device running and VCC drops
under it. 1089 avoids it by deferring before anything is powered up. Any other deferral later in
`ufs_qcom_init()` would still cut the supplies.

The GDSC was never a candidate. `platform_probe()` powers the domain up and down around every probe
attempt, 1089's early deferral included, and 1089 passed.
