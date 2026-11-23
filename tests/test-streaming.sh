#!/usr/bin/env bash
# Offline check for the NovaDeck Streaming Decky plugin's backend (apps/decky/novadeck-streaming).
#
#   tests/test-streaming.sh
#
# WHY THIS EXISTS. The backend is root and talks to a service the session user runs. It reads a
# password file that user owns and sends it to a local port that user can bind, so a link planted
# in place of the password would hand a root-only file to whoever listens. And it is what lets a
# person play on the device: a pairing reported as done when it was not, or a "Disconnect" that
# leaves the guest's pad plugged in, looks fine on the screen.
#
# So this drives the REAL client against a stub that speaks Sunshine's API over TLS with a
# self-signed certificate, and the file reader against every swap the user could make.
#
# WHAT IT CANNOT PROVE: Sunshine itself, systemd, and the frontend in Steam's UI.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/apps/decky/novadeck-streaming"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PYTHONPYCACHEPREFIX="$TMP/pyc"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

[[ -f $PLUGIN/main.py ]] || { echo "missing: $PLUGIN/main.py" >&2; exit 1; }
for n in sunshine other; do
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/$n.key" -out "$TMP/$n.pem" -days 2 \
        -subj "/CN=Sunshine Gamestream Host" >/dev/null 2>&1 || { echo "openssl failed" >&2; exit 1; }
done

out=$(python3 - "$PLUGIN" "$TMP" <<'PY'
import asyncio, base64, json, os, ssl, sys, time
plugin, tmp = sys.argv[1:3]
sys.path.insert(0, os.path.join(plugin, "py_modules"))
from novadeck_streaming import api, sessions, unit, userfile

def check(name, got, want=True):
    print(("ok   " if got == want else "FAIL ") + name + ("" if got == want else f" (want {want!r}, got {got!r})"))

me = os.getuid()
P = lambda n: os.path.join(tmp, n)
def put(name, data, mode=0o600):
    with open(P(name), "wb") as f: f.write(data)
    os.chmod(P(name), mode)

# -- the file reader: root reads what the user owns
put("pw", b"secret\n")
check("reads a regular file the user owns", userfile.read(P("pw"), me, 256), b"secret\n")
os.symlink(P("pw"), P("link"))
check("refuses a symlink", userfile.read(P("link"), me, 256), None)
check("refuses another owner's file", userfile.read(P("pw"), me + 1, 256), None)
os.mkfifo(P("fifo"))
check("refuses a fifo, without blocking", userfile.read(P("fifo"), me, 256), None)
check("refuses a directory", userfile.read(tmp, me, 256), None)
check("refuses a file over the limit", userfile.read(P("pw"), me, 3), None)
check("a missing file is None", userfile.read(P("nope"), me, 256), None)
os.link(P("pw"), P("hard"))
check("refuses a file with a second name", userfile.read(P("pw"), me, 256), None)
os.unlink(P("hard"))

# -- the API client
UUID = "0B5A1F0E-1111-4222-8333-444455556666"; PID = "ab" * 16
class Stub:
    def __init__(self): self.reqs = []; self.over = {}; self.hang = False; self.clients = [{"uuid": UUID, "name": "max", "enabled": True}]
    async def handle(self, r, w):
        head = (await r.readuntil(b"\r\n\r\n")).decode().split("\r\n")
        method, path, _ = head[0].split(" ")
        hdr = {k.lower(): v for k, v in (h.split(": ", 1) for h in head[1:] if h)}
        body = await r.readexactly(int(hdr.get("content-length", 0)))
        self.reqs.append((method, path, hdr, json.loads(body) if body else None))
        if self.hang and body and not json.loads(body).get("enabled", True):
            await asyncio.sleep(2); w.close(); return
        status, data = self.over.get((method, path), (200, None))
        if data is None:
            data = {"/api/clients/list": {"named_certs": self.clients, "status": True},
                    "/api/pin": {"pairings": [{"id": PID, "name": "phone", "address": "10.0.0.2"}]} if method == "GET" else {"status": True}
                    }.get(path, {"status": True})
        raw = data if isinstance(data, bytes) else json.dumps(data).encode()
        w.write(b"HTTP/1.1 %d X\r\nContent-Length: %d\r\n\r\n" % (status, len(raw)) + raw)
        await w.drain(); w.close()

async def main():
    stub = Stub()
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); sctx.load_cert_chain(P("sunshine.pem"), P("sunshine.key"))
    srv = await asyncio.start_server(stub.handle, "127.0.0.1", 0, ssl=sctx)
    port = srv.sockets[0].getsockname()[1]
    c = api.Client(uid=me, password_file=P("pw"), cert_file=P("sunshine.pem"), port=port)

    check("lists paired guests", await c.guests(), [{"uuid": UUID, "name": "max", "enabled": True}])
    m, p, h, b = stub.reqs[-1]
    check("authenticates as novadeck, newline stripped", h["authorization"], "Basic " + base64.b64encode(b"novadeck:secret").decode())
    check("sends no Origin or Referer, which Sunshine's CSRF check would want a token for", {"origin", "referer"} & set(h), set())
    check("lists pending pairings", await c.pending(), [{"id": PID, "address": "10.0.0.2"}])
    check("without the name the guest sent: every Moonlight sends the same one", "name" in (await c.pending())[0], False)

    check("pairs", await c.pair(PID, "1234", "Sam"), True)
    m, p, h, b = stub.reqs[-1]
    check("with Sunshine's field names, and the name the host gave", (m, p, b), ("POST", "/api/pin", {"pairing_id": PID, "pin": "1234", "name": "Sam"}))
    check("as JSON", h["content-type"], "application/json")
    stub.over[("POST", "/api/pin")] = (200, {"status": False})
    check("a wrong PIN is False, not an error", await c.pair(PID, "0000", "Sam"), False)
    del stub.over[("POST", "/api/pin")]

    n = len(stub.reqs)
    async def refused(coro):
        try: await coro
        except api.ApiError: return True
        return False
    for label, args in (("a short PIN", (PID, "123", "x")), ("a PIN with letters", (PID, "12a4", "x")),
                        ("other digits than 0-9", (PID, "١٢٣٤", "x")), ("a bad pairing id", ("../x", "1234", "x"))):
        check(f"refuses {label}", await refused(c.pair(*args)))
    check("refuses a bad uuid", await refused(c.disconnect("x/../y")))
    check("and none of those reached Sunshine", len(stub.reqs), n)

    check("refuses a guest who is no longer asking", await refused(c.pair("cd" * 16, "1234", "x")))
    check("without sending the PIN", [m for m, *_ in stub.reqs[n:]], ["GET"])
    async def named(raw):
        await c.pair(PID, "1234", raw)
        return stub.reqs[-1][3]["name"]
    check("a name cannot hide or turn text round", await named("S\u202ea\u200bm\x07 \n\n  2"), "Sam 2")
    sent = await named("日" * 99)
    check("a long non-Latin name still fits Sunshine's 128 bytes", (len(sent.encode()) <= 128, set(sent)), (True, {"日"}))
    check("no name: the guest is known by address", [await named(n) for n in ("", "\u200b", None)], ["Guest at 10.0.0.2"] * 3)
    check("a lone surrogate in a name is dropped", await named("a\ud800b"), "ab")

    stub.reqs.clear(); check("dismisses someone asking", await c.dismiss(PID), True)
    check("through Sunshine's own call", stub.reqs[-1][0:2] + (stub.reqs[-1][3],), ("DELETE", "/api/pin", {"pairing_id": PID}))
    check("refuses to dismiss a bad id", await refused(c.dismiss("x")))
    stub.reqs.clear(); check("disconnects", await c.disconnect(UUID), True)
    check("by blocking, which ends the session and removes the pad, then allowing again",
          [(p, b) for _, p, _, b in stub.reqs],
          [("/api/clients/update", {"uuid": UUID, "enabled": False}), ("/api/clients/update", {"uuid": UUID, "enabled": True})])
    stub.reqs.clear(); check("removes", await c.remove(UUID), True)
    check("by ending the session before unpairing", [(p, b) for _, p, _, b in stub.reqs],
          [("/api/clients/update", {"uuid": UUID, "enabled": False}), ("/api/clients/unpair", {"uuid": UUID})])
    stub.over[("POST", "/api/clients/update")] = (200, {"status": False}); stub.reqs.clear()
    check("a disconnect Sunshine refused says so", await c.disconnect(UUID), False)
    check("and does not go on to allow", len(stub.reqs), 1)
    stub.over.clear()
    # Sunshine ends the session inside the request: it can answer late, or not before we give up.
    stub.hang = True; stub.reqs.clear(); api.CHANGE_TIMEOUT, keep = 0.3, api.CHANGE_TIMEOUT
    check("a block whose answer never came is an error", await refused(c.disconnect(UUID)))
    check("but the guest is still allowed again", [b["enabled"] for *_, b in stub.reqs], [False, True])
    stub.reqs.clear(); check("a removal whose block never answered is an error", await refused(c.remove(UUID)))
    check("and does not unpair blindly", [p for _, p, *_ in stub.reqs], ["/api/clients/update"])
    api.CHANGE_TIMEOUT = keep; stub.hang = False
    check("a change waits longer than Sunshine's own 10 s limit on ending a session", api.CHANGE_TIMEOUT > 10)
    stub.reqs.clear(); check("allows a blocked guest", await c.allow(UUID), True)

    for label, over in (("a 401", (401, {})), ("a 500", (500, {})), ("not JSON", (200, b"<html>")),
                        ("a JSON list", (200, b"[]")), ("a nested answer", (200, b"[" * 200000)), ("an oversized answer", (200, b" " * (api.MAX_BODY + 1)))):
        stub.over[("GET", "/api/clients/list")] = over
        check(f"{label} is an error, never an empty list", await refused(c.guests()))
    stub.over[("GET", "/api/clients/list")] = (200, {"named_certs": [{"uuid": "bad", "name": 3}, {"uuid": UUID, "name": "x" * 999, "enabled": True}]})
    check("drops a malformed guest and caps the name", [(g["uuid"], len(g["name"])) for g in await c.guests()], [(UUID, 128)])
    stub.over.clear()

    for label, kw in (("another certificate on the port", {"cert_file": P("other.pem")}), ("no certificate file", {"cert_file": P("none")}),
                      ("no password file", {"password_file": P("none")}), ("a linked password file", {"password_file": P("link")})):
        n = len(stub.reqs)
        bad = api.Client(**{**dict(uid=me, password_file=P("pw"), cert_file=P("sunshine.pem"), port=port), **kw})
        check(f"{label}: refused", await refused(bad.guests()))
        check(f"{label}: no request sent", len(stub.reqs), n)
    srv.close()
    check("nothing listening is an error", await refused(c.guests()))

    # -- cancelling: the plugin must be able to stop during a pairing
    hang = await asyncio.start_server(lambda r, w: asyncio.sleep(60), "127.0.0.1", 0, ssl=sctx)
    hc = api.Client(uid=me, password_file=P("pw"), cert_file=P("sunshine.pem"), port=hang.sockets[0].getsockname()[1])
    t = asyncio.create_task(hc.pair(PID, "1234", "x")); await asyncio.sleep(0.3); t.cancel()
    done, _ = await asyncio.wait({t}, timeout=2)
    check("a pairing in flight can be cancelled", bool(done))
    hang.close()

asyncio.run(main())

# -- systemctl
async def systemctl():
    put("systemctl", b'#!/bin/sh\necho "$@" >> %s/calls\nexit ${RC:-0}\n' % tmp.encode(), 0o700)
    unit.SYSTEMCTL = P("systemctl")
    check("start reports success", await unit.start())
    check("stop reports success", await unit.stop())
    check("it only ever starts and stops the one unit", open(P("calls")).read().split("\n")[:2], ["start novadeck-sunshine.service", "stop novadeck-sunshine.service"])
    os.environ["RC"] = "1"; check("a failed start is reported", await unit.start(), False); del os.environ["RC"]
    put("slow", b"#!/bin/sh\necho $$ > %s/pid\nexec sleep 60\n" % tmp.encode(), 0o700); unit.SYSTEMCTL = P("slow")
    gone = lambda: not os.path.exists("/proc/" + open(P("pid")).read().strip())
    unit.CHANGE_TIMEOUT, keep = 0.4, unit.CHANGE_TIMEOUT
    check("a start that hangs is reported", await unit.start(), False); check("and its child is reaped", gone())
    unit.CHANGE_TIMEOUT = keep
    t = asyncio.create_task(unit.start()); await asyncio.sleep(0.4); t.cancel(); await asyncio.wait({t}, timeout=2)
    check("a cancelled start reaps its child too", gone())
asyncio.run(systemctl())

# -- the unit and the session count
S = lambda a, r="success": unit.parse(f"ActiveState={a}\nResult={r}\nMainPID=7\n")["state"]
check("unit states", [S("active"), S("inactive"), S("activating"), S("deactivating"), S("failed", "exit-code")], ["on", "off", "starting", "stopping", "failed"])
check("unreadable output is unknown, never off", unit.parse("")["state"], "unknown")
check("the main pid is read", unit.parse("ActiveState=active\nMainPID=7\n")["pid"], 7)
for tid, comm in (("1", "sunshine"), ("2", "session::video"), ("3", "session::audio"), ("4", "session::video")):
    os.makedirs(P(f"proc/7/task/{tid}")); open(P(f"proc/7/task/{tid}/comm"), "w").write(comm + "\n")
check("one session per session::video thread", sessions.count(7, P("proc")), 2)
check("a process that is gone has none", sessions.count(8, P("proc")), 0)
check("pid 0 is no process", sessions.count(0, P("proc")), 0)
check("children never inherit PyInstaller's library path", [k for k in unit.clean_env({"LD_LIBRARY_PATH": "/x", "A": "1"}) if k == "LD_LIBRARY_PATH"], [])

# -- joining: discovery
from novadeck_streaming import join, hosts
line = lambda *e: json.dumps({"browserServiceData": [{"updateFlag": f, "family": 2, "name": n, "type": "_nvstream._tcp", "domain": "local", "ifindex": 2} for f, n in e]})
check("browsing keeps what is there at the end", join.parse_browse("\n".join([line(("added", "a"), ("added", "b")), line(("removed", "a")), "junk", "[]", ""])), ["b"])
check("a name that is not an instance is dropped", join.parse_browse(line(("added", "x" * 64), ("added", "a\nb"), ("added", ""), ("added", "--address=unixexec:path=/bin/sh"), ("added", "-h"))), [])
svc = lambda ip, port=47989: json.dumps({"type": "x", "data": [[[0, 0, port, "novadeck8.local", [[2, 2, ip]], "novadeck8.local"]], [], "n", "t", "local", 1]})
check("a resolved service gives its address", join.parse_service(svc([192, 168, 1, 217])), "192.168.1.217")
for label, text in (("loopback", svc([127, 0, 0, 1])), ("multicast", svc([224, 0, 0, 1])), ("unspecified", svc([0, 0, 0, 0])), ("link-local", svc([169, 254, 1, 1])),
                    ("a public address", svc([8, 8, 8, 8])), ("another port", svc([192, 168, 1, 2], 22)), ("a short address", svc([1, 2])), ("no JSON", "x"), ("no data", "{}")):
    check(f"a service answering with {label} is dropped: the LAN decides what it says", join.parse_service(text), None)
async def searching():
    put("tool", b"#!/bin/bash\nprintf '%s|' \"$@\" >> " + P("tcalls").encode() + b"; echo >> " + P("tcalls").encode() + b"\n" +
        b"case \"$*\" in *BrowseServices*) echo '" + line(("added", "a"), ("added", "b")).encode() + b"';; *ResolveService*' a '*) echo '" + svc([192, 168, 1, 217]).encode() + b"';; *) echo '" + svc([192, 168, 1, 66]).encode() + b"';; esac\n", 0o700)
    join.VARLINKCTL = join.BUSCTL = P("tool"); join.as_user = lambda: ["/usr/bin/env", "AS=deck"]
    async def info(address): return {"name": "FIT", "uuid": "92B19CB9-E03F-2E0B-0D97-0F1E37570B6B"}
    keep, join._serverinfo = join._serverinfo, info
    found = await join.discover()
    check("a host whose id another one copies is not replaced by it", sorted(h["address"] for h in found), ["192.168.1.217", "192.168.1.66"])
    check("this device is left out", [h["address"] for h in await join.discover("192.168.1.66")], ["192.168.1.217"])
    ran = open(P("tcalls")).read()
    check("a name from the LAN comes after the end of options", all("|--|" in l for l in ran.splitlines() if "ResolveService" in l), True)
    seen = []
    async def spy(*argv, seconds): seen.append(argv[0:2]); return ""
    real, join._output = join._output, spy; await join.discover(); await join._find("a")
    check("every discovery command runs as the user, never root", seen, [("/usr/bin/env", "AS=deck")] * 2)
    join._output, join._serverinfo = real, keep
asyncio.run(searching())
check("typed addresses are IPv4 and nothing else", [join.valid_address(a) for a in ("192.168.1.2", " 10.0.0.1 ", "127.0.0.1", "host", "1.2.3", "::1", "192.168.1.2; x", None, "-h", "8.8.8.8", "100.64.0.9")],
      ["192.168.1.2", "10.0.0.1"] + [None] * 8 + ["100.64.0.9"])
U2 = "92B19CB9-E03F-2E0B-0D97-0F1E37570B6B"
xml = lambda name, uid=U2: f'<?xml version="1.0"?><root status_code="200"><hostname>{name}</hostname><uniqueid>{uid}</uniqueid></root>'
check("a host says its name and id", join.parse_serverinfo(xml("KONKR Pocket FIT")), {"name": "KONKR Pocket FIT", "uuid": U2})
check("entities are decoded, hidden characters dropped", join.parse_serverinfo(xml("A &amp; B‮"))["name"], "A & B")
check("a bad id is no host", join.parse_serverinfo(xml("x", "../../etc")), None)
check("no XML parser runs on what the LAN sends", join.parse_serverinfo('<!DOCTYPE r [<!ENTITY a "aaaa">]>' + xml("&a;"))["name"], "&a;")

# -- joining: pairing, with a stub Moonlight
def moonlight(pair, paired_after=1):
    open(P("mcalls"), "w").close()
    put("moonlight", (f"""#!/bin/bash
echo "$QT_QPA_PLATFORM $*" >> {tmp}/mcalls
if [ "$1" = list ]; then n=$(grep -c ' list ' {tmp}/mcalls); [ "$n" -gt {paired_after} ] && exit 0; exit 255; fi
echo $$ > {tmp}/mpid
{pair}
exec sleep 60
""").encode(), 0o700)
async def pairing():
    join.MOONLIGHT = P("moonlight"); join.as_user = lambda: []; join.GRACE = 0.1
    alive = lambda: os.path.exists("/proc/" + open(P("mpid")).read().strip())
    ok_ = 'echo \'00:00:00 - Qt Info: Executing request: "https://h:47984/pair?x"\' >&2'
    moonlight(ok_); check("pairs", await join.pair("10.0.0.2", "1234"), None)
    calls = open(P("mcalls")).read().split("\n")
    check("asks first whether it is paired, then pairs, then asks again", [c.split()[1] for c in calls if c], ["list", "pair", "list"])
    check("with the PIN and the address, and never on a screen", calls[1], "offscreen pair 10.0.0.2 --pin 1234")
    check("every call is offscreen", {c.split()[0] for c in calls if c}, {"offscreen"})
    check("Moonlight, which never exits by itself, is stopped", alive(), False)
    moonlight(ok_, paired_after=0); check("a host already paired is paired", await join.pair("10.0.0.2", "1234"), None)
    check("without asking for a PIN again", " pair " in open(P("mcalls")).read(), False)
    moonlight(ok_, paired_after=9); check("believing the log is not enough", bool(await join.pair("10.0.0.2", "1234")))
    moonlight("echo '00:00:01 - Qt Critical: Incorrect PIN' >&2"); check("a wrong PIN says so", "PIN" in (await join.pair("10.0.0.2", "1234") or ""))
    check("and stops Moonlight too", alive(), False)
    async def quick(cmd):
        t = time.time(); moonlight(cmd); r = await join.pair("10.0.0.2", "1234"); return r or "", time.time() - t < 5
    req = 'echo \'00:00:00 - Qt Info: Executing request: "http://h:47989/pair?x"\' >&2; '
    r, fast = await quick(req + "echo '00:00:00 - Qt Warning: Request failed: 409 \"x\"' >&2")
    check("a host still holding the last attempt says so, at once", ("last attempt" in r, fast, alive()), (True, True, False))
    for label, cmd in (("another refused request", req + "echo '00:00:00 - Qt Warning: Request failed: 500 x' >&2"),
                       ("a failed stage", req + "echo '00:00:00 - Qt Critical: Failed pairing at stage #2' >&2"),
                       ("a host someone else is pairing", req + "echo '00:00:00 - Qt Critical: Server likely already pairing' >&2"),
                       ("an interception", req + "echo '00:00:00 - Qt Critical: MITM detected' >&2"),
                       ("a dropped connection", req + "echo '00:00:00 - Qt Warning: \"pair\" request failed with error: 1' >&2")):
        r, fast = await quick(cmd); check(f"{label} is a failure, at once, and not blamed on the PIN", (bool(r), "PIN" in r, fast), (True, False, True))
    moonlight("echo '00:00:00 - Qt Warning: Request failed: 404 x' >&2; " + ok_)
    check("a failed request before the pairing began is not the pairing's", await join.pair("10.0.0.2", "1234"), None)
    moonlight("exit 3"); check("a Moonlight that ends early is a failure", bool(await join.pair("10.0.0.2", "1234")))
    moonlight("true"); join.PAIR_LIMIT, keep = 0.6, join.PAIR_LIMIT
    check("a host that never answers times out", bool(await join.pair("10.0.0.2", "1234"))); join.PAIR_LIMIT = keep
    check("and stops Moonlight", alive(), False)
    moonlight("true"); t = asyncio.create_task(join.pair("10.0.0.2", "1234")); await asyncio.sleep(0.6); t.cancel(); await asyncio.wait({t}, timeout=5)
    check("a cancelled pairing stops Moonlight", alive(), False)
    moonlight("yes x | head -c 3000000; " + ok_); check("a lot of output does not stall it", await join.pair("10.0.0.2", "1234"), None)
asyncio.run(pairing())
check("PINs are four digits", all(len(p) == 4 and p.isdigit() for p in (join.new_pin() for _ in range(300))))

# -- joining: the hosts we made tiles for
H = P("cfg/hosts.json"); hosts.as_user = lambda: []
async def registry():
    check("no file is no hosts", hosts.load(H, me), {})
    check("a host is remembered", await hosts.remember(H, me, U2, "FIT", 2930912870), True)
    check("with its tile", hosts.load(H, me), {U2: {"name": "FIT", "appid": 2930912870}})
    check("a signed appid is stored as Steam's file has it", (await hosts.remember(H, me, U2, "FIT", -1364054426), hosts.load(H, me)[U2]["appid"])[1], 2930912870)
    check("a bad id is refused", await hosts.remember(H, me, "../x", "n", 1), False)
    check("a bad appid is refused", await hosts.remember(H, me, U2, "n", "1"), False)
    full = {f"92B19CB9-E03F-2E0B-0D97-{i:012X}": {"name": "n", "appid": i + 1} for i in range(hosts.MAX_HOSTS)}
    open(H, "w").write(json.dumps(full)); check("a full registry takes no more", await hosts.remember(H, me, "92B19CB9-E03F-2E0B-0D97-FFFFFFFFFFFF", "n", 1), False)
    check("but still changes one it has", await hosts.remember(H, me, list(full)[0], "new", 9)); os.unlink(H); await hosts.remember(H, me, U2, "FIT", 1)
    check("forgets", (await hosts.forget(H, me, U2), hosts.load(H, me))[1], {})
    check("the file is private", oct(os.stat(H).st_mode & 0o777), "0o600")
    os.symlink(H, P("cfg/link.json")); check("a registry that is a link is an error, never an empty list", hosts.load(P("cfg/link.json"), me), None)
    open(H, "w").write("{broken"); check("a broken file is an error, never an empty list to overwrite", hosts.load(H, me), None)
    check("and is not overwritten", (await hosts.remember(H, me, U2, "n", 1), open(H).read()), (False, "{broken"))
    open(H, "w").write(json.dumps({U2: {"name": "x", "appid": 5}, "bad": {"appid": 1}, "y": 3})); check("rows that are not hosts are ignored", list(hosts.load(H, me)), [U2])
asyncio.run(registry())

# -- main.py: what the panel is told
import types, logging
sys.modules["decky"] = types.SimpleNamespace(logger=logging.getLogger("x")); logging.disable(logging.CRITICAL)
sys.path.insert(0, plugin); import main as M
class Fake:
    fail = False; result = True
    async def guests(self):
        if self.fail: raise api.ApiError("down")
        return []
    async def pending(self): return []
    async def disconnect(self, uuid): return self.result
async def panel():
    fake = Fake(); M._client = lambda: fake; host = {"state": "off", "pid": 0}
    async def status(): return host
    M.unit.status = status; M.sessions.count = lambda pid: 3; pl = M.Plugin()
    st = await pl.get_state()
    check("off: the lists are unknown and nobody streams", (st["hosting"], st["ready"], st["guests"], st["streaming"]), ("off", False, None, 0))
    host = {"state": "on", "pid": 7}; st = await pl.get_state()
    check("on: empty lists are known to be empty", (st["ready"], st["guests"], st["pending"], st["streaming"]), (True, [], [], 3))
    fake.fail = True; st = await pl.get_state()
    check("on but silent: unknown lists, and still the count", (st["ready"], st["guests"], st["streaming"]), (False, None, 3))
    fake.fail = False
    check("a change that worked has no problem", (await pl.disconnect("u"))["problem"], None)
    fake.result = False; check("a refused change says so", bool((await pl.disconnect("u"))["problem"]))
    async def nostart(): return False
    M.unit.start = nostart; check("a start that failed says so", (await pl.set_hosting(True))["problem"], "Hosting did not start")
asyncio.run(panel())

class FakeUser: pw_uid = me; pw_dir = tmp
async def joining():
    M._account = lambda: FakeUser; M._address = lambda: "192.168.1.9"; M._hosts_file = lambda: P("cfg/main.json"); pl = M.Plugin()
    async def found(own): return [{"name": "FIT", "uuid": U2, "address": "192.168.1.217"}, {"name": "Max", "uuid": UUID, "address": "192.168.1.214"}] if own == "192.168.1.9" else []
    M.join.discover = found
    st = await pl.find_hosts()
    check("finds hosts, without this device", [h["name"] for h in st["found"]], ["FIT", "Max"])
    gate = asyncio.Event(); seen = []
    async def pairs(address, pin): seen.append((address, pin)); await gate.wait(); return None
    M.join.pair = pairs
    async def info(address): return {"name": "FIT", "uuid": U2, "address": address}
    M.join.describe = info
    check("a bad address is refused before anything runs", bool((await pl.start_join("127.0.0.1"))["problem"]))
    r = await pl.start_join("192.168.1.217"); await asyncio.sleep(0.05)
    check("a join shows the PIN it uses", (r["problem"], seen), (None, [("192.168.1.217", r["pin"])]))
    check("and is waiting", (await pl.join_status())["state"], "waiting")
    check("a second join at once is refused", bool((await pl.start_join("192.168.1.214"))["problem"]))
    gate.set(); await asyncio.sleep(0.05); st = await pl.join_status()
    check("then paired, with what the tile needs", (st["state"], st["host"]), ("paired", {"name": "FIT", "uuid": U2, "address": "192.168.1.217"}))
    check("the tile is remembered", (await pl.remember_tile(U2, "FIT", 77))["hosts"], [{"uuid": U2, "name": "FIT", "appid": 77}])
    check("the tab lists its appids", await pl.tab_members(), {"appids": [77]})
    check("a found host we have is marked", [(h["name"], h["joined"]) for h in (await pl.find_hosts())["found"]], [("FIT", True), ("Max", False)])
    check("forgotten", (await pl.forget_host(U2))["hosts"], [])
    open(P("cfg/main.json"), "w").write("{"); check("an unreadable registry is said, not shown as none", (bool((await pl.get_hosts())["problem"]), "error" in await pl.tab_members()), (True, True)); os.unlink(P("cfg/main.json"))
    async def wrong(address, pin): return "The PIN typed on the host was not this one"
    M.join.pair = wrong; await pl.start_join("192.168.1.217"); await asyncio.sleep(0.05)
    check("a failed join says why", (await pl.join_status())["problem"], "The PIN typed on the host was not this one")
    async def boom(address, pin): raise KeyError("x")
    M.join.pair = boom; await pl.start_join("192.168.1.217"); await asyncio.sleep(0.05)
    check("an error nobody expected is a failure, not a stopped pairing", (await pl.join_status())["state"], "failed")
    runs = []
    async def slow(own): runs.append(1); await asyncio.sleep(0.2); return []
    M.join.discover = slow; await asyncio.gather(*(pl.find_hosts() for _ in range(5)))
    check("searches do not run side by side", len(runs), 1)
    stopped = []
    async def forever(address, pin):
        try: await asyncio.sleep(60)
        finally: stopped.append(1)
    M.join.pair = forever; await pl.start_join("192.168.1.217"); await asyncio.sleep(0.05); await pl.cancel_join()
    check("cancelling a join stops Moonlight", (stopped, (await pl.join_status())["state"]), ([1], "idle"))
    await pl.start_join("192.168.1.217"); await asyncio.sleep(0.05); await pl._unload()
    check("so does unloading the plugin", len(stopped), 2)
asyncio.run(joining())
PY
) || bad "the backend checks crashed"
while IFS= read -r line; do
    case $line in "ok   "*) ok "${line#ok   }" ;; "FAIL "*) bad "${line#FAIL }" ;; ?*) echo "$line" ;; esac
done <<<"$out"
[[ $(grep -c '^ok ' <<<"$out") -ge 155 ]] || bad "fewer backend checks ran than expected"

echo "the panel"
SRC="$PLUGIN/src"
# Source checks only: Steam's UI is not here to run it.
grep -qE '\bremove\b' "$SRC/Content.tsx" \
    && bad "Content.tsx removes a guest: the QAM opens over a running game, so that sits behind a dialog" \
    || ok "nothing destructive is a row in the QAM"
grep -A12 'const confirmRemove' "$SRC/GuestDialog.tsx" | grep -q 'ConfirmModal' \
    && ok "removing a guest asks first" || bad "removing a guest does not ask first"
grep -A8 'const onToggle' "$SRC/Content.tsx" | grep -q 'streaming === 0' && grep -q 'Stop hosting?' "$SRC/Content.tsx" \
    && ok "turning hosting off while someone streams asks first" || bad "hosting can be turned off under a guest without a question"
# Steam parses only these; @decky/ui types it as any string, so tsc cannot catch "horizontal".
check_flow=$(grep -ohE 'flow-children="[^"]*"' "$SRC"/*.tsx | sort -u | grep -vE '"(row|column)"')
[[ -z $check_flow ]] && ok "every flow-children is one Steam parses" || bad "Steam ignores $check_flow"
grep -q 'pending\.address' "$SRC/PinDialog.tsx" && ! grep -qE '\b(pending|p)\.name' "$SRC/PinDialog.tsx" "$SRC/Content.tsx" \
    && ok "a guest who asks is identified by address, never by a name they send" || bad "a screen shows the name a guest sent"
grep -q 'setInterval' "$SRC"/*.tsx && bad "polls can overlap (setInterval)" || ok "the next poll waits for the last one"
grep -q 'menus included' "$SRC/Content.tsx" && grep -q 'menus included' "$SRC/PinDialog.tsx" \
    && ok "both screens say guests reach the menus" || bad "a screen no longer says guests reach the menus"
TAB="$SRC/SunshineTab.tsx"
grep -q 'tabs.some((t) => t.id === TAB_ID)' "$TAB" && grep -q 'if (apps.length === 0) return result' "$TAB" \
    && ok "the Sunshine tab skips only itself, and is not there without a host" || bad "the Sunshine tab can hide other tabs, or show up empty"
grep -q 'isTabMasterInstalled()' "$TAB" && ok "with TabMaster installed the tab list is left to it" || bad "the tab list is patched even when TabMaster owns it"
# As in test-store-library.sh: a hook in the route patch is one of Decky's router's (React error 310).
route_patch=$(sed -n '/addPatch("\/library"/,/afterPatch(props\.children, "type"/p' "$TAB")
page=$(sed -n '/afterPatch(props\.children, "type"/,/ret1?\.type/p' "$TAB")
all_hooks=$(sed -n '/addPatch("\/library"/,$p' "$TAB" | grep -cE '\buse(State|Effect|Memo|Ref|Callback)\(')
[[ -n $route_patch ]] && ! grep -qE '\buse[A-Z][A-Za-z]*\(' <<<"$route_patch" \
    && ok "the route patch calls no hook of its own" || bad "the Sunshine tab calls a hook inside Decky's router (React error 310 beside Epic and GOG)"
[[ $(grep -cE '\buse(State|Effect)\(' <<<"$page") -eq 3 && $all_hooks -eq 3 ]] \
    && ok "the library page's hooks all come before its first return" || bad "the Sunshine tab calls a hook after a return, so their number can change"
grep -q 'const removeSunshineTab = applySunshineTab()' "$SRC/index.tsx" && grep -A3 'onDismount' "$SRC/index.tsx" | grep -q 'removeSunshineTab()' \
    && ok "the tab patch is applied at load and removed at dismount" || bad "the tab patch is not removed at dismount"
grep -q 'AddShortcut' "$SRC/tiles.ts" && ! grep -rq 'shortcuts\.vdf' "$PLUGIN/py_modules" "$PLUGIN/main.py" \
    && ok "tiles go through Steam, never its file" || bad "something other than Steam's API makes tiles"
grep -A14 'await rememberTile' "$SRC/tiles.ts" | grep -c 'RemoveShortcut' | grep -qx 2 && ok "a tile that could not be recorded is taken away again" || bad "an unrecorded tile would stay for good"
grep -A3 'if (!live) {' "$SRC/JoinDialog.tsx" | grep -q 'cancelJoin()' && ok "a dialog closed while the host is asked leaves no pairing behind" || bad "a dialog closed early leaves a pairing running unseen"
grep -A14 'return () => {' "$SRC/JoinDialog.tsx" | grep -q 'cancelJoin()' && ok "closing the dialog stops the pairing" || bad "a closed dialog leaves Moonlight waiting"
grep -B3 -A9 'const forget = ' "$SRC/JoinSection.tsx" | grep -q 'ConfirmModal' && ok "forgetting a host asks first" || bad "forgetting a host does not ask first"
for call in $(grep -ohE 'call<[^>]*>+\("[a-z_]+"' "$SRC/backend.ts" | sed -E 's/.*"([a-z_]+)"/\1/'); do
    grep -q "async def $call(" "$PLUGIN/main.py" && ok "the backend has $call" || bad "backend.ts calls $call, which main.py lacks"
done

echo "the tile's launcher"
LAUNCH="$ROOT/rootfs/overlay/usr/lib/novadeck/stream-host"
[[ -x $LAUNCH ]] && ok "it is executable" || bad "stream-host is missing or not executable"
printf '#!/usr/bin/env bash\necho "$LIBVA_DRIVER_NAME $HAS_DESKTOP_ENVIRONMENT $*"\n' >"$TMP/mlaunch"; chmod +x "$TMP/mlaunch"
U=92B19CB9-E03F-2E0B-0D97-0F1E37570B6B
[[ $(env MOONLIGHT="$TMP/mlaunch" bash "$LAUNCH" "$U" 2>&1) == "qcom 0 stream $U Desktop" ]] \
    && ok "streams the host by id, decoding on qcom, fullscreen" || bad "stream-host does not start the stream as expected"
for arg in "" "--help" "x y" "$U extra" "../$U"; do
    # shellcheck disable=SC2086  # "$U extra" is meant to be two arguments
    env MOONLIGHT="$TMP/mlaunch" bash "$LAUNCH" $arg >/dev/null 2>&1 && bad "stream-host accepts '$arg'" || ok "refuses '$arg'"
done

echo "the image ships it"
for f in Makefile rootfs/lib-assemble-decky-splash.sh rootfs/guard-rootfs.sh; do
    grep -qE '^(DECKY_PLUGINS|for (plugin_name|decky_plugin) ).*novadeck-streaming' "$ROOT/$f" \
        && ok "$f lists the plugin" || bad "$f does not list the plugin"
done
[[ $(python3 -c 'import json,sys; print("root" in json.load(open(sys.argv[1]))["flags"])' "$PLUGIN/plugin.json") == True ]] \
    && ok "it runs as root, which starting the unit needs" || bad "plugin.json lacks the root flag"
grep -rqE 'systemctl.{0,40}(enable|--now)|"enable"' "$PLUGIN/main.py" "$PLUGIN/py_modules" \
    && bad "something enables the unit: hosting must never start at boot" || ok "nothing enables the unit"
grep -rqE '/home/deck|\b1000\b' "$PLUGIN/py_modules" --include=*.py \
    && bad "a literal home or uid: take them from passwd" || ok "home and uid come from passwd"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
