import asyncio

from novadeck_control.power import (
    power_status,
    reset_fan_curve,
    set_active_profile,
    set_cpu_scheduler,
    set_fan_curve,
    set_gpu_level,
    set_manual_gpu_clock,
)
from novadeck_control.steam import installed_games
from novadeck_control.system import os_version
from novadeck_control.tweaks import load_base_thunks, load_fex_profiles, load_tweaks, save_tweaks


class Plugin:
    # Offload blocking work (file IO, busctl) to a thread so a slow call can't stall
    # Decky's asyncio loop.
    async def get_config(self):
        return await asyncio.to_thread(self._build_config)

    async def get_installed_games(self):
        return await asyncio.to_thread(installed_games)

    async def save_tweaks(self, data):
        return await asyncio.to_thread(save_tweaks, data)

    async def get_power_status(self):
        return await asyncio.to_thread(power_status)

    async def set_active_profile(self, label):
        return await asyncio.to_thread(set_active_profile, label)

    async def set_gpu_level(self, level):
        return await asyncio.to_thread(set_gpu_level, level)

    async def set_manual_gpu_clock(self, mhz):
        return await asyncio.to_thread(set_manual_gpu_clock, mhz)

    async def set_cpu_scheduler(self, scheduler):
        return await asyncio.to_thread(set_cpu_scheduler, scheduler)

    async def set_fan_curve(self, pwms):
        return await asyncio.to_thread(set_fan_curve, pwms)

    async def reset_fan_curve(self, every=False):
        return await asyncio.to_thread(reset_fan_curve, every)

    @staticmethod
    def _build_config():
        return {
            "tweaks": load_tweaks(),
            "fexProfiles": load_fex_profiles(),
            "fexThunks": load_base_thunks(),
            "power": power_status(),
            "osVersion": os_version(),
        }
