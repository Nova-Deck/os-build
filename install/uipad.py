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
        # would be spent before the spine has even connected, since the UI is started first.
        if screen.name == "idle" or self.i >= len(self.tokens):
            return []
        tok = self.tokens[self.i]
        self.i += 1
        if tok == "SHOWN":
            seq = getattr(screen, "sequence", "")
            return list(seq)
        return [tok]

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
        return bool(self.pads)

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
