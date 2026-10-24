#!/usr/bin/env bash
# Offline checks for the novadeck-stores Steam API watch: apps/decky/novadeck-stores/steam-api/
# (tokens + check.py), which upstream-watch.yml's steam-client-api job runs against every live
# steamdeck_stable build.
#
#   tests/test-store-steam-api.sh
#
# WHY THIS FILE EXISTS. The watcher is only as good as its list. A SteamClient call added to src/
# without a token is a call no one watches, and a token for a call src/ dropped is an issue filed
# about nothing. So the list and src/ are compared BOTH ways here. The second half runs check.py
# against fixture bundles built from the list itself, so a checker that passes everything (or
# nothing) fails here instead of going quiet in the watcher.
#
# WHAT IT CANNOT PROVE: that a name in the bundle is a working binding, or that a route patch's
# React tree still has its shape. Those are the device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/apps/decky/novadeck-stores"
TOKENS="$PLUGIN/steam-api/tokens"
CHECK="$PLUGIN/steam-api/check.py"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

pysuite() {
  local name="$1" out rc
  shift
  out="$(python3 -I - "$@")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== the token list matches src/"
pysuite "list" "$TOKENS" "$PLUGIN" <<'PY'
import json, pathlib, re, sys

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tokens, plugin = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = "\n".join(p.read_text() for p in sorted((plugin / "src").rglob("*.ts*")))

listed = {}          # kind -> set of tuples
for line in tokens.read_text().splitlines():
    f = line.split("#", 1)[0].split()
    if f:
        listed.setdefault(f[0], set()).add(tuple(f[1:]))
names = lambda *kinds: {t[0] for k in kinds for t in listed.get(k, ())}

# What src/ reaches for, by the forms it is written in.
used = {
    "SteamClient.Apps methods": ({m for m in re.findall(r"\bapps\??\.([A-Z]\w*)", src)}, names("api", "native")),
    "window globals": (set(re.findall(r"\(window as [^)]*\)\??\.(\w+)", src)), names("global", "binding", "decky")),
    "appStore methods": (set(re.findall(r"\b(?:appStore|store)\??\.([A-Z]\w*)", src)), names("store")),
    "code markers": (set(re.findall(r'toString\?\.\(\)\.includes\("([^"]+)"\)', src)), names("marker")),
    "React internals": (set(re.findall(r"\b(__[A-Z_]+_DO_NOT_USE_\w+)", src)),
                        {a for t in listed.get("oneof", ()) for a in t}),
    "class keys": ({(e, k) for e, k in re.findall(r"\b(\w+Classes)\??\.(\w+)", src)},
                   {(t[0], t[2]) for t in listed.get("class", ())}),
}
for what, (in_src, in_list) in used.items():
    (ok if in_src else bad)(f"src/ has {what} to watch (an empty extract means the pattern went stale)")
    unlisted, stale = sorted(in_src - in_list), sorted(in_list - in_src)
    (ok if not unlisted else bad)(f"every one of the {what} src/ uses is listed{f' — missing: {unlisted}' if unlisted else ''}")
    (ok if not stale else bad)(f"no listed {what} is unused{f' — stale: {stale}' if stale else ''}")

kinds = set(listed) - {"decky-ui", "api", "native", "binding", "global", "decky", "store", "marker", "oneof", "class"}
(ok if not kinds else bad)(f"every line has a kind check.py knows{f' — unknown: {sorted(kinds)}' if kinds else ''}")
(ok if all(len(t) == 3 for t in listed.get("class", ())) else bad)("every class line names export, finder and key")

# The finder keys are @decky/ui's at one version; moving off it means re-reading static-classes.js.
pinned = json.loads((plugin / "package.json").read_text())["dependencies"]["@decky/ui"]
(ok if listed.get("decky-ui") == {(pinned,)} else bad)(
    f"the class finder keys are for the @decky/ui package.json pins ({pinned}; list says {listed.get('decky-ui')})")
PY

echo "== check.py against fixture bundles"
pysuite "checker" "$TOKENS" "$CHECK" <<'PY'
import pathlib, subprocess, sys, tempfile

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tokens, check = sys.argv[1], sys.argv[2]
lines = [l.split("#", 1)[0].split() for l in pathlib.Path(tokens).read_text().splitlines()]
lines = [l for l in lines if l and l[0] != "decky-ui"]

def present(kind, args):
    """The snippet a bundle carries when this token is there, in the bundle's own minified forms."""
    if kind == "api":    return f"x=>SteamClient.Apps?.{args[0]}(a,b);"
    if kind == "global": return f"window.{args[0]}=s;"
    if kind == "store":  return f"class S{{m(){{}}{args[0]}(V){{return 1}}}}"
    if kind == "marker": return f'f("{args[0]}");'
    if kind == "oneof":  return f"r.{args[-1]}=1;"
    if kind == "class":  return f'e.exports={{Other:"a",{args[1]}:"b",{args[2]}:"c"}};'
    return ""

def run(files):
    with tempfile.TemporaryDirectory() as d:
        for name, text in files.items():
            p = pathlib.Path(d, name)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        r = subprocess.run([sys.executable, "-I", check, tokens, d], capture_output=True, text=True)
        return r.returncode, r.stdout

full = "\n".join(present(l[0], l[1:]) for l in lines)
rc, out = run({"steamui/sp.js": full})
(ok if rc == 0 and "MISSING" not in out else bad)(f"a bundle with every token passes (rc {rc})")
(ok if "UNCHECKED native SpecifyCompatTool" in out else bad)("a native-only call is reported UNCHECKED, never ok")

checked = [l for l in lines if l[0] not in ("native", "binding", "decky")]
for l in checked:
    rc, out = run({"steamui/sp.js": "\n".join(present(m[0], m[1:]) for m in lines if m is not l)})
    (ok if rc == 1 and f"MISSING   {' '.join(l)}" in out else bad)(f"dropping `{' '.join(l)}` is reported MISSING (rc {rc})")

marker = next(l for l in lines if l[0] == "marker")
rest = "\n".join(present(m[0], m[1:]) for m in lines if m is not marker)
rc, out = run({"steamui/sp.js": rest, "steamui\\localization\\steamui_english-json.js": f'{{"{marker[1]}":"x"}}'})
(ok if rc == 1 else bad)("a marker found only in a localization table is MISSING — the zip's Windows paths included")

cls = next(l for l in lines if l[0] == "class")
rc, out = run({"steamui/sp.js": "\n".join(present(m[0], m[1:]) for m in lines if m is not cls)
               + f'\ne.exports={{{cls[2]}:"b"}};e.exports={{{cls[3]}:"c"}};'})
(ok if rc == 1 and f"the {cls[2]} module has no {cls[3]}" in out else bad)(
    "a class key that moved to ANOTHER module is MISSING — the finder would pick the wrong one")

rc, out = run({"steamui/library.js": full})
(ok if rc == 2 else bad)(f"a directory with no sp.js is exit 2, not a pass (rc {rc})")
rc, out = run({})
(ok if rc == 2 else bad)(f"an empty directory is exit 2, not a pass (rc {rc})")
PY

echo
echo "steam-api: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
