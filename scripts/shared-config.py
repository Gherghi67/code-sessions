#!/usr/bin/env python3
"""Bring the old engine profile's history into the user's normal configuration.

ABOUTME: Preserves existing records, imports missing conversations and Codex thread metadata.
ABOUTME: Leaves credentials, user preferences, session folders and the old profile in place.
"""
import argparse
from contextlib import closing, contextmanager
import datetime
import errno
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import threading


CLAUDE_LOCK_HEARTBEAT_SECONDS = 2


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.digest()


def safe_target(path, root):
    """Never write through a user link into another configuration."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError(f"Refusing linked destination: {parent}")
        if parent == root:
            return
    raise ValueError(f"Destination outside home: {path}")


def private_directory(path, home):
    """Create each missing parent privately without changing existing directories."""
    safe_target(path, home)
    current = home
    for part in path.relative_to(home).parts:
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            safe_target(current, home)
            if not current.is_dir():
                raise
        else:
            current.chmod(0o700)


def installation_targets(home, checkout):
    # Read the same current/retired lists as the installer. Folder enumeration
    # misses retired names and does not describe flat-layout hook cleanup.
    script = r'''
source "$1"
record() {
    local category="$1" value
    shift
    for value in "$@"; do printf '%s\0%s\0' "$category" "$value"; done
}
while IFS= read -r value; do record payload "$value"; done < <(_cs_payload_files)
record retired_hook "${RETIRED_HOOKS[@]}"
record retired_command "${RETIRED_COMMANDS[@]}"
record retired_skill "${RETIRED_SKILLS[@]}"
record completion "${CS_COMPLETION_FILES[@]}"
'''
    output = subprocess.run(["bash", "-c", script, "backup-manifest", str(checkout / "lib/01-manifests.sh")],
                            check=True, stdout=subprocess.PIPE).stdout.split(b"\0")[:-1]
    paths = {home / name for name in (".claude.json", ".zshrc", ".bashrc", ".bash_profile", ".bash_login",
             ".profile", ".claude/hooks/cs", ".codex/hooks/cs",
             ".claude/agents-sidebar-status/original-statusline", ".config/cs",
             ".local/bin/cs-tui", ".local/bin/cs-tui.exe", ".local/bin/ccs",
             ".local/bin/code-sessions", ".local/bin/.cs-install-engines")}
    for category, value in zip(output[::2], output[1::2]):
        category, value = category.decode(), value.decode()
        if category == "payload":
            folder, relative = value.split("/", 1)
            if folder == "bin":
                paths.add(home / ".local/bin" / relative)
            elif folder in ("hooks", "commands"):
                paths.add(home / ".claude" / folder / relative)
            elif folder in ("skills", "mods"):
                name = relative.split("/", 1)[0]
                paths.add(home / ".claude/skills" / name)
                if folder == "skills":
                    paths.add(home / ".codex/skills" / name)
        elif category in ("retired_hook", "retired_command", "retired_skill"):
            folder = {"retired_hook": "hooks", "retired_command": "commands", "retired_skill": "skills"}[category]
            paths.add(home / ".claude" / folder / value)
        elif category == "completion":
            name = Path(value).name
            folders = (".bash_completion.d",) if name.endswith(".bash") else (".zsh/completion", ".zsh/completions")
            paths.update(home / folder / name for folder in folders)
    for engine in (".claude", ".codex"):
        paths.update(home / engine / name for name in ("settings.json", "hooks.json", "config.toml", "keybindings.json"))
    startup = {home / name for name in (".zshrc", ".bashrc", ".bash_profile", ".bash_login", ".profile")}
    if Path(os.environ.get("SHELL", "/bin/sh")).name == "zsh":
        directory = Path(os.environ.get("ZDOTDIR") or home)
        if not directory.is_absolute():
            directory = checkout / directory
        startup.add(directory / ".zshrc")
    paths.update(startup)
    # These writers follow links: native settings/keybinding updates, answer
    # and engine markers, and payload placement through managed directories.
    # Skill directory links are deliberately kept by the installer instead.
    write_through = startup | {home / name for name in (
        ".claude/settings.json", ".claude/keybindings.json", ".codex/config.toml",
        ".claude/agents-sidebar-status/original-statusline", ".local/bin/.cs-install-engines",
        ".claude/hooks/cs", ".codex/hooks/cs", ".config/cs",
        ".config/cs/option-keys", ".config/cs/statusline-caps")}
    # A dangling link's final target is also recorded as missing, so rollback
    # can remove a file the install creates there while retaining the old link.
    paths.update(path.resolve() for path in write_through)
    return sorted({Path(os.path.abspath(path)) for path in paths})


def backup(home, checkout):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    root = home / ".local/share/code-sessions/backups" / stamp
    private_directory(root, home)
    entries = []
    paths = installation_targets(home, checkout)
    for path in paths:
        if path.is_dir() and not path.is_symlink():
            try:
                root.resolve().relative_to(path.resolve())
            except ValueError:
                continue
            raise ValueError(f"Refusing recursive backup from {path} into {root}")
    for path in paths:
        try:
            relative = path.relative_to(home)
        except ValueError:
            relative = Path("external") / hashlib.sha256(str(path).encode()).hexdigest() / path.name
        entry = {"source": str(path), "backup": str(relative)}
        entries.append(entry)
        if not path.exists() and not path.is_symlink():
            entry.update(kind="missing", backup=None)
            continue
        target = root / relative
        private_directory(target.parent, root)
        entry["kind"] = "symlink" if path.is_symlink() else "directory" if path.is_dir() else "file"
        # An earlier directory snapshot may already include this entry.
        if target.exists() or target.is_symlink():
            continue
        if path.is_symlink():
            target.symlink_to(os.readlink(path))
        elif path.is_dir():
            shutil.copytree(path, target, symlinks=True)
        else:
            shutil.copy2(path, target)
    descriptor = os.open(root / "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump({"home": str(home), "entries": entries}, stream, indent=2)
        stream.write("\n")
    return root


def matching_import(source, target):
    if os.path.samefile(source, target) or digest(source) == digest(target):
        return True
    # A transcript already in normal config can be ahead of the old copy.
    size = source.stat().st_size
    if source.suffix == ".jsonl" and size <= target.stat().st_size:
        with source.open("rb") as incoming, target.open("rb") as current:
            while size:
                block = incoming.read(min(size, 64 * 1024))
                if not block or block != current.read(len(block)):
                    return False
                size -= len(block)
            return True
    return False


def publish_missing(source, target):
    # Links preserve live appends, and fail rather than replace a competing file.
    # A hardlink shares permissions with its source: remove public bits before
    # publication, retaining any more restrictive owner permissions.
    source.chmod(source.stat().st_mode & 0o600)
    try:
        os.link(source, target)
        return
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    # A cross-device copy is complete before its exclusive publication. Both
    # names now live on the same filesystem, so linking cannot fail with EXDEV.
    descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix=".shared-config-")
    os.close(descriptor)
    try:
        shutil.copy2(source, temporary)
        os.link(temporary, target)
    finally:
        os.unlink(temporary)


def import_tree(source, target, home, apply, conflicts):
    count = 0
    if not source.is_dir():
        return count
    for folder, dirs, files in os.walk(source, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(folder) / d).is_symlink()]
        for name in files:
            src = Path(folder) / name
            if src.is_symlink() or not src.is_file():
                continue
            dst = target / src.relative_to(source)
            safe_target(dst, home)
            if dst.exists():
                if matching_import(src, dst):
                    continue
                # Keep both divergent versions, without silently choosing one.
                conflicts.append(str(dst.relative_to(home)))
                continue
            if apply:
                private_directory(dst.parent, home)
                try:
                    publish_missing(src, dst)
                except FileExistsError:
                    safe_target(dst, home)
                    if not matching_import(src, dst):
                        conflicts.append(str(dst.relative_to(home)))
                    continue
            count += 1
    return count


def merge_jsonl(source, target, home, apply):
    if not source.is_file():
        return 0
    safe_target(target, home)
    if apply:
        private_directory(target.parent, home)
        descriptor = os.open(target, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
        stream = os.fdopen(descriptor, "a+b")
    elif target.exists():
        stream = target.open("rb")
    else:
        return merge_jsonl_records(source, target, None, False)
    with stream:
        # Codex holds this file lock through append and truncate/rewrite.
        # Read after acquisition so a completed compaction stays authoritative.
        fcntl.flock(stream, fcntl.LOCK_EX if apply else fcntl.LOCK_SH)
        if apply:
            os.fchmod(stream.fileno(), 0o600)
        stream.seek(0)
        return merge_jsonl_records(source, target, stream, apply)


def binary_records(stream):
    # Latin-1 round-trips every byte while universal newline handling preserves
    # splitlines' CR/LF boundaries, including a CRLF split across read buffers.
    reader = io.TextIOWrapper(stream, encoding="latin-1", newline=None)
    try:
        for line in reader:
            yield (line[:-1] if line.endswith("\n") else line).encode("latin-1")
    finally:
        reader.detach()


def merge_jsonl_records(source, target, stream, apply):
    count = 0
    # Exact BLOB keys keep deduplication semantics without retaining entire
    # histories in memory. The index is private, disposable and disk-backed.
    with tempfile.TemporaryDirectory(prefix="cs-history-index-") as directory:
        descriptor, index_path = tempfile.mkstemp(dir=directory, suffix=".sqlite")
        os.close(descriptor)
        with closing(sqlite3.connect(index_path)) as index:
            index.execute("PRAGMA journal_mode=OFF")
            index.execute("PRAGMA synchronous=OFF")
            index.execute("PRAGMA cache_size=-1024")
            index.execute("CREATE TABLE seen(line BLOB PRIMARY KEY) WITHOUT ROWID")
            insert = "INSERT OR IGNORE INTO seen VALUES (?)"
            if stream is not None:
                index.executemany(insert, ((line,) for line in binary_records(stream)))
            with source.open("rb") as incoming:
                for line in binary_records(incoming):
                    if not line.strip():
                        continue
                    try:
                        json.loads(line)
                    except ValueError:
                        # A live source may end with an incomplete record.
                        continue
                    if not index.execute(insert, (line,)).rowcount:
                        continue
                    if apply:
                        if count == 0 and stream.seek(0, os.SEEK_END):
                            stream.seek(-1, os.SEEK_END)
                            if stream.read(1) != b"\n":
                                raise ValueError(f"Incomplete destination record: {target}")
                        stream.write(line + b"\n")
                    count += 1
            if apply and count:
                stream.flush()
    return count


@contextmanager
def claude_config_lock(lock):
    """Keep Claude's empty native lock alive and release only its acquired inode."""
    lock.mkdir(mode=0o700)
    identity = None
    descriptor = None
    heartbeat = None
    stop = threading.Event()
    compromised = threading.Event()

    def owned():
        try:
            current = lock.lstat()
        except FileNotFoundError:
            return False
        return stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == identity

    def verify():
        if compromised.is_set() or not owned():
            raise ValueError(f"Lost Claude config lock: {lock}; retry after its writer finishes")

    def refresh():
        while not stop.wait(CLAUDE_LOCK_HEARTBEAT_SECONDS):
            try:
                verify()
                # Use the retained directory fd, never a successor's path.
                os.utime(descriptor, None)
            except (OSError, ValueError):
                compromised.set()
                return

    try:
        acquired = lock.lstat()
        identity = (acquired.st_dev, acquired.st_ino)
        descriptor = os.open(lock, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        retained = os.fstat(descriptor)
        if (retained.st_dev, retained.st_ino) != identity:
            raise ValueError(f"Lost Claude config lock: {lock}; retry after its writer finishes")
        verify()
        os.utime(descriptor, None)
        heartbeat = threading.Thread(target=refresh, name="claude-config-lock", daemon=True)
        heartbeat.start()
        yield verify
    finally:
        stop.set()
        if heartbeat is not None:
            heartbeat.join()
        try:
            if identity is not None and owned():
                lock.rmdir()
        finally:
            if descriptor is not None:
                os.close(descriptor)


def merge_project_settings(profile, home, apply):
    """Keep trusted project entries without copying account or user preferences."""
    source = profile / ".claude/.claude.json"
    target = home / ".claude.json"
    if not source.is_file():
        return 0
    safe_target(target, home)
    incoming = json.loads(source.read_text()).get("projects", {})
    current = json.loads(target.read_text()) if target.is_file() else {}
    projects = current.get("projects", {})
    missing = {key: value for key, value in incoming.items() if key not in projects}
    if missing and apply:
        lock = target.with_name(target.name + ".lock")
        temporary = None
        with claude_config_lock(lock) as verify:
            try:
                current = json.loads(target.read_text()) if target.is_file() else {}
                missing = {key: value for key, value in incoming.items() if key not in current.get("projects", {})}
                if not missing:
                    return 0
                current.setdefault("projects", {}).update(missing)
                fd, temporary = tempfile.mkstemp(dir=home, prefix=".claude.json.shared-")
                with os.fdopen(fd, "w") as stream:
                    json.dump(current, stream, indent=2)
                    stream.write("\n")
                if target.exists():
                    shutil.copymode(target, temporary)
                verify()
                os.replace(temporary, target)
            finally:
                if temporary and os.path.exists(temporary):
                    os.unlink(temporary)
    return len(missing)


def quoted_identifier(name):
    return '"' + name.replace('"', '""') + '"'


def check_foreign_keys(database):
    violation = database.execute("PRAGMA foreign_key_check").fetchone()
    if violation:
        raise ValueError(f"Codex database foreign key conflict in {violation[0]}; no thread metadata imported")


def thread_schemas(source, target):
    tables = ("thread_sections", "projects", "project_roots", "project_idempotency_keys", "threads",
              "thread_dynamic_tools", "thread_spawn_edges", "thread_attachments", "thread_read_receipts")
    schemas = {}

    def unique_indexes(database, table):
        indexes = []
        for index in database.execute(f'PRAGMA index_list("{table}")'):
            if index[2]:
                columns = tuple(row[2:5] for row in database.execute(
                    f"PRAGMA index_xinfo({quoted_identifier(index[1])})") if row[5])
                indexes.append((columns, index[4]))
        return sorted(indexes)

    for table in tables:
        incoming = list(source.execute(f'PRAGMA table_info("{table}")'))
        current = list(target.execute(f'PRAGMA table_info("{table}")'))
        if not incoming and not current:
            continue
        if incoming != current or list(source.execute(f'PRAGMA foreign_key_list("{table}")')) != \
                list(target.execute(f'PRAGMA foreign_key_list("{table}")')) or \
                unique_indexes(source, table) != unique_indexes(target, table):
            raise ValueError(f"Codex database schema differs for {table}; no thread metadata imported")
        schemas[table] = ([row[1] for row in incoming],
                          [row[1] for row in sorted(incoming, key=lambda row: row[5]) if row[5]])
    return schemas


def database_rows(database, table, columns):
    names = ",".join(quoted_identifier(column) for column in columns)
    for row in database.execute(f'SELECT {names} FROM "{table}"'):
        yield dict(zip(columns, row))


def insert_thread_metadata(database, table, schema, row, immutable=()):
    columns, primary = schema
    names = ",".join(quoted_identifier(column) for column in columns)
    condition = " AND ".join(f"{quoted_identifier(column)} IS ?" for column in primary)
    existing = database.execute(f'SELECT {names} FROM "{table}" WHERE {condition}',
                                [row[column] for column in primary]).fetchone()
    if existing is not None:
        current = dict(zip(columns, existing))
        if any(current[column] != row[column] for column in immutable):
            raise ValueError(f"Codex metadata conflict in {table}; existing identity has different ownership")
        return 0
    try:
        cursor = database.execute(f'INSERT INTO "{table}" ({names}) VALUES ({",".join("?" for _ in columns)})',
                                  [row[column] for column in columns])
    except sqlite3.IntegrityError as error:
        raise ValueError(f"Codex metadata conflict in {table}: {error}; no thread metadata imported") from error
    return cursor.rowcount


def backup_thread_database(target, backup_dir):
    descriptor, saved_path = tempfile.mkstemp(dir=backup_dir, prefix=f"codex-{target.stem}-", suffix=".sqlite")
    os.close(descriptor)
    try:
        # The importing connection already holds BEGIN IMMEDIATE. Backing up
        # that connection would wait on its own write transaction indefinitely.
        with closing(sqlite3.connect(target.as_uri() + "?mode=ro", uri=True)) as current, \
                closing(sqlite3.connect(saved_path)) as saved:
            current.backup(saved)
    except BaseException:
        os.unlink(saved_path)
        raise


def secure_thread_database(target):
    # Existing installations may have inherited public modes from an earlier
    # import. Secure their actual inodes before any private metadata is written.
    for suffix in ("", "-wal", "-shm", "-journal"):
        path = Path(str(target) + suffix)
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            if not suffix:
                raise
            continue
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise ValueError(f"Refusing non-regular Codex database file: {path}")
            os.fchmod(descriptor, 0o600)
        finally:
            os.close(descriptor)


def merge_thread_records(source, target, src, dst, incoming, schemas):
    columns = schemas["threads"][0]
    threads = [row for row in database_rows(src, "threads", columns) if row["id"] in incoming]
    projects = {row.get("project_id") for row in threads} - {None}
    sections = {row.get("thread_section_id") for row in threads} - {None}
    new_projects = set()
    count = 0
    for table, schema in schemas.items():
        for row in threads if table == "threads" else database_rows(src, table, schema[0]):
            immutable = ()
            if table in ("projects", "thread_sections"):
                if row["id"] not in (projects if table == "projects" else sections):
                    continue
            elif table == "project_roots":
                if row["project_id"] not in new_projects:
                    continue
                immutable = tuple(schema[0])
            elif table == "project_idempotency_keys":
                if row["project_id"] not in projects:
                    continue
                immutable = ("project_id",)
            elif table == "threads":
                prefix = str(source.parent) + "/"
                if row["rollout_path"].startswith(prefix):
                    row["rollout_path"] = str(target.parent) + "/" + row["rollout_path"][len(prefix):]
                immutable = tuple(schema[0])
            else:
                thread = row.get("thread_id", row.get("child_thread_id"))
                if thread not in incoming:
                    continue
                if table == "thread_dynamic_tools":
                    immutable = tuple(schema[0])
                elif table == "thread_spawn_edges":
                    immutable = ("parent_thread_id", "child_thread_id")
                elif table == "thread_attachments":
                    immutable = ("thread_id", "attachment_type", "identity_key")
                # Existing receipts remain authoritative even when a thread's
                # rebuildable metadata was absent before this import.
            inserted = insert_thread_metadata(dst, table, schema, row, immutable)
            if table == "projects" and inserted:
                new_projects.add(row["id"])
            elif table == "threads":
                count += inserted
    return count


def merge_threads(source, target, home, apply, backup_dir):
    if not source.is_file():
        return 0
    safe_target(target, home)
    if not target.is_file():
        if not apply:
            with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src:
                return src.execute("SELECT count(*) FROM threads").fetchone()[0]
        private_directory(target.parent, home)
        descriptor, temporary = tempfile.mkstemp(dir=target.parent, prefix=".shared-state-")
        os.close(descriptor)
        try:
            with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src, \
                    closing(sqlite3.connect(temporary)) as dst:
                src.execute("BEGIN")
                src.backup(dst)
                dst.execute("PRAGMA foreign_keys=ON")
                check_foreign_keys(dst)
                old = str(source.parent) + "/"
                new = str(target.parent) + "/"
                dst.execute("UPDATE threads SET rollout_path = ? || substr(rollout_path, ?) WHERE substr(rollout_path, 1, ?) = ?",
                            (new, len(old) + 1, len(old), old))
                dst.commit()
                count = dst.execute("SELECT count(*) FROM threads").fetchone()[0]
            try:
                os.link(temporary, target)
            except FileExistsError:
                # A native process created its database while the copy was made.
                # Keep it authoritative and use the ordinary merge below.
                safe_target(target, home)
            else:
                return count
        finally:
            os.unlink(temporary)
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as src, \
            closing(sqlite3.connect(target.as_uri() + ("?mode=rw" if apply else "?mode=ro"), uri=True, timeout=30)) as dst:
        src.execute("BEGIN")
        dst.execute("PRAGMA foreign_keys=ON")
        with dst:
            dst.execute("BEGIN IMMEDIATE" if apply else "BEGIN")
            if apply:
                secure_thread_database(target)
            incoming = {r[0] for r in src.execute("SELECT id FROM threads")} - {r[0] for r in dst.execute("SELECT id FROM threads")}
            if not apply or not incoming:
                return len(incoming)
            schemas = thread_schemas(src, dst)
            check_foreign_keys(src)
            if backup_dir:
                backup_thread_database(target, backup_dir)
            count = merge_thread_records(source, target, src, dst, incoming, schemas)
            check_foreign_keys(dst)
            return count


def migrate(home, apply=False, backup_dir=None):
    profile = home / ".local/share/code-sessions/home"
    counts, conflicts = {}, []
    for engine, folders in ((".claude", ("projects", "file-history", "paste-cache")),
                            (".codex", ("sessions", "archived_sessions"))):
        for folder in folders:
            counts[f"{engine}/{folder}"] = import_tree(profile / engine / folder, home / engine / folder, home, apply, conflicts)
        for name in (("history.jsonl",) if engine == ".claude" else ("history.jsonl", "session_index.jsonl")):
            counts[f"{engine}/{name}"] = merge_jsonl(profile / engine / name, home / engine / name, home, apply)
    for db in (profile / ".codex").glob("state_*.sqlite"):
        counts[db.name] = merge_threads(db, home / ".codex" / db.name, home, apply, backup_dir)
    counts["claude_project_settings"] = merge_project_settings(profile, home, apply)
    return {"applied": apply, "imported": counts, "conflicts_kept_in_profile": conflicts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup", action="store_true", help="back up the installation before setup")
    parser.add_argument("--backup-dir", type=Path)
    args = parser.parse_args()
    home = args.home.absolute()
    if args.backup:
        print(backup(home, Path(__file__).resolve().parent.parent))
    else:
        print(json.dumps(migrate(home, args.apply, args.backup_dir), indent=2))


if __name__ == "__main__":
    main()
