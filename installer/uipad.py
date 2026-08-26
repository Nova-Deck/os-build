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
# It imports nothing of ours, so both the state machine (installer/ui) and the install flow
# (installer/uiflow.py) can share this vocabulary without either importing the other.
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

# Keyboard equivalents, the same initials installer/confirm-tty takes. A USB keyboard therefore works
# for free, which §4d needs: it is the named fallback when no controller enumerates.
KEY_TO_CARDINAL = {"n": "N", "e": "E", "s": "S", "w": "W"}

TOKEN_BACK = "BACK"     # abort
TOKEN_QUIT = "QUIT"     # the window went away
TOKEN_LEFT = "LEFT"     # adjust a value down
TOKEN_RIGHT = "RIGHT"   # adjust a value up

# THE D-PAD, which had no tokens at all until hardware said so (2026-08-24). PreflightScreen has
# handled LEFT and RIGHT since it was written -- they are how the operator chooses how much of the
# disk Android keeps -- and NOTHING COULD EVER PRODUCE THEM: this file translated the four face
# buttons and BACK, and stopped there. The screen offered a control no input could reach, and the
# only visible symptom was that the number would not move.
#
# The face buttons are cardinal POSITIONS because their printed letters differ between boards
# (§4d). The d-pad needs no such care: left is left on every one of them, so these map straight
# through. SDL numbers them 11..14 (UP/DOWN/LEFT/RIGHT) as CONTROLLER_BUTTON_DPAD_*; only the two
# horizontal ones are bound, because they are the only ones any screen asks for -- an unbound
# direction is inert rather than surprising.
BUTTON_TO_NAV = {13: TOKEN_LEFT, 14: TOKEN_RIGHT}
# Arrow keys for the USB-keyboard fallback §4d requires, alongside the n/e/s/w initials above.
KEY_TO_NAV = {"left": TOKEN_LEFT, "right": TOKEN_RIGHT}


def log(msg):
    # This file's stdout is NOT the consent answer — confirm-ui's is — so logging here is free.
    # That separation is deliberate; see the header of installer/confirm-ui.
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

# KEY_S, KEY_W, KEY_N, KEY_E — the initials installer/confirm-tty takes and this UI accepts.
TYPING_KEYS = (31, 17, 49, 18)


def _key_mask(words):
    """The `B: KEY=` bitmask, printed high word first, as one integer."""
    try:
        return int("".join(w.rjust(16, "0") for w in words), 16)
    except ValueError:
        return 0


def virtual_pad_ids(path=None):
    """
    {"vvvv:pppp"} for every input device the kernel says is VIRTUAL, i.e. uinput.

    THIS IS HOW THE INSTALLER TELLS InputPlumber's PAD FROM THE ONE IT IS BUILT FROM (#69). Both
    enumerate, both are mapped game controllers, and SDL will happily open both -- but only one of
    them is the composite device whose buttons this file's cardinal mapping was written against.
    Holding the other is what breaks the consent gate: InputPlumber wants its sources exclusively,
    and a UI sitting on one of them cost a hardware gate on 2026-08-26.

    Measured on an AYANEO Pocket ACE, and the split is total:

        AYANEO Controller           4001:0428  /devices/platform/soc@0/...  <- a SOURCE
        Microsoft Xbox Series S|X   045e:0b12  /devices/virtual/input/...   <- the TARGET
        Microsoft X-Box 360 pad 0   28de:11ff  /devices/virtual/input/...   <- Steam's own

    NOT MATCHED BY NAME, deliberately. SDL renames a pad to whatever gamecontrollerdb calls it, so
    the same device is "Microsoft Xbox Series S|X Controller" here and "Xbox Series X Controller"
    to the UI -- a name comparison across that boundary silently matches nothing. vendor:product
    survives the rename because SDL carries it in the joystick GUID.

    Same `/devices/virtual/` test typing_keyboard_present() already relies on, for the same reason:
    it is the kernel's own answer to "did a program make this up?", and it needs no allow-list of
    boards or target names to keep current.

    An unreadable device list returns empty, which restores the old open-everything behaviour rather
    than leaving the operator with no pad at all -- the consent gate is the safety property, not
    this.
    """
    p = path or INPUT_DEVICES
    try:
        blocks = open(p, "r", encoding="utf-8", errors="replace").read().split("\n\n")
    except OSError as e:
        log("cannot read %s (%s) -- every pad will be treated as usable" % (p, e))
        return set()
    ids = set()
    for block in blocks:
        sysfs, ident = "", ""
        for line in block.splitlines():
            if line.startswith("S: Sysfs="):
                sysfs = line.split("=", 1)[1].strip()
            elif line.startswith("I: "):
                fields = dict(
                    kv.split("=", 1) for kv in line[3:].split() if "=" in kv
                )
                if "Vendor" in fields and "Product" in fields:
                    ident = "%s:%s" % (fields["Vendor"].lower(), fields["Product"].lower())
        if ident and sysfs.startswith("/devices/virtual/"):
            ids.add(ident)
    return ids


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

    `SHOWN` is the direct analogue of tests/test-install.sh's confirm-typist wrapper: it presses,
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
        # `pygame.controller` DOES NOT EXIST as a top-level module -- the game-controller API lives
        # at pygame._sdl2.controller in both pygame and pygame-ce. Written from the docs rather than
        # the library, this line was `pygame.controller.init()` and it took the whole UI down with
        # an AttributeError the first time it ran against a real pygame (Pocket S2, 2026-08-22) --
        # after gamescope had already come up, so the symptom was a black panel.
        self.controller = self._controller_module(pygame)
        if self.controller is None:
            log("this pygame exposes no game-controller API -- keyboard only")
            self.pads = {}
            return
        self.controller.init()
        self.pads = {}
        # Which pads are uinput, so a source claimed later can be dropped -- see _open and #69.
        self._virtual = virtual_pad_ids()
        self._raw = set()
        for i in range(pygame.joystick.get_count()):
            self._open(i)

    @staticmethod
    def _controller_module(pygame):
        try:
            from pygame._sdl2 import controller          # pygame and pygame-ce 2.x
            return controller
        except ImportError:
            return getattr(pygame, "controller", None)   # whatever a future version calls it

    def _device_ident(self, index):
        """
        "vvvv:pppp" for an SDL device index, read out of the joystick GUID -- or None.

        SDL packs vendor at bytes 4-5 and product at bytes 8-9 of the 16-byte GUID, little-endian,
        which is hex characters 8..11 and 16..19. Spelled out rather than taken from a helper
        because pygame exposes no accessor for either, and a GUID is a wire format that does not
        move.

        ANYTHING UNEXPECTED RETURNS None, AND A PAD WITH NO id IS ATTACHED, not skipped. The bug
        this guards against is holding one pad too many; refusing to open one we could not identify
        would trade that for no pad at all, and §4d says the operator must still be able to answer.
        """
        try:
            j = self.pygame.joystick.Joystick(index)
        except Exception as e:                                    # noqa: BLE001 -- see docstring
            log("cannot open input device %d to read its id (%s)" % (index, e))
            return None
        try:
            guid = j.get_guid()
        except Exception as e:                                    # noqa: BLE001
            log("this pygame exposes no joystick GUID (%s) -- pads cannot be told apart" % e)
            return None
        finally:
            j.quit()
        if not isinstance(guid, str) or len(guid) < 20:
            return None
        try:
            vendor = int(guid[10:12] + guid[8:10], 16)
            product = int(guid[18:20] + guid[16:18], 16)
        except ValueError:
            return None
        if not vendor and not product:
            return None
        return "%04x:%04x" % (vendor, product)

    def _drop_sources(self):
        """
        Let go of any source pad still held, once InputPlumber's target is actually up (#69).

        Needed because InputPlumber's discovery is ASYNCHRONOUS: its target can appear after this
        UI has already enumerated, in which case a source was opened while it was the only pad
        there. Ordering the units cannot express that -- inputplumber.service is already
        Before=novadeck-installer.service, and it did not help.

        Only fires while a non-source pad is held, so a board where InputPlumber never comes up
        keeps whatever it has rather than being left with nothing.
        """
        if not self._raw or not any(i not in self._raw for i in self.pads):
            return
        for index in sorted(self._raw):
            c = self.pads.pop(index, None)
            if c is None:
                continue
            try:
                c.quit()
            except Exception:                                     # noqa: BLE001
                pass
            log("controller released: device %d was a source, InputPlumber's pad is up" % index)
        self._raw.clear()

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
        # rootfs/overlay/etc/inputplumber/devices.d/sm8550-ayaneo-controller-japanese.yaml — not here.
        # This line staying loud is what would name the next mode nobody has seen yet.
        if not self.controller.is_controller(index):
            log("input device %d is not a mapped game controller -- ignored" % index)
            return
        # WHICH PAD IS THIS, in terms the kernel agrees with? SDL's name is gamecontrollerdb's, not
        # the device's, so ask the GUID -- it carries the real vendor:product through the rename.
        ident = self._device_ident(index)
        c = self.controller.Controller(index)
        if self._virtual and ident and ident not in self._virtual:
            # A SOURCE of InputPlumber's composite, not its target. Let go of it AT ONCE: holding a
            # source is what made add_source_device fail with EBUSY and took the whole composite
            # down with it, leaving the consent gate answerable by nothing (#69, HW 2026-08-26).
            # The pad still works -- through the target, where the buttons mean what §4d says.
            c.quit()
            log("controller ignored: %s (%s is a source device, not InputPlumber's pad)"
                % (c.name, ident))
            return
        self.pads[index] = c
        if ident and ident not in self._virtual:
            self._raw.add(index)
        log("controller attached: %s (%s)" % (c.name, ident or "no id"))

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
                # Re-read the kernel's list first: a target that InputPlumber creates AFTER this UI
                # started is not in the set built at __init__, and would otherwise be mistaken for
                # a source and dropped -- the exact inversion of the bug (#69). Keep the old set if
                # the list cannot be read, rather than falling back to "nothing is virtual".
                self._virtual = virtual_pad_ids() or self._virtual
                self._open(ev.device_index)
                self._drop_sources()
            elif ev.type == pg.CONTROLLERBUTTONDOWN:
                if ev.button in BUTTON_TO_CARDINAL:
                    out.append(BUTTON_TO_CARDINAL[ev.button])
                elif ev.button in BUTTON_TO_NAV:
                    out.append(BUTTON_TO_NAV[ev.button])
                elif ev.button == BUTTON_BACK:
                    out.append(TOKEN_BACK)
            elif ev.type == pg.KEYDOWN:
                name = pg.key.name(ev.key)
                if name in KEY_TO_CARDINAL:
                    out.append(KEY_TO_CARDINAL[name])
                elif name in KEY_TO_NAV:
                    out.append(KEY_TO_NAV[name])
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
