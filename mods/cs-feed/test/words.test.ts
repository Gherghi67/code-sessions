// ABOUTME: Pins feed wording to the feature specification's literal examples.
// ABOUTME: Covers cleaning at the transcript text boundary without drawing hooks.
import { expect, test } from 'claude-code/testing'
import { callWords, clean, toolName, isRefusal, looksLikeTest, stepsLine, fit, elapsed, hhmm, runWords, runChips, callChips } from '../hooks/words'
import { buildTranscript, callId } from '../hooks/transcript'

test('run summaries count kinds and chips without counting refused calls as failed work', () => {
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [
    { tool_use_id: 'a', tool: 'Bash', input: {}, result: { stdout: 'ok' } },
    { tool_use_id: 'b', tool: 'Bash', input: {}, result: { stdout: 'done' } },
    { tool_use_id: 'c', tool: 'Read', input: {}, result: { stdout: 'file' } },
    { tool_use_id: 'd', tool: 'Read', input: {}, isError: true, text: 'blocked by a hook' },
  ] }])
  const run = t.runs.get(callId('a'))
  if (!run) throw new Error('The fixture must file one run')
  expect(runWords(run, t)).toBe('Ran 2 shell commands · read 1 file')
  expect(runWords(run, t, 'Reading app.py')).toBe('Reading app.py')
  expect(runWords({ ...run, calls: [callId('a'), callId('c')] }, t)).toBe('Read 1 file · ran 1 shell command')
  expect(runWords({ ...run, calls: [callId('d')] }, t)).toBe('1 step refused by a hook')
  expect(runChips(run, t)).toEqual(['1 step refused by a hook', '+4 lines'])
  expect(callChips({ tool: 'Bash', input: {}, isRunning: false, isErrored: false, isInterrupted: false }, t.calls.get(callId('a')))).toEqual(['+1 lines'])
})

test('compact labels preserve singular counts and bounded time and text', () => {
  expect(stepsLine(1)).toBe('1 step this turn')
  expect(stepsLine(3)).toBe('3 steps this turn')
  expect(elapsed(-1000)).toBe('0s')
  expect(elapsed(8000)).toBe('8s')
  expect(elapsed(72000)).toBe('1m 12s')
  expect(elapsed(3780000)).toBe('1h 3m')
  expect(hhmm(new Date(2026, 0, 1, 9, 7).getTime())).toBe('09:07')
  expect(fit('short', 12)).toBe('short')
  expect(fit('Reading a large file', 14)).toBe('Reading a…')
  expect(fit('abcdefghijk', 2)).toBe('abcd…')
})

test('call labels clean descriptions and name tools without exposing commands', () => {
  expect(callWords({ tool: 'Bash', input: { command: 'cd /private/tmp/x && python3 run.py' } }, 'present')).toBe('Running a shell command')
  expect(callWords({ tool: 'Read', input: { file_path: '/repo/src/app.py' } }, 'present')).toBe('Reading app.py')
  expect(callWords({ tool: 'WebFetch', input: { url: 'https://www.example.com/a/b?c=1' } }, 'present')).toBe('Opening example.com')
  expect(clean('Run the tests in /private/tmp/12345678-abcd-1234-abcd-123456789abc/run')).toBe('Run the tests in run')
  expect(toolName('mcp__claude_ai_Slack__send')).toBe('Slack send')
})

test('hook refusals and background test words use the specified phrases', () => {
  expect(isRefusal('PreToolUse:Agent hook error: provide a brief')).toBe(true)
  expect(isRefusal('PermissionRequest hook denied')).toBe(true)
  expect(isRefusal('blocked by a hook')).toBe(true)
  expect(isRefusal('network failed')).toBe(false)
  expect(looksLikeTest('Run the unit tests')).toBe(true)
  expect(looksLikeTest('Build the docs site')).toBe(false)
})
