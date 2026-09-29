/**
 * Where a note's mathematics is — `PaperCoreTests/NoteMathTests.swift`,
 * test for test, so the card under a formula answers the same on every
 * desktop.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { displayFormulas, firstFormula, isDisplayLine, mathBlocks, mathSpanAt, type MathSpan } from '../shared/noteMath.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface FixtureSpan { from: number; to: number; latex: string; display: boolean; isBlock: boolean }
interface Fixture {
  notes: {
    text: string
    blocks: number[][]
    lines: { from: number; to: number; formulas: FixtureSpan[]; displays: number[][]; isDisplay: boolean }[]
    spans: (FixtureSpan | null)[]
  }[]
}

const flat = (span: MathSpan | null): FixtureSpan | null => span
  ? { from: span.range.from, to: span.range.to, latex: span.latex, display: span.display, isBlock: span.isBlock }
  : null

export async function noteMathSuite(test: Test, suite: (name: string) => void) {
  suite('Where the mathematics is in a note')

  // The Mac's own answers (`Scripts/note-math-fixture.swift`).
  const file = path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures', 'note-math.json')
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8')) as Fixture
  await test(`${fixture.notes.length} notes: the same formulas, blocks and spans as the Mac`, () => {
    for (const note of fixture.notes) {
      assert.deepEqual(mathBlocks(note.text).map((one) => [one.from, one.to]), note.blocks, note.text)
      for (const line of note.lines) {
        const text = note.text.slice(line.from, line.to)
        const found: FixtureSpan[] = []
        let index = 0
        for (let one = firstFormula(text, index); one && index < text.length; one = firstFormula(text, index)) {
          found.push(flat(one)!)
          index = one.range.from + Math.max(one.range.to - one.range.from, 1)
        }
        assert.deepEqual(found, line.formulas, text)
        assert.deepEqual(displayFormulas(text).map((one) => [one.from, one.to]), line.displays, text)
        assert.equal(isDisplayLine(text), line.isDisplay, text)
      }
      note.spans.forEach((expected, caret) => {
        assert.deepEqual(flat(mathSpanAt(note.text, caret)), expected, `${JSON.stringify(note.text)} at ${caret}`)
      })
    }
  })

  const range = (text: string, piece: string) => {
    const from = text.indexOf(piece)
    return { from, to: from + piece.length }
  }

  await test('a formula on its own lines is one block', () => {
    const text = 'before\n$$\n\\frac{a}{b}\n$$\nafter'
    assert.deepEqual(mathBlocks(text), [range(text, '$$\n\\frac{a}{b}\n$$')])
  })

  await test('a block may hold several lines', () => {
    const text = '$$\n\\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned}\n$$'
    assert.deepEqual(mathBlocks(text), [{ from: 0, to: text.length }])
  })

  await test('a display formula on one line is not a block', () => {
    assert.deepEqual(mathBlocks('$$\\frac{a}{b}$$'), [])
    assert.deepEqual(mathBlocks('x $$a$$ y\n$$b$$'), [])
  })

  await test('an opener nothing closes is not a block', () => {
    assert.deepEqual(mathBlocks('$$\n\\frac{a}{b}\nprose'), [])
  })

  await test('the opener and closer may carry latex', () => {
    const text = '$$ a +\nb $$\nrest'
    assert.deepEqual(mathBlocks(text), [range(text, '$$ a +\nb $$')])
  })

  await test('two blocks are two', () => {
    assert.equal(mathBlocks('$$\na\n$$\n\n$$\nb\n$$').length, 2)
  })

  await test('a caret inside inline math finds it', () => {
    const text = 'the mean $\\bar{x}$ is'
    const caret = text.indexOf('\\bar') + 2
    assert.deepEqual(mathSpanAt(text, caret), {
      range: range(text, '$\\bar{x}$'), latex: '\\bar{x}', display: false, isBlock: false,
    })
  })

  await test('a caret outside the delimiters is not inside', () => {
    const text = 'a $x$ b'
    assert.equal(mathSpanAt(text, 2), null)
    assert.notEqual(mathSpanAt(text, 3), null)
    assert.notEqual(mathSpanAt(text, 4), null)
    assert.equal(mathSpanAt(text, 5), null)
    assert.equal(mathSpanAt('plain', 0), null)
  })

  await test('a caret in display math on one line', () => {
    const span = mathSpanAt('$$\\frac{a}{b}$$', 5)
    assert.equal(span?.display, true)
    assert.equal(span?.isBlock, false)
    assert.equal(span?.latex, '\\frac{a}{b}')
  })

  await test('a caret inside a block finds the whole block', () => {
    const text = 'p\n$$\n\\frac{a}{b}\n$$\nq'
    const span = mathSpanAt(text, text.indexOf('{b}'))
    assert.deepEqual(span, {
      range: range(text, '$$\n\\frac{a}{b}\n$$'), latex: '\\frac{a}{b}', display: true, isBlock: true,
    })
    assert.equal(mathSpanAt(text, text.indexOf('\n$$\nq') + 1)?.isBlock, true)
    assert.equal(mathSpanAt(text, text.indexOf('q')), null)
  })

  await test('an empty formula has no span', () => {
    assert.equal(mathSpanAt('$$', 1), null)
  })

  await test('offsets are UTF-16', () => {
    const text = '평균 $\\mu$ 예요'
    assert.equal(mathSpanAt(text, text.indexOf('\\mu') + 1)?.latex, '\\mu')
  })
}
