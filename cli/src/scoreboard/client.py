"""Deliver events to the Scoreboard app over its unix socket.

Fire-and-forget: one NDJSON line per connection, hard 250ms timeout,
never raises. Failures are logged to hook.log and the event is dropped —
the next hook for a live session restores its row.
"""

import datetime
import json
import os
import socket

from scoreboard.paths import LOG_PATH, SOCKET_PATH, STATE_DIR

SEND_TIMEOUT = 0.25


def log(message: str) -> None:
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        stamp = datetime.datetime.now().isoformat(timespec="seconds")
        with open(LOG_PATH, "a") as f:
            f.write(f"{stamp} {message}\n")
    except OSError:
        pass


def send_event(event: dict) -> bool:
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(SEND_TIMEOUT)
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps(event) + "\n").encode())
        log(
            f"sent {event.get('reason') or 'update'} ({event.get('state') or 'meta'})"
            f" for {event.get('session_id')}"
        )
        return True
    except OSError as exc:
        log(f"drop {event.get('reason')} for {event.get('session_id')}: {exc}")
        return False
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
