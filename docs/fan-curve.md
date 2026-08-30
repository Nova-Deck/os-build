# Fan curve

The fan is driven by `novadeck-powerd`, which evaluates a temperature→PWM curve every 3
seconds. The curve belongs to the **power profile**, not to a game: Eco, Balanced and
Performance each have their own, and switching profiles switches curve.

Three factory curves ship in `/usr/share/novadeck/power-profiles.conf` (`relaxed`,
`moderate`, `aggressive`). The [novadeck-control Decky plugin](decky.md) lets a user edit
the curve of whichever profile is active, from the Power tab.

## What the daemon actually does with it

The curve is a list of points. Between two points the PWM is **linearly interpolated**;
below the first and above the last it is held flat. On top of that the fan tick applies
three things the curve does not express:

| Setting | Default | Effect |
|---|---|---|
| `smoothing` | `0.50` | EWMA over the temperature, so a one-tick spike does not audibly kick the fan |
| `ramp_up` / `ramp_down` | `36` / `6` | Max PWM change per tick — fast to spin up, slow to wind down |
| `pwm_quantum` | `8` | Rounds the result, so the fan sits on a stable speed instead of hunting |
| `min_pwm` / `max_pwm` | `51` / `255` | Hard floor and ceiling; the floor is what keeps the fan from stalling |

The temperature fed into the curve is a blended average of the hottest three of the
CPU/GPU/video/memory thermal zones — the novadeck-monitor plugin reports that same number, so
what it shows is what the curve is evaluated against.

## Editing from the Quick Access Menu

The plugin shows one slider per **fixed temperature stop** (`60, 70, 80, 90, 100 °C` by
default, from `[fan] curve_stops`), in **percent** — `min_pwm=51` reads as 20%, `255` as
100%. That conversion lives only in the plugin's Power tab; the D-Bus property, the config
file and the daemon all speak raw PWM. The PWM grid is finer than the percent one, so the
round trip is stable and a slider never drifts off the value it was just given.

Only the fan speeds are editable. That is deliberate:
with the temperatures fixed and sorted, a curve that falls as the device heats up is
unreachable rather than rejected, so there is no invalid state and no error to report. The
sliders enforce the same non-falling rule as they move, and `novadeck-powerd` clamps
anything a client sends regardless.

A factory curve is shown resampled onto those stops — exact at each stop, since that is
the curve's own value there.

**Reset** returns the active profile to its factory curve. The button appears only once
the profile is actually on a custom curve.

"Active profile" means the one in force, which under a running game's
[`powerProfile` override](per-game-perf.md) is the game's, not the user's saved choice — so an
edit made while an override holds lands on the curve that is actually running.

## Where a custom curve is stored

Config is three layers, lowest first:

1. `/usr/share/novadeck/power-profiles.conf` — factory, part of the read-only image
2. `/etc/novadeck/power-profiles.conf` — the operator's own overrides
3. `/etc/novadeck/power-profiles.conf.d/*.conf` — drop-ins, read in sorted order

The plugin writes only `50-fan-curves.conf` in layer 3, and rewrites that file in full on
every change. Layer 2 is never touched, because `configparser` cannot round-trip comments
and a slider drag must not eat an operator's notes. An operator who wants the last word
can use a higher-numbered drop-in (`90-mine.conf`), which is read after ours.

The stored format is the ordinary curve grammar, so a hand-written curve may have any
number of points at any temperatures:

```ini
[fan_curve.custom-balanced]
label=Custom (Balanced)
curve=100:240,90:180,80:120,70:90,60:60

[profile.balanced]
fan_curve=custom-balanced
```

A drop-in section merges key-by-key with the factory one, so overriding `fan_curve=` leaves
the rest of the profile alone.

> A curve hand-authored with points **off** the stops still applies verbatim — but opening
> the plugin and moving a slider rewrites it onto the five stops.

If any layer fails to parse, `novadeck-powerd` quarantines **every** user layer to
`*.invalid-<timestamp>` and comes up on factory defaults, logging what it dropped. The
quarantine suffix goes after `.conf` so a quarantined drop-in stops matching the glob.

## From a shell

The interface is `org.novadeck.Power1` on the system bus (`org.novadeck.Power`,
`/org/novadeck/Power`). `wheel` may call it, so `deck` needs no `sudo`.

```sh
# The stops, and the current curve for the ACTIVE profile
busctl get-property org.novadeck.Power /org/novadeck/Power org.novadeck.Power1 FanCurveStops
busctl get-property org.novadeck.Power /org/novadeck/Power org.novadeck.Power1 FanCurve

# Set all five speeds at once (count first, then one value per stop)
busctl set-property org.novadeck.Power /org/novadeck/Power org.novadeck.Power1 \
  FanCurve au 5 60 90 120 180 240

# Back to factory: this profile, or every profile at once
busctl call org.novadeck.Power /org/novadeck/Power org.novadeck.Power1 ResetFanCurve
busctl call org.novadeck.Power /org/novadeck/Power org.novadeck.Power1 ResetAllFanCurves
```

`ResetAllFanCurves` has no button in the Quick Access Menu on purpose — it is the blunt
"put everything back" instrument, and one reset per profile is the shape a user wants.

Editing the files directly is equally supported; `busctl call ... Reload` re-reads all
three layers without restarting the daemon.

## Tests

`tests/test-fan-curve.sh` (part of `make test`) drives the real parse, resample, write and
reset paths against fabricated config trees: layer precedence, that an operator's comments
survive a write, that a reset drops only the active profile, and that a bad drop-in is
quarantined rather than re-broken on the next boot.
