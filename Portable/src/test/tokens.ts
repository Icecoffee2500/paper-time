/**
 * The design tokens, pinned (`WR8`): the ladders `:root` declares — motion,
 * radius — are there, the panes use the panel's radius, and no transition
 * in the stylesheet spells a duration of its own instead of the ladder's.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function tokensSuite(test: Test, suite: (name: string) => void) {
  suite('The design tokens')
  const css = fs.readFileSync(path.resolve(__dirname, '../../src/renderer/style.css'), 'utf8')
  const root = css.slice(css.indexOf(':root {'), css.indexOf('}', css.indexOf(':root {')))

  await test('the motion and radius ladders are declared', () => {
    for (const token of ['--motion-tap', '--motion-move', '--motion-surface', '--motion-fade', '--ease',
      '--radius-control', '--radius-bar', '--radius-popover', '--radius-panel']) {
      assert.ok(root.includes(`${token}:`), token)
    }
  })

  await test('the panes stand at the panel radius, as the Mac’s do', () => {
    assert.match(root, /--panel-radius:\s*var\(--radius-panel\)/)
  })

  await test('every transition moves at a step of the ladder', () => {
    const literal = [...css.matchAll(/transition(?:-duration)?:([^;]*);/g)]
      .map((match) => match[1])
      .filter((value) => /\b\d*\.?\d+m?s\b/.test(value.replace(/var\([^)]*\)/g, '')))
    assert.deepEqual(literal, [])
  })

  await test('what loops or holds keeps its own time, and nothing else does', () => {
    const held = new Set(['spin', 'passage-flash', 'mark-row-flash', 'nm-flash'])
    const literal = [...css.matchAll(/animation:\s*([\w-]+)\s+([^;]*);/g)]
      .filter((match) => /\b\d*\.?\d+m?s\b/.test(match[2].replace(/var\([^)]*\)/g, '')) && !held.has(match[1]))
      .map((match) => match[0])
    assert.deepEqual(literal, [])
  })
}
