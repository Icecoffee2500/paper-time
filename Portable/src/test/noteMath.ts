/**
 * Where a note's mathematics is — `PaperCoreTests/NoteMathTests.swift`,
 * test for test, so the card under a formula answers the same on every
 * desktop.
 */
import assert from 'node:assert/strict'
import { mathBlocks, mathSpanAt } from '../shared/noteMath.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function noteMathSuite(test: Test, suite: (name: string) => void) {
  suite('Where the mathematics is in a note')

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
