"""Running legendary and gogdl — always as the store user, never as root.

The plugin backend is root (plugin.json flags), and every file these CLIs write lands in the
user's home. Running them as root would create root-owned credentials that the launch path, which
runs as the user, cannot refresh — the failure novadeck-framegen's conf.py documents for lsfg-vk.
Running it as the user makes the CLI the file's author, so ownership is right by construction
rather than repaired by a chown pass afterwards.

HOST SYSTEMD STARTS THE CLI, NOT US. PluginLoader is an x86_64 bundle under FEX, and FEX resolves
every path its children open against the x86 guest rootfs first. legendary and gogdl are not in
the guest, so their scripts come from the host — but their `#!/usr/bin/python` IS in the guest,
and that python has neither package (HW-observed: `ModuleNotFoundError: No module named
'legendary'`, exit 1, for both stores). A transient unit is started by PID 1 on the host, natively,
with none of our emulation, environment or file descriptors except the ones --pipe hands over.

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
CHECK_TIMEOUT = 10


def _as_user(user, argv, max_sec, setenv=None):
    """systemd-run invocation that runs argv as user on the host and returns its exit status.

    --pipe connects the unit to OUR stdin/stdout/stderr. Without it the unit's output goes to the
    journal, and gogdl prints the whole token set on stdout.
    --description replaces the default, which is the command line: the journal's "Started ..."
    line would otherwise carry the authorization code.
    RuntimeMaxSec bounds the unit itself. Our subprocess timeout only kills systemd-run, and the
    unit would carry on without it.
    The unit's environment is systemd's for that user (HOME, USER, PATH) plus setenv; nothing of
    ours is inherited.
    """
    opts = [
        "systemd-run", "--quiet", "--collect", "--pipe", "--wait",
        f"--description=novadeck-stores {argv[0]}",
        f"--property=User={user}",
        f"--property=RuntimeMaxSec={max_sec}",
    ]
    opts += [f"--setenv={k}={v}" for k, v in (setenv or {}).items()]
    return opts + ["--"] + argv


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


def _exchange_setenv(p):
    """Only what the CLI needs on top of systemd's per-user environment, not root's."""
    env = {"LEGENDARY_CONFIG_PATH": p["LEGENDARY_CONFIG_PATH"]}
    lang = _clean_env().get("LANG")
    if lang:
        env["LANG"] = lang
    return env


def exchange(store, code, p):
    """Run the exchange as the store user. Returns the exit status, for the log only.

    systemd-run itself is resolved from the guest rootfs and runs under FEX, so it gets
    _clean_env: the bundle's LD_LIBRARY_PATH breaks guest binaries (power.py's busctl finding).
    """
    argv = _as_user(p["NOVADECK_STORE_USER"], exchange_argv(store, code, p),
                    EXCHANGE_TIMEOUT, _exchange_setenv(p))
    result = subprocess.run(
        argv,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=_clean_env(), timeout=EXCHANGE_TIMEOUT + CHECK_TIMEOUT,
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
            _as_user(p["NOVADECK_STORE_USER"], ["test", "-w", d], CHECK_TIMEOUT),
            stdin=subprocess.DEVNULL, capture_output=True, env=_clean_env(),
            timeout=CHECK_TIMEOUT * 2,
        ).returncode
        if rc != 0:
            return False
    return True
