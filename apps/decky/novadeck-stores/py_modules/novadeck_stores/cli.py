"""Running legendary and gogdl — always as the store user, never as root.

The plugin backend is root (plugin.json flags), and every file these CLIs write lands in the
user's home. Running them as root would create root-owned credentials that the launch path, which
runs as the user, cannot refresh — the failure novadeck-framegen's conf.py documents for lsfg-vk.
runuser makes the CLI the file's author, so ownership is right by construction rather than
repaired by a chown pass afterwards.

NEITHER CLI'S EXIT STATUS MEANS ANYTHING HERE. `legendary auth` logs a failed login and returns 0;
`gogdl auth` prints {"error": true} and returns 0. Success is decided by reading the credential
file back (status.py), which is also what the panel shows — one answer, not two.

stdout is DISCARDED, never captured: on success gogdl prints the full token set (access and
refresh token) to it, and a captured stdout is one careless log line from a leaked credential.
The code itself travels on argv, because that is the only way either CLI accepts it; it is
single-use and spent within the call.
"""
import subprocess

from novadeck_stores.paths import _clean_env

EXCHANGE_TIMEOUT = 120


def _as_user(user, argv):
    return ["runuser", "-u", user, "--"] + argv


def exchange_argv(store, code, p):
    """The CLI invocation that turns an authorization code into stored credentials.

    gogdl's --auth-config-path goes BEFORE the subcommand; it has no default, and without it the
    tokens are fetched and then thrown away (store-env explains).
    """
    if store == "epic":
        return ["legendary", "auth", "--code", code]
    if store == "gog":
        return ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "auth", "--code", code]
    raise ValueError(f"unknown store {store!r}")


def _exchange_env(p):
    """Only what the CLI needs, not root's whole environment. runuser supplies HOME, USER and
    LOGNAME for the target user; LD_LIBRARY_PATH is dropped outright (see _clean_env)."""
    inherited = _clean_env()
    env = {k: inherited[k] for k in ("PATH", "LANG") if k in inherited}
    env["LEGENDARY_CONFIG_PATH"] = p["LEGENDARY_CONFIG_PATH"]
    return env


def exchange(store, code, p):
    """Run the exchange as the store user. Returns the exit status, for the log only."""
    env = _exchange_env(p)
    result = subprocess.run(
        _as_user(p["NOVADECK_STORE_USER"], exchange_argv(store, code, p)),
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=env, timeout=EXCHANGE_TIMEOUT,
    )
    return result.returncode


def writable_by_user(p):
    """Can the store user write both credential directories? Asked BEFORE the login opens.

    The code is single-use and the CLIs write only after spending it, so an unwritable directory
    discovered at exchange time has already cost the user their sign-in. `test -w` as the user
    answers the question the CLI will actually face, including ownership and mode.
    """
    gog_dir = p["NOVADECK_GOGDL_AUTH"].rsplit("/", 1)[0]
    for d in (p["LEGENDARY_CONFIG_PATH"], gog_dir):
        rc = subprocess.run(
            _as_user(p["NOVADECK_STORE_USER"], ["test", "-w", d]),
            stdin=subprocess.DEVNULL, capture_output=True, env=_clean_env(),
        ).returncode
        if rc != 0:
            return False
    return True
