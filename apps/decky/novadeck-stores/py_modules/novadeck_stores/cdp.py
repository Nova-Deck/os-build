"""Steam's CEF remote-debugging port — the only view we have of the login page.

The port exists because novadeck-steam writes .cef-enable-remote-debugging, and Decky's own
frontend is injected over it, so depending on it adds nothing: if it is gone, this plugin is not
running either.

Two calls, and the split between them is deliberate:

  list_targets  the stateless HTTP /json list. Polled once a second for the whole login, so it
                must hold nothing open.
  read_body     ONE short-lived websocket to the login page's OWN target, one Runtime.evaluate,
                closed. Only Epic needs it, and only once its redirect page has appeared.

What is NOT done is the thing tests/test-decky.sh warns about: holding a websocket to SteamUI's
SharedJSContext, the tab Decky itself is injected into. A connection that drops when that tab goes
stale mid-connect is how Decky loses its injection for good; the login page is a different target,
and the socket to it lives for one request.

Every failure is raised as OSError, which is the one exception connect.capture() treats as "try
again on the next poll".
"""
import asyncio
import json
import urllib.parse
import urllib.request

CDP_HOST = "127.0.0.1"
CDP_PORT = 8080
CDP_LIST = f"http://{CDP_HOST}:{CDP_PORT}/json"
TIMEOUT = 5


def _list_targets_sync():
    with urllib.request.urlopen(CDP_LIST, timeout=TIMEOUT) as resp:
        data = json.load(resp)
    return data if isinstance(data, list) else []


async def list_targets():
    try:
        return await asyncio.to_thread(_list_targets_sync)
    except ValueError as exc:   # a non-JSON answer from the port
        raise OSError(f"CEF target list unreadable: {type(exc).__name__}") from exc


def is_local_debugger(ws_url):
    """True only for a websocket on the same loopback port as the target list."""
    try:
        parsed = urllib.parse.urlparse(ws_url)
        port = parsed.port
    except ValueError:
        return False
    return parsed.scheme == "ws" and parsed.hostname == CDP_HOST and port == CDP_PORT


async def _reply(ws, request_id):
    """The response to request_id, skipping any event the target pushes first."""
    while True:
        msg = json.loads(await ws.receive_str())
        if msg.get("id") == request_id:
            return msg


async def read_body(target):
    """document.body.innerText of one target, or None if the page has no body yet."""
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        # CEF omits it while another client holds the target. Treat it as "not yet".
        return None
    if not is_local_debugger(ws_url):
        # Whatever answers on :8080 is trusted to LIST targets, not to aim this root process at an
        # arbitrary host. If Steam is not the one listening, something else squatted the port.
        return None
    # aiohttp ships inside Decky's PluginLoader, which is where this runs. Imported here and not
    # at module scope so the offline suite, which has no aiohttp, can import everything else.
    import aiohttp

    request = {
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": "document.body ? document.body.innerText : ''", "returnByValue": True},
    }
    try:
        # The timeout goes on the SESSION: ws_connect's own timeout= only bounds the close
        # handshake, and the upgrade request would otherwise inherit aiohttp's 300 s default —
        # half the login window gone on one stalled poll.
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT)) as session:
            async with session.ws_connect(ws_url) as ws:
                await ws.send_str(json.dumps(request))
                msg = await asyncio.wait_for(_reply(ws, 1), TIMEOUT)
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError, TypeError) as exc:
        raise OSError(f"CEF evaluate failed: {type(exc).__name__}") from exc
    value = msg.get("result", {}).get("result", {}).get("value")
    return value if isinstance(value, str) else None
