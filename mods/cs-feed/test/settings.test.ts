// ABOUTME: Tests the feed command grammar and the persisted view boundary.
// ABOUTME: Expected values come from the design and feature specification.
import { expect, test } from 'claude-code/testing'
import { DEFAULT_VIEW, PRESETS, isOn, modeOf, parseStoredView, parseFeedArgs, transition } from '../hooks/settings'

test('an off session reports raw without changing its view', () => {
  expect(modeOf({ on: false, view: DEFAULT_VIEW })).toBe('raw')
})

test('feed accepts the usage grammar and rejects unknown or extra sole words', () => {
  expect(['', 'close', 'on', 'off', 'status', 'clean', 'normal', 'raw', 'group off please', 'clear yes', 'keep false', 'style expanded', 'style subtle', 'style line', 'commands grouped', 'commands each', 'after clear', 'after keep', 'hide peer', 'show peer', 'loud', 'clean now'].map(parseFeedArgs)).toEqual([
    { kind: 'open' }, { kind: 'close' }, { kind: 'switch', on: true }, { kind: 'switch', on: false }, { kind: 'status' },
    { kind: 'preset', to: 'clean' }, { kind: 'preset', to: 'normal' }, { kind: 'preset', to: 'raw' },
    { kind: 'set', field: 'group', value: false }, { kind: 'set', field: 'clear', value: true }, { kind: 'set', field: 'keep', value: false },
    { kind: 'set', field: 'style', value: 'expanded' }, { kind: 'set', field: 'style', value: 'subtle' }, { kind: 'set', field: 'style', value: 'line' },
    { kind: 'set', field: 'commands', value: 'grouped' }, { kind: 'set', field: 'commands', value: 'each' }, { kind: 'set', field: 'after', value: 'clear' }, { kind: 'set', field: 'after', value: 'keep' },
    { kind: 'hide', what: 'peer' }, { kind: 'show', what: 'peer' }, { kind: 'usage' }, { kind: 'usage' },
  ])
  expect(parseFeedArgs('  GROUP   TRUE ')).toEqual({ kind: 'set', field: 'group', value: true })
  expect(parseFeedArgs('group no')).toEqual({ kind: 'set', field: 'group', value: false })
  expect(parseFeedArgs('style subtle')).toEqual({ kind: 'set', field: 'style', value: 'subtle' })
  expect(parseFeedArgs('commands each')).toEqual({ kind: 'set', field: 'commands', value: 'each' })
  expect(parseFeedArgs('after keep')).toEqual({ kind: 'set', field: 'after', value: 'keep' })
})

test('the file switch accepts only its complete on line', () => {
  expect(['on\n', 'on', 'on\n\n', ' on\n', 'off\n', 'ON\n', undefined].map(isOn)).toEqual([true, false, false, false, false, false, false])
})

test('a mode matches every field and requires no hidden kinds', () => {
  expect(modeOf({ on: true, view: { ...PRESETS.normal.fields, hide: [] } })).toBe('normal')
  expect(modeOf({ on: true, view: { ...DEFAULT_VIEW, hide: ['peer'] } })).toBe('custom')
  expect(modeOf({ on: true, view: { ...DEFAULT_VIEW, style: 'line' } })).toBe('custom')
})

test('stored views refuse torn, malformed, invalid and incomplete records', () => {
  expect(() => parseStoredView('{}')).toThrow('feed-view is torn: missing closing newline')
  expect(() => parseStoredView('{\n')).toThrow('feed-view contains invalid JSON')
  expect(() => parseStoredView(JSON.stringify({ ...DEFAULT_VIEW, group: 'yes' }) + '\n')).toThrow('feed-view field group has invalid value "yes"')
  expect(() => parseStoredView('{}\n')).toThrow('feed-view is missing field group')
  expect(parseStoredView(undefined)).toEqual({ group: true, clear: true, keep: false, style: 'subtle', commands: 'grouped', after: 'clear', hide: [] })
  expect(parseStoredView(JSON.stringify(DEFAULT_VIEW) + '\n')).toEqual({ group: true, clear: true, keep: false, style: 'subtle', commands: 'grouped', after: 'clear', hide: [] })
})

test('commands change only the session fields named by the transition table', () => {
  const current = { on: false, view: { ...DEFAULT_VIEW, hide: ['peer'] as const } }
  const changed = transition(parseFeedArgs('normal'), current)
  expect(changed).toEqual({ session: { on: true, view: { group: false, clear: false, keep: true, style: 'subtle', commands: 'grouped', after: 'keep', hide: ['peer'] } }, reply: 'Chat view: normal. each run of tool calls is one line with counts.' })
  expect(transition(parseFeedArgs('raw'), current).session).toEqual(current)
  const on = { on: true, view: { group: false, clear: false, keep: true, style: 'line' as const, commands: 'each' as const, after: 'keep' as const, hide: ['peer'] as const } }
  expect(transition(parseFeedArgs('raw'), on).session).toEqual({ on: false, view: { group: false, clear: false, keep: true, style: 'line', commands: 'each', after: 'keep', hide: ['peer'] } })
  expect(transition(parseFeedArgs('off'), on).session).toEqual({ on: false, view: { group: false, clear: false, keep: true, style: 'line', commands: 'each', after: 'keep', hide: ['peer'] } })
  expect(transition(parseFeedArgs('on'), current).session).toEqual({ ...current, on: true })
  expect(transition(parseFeedArgs('group off'), current).session).toEqual({ on: true, view: { ...current.view, group: false } })
  expect(transition(parseFeedArgs('show peer'), current).session).toEqual({ on: true, view: DEFAULT_VIEW })
  expect(transition(parseFeedArgs('hide tool'), current).session?.view.hide).toEqual(['peer', 'tool'])
  expect(transition(parseFeedArgs('status'), current)).toEqual({ reply: 'off · raw' })
  expect(transition(parseFeedArgs(''), current)).toEqual({ pane: 'open', reply: 'Chat view: raw. Settings are open above the prompt; /feed close shuts them.' })
  expect(transition(parseFeedArgs('close'), current)).toEqual({ pane: 'close', reply: 'Chat view settings closed.' })
  expect(transition(parseFeedArgs('bad'), current).session).toBeUndefined()
})
