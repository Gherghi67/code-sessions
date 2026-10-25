#!/usr/bin/env python3
"""Regression coverage for the engine-profile migration, using temporary homes."""
import importlib.util
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("shared_config", Path(__file__).resolve().parents[1] / "scripts/shared-config.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class SharedConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.profile = self.home / ".local/share/code-sessions/home"

    def put(self, root, path, data):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(data)
        return target

    def test_dry_run_writes_nothing(self):
        source = self.put(self.profile, ".claude/projects/project/thread.jsonl", '{}\n')
        result = migration.migrate(self.home)
        self.assertEqual(result["imported"][".claude/projects"], 1)
        self.assertFalse((self.home / ".claude").exists())
        self.assertTrue(source.exists())

    def test_missing_rollout_preserves_live_appends_and_rerun_is_empty(self):
        source = self.put(self.profile, ".codex/sessions/2026/rollout.jsonl", '{}\n')
        migration.migrate(self.home, True)
        with source.open("a") as stream:
            stream.write('{"next":1}\n')
        target = self.home / ".codex/sessions/2026/rollout.jsonl"
        self.assertEqual(target.read_text(), source.read_text())
        self.assertEqual(migration.migrate(self.home, True)["imported"][".codex/sessions"], 0)

    def test_existing_longer_transcript_wins(self):
        self.put(self.profile, ".claude/projects/project/thread.jsonl", '{}\n')
        target = self.put(self.home, ".claude/projects/project/thread.jsonl", '{}\n{"new":1}\n')
        result = migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{}\n{"new":1}\n')
        self.assertEqual(result["conflicts_kept_in_profile"], [])

    def test_divergent_transcripts_are_preserved_and_reported(self):
        source = self.put(self.profile, ".claude/projects/project/thread.jsonl", '{"source":1}\n')
        target = self.put(self.home, ".claude/projects/project/thread.jsonl", '{"target":1}\n')
        result = migration.migrate(self.home, True)
        self.assertEqual(source.read_text(), '{"source":1}\n')
        self.assertEqual(target.read_text(), '{"target":1}\n')
        self.assertEqual(len(result["conflicts_kept_in_profile"]), 1)

    def test_symlink_destination_cannot_escape_home(self):
        self.put(self.profile, ".claude/projects/project/thread.jsonl", '{}\n')
        outside = self.home / "outside"
        outside.mkdir()
        (self.home / ".claude").mkdir()
        (self.home / ".claude/projects").symlink_to(outside)
        with self.assertRaises(ValueError):
            migration.migrate(self.home, True)
        self.assertEqual(list(outside.iterdir()), [])

    def test_history_deduplicates_and_ignores_incomplete_source_record(self):
        self.put(self.profile, ".codex/history.jsonl", '{"id":1}\n{"id":2}\n{"incomplete":')
        target = self.put(self.home, ".codex/history.jsonl", '{"id":1}\n')
        migration.migrate(self.home, True)
        migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{"id":1}\n{"id":2}\n')

    def database(self, root, rows):
        path = root / ".codex/state_5.sqlite"
        path.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(path)) as db, db:
            db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, title TEXT)")
            db.executemany("INSERT INTO threads VALUES (?,?,?)", rows)
        return path

    def test_sqlite_import_keeps_existing_threads_and_rewrites_only_rollout_path(self):
        src = self.database(self.profile, [("new", str(self.profile / ".codex/sessions/new.jsonl"), "source"),
                                            ("same", "/old/rollout", "do not replace")])
        dst = self.database(self.home, [("same", "/normal/rollout", "keep")])
        count = migration.merge_threads(src, dst, self.home, True, None)
        self.assertEqual(count, 1)
        with closing(sqlite3.connect(dst)) as db:
            self.assertEqual(db.execute("SELECT title FROM threads WHERE id='same'").fetchone()[0], "keep")
            self.assertEqual(db.execute("SELECT rollout_path FROM threads WHERE id='new'").fetchone()[0],
                             str(self.home / ".codex/sessions/new.jsonl"))
        self.assertEqual(migration.merge_threads(src, dst, self.home, True, None), 0)

    def test_schema_mismatch_rolls_back(self):
        src = self.database(self.profile, [("new", "/rollout", "source")])
        dst = self.database(self.home, [])
        with closing(sqlite3.connect(dst)) as db, db:
            db.execute("ALTER TABLE threads ADD COLUMN extra TEXT")
        with self.assertRaises(ValueError):
            migration.merge_threads(src, dst, self.home, True, None)
        with closing(sqlite3.connect(dst)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM threads").fetchone()[0], 0)

    def test_config_and_credentials_are_untouched(self):
        for name in ("auth.json", "config.toml", "hooks.json"):
            self.put(self.profile, ".codex/" + name, "profile")
            self.put(self.home, ".codex/" + name, "normal")
        migration.migrate(self.home, True)
        for name in ("auth.json", "config.toml", "hooks.json"):
            self.assertEqual((self.home / ".codex" / name).read_text(), "normal")

    def test_project_trust_import_preserves_account_and_existing_entries(self):
        self.put(self.profile, ".claude/.claude.json", json.dumps({
            "oauthAccount": "old", "projects": {"new": {"trusted": True}, "same": "old"}}))
        target = self.put(self.home, ".claude.json", json.dumps({
            "oauthAccount": "normal", "projects": {"same": "keep"}}))
        migration.migrate(self.home, True)
        result = json.loads(target.read_text())
        self.assertEqual(result["oauthAccount"], "normal")
        self.assertEqual(result["projects"], {"same": "keep", "new": {"trusted": True}})

    def test_native_project_lock_prevents_overwrite(self):
        self.put(self.profile, ".claude/.claude.json", '{"projects":{"new":{}}}')
        target = self.put(self.home, ".claude.json", '{"projects":{}}')
        (self.home / ".claude.json.lock").mkdir()
        with self.assertRaises(FileExistsError):
            migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{"projects":{}}')


if __name__ == "__main__":
    unittest.main()
