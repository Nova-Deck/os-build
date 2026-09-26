#!/usr/bin/env bash
# Offline checks for the two store CLIs: the legendary and gogdl overlay packages, their pins, and
# their place in PKGS and the lock.
#
#   tests/test-store-cli.sh
#
# WHY THIS FILE EXISTS. Both packages land INERT — alien-games milestone 1 ships them with nothing
# on the image calling either one — so every ordinary signal that a package is wrong is absent.
# There is no service to fail, no UI to go blank, no journal line. A misspelled dependency, a pin
# that names a different package than its PKGBUILD builds, or a name that never made it into PKGS
# would sit in the tree looking finished until milestone 3 tried to use it. These are all decisions
# the committed files make about each other, which is exactly what can be checked on the host with
# no root, no device, no container and no network.
#
# THE ONE CHECK THIS CANNOT DO, and it is the one a bump is most likely to get wrong: whether
# `_xdelta_commit` still matches the submodule pointer in upstream's .gitmodules at the pinned tag.
# That needs the network, and an offline suite that reaches out is a suite that fails on a plane.
# What is checked here is internal coherence — the commit in the variable is the commit in the URL,
# so the two cannot drift apart. Matching them to UPSTREAM is a human step at bump time, and
# packages/gogdl/source.pin says so where whoever does the bump will be reading.
#
# The other things this deliberately CANNOT prove: that either binary runs, that either can reach
# its store, and that gogdl's C extension compiled. Those are the build and the HW gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGDIR="$ROOT/packages"
CUSTOMIZE="$ROOT/rootfs/customize-base.sh"
LOCK="$ROOT/rootfs/manifest.lock"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# pkgbuild_field <file> <var> — the RHS of a top-level `var=...` assignment, quotes stripped. Only
# used on scalars (pkgname, pkgver, arch, _xdelta_commit); arrays go through pkgbuild_array.
pkgbuild_field() {
  sed -n "s/^$2=//p" "$1" | head -1 | tr -d "'\"()"
}

# pkgbuild_array <file> <var> — the items of a top-level `var=(...)` array, one per line.
#
# Written with awk rather than `sed -n '/^var=(/,/)/p'` because that range does NOT close on the
# line it opens on: a single-line `depends=('python' 'python-requests')` runs on to the NEXT line
# holding a ')' and swallows makedepends whole. Nor with `tr -d "depends=()'"`, which deletes those
# CHARACTERS everywhere and turns python-requests into ytho-rqut. Both were written here first and
# both passed a green-looking suite while checking the wrong strings.
pkgbuild_array() {
  awk -v v="$2" '
    index($0, v "=(") == 1 { inarr = 1; sub("^" v "=\\(", ""); }
    inarr { line = $0; sub(/\).*$/, "", line); print line; if ($0 ~ /\)/) exit }
  ' "$1" | tr -d "'\"" | tr ' ' '\n' | grep -v '^$'
}

# --- both packages: pin and recipe agree ---------------------------------------------------
for pkg in legendary gogdl; do
  pin="$PKGDIR/$pkg/source.pin"
  pkgbuild="$PKGDIR/$pkg/PKGBUILD"

  if [ ! -f "$pin" ] || [ ! -f "$pkgbuild" ]; then
    bad "$pkg: source.pin and PKGBUILD must both exist (found pin=$([ -f "$pin" ] && echo y || echo n) pkgbuild=$([ -f "$pkgbuild" ] && echo y || echo n))"
    continue
  fi
  ok "$pkg: source.pin + PKGBUILD present"

  # The pin's name IS the work/ build dir and the repo entry. A pin naming one package and a
  # PKGBUILD building another produces an artifact nothing resolves, and build-overlay says
  # nothing about it.
  [ "$(pin_field "$pin" name)" = "$pkg" ] \
    && ok "$pkg: source.pin name matches the directory" \
    || bad "$pkg: source.pin name is '$(pin_field "$pin" name)', expected '$pkg'"

  [ "$(pkgbuild_field "$pkgbuild" pkgname)" = "$pkg" ] \
    && ok "$pkg: PKGBUILD pkgname matches the pin" \
    || bad "$pkg: PKGBUILD pkgname is '$(pkgbuild_field "$pkgbuild" pkgname)', expected '$pkg'"

  # Local recipe, not a fetched holo one: neither package exists in any holo repo, so the
  # pkgbuild_repo/path/ref triple would have nothing to fetch.
  [ "$(pin_field "$pin" pkgbuild_local)" = "PKGBUILD" ] \
    && ok "$pkg: pin declares the local PKGBUILD" \
    || bad "$pkg: pin has no 'pkgbuild_local: PKGBUILD' (a fetched pin would need repo/path/ref)"

  # pkgrel_suffix is what makes pacman prefer our build on a later upgrade. It must be an integer;
  # build-overlay turns N into pkgrel N.<suffix>.
  case "$(pin_field "$pin" pkgrel_suffix)" in
    ''|*[!0-9]*) bad "$pkg: pkgrel_suffix must be an integer, got '$(pin_field "$pin" pkgrel_suffix)'" ;;
    *)           ok  "$pkg: pkgrel_suffix is an integer" ;;
  esac

  grep -q '^sha256sums=' "$pkgbuild" \
    && ok "$pkg: sources are pinned by sha256" \
    || bad "$pkg: no sha256sums — an upstream retag would go unnoticed"

  # Every dependency has to resolve. The lock is the list of what the image actually installs, so a
  # name absent from it is a name pacman could not find — which is how gtk2 was learned.
  deps="$(pkgbuild_array "$pkgbuild" depends)"
  missing=""
  for d in $deps; do
    grep -qE "^${d} " "$LOCK" || missing="$missing $d"
  done
  if [ -n "$missing" ]; then
    bad "$pkg: depends not present in rootfs/manifest.lock:$missing (relock, or the name is wrong)"
  else
    ok "$pkg: every depends name has a row in rootfs/manifest.lock"
  fi

  # In PKGS, or the package is built and never installed.
  grep -qE "^PKGS=\(.*[( ]${pkg}[ )]" "$CUSTOMIZE" \
    && ok "$pkg: named in PKGS" \
    || bad "$pkg: not in PKGS — it would build into the overlay and never reach the image"
done

# --- legendary is arch-independent, gogdl is not -------------------------------------------
# This is the distinction the PRD got wrong before the packages existed ("the store CLIs are
# Python"), and it is load-bearing: gogdl compiles a C extension, so an `any` package would ship a
# .so built for whatever built it.
[ "$(pkgbuild_field "$PKGDIR/legendary/PKGBUILD" arch)" = "any" ] \
  && ok "legendary: arch=any (pure Python, no compiled artifact)" \
  || bad "legendary: arch is '$(pkgbuild_field "$PKGDIR/legendary/PKGBUILD" arch)', expected any"

[ "$(pkgbuild_field "$PKGDIR/gogdl/PKGBUILD" arch)" = "aarch64" ] \
  && ok "gogdl: arch=aarch64 (it builds the gogdl_xdelta3 extension)" \
  || bad "gogdl: arch is '$(pkgbuild_field "$PKGDIR/gogdl/PKGBUILD" arch)', expected aarch64"

# --- gogdl: the submodule trap --------------------------------------------------------------
GOGDL="$PKGDIR/gogdl/PKGBUILD"
XCOMMIT="$(pkgbuild_field "$GOGDL" _xdelta_commit)"

case "$XCOMMIT" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ok "gogdl: _xdelta_commit is a full 40-char sha" ;;
  *)
    bad "gogdl: _xdelta_commit is '$XCOMMIT' — must be a full 40-char commit, not a branch or tag" ;;
esac

# Two sources, because GitHub ships the submodule directory EMPTY. One source is the failure mode
# this package exists to avoid re-discovering. Counted by the `name::url` separator every entry
# here uses, NOT by a literal `::http` — the first source builds its URL from $url, so a grep for
# the scheme sees one of the two and reports a shape that is not there.
gogdl_sources="$(pkgbuild_array "$GOGDL" source | grep -c '::')"
[ "$gogdl_sources" -eq 2 ] \
  && ok "gogdl: two sources (the tarball's xdelta3/ is an empty submodule dir)" \
  || bad "gogdl: expected 2 sources, found $gogdl_sources — a one-source build cannot compile the extension"

[ "$(pkgbuild_array "$GOGDL" sha256sums | grep -cE "^[0-9a-f]{64}$")" -eq 2 ] \
  && ok "gogdl: both sources carry a sha256" \
  || bad "gogdl: sha256sums does not cover both sources"

# The variable and the URL cannot drift apart. (Matching either to UPSTREAM is the bump-time human
# step — see this file's header.)
grep -q "xdelta/archive/\${_xdelta_commit}.tar.gz" "$GOGDL" \
  && ok "gogdl: the xdelta source URL is built from _xdelta_commit, so they cannot disagree" \
  || bad "gogdl: the xdelta source URL does not interpolate _xdelta_commit — the pin and the fetch can drift"

# prepare() has to put the xdelta repo root AT xdelta3/, one level: gogdl_xdelta3.c includes
# <xdelta3/xdelta3.h> and pyproject sets include-dirs = ["xdelta3"].
sed -n '/^prepare()/,/^}/p' "$GOGDL" | grep -q 'mv .*xdelta3$' \
  && ok "gogdl: prepare() moves the xdelta tree to xdelta3/" \
  || bad "gogdl: prepare() does not place the xdelta tree at xdelta3/ — the include path would not resolve"

# rmdir, not rm -rf: if upstream ever ships real content there, this must fail loudly.
sed -n '/^prepare()/,/^}/p' "$GOGDL" | grep -q 'rmdir xdelta3' \
  && ok "gogdl: prepare() rmdirs the placeholder (fails loudly if it is ever non-empty)" \
  || bad "gogdl: prepare() should rmdir the empty placeholder, not force-remove it"

# --- where credentials live -------------------------------------------------------------------
# The location is a decision, not a default, and both wrong answers are reachable: each CLI's own
# default follows the CALLER's home (root for the Decky backend, deck for the launch path), and
# /root looks persistent enough to be tempting. Assert the declaration rather than trusting either.
STORE_ENV="$ROOT/rootfs/overlay/usr/lib/novadeck/store-env"

if [ ! -x "$STORE_ENV" ]; then
  bad "store-env missing or not executable at usr/lib/novadeck/store-env"
else
  ok "store-env present and executable"

  # The host has no deck user, so its uid is handed in; the lookup itself is checked below.
  env_out="$(NOVADECK_STORE_UID=1000 bash "$STORE_ENV" 2>/dev/null)"
  for var in NOVADECK_STORE_USER NOVADECK_STORE_UID NOVADECK_STORE_HOME LEGENDARY_CONFIG_PATH \
             NOVADECK_GOGDL_AUTH GOGDL_CONFIG_PATH NOVADECK_STORE_INSTALLS; do
    printf '%s\n' "$env_out" | grep -q "^${var}=" \
      && ok "store-env emits $var" \
      || bad "store-env does not emit $var — a caller would fall back to the CLI's own default"
  done

  # Every emitted path under the deck user's home. /root is the specific wrong answer this
  # guards: it persists (it is an offload bind from the same /home tree), so "it survives an OTA"
  # is true there and still not a reason to put the user's store accounts in root's home.
  strays=""
  while IFS='=' read -r key value; do
    case "$key" in NOVADECK_STORE_USER|NOVADECK_STORE_UID) continue ;; esac   # the account, not a path
    case "$value" in
      /home/deck/*) ;;
      '') ;;
      *) strays="$strays $value" ;;
    esac
  done <<EOF
$env_out
EOF
  if [ -n "$strays" ]; then
    bad "store-env points outside /home/deck:$strays"
  else
    ok "every store-env path is under /home/deck (not /root, /etc or /var)"
  fi

  # --ensure has to create the parents 0700. gogdl does not create its own parent and its writer
  # runs AFTER the code exchange, so a missing directory costs the user a single-use login.
  tmphome="$(mktemp -d)"
  if NOVADECK_STORE_USER="$(id -un)" NOVADECK_STORE_HOME="$tmphome/stores" \
     bash "$STORE_ENV" --ensure >/dev/null 2>&1; then
    modes="$(find "$tmphome/stores" -type d -printf '%m\n' 2>/dev/null | sort -u)"
    [ "$modes" = "700" ] \
      && ok "--ensure creates the tree 0700 (these are OAuth refresh tokens)" \
      || bad "--ensure left directory modes '$modes', expected only 700"
    [ -d "$tmphome/stores/gogdl" ] \
      && ok "--ensure creates gogdl's parent, which gogdl itself will not" \
      || bad "--ensure does not create gogdl's parent directory"
  else
    bad "store-env --ensure failed against a writable temp tree"
  fi
  rm -rf "$tmphome"

  # The plugin reads a credential file as root only if the store user owns it, so the uid it
  # compares against has to be the user's real one.
  [ "$(NOVADECK_STORE_USER="$(id -un)" bash "$STORE_ENV" 2>/dev/null \
       | sed -n 's/^NOVADECK_STORE_UID=//p')" = "$(id -u)" ] \
    && ok "store-env resolves the store user's uid" \
    || bad "store-env does not emit the store user's uid — root would read files it cannot vouch for"

  # The plugin runs store-env as ROOT, and every path it creates is inside a home the user owns.
  # A root `install -o` there follows a symlink the user (or any game) planted, and chowns its
  # target — a local root primitive. It must create the tree AS the user instead.
  if grep -Eq '^[^#]*install[^#]*[[:space:]]-o[[:space:]]' "$STORE_ENV"; then
    bad "store-env runs install -o — as root that chowns whatever a planted symlink points at"
  else
    ok "store-env never has root chown into the user's home (no install -o)"
  fi
  grep -q 'runuser -u "\$STORE_USER"' "$STORE_ENV" \
    && ok "store-env drops to the store user before creating the tree" \
    || bad "store-env does not drop to the store user for --ensure"
fi

# The plugin has to ASK store-env, not repeat its answer. A second copy of the paths would
# drift the first time the location moves, and the symptom is the worst kind: an account that
# reads as connected in the QAM and absent at launch, because the two callers looked in
# different directories.
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules/novadeck_stores"
if [ -d "$STORES_PY" ]; then
  grep -q 'store-env' "$STORES_PY/paths.py" 2>/dev/null \
    && ok "novadeck-stores resolves credential paths by running store-env" \
    || bad "novadeck-stores does not reference store-env — it is repeating the paths"
  hardcoded="$(grep -rn "/home/deck/\.local\|\.config/legendary\|gogdl/auth\.json" "$STORES_PY" \
               | grep -v '^\S*paths\.py' | grep -v '#' || true)"
  [ -z "$hardcoded" ] \
    && ok "novadeck-stores hardcodes no credential path outside paths.py" \
    || bad "novadeck-stores hardcodes credential paths: $hardcoded"
else
  bad "novadeck-stores py_modules missing — the QAM surface has no backend"
fi

[ "$(NOVADECK_STORE_UID=1000 bash "$STORE_ENV" 2>/dev/null | sed -n 's/^NOVADECK_STORE_USER=//p')" = deck ] \
  && ok "store-env declares deck as the account the CLIs run as" \
  || bad "store-env does not declare NOVADECK_STORE_USER=deck — the CLIs would write as someone else"

# --- sign-in: capturing the code and handing it to the CLI --------------------------------
# The sign-in happens in Steam's browser, on hardware, with a real account — none of which this
# suite has. What it CAN drive is every decision the backend makes about what it sees: which page
# is a store's redirect, where the code is in it, that a leftover redirect from an earlier sign-in
# is ignored (its code is spent, and grabbing it fails the exchange before the user has seen the
# login), and that the CLI is run as the user with its stdout thrown away. Those are the parts
# that fail silently; a wrong URL at least fails on screen.
pyout="$(python3 - "$STORES_PY/.." <<'PY'
import asyncio, subprocess, sys
sys.path.insert(0, sys.argv[1])
from novadeck_stores import cli, connect

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

GOG_DONE = "https://embed.gog.com/on_login_success?origin=client&code=GOGCODE"
EPIC_DONE = "https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code"

# -- recognising the redirect --
checks = [
    (connect.is_redirect("gog", GOG_DONE), "GOG's on_login_success is its redirect"),
    (not connect.is_redirect("gog", connect.GOG_LOGIN_URL),
     "GOG's login page is NOT its redirect, though it names the redirect in its own query string"),
    (connect.is_redirect("epic", EPIC_DONE), "Epic's /id/api/redirect is its redirect"),
    (not connect.is_redirect("epic", "https://www.epicgames.com/id/login?redirectUrl=" + EPIC_DONE),
     "Epic's login page is NOT its redirect, though it carries the redirect as a parameter"),
    (not connect.is_redirect("gog", EPIC_DONE), "one store's redirect is not the other's"),
    (not connect.is_redirect("gog", None), "a target with no url is not a redirect"),
]
for passed, label in checks:
    (ok if passed else bad)(label)

# -- extracting the code --
(ok if connect.code_from_url(GOG_DONE) == "GOGCODE" else bad)("GOG: the code is read from the redirect's query")
(ok if connect.code_from_url(GOG_DONE.replace("GOGCODE", "")) is None else bad)("GOG: an empty code= is no code")
body = '{"warning":"x","redirectUrl":"https://localhost/launcher/authorized?code=EPICCODE","authorizationCode":"EPICCODE","sid":null}'
(ok if connect.code_from_body(body) == "EPICCODE" else bad)("Epic: the code is read from the page's authorizationCode")
(ok if connect.code_from_body('{"authorizationCode":null}') is None else bad)(
    "Epic: the signed-out page's null is no code (it loads BEFORE the login form)")

# -- the capture loop, driven with fake target lists --
def run(store, polls, bodies=None, before=None, timeout=10):
    """polls: one target list per poll (an Exception instance = that poll fails)."""
    seq = iter(polls)
    reads = []
    async def list_targets():
        item = next(seq, [])
        if isinstance(item, Exception):
            raise item
        return item
    async def read_body(t):
        reads.append(t["id"])
        return (bodies or {}).get(t["id"])
    now = [0.0]
    async def sleep(s): now[0] += s
    code = asyncio.run(connect.capture(store, list_targets, read_body, before or {}, timeout,
                                       interval=1.0, clock=lambda: now[0], sleep=sleep))
    return code, reads

stale = {"id": "A", "url": GOG_DONE.replace("GOGCODE", "SPENT")}
fresh = {"id": "B", "url": GOG_DONE}
code, _ = run("gog", [[stale], [stale, fresh]], before=connect.snapshot([stale]))
(ok if code == "GOGCODE" else bad)(
    f"GOG: a redirect left from an EARLIER sign-in is ignored, the new one captured (got {code!r})")

same_target = {"id": "A", "url": GOG_DONE}   # the SAME target navigated to a new redirect
code, _ = run("gog", [[same_target]], before=connect.snapshot([stale]))
(ok if code == "GOGCODE" else bad)("GOG: a target that navigates to a NEW redirect counts, even with the same id")

code, _ = run("gog", [OSError("refused"), [fresh]])
(ok if code == "GOGCODE" else bad)("a refused poll (Steam's web helper restarting) is retried, not fatal")

code, reads = run("gog", [[fresh]])
(ok if not reads else bad)("GOG never reads a page body — its code is in the URL")

epic = {"id": "E", "url": EPIC_DONE}
code, reads = run("epic", [[epic], [epic]], bodies={"E": body})
(ok if code == "EPICCODE" else bad)("Epic: the code is taken from the redirect page's body")
code, _ = run("epic", [[epic]] * 5, bodies={"E": '{"authorizationCode":null}'}, timeout=3)
(ok if code is None else bad)("Epic: a redirect page that never carries a code times out as None")

code, _ = run("gog", [], timeout=3)
(ok if code is None else bad)("a login nobody finishes ends at the timeout with no code")

# -- the exchange --
p = {"NOVADECK_STORE_USER": "deck", "LEGENDARY_CONFIG_PATH": "/h/legendary",
     "NOVADECK_GOGDL_AUTH": "/h/gogdl/auth.json", "GOGDL_CONFIG_PATH": "/h/gogdl"}
argv = cli.exchange_argv("gog", "C", p)
(ok if argv[:3] == ["gogdl", "--auth-config-path", "/h/gogdl/auth.json"] and argv[3:] == ["auth", "--code", "C"] else bad)(
    "gogdl gets --auth-config-path BEFORE the subcommand (without it the tokens are thrown away)")
(ok if cli.exchange_argv("epic", "C", p) == ["legendary", "auth", "--code", "C"] else bad)(
    "legendary is handed the code with --code")

seen = {}
real_run = subprocess.run
def fake_run(argv, **kw):
    seen.update(argv=argv, **kw)
    return subprocess.CompletedProcess(argv, 0)
subprocess.run = fake_run
try:
    cli.exchange("epic", "SECRETCODE", p)
finally:
    subprocess.run = real_run
sd = seen["argv"]
sep = sd.index("--") if "--" in sd else len(sd)
opts, cmd = sd[:sep], sd[sep + 1:]
setenv = dict(o.split("=", 1)[1].split("=", 1) for o in opts if o.startswith("--setenv="))
(ok if sd[0] == "systemd-run" and cmd == ["legendary", "auth", "--code", "SECRETCODE"] else bad)(
    "the CLI is started by host systemd — under FEX a direct child resolves #!/usr/bin/python to "
    "the x86 guest's python, which has no legendary or gogdl (HW-observed: ModuleNotFoundError)")
(ok if "--property=User=deck" in opts else bad)(
    "the CLI runs as the store user, so its credential files are the user's from creation")
(ok if "--property=UMask=0077" in opts else bad)(
    "the CLI runs under umask 077, so the token files are 0600 — both CLIs create them with a "
    "bare open(..., 'w'), which would otherwise give 0644 (HW-observed)")
(ok if "--pipe" in opts and "--wait" in opts else bad)(
    "the unit's output comes back to us (--pipe) and we wait for its exit (--wait) — without "
    "--pipe systemd writes gogdl's token set to the journal")
(ok if seen.get("stdout") is subprocess.DEVNULL else bad)(
    "the CLI's stdout is discarded — gogdl prints the whole token set to it")
desc = [o for o in opts if o.startswith("--description=")]
(ok if desc and not any("SECRETCODE" in o for o in opts) else bad)(
    "the unit has its own description, so the journal's Started line does not carry the code")
(ok if setenv.get("LEGENDARY_CONFIG_PATH") == "/h/legendary" else bad)(
    "legendary is pointed at the declared config path, not the caller's home")
(ok if setenv.get("GOGDL_CONFIG_PATH") == "/h/gogdl" else bad)(
    "gogdl is pointed at the declared config path — without it, its build manifests go to the "
    "user's ~/.config/heroic_gogdl, outside the store tree")
extra = set(setenv) - {"LANG", "LEGENDARY_CONFIG_PATH", "GOGDL_CONFIG_PATH"}
(ok if not extra else bad)(f"the CLI gets a minimal environment, not root's (extra: {sorted(extra)})")
(ok if "LD_LIBRARY_PATH" not in seen["env"] else bad)(
    "systemd-run itself does not inherit the PyInstaller bundle's LD_LIBRARY_PATH")
(ok if any(o.startswith("--property=RuntimeMaxSec=") for o in opts) else bad)(
    "the unit has its own deadline — killing systemd-run on our timeout would not stop it")

from novadeck_stores import cdp
(ok if cdp.is_local_debugger("ws://127.0.0.1:8080/devtools/page/ABC") else bad)(
    "the Epic page read accepts Steam's own debugger socket")
for evil in ("ws://10.0.0.5:8080/devtools/page/A", "ws://127.0.0.1:9999/x",
             "wss://127.0.0.1:8080/x", "ws://127.0.0.1:notaport/x", "http://127.0.0.1:8080/x"):
    if cdp.is_local_debugger(evil):
        bad(f"the Epic page read would connect to {evil} — whatever squats :8080 could aim root at any host")
        break
else:
    ok("the Epic page read refuses any socket but loopback :8080 (a squatted port cannot aim root elsewhere)")
PY
)"
pyrc=$?
printf '%s\n' "$pyout"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$pyout" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$pyout" || true)))
[ "$pyrc" -eq 0 ] || bad "the sign-in checks crashed (exit $pyrc) — every check after the crash never ran"

# --- status, refresh and disconnect ----------------------------------------------------------
# Status is read from the credential files; refresh and disconnect go through each CLI's own
# path. What can be checked offline: what the panel is told for each shape of file, that it is
# never told a secret, and which CLI invocation each action runs, as whom.
pyout="$(python3 - "$STORES_PY/.." <<'PY'
import datetime, json, os, subprocess, sys, tempfile, time
sys.path.insert(0, sys.argv[1])
from novadeck_stores import cli, status

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

tmp = tempfile.mkdtemp()
lgd = os.path.join(tmp, "legendary")
os.mkdir(lgd)
gog = os.path.join(tmp, "auth.json")
UID = os.getuid()   # stands in for the store user: the files below are ours

def write(path, data):
    with open(path, "w", encoding="utf-8") as f:
        f.write(data if isinstance(data, str) else json.dumps(data))

def iso(delta):   # legendary's format: naive UTC with a trailing Z
    t = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(seconds=delta)
    return t.isoformat(timespec="milliseconds") + "Z"

ALLOWED = {"store", "connected", "account", "expired"}

# -- Epic --
s = status.epic_status(lgd, UID)
(ok if s == {"store": "epic", "connected": False} else bad)(f"Epic with no user.json is not connected ({s})")
write(os.path.join(lgd, "user.json"), "")
(ok if not status.epic_status(lgd, UID)["connected"] else bad)("Epic with an empty user.json is not connected")
write(os.path.join(lgd, "user.json"), {"displayName": "Loki", "access_token": "SECRET",
                                        "refresh_token": "SECRET", "expires_at": iso(3600)})
s = status.epic_status(lgd, UID)
(ok if s["connected"] and s["account"] == "Loki" and s["expired"] is False else bad)(
    f"a live Epic session is connected, named, and not expired ({s})")
(ok if set(s) <= ALLOWED and "SECRET" not in json.dumps(s) else bad)(
    "the panel is never handed a token, only connected/account/expired")
write(os.path.join(lgd, "user.json"), {"displayName": "Loki", "expires_at": iso(-60)})
(ok if status.epic_status(lgd, UID)["expired"] is True else bad)(
    "an Epic session past expires_at reads as expired (a refresh that could not reach Epic leaves it so)")
write(os.path.join(lgd, "user.json"), {"displayName": "Loki", "expires_at": "garbage"})
s = status.epic_status(lgd, UID)
(ok if s["connected"] and s["expired"] is False else bad)(
    "an unparseable expires_at does not invent an expiry — legendary decides on its next login")

# -- GOG --
s = status.gog_status(gog, UID)
(ok if s == {"store": "gog", "connected": False} else bad)(f"GOG with no auth.json is not connected ({s})")
write(gog, {"46899977096215655": {"access_token": "SECRET", "refresh_token": "SECRET",
                                  "loginTime": time.time(), "expires_in": 3600}})
s = status.gog_status(gog, UID)
(ok if s["connected"] and s["expired"] is False else bad)(f"a live GOG token is connected and not expired ({s})")
(ok if set(s) <= ALLOWED and "SECRET" not in json.dumps(s) else bad)(
    "the GOG status carries no token either")
write(gog, {"46899977096215655": {"access_token": "SECRET", "loginTime": time.time() - 7200, "expires_in": 3600}})
(ok if status.gog_status(gog, UID)["expired"] is True else bad)(
    "a GOG token past loginTime + expires_in reads as expired (gogdl's own test)")

# -- root reads these files inside a tree the user owns --
# Anything running as the user (a game) can swap the file, or any directory above it, for a
# symlink. Root must read only a regular file the store user owns, and must not block on a FIFO.
live = {"46899977096215655": {"access_token": "SECRET", "loginTime": time.time(), "expires_in": 3600}}
elsewhere = os.path.join(tmp, "elsewhere.json")
write(elsewhere, live)
os.remove(gog)
os.symlink(elsewhere, gog)
(ok if not status.gog_status(gog, UID)["connected"] else bad)(
    "a credential file swapped for a symlink is not followed")
os.remove(gog)
write(gog, live)
(ok if not status.gog_status(gog, UID + 1)["connected"] else bad)(
    "a credential file not owned by the store user is not read (a swapped parent directory "
    "leads to someone else's file)")
os.remove(gog)
os.mkfifo(gog)
import threading
done = threading.Event()
threading.Thread(target=lambda: (status.gog_status(gog, UID), done.set()), daemon=True).start()
(ok if done.wait(2) else bad)(
    "a FIFO in place of the credential file does not block root's read (it would hold the "
    "store's lock forever)")
os.remove(gog)

# -- which CLI runs, as whom --
p = {"NOVADECK_STORE_USER": "deck", "LEGENDARY_CONFIG_PATH": "/h/legendary",
     "NOVADECK_GOGDL_AUTH": "/h/gogdl/auth.json", "GOGDL_CONFIG_PATH": "/h/gogdl"}
(ok if cli.refresh_argv("epic", p) == ["legendary", "list-installed", "--check-updates"] else bad)(
    "Epic refreshes through legendary's own login, without fetching the whole library (status does)")
(ok if cli.refresh_argv("gog", p) == ["gogdl", "--auth-config-path", "/h/gogdl/auth.json", "auth"] else bad)(
    "GOG refreshes through gogdl auth, which renews an expired token and writes it back")
(ok if cli.disconnect_argv("epic", p) == ["legendary", "auth", "--delete"] else bad)(
    "Epic disconnects through legendary auth --delete")
(ok if cli.disconnect_argv("gog", p) == ["rm", "-f", "--", "/h/gogdl/auth.json"] else bad)(
    "GOG disconnects by removing its auth file (gogdl has no logout)")

real_run = subprocess.run
for action in ("refresh", "disconnect"):
    for store in ("epic", "gog"):
        seen = {}
        def fake_run(argv, **kw):
            seen.update(argv=argv, **kw)
            return subprocess.CompletedProcess(argv, 0)
        subprocess.run = fake_run
        try:
            getattr(cli, action)(store, p)
        finally:
            subprocess.run = real_run
        sd = seen["argv"]
        opts = sd[:sd.index("--")]
        good = (sd[0] == "systemd-run" and "--property=User=deck" in opts and "--pipe" in opts
                and seen.get("stdout") is subprocess.DEVNULL
                and "--setenv=LEGENDARY_CONFIG_PATH=/h/legendary" in opts)
        (ok if good else bad)(
            f"{action} {store}: runs as deck through host systemd, stdout discarded, at the declared paths")

# -- the per-store lock outlives a cancelled caller --
# start_connect cancels a pending sign-in. If that lands during the exchange, the CLI keeps running
# in its thread: the lock must stay held until it exits, or a second gogdl call can write auth.json
# alongside it. main.py imports decky, which only exists inside the loader, so it is stubbed.
import asyncio, threading, types
sys.modules["decky"] = types.SimpleNamespace(logger=types.SimpleNamespace(info=lambda *a: None))
sys.path.insert(0, os.path.join(sys.argv[1], ".."))
import main

async def cancelled_mid_cli():
    release = threading.Event()
    task = asyncio.create_task(main.Plugin()._run_cli(
        "exchange", "gog", {}, lambda: release.wait(5), ))
    await asyncio.sleep(0.05)              # the CLI "is running"
    task.cancel()
    await asyncio.sleep(0.05)
    held = main._LOCKS["gog"].locked()     # cancelled, but the CLI has not exited
    release.set()
    try:
        await task
    except asyncio.CancelledError:
        pass
    return held, main._LOCKS["gog"].locked()

main._store_status = lambda store, p: {"store": store, "connected": False}
held, after = asyncio.run(cancelled_mid_cli())
(ok if held and not after else bad)(
    f"a cancelled caller keeps the store's lock until its CLI exits, then frees it (held={held}, after={after})")
PY
)"
pyrc=$?
printf '%s\n' "$pyout"
PASS=$((PASS + $(grep -c '^  ok ' <<<"$pyout" || true)))
FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$pyout" || true)))
[ "$pyrc" -eq 0 ] || bad "the status checks crashed (exit $pyrc) — every check after the crash never ran"

# The code is a credential for as long as it lives, and the Decky log is readable by anyone with
# SSH on a dev card. No logger line in the backend may interpolate it.
leaky="$(grep -n 'logger\.' "$ROOT/apps/decky/novadeck-stores/main.py" "$STORES_PY"/*.py | grep -E '\{code\b|%s.*code|\bcode\)' || true)"
[ -z "$leaky" ] \
  && ok "no backend log line interpolates the authorization code" \
  || bad "a backend log line may print the authorization code: $leaky"

# --- the suite is wired in -------------------------------------------------------------------
grep -q 'test-store-cli.sh' "$ROOT/Makefile" \
  && ok "this suite is wired into make test (a suite nothing runs is documentation)" \
  || bad "tests/test-store-cli.sh is not in the Makefile test target"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
