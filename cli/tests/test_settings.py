import glob
import json
import os
import tempfile
import unittest

from scoreboard import settings


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "settings.json")

    def read(self):
        with open(self.path) as f:
            return json.load(f)

    def test_merge_into_missing_file(self):
        added = settings.merge(self.path)
        self.assertEqual(sorted(added), sorted(settings.ALL_EVENTS))
        data = self.read()
        for event in settings.PLAIN_EVENTS:
            self.assertEqual(
                data["hooks"][event],
                [{"hooks": [{"type": "command", "command": "scoreboard hook"}]}],
            )
        for event in settings.MATCHED_EVENTS:
            self.assertEqual(
                data["hooks"][event],
                [
                    {
                        "matcher": "AskUserQuestion",
                        "hooks": [{"type": "command", "command": "scoreboard hook"}],
                    }
                ],
            )

    def test_merge_preserves_user_hooks(self):
        original = {
            "model": "opus",
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "mytool notify"}]}]
            },
        }
        with open(self.path, "w") as f:
            json.dump(original, f)
        settings.merge(self.path)
        data = self.read()
        self.assertEqual(data["model"], "opus")
        self.assertEqual(
            data["hooks"]["Stop"][0]["hooks"][0]["command"], "mytool notify"
        )
        self.assertEqual(
            data["hooks"]["Stop"][1]["hooks"][0]["command"], "scoreboard hook"
        )

    def test_double_merge_is_noop(self):
        settings.merge(self.path)
        first = self.read()
        added = settings.merge(self.path)
        self.assertEqual(added, [])
        self.assertEqual(self.read(), first)

    def test_foreign_pretooluse_matcher_still_gets_ours(self):
        original = {
            "hooks": {
                "PreToolUse": [
                    {"matcher": "Bash", "hooks": [{"type": "command", "command": "x"}]}
                ]
            }
        }
        with open(self.path, "w") as f:
            json.dump(original, f)
        added = settings.merge(self.path)
        self.assertIn("PreToolUse", added)
        entries = self.read()["hooks"]["PreToolUse"]
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1]["matcher"], "AskUserQuestion")

    def test_scan(self):
        self.assertFalse(any(settings.scan(self.path).values()))
        settings.merge(self.path)
        self.assertTrue(all(settings.scan(self.path).values()))

    def test_remove_strips_only_ours(self):
        with open(self.path, "w") as f:
            json.dump(
                {
                    "hooks": {
                        "Stop": [
                            {"hooks": [{"type": "command", "command": "mytool notify"}]}
                        ]
                    }
                },
                f,
            )
        settings.merge(self.path)
        removed = settings.remove(self.path)
        self.assertEqual(sorted(removed), sorted(settings.ALL_EVENTS))
        data = self.read()
        self.assertEqual(list(data["hooks"]), ["Stop"])
        self.assertEqual(
            data["hooks"]["Stop"],
            [{"hooks": [{"type": "command", "command": "mytool notify"}]}],
        )

    def test_remove_deletes_empty_hooks_key(self):
        settings.merge(self.path)
        settings.remove(self.path)
        self.assertNotIn("hooks", self.read())

    def test_remove_on_clean_file_is_noop(self):
        with open(self.path, "w") as f:
            json.dump({"model": "opus"}, f)
        self.assertEqual(settings.remove(self.path), [])

    def test_backup_created_with_original_bytes(self):
        original_text = '{"model": "opus"}'
        with open(self.path, "w") as f:
            f.write(original_text)
        settings.merge(self.path)
        backups = glob.glob(self.path + ".backup-*")
        self.assertEqual(len(backups), 1)
        with open(backups[0]) as f:
            self.assertEqual(f.read(), original_text)

    def test_result_always_parses(self):
        settings.merge(self.path)
        self.read()


if __name__ == "__main__":
    unittest.main()
