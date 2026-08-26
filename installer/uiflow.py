#!/usr/bin/env python3
# novadeck internal install — PRE-FLIGHT, the spine as a child process, and the progress screen.
# Phase 5 of .claude/plans/internal-install.plan.md.
#
# THE UI DOES NOT INSTALL ANYTHING, and this is the file where that is easiest to break. It runs
# installer/novadeck-install and reads its output; every figure it puts on a screen was measured by
# the program that will act on it — select-target.sh for the target, carve.sh `plan` for what the
# carve does to it, device-env for the board. The one time a figure on a consent-adjacent screen
# was derived independently it said "NovaDeck will use the remaining 0 GiB" while the carve handed
# it 90853 MiB (Pocket ACE, 2026-08-21). A second copy of a rule is how the halves drift apart.
import os
import time

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
VERIFY_INSTALL = os.environ.get(
    "NOVADECK_VERIFY_INSTALL", "/usr/lib/novadeck/install/verify-install.sh")
# WHERE THE BYTES COME FROM, and the two halves arrive differently on purpose. The OS bundle is
# resolved from the update channel at install time by installer/release-info, so any medium installs
# the current release. The Steam seed /home is built from is CARRIED BY THE MEDIUM -- 1.4 GiB staged
# into this root by installer/mkimage.sh, with its sha256 beside it -- because a medium is bound to one
# seed whichever way it arrives, and fetching it only added a publisher, a pin handed between CI jobs
# and 1.7 GB of tmpfs taken while rauc streams the bundle.
#
# Both remain overridable, for the hardware stager (installer/hw-install.sh serves a bundle off a
# laptop and points the seed at a path on the card) and for the suite.
RELEASE_INFO = os.environ.get("NOVADECK_RELEASE_INFO", "/usr/lib/novadeck/install/release-info")
# A seam like every other path here, so tests/test-ui.sh can exercise both "the medium
# carries one" and "it does not" without a /usr/lib to write into.
SEED_ON_MEDIUM = os.environ.get(
    "NOVADECK_SEED_ON_MEDIUM", "/usr/lib/novadeck/install/steam-seed.tar.zst")
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


_RELEASE = None     # a resolved release, cached. A FAILURE IS NEVER CACHED, so Check again re-asks.


def resolve_release():
    """
    {bundle, seed, state, detail} -- what this medium would install, or why it cannot.

    THE FACTS BELONG TO release-info AND THE WORDS TO THE SCREEN, the same split as netcfg. All this
    does is prefer the environment over the server, per source rather than as a pair: the hardware
    stager serves a bundle off a laptop and hands the seed over as a local path (~1 GB that must not
    be re-fetched into tmpfs at every reboot), so the two arrive from different places there and
    an all-or-nothing override would make that run ask the server for a seed it already has.

    Only a resolved release is remembered. Every failure here is one a person can act on -- the
    server was not up yet, the channel had nothing published, DNS was still settling -- and a cached
    "no" would make the Check again button on the pre-flight screen a button that redraws itself.
    """
    global _RELEASE
    # THE SEED IS A FILE ON THIS MEDIUM, and a missing one is a fact worth a screen rather than a
    # spine that dies at verify_sources with the disk untouched but nothing on the panel to explain
    # it. mkimage refuses to build a medium without one, so this only fires for a hand-assembled
    # tree -- which is exactly when a plain answer is worth most.
    seed = HOME_SEED or (SEED_ON_MEDIUM if os.path.exists(SEED_ON_MEDIUM) else "")
    if BUNDLE and seed:
        return {"bundle": BUNDLE, "seed": seed, "state": "ok", "detail": ""}
    if _RELEASE is not None:
        return _RELEASE
    # SYNCHRONOUS, and bounded so it can stay that way. This blocks the frame like every other tool
    # the pre-flight gathers from (select-target.sh, carve.sh), and it is reached only after netcfg
    # has already pronounced the same host reachable within its own 20s -- so the fetch is a few
    # hundred bytes over a connection just proven to work. `netcfg join` is a child process instead
    # because it waits on an access point for up to 90s, which is a frozen panel and looks like a
    # dead device (HW 2026-08-24). Keep this the short one, or it earns the same treatment.
    rc, out = run_tool([RELEASE_INFO], timeout=45)
    facts = kv(out)
    state = facts.get("STATE", "")
    if not state:
        # release-info always prints a STATE, so no STATE means it did not run: a medium that
        # shipped without it, or a python that could not start. HW 2026-08-24 taught this shape
        # once already, with lib-gpt.sh -- a tool that is missing must not read as an answer.
        state, facts = "no-tool", {
            "DETAIL": "the installer's own release helper did not answer: %s"
                      % ((out.strip().splitlines() or ["it produced nothing (rc=%d)" % rc])[-1])}
    if state == "ok" and not seed:
        # The bundle resolved and the medium has no Steam tree: say which half is missing, since the
        # screen would otherwise show a perfectly good release next to a Continue that never appears.
        state = "no-seed"
        facts = {"DETAIL": "this medium carries no Steam seed (no %s) -- it cannot build /home"
                           % SEED_ON_MEDIUM}
    release = {
        "bundle": BUNDLE or facts.get("BUNDLE", ""),
        "seed": seed,
        "state": state,
        "detail": facts.get("DETAIL", ""),
    }
    log("release: %s (%s)" % (state, release["detail"] or "no detail"))
    if release["bundle"] and release["seed"]:
        _RELEASE = release
    return release


def gather_preflight():
    """
    (facts, reason) -- facts for the pre-flight screen, or None with the reason there are none.

    THE REASON IS RETURNED, NOT JUST LOGGED, and that is the whole point of the second element.
    This used to return a bare None for every no-target outcome, so the panel fell back to a screen
    saying "Waiting for the installer." and nothing else. That reads as correct in exactly one
    situation -- the UI running as a consent renderer for a spine driven over SSH -- and it was
    silently swallowing two others that look nothing like it: a device that genuinely has no target
    (booted from internal, rule 1), and select-target.sh failing to RUN at all.

    HW-FOUND 2026-08-24: the medium shipped without lib-gpt.sh, select-target.sh died with
    "cannot find lib-gpt.sh", and the operator got "Waiting for the installer." forever with no clue
    that anything had gone wrong. A person holding the device could not tell a broken build from a
    disk this installer refuses to touch. Whatever the caller does with it, the reason has to reach
    the screen.
    """
    rc, out = run_tool([SELECT_TARGET])
    if rc != 0:
        # KEEP THE REASONS, NOT THE SUMMARY. select-target.sh prints one INDENTED line per disk
        # explaining why that disk was rejected, then ends with "no disk qualifies -- see the
        # reasons above". Taking splitlines()[-1] kept only the summary, so the panel told the
        # operator to look above it -- on a screen with no above. HW 2026-08-24, Pocket FIT: rule 3b
        # correctly refused a disk carrying ROCKNIX and said so in as many words ("partition 12
        # (ROCKNIX) is a bootable ESP that is not ours -- remove the other OS first"), and that
        # sentence was the one thrown away.
        lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
        detail = [ln for ln in lines if ln.startswith(("/dev/", "  /dev/"))] or \
                 [ln for ln in lines if ln.startswith("/dev/")]
        # The indented per-disk lines are the answer; fall back to everything, then to the summary,
        # so a message shape we did not anticipate still reaches the screen instead of vanishing.
        reason = "\n".join(detail) if detail else ("\n".join(lines[-3:]) if lines
                                                   else "select-target.sh failed with no output")
        log("no install target (%s); serving consent only" % reason.replace("\n", " | "))
        return None, reason
    target = kv(out)
    disk = target.get("TARGET", "")
    if not disk:
        return None, "select-target.sh named no disk"
    name = "this device"
    drc, dout = run_tool([DEVICE_ENV])
    if drc == 0:
        name = kv(dout).get("NOVADECK_DEVICE_NAME", name)
    facts = {
        "device": name,
        "disk": disk,
        "mode": target.get("MODE", "?"),
        "ud_index": target.get("UD_INDEX", "?"),
        "disk_facts": disk_facts(disk),
    }
    facts.update(release_facts())
    return facts, ""


def release_facts():
    """The three keys the pre-flight screen reads about the download, as a fresh dict."""
    r = resolve_release()
    return {"bundle": r["bundle"], "seed": r["seed"],
            "release": r["state"], "release_detail": r["detail"]}


# =================================================================================================
# the network screen — §4b's table, and nothing else
# =================================================================================================
# DIAGNOSIS ONLY. There is no SSID picker and no on-screen keyboard: §4b moved credentials to a
# file on the installer's ESP because this device has no keyboard and no guaranteed touchscreen, so
# the only thing a screen can usefully do here is say WHICH failure this is. Each row of §4b's
# table has a different fix, and getting it wrong costs the user a power-off, a card pulled, an
# edit on another computer and a reboot. That price is why "network failed" is not an option.
#
# The words are here and the facts are in installer/netcfg, the same split the consent gate uses.
NETCFG = os.environ.get("NOVADECK_NETCFG", "/usr/lib/novadeck/install/netcfg")


def net_diagnose(action="diagnose"):
    """Run installer/netcfg and return its key=value output. A failure is itself a diagnosis."""
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
        # THE STEPS ARE NUMBERED AND THE FILE IS REALLY THERE. This said "copy wifi.conf.example
        # next to it", and until 2026-08-24 no such file existed anywhere -- not in the tree, not on
        # any medium. Instructions naming a file that is not there read as a fault in the person
        # following them. installer/mkimage.sh now writes it to /novadeck/ on the medium's boot
        # partition, which is typed 0700 precisely so Windows and macOS will show it.
        "no-conf": (
            "No Wi-Fi settings on this card",
            "The installer downloads NovaDeck over the network, and it found no {path} telling it "
            "which network to join.",
            "Power off and take the card out. On another computer, open the NDINSTALLER volume and "
            "look in the novadeck folder: copy wifi.conf.example to a file named wifi.conf, open "
            "the copy, and put your network name and password in it. Put the card back and switch "
            "on. Or plug in a USB-C Ethernet adapter -- that needs no file at all.",
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
        # CONFIGURED BUT NOT YET JOINED. Self-clearing, like no-clock. have_lease is false for the
        # whole association window, so before this row existed everything in that window fell
        # through to `no-conf` and told the operator to go and write a file on another computer
        # while the radio was mid-handshake -- and on a TEST medium, whose network is a baked NM
        # profile with no wifi.conf at all, that was every cold boot rather than a corner case.
        "associating": (
            "Joining the network",
            "{detail}. This device asks the access point for an address, and that takes a few "
            "seconds after the radio associates.",
            "Nothing to fix. It moves on by itself as soon as an address arrives.",
        ),
        # THE ONLY ROW WHOSE FIX IS TO DO NOTHING. These boards have no clock battery -- the PMIC
        # RTC probe defers forever (issue #38) -- so on every cold boot the clock starts at the
        # epoch and OpenSSL rejects every certificate as not-yet-valid until systemd-timesyncd has
        # synced. HW 2026-08-24: this surfaced as "the update server is unreachable", which is a row
        # that sends the operator to check their router, and it is neither their router nor the
        # server. It clears itself within a few seconds of joining a network.
        "no-clock": (
            "Waiting for the time to be set",
            "This device has no clock battery, so it does not know the date until the network tells "
            "it -- {detail}. Until then every secure connection looks expired, including {url}.",
            "Nothing to fix. Give it a few seconds and press Check again; it sets itself as soon as "
            "the network answers.",
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

    # STATES WITH NOTHING FOR A RETRY TO DO. HW 2026-08-24, on the first release medium to reach
    # this screen: `no-conf` offered "Check again", and it cannot succeed. The card is inside the
    # device, so nobody can write wifi.conf to it while it is running -- the only remedies are to
    # power off, write the file on another computer and boot again, or to plug in USB-C Ethernet,
    # which the periodic re-probe now notices by itself. So the button pointed at the one thing that
    # could not help, gave no feedback when pressed (the state is unchanged, so the screen redraws
    # identically), and sat where the eye looks first, while "Power off" -- the action the advice
    # text actually asks for -- was the secondary.
    #
    # SELECT keeps Power off. Nothing replaces the South button: an installer that offers no action
    # is telling the truth about a state that needs the operator to go and do something elsewhere.
    NO_RETRY = ("no-conf",)

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
            if st in self.NO_RETRY:
                return          # no button is drawn for it, so nothing may act on the press either
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
            buttons = [{"pos": "SELECT", "label": "Power off"}] if st in self.NO_RETRY else \
                      [{"pos": "S", "label": "Check again"}, {"pos": "SELECT", "label": "Power off"}]
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

    # A RELEASE FAILURE A RE-ASK CANNOT CURE. Same reasoning as the network screen's NO_RETRY, and
    # it comes from the same finding: a button that cannot succeed, sitting where the eye looks
    # first, is worse than no button (HW 2026-08-24). `no-pin` is a property of how this medium was
    # BUILT: the Steam tree it would build /home from is not on it, and no amount of asking the
    # update server again will put it there. The screen says so instead of offering to try.
    NO_RETRY = ("no-seed",)

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
            elif self.facts.get("release") not in self.NO_RETRY:
                # The disk is already known; it is the download that is not. Ask again for that
                # alone -- and keep the size the operator chose, which is why this is a result the
                # loop acts on rather than a fresh screen built here.
                self.result = ("recheck",)
        elif token in (TOKEN_BACK, TOKEN_QUIT):
            self.result = ("quit",)

    def ready(self):
        return bool(self.facts.get("bundle")) and bool(self.facts.get("seed"))

    def to_install(self):
        """
        What is about to be downloaded, or WHY THERE IS NOTHING TO DOWNLOAD.

        This block used to be the bundle URL or the words "NO BUNDLE CONFIGURED", which named the
        symptom and no cause: an unreachable server, a channel with nothing published, a manifest
        that did not parse and a medium built with no seed pin all produced the same four words on
        the same dead-end screen. release-info knows which it is and says so in one line
        ([[screens-must-say-what-the-code-knows]]), so this passes that line through rather than
        writing a fifth version of it here.
        """
        f = self.facts
        if self.ready():
            return f.get("release_detail") or f["bundle"]
        detail = f.get("release_detail")
        if detail:
            return detail
        return ("This installer has not been told what to install, and cannot continue."
                if f.get("release") else
                "The download has not been worked out yet -- press Check again.")

    def describe(self):
        f, d = self.facts, self.facts["disk_facts"]
        destroy = self.plan["destroy"]
        # ONE LINE PER PARTITION DOES NOT FIT, and this screen is the one that must. HW 2026-08-25,
        # Pocket ACE with NovaDeck already installed: eight partitions at one line each, under a
        # heading, above four more blocks, ran off the bottom of the panel and collided with the
        # SELECT row -- worse after the type scale went up, which it did because these screens were
        # too small to read.
        #
        # NOTHING IS ELIDED TO ACHIEVE IT. This is the list a person consents to losing; "and 4
        # more" is not a thing a consent screen may say. When every partition shares one fate --
        # which is exactly the eight-of-ours case -- the fate is stated ONCE in the heading and the
        # names run together as prose the wrapper can break, so eight lines become two and every
        # index and name is still on the panel. Mixed fates stay one per line, because there the
        # fate is the information and the list is short anyway.
        lost_head = "These partitions will be destroyed"
        if not destroy:
            lost = "carve.sh could not be asked what it would destroy -- do not continue."
        else:
            # ONE LINE PER FATE, NOT PER PARTITION. carve.sh emits `userdata data-erased` and then
            # one `replaced` per partition of ours that exists, so a reinstall is nine lines under
            # a heading with four blocks below it -- which ran off the panel and collided with the
            # SELECT row on a Pocket ACE (HW 2026-08-25).
            #
            # GROUPING, NOT A SINGLE-FATE SPECIAL CASE. The first attempt at this compacted only
            # when every fate matched, and no real disk produces that: userdata is always in the
            # list with a fate of its own, so the branch could not fire on hardware and the screen
            # was unchanged. Grouping has no such condition -- it is the same code path for one
            # fate or five, which is why it cannot quietly not happen.
            order, groups = [], {}
            for x in destroy:
                fate = x["fate"].replace("-", " ")
                if fate not in groups:
                    groups[fate] = []
                    order.append(fate)
                groups[fate].append("p%s %s" % (x["index"], x["name"]))
            lost_head = "These %d partitions will be destroyed" % len(destroy)
            # Every index and name still reaches the panel: this is the list a person consents to
            # losing, so it is compacted, never shortened. The wrapper breaks the long group.
            lost = "\n".join("%s:  %s" % (fate, ",  ".join(groups[fate])) for fate in order)
        # WHAT KIND OF INSTALL THIS IS, said before anything else. HW 2026-08-24, Pocket ACE with
        # NovaDeck already on its internal disk: the screen listed our own eight partitions in the
        # destroy list and never said the word reinstall, so nothing on it distinguished "install
        # alongside Android" from "replace the NovaDeck that is already here". The mode was in the
        # facts the whole time and simply was not drawn.
        #
        # AND THE PLAN REALLY IS A FRESH CARVE. select-target.sh reports MODE=reinstall when our
        # eight are present, but plan_carve() calls `carve.sh plan`, and carve.sh handles `plan` in
        # the same branch as `fresh` -- so what is being described, and what pressing through would
        # do, destroys /home. The `reinstall` mode that keeps /home is not reachable from this UI at
        # all. Saying so is the honest thing until it is: the operator is not choosing wrong, the
        # choice does not exist yet.
        if f.get("mode") == "reinstall":
            blocks = [
                ("This device already has NovaDeck",
                 "Everything currently installed will be erased and replaced, INCLUDING /home -- "
                 "your games, saves and settings. This installer cannot yet repair an existing "
                 "install while keeping them; it only does a full replacement."),
            ]
        else:
            blocks = [
                ("This device is running Android",
                 "NovaDeck will be installed alongside it. Android keeps the space you choose "
                 "below, and everything else on that partition is erased."),
            ]
        blocks += [
            ("Target", "%s  %s  %s GiB" % (f["disk"], d["model"], d["size_gib"])),
            ("Android keeps", "%s GiB   (left / right to change)" % self.gib),
            ("NovaDeck gets", "%s GiB" % self.plan["NOVADECK_GIB"]),
            (lost_head, lost),
            ("To install", self.to_install()),
        ]
        return {
            "screen": "preflight",
            # The title carries it too: the first block explains, but a person glancing at the panel
            # reads the heading, and "Install" and "Replace" are different promises.
            "title": ("Replace the NovaDeck on %s" if f.get("mode") == "reinstall"
                      else "Install NovaDeck on %s") % f["device"],
            "blocks": blocks,
            "diamonds": [],
            "prompt": "",
            "note": "Nothing has been written yet, and nothing will be until you confirm.",
            "buttons": ([{"pos": "S", "label": "Continue"}] if self.ready() else
                        [] if f.get("release") in self.NO_RETRY else
                        [{"pos": "S", "label": "Check again"}])
            + [{"pos": "SELECT", "label": "Cancel"}],
            "abort": "",
        }


# =================================================================================================
# the install itself — the spine as a subprocess, and the bar over it
# =================================================================================================
# THE UI DOES NOT INSTALL ANYTHING. It runs installer/novadeck-install and reads its output, which is
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


class NetJoin:
    """
    netcfg join as a child process, so the frame keeps drawing while nmcli works.

    It was a synchronous run_tool with a 180s timeout, which did not merely fail to acknowledge the
    press -- it blocked the whole UI loop, so nothing redrew and a slow access point made the device
    look dead. HW 2026-08-24.
    """

    def __init__(self):
        import subprocess

        log("joining the network")
        self.proc = subprocess.Popen(
            [NETCFG, "join"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.chunks = []
        self.started = time.monotonic()

    def _drain(self):
        try:
            d = self.proc.stdout.read()
            if d:
                self.chunks.append(d)
        except (BlockingIOError, ValueError, OSError):
            pass

    def attempt(self):
        """
        Which activation netcfg is on, read from the output it has produced SO FAR.

        netcfg emits ATTEMPT= before each try, and this is drained mid-flight rather than at the end,
        which is the whole point: a second activation must be something the connecting screen can
        say while it is happening. A join that has printed nothing yet is attempt 1.
        """
        self._drain()
        out = b"".join(self.chunks).decode("utf-8", "replace")
        n = 1
        for line in out.splitlines():
            if line.startswith("ATTEMPT="):
                try:
                    n = int(line.split("=", 1)[1].strip())
                except ValueError:
                    pass
        return n

    def poll(self):
        """The diagnosis once the join has finished, or None while it is still running."""
        self._drain()
        if self.proc.poll() is None:
            return None
        self._drain()
        out = b"".join(self.chunks).decode("utf-8", "replace")
        facts = kv(out)
        if not facts.get("STATE"):
            last = (out.strip().splitlines() or ["netcfg produced no diagnosis"])[-1]
            facts = {"STATE": "netcfg-failed", "DETAIL": last}
        log("join finished after %.1fs: %s  (%s)" % (
            time.monotonic() - self.started, facts.get("STATE"), facts.get("DETAIL", "")))
        # EVERYTHING THE CHILD SAID, NOT JUST THE FACTS IT EMITTED. netcfg logs how long nmcli took
        # and whether it returned OK or failed -- the two lines that separate "we judged the lease
        # too early" from "nmcli failed in a shape neither error grep catches" -- and it writes them
        # to STDERR. This class captures stderr into stdout so the frame can keep drawing, so those
        # lines land in this buffer and went NOWHERE: kv() keeps the key=value lines and the prose
        # was dropped on the floor whenever STATE parsed. HW 2026-08-25, an installer log that could
        # not answer the question the instrumentation had been added for a day earlier.
        #
        # Re-emitting is safe BECAUSE netcfg guarantees it: "THE PSK IS NEVER PRINTED, not even in a
        # debug line". This is the loop that would publish it to the journal and the ESP if that
        # ever stopped being true, so it is the loop that has to keep naming the guarantee.
        for line in out.splitlines():
            line = line.strip()
            if line and "=" not in line.split(" ", 1)[0]:
                log("  netcfg: %s" % line)
        return facts


class ConnectingScreen:
    """Shown the instant Join is pressed, so the press is visibly registered."""

    name = "connecting"
    interactive = False          # it asks for nothing, so a scripted source spends no press on it

    def __init__(self, ssid, attempt=None):
        self.ssid = ssid or "the network"
        self.started = time.monotonic()
        # A callable, not a number: the attempt changes WHILE this screen is up, and a screen that
        # took a copy at construction would keep claiming the first one through the second.
        self.attempt = attempt or (lambda: 1)

    def handle(self, token):
        pass

    def describe(self):
        # Animated from elapsed time rather than a frame counter, so it moves at the same rate
        # whatever the panel is doing.
        dots = "." * (1 + int((time.monotonic() - self.started) * 2) % 3)
        # THE SECOND ACTIVATION IS SAID OUT LOUD. netcfg re-activates once when the first join lands
        # without an address (HW 2026-08-25), and an operator watching an unexplained wait get twice
        # as long is exactly who this screen exists for -- silence here would undo the reason the
        # join was made asynchronous in the first place.
        try:
            n = self.attempt()
        except Exception:                                          # noqa: BLE001 - never a screen
            n = 1
        second = [("", "The first attempt joined without being given an address. Trying once "
                       "more -- this is the attempt that usually succeeds.")] if n > 1 else []
        return {
            "screen": "connecting",
            "title": "Connecting to '%s'" % self.ssid,
            "blocks": [("", "Joining the network, then asking it for an address%s" % dots)] + second
                      + [("", "Usually a few seconds. Some access points take up to a minute to "
                              "hand out an address.")],
            "diamonds": [],
            "prompt": "",
            "note": "",
            "abort": "",
        }


class ChildLines:
    """
    Whole lines from a child's merged stdout/stderr, without ever blocking the frame.

    Shared by SpineRun and VerifyRun because they read the same way and only differ in what they
    launch. Subclasses set `self.proc` (non-blocking stdout) and call `_init_lines()`.
    """

    def _init_lines(self):
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


class VerifyRun(ChildLines):
    """
    installer/verify-install.sh as a child, run by the UI once the spine reports success.

    THE UI RUNS IT, NOT THE SPINE, and that is the whole point. verify-install.sh exists as a
    separate program because "the spine writes; this reads -- an installer that graded its own work
    would share the bug with its grader", so folding it into the spine's success path would undo
    the reason it is a separate file. Running it from here keeps the two judgements apart while
    still getting the answer in front of the operator.

    IT HAD NO CALLER AT ALL UNTIL NOW (#66). The script's own header says to run it "after the
    install and BEFORE the card comes out, while there is still a shell that can fix things" -- and
    a release medium has no shell: no sshd, no Wi-Fi, and a session whose only client is this UI.
    So the tool shipped on every medium and nothing could ever invoke it. Confirmed by the first
    end-to-end install (Pocket ACE, 2026-08-25): zero mentions in the whole ESP log.

    The disk is PASSED, never discovered. verify-install.sh can find the installed disk itself, but
    we already know which one the spine just wrote -- and asking it to search is a second copy of a
    rule that has exactly one right answer here.
    """

    def __init__(self, disk):
        import subprocess

        argv = [VERIFY_INSTALL] + ([disk] if disk else [])
        log("checking the install: %s" % " ".join(argv))
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        self._init_lines()


class SpineRun(ChildLines):
    """installer/novadeck-install as a child process, read without blocking the frame."""

    def __init__(self, gib, sock_path, bundle, seed, intent):
        import subprocess

        env = dict(os.environ)
        # THE SPINE MUST ASK US FOR CONSENT. $CONFIRM names who renders; pointing it at our shim is
        # what puts the gate on this screen instead of on a terminal nobody is looking at.
        env["NOVADECK_CONFIRM"] = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "confirm-ui")
        env["NOVADECK_UI_SOCK"] = sock_path
        # THE URLS COME FROM THE SCREEN THAT WAS SHOWN, not from a second call to release-info and
        # not from the module's environment defaults. Whatever the pre-flight printed under "To
        # install" is what gets installed: resolving again here would be a second copy of the rule,
        # free to answer differently from the one the operator read (the update server can publish
        # between the two calls) -- the same drift the screen's every-figure-is-measured rule exists
        # to prevent.
        # --intent IS NOT OPTIONAL, and it was until hardware said so. On a disk that already
        # carries NovaDeck the spine refuses to pick for us -- "a disk that already carries a
        # novadeck install admits three different answers and this script may not pick one" -- so an
        # install on such a disk died at select-target, every time, with the UI having done
        # everything else right (Pocket ACE, 2026-08-25). This argument existed and nothing ever
        # passed it, which is why a REQUIRED parameter now rather than a default: the same shape as
        # bundle and seed, which were silently taken from the module's environment until the day
        # they were empty.
        argv = [SPINE, "--bundle", bundle, "--home-seed", seed,
                "--userdata-gib", str(gib), "--intent", intent]
        log("starting the spine: %s" % " ".join(argv))
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, bufsize=0)
        self._init_lines()


class ProgressScreen:
    """A bar per phase, and the one honest sentence a failure owes the user."""

    name = "progress"

    def __init__(self, run, disk=None):
        self.run = run
        self.disk = disk                # which disk to hand verify-install.sh when the spine wins
        self.phase = None
        self.percent = None
        self.message = ""
        self.rc = None
        self.reached_carve = False      # i.e. whether the disk has been modified
        self.result = None              # ("quit",)
        # None = not started, "running", "ok", "bad", "unrunnable". A successful install is not the
        # same claim as a verified one, and the screen must not merge them.
        self.verify = None
        self.verify_bad = []            # the `!!` lines, which are what the operator has to read
        self.verify_tail = []           # its last few lines, for the case where it refused to run

    def begin_verify(self):
        self.verify = "running"

    def feed_verify(self, line):
        """verify-install.sh prints `    ok  ...` and `    !!  ...`; only the failures go on screen."""
        text = line.strip()
        self.verify_tail = (self.verify_tail + [text])[-6:]
        if text.startswith("!!"):
            self.verify_bad.append(text[2:].strip())

    def finish_verify(self, rc):
        # rc 1 is BOTH "a check failed" and "it could not run" (its die() also exits 1), so the
        # `!!` lines are what tells them apart: a run that refused printed none.
        if rc == 0:
            self.verify = "ok"
        else:
            self.verify = "bad" if self.verify_bad else "unrunnable"

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
        # then power the device off".
        #
        # A FAILED one offered "Continue", which named nothing that happens: it quit the UI and left
        # a blank panel. Flagged on hardware 2026-08-25, and the operator was right to find it odd --
        # a failure screen has exactly two useful actions, and neither of them is continuing. Trying
        # again is the DOCUMENTED recovery (the installer takes no backups precisely because
        # re-running has to work), and powering off is what gets the log onto the ESP, since
        # save-log.sh runs when the unit stops.
        # A VERIFIED install offers only Power off, so any press means that. An install the CHECK
        # rejected offers the same two actions a failed one does -- it is the one rc==0 state where
        # trying again is the right answer, so it must route like a failure rather than powering
        # off on a press meant for "Try again".
        if self.rc == 0 and self.verify != "bad":
            self.result = ("poweroff",)
        else:
            self.result = ("retry",) if token == "S" else ("poweroff",)

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
        # NOT a second copy of the phase list. uiview's _phases() renders `rows` -- with the
        # done/active colour, the bar and the percentage -- and this used to ALSO build one
        # plain-text line per reached phase, which _flow() draws immediately above it. So every
        # phase the spine reached appeared twice on the panel: once flat, once as a real row.
        # Observed on an AYANEO Pocket ACE, 2026-08-25 ("Reading the disk / Choosing the target /
        # Writing the install record", each twice). `rows` is the renderer; `blocks` carries only
        # what has no row of its own.
        blocks = []
        title = "Installing NovaDeck"
        note = "Do not power the device off."
        buttons = []
        if self.rc == 0:
            title = "NovaDeck is installed"
            # THE CARD MUST NOT COME OUT UNTIL THE CHECK HAS SPOKEN. verify-install.sh is the only
            # thing that reads back what was written, and its own header asks to be run "BEFORE the
            # card comes out, while there is still a shell that can fix things" -- so telling the
            # operator to remove it while the check is still running would waste the one window it
            # has. Power off stays offered throughout: a check that hangs must never trap anyone.
            buttons = [{"pos": "S", "label": "Power off"}]
            if self.verify in (None, "running"):
                note = "Checking the install -- leave the SD card in."
            elif self.verify == "ok":
                note = "Remove the SD card, then power the device off."
                blocks = blocks + [("Checked", "The eight partitions carry what the boot chain "
                                               "looks for. This does not prove the device boots -- "
                                               "that is the next thing to try.")]
            elif self.verify == "unrunnable":
                # NOT a failed install, and it may not be reported as one. Say which question went
                # unanswered instead of inventing an answer to it.
                note = "Remove the SD card, then power the device off."
                blocks = blocks + [("The check could not run",
                                    "The install finished, but the verifier did not run, so "
                                    "nothing has read back what was written.\n"
                                    + "\n".join(self.verify_tail[-4:]))]
            else:
                title = "NovaDeck is installed, but the check did not pass"
                note = ("Do not remove the SD card. Re-running the installer is the recovery.")
                blocks = blocks + [("What did not check out", "\n".join(self.verify_bad))]
                buttons = [{"pos": "S", "label": "Try again"},
                           {"pos": "SELECT", "label": "Power off"}]
        elif self.rc is not None:
            title = "The install did not finish"
            # THE ONE THING A FAILURE OWES THE USER: which of two states the device is in. "It
            # failed" is not actionable; "nothing was written" and "the disk was modified" are
            # different situations and only one of them needs anything done about it.
            note = ("The disk WAS modified. Re-run the installer; Android's data is already gone."
                    if self.reached_carve else
                    "Nothing was written. The device is exactly as it was.")
            buttons = [{"pos": "S", "label": "Try again"},
                       {"pos": "SELECT", "label": "Power off"}]
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
