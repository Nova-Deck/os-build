"""
A pygame stand-in with DETERMINISTIC metrics, so installer/uiview.py's layout can be tested.

tests/test-ui.sh injects this into sys.modules before constructing the view. uiview imports pygame
lazily, inside the view only — the whole reason the rest of the UI runs headless — and this is what
extends that reach to the one part that was left out: where things land on the screen.

WHAT IT CAN AND CANNOT PROVE. It cannot prove anything about pixels, fonts or the panel: the real
metrics come from a real SDL on the device. What it proves is the ARITHMETIC — that the flowing
content is measured against the button row and shrunk until it clears it, on a screen shape and a
text volume chosen by the test rather than by whatever happened to be on the panel that day. The
consent screen overlapped its own button row on an AYANEO Pocket ACE (2026-08-25) and nothing
offline could see it, because nothing offline drew anything.

Every glyph is HALF THE FONT SIZE WIDE and one size tall. That is not a real font, and it does not
need to be: the property under test is that the layout responds to height at all.
"""
FULLSCREEN = 1


class _Surface:
    def __init__(self, w, h, recorder=None):
        self._w, self._h = w, h
        self.blits = recorder if recorder is not None else []

    def get_size(self):
        return (self._w, self._h)

    def get_width(self):
        return self._w

    def get_height(self):
        return self._h

    def fill(self, _colour):
        del self.blits[:]          # a redraw starts from an empty screen, like the real one

    def blit(self, surf, pos):
        self.blits.append((pos[0], pos[1], surf.get_width(), surf.get_height()))


class _Font:
    def __init__(self, _name, size):
        self.size_px = max(1, int(size))

    def size(self, text):
        return (int(len(text) * self.size_px * 0.5), self.size_px)

    def render(self, text, _aa, _colour):
        w, h = self.size(text)
        return _Surface(w, h, recorder=[])

    def get_height(self):
        return self.size_px


class _FontModule:
    Font = _Font


class _DisplayModule:
    """The one surface everything draws onto, so a test can read back what landed where."""

    surface = None

    @classmethod
    def set_mode(cls, _size, _flags=0):
        cls.surface = _Surface(SCREEN[0], SCREEN[1])
        return cls.surface

    @staticmethod
    def set_caption(_s):
        pass

    @staticmethod
    def flip():
        pass


class _DrawModule:
    """Rects and circles are recorded as blits too — an overlap is an overlap whatever drew it."""

    @staticmethod
    def rect(surface, _colour, r):
        surface.blits.append((r[0], r[1], r[2], r[3]))

    @staticmethod
    def circle(surface, _colour, centre, radius, _width=0):
        surface.blits.append((centre[0] - radius, centre[1] - radius, radius * 2, radius * 2))


# The test sets this before constructing the view.
SCREEN = (1920, 1080)

font = _FontModule
display = _DisplayModule
draw = _DrawModule


def init():
    pass


def quit():  # noqa: A001 - the name pygame uses
    pass
