/**
 * The drawing layer's geometry and its PDF copy, without a window (`WR6`):
 * handles, Shift's constraint, what a handle does to a box, a frame and a
 * group; whether a point touches a stroke; the card's line breaking; an
 * element's copy, byte for byte; and a frame and a group written into a PDF
 * as the boxes the Mac writes — not as lines.
 */
import assert from 'node:assert/strict'
import { PDFDocument, PDFName, PDFNumber, PDFArray, PDFDict } from 'pdf-lib'
import { SketchElement, SketchStyle, point } from '../shared/sketch.js'
import { SketchTree } from '../shared/sketchTree.js'
import { InkStroke } from '../shared/ink.js'
import { SketchColor } from '../shared/sketch.js'
import { BOX_HANDLES, constrained, handlePoint, pageRect, resized, strokeTouches, strokesBox } from '../shared/sketchGeometry.js'
import { wrap } from '../shared/sketchRender.js'
import { readDrawings, writeDrawings } from '../main/pdfwrite.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const box = (x: number, y: number, width: number, height: number, kind: 'rectangle' | 'frame' | 'group' | 'ellipse' = 'rectangle') =>
  new SketchElement({ kind, points: [point(x, y), point(x + width, y + height)] })

export async function sketchGeometrySuite(test: Test, suite: (name: string) => void) {
  suite('Drawing: geometry, copies, and the PDF copy of frames and groups')

  await test('the handles sit on the box, the top at its largest y', () => {
    const r = { x: 10, y: 20, width: 100, height: 50 }
    assert.deepEqual(handlePoint(r, 'topLeft'), { x: 10, y: 70 })
    assert.deepEqual(handlePoint(r, 'bottomRight'), { x: 110, y: 20 })
    assert.deepEqual(handlePoint(r, 'right'), { x: 110, y: 45 })
    assert.equal(BOX_HANDLES.length, 8)
    assert.deepEqual(pageRect([0, 9, 482, 699]), { x: 0, y: 9, width: 482, height: 690 })
  })

  await test('Shift keeps a box square and a line on an eighth of a turn', () => {
    assert.deepEqual(constrained({ x: 0, y: 0 }, { x: 30, y: -10 }, false), { x: 30, y: -30 })
    const line = constrained({ x: 0, y: 0 }, { x: 10, y: 9 }, true)
    assert.ok(Math.abs(line.x - line.y) < 1e-9, '45 degrees')
    assert.ok(Math.abs(Math.hypot(line.x, line.y) - Math.hypot(10, 9)) < 1e-9, 'at the length pulled')
  })

  await test('a corner handle resizes a box; a frame stops hugging; a group scales what is in it', () => {
    const rect = box(0, 0, 100, 100)
    const [grown] = resized(rect, 'topRight', { x: 150, y: 200 }, false, new SketchTree([rect]))
    assert.deepEqual(grown.rect, { x: 0, y: 0, width: 150, height: 200 })
    const frame = box(0, 0, 100, 100, 'frame')
    frame.layout = { direction: 'vertical', gap: 8, padding: 8, align: 'start', hugs: true }
    const child = box(10, 10, 20, 20)
    child.parent = frame.id
    const [resizedFrame, ...rest] = resized(frame, 'right', { x: 300, y: 50 }, false, new SketchTree([frame, child]))
    assert.equal(resizedFrame.layout?.hugs, false)
    assert.deepEqual(rest[0].rect, child.rect, 'the children stay where they are')
    const group = box(0, 0, 100, 100, 'group')
    const inner = box(50, 50, 50, 50)
    inner.parent = group.id
    const scaled = resized(group, 'topRight', { x: 200, y: 200 }, false, new SketchTree([group, inner]))
    // A group's box is its children's: here the one child, 50–100.
    assert.deepEqual(scaled.find((one) => one.id === inner.id)!.rect, { x: 50, y: 50, width: 150, height: 150 })
    const square = resized(rect, 'topRight', { x: 50, y: 120 }, true, new SketchTree([rect]))[0]
    assert.equal(square.rect.width, square.rect.height, 'Shift makes it square')
  })

  await test('a point touches a stroke near its line, not anywhere in its box', () => {
    const stroke = new InkStroke([{ x: 0, y: 0, w: 2 }, { x: 100, y: 100, w: 2 }], SketchColor.ink, 'pen')
    assert.ok(strokeTouches(stroke, { x: 0.5, y: 0.5 }, 2))
    assert.equal(strokeTouches(stroke, { x: 90, y: 10 }, 2), false)
    assert.deepEqual(strokesBox([stroke], [0, 5]), stroke.bounds, 'an index past the end is left out')
    assert.equal(strokesBox([stroke], []), null)
  })

  await test('a word wider than the card is broken wherever it falls on its line', () => {
    // One unit a character: a column of ten.
    const ctx = { measureText: (text: string) => ({ width: text.length }) } as never
    assert.deepEqual(wrap(ctx, 'hi abcdefghijklmnop', 10), ['hi ', 'abcdefghij', 'klmnop'])
    assert.deepEqual(wrap(ctx, 'abcdefghijklmnop ok', 10), ['abcdefghij', 'klmnop ok'])
    assert.deepEqual(wrap(ctx, 'one two three', 10), ['one two ', 'three'])
    assert.deepEqual(wrap(ctx, '', 10), [''])
  })

  await test("an element's copy writes the same bytes, and changing it leaves the original", () => {
    const raw = {
      id: 'A1', kind: 'rectangle', points: [[1, 2], [30, 40]], text: '카드',
      style: { stroke: { red: 1, green: 0, blue: 0, alpha: 1 }, width: 3, dash: 'dashed', fontSize: 22, textAlign: 'center', fontName: 'Pretendard' },
      createdAt: 811492215.409792, parent: 'F1', name: 'Box', clips: true,
      layout: { direction: 'horizontal', gap: 4, padding: 2, align: 'end', hugs: false },
      textSizing: 'autoWidth', futureField: { nested: [1, 2] },
    }
    const element = SketchElement.from(raw)
    const copy = element.copy()
    assert.deepEqual(JSON.parse(JSON.stringify(copy.encode())), JSON.parse(JSON.stringify(element.encode())))
    assert.equal(copy.encode().createdAt, 811492215.409792, "the file's own timestamp")
    copy.points[0].x = 999
    copy.layout!.gap = 99
    copy.style.width = 7
    assert.equal(element.points[0].x, 1)
    assert.equal(element.layout!.gap, 4)
    assert.equal(element.style.width, 3)
    const style = new SketchStyle()
    style.fill = SketchColor.paleYellow
    assert.deepEqual(style.copy().encode(), style.encode())
  })

  await test('a frame and a group go into the PDF as boxes — the group hidden — and come back', async () => {
    const made = await PDFDocument.create()
    made.addPage([612, 792])
    const bytes = await made.save({ useObjectStreams: false })
    const frame = box(50, 400, 200, 150, 'frame')
    frame.name = 'Frame 1'
    const inside = box(60, 410, 40, 40)
    inside.parent = frame.id
    const group = box(300, 300, 100, 100, 'group')
    const member = box(300, 300, 100, 100, 'ellipse')
    member.parent = group.id
    const card = new SketchElement({ kind: 'text', points: [point(100, 100), point(200, 130)], text: 'Hello' })
    card.style.fontSize = 22
    card.style.textAlign = 'right'
    card.style.fontName = 'Pretendard'
    const elements = SketchTree.normalized([frame, inside, group, member, card])
    const written = await writeDrawings(bytes, [{ pageIndex: 0, elements, strokes: [], managesMarks: false, managesInk: false }])
    const document = await PDFDocument.load(written, { updateMetadata: false })
    const annots = document.getPage(0).node.lookup(PDFName.of('Annots'), PDFArray)
    const dicts = annots.asArray().map((ref) => document.context.lookup(ref, PDFDict))
    const decoded = (value: unknown) => (value as { decodeText?: () => string } | undefined)?.decodeText?.() ?? String(value ?? '')
    const bySketch = (id: string) => dicts.find((dict) => decoded(dict.get(PDFName.of('PTSketchID'))) === id)!
    const subtype = (dict: PDFDict) => dict.get(PDFName.of('Subtype'))?.toString()
    assert.equal(subtype(bySketch(frame.id)), '/Square', 'a frame is a box, not a line')
    const ghost = bySketch(group.id)
    assert.equal(subtype(ghost), '/Square')
    assert.equal((ghost.get(PDFName.of('F')) as PDFNumber).asNumber(), 2, 'a group is hidden')
    assert.equal(ghost.get(PDFName.of('AP')), undefined, 'and draws nothing')
    const text = bySketch(card.id)
    assert.ok(decoded(text.get(PDFName.of('DA'))).includes('22 Tf'), "the card's own size")
    assert.equal((text.get(PDFName.of('Q')) as PDFNumber).asNumber(), 2, 'right-aligned')
    assert.ok(decoded(text.get(PDFName.of('DS'))).includes('Pretendard'), 'its family')
    const back = (await readDrawings(written)).get(0)!
    assert.deepEqual(back.elements.map((one) => one.kind).sort(), ['ellipse', 'frame', 'group', 'rectangle', 'text'])
    assert.equal(back.elements.find((one) => one.id === inside.id)?.parent, frame.id)
    // Saved again unchanged, nothing is added.
    const again = await writeDrawings(written, [{ pageIndex: 0, elements: back.elements, strokes: [], managesMarks: false, managesInk: false }])
    assert.equal(again.length, written.length, 'nothing to write')
  })
}
