"""novadeck-stores — the Quick Access surface for game stores outside Steam.

Milestone 2 of the alien-games PRD. RIGHT NOW IT ONLY REPORTS: the panel shows whether Epic and
GOG are connected and offers no way to connect them. That is deliberate — the PRD lands each layer
inert rather than behind a flag nothing exercises, and the sign-in flow is the next task.

It is its own plugin rather than a novadeck-control tab because it owns credentials. novadeck-control
is the settings surface and reads nothing secret; keeping the store tokens behind a separate backend
keeps the blast radius of a mistake in either one small, and it means the store panel can be dropped
from an image without touching the settings UI.

Status is read from the CLIs' own credential files rather than from any state of ours — legendary and
gogdl refresh and invalidate those, so they own the answer (see status.py).
"""
import asyncio

from novadeck_stores import paths, status


class Plugin:
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
        return {
            "stores": [
                status.epic_status(p["LEGENDARY_CONFIG_PATH"]),
                status.gog_status(p["NOVADECK_GOGDL_AUTH"]),
            ]
        }

    async def _main(self):
        pass

    async def _unload(self):
        pass
