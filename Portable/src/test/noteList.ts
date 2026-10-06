/**
 * Numbered lists counted, and items moved in and out, as the Mac does it —
 * `note-lists.json` is the Mac's own `NoteList`
 * (`Scripts/note-lists-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { backspaceAt, deleteForwardAt, listNumbers, newLine, shiftItem, shiftSelection, shortcutAt, type ListEdit } from '../shared/noteList.js'
import { indentEdit, returnEdit, backspaceEdit } from '../shared/noteBlocks.js'
import { planNote } from '../shared/noteMarkdown.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Written { range: [number, number]; replacement: string; caret: number; length?: number; after: string }
interface Keyed { note: string; caret: number; edit: Written | null }
interface Fixture {
  numbers: { note: string; numbers: [number, number][] }[]
  shifts: (Keyed & { by: 1 | -1; length?: number })[]
  returns: (Keyed & { folded?: boolean })[]
  backspaces: Keyed[]
  deletes: Keyed[]
  shortcuts: Keyed[]
}

/** That an edit is the one the Mac wrote down — what it replaces, with what, where the caret and the selection go. */
function same(edit: ListEdit | null, item: Keyed) {
  const label = JSON.stringify(item.note.slice(0, item.caret) + '|' + item.note.slice(item.caret))
  if (!item.edit) {
    assert.equal(edit, null, label)
    return
  }
  assert.ok(edit, label)
  assert.deepEqual([edit.from, edit.to - edit.from], item.edit.range, label)
  assert.equal(edit.insert, item.edit.replacement, label)
  assert.equal(edit.caret, item.edit.caret, label)
  assert.equal(edit.length ?? 0, item.edit.length ?? 0, label)
  assert.equal(item.note.slice(0, edit.from) + edit.insert + item.note.slice(edit.to), item.edit.after, label)
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

  await test(`${fixture.shifts.length} moves: Tab and ⇧Tab make the Mac's edit, one item or a selection of them`, () => {
    for (const item of fixture.shifts) {
      const edit = item.length ? shiftSelection(item.note, item.caret, item.caret + item.length, item.by) : shiftItem(item.note, item.caret, item.by)
      same(edit, item)
    }
  })

  await test(`${fixture.returns.length} Returns make the Mac's edit — the next item, the end of a list, a step out`, () => {
    for (const item of fixture.returns) same(newLine(item.note, item.caret, item.folded ?? false), item)
  })

  await test(`${fixture.backspaces.length} Backspaces at a marker's edge make the Mac's edit`, () => {
    for (const item of fixture.backspaces) same(backspaceAt(item.note, item.caret), item)
  })

  await test(`${fixture.deletes.length} Deletes before a marked line make the Mac's edit`, () => {
    for (const item of fixture.deletes) same(deleteForwardAt(item.note, item.caret), item)
  })

  await test(`${fixture.shortcuts.length} spaces after «[]» and «--» make the Mac's edit`, () => {
    for (const item of fixture.shortcuts) same(shortcutAt(item.note, item.caret), item)
  })

  await test('the marker shows the number the item stands at — «a.» for the first one moved in', () => {
    const note = '1. original\n  2. the whole\n  3. the retain\n2. next'
    assert.deepEqual(planNote(note).map((line) => line.shownMarker), ['1.\t', 'a.\t', 'b.\t', '2.\t'])
  })

  await test('Tab, Return on an empty item and Backspace move an item the same way', () => {
    const applied = (text: string, edit: { from: number; to: number; insert: string; caret: number } | null) =>
      edit ? { text: text.slice(0, edit.from) + edit.insert + text.slice(edit.to), caret: edit.caret } : null
    const typed = '1. original\n2. the whole'
    assert.deepEqual(applied(typed, indentEdit(typed, typed.length, typed.length, 1)), { text: '1. original\n  1. the whole', caret: 26 })
    const empty = '1. a\n  1. x\n  2. '
    assert.deepEqual(applied(empty, returnEdit(empty, empty.length)), { text: '1. a\n  1. x\n2. ', caret: 15 })
    assert.deepEqual(applied(empty, backspaceEdit(empty, empty.length)), { text: '1. a\n  1. x\n2. ', caret: 15 })
    // A quotation set in is not a list: it steps out as it did.
    const quoted = 'a\n  > '
    assert.deepEqual(applied(quoted, returnEdit(quoted, quoted.length)), { text: 'a\n> ', caret: 4 })
  })
}
