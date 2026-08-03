"""scoreboard CLI: init / hook / state."""

import argparse
import json
import os
import sys
import time
import traceback

from scoreboard import client, mapping, settings, terminals
from scoreboard.paths import CLAUDE_SETTINGS_PATH, SNAPSHOT_PATH, SOCKET_PATH


def cmd_hook() -> int:
    # Hook path: always exit 0, never write stdout/stderr — Claude parses
    # hook output and any noise here would disturb the session.
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        event = mapping.map_hook(payload)
        if event is not None:
            client.send_event(event)
    except Exception:
        client.log(traceback.format_exc())
    return 0


def cmd_init(remove: bool) -> int:
    path = CLAUDE_SETTINGS_PATH
    if remove:
        removed = settings.remove(path)
        if removed:
            print(f"removed scoreboard hooks: {', '.join(removed)}")
        else:
            print("nothing to remove")
        return 0
    added = settings.merge(path)
    status = settings.scan(path)
    for event in settings.ALL_EVENTS:
        mark = "added" if event in added else ("✓" if status[event] else "✗")
        print(f"  {mark:5s} {event}")
    if not os.path.exists(SOCKET_PATH):
        print("note: Scoreboard app is not running (make run)")
    return 0


def _read_sessions() -> list[dict] | None:
    if not os.path.exists(SNAPSHOT_PATH):
        return None
    with open(SNAPSHOT_PATH) as f:
        return json.load(f).get("sessions") or []


def _resolve_session(sessions: list[dict], prefix: str | None) -> dict | None:
    """Find the target session: $CLAUDE_CODE_SESSION_ID, else an id prefix."""
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if session_id:
        matches = [s for s in sessions if s.get("sessionId") == session_id]
        # Inside a session the id is authoritative even if not on the board yet.
        return matches[0] if matches else {"sessionId": session_id}
    if prefix:
        matches = [s for s in sessions if (s.get("sessionId") or "").startswith(prefix)]
        if len(matches) == 1:
            return matches[0]
        kind = "ambiguous" if matches else "no"
        print(f"{kind} session match for {prefix!r}")
        return None
    print("not inside a Claude session - pass --session <id-prefix>")
    return None


def cmd_refresh() -> int:
    sessions = _read_sessions()
    if sessions is None:
        print("no snapshot — is the Scoreboard app running?")
        return 1
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if session_id:
        # Run from inside the session's tab: capture this terminal directly.
        adapter = terminals.detect()
        if adapter is None:
            print("unsupported terminal (no adapter)")
            return 1
        origin = adapter.capture_origin()
        if not origin:
            print("could not capture terminal (is the terminal focused?)")
            return 1
        client.send_event(
            {"v": 1, "session_id": session_id, "origin": origin, "ts": time.time()})
        print(f"linked session to {origin['kind']} terminal")
        return 0
    # Outside a session: match origin-less sessions to terminals by unique cwd.
    origins = []
    for adapter_cls in terminals.ADAPTERS:
        origins.extend(adapter_cls().list_origins())
    fixed = 0
    for session in sessions:
        if session.get("origin"):
            continue
        matches = [o for o, cwd in origins if cwd == session.get("cwd")]
        label = f"{session.get('title')} ({(session.get('sessionId') or '')[:8]})"
        if len(matches) == 1:
            client.send_event(
                {"v": 1, "session_id": session["sessionId"], "origin": matches[0],
                 "ts": time.time()})
            print(f"linked   {label}")
            fixed += 1
        else:
            state = "ambiguous cwd" if matches else "no terminal match"
            print(f"skipped  {label}: {state}")
    if fixed == 0 and all(s.get("origin") for s in sessions):
        print("all sessions already linked")
    return 0


def cmd_rename(name: str, prefix: str | None) -> int:
    sessions = _read_sessions()
    if sessions is None:
        print("no snapshot — is the Scoreboard app running?")
        return 1
    session = _resolve_session(sessions, prefix)
    if session is None:
        return 1
    client.send_event(
        {"v": 1, "session_id": session["sessionId"], "title": name,
         "title_pinned": True, "ts": time.time()})
    print(f"renamed to {name!r}")
    return 0


def _age(ts: float) -> str:
    seconds = max(0, int(time.time() - ts))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


def cmd_state() -> int:
    if not os.path.exists(SNAPSHOT_PATH):
        print("no snapshot — is the Scoreboard app running?")
        return 1
    with open(SNAPSHOT_PATH) as f:
        snapshot = json.load(f)
    sessions = snapshot.get("sessions") or []
    if not sessions:
        print("no Claude sessions")
        return 0
    for s in sorted(sessions, key=lambda s: -(s.get("updatedAt") or 0)):
        print(
            f"{s.get('state', '?'):8s} {s.get('title', '?'):24s} "
            f"pid={s.get('pid', 0):<7d} age={_age(s.get('updatedAt') or 0):6s} "
            f"{s.get('sessionId', '?')}"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="scoreboard")
    sub = parser.add_subparsers(dest="command", required=True)
    p_init = sub.add_parser("init", help="register Claude Code hooks")
    p_init.add_argument("--remove", action="store_true", help="unregister hooks")
    sub.add_parser("hook", help="hook entrypoint (reads JSON on stdin)")
    sub.add_parser("state", help="print current sessions")
    sub.add_parser("refresh", help="re-link sessions to their terminals")
    p_rename = sub.add_parser("rename", help="rename a session's menu row")
    p_rename.add_argument("name")
    p_rename.add_argument("--session", help="session id prefix (when outside a session)")
    args = parser.parse_args()

    if args.command == "hook":
        return cmd_hook()
    if args.command == "init":
        return cmd_init(args.remove)
    if args.command == "refresh":
        return cmd_refresh()
    if args.command == "rename":
        return cmd_rename(args.name, args.session)
    return cmd_state()


if __name__ == "__main__":
    sys.exit(main())
