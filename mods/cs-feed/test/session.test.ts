// ABOUTME: Exercises the pure state transitions behind live transcript observations.
// ABOUTME: Event order comes from the design's measured append and turn-start sequence.
import { expect, test } from 'claude-code/testing'
import { newLoad, observePrompt, observeTurnStart, observeResponse, openTurn, replaceResponseText } from '../hooks/session'
import { buildTranscript } from '../hooks/transcript'

test('an unknown phase uses the band observation or a running call without inventing a turn id', () => {
  const load = newLoad()
  const t = buildTranscript([{ role: 'user', text: 'work', toolUses: [] }, { role: 'assistant', text: '', toolUses: [{ tool_use_id: 'live', tool: 'Read', input: {} }] }])
  expect(openTurn(load, t)?.id).toBe('live')
  load.obs.working = false
  expect(openTurn(load, t)).toBeUndefined()
  load.obs.phase = 'live'
  const empty = buildTranscript([{ role: 'user', text: 'work', toolUses: [] }])
  expect(openTurn(load, empty)).toEqual({ steps: [], runs: [] })
  load.obs.phase = 'idle'
  expect(openTurn(load, empty)).toBeUndefined()
})

test('a prompt-door idle peer opens its first response call unless a typed prompt intervenes', () => {
  const load = newLoad()
  observePrompt(load, { door: 'prompt', peer: true, isMeta: true })
  observeTurnStart(load)
  observeResponse(load, { uuid: 'reply', text: 'working', calls: ['peer-call'] })
  expect([...load.obs.turnOpeners]).toEqual(['peer-call'])
  observeResponse(load, { uuid: 'later', text: 'done', calls: ['later-call'] })
  expect([...load.obs.turnOpeners]).toEqual(['peer-call'])
  const typed = newLoad()
  observePrompt(typed, { door: 'prompt', peer: true, isMeta: true })
  observePrompt(typed, { door: 'prompt', peer: false, isMeta: false })
  observeTurnStart(typed)
  observeResponse(typed, { uuid: 'reply', text: 'working', calls: ['typed-call'] })
  expect([...typed.obs.turnOpeners]).toEqual([])
})

test('a response anchors its text before filing the same row’s new calls', () => {
  const load = newLoad()
  observeResponse(load, { uuid: 'first', text: 'starting', calls: ['before'] })
  expect(load.obs.anchors.has('first')).toBe(false)
  observeResponse(load, { uuid: 'second', text: 'continuing', calls: ['after'] })
  expect(load.obs.anchors.get('second')).toEqual({ call: 'before', text: 'continuing', seq: 1 })
  expect(load.obs.callSincePrompt).toBe('after')
  replaceResponseText(load, 'second', 'stored text')
  expect(load.obs.anchors.get('second')).toEqual({ call: 'before', text: 'stored text', seq: 1 })
  expect([...load.obs.latestByCall]).toEqual([['before', 'second']])
})
