// ABOUTME: The cs-update release-notes pane in each state, as PaneView fixtures handed to the mod's own drawPane.
// ABOUTME: Typed against the mod's exports, so a change to PaneView breaks this file at type-check.
import { drawPane, parseSpan, type PaneView } from '../../mods/cs-update/hooks/register.tsx'
import { SESSION_PALETTE } from '../../mods/cs/hooks/register.tsx'
import { elements, type Surface } from './registry.ts'

const NOTES = [
  '## 2026.10.25',
  '### Fixed',
  "- The band's **mark** keeps its colour",
  '- `cs -update` checks the signature',
  '  before it installs',
  '## 2026.10.20',
  '- A [link](https://example.com) survives as text',
  '',
].join('\n')

const base: PaneView = { version: '2026.10.25', sections: parseSpan(NOTES), accent: `rgb(${SESSION_PALETTE.blue})`, phase: 'idle', outcome: '' }
const pane = (over: Partial<PaneView>) => () => drawPane({ ...base, ...over }, elements(), () => {})

export const surfaces: Surface[] = [{
  id: 'cs-update.Pane.cs-update',
  mod: 'cs-update',
  slot: 'Pane',
  source: 'generated',
  global: 'CsUpdateSurfaces',
  needs: [],
  chrome: { kind: 'pane', title: 'cs 2026.10.25 is available', rows: 16 },
  states: [
    { id: 'idle-notes', name: 'reading the notes before installing', draw: pane({}) },
    { id: 'idle-no-colour', name: 'reading the notes in a session with no colour', draw: pane({ accent: undefined }) },
    { id: 'idle-no-notes', name: 'offered an update whose notes were not fetched', draw: pane({ sections: [] }) },
    { id: 'several-sections', name: 'reading notes that span many releases', draw: pane({ sections: parseSpan(Array.from({ length: 5 }, (_, i) => `## 2026.10.${25 - i}\n- release note ${i + 1}\n- and a second line`).join('\n')) }) },
    { id: 'running', name: 'waiting while cs -update runs', draw: pane({ phase: 'running' }) },
    { id: 'failed-no-bin', name: 'told the launch did not say where cs is', draw: pane({ phase: 'failed', outcome: 'The launch did not say where cs is; run `cs -update` from a shell.' }) },
    { id: 'failed-exit', name: 'reading why cs -update failed', draw: pane({ phase: 'failed', outcome: 'cs -update exited 3.\ndownload failed\nchecksum mismatch' }) },
    { id: 'done', name: 'told the update finished', draw: pane({ phase: 'done', outcome: 'Update finished. Takes effect on your next launch.' }) },
  ],
  parts: [
    { id: 'update-key', name: 'hotkey Button', state: 'idle-notes', path: [1, 0, 0] },
    { id: 'release-heading', name: 'release heading', state: 'idle-notes', path: [2, 0] },
    { id: 'note-line', name: 'note line', state: 'idle-notes', path: [2, 1] },
  ],
}]
