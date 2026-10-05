#!/usr/bin/env bash
# Offline checks for what the shared Android container does to its Steam titles after adding
# them: the "Google Play" collection and the Play artwork.
#
#   rootfs/overlay/usr/lib/novadeck/play-info     the listing scraper -- run here against a local
#                                                 stand-in for play.google.com (its URL is a seam)
#   rootfs/overlay/usr/lib/novadeck/steam-title   shortcuts.vdf lookup, and the live apply over
#                                                 CEF -- run here against a fake debugger that
#                                                 speaks just enough websocket to be the client's
#                                                 other end (both its roots are seams)
#   rootfs/overlay/usr/bin/novadeck-android       the wiring: the tick, the markers, the command
#
# What this cannot prove is Steam's own JS API (collectionStore, SetCustomArtworkForApp): that
# is asserted by name only, and on a device. Everything up to the socket is executed for real.
#
# Runs on the host with no root, no device, no network beyond 127.0.0.1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/rootfs/overlay/usr/bin/novadeck-android"
PLAY_INFO="$ROOT/rootfs/overlay/usr/lib/novadeck/play-info"
STEAM_TITLE="$ROOT/rootfs/overlay/usr/lib/novadeck/steam-title"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$RUNTIME" "$PLAY_INFO" "$STEAM_TITLE"; do
    [[ -f $f ]] || { echo "missing input: $f" >&2; exit 1; }
done
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

echo "the wiring in novadeck-android"

for f in "$PLAY_INFO" "$STEAM_TITLE"; do
    [[ -x $f ]] && ok "$(basename "$f") is executable" || bad "$(basename "$f") is not executable"
    python3 -m py_compile "$f" 2>/dev/null && ok "$(basename "$f") compiles" || bad "$(basename "$f") does not compile"
done
grep -q "^PLAY_INFO=/usr/lib/novadeck/$(basename "$PLAY_INFO")\$" "$RUNTIME" \
    && ok "the runtime runs play-info where the overlay puts it" || bad "PLAY_INFO= points elsewhere"
grep -q "^STEAM_TITLE=/usr/lib/novadeck/$(basename "$STEAM_TITLE")\$" "$RUNTIME" \
    && ok "the runtime runs steam-title where the overlay puts it" || bad "STEAM_TITLE= points elsewhere"
grep -q '^COLLECTION="Google Play" ' "$RUNTIME" \
    && ok 'titles go into the "Google Play" collection' || bad "the collection name changed"
# The same tick that adds a title enriches it: nothing else runs sync_meta periodically.
awk '/^cmd_daemon\(\)/,/^}/' "$RUNTIME" | grep -q 'sync_titles || true; sync_meta || true' \
    && ok "the daemon enriches titles on the tick that adds them" \
    || bad "cmd_daemon's loop does not run sync_meta beside sync_titles"
grep -q '^  enrich) cmd_enrich' "$RUNTIME" && ok "'enrich' is a command" || bad "no enrich command"
grep -q 'novadeck-android enrich' "$RUNTIME" && ok "'enrich' is in the usage" || bad "enrich is not in the usage"
# The usage is the header; the range printed must cover every command line and nothing else.
range="$(sed -n "s/.*sed -n '\([0-9]*,[0-9]*\)p' \"\$0\".*/\1/p" "$RUNTIME")"
last="$(grep -n '^#   novadeck-android ' "$RUNTIME" | tail -1 | cut -d: -f1)"
[[ "$range" == "2,$last" ]] && ok "the usage prints the whole command list (lines $range)" \
    || bad "the usage prints lines $range but the command list ends on line $last"
# Uninstall, by either path, drops the listing with the desktop entry.
awk '/^sync_titles\(\)/,/^}/' "$RUNTIME" | grep -q 'rm -rf "\$f" "\${META_DIR}/\${pkg}"' \
    && ok "an app uninstalled inside Android loses its listing" || bad "sync_titles keeps the listing of an uninstalled app"
awk '/^cmd_remove\(\)/,/^}/' "$RUNTIME" | grep -q '"\${META_DIR}/\${pkg}"' \
    && ok "'remove' drops the listing" || bad "cmd_remove keeps the listing"
# The store title is added by setup, with Steam possibly not yet showing a library; it must not
# be asked of Play (there is no listing) and must still reach the collection.
awk '/^cmd_setup\(\)/,/^}/' "$RUNTIME" | grep -q 'com.android.vending/.fetched"' \
    && ok "setup records that the Play Store has no listing" || bad "setup would ask Play for the store's own listing"
awk '/^cmd_setup\(\)/,/^}/' "$RUNTIME" | grep -q 'apply_meta com.android.vending' \
    && ok "setup puts the Play Store into the collection" || bad "setup never applies the collection to the store"
awk '/^cmd_setup\(\)/,/^}/' "$RUNTIME" | grep -qx '      apply_meta com.android.vending || true' \
    && ok "setup tries the collection once and leaves the rest to the daemon's tick" \
    || bad "setup waits on Steam's UI to apply the store's collection"

# Exercise the bash functions themselves: source the runtime with a no-op dispatcher, fake the
# helpers on PATH-independent variables, and drive fetch_meta/apply_meta/sync_meta.
echo
echo "fetch_meta / apply_meta / sync_meta (the runtime's own functions, fake helpers)"
export HOME="$TMP/home"
mkdir -p "$HOME/.local/share/novadeck-android" "$TMP/bin"
# The runtime runs both helpers as `python3 FILE`, so the fakes are Python too.
cat >"$TMP/bin/fake-play-info" <<'EOF'
import os, sys
# $FAKE_PLAY_RC decides; 0 writes art like the real one, 3 is "not on Play" (nothing written).
open(os.environ["FAKE_LOG"], "a").write(sys.argv[1] + "\n")
rc = int(os.environ.get("FAKE_PLAY_RC", "0"))
if rc == 0:
    os.makedirs(sys.argv[2], exist_ok=True)
    open(os.path.join(sys.argv[2], "icon.png"), "w").close()
sys.exit(rc)
EOF
cat >"$TMP/bin/fake-steam-title" <<'EOF'
import os, sys
open(os.environ["FAKE_LOG"], "a").write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "appid":
    if not os.environ.get("FAKE_APPID"):
        sys.exit(1)
    print(os.environ["FAKE_APPID"])
elif sys.argv[1] == "apply":
    sys.exit(int(os.environ.get("FAKE_APPLY_RC", "0")))
EOF
chmod +x "$TMP/bin/"*
export FAKE_LOG="$TMP/calls"
# Load the function definitions without running the dispatcher: everything after `case` is cut.
sed '/^case "\${1:-}" in/,$d' "$RUNTIME" >"$TMP/runtime-lib.sh"
sed -i "s|^PLAY_INFO=.*|PLAY_INFO=$TMP/bin/fake-play-info|; s|^STEAM_TITLE=.*|STEAM_TITLE=$TMP/bin/fake-steam-title|" "$TMP/runtime-lib.sh"
run() { ( set +e; cd "$TMP"; . "$TMP/runtime-lib.sh"; "$@" ) 2>>"$TMP/stderr"; }
SYS="$HOME/.local/share/novadeck-android"
printf 'com.example.one\ncom.example.two\n' >"$SYS/titles"

: >"$FAKE_LOG"; FAKE_APPID=123 FAKE_PLAY_RC=0 run sync_meta
[[ "$(grep -c '^com.example' "$FAKE_LOG")" == 1 ]] \
    && ok "one tick asks Play for at most one title" || bad "a tick fetched more than one listing: $(cat "$FAKE_LOG")"
[[ -f "$SYS/meta/com.example.one/.fetched" && -f "$SYS/meta/com.example.one/icon.png" ]] \
    && ok "the art lands under meta/<pkg>/, marked fetched" || bad "meta/com.example.one: $(ls -A "$SYS/meta/com.example.one")"
grep -q '^apply 123 --collection Google Play --art .*/meta/com.example.one --icon .*/icon.png$' "$FAKE_LOG" \
    && ok "a fetched title is applied with its collection, art dir and icon" || bad "apply call wrong: $(grep apply "$FAKE_LOG")"
grep -q '^apply 123 --collection Google Play --art .*/meta/com.example.two$' "$FAKE_LOG" \
    && ok "a title without a listing yet still gets the collection" || bad "unfetched title was not applied: $(grep apply "$FAKE_LOG")"
[[ "$(cat "$SYS/meta/com.example.one/.applied")" == "appid=123 art=1" ]] \
    && ok ".applied records the app id and that the art went in" || bad ".applied is '$(cat "$SYS/meta/com.example.one/.applied" 2>&1)'"
[[ "$(cat "$SYS/meta/com.example.two/.applied")" == "appid=123" ]] \
    && ok ".applied without art means the art is still owed" || bad ".applied for two is '$(cat "$SYS/meta/com.example.two/.applied" 2>&1)'"

: >"$FAKE_LOG"; FAKE_APPID=123 FAKE_PLAY_RC=0 run sync_meta
grep -q 'apply 123 .*com.example.one' "$FAKE_LOG" && bad "an applied title was applied again" || ok "an applied title is left alone"
grep -q 'apply 123 .*com.example.two' "$FAKE_LOG" && ok "the owed art is applied once the listing arrives" || bad "two's art never followed"

: >"$FAKE_LOG"; FAKE_APPID=999 FAKE_PLAY_RC=0 run sync_meta
[[ "$(grep -c '^apply 999' "$FAKE_LOG")" == 2 ]] && ok "a shortcut re-added under a new app id is re-applied" \
    || bad "new app id did not trigger a re-apply: $(cat "$FAKE_LOG")"

rm -rf "$SYS/meta"; : >"$FAKE_LOG"
FAKE_APPID=5 FAKE_PLAY_RC=1 run sync_meta
[[ -f "$SYS/meta/com.example.one/.failed" ]] && ok "a failed fetch is recorded" || bad "no .failed after a fetch error"
grep -q 'apply 5' "$FAKE_LOG" && ok "a fetch failure does not hold the collection back" || bad "collection waited on the fetch"
: >"$FAKE_LOG"; FAKE_APPID=5 FAKE_PLAY_RC=1 run sync_meta
grep -q '^com.example.one$' "$FAKE_LOG" && bad "Play was asked again within the back-off" || ok "a failed title backs off (not asked again at once)"
echo "1 $(( $(date +%s) - 200 ))" >"$SYS/meta/com.example.one/.failed"
: >"$FAKE_LOG"; FAKE_APPID=5 FAKE_PLAY_RC=1 run sync_meta
grep -q '^com.example.one$' "$FAKE_LOG" && ok "asked again once the back-off (2 min after the 2nd failure) has passed" \
    || bad "not retried after the back-off"
[[ "$(cut -d' ' -f1 "$SYS/meta/com.example.one/.failed")" == 2 ]] && ok "the try count climbs" || bad "try count did not climb"
echo "40 0" >"$SYS/meta/com.example.one/.failed"
: >"$FAKE_LOG"; FAKE_APPID=5 FAKE_PLAY_RC=1 run sync_meta
grep -q '^com.example.one$' "$FAKE_LOG" && ok "the back-off is capped (a huge try count still retries after 64 min)" \
    || bad "an oversized try count stopped retries for good"

rm -rf "$SYS/meta"; : >"$FAKE_LOG"
FAKE_APPID=5 FAKE_PLAY_RC=3 run sync_meta
[[ ! -f "$SYS/meta/com.example.one/.failed" && -f "$SYS/meta/com.example.one/.fetched" ]] \
    && ok "'not on Play' is final: recorded, never retried" || bad "a 404 from Play was treated as a failure"
: >"$FAKE_LOG"; FAKE_APPID="" run sync_meta
grep -q '^apply' "$FAKE_LOG" && bad "applied with no shortcut in Steam" || ok "nothing is applied until Steam has the shortcut"
rm -f "$SYS/meta/com.example.two/.applied"
: >"$FAKE_LOG"; FAKE_APPID=5 FAKE_APPLY_RC=1 run sync_meta
[[ ! -f "$SYS/meta/com.example.two/.applied" ]] && ok "an apply that could not reach Steam leaves no .applied (retried next tick)" \
    || bad ".applied written although apply failed"

echo
echo "play-info against a stand-in for play.google.com"
# A listing page shaped like Play's: the ds:5 blob with the app at [1][2] and the positions
# play-info reads, plus the og: tags. The image server answers any URL with a PNG or JPEG.
python3 - "$TMP" <<'EOF'
import json, os, sys
tmp = sys.argv[1]
def img(t, w, h, name):
    return [t, [w, h], None, [None, None, f"http://127.0.0.1:PORT/img/{name}"]]
app = [None] * 100
app[0] = ["Clash of Blocks"]
app[12] = None
app[68] = ["Blockworks Ltd"]
app[72] = [[None, "Build towers.<br>Knock them &amp; down.<br><br>Fun for <b>all</b>."]]
app[73] = [[None, "Towers, in real time"]]
app[78] = [[img(1, 1080, 1920, "shot1"), img(1, 1920, 1080, "shot2")]]
app[79] = [[["Strategy"]]]
app[95] = [img(4, 512, 512, "icon")]
app[96] = [img(2, 1024, 500, "feature")]
ds5 = [None, [None, None, app]]
page = f"""<html><head><meta property="og:title" content="Clash of Blocks - Apps on Google Play">
<meta content="http://127.0.0.1:PORT/img/ogicon=s0-br30" property="og:image">
<meta property="og:description" content="Towers, in real time"></head><body><h1>Clash of Blocks</h1>
<script>AF_initDataCallback({{key: 'ds:3', hash: '1', data:[1,2], sideChannel: {{}}}});</script>
<script>AF_initDataCallback({{key: 'ds:5', hash: '2', data:{json.dumps(ds5)}, sideChannel: {{}}}});</script>
</body></html>"""
open(os.path.join(tmp, "listing.html"), "w").write(page)
# The same without any script data: only the tags and the heading.
open(os.path.join(tmp, "listing-bare.html"), "w").write(page.split("<script>")[0] + "</body></html>")
EOF
cat >"$TMP/playserver.py" <<'EOF'
import http.server, os, sys, urllib.parse
tmp = sys.argv[1]
# Real images (the portrait capsule is decoded and composed by ffmpeg), made before the server.
PNG = open(os.path.join(tmp, "real.png"), "rb").read()
JPG = open(os.path.join(tmp, "real.jpg"), "rb").read()
WEBP = b"RIFF\0\0\0\0WEBPVP8 " + b"\0" * 32
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(tmp, "requests"), "a") as f:
            f.write(self.path + "\n")
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/details":
            pkg = q.get("id", [""])[0]
            if pkg == "com.example.missing" or (pkg == "com.example.uslocked" and "gl" in q):
                self.send_response(404); self.end_headers(); return
            name = "listing-bare.html" if pkg == "com.example.bare" else "listing.html"
            body = open(os.path.join(tmp, name), "rb").read().replace(b"PORT", str(self.server.server_port).encode())
            if pkg == "com.example.consent":
                body = b"<html><body>Before you continue to Google</body></html>"
            if pkg == "com.example.webp":
                body = body.replace(b"/img/", b"/img/webponly-")
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(body)
        elif u.path.startswith("/img/"):
            # Like Play's image server, WebP to whoever might take it; this one is stricter and
            # also sends it when nothing narrower than */* was asked for.
            accept = self.headers.get("Accept", "*/*")
            if "webponly" in u.path or "webp" in accept or "*/*" in accept:
                body = WEBP
            else:
                body = JPG if "-c" in u.path and "icon" not in u.path else PNG
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(tmp, "playport"), "w").write(str(srv.server_port))
srv.serve_forever()
EOF
# The composed capsule needs ffmpeg, which the base installs for the Steam client; this suite
# proves the composition, not that the image ships ffmpeg (that is the package list's job).
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed on the host for the portrait capsule checks" >&2; exit 1; }
ffmpeg -v error -f lavfi -i color=c=red:s=64x64 -frames:v 1 "$TMP/real.png"
ffmpeg -v error -f lavfi -i color=c=blue:s=64x64 -frames:v 1 -f mjpeg "$TMP/real.jpg"
python3 "$TMP/playserver.py" "$TMP" & PIDS+=($!)
for _ in $(seq 50); do [[ -s "$TMP/playport" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/playport")"
export NOVADECK_PLAY_STORE_URL="http://127.0.0.1:$PORT/details"

out="$TMP/meta/com.example.app"
python3 "$PLAY_INFO" com.example.app "$out" 2>"$TMP/pi.err"; rc=$?
[[ $rc == 0 ]] && ok "a listing is fetched (exit 0)" || bad "play-info exited $rc: $(cat "$TMP/pi.err")"
[[ "$(ls -A "$out" | sort | tr '\n' ' ')" == "grid.jpg hero.jpg icon.png portrait.jpg " ]] \
    && ok "only the art is written (the listing's text is not kept)" || bad "wrote: $(ls -A "$out")"
dims() { ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$1" 2>/dev/null; }
[[ "$(dims "$out/portrait.jpg")" == "mjpeg,600,900" ]] \
    && ok "the portrait capsule is composed, a 600x900 JPEG" || bad "portrait.jpg is '$(dims "$out/portrait.jpg")'"
[[ -z "$(find "$out" -name '.portrait-*' -o -name '*.tmp')" ]] && ok "composing leaves no scratch files" \
    || bad "left behind: $(find "$out" -name '.portrait-*' -o -name '*.tmp')"
for f in grid.jpg hero.jpg portrait.jpg icon.png; do
    [[ -s "$out/$f" ]] && ok "$f written, named by what the server returned" || bad "$f missing"
done
grep -q '^/img/feature=w920-h430-c$' "$TMP/requests" && ok "the grid is the feature graphic cropped to 920x430 by Play" || bad "grid request wrong"
grep -q '^/img/feature=w1920-h620-c$' "$TMP/requests" && ok "the hero is the feature graphic cropped to 1920x620" || bad "hero request wrong"
grep -q '^/img/feature=w600-h900-c$' "$TMP/requests" && grep -q '^/img/icon=w384-h384-c$' "$TMP/requests" \
    && ok "the capsule is the feature graphic cropped to 600x900 by Play, under the icon at 384" || bad "portrait sources wrong"
grep -q 'shot' "$TMP/requests" && bad "a screenshot was fetched" || ok "no screenshot is fetched"
grep -q '^/img/icon=w256-h256-c$' "$TMP/requests" && ok "the icon is 256x256" || bad "icon request wrong"
grep -q '^/details?id=com.example.app&hl=en&gl=us$' "$TMP/requests" && ok "asks in English, US storefront first" || bad "listing request: $(grep details "$TMP/requests")"

: >"$TMP/requests"
python3 "$PLAY_INFO" com.example.missing "$TMP/meta/missing" 2>/dev/null; rc=$?
[[ $rc == 3 && -z "$(ls -A "$TMP/meta/missing")" ]] \
    && ok "no listing: exit 3, nothing written" || bad "missing app: exit $rc, $(ls -A "$TMP/meta/missing")"
[[ "$(grep -c details "$TMP/requests")" == 2 ]] && ok "a 404 is retried without the storefront before giving up" || bad "404 handling: $(cat "$TMP/requests")"
python3 "$PLAY_INFO" com.example.uslocked "$TMP/meta/uslocked" 2>/dev/null; rc=$?
[[ $rc == 0 ]] && ok "a listing absent from the US storefront is found without gl=" || bad "uslocked: exit $rc"
out="$TMP/meta/bare"
python3 "$PLAY_INFO" com.example.bare "$out" 2>/dev/null; rc=$?
[[ $rc == 0 ]] && grep -q '^/img/ogicon=w256-h256-c$' "$TMP/requests" \
    && ok "without script data: a listing by its <h1>, the icon from og:image (its size suffix replaced)" \
    || bad "bare page: exit $rc, $(grep ogicon "$TMP/requests")"
python3 "$PLAY_INFO" com.example.consent "$TMP/meta/consent" 2>/dev/null; rc=$?
[[ $rc == 1 && -z "$(ls -A "$TMP/meta/consent")" ]] \
    && ok "a page that is no listing (no title, no icon): exit 1, try later" || bad "consent page: exit $rc"
[[ -s "$out/icon.png" && ! -e "$out/grid.jpg" ]] && ok "only the files that had a source exist" || bad "bare page wrote the wrong files"
[[ "$(dims "$out/portrait.jpg")" == "mjpeg,600,900" ]] && ok "with no feature graphic the capsule is composed on the icon alone" \
    || bad "bare page portrait: '$(dims "$out/portrait.jpg")'"
mkdir -p "$TMP/noffmpeg"; printf '#!/bin/sh\nexit 1\n' >"$TMP/noffmpeg/ffmpeg"; chmod +x "$TMP/noffmpeg/ffmpeg"
out="$TMP/meta/noffmpeg"
PATH="$TMP/noffmpeg:$PATH" python3 "$PLAY_INFO" com.example.app "$out" 2>/dev/null; rc=$?
[[ $rc == 0 && -s "$out/grid.jpg" && ! -e "$out/portrait.jpg" \
   && -z "$(find "$out" -name '.portrait-*' -o -name '*.tmp')" ]] \
    && ok "ffmpeg failing costs only the capsule (no file, no scratch, the rest written)" || bad "ffmpeg failure: exit $rc, $(ls -A "$out")"
out="$TMP/meta/webp"
python3 "$PLAY_INFO" com.example.webp "$out" 2>/dev/null; rc=$?
[[ $rc == 0 && -z "$(ls -A "$out")" ]] \
    && ok "a WebP the server sends anyway is dropped (Steam takes PNG/JPEG only); still a listing (exit 0)" \
    || bad "webp listing: exit $rc, files: $(ls "$out")"
NOVADECK_PLAY_STORE_URL="http://127.0.0.1:1/details" python3 "$PLAY_INFO" com.example.app "$TMP/meta/offline" 2>/dev/null; rc=$?
[[ $rc == 1 && -z "$(ls -A "$TMP/meta/offline")" ]] && ok "unreachable: exit 1, nothing recorded" || bad "offline: exit $rc"
python3 "$PLAY_INFO" 'bad;name' "$TMP/meta/x" 2>/dev/null; [[ $? == 2 ]] && ok "rejects a bad package name" || bad "accepted a bad package name"

echo
echo "steam-title appid (a real shortcuts.vdf)"
export NOVADECK_STEAM_ROOT="$TMP/steam"
mkdir -p "$NOVADECK_STEAM_ROOT/userdata/1234/config"
python3 - "$NOVADECK_STEAM_ROOT/userdata/1234/config/shortcuts.vdf" <<'EOF'
import struct, sys
def s(k, v): return b"\x01" + k.encode() + b"\0" + v.encode() + b"\0"
def i(k, v): return b"\x02" + k.encode() + b"\0" + struct.pack("<I", v)
def obj(k, body): return b"\x00" + k.encode() + b"\0" + body + b"\x08"
sc0 = obj("0", i("appid", 2902312254) + s("AppName", "Clash of Blocks") + s("Exe", '"/usr/bin/novadeck-android"')
          + s("StartDir", '"/usr/bin/"') + s("LaunchOptions", '"run" "com.example.app"')
          + s("ShortcutPath", "/home/deck/.local/share/applications/novadeck-android-com.example.app.desktop")
          + obj("tags", b""))
sc1 = obj("1", i("appid", 3000000001) + s("AppName", "Something Else") + s("Exe", '"/usr/bin/other"')
          + s("LaunchOptions", '"run" "com.example.other"') + obj("tags", b""))
open(sys.argv[1], "wb").write(obj("shortcuts", sc0 + sc1) + b"\x08")
EOF
[[ "$(python3 "$STEAM_TITLE" appid com.example.app)" == 2902312254 ]] \
    && ok "finds the shortcut's app id from Exe + LaunchOptions" || bad "appid lookup failed"
python3 "$STEAM_TITLE" appid com.example.other >/dev/null 2>&1 && bad "matched a shortcut that is not novadeck-android's" \
    || ok "a shortcut with another exe is not ours, whatever its options say"
python3 "$STEAM_TITLE" appid com.example.nope >/dev/null 2>&1 && bad "found an app id for a title that has none" \
    || ok "no shortcut: exit 1"

echo
echo "steam-title apply (a fake CEF debugger: real HTTP /json, real websocket framing)"
cat >"$TMP/cefserver.py" <<'EOF'
import base64, hashlib, http.server, json, os, struct, sys, threading
tmp = sys.argv[1]
MAGIC = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
def recv_exact(rf, n):
    out = b""
    while len(out) < n:
        c = rf.read(n - len(out))
        if not c: raise EOFError
        out += c
    return out
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        port = self.server.server_port
        if self.path == "/json":
            body = json.dumps([
                {"title": "Steam Big Picture Mode", "type": "page", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/BPM"},
                {"title": "SharedJSContext", "type": "page", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/SJC"},
            ]).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if self.path != "/devtools/page/SJC":
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        key = self.headers["Sec-WebSocket-Key"].encode()
        accept = base64.b64encode(hashlib.sha1(key + MAGIC).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        # One text message from the client, possibly > 64 KiB (the art is inline base64).
        b0, b1 = recv_exact(self.rfile, 2)
        n = b1 & 0x7F
        if n == 126: n = struct.unpack(">H", recv_exact(self.rfile, 2))[0]
        elif n == 127: n = struct.unpack(">Q", recv_exact(self.rfile, 8))[0]
        assert b1 & 0x80, "client frames must be masked"
        mask = recv_exact(self.rfile, 4)
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(self.rfile, n)))
        msg = json.loads(payload)
        open(os.path.join(tmp, "cdp-request.json"), "w").write(json.dumps(msg))
        expr = msg["params"]["expression"]
        mode = open(os.path.join(tmp, "cdp-mode")).read().strip()
        if mode == "ok":
            value = {"collection": "added", "collectionCreated": True, "art": [0, 1, 3], "icon": True}
            result = {"result": {"type": "object", "value": value}}
        elif mode == "noapp":
            result = {"result": {"type": "object", "value": {"error": "no app 42"}}}
        else:
            result = {"result": {"type": "undefined"}, "exceptionDetails": {"text": "Uncaught", "exception": {"description": "ReferenceError: collectionStore is not defined"}}}
        # Reply in two fragments, unmasked, with an interleaved ping -- what a server may do.
        reply = json.dumps({"id": msg["id"], "result": result}).encode()
        half = len(reply) // 2
        def frame(op, fin, data):
            head = bytes([(0x80 if fin else 0) | op])
            if len(data) < 126: head += bytes([len(data)])
            else: head += bytes([126]) + struct.pack(">H", len(data))
            return head + data
        self.wfile.write(frame(0x1, False, reply[:half]))
        self.wfile.write(frame(0x9, True, b"hi"))
        self.wfile.write(frame(0x0, True, reply[half:]))
        self.wfile.flush()
        self.close_connection = True
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(tmp, "cefport"), "w").write(str(srv.server_port))
srv.serve_forever()
EOF
python3 "$TMP/cefserver.py" "$TMP" & PIDS+=($!)
for _ in $(seq 50); do [[ -s "$TMP/cefport" ]] && break; sleep 0.1; done
export NOVADECK_STEAM_CEF="127.0.0.1:$(cat "$TMP/cefport")"
art="$TMP/art"; mkdir -p "$art"
# Real magic bytes, and a hero big enough that the frame needs the 64-bit length.
{ printf '\x89PNG\r\n\x1a\n'; head -c 100 /dev/zero; } >"$art/icon.png"
{ printf '\xff\xd8\xff\xe0'; head -c 100 /dev/urandom; } >"$art/grid.jpg"       # distinct bytes, so a
{ printf '\xff\xd8\xff\xe0'; head -c 100 /dev/urandom; } >"$art/portrait.jpg"   # swapped type shows
{ printf '\xff\xd8\xff\xe0'; head -c 90000 /dev/urandom; } >"$art/hero.jpg"
printf 'RIFF....WEBP' >"$art/logo.webp"   # a format Steam does not take: must be skipped
echo ok >"$TMP/cdp-mode"
out="$(python3 "$STEAM_TITLE" apply 2902312254 --collection "Google Play" --art "$art" --icon "$art/icon.png" 2>"$TMP/st.err")"; rc=$?
[[ $rc == 0 ]] && ok "apply succeeds against the debugger (exit 0)" || bad "apply exited $rc: $(cat "$TMP/st.err")"
[[ "$out" == $'collection added\nart 0\nart 1\nart 3\nicon set' ]] && ok "reports what Steam did" || bad "apply output: $out"
req="$TMP/cdp-request.json"
python3 - "$req" "$art" <<'EOF' && ok "the script carries the app id, the collection, each image as base64 with Steam's asset type, and the icon path" || bad "the evaluated script is not what Steam needs (see above)"
import base64, json, re, sys
msg = json.load(open(sys.argv[1])); art = sys.argv[2]
p = msg["params"]; e = p["expression"]
assert msg["method"] == "Runtime.evaluate" and p["awaitPromise"] and p["returnByValue"]
assert "const appid = 2902312254," in e
assert '"Google Play"' in e
assert "collectionStore.userCollections" in e and "NewUnsavedCollection" in e and "AsDragDropCollection().AddApps" in e
assert "SteamClient.Apps.SetCustomArtworkForApp(appid, data, ext, type)" in e
assert "appStore.GetAppOverviewByAppID(appid)" in e
m = re.search(r"art = (\[.*?\]), iconPath = (\".*?\");", e, re.S)
entries = json.loads(m.group(1))
got = {(t, x): base64.b64decode(d) for t, x, d in entries}
assert sorted(got) == [(0, "jpg"), (1, "jpg"), (3, "jpg")], got.keys()
# Steam's enum: 0 is the portrait capsule, 3 the wide grid; the icon never goes in as art (4 would
# overwrite the wide grid), only as the shortcut icon.
assert got[(0, "jpg")] == open(art + "/portrait.jpg", "rb").read()
assert got[(3, "jpg")] == open(art + "/grid.jpg", "rb").read()
assert not any(t == 2 for t, _, _ in entries), "webp logo should be skipped"
assert got[(1, "jpg")] == open(art + "/hero.jpg", "rb").read()
assert json.loads(m.group(2)) == art + "/icon.png"
EOF
python3 "$STEAM_TITLE" apply 1 --collection "Google Play" >/dev/null 2>&1 \
    && python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["params"]["expression"]; sys.exit(0 if "art = [], iconPath = null;" in e else 1)' "$req" \
    && ok "collection alone, with no art dir, sends no art and no icon" || bad "apply without --art failed"
echo noapp >"$TMP/cdp-mode"
python3 "$STEAM_TITLE" apply 42 --collection x >/dev/null 2>"$TMP/st.err"; rc=$?
[[ $rc == 2 ]] && grep -q "no app 42" "$TMP/st.err" && ok "Steam not knowing the app: exit 2 with its reason" || bad "noapp: exit $rc: $(cat "$TMP/st.err")"
echo throw >"$TMP/cdp-mode"
python3 "$STEAM_TITLE" apply 42 --collection x >/dev/null 2>"$TMP/st.err"; rc=$?
[[ $rc == 1 ]] && grep -q "collectionStore is not defined" "$TMP/st.err" && ok "a JS exception is reported, exit 1" || bad "throw: exit $rc: $(cat "$TMP/st.err")"
NOVADECK_STEAM_CEF=127.0.0.1:1 python3 "$STEAM_TITLE" apply 42 --collection x >/dev/null 2>"$TMP/st.err"; rc=$?
[[ $rc == 1 ]] && ok "no debugger listening: exit 1 (try later), no traceback" || bad "unreachable CEF: exit $rc: $(cat "$TMP/st.err")"
grep -q Traceback "$TMP/st.err" && bad "unreachable CEF printed a traceback" || true

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
