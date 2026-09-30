#!/system/bin/sh
# novadeck: the writer behind novadeck-logcat.rc. DEV CARDS ONLY -- see the .rc for the reasoning.
#
# TWO PHASES, because the question changes the instant the app launches.
#
# IDLE covers the boot, and is a filtered stream. Measured 2026-08-24, three runs: `logcat -f`
# keeps native pace but writes through stdio, and the container is SIGKILLed, so the last block is
# never flushed -- run 1 covered its whole 52s container and lost only the final ~4KB, which is
# exactly where the app exit was. A `while read` loop makes every line its own write(2) so nothing
# is stranded, but unfiltered it cannot keep pace with boot spew (run 3: 5043 lines covering TWO
# SECONDS of a ~90s run, still 30s behind when it died). FILTERED, that loop is a few hundred lines
# over a whole run, so it stays current AND its tail is durable. That is the idle phase.
#
# HOT covers the launch, and is a ring-buffer dump. `logcat -d` does not stream -- it reads the
# buffer and exits -- so nothing it prints can be stranded in a pipe when the container dies.
#
# WHY NOT JUST DUMP CONTINUOUSLY, which the previous revision did. `-t <count>` counts UNFILTERED
# lines and only then applies the filter, so a window sized for the filter (-t 400) yielded seven
# matching lines and stopped 300ms short of the app starting, and a window sized for the spew
# (-t 20000) took longer to run than its own 250ms loop interval and so sat ~400ms behind at the
# one moment that mattered. Both failed the same way: the instrument worked perfectly and showed
# nothing. `-t '<time>'` has no such coupling -- the window is wall-clock, exact regardless of how
# chatty the guest is -- but a timestamp is only available once we know which instant to anchor to.
# Hence the trigger.
#
# WHERE. /data/media/0, which is the guest's view of compatdata/<appid>/external. NOT /data/local
# and NOT any other /data path: on an early app exit Lepton deletes compatdata/<appid>/baked/
# outright, and data_overlay with it -- that is how run 2's capture was destroyed between the run
# and reading it. external/ and internal/ demonstrably survive that clear; nothing else does.

OUT=/data/media/0
FULL="$OUT/novadeck-logcat.txt"
TAIL="$OUT/novadeck-tail.txt"
SNAP="$OUT/novadeck-snapshot.txt"

mkdir -p "$OUT" 2>/dev/null

printf '\n===== novadeck capture start: %s =====\n' "$(date 2>/dev/null || echo unknown)" >>"$TAIL"

# THE HOT PHASE. Arms on the first sign of a launch, anchors a wall-clock window at that instant,
# then dumps everything since it, UNFILTERED, until the window has outlived the question.
#
# THE TRIGGER IS THE FORCE-STOP, NOT `Start proc`, and that is the whole point. Lepton launches with
# `am start -S` (liblepton `app_metadata.sh:164`, identical on both paths), and `-S` force-stops the
# package BEFORE starting it. So the sequence is: Force stopping -> any old process dies -> START ->
# Start proc. Anchoring on `Start proc` would begin the window AFTER the deaths, which is precisely
# where the suspect lives: on the Steam path `lepton.app_id` is set (properties.sh gates it on
# is_app, which is false for `dev`), and Valve's own comment says a guest system service watches for
# a process exit matching that package and SHUTS THE CONTAINER DOWN. A teardown fired by the
# force-stop's own casualty would look exactly like what we keep measuring: the log simply stops
# mid-graphics-init, with no tombstone and no ANR.
#
# UNFILTERED is deliberate. Every filtered capture so far has been a bet on which tag names the
# killer, and every one has lost -- the window is bounded to a couple of seconds, so we can afford
# to stop guessing.
(
    APP_ID="$(getprop lepton.app_id 2>/dev/null)"

    # ActivityManager:I carries all three trigger candidates and almost nothing else, so this stream
    # stays current the same way the idle tail does.
    /system/bin/logcat -b all -v threadtime ActivityManager:I "*:S" 2>/dev/null \
    | while IFS= read -r line; do
        case "$line" in
            *"Force stopping "*|*"START u0"*|*"Start proc"*) ;;
            *) continue ;;
        esac
        # When Lepton told us the package (Steam path), ignore launches that are not it. On the dev
        # path the property is unset and any launch is the one we came for.
        if [ -n "$APP_ID" ]; then
            case "$line" in
                *"$APP_ID"*) ;;
                *) continue ;;
            esac
        fi

        # threadtime puts `MM-DD HH:MM:SS.mmm` in the first two fields, which is exactly the format
        # `-t` wants. Taking it from the line rather than from `date` means the anchor comes off the
        # same clock as the buffer, with no format or timezone guesswork.
        set -- $line
        TS="$1 $2"
        printf 'anchor %s\n' "$TS" >>"$TAIL"

        # 60 iterations at 0.4s is ~24s of coverage. The failing launch dies inside 100ms; anything
        # still alive after 24s is not this bug, and letting the window grow for the length of a
        # session that WORKS would mean re-dumping a whole gameplay run four times a second onto an
        # SD card. Bounded on purpose.
        i=0
        while [ "$i" -lt 60 ]; do
            /system/bin/logcat -d -b all -v threadtime -t "$TS" >"$SNAP.new" 2>/dev/null
            mv -f "$SNAP.new" "$SNAP" 2>/dev/null
            i=$((i + 1))
            sleep 0.4
        done
        break
    done
) &

# THE BULK STREAM IS DELIBERATELY OFF. It wrote ~600KB of rotated logs into /data/media/0 during
# boot -- which is inside the SAME fuse-overlayfs /data whose SQLite failures are what we are
# chasing. The run with it enabled died 1.4s in, at system_server's first content provider, earlier
# than any run before it; the run with no capture at all booted fully and reached the app. That is
# correlation on one sample, not proof, but an instrument that plausibly causes the fault it is
# measuring is worthless until ruled out. The filtered stream below is ~2KB over a whole run.
#
# The hot phase above is loud by comparison, but it cannot perturb the boot it is not running
# during: it writes nothing at all until a launch is already underway, and then only one file that
# it overwrites in place.
#
# Re-enable ONLY to answer a question the filtered tags cannot, and expect to re-check this first:
#   /system/bin/logcat -b all -v threadtime -f "$FULL" -r 16 -n 128 &
: "$FULL"

# Tail: only what answers "why did the app exit". Unity/IL2CPP for the engine's own account,
# AndroidRuntime+DEBUG for a Java or native death, lmkd+ActivityManager for a low-memory kill
# (which leaves NO tombstone and NO ANR -- exactly the shape seen so far), libc for loader errors.
# `vulkan:V` is load-bearing, not decoration. The Steam path dies at Unity's graphics init, and
# `D/vulkan: searching for layers` is the first line the Android Vulkan loader emits there --
# measured on the dev path, where the game then runs. Without this tag `*:S` silences it, and the
# capture cannot distinguish "died INSIDE Vulkan init" from "died BEFORE reaching it". Several runs
# were spent unable to tell those apart. gralloc/EGL are here for the same reason: they are the
# other two things that speak up when a graphics init fails.
/system/bin/logcat -b all -v threadtime \
    Unity:V IL2CPP:V AndroidRuntime:E DEBUG:V lmkd:V ActivityManager:I libc:E \
    vulkan:V gralloc:V libEGL:V MESA:V "*:S" \
| while IFS= read -r line; do
    printf '%s\n' "$line"
done >>"$TAIL"
