#!/usr/bin/env bash
# Offline checks for alien-games milestone 6: the launch path (.claude/plans/alien-games-launch.plan.md).
#
#   tests/test-store-launch.sh
#
# WHY THIS FILE EXISTS. Model B hands the launch to Steam (Exe = the game binary + a compat tool),
# so the risky parts to get right offline are: resolving the installed game's executable from each
# store's own metadata, deciding which compat tool a platform wants (Windows → Proton, native →
# none), and the managed-install-root ownership test that replaces the retired stub's basename.
#
# WHAT IT CANNOT PROVE: that setting a compat tool makes Steam build SLR4+Proton, that the title
# renders, or that game-launch fronts the composed chain. Those are the hardware gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORES_PY="$ROOT/apps/decky/novadeck-stores/py_modules"
PASS=0 FAIL=0 SKIP=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

pysuite() {
  local name="$1" out rc
  out="$(python3 - "$STORES_PY")"
  rc=$?
  printf '%s\n' "$out"
  PASS=$((PASS + $(grep -c '^  ok ' <<<"$out" || true)))
  FAIL=$((FAIL + $(grep -c '^  FAIL' <<<"$out" || true)))
  [ "$rc" -eq 0 ] || bad "the $name checks crashed (exit $rc) — every check after the crash never ran"
}

echo "== resolve, compat decision, managed-root ownership"
pysuite "launch" <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, sys.argv[1])

def ok(m): print(f"  ok   {m}")
def bad(m): print(f"  FAIL {m}")

from novadeck_stores import launch

# -- compat tool decision --
(ok if launch.compat_tool("windows") == "proton-cachyos-11.0-arm64" else bad)(
    "a Windows title wants our arm64 Proton")
(ok if launch.compat_tool("linux") is None else bad)(
    "a native Linux title wants NO compat tool — bare binfmt+FEX")

tmp = pathlib.Path(tempfile.mkdtemp(prefix="store-launch."))
uid = os.getuid()

# -- Epic: resolved from legendary's installed.json (a file read, no launch invocation) --
lgd = tmp / "legendary"
lgd.mkdir()
install_dir = tmp / "Games" / "Epic" / "Breathedge"
install_dir.mkdir(parents=True)
(lgd / "installed.json").write_text(json.dumps({
    "0a20": {"app_name": "0a20", "title": "Breathedge",
             "install_path": str(install_dir), "executable": "Breathedge.exe"}}))
p = {"LEGENDARY_CONFIG_PATH": str(lgd), "NOVADECK_STORE_UID": str(uid),
     "NOVADECK_STORE_USER": os.environ.get("USER", "nobody")}
t = launch.resolve_target("epic", "0a20", p, {})
(ok if t and t["exe"] == str(install_dir / "Breathedge.exe") and t["platform"] == "windows" else bad)(
    f"Epic resolves exe = install_path/executable from installed.json ({t})")
(ok if launch.resolve_target("epic", "missing", p, {}) is None else bad)(
    "an Epic game not in installed.json resolves to None, never a guess")

# -- GOG Windows: primary playTask from goggame-<id>.info --
gog_dir = tmp / "Games" / "GOG" / "Witcher"
gog_dir.mkdir(parents=True)
(gog_dir / "goggame-123.info").write_text(json.dumps({"playTasks": [
    {"category": "document", "path": "manual.pdf"},
    {"category": "game", "path": "bin/witcher.exe", "isPrimary": True},
    {"category": "game", "path": "bin/other.exe"},
]}))
rec = {"path": str(gog_dir), "platform": "windows"}
t = launch.resolve_target("gog", "123", p, rec)
(ok if t and t["exe"] == str(gog_dir / "bin/witcher.exe") and t["platform"] == "windows" else bad)(
    f"GOG Windows resolves the PRIMARY game playTask ({t})")

# -- GOG native Linux: the install-root start.sh, no compat tool --
rec_linux = {"path": str(gog_dir), "platform": "linux"}
t = launch.resolve_target("gog", "123", p, rec_linux)
(ok if t and t["exe"] == str(gog_dir / "start.sh") and t["platform"] == "linux" else bad)(
    f"GOG native resolves install-root start.sh ({t})")
(ok if launch.compat_tool(t["platform"]) is None else bad)(
    "and a native resolution carries no compat tool")

# -- managed-root ownership: Exe under a <volume>/Games/<store> root --
vols = [{"path": str(tmp), "label": "Internal", "free": 1}]
roots = launch.managed_roots({"NOVADECK_STORE_USER": "x"}, vols=vols)
(ok if launch.under_managed_root(str(install_dir / "Breathedge.exe"), roots) else bad)(
    "a game under <vol>/Games/Epic is ours")
(ok if launch.under_managed_root(str(gog_dir / "bin/witcher.exe"), roots) else bad)(
    "a game under <vol>/Games/GOG is ours")
(ok if not launch.under_managed_root("/usr/bin/retroarch", roots) else bad)(
    "a foreign binary outside our tree is not ours")
(ok if not launch.under_managed_root(str(tmp / "Games" / "Epic"), roots) else bad)(
    "the store root dir itself (no game under it) is not a game we own")
# a symlink that points out of the tree does not launder ownership
evil = tmp / "Games" / "Epic" / "escape"
os.symlink("/usr/bin/sh", evil)
(ok if not launch.under_managed_root(str(evil), roots) else bad)(
    "a symlink from inside the tree to /usr/bin is not ours (realpath defeats it)")
(ok if not launch.under_managed_root("", roots) and not launch.under_managed_root(None, roots) else bad)(
    "an empty or missing Exe is not ours")
PY

echo
echo "test-store-launch.sh: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
