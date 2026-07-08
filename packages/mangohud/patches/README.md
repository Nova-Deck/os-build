# mangohud patches

novadeck patches applied on top of the local mangohud PKGBUILD source (MangoHud `0.8.4`, see
[`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the MangoHud source root
(the `MangoHud/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-Qualcomm-GPU-support.patch
0002-SM8550-GPU.patch
0003-Battery-name.patch
0004-Qualcomm-battery-power-now.patch
0005-RAM-name.patch
0006-SM8750-Battery.patch
```

These are the ROCKNIX Qualcomm / SM85xx patch set as carried by armada (each traced to an
upstream ROCKNIX commit — see `_reference/armada-packages/mangohud/PATCHES.md` for the pinned
source URLs). Stock MangoHud only knows how to read desktop GPUs (amdgpu/i915/nvidia) and generic
`BAT*` power supplies, so on an Adreno part the GPU/battery/RAM fields are blank or wrong. The set:

- `0001` — **Qualcomm GPU support.** Match the `msm`/`msm_dpu`/`msm_drm` DRM driver in
  `GPU_fdinfo::find_fd()`, read the GPU thermal hwmon, and pull the GPU clock from kgsl
  (`init_kgsl()` + `get_kgsl_clock()` off the devfreq `cur_freq`).
- `0002` — **SM8550 GPU paths.** Point kgsl at the devfreq node `/sys/class/devfreq/3d00000.gpu`
  and the hwmon sensor at `gpuss_0_thermal`.
- `0003` — **Battery name.** Use the single `/sys/class/power_supply/battery` node (Qualcomm PMIC
  fuel gauge) instead of scanning for `BAT*`.
- `0004` — **Qualcomm battery power_now.** Prefer `current_now * voltage_now` for discharge
  wattage, fall back to `power_now`.
- `0005` — **RAM label.** Show `RAM` instead of `PMEM` for the process-memory HUD element.
- `0006` — **SM8750 battery remaining-time.** Use `time_to_empty_avg` (seconds) when present.

**SM8650 tuning note:** we ship on SM8650 (Adreno 750), while `0002`/`0006` were authored for
SM8550 (Adreno 740) / SM8750. We take all six anyway — SM8650 shares the Adreno kgsl/devfreq +
`gpuss_0_thermal` hwmon layout, so they are the closest match and the correct starting point. If a
HUD field reads wrong on HW, verify the on-device sysfs path and adjust the patch: GPU clock/temp
come from `/sys/class/devfreq/3d00000.gpu/cur_freq` + the `gpuss_0_thermal` hwmon (`0002`), battery
from `/sys/class/power_supply/battery` (`0003`/`0004`/`0006`). No source refs to peer distros ship
in these files — provenance lives here and in commit history only.

Drop the patch files here with those exact names (or rename and update `source.pin`'s `patches:`
line). **Until a declared patch is present, `make overlay` / `make base` fail fast** with a clear
"missing patch" message from `build-overlay.sh`.
