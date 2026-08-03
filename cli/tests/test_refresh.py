import json
import os
import tempfile
import unittest
from unittest import mock

from scoreboard import main


def session(session_id, cwd, origin=None):
    s = {"sessionId": session_id, "state": "idle", "title": os.path.basename(cwd),
         "cwd": cwd, "pid": 1, "updatedAt": 0}
    if origin:
        s["origin"] = origin
    return s


class FakeAdapter:
    kind = "fake"
    origins = []

    def list_origins(self):
        return list(type(self).origins)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.snapshot = os.path.join(self.tmp.name, "state.json")
        self.sent = []
        patches = [
            mock.patch.object(main, "SNAPSHOT_PATH", self.snapshot),
            mock.patch.object(main.client, "send_event", self.sent.append),
            mock.patch.object(main.terminals, "ADAPTERS", [FakeAdapter]),
            mock.patch.dict(os.environ, {}, clear=False),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        os.environ.pop("CLAUDE_CODE_SESSION_ID", None)

    def write_snapshot(self, sessions):
        with open(self.snapshot, "w") as f:
            json.dump({"sessions": sessions}, f)

    def test_unique_cwd_match_links_session(self):
        self.write_snapshot([session("s1", "/proj/a")])
        FakeAdapter.origins = [({"kind": "fake", "terminal_id": "T1"}, "/proj/a")]
        self.assertEqual(main.cmd_refresh(), 0)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["session_id"], "s1")
        self.assertEqual(self.sent[0]["origin"]["terminal_id"], "T1")
        self.assertNotIn("state", self.sent[0])

    def test_ambiguous_cwd_skipped(self):
        self.write_snapshot([session("s1", "/proj/a")])
        FakeAdapter.origins = [
            ({"kind": "fake", "terminal_id": "T1"}, "/proj/a"),
            ({"kind": "fake", "terminal_id": "T2"}, "/proj/a"),
        ]
        main.cmd_refresh()
        self.assertEqual(self.sent, [])

    def test_no_match_skipped(self):
        self.write_snapshot([session("s1", "/proj/a")])
        FakeAdapter.origins = [({"kind": "fake", "terminal_id": "T1"}, "/proj/b")]
        main.cmd_refresh()
        self.assertEqual(self.sent, [])

    def test_already_linked_untouched(self):
        self.write_snapshot(
            [session("s1", "/proj/a", origin={"kind": "fake", "terminal_id": "T0"})])
        FakeAdapter.origins = [({"kind": "fake", "terminal_id": "T1"}, "/proj/a")]
        main.cmd_refresh()
        self.assertEqual(self.sent, [])

    def test_no_snapshot_errors(self):
        self.assertEqual(main.cmd_refresh(), 1)

    def test_rename_inside_session(self):
        self.write_snapshot([session("s1", "/proj/a")])
        os.environ["CLAUDE_CODE_SESSION_ID"] = "s1"
        self.assertEqual(main.cmd_rename("my-task", None), 0)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["title"], "my-task")
        self.assertTrue(self.sent[0]["title_pinned"])
        self.assertNotIn("state", self.sent[0])

    def test_rename_by_prefix(self):
        self.write_snapshot([session("abc123", "/proj/a"), session("def456", "/proj/b")])
        self.assertEqual(main.cmd_rename("x", "abc"), 0)
        self.assertEqual(self.sent[0]["session_id"], "abc123")

    def test_rename_ambiguous_prefix_fails(self):
        self.write_snapshot([session("abc1", "/proj/a"), session("abc2", "/proj/b")])
        self.assertEqual(main.cmd_rename("x", "abc"), 1)
        self.assertEqual(self.sent, [])

    def test_rename_outside_session_without_prefix_fails(self):
        self.write_snapshot([session("s1", "/proj/a")])
        self.assertEqual(main.cmd_rename("x", None), 1)


if __name__ == "__main__":
    unittest.main()
