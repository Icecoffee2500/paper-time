/**
 * Every command has a row (`WR4`): each name the menu sends and each name the
 * shortcut list gives a key is a key of `COMMANDS` in `renderer/commands.ts`.
 * A name without one used to reach a toast saying it was not in this build —
 * which is how Ctrl+N and Ctrl+L were dead. Read from the source, because the
 * table imports the whole window.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { SHORTCUTS } from '../shared/shortcuts.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const source = (file: string) => fs.readFileSync(path.join(__dirname, '../../src', file), 'utf8')

export async function commandsSuite(test: Test, suite: (name: string) => void) {
  suite('Every command has a row')

  const table = source('renderer/commands.ts')
  const body = table.slice(table.indexOf('export const COMMANDS = {'), table.indexOf('} satisfies Record<string, () => void>'))
  const rows = new Set([...body.matchAll(/^ {2}([a-zA-Z]+): /gm)].map((match) => match[1]))

  await test('the table was read', () => {
    assert.ok(rows.size > 30, `found ${rows.size}`)
  })

  await test('every key in the shortcut list reaches a command', () => {
    const missing = SHORTCUTS.map((entry) => entry.command).filter((name) => !rows.has(name))
    assert.deepEqual(missing, [])
  })

  await test('every item in the menu reaches a command', () => {
    const menu = source('main/menu.ts')
    const names = [...menu.matchAll(/\b(?:item|command)\('([a-zA-Z]+)'/g)].map((match) => match[1])
    assert.ok(names.length > 20, `found ${names.length}`)
    assert.deepEqual([...new Set(names)].filter((name) => !rows.has(name)), [])
  })
}
