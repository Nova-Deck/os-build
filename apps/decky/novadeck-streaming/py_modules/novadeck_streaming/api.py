"""Sunshine's local API: pairing, and who is paired.

The credentials are made at every start of novadeck-sunshine.service and read per request. The
server is Sunshine only if it presents Sunshine's own certificate: that file is the one trust anchor,
so nothing else that binds the port is sent the password. The name is not checked, because the
certificate carries no address (CN=Sunshine Gamestream Host).

asyncio streams, not http.client on a worker thread: POST /api/pin answers only when the pairing has
finished, up to 10 s, and a thread parked that long outlives Decky's 5 s to stop a plugin.

No Origin or Referer is sent: with either, Sunshine's CSRF check would want a token.

Sunshine has no call that lists sessions, so which guest is streaming cannot be asked (sessions.py
counts them).
"""
import asyncio
import base64
import json
import re
import ssl
import unicodedata

from novadeck_streaming import userfile

PORT = 47990
USER = "novadeck"
TIMEOUT = 4
# Ending a session happens inside the request, and Sunshine allows itself 10 s for it.
CHANGE_TIMEOUT = 20
# Sunshine holds POST /api/pin for at most its ping_timeout (10 s).
PAIR_TIMEOUT = 15
MAX_BODY = 256 * 1024
MAX_HEAD = 16 * 1024
MAX_NAME = 128
UUID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
PAIRING_ID = re.compile(r"[0-9A-Fa-f]{32}")
PIN = re.compile(r"[0-9]{4}")


class ApiError(Exception):
    """The call did not happen or its answer cannot be used. Never stands for an empty answer."""


def _text(value):
    """A name as it is shown and stored. Control and format characters
    (a right-to-left override, a zero-width space) go, and the length is Sunshine's limit in BYTES."""
    if not isinstance(value, str):
        return ""
    # Whitespace first: a line break is a control character too, and must leave a space behind.
    plain = "".join(c for c in " ".join(value.split()) if not unicodedata.category(c).startswith("C"))
    return " ".join(plain.split()).encode()[:MAX_NAME].decode("utf-8", "ignore")


def _need_uuid(uuid):
    if not isinstance(uuid, str) or not UUID.fullmatch(uuid):
        raise ApiError("not a guest id")


class Client:
    def __init__(self, uid, password_file, cert_file, port=PORT):
        self._uid = uid
        self._password_file = password_file
        self._cert_file = cert_file
        self._port = port

    def _context(self):
        pem = userfile.read(self._cert_file, self._uid, MAX_HEAD)
        if pem is None:
            raise ApiError("no usable Sunshine certificate")
        # Not create_default_context: that one adds the system's trust store.
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        try:
            ctx.load_verify_locations(cadata=pem.decode("ascii"))
        except (ssl.SSLError, UnicodeDecodeError, ValueError) as exc:
            raise ApiError("unreadable Sunshine certificate") from exc
        return ctx

    def _authorization(self):
        password = userfile.read(self._password_file, self._uid, 256)
        if not password or not password.strip():
            raise ApiError("no usable Sunshine password")
        return "Basic " + base64.b64encode(USER.encode() + b":" + password.strip()).decode("ascii")

    async def _exchange(self, request, ctx):
        reader, writer = await asyncio.open_connection("127.0.0.1", self._port, ssl=ctx, limit=MAX_HEAD)
        try:
            writer.write(request)
            await writer.drain()
            head = (await reader.readuntil(b"\r\n\r\n")).decode("latin-1").split("\r\n")
            status = int(head[0].split(" ", 2)[1])
            length = None
            for line in head[1:]:
                name, _, value = line.partition(":")
                if name.strip().lower() == "content-length":
                    length = int(value)
            if status != 200:
                raise ApiError(f"Sunshine answered {status}")
            if length is None or not 0 <= length <= MAX_BODY:
                raise ApiError("Sunshine's answer has no usable length")
            return await reader.readexactly(length)
        finally:
            writer.close()

    async def _call(self, method, path, body=None, timeout=TIMEOUT):
        payload = b"" if body is None else json.dumps(body).encode()
        lines = [f"{method} {path} HTTP/1.1", "Host: 127.0.0.1", "Connection: close",
                 f"Authorization: {self._authorization()}", f"Content-Length: {len(payload)}"]
        if body is not None:
            lines.append("Content-Type: application/json")
        request = "\r\n".join(lines).encode("ascii") + b"\r\n\r\n" + payload
        try:
            raw = await asyncio.wait_for(self._exchange(request, self._context()), timeout)
            answer = json.loads(raw)
        except ApiError:
            raise
        except (OSError, EOFError, ValueError, IndexError, asyncio.TimeoutError,
                asyncio.LimitOverrunError, RecursionError) as exc:
            # The type only: the message of a JSON or header error can quote what was received.
            raise ApiError(f"Sunshine did not answer ({type(exc).__name__})") from exc
        if not isinstance(answer, dict):
            raise ApiError("Sunshine's answer is not an object")
        return answer

    async def _list(self, path, key):
        rows = (await self._call("GET", path)).get(key)
        if not isinstance(rows, list):
            raise ApiError(f"Sunshine's answer has no {key}")
        return [row for row in rows if isinstance(row, dict)]

    async def guests(self):
        return [{"uuid": row["uuid"], "name": _text(row.get("name")), "enabled": row.get("enabled") is not False}
                for row in await self._list("/api/clients/list", "named_certs")
                if isinstance(row.get("uuid"), str) and UUID.fullmatch(row["uuid"])]

    async def pending(self):
        """Who is asking to join, by address. Not by name: Moonlight sends the same one ("roth") from
        every device, and it is the guest's to choose before anyone has accepted them."""
        return [{"id": row["id"], "address": _text(row.get("address"))}
                for row in await self._list("/api/pin", "pairings")
                if isinstance(row.get("id"), str) and PAIRING_ID.fullmatch(row["id"])]

    async def pair(self, pairing_id, pin, name):
        """True once the guest is paired; False when Sunshine says it did not happen (a wrong PIN,
        or a guest that gave up). Either way this pairing id is spent: a guest who tries again gets
        a new one. The host names the guest; without a name they are known by address."""
        if not isinstance(pairing_id, str) or not PAIRING_ID.fullmatch(pairing_id):
            raise ApiError("not a pairing id")
        if not isinstance(pin, str) or not PIN.fullmatch(pin):
            raise ApiError("the PIN is four digits")
        asking = [row for row in await self.pending() if row["id"] == pairing_id]
        if not asking:
            raise ApiError("this guest is no longer asking to join")
        answer = await self._call(
            "POST", "/api/pin", {"pairing_id": pairing_id, "pin": pin, 
             "name": _text(name) or f"Guest at {asking[0]['address']}"},
            PAIR_TIMEOUT)
        return answer.get("status") is True

    async def dismiss(self, pairing_id):
        """Turn away someone who asks. Sunshine otherwise holds the request for minutes, and refuses
        the same device until then."""
        if not isinstance(pairing_id, str) or not PAIRING_ID.fullmatch(pairing_id):
            raise ApiError("not a pairing id")
        return (await self._call("DELETE", "/api/pin", {"pairing_id": pairing_id})).get("status") is True

    async def _set_enabled(self, uuid, enabled):
        _need_uuid(uuid)
        answer = await self._call("POST", "/api/clients/update", {"uuid": uuid, "enabled": enabled},
                                  CHANGE_TIMEOUT)
        return answer.get("status") is True

    async def disconnect(self, uuid):
        """End this guest's session and unplug their controller; they stay paired and may come back.

        Sunshine keeps the pad of a guest who merely closed Moonlight, so there is no softer way to
        unplug it. Sunshine blocks the guest first and then ends the session, so a block that was not
        answered has happened: allow them again before reporting it.
        """
        try:
            blocked = await self._set_enabled(uuid, False)
        except ApiError:
            await self._set_enabled(uuid, True)
            raise
        return blocked and await self._set_enabled(uuid, True)

    async def allow(self, uuid):
        return await self._set_enabled(uuid, True)

    async def remove(self, uuid):
        """Unpair. The session is ended first: unpairing alone does not end it."""
        if not await self._set_enabled(uuid, False):
            return False
        return (await self._call("POST", "/api/clients/unpair", {"uuid": uuid},
                                 CHANGE_TIMEOUT)).get("status") is True
