# Plan: Sunshine + Moonlight on novadeck, for non-Steam games

**Goal**: Remote Play Together for the games Steam cannot invite to (Epic, GOG). A novadeck **hosts**
with Sunshine. Friends **join** with Moonlight, from another novadeck (shipped Moonlight) or any device.
**Branch**: `sunshine-streaming`, one commit per step.
**Complexity**: Large. Kernel (iris gen1, encode and decode), three new packages (qcom-va-driver,
Sunshine, Moonlight-qt), a capture question under gamescope, and a QAM surface.

User decisions (2026-11-20):
- **Both sides ship on novadeck: Sunshine (host) and Moonlight (client).**
- **SM8250 (gen1, Pocket Max) is tested first.** It is the hard case.
- **If SM8250 encode fails, qcom-va-driver still ships for decode** (the Moonlight side).

## Verified before planning

### Host (Sunshine)

| Fact | Evidence |
|---|---|
| Sunshine has no V4L2 encoder. Its Linux encoders are nvenc, vaapi, vulkan, software | `_reference/sunshine` 00a2994, `src/video.cpp:1302,1366` |
| Sunshine's probe needs the first packet to be an IDR, and rewrites the SPS inside IDR packets | `video.cpp:3156`, `:1934` |
| Mesa ships no VA driver for freedreno; turnip has no `VK_KHR_video*`. Moonshine (another host) needs Vulkan encode: out | Mesa 26.3.0 `meson.build:840`; `_reference/moonshine` e6a7391 |
| Sunshine reads PipeWire only through the portal or KWin, which gamescope has neither of. KMS capture reads one plane | `src/platform/linux/misc.cpp:1474-1505`, `portalgrab.cpp`, `kwingrab.cpp` |

### Client (Moonlight-qt)

| Fact | Evidence |
|---|---|
| Linux hardware decode goes through FFmpeg: VAAPI/VDPAU/CUDA hwaccels, or non-hwaccel decoders including `h264_v4l2m2m`/`hevc_v4l2m2m` | `_reference/moonlight-qt` 2dc63d1, `app/streaming/video/ffmpeg.cpp:130-141` |
| Upstream ffmpeg's v4l2m2m **decoder** outputs system-memory frames only (no DRM_PRIME), so every frame is CPU-copied for display: the CEF failure mode on SM8250 | `_reference/ffmpeg` 8.1.1 `libavcodec/v4l2_m2m_dec.c` |
| The VAAPI renderer exports surfaces as dmabufs (`vaExportSurfaceHandle`) for zero-copy EGL import; qcom-va-driver implements that export (PRIME2) | `ffmpeg-renderers/vaapi.cpp`, `qcom-va-driver/src/backend.cpp:1111,1256` |
| Moonlight honours a preset `LIBVA_DRIVER_NAME`, and has no vendor gate that would reject qcom-va-driver | `vaapi.cpp:283-340,401-440` |

### qcom-va-driver and iris

| Fact | Evidence |
|---|---|
| **qcom-va-driver** (Radxa, MIT) is a VA-API driver over iris V4L2. H.264/HEVC Main encode, H.264/HEVC/VP9/AV1 decode, DMABUF import and export. "Tested with Sunshine: use H.264 / SDR". Tested only on SC8280XP (gen2) | `_reference/qcom-va-driver` 0980a1d, README |
| It installs `qcom_drv_video.so` plus an `msm` alias, so libva picks it **for every VA client** on our DRM driver | README "Build and install" |
| The encoder opens any `iris_driver` node. Every S_CTRL failure is fatal; it sets `HEADER_MODE_JOINED`, `PREPEND_SPSPPS_TO_IDR=1`, `BITRATE_PEAK`. Deblocking controls are optional | `src/encoder.cpp:208,362,643-651,369-395` |
| The decoder hard-requires `DEC_DISPLAY_DELAY(_ENABLE)` and enough CAPTURE buffers | `src/decoder.cpp:128-135,218-229` |
| **Gen1 iris lacks `PREPEND_SPSPPS_TO_IDR`, `BITRATE_PEAK` and `DISPLAY_DELAY`**, so qcom-va-driver fails on SM8250 for encode AND decode | 7.3.5 `iris_hfi_gen1.c` cap list |
| Gen1's default `HEADER_MODE=JOINED` already sets `SYNC_FRAME_SEQUENCE_HEADER`=1, which venus uses for "headers with every sync frame". SM8250 probably already emits SPS/PPS per IDR; only the control is missing | `iris_hfi_gen1.c:120-128`, `venus/venc.c:876-885` |
| Venus does decode order on the same HFI family with `HFI_PROPERTY_PARAM_VDEC_OUTPUT_ORDER` | `venus/vdec.c:703`, `vdec_ctrls.c:33-36` |
| **Our 1092 already gives gen2 `DISPLAY_DELAY` + stage-1/top-OPP low-latency decode**, written for Moonlight and Remote Play. That overlap is why Radxa's 0001 does not apply | `kernel/patches/1092-*` |
| Radxa's 5 patches (on the list, bod 2026-11-17: "close to mergeable") are gen2-only. Against our tree: 0002-0004 apply, 0001 and 0005 do not | `patches/`, dry run 2026-11-20 |
| Sending `VENC_MAX_BITRATE` kills the SM8250 session (our dropped 1098) | memory `steam-remote-play-host-video-enc0` |
| Steam's own Remote Play Together hosting works on gen2 iris (Odin 2 + Pocket S2) | user, 2026-11-20 |

## Steps

### 0. Measure SM8250 before writing code (read-only on the Pocket Max) — DONE 2026-11-21, gate PASSED
Pocket Max, release v0.10.10 (fdeca0a), kernel 7.3.5, as `deck` over SSH. 1080p NV12, 150 frames,
stream piped back to the host; nothing written on the card.

| Run | Keyframes | SPS/PPS in front |
|---|---|---|
| `v4l2-ctl`, GOP 30, `HEADER_MODE` joined (default) | frame 0 IDR; 30/60/90/120 are **non-IDR I slices** | frame 0 only |
| ffmpeg `h264_v4l2m2m`, `-force_key_frames` 45,100 (it forces SEPARATE) | IDR at 45 and 100 | frame 0 only |
| Python V4L2 probe, joined, `FORCE_KEY_FRAME` before frames 45 and 100 | IDR at 45 and 100 | **every IDR** |

- **Gen1 already emits SPS+PPS with every IDR in joined mode.** 1a only has to expose the control.
- `FORCE_KEY_FRAME` gives a real IDR on the requested frame. The GOP never does after frame 0, so
  on-demand IDRs (Sunshine's model) are the only path that produces in-band headers.
- Separate mode turns per-IDR headers off, so ffmpeg `h264_v4l2m2m` is useless here, as expected.
- Side finding: the SPS says `level_idc=10` (level 1) at 1080p, which is the `h264_level` default.
  Check what qcom-va-driver sets, and whether Moonlight cares (step 2 gate).
- Controls on the 7.3.5 gen1 encoder: no `PREPEND_SPSPPS_TO_IDR`, no `BITRATE_PEAK`, as read from source.

### 1. Kernel, iris gen1 (free slots: 1104, 1106-1109)
- **1a** (host) Expose `PREPEND_SPSPPS_TO_IDR` on gen1, folded into the existing
  `SYNC_FRAME_SEQUENCE_HEADER` setter (mirrors `iris_set_header_mode_gen2`).
  **DONE: `1104`, HW-passed 2026-11-21** on the Pocket Max (dev card 20261121T094634Z, qcom-iris.ko
  sha256 aa14b639 = the build). The control is listed (`prepend_sps_and_pps_to_idr`). With IDRs
  forced at 45 and 100: separate + PREPEND=1 gives SPS/PPS before every IDR; separate + PREPEND=0
  gives them before frame 0 only (unchanged); joined unchanged (every IDR). No iris errors in dmesg.
- **1b** (client) `DEC_DISPLAY_DELAY(_ENABLE)` on gen1 via `HFI_PROPERTY_PARAM_VDEC_OUTPUT_ORDER`, ported
  from venus. Extend 1092's low-latency decode to gen1 if the stage/OPP logic applies there.
  **DONE: `1107`, HW-passed 2026-11-21** (module swapped on the dev card, sha256 9249f39f). 1092's
  stage/OPP logic already reached gen1 (its decoder caps use the shared `iris_set_stage`), so 1107 only
  adds the controls and the gen1 packing. Through qcom-va-driver, `-hwaccel vaapi`: the 1080p60 CBR
  stream at ~650 fps; a libx264 1080p60 stream with 441 B-frames out of 600 at 422 fps, and all 600
  frames bit-exact (framemd5 of NV12) against the host's software decode, in display order.
  No iris lines in dmesg.
- **1d** (host, found at the step 2 gate) `1106`: the gen1 encoder sends the visible size as
  `FRAME_SIZE`, as venus does. Before it, a 1080p encode was 1920x1088 with no SPS cropping.
  **HW-passed 2026-11-21** (module swapped on the dev card, sha256 51edb3e9; the 1104 module is kept at
  `/var/tmp/qcom-iris-1104.ko`): `h264_vaapi` CBR 12M at 1920x1080 and 1280x720, both on target. PSNR
  against the reference equals the 1088 run's top 1080 rows (26.81 vs 26.82 dB luma), so the firmware
  crops rather than rescales. iris decodes the stream back (600/600); no iris lines in dmesg.
- **Not in the kernel:** `BITRATE_PEAK`. A control that is accepted but never sent would mislead; see 2a.
- **1c (gen2) Carry Radxa's series. Do not drop it** (user, 2026-11-21): "[PATCH 0/5] media: iris: HFI gen2
  features and fixes for VA-API", Xilin Wu, v1 2026-10-29,
  `<20261029-iris-va-fixes-v1-0-44a2783f782b@radxa.com>`. `b4 am -c` on 2026-11-21: v1 is still the latest.
  Trailers: 1/5 Ack Dufresne, 4/5 Reviewed-by O'Donoghue. bod 2026-11-17: "close to mergable" once the
  comments are addressed. Open review: 2/5 (why decoder-only, put the max in the platform data),
  5/5 (fluster results asked for). One squashed patch in the 109x/110x media band, header listing all 5.
  Against our tree, 0002-0004 apply and 0001 + 0005 do not: 1092 already gives gen2 `DISPLAY_DELAY`, so
  1/5 is regenerated on top of 1092 (or dropped where 1092 is identical), and 5/5 is rebased. Needed
  before the gen2 gates of step 2 (the decoder's CAPTURE pool, 2/5).
  **Carried as `1108`** (2/5-5/5; 1/5 dropped, `1092` already covers every novadeck gen2 SoC; 5/5's last
  hunk placed against `1102`, same behaviour). Builds clean. **Gen1 regression PASSED 2026-11-21** on the
  Pocket Max (module sha256 a7b92b01): encode 11.98 Mbit/s at 1920x1080 with SPS/PPS per IDR; B-frame
  VA-API decode 600/600 bit-exact, 413 fps; no iris lines in dmesg. **Gen2 PASSED 2026-11-21** on the
  Pocket FIT (SM8650, same card and module): h264_vaapi CBR 12M at 11.95 Mbit/s and hevc_vaapi CBR 12M
  at 12.00 Mbit/s, both 1920x1080, SPS/PPS on every IDR, decode cleanly on the host; VA-API decode of
  the x264 B-frame stream and of that HEVC stream 600/600 bit-exact each, in order, "Format vaapi
  chosen", ~740 and ~1100 fps; the 3/5 deblocking controls are listed; no iris lines in dmesg. No A/B
  against a module without 1108 on gen2: the pass shows 1108 works, not which part qcom-va-driver needs.

### 2. qcom-va-driver package
- **2a** Patch: send `BITRATE_PEAK` only when QUERYCTRL finds it (the pattern it already uses for
  deblocking). Offer it to Radxa.
- **2b** `packages/qcom-va-driver`, `-Dcdsp_vpp=disabled` (no QAIC/Hexagon download in the builder).
- **2c** **Limit the blast radius: no `msm` alias at first.** Sunshine and Moonlight each set
  `LIBVA_DRIVER_NAME=qcom` in their own launch env, so Steam, CEF, Remote Play and recording see no
  change. A system-wide alias is a later, separately A/B'd decision.
- **SM8250 encode, 2026-11-21** (package installed with `pacman -U` on the 1104 dev card): libva loads
  `qcom` only with `LIBVA_DRIVER_NAME=qcom`; without it libva tries `msm_drv_video.so` and fails, as
  intended. `h264_vaapi` 1080p60 `testsrc2`, 10 s: CBR 12M -> 11.98 Mbit/s, VBR 8M -> 8.01 Mbit/s, 392 fps
  (6.5x real time). Streams decode clean, High@5.2, SPS/PPS on every IDR. **Defect: 1920x1088** -> `1106`.
  `libva-utils` (vainfo) is not in the pinned snapshot; the gate uses ffmpeg's VA-API device instead.
- **Gates (SM8250 first, then one gen2):** `vainfo` lists `VAEntrypointVLD` and `VAEntrypointEncSlice` for
  H.264. `ffmpeg -c:v h264_vaapi` holds the asked bitrate (the gen1 rate-control history: 1098).
  `ffmpeg -hwaccel vaapi` decodes a 1080p60 stream in real time.

### 3. Sunshine package (host)
- `packages/sunshine` from the upstream Arch PKGBUILD, CUDA off, built against our FFmpeg with VA-API
  (not LizardByte's prebuilt; check `FFMPEG_PREPARED_BINARIES`).
- **Built 2026-11-21, stable v2026.914.233613** (the local `_reference` tag v2026.1120.12055 is not upstream).
  "Our FFmpeg" is impossible: Sunshine links static libav* plus `libcbs.a` (FFmpeg's internal CBS, which
  only build-deps packages). So the PKGBUILD builds the build-deps submodule the tag pins, from source,
  BUILD_ALL=OFF + FFmpeg only (vaapi + libx264 + cbs; AMF/MF/CUDA_LLVM/SVT-AV1/x265/Vulkan off).
  build-deps still enables nvenc (header-only) and `h264_v4l2m2m`. Boost is not ours either: Sunshine
  wants Boost EXACT 1.89.0, the snapshot has 1.91, so it fetches 1.89.0 (URL_HASH-pinned) and links it
  static. miniupnpc is built static in the PKGBUILD (not in the snapshot). Linkage checked: no ICU, no numa.
  The package ships a udev rule (uinput/uhid to group `input` + uaccess) and `modules-load.d` uhid.
- **Probe PASSED 2026-11-21, Pocket FIT** (`pacman -U` on the 1108 dev card; root, `LIBVA_DRIVER_NAME=qcom`,
  `encoder = vaapi`, KMS capture of DSI-1, under gamescope): "Found H.264 encoder: h264_vaapi [vaapi]" and
  "Found HEVC encoder: hevc_vaapi [vaapi]", both VUI_PARAMETERS supported; vendor "Iris V4L2 stateful VA-API
  backend", EncSlice, CBR. No AV1, no HEVC Main10 (no HDR). Warning "Driver does not support some wanted
  packed headers" is expected (SPS/PPS come from PREPEND). avahi-daemon is disabled in the image, so
  Sunshine cannot publish mDNS ("Failed to create client: Daemon not running"): Moonlight must add the host
  by IP until step 7 decides.
- **GATE PASSED 2026-11-21:** a LAN PC Moonlight paired (host added by IP, PIN in the web UI) and streamed
  the FIT's Desktop: session encoder `hevc_vaapi` on iris, 14.99 Mbit/s CBR, SDR Rec. 709 8-bit, KMS grab of
  DSI-1 under gamescope. Found on the way, all for steps 5-7:
  - **No audio:** run as root, Sunshine gets "Couldn't connect to pulseaudio: Access denied" (the user's
    pipewire-pulse). It must run in the deck user's session, which then needs cap_sys_admin for KMS
    (or another capture path): step 5.
  - **Web UI by LAN IP is CSRF-blocked:** only localhost origins are allowed by default; the test added
    `csrf_allowed_origins = https://<ip>:47990`. Whatever owns Sunshine's config (step 7) must set it, or pair
    another way.
  - **OPEN: stream sometimes black at start until the mouse moves** (user report). Host log of the one
    session: Moonlight sent 10 IDR requests in 2.2 s after connect (~every 270 ms), Sunshine answered each
    with an IDR ~14 ms later at ~60 fps, then requests stopped at frame 139 and the stream stayed healthy.
    So the client discarded those IDRs. Mouse input began at +0.06 s, so the log cannot tie the recovery to
    the mouse. Two candidates: (1) a forced HEVC IDR on gen2 does not start with VPS: moonlight-common-c
    only accepts an HEVC IDR whose first NAL is a VPS (`VideoDepacketizer.c:469-480`) and loops on "Waiting
    for IDR frame"; step 1c checked per-IDR headers on gen1 H.264 only. (2) the PC's decoder rejects them.
    Next: the PC's Moonlight log at a reproduction (`%TEMP%\Moonlight-*.log` on Windows), H.264 vs HEVC in
    Moonlight's settings, and on a dev card `ffmpeg -c:v hevc_vaapi -force_key_frames` with the headers of
    every keyframe dumped (trace_headers bsf).
  - **No mDNS** (avahi-daemon disabled in the image, above). Proposed fix (publish through systemd-resolved) in step 7, not tested yet.
- **Gate:** Sunshine's encoder probe picks `vaapi` H.264 (log), and a LAN Moonlight client on a PC
  streams the session.

### 4. Moonlight-qt package (client)
- `packages/moonlight-qt`, FFmpeg with VA-API. Launched as a Steam tile (a non-Steam shortcut, like the
  alien-games tiles), with `LIBVA_DRIVER_NAME=qcom`.
- **Gates:** under gamescope, the log shows `VAAPI` with EGL direct rendering, not a software decoder.
  Moonlight's stats overlay shows decode time and frame drops at 1080p60 on SM8250 and one gen2.
  Controller input reaches the host.
- **Fallback if VA-API decode fails on a SoC:** `h264_v4l2m2m` with its CPU copy. Measure it on that SoC
  before accepting it (the CEF verdict).

### 5. Capture under gamescope (host)
- First try `capture = kms` and check rotated panels, MangoHud and overlay planes (the rotation-work
  caveats).
- If KMS is wrong: add a Sunshine capture method for gamescope's own PipeWire node, which Steam already
  uses ("Desktop PipeWire NV12"). Model it on `kwingrab.cpp` (get a node id, stream through the shared
  `pipewire.cpp`). Upstreamable.
- Stream the **whole session**, not a Sunshine "app": the friend sees whatever is running, as with
  Remote Play Together.

### 6. Input and several players (host)
- Sunshine's virtual pads (uinput/uhid) must show up in Steam Input as extra controllers. Check player
  numbering.
- Sunshine `channels` > 1: one iris encode session per client. Measure 2 clients on SM8250.

### 7. Its own Decky plugin (user decision, 2026-11-20)
A new plugin, `apps/decky/novadeck-<name>` (name TBD; the repo convention, beside `novadeck-stores`),
not a section of an existing panel. Two halves:
- **Host:** start / stop Sunshine, **off by default**. Shows the state and connected players. Has a
  PIN field for pairing a new client: the backend posts it to Sunshine's local API, so the web UI is
  never needed on the device.
- **Join:** lists hosts found on the LAN (Sunshine publishes `_nvstream._tcp` over mDNS,
  `src/platform/linux/publish.cpp`), pairs, and starts the stream. It drives the Moonlight-qt CLI,
  which has exactly these verbs: `moonlight pair <host> --pin NNNN` (the plugin picks the PIN and shows
  it, the host user types it in their plugin), `moonlight list <host>`,
  `moonlight stream <host> "Desktop"` (Sunshine's default app = the whole session, step 5),
  `moonlight quit <host>` (`app/cli/commandlineparser.cpp:167-553`).
- **Each paired host gets its own Steam tile** (user, 2026-11-20): Exe = moonlight-qt, options =
  `stream <host> "Desktop"`. Launching from a tile gives the stream gamescope focus and Steam Input
  like any game, so the plugin never spawns the stream itself. Pairing creates the tile, unpairing
  removes it. Reuse the novadeck-stores mechanism, copied not imported (plugins cannot import each
  other): tiles go through `SteamClient.Apps.AddShortcut` from the frontend and never by writing
  shortcuts.vdf, the registry is the ownership, and the durable key is our token (here the host's
  Sunshine UUID, not its name or IP, which change), never Steam's appid
  (`novadeck-stores/py_modules/novadeck_stores/shortcuts.py`, `src/lib/shortcutBridge.ts`).
  Step 4's generic Moonlight tile then becomes optional.
- **Proposed: mDNS publish through systemd-resolved, not avahi** (my recommendation, 2026-11-21; the
  user asked for it in the plan, to be tested later, not yet chosen). Sunshine's Linux
  publisher only talks to avahi-daemon (`publish.cpp` dlopens libavahi-client), and the image keeps
  avahi-daemon disabled: systemd-resolved owns UDP 5353 with mDNS on and answers `novadeck.local`. Steam
  Remote Play is unaffected because Steam discovers over its own UDP 27036 broadcast. Plan: the plugin
  writes `/etc/systemd/dnssd/sunshine.dnssd` (`Type=_nvstream._tcp`, `Port=47989`, `Name=%H`) and reloads
  resolved when it starts Sunshine, and removes it when it stops it, so the advert follows the host
  toggle. Alternative not recommended: enabling avahi-daemon (two responders on 5353; doing it right means turning resolved's
  mDNS off and adding nss-mdns for `novadeck.local`, a system-wide change). Possible later: a Sunshine
  patch registering through resolved's D-Bus `RegisterService`, so the advert follows Sunshine itself
  (upstreamable). Test first: a `.dnssd` on a dev card, then the PC Moonlight lists the host unasked.
- Security: Sunshine's web UI (47990) and stream ports LAN-only by default; credentials generated per
  device, never shipped. Internet play (port forwarding or Tailscale) is documented, not automated.
  Security review before merge (open ports, injected input, a root backend posting to a local API).

### 8. novadeck to novadeck
- The real target: an SM8250 host with a gen2 client, and the reverse. Latency and drops from
  Moonlight's overlay, two players with pads.

## Open questions
- Does Steam offer the Remote Play Together invite on an Epic/GOG shortcut? Not checked; a yes covers
  Steam friends without any of this.
- Gen1 encode session count when Steam recording and Sunshine both want the encoder.
- Panel rotation under KMS capture (AYANEO, Odin).
- Whether Moonlight-qt's EGL renderer under gamescope's Xwayland gets a zero-copy import on freedreno.
