# ABOUTME: Helpers shared by code-sessions-to-cs.py and cs-to-code-sessions.py, which carry sessions between the stable cs and code-sessions.
# ABOUTME: Claude folder names, open-session checks, the append-only transcript merge and the protocol wording.
"""What both directions of a session transfer need.

The two scripts copy the same kinds of things in opposite directions: Claude
Code's transcript folders, the session protocol in CLAUDE.local.md, and
secrets. Their rules live here so the two cannot drift apart.
"""

import ctypes
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


def tilde(path):
    home = os.path.expanduser("~")
    if path == home or path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def claude_project_key(path):
    """Claude Code names a transcript folder after the path, every other character a '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def pid_alive(value):
    try:
        pid = int(str(value).strip())
    except ValueError:
        return False
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def session_is_open(meta):
    """True when a lock or run lease in .cs names a live process."""
    try:
        with open(os.path.join(meta, "session.lock")) as f:
            if pid_alive(f.read()):
                return True
    except OSError:
        pass
    try:
        with open(os.path.join(meta, "local", "run-lease.json")) as f:
            lease = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(lease, dict) and any(
        pid_alive(lease.get(key, "")) for key in ("owner_pid", "native_pid"))


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def state_value(meta, key):
    text = read_text(os.path.join(meta, "local", "state")) or ""
    for line in text.splitlines():
        if line.startswith(key + ":"):
            return line[len(key) + 1:].strip()
    return ""


def write_atomic(path, data, like=None, prefix=".session-transfer."):
    """Replace path with data (bytes), keeping the mode of like or of path itself."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=prefix)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        source = like if like is not None else path
        if os.path.exists(source):
            shutil.copystat(source, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _load_clonefile():
    if sys.platform != "darwin":
        return None
    try:
        clone = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).clonefile
    except (OSError, AttributeError):
        return None
    clone.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32)
    clone.restype = ctypes.c_int
    return clone


_CLONEFILE = _load_clonefile()


def copy_file(src, dst):
    """Copy src to dst, which must not exist yet, with copy2's metadata.

    On APFS the copy is a clone: it shares the original's blocks until either
    side writes, so carrying gigabytes of transcripts costs no disk space.
    Anywhere a clone is refused (another volume, another file system) it is an
    ordinary copy.
    """
    if _CLONEFILE is not None and _CLONEFILE(os.fsencode(src), os.fsencode(dst), 0) == 0:
        shutil.copystat(src, dst)
        return
    shutil.copy2(src, dst)


def files_equal_prefix(shorter, longer, length):
    """True when the first length bytes of longer equal the file shorter."""
    with open(shorter, "rb") as a, open(longer, "rb") as b:
        remaining = length
        while remaining > 0:
            chunk = a.read(min(1 << 20, remaining))
            if not chunk or b.read(len(chunk)) != chunk:
                return False
            remaining -= len(chunk)
    return True


class Tally:
    def __init__(self):
        self.new = 0
        self.grown = 0
        self.same = 0
        self.ahead = 0
        self.kept = 0       # rewritten on the receiving side only (the source's unchanged since a run looked)
        self.taken = []     # rewritten in the source, the receiving side's still as a run left it: replaced
        self.diverged = []
        self.blocked = []   # folders of dst that are a link or a file

    def add(self, other):
        self.new += other.new
        self.grown += other.grown
        self.same += other.same
        self.ahead += other.ahead
        self.kept += other.kept
        self.taken += other.taken
        self.diverged += other.diverged
        self.blocked += other.blocked

    def pending(self):
        return self.new + self.grown + len(self.taken)


def merged_parts(tally, src):
    """What a merge brings (or would bring) over, as the parts of the line that counts it."""
    parts = []
    if tally.new:
        parts.append("%d new" % tally.new)
    if tally.grown:
        parts.append("%d grown since the last copy" % tally.grown)
    if tally.taken:
        parts.append("%d rewritten in %s since the last copy" % (len(tally.taken), src))
    return parts


def merged_notes(tally, src, dst, apply, limit=10):
    """The lines that name each file a merge takes from src (src rewrote it, dst left it as a run copied it),
    then the count of those dst rewrote that src has not changed since a run last looked."""
    verb = "brought over" if apply else "would be brought over"
    lines = ["rewritten in %s since the last copy and untouched in %s, %s: %s" % (src, dst, verb, tilde(path))
             for path in tally.taken[:limit]]
    if len(tally.taken) > limit:
        lines.append("and %d more rewritten in %s and untouched in %s, %s" % (len(tally.taken) - limit, src, dst, verb))
    if tally.kept:
        lines.append("%d file(s) %s rewrote, unchanged in %s since the last run; %s's kept" % (tally.kept, dst, src, dst))
    return lines


def merge_tree(src, dst, apply, tmp_suffix=".session-transfer.tmp", record=None):
    """Copy files of src missing from dst, and replace those that only grew; see merge_files."""
    if not os.path.isdir(src):
        return Tally()
    rels = []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel = os.path.relpath(root, src)
        rels += [name if rel == "." else os.path.join(rel, name) for name in sorted(files)]
    return merge_files(src, dst, rels, apply, tmp_suffix, record=record)


# --- history files rewritten whole ------------------------------------------
#
# Claude Code appends to a transcript and never rewrites it, so a copy that is
# an unchanged start of the source's file is safe to replace, and a copy that
# holds more than the source's was continued on the receiving side. Some of
# its files it rewrites whole, though: a conversation's workflow state
# (<conversation>/workflows/wf_*.json), a task list's tasks. Neither side's is
# then a start of the other's, and the content alone cannot tell which side
# rewrote it. A Record's history() keeps, per file of the receiving side a run
# merged, a signature (size, mtime, ctime: _signature) of
#
#   "dst": that file when it last held content the source had: right after a
#          run wrote it (a clone of the source's), or when a run found it equal
#          to the source's;
#   "src": the source's file when a run last read it.
#
# A file the receiving side has that is neither the source's nor a start of
# it is then the source's to take when the receiving side's still has its
# "dst" signature: ctime is set by the kernel alone on every write, rename,
# truncation or mode change, so an unchanged ctime proves nothing wrote it
# since, and it holds content the source had, which the source has moved past
# (rewritten, or rewritten shorter: then it is no copy that went on, though
# the source's is a start of it). When only the source's still has its "src"
# signature, the receiving side rewrote it alone: kept, and not a problem.
# When neither, both rewrote it: kept, reported, and its "src" noted, so it is
# reported once per change in the source.
#
# A copy an earlier version of the scripts made has no signature yet: nothing
# proves it untouched, so where the source rewrote it, it is kept and reported
# once, as above.

def _signature(st):
    return [st.st_size, st.st_mtime_ns, st.st_ctime_ns]


def merge_files(src, dst, rels, apply, tmp_suffix=".session-transfer.tmp", new_only=False, record=None):
    """merge_tree for the files rels (paths relative to src and dst) alone.

    A file dst lacks is copied, and one dst holds an unchanged start of is
    replaced. Any other is decided by record (a Record, whose history() it
    reads and, with apply, updates; see the comment above):
    taken when dst's is provably as a run left it; else kept when dst's holds
    more (ahead) or src's is unchanged since a run read it (kept); else, and
    always without record, left and reported (diverged).
    With new_only, a file dst already has is left as it is, whatever it holds
    (for files named after their content).
    """
    tally = Tally()
    in_the_way = set()
    known = record.history() if record is not None else {}

    def note(d, entry):
        if apply and record is not None and known.get(d) != entry:
            known[d] = entry
            record.history_changed()

    def put(s, d, s_st):
        placed = _replace_with_copy(s, d, tmp_suffix)
        now = os.lstat(d)
        # Only what this run placed: the clone's inode, still with the mtime it was given (any write since sets
        # its own). A write that slipped in between is left without a signature, so it is never taken.
        if (now.st_ino, now.st_size, now.st_mtime_ns) == (placed.st_ino, placed.st_size, placed.st_mtime_ns):
            note(d, {"dst": _signature(now), "src": _signature(s_st)})

    for rel in rels:
        s = os.path.join(src, rel)
        d = os.path.join(dst, rel)
        if os.path.islink(s) or not os.path.isfile(s):
            continue
        way = _in_the_way(dst, rel)
        if way:
            if way not in in_the_way:
                in_the_way.add(way)
                tally.blocked.append(os.path.join(dst, way))
            continue
        s_st = os.lstat(s)  # before s is read: a write while it is, and the next run looks again
        if not os.path.lexists(d):
            tally.new += 1
            if apply:
                target_dir = os.path.dirname(d)
                if not os.path.isdir(target_dir):
                    os.makedirs(target_dir)
                    shutil.copystat(os.path.dirname(s), target_dir)
                put(s, d, s_st)
            continue
        if new_only:
            tally.same += 1
            continue
        if os.path.islink(d) or not os.path.isfile(d):
            tally.diverged.append(d)
            continue
        d_st = os.lstat(d)
        s_size, d_size = s_st.st_size, d_st.st_size
        if d_size < s_size and files_equal_prefix(d, s, d_size):
            tally.grown += 1
            if apply:
                put(s, d, s_st)
        elif d_size == s_size and files_equal_prefix(d, s, d_size):
            tally.same += 1
            # Equal to the source's now: noted only if neither side moved while they were compared.
            if (apply and record is not None and _signature(os.lstat(s)) == _signature(s_st)
                    and _signature(os.lstat(d)) == _signature(d_st)):
                note(d, {"dst": _signature(d_st), "src": _signature(s_st)})
        else:
            entry = known.get(d) or {}
            if record is not None and entry.get("dst") == _signature(d_st):
                # Before ahead: a copy no one wrote since cannot have gone on, so a
                # source now shorter than it was rewritten shorter.
                tally.taken.append(d)
                if apply:
                    put(s, d, s_st)
            elif d_size > s_size and files_equal_prefix(s, d, s_size):
                tally.ahead += 1
            elif entry.get("src") == _signature(s_st):
                tally.kept += 1
            else:
                tally.diverged.append(d)
                note(d, {"src": _signature(s_st)})
    return tally


def _replace_with_copy(src, dst, tmp_suffix):
    """Replace dst with a copy of src; the copy's lstat just before it took dst's place."""
    tmp = dst + tmp_suffix
    if os.path.lexists(tmp):
        os.unlink(tmp)
    copy_file(src, tmp)
    placed = os.lstat(tmp)
    os.replace(tmp, dst)
    return placed


def special_files(directory, names):
    """copytree's ignore: sockets and pipes belong to a running process, and copying one blocks."""
    out = []
    for name in names:
        mode = os.lstat(os.path.join(directory, name)).st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            out.append(name)
    return out


def scrubbed_env():
    """The caller's environment without what a code-sessions or cs session exports."""
    env = {}
    for key, value in os.environ.items():
        if key.startswith(("CS_", "CLAUDE_SESSION_")):
            continue
        if key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODE_SESSIONS_HOME"):
            continue
        env[key] = value
    return env


def profile_secrets_env(secrets_dir):
    """The environment the code-sessions launcher gives cs-secrets.

    The keychain, as in the original cs, with the profile's items filed as
    code-sessions:<session>:<name>; where there is no keychain, the profile's
    encrypted store. A backend the caller's shell names is dropped with the
    rest of CS_*, as the launcher drops it.
    """
    env = scrubbed_env()
    env.update(CS_SECRETS_KEYCHAIN_PREFIX="code-sessions", CS_SECRETS_DIR=secrets_dir)
    return env


class SecretsError(Exception):
    pass


def secret_names(command, env, session):
    try:
        result = subprocess.run(command + ["--session", session, "list"], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError as error:
        raise SecretsError("could not run %s: %s" % (tilde(command[0]), error.strerror))
    if result.returncode != 0:
        detail = (result.stderr.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        raise SecretsError("%s could not list %s: %s" % (os.path.basename(command[0]), session, detail))
    return [line[4:] for line in result.stdout.splitlines() if line.startswith("  - ")]


def secret_differs(first_command, first_env, second_command, second_env):
    """True when two secrets get commands give different values, or one fails; neither value is shown."""
    values = []
    for command, env in ((first_command, first_env), (second_command, second_env)):
        got = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, capture_output=True)
        if got.returncode != 0:
            return True
        values.append(got.stdout[:-1] if got.stdout.endswith(b"\n") else got.stdout)
    return values[0] != values[1]


def copy_secret(get_command, get_env, set_command, set_env):
    """Move one value from a secrets get to a secrets set, on stdin only; True when stored.

    Neither command's output is shown: a refusal quotes the value it refused.
    """
    got = subprocess.run(get_command, env=get_env, stdin=subprocess.DEVNULL, capture_output=True)
    if got.returncode != 0:
        return False
    value = got.stdout[:-1] if got.stdout.endswith(b"\n") else got.stdout
    stored = subprocess.run(set_command, env=set_env, input=value, capture_output=True)
    return stored.returncode == 0


# --- copies that keep in step with their source ---------------------------
#
# Each direction makes its own copy of a session (never a link, so neither
# manager writes into the other's folders) and keeps a record of the last
# sync beside the receiving side. A rerun brings over what the source changed
# since: a file changed only there is copied, one changed only in the copy is
# kept, and one changed on both sides keeps the copy's and is reported once
# per change in the source. A file the copy kept stays kept until the two
# sides hold the same content again, so a later change in the source counts
# as a change on both sides.
# Files are told apart by their inode change time (ctime), which nothing but
# the kernel sets: each side has a mark, taken before that side is read, and
# a file whose ctime is past its side's mark changed since. The copy's own
# writes are recorded with their ctimes, so they are not taken for changes
# made in the copy. The record holds the paths both sides had at the last
# sync, so a deletion is told from an addition.

CLONE_NOFOLLOW = 1
STATE = os.path.join(".cs", "local", "state")
SESSION_META = ".cs"
# Taken off every mark, so a clock coarser than a nanosecond hides nothing.
# The price: a change made in the 2 s before a run is looked at again on the
# next one (a copy is then a no-op; a conflict is reported a second time).
MARGIN_NS = 2 * 10 ** 9
# What belongs to the process holding a session open, or to the manager that
# stamped it: a copy never carries these, and a sync leaves them be.
PROCESS_FILES = frozenset(os.path.join(".cs", *parts) for parts in (
    ("session.lock",), ("local", "run-lease.json"), ("local", "run-lease.guard"), ("local", "migrated")))
PROCESS_PREFIXES = (os.path.join(".cs", "local", ".session-lock."), os.path.join(".cs", "local", ".run-lease."))
LOGGED = 1000


def left_out(rel):
    return rel in PROCESS_FILES or rel.startswith(PROCESS_PREFIXES)


def mark_now():
    return time.time_ns() - MARGIN_NS


def relinker(roots):
    """A function that moves an absolute link target inside one of roots (old -> new) to its new place.

    A worktree may link node_modules or an .env file to the project by an
    absolute path; copied as it is, the copy would write through the link
    into the folder it was copied from.
    """
    pairs = sorted(((os.path.normpath(old), new) for old, new in roots.items()), key=lambda p: -len(p[0]))

    def relink(target):
        if not os.path.isabs(target):
            return target
        for old, new in pairs:
            if target == old or target.startswith(old + os.sep):
                return new + target[len(old):]
        return target
    return relink


# A Python virtual environment names its own folder by absolute path: in
# pyvenv.cfg, bin/activate*, the shebang of each script in bin/ and, for an
# editable install, the project's folder in a .pth file, a finder module or
# direct_url.json. Copied as they are, the copy's pip would install into the
# folder it was copied from, and its Python would import that folder's code.
VENV_TEXT_LIMIT = 1024 * 1024
# Where a path starts and ends in text: not inside a name (so /x/a/wap holds no /a/wap, nor
# /a/wap-other one), and a '/' before it, as in file:///a/wap, still lets it start.
_PATH_START = rb"(?<![A-Za-z0-9._@+~-])"
_PATH_END = rb"(?![A-Za-z0-9._@+~-])"


def _venv_folder(rel):
    """The folder (relative) of the virtual environment whose text file rel would be, or None."""
    parts = rel.split(os.sep)
    name = parts[-1]
    if name == "pyvenv.cfg":
        return os.sep.join(parts[:-1])
    if len(parts) >= 2 and parts[-2] == "bin":
        return os.sep.join(parts[:-2])
    editable = name.endswith((".pth", ".egg-link")) or (name.startswith("__editable__") and name.endswith(".py"))
    installed = name == "direct_url.json" and len(parts) >= 2 and parts[-2].endswith(".dist-info")
    for k, wanted in ((len(parts) - 2, editable), (len(parts) - 3, installed)):
        if wanted and k >= 2 and parts[k] == "site-packages" and parts[k - 2] == "lib" \
                and parts[k - 1].startswith("python"):
            return os.sep.join(parts[:k - 2])
    return None


class Rewrites:
    """What a copy of root holds in place of some of its files, for sync_files and a fresh copy.

    fixed maps a path to a function of its bytes. Besides those, each text
    file of a virtual environment in root (one with a pyvenv.cfg) has every
    absolute path inside one of roots (old -> new) moved to its new place, as
    relinker moves a link's target. A function gives None to copy as is.
    """

    def __init__(self, root, fixed=None, roots=None):
        self.root = root
        self.fixed = dict(fixed or {})
        pairs = sorted(((os.fsencode(os.path.normpath(old)), os.fsencode(new)) for old, new in (roots or {}).items()),
                       key=lambda pair: -len(pair[0]))
        self._new = dict(pairs)
        self._pattern = (re.compile(_PATH_START + b"(" + b"|".join(re.escape(old) for old, _ in pairs) + b")"
                                    + _PATH_END) if pairs else None)
        self._venvs = {}

    def _in_venv(self, rel):
        if self._pattern is None:
            return False
        folder = _venv_folder(rel)
        if folder is None:
            return False
        if folder not in self._venvs:
            self._venvs[folder] = os.path.isfile(os.path.join(self.root, folder, "pyvenv.cfg"))
        if not self._venvs[folder]:
            return False
        try:
            st = os.lstat(os.path.join(self.root, rel))
        except OSError:
            return False
        return stat.S_ISREG(st.st_mode) and st.st_size <= VENV_TEXT_LIMIT

    def venvs(self, rels):
        """How many of rels are each virtual environment's text files: {its folder: count}."""
        out = {}
        for rel in rels:
            folder = None if rel in self.fixed else _venv_folder(rel)
            if folder is not None:
                out[folder] = out.get(folder, 0) + 1
        return out

    def preview(self, skip=()):
        """The virtual environments' text files a fresh copy of root rewrites (see apply), found without copying.

        Only a folder with pyvenv.cfg is looked into, and in it only the
        places _venv_folder covers; paths in skip are passed by whole.
        """
        if self._pattern is None:
            return []
        skip = frozenset(os.path.normpath(rel) for rel in skip)
        out = []
        for top, dirs, files in os.walk(self.root):
            rel_dir = os.path.relpath(top, self.root)
            rel_dir = "" if rel_dir == "." else rel_dir
            if not rel_dir and ".git" in dirs:
                dirs.remove(".git")
            dirs[:] = sorted(d for d in dirs if os.path.join(rel_dir, d) not in skip)
            if "pyvenv.cfg" not in files:
                continue
            dirs[:] = []
            for rel in self._venv_candidates(rel_dir):
                if self._in_venv(rel) and self.rebase(_read_bytes(os.path.join(self.root, rel))) is not None:
                    out.append(rel)
        return sorted(out)

    def _venv_candidates(self, folder):
        """Each path in the virtual environment at folder that _venv_folder would take for one of its files."""
        def names(*parts):
            try:
                return sorted(os.listdir(os.path.join(self.root, folder, *parts)))
            except OSError:
                return []
        out = [os.path.join(folder, "pyvenv.cfg")] + [os.path.join(folder, "bin", n) for n in names("bin")]
        for python in names("lib"):
            if not python.startswith("python"):
                continue
            site = os.path.join("lib", python, "site-packages")
            for name in names(site):
                if name.endswith((".pth", ".egg-link")) or (name.startswith("__editable__") and name.endswith(".py")):
                    out.append(os.path.join(folder, site, name))
                elif name.endswith(".dist-info"):
                    out.append(os.path.join(folder, site, name, "direct_url.json"))
        return out

    def __contains__(self, rel):
        return rel in self.fixed or self._in_venv(rel)

    def __getitem__(self, rel):
        if rel in self.fixed:
            return self.fixed[rel]
        if self._in_venv(rel):
            return self.rebase
        raise KeyError(rel)

    def rebase(self, data):
        """data with each path inside a root moved to its new place; None when it names none or is not text."""
        if b"\0" in data:
            return None
        moved = self._pattern.sub(lambda match: self._new[match.group(1)], data)
        return moved if moved != data else None

    def apply(self, copy, paths, prefix):
        """Rewrite in copy, a fresh copy of root, each of paths covered here; the paths rewritten."""
        done = []
        for rel in sorted(paths):
            if rel not in self:
                continue
            target = os.path.join(copy, rel)
            if os.path.islink(target) or not os.path.isfile(target):
                continue
            with open(target, "rb") as f:
                data = f.read()
            moved = self[rel](data)
            if moved is not None and moved != data:
                write_atomic(target, moved, prefix=prefix)
                done.append(rel)
        return done


def clone_tree(src, dst, relink=None, skip=()):
    """Copy the directory src to dst, which must not exist; the paths a sync tracks.

    On APFS one clonefile call clones the whole tree, sharing every block
    until either side writes, and keeps each file's times. Elsewhere it is a
    copy, file by file. Sockets, pipes and the session's lock and lease belong
    to a process on the other side and are dropped from the copy; a link into
    the source is pointed at the copy (see relinker). Paths in skip (relative
    to src: another session's folder inside this one) are left out of the
    copy and of the paths returned.
    """
    skip = frozenset(os.path.normpath(rel) for rel in skip)

    def ignore(directory, names):
        out = special_files(directory, names)
        rel_dir = os.path.relpath(directory, src)
        return out + [n for n in names if os.path.normpath(os.path.join(rel_dir, n)) in skip]

    if _CLONEFILE is None or _CLONEFILE(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW) != 0:
        if os.path.lexists(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True, ignore=ignore if skip else special_files, copy_function=copy_file)
    drop_git_locks(os.path.join(dst, ".git"))
    for rel in sorted(skip):
        _remove_inside(dst, rel)
    paths = set()
    for rel, st in _walk(dst, None, keep_special=True, skip=skip):
        path = os.path.join(dst, rel)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)) or left_out(rel):
            os.unlink(path)
            continue
        if relink and stat.S_ISLNK(st.st_mode):
            target = os.readlink(path)
            if relink(target) != target:
                os.unlink(path)
                os.symlink(relink(target), path)
        paths.add(rel)
    return paths


def _remove_inside(root, rel):
    """Remove root/rel, a folder whole, but only when every folder above it under root is a real one.

    A link on the way would put the removal outside root.
    """
    parts = rel.split(os.sep)
    for n in range(1, len(parts)):
        try:
            if not stat.S_ISDIR(os.lstat(os.path.join(root, *parts[:n])).st_mode):
                return
        except FileNotFoundError:
            return
    path = os.path.join(root, rel)
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        return
    if stat.S_ISDIR(mode):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def reap(directory, prefix):
    """Remove what a copy stopped by a kill left in directory under its temporary prefix."""
    for name in os.listdir(directory) if os.path.isdir(directory) else []:
        path = os.path.join(directory, name)
        if name.startswith(prefix) and os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)


def copy_admin_dir(src, dst):
    """Copy a worktree's administrative directory (HEAD, index, its own refs) from a repository's .git/worktrees."""
    shutil.copytree(src, dst, symlinks=True, ignore=special_files, copy_function=copy_file)
    drop_git_locks(dst)


def admin_dir_for(worktrees, stem, back_link):
    """A free name in worktrees for a worktree's administrative directory, clearing one an earlier copy left."""
    admin_id, n = stem, 1
    while os.path.lexists(os.path.join(worktrees, admin_id)):
        if read_text(os.path.join(worktrees, admin_id, "gitdir")) == back_link:
            # Left by a copy that stopped before its rename.
            shutil.rmtree(os.path.join(worktrees, admin_id))
            break
        n += 1
        admin_id = "%s%d" % (stem, n)
    return os.path.join(worktrees, admin_id)


def drop_git_locks(git_dir):
    """A git command running on the other side while it was copied leaves its locks in the copy."""
    if not os.path.isdir(git_dir) or os.path.islink(git_dir):
        return
    for name in os.listdir(git_dir):
        if name.endswith(".lock") or name == "gc.pid":
            path = os.path.join(git_dir, name)
            if os.path.isfile(path) and not os.path.islink(path):
                os.unlink(path)
    for root, _, files in os.walk(os.path.join(git_dir, "refs")):
        for name in files:
            if name.endswith(".lock"):
                os.unlink(os.path.join(root, name))


def _walk(root, only, keep_special=False, unreadable=None, skip=frozenset()):
    """(relative path, lstat) of every file and link under root, past the top-level .git and left_out paths.

    A folder that cannot be read is added to unreadable (a list), when given.
    A path in skip is passed by whole, whatever it is: not listed, not entered.
    """
    stack = [only.rstrip(os.sep)] if only else [""]
    while stack:
        rel_dir = stack.pop()
        try:
            entries = os.scandir(os.path.join(root, rel_dir) if rel_dir else root)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            if unreadable is None:
                raise
            unreadable.append(rel_dir)
            continue
        with entries:
            for entry in entries:
                if not rel_dir and entry.name == ".git":
                    continue
                rel = os.path.join(rel_dir, entry.name) if rel_dir else entry.name
                if rel in skip:
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    stack.append(rel)
                elif keep_special or ((stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)) and not left_out(rel)):
                    yield rel, st


def _same(src, dst, s, d, data, relink):
    """True when the copy dst holds what src would put there (data: src's bytes after a rewrite, if any)."""
    if stat.S_ISLNK(s.st_mode) or stat.S_ISLNK(d.st_mode):
        if not (stat.S_ISLNK(s.st_mode) and stat.S_ISLNK(d.st_mode)):
            return False
        target = os.readlink(src)
        return (relink(target) if relink else target) == os.readlink(dst)
    if (s.st_mode & 0o777) != (d.st_mode & 0o777):
        return False
    if data is not None:
        return d.st_size == len(data) and _read_bytes(dst) == data
    return s.st_size == d.st_size and files_equal_prefix(src, dst, s.st_size)


def _refreshable(s, d, data, relink):
    """A link on both sides that relink places, or a file both sides have that a rewrite gives."""
    if stat.S_ISLNK(s.st_mode) and stat.S_ISLNK(d.st_mode):
        return relink is not None
    return data is not None and stat.S_ISREG(s.st_mode) and stat.S_ISREG(d.st_mode)


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _put(src, dst, data, relink, tmp_suffix):
    """Make dst what src is (or the rewritten bytes data), replacing it whole."""
    parent = os.path.dirname(dst)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = dst + tmp_suffix
    if os.path.lexists(tmp):
        os.unlink(tmp)
    if os.path.islink(src):
        target = os.readlink(src)
        os.symlink(relink(target) if relink else target, tmp)
    elif data is not None:
        with open(tmp, "wb") as f:
            f.write(data)
        shutil.copymode(src, tmp)
    else:
        copy_file(src, tmp)
    os.replace(tmp, dst)


def _in_the_way(root, rel):
    """The nearest folder above rel under root that is a link or not a folder, or None.

    Writing below a link would land outside root; below a file it cannot land
    at all. root itself is trusted. The check is a live lstat, made right
    before the write: a folder swapped for a link between the two is not
    caught, which only the owner of both trees could do, and they can already
    write there directly.
    """
    parts = rel.split(os.sep)[:-1]
    for n in range(1, len(parts) + 1):
        try:
            mode = os.lstat(os.path.join(root, *parts[:n])).st_mode
        except FileNotFoundError:
            return None   # _put makes the rest
        if not stat.S_ISDIR(mode):
            return os.path.join(*parts[:n])
    return None


def parse_state(text):
    """The key: value lines of .cs/local/state, in order."""
    out = {}
    for line in (text or "").splitlines():
        key, sep, value = line.partition(":")
        if sep and key and " " not in key:
            out[key] = value.strip()
    return out


def merge_state(base, src, dst, pinned=()):
    """Bring each key the source changed since base into dst's state; (text, keys changed on both sides)."""
    b, s, d = parse_state(base), parse_state(src), parse_state(dst)
    merged = dict(d)
    conflicts = []
    for key in list(s) + [k for k in b if k not in s]:
        if key in pinned or s.get(key) == b.get(key) or s.get(key) == d.get(key):
            continue
        if d.get(key) != b.get(key):
            conflicts.append(key)
        elif key in s:
            merged[key] = s[key]
        else:
            merged.pop(key, None)
    if merged == d:
        return dst, conflicts
    lines = []
    for line in (dst or "").splitlines():
        key, sep, _ = line.partition(":")
        if sep and key in d and " " not in key:
            if key in merged:
                lines.append("%s: %s" % (key, merged.pop(key)))
            continue
        lines.append(line)
    lines += ["%s: %s" % (key, merged[key]) for key in merged if key not in d]
    return "\n".join(lines) + "\n", conflicts


class FileSync:
    def __init__(self):
        self.copied = 0
        self.deleted = 0
        self.kept = 0           # changed on the receiving side only
        self.conflicts = []     # (path, why): the receiving side's is kept
        self.failed = 0         # reads or writes that did not happen; the marks then stay
        self.paths = set()
        self.written = {}       # path -> ctime of what this sync wrote there
        self.state = None       # the source's state, the next merge's base
        self.state_after = None  # what the copy's state holds once this sync is done (a dry run's too)
        self.held = set()       # paths whose copy is kept until the two sides agree again
        self.rewritten = set()  # paths copied with a rewrite (a dry run's too)


def _inside(rel, folder):
    return not folder or rel == folder or rel.startswith(folder + os.sep)


def sync_files(src, dst, mark, apply, rewrites=None, relink=None, only=None, pinned=(),
               tmp_suffix=".session-transfer.tmp", skip=()):
    """Bring what src changed since the last sync into its copy dst; see the comment above.

    mark holds the last sync: since ({folder: [src mark, dst mark]}, "" for
    the whole tree; the latest that holds a path counts), written (path ->
    ctime of the copy's own last writes), paths (on both sides then), held
    (paths whose copy was kept against src's) and state (src's
    .cs/local/state then). Each side's mark must have been taken before that
    side was read. rewrites maps a path to a function of its
    bytes giving what the copy should hold, or None to copy it as is (a
    Rewrites does); relink places absolute link targets, and a dry run asks
    it about each link it would copy too, so what it notes is the same. A
    link or a rewritten file that neither side changed is put right when
    relink or the rewrite now gives something else. With only, just that folder is synced.
    Paths in skip (another session's folder inside this one) are left alone
    on both sides, whatever either side has there.
    """
    out = FileSync()
    rewrites = rewrites or {}
    known = mark["paths"]
    since = mark.get("since") or {"": [0, 0]}
    written = mark.get("written") or {}
    held = set(mark.get("held") or ())
    skip = frozenset(os.path.normpath(rel) for rel in skip)
    out.paths = {p for p in known if not _inside(p, only) and not (skip and any(_inside(p, s) for s in skip))}
    blind = []
    s_files = dict(_walk(src, only, unreadable=blind, skip=skip))
    d_files = dict(_walk(dst, only, unreadable=blind, skip=skip))
    for folder in sorted(set(blind)):
        out.failed += 1
        out.conflicts.append((folder or ".", "could not read this folder on one side; left as it is"))
    in_the_way, gone = set(), set()

    def marks(rel):
        held = [v for k, v in since.items() if _inside(rel, k)]
        return max(v[0] for v in held), max(v[1] for v in held)

    def attempt(rel, action, *args):
        try:
            action(*args)
            path = os.path.join(dst, rel)
            if os.path.lexists(path):
                out.written[rel] = os.lstat(path).st_ctime_ns
            return True
        except OSError as error:
            out.failed += 1
            out.conflicts.append((rel, "could not write it: %s" % (error.strerror or error)))
            return False

    def unchanged_since_read(rel, d):
        """The copy's file is still what was read, so a write cannot lose an edit made during the sync."""
        try:
            now = os.lstat(os.path.join(dst, rel))
        except FileNotFoundError:
            return d is None
        if d is None or now.st_ctime_ns != d.st_ctime_ns:
            out.conflicts.append((rel, "changed here while the sync ran"))
            return False
        return True

    for rel in sorted(set(s_files) | set(d_files)):
        if any(_inside(rel, folder) for folder in blind):
            if rel in known:
                out.paths.add(rel)
            continue
        s, d = s_files.get(rel), d_files.get(rel)
        s_since, d_since = marks(rel)
        s_new = s is not None and s.st_ctime_ns > s_since
        d_changed = d is not None and d.st_ctime_ns > d_since and written.get(rel) != d.st_ctime_ns
        d_new = d_changed or (d is not None and rel in held)
        was = rel in known
        sp, dp = os.path.join(src, rel), os.path.join(dst, rel)
        try:
            way = _in_the_way(dst, rel)
            # A dry run deletes nothing, so what it would delete is still there.
            if way and (apply or way not in gone):
                if way not in in_the_way:
                    in_the_way.add(way)
                    out.failed += 1
                    out.conflicts.append((way, "a link or a file here, a folder in the source; left as it is"))
                if was:
                    out.paths.add(rel)
                continue
            if s is not None and d is not None:
                out.paths.add(rel)
                if rel == STATE:
                    text = read_text(sp)
                    out.state = text
                    current = read_text(dp)
                    out.state_after = current
                    if s_new:
                        merged, keys = merge_state(mark.get("state"), text, current, pinned)
                        out.state_after = merged
                        if merged != current:
                            out.copied += 1
                            if apply and unchanged_since_read(rel, d):
                                attempt(rel, write_atomic, dp, merged.encode(), None,
                                        os.path.basename(tmp_suffix))
                        out.conflicts += [(rel, "%s changed on both sides" % k) for k in keys]
                    elif d_new:
                        out.kept += 1
                    continue
                data = (rewrites[rel](_read_bytes(sp))
                        if rel in rewrites and stat.S_ISREG(s.st_mode) else None)
                if not s_new:
                    out.kept += d_changed
                    if d_new and not _same(sp, dp, s, d, data, relink):
                        out.held.add(rel)
                    elif not d_new and _refreshable(s, d, data, relink) and not _same(sp, dp, s, d, data, relink):
                        # Changed on neither side, yet not what the copy should
                        # hold now that a link's target or a file's rewrite
                        # moved (its session copied since, a rule added since):
                        # the copy's own earlier write, so it is put right.
                        out.copied += 1
                        if data is not None:
                            out.rewritten.add(rel)
                        if apply and unchanged_since_read(rel, d):
                            attempt(rel, _put, sp, dp, data, relink, tmp_suffix)
                    continue
                if was and not d_new:
                    if not _same(sp, dp, s, d, data, relink):
                        out.copied += 1
                        if data is not None:
                            out.rewritten.add(rel)
                        if apply and unchanged_since_read(rel, d):
                            attempt(rel, _put, sp, dp, data, relink, tmp_suffix)
                elif not _same(sp, dp, s, d, data, relink):
                    out.held.add(rel)
                    out.conflicts.append((rel, "changed on both sides" if was else "added on both sides"))
            elif s is not None:
                if was:
                    # Deleted in the copy: it stays deleted, and the path is
                    # remembered so the next sync does not bring it back.
                    out.paths.add(rel)
                    if s_new:
                        out.conflicts.append((rel, "deleted here, changed in the source"))
                    continue
                if not way and os.path.lexists(dp):
                    out.conflicts.append((rel, "a folder here, a file in the source"))
                    continue
                data = (rewrites[rel](_read_bytes(sp))
                        if rel in rewrites and stat.S_ISREG(s.st_mode) else None)
                out.copied += 1
                if data is not None:
                    out.rewritten.add(rel)
                if rel == STATE:
                    out.state_after = data.decode() if data is not None else read_text(sp)
                if not apply:
                    out.paths.add(rel)
                    if relink and stat.S_ISLNK(s.st_mode):
                        relink(os.readlink(sp))
                elif unchanged_since_read(rel, None) and attempt(rel, _put, sp, dp, data, relink, tmp_suffix):
                    out.paths.add(rel)
            else:
                if not was:
                    out.kept += d_new
                elif d_new:
                    out.conflicts.append((rel, "deleted in the source, changed here"))
                else:
                    out.deleted += 1
                    gone.add(rel)
                    if apply and unchanged_since_read(rel, d):
                        attempt(rel, os.unlink, dp)
        except OSError as error:
            out.failed += 1
            out.conflicts.append((rel, "could not read it: %s" % (error.strerror or error)))
            if was:
                out.paths.add(rel)
    if out.state is None and os.path.isfile(os.path.join(src, STATE)):
        out.state = read_text(os.path.join(src, STATE))
    return out


# --- git: the copy's own repository, kept in step with the source's --------
#
# Commands on the source run with GIT_OPTIONAL_LOCKS=0 and only ever read:
# a status-like refresh would otherwise rewrite the source's index.

def _git_env(extra=None):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"):
        env.pop(key, None)
    env.update(extra or {})
    return env


def git(cwd, *args, **kwargs):
    """Run git in cwd; text output unless binary=True. input= goes to its stdin, env= adds variables."""
    binary = kwargs.pop("binary", False)
    data = kwargs.pop("input", None)
    extra = kwargs.pop("env", None)
    return subprocess.run(["git", "-C", cwd] + list(args), env=_git_env(extra), capture_output=True,
                          input=data, stdin=None if data is not None else subprocess.DEVNULL,
                          text=not binary)


def git_ok(cwd, *args, **kwargs):
    result = git(cwd, *args, **kwargs)
    if result.returncode != 0:
        err = result.stderr if isinstance(result.stderr, str) else result.stderr.decode(errors="replace")
        detail = (err.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        raise OSError("git %s failed in %s: %s" % (args[0], tilde(cwd), detail))
    return result


def head_state(worktree):
    """HEAD as '<ref or detached> <commit>'."""
    ref = git(worktree, "symbolic-ref", "-q", "HEAD").stdout.strip()
    sha = git(worktree, "rev-parse", "-q", "--verify", "HEAD").stdout.strip()
    return "%s %s" % (ref or "detached", sha)


def index_digest(worktree):
    """What the index holds (modes, blobs, paths), not its stat cache."""
    listing = git(worktree, "ls-files", "-s", "-z", binary=True).stdout
    return hashlib.sha1(listing).hexdigest()


def branch_heads(repo):
    out = git(repo, "for-each-ref", "--format=%(refname:strip=2) %(objectname)", "refs/heads").stdout
    return dict(line.rsplit(" ", 1) for line in out.splitlines() if " " in line)


def checked_out(repo):
    """Branch name -> the worktree that has it checked out."""
    out, path = {}, None
    for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/") and path:
            out[line[len("branch refs/heads/"):]] = path
    return out


def _is_ancestor(repo, a, b):
    """True or False; None when repo lacks one of the commits."""
    rc = git(repo, "merge-base", "--is-ancestor", a, b).returncode
    return {0: True, 1: False}.get(rc)


def relation(dst_repo, src_repo, d, s):
    """same, behind (the copy's commit is an ancestor of the source's), ahead or diverged."""
    if d == s:
        return "same"
    for a, b, answer in ((d, s, "behind"), (s, d, "ahead")):
        found = _is_ancestor(dst_repo, a, b)
        if found is None:
            found = _is_ancestor(src_repo, a, b)
        if found:
            return answer
    return "diverged"


# git 2.31 or later: rev-parse --path-format (copy_index, _common_dir, _git_path), fetch --no-write-fetch-head.
def fetch_quietly(dst_repo, src_repo, refspecs, options=()):
    """git fetch src_repo refspecs in the copy, leaving the copy's FETCH_HEAD as the copy's own fetches left it."""
    git_ok(dst_repo, "fetch", "--quiet", "--no-tags", *options, "--no-write-fetch-head", src_repo, *refspecs)


def fetch_source(dst_repo, src_repo, label):
    """The source's branches as refs/remotes/<label>/* in the copy; the source is only read."""
    fetch_quietly(dst_repo, src_repo, ["+refs/heads/*:refs/remotes/%s/*" % label], options=["--prune"])


def _refs(repo, prefix):
    """{refname: value} under prefix: an object id, or 'ref: <target>' for a symbolic ref."""
    listing = git_ok(repo, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", prefix).stdout
    out = {}
    for line in listing.splitlines():
        parts = line.split("\0")
        if len(parts) == 3:
            out[parts[0]] = "ref: " + parts[2] if parts[2] else parts[1]
    return out


def _is_symbolic(value):
    return value is not None and value.startswith("ref: ")


def _common_dir(repo):
    return git_ok(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()


def _files_backend(repo):
    """True when the repository keeps its refs and reflogs as files (not reftable)."""
    return git(repo, "config", "--get", "extensions.refstorage").stdout.strip().lower() in ("", "files")


def _reflog_lines(data):
    """The lines of a reflog file, or None when its last line is not complete (git is writing it)."""
    if not data.endswith(b"\n"):
        return None
    return data[:-1].split(b"\n")


def _null_id(value):
    return value.strip(b"0") == b""


# Reflog lines with no message from before this were a sync's: earlier versions wrote no -m.
REFLOG_MARKED_SINCE = 1791894604


class Reflogs:
    """Gives a ref of the copy the source's reflog, as a fresh copy has it, where the copy's holds nothing of its own.

    That is when the ref is where the source's is and the copy's reflog is
    the start of the source's: each of its lines one of the source's, in the
    source's order from the first, but for lines a sync wrote ("sync: from
    <label>", or a line with no message from before REFLOG_MARKED_SINCE, as
    this script's earlier versions left). A line the copy's own git wrote (a
    fetch, a commit, a reset, an update-ref with no message since) keeps the
    copy's reflog as it is. Only when every commit the
    source's reflog names is in the copy, or a dry run's ref comes with it:
    one only the source's reflog keeps (amended or rebased away) would break
    git fsck in the copy, which then keeps git's own line. A link or a file
    in place of a folder above the copy's log means no log is brought, and the
    folder is kept in blocked: git itself still writes its lines through such
    a link, this script never does.
    """

    def __init__(self, src_repo, dst_repo, label, apply):
        self.src_repo, self.dst_repo, self.apply = src_repo, dst_repo, apply
        self._sync_line = ("sync: from %s" % label).encode()
        self._dirs = None
        self.blocked = []   # folders of the copy's .git/logs that are a link or a file

    def dirs(self):
        if self._dirs is None:
            files = _files_backend(self.src_repo) and _files_backend(self.dst_repo)
            self._dirs = (_common_dir(self.src_repo), _common_dir(self.dst_repo)) if files else ()
        return self._dirs

    def _read(self, side, ref):
        dirs = self.dirs()
        if not dirs:
            return None
        path = os.path.join(dirs[side], "logs", ref)
        if os.path.islink(path) or not os.path.isfile(path):
            return None
        try:
            return _read_bytes(path)
        except OSError:
            return None

    def _in_the_way_of(self, ref):
        """True when a link or a file stands above the copy's log of ref (see _in_the_way)."""
        way = _in_the_way(self.dirs()[1], os.path.join("logs", ref))
        if way is None:
            return False
        way = os.path.join(self.dirs()[1], way)
        if way not in self.blocked:
            self.blocked.append(way)
        return True

    def _own(self, lines):
        """lines but those a sync wrote."""
        return [line for line in lines if not self._by_a_sync(line)]

    def _by_a_sync(self, line):
        head, tab, message = line.partition(b"\t")
        if tab:
            return message == self._sync_line
        when = head.split(b" ")[-2:-1]
        return bool(when) and when[0].isdigit() and int(when[0]) < REFLOG_MARKED_SINCE

    def due(self, ref, value, changing):
        """(the source's reflog of ref, the copy's as read) when the copy's should become the source's, else None.

        value: the ref's object id in the copy once this sync is done.
        changing: this sync creates or moves the ref (a dry run: would), so the
        copy's reflog gains git's line for that first, or starts with it.
        """
        src = self._read(0, ref)
        src_lines = _reflog_lines(src) if src else None
        if not src_lines or src_lines[-1].split(b" ", 2)[1:2] != [value.encode()]:
            return None
        if self._in_the_way_of(ref):
            return None
        dst = seen = self._read(1, ref)
        if dst is None:
            # A log git keeps: core.logAllRefUpdates off in the copy means none.
            if self.apply or not changing:
                return None
            dst = b""
        if dst == src:
            return None
        dst_lines = _reflog_lines(dst) if dst else []
        own = self._own(dst_lines) if dst_lines is not None else None
        if own is None or own != self._own(src_lines)[:len(own)]:
            return None
        return (src, seen) if self._objects_there(src_lines, value, changing) else None

    def _objects_there(self, lines, value, changing):
        """True when the copy has each object lines name; a dry run counts those that come with value."""
        ids = set()
        for line in lines:
            fields = line.split(b" ", 2)
            if len(fields) < 3:
                return False
            ids.update(f.decode("ascii", "replace") for f in fields[:2] if not _null_id(f))
        if not ids:
            return True
        check = git(self.dst_repo, "cat-file", "--batch-check", input="\n".join(sorted(ids)) + "\n")
        if check.returncode != 0:
            return False
        missing = [line.split()[0] for line in check.stdout.splitlines() if line.endswith(" missing")]
        if missing and (self.apply or not changing):
            return False
        # A dry run has not fetched yet: what value leads to comes with it.
        return all(_is_ancestor(self.src_repo, sha, value) for sha in missing)

    def bring(self, ref, value, changing):
        """Give the copy the source's reflog of ref when due (see due); True when it has, or a dry run's would."""
        found = self.due(ref, value, changing)
        if found is None:
            return False
        if not self.apply:
            return True
        data, seen = found
        # Only over what was read: a line git added meanwhile in the copy is the copy's own.
        if self._read(1, ref) != seen or self._in_the_way_of(ref):
            return False
        write_atomic(os.path.join(self.dirs()[1], "logs", ref), data, prefix=".session-transfer.")
        return True


def _bring_objects(src_repo, dst_repo, wanted):
    """Fetch the objects of wanted ({source refname: object id}) the copy lacks, by the source's ref names."""
    ids = sorted(set(wanted.values()))
    if not ids:
        return
    check = git_ok(dst_repo, "cat-file", "--batch-check", input="\n".join(ids) + "\n").stdout
    missing = {line.split()[0] for line in check.splitlines() if line.endswith(" missing")}
    names = sorted(name for name, sha in wanted.items() if sha in missing)
    for start in range(0, len(names), 200):
        # A refspec with no destination brings the objects and writes no ref.
        fetch_quietly(dst_repo, src_repo, names[start:start + 200])


class BranchSync:
    def __init__(self):
        self.created = []
        self.moved = []
        self.ahead = []
        self.diverged = []
        self.heads = {}
        self.reflogs = 0        # created branches that take the source's reflog (a dry run's too)
        self.reflogs_taken = []  # other branches whose reflog becomes the source's (see Reflogs)
        self.reflogs_blocked = []  # folders of the copy's .git/logs in the way of a reflog (Reflogs.blocked)


def sync_branches(src_repo, dst_repo, recorded, apply, skip=(), label="source"):
    """Bring each branch the source moved into the copy, unless the copy moved it too.

    recorded maps each branch to where both sides had it at the last sync.
    Branches in skip (checked out in the copy) are left to their worktree,
    and so is their record. A branch the copy ends up having where the
    source has it, skipped or not, takes the source's reflog when Reflogs
    says so: one created here, as a rule. label names the source in the
    reflog's sync lines.
    """
    out = BranchSync()
    src, dst = branch_heads(src_repo), branch_heads(dst_repo)
    reflogs = Reflogs(src_repo, dst_repo, label, apply)
    out.heads = dict(recorded)
    for name, s in sorted(src.items()):
        d, r = dst.get(name), recorded.get(name)
        ref = "refs/heads/" + name
        if name in skip:
            # Its worktree's, but for the reflog: taking the source's moves nothing.
            if d == s and reflogs.bring(ref, s, False):
                out.reflogs_taken.append(name)
            continue
        # Past this sync, the source's tip is the base: a branch that moved
        # on both sides is reported once, not on every run.
        out.heads[name] = s
        if d == s:
            if reflogs.bring(ref, s, False):
                out.reflogs_taken.append(name)
            continue
        if d is None:
            if r is None:
                out.created.append(name)
                if apply:
                    git_ok(dst_repo, "update-ref", "-m", "sync: from %s" % label, ref, s, "")
                out.reflogs += reflogs.bring(ref, s, True)
            # else: deleted in the copy since the last sync; it stays deleted.
            continue
        if s == r:
            continue            # only the copy moved it
        how = "taken" if d == r else relation(dst_repo, src_repo, d, s)
        if how in ("taken", "behind"):
            out.moved.append(name)
            if apply:
                git_ok(dst_repo, "update-ref", "-m", "sync: from %s" % label, ref, s, d)
            if reflogs.bring(ref, s, True):
                out.reflogs_taken.append(name)
        elif how == "ahead":
            out.ahead.append(name)
        else:
            out.diverged.append(name)
    out.reflogs_blocked = reflogs.blocked
    return out


# Besides branches, a repository copied whole has the source's tags,
# remote-tracking refs (refs/remotes/<remote>/*) and branch.* and remote.*
# settings. A rerun brings what the source gained since, by the same rule as
# everything else: what the copy changed is kept and reported, never
# overwritten. The record keeps, beside "heads": "remotes" (the source's
# remote-tracking refs at the last sync, so a later run tells who moved
# which), "config" (the settings sections the last sync looked at, so one
# the copy removed is not brought back), "tags" (tags kept as the copy has
# them, so each is reported once), "tag_names" (the source's tags at the
# last sync, so one the copy deleted is not brought back; Record keeps them
# in a file of their own) and "remote_urls" (a digest per remote whose URL
# differs, reported once). The remote named after the source's label
# (refs/remotes/cs/* in a code-sessions copy) holds the source's branches,
# fetched by fetch_source, and is left out.

def _config_sections(repo):
    """{section: [(key, value), ...]}: the repository's own branch.* and remote.* settings, in file order.

    A key written with no value (git's implicit true) has the value None.
    """
    result = git(repo, "config", "--local", "-z", "--get-regexp", r"^(branch|remote)\.")
    if result.returncode not in (0, 1):
        detail = (result.stderr.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        raise OSError("git config failed in %s: %s" % (tilde(repo), detail))
    out = {}
    for entry in result.stdout.split("\0"):
        if entry:
            key, sep, value = entry.partition("\n")
            out.setdefault(key.rsplit(".", 1)[0], []).append((key, value if sep else None))
    return out


def _remote_names(conf):
    return {section.partition(".")[2] for section in conf if section.startswith("remote.")} - {""}


def _own_remote(name, label):
    """False for the remote whose refs fetch_source writes (the label's)."""
    return name != label and not name.startswith(label + "/")


def _remote_of(short, names):
    """The remote (one of names) a remote-tracking ref given as <remote>/<branch> belongs to, or None."""
    best = None
    for name in names:
        if short.startswith(name + "/") and (best is None or len(name) > len(best)):
            best = name
    return best


def _remote_refs(repo, names, synced):
    """{<remote>/<branch>: value} of the remote-tracking refs of the remotes in synced (names: every remote)."""
    out = {}
    for ref, value in _refs(repo, "refs/remotes/").items():
        short = ref[len("refs/remotes/"):]
        if _remote_of(short, names) in synced:
            out[short] = value
    return out


def _settings_wanted(conf, branches, label):
    """The sections of conf a copy takes: branch.<b> for each of branches, and every remote.<r> but the label's."""
    out = {}
    for section, entries in conf.items():
        kind, _, name = section.partition(".")
        if (kind == "branch" and name in branches) or (kind == "remote" and name and _own_remote(name, label)):
            out[section] = entries
    return out


def _tags(repo):
    """{name: object id} of the repository's tags, symbolic ones left out."""
    return {ref[len("refs/tags/"):]: v for ref, v in _refs(repo, "refs/tags/").items() if not _is_symbolic(v)}


def repo_marks(repo, label):
    """What a record holds of a repository just copied whole: its branches, remote-tracking refs, settings and tags."""
    conf = _config_sections(repo)
    heads = branch_heads(repo)
    names = _remote_names(conf)
    synced = {name for name in names if _own_remote(name, label)}
    return {"heads": heads, "remotes": _remote_refs(repo, names, synced),
            "config": sorted(_settings_wanted(conf, heads, label)), "tag_names": sorted(_tags(repo))}


def _urls(conf, remote):
    return [value for key, value in conf.get("remote." + remote, ()) if key == "remote.%s.url" % remote]


class GitMetaSync:
    """What sync_git_meta did, or would do (a dry run)."""

    def __init__(self):
        self.tags_added = []
        self.tags_kept = []         # on both sides, on different objects: the copy's kept, reported once
        self.refs_added = []        # remote-tracking refs, each as <remote>/<branch>
        self.refs_moved = []
        self.refs_deleted = []      # pruned in the source, left alone in the copy
        self.refs_ahead = []        # the copy fetched past the source: kept
        self.refs_kept = []         # moved or deleted in the copy, changed or pruned in the source: kept
        self.refs_diverged = []     # moved elsewhere on both sides: the copy's kept
        self.reflogs = 0            # added refs that take the source's reflog
        self.reflogs_taken = []     # other refs whose reflog becomes the source's (see Reflogs)
        self.reflogs_blocked = []   # folders of the copy's .git/logs in the way of a reflog (Reflogs.blocked)
        self.urls = []              # remotes whose URL differs: their refs are left as the copy has them
        self.branch_settings = []   # branches given the source's branch.<name>.* settings
        self.remote_settings = []   # remotes given the source's remote.<name>.* settings
        self.fetch_head = None      # "replaced" or "removed": an earlier version's FETCH_HEAD (repair_fetch_head)
        self.errors = []

    def changed(self):
        return bool(self.tags_added or self.refs_added or self.refs_moved or self.refs_deleted
                    or self.branch_settings or self.remote_settings or self.reflogs_taken or self.fetch_head)


def sync_git_meta(src_repo, dst_repo, record, label, created, apply):
    """Bring the settings, remote-tracking refs and tags the source gained since the last sync into the copy.

    record is the family's record (its "config", "remotes", "tags",
    "tag_names" and "remote_urls" are read and updated); label names the
    remote fetch_source fills, which is left out; created are the branches
    this run adds (a dry run's too). The source is only read.

    - Settings: a branch both sides have (or this run adds) whose branch.<b>
      section the copy lacks takes the source's entries, and so does a
      remote.<r> section the copy lacks; a section the copy has is never
      changed, and one the copy removed since the last sync stays removed.
    - Remote-tracking refs, for each remote both configure with the same URL
      (another URL: the copy's refs are its own, said once): a ref the copy
      lacks is added; one the copy left where the last sync had it, or that
      is behind the source's, is moved along; one the source pruned is
      deleted where the copy left it alone, before any is added. One the copy
      moved past the source's, moved elsewhere, deleted, or kept after the
      source pruned it, stays as the copy has it and is reported once.
      refs/remotes/<remote>/HEAD follows the source's symbolic ref the same
      way. A ref git cannot write (its name a folder of another's) is
      reported and tried again next time; the others are written.
    - Reflogs: each ref on the source's commit takes the source's reflog
      where Reflogs says so, an added one as a rule.
    - Tags: each one the source has and the copy lacks is added, unless the
      source had it at the last sync too (the copy deleted it); a tag on both
      sides on different objects is kept as the copy has it, reported once.
    - FETCH_HEAD: one an earlier version of this script wrote is undone
      (repair_fetch_head).

    Objects the copy lacks for these are fetched by the source's ref names,
    writing no ref and no FETCH_HEAD.
    """
    out = GitMetaSync()
    s_conf, d_conf = _config_sections(src_repo), _config_sections(dst_repo)
    both = set(branch_heads(src_repo)) & (set(branch_heads(dst_repo)) | set(created))

    # Settings first: a remote whose section comes now has its refs brought below.
    wanted = _settings_wanted(s_conf, both, label)
    seen = set(record.get("config") or ())
    failed = set()
    for section in sorted(wanted):
        if section in d_conf or section in seen:
            continue
        kind, _, name = section.partition(".")
        (out.branch_settings if kind == "branch" else out.remote_settings).append(name)
        if apply:
            try:
                for key, value in wanted[section]:
                    git_ok(dst_repo, "config", "--local", "--add", key, "true" if value is None else value)
            except OSError as error:
                failed.add(section)
                out.errors.append("could not add the settings of %s: %s" % (section, error))
    record["config"] = sorted(set(wanted) - failed)

    # Remote-tracking refs.
    names = _remote_names(s_conf) | _remote_names(d_conf)
    d_remotes = _remote_names(d_conf) | {name for name in out.remote_settings if "remote." + name not in failed}
    synced, url_marks = set(), {}
    for remote in sorted(r for r in _remote_names(s_conf) & d_remotes if _own_remote(r, label)):
        s_urls = _urls(s_conf, remote)
        d_urls = _urls(d_conf, remote) if "remote." + remote in d_conf else s_urls
        if s_urls == d_urls:
            synced.add(remote)
            continue
        # A digest, so a URL holding credentials is never written to the record.
        url_marks[remote] = hashlib.sha1(json.dumps([s_urls, d_urls]).encode()).hexdigest()
        if (record.get("remote_urls") or {}).get(remote) != url_marks[remote]:
            out.urls.append(remote)
    if url_marks:
        record["remote_urls"] = url_marks
    else:
        record.pop("remote_urls", None)
    s_refs, d_refs = _remote_refs(src_repo, names, synced), _remote_refs(dst_repo, names, synced)
    recorded = record.get("remotes") or {}
    remotes, plan = {}, []          # plan: (<remote>/<branch>, new value or None, old value or None)
    for short in sorted(set(s_refs) | set(d_refs)):
        s, d, r = s_refs.get(short), d_refs.get(short), recorded.get(short)
        if s is not None:
            # Past this sync, the source's value is the base: reported once.
            remotes[short] = s
        if s == d:
            continue
        if s is None:
            if r is None:
                continue                        # the copy's own
            if d == r:
                out.refs_deleted.append(short)
                plan.append((short, None, d))
            else:
                out.refs_kept.append(short)
            continue
        if d is None:
            if r is None:
                out.refs_added.append(short)
                plan.append((short, s, None))
            elif s != r:
                out.refs_kept.append(short)     # deleted in the copy; it stays deleted
            continue
        if s == r:
            continue                            # only the copy moved it
        how = "taken" if d == r else ("diverged" if _is_symbolic(s) or _is_symbolic(d)
                                     else relation(dst_repo, src_repo, d, s))
        if how in ("taken", "behind"):
            out.refs_moved.append(short)
            plan.append((short, s, d))
        elif how == "ahead":
            out.refs_ahead.append(short)
        else:
            out.refs_diverged.append(short)
    not_written = {}
    if apply and plan:
        try:
            not_written = _apply_refs(src_repo, dst_repo, plan, label)
        except OSError as error:
            out.errors.append("could not bring the remote-tracking refs: %s" % error)
            not_written = {short: None for short, _, _ in plan}
        out.errors += _failures("write the remote-tracking ref",
                                [(short, why) for short, why in sorted(not_written.items()) if why])
        for names_of in (out.refs_added, out.refs_moved, out.refs_deleted):
            names_of[:] = [short for short in names_of if short not in not_written]
        # The record stays where it was for these, so the next run tries again.
        for short in not_written:
            if short in recorded:
                remotes[short] = recorded[short]
            else:
                remotes.pop(short, None)
    record["remotes"] = remotes

    # Reflogs, once the refs are where this sync puts them (see Reflogs).
    reflogs = Reflogs(src_repo, dst_repo, label, apply)
    added, moved = set(out.refs_added), set(out.refs_moved)
    for short, s in sorted(s_refs.items()):
        if _is_symbolic(s) or (s != d_refs.get(short) and short not in added | moved):
            continue
        if reflogs.bring("refs/remotes/" + short, s, short in added | moved):
            if short in added:
                out.reflogs += 1
            else:
                out.reflogs_taken.append(short)
    out.reflogs_blocked = reflogs.blocked

    # Tags: added, never moved; one the copy deleted since the last sync stays deleted.
    s_tags, d_tags = _tags(src_repo), {ref[len("refs/tags/"):]: v for ref, v in _refs(dst_repo, "refs/tags/").items()}
    known = record.get("tag_names")
    known = None if known is None else set(known)   # None: a record from before they were kept
    kept_before, kept, adding = record.get("tags") or {}, {}, {}
    for name, s in sorted(s_tags.items()):
        d = d_tags.get(name)
        if d is None:
            if known is None or name not in known:
                adding[name] = s
        elif d != s:
            kept[name] = s
            if kept_before.get(name) != s:
                out.tags_kept.append(name)
    out.tags_added = sorted(adding)
    not_added = set()
    if apply and adding:
        try:
            _bring_objects(src_repo, dst_repo, {"refs/tags/" + name: sha for name, sha in adding.items()})
            # create fails for a tag the copy made meanwhile: an existing tag is never moved.
            failed = _update_refs(dst_repo, ["create refs/tags/%s %s" % item for item in sorted(adding.items())])
        except OSError as error:
            out.errors.append("could not add the tags: %s" % error)
            failed = [("refs/tags/" + name, None) for name in adding]
        out.errors += _failures("add the tag", [(ref[len("refs/tags/"):], why) for ref, why in failed if why])
        not_added = {ref[len("refs/tags/"):] for ref, _ in failed}
        out.tags_added = [name for name in out.tags_added if name not in not_added]
    # One that could not be added is tried again next time.
    record["tag_names"] = sorted(set(s_tags) - not_added)
    if kept:
        record["tags"] = kept
    else:
        record.pop("tags", None)

    try:
        out.fetch_head = repair_fetch_head(src_repo, dst_repo, apply)
    except OSError as error:
        out.errors.append("could not put back FETCH_HEAD: %s" % error)
    return out


def _update_refs(repo, lines, message=None):
    """Apply update-ref --stdin lines ("<verb> <ref> ...") in repo; [(ref, why)] for those not applied.

    One transaction, as a rule. When git refuses it (a ref whose name another
    holds as a folder, foo against foo/bar; one that moved meanwhile), each
    line is tried on its own, so only the refs that cannot be written are left.
    """
    if not lines:
        return []
    command = ["update-ref", "--no-deref"] + (["-m", message] if message else []) + ["--stdin"]
    if git(repo, *command, input="\n".join(lines) + "\n").returncode == 0:
        return []
    failed = []
    for line in lines:
        result = git(repo, *command, input=line + "\n")
        if result.returncode != 0:
            detail = (result.stderr.strip().splitlines() or ["exit %d" % result.returncode])[-1]
            failed.append((line.split(" ", 2)[1], re.sub(r"^(fatal|error): ", "", detail)))
    return failed


def _apply_refs(src_repo, dst_repo, plan, label):
    """Make each ref of plan ((<remote>/<branch>, new, old)) new where it is still old.

    Deletions go first, on their own, as git fetch --prune prunes before it
    fetches: a ref the source pruned may hold the name a new one needs (foo
    against foo/bar). Then the object ids, then the symbolic refs. Returns
    {<remote>/<branch>: why} for each ref that could not be written.
    """
    _bring_objects(src_repo, dst_repo, {"refs/remotes/" + short: new for short, new, _ in plan
                                        if new is not None and not _is_symbolic(new)})
    deletes, writes, symbolic = [], [], []
    for short, new, old in plan:
        ref = "refs/remotes/" + short
        if _is_symbolic(new) or _is_symbolic(old):
            symbolic.append((short, new))
        elif new is None:
            deletes.append("delete %s %s" % (ref, old))
        elif old is None:
            writes.append("create %s %s" % (ref, new))
        else:
            writes.append("update %s %s %s" % (ref, new, old))
    failed = {}
    for lines in (deletes, writes):
        for ref, why in _update_refs(dst_repo, lines, "sync: from %s" % label):
            failed[ref[len("refs/remotes/"):]] = why
    for short, new in symbolic:
        ref = "refs/remotes/" + short
        try:
            if new is None:
                git_ok(dst_repo, "symbolic-ref", "--delete", ref)
            elif _is_symbolic(new):
                git_ok(dst_repo, "symbolic-ref", ref, new[len("ref: "):])
            else:
                git_ok(dst_repo, "update-ref", "--no-deref", "-m", "sync: from %s" % label, ref, new)
        except OSError as error:
            failed[short] = str(error)
    return failed


def _failures(what, failed, limit=10):
    """One error line per item of failed ([(name, why)]), the first limit of them, and a count of the rest."""
    lines = ["could not %s %s: %s" % (what, name, why) for name, why in failed[:limit]]
    if len(failed) > limit:
        lines.append("and %d more like it" % (len(failed) - limit))
    return lines


def _fetched_from(text, urls):
    """True when each line of a FETCH_HEAD says it came from one of urls."""
    lines = [line for line in text.splitlines() if line]
    if not lines:
        return False
    for line in lines:
        fields = line.split("\t")
        if len(fields) != 3 or not any(fields[2] == url or fields[2].endswith(" of " + url) for url in urls):
            return False
    return True


def _git_path(repo, name):
    return git_ok(repo, "rev-parse", "--path-format=absolute", "--git-path", name).stdout.strip()


def repair_fetch_head(src_repo, dst_repo, apply):
    """Undo the FETCH_HEAD an earlier version's fetch of the source left in the copy; None, "replaced" or "removed".

    Before this script's fetches wrote no FETCH_HEAD, a rerun's fetch of the
    source's branches put its own in place of the one the copy took from the
    source. A FETCH_HEAD every line of which came from the source is that
    one. It becomes the source's FETCH_HEAD, as a fresh copy has it, when the
    copy has each commit that names or gets it by one of the source's refs;
    otherwise it goes, as in a repository that never fetched.
    """
    target = _git_path(dst_repo, "FETCH_HEAD")
    if os.path.islink(target) or not os.path.isfile(target):
        return None
    seen = _read_bytes(target)
    urls = {src_repo.rstrip(os.sep) or os.sep, os.path.realpath(src_repo)}
    if not _fetched_from(seen.decode("utf-8", "replace"), urls):
        return None
    source = _git_path(src_repo, "FETCH_HEAD")
    data = None if os.path.islink(source) or not os.path.isfile(source) else _read_bytes(source)
    wanted = {}
    if data:
        ids = sorted({line.split(b"\t", 1)[0].decode("ascii", "replace") for line in data.splitlines() if line})
        check = git_ok(dst_repo, "cat-file", "--batch-check", input="\n".join(ids) + "\n").stdout
        missing = {line.split()[0] for line in check.splitlines() if line.endswith(" missing")}
        if missing:
            by_id = {v: ref for ref, v in _refs(src_repo, "refs/").items() if not _is_symbolic(v)}
            wanted = {by_id[sha]: sha for sha in missing if sha in by_id}
            if len(wanted) < len(missing):
                data, wanted = None, {}
    how = "replaced" if data else "removed"
    if apply:
        _bring_objects(src_repo, dst_repo, wanted)
        # Only over what was read: a fetch in the copy meanwhile wrote the copy's own.
        try:
            if _read_bytes(target) != seen:
                return None
        except FileNotFoundError:
            return None
        if data:
            write_atomic(target, data, prefix=".session-transfer.")
        else:
            os.unlink(target)
    return how


def copy_index(src_worktree, dst_worktree):
    """Give the copy's worktree the source's index, staged blobs included.

    The new index is built beside the old one and renamed over it, so a run
    stopped halfway leaves the old index, never an empty one.
    """
    listing = git_ok(src_worktree, "ls-files", "-s", "-z", binary=True).stdout
    entries = [e for e in listing.split(b"\0") if e]
    blobs = sorted({e.split(b" ", 2)[1] for e in entries if not e.startswith(b"160000")})
    if blobs:
        check = git_ok(dst_worktree, "cat-file", "--batch-check", input=b"\n".join(blobs) + b"\n", binary=True).stdout
        for line in check.splitlines():
            if line.endswith(b" missing"):
                sha = line.split()[0].decode()
                blob = git_ok(src_worktree, "cat-file", "blob", sha, binary=True).stdout
                git_ok(dst_worktree, "hash-object", "-w", "--stdin", input=blob, binary=True)
    index = git_ok(dst_worktree, "rev-parse", "--path-format=absolute", "--git-path", "index").stdout.strip()
    tmp = index + ".session-transfer"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    try:
        git_ok(dst_worktree, "read-tree", "--empty", env={"GIT_INDEX_FILE": tmp})
        git_ok(dst_worktree, "update-index", "-z", "--index-info", input=listing, binary=True,
               env={"GIT_INDEX_FILE": tmp})
        os.replace(tmp, index)
    finally:
        if os.path.lexists(tmp):
            os.unlink(tmp)


def copy_blocker(src_worktree, dst_repo, due=()):
    """Why a feature worktree cannot join dst_repo as a worktree as it stands, or None.

    due: branches this run moves or adds in the copy (a dry run has not yet).
    """
    ref, sha = head_state(src_worktree).split(" ", 1)
    if not sha:
        return "it has no commit checked out"
    if ref == "detached":
        if git(dst_repo, "cat-file", "-e", sha + "^{commit}").returncode != 0:
            return "its detached HEAD %s is on no branch the copy has" % sha[:10]
        return None
    name = ref[len("refs/heads/"):]
    where = checked_out(dst_repo).get(name)
    if where:
        return "%s is checked out in %s already" % (name, tilde(where))
    if branch_heads(dst_repo).get(name) != sha and name not in due:
        return "the copy's %s is not where the source's is (see the branches above)" % name
    return None


def sync_worktree_git(src_worktree, dst_worktree, src_repo, dst_repo, mark, heads, apply, busy=(), label="source"):
    """Bring the source worktree's HEAD and index over when the copy left its own alone.

    Returns (what, detail): same, kept (only the copy moved), taken,
    diverged (moved on both sides; diverged-seen when the source has not moved
    since that was reported) or refused, with the reason. mark holds head and
    index of the last sync; heads is the branch record, updated for a branch
    this moves. label names the source in the reflog's sync lines.
    """
    sh, si = head_state(src_worktree), index_digest(src_worktree)
    dh, di = head_state(dst_worktree), index_digest(dst_worktree)
    rh, ri = mark.get("head"), mark.get("index")
    if (sh, si) == (dh, di):
        mark.update(head=sh, index=si)
        mark.pop("diverged", None)
        return "same", None
    if (sh, si) == (rh, ri):
        mark.pop("diverged", None)
        return "kept", None
    if (dh, di) != (rh, ri):
        # The record keeps the state both had, so files stay pending until
        # git agrees again; the source's state now is remembered so this is
        # reported once.
        seen = mark.get("diverged") == [sh, si]
        mark["diverged"] = [sh, si]
        return ("diverged-seen" if seen else "diverged"), "HEAD or the index moved on both sides"
    ref, sha = sh.split(" ", 1)
    if not sha:
        return "refused", "the source has no commit checked out"
    if git(dst_repo, "cat-file", "-e", sha + "^{commit}").returncode != 0 and apply:
        return "refused", "its commit %s is on no branch the copy fetched" % sha[:10]
    if ref != "detached":
        name = ref[len("refs/heads/"):]
        d = branch_heads(dst_repo).get(name)
        if name in busy:
            return "refused", "%s is checked out in another worktree of the copy" % name
        if d not in (None, sha) and dh.split(" ", 1)[0] != ref:
            how = "taken" if d == heads.get(name) else relation(dst_repo, src_repo, d, sha)
            if how not in ("taken", "behind"):
                return "refused", "the copy's %s moved on since the last sync" % name
    if apply:
        # The index first: stopped after it, the copy shows the source's
        # changes as staged, which loses nothing; the refs last.
        copy_index(src_worktree, dst_worktree)
        if ref != "detached":
            git_ok(dst_repo, "update-ref", "-m", "sync: from %s" % label, ref, sha)
            git_ok(dst_worktree, "symbolic-ref", "HEAD", ref)
            heads[ref[len("refs/heads/"):]] = sha
        else:
            git_ok(dst_worktree, "update-ref", "--no-deref", "-m", "sync: from %s" % label, "HEAD", sha)
    mark.update(head=sh, index=si)
    mark.pop("diverged", None)
    return "taken", None


def adopt_legacy_dir(new, legacy, apply):
    """The folder a record lives in: new, or the one the pre-rename tool left, renamed to new when applying."""
    if os.path.lexists(new) or os.path.islink(legacy) or not os.path.isdir(legacy):
        return new
    if not apply:
        return legacy
    try:
        os.rename(legacy, new)
    except OSError:
        return legacy
    return new


class Record:
    """What the last sync of one session family left: a JSON file, and per session its paths and own writes.

    The data's "tag_names" (thousands, in a big repository) are kept apart
    from the JSON, in TAG_NAMES; without that file there are none, as in a
    record from before they were kept. HISTORY holds the signatures of the
    family's history files (merge_files); without it there are none, as in a
    record from before they were kept.
    """

    TAG_NAMES = "tag-names.gz"
    HISTORY = "history.gz"

    def __init__(self, directory):
        self.dir = directory
        self.data = json.loads(read_text(os.path.join(directory, "record.json")) or "{}")
        self.data.setdefault("sessions", {})
        self.data.pop("tag_names", None)
        try:
            with gzip.open(os.path.join(directory, self.TAG_NAMES), "rt") as f:
                self.data["tag_names"] = [name for name in f.read().split("\0") if name]
        except (OSError, EOFError, ValueError):
            pass    # none kept, or unreadable: the next sync brings each tag the copy lacks, and writes it afresh
        self._paths = {}
        self._written = {}
        self._dirty = set()
        self._history = None
        self._history_dirty = False

    def history(self):
        """Path of each history file merged into the receiving side -> its signatures (see merge_files)."""
        if self._history is None:
            try:
                with gzip.open(os.path.join(self.dir, self.HISTORY), "rt") as f:
                    loaded = json.loads(f.read())
                self._history = loaded if isinstance(loaded, dict) else {}
            except (OSError, EOFError, ValueError):
                # None kept yet, or unreadable: nothing is taken on its word, and a file
                # changed on both sides is reported once more.
                self._history = {}
        return self._history

    def history_changed(self):
        self._history_dirty = True

    def session(self, name):
        return self.data["sessions"].setdefault(name, {})

    def _load(self, name, suffix, empty):
        path = os.path.join(self.dir, name + suffix)
        try:
            with gzip.open(path, "rt") as f:
                return f.read()
        except FileNotFoundError:
            if self.data["sessions"].get(name):
                # Without it every file deleted on the receiving side would
                # look new on the source's and come back.
                raise OSError("the record of %s's last sync has lost %s; move %s aside to copy it afresh"
                              % (name, tilde(path), tilde(self.dir)))
            return empty
        except (OSError, EOFError, ValueError) as error:
            raise OSError("the record of %s's last sync is unreadable (%s): %s"
                          % (name, tilde(path), getattr(error, "strerror", None) or error))

    def paths(self, name):
        if name not in self._paths:
            self._paths[name] = set(self._load(name, ".paths.gz", "").split("\0")) - {""}
        return self._paths[name]

    def written(self, name):
        if name not in self._written:
            try:
                self._written[name] = json.loads(self._load(name, ".written.gz", "{}"))
            except OSError:
                self._written[name] = {}
        return self._written[name]

    def set_paths(self, name, paths, written=None):
        self._paths[name] = paths
        self._written[name] = written or {}
        self._dirty.add(name)

    def forget(self, name):
        self.data["sessions"].pop(name, None)
        self._paths[name] = None
        self._written[name] = None
        self._dirty.add(name)

    def save(self):
        if not self.data["sessions"] and not os.path.isdir(self.dir):
            return
        os.makedirs(self.dir, exist_ok=True)
        for name in sorted(self._dirty):
            paths, written = self._paths.get(name), self._written.get(name)
            self._save(name + ".paths.gz", None if paths is None else "\0".join(sorted(paths)))
            self._save(name + ".written.gz", None if written is None else json.dumps(written))
        self._dirty.clear()
        if self._history_dirty:
            self._save(self.HISTORY, json.dumps(self._history, separators=(",", ":"), sort_keys=True))
            self._history_dirty = False
        data = dict(self.data)
        tag_names = data.pop("tag_names", None)
        self._save(self.TAG_NAMES, None if tag_names is None else "\0".join(tag_names))
        write_atomic(os.path.join(self.dir, "record.json"),
                     (json.dumps(data, indent=1, sort_keys=True) + "\n").encode(), prefix=".record.")

    def _save(self, filename, text):
        target = os.path.join(self.dir, filename)
        if text is None:
            if os.path.lexists(target):
                os.unlink(target)
            return
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".record.")
        os.close(fd)
        with gzip.open(tmp, "wt") as f:
            f.write(text)
        os.replace(tmp, target)


def shown(names, limit=10):
    if len(names) <= limit:
        return ", ".join(names)
    return "%s and %d more" % (", ".join(names[:limit]), len(names) - limit)


def counted(names, limit=10):
    """How many, and which (the first limit of them)."""
    return "%d (%s)" % (len(names), shown(names, limit))


class Syncer:
    """Brings a copy up to date with its source, saying what it did; both directions use it.

    src and dst are what the reader calls the two sides (cs, code-sessions). say,
    problem and log are the calling script's.
    """

    SHOWN = 10

    def __init__(self, src, dst, apply, say, problem, log, log_path, tmp_suffix):
        self.src, self.dst = src, dst
        self.apply = apply
        self.say, self.problem, self.log = say, problem, log
        self.log_path = log_path
        self.tmp_suffix = tmp_suffix
        self.fetched = set()

    def fetch(self, src_repo, dst_repo):
        if self.apply and dst_repo not in self.fetched:
            fetch_source(dst_repo, src_repo, self.src)
            self.fetched.add(dst_repo)

    def repo(self, name, src_repo, dst_repo, record):
        """Fetch the source's branches into the copy and move along those the copy left alone; then bring
        the settings, remote-tracking refs and tags the copy lacks (sync_git_meta)."""
        self.fetch(src_repo, dst_repo)
        busy = checked_out(dst_repo)
        result = sync_branches(src_repo, dst_repo, record.data.get("heads", {}), self.apply, skip=set(busy),
                               label=self.src)
        record.data["heads"] = result.heads
        verb = "" if self.apply else "would be "
        if result.created:
            self.say("branches new in %s, %sadded: %s%s" % (self.src, verb, shown(result.created),
                                                           self.with_reflogs(result.reflogs, len(result.created))))
        if result.moved:
            self.say("branches %s moved on, %smoved along: %s" % (self.src, verb, shown(result.moved)))
        if result.ahead:
            self.say("branches %s moved past %s, kept: %s" % (self.dst, self.src, shown(result.ahead)))
        for branch in result.diverged:
            self.problem("branch %s moved on in both %s and %s; %s's is kept, %s's is at refs/remotes/%s/%s"
                         % (branch, self.src, self.dst, self.dst, self.src, self.src, branch))
        if result.moved or result.created:
            self.log("synced-branches", session=name, created=result.created, moved=result.moved)
        meta = sync_git_meta(src_repo, dst_repo, record.data, self.src, result.created, self.apply)
        self.git_meta(name, meta, result.reflogs_taken)
        for way in dict.fromkeys(result.reflogs_blocked + meta.reflogs_blocked):
            self.problem("%s: a link or a file in %s's .git where git keeps reflogs, left as it is: %s"
                         % (name, self.dst, tilde(way)))
        return result

    def with_reflogs(self, count, total):
        """What to say of count of total refs added taking the source's reflog (see Reflogs for the rest)."""
        if not count:
            return ""
        if count < total:
            return " (%d of them with %s's reflog)" % (count, self.src)
        return " (%s %s's reflog)" % ("each with" if count > 1 else "with", self.src)

    def git_meta(self, name, meta, branch_reflogs=()):
        """Say what sync_git_meta did, or would do: a count per kind, and the names when few.

        branch_reflogs: the branches whose reflog became the source's (sync_branches), said with the refs'.
        """
        verb = "" if self.apply else "would be "
        src, dst = self.src, self.dst
        if meta.branch_settings:
            self.say("branch settings (upstream and the rest) new in %s, %sadded for: %s"
                     % (src, verb, counted(meta.branch_settings)))
        if meta.remote_settings:
            self.say("remotes new in %s, %sadded: %s" % (src, verb, counted(meta.remote_settings)))
        for remote in meta.urls:
            self.say("remote %s has another URL in %s than in %s; its remote-tracking refs are %s's own, "
                     "left as they are" % (remote, dst, src, dst))
        if meta.refs_added:
            self.say("remote-tracking refs new in %s, %sadded: %s%s"
                     % (src, verb, counted(meta.refs_added), self.with_reflogs(meta.reflogs, len(meta.refs_added))))
        if meta.refs_moved:
            self.say("remote-tracking refs %s moved on, %smoved along: %s" % (src, verb, counted(meta.refs_moved)))
        if meta.refs_deleted:
            self.say("remote-tracking refs %s pruned, %sdeleted: %s" % (src, verb, counted(meta.refs_deleted)))
        if meta.refs_ahead:
            self.say("remote-tracking refs %s fetched past %s, kept: %s" % (dst, src, counted(meta.refs_ahead)))
        if meta.refs_kept:
            self.say("remote-tracking refs %s moved or deleted, kept as they are though %s changed them: %s"
                     % (dst, src, counted(meta.refs_kept)))
        if meta.refs_diverged:
            self.problem("remote-tracking refs moved on in both %s and %s; %s's are kept: %s"
                         % (src, dst, dst, counted(meta.refs_diverged)))
        if meta.tags_added:
            self.say("tags new in %s, %sadded: %s" % (src, verb, counted(meta.tags_added)))
        if meta.tags_kept:
            self.problem("tags %s has on other objects than %s; %s's are kept: %s"
                         % (dst, src, dst, counted(meta.tags_kept)))
        reflogs = list(branch_reflogs) + meta.reflogs_taken
        if reflogs:
            self.say("reflogs only %s went on with, %sbrought over: %s" % (src, verb, counted(reflogs)))
        if meta.fetch_head:
            self.say("FETCH_HEAD is an earlier run's fetch of %s's branches, %s%s"
                     % (src, verb, "replaced by %s's" % src if meta.fetch_head == "replaced"
                        else "removed (%s's names commits %s cannot get)" % (src, dst)))
        for error in meta.errors:
            self.problem("%s: %s" % (name, error))
        if self.apply and (meta.changed() or reflogs):
            self.log("synced-git", session=name, tags_added=meta.tags_added[:LOGGED],
                     tags_added_count=len(meta.tags_added), refs_added=meta.refs_added[:LOGGED],
                     refs_moved=meta.refs_moved[:LOGGED], refs_deleted=meta.refs_deleted[:LOGGED],
                     branch_settings=meta.branch_settings, remote_settings=meta.remote_settings,
                     reflogs_brought=reflogs[:LOGGED], fetch_head=meta.fetch_head)

    def session(self, name, src, dst, src_repo, dst_repo, record, rewrites=None, relink=None, pinned=(),
                is_repo=True, skip=()):
        """Bring one worktree's git state and files over where the copy left them alone (skip: paths to leave be)."""
        mark = record.session(name)
        only = None
        if is_repo:
            self.fetch(src_repo, dst_repo)
            busy = {b for b, where in checked_out(dst_repo).items()
                    if os.path.realpath(where) != os.path.realpath(dst)}
            how, why = sync_worktree_git(src, dst, src_repo, dst_repo, mark, record.data.setdefault("heads", {}),
                                         self.apply, busy, label=self.src)
            if how == "taken":
                ref, sha = head_state(src).split(" ", 1)
                self.say("%s: %s %s's HEAD and index: %s at %s" % (
                    name, "took" if self.apply else "would take", self.src,
                    ref.replace("refs/heads/", "") if ref != "detached" else "a detached HEAD", sha[:10]))
            elif how == "kept":
                self.say("%s: HEAD and index moved on in %s only, kept" % (name, self.dst))
            elif how in ("diverged", "refused"):
                self.problem("%s: git left as %s has it: %s; only its .cs/ is brought over until git agrees "
                             "again" % (name, self.dst, why))
            if how in ("diverged", "diverged-seen", "refused"):
                only = SESSION_META
        # Each side's mark is taken before that side is read.
        since = mark_now()
        last = {"paths": record.paths(name), "since": mark.get("since"), "written": record.written(name),
                "state": mark.get("state"), "held": mark.get("held")}
        result = sync_files(src, dst, last, self.apply, rewrites=rewrites, relink=relink, only=only,
                            pinned=pinned, tmp_suffix=self.tmp_suffix, skip=skip)
        if self.apply:
            if is_repo:
                git(dst, "update-index", "-q", "--refresh")
            if result.failed:
                # The marks stay, so what could not be read or written is
                # looked at again next time.
                written = dict(record.written(name))
                written.update(result.written)
                record.set_paths(name, result.paths, written)
                mark["held"] = sorted(set(mark.get("held") or ()) | result.held)
            else:
                marks = dict(mark.get("since") or {})
                if only:
                    marks[only] = [since, since]
                else:
                    marks = {"": [since, since]}
                written = {p: c for p, c in record.written(name).items() if only and not _inside(p, only)}
                written.update(result.written)
                record.set_paths(name, result.paths, written)
                held = {p for p in mark.get("held") or () if only and not _inside(p, only)}
                mark.update(since=marks, state=result.state, held=sorted(held | result.held))
        parts = []
        if result.copied:
            parts.append("%d %s from %s" % (result.copied, "copied" if self.apply else "to copy", self.src))
        if result.deleted:
            parts.append("%d %s as in %s" % (result.deleted, "deleted" if self.apply else "to delete", self.src))
        if result.kept:
            parts.append("%d changed in %s only, kept" % (result.kept, self.dst))
        what = "files" if not only else "files in %s/" % only
        self.say("%s: %s: %s" % (name, what, ", ".join(parts) if parts else "nothing new in %s" % self.src))
        for rel, why in result.conflicts[:self.SHOWN]:
            self.problem("%s: kept %s's %s (%s)" % (name, self.dst, rel, why))
        if len(result.conflicts) > self.SHOWN:
            self.problem("%s: and %d more kept as %s has them; the first %d are in %s"
                         % (name, len(result.conflicts) - self.SHOWN, self.dst, LOGGED, tilde(self.log_path)))
        if result.copied or result.deleted or result.conflicts:
            self.log("synced-files", session=name, copied=result.copied, deleted=result.deleted,
                     kept_on_both_sides=[rel for rel, _ in result.conflicts[:LOGGED]],
                     kept_on_both_sides_count=len(result.conflicts))
        return result


def mark_copied(record, name, source, since, state, worktree, is_repo, paths):
    """Note in record a session just copied from source to worktree.

    The copy did not exist while it was made, so nothing in it can be an edit
    made meanwhile: its mark is the moment it is complete.
    """
    mark = record.session(name)
    mark.clear()
    mark.update(source=source, since={"": [since, time.time_ns()]}, state=state)
    if is_repo:
        mark.update(head=head_state(worktree), index=index_digest(worktree))
    record.set_paths(name, paths)
