/**
 * Keys a person changes, and the release notes read out of the Mac's Swift
 * (`WR20`): one key per action, the menus' spelling, the key a press
 * spells, and a JSON that is the Swift's and not a copy that drifted.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import {
  acceleratorFor, acceleratorFromEvent, assignShortcut, displayAccelerator, eventIs, hasShortcut, keyFor,
  matchingShortcuts, parseShortcutOverrides, sameAccelerator, setShortcutOverrides, shortcut,
} from '../shared/shortcuts.js'
import { readReleaseNotes } from '../../tools/release-notes-parser.mjs'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const press = (code: string, mods: Partial<{ metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }> = {}, key = '') =>
  ({ key: key || code.replace(/^Key/, '').toLowerCase(), code, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods })

export async function shortcutsAndLogSuite(test: Test, suite: (name: string) => void) {
  suite('Keys you change, and the Log read from the Mac')

  await test('a key belongs to one command: giving it to a second takes it from the first', () => {
    const k = 'CmdOrCtrl+K'
    let using = assignShortcut({}, 'findInDocument', k, 'win32')
    assert.equal(acceleratorFor(shortcut('findInDocument')!, 'win32', using), k)
    assert.equal(acceleratorFor(shortcut('searchEverything')!, 'win32', using), '', 'the old owner has none now')
    assert.equal(hasShortcut('searchEverything', 'win32', using), false)
    // Back to its own key is no override at all.
    using = assignShortcut(using, 'findInDocument', 'CmdOrCtrl+F', 'win32')
    assert.equal('findInDocument' in using, false)
    // Unset, and the settings' JSON read back with only what it may hold.
    using = assignShortcut(using, 'newNote', '', 'win32')
    assert.equal(using.newNote, '')
    assert.deepEqual(parseShortcutOverrides(JSON.stringify({ ...using, nonsense: 'X', draw: 3 })), using)
    assert.deepEqual(parseShortcutOverrides('not json'), {})
  })

  await test('what the menus and tooltips say follows the chosen key, on each desktop', () => {
    setShortcutOverrides({ searchEverything: 'CmdOrCtrl+Shift+Space' })
    try {
      assert.equal(keyFor('searchEverything', 'win32'), 'Ctrl+Shift+Space')
      assert.equal(keyFor('searchEverything', 'darwin'), '⇧⌘Space')
      assert.equal(keyFor('findInDocument', 'linux'), 'Ctrl+F')
      assert.equal(displayAccelerator('', 'win32'), '')
    } finally {
      setShortcutOverrides({})
    }
  })

  await test('a press spells its accelerator by where the key is, not what it typed', () => {
    assert.equal(acceleratorFromEvent(press('KeyK', { ctrlKey: true, shiftKey: true }, 'K'), 'win32'), 'CmdOrCtrl+Shift+K')
    assert.equal(acceleratorFromEvent(press('Digit1', { metaKey: true, shiftKey: true }, '!'), 'darwin'), 'CmdOrCtrl+Shift+1')
    assert.equal(acceleratorFromEvent(press('KeyK', { ctrlKey: true }), 'darwin'), 'Ctrl+K', 'Control on a Mac is its own key')
    assert.equal(acceleratorFromEvent(press('KeyK'), 'win32'), null, 'a letter alone is typing')
    assert.equal(acceleratorFromEvent(press('KeyK', { shiftKey: true }, 'K'), 'win32'), null, 'a capital is typing too')
    assert.equal(acceleratorFromEvent(press('F5'), 'win32'), 'F5')
    assert.equal(acceleratorFromEvent({ ...press('ShiftLeft', { shiftKey: true }), key: 'Shift' }, 'win32'), null)
    assert.equal(acceleratorFromEvent(press('BracketLeft', { ctrlKey: true }, '['), 'linux'), 'CmdOrCtrl+[')
    assert.ok(sameAccelerator('Shift+CmdOrCtrl+K', 'CmdOrCtrl+Shift+K', 'win32'))
    assert.ok(sameAccelerator('CmdOrCtrl+K', 'Ctrl+K', 'linux'))
    assert.ok(!sameAccelerator('CmdOrCtrl+K', 'Ctrl+K', 'darwin'))
    assert.ok(eventIs('openPapers', press('KeyO', { ctrlKey: true, shiftKey: true }, 'O'), 'win32'))
  })

  await test('the search finds a command by its name, or by the key pressed in the field', () => {
    assert.deepEqual(matchingShortcuts('', 'CmdOrCtrl+K', 'win32').map((one) => one.command), ['searchEverything'])
    assert.deepEqual(matchingShortcuts('', 'CmdOrCtrl+Alt+Shift+9', 'win32'), [])
    assert.ok(matchingShortcuts('zoom', null, 'win32').every((one) => one.command.toLowerCase().includes('zoom') || one.title().toLowerCase().includes('zoom')))
  })

  await test("the Log's JSON is what ReleaseNotes.swift says now", () => {
    const root = path.resolve(process.cwd(), '..')
    const fresh = readReleaseNotes(
      fs.readFileSync(path.join(root, 'App/Model/ReleaseNotes.swift'), 'utf8'),
      fs.readFileSync(path.join(root, 'App/Model/Contributors.swift'), 'utf8'),
    )
    const kept = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'src/shared/releaseNotes.json'), 'utf8'))
    assert.deepEqual(kept, fresh, 'run node tools/generate-release-notes.mjs')
    assert.ok(fresh.releases.length > 20 && fresh.highlights.length > 10)
    assert.ok(fresh.releases.every((release: { version: string; added: unknown[] }) => /^\d+\.\d+\.\d+$/.test(release.version)))
  })
}
