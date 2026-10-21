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
import itertools
import subprocess

import decky

import base64

from novadeck_stores import (artwork, cdp, cli, connect, install_requests, installs, launch,
                             library, locations, paths, shortcuts, status)

# Long enough to type an email and a password on the on-screen keyboard and clear a captcha;
# short enough that a login the user walked away from does not poll for the rest of the session.
LOGIN_TIMEOUT = 600


def _store_status(store, p):
    uid = int(p["NOVADECK_STORE_UID"])
    if store == "epic":
        return status.epic_status(p["LEGENDARY_CONFIG_PATH"], uid)
    return status.gog_status(p["NOVADECK_GOGDL_AUTH"], uid)


# One CLI call per store at a time. gogdl rewrites its whole auth file after a refresh with no
# lock of its own, so a refresh still in flight when the user disconnects would write the
# credentials straight back. legendary has a file lock; this keeps the two stores' rules the same.
_LOCKS = {store: asyncio.Lock() for store in connect.STORES}
# One install operation at a time: two starts would race for the one unit name, and an uninstall
# must not interleave with a start writing the same record.
_INSTALL_LOCK = asyncio.Lock()
# One library-entry operation at a time, for the same reason: two registers would race the
# registry read-modify-write, and the frontend round-trip must pair one result with one request.
_SHORTCUT_LOCK = asyncio.Lock()
# How long Steam gets to answer an AddShortcut/RemoveShortcut before the operation is an error.
# Generous: the frontend executes synchronously once it hears the event, but the event bus itself
# can lag behind a busy SteamUI.
SHORTCUT_TIMEOUT = 30
# How often the tile stub's install requests are looked for. The stub waits 10 s for its request
# to be taken (store-launch TAKE_TIMEOUT), so this must stay well under that.
REQUEST_POLL = 1.0


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

    # --- milestone 3: owned titles, drives, install / stop / uninstall. Callable, not yet surfaced:
    # the panel that uses these is milestone 7's. ---------------------------------------------

    async def owned(self, store):
        """{"titles": [{id, title, installable[, requires]}]} or {"error": ...}. Under the store's
        lock: listing logs in, and a login can rewrite the token file."""
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        async with _LOCKS[store]:
            return await asyncio.to_thread(library.owned, store, p)

    async def drives(self):
        """[{path, label, free}] — where a game can be installed."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            return {"drives": await asyncio.to_thread(locations.user_volumes, p["NOVADECK_STORE_USER"])}
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot list drives: {type(exc).__name__}"}

    async def install(self, store, gid, title, drive):
        """Start or resume an install; the download then runs on its own (installs.py)."""
        return await self._install_action("install", store, installs.install, store, gid, title, drive)

    async def install_status(self):
        """Read-only (installs.install_status), so it takes no lock: polled for progress, it must
        not wait behind an uninstall's rm."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            return await asyncio.to_thread(installs.install_status, p)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"status failed: {type(exc).__name__}"}

    async def stop_install(self):
        return await self._install_action("stop", None, lambda p: {"stopped": installs.stop() == 0})

    async def uninstall(self, store, gid):
        return await self._install_action("uninstall", store, installs.uninstall, store, gid)

    async def _install_action(self, action, store, fn, *args):
        """One install operation at a time, and under the store's lock where the call can log in
        (the size lookup) or remove what a refresh would write back."""
        if store is not None and store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths, action == "install")
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        async with _INSTALL_LOCK:
            try:
                if store is None:
                    result = await asyncio.to_thread(fn, *args, p)
                else:
                    async with _LOCKS[store]:
                        result = await asyncio.to_thread(fn, *args, p)
            except (OSError, subprocess.SubprocessError) as exc:
                result = {"error": f"{action} failed: {type(exc).__name__}"}
        decky.logger.info(f"{action} {store or ''} {args[1] if len(args) > 1 else ''}: "
                          f"{result.get('error') or 'ok'}")
        return result

    # -- milestone 4: library entries, callable but not yet surfaced --

    _shortcut_pending = {}
    _shortcut_seq = itertools.count(1)

    async def _shortcut_roundtrip(self, payload):
        """Emit one operation to the frontend bridge and wait for its shortcut_result. The req id
        pairs them; a SteamUI that never answers is an error here, never a hang."""
        req = payload["req"]
        fut = asyncio.get_running_loop().create_future()
        self._shortcut_pending[req] = fut
        try:
            await decky.emit("shortcut_op", payload)
            return await asyncio.wait_for(fut, SHORTCUT_TIMEOUT)
        except asyncio.TimeoutError:
            return {"error": "Steam did not answer the shortcut operation"}
        finally:
            self._shortcut_pending.pop(req, None)

    async def shortcut_result(self, req, appid=None, error=None):
        """Called back by the frontend bridge (shortcutBridge.ts) with one operation's outcome."""
        fut = self._shortcut_pending.get(req)
        if fut is not None and not fut.done():
            fut.set_result({"error": error} if error else {"appid": appid})

    async def register_entry(self, store, gid, title=None):
        """Create the Steam library entry for an INSTALLED game: Exe = the resolved game binary,
        and for a Windows title a compat tool is set so Steam composes SLR4+Proton (milestone 6).
        {"registered": True, "appid": N, "path": ..., "platform": ...} or {"error": ...}."""
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        async with _SHORTCUT_LOCK:
            record = (await asyncio.to_thread(installs.read_records, p)).get(f"{store}:{gid}", {})
            title = title or record.get("title")
            if not title:
                return {"error": "no title known for this game — pass one"}
            resolved = await asyncio.to_thread(launch.resolve_target, store, gid, p, record)
            if resolved is None:
                return {"error": "the game is not installed, or the store names no executable"}
            registry = await asyncio.to_thread(shortcuts.read_registry, p)
            refused = shortcuts.check_register(registry, store, gid)
            if refused:
                return {"error": refused}
            try:
                payload = shortcuts.add_payload(next(self._shortcut_seq), store, gid, title, resolved)
            except ValueError as exc:
                return {"error": str(exc)}
            result = await self._shortcut_roundtrip(payload)
            if "error" in result:
                decky.logger.info(f"register {store}:{gid}: {result['error']}")
                return result
            appid = int(result["appid"])
            # Windows → set our Proton so Steam composes the runtime. A compat failure does NOT
            # unwind the entry (it still exists and can launch once the tool is set on retry/boot),
            # but it is surfaced so the caller knows the runtime is not yet wired.
            warning = None
            tool = launch.compat_tool(resolved["platform"])
            if tool:
                compat = await self._shortcut_roundtrip(
                    shortcuts.compat_payload(next(self._shortcut_seq), appid, tool))
                if "error" in compat:
                    warning = f"compat tool not set: {compat['error']}"
                    decky.logger.info(f"register {store}:{gid}: {warning}")
            registry[f"{store}:{gid}"] = {"appid": appid, "title": title,
                                          "exe": resolved["exe"], "platform": resolved["platform"]}
            if not await asyncio.to_thread(shortcuts.write_registry, p, registry):
                return {"error": "entry created but the registry could not be written"}
            decky.logger.info(f"register {store}:{gid}: appid {appid} ({resolved['platform']})")
            out = {"registered": True, "appid": appid, "path": resolved["startdir"],
                   "platform": resolved["platform"]}
            return {**out, "warning": warning} if warning else out

    async def reassert_compat(self, p=None):
        """Re-set the compat tool on every Windows entry. SpecifyCompatTool is in-memory until
        Steam flushes config.vdf, so a set made late in a session can be lost on a crash; this
        runs best-effort at plugin boot. Fire-and-forget: a frontend not yet listening must not
        block load."""
        try:
            p = p or await asyncio.to_thread(paths.store_paths)
            registry = await asyncio.to_thread(shortcuts.read_registry, p)
        except (OSError, subprocess.SubprocessError):
            return
        for row in registry.values():
            if not isinstance(row, dict) or "appid" not in row:
                continue
            tool = launch.compat_tool(row.get("platform", "windows"))
            if tool:
                asyncio.create_task(self._shortcut_roundtrip(
                    shortcuts.compat_payload(next(self._shortcut_seq), row["appid"], tool)))

    async def deregister_entry(self, store, gid):
        """Remove the entry and its registry row. {"deregistered": True} or {"error": ...}."""
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        async with _SHORTCUT_LOCK:
            registry = await asyncio.to_thread(shortcuts.read_registry, p)
            row = registry.get(f"{store}:{gid}")
            if not isinstance(row, dict) or "appid" not in row:
                decky.logger.info(f"deregister {store}:{gid}: not in the registry")
                return {"error": "not registered"}
            result = await self._shortcut_roundtrip(
                shortcuts.remove_payload(next(self._shortcut_seq), row["appid"]))
            if "error" in result:
                decky.logger.info(f"deregister {store}:{gid}: {result['error']}")
                return result
            registry.pop(f"{store}:{gid}")
            if not await asyncio.to_thread(shortcuts.write_registry, p, registry):
                return {"error": "entry removed but the registry could not be written"}
            decky.logger.info(f"deregister {store}:{gid}: removed appid {row['appid']}")
            return {"deregistered": True}

    async def apply_artwork(self, store, gid, appid):
        """Set grid art on a registered entry from the store's own metadata. NON-BLOCKING by
        contract: {"applied": [kinds]} always, even when nothing could be fetched — a failure
        here must never unwind a good registration or raise into the caller. Idempotent: re-runs
        re-set the same slots."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            urls = await asyncio.to_thread(artwork.store_urls, store, gid, p)
            images = []
            for kind, url in urls.items():
                got = await asyncio.to_thread(artwork.fetch_image, url)
                if got is None:
                    continue
                data, image_type = got
                images.append({"kind": kind, "assetType": artwork.KIND_ASSET[kind],
                               "base64": base64.b64encode(data).decode(), "imageType": image_type})
            if not images:
                return {"applied": []}
            payload = {"op": "artwork", "req": next(self._shortcut_seq), "appid": int(appid),
                       "images": images}
            result = await self._shortcut_roundtrip(payload)
            if "error" in result:
                decky.logger.info(f"artwork {store}:{gid}: {result['error']}")
                # Still not an error to the caller: the entry stands with its name tile.
                return {"applied": [], "warning": result["error"]}
            return {"applied": [img["kind"] for img in images]}
        except (OSError, subprocess.SubprocessError) as exc:
            decky.logger.info(f"artwork {store}:{gid}: {type(exc).__name__}")
            return {"applied": []}

    async def entry_status(self):
        """Registry joined against what Steam's own file holds — READ-ONLY, like install_status.
        An unreadable file reports as such; it is never 'no entries'."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            return await asyncio.to_thread(self._entry_status, p)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"status failed: {type(exc).__name__}"}

    def _entry_status(self, p):
        registry = shortcuts.read_registry(p)
        roots = launch.managed_roots(p)
        reports = []
        for path in shortcuts.vdf_paths(p):
            f = status.open_user_file(path, int(p["NOVADECK_STORE_UID"]))
            if f is None:
                reports.append({"file": path, "error": "not readable as the store user's file"})
                continue
            with f:
                raw = f.read()
            try:
                reports.append({"file": path, **shortcuts.orphan_report(raw, registry, roots)})
            except ValueError as exc:
                reports.append({"file": path, "error": f"unreadable: {exc}"})
        return {"registry": registry, "files": reports}

    # -- milestone 7: a not-installed tile's Play becomes an install --

    async def take_install_requests(self, p):
        """Act on every request the tile stub left. Each outcome is emitted as an install_event
        (a toast), because the stub has already exited and Steam shows nothing for a shortcut."""
        tokens = await asyncio.to_thread(install_requests.take, p)
        for token in tokens:
            store, gid = token.split(":", 1)
            row = (await asyncio.to_thread(shortcuts.read_registry, p)).get(token)
            if not shortcuts.is_shelf(row):
                # A stale or forged request: not a tile we made, or one already installed.
                decky.logger.info(f"install request {token}: not a not-installed tile, ignored")
                continue
            vol = locations.default_volume(
                await asyncio.to_thread(locations.user_volumes, p["NOVADECK_STORE_USER"]))
            if vol is None:
                result = {"error": "no drive available"}
            else:
                result = await self.install(store, gid, row["title"], vol["path"])
            ok = bool(result.get("started"))
            await decky.emit("install_event", {
                "store": store, "id": gid, "title": row["title"], "ok": ok,
                "message": f"Installing to {vol['label']}" if ok else result.get("error", "failed")})

    async def _request_loop(self):
        # Paths resolved once (store-env is a process spawn) and retried only until they resolve;
        # the spool is a directory listing per poll, nothing more.
        p = None
        while True:
            try:
                p = p or await asyncio.to_thread(paths.store_paths)
                await self.take_install_requests(p)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - one bad pass must not end the watch
                decky.logger.info(f"install requests: {type(exc).__name__}")
            await asyncio.sleep(REQUEST_POLL)

    async def _main(self):
        # Compat mappings are in-memory until Steam flushes config.vdf; re-assert ours at boot.
        try:
            await self.reassert_compat()
        except Exception as exc:  # noqa: BLE001 - boot best-effort, never fail load
            decky.logger.info(f"reassert_compat at boot: {type(exc).__name__}")
        await self._request_loop()

    async def _unload(self):
        if self._pending and not self._pending.done():
            self._pending.cancel()
