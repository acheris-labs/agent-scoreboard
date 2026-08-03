"""Terminal adapters: everything terminal-app-specific lives here.

An adapter turns "which terminal is the user in" into an opaque `origin`
dict (`{"kind": ..., ...}`) that only the matching adapter — Python here,
Swift in the app — ever interprets. Adding a terminal app means one new
module here and one Swift adapter file, nothing else.
"""

import os

from scoreboard.terminals import ghostty

ADAPTERS = [ghostty.GhosttyAdapter]


def detect(environ=os.environ):
    """Return an adapter instance for the current terminal, or None."""
    for adapter in ADAPTERS:
        if adapter.detect(environ):
            return adapter()
    return None
