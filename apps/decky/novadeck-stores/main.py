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
                             library, library_sync, locations, paths, settings, shortcuts, status)

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
NO_ANSWER = "Steam did not answer the shortcut operation"
# How often the tile stub's install requests are looked for. The stub waits 10 s for its request
# to be taken (store-launch TAKE_TIMEOUT), so this must stay well under that.
REQUEST_POLL = 1.0
# Seconds between one tile's artwork and the next in the background pass after a sync.
ARTWORK_PACE = 1.0
# Finished installs are checked every FINISH_EVERY request polls (~10 s).
FINISH_EVERY = 10


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
            # Library-first: a fresh account's games appear as tiles without a second action.
            # Held and logged: nobody awaits this task, so without both an exception (or the
            # task being collected) vanishes without a line — HW 2026-10-21 left no trace at all.
            self._sync_task = asyncio.create_task(self._sync_logged(store))
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
        """Remove the game's files; an installed tile then goes back on the shelf (milestone 7),
        so the game stays in the library, installable again with one press."""
        result = await self._install_action("uninstall", store, installs.uninstall, store, gid)
        if result.get("uninstalled"):
            p = await asyncio.to_thread(paths.store_paths)
            async with _SHORTCUT_LOCK:
                row = (await asyncio.to_thread(shortcuts.read_registry, p)).get(f"{store}:{gid}")
                if isinstance(row, dict) and "appid" in row and not shortcuts.is_shelf(row):
                    swapped = await self._swap_entry(
                        p, store, gid,
                        shortcuts.shelf_payload(next(self._shortcut_seq), store, gid, row["title"]),
                        {"title": row["title"], "state": "shelf"}, None)
                    if "error" in swapped:
                        # The game is gone but its entry still points at it. Marked, so the next
                        # sync retries the swap rather than leaving a Play that launches nothing.
                        registry = await asyncio.to_thread(shortcuts.read_registry, p)
                        registry[f"{store}:{gid}"] = {**row, "state": "pending_shelf"}
                        await asyncio.to_thread(shortcuts.write_registry, p, registry)
                        return {**result, "warning": f"tile not returned to the shelf yet: {swapped['error']}"}
        return result

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
            # The frontend bridge never replied: its listener is gone (Decky dropped it) or
            # SteamUI is wedged. Logged here, once, for every caller.
            decky.logger.info(f"shortcut_op {payload.get('op')} req {req}: no answer in {SHORTCUT_TIMEOUT}s")
            return {"error": NO_ANSWER}
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
            # A shelf tile's Exe is the native install stub: a compat tool there would run the
            # stub through Proton.
            if not isinstance(row, dict) or "appid" not in row or shortcuts.is_shelf(row):
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

    # -- milestone 7: the whole owned library as Steam tiles --

    async def sync_library(self, store):
        """Give every installable owned title a tile and re-assert the [NovaDeck] collections.
        {"added": N, "tiles": total} or {"error": ...}. Idempotent; artwork for new tiles follows
        in the background and never holds the sync up."""
        if store not in connect.STORES:
            return {"error": f"unknown store {store!r}"}
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot resolve credential paths: {type(exc).__name__}"}
        async with _LOCKS[store]:
            owned = await asyncio.to_thread(library.owned, store, p)
        if "error" in owned:
            decky.logger.info(f"sync {store}: {owned['error']}")
            return owned
        added = []
        async with _SHORTCUT_LOCK:
            registry = await asyncio.to_thread(shortcuts.read_registry, p)
            for t in library_sync.to_shelve(store, owned["titles"], registry):
                result = await self._shortcut_roundtrip(
                    shortcuts.shelf_payload(next(self._shortcut_seq), store, t["id"], t["title"]))
                if result.get("error") == NO_ANSWER:
                    # SteamUI is not listening (the frontend not loaded yet): every further op
                    # would wait out the same timeout while holding the lock.
                    return {"error": NO_ANSWER}
                if "error" in result:
                    decky.logger.info(f"sync {store}:{t['id']}: {result['error']}")
                    continue
                registry[f"{store}:{t['id']}"] = {"appid": int(result["appid"]), "title": t["title"],
                                                  "state": "shelf"}
                # Written after EVERY add: a tile whose appid we never recorded is one we can
                # never touch again, and the next sync would add it twice.
                if not await self._record_or_undo(p, registry, int(result["appid"])):
                    return {"error": "the registry could not be written"}
                added.append((t["id"], int(result["appid"])))
            # Uninstalled games whose swap back to the shelf failed at the time.
            for token, row in list(registry.items()):
                if token.startswith(f"{store}:") and isinstance(row, dict) \
                        and row.get("state") == "pending_shelf":
                    gid = token.split(":", 1)[1]
                    await self._swap_entry(
                        p, store, gid,
                        shortcuts.shelf_payload(next(self._shortcut_seq), store, gid, row["title"]),
                        {"title": row["title"], "state": "shelf"}, None)
                    registry = await asyncio.to_thread(shortcuts.read_registry, p)
            # Entries replaced at an install transition whose removal Steam did not confirm.
            for token, row in registry.items():
                if not (token.startswith(f"{store}:") and isinstance(row, dict) and row.get("retired")):
                    continue
                still = [a for a in row["retired"] if "error" in await self._shortcut_roundtrip(
                    shortcuts.remove_payload(next(self._shortcut_seq), a))]
                registry[token] = {k: v for k, v in row.items() if k != "retired"} | (
                    {"retired": still} if still else {})
                await asyncio.to_thread(shortcuts.write_registry, p, registry)
            warnings = []
            for op in library_sync.collection_ops(store, registry):
                result = await self._shortcut_roundtrip(
                    library_sync.collection_payload(next(self._shortcut_seq), op))
                if "error" in result:
                    warnings.append(f"{op['name']}: {result['error']}")
        decky.logger.info(f"sync {store}: {len(added)} added, {warnings or 'collections ok'}")
        if added:
            asyncio.create_task(self._artwork_pass(store, added))
        tiles = sum(1 for k in registry if k.startswith(f"{store}:"))
        out = {"added": len(added), "tiles": tiles}
        return {**out, "warning": "; ".join(warnings)} if warnings else out

    _sync_task = None

    async def _sync_logged(self, store):
        try:
            result = await self.sync_library(store)
        except Exception as exc:  # noqa: BLE001 - a background task: logged or lost
            decky.logger.info(f"sync {store} after sign-in raised {type(exc).__name__}: {exc}")
            return
        decky.logger.info(f"sync {store} after sign-in: {result}")

    async def _artwork_pass(self, store, tiles):
        """Art for freshly added tiles, one at a time with a pause between: a 55-title library is
        165 downloads, and the sync that started this must not flood the network or SteamUI."""
        for gid, appid in tiles:
            # One tile's failure must not end the pass for every tile after it (HW 2026-10-21:
            # an InvalidURL at GTA V left the rest of a 55-tile library without art).
            try:
                await self.apply_artwork(store, gid, appid)
            except Exception as exc:  # noqa: BLE001 - art is best-effort, per tile
                decky.logger.info(f"artwork {store}:{gid}: {type(exc).__name__}: {exc}")
            await asyncio.sleep(ARTWORK_PACE)

    # -- milestone 7: a not-installed tile's Play becomes an install --

    async def take_install_requests(self, p):
        """Act on every request the tile stub left. Each outcome is emitted as an install_event
        (a toast), because the stub has already exited and Steam shows nothing for a shortcut."""
        for token in await asyncio.to_thread(install_requests.take, p):
            # Per token: the stubs have all been told "taken", so one failure must neither drop
            # the rest of the batch nor go unsaid.
            try:
                event = await self._install_tile(p, token)
            except Exception as exc:  # noqa: BLE001 - reported to the user, never swallowed
                decky.logger.info(f"install request {token}: {type(exc).__name__}")
                store, _, gid = token.partition(":")
                event = {"store": store, "id": gid, "title": gid, "ok": False,
                         "message": f"could not start: {type(exc).__name__}"}
            if event is not None:
                await decky.emit("install_event", event)

    async def install_tile(self, store, gid):
        """The panel's Resume: exactly what pressing the tile does. Returns the install_event."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"ok": False, "message": f"cannot resolve credential paths: {type(exc).__name__}"}
        event = await self._install_tile(p, f"{store}:{gid}")
        return event or {"ok": False, "message": "not a NovaDeck tile waiting to install"}

    async def _install_tile(self, p, token):
        """Start (or resume) the install behind one shelf tile. The event to show, or None for a
        request that names no shelf tile of ours (stale or forged — logged, never acted on)."""
        if not shortcuts.TOKEN.fullmatch(token):
            return None
        store, gid = token.split(":", 1)
        row = (await asyncio.to_thread(shortcuts.read_registry, p)).get(token)
        if not shortcuts.is_shelf(row):
            decky.logger.info(f"install request {token}: not a not-installed tile, ignored")
            return None
        event = {"store": store, "id": gid, "title": row["title"]}
        unit = await asyncio.to_thread(installs.unit_state)
        if unit.get("Description", "").removeprefix("novadeck-stores install ") == token \
                and unit["ActiveState"] in ("active", "activating", "reloading"):
            # A second press on a tile that is already downloading.
            return {**event, "ok": True, "message": "Already installing"}
        record = (await asyncio.to_thread(installs.read_records, p)).get(token, {})
        vols = await asyncio.to_thread(locations.user_volumes, p["NOVADECK_STORE_USER"])
        vol = locations.install_volume(vols, store, record.get("path"),
                                       await asyncio.to_thread(settings.install_drive, p))
        if vol is None:
            return {**event, "ok": False, "message": "the drive it was installing to is not available"
                    if record.get("path") else "no drive available"}
        result = await self.install(store, gid, row["title"], vol["path"])
        if result.get("started"):
            return {**event, "ok": True, "message": f"Installing to {vol['label']}"}
        return {**event, "ok": False, "message": result.get("error", "failed")}

    async def library_state(self):
        """Everything the slim panel shows below the accounts, in one call so its poll is one
        round trip: the install activity, the registry's installed games, the drives and the
        preferred one. Read-only, no lock (like install_status)."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            status_ = await asyncio.to_thread(installs.install_status, p)
            registry = await asyncio.to_thread(shortcuts.read_registry, p)
            drives = await asyncio.to_thread(locations.user_volumes, p["NOVADECK_STORE_USER"])
            drive = await asyncio.to_thread(settings.install_drive, p)
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"status failed: {type(exc).__name__}"}
        if "error" in status_:
            return status_
        tiles = {t: ("shelf" if shortcuts.is_shelf(r) else "installed")
                 for t, r in registry.items() if isinstance(r, dict)}
        installs_ = [{**i, "tile": tiles.get(f"{i['store']}:{i['id']}")} for i in status_["installs"]]
        return {"installs": installs_, "drives": drives,
                "install_drive": locations.default_volume(drives, drive)["path"] if drives else None}

    async def set_install_drive(self, drive):
        """Remember where a tile press installs. Only a drive that is mounted now is accepted."""
        try:
            p = await asyncio.to_thread(paths.store_paths)
            vols = await asyncio.to_thread(locations.user_volumes, p["NOVADECK_STORE_USER"])
            if not any(v["path"] == drive for v in vols):
                return {"error": "that drive is not available"}
            if not await asyncio.to_thread(settings.set_install_drive, p, drive):
                return {"error": "the setting could not be saved"}
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"cannot save the setting: {type(exc).__name__}"}
        return {"install_drive": drive}

    # -- milestone 7: a finished install turns its shelf tile into the model-B entry --

    async def _record_or_undo(self, p, registry, appid):
        """Write the registry that now records a just-created appid. If it cannot be written,
        remove the entry again: an entry no registry row records is one we may never touch, and
        whatever created it would create another on its next pass."""
        if await asyncio.to_thread(shortcuts.write_registry, p, registry):
            return True
        undo = await self._shortcut_roundtrip(shortcuts.remove_payload(next(self._shortcut_seq), appid))
        decky.logger.info(f"registry write failed; removed unrecorded appid {appid}: "
                          f"{undo.get('error') or 'ok'}")
        return False

    async def _swap_entry(self, p, store, gid, payload, new_row, tool):
        """Replace a token's entry with a new one. ADD FIRST: if Steam refuses the new entry the
        old tile is still there, never neither. The old appid is kept on the new row as `retired`
        until Steam confirms its removal, so a failed remove leaves an appid we still own and
        retry, not an orphan. Caller holds _SHORTCUT_LOCK. {"appid": N} or {"error": ...}."""
        token = f"{store}:{gid}"
        registry = await asyncio.to_thread(shortcuts.read_registry, p)
        old = registry.get(token)
        result = await self._shortcut_roundtrip(payload)
        if "error" in result:
            return result
        appid = int(result["appid"])
        if tool:
            compat = await self._shortcut_roundtrip(
                shortcuts.compat_payload(next(self._shortcut_seq), appid, tool))
            if "error" in compat:
                decky.logger.info(f"swap {token}: compat tool not set: {compat['error']}")
        retired = (list(old.get("retired", [])) + [old["appid"]]
                   if isinstance(old, dict) and "appid" in old else [])
        retired = [a for a in retired if a != appid]  # never retire the entry just made
        registry[token] = {**new_row, "appid": appid, "retired": retired}
        if not await self._record_or_undo(p, registry, appid):
            return {"error": "the registry could not be written"}
        still = []
        for old_appid in retired:
            gone = await self._shortcut_roundtrip(
                shortcuts.remove_payload(next(self._shortcut_seq), old_appid))
            if "error" in gone:
                still.append(old_appid)
        registry[token] = {**new_row, "appid": appid, **({"retired": still} if still else {})}
        await asyncio.to_thread(shortcuts.write_registry, p, registry)
        for op in library_sync.collection_ops(store, registry):
            await self._shortcut_roundtrip(library_sync.collection_payload(next(self._shortcut_seq), op))
        # Art is keyed by appid in Steam's grid dir, so the new entry needs its own.
        asyncio.create_task(self.apply_artwork(store, gid, appid))
        decky.logger.info(f"swap {token}: appid {appid}, retired {retired}, still held {still}")
        return {"appid": appid}

    async def finish_installs(self, p):
        """Every shelf tile whose install the CLI has now recorded as done becomes the model-B
        entry (Exe = the game, compat tool for Windows) and the user is told it is ready."""
        registry = await asyncio.to_thread(shortcuts.read_registry, p)
        records = await asyncio.to_thread(installs.read_records, p)
        waiting = [t for t, row in registry.items() if shortcuts.is_shelf(row) and t in records]
        if not waiting:
            return  # nothing installing into a tile: no systemctl spawn on an idle poll
        done = {f"{i['store']}:{i['id']}" for i in
                (await asyncio.to_thread(installs.install_status, p)).get("installs", [])
                if i.get("state") == "installed"}
        for token in waiting:
            if token not in done or token in self._unresolvable:
                continue
            store, gid = token.split(":", 1)
            title = registry[token]["title"]
            resolved = await asyncio.to_thread(launch.resolve_target, store, gid, p, records[token])
            if resolved is None:
                # Said once, not every poll: the store's metadata names no executable.
                self._unresolvable.add(token)
                await decky.emit("install_event", {"store": store, "id": gid, "title": title,
                                                   "ok": False, "message": "installed, but the store names no executable to launch"})
                continue
            async with _SHORTCUT_LOCK:
                # Re-checked under the lock: the snapshot above may predate an uninstall or a sync
                # that ran while this waited, and a swap on it would resurrect a deleted game.
                fresh = (await asyncio.to_thread(shortcuts.read_registry, p)).get(token)
                if not shortcuts.is_shelf(fresh) or token not in await asyncio.to_thread(installs.read_records, p):
                    continue
                try:
                    payload = shortcuts.add_payload(next(self._shortcut_seq), store, gid, title, resolved)
                except ValueError as exc:
                    self._unresolvable.add(token)
                    decky.logger.info(f"finish {token}: {exc}")
                    continue
                result = await self._swap_entry(
                    p, store, gid, payload,
                    {"title": title, "exe": resolved["exe"], "platform": resolved["platform"]},
                    launch.compat_tool(resolved["platform"]))
            if "error" in result:
                # Retried on the next beat; told once, not every ten seconds.
                if token not in self._finish_reported:
                    self._finish_reported.add(token)
                    await decky.emit("install_event", {"store": store, "id": gid, "title": title,
                                                       "ok": False, "message": result["error"]})
                continue
            self._finish_reported.discard(token)
            await decky.emit("install_event", {"store": store, "id": gid, "title": title,
                                               "ok": True, "message": "Ready to play"})

    _unresolvable = set()
    _finish_reported = set()
    _finish_task = None

    async def _finish_logged(self, p):
        try:
            await self.finish_installs(p)
        except Exception as exc:  # noqa: BLE001 - one bad pass must not end the watch
            decky.logger.info(f"finish installs: {type(exc).__name__}")

    async def _request_loop(self):
        # Paths resolved once (store-env is a process spawn) and retried only until they resolve;
        # the spool is a directory listing per poll, nothing more. Finished installs are looked
        # for on a slower beat: completion is not something the user is staring at a tile for.
        p = None
        tick = 0
        while True:
            try:
                p = p or await asyncio.to_thread(paths.store_paths)
                await self.take_install_requests(p)
                # Its own task: a swap can wait a long time on _SHORTCUT_LOCK (a sync talking to
                # a slow SteamUI), and a tile press must still be taken within the stub's 10 s.
                if tick % FINISH_EVERY == 0 and (self._finish_task is None or self._finish_task.done()):
                    self._finish_task = asyncio.create_task(self._finish_logged(p))
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - one bad pass must not end the watch
                decky.logger.info(f"install watch: {type(exc).__name__}")
            tick += 1
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
