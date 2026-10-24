// ABOUTME: Tests for the band variants gallery in docs/mods-band-variants.js.
// ABOUTME: Pins the state catalogue, the shipped band's port against register.tsx, and every sketch against the engine.
import { test, expect } from 'bun:test'
const { STATES } = require('../mods-band-variants.js')

const state = (id: string) => {
  const found = STATES.find((s: any) => s.id === id)
  if (found === undefined) throw new Error(`no state ${id}`)
  return found.facts
}

test('the catalogue names every state the gallery draws, in order', () => {
  expect(STATES.map((s: any) => s.id)).toEqual([
    'idle', 'rotate-due', 'countdown', 'armed-clear-now', 'feed-off', 'feed-on', 'queue-waiting', 'queue-running',
    'gate-running', 'mail', 'features-ready', 'everything', 'rail-few', 'rail-many', 'no-chords',
  ])
})

test('the catalogue carries the labels buildBandEntries and its producers write', () => {
  expect(state('features-ready').featured).toEqual({ label: '3 features · fix-auth ready', pressable: true })
  expect(state('gate-running').gate).toBe('finishing fix-auth · gate 1m 12s')
  expect(state('countdown').countdown).toEqual({ seconds: 7, ink: 'amber' })
  expect(state('rail-few').rail.prompts.length).toBe(3)
  expect(state('rail-many').rail.prompts.length).toBe(14)
  expect(state('no-chords').chords).toEqual({})
  expect(state('rotate-due').chords).toEqual({ rotate: 'ctrl+x 1', wrap: 'ctrl+x 2', feed: 'ctrl+x 3' })
})
