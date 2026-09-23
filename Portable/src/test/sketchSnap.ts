/**
 * Lining a drag up — `InkEngineTests/SketchSnapTests.swift`, test for test.
 *
 * The same boxes and the same numbers as the Mac's suite, so the two sides are
 * held to one answer: a card dragged near another lands on the same point on
 * either desktop.
 */
import assert from 'node:assert/strict'
import { SketchSnap } from '../shared/sketchSnap.js'
import type { Rect } from '../shared/sketch.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

export async function sketchSnapSuite(test: Test, suite: (name: string) => void) {
  suite('Lining a drag up')

  const a: Rect = { x: 100, y: 100, width: 80, height: 40 }

  await test('a drag that lands near an edge gives up the last few points', () => {
    // Moving a box to x = 203 when something's left edge is at 200.
    const other: Rect = { x: 200, y: 400, width: 80, height: 40 }
    const result = SketchSnap.adjust(a, { x: 103, y: 0 }, [other])
    assert.equal(result.offset.x, 100)
    assert.ok(result.guides.some((guide) => guide.axis === 'vertical' && guide.position === 200))
  })

  await test('a middle lines up as an edge does', () => {
    // Two boxes of the same width, so a left edge on a left edge is also a
    // middle on a middle: already lined up, and it says so rather than
    // nudging anything.
    const other: Rect = { x: 200, y: 400, width: 80, height: 40 }
    const result = SketchSnap.adjust(a, { x: 100, y: 0 }, [other])
    assert.equal(result.offset.x, 100, 'already lined up; nothing to give')
    assert.ok(result.guides.some((guide) => guide.axis === 'vertical'))

    // And a middle on its own: a narrower box whose centre is where ours
    // would land, with neither edge anywhere near.
    const narrow: Rect = { x: 230, y: 400, width: 20, height: 40 }
    const byMiddle = SketchSnap.adjust(a, { x: 97, y: 0 }, [narrow])
    assert.equal(byMiddle.offset.x, 100, '240 is the middle of both')
    assert.ok(byMiddle.guides.some((guide) => guide.axis === 'vertical' && guide.position === 240))
  })

  await test('too far away is left alone', () => {
    const other: Rect = { x: 400, y: 400, width: 80, height: 40 }
    const result = SketchSnap.adjust(a, { x: 37, y: 11 }, [other])
    assert.deepEqual(result.offset, { x: 37, y: 11 })
    assert.equal(result.guides.length, 0)
  })

  await test('each axis answers for itself', () => {
    // Near on x, nowhere near on y.
    const other: Rect = { x: 200, y: 900, width: 80, height: 40 }
    const result = SketchSnap.adjust(a, { x: 103, y: 50 }, [other])
    assert.equal(result.offset.x, 100)
    assert.equal(result.offset.y, 50)
    assert.equal(result.guides.length, 1)
  })

  await test('the page is something to line up by', () => {
    const page: Rect = { x: 0, y: 0, width: 612, height: 792 }
    // The box's middle lands at 302; the page's middle is 306.
    const result = SketchSnap.adjust(a, { x: 162, y: 0 }, [], page)
    assert.equal(result.offset.x, 166)
    assert.ok(result.guides.some((guide) => guide.axis === 'vertical' && guide.position === 306))
  })

  await test('a guide reaches both boxes', () => {
    const other: Rect = { x: 200, y: 400, width: 80, height: 40 }
    const result = SketchSnap.adjust(a, { x: 103, y: 0 }, [other])
    const guide = result.guides.find((one) => one.axis === 'vertical')
    assert.ok(guide, 'no vertical guide')
    assert.equal(guide.from, 100)
    assert.equal(guide.to, 440)
  })

  await test('nothing to line up against changes nothing', () => {
    const result = SketchSnap.adjust(a, { x: 13, y: 7 }, [])
    assert.deepEqual(result.offset, { x: 13, y: 7 })
  })
}
