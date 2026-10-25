#!/usr/bin/env python3
"""Regression coverage for the engine-profile migration, using temporary homes."""
import importlib.util
from contextlib import closing
import errno
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
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

    def test_backup_restores_deployment_retirement_and_completion_targets(self):
        files = {
            ".local/bin/ccs": ("old launcher", 0o751),
            ".local/bin/code-sessions": ("old named launcher", 0o755),
            ".local/bin/cs-tui.exe": ("old picker", 0o700),
            ".codex/hooks/cs/cs-shared.sh": ("old recovery", 0o750),
            ".claude/hooks/narrative-precompact.sh": ("old flat hook", 0o755),
            ".claude/hooks/session-start.sh": ("old active flat hook", 0o755),
            ".claude/hooks/cs/.version": ("old version", 0o644),
            ".claude/skills/voice/SKILL.md": ("old retired skill", 0o640),
            ".claude/skills/cs/hooks/register.tsx": ("old mod", 0o644),
            ".codex/skills/finish/SKILL.md": ("old codex skill", 0o644),
            ".bash_completion.d/cs.bash": ("old bash completion", 0o644),
            ".zsh/completion/_cs": ("old singular completion", 0o644),
            ".zsh/completions/_cs": ("old plural completion", 0o644),
            ".bash_login": ("old login", 0o600),
            ".config/cs/installed": ("old ownership", 0o600),
        }
        for relative, (content, mode) in files.items():
            self.put(self.home, relative, content).chmod(mode)
        link = self.home / ".claude/skills/rotate"
        link.symlink_to("../custom-rotate")
        self.put(self.home, ".codex/auth.json", "private login")
        self.put(self.home, ".claude/.credentials.json", "private credential")
        saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        for relative, (content, mode) in files.items():
            with self.subTest(path=relative):
                snapshot = saved / relative
                self.assertTrue(snapshot.is_file(), f"backup omitted {relative}")
                current = self.home / relative
                current.write_text("overwritten by install")
                current.chmod(0o644)
                migration.shutil.copy2(snapshot, current)
                self.assertEqual(current.read_text(), content)
                self.assertEqual(current.stat().st_mode & 0o777, mode)
        link.unlink()
        self.assertTrue((saved / ".claude/skills/rotate").is_symlink())
        link.symlink_to(os.readlink(saved / ".claude/skills/rotate"))
        self.assertEqual(os.readlink(link), "../custom-rotate")
        self.assertFalse((saved / ".codex/auth.json").exists())
        self.assertFalse((saved / ".claude/.credentials.json").exists())

    def test_backup_reads_current_and_retired_targets_from_checkout_manifest(self):
        checkout = self.home / "checkout"
        (checkout / "lib").mkdir(parents=True)
        (checkout / "skills").mkdir()
        (checkout / "mods").mkdir()
        manifest = (Path(SPEC.origin).parent.parent / "lib/01-manifests.sh").read_text()
        (checkout / "lib/01-manifests.sh").write_text(manifest + """
RETIRED_HOOKS+=(fixture-retired-hook.sh)
RETIRED_SKILLS+=(fixture-retired-skill)
CS_SKILLS+=(fixture-active-skill)
CS_HOOKS+=(fixture-active-hook.sh)
""")
        paths = [".claude/hooks/fixture-retired-hook.sh", ".claude/hooks/fixture-active-hook.sh",
                 ".claude/skills/fixture-retired-skill/SKILL.md", ".claude/skills/fixture-active-skill/SKILL.md",
                 ".codex/skills/fixture-active-skill/SKILL.md"]
        for relative in paths:
            self.put(self.home, relative, "old managed file")
        saved = migration.backup(self.home, checkout)
        for relative in paths:
            with self.subTest(path=relative):
                self.assertTrue((saved / relative).is_file(), f"backup omitted manifest target {relative}")

    def test_backup_captures_external_zsh_startup_link_and_its_referent(self):
        external = tempfile.TemporaryDirectory()
        self.addCleanup(external.cleanup)
        directory = Path(external.name).resolve()
        actual = self.put(directory, "dotfiles/startup", "old external startup")
        actual.chmod(0o640)
        selected = directory / "selected/.zshrc"
        selected.parent.mkdir()
        selected.symlink_to("../dotfiles/startup")
        with mock.patch.dict(os.environ, {"SHELL": "/bin/zsh", "ZDOTDIR": str(selected.parent)}):
            saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        self.assertTrue((saved / "manifest.json").is_file(), "backup lacks an absolute path restoration map")
        entries = {entry["source"]: entry for entry in json.loads((saved / "manifest.json").read_text())["entries"]}
        self.assertIn(str(selected), entries)
        self.assertIn(str(actual), entries)
        link_snapshot = saved / entries[str(selected)]["backup"]
        self.assertTrue(link_snapshot.is_symlink())
        self.assertEqual(os.readlink(link_snapshot), "../dotfiles/startup")
        actual.write_text("appended by setup")
        selected.unlink()
        migration.shutil.copy2(saved / entries[str(actual)]["backup"], actual)
        selected.symlink_to(os.readlink(link_snapshot))
        self.assertEqual(selected.read_text(), "old external startup")
        self.assertEqual(actual.stat().st_mode & 0o777, 0o640)

    def test_backup_restores_linked_settings_after_the_native_settings_writer(self):
        external = tempfile.TemporaryDirectory()
        self.addCleanup(external.cleanup)
        actual = self.put(Path(external.name).resolve(), "settings.json", '{"env":{"KEEP":"yes"}}\n')
        actual.chmod(0o640)
        logical = self.home / ".claude/settings.json"
        logical.parent.mkdir()
        logical.symlink_to(actual)
        saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        script = 'source "$1"; cs_settings_update "$2" jq \'.env.CHANGED = "yes"\''
        result = subprocess.run(["bash", "-c", script, "settings-fixture",
                                 str(Path(SPEC.origin).parent.parent / "hooks/cs-shared.sh"), str(logical)],
                                env={"HOME": str(self.home), "PATH": os.environ["PATH"]},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(actual.read_text())["env"]["CHANGED"], "yes")
        entries = {entry["source"]: entry for entry in json.loads((saved / "manifest.json").read_text())["entries"]}
        self.assertTrue(str(actual) in entries, "write-through settings referent was not backed up")
        migration.shutil.copy2(saved / entries[str(actual)]["backup"], actual)
        logical.unlink()
        logical.symlink_to(os.readlink(saved / ".claude/settings.json"))
        self.assertEqual(logical.read_text(), '{"env":{"KEEP":"yes"}}\n')
        self.assertEqual(actual.stat().st_mode & 0o777, 0o640)

    def test_backup_captures_writable_directory_links_and_nested_answer_referents(self):
        external = tempfile.TemporaryDirectory()
        self.addCleanup(external.cleanup)
        directory = Path(external.name).resolve()
        originals = {}
        for relative, name in [(".claude/hooks/cs", "claude-hooks"), (".codex/hooks/cs", "codex-hooks"),
                               (".config/cs", "config")]:
            actual = directory / name
            actual.mkdir()
            original = self.put(actual, ".installed", "old owned files")
            original.chmod(0o640)
            logical = self.home / relative
            logical.parent.mkdir(parents=True, exist_ok=True)
            logical.symlink_to(actual)
            originals[actual] = original
        answers = []
        for name in ("option-keys", "statusline-caps"):
            actual = self.put(directory, "answers/" + name, "old answer")
            actual.chmod(0o640)
            (directory / "config" / name).symlink_to(actual)
            answers.append(actual)
        marker = self.put(directory, "engines", "claude\n")
        logical_marker = self.home / ".local/bin/.cs-install-engines"
        logical_marker.parent.mkdir(parents=True)
        logical_marker.symlink_to(marker)
        saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        entries = {entry["source"]: entry for entry in json.loads((saved / "manifest.json").read_text())["entries"]}
        for actual, original in originals.items():
            with self.subTest(directory=actual.name):
                self.assertTrue(str(actual) in entries, f"directory referent omitted: {actual.name}")
                original.write_text("overwritten")
                original.chmod(0o644)
                migration.shutil.copy2(saved / entries[str(actual)]["backup"] / ".installed", original)
                self.assertEqual(original.read_text(), "old owned files")
                self.assertEqual(original.stat().st_mode & 0o777, 0o640)
        for actual in (*answers, marker):
            with self.subTest(referent=actual.name):
                self.assertTrue(str(actual) in entries, f"file referent omitted: {actual.name}")
                old = actual.read_text()
                actual.write_text("overwritten")
                migration.shutil.copy2(saved / entries[str(actual)]["backup"], actual)
                self.assertEqual(actual.read_text(), old)
        self.assertTrue(logical_marker.is_symlink())
        self.assertTrue((directory / "config/option-keys").is_symlink())

    def test_backup_records_a_dangling_startup_links_missing_referent(self):
        missing = self.home / "dotfiles/zshrc"
        missing.parent.mkdir()
        startup = self.home / ".zshrc"
        startup.symlink_to(missing)
        saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        entries = {entry["source"]: entry for entry in json.loads((saved / "manifest.json").read_text())["entries"]}
        self.assertTrue(str(missing.resolve()) in entries, "missing startup referent omitted")
        self.assertEqual(entries[str(missing.resolve())]["kind"], "missing")
        self.assertIsNone(entries[str(missing.resolve())]["backup"])
        missing.write_text("created by setup append")
        if entries[str(missing.resolve())]["kind"] == "missing":
            missing.unlink()
        self.assertTrue(startup.is_symlink())
        self.assertFalse(startup.exists())

    def test_backup_refuses_a_directory_referent_containing_its_own_destination(self):
        config = self.home / ".config/cs"
        config.parent.mkdir()
        config.symlink_to(self.home)
        with self.assertRaisesRegex(ValueError, "recursive backup"):
            migration.backup(self.home, Path(SPEC.origin).parent.parent)

    def test_backup_preserves_a_skill_link_without_following_its_arbitrary_directory(self):
        skill = self.home / ".claude/skills/rotate"
        skill.parent.mkdir(parents=True)
        skill.symlink_to(self.home)
        saved = migration.backup(self.home, Path(SPEC.origin).parent.parent)
        self.assertTrue((saved / ".claude/skills/rotate").is_symlink())
        self.assertEqual(os.readlink(saved / ".claude/skills/rotate"), str(self.home))
        sources = {entry["source"] for entry in json.loads((saved / "manifest.json").read_text())["entries"]}
        self.assertNotIn(str(self.home.resolve()), sources)

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

    def test_history_import_makes_an_existing_public_file_private(self):
        source = self.put(self.profile, ".codex/history.jsonl", '{"private":1}\n')
        source.chmod(0o600)
        target = self.put(self.home, ".codex/history.jsonl", '{"normal":1}\n')
        target.chmod(0o644)
        target.parent.chmod(0o755)
        previous = os.umask(0o022)
        try:
            self.assertEqual(migration.merge_jsonl(source, target, self.home, True), 1)
        finally:
            os.umask(previous)
        self.assertEqual(target.read_text(), '{"normal":1}\n{"private":1}\n')
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(target.parent.stat().st_mode & 0o777, 0o755)

    def test_history_dry_run_preserves_existing_file_permissions(self):
        source = self.put(self.profile, ".codex/history.jsonl", '{"private":1}\n')
        target = self.put(self.home, ".codex/history.jsonl", '{"normal":1}\n')
        target.chmod(0o644)
        self.assertEqual(migration.merge_jsonl(source, target, self.home, False), 1)
        self.assertEqual(target.read_text(), '{"normal":1}\n')
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)

    def history_process(self, source, target):
        script = """
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('migration', sys.argv[1])
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
print('ready', flush=True)
print(migration.merge_jsonl(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), True))
"""
        return subprocess.Popen([sys.executable, "-B", "-c", script, str(SPEC.origin),
                                 str(source), str(target), str(self.home)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_history_waits_for_native_lock_and_rereads_compacted_records(self):
        source = self.put(self.profile, ".codex/history.jsonl", '{"id":2}\n')
        target = self.put(self.home, ".codex/history.jsonl", '{"id":1}\n')
        for retained, expected_count in [('{"native":1}\n', 1), ('{"id":2}\n', 0)]:
            with self.subTest(retained=retained), target.open("r+b") as native:
                fcntl.flock(native, fcntl.LOCK_EX)
                child = self.history_process(source, target)
                try:
                    self.assertEqual(child.stdout.readline(), "ready\n")
                    try:
                        child.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        blocked = True
                    else:
                        blocked = False
                    native.seek(0)
                    native.truncate()
                    native.write(retained.encode())
                    native.flush()
                    fcntl.flock(native, fcntl.LOCK_UN)
                    output, errors = child.communicate(timeout=5)
                    self.assertEqual(child.returncode, 0, errors)
                    self.assertTrue(blocked, "history import ignored the native writer's file lock")
                    self.assertEqual(int(output.strip()), expected_count)
                    self.assertEqual(target.read_text(), retained + ('{"id":2}\n' if expected_count else ""))
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()

    def test_concurrent_history_imports_append_each_record_once(self):
        source = self.put(self.profile, ".codex/history.jsonl", '{"id":2}\n')
        target = self.put(self.home, ".codex/history.jsonl", '{"id":1}\n')
        children = []
        try:
            with target.open("r+b") as native:
                fcntl.flock(native, fcntl.LOCK_EX)
                for _ in range(2):
                    child = self.history_process(source, target)
                    children.append(child)
                    self.assertEqual(child.stdout.readline(), "ready\n")
                fcntl.flock(native, fcntl.LOCK_UN)
            counts = []
            for child in children:
                output, errors = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, errors)
                counts.append(int(output.strip()))
            self.assertEqual(sorted(counts), [0, 1])
            self.assertEqual(target.read_text(), '{"id":1}\n{"id":2}\n')
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    def test_incomplete_destination_history_is_preserved_without_appending(self):
        source = self.put(self.profile, ".codex/history.jsonl", '{"id":2}\n')
        target = self.put(self.home, ".codex/history.jsonl", '{"incomplete":')
        with self.assertRaisesRegex(ValueError, "Incomplete destination record"):
            migration.merge_jsonl(source, target, self.home, True)
        self.assertEqual(target.read_text(), '{"incomplete":')

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

    def test_project_lock_takeover_preserves_successor_config_and_lock(self):
        self.put(self.profile, ".claude/.claude.json", '{"projects":{"new":{}}}')
        target = self.put(self.home, ".claude.json", '{"oauthAccount":"normal","projects":{}}')
        lock = self.home / ".claude.json.lock"
        abandoned = self.home / ".claude.json.abandoned-lock"
        dump = json.dump

        def takeover(document, stream, **options):
            lock.rename(abandoned)
            lock.mkdir()
            target.write_text('{"oauthAccount":"successor","projects":{"native":{}}}')
            return dump(document, stream, **options)

        with mock.patch.object(migration.json, "dump", side_effect=takeover):
            with self.assertRaisesRegex(ValueError, "Lost Claude config lock"):
                migration.merge_project_settings(self.profile, self.home, True)
        self.assertEqual(target.read_text(), '{"oauthAccount":"successor","projects":{"native":{}}}')
        self.assertTrue(lock.is_dir())
        self.assertEqual(list(lock.iterdir()), [])

    def test_project_lock_heartbeats_while_config_is_serialized(self):
        self.put(self.profile, ".claude/.claude.json", '{"projects":{"new":{}}}')
        target = self.put(self.home, ".claude.json", '{"projects":{}}')
        lock = self.home / ".claude.json.lock"
        dump = json.dump

        def slow_dump(document, stream, **options):
            os.utime(lock, ns=(0, 0))
            deadline = time.monotonic() + 0.5
            while lock.stat().st_mtime_ns == 0 and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertGreater(lock.stat().st_mtime_ns, 0, "native config lock became stale during serialization")
            return dump(document, stream, **options)

        with mock.patch.object(migration, "CLAUDE_LOCK_HEARTBEAT_SECONDS", 0.01, create=True), \
                mock.patch.object(migration.json, "dump", side_effect=slow_dump):
            self.assertEqual(migration.merge_project_settings(self.profile, self.home, True), 1)
        self.assertEqual(json.loads(target.read_text())["projects"], {"new": {}})
        self.assertFalse(lock.exists())

    def test_project_import_counts_only_entries_missing_after_lock_acquisition(self):
        self.put(self.profile, ".claude/.claude.json", '{"projects":{"new":"old"}}')
        target = self.put(self.home, ".claude.json", '{"projects":{}}')
        lock = self.home / ".claude.json.lock"
        mkdir = Path.mkdir

        def native_update(path, *args, **options):
            result = mkdir(path, *args, **options)
            if path == lock:
                target.write_text('{"projects":{"new":"normal"}}')
            return result

        with mock.patch.object(Path, "mkdir", native_update):
            count = migration.merge_project_settings(self.profile, self.home, True)
        self.assertEqual(count, 0)
        self.assertEqual(json.loads(target.read_text())["projects"], {"new": "normal"})


if __name__ == "__main__":
    unittest.main()
