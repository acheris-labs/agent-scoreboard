"""Ghostty adapter: all Ghostty AppleScript lives here.

Ghostty (>= 1.3) exposes terminals with stable UUID ids via its scripting
dictionary. Origin shape: {"kind": "ghostty", "terminal_id": "<uuid>"}.
"""

import subprocess

KIND = "ghostty"
OSASCRIPT_TIMEOUT = 2.0

# The focused terminal of the front window is where the user just typed.
# The frontmost guard means we never capture when the prompt didn't come
# from a foreground Ghostty tab - better no origin than a wrong one.
CAPTURE_SCRIPT = """
tell application "Ghostty"
    if frontmost then
        get id of focused terminal of selected tab of front window
    end if
end tell
"""

# One id per line, then a blank separator line, then one cwd per line.
LIST_SCRIPT = """
tell application "Ghostty"
    set ids to id of every terminal
    set cwds to working directory of every terminal
end tell
set out to ""
repeat with i in ids
    set out to out & i & linefeed
end repeat
set out to out & linefeed
repeat with c in cwds
    set out to out & c & linefeed
end repeat
return out
"""


def _osascript(script: str) -> str | None:
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=OSASCRIPT_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


class GhosttyAdapter:
    kind = KIND

    @staticmethod
    def detect(environ) -> bool:
        return environ.get("TERM_PROGRAM") == "ghostty"

    def capture_origin(self) -> dict | None:
        terminal_id = _osascript(CAPTURE_SCRIPT)
        if not terminal_id:
            return None
        return {"kind": KIND, "terminal_id": terminal_id}

    def list_origins(self) -> list[tuple[dict, str]]:
        """All terminals as (origin, working_directory) pairs."""
        out = _osascript(LIST_SCRIPT)
        if not out:
            return []
        ids, _, cwds = out.partition("\n\n")
        id_list = ids.splitlines()
        cwd_list = cwds.splitlines()
        if len(id_list) != len(cwd_list):
            return []
        return [
            ({"kind": KIND, "terminal_id": tid}, cwd)
            for tid, cwd in zip(id_list, cwd_list)
        ]
