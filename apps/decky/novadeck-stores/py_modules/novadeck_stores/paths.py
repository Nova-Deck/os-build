"""Where store credentials live — asked, never assumed.

The answer belongs to /usr/lib/novadeck/store-env, which is also what the launch path will read
in a later milestone. This module runs it rather than repeating its paths, so there is exactly one
declaration: a second copy here would drift the first time the location moves, and the symptom
would be an account that reads as connected in the QAM and absent at launch.

NOVADECK_STORE_ENV points the whole module at another script, which is how the offline suite
drives this against a temp tree with no /usr/lib/novadeck and no deck user.
"""
import os
import shlex
import subprocess

STORE_ENV = os.environ.get("NOVADECK_STORE_ENV", "/usr/lib/novadeck/store-env")


def _clean_env():
    """Decky's PluginLoader is a PyInstaller bundle, and it exports an LD_LIBRARY_PATH pointing at
    its OWN bundled libraries. store-env is a host shell script, so inheriting that would load
    the bundle's libraries into host tools instead of the system's (on a loader still x86 under
    FEX, libraries of the wrong arch outright). Restoring PyInstaller's saved
    _ORIG value is the documented pattern, and novadeck-control's power.py does the same for
    busctl; tests/test-decky.sh asserts on it for every plugin that spawns anything.
    """
    env = dict(os.environ)
    orig = env.pop("LD_LIBRARY_PATH_ORIG", None)
    if orig is not None:
        env["LD_LIBRARY_PATH"] = orig
    else:
        env.pop("LD_LIBRARY_PATH", None)
    return env


def store_paths(ensure=False):
    """Return {NOVADECK_STORE_USER, NOVADECK_STORE_UID, NOVADECK_STORE_HOME, LEGENDARY_CONFIG_PATH,
    NOVADECK_GOGDL_AUTH}.

    With ensure=True the tree is created first, owned by the deck user — gogdl will not create
    its own parent, and its writer runs AFTER the authorization code has been exchanged, so a
    missing directory costs the user a single-use login rather than just failing.
    """
    argv = [STORE_ENV] + (["--ensure"] if ensure else [])
    out = subprocess.run(
        argv, capture_output=True, text=True, check=True, env=_clean_env()
    ).stdout
    values = {}
    for line in out.splitlines():
        key, _, raw = line.partition("=")
        if not raw:
            continue
        # store-env quotes with printf %q, so a path with a space arrives escaped rather than
        # split. shlex undoes exactly that.
        parts = shlex.split(raw)
        if parts:
            values[key] = parts[0]
    return values
