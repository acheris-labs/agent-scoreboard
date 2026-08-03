"""Filesystem contract shared with the Scoreboard menu bar app."""

import os

STATE_DIR = os.path.expanduser("~/.local/state/scoreboard")
SOCKET_PATH = os.path.join(STATE_DIR, "scoreboard.sock")
SNAPSHOT_PATH = os.path.join(STATE_DIR, "state.json")
LOG_PATH = os.path.join(STATE_DIR, "hook.log")
CLAUDE_SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
