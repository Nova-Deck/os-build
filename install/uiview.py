#!/usr/bin/env python3
# novadeck internal install — the installer UI's VIEW. Phase 5 of
# .claude/plans/internal-install.plan.md.
#
# This file is the only one in the installer that knows what a pixel is, and it is a separate file
# rather than a class in install/ui so that the separation is physical instead of a convention. The
# whole state machine — screens, the consent socket, the spine driver — lives in install/ui and
# imports nothing from here; install/ui loads THIS module lazily, only when there is a display to
# open. That is what lets the suite drive every screen on a build host with no SDL, no panel and no
# pad, and it is what would let the KMSDRM fallback (§5's documented alternative if Phase 0 item 7
# goes badly) be a second file rather than a rewrite.
#
# Everything it knows about a screen arrives as the dict describe() returned. It makes no decisions.

class PygameView:
    """
    The SDL2 client. Everything it knows about a screen arrives as the dict from describe().

    The font is pygame's own bundled face by default: a UI that dies because fontconfig came up
    empty is a black panel on a device with no serial console, and the installer is the one tool
    that has to work when everything else is broken.
    """

    BG = (16, 18, 22)
    FG = (232, 234, 238)
    DIM = (150, 155, 165)
    WARN = (240, 180, 90)
    DOT = (90, 96, 108)
    DOT_ON = (240, 240, 245)

    def __init__(self):
        import pygame                                            # lazy: see this file's header

        self.pygame = pygame
        pygame.init()
        pygame.display.set_caption("NovaDeck installer")
        self.surface = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
        self.w, self.h = self.surface.get_size()
        # THE PANEL IS HELD AT ARM'S LENGTH, NOT SAT IN FRONT OF. h/34 came from reading these
        # screens on a monitor; on the device they were consistently a little small (reported
        # 2026-08-25), which on the one screen that matters -- a failure naming the file to edit and
        # the computer to edit it on -- is the difference between advice read and advice squinted
        # at. h/28 is about 20% larger. Everything else scales off this, so the title and headings
        # keep their relationship to the body and only the one number moves.
        self._base = max(16, int(self.h / 28))
        self._fonts(self._base)
        # Set while MEASURING rather than drawing: every blit in this file is suppressed, so the
        # same code that lays a screen out can be asked how tall it comes to before anything is on
        # the panel. See draw().
        self._dry = False

    def _fonts(self, base):
        pygame = self.pygame
        self.f_title = pygame.font.Font(None, int(base * 1.9))
        self.f_head = pygame.font.Font(None, int(base * 1.25))
        self.f_body = pygame.font.Font(None, base)

    def draw(self, desc):
        """
        THE BUTTON ROW IS RESERVED, and the content is shrunk until it fits above it.

        Everything except the buttons flows down the screen; the buttons are pinned to the bottom.
        So a screen whose content grew -- a long board name, a consent screen with three paragraphs
        and a row of diamonds -- ran straight through them: text on top of the one row that says
        which button does what, on the one screen where that matters most. Reported on an AYANEO
        Pocket ACE (consent, 2026-08-25); the pre-flight screen had hit the same wall in August and
        was fixed by compacting ITS content, which fixed one screen and left the mechanism.
        NOTHING IS ELIDED to achieve it, and on a consent screen nothing may be: the fix is a
        smaller type scale, chosen by measuring, not less text. The floor is 60% of the base size --
        past that a screen is unreadable anyway, and the honest failure is small text rather than
        hidden text.
        """
        pg = self.pygame
        m = int(self.w * 0.06)
        # The top of the button row, less a gap. _buttons() centres itself on this line.
        limit = self.h - m - int(self.h * 0.06) - int(self.h * 0.02)
        base, floor = self._base, max(12, int(self._base * 0.6))
        self._dry = True
        while True:
            self._fonts(base)
            if self._flow(desc, m) <= limit or base <= floor:
                break
            base = max(floor, int(base * 0.92))
        self._dry = False

        self.surface.fill(self.BG)
        self._flow(desc, m)
        if desc.get("buttons"):
            self._buttons(desc["buttons"], m, self.h - m - int(self.h * 0.06))
        if desc.get("abort"):
            self._text(desc["abort"], self.f_body, self.DIM, m, self.h - m)
        pg.display.flip()
        self._fonts(self._base)          # the next screen starts from the full size again

    def _flow(self, desc, m):
        """Everything that flows down the screen. Returns the y it ended at."""
        y = m
        y = self._text(desc.get("title", ""), self.f_title, self.FG, m, y) + int(self.h * 0.02)
        for head, body in desc.get("blocks", []):
            if head:
                y = self._text(head, self.f_head, self.WARN, m, y)
            # Multi-line bodies (the destroy list, a failure's tail) are already broken where they
            # mean to break; only the prose gets wrapped.
            for para in body.split("\n"):
                y = self._wrap(para, self.f_body, self.DIM, m, y, self.w - 2 * m)
            y += int(self.h * 0.012)
        if desc.get("rows"):
            y = self._phases(desc["rows"], m, y + int(self.h * 0.01))
        diamonds = desc.get("diamonds", [])
        if diamonds:
            y = self._text(desc.get("prompt", ""), self.f_head, self.FG, m, y + int(self.h * 0.01))
            y = self._diamonds(diamonds, m, y + int(self.h * 0.015))
            y = self._text(desc.get("note", ""), self.f_body, self.DIM, m, y + int(self.h * 0.01))
        if desc.get("note") and not diamonds:
            y = self._text(desc["note"], self.f_body, self.DIM, m, y + int(self.h * 0.02))
        return y

    def _phases(self, rows, x, y):
        """One line per phase the spine has reached, with a bar on the one that is running."""
        pg = self.pygame
        width = self.w - 2 * x
        for r in rows:
            if r["state"] == "pending":
                continue
            colour = self.FG if r["state"] == "active" else self.DIM
            y = self._text(r["label"], self.f_body, colour, x, y)
            if r["state"] == "active":
                h = max(4, int(self.h / 160))
                if not self._dry:
                    pg.draw.rect(self.surface, self.DOT, (x, y + h, width, h))
                    if r["percent"] is not None:
                        pg.draw.rect(self.surface, self.DOT_ON,
                                     (x, y + h, int(width * r["percent"] / 100), h))
                y += h * 3
            y += int(self.h * 0.006)
        return y

    def _buttons(self, buttons, x, y):
        """
        The prompt row: a glyph and what it does.

        A face button is drawn as the same diamond the consent screen uses, for the same reason --
        the letter printed on it is not the same button from one board to the next, so the UI never
        prints one. SELECT has no position to draw, so it is the one control named in words.
        """
        pg = self.pygame
        r = max(4, int(self.h / 150))
        span = r * 4
        # The gap between a diamond and the word it labels. It was r -- the east dot`s edge sits at
        # cx + span + r and the label started at cx + span + r*2 -- which is about 9px on a
        # 1440-high panel, so "Continue" read as part of the glyph rather than a caption for it.
        # Reported from the panel twice (2026-08-24), on the network screen and again on the
        # connected one. Derived from r so it tracks the dot size on any output.
        gap = r * 6
        # ONE BASELINE FOR EVERY CONTROL IN THE ROW. A diamond's label is centred on the diamond,
        # at y + span; SELECT was blitted at y, the row's TOP, so the two captions sat a whole span
        # apart on the same row and "SELECT Cancel" rode high above "Join" next to it. Reported from
        # the panel, 2026-08-25. The centre line is a property of the ROW, not of whichever control
        # happens to be drawn, so it is computed once here and both paths are given it.
        cy = y + span
        for b in buttons:
            if b["pos"] == "SELECT":
                x = self._inline(x, cy, "SELECT", b["label"])
                continue
            cx = x + span
            for pos, (dx, dy) in (
                ("N", (0, -span)), ("E", (span, 0)), ("S", (0, span)), ("W", (-span, 0))
            ):
                filled = pos == b["pos"]
                pg.draw.circle(self.surface, self.DOT_ON if filled else self.DOT,
                               (cx + dx, cy + dy), r, 0 if filled else 2)
            label = self.f_body.render(b["label"], True, self.FG)
            self.surface.blit(label, (cx + span + gap, cy - label.get_height() // 2))
            # The advance clears the dot, the gap and the word, so the next control starts free of
            # all three -- it used to add r*3, which double-counted nothing and left the spacing
            # between controls dependent on a constant that no longer describes the layout.
            x = cx + span + gap + label.get_width() + int(self.w * 0.05)

    def _inline(self, x, cy, key, label):
        """A control with no glyph to draw, centred on the row's centre line like the diamonds."""
        surf = self.f_body.render("%s  %s" % (key, label), True, self.FG)
        self.surface.blit(surf, (x, cy - surf.get_height() // 2))
        return x + surf.get_width() + int(self.w * 0.05)

    def _text(self, s, font, colour, x, y):
        if not s:
            return y
        surf = font.render(s, True, colour)
        if not self._dry:
            self.surface.blit(surf, (x, y))
        return y + surf.get_height()

    def _wrap(self, s, font, colour, x, y, width):
        words, line = s.split(), ""
        for w in words:
            trial = (line + " " + w).strip()
            if font.size(trial)[0] > width and line:
                y = self._text(line, font, colour, x, y)
                line = w
            else:
                line = trial
        return self._text(line, font, colour, x, y)

    def _diamonds(self, diamonds, x, y):
        """One diamond of four dots per press, the target filled, its position named underneath."""
        pg = self.pygame
        r = max(6, int(self.h / 90))          # dot radius
        span = r * 5                          # centre-to-centre of opposite dots
        cell = span * 2 + r * 6
        for i, d in enumerate(diamonds):
            cx = x + int(cell * (i + 0.5))
            cy = y + span
            for pos, (dx, dy) in (
                ("N", (0, -span)), ("E", (span, 0)), ("S", (0, span)), ("W", (-span, 0))
            ):
                filled = pos == d["pos"]
                colour = self.DOT_ON if filled else self.DOT
                if not self._dry:
                    pg.draw.circle(self.surface, colour, (cx + dx, cy + dy), r, 0 if filled else 2)
            label = self.f_body.render(d["name"], True, self.FG if not d["done"] else self.DIM)
            if not self._dry:
                self.surface.blit(label, (cx - label.get_width() // 2, cy + span + r * 2))
        return y + span * 2 + r * 4 + self.f_body.get_height()

    def close(self):
        self.pygame.quit()
