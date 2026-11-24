"""Run something as the session user: Moonlight and the file it keeps are theirs, and nothing on this
side of the plugin needs root.

setpriv, not runuser: it execs, so the process here IS the command and stopping it stops the command.
env -i: PluginLoader is a PyInstaller bundle whose LD_LIBRARY_PATH breaks system binaries.
"""
import os
import pwd

USER = "deck"


def account():
    return pwd.getpwnam(USER)


def prefix():
    user = account()
    return ["/usr/bin/setpriv", f"--reuid={user.pw_uid}", f"--regid={user.pw_gid}", "--init-groups", "--no-new-privs",
            "--inh-caps=-all", "--bounding-set=-all", "/usr/bin/env", "-i", f"HOME={user.pw_dir}", f"USER={USER}",
            "PATH=/usr/bin", "LANG=C.UTF-8", f"XDG_RUNTIME_DIR=/run/user/{user.pw_uid}"]


def config(name):
    return os.path.join(account().pw_dir, ".config", "novadeck", name)
