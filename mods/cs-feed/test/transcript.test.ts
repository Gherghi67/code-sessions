// ABOUTME: Verifies turn boundaries and call identity from recorded engine transcripts.
// ABOUTME: Expected segmentation follows the design's conservative plain and API join.
import { expect, test } from 'claude-code/testing'
import { opensTurn, opensPeerTurn, joinApi, buildTranscript, backgroundRuns, questionPairs, callId } from '../hooks/transcript'
import type { ApiMessage, SessionMessage } from 'claude-code'
import base from './fixtures/messages-plain'
import m1a from './fixtures/messages-m1a-plain'
import sendnow from './fixtures/messages-m1a2-sendnow-plain'
import stream from './fixtures/messages-m1a2-stream-plain'
import m1b from './fixtures/messages-m1b-plain'
import m1c from './fixtures/messages-m1c-plain'
import m1d from './fixtures/messages-m1d-plain'
import m1cApi from './fixtures/messages-m1c-api'
import m1dApi from './fixtures/messages-m1d-api'
import baseApi from './fixtures/messages-api'
import m1aApi from './fixtures/messages-m1a-api'
import sendnowApi from './fixtures/messages-m1a2-sendnow-api'
import streamApi from './fixtures/messages-m1a2-stream-api'
import m1bApi from './fixtures/messages-m1b-api'

// These captured SessionMessage records have the engine's shape; JSON imports widen role to string.
const dumps = [base, m1a, sendnow, stream, m1b, m1c, m1d] as readonly SessionMessage[][]

test('structured output precedes model-facing wrappers and retains its count when capped', () => {
  const transcript = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'output', tool: 'Bash', input: {}, text: '<tool_result>wrapped</tool_result>', result: { stdout: 'one\ntwo', stderr: 'three' } }, { tool_use_id: 'long', tool: 'Read', input: {}, text: 'wrapper', result: { stdout: 'x'.repeat(2100) } }] }])
  expect(transcript.calls.get(callId('output'))?.outcome).toEqual({ state: 'done', errored: false, refused: false, interrupted: false, lines: 3, output: 'one\ntwo\nthree', durationMs: undefined, answers: undefined })
  expect(transcript.calls.get(callId('long'))?.outcome).toEqual({ state: 'done', errored: false, refused: false, interrupted: false, lines: 1, output: 'x'.repeat(2000), durationMs: undefined, answers: undefined })
})

test('recorded prompts, deliveries and Stop continuations retain their measured turns', () => {
  expect(dumps.map(rows => buildTranscript(rows).turns.length)).toEqual([3, 1, 2, 4, 2, 2, 3])
  // The paired captures carry the same engine ApiMessage contract as the plain dumps.
  const apis = [baseApi, m1aApi, sendnowApi, streamApi, m1bApi, m1cApi, m1dApi] as readonly ApiMessage[][]
  expect(dumps.map((rows, index) => buildTranscript(rows, apis[index]).turns.length)).toEqual([3, 1, 2, 4, 2, 2, 3])
  const whole = buildTranscript(dumps[6] ?? [])
  const cut = buildTranscript((dumps[6] ?? []).slice(4))
  expect(cut.turns.map(turn => turn.id)).toEqual(whole.turns.slice(1).map(turn => turn.id))
})

test('background launches close on idle notifications and API mid-turn notifications', () => {
  const rows = dumps[5] ?? []
  expect(backgroundRuns(rows).map(run => run.id)).toEqual(['toolu_d6c6d6f3637c495ea8e8'])
  expect(backgroundRuns(dumps[2] ?? [])).toEqual([])
  // Captured API messages have the engine contract's role and content block structure.
  expect(buildTranscript(rows, m1cApi as ApiMessage[]).background).toEqual([])
  expect(backgroundRuns([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'test', tool: 'Bash', input: { command: 'npm test', run_in_background: true } }] }])).toEqual([{ id: 'test', words: 'Running a shell command', isTest: true }])
  expect(backgroundRuns([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'test', tool: 'Bash', input: { description: 'npm test', command: 'npm test', run_in_background: true } }] }])).toEqual([{ id: 'test', words: 'Running a shell command', isTest: true }])
})

test('questions retain literal answers and shorten only the question sentence', () => {
  expect(questionPairs({ questions: [{ question: 'Which look? Each is drawn on the page.' }] }, { answers: { 'Which look? Each is drawn on the page.': 'Red' } })).toEqual([{ question: 'Which look', answer: 'Red' }])
  expect(questionPairs({ questions: [{ question: 'Anything else?' }] }, { response: 'free text' })).toEqual([{ question: 'Anything else', answer: 'free text' }])
  expect(questionPairs({}, {})).toEqual([])
  expect(questionPairs({}, { response: 'free text' })).toEqual([{ question: 'a question', answer: 'free text' }])
  expect(questionPairs({}, { answers: { 'Read v1.2. Ready? Details follow.': 'yes', 'First.Second': 'ok' } })).toEqual([{ question: 'Read v1.2. Ready', answer: 'yes' }, { question: 'First', answer: 'ok' }])
})

test('only plain user text without tool results or bash framing opens a turn', () => {
  expect(opensTurn({ role: 'user', text: 'do the work', toolUses: [] })).toBe(true)
  expect(opensTurn({ role: 'assistant', text: 'reply', toolUses: [] })).toBe(false)
  expect(opensTurn({ role: 'user', text: '', toolUses: [] })).toBe(false)
  expect(opensTurn({ role: 'user', text: '<bash-input>pwd</bash-input>', toolUses: [] })).toBe(false)
  expect(opensTurn({ role: 'user', text: '<bash-stdout>/work</bash-stdout>', toolUses: [] })).toBe(false)
  expect(opensTurn({ role: 'user', text: 'result', toolUses: [], toolResults: [{ tool_use_id: 'call', text: 'done', isError: false, result: {} }] })).toBe(false)
})

test('API joins verify ordered tool ids and stop at the first inconsistent pair', () => {
  const plain: SessionMessage[] = [
    { role: 'assistant', text: 'before', toolUses: [{ tool_use_id: 'a', tool: 'Read', input: {} }] },
    { role: 'assistant', text: 'after', toolUses: [{ tool_use_id: 'b', tool: 'Read', input: {} }] },
  ]
  const peer: ApiMessage = { role: 'user', content: [{ type: 'text', text: 'Another Claude session sent a message:\n<cross-session-message from="test-session">hello</cross-session-message>' }] }
  const api: ApiMessage[] = [{ role: 'assistant', content: [{ type: 'text', text: 'before' }, { type: 'tool_use', id: 'a' }] }, peer, { role: 'assistant', content: [{ type: 'text', text: 'after' }, { type: 'tool_use', id: 'b' }] }]
  expect([...joinApi(plain, api).keys()]).toEqual([1])
  expect(buildTranscript(plain, api).turns.map(turn => turn.id)).toEqual(['a', 'b'])
  expect(buildTranscript(plain).turns.map(turn => turn.id)).toEqual(['a'])
  expect(buildTranscript(plain, undefined, new Set([callId('b')])).turns.map(turn => turn.id)).toEqual(['a', 'b'])
  expect([...joinApi(plain, [...api.slice(0, 2), { role: 'assistant', content: [{ type: 'text', text: 'changed' }, { type: 'tool_use', id: 'b' }] }]).keys()]).toEqual([])
  expect([...joinApi(plain, [...api.slice(0, 2), { role: 'assistant', content: [{ type: 'text', text: 'after' }, { type: 'tool_use', id: 'other' }] }]).keys()]).toEqual([])
  const multiple: SessionMessage[] = [plain[0] ?? { role: 'assistant', text: '', toolUses: [] }, { role: 'assistant', text: 'after', toolUses: [{ tool_use_id: 'b', tool: 'Read', input: {} }, { tool_use_id: 'c', tool: 'Read', input: {} }] }]
  expect([...joinApi(multiple, [...api.slice(0, 2), { role: 'assistant', content: [{ type: 'text', text: 'after' }, { type: 'tool_use', id: 'b' }, { type: 'tool_use', id: 'c' }] }]).keys()]).toEqual([1])
  expect([...joinApi(multiple, [...api.slice(0, 2), { role: 'assistant', content: [{ type: 'text', text: 'after' }, { type: 'tool_use', id: 'c' }, { type: 'tool_use', id: 'b' }] }]).keys()]).toEqual([])
})

test('a tool-free text verifies only when it is unique in both lists', () => {
  const plain: SessionMessage[] = [{ role: 'assistant', text: 'before', toolUses: [] }, { role: 'assistant', text: 'after', toolUses: [] }]
  const api: ApiMessage[] = [{ role: 'assistant', content: [{ type: 'text', text: 'before' }] }, { role: 'user', content: [{ type: 'text', text: 'peer' }] }, { role: 'assistant', content: [{ type: 'text', text: 'after' }] }]
  expect([...joinApi(plain, api).keys()]).toEqual([1])
  expect([...joinApi([{ role: 'assistant', text: 'before', toolUses: [] }, ...plain], api).keys()]).toEqual([])
  expect([...joinApi(plain, [{ role: 'assistant', content: [{ type: 'text', text: 'before' }] }, ...api]).keys()]).toEqual([])
  // m1d has the identical "ok" replies at API rows 11 and 13; neither verifies even if the newest API reply is absent.
  expect([...joinApi(dumps[6] ?? [], m1dApi as ApiMessage[]).keys()]).toEqual([])
  expect([...joinApi(dumps[6] ?? [], (m1dApi as ApiMessage[]).slice(0, -1)).keys()]).toEqual([])
})

test('peer history accepts one anchored preamble and refuses quoted envelopes', () => {
  const preamble = 'Another Claude session sent a message:\n<cross-session-message from="test-session">hello</cross-session-message>'
  expect(opensPeerTurn({ role: 'user', content: [{ type: 'text', text: preamble }] })).toBe(true)
  expect(opensPeerTurn({ role: 'user', content: [{ type: 'text', text: preamble }, { type: 'text', text: '<system-reminder>tokens</system-reminder>' }] })).toBe(true)
  for (const text of ['see: ' + preamble, '<system-reminder>' + preamble + '</system-reminder>', 'Stop hook feedback:\n<task-notification>done</task-notification>', 'Stop hook feedback:\n' + preamble, '<teammate-message>done</teammate-message>']) {
    expect(opensPeerTurn({ role: 'user', content: [{ type: 'text', text }] })).toBe(false)
  }
  expect(opensPeerTurn({ role: 'assistant', content: [{ type: 'text', text: preamble }] })).toBe(false)
  expect(opensPeerTurn({ role: 'user', content: [{ type: 'text', text: preamble }, { type: 'tool_result', content: 'done' }] })).toBe(false)
})
