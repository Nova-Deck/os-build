# firmware/

Recipes that **extract and stage** device firmware for image assembly.

**Proprietary Qualcomm blobs are never committed.** `extracted/` and `blobs/` are
git-ignored (see `.gitignore`). Two firmware sources:

- **`linux-fw`** — ships in the upstream base's `linux-firmware` package; no action.
- **`device`** — signed/vendor blobs (GPU zap shader, adsp/cdsp images) that must be
  pulled from the target device's own vendor/modem partitions.

| File | Purpose |
|---|---|
| `manifest.sh <soc>` | Verify the SoC manifest against the **built** kernel: cross-checks DTB `firmware-name` + module `MODULE_FIRMWARE` and reports missing/unbacked entries. Run after `kernel/build.sh`. |
| `extract.sh <soc> <vendor-tree>` | Stage `device`-sourced blobs per the SoC manifest into `extracted/<soc>/` (writes a `sha256sums.txt` sidecar). Reassembles split Qualcomm `.mdt` + `.bNN` images into a single `.mbn` via `pil-squasher` or an embedded python3 fallback. |

Per-SoC requirements live in `devices/<soc>/firmware-manifest.txt`. `manifest.sh`
needs `dtc` + `objcopy`, so run it inside the build image:

```
docker run --rm -v "$PWD":/src -w /src novadeck-kbuild firmware/manifest.sh sm8650
```

_Phase 1 scaffold._
