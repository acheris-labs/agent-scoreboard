import unittest

from scoreboard import mapping


def map_hook(payload):
    # Tests never touch a real terminal adapter.
    return mapping.map_hook(payload, detect_adapter=lambda: None)


class FakeAdapter:
    kind = "fake"

    def __init__(self, origin):
        self.origin = origin

    def capture_origin(self):
        return self.origin


def hook(name, **fields):
    return {"hook_event_name": name, "session_id": "s1", "cwd": "/tmp/proj", **fields}


class MapHookTests(unittest.TestCase):
    def assert_state(self, payload, state, reason=None):
        event = map_hook(payload)
        self.assertIsNotNone(event)
        self.assertEqual(event["state"], state)
        if reason is not None:
            self.assertEqual(event["reason"], reason)

    def test_session_start(self):
        self.assert_state(hook("SessionStart"), "idle", "session_start")

    def test_prompt_submit(self):
        self.assert_state(hook("UserPromptSubmit"), "running", "prompt")

    def test_stop(self):
        self.assert_state(hook("Stop"), "idle", "stop")

    def test_notification_idle_typed(self):
        payload = hook("Notification", notification_type="idle_prompt")
        self.assert_state(payload, "idle", "idle")

    def test_notification_idle_typeless_message(self):
        payload = hook("Notification", message="Claude is waiting for your input")
        self.assert_state(payload, "idle", "idle")

    def test_notification_permission_message_is_waiting(self):
        payload = hook("Notification", message="Claude needs your permission to use Bash")
        self.assert_state(payload, "waiting", "notification")

    def test_notification_typed_non_idle_is_waiting(self):
        payload = hook(
            "Notification",
            notification_type="permission",
            message="finished setting up, needs permission",
        )
        self.assert_state(payload, "waiting", "notification")

    def test_permission_request(self):
        self.assert_state(
            hook("PermissionRequest", tool_name="Bash"), "waiting", "permission_request"
        )

    def test_permission_request_ask_question(self):
        payload = hook("PermissionRequest", tool_name="AskUserQuestion")
        self.assert_state(payload, "waiting", "question")

    def test_pre_tool_use_ask_question(self):
        payload = hook("PreToolUse", tool_name="AskUserQuestion")
        self.assert_state(payload, "waiting", "question")

    def test_pre_tool_use_other_tools_ignored(self):
        self.assertIsNone(map_hook(hook("PreToolUse", tool_name="Bash")))

    def test_stop_failure(self):
        self.assert_state(hook("StopFailure"), "error")

    def test_session_end(self):
        self.assert_state(hook("SessionEnd"), "ended", "session_end")

    def test_unknown_event_ignored(self):
        self.assertIsNone(map_hook(hook("PostToolUse")))

    def test_missing_session_id_ignored(self):
        self.assertIsNone(map_hook({"hook_event_name": "Stop"}))

    def test_garbage_payloads_never_raise(self):
        for garbage in (None, [], "str", 42, {}, {"session_id": 7}):
            self.assertIsNone(map_hook(garbage))

    def test_event_shape(self):
        event = map_hook(hook("Stop"))
        self.assertEqual(event["v"], 1)
        self.assertEqual(event["session_id"], "s1")
        self.assertEqual(event["title"], "proj")
        self.assertEqual(event["cwd"], "/tmp/proj")
        self.assertIsInstance(event["pid"], int)
        self.assertIsInstance(event["ts"], float)

    def test_missing_cwd_gets_fallback_title(self):
        event = map_hook({"hook_event_name": "Stop", "session_id": "s1"})
        self.assertEqual(event["title"], "claude")

    def test_origin_captured_on_session_start(self):
        origin = {"kind": "fake", "terminal_id": "T-1"}
        event = mapping.map_hook(
            hook("SessionStart"), detect_adapter=lambda: FakeAdapter(origin))
        self.assertEqual(event["origin"], origin)

    def test_origin_not_captured_on_other_events(self):
        adapter = FakeAdapter({"kind": "fake", "terminal_id": "T-1"})
        for name in ("UserPromptSubmit", "Stop", "SessionEnd"):
            event = mapping.map_hook(hook(name), detect_adapter=lambda: adapter)
            self.assertNotIn("origin", event, name)

    def test_origin_absent_when_capture_fails(self):
        event = mapping.map_hook(
            hook("SessionStart"), detect_adapter=lambda: FakeAdapter(None))
        self.assertNotIn("origin", event)

    def test_origin_absent_when_no_adapter(self):
        event = map_hook(hook("SessionStart"))
        self.assertNotIn("origin", event)


if __name__ == "__main__":
    unittest.main()
