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
REFRESH_TIMEOUT = 60
CHECK_TIMEOUT = 10


def _as_user(user, argv, max_sec, setenv=None, *, umask="0077", unit=None, description=None,
             props=()):
    """systemd-run invocation that runs argv as user on the host and returns its exit status.

    With unit= it is DETACHED instead: a named unit that outlives us, no --pipe and no --wait,
    for a download that takes hours (installs.py). max_sec=None sets no deadline.

    --pipe connects the unit to OUR stdin/stdout/stderr. Without it the unit's output goes to the
    journal, and gogdl prints the whole token set on stdout.
    --description replaces the default, which is the command line: the journal's "Started ..."
    line would otherwise carry the authorization code.
    UMask=0077 makes the token files 0600. Both CLIs create them with a bare open(..., 'w'), so
    the unit's umask is their mode: 0644 under the default (HW-observed). The 0700 directory keeps
    them private either way; the files should not rely on it.
    RuntimeMaxSec bounds the unit itself. Our subprocess timeout only kills systemd-run, and the
    unit would carry on without it.
    The unit's environment is systemd's for that user (HOME, USER, PATH) plus setenv; nothing of
    ours is inherited.
    """
    opts = ["systemd-run", "--quiet", "--collect"]
    opts += [f"--unit={unit}"] if unit else ["--pipe", "--wait"]
    opts += [
        f"--description={description or f'novadeck-stores {argv[0]}'}",
        f"--property=User={user}",
        f"--property=UMask={umask}",
    ]
    if max_sec:
        opts.append(f"--property=RuntimeMaxSec={max_sec}")
    opts += [f"--property={prop}" for prop in props]
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


def refresh_argv(store, p):
    """The CLI invocation that renews a session through the CLI's own refresh path.

    legendary: list-installed --check-updates is the lightest command that logs in. `status`
    also fetches the whole game library. Login re-uses a session with 10+ minutes left and
    refreshes otherwise; when Epic rejects the refresh, legendary deletes user.json itself.
    gogdl: `auth` with no code renews an expired token and writes it back. On any failure it
    leaves the file as it was, still expired, which is what status.py reads.
    """
    if store == "epic":
        return ["legendary", "list-installed", "--check-updates"]
    if store == "gog":
        return ["gogdl", "--auth-config-path", p["NOVADECK_GOGDL_AUTH"], "auth"]
    raise ValueError(f"unknown store {store!r}")


def disconnect_argv(store, p):
    """The invocation that removes a store's credentials from this device. Local only: neither
    CLI can revoke the session with the store."""
    if store == "epic":
        return ["legendary", "auth", "--delete"]
    if store == "gog":
        # gogdl has no logout. Removed AS the user like every other write here: root unlinking
        # a path inside the user's home would follow a directory the user swapped for a link.
        return ["rm", "-f", "--", p["NOVADECK_GOGDL_AUTH"]]
    raise ValueError(f"unknown store {store!r}")


def _cli_setenv(p):
    """Only what the CLI needs on top of systemd's per-user environment, not root's."""
    env = {"LEGENDARY_CONFIG_PATH": p["LEGENDARY_CONFIG_PATH"],
           "GOGDL_CONFIG_PATH": p["GOGDL_CONFIG_PATH"]}
    lang = _clean_env().get("LANG")
    if lang:
        env["LANG"] = lang
    return env


def _run(p, argv, max_sec):
    """Run argv as the store user. Returns the exit status, for the log only.

    systemd-run itself is resolved from the guest rootfs and runs under FEX, so it gets
    _clean_env: the bundle's LD_LIBRARY_PATH breaks guest binaries (power.py's busctl finding).
    """
    result = subprocess.run(
        _as_user(p["NOVADECK_STORE_USER"], argv, max_sec, _cli_setenv(p)),
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=_clean_env(), timeout=max_sec + CHECK_TIMEOUT,
    )
    return result.returncode


def capture(p, argv, max_sec):
    """Run argv as the store user and return (exit status, stdout).

    Only for output that is DATA — a game list. Never for a call that can print a token: that is
    every auth and refresh call, which go through _run and have their stdout discarded.
    """
    result = subprocess.run(
        _as_user(p["NOVADECK_STORE_USER"], argv, max_sec, _cli_setenv(p)),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        env=_clean_env(), timeout=max_sec + CHECK_TIMEOUT,
    )
    return result.returncode, result.stdout


def start_detached(unit_argv):
    """Start a detached unit built by _as_user(unit=...). systemd-run returns once it is started."""
    return subprocess.run(
        unit_argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, env=_clean_env(), timeout=CHECK_TIMEOUT * 2,
    ).returncode


# Written into the target's directory and renamed over it, AS the user: the rename replaces a
# planted symlink rather than following it, and nothing root-owned lands in the user's tree.
_WRITE_FILE = 'umask 077; cat >"$0.tmp" && mv -f "$0.tmp" "$0"'


def write_as_user(p, path, text):
    """Replace path with text, as the store user. Returns the exit status."""
    return subprocess.run(
        _as_user(p["NOVADECK_STORE_USER"], ["sh", "-c", _WRITE_FILE, path], CHECK_TIMEOUT),
        input=text, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True,
        env=_clean_env(), timeout=CHECK_TIMEOUT * 2,
    ).returncode


def exchange(store, code, p):
    return _run(p, exchange_argv(store, code, p), EXCHANGE_TIMEOUT)


def refresh(store, p):
    return _run(p, refresh_argv(store, p), REFRESH_TIMEOUT)


def disconnect(store, p):
    return _run(p, disconnect_argv(store, p), CHECK_TIMEOUT)


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
