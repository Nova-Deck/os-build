"""Find hosts on the network, and pair with one.

Everything read here comes from the LAN and is believed about nothing: addresses are checked before
they are contacted, names are cleaned before they are shown, and no XML parser runs on an answer.

Nothing here runs as root: every command runs as the session user, a name from the LAN among their
arguments. Discovery is systemd-resolved's: Moonlight only browses with its window open. Pairing is Moonlight's own, offscreen. It never exits after pairing (both outcomes end
in a dialog), and without `offscreen` it drives the screen directly, so it is watched, stopped, and
never run any other way. `moonlight list` is what says whether a host is paired: it exits 0 only then.
"""
import asyncio
import html
import ipaddress
import json
import re
import secrets
import socket

from novadeck_streaming import api, unit, user

SERVICE = "_nvstream._tcp"
PORT = 47989
RESOLVE = "/run/systemd/resolve/io.systemd.Resolve"
VARLINKCTL = "/usr/bin/varlinkctl"
BUSCTL = "/usr/bin/busctl"
MOONLIGHT = "/usr/bin/moonlight"
BROWSE_SECONDS = 4
QUERY_TIMEOUT = 6
# The other person has to find the panel and type four digits.
PAIR_LIMIT = 180
# Moonlight gives up on a host, and on its app list, after 30 s in all.
LIST_LIMIT = 35
# Moonlight saves what it paired from its own thread.
GRACE = 3
MAX_HOSTS = 16
MAX_INFO = 64 * 1024
# Never an option: no leading dash.
INSTANCE = re.compile(r"(?!-)[^\x00-\x1f\x7f]{1,63}")

as_user = user.prefix


def new_pin():
    return f"{secrets.randbelow(10000):04d}"


def valid_address(text):
    """The IPv4 address as Moonlight takes it, or None."""
    if not isinstance(text, str):
        return None
    try:
        ip = ipaddress.IPv4Address(text.strip())
    except ValueError:
        return None
    # A private network, a VPN's 100.64/10 included, and not the internet.
    unusable = (ip.is_global or ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_link_local
                or ip.is_reserved)
    return None if unusable else str(ip)


def parse_browse(text):
    """The instance names present at the end of a browse."""
    found = {}
    for line in text.splitlines():
        try:
            rows = json.loads(line)["browserServiceData"]
            for row in rows:
                name = row["name"]
                if not isinstance(name, str) or not INSTANCE.fullmatch(name):
                    continue
                if row["updateFlag"] == "added":
                    found[name] = True
                else:
                    found.pop(name, None)
        except (ValueError, KeyError, TypeError, RecursionError):
            continue
    return list(found)[:MAX_HOSTS]


def parse_service(text):
    """The address of a resolved instance, or None."""
    try:
        for _prio, _weight, port, _host, addresses, _canonical in json.loads(text)["data"][0]:
            for _ifindex, family, raw in addresses:
                if port == PORT and family == socket.AF_INET and len(raw) == 4:
                    return valid_address(str(ipaddress.IPv4Address(bytes(raw))))
    except (ValueError, KeyError, TypeError, IndexError, RecursionError):
        pass
    return None


def parse_serverinfo(text):
    name = re.search(r"<hostname>([^<]{1,512})</hostname>", text)
    uid = re.search(r"<uniqueid>([^<]{1,64})</uniqueid>", text)
    if not uid or not api.UUID.fullmatch(uid[1]):
        return None
    return {"name": api._text(html.unescape(name[1])) if name else "", "uuid": uid[1]}


async def _output(*argv, seconds):
    """What a command printed within `seconds`; it is ended then, which is how a browse ends."""
    proc = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, env=unit.clean_env())
    chunks = []

    async def drain():
        size = 0
        while chunk := await proc.stdout.read(4096):
            size += len(chunk)
            if size > MAX_INFO:
                return
            chunks.append(chunk)

    try:
        await asyncio.wait_for(drain(), seconds)
    except asyncio.TimeoutError:
        pass
    finally:
        await _stop(proc)
    return b"".join(chunks).decode("utf-8", "replace")


async def _stop(proc):
    if proc.returncode is not None:
        return
    try:
        proc.terminate()
        await asyncio.wait_for(proc.wait(), 3)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
    except ProcessLookupError:
        pass
    except asyncio.CancelledError:
        proc.kill()
        await proc.wait()
        raise


async def _serverinfo(address):
    """What the host at an address calls itself, or None."""
    async def ask():
        reader, writer = await asyncio.open_connection(address, PORT)
        try:
            writer.write(f"GET /serverinfo HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n".encode())
            await writer.drain()
            data = b""
            while len(data) < MAX_INFO and (chunk := await reader.read(4096)):
                data += chunk
            return data.decode("utf-8", "replace")
        finally:
            writer.close()
    try:
        return parse_serverinfo(await asyncio.wait_for(ask(), QUERY_TIMEOUT))
    except (OSError, asyncio.TimeoutError):
        return None


async def _find(name):
    address = parse_service(await _output(
        *as_user(), BUSCTL, "--json=short", "call", "--", "org.freedesktop.resolve1", "/org/freedesktop/resolve1",
        "org.freedesktop.resolve1.Manager", "ResolveService", "isssit", "0", name, SERVICE, "local",
        str(int(socket.AF_INET)), "0", seconds=QUERY_TIMEOUT))
    info = await _serverinfo(address) if address else None
    return {**info, "address": address} if info else None


async def discover(own=None):
    """Hosts that answer, but not this device."""
    query = json.dumps({"domain": "local", "type": SERVICE, "ifindex": 0, "flags": 0})
    names = parse_browse(await _output(
        *as_user(), VARLINKCTL, "--json=short", "--more", "call", RESOLVE, "io.systemd.Resolve.BrowseServices", query,
        seconds=BROWSE_SECONDS))
    found = [h for h in await asyncio.gather(*(_find(n) for n in names)) if h and h["address"] != own]
    # By id AND address: a host's id is not proven, and one that copies another's must not replace it.
    return list({(h["uuid"], h["address"]): h for h in found}.values())


async def describe(address):
    """The host at a typed address, or None."""
    info = await _serverinfo(address)
    return {**info, "address": address} if info else None


def _moonlight(*args):
    # env, so the one variable that keeps it off the screen cannot be lost.
    return [*as_user(), "/usr/bin/env", "QT_QPA_PLATFORM=offscreen", MOONLIGHT, *args]


async def _paired(address):
    proc = await asyncio.create_subprocess_exec(
        *_moonlight("list", address), stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL, env=unit.clean_env())
    try:
        return await asyncio.wait_for(proc.wait(), LIST_LIMIT) == 0
    except asyncio.TimeoutError:
        return False
    finally:
        await _stop(proc)


async def _answer(stream):
    """None once Moonlight has sent the last step of a pairing, or why there is none. Every other
    failure ends in a dialog nobody sees, so all it logs is all there is to go by."""
    buffer = b""
    asked = False
    while chunk := await stream.read(4096):
        buffer += chunk
        *lines, buffer = buffer.split(b"\n")
        buffer = buffer[-4096:]
        for line in lines:
            if b"Incorrect PIN" in line:
                return "The PIN typed on the host was not this one"
            if b"/pair?" in line:
                if b"https://" in line:
                    return None
                asked = True
            if asked and b"Request failed: 409" in line:
                return ("The host still has the last attempt open. Dismiss it there, or try again in five minutes")
            if b"Qt Critical" in line or (asked and (b"Request failed" in line or b"request failed" in line)):
                return "The host did not go through with the pairing"
    return "Moonlight stopped before it was paired"


async def pair(address, pin):
    """None once paired, or a sentence saying why not. Takes as long as the person at the host does."""
    if await _paired(address):
        return None
    proc = await asyncio.create_subprocess_exec(
        *_moonlight("pair", address, "--pin", pin), stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, env=unit.clean_env())
    try:
        problem = await asyncio.wait_for(_answer(proc.stdout), PAIR_LIMIT)
        if problem is None:
            await asyncio.sleep(GRACE)
    except asyncio.TimeoutError:
        problem = "Nobody typed the PIN on the host"
    finally:
        await _stop(proc)
    if problem:
        return problem
    return None if await _paired(address) else "The host did not accept the pairing"
