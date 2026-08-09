"""Small read-only system facts for the plugin header."""
from pathlib import Path

# Written by images/assemble-rootfs.sh. KEY=VALUE lines, NOT a bare version string — reading
# the file whole put the entire build stamp in the plugin's header (HW-observed 2026-08-09).
OS_VERSION_PATH = Path("/etc/novadeck-release")
OS_RELEASE_PATH = Path("/etc/os-release")


def _keyvals(path):
    values = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return values


def os_version():
    """A short human label: the release version, plus the commit when it adds information.

    A dev build stamps NOVADECK_VERSION=dev, which alone cannot tell two dev cards apart — and
    telling them apart is exactly what this line is for in a bug report, so the git stamp rides
    along. A release ("v0.2.1") already names itself and the sha would be noise.
    """
    release = _keyvals(OS_VERSION_PATH)
    version = release.get("NOVADECK_VERSION", "")
    git = release.get("NOVADECK_GIT", "")
    if version and git and version == "dev":
        return f"{version} ({git})"
    if version:
        return version
    return _keyvals(OS_RELEASE_PATH).get("VERSION_ID", "unknown")
