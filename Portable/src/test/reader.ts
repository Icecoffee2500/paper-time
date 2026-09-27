/**
 * The reader's arithmetic and state machines, without a window (`WR5`):
 * the page math against pdf.js's own on real pages turned and cropped, the
 * spreads, the page under a height, destinations and outlines, the history a
 * link makes, what an open error was, which links may leave the app, the
 * found places, the marks under a point — and the thumbnail queue. And that
 * the files pdf.js asks the window for were built beside it.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { PDFDocument, degrees } from 'pdf-lib'
import '../main/pdfjsQuiet.js'
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs'
// @ts-expect-error -- the worker ships without declarations
import * as pdfjsWorker from 'pdfjs-dist/legacy/build/pdf.worker.mjs'
import {
  applyInverseTransform,
  applyTransform,
  classifyOpenError,
  destinationTop,
  flattenOutline,
  formatError,
  isOpenableLink,
  pageAtOffset,
  fitScale,
  pageViewport,
  shownPages,
  spreadStart,
  turnedTo,
} from '../shared/readerMath.js'
import { foldWithMap, occurrences } from '../shared/textFold.js'
import { DocumentHistory, scrollFor } from '../renderer/ui/readerHistory.js'
import { markAt, marksInReadingOrder } from '../renderer/ui/readerMarks.js'
import { ThumbnailQueue } from '../renderer/ui/pageThumbnails.js'
import type { Mark } from '../shared/marks.js'

;(globalThis as unknown as { pdfjsWorker: unknown }).pdfjsWorker = pdfjsWorker

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const close = (a: number, b: number) => Math.abs(a - b) < 1e-9

export async function readerSuite(test: Test, suite: (name: string) => void) {
  suite('The reader: page math, spreads, history, links, marks')

  await test('a page is laid out the way pdf.js lays it out, turned and cropped', async () => {
    const made = await PDFDocument.create()
    const shapes: { size: [number, number]; crop?: [number, number, number, number]; turn: number }[] = [
      { size: [612, 792], turn: 0 },
      { size: [595, 842], crop: [20, 30, 500, 700], turn: 90 },
      { size: [792, 612], turn: 180 },
      { size: [400, 600], crop: [-10, 5, 390, 610], turn: 270 },
    ]
    for (const shape of shapes) {
      const page = made.addPage(shape.size)
      if (shape.crop) page.setCropBox(...shape.crop)
      page.setRotation(degrees(shape.turn))
    }
    const bytes = await made.save()
    const document = await pdfjs.getDocument({ data: bytes, useWorkerFetch: false, isEvalSupported: false }).promise
    try {
      for (let index = 1; index <= shapes.length; index += 1) {
        const proxy = await document.getPage(index)
        for (const scale of [1, 1.37, 2.5]) {
          const theirs = proxy.getViewport({ scale })
          const ours = pageViewport({ view: proxy.view as number[], rotate: proxy.rotate, userUnit: 1 }, scale)
          assert.ok(close(ours.width, theirs.width) && close(ours.height, theirs.height), `page ${index} size at ${scale}`)
          ours.transform.forEach((value, at) => assert.ok(close(value, (theirs.transform as number[])[at]), `page ${index} transform[${at}]`))
          const [vx, vy] = theirs.convertToViewportPoint(100, 200)
          const view = applyTransform(ours.transform, 100, 200)
          assert.ok(close(view.x, vx) && close(view.y, vy))
          const back = applyInverseTransform(ours.transform, view.x, view.y)
          assert.ok(close(back.x, 100) && close(back.y, 200), 'and back again')
        }
      }
    } finally {
      await document.destroy()
    }
  })

  await test('a book shows its pages two by two, the first page with the second', () => {
    assert.equal(spreadStart('book', 5), 4)
    assert.equal(spreadStart('single', 5), 5)
    assert.deepEqual(shownPages('book', 3, 10), [2, 3])
    assert.deepEqual(shownPages('book', 9, 9), [8], 'an odd last page stands alone')
    assert.deepEqual(shownPages('single', 4, 10), [4])
    assert.equal(shownPages('continuous', 4, 10), null)
    assert.deepEqual(shownPages('single', 0, 0), [])
  })

  await test('turning stops at either end, and an empty paper does not turn at all', () => {
    assert.equal(turnedTo('book', 0, 1, 10), 2)
    assert.equal(turnedTo('book', 9, 1, 10), null)
    assert.equal(turnedTo('single', 0, -1, 10), null)
    assert.equal(turnedTo('continuous', 3, 1, 10), 4)
    assert.equal(turnedTo('single', 0, 1, 0), null, 'no page −1')
    assert.equal(turnedTo('continuous', 0, 1, 0), null)
  })

  await test('a page fits the column; a book fits its spread to the height as well', () => {
    const letter = { width: 612, height: 792 }
    assert.ok(Math.abs(fitScale(letter, { width: 652, height: 400 }, 'continuous', 24) - 1) < 1e-9, 'the width, whatever the height')
    const wide = fitScale(letter, { width: 3000, height: 832 }, 'book', 24)
    assert.ok(Math.abs(wide - 1) < 1e-9, 'a wide window: the height decides')
    const narrow = fitScale(letter, { width: 1288, height: 5000 }, 'book', 24)
    assert.ok(Math.abs(narrow - 1) < 1e-9, 'a tall window: two pages and the gutter across')
  })

  await test('the page under a height is found by halving the tops', () => {
    const tops = [0, 800, 1600, 2400]
    assert.equal(pageAtOffset(tops, -5), 0)
    assert.equal(pageAtOffset(tops, 0), 0)
    assert.equal(pageAtOffset(tops, 799), 0)
    assert.equal(pageAtOffset(tops, 800), 1)
    assert.equal(pageAtOffset(tops, 9999), 3)
    assert.equal(pageAtOffset([], 10), 0)
  })

  await test('a destination says how far down its page, when it says', () => {
    assert.equal(destinationTop('XYZ', [72, 700, 0]), 700)
    assert.equal(destinationTop('FitH', [650]), 650)
    assert.equal(destinationTop('FitBH', [640]), 640)
    assert.equal(destinationTop('FitR', [10, 20, 300, 500]), 500)
    assert.equal(destinationTop('Fit', []), null)
    assert.equal(destinationTop('XYZ', [72, null, 0]), null)
  })

  await test('an outline is flattened in reading order, untitled headings dropped', () => {
    const flat = flattenOutline([
      { title: '1  Introduction', dest: 'a', items: [{ title: ' 1.1\nMotivation ', dest: 'b' }, { title: '   ', dest: 'x' }] },
      { title: '2 Method', dest: 'c' },
    ])
    assert.deepEqual(flat.map((one) => [one.title, one.depth, one.dest]), [
      ['1 Introduction', 0, 'a'], ['1.1 Motivation', 1, 'b'], ['2 Method', 0, 'c'],
    ])
    assert.deepEqual(flattenOutline(null), [])
  })

  await test('Back after a link is the place it came from; a new jump forgets what lay ahead', () => {
    const history = new DocumentHistory()
    const at = (page: number) => ({ page, top: page * 100, of: 1000 })
    history.leave(at(1))
    history.leave(at(5))
    assert.deepEqual(history.goBack(at(9)), at(5))
    assert.ok(history.canGoForward)
    history.leave(at(3))
    assert.equal(history.canGoForward, false)
    assert.deepEqual(history.goBack(at(4)), at(3))
    assert.deepEqual(history.goForward(at(3)), at(4))
    assert.equal(scrollFor({ top: 500, of: 1000 }, 2000), 1000, 'by fraction when the paper changed height')
    assert.equal(scrollFor({ top: 500, of: 1000 }, 1000.5), 500, 'by the pixel when it did not')
  })

  await test('an open error is told by its name before its words', () => {
    assert.equal(classifyOpenError({ name: 'PasswordException', message: 'No password given' }), 'password')
    assert.equal(classifyOpenError(Object.assign(new Error('password needed'), { name: 'NeedsPassword' })), 'password')
    assert.equal(classifyOpenError(new Error('Unknown crypto method')), 'rights')
    assert.equal(classifyOpenError({ name: 'InvalidPDFException', message: 'Invalid PDF structure.' }), 'other')
    assert.equal(formatError({ name: 'InvalidPDFException', message: 'Invalid PDF structure.' }), 'InvalidPDFException: Invalid PDF structure.')
    assert.equal(formatError(new Error('plain')), 'plain')
    assert.notEqual(formatError({ code: 3 }), '[object Object]')
  })

  await test('only the web and mail leave the app from a link in a paper', () => {
    assert.ok(isOpenableLink('https://arxiv.org/abs/2301.00001'))
    assert.ok(isOpenableLink('HTTP://example.com'))
    assert.ok(isOpenableLink('mailto:author@example.edu'))
    for (const url of ['file:///etc/passwd', 'javascript:alert(1)', 'smb://share/x', 'zotero://select']) {
      assert.equal(isOpenableLink(url), false, url)
    }
  })

  await test('every place a word is found, the same way for the find bar and a passage', () => {
    const text = 'Unlearning, and re-\nlearning: LEARNING.'
    const folded = foldWithMap(text)
    const found = occurrences(text, folded, 'learning')
    assert.equal(found.length, 3)
    assert.equal(text.slice(found[0].start, found[0].end).toLowerCase(), 'learning')
    assert.equal(text.slice(found[2].start, found[2].end), 'LEARNING')
    assert.deepEqual(occurrences(text, folded, ''), [])
    for (const range of found) assert.ok(range.end > range.start, 'never empty')
  })

  await test('the mark under a point is the topmost; marks are listed top to bottom', () => {
    const mark = (id: string, x: number, top: number): Mark => ({
      id, kind: 'highlight', color: [1, 1, 0], text: id,
      quads: [[x, top, x + 100, top, x, top - 10, x + 100, top - 10]],
    })
    const marks = [mark('low', 50, 400), mark('high', 50, 700), mark('over', 60, 700)]
    assert.equal(markAt(marks, { x: 70, y: 695 })?.id, 'over')
    assert.equal(markAt(marks, { x: 55, y: 695 })?.id, 'high')
    assert.equal(markAt(marks, { x: 10, y: 10 }), null)
    const order = marksInReadingOrder([{ index: 0, marks }, { index: 1, marks: [mark('next', 0, 100)] }])
    assert.deepEqual(order.map((one) => one.mark.id), ['high', 'over', 'low', 'next'])
  })

  await test('thumbnails are drawn two at a time, kept, and let go of when the grid closes', async () => {
    const queue = new ThumbnailQueue()
    let running = 0
    let most = 0
    const releases: (() => void)[] = []
    const make = () => new Promise<HTMLCanvasElement | null>((resolve) => {
      running += 1
      most = Math.max(most, running)
      releases.push(() => {
        running -= 1
        resolve({} as HTMLCanvasElement)
      })
    })
    const asked = [0, 1, 2, 3, 4].map((index) => queue.draw(`p:${index}:132`, make))
    assert.equal(queue.pending.running, 2)
    assert.equal(queue.pending.waiting, 3)
    queue.cancel()
    assert.equal(await asked[4], null, 'what was waiting is let go of')
    releases.splice(0).forEach((release) => release())
    await Promise.all(asked.slice(0, 2))
    assert.equal(most, 2)
    const again = await queue.draw('p:0:132', make)
    assert.ok(again, 'kept')
    assert.equal(releases.length, 0, 'nothing drawn again')
  })

  await test('the character maps and standard fonts pdf.js asks the window for are built beside it', () => {
    const renderer = path.resolve(__dirname, '../renderer')
    assert.ok(fs.readdirSync(path.join(renderer, 'cmaps')).some((name) => name.startsWith('Adobe-Korea1')), 'Korean character maps')
    assert.ok(fs.readdirSync(path.join(renderer, 'standard_fonts')).some((name) => name.endsWith('.pfb') || name.endsWith('.ttf')), 'standard fonts')
    assert.ok(fs.existsSync(path.join(renderer, 'pdf.worker.js')), 'the worker')
  })
}
