// ABOUTME: Loads the lab's shim, every mod bundle and the registry into this process as the page's script tags would.
// ABOUTME: Shared by the bun tests that draw a bundled surface.
const fs = require('fs'), path = require('path'), vm = require('vm')
const dir = path.join(__dirname, '..', 'surfaces')
for (const f of ['shim.js', ...fs.readdirSync(dir).filter((f: string) => /^cs.*\.js$/.test(f)).sort()]) {
  vm.runInThisContext(fs.readFileSync(path.join(dir, f), 'utf8'), { filename: path.join(dir, f) })
}
export const { SURFACES } = require('../surfaces/surfaces.js')
export function surface(id: string): any {
  const found = SURFACES.find((s: any) => s.id === id)
  if (found === undefined) throw new Error(`no surface ${id}`)
  return found
}
export function state(id: string): any {
  const [sid, st] = id.split('/')
  const found = surface(sid).states.find((s: any) => s.id === st)
  if (found === undefined) throw new Error(`no state ${st} of ${sid}`)
  return found
}
