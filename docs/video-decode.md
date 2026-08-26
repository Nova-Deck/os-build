# Hardware video decode in the Steam UI — measured, and deliberately NOT used

**Conclusion on SM8250: do not enable CEF's V4L2 decode path. It is slower than plain CPU decode
and costs about 2.5x the total CPU.** This document exists so nobody re-derives the idea from
Valve's binaries and ships it again — the strings all point the right way, and the hardware
disagrees.

HW-measured on the MANGMI Pocket Max (SM8250), 2026-08-19.

> **Both VPU generations tested. SM8250 is harmful; SM8650 is pointless.** They fail differently
> and neither is worth shipping — see [SM8650](#sm8650-vpu3x--works-buys-nothing-declines-the-content-that-matters)
> below for the second board, measured on the AYANEO Pocket S2. SM8550 is formally untested but
> shares vpu3x with SM8650.

## The measurement

Same device, same UI, video playing, sampled over 5 s:

| | V4L2 path (`/dev/video-dec0` present) | CPU decode (no symlink) |
|---|---|---|
| VPU busy | **101% of wall** (saturated) | 0% |
| whole-SoC CPU | 50% of 8 cores | **18% of 8 cores** |
| CEF processes | ~101% of one core | **89% of one core** |
| how it looked | sluggish, visibly janky | fast |

The VPU genuinely decodes — it saturates, and the frames are real. It is simply worse end to end.
The likely mechanism is that the decoded NV12 DMABUFs do not import zero-copy into CEF's GL path,
so every frame is copied on the CPU *on top of* V4L2 buffer management — which is why the
hardware path burns more CPU than the software one it was supposed to replace.

(Discount ~5% of the 50% figure: repeated SSH logins inflated `systemd-logind`/`journald` during
that sample. The gap is still ~2.5x.)

### Caveat on the SM8250 CPU numbers

The two SM8250 samples were taken during *different* videos — the hardware one during a store
trailer, the software one during other playback — so the 50%-vs-18% gap may carry a content
difference as well as a decode-path one. What is NOT in doubt on that board is the perceptual
result: sluggish with the symlink, fast without, and flipping the symlink flipped it. Treat the
ratio as indicative and the direction as solid.

## SM8650 (vpu3x) — works, buys nothing, declines the content that matters

Measured on the AYANEO Pocket S2, 2026-08-19, mask on vs off across reboots on the same board:

| video playing | CPU decode | V4L2 path |
|---|---|---|
| VPU busy | idle | **101% of wall — genuinely decoding** |
| whole-SoC CPU | 11% of 8 cores | 11–12% |
| CEF processes | 46% of one core | 42–43% |

So on vpu3x the decoder works and is stable in steady state — but **it offloads nothing
measurable.** CPU is identical within noise while an extra engine runs, which means total power
almost certainly goes *up*. The point of hardware decode is to take work off the CPU; here it does
not.

Three findings make it worse than a wash:

1. **Store trailers do not use it at all.** Playing a Steam store page video with the symlink
   present: **zero decoder fds, VPU 0%**, 18% of 8 cores in software. CEF declines the V4L2 path
   for that content (likely codec/profile) and decodes on the CPU regardless. The 360p clip that
   did engage the VPU is not the use case; store trailers are, and for them the whole mechanism is
   inert.
2. **A reproducible stall at the logo→SteamUI transition.** Seen on both hardware-path boots: once
   as a long transition, once as an outright hang at logo end.
3. **One pathological run.** At 39 s uptime after the hung logo, the fd-holding CEF process burned
   **371% of one core** with `V4L2DevicePollerThread` among its hottest threads. Later steady-state
   runs did not reproduce it, so treat it as a startup-failure mode rather than the normal case —
   but it is the severe version of finding 2, not an unrelated blip.

## What actually switches it on

Not a Steam flag. **The `/dev/video-dec0` symlink.**

Chromium's legacy `V4L2VideoDecodeAccelerator` builds its device path from the ChromeOS
`/dev/video-dec` prefix, a name that only exists where udev is told to create it. iris registers
its nodes with `video_register_device(..., -1)`, so they come up as plain `/dev/videoN`. With no
symlink, no CEF process ever opens the decoder — verified by fd count. Create the symlink and the
legacy path finds it, takes over, and the UI gets slower.

The newer flat decoders are supposed to scan `/dev/video%d` and find iris unaided. On this client
they demonstrably do not: with the symlink removed, zero video fds are held. So on this libcef the
only reachable V4L2 pipeline is the legacy one, and the legacy one is the slow one.

## `-cef-enable-vaapi` is a no-op — do not add it back

It reads like the switch for this, and it changes nothing that matters. Diffing the webhelper argv
with and without it, the *only* difference is one feature name:

```
without: --enable-features=PlatformHEVCDecoderSupport,V4L2VideoDecode
with:    --enable-features=PlatformHEVCDecoderSupport,VaapiVideoDecodeLinuxGL,V4L2VideoDecode
```

`VaapiVideoDecodeLinuxGL` is meaningless here — Valve's arm64 `libcef.so` contains no VA-API at
all (it is built `use_v4l2_codec=true`), and VA-API is impossible on Adreno regardless: no video
engine, the VPU is separate silicon Mesa never touches.

Everything else is already the arm64 client's default: `--ignore-gpu-blocklist`, `V4L2VideoDecode`
in `--enable-features`, and **no** `--disable-accelerated-video-decode`. There was never anything
to turn on.

## `--gpu-launcher` is a dead end too

`steamclient.so` turns `$STEAM_CEF_GPU_CMD_PREFIX` into `--gpu-launcher='%s'`, which looks like a
way to inject an arbitrary Chromium switch. Chromium does not shell-parse that value, so the quotes
arrive literally and the path can never resolve — confirmed on device, the argv read
`--gpu-launcher='/usr/lib/novadeck/cef-gpu-launcher'`. It fails harmlessly (Chromium falls back to
the zygote) but it is not an injection point.

## What is still true and worth keeping

The kernel side works and is not in question. `ffmpeg -c:v h264_v4l2m2m` decodes through
`iris_driver` at ~34x realtime, and `ffmpeg`/`v4l2-ctl` are both on the image:

```sh
v4l2-ctl --list-devices
ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30:duration=5 -c:v libx264 -y /tmp/t.mp4
ffmpeg -c:v h264_v4l2m2m -i /tmp/t.mp4 -f null -
```

So iris is available to anything that wants it — a media player, a transcode job — just not to
CEF, where the integration is the problem rather than the decoder.

### Instruments worth reusing

- **`…/aa00000.video-codec/power/runtime_active_time`** counts only real streaming work. Calibrate
  before attributing: one 5 s 720p clip costs ~1880 ms. Open fds prove nothing — Chromium opens the
  node just to enumerate profiles.
- **Do not trust `--type=` in `/proc/*/cmdline`.** Zygote-forked children keep the *zygote's*
  command line, so the GPU process reads `--type=zygote` and `pgrep -f type=gpu-process` finds
  nothing. Identify it by its open `/dev/dri/render*` fds.
- **`systemctl restart sddm` does not restart the Steam client.** It reparents and survives, so a
  new session inherits the old argv. Check the client pid actually changed, or reboot.
- **`/etc/novadeck/session.conf` is sourced shell**, so `export NOVADECK_STEAM_ARGS=...` there gives
  a live A/B with no rebuild. It only takes effect on a real reboot, per the point above.

### Neutralising the symlink on a device that already has it

`/etc` is a writable overlay, so an empty file of the same name masks a shipped rule:

```sh
: > /etc/udev/rules.d/70-novadeck-iris-video-dec.rules
udevadm control --reload
```

## Retesting (SM8550, or any newer Steam client)

The switch is one udev rule, so the retest is cheap. On a card built before the revert the rule is
still in `/usr`; on a current build it is gone and has to be put back by hand:

```sh
# if a previous session masked it, unmask:
rm -f /etc/udev/rules.d/70-novadeck-iris-video-dec.rules
# on a current image, recreate it in the writable overlay:
printf '%s\n' 'SUBSYSTEM=="video4linux", ATTR{name}=="qcom-iris-decoder", SYMLINK+="video-dec0"' \
  > /etc/udev/rules.d/70-novadeck-iris-video-dec.rules
reboot
```

Confirm `ls -l /dev/video-dec0` exists, then play a video and take the same three numbers this
document compares: VPU `runtime_active_time` delta over a fixed window, whole-SoC CPU from
`/proc/stat`, and the CEF processes' own CPU. **Measure with the symlink present AND absent on the
same board** — the cross-board comparison is worthless on its own, because content and UI state
differ between sessions.

The result to beat is that board's OWN software baseline, measured in the same session — 18% of 8
cores on SM8250, 11% on SM8650. Two traps worth repeating, both of which bit here:

- **Use the same video in both conditions, and a demanding one.** A 360p clip decodes almost for
  free in software, so it cannot show an offload no matter what the hardware does. That is what
  made the first SM8650 comparison look like a wash.
- **Check the decoder is actually used for the content you care about** — `decoder fds` plus a VPU
  `runtime_active_time` delta, not just that the symlink exists. On SM8650 store trailers bypass
  the V4L2 path entirely, so a measurement taken on a trailer says nothing about the decoder.

If a future result genuinely beats that baseline, the rule can ship per-SoC — `device-env` already
resolves `NOVADECK_SOC_CLASS` per board.

## Offline check

`tests/test-video-decode.sh` (part of `make test`) is a **regression guard**: it asserts the
symlink rule is not in the overlay and the no-op flag is not in the launch args, and it keeps the
reasoning attached to the assertion so the next person finds this document instead of the strings.
