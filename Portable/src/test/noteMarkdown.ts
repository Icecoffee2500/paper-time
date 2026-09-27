/**
 * A note as it is shown while it is written, against the Mac: the runs
 * `NoteMarkdown.dump` printed for `Tests/PaperCoreTests/Fixtures/note-render.md`
 * (`Scripts/note-render-fixture.sh`), and the plan the editor draws from.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { displayRuns, inlineTokens, noteLines, planNote, type DisplayRun } from '../shared/noteMarkdown.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const FIXTURE = path.resolve(process.cwd(), '..', 'Tests', 'PaperCoreTests', 'Fixtures', 'note-render.json')

/** Runs whose printed marks are the same, joined — the Mac splits where attributes the dump does not print differ. */
function joined(runs: DisplayRun[]): DisplayRun[] {
  const out: DisplayRun[] = []
  for (const run of runs) {
    const last = out[out.length - 1]
    if (last && last.marks === run.marks) last.text += run.text
    else if (run.text) out.push({ text: run.text, marks: run.marks })
  }
  return out
}

export async function noteMarkdownSuite(test: Test, suite: (name: string) => void) {
  suite('A note shown as it is written, as the Mac shows it')

  await test("every run of the Mac's rendering, with its marks", () => {
    const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8')) as { markdown: string; length: number; runs: DisplayRun[] }
    const mine = displayRuns(fixture.markdown)
    const theirs = joined(fixture.runs)
    assert.equal(mine.map((run) => run.text).join('').length, fixture.length, 'the same number of characters shown')
    assert.deepEqual(mine, theirs)
  })

  await test('the caret line is shown as written; the others are set', () => {
    const source = '# Title\n- **bold** item'
    const set = planNote(source)
    assert.equal(set[1].tokens.length, 1)
    const editing = planNote(source, source.length)
    assert.equal(editing[1].revealed, true)
    assert.equal(editing[1].tokens.length, 0, 'no pieces on the line under the caret')
    assert.equal(editing[0].revealed, false)
  })

  await test('a $$ block across lines is one line; the shorter of two pieces at one bracket wins', () => {
    assert.deepEqual(noteLines('a\n$$\nx\n$$\nb').map((one) => [one.from, one.to]), [[0, 1], [2, 9], [10, 11]])
    const tokens = inlineTokens('[[a|b]] then [c](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)')
    assert.deepEqual(tokens.map((one) => one.kind), ['note', 'anchor'])
  })
}
