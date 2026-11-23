"""novadeck-streaming: host this device's games for friends who join with Moonlight.

It starts and stops novadeck-sunshine.service and is the whole of Sunshine's UI on the device: the
web page is never shown. It is its own plugin because it holds the service's password and accepts
guests, who then control the device like a second controller, Steam's menus included.

Every mutating call returns the whole new state with what happened, never an acknowledgement:
Sunshine is the record of who is paired, and the panel shows what it says now.
"""
import asyncio
import os
import pwd
import socket

import decky

from novadeck_streaming import api, sessions, unit

USER = "deck"
PASSWORD_FILE = "/run/novadeck-sunshine/webui-password"


def _client():
    user = pwd.getpwnam(USER)
    return api.Client(user.pw_uid, PASSWORD_FILE,
                      os.path.join(user.pw_dir, ".config", "sunshine", "credentials", "cacert.pem"))


def _address():
    """The address to type into Moonlight, or None. Connecting a UDP socket sends nothing."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))
            return s.getsockname()[0]
        except OSError:
            return None


# One change at a time: two presses must not interleave a block with an unpair.
_LOCK = asyncio.Lock()


class Plugin:
    async def get_state(self):
        return await self._state()

    async def set_hosting(self, on):
        async with _LOCK:
            done = await (unit.start() if on else unit.stop())
            if done:
                return await self._state()
            return await self._state("Hosting did not start" if on else "Hosting did not stop")

    async def pair(self, pairing_id, pin):
        return await self._change(lambda c: c.pair(pairing_id, pin),
                                  "Not paired: the PIN was wrong, or the guest gave up")

    async def disconnect(self, uuid):
        return await self._change(lambda c: c.disconnect(uuid), "Sunshine did not disconnect this guest")

    async def allow(self, uuid):
        return await self._change(lambda c: c.allow(uuid), "Sunshine did not allow this guest")

    async def remove(self, uuid):
        return await self._change(lambda c: c.remove(uuid), "Sunshine did not remove this guest")

    async def _change(self, action, refusal):
        async with _LOCK:
            try:
                problem = None if await action(_client()) else refusal
            except api.ApiError as exc:
                decky.logger.warning("sunshine call failed: %s", exc)
                problem = str(exc)
            return await self._state(problem)

    async def _state(self, problem=None):
        """`ready` is false while Sunshine is up but not answering yet, and the lists are then None:
        unknown, not empty."""
        host = await unit.status()
        state = {"hosting": host["state"], "ready": False, "streaming": 0, "address": _address(),
                 "guests": None, "pending": None, "problem": problem}
        if host["state"] != "on":
            return state
        streaming = sessions.count(host["pid"])
        try:
            client = _client()
            guests, pending = await client.guests(), await client.pending()
        except (api.ApiError, KeyError) as exc:
            decky.logger.info("sunshine not ready: %s", exc)
            return {**state, "streaming": streaming}
        return {**state, "ready": True, "streaming": streaming, "guests": guests, "pending": pending}
