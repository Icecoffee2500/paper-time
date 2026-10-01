/**
 * A note as it is shown while it is written, against the Mac: the runs
 * `NoteMarkdown.dump` printed for `Tests/PaperCoreTests/Fixtures/note-render.md`
 * (`Scripts/note-render-fixture.sh`), and the plan the editor draws from.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { displayRuns, inlineTokens, letters, noteLines, planNote, roman, shownMarker, type DisplayRun } from '../shared/noteMarkdown.js'
import { blockOf } from '../shared/noteBlocks.js'

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

  await test("a nested list's markers go round • ◦ ▪ and 1. a. i., as the Mac's do", () => {
    assert.equal(letters(1), 'a')
    assert.equal(letters(26), 'z')
    assert.equal(letters(27), 'aa')
    assert.equal(letters(28), 'ab')
    assert.equal(letters(52), 'az')
    assert.equal(letters(53), 'ba')
    assert.equal(letters(703), 'aaa')
    for (const [n, numeral] of [[1, 'i'], [2, 'ii'], [3, 'iii'], [4, 'iv'], [5, 'v'], [9, 'ix'], [14, 'xiv'], [40, 'xl'], [90, 'xc'], [400, 'cd'], [900, 'cm'], [1994, 'mcmxciv']] as [number, string][]) {
      assert.equal(roman(n), numeral)
    }
    const marker = (line: string) => shownMarker(blockOf(line))
    assert.equal(marker('- a'), '•\t')
    assert.equal(marker('  - a'), '◦\t')
    assert.equal(marker('    - a'), '▪\t')
    assert.equal(marker('      - a'), '•\t')
    assert.equal(marker('3. a'), '3.\t')
    assert.equal(marker('  3. a'), 'c.\t')
    assert.equal(marker('    4. a'), 'iv.\t')
    assert.equal(marker('      2. a'), '2.\t')
    assert.equal(marker('  - [x] a'), '☑\t')
    assert.equal(marker('  > a'), '\u200b')
  })
}
