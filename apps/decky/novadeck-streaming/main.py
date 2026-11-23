"""novadeck-streaming: host this device's games for friends who join with Moonlight, and join theirs.

It starts and stops novadeck-sunshine.service and is the whole of Sunshine's UI on the device: the
web page is never shown. It is its own plugin because it holds the service's password and accepts
guests, who then control the device like a second controller, Steam's menus included.

Every mutating call returns the whole new state with what happened, never an acknowledgement:
Sunshine is the record of who is paired, and the panel shows what it says now.

Joining runs Moonlight as the session user (user.py). A paired host becomes a Steam tile, made by the
frontend, which is the only side that can ask Steam; this side keeps which tiles are ours (hosts.py).
"""
import asyncio
import os
import socket

import decky

from novadeck_streaming import api, hosts, join, sessions, unit, user

PASSWORD_FILE = "/run/novadeck-sunshine/webui-password"


_account = user.account


def _hosts_file():
    return user.config("stream-hosts.json")


def _client():
    account = _account()
    return api.Client(account.pw_uid, PASSWORD_FILE,
                      os.path.join(account.pw_dir, ".config", "sunshine", "credentials", "cacert.pem"))


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

    async def pair(self, pairing_id, pin, name):
        return await self._change(lambda c: c.pair(pairing_id, pin, name),
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

    # -- joining

    _join = None
    _joined = None

    async def get_hosts(self):
        return self._hosts()

    async def find_hosts(self):
        known = hosts.load(_hosts_file(), _account().pw_uid) or {}
        found = await join.discover(_address())
        return {"found": [{**host, "joined": host["uuid"] in known} for host in found]}

    async def start_join(self, address):
        """Start pairing with the host at an address: {"pin": ...} to type there, or {"problem": ...}."""
        address = join.valid_address(address)
        if address is None:
            return {"pin": None, "problem": "That is not an address on this network"}
        if self._join and not self._join.done():
            return {"pin": None, "problem": "Another host is being paired"}
        host = await join.describe(address)
        if host is None:
            return {"pin": None, "problem": f"No host answers at {address}. Is it turned on there?"}
        if self._join and not self._join.done():  # another press, while the host was being asked
            return {"pin": None, "problem": "Another host is being paired"}
        pin = join.new_pin()
        self._joined = None
        self._join = asyncio.create_task(self._run_join(host, pin))
        return {"pin": pin, "problem": None, "host": host}

    async def _run_join(self, host, pin):
        try:
            problem = await join.pair(host["address"], pin)
        except OSError as exc:
            decky.logger.warning("moonlight could not run: %s", exc)
            problem = "Moonlight could not be started"
        self._joined = {"state": "failed" if problem else "paired", "problem": problem, "host": host}

    async def join_status(self):
        if self._join and not self._join.done():
            return {"state": "waiting", "problem": None, "host": None}
        return self._joined or {"state": "idle", "problem": None, "host": None}

    async def cancel_join(self):
        if self._join and not self._join.done():
            self._join.cancel()
            await asyncio.wait({self._join})
        self._join = self._joined = None

    async def remember_tile(self, uuid, name, appid):
        done = await hosts.remember(_hosts_file(), _account().pw_uid, uuid, name, appid)
        return self._hosts(None if done else "This host's tile could not be saved")

    async def forget_host(self, uuid):
        done = await hosts.forget(_hosts_file(), _account().pw_uid, uuid)
        return self._hosts(None if done else "This host could not be forgotten")

    async def tab_members(self):
        rows = hosts.load(_hosts_file(), _account().pw_uid)
        if rows is None:
            return {"error": "the list of hosts cannot be read"}
        return {"appids": [row["appid"] for row in rows.values()]}

    def _hosts(self, problem=None):
        rows = hosts.load(_hosts_file(), _account().pw_uid)
        if rows is None:
            return {"hosts": [], "problem": "The list of hosts cannot be read"}
        return {"hosts": [{"uuid": uuid, **row} for uuid, row in rows.items()], "problem": problem}

    async def _unload(self):
        await self.cancel_join()
