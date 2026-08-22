#!/usr/bin/env python3
# novadeck internal install — PRE-FLIGHT, the spine as a child process, and the progress screen.
# Phase 5 of .claude/plans/internal-install.plan.md.
#
# THE UI DOES NOT INSTALL ANYTHING, and this is the file where that is easiest to break. It runs
# install/novadeck-install and reads its output; every figure it puts on a screen was measured by
# the program that will act on it — select-target.sh for the target, carve.sh `plan` for what the
# carve does to it, device-env for the board. The one time a figure on a consent-adjacent screen
# was derived independently it said "NovaDeck will use the remaining 0 GiB" while the carve handed
# it 90853 MiB (Pocket ACE, 2026-08-21). A second copy of a rule is how the halves drift apart.
import os

from uipad import TOKEN_BACK, TOKEN_QUIT, log

# =================================================================================================
# pre-flight — what is about to happen, while nothing has happened yet
# =================================================================================================
# Every number on this screen is MEASURED, by the same programs the spine will use. The UI does not
# read a partition table and reason about it: select-target.sh says what the target is, carve.sh
# `plan` says what the carve would do to it, device-env says what board this is. That is not
# ceremony -- the one time a figure on a consent-adjacent screen was derived independently, it said
# "NovaDeck will use the remaining 0 GiB" while the carve went on to hand it 90853 MiB (Pocket ACE,
# 2026-08-21). A second copy of a rule is how the two halves drift apart.
DEVICE_ENV = os.environ.get("NOVADECK_DEVICE_ENV", "/usr/lib/novadeck/device-env")
SELECT_TARGET = os.environ.get(
    "NOVADECK_SELECT_TARGET", "/usr/lib/novadeck/install/select-target.sh")
CARVE = os.environ.get("NOVADECK_CARVE", "/usr/lib/novadeck/install/carve.sh")
SPINE = os.environ.get("NOVADECK_SPINE", "/usr/lib/novadeck/install/novadeck-install")
# Phase 6 gives the installer medium a config file for these two; until it exists they are the
# environment, and the pre-flight screen refuses to start an install without them rather than
# inventing a default that would download something nobody asked for.
BUNDLE = os.environ.get("NOVADECK_INSTALL_BUNDLE", "")
HOME_SEED = os.environ.get("NOVADECK_INSTALL_SEED", "")

UD_GIB_DEFAULT = int(os.environ.get("NOVADECK_UD_GIB", "16"))
UD_GIB_MIN = 4          # carve.sh has its own ANDROID_FLOOR_GIB; this is the UI's coarse guard
UD_GIB_STEP = 4


def run_tool(argv, timeout=120):
    """A read-only helper: (rc, output). It never raises — a tool that is missing is a fact."""
    import subprocess

    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, ValueError) as e:
        return 127, str(e)
    except Exception as e:                                   # noqa: BLE001 - timeout, mostly
        return 124, str(e)


def kv(text):
    """
    KEY=VALUE lines, parsed the way the SHELL would parse them.

    Not `.strip("'\\"")`. device-env emits with `printf '%s=%q\\n'`, and bash's %q escapes rather
    than quotes when it can: a board called `AYANEO Pocket S2` arrives as `AYANEO\\ Pocket\\ S2`.
    Stripping quotes leaves the backslash in, and it goes on the panel -- measured on a real Pocket
    S2, 2026-08-22, where the pre-flight title read "Install NovaDeck on AYANEO\\ Pocket\\ S2".
    Every offline stub had emitted the single-quoted form, which is the other thing %q produces.
    """
    import shlex

    out = {}
    for line in text.splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        k, v = line.split("=", 1)
        try:
            # JOINED, not parts[0]. Both producers feed this: device-env emits one %q-escaped token
            # (`AYANEO\ Pocket\ S2`), which shlex returns as a single element -- but netcfg emits
            # plain prose with spaces (`DETAIL=the installer can reach https://...`), which splits
            # into many. Taking the first element rendered that as "the" on a real Pocket S2.
            # Joining handles both; the only loss is a run of consecutive spaces, which no producer
            # here emits and no screen would show.
            parts = shlex.split(v.strip())
        except ValueError:                       # an unbalanced quote (an SSID with an apostrophe)
            parts = [v.strip().strip("'\"")]
        out[k.strip()] = " ".join(parts)
    return out


def disk_facts(dev):
    """Model and size straight out of sysfs. Both are decoration; neither may stop a run."""
    base = os.path.basename(dev)
    facts = {"model": "unknown", "size_gib": "unknown"}
    try:
        with open("/sys/block/%s/device/model" % base) as f:
            facts["model"] = f.read().strip() or "unknown"
    except OSError:
        pass
    try:
        with open("/sys/block/%s/size" % base) as f:
            facts["size_gib"] = str(int(f.read().strip()) * 512 // (1024 ** 3))
    except (OSError, ValueError):
        pass
    return facts


def plan_carve(disk, gib):
    """carve.sh plan — the resulting free space and the list of partitions it will destroy."""
    rc, out = run_tool([CARVE, "plan", disk, str(gib)])
    if rc != 0:
        return {"NOVADECK_GIB": "unknown", "REPLACES_OURS": "unknown", "destroy": [], "error": out}
    fields = kv(out)
    destroy = []
    for line in out.splitlines():
        if line.startswith("DESTROY="):
            parts = line[len("DESTROY="):].split(None, 2)
            if len(parts) == 3:
                destroy.append({"index": parts[0], "name": parts[1], "fate": parts[2]})
    return {
        "NOVADECK_GIB": fields.get("NOVADECK_GIB", "unknown"),
        "REPLACES_OURS": fields.get("REPLACES_OURS", "unknown"),
        "destroy": destroy,
        "error": "",
    }


def gather_preflight():
    """
    Everything the pre-flight screen shows, or None if there is nothing to install onto.

    Returning None is a normal outcome, not a failure: the UI is also started on a machine where the
    spine is being driven over SSH, and there its only job is to render consent when asked.
    """
    rc, out = run_tool([SELECT_TARGET])
    if rc != 0:
        log("no install target (%s); serving consent only" % out.strip().splitlines()[-1:])
        return None
    target = kv(out)
    disk = target.get("TARGET", "")
    if not disk:
        return None
    name = "this device"
    drc, dout = run_tool([DEVICE_ENV])
    if drc == 0:
        name = kv(dout).get("NOVADECK_DEVICE_NAME", name)
    return {
        "device": name,
        "disk": disk,
        "mode": target.get("MODE", "?"),
        "ud_index": target.get("UD_INDEX", "?"),
        "disk_facts": disk_facts(disk),
        "bundle": BUNDLE,
        "seed": HOME_SEED,
    }


# =================================================================================================
# the network screen — §4b's table, and nothing else
# =================================================================================================
# DIAGNOSIS ONLY. There is no SSID picker and no on-screen keyboard: §4b moved credentials to a
# file on the installer's ESP because this device has no keyboard and no guaranteed touchscreen, so
# the only thing a screen can usefully do here is say WHICH failure this is. Each row of §4b's
# table has a different fix, and getting it wrong costs the user a power-off, a card pulled, an
# edit on another computer and a reboot. That price is why "network failed" is not an option.
#
# The words are here and the facts are in install/netcfg, the same split the consent gate uses.
NETCFG = os.environ.get("NOVADECK_NETCFG", "/usr/lib/novadeck/install/netcfg")


def net_diagnose(action="diagnose"):
    """Run install/netcfg and return its key=value output. A failure is itself a diagnosis."""
    rc, out = run_tool([NETCFG, action], timeout=180)
    facts = kv(out)
    if not facts.get("STATE"):
        facts = {"STATE": "netcfg-failed", "DETAIL": out.strip().splitlines()[-1:] and
                 out.strip().splitlines()[-1] or "netcfg produced no diagnosis (rc=%d)" % rc}
    return facts


class NetworkScreen:
    """
    §4b's table, one state at a time, with the SSID quoted back.

    `need-join` is the confirm-before-connecting state, and it is deliberately a plain button press
    rather than the §4d sequence: nothing destructive happens here. Its job is the STALE FILE — a
    card round-tripped through an earlier install names an SSID the user recognises as wrong, and
    they see it before a failed attempt rather than after one.
    """

    name = "network"

    # state -> (title, what happened, what the user does about it)
    TABLE = {
        "no-conf": (
            "No Wi-Fi settings on this card",
            "The installer downloads NovaDeck over the network, and it found no {path} to tell it "
            "which network to join.",
            "On another computer, copy wifi.conf.example next to it and fill in SSID and PSK. Or "
            "plug in a USB-C Ethernet adapter -- that needs no file at all.",
        ),
        "unparsable": (
            "The Wi-Fi settings could not be read",
            "{path} exists, but {where}.",
            "Edit it on another computer. Each line is SSID=... or PSK=..., and anything else is "
            "a comment starting with #.",
        ),
        "not-found": (
            "'{ssid}' was not found",
            "The installer scanned for the network named in the settings on this card and did not "
            "see it.",
            "Check the name for a typo -- it is case-sensitive. A 5 GHz-only access point may "
            "simply be out of range.",
        ),
        "auth-failed": (
            "'{ssid}' rejected the password",
            "The network is there and the installer reached it, but the key on this card was not "
            "accepted.",
            "Correct PSK= on another computer. Nothing else about the card needs changing.",
        ),
        "no-lease": (
            "'{ssid}' gave out no address",
            "The installer joined the network, and then waited for an address that never arrived.",
            "This is the access point, not the installer -- its DHCP is not answering. Try another "
            "network, or a USB-C Ethernet adapter.",
        ),
        "no-host": (
            "Connected, but the update server is unreachable",
            "This device has an address, and {url} does not answer.",
            "This is upstream or DNS, not the installer. Check the connection on another device on "
            "the same network.",
        ),
        "netcfg-failed": (
            "The network could not be checked",
            "The installer's own network helper did not answer: {detail}",
            "Report this. The installer will not continue without knowing the network is up.",
        ),
    }

    def __init__(self, facts):
        self.facts = facts
        self.result = None      # ("join",) | ("retry",) | ("continue",) | ("quit",)

    def state(self):
        return self.facts.get("STATE", "netcfg-failed")

    def handle(self, token):
        if token in (TOKEN_BACK, TOKEN_QUIT):
            # SELECT is labelled Cancel while a join is being offered and Power off once something
            # has failed. The result has to say which, or the button lies about what it does.
            self.result = ("quit",) if self.state() == "need-join" else ("poweroff",)
        elif token == "S":
            st = self.state()
            self.result = ("join",) if st == "need-join" else \
                          ("continue",) if st == "online" else ("retry",)

    def describe(self):
        f, st = self.facts, self.state()
        ssid = f.get("SSID", "?")
        if st == "online":
            blocks = [("Network is up", f.get("DETAIL", "The installer can reach the update "
                                                        "server."))]
            title, buttons = "Connected", [{"pos": "S", "label": "Continue"}]
        elif st == "need-join":
            title = "Join '%s'?" % ssid
            blocks = [
                ("The settings on this card name this network",
                 "The installer will connect to '%s' using the password stored on the card. The "
                 "password itself is never shown." % ssid),
                ("If that is not your network",
                 "Cancel, power off, and edit novadeck/wifi.conf on another computer. A card used "
                 "for an earlier install can still be carrying its old network."),
            ]
            buttons = [{"pos": "S", "label": "Join"}, {"pos": "SELECT", "label": "Cancel"}]
        else:
            title, what, fix = self.TABLE.get(st, self.TABLE["netcfg-failed"])
            where = "it names no network" if f.get("LINE") == "0" \
                else "line %s is not something it understands" % f.get("LINE", "?")
            fmt = {"ssid": ssid, "path": f.get("PATH_", "the settings file"),
                   "url": f.get("URL", "the update server"), "where": where,
                   "detail": f.get("DETAIL", "no reason given")}
            title = title.format(**fmt)
            blocks = [("What happened", what.format(**fmt)), ("What to do", fix.format(**fmt))]
            buttons = [{"pos": "S", "label": "Check again"}, {"pos": "SELECT", "label": "Power off"}]
        return {
            "screen": "network",
            "state": st,
            "title": title,
            "blocks": blocks,
            "diamonds": [],
            "prompt": "",
            "note": "Nothing has been written to this device.",
            "buttons": buttons,
            "abort": "",
        }


class PreflightScreen:
    """
    The last screen before the consent gate, and the only one with a knob on it.

    LEFT/RIGHT adjust what Android keeps -- §5 says adjusted, never typed, because there is no text
    entry anywhere in this UI. Every adjustment re-asks carve.sh, so the figure next to it is always
    the one that carve would produce for that choice rather than an interpolation.
    """

    name = "preflight"

    def __init__(self, facts, gib=UD_GIB_DEFAULT):
        self.facts = facts
        self.gib = gib
        self.plan = plan_carve(facts["disk"], gib)
        self.result = None      # ("start", gib) | ("quit",)

    def _replan(self, gib):
        if gib < UD_GIB_MIN:
            return
        self.gib = gib
        self.plan = plan_carve(self.facts["disk"], gib)

    def handle(self, token):
        if token == "LEFT":
            self._replan(self.gib - UD_GIB_STEP)
        elif token == "RIGHT":
            self._replan(self.gib + UD_GIB_STEP)
        elif token == "S":
            # Nothing is written by pressing this. It starts the spine, which recons, verifies the
            # bundle and THEN takes consent -- the disk is still untouched on the other side of it.
            if self.ready():
                self.result = ("start", self.gib)
        elif token in (TOKEN_BACK, TOKEN_QUIT):
            self.result = ("quit",)

    def ready(self):
        return bool(self.facts.get("bundle")) and bool(self.facts.get("seed"))

    def describe(self):
        f, d = self.facts, self.facts["disk_facts"]
        destroy = self.plan["destroy"]
        if destroy:
            lost = "\n".join(
                "p%s  %s  (%s)" % (x["index"], x["name"], x["fate"].replace("-", " "))
                for x in destroy)
        else:
            lost = "carve.sh could not be asked what it would destroy -- do not continue."
        blocks = [
            ("Target", "%s  %s  %s GiB" % (f["disk"], d["model"], d["size_gib"])),
            ("Android keeps", "%s GiB   (left / right to change)" % self.gib),
            ("NovaDeck gets", "%s GiB" % self.plan["NOVADECK_GIB"]),
            ("These partitions will be destroyed", lost),
            ("To install", f["bundle"] or "NO BUNDLE CONFIGURED -- this installer cannot continue."),
        ]
        return {
            "screen": "preflight",
            "title": "Install NovaDeck on %s" % f["device"],
            "blocks": blocks,
            "diamonds": [],
            "prompt": "",
            "note": "Nothing has been written yet, and nothing will be until you confirm.",
            "buttons": ([{"pos": "S", "label": "Continue"}] if self.ready() else [])
            + [{"pos": "SELECT", "label": "Cancel"}],
            "abort": "",
        }


# =================================================================================================
# the install itself — the spine as a subprocess, and the bar over it
# =================================================================================================
# THE UI DOES NOT INSTALL ANYTHING. It runs install/novadeck-install and reads its output, which is
# what keeps the orchestrator the testable spine and this a view. Two things come back on that pipe:
#
#   [novadeck-install] == <step> ==     the step markers the spine already prints
#          NN% <message>                rauc's own progress, printed by `rauc install`
#
# The plan said to reuse novadeck-update's D-Bus subscription for the second one. That is the right
# call THERE, where the client talks to the system rauc; it is the wrong one here, because the rauc
# the spine drives lives on the PRIVATE system bus rauc-session.sh starts for the occasion, and the
# UI would have to find that bus to subscribe to it. Reading the percentage off the pipe we already
# hold gets the same number from the same source with no second bus client in the installer.
STEP_RE = r"^\[[^]]+\] == (.+) ==\s*$"
PERCENT_RE = r"^\s*(\d{1,3})%\s+(.*)$"

# The spine's steps, in the order it prints them, with what to call them on a panel. `/home (kept)`
# is the reinstall path's name for the same phase and is folded in.
PHASES = [
    ("recon", "Reading the disk"),
    ("select-target", "Choosing the target"),
    ("install record", "Writing the install record"),
    ("verify sources", "Verifying the download"),
    ("CONFIRM", "Waiting for you"),
    ("carve", "Repartitioning"),
    ("filesystems", "Creating filesystems"),
    ("root slot", "Installing NovaDeck"),
    ("/home", "Setting up /home"),
    ("efi-a / efi-b", "Writing the boot slots"),
    ("ESP", "Writing the boot partition"),
    ("done", "Done"),
]
PHASE_ALIAS = {"/home (kept)": "/home"}


class SpineRun:
    """install/novadeck-install as a child process, read without blocking the frame."""

    def __init__(self, gib, sock_path, intent=None):
        import subprocess

        env = dict(os.environ)
        # THE SPINE MUST ASK US FOR CONSENT. $CONFIRM names who renders; pointing it at our shim is
        # what puts the gate on this screen instead of on a terminal nobody is looking at.
        env["NOVADECK_CONFIRM"] = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "confirm-ui")
        env["NOVADECK_UI_SOCK"] = sock_path
        argv = [SPINE, "--bundle", BUNDLE, "--home-seed", HOME_SEED, "--userdata-gib", str(gib)]
        if intent:
            argv += ["--intent", intent]
        log("starting the spine: %s" % " ".join(argv))
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, bufsize=0)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.buf = b""
        self.tail = []          # the last few lines, for the failure text

    def poll(self):
        """Whatever whole lines are available right now. Never blocks."""
        try:
            chunk = self.proc.stdout.read()
        except (BlockingIOError, ValueError):
            chunk = None
        if chunk:
            self.buf += chunk
        lines = []
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            text = line.decode("utf-8", "replace").rstrip()
            if text:
                lines.append(text)
                self.tail = (self.tail + [text])[-12:]
        return lines

    def returncode(self):
        return self.proc.poll()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()


class ProgressScreen:
    """A bar per phase, and the one honest sentence a failure owes the user."""

    name = "progress"

    def __init__(self, run):
        self.run = run
        self.phase = None
        self.percent = None
        self.message = ""
        self.rc = None
        self.reached_carve = False      # i.e. whether the disk has been modified
        self.result = None              # ("quit",)

    def feed(self, line):
        import re

        m = re.match(STEP_RE, line)
        if m:
            step = PHASE_ALIAS.get(m.group(1), m.group(1))
            if any(step == p for p, _ in PHASES):
                self.phase = step
                self.percent = None
                if step == "carve":
                    self.reached_carve = True
            return
        m = re.match(PERCENT_RE, line)
        if m:
            self.percent = int(m.group(1))
            self.message = m.group(2)

    def handle(self, token):
        if self.rc is None:
            return
        # A finished install offers one button and it says Power off -- §5, "Remove the SD card,
        # then power the device off". A FAILED one offers Continue, because the user still has a
        # log to read and a device that may need re-running.
        self.result = ("poweroff",) if self.rc == 0 else ("quit",)

    def finish(self, rc):
        self.rc = rc

    def describe(self):
        rows = []
        seen_current = False
        for step, label in PHASES:
            if step == self.phase:
                state, seen_current = "active", True
            elif seen_current:
                state = "pending"
            else:
                state = "done" if self.phase else "pending"
            rows.append({
                "label": label,
                "state": state,
                "percent": self.percent if state == "active" else None,
            })
        blocks = [("", r["label"] + ("  %d%%" % r["percent"] if r["percent"] is not None else ""))
                  for r in rows if r["state"] != "pending"]
        title = "Installing NovaDeck"
        note = "Do not power the device off."
        buttons = []
        if self.rc == 0:
            title = "NovaDeck is installed"
            note = "Remove the SD card, then power the device off."
            buttons = [{"pos": "S", "label": "Power off"}]
        elif self.rc is not None:
            title = "The install did not finish"
            # THE ONE THING A FAILURE OWES THE USER: which of two states the device is in. "It
            # failed" is not actionable; "nothing was written" and "the disk was modified" are
            # different situations and only one of them needs anything done about it.
            note = ("The disk WAS modified. Re-run the installer; Android's data is already gone."
                    if self.reached_carve else
                    "Nothing was written. The device is exactly as it was.")
            buttons = [{"pos": "S", "label": "Continue"}]
            blocks = blocks + [("What happened", "\n".join(self.run.tail[-6:]))]
        return {
            "screen": "progress",
            "title": title,
            "blocks": blocks,
            "rows": rows,
            "diamonds": [],
            "prompt": "",
            "note": note,
            "buttons": buttons,
            "abort": "",
        }
