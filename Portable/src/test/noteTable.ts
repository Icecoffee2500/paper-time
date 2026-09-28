/**
 * Tables in a note, as the Mac finds, reads and pastes them —
 * `note-tables.json` is the Mac's own `NoteTable` (`Scripts/note-tables-fixture.swift`).
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fromHTML, fromTabSeparated, parseTable, tableBlocks, tableMarkdown } from '../shared/noteTable.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Fixture {
  notes: { text: string; blocks: number[][]; markdown?: (string | null)[] }[]
  pastes: { html: string; markdown?: string }[]
  rows: { text: string; markdown?: string }[]
}

export async function noteTableSuite(test: Test, suite: (name: string) => void) {
  suite('Tables in a note, found and pasted as the Mac does')
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'note-tables.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture

  await test(`${fixture.notes.length} notes: the same tables in the same places`, () => {
    for (const note of fixture.notes) {
      const blocks = tableBlocks(note.text)
      assert.deepEqual(blocks.map((one) => [one.from, one.to]), note.blocks, note.text)
      blocks.forEach((block, index) => {
        const table = parseTable(note.text.slice(block.from, block.to))
        assert.equal(table ? tableMarkdown(table) : null, note.markdown?.[index] ?? null, note.text)
      })
    }
  })

  await test(`${fixture.pastes.length} pastes of HTML become the same Markdown`, () => {
    for (const paste of fixture.pastes) assert.equal(fromHTML(paste.html), paste.markdown ?? null, paste.html)
  })

  await test(`${fixture.rows.length} tab-separated pastes become the same table`, () => {
    for (const rows of fixture.rows) assert.equal(fromTabSeparated(rows.text), rows.markdown ?? null, JSON.stringify(rows.text))
  })
}
