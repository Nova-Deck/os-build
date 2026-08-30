import asyncio

from novadeck_monitor.powerd import power_snapshot
from novadeck_monitor.system import os_version
from novadeck_monitor.telemetry import telemetry


class Plugin:
    # Offload blocking work (sysfs sweeps, busctl) to a thread so a slow call can't stall
    # Decky's asyncio loop.
    async def get_telemetry(self):
        # One call, not two: the panel polls at 1 Hz and the fan/temperature half of what it
        # shows comes from powerd, so pairing the sysfs read with a single GetAll keeps the
        # panel at one busctl subprocess per second instead of two.
        return await asyncio.to_thread(self._build_telemetry)

    async def get_os_version(self):
        return await asyncio.to_thread(os_version)

    @staticmethod
    def _build_telemetry():
        return {**telemetry(), "power": power_snapshot()}
