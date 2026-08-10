# mangohud patches

novadeck patches applied on top of the local mangohud PKGBUILD source (MangoHud `0.8.4`, see
[`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the MangoHud source root
(the `MangoHud/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-Qualcomm-GPU-support.patch
0002-GPU-monitoring.patch
0003-Battery-name.patch
0004-Qualcomm-battery-power-now.patch
0005-RAM-name.patch
0006-SM8750-Battery.patch
```

These are an upstream Qualcomm / SM85xx patch set, each taken at a pinned upstream revision.
Stock MangoHud only knows how to read desktop GPUs (amdgpu/i915/nvidia) and generic
`BAT*` power supplies, so on an Adreno part the GPU/battery/RAM fields are blank or wrong. The set:

- `0001` — **Qualcomm GPU support.** Match the `msm`/`msm_dpu`/`msm_drm` DRM driver in
  `GPU_fdinfo::find_fd()`, read the GPU thermal hwmon, and pull the GPU clock from kgsl
  (`init_kgsl()` + `get_kgsl_clock()` off the devfreq `cur_freq`).
- `0002` — **kgsl/devfreq node probing.** Try `/sys/class/kgsl/kgsl-3d0`, then
  `/sys/class/devfreq/5900000.gpu` (SM6115), then `/sys/class/devfreq/3d00000.gpu`
  (SM8250/SM8550/SM8650/SM8750), and use the first that exists instead of one hardcoded path.
- `0003` — **Battery name.** Use the single `/sys/class/power_supply/battery` node (Qualcomm PMIC
  fuel gauge) instead of scanning for `BAT*`.
- `0004` — **Qualcomm battery power_now.** Prefer `current_now * voltage_now` for discharge
  wattage, fall back to `power_now`.
- `0005` — **RAM label.** Show `RAM` instead of `PMEM` for the process-memory HUD element.
- `0006` — **SM8750 battery remaining-time.** Use `time_to_empty_avg` (seconds) when present.

**SM8650 tuning note:** we ship on SM8650 (Adreno 750), while `0006` was authored for SM8750 and
`0002` was originally SM8550-only. We take all six anyway — SM8650 shares the Adreno kgsl/devfreq +
GPU hwmon layout they target. `0002` now names `3d00000.gpu` as covering SM8650 explicitly, so that
half is no longer a "close enough" bet. If a HUD field reads wrong on HW, verify the on-device sysfs
path and adjust the patch: GPU clock comes from `/sys/class/devfreq/3d00000.gpu/cur_freq` (`0002`),
battery from `/sys/class/power_supply/battery` (`0003`/`0004`/`0006`).

**GPU temperature is a substring match, and that is load-bearing.** `0002` used to also repoint the
hwmon lookup from `find_hwmon_sensor_dir("gpu")` to `"gpuss_0_thermal"`; it no longer does, and
nothing replaced it, so the lookup `0001` leaves in place is plain `"gpu"`. That is *not* a
regression, because `find_hwmon_sensor_dir` matches with `name_content.find(name) != npos`
(`src/gpu_fdinfo.cpp:275` in 0.8.4) — `"gpu"` is a substring of every SoC's sensor name, so it
resolves everywhere.

Keeping it that way is what lets ONE binary serve every SoC we ship, and it is the reason the
per-SoC GPU patches published upstream must NOT be taken as-is. Each of those hardcodes one name:

| SoC    | upstream patch pins   | zones actually in the .dtsi                     |
|--------|-----------------------|-------------------------------------------------|
| SM8250 | `gpu_top_thermal`     | `gpu-top-thermal`, `gpu-bottom-thermal`          |
| SM8550 | `gpuss_0_thermal`     | `gpuss-0-thermal` … `gpuss-7-thermal`            |
| SM8650 | `gpuss0_thermal`      | `gpuss0-thermal` … `gpuss7-thermal`              |

novadeck builds one unified image, so pinning any single one of those breaks the other two SoCs
outright (`gpuss_0_thermal` is not a substring of `gpu_top_thermal`, and vice versa). The other
half of those patches — repointing `init_kgsl()` at `/sys/class/devfreq/3d00000.gpu` — is already
covered by `0002`, which tries that path plus the kgsl and SM6115 ones and takes the first that
exists. Nothing from them is missing here.

The remaining wrinkle is determinism, not correctness: `find_hwmon_sensor_dir` returns the *first*
hwmon whose name contains `"gpu"` in unspecified `directory_iterator` order, and every SoC above
exposes 2–8 of them. All of them are genuine GPU-subsystem sensors, so any winner reports a sane
temperature — but which one is not pinned, so two boots can disagree by a couple of degrees. If GPU
temp ever reads oddly, check `/sys/class/hwmon/*/name` on the device first. Making it deterministic
means preferring an ordered list of exact names before falling back to the substring — deliberately
not done yet, since it costs an overlay rebuild for a cosmetic gain.

No peer-distro refs ship in the tree — upstream provenance lives in commit history only.

Drop the patch files here with those exact names (or rename and update `source.pin`'s `patches:`
line). **Until a declared patch is present, `make overlay` / `make base` fail fast** with a clear
"missing patch" message from `build-overlay.sh`.
