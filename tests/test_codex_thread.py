#!/usr/bin/env python3
# ABOUTME: Exercises Codex bootstrap protocol, exact identity, persistence, and cleanup.
# ABOUTME: Uses an isolated fake server and an optional real Codex no-model smoke test.

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "bin/cs-codex-thread"
THREAD_ID = "01900000-0000-7000-8000-000000000001"
OTHER_ID = "01900000-0000-7000-8000-000000000002"
FAKE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
mode = os.environ.get('FAKE_MODE', '')
count_file = root / 'count'
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
with (root / 'pids').open('a') as f: f.write(str(os.getpid()) + '\n')
if mode == 'stderr':
    os.write(2, b'private stderr value\x1b[2J\n' * 20000)
if mode == 'stubborn':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in sys.stdin:
    request = json.loads(line)
    with (root / 'requests').open('a') as f:
        f.write(json.dumps({'process': count, 'cwd': os.getcwd(), 'request': request}) + '\n')
    method = request['method']
    if 'id' not in request: continue
    rid = request['id']
    def reply(value):
        print(json.dumps(dict(value, id=rid)), flush=True)
    if mode in ('timeout', 'stubborn'):
        time.sleep(60)
    if mode == 'eof': sys.exit(3)
    if mode == 'oversize':
        os.write(1, b'x' * (5 * 1024 * 1024)); time.sleep(60)
    if mode == 'server_request':
        print(json.dumps({'id': rid, 'method':'approval/request', 'params':{}}), flush=True)
        continue
    if mode == 'noise':
        print('not JSON startup output')
        print('[]')
        print(json.dumps({'method':'thread/started', 'params':{'thread':{'id':'wrong'}}}))
        print(json.dumps({'id':'unrelated', 'result':{'thread':{'id':'wrong'}}}))
    if mode == 'init_error' and method == 'initialize':
        reply({'error':{'code':-32600,'message':'private token secret\u001b[2J'}});continue
    if mode == 'active_writer' and method == 'thread/resume':
        reply({'error':{'code':-32600,'message':'private thread ID already has an active writer'}});continue
    if mode == 'inject_error' and method == 'thread/inject_items':
        reply({'error':{'code':-32601,'message':'unknown method'}});continue
    if mode == 'verify_error' and count == 2 and method == 'thread/resume':
        reply({'error':{'code':-32600,'message':'no rollout found'}});continue
    if mode == 'invalid_result':
        reply({'result':[]});continue
    if method == 'thread/turns/list':
        reply({'result':{'data':json.loads(os.environ.get('FAKE_TURNS', '[]')),'nextCursor':None}});continue
    if method == 'config/read':
        reply({'result':json.loads(os.environ.get('FAKE_CONFIG', '{}'))});continue
    if method in ('thread/start','thread/resume'):
        tid = '01900000-0000-7000-8000-000000000001'
        if mode == 'mismatch' and method == 'thread/resume':
            tid = '01900000-0000-7000-8000-000000000002'
        if mode == 'bad_id': tid = 'malicious\n--last'
        thread = {'id':tid,'ephemeral':mode == 'ephemeral'}
        if mode == 'large_history' and method == 'thread/resume':
            # Real resume responses include history unless explicitly excluded.
            thread['turns'] = [] if request['params'].get('excludeTurns') is True else [
                {'id':'large-turn','status':'completed','items':[
                    {'type':'agentMessage','id':'large-message','text':'x' * (5 * 1024 * 1024)}]}]
        reply({'result':{'thread':thread}})
        if mode == 'write_timeout': time.sleep(60)
    else: reply({'result':{}})
if mode == 'cleanup':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
'''


class HelperFixture(unittest.TestCase):
    """An isolated fake app-server and the helper command line around it."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cs-codex-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "project spaces 'quotes' $(touch UNEXPECTED) ;"
        self.cwd.mkdir()
        self.instructions = self.root / "context ' quoted.txt"
        self.instructions.write_text('CS context\n"quoted" \\ backslash ✓', encoding="utf-8")
        self.fake = self.root / "fake codex"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.env = dict(os.environ, FAKE_ROOT=str(self.root))

    def command(self, *extra):
        return [sys.executable, str(HELPER), '--codex-bin', str(self.fake),
                '--cwd', str(self.cwd), '--instructions-file', str(self.instructions),
                '--timeout', '5', *extra]

    def run_helper(self, mode='', *extra):
        result = subprocess.run(self.command(*extra), env=dict(self.env, FAKE_MODE=mode),
                                capture_output=True, text=True, timeout=10)
        self.assert_cleaned_up()
        return result

    def assert_cleaned_up(self):
        path = self.root / 'pids'
        if path.exists():
            for pid in path.read_text().splitlines():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid), 0)

    def requests(self):
        path = self.root / 'requests'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_failure(self, mode, text, *extra):
        result = self.run_helper(mode, *extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn(text, result.stderr)
        return result


class BootstrapTests(HelperFixture):
    def test_new_thread_persists_in_fresh_process_and_preserves_context(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        self.assertEqual(result.stderr, '')
        requests = self.requests()
        self.assertEqual([r['request']['method'] for r in requests], [
            'initialize', 'initialized', 'thread/start', 'thread/inject_items',
            'thread/unsubscribe', 'initialize', 'initialized', 'thread/resume', 'thread/unsubscribe'])
        self.assertEqual({r['process'] for r in requests}, {1, 2})
        for record in requests:
            self.assertEqual(Path(record['cwd']).resolve(), self.cwd.resolve())
            params = record['request'].get('params', {})
            self.assertNotIn('developerInstructions', params)
            self.assertNotIn('config', params)
        start = requests[2]['request']['params']
        self.assertEqual(start, {'cwd': str(self.cwd.resolve()), 'ephemeral': False})
        injection = requests[3]['request']['params']
        self.assertEqual(injection['threadId'], THREAD_ID)
        self.assertEqual(injection['items'], [{'type': 'message', 'role': 'developer',
                          'content': [{'type': 'input_text', 'text': self.instructions.read_text()}]}])
        self.assertFalse((self.cwd / 'UNEXPECTED').exists())

    def test_existing_thread_refresh_does_not_create_or_inject_twice(self):
        result = self.run_helper('', '--thread-id', THREAD_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        methods = [r['request']['method'] for r in self.requests()]
        self.assertNotIn('thread/start', methods)
        self.assertEqual(methods.count('thread/resume'), 2)
        self.assertEqual(methods.count('thread/inject_items'), 1)

    def test_noise_and_wrong_ids_cannot_supply_thread_identity(self):
        result = self.run_helper('noise')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')

    def test_large_history_resumes_and_verifies_without_fetching_turns(self):
        result = self.run_helper('large_history', '--thread-id', THREAD_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        requests = self.requests()
        resumes = [r for r in requests if r['request']['method'] == 'thread/resume']
        self.assertEqual([r['process'] for r in resumes], [1, 2])
        self.assertEqual(sum(r['request']['method'] == 'thread/inject_items' for r in requests), 1)
        self.assertNotIn('thread/start', [r['request']['method'] for r in requests])

    def test_large_private_stderr_does_not_block_or_leak(self):
        result = self.run_helper('stderr')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_rpc_error_redacts_server_message(self):
        result = self.assert_failure('init_error', 'rejected initialize (code -32600)')
        self.assertNotIn('secret', result.stderr)
        self.assertNotIn('\x1b', result.stderr)

    def test_active_writer_has_actionable_redacted_error(self):
        result = self.assert_failure('active_writer', 'close the existing Codex CLI or desktop session',
                                     '--thread-id', THREAD_ID)
        self.assertNotIn('private thread ID', result.stderr)
        self.assertNotIn('thread/start', [r['request']['method'] for r in self.requests()])

    def test_unsupported_injection_is_actionable(self):
        self.assert_failure('inject_error', 'experimental API support')

    def test_failed_persistence_never_returns_id(self):
        self.assert_failure('verify_error', 'rejected thread/resume')

    def test_changed_identity_never_falls_back(self):
        self.assert_failure('mismatch', 'different thread', '--thread-id', THREAD_ID)
        self.assertNotIn('thread/start', [r['request']['method'] for r in self.requests()])

    def test_malformed_id_is_rejected(self):
        self.assert_failure('bad_id', 'exact thread ID')

    def test_ephemeral_thread_is_rejected(self):
        self.assert_failure('ephemeral', 'ephemeral thread')

    def test_invalid_result_is_rejected(self):
        self.assert_failure('invalid_result', 'invalid initialize response')

    def test_server_interactions_are_not_approved(self):
        self.assert_failure('server_request', 'unsupported interaction')

    def test_early_exit(self):
        # The server's own output stays private; its exit status is not.
        self.assert_failure('eof', 'exited before completing bootstrap (exit status 3)')

    def test_missing_codex_home_is_named_without_launching(self):
        missing = self.root / 'no such home'
        result = subprocess.run(self.command(), env=dict(self.env, CODEX_HOME=str(missing)),
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('CODEX_HOME points to ' + str(missing), result.stderr)
        self.assertFalse((self.root / 'count').exists(), 'the server must not start')

    def test_response_timeout_is_bounded_and_process_reaped(self):
        started = time.monotonic()
        self.assert_failure('timeout', 'timed out', '--timeout', '0.15')
        self.assertLess(time.monotonic() - started, 4)

    def test_blocked_stdin_does_not_defeat_timeout(self):
        self.instructions.write_text('x' * 200000)
        self.assert_failure('write_timeout', 'timed out', '--timeout', '0.15')

    def test_oversized_output_is_bounded(self):
        self.assert_failure('oversize', 'protocol limit')

    def test_sigterm_ignoring_server_is_killed(self):
        self.assert_failure('stubborn', 'timed out', '--timeout', '0.15')

    def test_cleanup_after_success_can_kill_a_stubborn_server(self):
        result = self.run_helper('cleanup')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interrupt_cleans_up_server(self):
        process = subprocess.Popen(self.command(), env=dict(self.env, FAKE_MODE='timeout'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / 'pids').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / 'pids').exists())
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
            self.assertEqual(stdout, '')
            self.assertIn('interrupted', stderr)
            self.assert_cleaned_up()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def latest_turn(self, turns=(), mode='', *extra):
        command = [sys.executable, str(HELPER), '--codex-bin', str(self.fake), '--cwd', str(self.cwd),
                   '--timeout', '5', '--latest-turn', *(extra or ('--thread-id', THREAD_ID))]
        result = subprocess.run(command, env=dict(self.env, FAKE_MODE=mode, FAKE_TURNS=json.dumps(list(turns))),
                                capture_output=True, text=True, timeout=10)
        self.assert_cleaned_up()
        return result

    def test_latest_turn_reads_the_history_and_changes_nothing(self):
        result = self.latest_turn()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '\n', 'a thread no turn started in prints an empty line')
        result = self.latest_turn([{'id': '01a139d6-0c65-7111-a45d-c97f4d0488eb', 'status': 'interrupted'}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '01a139d6-0c65-7111-a45d-c97f4d0488eb\n')
        requests = self.requests()
        self.assertEqual([r['request']['method'] for r in requests],
                         ['initialize', 'initialized', 'thread/turns/list'] * 2)
        self.assertEqual(requests[2]['request']['params'], {
            'threadId': THREAD_ID, 'limit': 1, 'sortDirection': 'desc', 'itemsView': 'notLoaded'})

    def test_latest_turn_rejects_what_is_not_a_turn(self):
        for turns in ([{'id': 'turn\n--last'}], [{'status': 'completed'}], ['turn-1']):
            result = self.latest_turn(turns)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('exact turn ID', result.stderr)
        result = self.latest_turn((), 'invalid_result')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def project_config(self, config, mode=''):
        command = [sys.executable, str(HELPER), '--codex-bin', str(self.fake), '--cwd', str(self.cwd),
                   '--timeout', '5', '--project-config']
        result = subprocess.run(command, env=dict(self.env, FAKE_MODE=mode, FAKE_CONFIG=json.dumps(config)),
                                capture_output=True, text=True, timeout=10)
        self.assert_cleaned_up()
        return result

    def test_project_config_names_only_what_a_project_layer_sets(self):
        folder = str(self.root / 'repo' / '.codex')
        result = self.project_config({
            'config': {'model': 'gpt-project', 'model_reasoning_effort': 'high'},
            'origins': {
                'model': {'name': {'type': 'project', 'dotCodexFolder': folder}, 'version': 'sha256:a'},
                'model_reasoning_effort': {'name': {'type': 'user', 'file': '/home/config.toml'},
                                           'version': 'sha256:b'}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         {'model': {'value': 'gpt-project', 'file': folder + '/config.toml'}})
        requests = self.requests()
        self.assertEqual([r['request']['method'] for r in requests], ['initialize', 'initialized', 'config/read'])
        self.assertEqual(requests[2]['request']['params'], {'cwd': str(self.cwd.resolve()), 'includeLayers': False})
        result = self.project_config({'config': {'model': 'gpt-user'},
                                      'origins': {'model': {'name': {'type': 'user', 'file': '/c'}}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})

    def test_project_config_rejects_a_malformed_answer(self):
        for config in ({'config': {}}, {'config': [], 'origins': {}}):
            result = self.project_config(config)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            self.assertIn('config/read', result.stderr)
        result = self.project_config({}, 'invalid_result')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_latest_turn_needs_a_thread_and_no_instructions(self):
        result = self.latest_turn((), '', '--instructions-file', str(self.instructions))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--latest-turn needs --thread-id', result.stderr)
        self.assertFalse((self.root / 'pids').exists())

    def test_bad_arguments_and_empty_inputs_do_not_launch_server(self):
        for extra in [('--thread-id', '--last'), ('--timeout', 'nan'), ('--timeout', '0')]:
            result = self.run_helper('', *extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
        self.instructions.write_text('')
        self.assert_failure('', 'must not be empty')
        self.assertFalse((self.root / 'pids').exists())

    @unittest.skipUnless(os.environ.get('CS_CODEX_REAL_BIN'), 'set CS_CODEX_REAL_BIN for no-model smoke test')
    def test_real_codex_persists_context_without_a_model_turn(self):
        home = self.root / 'isolated-codex-home'
        home.mkdir()
        (home / 'config.toml').write_text(
            'model = "gpt-5.5"\ndeveloper_instructions = "USER_CONFIGURATION_MARKER"\n'
            '[analytics]\nenabled = false\n')
        env = dict(os.environ, CODEX_HOME=str(home))
        command = [sys.executable, str(HELPER), '--codex-bin', os.environ['CS_CODEX_REAL_BIN'],
                   '--cwd', str(self.cwd), '--instructions-file', str(self.instructions)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stderr)
        thread_id = result.stdout.strip()
        self.assertRegex(thread_id, r'^[a-f0-9-]{36}$')
        rollouts = list(home.glob('sessions/**/*.jsonl'))
        self.assertEqual(len(rollouts), 1)
        contents = [json.loads(line) for line in rollouts[0].read_text().splitlines()]
        self.assertEqual(contents[0]['payload']['id'], thread_id)
        developer_text = '\n'.join(c.get('text', '') for item in contents
                                  if item.get('payload', {}).get('role') == 'developer'
                                  for c in item['payload'].get('content', []))
        self.assertIn('USER_CONFIGURATION_MARKER', developer_text)
        self.assertIn(self.instructions.read_text(), developer_text)
        self.assertFalse(any(item.get('payload', {}).get('type') == 'task_started' for item in contents))
        self.instructions.write_text('CS refreshed context marker')
        refresh = subprocess.run(command + ['--thread-id', thread_id], env=env,
                                 capture_output=True, text=True, timeout=40)
        self.assertEqual(refresh.returncode, 0, refresh.stderr)
        self.assertEqual(refresh.stdout, thread_id + '\n')
        self.assertIn('CS refreshed context marker', rollouts[0].read_text())
        turns = subprocess.run(command[:6] + ['--thread-id', thread_id, '--latest-turn'], env=env,
                               capture_output=True, text=True, timeout=40)
        self.assertEqual(turns.returncode, 0, turns.stderr)
        self.assertEqual(turns.stdout, '\n', 'context alone starts no turn')

    @unittest.skipUnless(os.environ.get('CS_CODEX_REAL_BIN'), 'set CS_CODEX_REAL_BIN for no-model smoke test')
    def test_real_codex_names_a_trusted_project_model(self):
        # A trusted project's config outranks a --profile; an untrusted one is not read.
        home = self.root / 'isolated-codex-home'
        home.mkdir()
        project = self.root / 'trusted project'
        (project / '.codex').mkdir(parents=True)
        (project / '.codex' / 'config.toml').write_text('model = "gpt-project"\n')
        user = 'model = "gpt-user"\nmodel_reasoning_effort = "high"\n[analytics]\nenabled = false\n'
        trust = '[projects."{}"]\ntrust_level = "trusted"\n'.format(project.resolve())
        env = dict(os.environ, CODEX_HOME=str(home))
        command = [sys.executable, str(HELPER), '--codex-bin', os.environ['CS_CODEX_REAL_BIN'],
                   '--cwd', str(project), '--project-config']
        for config, expected in ((user + trust, {'model': {
                'value': 'gpt-project', 'file': str(project.resolve() / '.codex' / 'config.toml')}}), (user, {})):
            (home / 'config.toml').write_text(config)
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), expected)


CLAUDE_ID = "a0000000-0000-4000-8000-00000000000a"
NEW_CLAUDE_ID = "b0000000-0000-4000-8000-00000000000b"


def rollout_line(kind, payload, stamp="2026-11-06T16:49:50.000Z"):
    return json.dumps({"timestamp": stamp, "type": kind, "payload": payload})


def codex_message(role, text, kind=None):
    kind = kind or ("output_text" if role == "assistant" else "input_text")
    return {"type": "message", "role": role, "content": [{"type": kind, "text": text}]}


def claude_record(kind, content, uid, parent, **extra):
    record = {"type": kind, "uuid": uid, "parentUuid": parent, "sessionId": CLAUDE_ID,
              "timestamp": "2026-11-07T10:00:00.000Z",
              "message": {"role": kind, "content": content}}
    record.update(extra)
    return json.dumps(record)


class TransplantTests(HelperFixture):
    """A conversation carried across engines: a Codex thread out as a Claude
    transcript, a Claude transcript into a new thread."""

    def setUp(self):
        super().setUp()
        self.codex_home = self.root / "codex home"
        self.codex_home.mkdir()
        self.env["CODEX_HOME"] = str(self.codex_home)

    def write_rollout(self, lines, thread=THREAD_ID):
        folder = self.codex_home / "sessions" / "2026" / "11" / "06"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / ("rollout-2026-11-06T18-49-45-" + thread + ".jsonl")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def export(self, *extra):
        out = self.root / "carried.jsonl"
        command = [sys.executable, str(HELPER), "--export-claude", "--thread-id", THREAD_ID,
                   "--session-id", NEW_CLAUDE_ID, "--cwd", str(self.cwd), "--out", str(out),
                   "--claude-version", "2.1.300", "--git-branch", "cs/x", *extra]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=10)
        records = [json.loads(line) for line in out.read_text().splitlines()] if out.exists() else []
        return result, records

    @staticmethod
    def text_of(record):
        content = record["message"]["content"]
        return content if isinstance(content, str) else content[0]["text"]

    def sample_rollout(self):
        return [
            rollout_line("session_meta", {"id": THREAD_ID, "cwd": "/x"}),
            rollout_line("response_item", codex_message("developer", "SECRET DEVELOPER TEXT")),
            rollout_line("response_item", {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "# AGENTS.md instructions for /x\n\n<INSTRUCTIONS>AGENTS</INSTRUCTIONS>"},
                {"type": "input_text", "text": "<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"}]}),
            rollout_line("response_item", codex_message("user", "what is the codename?")),
            rollout_line("response_item", {"type": "reasoning", "summary": [],
                                           "encrypted_content": "ENCRYPTED REASONING"}),
            rollout_line("response_item", codex_message("assistant", "Checking the notes.")),
            rollout_line("response_item", {"type": "custom_tool_call", "name": "exec", "call_id": "c1",
                                           "input": "cat notes.txt"}),
            rollout_line("response_item", {"type": "custom_tool_call_output", "call_id": "c1",
                                           "output": [{"type": "input_text", "text": "AMBER-FALCON " + "x" * 5000}]}),
            rollout_line("response_item", {"type": "function_call", "name": "shell", "call_id": "c2",
                                           "arguments": "{\"cmd\": \"ls\"}"}),
            rollout_line("response_item", {"type": "function_call_output", "call_id": "c2", "output": "notes.txt"}),
            "not json at all",
            rollout_line("response_item", {"type": "some_future_item", "text": "FUTURE ITEM"}),
            rollout_line("event_msg", {"type": "agent_message", "message": "EVENT DUPLICATE"}),
            rollout_line("response_item", codex_message("assistant", "The codename is AMBER-FALCON.")),
            rollout_line("response_item", codex_message("user", "$wrap")),
            rollout_line("response_item", codex_message("user", "<skill>\n<name>wrap</name>\nBODY\n</skill>")),
            rollout_line("response_item", codex_message("assistant", "Wrapped.")),
        ]

    def test_thread_exports_as_a_resumable_claude_transcript(self):
        self.write_rollout(self.sample_rollout())
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        stats = json.loads(result.stdout)
        self.assertEqual(stats["messages"], 4)
        self.assertEqual([r["type"] for r in records], ["user", "assistant", "user", "assistant"])
        # One chain, every record naming the new conversation and this folder.
        self.assertIsNone(records[0]["parentUuid"])
        for before, after in zip(records, records[1:]):
            self.assertEqual(after["parentUuid"], before["uuid"])
        for record in records:
            self.assertEqual(record["sessionId"], NEW_CLAUDE_ID)
            self.assertEqual(record["cwd"], str(self.cwd.resolve()))
            self.assertEqual(record["version"], "2.1.300")
            self.assertEqual(record["gitBranch"], "cs/x")
            self.assertFalse(record["isSidechain"])
        for record in records[1::2]:
            self.assertEqual(record["message"]["model"], "<synthetic>")
            self.assertEqual(record["message"]["stop_reason"], "end_turn")
            self.assertTrue(record["requestId"])
        first = self.text_of(records[0])
        self.assertTrue(first.startswith("[cs carried this conversation over from Codex thread " + THREAD_ID))
        self.assertIn("4,000 characters", first)
        self.assertTrue(first.endswith("what is the codename?"))
        agent = self.text_of(records[1])
        self.assertIn("Checking the notes.", agent)
        self.assertIn("[tool call: exec]\ncat notes.txt", agent)
        self.assertIn("[tool result]\nAMBER-FALCON " + "x" * (4000 - len("AMBER-FALCON ")), agent)
        self.assertIn("[cs cut the remaining 1,013 characters]", agent)
        self.assertIn('[tool call: shell]\n{"cmd": "ls"}', agent)
        self.assertIn("[tool result]\nnotes.txt", agent)
        self.assertIn("The codename is AMBER-FALCON.", agent)
        self.assertEqual(self.text_of(records[2]), "$wrap")
        whole = json.dumps(records)
        for absent in ("SECRET DEVELOPER TEXT", "ENCRYPTED REASONING", "AGENTS.md", "environment_context",
                       "FUTURE ITEM", "EVENT DUPLICATE", "<skill>"):
            self.assertNotIn(absent, whole)
        self.assertEqual(os.stat(self.root / "carried.jsonl").st_mode & 0o777, 0o600)
        self.assertEqual([p.name for p in self.root.iterdir() if p.name.startswith(".carried")], [])

    def test_compaction_keeps_only_what_codex_kept(self):
        lines = self.sample_rollout()[:7] + [
            rollout_line("compacted", {"message": "", "replacement_history": [
                codex_message("user", "<environment_context>\n</environment_context>"),
                codex_message("user", "summary: the codename question was answered"),
                {"type": "reasoning", "encrypted_content": "X"},
                codex_message("assistant", "Kept answer.")]}),
            rollout_line("response_item", codex_message("user", "after compaction")),
        ]
        self.write_rollout(lines)
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        texts = [self.text_of(r) for r in records]
        self.assertEqual(len(texts), 3)
        self.assertTrue(texts[0].endswith("summary: the codename question was answered"))
        self.assertEqual(texts[1], "Kept answer.")
        self.assertEqual(texts[2], "after compaction")
        self.assertNotIn("Checking the notes.", json.dumps(records))

    def test_summary_only_compaction_starts_from_the_summary(self):
        self.write_rollout(self.sample_rollout()[:7] + [
            rollout_line("compacted", {"message": "Earlier: codename work."}),
            rollout_line("response_item", codex_message("assistant", "Next step."))])
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["type"] for r in records], ["user", "assistant"])
        self.assertIn("[Summary of the earlier conversation]\nEarlier: codename work.", self.text_of(records[0]))

    def test_a_thread_that_starts_with_the_agent_gets_a_user_note_first(self):
        self.write_rollout([rollout_line("response_item", codex_message("assistant", "Hello."))])
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["type"] for r in records], ["user", "assistant"])
        self.assertTrue(self.text_of(records[0]).startswith("[cs carried"))

    def test_clip_is_adjustable(self):
        self.write_rollout(self.sample_rollout())
        result, records = self.export("--clip", "5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[tool result]\nAMBER\n[cs cut the remaining", self.text_of(records[1]))
        self.assertIn("first 5 characters", self.text_of(records[0]))

    def test_a_thread_with_nothing_to_carry_writes_nothing(self):
        self.write_rollout(self.sample_rollout()[:3])
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"messages": 0, "characters": 0})
        self.assertEqual(records, [])

    def test_a_thread_without_saved_history_is_named(self):
        result, records = self.export()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("no saved history for thread " + THREAD_ID, result.stderr)
        self.assertEqual(records, [])

    def test_archived_and_newest_rollouts_are_found(self):
        old = self.write_rollout([rollout_line("response_item", codex_message("user", "old copy"))])
        archived = self.codex_home / "archived_sessions"
        archived.mkdir()
        newer = archived / old.name
        newer.write_text(rollout_line("response_item", codex_message("user", "archived copy")) + "\n")
        os.utime(old, (1, 1))
        result, records = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.text_of(records[0]).endswith("archived copy"))

    def test_export_arguments_are_checked(self):
        base = [sys.executable, str(HELPER), "--export-claude", "--thread-id", THREAD_ID,
                "--cwd", str(self.cwd), "--out", str(self.root / "o.jsonl")]
        for extra in ([], ["--session-id", "not-a-uuid"]):
            result = subprocess.run(base + extra, env=self.env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--session-id", result.stderr)

    def sample_transcript(self):
        path = self.root / (CLAUDE_ID + ".jsonl")
        lines = [
            json.dumps({"type": "custom-title", "customTitle": "x", "sessionId": CLAUDE_ID}),
            claude_record("user", "OLD BRANCH PROMPT", "u0", None),
            claude_record("user", "<command-name>/color</command-name>\n<command-args>blue</command-args>",
                          "u1", None),
            claude_record("user", "<local-command-stdout>Session color set</local-command-stdout>", "u2", "u1"),
            claude_record("user", "Caveat: generated by local commands", "u3", "u2", isMeta=True),
            claude_record("user", "find the budget<system-reminder>REMINDER TEXT</system-reminder>", "u4", "u3"),
            json.dumps({"type": "attachment", "uuid": "a1", "parentUuid": "u4", "attachment": {"text": "HOOK CONTEXT"}}),
            claude_record("assistant", [
                {"type": "thinking", "thinking": "SECRET THINKING", "signature": "sig"},
                {"type": "text", "text": "Reading notes."},
                {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "notes.txt"}}],
                "x1", "a1"),
            claude_record("assistant", "SIDECHAIN WORK", "s1", "x1", isSidechain=True),
            claude_record("user", [{"type": "tool_result", "tool_use_id": "t1", "content": [
                {"type": "text", "text": "budget is 42<system-reminder>RESULT REMINDER</system-reminder>"},
                {"type": "image", "source": {}}]}], "x2", "x1"),
            claude_record("assistant", [{"type": "text", "text": "API ERROR"}], "x3", "x2", isApiErrorMessage=True),
            claude_record("assistant", [{"type": "text", "text": "The budget is 42."}], "x4", "x3"),
            # A rewind: the abandoned reply is off the newest message's path.
            claude_record("user", "follow-up v1", "r1", "x4"),
            claude_record("assistant", [{"type": "text", "text": "ABANDONED REPLY"}], "r2", "r1"),
            claude_record("user", "follow-up v2", "r3", "x4"),
            claude_record("assistant", [{"type": "text", "text": "Answer two."}], "r4", "r3"),
            "{broken",
        ]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def test_claude_transcript_is_read_along_the_live_branch(self):
        path = self.sample_transcript()
        result = subprocess.run([sys.executable, str(HELPER), "--read-claude", str(path)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["messages"], 4)

    def test_claude_transcript_starts_a_thread_after_the_context(self):
        path = self.sample_transcript()
        result = self.run_helper('', '--history-from-claude', str(path), '--history-source', CLAUDE_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, THREAD_ID + '\n')
        requests = [r['request'] for r in self.requests()]
        injections = [r['params']['items'] for r in requests if r['method'] == 'thread/inject_items']
        self.assertEqual(len(injections), 2)
        self.assertEqual(injections[0][0]['content'][0]['text'], self.instructions.read_text())
        items = injections[1]
        self.assertEqual([(i['role'], i['content'][0]['type']) for i in items], [
            ('developer', 'input_text'), ('user', 'input_text'), ('assistant', 'output_text'),
            ('user', 'input_text'), ('assistant', 'output_text')])
        texts = [i['content'][0]['text'] for i in items]
        self.assertTrue(texts[0].startswith('[cs carried this conversation over from Claude conversation ' + CLAUDE_ID))
        self.assertIn("Claude's thinking is not included", texts[0])
        self.assertEqual(texts[1], '/color blue\n\nfind the budget')
        self.assertIn('Reading notes.', texts[2])
        self.assertIn('[tool call: Read]\n{"file_path": "notes.txt"}', texts[2])
        self.assertIn('[tool result]\nbudget is 42\n[image]', texts[2])
        self.assertIn('The budget is 42.', texts[2])
        self.assertEqual(texts[3], 'follow-up v2')
        self.assertEqual(texts[4], 'Answer two.')
        whole = json.dumps(items)
        for absent in ('OLD BRANCH', 'Session color set', 'Caveat', 'REMINDER', 'HOOK CONTEXT',
                       'SECRET THINKING', 'SIDECHAIN', 'API ERROR', 'ABANDONED', 'v1'):
            self.assertNotIn(absent, whole)
        # Injection precedes the durability check in a fresh process.
        methods = [r['method'] for r in requests]
        self.assertLess(methods.index('thread/unsubscribe'), methods.index('thread/resume'))

    def test_claude_compaction_starts_at_its_summary(self):
        path = self.root / (CLAUDE_ID + ".jsonl")
        path.write_text("\n".join([
            claude_record("user", "BEFORE COMPACTION", "p1", None),
            json.dumps({"type": "system", "subtype": "compact_boundary", "uuid": "b1", "parentUuid": None,
                        "logicalParentUuid": "p1"}),
            claude_record("user", "This session is being continued. Summary: budget 42.", "c1", "b1",
                          isCompactSummary=True),
            claude_record("assistant", [{"type": "text", "text": "Continuing."}], "c2", "c1"),
        ]) + "\n")
        result = self.run_helper('', '--history-from-claude', str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        items = [r['request']['params']['items'] for r in self.requests()
                 if r['request']['method'] == 'thread/inject_items'][1]
        texts = [i['content'][0]['text'] for i in items]
        self.assertEqual(texts[1:], ['This session is being continued. Summary: budget 42.', 'Continuing.'])
        # Without --history-source the note names the transcript's own ID.
        self.assertIn(CLAUDE_ID, texts[0])

    def test_large_conversations_are_injected_in_order_in_batches(self):
        path = self.root / (CLAUDE_ID + ".jsonl")
        lines, parent = [], None
        for n in range(12):
            uid = "m%d" % n
            if n % 2 == 0:
                lines.append(claude_record("user", "prompt %d " % n + "p" * 120000, uid, parent))
            else:
                lines.append(claude_record("assistant", [{"type": "text", "text": "reply %d" % n}], uid, parent))
            parent = uid
        path.write_text("\n".join(lines) + "\n")
        result = self.run_helper('', '--history-from-claude', str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        batches = [r['request']['params']['items'] for r in self.requests()
                   if r['request']['method'] == 'thread/inject_items'][1:]
        self.assertGreater(len(batches), 1)
        for batch in batches:
            self.assertLessEqual(len(json.dumps(batch)), 512 * 1024 + 130000)
        texts = [i['content'][0]['text'] for batch in batches for i in batch][1:]
        self.assertEqual([t.split(' ')[1] for t in texts], [str(n) for n in range(12)])

    def test_nothing_to_carry_starts_no_server(self):
        path = self.root / (CLAUDE_ID + ".jsonl")
        path.write_text(claude_record("user", "meta only", "u1", None, isMeta=True) + "\n")
        self.assert_failure('', 'nothing to carry over', '--history-from-claude', str(path))
        self.assertFalse((self.root / 'pids').exists())
        result = subprocess.run([sys.executable, str(HELPER), "--read-claude", str(path)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"messages": 0, "characters": 0})

    def test_carrying_needs_a_new_thread_and_a_readable_transcript(self):
        path = self.sample_transcript()
        result = self.run_helper('', '--history-from-claude', str(path), '--thread-id', THREAD_ID)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--history-from-claude starts a new thread', result.stderr)
        self.assert_failure('', 'could not read bootstrap inputs', '--history-from-claude', str(self.root / 'missing.jsonl'))
        self.assertFalse((self.root / 'pids').exists())
        result = subprocess.run([sys.executable, str(HELPER), "--read-claude", str(self.root / "missing.jsonl")],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not read the Claude transcript", result.stderr)


if __name__ == '__main__':
    unittest.main()
