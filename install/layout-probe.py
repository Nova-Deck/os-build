"""
Lay one screen out against install/fakepygame.py and report where it landed.

    SCR_W=1920 SCR_H=1080 DESC='desc = {...}' python3 install/layout-probe.py
      -> "<lowest pixel the FLOW reached> <the y the button row draws at>"
    COUNT=1  -> "<how many pieces were drawn>" instead

Its own file rather than a heredoc inside install/test-ui.sh, because that suite is itself full of
heredocs and nesting two with the same delimiter silently truncates the outer one — which is exactly
what happened while writing this (2026-08-25).

install/uiview.py imports pygame lazily, inside the view, so injecting the stand-in before the
import is all it takes to run the real layout code with metrics a test controls.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fakepygame                                                # noqa: E402

fakepygame.SCREEN = (int(os.environ["SCR_W"]), int(os.environ["SCR_H"]))
sys.modules["pygame"] = fakepygame

import uiview                                                    # noqa: E402

view = uiview.PygameView()
desc = {}
exec(os.environ["DESC"])                                         # noqa: S102 - the test's own fixture
view.draw(desc)

blits = fakepygame.display.surface.blits
if os.environ.get("COUNT"):
    print(len(blits))
else:
    m = int(view.w * 0.06)
    row = view.h - m - int(view.h * 0.06)
    # The button row draws AT `row` and below, so it is excluded by construction: what must not
    # cross that line is everything above it, which is the flow.
    flow = [b for b in blits if b[1] < row]
    print("%d %d" % (max((b[1] + b[3]) for b in flow), row))
