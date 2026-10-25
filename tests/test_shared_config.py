#!/usr/bin/env python3
"""Regression coverage for the engine-profile migration, using temporary homes."""
import importlib.util
from contextlib import closing
import errno
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

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

    def test_competing_transcript_creation_is_preserved_and_reported(self):
        self.put(self.profile, ".codex/sessions/rollout.jsonl", '{"old":1}\n')
        target = self.home / ".codex/sessions/rollout.jsonl"
        link = os.link

        def competing_link(source, destination):
            target.write_text('{"normal":1}\n')
            return link(source, destination)

        with mock.patch.object(migration.os, "link", side_effect=competing_link):
            result = migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{"normal":1}\n')
        self.assertEqual(result["imported"][".codex/sessions"], 0)
        self.assertEqual(result["conflicts_kept_in_profile"], [".codex/sessions/rollout.jsonl"])

    def test_cross_device_copy_does_not_replace_a_competing_transcript(self):
        source = self.put(self.profile, ".codex/sessions/rollout.jsonl", '{"old":1}\n')
        target = self.home / ".codex/sessions/rollout.jsonl"
        link = os.link

        def competing_link(src, dst):
            if Path(src) == source:
                target.write_text('{"normal":1}\n')
                raise OSError(errno.EXDEV, "different filesystems")
            return link(src, dst)

        with mock.patch.object(migration.os, "link", side_effect=competing_link):
            result = migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{"normal":1}\n')
        self.assertEqual(result["imported"][".codex/sessions"], 0)
        self.assertEqual(result["conflicts_kept_in_profile"], [".codex/sessions/rollout.jsonl"])
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_cross_device_transcript_copy_publishes_once(self):
        source = self.put(self.profile, ".codex/sessions/rollout.jsonl", '{"old":1}\n')
        target = self.home / ".codex/sessions/rollout.jsonl"
        link = os.link

        def cross_device_link(src, dst):
            if Path(src) == source:
                raise OSError(errno.EXDEV, "different filesystems")
            return link(src, dst)

        with mock.patch.object(migration.os, "link", side_effect=cross_device_link):
            result = migration.migrate(self.home, True)
        self.assertEqual(target.read_text(), '{"old":1}\n')
        self.assertEqual(result["imported"][".codex/sessions"], 1)
        self.assertEqual(result["conflicts_kept_in_profile"], [])
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_new_engine_history_paths_are_private_under_permissive_umask(self):
        self.put(self.profile, ".claude/projects/project/thread.jsonl", '{}\n').chmod(0o644)
        self.put(self.profile, ".claude/history.jsonl", '{"id":1}\n')
        self.put(self.profile, ".codex/sessions/2026/10/rollout.jsonl", '{}\n').chmod(0o644)
        self.put(self.profile, ".codex/history.jsonl", '{"id":1}\n')
        self.put(self.profile, ".codex/session_index.jsonl", '{"id":1}\n')
        self.database(self.profile, [("legacy", "/rollout", "private")])
        previous = os.umask(0o022)
        try:
            migration.migrate(self.home, True)
        finally:
            os.umask(previous)
        for engine in (".claude", ".codex"):
            root = self.home / engine
            for path in (root, *root.rglob("*")):
                with self.subTest(path=path.relative_to(self.home)):
                    self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)

    def test_cross_device_copy_does_not_publish_public_history_permissions(self):
        source = self.put(self.profile, ".codex/sessions/rollout.jsonl", '{}\n')
        source.chmod(0o664)
        target = self.home / ".codex/sessions/rollout.jsonl"
        link = os.link

        def cross_device_link(src, dst):
            if Path(src) == source:
                raise OSError(errno.EXDEV, "different filesystems")
            return link(src, dst)

        with mock.patch.object(migration.os, "link", side_effect=cross_device_link):
            migration.migrate(self.home, True)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_existing_engine_directory_and_readonly_source_permissions_are_preserved(self):
        source = self.put(self.profile, ".codex/sessions/rollout.jsonl", '{}\n')
        source.chmod(0o400)
        engine = self.home / ".codex"
        engine.mkdir(mode=0o755)
        engine.chmod(0o755)
        migration.migrate(self.home, True)
        self.assertEqual(engine.stat().st_mode & 0o777, 0o755)
        self.assertEqual(source.stat().st_mode & 0o777, 0o400)
        self.assertEqual((engine / "sessions/rollout.jsonl").stat().st_mode & 0o777, 0o400)

    def test_unexpected_link_failure_does_not_fall_back_to_copy(self):
        self.put(self.profile, ".codex/sessions/rollout.jsonl", '{"old":1}\n')
        target = self.home / ".codex/sessions/rollout.jsonl"
        with mock.patch.object(migration.os, "link", side_effect=PermissionError(errno.EACCES, "denied")):
            with self.assertRaises(PermissionError):
                migration.migrate(self.home, True)
        self.assertFalse(target.exists())

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

    def test_competing_database_creation_merges_without_losing_normal_threads(self):
        src = self.database(self.profile, [("legacy-thread", str(self.profile / ".codex/sessions/old.jsonl"), "old"),
                                            ("same", "/old/same", "old title")])
        dst = self.home / ".codex/state_5.sqlite"
        is_file = Path.is_file
        created = False

        def competing_creation(path):
            nonlocal created
            if path == dst and not created:
                created = True
                self.database(self.home, [("normal-thread", "/normal/thread", "normal"),
                                           ("same", "/normal/same", "normal title")])
                return False
            return is_file(path)

        with mock.patch.object(Path, "is_file", competing_creation):
            count = migration.merge_threads(src, dst, self.home, True, None)
        with closing(sqlite3.connect(dst)) as db:
            self.assertEqual(dict(db.execute("SELECT id, title FROM threads")),
                             {"normal-thread": "normal", "same": "normal title", "legacy-thread": "old"})
            self.assertEqual(db.execute("SELECT rollout_path FROM threads WHERE id='legacy-thread'").fetchone()[0],
                             str(self.home / ".codex/sessions/old.jsonl"))
        self.assertEqual(count, 1)
        self.assertEqual(list(dst.parent.iterdir()), [dst])

    def test_first_database_publication_rewrites_paths_and_cleans_private_copy(self):
        src = self.database(self.profile, [("legacy-thread", str(self.profile / ".codex/sessions/old.jsonl"), "old")])
        dst = self.home / ".codex/state_5.sqlite"
        self.assertEqual(migration.merge_threads(src, dst, self.home, True, None), 1)
        with closing(sqlite3.connect(dst)) as db:
            self.assertEqual(db.execute("SELECT rollout_path FROM threads").fetchone()[0],
                             str(self.home / ".codex/sessions/old.jsonl"))
        self.assertEqual(list(dst.parent.iterdir()), [dst])

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
