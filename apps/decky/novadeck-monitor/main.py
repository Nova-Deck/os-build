import asyncio

from novadeck_monitor.powerd import power_snapshot
from novadeck_monitor.system import os_version
from novadeck_monitor.telemetry import telemetry


class Plugin:
    # The sysfs sweeps go to a thread so a slow read can't stall Decky's asyncio loop. The
    # busctl call does NOT: it is awaited, because a worker thread parked in a subprocess is
    # non-daemon and blocks interpreter exit -- which cost the Monitor a SIGKILL on every
    # shutdown. powerd.py's _busctl docstring has the measurement.
    async def get_telemetry(self):
        # One busctl, not two: the panel polls at 1 Hz and the fan/temperature half of what it
        # shows comes from powerd, so pairing the sysfs read with a single GetAll keeps the
        # panel at one subprocess per second instead of two.
        base = await asyncio.to_thread(telemetry)
        return {**base, "power": await power_snapshot()}

    async def get_os_version(self):
        return await asyncio.to_thread(os_version)
