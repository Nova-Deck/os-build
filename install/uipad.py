#!/usr/bin/env python3
# novadeck internal install — the installer UI's INPUT VOCABULARY and its sources. Phase 5 of
# .claude/plans/internal-install.plan.md.
#
# Everything in the installer that has an opinion about buttons is here, and it has exactly one:
# THEY ARE POSITIONS. The silkscreen on the face cluster is not the same across the boards this one
# installer is unified over (`A` is EAST on the AYANEO Pocket ACE and SOUTH on the Pocket S2), so a
# letter names a different physical button per device — on a tool whose consent screen erases an
# Android install. See §4d.
#
# It imports nothing of ours, so both the state machine (install/ui) and the install flow
# (install/uiflow.py) can share this vocabulary without either importing the other.
import os
import sys

PROG = os.path.basename(sys.argv[0])

# =================================================================================================
# input — positions, never printed letters
# =================================================================================================
CARDINALS = ("N", "E", "S", "W")
CARDINAL_NAME = {"N": "NORTH", "E": "EAST", "S": "SOUTH", "W": "WEST"}

# SDL_CONTROLLER_BUTTON_A/B/X/Y = 0/1/2/3, and SDL defines them by POSITION: A is the bottom button
# of the face cluster, B the right, X the left, Y the top, regardless of what the pad prints. That
# is the whole reason this mapping is trustworthy on both silkscreens, and the reason it is written
# out as numbers with this comment rather than as pygame.CONTROLLER_BUTTON_A: it is a wire format,
# not a pygame detail, and the installer ships InputPlumber's virtual Xbox pad in front of it.
BUTTON_TO_CARDINAL = {0: "S", 1: "E", 2: "W", 3: "N"}
BUTTON_BACK = 4  # SDL_CONTROLLER_BUTTON_BACK — "select"/"view". The abort, see below.

# Keyboard equivalents, the same initials install/confirm-tty takes. A USB keyboard therefore works
# for free, which §4d needs: it is the named fallback when no controller enumerates.
KEY_TO_CARDINAL = {"n": "N", "e": "E", "s": "S", "w": "W"}

TOKEN_BACK = "BACK"     # abort
TOKEN_QUIT = "QUIT"     # the window went away


def log(msg):
    # This file's stdout is NOT the consent answer — confirm-ui's is — so logging here is free.
    # That separation is deliberate; see the header of install/confirm-ui.
    print("%s: %s" % (PROG, msg), file=sys.stderr, flush=True)


# =================================================================================================
# is there anything to answer with? — §4d
# =================================================================================================
# "If neither a controller nor a keyboard is present, the installer STOPS and says so. There is no
# bypass. An installer that cannot take consent cannot install."
#
# The keyboard half cannot be asked of SDL, so it is read from the kernel's device list — and the
# question is not "is there a keyboard" but "is there something that can type the four letters the
# consent screen asks for". That is the same question, asked in the form that can be answered.
INPUT_DEVICES = os.environ.get("NOVADECK_UI_INPUT_DEVICES", "/proc/bus/input/devices")

# KEY_S, KEY_W, KEY_N, KEY_E — the initials install/confirm-tty takes and this UI accepts.
TYPING_KEYS = (31, 17, 49, 18)


def _key_mask(words):
    """The `B: KEY=` bitmask, printed high word first, as one integer."""
    try:
        return int("".join(w.rjust(16, "0") for w in words), 16)
    except ValueError:
        return 0


def typing_keyboard_present(path=None):
    """
    A device that can type S/W/N/E, and is not one of ours.

    TWO EXCLUSIONS, and both were measured rather than guessed:

    * `/devices/virtual/` is skipped. InputPlumber always creates an "InputPlumber Keyboard", and
      it DECLARES a full keyboard — the capability bitmap covers the whole alphabet — while
      carrying almost nothing: across every capability map we ship, 130 events target the gamepad
      and 3 target the keyboard, all of them `KeyHome`/`KeyF1` quick-access buttons on boards with
      extra controls that do not fit an Xbox layout. Not one letter. So it can never type these
      four keys no matter what the pad is doing, and a scan that trusted its bitmap would report a
      keyboard on every board this project ships — including one with nothing attached at all,
      which is the only case this check exists for.
    * capability, not the `kbd` handler. `pmic_pwrkey`, `gpio-keys` and even the headset jack carry
      `Handlers=kbd`; none of them can type a letter.

    A device list that cannot be READ reports present, deliberately. This check is an early and
    friendly stop, not the safety property — the safety property is the consent gate itself, which
    still cannot be satisfied without a person pressing something. Refusing to install because
    /proc looked odd would trade a real capability for a guess.
    """
    p = path or INPUT_DEVICES
    try:
        blocks = open(p, "r", encoding="utf-8", errors="replace").read().split("\n\n")
    except OSError as e:
        log("cannot read %s (%s) -- assuming an input device is present" % (p, e))
        return True
    for block in blocks:
        sysfs, mask = "", 0
        for line in block.splitlines():
            if line.startswith("S: Sysfs="):
                sysfs = line.split("=", 1)[1].strip()
            elif line.startswith("B: KEY="):
                mask = _key_mask(line.split("=", 1)[1].split())
        if not mask or sysfs.startswith("/devices/virtual/"):
            continue
        if all((mask >> k) & 1 for k in TYPING_KEYS):
            return True
    return False


# =================================================================================================
# input sources
# =================================================================================================
class ScriptedInput:
    """
    A file of tokens, one per line, consumed one per frame. The headless seam.

    `SHOWN` is the direct analogue of install/test-install.sh's confirm-typist wrapper: it presses,
    in order, the sequence the screen is displaying right now. It is a KEYBOARD, not a bypass — the
    sequence is random per attempt, so a driver that could not read the screen could not answer at
    all, which is exactly the user's position. Every wrong-answer case in the suite is written with
    literal tokens instead.
    """

    def __init__(self, path):
        with open(path, "r", encoding="utf-8") as f:
            self.tokens = [t.strip() for t in f if t.strip()]
        self.i = 0

    def poll(self, screen):
        # Nothing is pressed at a screen that asks for nothing. Without this the scripted presses
        # are spent before the spine has even connected, since the UI is started first -- and the
        # run then ends early, which looks exactly like a UI that crashed.
        #
        # Asked as a PROPERTY of the screen rather than by name: a name list is a list somebody
        # forgets to extend, and both times this loop grew a screen that is what happened.
        if not getattr(screen, "interactive", True) or self.i >= len(self.tokens):
            return []
        tok = self.tokens[self.i]
        self.i += 1
        if tok == "SHOWN":
            seq = getattr(screen, "sequence", "")
            return list(seq)
        return [tok]

    def present(self):
        # This source IS an input device -- it replays presses, which is what a keyboard does. It
        # defers to the device scan only when a test points it at a fixture explicitly, which is
        # how §4d's no-input case is driven with no SDL in the picture.
        return typing_keyboard_present() if os.environ.get("NOVADECK_UI_INPUT_DEVICES") else True

    def close(self):
        pass


class PadInput:
    """SDL_GameController and the keyboard, mapped to positions at the boundary."""

    def __init__(self, pygame):
        self.pygame = pygame
        pygame.controller.init()
        self.pads = {}
        for i in range(pygame.joystick.get_count()):
            self._open(i)

    def _open(self, index):
        pg = self.pygame
        # A pad that SDL has no mapping for enumerates as a joystick and produces no
        # CONTROLLERBUTTONDOWN at all — i.e. positions we cannot name. The installer ships
        # InputPlumber's virtual Xbox pad precisely so that this is never the case here, so an
        # unmapped device is worth a line in the journal rather than a silent skip.
        #
        # NOT HYPOTHETICAL. Measured on an AYANEO Pocket ACE, 2026-08-22: the controller MCU has two
        # modes (Xbox -> `045e:028e`, AYANEO -> `4001:0428`) and the unit came up in the second,
        # which no InputPlumber config claimed. The raw pad has no gamecontrollerdb entry, so this
        # check would have skipped it and the consent screen would have found no controller at all.
        # Fixed where it belongs, in the source list of
        # fs-overlay/etc/inputplumber/devices.d/sm8550-ayaneo-controller-japanese.yaml — not here.
        # This line staying loud is what would name the next mode nobody has seen yet.
        if not pg.controller.is_controller(index):
            log("input device %d is not a mapped game controller -- ignored" % index)
            return
        c = pg.controller.Controller(index)
        self.pads[index] = c
        log("controller attached: %s" % c.name)

    def present(self):
        # A PAD SDL CANNOT MAP DOES NOT COUNT, which is why this asks SDL rather than the kernel:
        # an AYANEO Pocket ACE in AYANEO mode exposes a perfectly good gamepad that SDL has no
        # mapping for (2026-08-22), and a screen whose buttons cannot be named is not a screen
        # anyone can give consent on. The keyboard half has no SDL equivalent, so it is read from
        # the device list.
        return bool(self.pads) or typing_keyboard_present()

    def poll(self, screen):
        pg = self.pygame
        out = []
        for ev in pg.event.get():
            if ev.type == pg.QUIT:
                out.append(TOKEN_QUIT)
            elif ev.type == pg.CONTROLLERDEVICEADDED:
                self._open(ev.device_index)
            elif ev.type == pg.CONTROLLERBUTTONDOWN:
                if ev.button in BUTTON_TO_CARDINAL:
                    out.append(BUTTON_TO_CARDINAL[ev.button])
                elif ev.button == BUTTON_BACK:
                    out.append(TOKEN_BACK)
            elif ev.type == pg.KEYDOWN:
                name = pg.key.name(ev.key)
                if name in KEY_TO_CARDINAL:
                    out.append(KEY_TO_CARDINAL[name])
                elif ev.key == pg.K_ESCAPE:
                    out.append(TOKEN_BACK)
        return out

    def close(self):
        pass


# =================================================================================================
# views
# =================================================================================================
class NullView:
    """Draws nothing and records the last description, so a test can assert what would be drawn."""

    def __init__(self):
        self.last = None

    def draw(self, desc):
        self.last = desc

    def close(self):
        pass
