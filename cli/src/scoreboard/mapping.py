"""Map Claude Code hook payloads to scoreboard state events.

Pure functions only: no I/O, never raises on malformed payloads.
States: running | idle | waiting | error | ended.
"""

import os
import re
import time

from scoreboard import terminals

IDLE_MESSAGE = re.compile(r"waiting for your input|idle|finished|no longer")


def is_idle_notification(payload: dict) -> bool:
    """Idle-prompt Notifications mean Claude is done, not blocked on us.

    Current Claude Code versions send free-text `message` without a
    `notification_type`, so fall back to matching known idle phrasings.
    """
    if payload.get("hook_event_name") != "Notification":
        return False
    ntype = payload.get("notification_type")
    if ntype == "idle_prompt":
        return True
    if ntype:
        return False
    message = payload.get("message") or ""
    return bool(IDLE_MESSAGE.search(message.lower()))


def map_hook(payload, detect_adapter=terminals.detect) -> dict | None:
    """Return a scoreboard event for a hook payload, or None to ignore it."""
    if not isinstance(payload, dict):
        return None
    session_id = payload.get("session_id")
    if not session_id or not isinstance(session_id, str):
        return None
    name = payload.get("hook_event_name")

    if name == "SessionStart":
        # A fresh session sits at the prompt: idle until the first submit.
        state, reason = "idle", "session_start"
    elif name == "UserPromptSubmit":
        state, reason = "running", "prompt"
    elif name == "Stop":
        state, reason = "idle", "stop"
    elif name == "Notification":
        if is_idle_notification(payload):
            state, reason = "idle", "idle"
        else:
            state, reason = "waiting", "notification"
    elif name == "PermissionRequest":
        if payload.get("tool_name") == "AskUserQuestion":
            state, reason = "waiting", "question"
        else:
            state, reason = "waiting", "permission_request"
    elif name == "PreToolUse":
        if payload.get("tool_name") != "AskUserQuestion":
            return None
        state, reason = "waiting", "question"
    elif name == "StopFailure":
        state, reason = "error", str(payload.get("error_type") or "stop_failure")
    elif name == "SessionEnd":
        state, reason = "ended", "session_end"
    else:
        return None

    cwd = payload.get("cwd") or ""
    event = {
        "v": 1,
        "session_id": session_id,
        "state": state,
        "reason": reason,
        "title": os.path.basename(cwd.rstrip("/")) or "claude",
        "cwd": cwd,
        "pid": os.getppid(),
        "ts": time.time(),
    }
    # Terminal origin is captured only at SessionStart: the user just typed
    # `claude` in that tab, so the focused terminal is the session's home.
    # Later hooks may fire while the user is elsewhere - never recapture.
    if name == "SessionStart":
        adapter = detect_adapter()
        if adapter is not None:
            origin = adapter.capture_origin()
            if origin:
                event["origin"] = origin
    return event
