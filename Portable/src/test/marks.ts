/**
 * Text marks (`WR10`): another reader's marks named as the Mac names them and
 * taken into this app's care on the first change, the Mac's drawing numbers,
 * one nearest colour, the quotation kept through a reconcile, and the
 * journal written from the window's own change.
 */
import assert from 'node:assert/strict'
import { PDFDocument, PDFHexString, type PDFContext, type PDFRef } from 'pdf-lib'
import { derivedMarkID, uuidFromSeed } from '../shared/markIds.js'
import { MARK_COLORS, markLine, nearestColorName, rectToQuad, type Mark } from '../shared/marks.js'
import { reconcile, recordChanges, type Journal } from '../shared/markJournal.js'
import { readMarks, writeDrawings } from '../main/pdfwrite.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

/** What Swift's `TextMarkupWriter.uuid(from:)` gives for these seeds
 *  (`scratchpad/wr10uuid.swift`, the Mac's code as it stands). */
const SWIFT_UUIDS: [string, string][] = [
  ['Highlight|0|72|700|200|12', 'CA947990-67F5-4DF2-9D65-4C15DC9255F1'],
  ['Underline|3|-5|0|1|1', '0B63330A-49F3-4678-B075-EBDE7400289B'],
  ['StrikeOut|12|100|200|300|14', '0045F6E1-E82B-4925-AC80-E926A5534CF2'],
  ['Highlight|0|73|701|201|13', 'BFBF33B0-81F4-4214-9DB4-EF662BEF6191'],
  ['형광펜|1|2|3|4|5', 'C02D73CB-45E5-4856-BA83-F970DB89DD71'],
]

function annotation(context: PDFContext, fields: Record<string, unknown>): PDFRef {
  return context.register(context.obj({ Type: 'Annot', F: 4, ...fields } as never))
}

/** One page with one highlight Preview made: no identifier of ours. */
async function previewHighlight(): Promise<Uint8Array> {
  const document = await PDFDocument.create()
  const page = document.addPage([612, 792])
  const context = document.context
  const mark = annotation(context, {
    Subtype: 'Highlight',
    Rect: [72.4, 400, 300, 412.5],
    QuadPoints: rectToQuad({ x: 72.4, y: 400, width: 227.6, height: 12.5 }),
    C: [0.45, 0.83, 0.51],
    Contents: PDFHexString.fromText('the words'),
  })
  page.node.set(context.obj('Annots') as never, context.obj([mark]))
  page.node.set(document.context.obj('Annots') as never, context.obj([mark]))
  return document.save({ useObjectStreams: false })
}

function journal(): Journal {
  return { device: 'test', entries: {}, updated: '2026-01-01T00:00:00Z' } as unknown as Journal
}

export async function marksSuite(test: Test, suite: (name: string) => void) {
  suite('Text marks')

  await test('another reader’s mark goes by the identifier the Mac derives', async () => {
    for (const [seed, expected] of SWIFT_UUIDS) assert.equal(uuidFromSeed(seed), expected, seed)
    // Rounded as Swift rounds: half away from zero.
    assert.equal(derivedMarkID('Underline', 3, { x: -4.5, y: 0.4, width: 1.2, height: 0.5 }), SWIFT_UUIDS[1][1])
    const marks = (await readMarks(await previewHighlight())).get(0) ?? []
    assert.equal(marks.length, 1)
    assert.equal(marks[0].foreign, true)
    assert.equal(marks[0].id, derivedMarkID('Highlight', 0, { x: 72.4, y: 400, width: 227.6, height: 12.5 }))
    assert.equal(marks[0].text, 'the words')
  })

  await test('recoloured here, it becomes ours under the same name; removed, it goes', async () => {
    const bytes = await previewHighlight()
    const [found] = (await readMarks(bytes)).get(0)!
    const recoloured: Mark = { ...found, foreign: undefined, color: [...MARK_COLORS.pink] as [number, number, number] }
    delete recoloured.foreign
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [recoloured], foreignComplete: true, managesMarks: true, managesSketch: false, managesInk: false,
    }])
    const after = (await readMarks(written)).get(0) ?? []
    assert.equal(after.length, 1, 'the original is gone, not beside ours')
    assert.equal(after[0].id, found.id)
    assert.equal(after[0].foreign, undefined, 'it carries our identifier now')
    assert.equal(nearestColorName(after[0].color), 'pink')
    // Left alone, a foreign mark is left alone — the same bytes.
    const untouched = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [found], foreignComplete: true, managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.equal(untouched, bytes)
    // Taken off (the journal said so): out of the file.
    const removed = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [], foreignComplete: true, managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.equal(((await readMarks(removed)).get(0) ?? []).length, 0)
    // Without the whole list, nobody else's mark is ever taken out.
    const cautious = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [], managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.equal(((await readMarks(cautious)).get(0) ?? []).length, 1)
  })

  await test('the journal names a foreign mark only once it is changed', () => {
    const foreign: Mark = { id: 'CA947990-67F5-4DF2-9D65-4C15DC9255F1', kind: 'highlight', quads: [rectToQuad({ x: 0, y: 0, width: 10, height: 10 })], color: [1, 0.84, 0.25], text: 'x', foreign: true }
    const own = journal()
    assert.equal(recordChanges(own, 0, [], [foreign], new Date()), false, 'seen is not changed')
    const recoloured = { ...foreign, color: [...MARK_COLORS.blue] as [number, number, number] }
    assert.equal(recordChanges(own, 0, [foreign], [recoloured], new Date()), true)
    assert.equal(own.entries[foreign.id].descriptor?.color, 'blue')
    assert.equal(recordChanges(own, 0, [recoloured], [], new Date()), true)
    assert.equal(own.entries[foreign.id].descriptor, null, 'a removal, under the name the Mac knows')
  })

  await test('a reconcile keeps the quotation the journal knows', () => {
    const quad = rectToQuad({ x: 10, y: 10, width: 100, height: 12 })
    const fromFile: Mark = { id: 'ABC', kind: 'highlight', quads: [quad], color: [1, 0.84, 0.25], text: '', comment: 'why' }
    const words = new Map([['ABC', { device: 'mac', entry: { at: '2026-01-01T00:00:00Z', descriptor: {
      color: 'yellow', comment: 'why', createdAt: '2026-01-01T00:00:00Z', id: 'ABC', kind: 'highlight', pageIndex: 0,
      quotedText: 'the quoted words', rects: [[[10, 10], [100, 12]]],
    } } }]]) as never
    const { pages, dirty } = reconcile(new Map([[0, [fromFile]]]), words)
    assert.equal(pages.get(0)![0].text, 'the quoted words')
    assert.equal(dirty.size, 0)
  })

  await test('a mark is drawn with the Mac’s numbers (`RoundedMarks`)', () => {
    const rect = { x: 0, y: 0, width: 100, height: 20 }
    const band = markLine('highlight', [1, 0.5, 0], rect)
    assert.ok('band' in band)
    if ('band' in band) {
      assert.equal(band.radius, 3.5, 'at most three and a half points')
      assert.deepEqual(band.fill.map((v) => +v.toFixed(3)), [1, 0.675, 0.35], 'a third of the way to white')
      assert.equal(band.edge, null)
    }
    const small = markLine('highlight', [1, 1, 1], { x: 0, y: 0, width: 10, height: 5 })
    if ('band' in small) assert.equal(small.radius, 1.5)
    const hovered = markLine('highlight', [1, 0.5, 0], rect, true)
    if ('band' in hovered) {
      assert.deepEqual(hovered.fill.map((v) => +v.toFixed(3)), [1, 0.775, 0.55])
      assert.ok(hovered.edge)
    }
    const under = markLine('underline', [1, 0.5, 0], rect)
    assert.ok('width' in under)
    if ('width' in under) {
      assert.ok(Math.abs(under.width - 1.7) < 1e-9)
      assert.ok(Math.abs(under.from.y - 0.85) < 1e-9, 'at the foot of the words')
      assert.deepEqual(under.ink.map((v) => +v.toFixed(3)), [0.7, 0.35, 0])
    }
    const strike = markLine('strikethrough', [1, 0.5, 0], rect)
    if ('width' in strike) assert.equal(strike.from.y, 10, 'through the middle')
    const thin = markLine('underline', [0, 0, 0], { x: 0, y: 0, width: 10, height: 4 })
    if ('width' in thin) assert.equal(thin.width, 1, 'never under a point')
  })

  await test('one nearest colour: a grey is called yellow everywhere', () => {
    assert.equal(nearestColorName([0.5, 0.5, 0.5]), 'yellow')
    assert.equal(nearestColorName([0, 0, 0]), 'yellow')
    assert.equal(nearestColorName([0.4, 0.7, 1]), 'blue')
    assert.equal(nearestColorName([1, 0.55, 0.65]), 'pink')
  })
}
