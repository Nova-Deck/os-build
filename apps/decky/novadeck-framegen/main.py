"""novadeck-framegen — the Quick Access surface for lsfg-vk frame generation.

It exists as its own plugin rather than a novadeck-control tab because it is optional in a way
nothing else in that panel is: it does nothing at all unless the user has bought a third-party
app AND switched it to a beta branch. It also replaces upstream's own configuration UI, which is
a Qt6 desktop application and cannot be shown in a gamescope session.

Every state-changing call returns the WHOLE new state rather than an acknowledgement. Two files
are involved (lsfg-vk's conf.toml and game-tweaks.json), a second plugin writes one of them, and
the layer itself writes the other -- so the panel re-reads rather than assuming its own optimistic
update won.

Blocking work goes to a thread: this reads Steam's on-disk library, which on a full card is a few
hundred small files, and Decky's asyncio loop is shared with every other plugin.
"""
import asyncio

from novadeck_framegen import conf, device, prereq, tweaks
from novadeck_framegen.steam import installed_games


class Plugin:
    async def get_state(self):
        return await asyncio.to_thread(self._state)

    async def set_enabled(self, appid: str, on: bool):
        """Turn frame generation on or off for one game.

        Turning ON writes the profile FIRST, then the env that points at it. The other order
        leaves a window where a launch would set LSFGVK_PROFILE to a profile that does not
        exist yet -- upstream falls back to no profile at all in that case, so frame generation
        would silently not happen and the panel would say it was on.
        """
        return await asyncio.to_thread(self._set_enabled, str(appid), bool(on))

    async def set_settings(self, appid: str, settings: dict):
        """Update one game's tuning. Hot-reloads into a running game via the layer's watcher."""
        return await asyncio.to_thread(self._set_settings, str(appid), settings or {})

    @staticmethod
    def _state():
        status = prereq.status()
        return {
            "prereq": status,
            "defaults": device.defaults(),
            "games": installed_games(),
            "profiles": conf.read_profiles(),
            "enabled": sorted(tweaks.enabled_games()),
            # Display names for games Steam no longer has a manifest for. `games` above is
            # INSTALLED titles only, so without this an enabled game that has been uninstalled
            # has no name to show -- and, before the picker learned to list it at all, no row
            # either, while its env keys and the launch wrapper stayed live.
            "knownNames": tweaks.known_names(),
            # Which games the CONTROL plugin has tuning on for. The panel needs it to
            # decide whether the launch wrapper may be removed -- both features need it.
            "tweaked": sorted(tweaks.tweaked_games()),
        }

    @staticmethod
    def _set_enabled(appid, on):
        if on:
            existing = conf.read_profiles().get(appid)
            conf.write_profile(appid, existing or device.defaults())
            # Cache the name into the shared entry while Steam still has a manifest to read it
            # from -- enabling is the last moment we are guaranteed to have one, and the entry
            # outlives the install.
            name = next(
                (game["name"] for game in installed_games() if str(game.get("appid")) == appid),
                "",
            )
            tweaks.set_enabled(appid, True, name=name)
        else:
            # The profile is deliberately LEFT BEHIND on disable. It is a few lines of TOML, it
            # is what the user tuned, and having it survive an off/on cycle is the difference
            # between a toggle and a reset button.
            tweaks.set_enabled(appid, False)
        return Plugin._state()

    @staticmethod
    def _set_settings(appid, settings):
        conf.write_profile(appid, settings)
        return Plugin._state()
