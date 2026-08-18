# firmware/

Recipes that **fetch and stage** device firmware for the kernel build and image assembly.
Nothing here ships proprietary blobs — both sources are fetched on demand, pinned, and
verified, into git-ignored trees (`qcom-fw/`, `linux-fw/`; see `.gitignore`).

Two firmware sources:

- **`linux-fw`** — open firmware (Adreno GPU microcode, qca BT, Venus/Iris VPU, ath11k
  Wi-Fi, and on SM8250 the adsp/cdsp too) from the official `linux-firmware` repo. The
  upstream Holo base ships no `/lib/firmware`, so these are fetched + sha256-verified by
  `fetch-linux-fw.sh` (pinned in `LINUX_FW.pin`).
- **`qcom-fw`** — device-proprietary Qualcomm/vendor blobs (GPU zap shaders, adsp/cdsp DSP
  images, AudioReach tplg, ath12k Wi-Fi/BT, Renesas xHCI) extracted from each device's Android
  vendor image and republished to the [Nova-Deck/qcom-firmwares](https://github.com/Nova-Deck/qcom-firmwares)
  repo. Fetched + verified by `fetch-qcom-fw.sh` (pinned in `QCOM_FW.pin`).

Which class a given blob falls in is **per-SoC, not fixed**. SM8550/SM8650 boards each need
their own vendor-signed `adsp`/`cdsp`; every SM8250 board is served by the generic open pair
in `linux-firmware`. Two SM8250 blobs are missing from both sources and are documented as
open gaps at the bottom of `QCOM_FW.pin`.

One trap worth knowing when adding rows: `linux-firmware` uses **symlinks** for several
driver-facing names (e.g. `qcom/vpu/vpu30_p4.mbn` → `vpu30_p4_s7.mbn`), and cgit's
`plain/` endpoint returns 404 for a symlink. A 404 is therefore not proof the firmware is
absent — check `WHENCE` at the pinned commit, then pin the real blob and rename it via the
row's install-path column. Which signed variant the link points at is not guessable from the
name: `vpu30_p4_s6.mbn` sits right next to `vpu30_p4_s7.mbn` and belongs to a different SoC.

The second trap is the one that actually cost us working SM8250 decode: pin the name the
**binding driver** asks for, not the one the DT node's label suggests. `&venus` on SM8250 is
claimed by `qcom-iris.ko`, not venus — see the SM8250 block in `LINUX_FW.pin`.

| File | Purpose |
|---|---|
| `fetch-linux-fw.sh` | Fetch the open `linux-fw` blobs at the pinned commit into `linux-fw/`, per-file sha256-verified. Host, network. SoC-agnostic flat tree. |
| `fetch-qcom-fw.sh` | Fetch the device-proprietary `qcom-fw` tree from the pinned qcom-firmwares commit into `qcom-fw/`, verified against the repo's `sha256sums.txt`. Host, network. SoC-agnostic (blobs are self-namespaced by on-device path). |

There is no separate firmware requirements list. What ships is decided by the two pins and
nothing else: `LINUX_FW.pin` is an explicit per-file allowlist (each row carries its own
sha256), and `qcom-fw/` is whatever the pinned qcom-firmwares commit contains. Both staged
trees are then installed into the rootfs wholesale by `images/assemble-rootfs.sh`.

A board's firmware requirement is expressed where it is actually consumed — the DTS
`firmware-name` properties, and `kernel/embed.list` for the subset baked into `Image.gz`.
A hand-maintained mirror of that was tried and deleted: nothing enforced it, so it silently
drifted (it still claimed to be SM8650-only long after the SM8550 boards landed).
