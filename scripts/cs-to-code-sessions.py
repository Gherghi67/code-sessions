#!/usr/bin/env python3
# ABOUTME: Gives code-sessions its own copy of each stable cs session, with its features, Claude history and secrets.
# ABOUTME: cs is only read; a rerun brings over what cs changed since and keeps what code-sessions changed.
"""Copy cs sessions into code-sessions, and bring the copies up to date with cs later.

code-sessions refuses to adopt a folder that already has .cs/, so a session the stable
cs has cannot simply be adopted again. This script gives code-sessions a copy of
it instead, so `ccs <name>` opens it on the conversations cs left off with,
and the two never share a folder. --session names one session; --all takes
every one in ~/.claude-sessions, one after another:

- The session's folder is copied whole into the profile's sessions root,
  whether cs adopted it (a link in ~/.claude-sessions) or created it there (a
  folder of its own): its repository, if it has one, .cs/, node_modules,
  ignored and untracked files. On APFS the copy is a clone, which costs no
  space until either side writes. From then on it is code-sessions's own.
- A session folder inside another one's (a project cs adopted inside a
  project it adopted too) is copied once, as its own session. In the outer
  copy a link to the inner copy takes its place, and no sync of the outer
  copy ever touches that path. An inner session that is not copied gets no
  link, and the run says why; a folder the outer repository tracks files in
  comes with the outer copy as well.
- Each feature worktree (<name>@<task>) is copied beside it as a linked
  worktree of the copy's repository, on the same branch, with its index and
  uncommitted changes. A link into any cs session's folder by an absolute
  path is pointed at that session's copy, and so is each such path in a
  Python virtual environment's text files (pyvenv.cfg, bin/, an editable
  install's .pth, finder and direct_url.json); the run names each such
  environment once, with how many of its files it rewrites.
- The stable cs never reads the engine its state names: it opens Claude on
  claude_session_id. A copy whose cs state names another engine (left by
  trials of this fork) says claude, so ccs opens the same conversation; the
  run says so, and that ccs <name> --engine codex opens the Codex thread
  instead. From then on the engine is code-sessions's own.
- Each session's Claude conversations are copied from ~/.claude/projects into
  the profile's, under the folder name of the copy's path, whole: subagents,
  workflows, tool results. Their file-history, session-env and task list come
  too, and the session's prompt history from history.jsonl, with the files
  of ~/.claude/paste-cache its lines name (new files only).
- Each Codex thread a session binds (.cs/local/codex-thread-id) comes too:
  its rollout from ~/.codex/sessions into the profile's Codex home at the
  same place, which is all Codex needs to resume it by id, and its name from
  session_index.jsonl. A rollout that grew in cs is brought over; one
  code-sessions went on with is kept.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more; they come too, as history (--no-history
  leaves them out).
- Trust and per-project settings in ~/.claude.json and ~/.codex/config.toml
  are copied into the profile's under the copy's paths, while no code-sessions session
  is running.
- Secrets are copied from the stable cs store into the profile's (the
  keychain, as code-sessions:<session>:<name>), through each side's
  cs-secrets, values on stdin (cs-secrets's keychain backend then passes the
  value to `security -w`, in that process's arguments).
- With --all, a folder in ~/.claude-sessions that is no session (no .cs/) and
  the root's .voice/ come too, file by file: new files and files that only
  grew, never over what the profile changed. .usage/ (each install keeps its
  own usage cache), .spawn/ (runtime) and index.md (cs writes it afresh) stay,
  and the run names them.

A rerun brings over what cs changed since the last one, wherever code-sessions left
the same thing alone: branches cs moved (fetched into the copy, also as
refs/remotes/cs/*; a branch new in cs comes with its reflog), a worktree's
HEAD and index, files, keys of .cs/local/state, conversations, and features
cs started. The rest of what a fresh copy's repository would have comes too:
each tag cs has and code-sessions lacks, unless code-sessions deleted it (one
on both sides on different objects keeps code-sessions's); the remote-tracking
refs of each remote both configure with the same URL (added, moved along, or
deleted where cs pruned them and code-sessions left them alone, deletions
first; refs/remotes/<remote>/HEAD follows cs's), a remote of another URL being
code-sessions's own; and the branch.<name> and remote.<name> settings
code-sessions has none of, such as the upstream of a branch cs pushed. A ref
or tag git will not write (its name a folder of another's) is reported and
tried again next time. A branch or remote-tracking ref on cs's commit takes
cs's reflog where code-sessions's holds nothing of its own and the copy has
every commit it names. Its fetches write no FETCH_HEAD, so the copy's stays
its own; one an earlier version's fetch of cs's branches wrote becomes cs's
again.
What code-sessions changed is kept until both sides hold the same content
again; something changed on both sides keeps code-sessions's and is reported
once per change in cs. A secret whose value differs is reported, never
overwritten.
Conversations grow by appending, so one code-sessions's copy holds an unchanged
start of is brought over, and one code-sessions went on with is kept. A file
Claude Code rewrites whole instead (a conversation's workflow state, a task)
comes when cs rewrote it and code-sessions's copy is still as a run left it:
the record keeps each copy's size, mtime and ctime right after the run wrote
it or found it equal to cs's, and cs's file's when a run read it, so an
unchanged ctime proves the copy untouched, and an unchanged cs file tells a
rewrite in code-sessions alone (kept). A copy an earlier version of this script
made has no such entry: where cs rewrote it, it is kept and reported once as
continued in both. See merge_files in session_transfer.py.

Nothing outside the profile is written: ~/.claude-sessions, the project and
its feature folders, ~/.claude, ~/.claude.json, ~/.codex and the keychain are
only read, and git runs there only to read. The record of the last sync and a
log of every change are in the profile's .cs-to-code-sessions/.

Left behind, and said so: an encrypted session, a session whose folder is
there but cannot be read, a feature worktree git does not list or whose base
is not copied, anything whose name code-sessions already uses for something
else, and a name whose rename in the profile (.rename-profile-session/) has
not finished. A session whose folder is gone (nothing at its link's target)
is left too, as a note rather than a problem, since cs cannot open it either;
its Claude conversations and prompt history still come, under the same names,
as history. --all ends with a line per session and the count of problems.

    scripts/cs-to-code-sessions.py --session wap            # print what would happen; change nothing
    scripts/cs-to-code-sessions.py --session wap --apply    # copy; rerun to bring over what cs did since
    scripts/cs-to-code-sessions.py --all                    # the same for every cs session

Paths come from HOME and the options below, never from CS_* variables: inside
a session those name the session manager running it.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

from session_transfer import (
    STATE, Record, Rewrites, SecretsError, Syncer, Tally, adopt_legacy_dir, admin_dir_for,
    claude_project_key, clone_tree, copy_admin_dir, copy_blocker, copy_index, copy_secret, git, mark_copied, mark_now,
    merge_files, merge_tree, merged_notes, merged_parts, parse_state, profile_secrets_env, read_text, reap, relinker,
    repo_marks, scrubbed_env, secret_names, session_is_open, secret_differs, shown, state_value, tilde, write_atomic,
)

TMP_SUFFIX = ".cs-to-code-sessions.tmp"
TMP_PREFIX = ".cs-to-code-sessions."
VAULT_LINKS = ("memory", "plans", "claude-config", "private")
# What the cs root holds besides sessions: copied with --all, file by file, or
# left, each for its reason. Any other hidden entry is left too, and named.
ROOT_FOLDERS = (".voice",)
ROOT_LEFT_OUT = {
    ".usage": "each install keeps its own usage cache",
    ".spawn": "runtime files of a running cs",
    "index.md": "cs writes it afresh",
}
SETTINGS = os.path.join(".claude", "settings.local.json")
# What keeps a conversation open in a folder: an engine, or the session manager running one.
ENGINES = {"claude", "codex", "cs", "code-sessions", "ccs"}
# Fields of a .claude.json project entry that describe its last run, not its settings.
VOLATILE = re.compile(r"^(last|exampleFiles)")
SCRATCH = re.compile(r"^-private-tmp-claude-\d+-")
# A conversation's scratch folder: <project>/<conversation id>/scratchpad[/...].
SCRATCHPAD = r"-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-scratchpad(?:-|$)"
# A Codex thread id, as .cs/local/codex-thread-id holds it, and the rollout Codex
# keeps of a thread: <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl.
THREAD_ID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
ROLLOUT = re.compile(r"rollout-.*-([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\.jsonl\Z")
# The engine line of .cs/local/state. The stable cs never reads it and always opens Claude.
ENGINE_LINE = re.compile(rb"^engine:(.*)$", re.M)
# A file of ~/.claude/paste-cache is named after the contentHash a history.jsonl line gives.
PASTE_HASH = re.compile(r"[0-9A-Za-z]+\Z")


def stat_error(path):
    """(missing, why) for path, links followed: missing when nothing is there (no such file, or a
    file where the path needs a folder); why is the error that stopped the look, or None."""
    try:
        os.stat(path)
    except (FileNotFoundError, NotADirectoryError) as error:
        return True, error.strerror or str(error)
    except OSError as error:
        return False, error.strerror or str(error)
    return False, None


def claude_engine(data):
    """cs's state (bytes) naming claude where it names an engine the stable cs does not run; None if unchanged.

    The stable cs opens Claude on claude_session_id whatever the state says,
    so the copy says claude and ccs opens the same conversation.
    """
    def fix(match):
        return match.group(0) if match.group(1).strip() in (b"", b"claude") else b"engine: claude"
    moved = ENGINE_LINE.sub(fix, data)
    return moved if moved != data else None


class Session:
    """A base or one of its feature worktrees, as cs has it and as code-sessions will."""

    def __init__(self, importer, name, cs_path, kind="session"):
        self.name = name
        self.cs_path = cs_path
        self.kind = kind        # session, folder (no .cs: copied file by file), gone (its folder is), orphan
        self.source = None      # cs's folder
        self.skip = None
        self.state = None       # free, ours (copied by an earlier run) or gone (code-sessions removed its copy)
        self.failed = False
        self.admin = None       # a feature's administrative directory in cs's repository
        self.record = None      # a base's record of the last sync
        self.is_repo = False
        self.branches = None
        self.nested = []        # (path inside this folder, name) of each other cs session's folder there
        self.left = {}          # path of nested -> why its session is not copied: no link in its place
        self.shared = []        # (path, name) of a session folder this one's repository tracks: copied here too
        self.held = []          # (path, name) of a link to a session cs no longer has, kept as it is
        self.features = []
        self.open_now = []
        self.gone_in_cs = []
        self.outcome = ""       # its line in the summary
        self.problems = 0
        self.synced = None      # the FileSync of this run's sync of a copy made by an earlier run
        self.ccs_path = os.path.join(importer.ccs_root, name)
        self.ccs_physical = os.path.join(importer.ccs_root_real, name)

    @property
    def meta(self):
        return os.path.join(self.source, ".cs")

    @property
    def nested_paths(self):
        """Paths no copy or sync of this folder goes into."""
        return [rel for rel, _ in self.nested + self.held]

    @property
    def links(self):
        """(path, name) of each nested session folder whose copy a link stands for here."""
        return [(rel, name) for rel, name in self.nested if rel not in self.left]


class Importer:
    def __init__(self, args):
        expand = lambda p: os.path.abspath(os.path.expanduser(p))
        self.apply = args.apply
        self.history = not args.no_history
        self.profile = expand(args.profile)
        self.cs_root = expand(args.cs_root)
        self.claude_dir = expand(args.claude_dir)
        self.claude_json = expand(args.claude_json)
        self.codex_home = expand(args.codex_home)
        self.cs_secrets = expand(args.cs_secrets)
        self.all = args.all
        self.names = args.session or []
        self.ccs_root = os.path.join(self.profile, "sessions")
        if not os.path.isdir(self.ccs_root):
            raise SystemExit("No code-sessions sessions root at %s; run setup.sh first, or pass --profile." % tilde(self.ccs_root))
        if not os.path.isdir(self.cs_root):
            raise SystemExit("No cs sessions root at %s; pass --cs-root." % tilde(self.cs_root))
        self.ccs_root_real = os.path.realpath(self.ccs_root)
        self.cs_root_real = os.path.realpath(self.cs_root)
        self.ccs_claude = os.path.join(self.profile, ".claude")
        self.ccs_codex = os.path.join(self.profile, ".codex")
        self.ccs_secrets = os.path.join(self.profile, ".local", "bin", "cs-secrets")
        self.ccs_secrets_dir = os.path.join(self.profile, ".cs-secrets")
        self.record_root = adopt_legacy_dir(os.path.join(self.profile, ".cs-to-code-sessions"),
                                            os.path.join(self.profile, ".cs-to-ags"), self.apply)
        self.log_path = os.path.join(self.record_root, "log.jsonl")
        self.failed = False
        self.problems = 0
        self.in_run = set()
        self._processes = None
        self._roots = None
        self._relink = None
        self._probes = {}
        self._rollouts = None
        self._paste_names = None
        self.pasted = set()     # paste-cache hashes this run has dealt with
        self.folders = self.session_folders()
        self.syncer = Syncer("cs", "code-sessions", self.apply, self.say, self.problem, self.log, self.log_path, TMP_SUFFIX)

    # --- planning -------------------------------------------------------

    def session_folders(self):
        """The real folder of each session in the cs root, features included: name -> path."""
        out = {}
        for entry in sorted(os.listdir(self.cs_root)):
            if entry.startswith(".") or entry in ROOT_LEFT_OUT:
                continue
            real = os.path.realpath(os.path.join(self.cs_root, entry))
            if os.path.isdir(os.path.join(real, ".cs")):
                out[entry] = real
        return out

    def scan(self):
        """What --all takes from the cs root: bases, features whose base is missing, root folders, what stays."""
        entries = sorted(os.listdir(self.cs_root))
        names, orphans, folders, left = [], [], [], []
        for entry in entries:
            path = os.path.join(self.cs_root, entry)
            if entry in ROOT_FOLDERS and os.path.isdir(path) and not os.path.islink(path):
                folders.append(entry)
            elif entry in ROOT_LEFT_OUT:
                left.append("%s (%s)" % (entry, ROOT_LEFT_OUT[entry]))
            elif entry.startswith("."):
                left.append("%s (hidden, not a session)" % entry)
            elif not os.path.islink(path) and not os.path.isdir(path):
                left.append("%s (a file, not a session)" % entry)
            elif "@" not in entry:
                names.append(entry)
        for entry in entries:
            if "@" in entry and not entry.startswith(".") and entry.partition("@")[0] not in names:
                orphans.append(entry)
        return names, orphans, folders, left

    def nested_in(self, session):
        """Each other session folder inside session's, as (path inside it, name): those copied on their
        own, the outermost only, and those session's repository tracks files in, which come with it too."""
        inner = sorted((os.path.relpath(real, session.source), name) for name, real in self.folders.items()
                       if real.startswith(session.source + os.sep))
        out, shared = [], []
        own_repo = os.path.lexists(os.path.join(session.source, ".git"))
        for rel, name in inner:
            if any(rel == r or rel.startswith(r + os.sep) for r, _ in out):
                continue
            # A subproject the outer repository tracks: left out, it would show as deleted there.
            if own_repo and git(session.source, "ls-files", "-z", "--", ":(literal)" + rel).stdout:
                shared.append((rel, name))
            else:
                out.append((rel, name))
        return out, shared

    def recorded_links(self, base, session):
        """Links an earlier run put in session's copy for a session cs no longer has there: kept as they are."""
        if session.state != "ours":
            return []
        current = {rel for rel, _ in session.nested + session.shared}
        recorded = (base.record.data.get("nested") or {}).get(session.name) or {}
        return [(rel, name) for rel, name in sorted(recorded.items())
                if rel not in current and self.is_link_to_copy(session, rel, name)]

    def is_link_to_copy(self, session, rel, name):
        where = os.path.join(session.ccs_physical, rel)
        return os.path.islink(where) and os.readlink(where) == os.path.join(self.ccs_root, name)

    def unfinished_rename(self, name):
        """Why code-sessions's own session called name is still being renamed, or None.

        A rename of a profile session (.cs/local/rename-profile-session.py)
        moves its folder first and its transcripts, prompt history, settings
        and secrets after; its record in <profile>/.rename-profile-session/
        says finished once all have moved. Until then they may still be under
        the old name, a copy under that name would merge into them, and the
        rename could no longer finish. Only read: nothing here writes there.
        """
        folder = os.path.join(self.profile, ".rename-profile-session")
        for entry in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if not (entry.startswith(name + "-to-") and entry.endswith(".json")):
                continue
            try:
                record = json.loads(read_text(os.path.join(folder, entry)) or "{}")
            except ValueError:
                record = {"old": name, "new": entry[len(name + "-to-"):-len(".json")]}
            if isinstance(record, dict) and record.get("old") == name and not record.get("finished"):
                return ("the rename of code-sessions's own %s to %s has not finished (record %s); finish it, "
                        "then rerun" % (name, record.get("new"), tilde(os.path.join(folder, entry))))
        return None

    def settle_nested(self, bases):
        """Which nested session folders a link stands for: those whose session is copied, now or by a run
        that names it. A link to any other would lead into a different session of that name, or nowhere."""
        planned = {s.name: s for b in bases for s in [b] + b.features}
        for base in bases:
            for session in [base] + base.features:
                if session.skip:
                    continue
                for rel, name in session.nested:
                    why = self.not_copied(name, planned)
                    if why:
                        session.left[rel] = why

    def not_copied(self, name, planned):
        """Why the cs session name is not copied, or None when it is (or a run that names it would copy it)."""
        session = planned.get(name)
        if session is None:
            base_name = name.partition("@")[0]
            if not os.path.lexists(os.path.join(self.cs_root, base_name)):
                return "its base %s is not in cs" % base_name
            if base_name not in self._probes:
                self._probes[base_name] = self.plan_safely(base_name)
            probe = self._probes[base_name]
            session = probe if base_name == name else next((f for f in probe.features if f.name == name), None)
            if session is None:
                return "its base %s does not list it" % base_name
        if session.skip:
            return session.skip
        if session.state == "gone":
            return "code-sessions removed its copy after an earlier run"
        return None

    def feature_entries(self, name):
        prefix = name + "@"
        return [e for e in sorted(os.listdir(self.cs_root)) if e.startswith(prefix) and len(e) > len(prefix)]

    def plan_orphans(self, base, why=None):
        """The base is not copied, so neither is any of its features: say so for each."""
        why = why or "its base %s is not copied" % base.name
        for entry in self.feature_entries(base.name):
            feature = Session(self, entry, os.path.join(self.cs_root, entry))
            feature.skip = why
            base.features.append(feature)

    def plan(self, name):
        base = Session(self, name, os.path.join(self.cs_root, name))
        if not os.path.lexists(base.cs_path):
            raise SystemExit("No cs session named %s in %s." % (name, tilde(self.cs_root)))
        linked = os.path.islink(base.cs_path)
        base.source = os.path.realpath(base.cs_path)
        if linked:
            # Only a target that is not there is gone: one that is there but
            # cannot be read, or is no folder, is a problem, since cs may still open it.
            target = tilde(os.readlink(base.cs_path))
            missing, error = stat_error(base.cs_path)
            if missing:
                base.kind = "gone"
                base.skip = "its directory %s no longer exists" % target
            elif error:
                base.skip = "its directory %s cannot be read: %s" % (target, error)
            elif not os.path.isdir(base.cs_path):
                base.skip = "its link points at %s, which is not a folder" % target
            if base.skip:
                self.plan_orphans(base)
                return base
        elif not os.path.isdir(base.source):
            base.skip = "a file, not a session"
            self.plan_orphans(base)
            return base
        if not os.path.isdir(base.meta):
            if linked:
                missing, error = stat_error(base.meta)
                base.skip = ("%s cannot be read: %s" % (tilde(base.meta), error) if error and not missing
                             else "%s has no .cs folder" % tilde(base.source))
                self.plan_orphans(base)
                return base
            return self.plan_folder(base)
        if os.path.lexists(os.path.join(base.meta, "local", "pre-open")) or any(
                os.path.islink(os.path.join(base.meta, sub)) for sub in VAULT_LINKS):
            base.skip = "encrypted: its vault opens only with its password, so this script leaves it"
            self.plan_orphans(base)
            return base
        renaming = self.unfinished_rename(name)
        if renaming:
            base.skip = renaming
            self.plan_orphans(base)
            return base
        git_dir = os.path.join(base.source, ".git")
        if os.path.lexists(git_dir) and (os.path.islink(git_dir) or not os.path.isdir(git_dir)):
            base.skip = "its repository lives elsewhere (.git is not a folder), so a copy would still share it"
            self.plan_orphans(base)
            return base
        base.is_repo = os.path.isdir(git_dir)
        base.record = Record(os.path.join(self.record_root, name))
        if not os.path.lexists(base.ccs_path):
            base.state = "free"
            # A record whose copy is gone is history: the next copy starts over.
            for old in list(base.record.data["sessions"]):
                base.record.forget(old)
            base.record.data = {"sessions": {}}
        elif (os.path.isdir(base.ccs_path) and not os.path.islink(base.ccs_path)
              and base.record.data.get("source") == base.source):
            base.state = "ours"
        else:
            base.skip = "code-sessions already has a different %s; remove that one, then rerun" % name
            self.plan_orphans(base)
            return base
        base.nested, base.shared = self.nested_in(base)
        base.held = self.recorded_links(base, base)
        if base.is_repo:
            self.plan_features(base)
        else:
            self.plan_orphans(base, "its base %s has no repository, so it cannot be a worktree of it" % name)
        base.open_now = self.open_sessions(base)
        return base

    def plan_folder(self, base):
        """A folder in the cs root with no .cs: no session, so its files are merged in, the profile's kept."""
        base.kind = "folder"
        if not os.path.lexists(base.ccs_path):
            base.state = "free"
        elif (os.path.isdir(base.ccs_path) and not os.path.islink(base.ccs_path)
              and not os.path.isdir(os.path.join(base.ccs_path, ".cs"))):
            base.state = "ours"
        else:
            base.skip = "code-sessions already has a different %s; remove that one, then rerun" % base.name
        self.plan_orphans(base, "its base %s is a folder, not a session" % base.name)
        return base

    def plan_features(self, base):
        listing = git(base.source, "worktree", "list", "--porcelain").stdout
        registered = {line[len("worktree "):] for line in listing.splitlines() if line.startswith("worktree ")}
        recorded = base.record.data["sessions"]
        admin_root = os.path.join(base.source, ".git", "worktrees") + os.sep
        prefix = base.name + "@"
        for entry in sorted(os.listdir(self.cs_root)):
            if not entry.startswith(prefix) or len(entry) == len(prefix):
                continue
            feature = Session(self, entry, os.path.join(self.cs_root, entry))
            base.features.append(feature)
            feature.source = os.path.realpath(feature.cs_path)
            if not os.path.isdir(os.path.join(feature.source, ".cs")):
                feature.skip = "not a cs session (no .cs folder)"
                continue
            top = git(feature.source, "rev-parse", "--show-toplevel").stdout.strip()
            if (top or feature.source) not in registered:
                feature.skip = ("not a registered worktree of %s's repository (pruned or made by hand?)"
                                % base.name)
                continue
            pointer = read_text(os.path.join(feature.source, ".git")) or ""
            admin = pointer[len("gitdir:"):].strip() if pointer.startswith("gitdir:") else ""
            admin = os.path.realpath(os.path.join(feature.source, admin)) if admin else ""
            if not admin.startswith(admin_root) or not os.path.isdir(admin):
                feature.skip = "not a linked worktree of %s's repository" % base.name
                continue
            feature.admin = admin
            feature.nested, feature.shared = self.nested_in(feature)
            if not os.path.lexists(feature.ccs_path):
                feature.state = "gone" if entry in recorded else "free"
            elif (os.path.isdir(feature.ccs_path) and not os.path.islink(feature.ccs_path)
                  and (recorded.get(entry) or {}).get("source") == feature.source):
                feature.state = "ours"
                feature.held = self.recorded_links(base, feature)
            else:
                feature.skip = "code-sessions already has a different %s; remove that one, then rerun" % entry
        listed = {f.name for f in base.features}
        base.gone_in_cs = sorted(n for n in recorded if n != base.name and n not in listed)

    def open_sessions(self, base):
        """Which of the session's folders an engine or a session manager runs in right now.

        A lock is not enough: cs execs claude in its place, and the lock goes with it.
        """
        sessions = [base] + [f for f in base.features if not f.skip]
        found = {s.name: [] for s in sessions if session_is_open(s.meta)}
        listing, commands = self.processes()
        inside = lambda cwd, root: cwd == root or cwd.startswith(root + os.sep)
        # The deepest folder first: a feature may live inside the project.
        by_depth = sorted(sessions, key=lambda s: len(s.source), reverse=True)
        # Another session's folder inside one of these is that session's; a
        # feature's inside its own project is the feature's, found by depth.
        names = {s.name for s in sessions}
        elsewhere = [os.path.join(s.source, rel) for s in sessions for rel, name in s.nested if name not in names]
        pid = None
        for line in listing.splitlines():
            if line.startswith("p"):
                pid = line[1:]
                continue
            command = commands.get(pid, "")
            if not line.startswith("n") or not command or pid == str(os.getpid()):
                continue
            if not {os.path.basename(w) for w in command.split()[:2]} & ENGINES:
                continue
            if any(inside(line[1:], other) for other in elsewhere):
                continue
            where = next((s.name for s in by_depth if inside(line[1:], s.source)), None)
            if where:
                found.setdefault(where, []).append((pid, command))
        out = []
        for name in sorted(found):
            if found[name]:
                pid, command = found[name][0]
                more = ", and %d more" % (len(found[name]) - 1) if len(found[name]) > 1 else ""
                out.append("%s (pid %s: %s%s)" % (name, pid, command[:50], more))
            else:
                out.append(name)
        return out

    def processes(self):
        """Each process's working folder (lsof -F pn) and command line by pid, read once per run."""
        if self._processes is None:
            try:
                listing = subprocess.run(["lsof", "-a", "-d", "cwd", "-F", "pn"], stdin=subprocess.DEVNULL,
                                         capture_output=True, text=True).stdout
                table = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                       capture_output=True, text=True).stdout
            except OSError:
                listing = table = ""
            commands = {}
            for line in table.splitlines():
                pid, _, command = line.strip().partition(" ")
                commands[pid] = command.strip()
            self._processes = (listing, commands)
        return self._processes

    def ccs_running(self):
        """Lines of processes run from the profile's bin, which write the files we would merge into."""
        try:
            listing = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True).stdout
        except OSError:
            return ["(could not list processes)"]
        needle = os.path.join(os.path.realpath(self.profile), ".local", "bin") + os.sep
        return [line.strip() for line in listing.splitlines() if needle in line]

    # --- copying ---------------------------------------------------------

    def log(self, action, **fields):
        if not self.apply:
            return
        os.makedirs(self.record_root, exist_ok=True)
        fields.update(action=action, at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        with open(self.log_path, "a") as f:
            f.write(json.dumps(fields, sort_keys=True) + "\n")

    def rekey_settings(self, data, session):
        """settings.local.json names the session's memory folder by its path, which is the copy's now."""
        try:
            settings = json.loads(data)
        except ValueError:
            return None
        memory = os.path.join(session.ccs_path, ".cs", "memory")
        if not isinstance(settings, dict) or settings.get("autoMemoryDirectory") in (None, memory):
            return None
        settings["autoMemoryDirectory"] = memory
        return (json.dumps(settings, indent=2) + "\n").encode()

    def roots(self):
        """The folder of each cs session, by every spelling, -> where its copy is in code-sessions.

        A session's folder by its link in the cs root, by the link's target
        and by where it really is; inside a folder that holds another session's,
        the inner one's copy wins, as the longer path.
        """
        if self._roots is None:
            self._roots = {}
            for name, real in self.folders.items():
                cs_path = os.path.join(self.cs_root, name)
                paths = [cs_path, real, os.path.join(self.cs_root_real, name)]
                if os.path.islink(cs_path) and os.path.isabs(os.readlink(cs_path)):
                    paths.append(os.readlink(cs_path))
                for path in paths:
                    self._roots[path] = os.path.join(self.ccs_root, name)
        return self._roots

    def relink(self):
        """Absolute links into the folder of any cs session, pointed at code-sessions's copy of it."""
        if self._relink is None:
            self._relink = relinker(self.roots())
        return self._relink

    def rewrites(self, session):
        """What session's copy holds in place of cs's file: the memory folder at the copy's path, the engine cs
        opens it with, and each Python virtual environment naming the copy wherever it names a cs session's folder.

        sync_files merges .cs/local/state rather than rewrite it, so the engine
        is set in a fresh copy only; from then on it is code-sessions's own.
        """
        return Rewrites(session.source, {SETTINGS: lambda data: self.rekey_settings(data, session),
                                         STATE: claude_engine}, self.roots())

    def say_venvs(self, session, rels, done):
        """One line per Python virtual environment of session whose text files are among rels (rewritten ones)."""
        for folder, count in sorted(self.rewrites(session).venvs(rels).items()):
            self.say("%s/%s, a Python virtual environment: %d text file(s) %s to name the copy"
                     % (session.name, folder or ".", count, "rewritten" if done else "would be rewritten"))

    def say_engine(self, session):
        """Say so when cs's state names an engine the stable cs does not run: the copy's names claude."""
        engine = state_value(session.meta, "engine")
        if not engine or engine == "claude":
            return
        claude_id = state_value(session.meta, "claude_session_id")
        thread = self.codex_thread(session)
        if thread:
            other = "opens its Codex thread %s instead" % thread
        elif thread == "":
            other = "refuses until its .cs/local/codex-thread-id names a Codex thread"
        else:
            other = "starts a Codex conversation instead (it binds none)"
        self.say("engine: cs's state says %s, which the stable cs never runs: it opens Claude%s. The copy's state %s "
                 "claude, so ccs %s does the same; ccs %s --engine codex %s, and makes Codex its engine"
                 % (engine, " on conversation %s" % claude_id if claude_id else "",
                    "says" if self.apply else "would say", session.name, session.name, other))

    def codex_thread(self, session):
        """The Codex thread cs's folder of session binds: its id; "" when the binding names none; None without one."""
        path = os.path.join(session.meta, "local", "codex-thread-id")
        if not os.path.lexists(path):
            return None
        text = read_text(path) if os.path.isfile(path) else None
        value = (text or "")[:-1] if (text or "").endswith("\n") else (text or "")
        return value if THREAD_ID.match(value) else ""

    def rollouts(self):
        """Each rollout in the Codex home's sessions/, by thread id: id -> [its path inside sessions/]."""
        if self._rollouts is None:
            self._rollouts = {}
            root = os.path.join(self.codex_home, "sessions")
            for top, dirs, files in os.walk(root):
                dirs.sort()
                for name in sorted(files):
                    found = ROLLOUT.match(name)
                    if found:
                        self._rollouts.setdefault(found.group(1).lower(), []).append(
                            os.path.relpath(os.path.join(top, name), root))
        return self._rollouts

    def codex_threads(self, sessions, record=None):
        """Bring each Codex thread a session binds into the profile's Codex home: its rollout, at the same place
        under sessions/, which is all Codex needs to resume it by id, and its name from session_index.jsonl.
        record: the family's Record, which merge_files reads and keeps."""
        src = os.path.join(self.codex_home, "sessions")
        dst = os.path.join(self.ccs_codex, "sessions")
        verb = "copied" if self.apply else "to copy"
        for session in sessions:
            thread = self.codex_thread(session)
            if thread is None:
                continue
            if not thread:
                self.say("note: %s/.cs/local/codex-thread-id names no Codex thread; the copy has it as cs has it"
                         % session.name)
                continue
            what = "Codex thread %s of %s" % (thread, session.name)
            rels = self.rollouts().get(thread.lower(), [])
            if not rels:
                self.say("note: %s has no rollout in %s, so there is nothing to copy; ccs %s --engine codex "
                         "cannot resume it" % (what, tilde(src), session.name))
                continue
            tally = merge_files(src, dst, rels, self.apply, TMP_SUFFIX, record=record)
            named = self.codex_index(thread)
            index = "; its name in session_index.jsonl %s" % ("added" if self.apply else "to add") if named else ""
            if tally.pending():
                self.say("%s, rollout %s: %s%s" % (what, verb, ", ".join(merged_parts(tally, "cs")), index))
            elif index or not (tally.ahead or tally.kept or tally.diverged or tally.blocked):
                self.say("%s, rollout: nothing new%s" % (what, index))
            for line in merged_notes(tally, "cs", "code-sessions", self.apply):
                self.say(line)
            if tally.ahead:
                self.say("%s: code-sessions went on with its rollout past cs's; kept" % what)
            for path in tally.diverged:
                self.problem("continued in both cs and code-sessions, left as it is: %s" % tilde(path))
            for path in tally.blocked:
                self.problem("a link or a file in code-sessions where cs has a folder, left as it is: %s" % tilde(path))
            if tally.pending() or named:
                self.log("copied-codex-thread", session=session.name, thread=thread, new=tally.new,
                         grown=tally.grown, rewritten=len(tally.taken), named=named)

    def codex_index(self, thread):
        """Append to the profile's session_index.jsonl the lines of the Codex home's that name thread and it
        lacks (a thread's name); how many."""
        target = os.path.join(self.ccs_codex, "session_index.jsonl")
        have = set((read_text(target) or "").splitlines())
        out = []
        for line in (read_text(os.path.join(self.codex_home, "session_index.jsonl")) or "").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict) and record.get("id") == thread and line not in have:
                have.add(line)
                out.append(line)
        if out and self.apply:
            os.makedirs(self.ccs_codex, mode=0o700, exist_ok=True)
            existing = read_text(target) or ""
            with os.fdopen(os.open(target, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as f:
                f.write(("\n" if existing and not existing.endswith("\n") else "") + "\n".join(out) + "\n")
        return len(out)

    def paste_cache(self, hashes):
        """Copy the files of ~/.claude/paste-cache that hashes name and the profile lacks; how many."""
        src = os.path.join(self.claude_dir, "paste-cache")
        wanted = {h for h in hashes if PASTE_HASH.match(h)} - self.pasted
        if not wanted:
            return 0
        self.pasted |= wanted
        if self._paste_names is None:
            try:
                self._paste_names = sorted(os.listdir(src))
            except OSError:
                self._paste_names = []
        names = [n for n in self._paste_names if os.path.splitext(n)[0] in wanted]
        tally = merge_files(src, os.path.join(self.ccs_claude, "paste-cache"), names, self.apply, TMP_SUFFIX,
                            new_only=True)
        if tally.new and self.apply:
            self.log("copied-pasted-contents", files=tally.new)
        return tally.new

    def place_link(self, root, rel, name):
        """A link to name's copy at root/rel, where nothing is and every folder above it under root is a real
        one (a link on the way would put it outside root)."""
        parts = rel.split(os.sep)
        for n in range(1, len(parts)):
            try:
                if not stat.S_ISDIR(os.lstat(os.path.join(root, *parts[:n])).st_mode):
                    return False
            except FileNotFoundError:
                return False
        where = os.path.join(root, rel)
        if os.path.lexists(where):
            return False
        os.symlink(os.path.join(self.ccs_root, name), where)
        return True

    def say_nested(self, session):
        """Name each session folder inside this one's, and what the copy has in its place.

        In a copy made by an earlier run, a link that is missing is put in;
        anything else there is named, since it duplicates the inner copy.
        """
        for rel, name in session.shared:
            self.say("%s/%s is the folder of cs session %s, and %s's repository tracks files there: copied with %s "
                     "as well; %s's copy is its own" % (session.name, rel, name, session.name, session.name, name))
        for rel, name in session.nested:
            if rel in session.left:
                self.say("%s/%s is the folder of cs session %s, which is not copied (%s): left out here, with no link"
                         % (session.name, rel, name, session.left[rel]))
                continue
            copy = tilde(os.path.join(self.ccs_root, name))
            later = ""
            if name not in self.in_run and not os.path.lexists(os.path.join(self.ccs_root, name)):
                later = "; it has no copy yet: --session %s makes one" % name.partition("@")[0]
            if session.state == "free":
                self.say("%s/%s is the folder of cs session %s, copied on its own: %sleft out here, with a link "
                         "to %s in its place%s" % (session.name, rel, name, "" if self.apply else "would be ",
                                                   copy, later))
            elif self.is_link_to_copy(session, rel, name):
                self.say("%s/%s is the folder of cs session %s, copied on its own: left alone here%s"
                         % (session.name, rel, name, later))
            elif not os.path.lexists(os.path.join(session.ccs_physical, rel)):
                placed = self.apply and self.place_link(session.ccs_physical, rel, name)
                self.say("%s/%s is the folder of cs session %s, copied on its own: a link to %s %s in its place%s"
                         % (session.name, rel, name, copy, "put" if placed else "would be put", later))
            else:
                self.problem("%s/%s is the folder of cs session %s now, copied on its own, but %s's copy has its own "
                             "%s there from before: left as it is; move %s aside and rerun to put a link to %s's copy "
                             "in its place" % (session.name, rel, name, session.name, rel,
                                               tilde(os.path.join(session.ccs_path, rel)), name))
        for rel, name in session.held:
            self.say("%s/%s was the folder of cs session %s, which cs no longer has: the copy keeps its link to %s "
                     "and leaves that path alone" % (session.name, rel, name, tilde(os.path.join(self.ccs_root, name))))

    def note_links(self, base, session):
        """Record the links session's copy has for nested sessions, so a later run knows them as its own."""
        if not self.apply:
            return
        kept = {rel: name for rel, name in session.links + session.held if self.is_link_to_copy(session, rel, name)}
        nested = base.record.data.setdefault("nested", {})
        if kept:
            nested[session.name] = kept
        else:
            nested.pop(session.name, None)
        if not nested:
            base.record.data.pop("nested")

    def sync(self, base, session):
        session.synced = self.syncer.session(session.name, session.source, session.ccs_physical, base.source,
                                             base.ccs_physical, base.record, rewrites=self.rewrites(session),
                                             relink=self.relink(), is_repo=base.is_repo, skip=session.nested_paths)
        self.say_venvs(session, session.synced.rewritten, self.apply)
        self.note_links(base, session)

    def copy_base(self, base):
        os.makedirs(self.ccs_root, exist_ok=True)
        reap(self.ccs_root, ".%s%s" % (base.name, TMP_PREFIX))
        tmp = tempfile.mkdtemp(dir=self.ccs_root, prefix=".%s%s" % (base.name, TMP_PREFIX))
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(base.source, tmp, self.relink(), skip=base.nested_paths)
            for rel, name in base.links:
                self.place_link(tmp, rel, name)
            # cs's linked worktrees are not the copy's; each feature copied
            # after it gets its own entry back.
            worktrees = os.path.join(tmp, ".git", "worktrees")
            if os.path.isdir(worktrees) and not os.path.islink(worktrees):
                shutil.rmtree(worktrees)
            state = read_text(os.path.join(tmp, STATE))
            rewritten = self.rewrites(base).apply(tmp, paths, TMP_PREFIX)
            os.rename(tmp, base.ccs_path)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        base.record.data["source"] = base.source
        if base.is_repo:
            base.record.data.update(repo_marks(base.ccs_physical, self.syncer.src))
        else:
            base.record.data["heads"] = {}
        mark_copied(base.record, base.name, base.source, since, state, base.ccs_physical, base.is_repo, paths)
        self.note_links(base, base)
        base.record.save()
        self.log("copied", session=base.name, source=base.source, path=base.ccs_path)
        return rewritten

    def copy_feature(self, base, feature):
        """Copies a feature worktree as a linked worktree of the copy's repository.

        git links a worktree both ways: the worktree's .git file names an
        administrative directory in the repository (HEAD, index, per-worktree
        refs), whose gitdir file names the worktree back. The copy takes the
        original's administrative directory into code-sessions's repository and points
        the two at each other.
        """
        worktrees = os.path.join(base.ccs_physical, ".git", "worktrees")
        os.makedirs(worktrees, exist_ok=True)
        back_link = os.path.join(feature.ccs_physical, ".git") + "\n"
        admin = admin_dir_for(worktrees, os.path.basename(feature.admin), back_link)
        reap(self.ccs_root, ".%s%s" % (feature.name, TMP_PREFIX))
        tmp = tempfile.mkdtemp(dir=self.ccs_root, prefix=".%s%s" % (feature.name, TMP_PREFIX))
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(feature.source, tmp, self.relink(), skip=feature.nested_paths)
            for rel, name in feature.links:
                self.place_link(tmp, rel, name)
            state = read_text(os.path.join(tmp, STATE))
            rewritten = self.rewrites(feature).apply(tmp, paths, TMP_PREFIX)
            copy_admin_dir(feature.admin, admin)
            with open(os.path.join(admin, "gitdir"), "w") as f:
                f.write(back_link)
            with open(os.path.join(tmp, ".git"), "w") as f:
                f.write("gitdir: %s\n" % admin)
            # Staged changes may hold blobs code-sessions's repository has not got yet.
            copy_index(feature.source, tmp)
            os.rename(tmp, feature.ccs_path)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(admin, ignore_errors=True)
            raise
        mark_copied(base.record, feature.name, feature.source, since, state, feature.ccs_physical, True, paths)
        self.note_links(base, feature)
        # After each copy, so a run stopped midway leaves a record of every copy it made.
        base.record.save()
        self.log("copied-feature", session=feature.name, source=feature.source, path=feature.ccs_path)
        return rewritten

    # --- the rest of one session ------------------------------------------

    def conversations(self, old_key, new_key, record=None):
        """Merge one Claude folder and each conversation's side files; the tally and conversation count.

        record: the family's Record, which keeps what merge_files needs to bring a file cs rewrote whole
        (None for a session whose folder is gone, which has no record: cs cannot open it to rewrite one).
        """
        src = os.path.join(self.claude_dir, "projects", old_key)
        tally = merge_tree(src, os.path.join(self.ccs_claude, "projects", new_key), self.apply, TMP_SUFFIX,
                           record=record)
        count = 0
        if os.path.isdir(src):
            for name in sorted(os.listdir(src)):
                if name.endswith(".jsonl"):
                    count += 1
                    conversation = name[:-len(".jsonl")]
                    for side in ("file-history", "session-env"):
                        tally.add(merge_tree(os.path.join(self.claude_dir, side, conversation),
                                             os.path.join(self.ccs_claude, side, conversation),
                                             self.apply, TMP_SUFFIX, record=record))
        return tally, count

    def history_keys(self, base, mains, owned):
        """Claude folders of the session's retired features and scratch folders: no session owns them now.

        mains: the folder names of the session's own paths, whose scratch
        folders count; owned: folder names copied under the copy's, not as history.
        """
        projects = os.path.join(self.claude_dir, "projects")
        if not os.path.isdir(projects):
            return []
        family = claude_project_key(os.path.join(self.cs_root_real, base.name + "@"))
        # Every other cs session, by its real and its link path: a key is lossy,
        # so wap@foo and a session called wap-foo share a folder name.
        others = set()
        for entry in os.listdir(self.cs_root):
            if entry == base.name or entry.startswith(base.name + "@"):
                continue
            path = os.path.join(self.cs_root, entry)
            others.add(claude_project_key(os.path.realpath(path)))
            others.add(claude_project_key(os.path.join(self.cs_root_real, entry)))
        keys = []
        for key in sorted(os.listdir(projects)):
            if key in owned or not os.path.isdir(os.path.join(projects, key)):
                continue
            scratch = SCRATCH.match(key)
            core = key[scratch.end():] if scratch else key
            if scratch:
                ours = any(re.match(re.escape(main) + SCRATCHPAD, core) for main in mains) or (
                    core.startswith(family) and re.search(SCRATCHPAD, core) is not None)
            else:
                ours = core.startswith(family)
            if ours and not any(core == o or core.startswith(o + "-") for o in others):
                keys.append(key)
        return keys

    def gone_paths(self, base):
        """Where a session whose folder is gone ran: its link's target, and its path in the cs root."""
        target = os.readlink(base.cs_path)
        if not os.path.isabs(target):
            target = os.path.join(os.path.dirname(base.cs_path), target)
        return sorted({os.path.normpath(target), base.source, os.path.join(self.cs_root_real, base.name),
                       base.cs_path})

    def prompt_history(self, base, paths, carried=None):
        """Lines of history.jsonl for the session's paths, under the copy's paths, that the profile lacks.

        With history, lines of the session's retired features come as they
        are, and those carried(project) names. Returns how many lines it
        appends, how many are the session's (the profile may have them), and
        the paste-cache hashes those name.
        """
        src = os.path.join(self.claude_dir, "history.jsonl")
        dst = os.path.join(self.ccs_claude, "history.jsonl")
        text = read_text(src)
        hashes, matched = set(), 0
        if not text:
            return 0, matched, hashes
        family = os.path.join(self.cs_root_real, base.name + "@")
        carried = carried or (lambda project: False)
        have = set((read_text(dst) or "").splitlines())
        out = []
        for line in text.splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            project = record.get("project") if isinstance(record, dict) else None
            if not isinstance(project, str):
                continue
            if project in paths:
                record["project"] = paths[project]
                line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            elif not (self.history and (project.startswith(family) or carried(project))):
                continue
            matched += 1
            pasted = record.get("pastedContents")
            for item in pasted.values() if isinstance(pasted, dict) else ():
                if isinstance(item, dict) and isinstance(item.get("contentHash"), str):
                    hashes.add(item["contentHash"])
            if line not in have:
                have.add(line)
                out.append(line)
        if out and self.apply:
            os.makedirs(self.ccs_claude, exist_ok=True)
            existing = read_text(dst) or ""
            with open(dst, "a") as f:
                f.write(("\n" if existing and not existing.endswith("\n") else "") + "\n".join(out) + "\n")
            self.log("appended-prompt-history", lines=len(out))
        return len(out), matched, hashes

    def say_prompts(self, lines, hashes):
        """The prompt history appended, and the pasted contents its lines name."""
        verb = "appended" if self.apply else "to append"
        if lines:
            self.say("prompt history: %d line(s) %s" % (lines, verb))
        pasted = self.paste_cache(hashes)
        if pasted:
            self.say("pasted contents: %d file(s) of %s %s" % (pasted, tilde(os.path.join(self.claude_dir, "paste-cache")),
                                                               "copied" if self.apply else "to copy"))
        return pasted

    def project_settings(self, paths):
        """Copy each path's settings from ~/.claude.json into the profile's, under the copy's path."""
        stable = json.loads(read_text(self.claude_json) or "{}")
        target = os.path.join(self.ccs_claude, ".claude.json")
        raw = read_text(target)
        profile = json.loads(raw) if raw else {}
        projects = profile.setdefault("projects", {})
        changed = []
        for old, new in sorted(paths.items()):
            entry = (stable.get("projects") or {}).get(old)
            if not isinstance(entry, dict):
                continue
            mine = projects.setdefault(new, {})
            added = [k for k in sorted(entry) if not VOLATILE.match(k) and k not in mine]
            for key in added:
                mine[key] = entry[key]
            if added:
                changed.append(new)
        if changed and self.apply:
            write_atomic(target, (json.dumps(profile, indent=2, ensure_ascii=False) + "\n").encode(),
                         prefix=TMP_PREFIX)
            self.log("merged-claude-project-settings", paths=changed)
        return changed

    def codex_trust(self, paths):
        """Append to the profile's Codex config each path's project table, under the copy's path."""
        stable = (read_text(os.path.join(self.codex_home, "config.toml")) or "").splitlines()
        target = os.path.join(self.profile, ".codex", "config.toml")
        mine = read_text(target)
        if mine is None:
            return []
        added, blocks = [], []
        for old, new in sorted(paths.items()):
            header = '[projects."%s"]' % old
            if header not in stable or ('[projects."%s"]' % new) in mine.splitlines():
                continue
            body = []
            for line in stable[stable.index(header) + 1:]:
                if line.startswith("["):
                    break
                body.append(line)
            while body and not body[-1].strip():
                body.pop()
            blocks.append('[projects."%s"]\n%s\n' % (new, "\n".join(body)))
            added.append(new)
        if blocks and self.apply:
            text = mine if mine.endswith("\n") or not mine else mine + "\n"
            write_atomic(target, (text + "\n" + "\n".join(blocks)).encode(), prefix=TMP_PREFIX)
            self.log("added-codex-trust", paths=added)
        return added

    def secret_envs(self):
        return scrubbed_env(), profile_secrets_env(self.ccs_secrets_dir)

    def secrets(self, session):
        """Names to copy, names code-sessions already has, and any problem reading either."""
        cs_env, ccs_env = self.secret_envs()
        if not os.access(self.cs_secrets, os.X_OK):
            return [], [], "%s is missing; pass --cs-secrets" % tilde(self.cs_secrets)
        try:
            names = secret_names([self.cs_secrets], cs_env, session)
            if not names:
                return [], [], None
            if not os.access(self.ccs_secrets, os.X_OK):
                raise SecretsError("%s is missing; run setup.sh" % tilde(self.ccs_secrets))
            have = set(secret_names([self.ccs_secrets], ccs_env, session))
        except SecretsError as error:
            return [], [], str(error)
        return [n for n in names if n not in have], [n for n in names if n in have], None

    def secret_differs(self, session, name):
        cs_env, ccs_env = self.secret_envs()
        return secret_differs([self.cs_secrets, "--session", session, "get", name], cs_env,
                              [self.ccs_secrets, "--session", session, "get", name], ccs_env)

    def copy_secrets(self, session, names):
        cs_env, ccs_env = self.secret_envs()
        failed = [name for name in names
                  if not copy_secret([self.cs_secrets, "--session", session, "get", name], cs_env,
                                     [self.ccs_secrets, "--session", session, "set", name], ccs_env)]
        if len(failed) < len(names):
            self.log("copied-secrets", session=session, names=[n for n in names if n not in failed])
        return failed

    # --- running ---------------------------------------------------------

    def run(self):
        print("cs sessions: %s   Claude: %s" % (tilde(self.cs_root), tilde(self.claude_dir)))
        print("code-sessions profile: %s" % tilde(self.profile))
        if self.all:
            names, orphans, folders, left = self.scan()
        else:
            names, orphans, folders, left = self.names, [], [], []
        bases = [self.plan_safely(name) for name in names]
        for entry in orphans:
            orphan = Session(self, entry, os.path.join(self.cs_root, entry), kind="orphan")
            orphan.skip = "its base %s is not in cs" % entry.partition("@")[0]
            bases.append(orphan)
        for entry in folders:
            folder = Session(self, entry, os.path.join(self.cs_root, entry))
            folder.source = os.path.realpath(folder.cs_path)
            bases.append(self.plan_folder(folder))
        bases.sort(key=lambda b: b.name)
        self.in_run = {s.name for b in bases for s in [b] + b.features if not s.skip}
        self.settle_nested(bases)
        for base in bases:
            print()
            before = self.problems
            try:
                self.handle(base)
            except OSError as error:
                base.outcome = "%sstopped: %s" % (base.outcome + "; " if base.outcome else "not copied: ", error)
                self.problem("stopped: %s" % error)
            finally:
                if self.apply and not base.skip and base.record is not None and os.path.isdir(base.ccs_path):
                    base.record.save()
            base.problems = self.problems - before
        if left:
            print()
            print("Left out of %s: %s" % (tilde(self.cs_root), ", ".join(left)))
        if self.all:
            self.summary(bases)
        print()
        if not self.apply:
            print("Dry run: nothing changed. Run again with --apply to copy.")
        elif self.failed:
            print("Copied what could be; the items marked ! above were not, or were kept as code-sessions has them.")
        elif self.all:
            print("Done. ccs -list lists the sessions; open one with ccs <name>.")
        else:
            opened = [b.name for b in bases if b.kind == "session"]
            print("Done. Open it with: ccs %s" % " / ccs ".join(opened) if opened else "Done.")
        return 1 if self.failed else 0

    def plan_safely(self, name):
        """plan(), with a record or repository that cannot be read reported as that session's problem."""
        try:
            return self.plan(name)
        except (OSError, ValueError) as error:
            base = Session(self, name, os.path.join(self.cs_root, name))
            base.skip = "could not be read: %s" % error
            return base

    def summary(self, bases):
        print()
        print("Summary%s:" % ("" if self.apply else " of the dry run"))
        for base in bases:
            more = " (%d problem(s), marked ! above)" % base.problems if base.problems and not base.skip else ""
            print("  %s: %s%s" % (base.name, base.outcome or "not reached; see above", more))
            for feature in base.features:
                print("    %s: %s" % (feature.name, feature.outcome or "not reached; see above"))
        if self.problems:
            print("%d problem(s), each marked ! above." % self.problems)
        else:
            print("No problems.")

    def say(self, text, mark=" "):
        print("  %s %s" % (mark, text))

    def problem(self, text):
        self.failed = True
        self.problems += 1
        self.say(text, "!")

    def report_tally(self, what, tally, count):
        verb = "copied" if self.apply else "to copy"
        if tally.pending():
            self.say("%s, %d conversation(s), files %s: %s" % (what, count, verb, ", ".join(merged_parts(tally, "cs"))))
        elif not tally.diverged and not tally.blocked:
            self.say("%s, %d conversation(s): nothing new" % (what, count))
        for line in merged_notes(tally, "cs", "code-sessions", self.apply):
            self.say(line)
        if tally.ahead:
            self.say("%d code-sessions file(s) went on past the cs copy; kept" % tally.ahead)
        for path in tally.diverged:
            self.problem("continued in both cs and code-sessions, left as it is: %s" % tilde(path))
        for path in tally.blocked:
            self.problem("a link or a file in code-sessions where cs has a folder, left as it is: %s" % tilde(path))

    def skip_features(self, base):
        for feature in base.features:
            self.problem("%s: not copied: %s" % (feature.name, feature.skip))
            feature.outcome = "not copied: %s" % feature.skip

    def handle(self, base):
        if base.kind == "gone":
            self.handle_gone(base)
            return
        if base.skip:
            print("%s: not copied" % base.name)
            self.problem(base.skip)
            base.outcome = "not copied: %s" % base.skip
            self.skip_features(base)
            return
        if base.kind == "folder":
            self.handle_folder(base)
            return
        print(base.name)
        if base.open_now:
            self.say("note: open in cs right now: %s. What it writes from here on comes over on a rerun"
                     % ", ".join(base.open_now))
        will = "" if self.apply else "would "
        done = (lambda what: what) if self.apply else (lambda what: "would be " + what)

        # 1. The project and its repository.
        if base.state == "free":
            self.say("%scopy %s to %s%s" % (will, tilde(base.source), tilde(base.ccs_path),
                                            ", with a repository of its own" if base.is_repo
                                            else " (it has no repository)"))
            self.say_nested(base)
            if self.apply:
                rewritten = self.copy_base(base)
            else:
                rewritten = self.rewrites(base).preview(base.nested_paths)
            self.say_venvs(base, rewritten, self.apply)
            self.say_engine(base)
            base.outcome = done("copied")
        else:
            self.say("in code-sessions at %s since an earlier run; bringing over what cs changed since" % tilde(base.ccs_path))
            self.say_nested(base)
            base.outcome = "copied by an earlier run"
            if base.is_repo:
                base.branches = self.syncer.repo(base.name, base.source, base.ccs_physical, base.record)
            self.sync(base, base)
            base.outcome = done("brought up to date")

        # 2. Feature worktrees.
        for feature in base.features:
            if feature.skip:
                self.problem("%s: not copied: %s" % (feature.name, feature.skip))
                feature.outcome = "not copied: %s" % feature.skip
                continue
            if feature.state == "gone":
                self.say("%s: code-sessions removed its copy after an earlier run; not copied again" % feature.name)
                feature.outcome = "not copied again: code-sessions removed its copy after an earlier run"
                continue
            if feature.state == "ours":
                self.say_nested(feature)
                self.sync(base, feature)
                feature.outcome = done("brought up to date")
                continue
            branch = git(feature.source, "branch", "--show-current").stdout.strip()
            if base.state == "ours":
                feature.skip = copy_blocker(feature.source, base.ccs_physical,
                                            due=base.branches.created + base.branches.moved)
                if feature.skip:
                    self.problem("%s: not copied: %s" % (feature.name, feature.skip))
                    feature.outcome = "not copied: %s" % feature.skip
                    continue
            self.say("%s: %scopy it to %s, a worktree of code-sessions's %s on %s"
                     % (feature.name, will, tilde(feature.ccs_path), base.name, branch or "a detached HEAD"))
            self.say_nested(feature)
            feature.outcome = done("copied")
            if self.apply:
                try:
                    rewritten = self.copy_feature(base, feature)
                except OSError as error:
                    feature.failed = True
                    feature.outcome = "not copied: stopped: %s" % error
                    self.problem("%s: stopped: %s" % (feature.name, error))
                    continue
            else:
                rewritten = self.rewrites(feature).preview(feature.nested_paths)
            self.say_venvs(feature, rewritten, self.apply)
            self.say_engine(feature)
        for name in base.gone_in_cs:
            self.say("%s: cs no longer has it; code-sessions keeps its copy" % name)
        sessions = [base] + [f for f in base.features if not f.skip and not f.failed and f.state != "gone"]

        # 3. Claude conversations, under the folder name of each copy's path.
        paths = {s.source: s.ccs_physical for s in sessions}
        for session in sessions:
            tally, count = self.conversations(claude_project_key(session.source),
                                              claude_project_key(session.ccs_physical), base.record)
            self.report_tally("Claude history of %s" % session.name, tally, count)
        # The conversation the copy has once this run is done: a dry run's sync says what it would merge.
        if not self.apply and base.synced is not None and base.synced.state_after is not None:
            claude_id = parse_state(base.synced.state_after).get("claude_session_id", "")
        else:
            copied = self.apply or base.state == "ours"
            claude_id = state_value(os.path.join(base.ccs_path if copied else base.source, ".cs"), "claude_session_id")
        transcripts = (os.path.join(self.ccs_claude, "projects", claude_project_key(base.ccs_physical)),
                       os.path.join(self.claude_dir, "projects", claude_project_key(base.source)))
        if claude_id and any(os.path.isfile(os.path.join(t, claude_id + ".jsonl")) for t in transcripts):
            self.say("ccs %s resumes conversation %s" % (base.name, claude_id))
        for session in sessions:
            tally = merge_tree(os.path.join(self.claude_dir, "tasks", session.name),
                               os.path.join(self.ccs_claude, "tasks", session.name), self.apply, TMP_SUFFIX,
                               record=base.record)
            if tally.pending():
                self.say("task list of %s: %d file(s) %s"
                         % (session.name, tally.pending(), "copied" if self.apply else "to copy"))
        if self.history:
            main = claude_project_key(base.source)
            owned = {main} | {claude_project_key(f.source) for f in base.features if f.source}
            keys = self.history_keys(base, [main], owned)
            total, conversations = Tally(), 0
            for key in keys:
                tally, count = self.conversations(key, key, base.record)
                conversations += count
                total.add(tally)
            if keys:
                self.report_tally("history of %d retired feature and scratch folder(s), no session"
                                  % len(keys), total, conversations)
        lines, _, hashes = self.prompt_history(base, paths)
        self.say_prompts(lines, hashes)

        # 3b. Codex threads the sessions bind, for ccs <name> --engine codex.
        self.codex_threads(sessions, base.record)

        # 4. Trust and per-project settings, which a running code-sessions may rewrite under us.
        running = self.ccs_running()
        if running:
            self.say("note: a code-sessions session is running (%s), so .claude.json and the Codex config are left; "
                     "rerun once none is open" % running[0][:80])
        else:
            changed = self.project_settings(paths)
            if changed:
                self.say("Claude project settings %s for %s" % ("merged" if self.apply else "to merge",
                                                                 ", ".join(tilde(p) for p in changed)))
            added = self.codex_trust(paths)
            if added:
                self.say("Codex trust %s for %s" % ("added" if self.apply else "to add",
                                                    ", ".join(tilde(p) for p in added)))

        # 5. Secrets. A feature's go through its base, but one may hold its own.
        for session in sessions:
            missing, present, error = self.secrets(session.name)
            if error:
                self.problem("secrets of %s: %s" % (session.name, error))
            differs = [n for n in present if self.secret_differs(session.name, n)]
            if present and len(differs) < len(present):
                self.say("secrets of %s code-sessions already has: %s" % (session.name, ", ".join(
                    n for n in present if n not in differs)))
            for name in differs:
                self.problem("secret %s of %s differs between cs and code-sessions; code-sessions's is kept" % (name, session.name))
            if missing:
                self.say("secrets of %s %s: %s" % (session.name, "copied" if self.apply else "to copy",
                                                    ", ".join(missing)))
                if self.apply:
                    for name in self.copy_secrets(session.name, missing):
                        self.problem("secret %s of %s was not copied" % (name, session.name))
        if self.apply:
            self.say("cs keeps %s as it was. Rerun to bring over what cs does from here on; to go back to cs, "
                     "run scripts/code-sessions-to-cs.py --session %s" % (base.name, base.name))

    def handle_gone(self, base):
        """A session whose folder is gone: nothing to copy but its Claude history, under the same names.

        cs cannot open it either, so it is a note, not a problem.
        """
        print("%s: not copied" % base.name)
        self.say("note: %s, so cs cannot open it either" % base.skip)
        self.skip_features(base)
        if not self.history:
            base.outcome = "not copied: its folder is gone (its history left out: --no-history)"
            return
        places = self.gone_paths(base)
        mains = [claude_project_key(p) for p in places]
        projects = os.path.join(self.claude_dir, "projects")
        keys = sorted({k for k in mains if os.path.isdir(os.path.join(projects, k))}
                      | set(self.history_keys(base, mains, set(mains))))
        total, conversations = Tally(), 0
        for key in keys:
            tally, count = self.conversations(key, key)
            conversations += count
            total.add(tally)
        if keys:
            self.report_tally("its Claude history, as history under the same folder name(s)", total, conversations)
        under = lambda project: any(project == p or project.startswith(p + os.sep) for p in places)
        lines, matched, hashes = self.prompt_history(base, {}, under)
        pasted = self.say_prompts(lines, hashes)
        if not (keys or matched):
            base.outcome = "not copied: its folder is gone (it left no history)"
        elif not self.apply and (total.pending() or lines or pasted):
            base.outcome = "not copied: its folder is gone (history would be carried)"
        else:
            base.outcome = "not copied: its folder is gone (history carried)"

    def handle_folder(self, base):
        """A folder that is no session: its files merged in, new and grown ones only."""
        print("%s (a folder, not a session)" % base.name)
        if base.state == "free":
            self.say("%scopy %s to %s, file by file" % ("" if self.apply else "would ", tilde(base.source),
                                                         tilde(base.ccs_path)))
            if self.apply:
                os.makedirs(base.ccs_path)
                shutil.copystat(base.source, base.ccs_path)
        tally = merge_tree(base.source, base.ccs_path, self.apply, TMP_SUFFIX)
        if tally.pending():
            parts = (["%d new" % tally.new] if tally.new else []) + (["%d grown" % tally.grown] if tally.grown else [])
            self.say("files %s: %s" % ("copied" if self.apply else "to copy", ", ".join(parts)))
            self.log("merged-folder", name=base.name, source=base.source, path=base.ccs_path,
                     new=tally.new, grown=tally.grown)
        elif not tally.diverged and not tally.blocked:
            self.say("files: nothing new in cs")
        if tally.ahead:
            self.say("%d file(s) code-sessions went on with past cs's; kept" % tally.ahead)
        # Without a record of the last copy, a file that differs inside is
        # either side's rewrite: code-sessions's stays, and is named.
        if tally.diverged:
            self.say("%d file(s) differ from cs's; code-sessions's kept: %s"
                     % (len(tally.diverged), shown([tilde(p) for p in tally.diverged])))
        for path in tally.blocked:
            self.problem("a link or a file in code-sessions where cs has a folder, left as it is: %s" % tilde(path))
        done = "copied" if base.state == "free" else "brought up to date"
        base.outcome = "%s (a folder, not a session)" % (done if self.apply else "would be " + done)
        self.skip_features(base)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Give code-sessions its own copy of cs sessions, with their feature worktrees, Claude history and "
                    "secrets; a rerun brings over what cs changed since.",
        epilog="Prints what it would do unless --apply is given. Nothing outside the code-sessions profile is written. "
               "--all also copies the folders in the cs root that are no session, and its .voice/, file by file; "
               "it leaves .usage/, .spawn/ and index.md, and names them.")
    parser.add_argument("--session", action="append", metavar="NAME",
                        help="the cs session to copy (repeatable); its features come with it")
    parser.add_argument("--all", action="store_true",
                        help="every session in the cs root, each with its features, one after another")
    parser.add_argument("--apply", action="store_true", help="copy; without it nothing is written")
    parser.add_argument("--no-history", action="store_true",
                        help="leave out the conversations of retired features, scratch folders and sessions "
                             "whose folder is gone")
    parser.add_argument("--profile", default="~/.local/share/code-sessions/home",
                        help="the code-sessions profile (default: %(default)s)")
    parser.add_argument("--cs-root", default="~/.claude-sessions",
                        help="the stable cs sessions root (default: %(default)s)")
    parser.add_argument("--claude-dir", default="~/.claude",
                        help="the Claude config dir the stable cs runs Claude Code on (default: %(default)s)")
    parser.add_argument("--claude-json", default="~/.claude.json",
                        help="Claude Code's state file beside it (default: %(default)s)")
    parser.add_argument("--codex-home", default="~/.codex",
                        help="the Codex home outside code-sessions (default: %(default)s)")
    parser.add_argument("--cs-secrets", default="~/.local/bin/cs-secrets",
                        help="the stable cs secrets command (default: %(default)s)")
    args = parser.parse_args(argv)
    if args.all and args.session:
        parser.error("--all takes every session; leave out --session")
    if not args.all and not args.session:
        parser.error("name a session with --session NAME, or take every one with --all")
    for name in args.session or []:
        if "@" in name or "/" in name or name.startswith("."):
            parser.error("--session %s: name a base session; its feature worktrees come with it" % name)
    return Importer(args).run()


if __name__ == "__main__":
    sys.exit(main())
