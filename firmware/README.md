# firmware/

Recipes that **extract and stage** device firmware for image assembly.

**Proprietary Qualcomm blobs are never committed.** `extracted/` and `blobs/` are
git-ignored (see `.gitignore`). Two firmware sources:

- **`linux-fw`** — ships in the upstream base's `linux-firmware` package; no action.
- **`device`** — signed/vendor blobs (GPU zap shader, adsp/cdsp images) that must be
  pulled from the target device's own vendor/modem partitions.

| File | Purpose |
|---|---|
| `extract.sh <soc> <vendor-tree>` | Stage `device`-sourced blobs per the SoC manifest into `extracted/<soc>/` |

Per-SoC requirements live in `devices/<soc>/firmware-manifest.txt`.

_Phase 1 scaffold._
