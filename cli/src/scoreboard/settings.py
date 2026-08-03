"""Register/remove scoreboard hooks in Claude Code's settings.json.

The literal command string `scoreboard hook` is the ownership marker:
presence is detected by exact string, and removal strips only entries
whose command equals it. Writes are backup-then-atomic-rename.
"""

import datetime
import json
import os
import shutil

HOOK_COMMAND = "scoreboard hook"
ASK_MATCHER = "AskUserQuestion"
PLAIN_EVENTS = [
    "Notification",
    "Stop",
    "UserPromptSubmit",
    "SessionStart",
    "SessionEnd",
    "PermissionRequest",
]
MATCHED_EVENTS = ["PreToolUse", "PostToolUse"]
ALL_EVENTS = PLAIN_EVENTS + MATCHED_EVENTS


def _is_ours(hook: dict) -> bool:
    return isinstance(hook, dict) and hook.get("command") == HOOK_COMMAND


def _entry_has_ours(entry: dict) -> bool:
    return isinstance(entry, dict) and any(
        _is_ours(h) for h in entry.get("hooks") or []
    )


def _load(settings_path: str) -> dict:
    if not os.path.exists(settings_path):
        return {}
    with open(settings_path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{settings_path} is not a JSON object")
    return data


def _installed(settings: dict, event: str) -> bool:
    entries = (settings.get("hooks") or {}).get(event) or []
    for entry in entries:
        if not _entry_has_ours(entry):
            continue
        if event in MATCHED_EVENTS and entry.get("matcher") != ASK_MATCHER:
            continue
        return True
    return False


def scan(settings_path: str) -> dict:
    """Return {event: True|False} for each hook event scoreboard needs."""
    settings = _load(settings_path)
    return {event: _installed(settings, event) for event in ALL_EVENTS}


def _write(settings_path: str, settings: dict) -> str | None:
    """Backup the original (if any), then atomically write settings."""
    json.loads(json.dumps(settings))  # sanity: result must round-trip
    backup = None
    if os.path.exists(settings_path):
        stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
        backup = f"{settings_path}.backup-{stamp}"
        shutil.copy2(settings_path, backup)
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    tmp = f"{settings_path}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
    return backup


def merge(settings_path: str) -> list[str]:
    """Add missing scoreboard hooks. Returns the list of events added."""
    settings = _load(settings_path)
    hooks = settings.setdefault("hooks", {})
    added = []
    for event in ALL_EVENTS:
        if _installed(settings, event):
            continue
        entry = {"hooks": [{"type": "command", "command": HOOK_COMMAND}]}
        if event in MATCHED_EVENTS:
            entry = {"matcher": ASK_MATCHER, **entry}
        hooks.setdefault(event, []).append(entry)
        added.append(event)
    if added:
        _write(settings_path, settings)
    return added


def remove(settings_path: str) -> list[str]:
    """Strip scoreboard hooks only. Returns the list of events cleaned."""
    settings = _load(settings_path)
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return []
    removed = []
    for event in list(hooks):
        entries = hooks[event]
        if not isinstance(entries, list):
            continue
        cleaned = []
        touched = False
        for entry in entries:
            if not _entry_has_ours(entry):
                cleaned.append(entry)
                continue
            kept = [h for h in entry.get("hooks") or [] if not _is_ours(h)]
            touched = True
            if kept:
                entry = dict(entry)
                entry["hooks"] = kept
                cleaned.append(entry)
        if touched:
            removed.append(event)
            if cleaned:
                hooks[event] = cleaned
            else:
                del hooks[event]
    if removed:
        if not hooks:
            del settings["hooks"]
        _write(settings_path, settings)
    return removed
