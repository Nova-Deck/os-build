"""novadeck-stores — the Quick Access surface for game stores outside Steam.

Milestone 2 of the alien-games PRD: the panel shows whether Epic and GOG are connected, renews a
connected store's session each time it opens (refresh), removes one on request (disconnect), and
signs either one in from Game Mode with a gamepad. Nothing is typed and nothing leaves the device:

  1. start_connect() makes sure the credential directories exist and are writable by the user,
     snapshots Steam's browser targets, starts waiting in the background, and hands the frontend
     the login URL.
  2. The frontend opens it with NavigateToExternalWeb — Steam's own browser, created by SteamUI's
     own code, which is the only way a browser view reaches the screen (the milestone-2 spike).
  3. The background task watches Steam's CEF target list for the store's redirect, takes the code
     from it (connect.py), and has the CLI exchange it, running as the user (cli.py).
  4. It reads the credential file back and emits "connect_done"; the frontend closes the browser
     and says how it went. The QAM panel is not mounted while the browser is showing, so the
     listener lives in index.tsx, not in the panel.

It is its own plugin rather than a novadeck-control tab because it owns credentials. novadeck-control
is the settings surface and reads nothing secret; keeping the store tokens behind a separate backend
keeps the blast radius of a mistake in either one small, and it means the store panel can be dropped
from an image without touching the settings UI.

Status is read from the CLIs' own credential files rather than from any state of ours — legendary and
gogdl refresh and invalidate those, so they own the answer (see status.py).
"""
import asyncio
import subprocess

import decky

from novadeck_stores import cdp, cli, connect, paths, status

# Long enough to type an email and a password on the on-screen keyboard and clear a captcha;
# short enough that a login the user walked away from does not poll for the rest of the session.
LOGIN_TIMEOUT = 600


def _store_status(store, p):
    if store == "epic":
        return status.epic_status(p["LEGENDARY_CONFIG_PATH"])
    return status.gog_status(p["NOVADECK_GOGDL_AUTH"])


# One CLI call per store at a time. gogdl rewrites its whole auth file after a refresh with no
# lock of its own, so a refresh still in flight when the user disconnects would write the
# credentials straight back. legendary has a file lock; this keeps the two stores' rules the same.
_LOCKS = {store: asyncio.Lock() for store in connect.STORES}


class Plugin:
    _pending = None

    async def get_status(self):
        return await asyncio.to_thread(self._status)

    def _status(self):
        try:
            p = paths.store_paths()
        except Exception as exc:
            # store-env missing or refusing to run is a broken image, not an empty state. Say so
            # rather than reporting both stores "not connected", which invites the user to fix it
            # by signing in again — the one action that cannot help.
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        return {"stores": [_store_status(s, p) for s in connect.STORES]}

    async def start_connect(self, store):
        """Prepare a sign-in and return {"url": ...} for the frontend to open, or {"error": ...}.

        Everything that can fail without spending the user's code fails HERE, before the login
        page is on screen: an unknown store, unresolvable paths, a directory the user cannot write.
        """
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths, True)
            writable = await asyncio.to_thread(cli.writable_by_user, p)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot prepare credential storage: {type(exc).__name__}"}
        if not writable:
            return {"error": "credential storage is not writable by the user"}
        try:
            before = connect.snapshot(await cdp.list_targets())
        except OSError:
            return {"error": "cannot reach Steam's browser"}

        # One sign-in at a time. A second start replaces the first: the user backed out of the
        # earlier page (the only way to get back to the panel), so nothing is waiting on it.
        if self._pending and not self._pending.done():
            self._pending.cancel()
        self._pending = asyncio.create_task(self._connect_flow(store, p, before))
        return {"url": connect.LOGIN_URLS[store]}

    async def _connect_flow(self, store, p, before):
        code = await connect.capture(store, cdp.list_targets, cdp.read_body, before, LOGIN_TIMEOUT)
        if code is None:
            decky.logger.info(f"{store}: sign-in not completed within {LOGIN_TIMEOUT}s")
            # close=False: the user has long since left the login, and navigating Home now would
            # pull them out of whatever they are doing instead.
            await decky.emit("connect_done", store, False, False, "Sign-in timed out")
            return
        result = await self._run_cli("exchange", store, p, cli.exchange, store, code, p)
        if result["connected"]:
            await decky.emit("connect_done", store, True, True, "Connected")
        else:
            await decky.emit("connect_done", store, False, True, "Sign-in failed")

    async def _run_cli(self, action, store, p, fn, *args):
        """Run one CLI call under the store's lock and return the status read back afterwards.
        The exit status goes to the log only: neither CLI's means anything (cli.py)."""
        async with _LOCKS[store]:
            # Cancelling a task does not stop its thread: start_connect cancels a pending sign-in,
            # and if that lands here the CLI runs on. So the lock is held until the CLI has
            # really exited, and only then does the cancellation carry on up.
            call = asyncio.ensure_future(asyncio.to_thread(fn, *args))
            try:
                rc = await asyncio.shield(call)
            except asyncio.CancelledError:
                await asyncio.wait({call})
                raise
            except (OSError, subprocess.SubprocessError) as exc:
                rc = type(exc).__name__
            result = await asyncio.to_thread(_store_status, store, p)
        decky.logger.info(f"{store}: {action} exited {rc}, connected={result['connected']}, "
                          f"expired={result.get('expired')}")
        return result

    async def refresh(self, store):
        """Renew a connected store's session through its CLI and return the status after.

        Asked by the panel on every open, for each connected store. Afterwards `expired` means
        the CLI could not renew it: offline, or GOG refused (gogdl cannot tell those apart). A
        session Epic refused is gone entirely, since legendary deletes it.
        """
        return await self._account_action("refresh", store, cli.refresh)

    async def disconnect(self, store):
        """Remove a store's credentials from this device and return the status after."""
        return await self._account_action("disconnect", store, cli.disconnect)

    async def _account_action(self, action, store, fn):
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        return await self._run_cli(action, store, p, fn, store, p)

    async def _main(self):
        pass

    async def _unload(self):
        if self._pending and not self._pending.done():
            self._pending.cancel()
