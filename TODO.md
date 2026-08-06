# novadeck — follow-up TODO

Deferred work — OPEN items only. Anything resolved moves to [DONE.md](DONE.md), which
keeps the full reasoning rather than a one-line epitaph: several closed entries are the
only written record of why a thing is shaped the way it is, and open items below cite
them. The full rationale otherwise lives in the linked memories and commit history.

## Open

- [ ] **The device sometimes reboots itself early in boot, and a SINGLE such reboot is enough to
  mark the slot invalid — but nothing on the device can currently record why.** USER-OBSERVED
  (recurring, 2026-08-06 and before): the unit reboots on its own well before SteamUI, usually once,
  and the next boot is fine. Two separate problems, and the second is what blocks fixing the first.
  - **Why one early reboot invalidates a slot.** GRUB increments `boot-attempts` in
    `($esp)/SteamOS/conf/<SLOT>.conf` on EVERY boot attempt, before the kernel starts
    (`boot/gen-grub-cfg.sh`, the `novadeck_bootattempts` call). `novadeck-boot-good` clears it only
    once the session proves healthy (`novadeck-bootctl mark-good --require-marker`). A reboot that
    happens before SteamUI therefore never clears the counter, and the threshold in
    `fs-overlay/usr/bin/novadeck-bootctl:150` is `[ "$tries" -ge 1 ] || [ "$invalid" -gt 0 ]` —
    **one** uncleared attempt is enough, and the fallback arm then writes `image-invalid 1`. This is
    arguably correct behaviour; it is recorded here because it makes a rare early reboot look like a
    slot-integrity failure, and it is a plausible source of otherwise-unexplained slot demotions and
    of an update client deciding a slot needs reinstalling.
  - **The fault is invisible by construction, and this was checked the hard way 2026-08-06 by
    pulling the card.** THREE independent recorders are all unavailable at that point in boot:
    - the journal IS persistent, but it lives at
      `/home/.novadeck/offload/var/log/journal` — an OFFLOAD BIND onto the home partition, NOT
      `novadeck-var-{A,B}/log/`, which are empty (look in the wrong place and you will wrongly
      conclude journald is volatile). Persistence cannot begin until that mount is up, so a crash
      before `systemd-journal-flush` writes nothing. Confirmed: all 8 most recent boots end with
      clean shutdown tails (unmounts, BPF unload) — not one abruptly-terminated boot is recorded,
      despite the symptom recurring.
    - `/sys/fs/pstore` is EMPTY: `systemd-pstore` logs `Platform Persistent Storage Archival was
      skipped ... (ConditionDirectoryNotEmpty=/sys/fs/pstore)`, and `efi_pstore` is skipped too.
      There is no `ramoops` reserved-memory node in our DTs, so nothing survives the reset.
    - no UART on this hardware ([[sm8650-no-uart]]) and no root on release units by design.
  - **`panic=5` turns a panic into exactly this symptom.** The kernel cmdline carries `panic=5`, so
    a panic auto-reboots after 5s with nothing on screen. That does not cause the fault, but it
    converts a diagnosable stop into a silent reboot that usually succeeds on retry — i.e. it is
    consistent with every detail of the report, and means "reboots once then works" tells us
    nothing about whether it was a panic, a watchdog bite, or a PMIC reset.
  - **Fix the recorder FIRST, then the bug.** Add a `ramoops` reserved-memory region to the
    SM8550/SM8650 DTs; `systemd-pstore` is already enabled and will archive the previous boot's
    panic tail into the (persistent, offloaded) journal automatically. Without that, every
    investigation ends where 2026-08-06's did: no reset reason, no crash tail, nothing to read.
  - **Adjacent, probably unrelated, recorded so it is not re-discovered as a lead:** every boot logs
    `CPU features: SANITY CHECK: Unexpected variation in SYS_ID_AA64MMFR1_EL1` between the boot CPU
    and CPUs 2-7 (`0x...11312122` vs `0x...10312122`) — a big.LITTLE ID-register mismatch. It is
    present on boots that come up fine, so it is not by itself the trigger.

- [ ] **A boot-time Steam client self-update paints NOTHING — the screen is black for minutes with
  no progress, and a power-cycle during it corrupts the download.** OBSERVED 2026-08-06 on a
  release unit (v0.2.1, slot A) taking client `1785347151` -> `1785979169`.
  - **Why there is no progress bar, and why it is not a bug in the session.** Steam's client update
    runs in its BOOTSTRAP, before the renderer exists: `~/.local/share/Steam/logs/bootstrap_log.txt`
    logged `Found pending update` / `Installing update...` / `Extracting package...` while
    `pgrep steamwebhelper` returned ZERO. The progress dialog is drawn by Steam's own UI, so during
    the one phase that most needs feedback there is nothing alive to draw it. Everything else was
    healthy and was checked: `plymouthd` had already exited (so it was NOT starving DRM master),
    `sddm` was active running `novadeck-session` with autologin, and `steam` was correctly parented
    to `novadeck-steam`. The screen had nothing drawing to it — it was not wedged.
  - **Cost measured:** ~3-4 minutes of black screen, ending when Steam re-execs itself (the exit-42
    restart loop — `steam`'s ELAPSED went DOWN, 78s -> 45s, and `steamwebhelper` appeared). Longer
    when a previous download was interrupted: this run also had to recover from
    `Error: Download failed: http error 0` plus an `uninstalled manifest found`, because a reboot
    had landed mid-download.
  - **The failure loop is what makes it worth fixing.** A black unresponsive screen after boot
    invites exactly one user action — hold the power button — which interrupts the download and
    guarantees a longer, messier recovery on the next boot. It is self-reinforcing, and on a
    handheld with no visible activity indicator there is no way to tell it apart from a hang.
  - **The obvious fix collides with a known constraint.** Holding the splash until Steam's first
    frame runs straight into [[boot-splash-plymouth]]: `plymouthd` starves gamescope's DRM master
    and MUST be released as root before `sddm`. So this needs a surface that is not plymouth's, or
    a handoff, not a one-line ordering change. Do not "fix" it by delaying the plymouth quit.
  - **How to reproduce deterministically:** stage a client bump into the seed
    (`steam-seed/fetch-steam-seed.sh` restages whenever Valve's rolling channel moves), boot, and
    watch the panel while tailing `bootstrap_log.txt` over SSH. Note that `make` alone will NOT
    re-fetch the seed: `$(STEAM_SEED)`'s only prerequisites are `STEAM_SEED.pin` and the fetcher,
    and the pin is deliberately version-less (both channels are live rolling pointers), so a client
    bump changes no file make can see. Run `steam-seed/fetch-steam-seed.sh` explicitly — its own
    live-vs-staged check is what detects the bump.

- [ ] **The night-mode atom workaround INVERTS if Steam fixes its property packing — re-check on
  every client update.** `packages/gamescope/patches/0002` decodes
  `GAMESCOPE_COLOR_NIGHT_MODE` as `[amount, saturation]` and pins the hue, because the arm64 client
  mis-packs the property for Xlib's `format=32` LP64 ABI: `XChangeProperty` transmits the low 32
  bits of each `long`, the client passes a 12-byte `float[3] {amount, hue, saturation}`, so Xlib
  reads three 8-byte longs off it and the wire becomes `[amount, saturation, overread]`. The hue is
  computed and then destroyed in transit; `vec[2]` is an out-of-bounds read of the client's stack.
  - **A fixed client sends a correct `[amount, hue, saturation]` and our patch then reads the real
    hue as saturation and forces amber over it.** Peak Saturation goes wrong, Primary Hue stays
    dead. The failure is quiet: our `clamp` turns the mis-decode into a plausible-looking value
    rather than an obviously broken screen, so it will not announce itself.
  - **There is no reliable runtime sniff.** A legitimate `vec[2]` in `[0,1]` and random heap bits
    are not distinguishable — a large share of float bit patterns land in `[0,1]` — and a fixed
    client still declares `nelements=3`, so gamescope's `size()==3` guard cannot tell them apart
    either. Auto-detection is not on the table; this has to be a human re-check.
  - **How to re-check** (from [[nightmode-atom-is-amount-saturation]]): all sliders to min, night
    mode ON, change-only `xprop` monitor, then sweep each control. If "Primary Hue" has come alive
    and `vec[2]` has become stable and in-range, the client is fixed — drop the patch entirely
    rather than adjusting it. Verifying from the screen instead of the atom does not work.
  - Upstream is expected to fix this in the client, so the patch is meant to be temporary. It has
    no expiry mechanism, which is why it is tracked here.

- [ ] **Pocket FIT touch works via `=m` timing, not via a declared dependency — make the chipone
  probe defer.** HW-VALIDATED 2026-08-04: flipping `CONFIG_TOUCHSCREEN_CHIPONE_TDDI` to `=m`
  restored the touchscreen and cut the boot (the built-in probe was burning ~18.6s of the 20.9s
  kernel phase, with PCIe/UFS/DRM queued behind it). That is ROCKNIX parity — they ship the same
  driver as an out-of-tree `.ko` against a byte-identical touch node — **but it is timing, not a
  guarantee.** The controller is a TDDI part powered off the panel rails, and the driver still
  declares no supply and no ordering: it just happens to be udev-loaded after the msm DRM panel
  driver binds. Anything that reorders userspace bring-up can put it back in front of the panel,
  and the failure mode is silent and total — three 5.1s I2C `-110` retries, probe fails `-19`,
  touch absent for the session, no retry ever.
  - The real fix is to make the probe **defer** instead of dying on first failure: declare the
    panel supply on the touch node and have the ported driver request it (regulator core then
    returns `-EPROBE_DEFER` until it exists), or map the `-110` to `-EPROBE_DEFER` directly.
    Either way the driver retries instead of giving up, and `=y` becomes safe again.
  - Worth checking whether the retry loop should be that expensive at all: 3 × 5.1s is a long
    time to spend proving an unpowered part is unpowered, even off the critical path.
  - `=m` is asserted in `kernel/build.sh`'s config-parity loop — kconfig silently promotes a
    module to built-in when an `=y` symbol selects it, and that regression costs both the
    touchscreen and the boot. See [[chipone-tddi-must-be-a-module]].

- [ ] **`scx_lavd` is OFF by default as of 2026-08-03 — investigate the reported in-game
  performance regression before turning it back on.** Users reported worse in-game performance
  with lavd, so `DEFAULT_CPU_SCHEDULER` in `fs-overlay/usr/bin/novadeck-powerd` went back to
  `"none"` (stock EEVDF). **This is a report, not a measurement — nothing here has been profiled.**
  Everything else about the sched_ext stack is unchanged and still works: the kernel half, the
  package, `scx.service` (still never `enable`d), the `CpuScheduler1` property and
  `novadeck-scheduler lavd`. Only the fresh-device default moved.
  - **A device that already booted the lavd default keeps lavd.** `save_state()` persists
    `cpu_scheduler=` on any property write, and an explicit saved value outranks the default in
    both directions. No state migration was written (nothing public has shipped, same call as when
    lavd became the default). Test devices need one `novadeck-scheduler none`, and a bench run
    must check `novadeck-scheduler status` first rather than assuming the new default is in force.
  - **Reproduce and quantify before deciding anything.** Wanted: a frame-time capture (MangoHud
    log, not eyeballed FPS) on the same title, same power profile, same governor, lavd vs none,
    ideally both orders to rule out thermal drift. Note whether the title is native arm64, Proton,
    or system-FEX x86 — lavd's latency heuristics and FEX's thread behaviour are a plausible
    interaction and the three paths should not be assumed to behave alike.
  - **Suspects worth checking first, cheapest to most expensive.** (1) `--autopower`: lavd's
    internal power mode follows `PowerProfiles.ActiveProfile`, and it gives up on that coupling
    **permanently and silently** on an unknown profile value — a device stuck in powersave mode
    would look exactly like this report. Diagnose with `scx_lavd --monitor 1`; the give-up path
    logs nothing, so the journal cannot see it ([[novadeck-ppd-shim-for-scx-autopower]]).
    (2) scx 1.1.2 is pinned and old — the kernel already warns `Writing directly to
    p->scx.slice/dsq_vtime is deprecated` against its BPF code; try a version bump before
    concluding lavd is wrong for this SoC. (3) little/big topology: check lavd is reading this
    SoC's core layout sanely rather than treating it as uniform.
  - Re-enabling by default is a one-line revert of `DEFAULT_CPU_SCHEDULER` plus the comment blocks
    in `novadeck-powerd`, `novadeck-scheduler` and `images/customize-base.sh` that state the
    default. Do it only on measured evidence. See [[scx-sched-bringup]].

- [ ] **The device runs at least THREE mDNS participants — decide who owns 5353.** Every
  `avahi-daemon` start logs `*** WARNING: Detected another IPv4 mDNS stack running on this host ***`
  (and the IPv6 twin); avahi itself calls this unreliable. Measured on the device 2026-07-29, so
  this is not inference:
  - `avahi-daemon` — active, and the one that publishes our `_steamos-devkit._tcp` pairing advert
    (`Service "novadeck" ... successfully established`).
  - `systemd-resolved` — active, with `Current Scopes: DNS LLMNR/IPv4 mDNS/IPv4`, i.e. its own
    MulticastDNS responder is on.
  - **`steamwebhelper`** — bound to `224.0.0.251:5353` (`ss -lunp`, pid 930). This one is the
    surprise and it changes the fix: that is almost certainly Steam's own local-network discovery
    (Remote Play), so "disable the other responder" is NOT safe advice — killing it may break
    Remote Play. Whatever we turn off must be chosen with that in mind.
  `ss` was run as `deck`, so only the `deck`-owned socket could be attributed; the remaining
  `0.0.0.0:5353` and `*:5353` listeners are root-owned and were left unidentified. **Re-run
  `ss -lunp | grep 5353` as root** to finish the census before changing anything. Not blocking:
  discovery worked throughout the remote-access validation (`novadeck.local` resolves, pairing
  endpoint reachable by name). But several responders answering for one name is a coin-flip we have
  not characterised, and mDNS is how a user finds the device without reading an address off the
  on-screen network settings. Likely landing: keep avahi as the publisher, turn off resolved's
  MulticastDNS, leave Steam's alone. Same shape as the networkd/NM double-stack deadlock in
  [[test-image-grow-and-networkd-gaps]]. NB `avahi-browse` on the dev workstation cannot verify any
  of this — see [[avahi-browse-dead-instrument]].

- [ ] **Nothing ends an unconfirmed trial — the rollback is automatic ON NEXT BOOT, not on failure**
  — found on hardware 2026-07-28 while testing the rollback branch, by noticing the device simply
  sat there. The confirm mechanism is ASYMMETRIC: `novadeck-boot-good.path`/`.service` is purely a
  confirmer, and there is no negative counterpart. Nothing observes "the session never came up" and
  acts on it. Verified in the tree: no `RuntimeWatchdogSec`/`RebootWatchdogSec` anywhere under
  `fs-overlay/etc/systemd/`, and no novadeck timer or watchdog unit exists. A hardware watchdog
  would not help even if armed — the OS is healthy and systemd would keep petting it; only the
  session is missing.
  **Measured:** a trial slot booted with `sddm` masked sat at `slot=b source=try tries_left=0`
  indefinitely, well past the 30s `ExecStartPre` in `novadeck-boot-good.service`, with `pending=b`
  still armed. Correct, but inert.
  **Field consequence:** update installs → reboots → black screen → stays black until the user
  holds the power button → *then* it recovers. Recovery works and the state machine is right, but
  the window before it is UNBOUNDED, and a device left on a black screen just drains its battery.
  On a board with no serial console the user's only signal is that black screen.
  **Why this is not a quick patch.** A timer that force-reboots an unconfirmed trial after N
  minutes closes it, but collides head-on with the tension `novadeck-boot-good.service` already
  documents: a legitimately slow first boot — OOBE, an offline Steam start, a large shader compile
  — must not be rebooted out from under the user. Picking N is a real decision and too-aggressive
  is worse than the current gap. Note the existing comment there argues against a timeout that
  marks GOOD; this is the opposite direction (a timeout that gives UP) and needs its own argument,
  not that one inverted.

  **DECISION 2026-08-03: the SteamUI update button ships WITHOUT this closed.** Accepted and
  tracked, deliberately not mitigated. The failure needs a bad bundle to trigger, we control what
  is published, and every bundle gets a hardware install before it reaches the server — so the
  exposure is gated by the release process rather than by the device. Revisit when anyone other
  than us can publish, or when the first bundle ships to a device we cannot physically reach.

  **Two findings from that decision (2026-08-03), both of which narrow the solution space:**

  1. **A message on screen is NOT a mitigation, and the reason is not "delivery is unreliable".**
     The most likely cause of "the session never came up" after an OS update is a display-stack
     regression — kernel, mesa and gamescope are exactly what a bundle carries. In that case the
     thing that would draw the warning is broken by the same fault that made the warning necessary.
     The mitigation fails *correlated* with the failure it reports, so for the dominant case it is
     not partial coverage, it is no coverage. Any fix has to be display-independent.
  2. **Phase 5 removed the signal a give-up timer would need to arm on.** `images/initramfs/init:189`
     now writes `source=grub` on EVERY boot, and the stage-2 GRUB module increments `boot-attempts`
     on every boot, so from userspace a post-update trial is indistinguishable from an OOBE first
     boot — every boot looks unconfirmed until `mark-good` runs. That is what makes "arm the timer
     only on a trial" (which would dodge the slow-first-boot collision entirely) impossible today.
     The bootconf carries an `update` bool, but `_reference/steamos-efi/chainloader/config.c:44`
     marks the whole update group deprecated, so building on it is borrowing trouble.
     **Fix sketch:** `post-install.sh` already runs after every install and already writes the
     bootconf — have it record "this slot is on trial from an update", and have `mark-good` clear
     it. Small, explicit, ours.

  **The reframing that makes a timer defensible**, and the reason "picking N is a real decision"
  overstates the difficulty: a timer is NOT adjudicating "is this slot good". It is supplying the
  boot attempts the failsafe already requires and that nothing currently generates. Recovery today
  is guaranteed but stalled — the failsafe shows a menu at >=3 attempts and auto-picks the other
  slot at >=6, and a counter of BOOT ATTEMPTS only advances when something causes a boot. A timer
  turns ~6 human power-cycles into automatic ones, or into one if it calls `set-state self bad`
  directly instead of feeding the counter. The cost asymmetry is the argument: a misfire on a
  genuinely slow boot costs one reboot and a rolled-back good update, which the user can simply
  re-apply; not firing costs an unbounded black screen and a flat battery.

- [ ] **Third-party prebuilt tarballs unpack at `/` — nothing constrains what they place there** —
  found 2026-07-26 while root-causing a real ownership bug. `packages/inputplumber/prebuilt.pin`
  declares no `dest:`, so `images/customize-base.sh` extracts it at `/` with
  `--strip-components=1`. It is a sha256-pinned archive, so its CONTENT cannot change under us —
  but nothing says what paths it is allowed to contain, and a root `tar -x` applies whatever
  ownership, modes and paths the archive carries. That is exactly how `/usr`, `/usr/bin`,
  `/usr/lib` and `/usr/share` came to be owned by uid **1001** (the upstream CI builder) on every
  image built to date: the tarball is `1001/1001` throughout and its bare `usr/` directory entry
  chowned ours. Fixed at the extraction (`tar --no-same-owner`, commit `1254f1b`), which closes
  the ownership half — the PATH half is still open. Phase 4c made every *package* row traceable
  to a hashed file; the 4 prebuilt rows are hashed too, but they are opaque blobs rather than a
  file manifest, so they are the one remaining way for content to land in the root without
  anything declaring what it is. **Options, cheapest first:** give the pin a `dest:` and refuse
  `/` (InputPlumber's payload is all `/usr`, so `dest: /usr` + `strip: 2` would do); or record a
  per-pin allowed-path prefix and assert the archive against it before extraction; or convert the
  prebuilts into real `[novadeck]` packages, which is the proper fix and the most work.
  See [[rootfs-build-approach]], [[overlay-package-pipeline]].

- [ ] **`images/guard-rootfs.sh` asserts PACKAGES, never FILES — no ownership or mode check** —
  the 1001-owned `/usr` above passed every guard assertion on every build, because all five ask
  about the package set and the seal, not about the bytes. This is the second time this repo has
  shipped a correct-diff/wrong-tree defect of exactly this shape: the first was the git-644 mode
  regression that blacked out the OOBE ([[gamescope-x11-unix-tmpfiles-oobe]]), whose own lesson
  was recorded as "diff the MODE manifest of built trees". That lesson never became an assertion.
  Note `assemble-rootfs.sh` step 4z is NOT this check — it reclaims only the repo-checkout uid
  (dynamically `stat`'d off the script), so it silently ignored 1001 while its comment cites the
  identical HW symptom for uid 1000 ("systemd-tmpfiles: unsafe path transition /etc (owned by
  deck)"). **Shape of the fix:** a sixth assertion that every path in the staged tree is owned by
  root or by a uid that exists in the tree's own `/etc/passwd`, plus no unexpected setuid/setgid.
  Cheap (one `find`), and it is the assertion that would have caught this without a person
  reading `stat` output by hand. See [[folder-refactor-fs-overlay]].

- [ ] **Pocket DS: SY7758 backlight has no `enable-gpios` → panel will defer (no display)** — the
  upstream `silergy,sy7758` driver requires `enable-gpios` to bind (root cause of the Pocket ACE blue
  screen, fixed 2026-07-13 for ace/s2k/s1k with `enable-gpios = <&tlmm 41 GPIO_ACTIVE_HIGH>`). The
  Pocket DS node (`qcs8550-ayaneo-pocketds.dts:129` `backlight: backlight@2e`) has **no enable GPIO and
  no `backlight_pwr_active` pinctrl** to derive one from — unlike the other AYANEO boards. Its I2C bus
  carries a **`tca6408` GPIO expander** (`tca64_20@20`), so the DS backlight enable is most likely an
  **expander pin** (`enable-gpios = <&tca6408 N GPIO_ACTIVE_HIGH>`), not a tlmm gpio — pin N unknown,
  needs the DS schematic or a reference. Not in Armada's fix commit (a537fbae, which only did
  ace/s2k). Without it the AR-class DS panel(s) will sit in deferred-probe exactly like ace did. See
  [[sm8550-bringup-pickup]].

- [ ] **PMIC RTC probe defers forever → no `/dev/rtc` (SM8650 ayaneo boards)** — HW-confirmed on
  Pocket S2 (2026-07-12), **re-confirmed 2026-08-03** on the trimmed 7.1.6 kernel: `devices_deferred`
  still holds `c400000.spmi:pmic@0:rtc@6100`, so it survives both the 7.1.6 bump and the Kconfig
  platform trim (`CONFIG_EFI` is untouched by the trim — it is not behind any `ARCH_*` gate). This is
  also the mechanism behind [[journalctl-boot-index-broken-stale-rtc]]: no RTC means a stale clock,
  which breaks `journalctl -b -1` — query by `_BOOT_ID=` instead.
  The entry reads "reason unknown" and there is no `/dev/rtc0`. Root cause: `sm8650-ayaneo-common.dtsi` sets
  `qcom,uefi-rtc-info` on `&pmk8550_rtc`. That property makes `rtc-pm8xxx` read the RTC offset from a
  UEFI variable; with `CONFIG_EFI=y` on a device that is **not** UEFI-booted (`efi: UEFI not found` —
  we boot via ABL android-bootimg), `pm8xxx_rtc_probe_offset()` hits
  `if (!efivar_is_available()) { if (IS_ENABLED(CONFIG_EFI)) return -EPROBE_DEFER; }`
  (`drivers/rtc/rtc-pm8xxx.c:584`) and defers permanently — efivars never appear.
  Fix: drop `qcom,uefi-rtc-info` from the `&pmk8550_rtc` override (keep `qcom,no-alarm` + `status`).
  The RTC then binds offset-less (read-only, offset=0) and `/dev/rtc0` appears; `systemd-timesyncd`
  already owns wall-clock so nothing else regresses. Impact is cosmetic today (NTP fixes the clock
  seconds after Wi-Fi), which is why it's parked — but it's a one-line DTS change on the next kernel
  build. Property arrived with the unified-image refactor (`a6fc71f`); only in this one dtsi.

- [ ] **Decide how `vblank_mode=3` ships — per-title launch option or session-wide default** —
  follow-up to the resolved "One title (Gravity Circuit) not paced by the frame limiter" item in
  DONE.md, where it is proven as a FIX but is currently applied by
  hand as a Steam launch option, i.e. every affected title needs a user to know the trick. Options:
  (a) export `vblank_mode=3` from the session so every Mesa GL client is pacing-eligible by
  construction — under gamescope a client presenting faster than the compositor consumes is doing
  wasted work anyway, so forcing sync-to-vblank there is defensible; (b) leave it per-title and just
  document it. Caveats for (a): it is a **Mesa driconf** knob, so it reaches only titles rendering
  through our Mesa GL — a bundled or non-Mesa GL stack ignores it, and it does nothing for Vulkan; it
  must land in the GAME's environment (Steam launch options do this today, a session-level export would
  too); and a per-title launch option can still override it. Regression canary if (a) is taken: the
  OpenGL3 title that ALREADY caps correctly (Parking Garage Circuit) — it must keep capping and must
  not lose frames to a forced wait. No rebuild either way, this is an env decision.

- [ ] **D3D11 title runs on wined3d → OpenGL instead of DXVK under our Proton** — split out of the
  Gravity Circuit pacing item in DONE.md, where it was a parenthetical; it is the bigger perf
  problem of the two and is
  entirely unrelated to the frame cap. Gravity Circuit maps ZERO vulkan libs under
  proton-cachyos-11.0-arm64, i.e. it is going through wined3d's GL path rather than DXVK on Turnip —
  so it pays a translation layer we have a working Vulkan driver for. Unexplained: whether this is
  DXVK missing/failing to load in the arm64 Proton build, a per-title Proton config, or the title
  requesting a feature level DXVK declines. Start by checking the title's `steam-<appid>.log` /
  `PROTON_LOG=1` output for a DXVK init failure before assuming the build lacks it.

- [ ] **Suspend polish: robust panel blank** (fan-off DONE) — follow-up from the 2026-07-05 HW pass,
  cosmetic (freeze/wake itself is solid):
  - [x] **Fan keeps spinning during fake-suspend — DONE + HW-validated 2026-07-14.** Superseded the
    planned `power-ops.sh` fan-off op: `novadeck-powerd` now OWNS the fan, and `novadeck-suspend` calls
    its `Suspend()`/`Resume()` (busctl) around the freeze — powerd is in system.slice so it answers while
    user.slice is frozen. HW-confirmed: fan stops on sleep, restarts on wake. Skippable via
    `NOVADECK_SUSPEND_SKIP="powerd"`. See [[power-profiles-device-env-stack]].
  - **Our `gamescopectl` panel-blank path logs "unreachable"** when `novadeck-suspend` runs as
    `systemd-suspend.service` (root, system.slice) — it can't resolve the live gamescope socket. Add a
    `bl_power` fallback (`echo 4 > /sys/class/backlight/*/bl_power` on suspend, `0` on resume) so a
    blank still happens without Steam. **HW 2026-07-26 — no longer hypothetical.** A full cycle entered
    via `systemctl suspend` (i.e. bypassing Steam's own blank) left the panel **lit for the entire
    ~70s frozen window**, user-visible: engine logged `no live gamescope socket` → `gamescopectl
    unreachable; panel unchanged` → `panel blank NOT confirmed in 30ds; freezing anyway`, and the
    recorder read `panel=enabled` on all 43 frozen samples. So the only thing blanking the screen today
    is Steam's sleep flow; every other entry point (idle timeout, a direct `Suspend()`, anything that
    lands here without the client's blank) sleeps with the backlight ON. Note it also costs 8s of the
    suspend path — 5s socket-resolve + a 3s `wait_panel` timeout — before the freeze even starts.
    See [[sm8650-gamescope-flip-blocker]].

- [ ] 🍒 **Cherry on top: install to internal UFS + SD card as game library** — today NovaDeck
  runs from a dd'd SD-card image (Phase 1). Ultimately we want a real **installer that lays the
  image down on the device's internal UFS** (like SteamOS on the Deck's internal drive), and then
  repurposes the **SD card as an external Steam game library**. SteamOS already ships the format
  helpers for the library step — `steamos-format-sdcard` / `steamos-format-device` (seen in the
  baked `steamui.so` strings next to the OOBE update helpers), called by Settings > Storage — which
  we have NOT wired up yet (candidate to port). Our ext4 `novadeck-home` already matches SteamOS
  (plain-dir libraries, no btrfs nodatacow dance — Armada's `steamapps` subvolume is Armada-only, do
  not port). Fits the Phase-4 manifest/immutable model. See
  [[install-to-ufs-sdcard-library-goal]], [[grow-home-repart-no-initramfs]], [[rootfs-build-approach]].
  - **Dependency, park until then: port the upstream fstab-repair one-shot.** The reference
    platform ships a tiny unit that comments out `/dev/mmcblk* none …` lines in `/etc/fstab`
    (upstream `ValveSoftware/SteamOS#1208`): their SD-card format helper writes such entries, they
    are invalid, and they stop UDisks mounting the card at all. It is NOT needed today — nothing on
    our image writes `/etc/fstab` at runtime, only `images/assemble-rootfs.sh` at build time — but it
    becomes needed the moment we ship the format helper above, because that is what creates the bad
    entries. Cheap when the time comes: the whole thing is a 10-line `sed` plus a unit gated on
    `ConditionPathExists=/var/lib/overlays/etc/upper/fstab`, which is *already* our /etc overlay
    upper path, so it drops in unmodified. Reviewed 2026-07-30 against upstream
    `holo-PKGBUILD/holo-fstab-repair`; do not ship it before the helper, or it is a unit that
    guards against a state we cannot reach.

- [ ] **Decompose `images/assemble-rootfs.sh` into named sub-stages** — build-infra hygiene, no
  behaviour change. At **733 lines** it is ~2x the next-largest script (`customize-base.sh`, 418) and
  is brushing our 800-line ceiling; it is also the pipeline's single coupling point, staging base
  userspace + kernel/dtbs/modules + both firmware sets + `fs-overlay/` + first-boot storage + offload
  mounts + test-only Wi-Fi/SSH injection + debug capture + ownership normalization, then carving
  `var.img` and baking `rootfs.img`. The structure is **already there as comment banners** (`# 1.`
  base, `# 2/2b/2c` kernel/modules/`/efi`, `# 3/3b` qcom + linux firmware, `# 4/4b` marker + overlay,
  `# 4g` grow-home, `# 4h` offload, `# 4c` test-only, `# 4d` debug, `# 4z` chown, `# 5` var carve,
  `# 6` btrfs bake) — the work is promoting each to a named function or sourced helper under
  `images/`, keeping `assemble-rootfs.sh` as the entry point and the existing per-section rationale
  comments intact. Payoff is that the test-only and debug injections become separable from the
  release path by construction rather than by an `if`, which matters as RAUC lands. Only substantive
  finding salvaged from the Copilot architecture-review PR (`Nova-Deck/os-build#2`, closed
  2026-07-24 — its other four recommendations were already implemented: artifact paths are
  centralized at `Makefile:92-99`, `ROOTFS_MODE` is already derived + stamped at `Makefile:54`, and
  the stage `README.md`s already document per-script inputs/outputs/env). Relates to
  [[folder-refactor-fs-overlay]], [[rootfs-build-approach]].

- [ ] **Residual foreign-hardware drivers that the ARCH gates do NOT reach** — the platform-gate trim
  above cannot touch drivers whose Kconfig has no `ARCH_*` dependency, and a measurable block survives:
  **~7.2 MiB across 22 modules** in `net/ethernet` + `net/dsa`, for NICs and switches that cannot exist
  on these handhelds — Mellanox datacenter NICs, Amazon ENA, Xilinx, STMicro, and a Broadcom
  GENET/SYSTEMPORT/B53/SF2 block (`MDIO_BCM_UNIMAC` only `depends on HAS_IOMEM`, so it survived as `=m`
  once its Broadcom selectors went modular). Same story likely in `sound/` (107 modules remain) and
  parts of `drivers/`. This is a **separate judgement call** from the gate trim: cutting it means
  per-driver negatives, which is exactly the rotting list `trim-platforms.config`'s header warns
  against — so it wants its own decision on where the line sits, not a reflex extension. Deferred out
  of the 2026-08-03 pass deliberately; `card/v0.2.0` does not block on it.

- [ ] **In-session splash client — cover the gamescope→Steam black gap (and decide plymouth's fate)**
  — boot currently ends in ~10s of black: gamescope's first modeset lands at ~15s and Steam does not
  paint its UI until ~25s. That tail is the part that reads as "did this hang?", because it sits
  immediately before the UI appears. **No plymouth setting can reach it.** DRM master is exclusive,
  so plymouthd must be gone before the compositor can paint at all, and `--retain-splash` only skips
  the explicit clear (`main.c:1502`) — `quit_splash()` still closes the DRM fd, after which the
  kernel's fbdev emulation (`[drm] fb0: msmdrmfb`) restores a blank console over the retained frame.
  The fix has to live INSIDE the session: a fullscreen client that paints the logo on gamescope's
  nested display, started by `novadeck-session` right after the startup handshake and torn down when
  Steam's first window appears. Cheap by comparison — no initramfs growth, no source-built package,
  no patched upstream, no DRM-master ordering invariant.
  **This item also decides whether plymouth is worth keeping at all** (`feat/plymouth-splash`,
  HW-validated but deliberately unmerged as of 2026-07-25). plymouth covers ~4s→15s, i.e. boot's
  FIRST half — the half nobody complained about — and costs a from-source overlay package, an
  unsubmitted upstream NULL-deref patch that must be re-verified on every bump, ~1.9M of initramfs,
  four cmdline requirements (`rhgb`, `plymouth.ignore-udev`, `loglevel=3`,
  `vt.global_cursor_default=0`), and an ordering invariant anyone touching the session can break.
  Build the in-session client FIRST, then judge: if the boot feels fine with black at the front,
  delete the branch; if the front-half black still grates, merge it then.
  See [[boot-splash-plymouth]], [[sm8650-gamescope-session-plumbing]].

