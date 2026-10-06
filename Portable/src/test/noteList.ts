/**
 * Numbered lists counted, and items moved in and out, as the Mac does it —
 * `note-lists.json` is the Mac's own `NoteList`
 * (`Scripts/note-lists-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { listNumbers, shiftItem } from '../shared/noteList.js'
import { indentEdit, returnEdit, backspaceEdit } from '../shared/noteBlocks.js'
import { planNote } from '../shared/noteMarkdown.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  numbers: { note: string; numbers: [number, number][] }[]
  shifts: { note: string; caret: number; by: 1 | -1; edit: { range: [number, number]; replacement: string; caret: number; after: string } | null }[]
}

export async function noteListSuite(test: Test, suite: (name: string) => void) {
  suite('Numbered lists, counted and moved as the Mac does')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'note-lists.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`${fixture.numbers.length} notes: every numbered item shows the Mac's number`, () => {
    for (const item of fixture.numbers) {
      const shown = [...listNumbers(item.note).entries()].sort((a, b) => a[0] - b[0])
      assert.deepEqual(shown, item.numbers, JSON.stringify(item.note))
    }
  })

  await test(`${fixture.shifts.length} moves: Tab and ⇧Tab make the Mac's edit`, () => {
    for (const item of fixture.shifts) {
      const edit = shiftItem(item.note, item.caret, item.by)
      if (!item.edit) {
        assert.equal(edit, null, JSON.stringify(item.note))
        continue
      }
      assert.ok(edit, JSON.stringify(item.note))
      assert.deepEqual([edit.from, edit.to - edit.from], item.edit.range, JSON.stringify(item.note))
      assert.equal(edit.insert, item.edit.replacement, JSON.stringify(item.note))
      assert.equal(edit.caret, item.edit.caret, JSON.stringify(item.note))
    }
  })

  await test('the marker shows the number the item stands at — «a.» for the first one moved in', () => {
    const note = '1. original\n  2. the whole\n  3. the retain\n2. next'
    assert.deepEqual(planNote(note).map((line) => line.shownMarker), ['1.\t', 'a.\t', 'b.\t', '2.\t'])
  })

  await test('Tab, Return on an empty item and Backspace move an item the same way', () => {
    const applied = (text: string, edit: { from: number; to: number; insert: string; caret: number } | null) =>
      edit ? { text: text.slice(0, edit.from) + edit.insert + text.slice(edit.to), caret: edit.caret } : null
    const typed = '1. original\n2. the whole'
    assert.deepEqual(applied(typed, indentEdit(typed, typed.length, 1)), { text: '1. original\n  1. the whole', caret: 26 })
    const empty = '1. a\n  1. x\n  2. '
    assert.deepEqual(applied(empty, returnEdit(empty, empty.length)), { text: '1. a\n  1. x\n2. ', caret: 15 })
    assert.deepEqual(applied(empty, backspaceEdit(empty, empty.length)), { text: '1. a\n  1. x\n2. ', caret: 15 })
    // A quotation set in is not a list: it steps out as it did.
    const quoted = 'a\n  > '
    assert.deepEqual(applied(quoted, returnEdit(quoted, quoted.length)), { text: 'a\n> ', caret: 4 })
  })
}
