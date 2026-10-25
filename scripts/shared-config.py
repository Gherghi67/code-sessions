#!/usr/bin/env python3
"""Bring the old engine profile's history into the user's normal configuration.

ABOUTME: Preserves existing records, imports missing conversations and Codex thread metadata.
ABOUTME: Leaves credentials, user preferences, session folders and the old profile in place.
"""
import argparse
from contextlib import closing
import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile


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
    # setup appends to startup files through their links. Preserve both the
    # link and the bytes actually modified, including a dotfiles tree outside HOME.
    paths.update(path.resolve() for path in startup if path.exists())
    return sorted({Path(os.path.abspath(path)) for path in paths})


def backup(home, checkout):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    root = home / ".local/share/code-sessions/backups" / stamp
    private_directory(root, home)
    entries = []
    for path in installation_targets(home, checkout):
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
    if source.suffix == ".jsonl" and source.stat().st_size <= target.stat().st_size:
        with target.open("rb") as stream:
            return stream.read(source.stat().st_size) == source.read_bytes()
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


def merge_jsonl_records(source, target, stream, apply):
    seen = set(stream.read().splitlines()) if stream is not None else set()
    additions = []
    for line in source.read_bytes().splitlines():
        if line in seen or not line.strip():
            continue
        try:
            json.loads(line)
        except ValueError:
            # The source can be in the middle of appending its last record.
            continue
        seen.add(line)
        additions.append(line)
    if apply and additions:
        if stream.seek(0, os.SEEK_END):
            stream.seek(-1, os.SEEK_END)
            if stream.read(1) != b"\n":
                raise ValueError(f"Incomplete destination record: {target}")
        stream.write(b"\n".join(additions) + b"\n")
        stream.flush()
    return len(additions)


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
        # Claude's native writer uses this sibling lock too. Refuse rather
        # than overwrite a concurrent account switch or project update.
        lock = target.with_name(target.name + ".lock")
        lock.mkdir(mode=0o700)
        temporary = None
        try:
            current = json.loads(target.read_text()) if target.is_file() else {}
            for key, value in missing.items():
                current.setdefault("projects", {}).setdefault(key, value)
            fd, temporary = tempfile.mkstemp(dir=home, prefix=".claude.json.shared-")
            with os.fdopen(fd, "w") as stream:
                json.dump(current, stream, indent=2)
                stream.write("\n")
            if target.exists():
                shutil.copymode(target, temporary)
            os.replace(temporary, target)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
            lock.rmdir()
    return len(missing)


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
                src.backup(dst)
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
        incoming = {r[0] for r in src.execute("SELECT id FROM threads")} - {r[0] for r in dst.execute("SELECT id FROM threads")}
        if not apply or not incoming:
            return len(incoming)
        if backup_dir:
            descriptor = os.open(backup_dir / "codex-state.sqlite", os.O_WRONLY | os.O_CREAT, 0o600)
            os.close(descriptor)
            with closing(sqlite3.connect(backup_dir / "codex-state.sqlite")) as saved:
                dst.backup(saved)
        tables = ("thread_sections", "projects", "project_roots", "project_idempotency_keys", "threads",
                  "thread_dynamic_tools", "thread_spawn_edges", "thread_attachments", "thread_read_receipts")
        available = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        with dst:
            for table in tables:
                if table not in available:
                    continue
                columns = [r[1] for r in src.execute(f'PRAGMA table_info("{table}")')]
                if columns != [r[1] for r in dst.execute(f'PRAGMA table_info("{table}")')]:
                    raise ValueError(f"Codex database schema differs for {table}; no thread metadata imported")
                keys = ",".join('"' + c + '"' for c in columns)
                for raw in src.execute(f'SELECT {keys} FROM "{table}"'):
                    row = dict(zip(columns, raw))
                    thread = row.get("thread_id", row.get("child_thread_id", row.get("id") if table == "threads" else None))
                    if thread is not None and thread not in incoming:
                        continue
                    if table == "threads":
                        old = str(source.parent) + "/"
                        if row["rollout_path"].startswith(old):
                            row["rollout_path"] = str(target.parent) + "/" + row["rollout_path"][len(old):]
                    dst.execute(f'INSERT OR IGNORE INTO "{table}" ({keys}) VALUES ({",".join("?" for _ in columns)})',
                                [row[c] for c in columns])
        return len(incoming)


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
