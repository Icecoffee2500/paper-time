/**
 * The tests that matter for a port: does this write what the other side wrote?
 *
 * A library folder is opened by both builds, often through a cloud drive, so
 * "compatible" has to mean the same bytes and not merely the same meaning. A
 * record rewritten with different spacing is a whole-file change to every sync
 * client and a conflict where there was none.
 *
 * Run with `npm test`.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import {
  APPLE_EPOCH_OFFSET,
  appleTimestamp,
  dateFromAppleTimestamp,
  encodeSwiftJSON,
  isoTimestamp,
} from '../shared/coding.js'
import {
  SketchColor,
  SketchElement,
  SketchStyle,
  distanceToSegment,
  rectFrom,
} from '../shared/sketch.js'
import { InkStroke, resample } from '../shared/ink.js'
import { KNOWN_HANDLERS, containerKind, diagnose, headLine, looksWhole, rightsHandler } from '../shared/pdfLock.js'
import { fileForRecordPath, recordPath } from '../main/layout.js'
import { shelfPapers, store, type Paper } from '../renderer/state.js'
import { guessKind, hasAbstract, hasIdentifier, hasReferences } from '../shared/documentKind.js'
import { SketchTree, adopted, guessedDirection, ordered, pruned, copied } from '../shared/sketchTree.js'
import { sketchSnapSuite } from './sketchSnap.js'
import { annotationSuite } from './annotations.js'
import { PaperMeta, PaperState } from '../shared/model.js'
import { entryFor, formatEntry, protectTitle } from '../shared/bibtex.js'
import { escapeLaTeX } from '../shared/latexTable.js'
import { readDrawings, writeDrawings, stripOwnedForDisplay } from '../main/pdfwrite.js'
import { Library, RecordUnreadable, readJSON } from '../main/library.js'
import { providerIcon, providerOf } from '../shared/cloudProvider.js'
import { linesFromRuns, type RunBox } from '../shared/textLines.js'
import { encodeSwiftJSON as encode } from '../shared/coding.js'
import { splitDock, splitPapers, splitRemove, zoneAt, zoneRect } from '../shared/split.js'

let passed = 0
let failed = 0
const failures: string[] = []

function test(name: string, body: () => void | Promise<void>): Promise<void> {
  const run = async () => {
    try {
      await body()
      passed += 1
      process.stdout.write(`  ✓ ${name}\n`)
    } catch (error) {
      failed += 1
      failures.push(`${name}\n    ${String((error as Error).message ?? error).split('\n').join('\n    ')}`)
      process.stdout.write(`  ✗ ${name}\n`)
    }
  }
  return run()
}

function suite(name: string) {
  process.stdout.write(`\n${name}\n`)
}

async function main() {
  // ------------------------------------------------------ Swift's JSON shape
  suite('The file format Swift writes')

  await test('an empty array is a bracket, a blank line and a bracket', () => {
    assert.equal(encodeSwiftJSON({ tags: [] }), '{\n  "tags" : [\n\n  ]\n}')
  })

  await test('an empty object likewise', () => {
    assert.equal(encodeSwiftJSON({ identifiers: {} }), '{\n  "identifiers" : {\n\n  }\n}')
  })

  await test('keys are sorted and separated by " : "', () => {
    assert.equal(encodeSwiftJSON({ b: 1, a: 2 }), '{\n  "a" : 2,\n  "b" : 1\n}')
  })

  await test('a nil field is absent, not null', () => {
    assert.equal(encodeSwiftJSON({ a: undefined, b: 1 }), '{\n  "b" : 1\n}')
  })

  await test('nothing is written after the closing brace', () => {
    // Swift's JSONEncoder ends at the brace. A trailing newline would make
    // every file this build touched a change in the folder it is synced from.
    assert.ok(!encodeSwiftJSON({ a: 1 }).endsWith('\n'))
  })

  await test('slashes are not escaped, and neither is anything above ASCII', () => {
    assert.equal(
      encodeSwiftJSON({ URL: 'https://arxiv.org/abs/2601.21564', who: 'Almudévar' }),
      '{\n  "URL" : "https://arxiv.org/abs/2601.21564",\n  "who" : "Almudévar"\n}',
    )
  })

  await test('keys sort by UTF-8 bytes, as Swift does', () => {
    // "é" is two bytes starting 0xC3; "z" is 0x7A, so "z" sorts first.
    assert.equal(Object.keys(JSON.parse(encodeSwiftJSON({ 'é': 1, z: 2 })))[0], 'z')
  })

  await test('a real library.json round-trips to the same bytes', () => {
    const sample = [
      '{',
      '  "createdAt" : "2026-09-19T06:21:28Z",',
      '  "displayName" : "Paper Time",',
      '  "libraryID" : "E61DCF37-3EFA-4037-A379-1402563D9128",',
      '  "schema" : 1,',
      '  "tags" : [',
      '',
      '  ]',
      '}',
    ].join('\n')
    assert.equal(encodeSwiftJSON(JSON.parse(sample)), sample)
  })

  await test('a real meta.json round-trips to the same bytes', () => {
    const file = findSampleMeta()
    if (!file) return // No library to compare against on this machine.
    const original = fs.readFileSync(file, 'utf8')
    assert.equal(encodeSwiftJSON(JSON.parse(original)), original)
  })

  // ------------------------------------------------------------------ dates
  suite('The two date shapes')

  await test('the library\'s records use ISO-8601 with no fraction', () => {
    assert.equal(isoTimestamp(new Date('2026-09-19T06:21:28.123Z')), '2026-09-19T06:21:28Z')
  })

  await test('a sketch\'s createdAt counts from 2001, as Swift\'s default does', () => {
    assert.equal(APPLE_EPOCH_OFFSET, 978307200)
    const date = new Date('2026-09-19T00:00:00Z')
    assert.equal(appleTimestamp(date), date.getTime() / 1000 - 978307200)
    assert.equal(dateFromAppleTimestamp(appleTimestamp(date)).getTime(), date.getTime())
  })

  await test('a timestamp the Mac wrote reads as the date it was', () => {
    // From a sketch file written by the Mac build on 2026-09-19.
    const read = dateFromAppleTimestamp(811492215.409792)
    assert.equal(read.getUTCFullYear(), 2026)
    assert.equal(read.getUTCMonth(), 8) // September
  })

  // ------------------------------------------------------- the sketch model
  suite('The drawing layer')

  await test('an element the Mac wrote decodes and re-encodes identically', () => {
    const original = MAC_SKETCH
    const decoded = JSON.parse(original).map(SketchElement.from)
    const again = encodeSwiftJSON(decoded.map((e: SketchElement) => e.encode()))
    assert.equal(again, original)
  })

  await test('a missing style field takes its default rather than failing', () => {
    const style = SketchStyle.from({ stroke: { red: 1, green: 0, blue: 0, alpha: 1 } })
    assert.equal(style.width, 2)
    assert.equal(style.dash, 'solid')
    assert.equal(style.endHead, 'arrow')
    assert.equal(style.fill, null)
  })

  await test('a fill of nil is written as an absent key', () => {
    const style = new SketchStyle()
    assert.equal(style.encode().fill, undefined)
    assert.ok(!encodeSwiftJSON(style.encode()).includes('fill'))
  })

  await test('a colour flattened on white loses its alpha but not its look', () => {
    const flat = SketchColor.paleYellow.flattenedOnWhite
    assert.equal(flat.alpha, 1)
    assert.ok(flat.red > SketchColor.paleYellow.red - 0.001)
    assert.ok(flat.green > SketchColor.paleYellow.green)
  })

  await test('setMidpoint inverts the curve at t = 0.5', () => {
    const element = new SketchElement({ kind: 'arrow', points: [{ x: 0, y: 0 }, { x: 100, y: 0 }] })
    element.setMidpoint({ x: 50, y: 40 })
    const midpoint = element.midpoint
    assert.ok(Math.abs(midpoint.x - 50) < 0.0001, `x was ${midpoint.x}`)
    assert.ok(Math.abs(midpoint.y - 40) < 0.0001, `y was ${midpoint.y}`)
  })

  await test('a bend under a point is no bend at all', () => {
    const element = new SketchElement({ kind: 'arrow', points: [{ x: 0, y: 0 }, { x: 100, y: 0 }] })
    element.setMidpoint({ x: 50, y: 0.2 })
    assert.equal(element.bend, null)
  })

  await test('a filled box is hit anywhere inside; an empty one only on its edge', () => {
    const empty = new SketchElement({ kind: 'rectangle', points: [{ x: 0, y: 0 }, { x: 100, y: 100 }] })
    assert.equal(empty.hits({ x: 50, y: 50 }, 2), false)
    assert.equal(empty.hits({ x: 0, y: 50 }, 2), true)
    const filled = new SketchElement({
      kind: 'rectangle',
      points: [{ x: 0, y: 0 }, { x: 100, y: 100 }],
      style: SketchStyle.from({ fill: SketchColor.paleBlue.encode() }),
    })
    assert.equal(filled.hits({ x: 50, y: 50 }, 2), true)
  })

  await test('a connector is hit along its curve, not along the straight line', () => {
    const element = new SketchElement({ kind: 'arrow', points: [{ x: 0, y: 0 }, { x: 100, y: 0 }] })
    element.setMidpoint({ x: 50, y: 40 })
    assert.equal(element.hits({ x: 50, y: 40 }, 3), true)
    assert.equal(element.hits({ x: 50, y: 0 }, 3), false)
  })

  await test('fitted scales a shape into a new box', () => {
    const element = new SketchElement({ kind: 'rectangle', points: [{ x: 0, y: 0 }, { x: 10, y: 10 }] })
    const grown = element.fitted({ x: 0, y: 0, width: 20, height: 20 }, { x: 0, y: 0, width: 10, height: 10 })
    assert.deepEqual(grown.rect, { x: 0, y: 0, width: 20, height: 20 })
    assert.equal(grown.id, element.id)
  })

  await test('distance to a segment is the perpendicular, and clamps at the ends', () => {
    assert.equal(distanceToSegment({ x: 5, y: 3 }, { x: 0, y: 0 }, { x: 10, y: 0 }), 3)
    assert.equal(distanceToSegment({ x: -4, y: 0 }, { x: 0, y: 0 }, { x: 10, y: 0 }), 4)
  })

  await test('rectFrom normalises whichever way the drag went', () => {
    assert.deepEqual(rectFrom({ x: 10, y: 10 }, { x: 0, y: 0 }), { x: 0, y: 0, width: 10, height: 10 })
  })

  // ---------------------------------------------------------------- the tree
  suite('The drawing\'s tree — frames, groups and layout, as the Mac keeps them')

  const box = (id: string, x: number, y: number, w: number, h: number, kind: 'rectangle' | 'frame' | 'group' | 'text' = 'rectangle') => {
    const element = new SketchElement({ id, kind, points: [{ x, y }, { x: x + w, y: y + h }] })
    return element
  }

  await test('normalized puts every child after its parent, in its parent\'s order', () => {
    const child = box('C', 0, 0, 10, 10)
    child.parent = 'F'
    const frame = box('F', 0, 0, 100, 100, 'frame')
    const out = SketchTree.normalized([child, frame])
    assert.deepEqual(out.map((e) => e.id), ['F', 'C'])
  })

  await test('a parent that is not on the page is dropped from the child', () => {
    const child = box('C', 0, 0, 10, 10)
    child.parent = 'GONE'
    const out = SketchTree.normalized([child])
    assert.equal(out[0].parent, null)
  })

  await test('a vertical layout stacks children from the frame\'s top-left, and the frame hugs them', () => {
    const frame = box('F', 100, 500, 300, 40, 'frame')
    frame.layout = { direction: 'vertical', gap: 8, padding: 8, align: 'start', hugs: true }
    const a = box('A', 0, 0, 50, 20)
    a.parent = 'F'
    const b = box('B', 0, 0, 80, 30)
    b.parent = 'F'
    const out = SketchTree.normalized([frame, a, b])
    const byID = new Map(out.map((e) => [e.id, e]))
    // Top-left stays at (100, 540); content 80 × (20 + 8 + 30) = 80 × 58; plus 16 of padding.
    assert.deepEqual(byID.get('F')!.rect, { x: 100, y: 540 - 74, width: 96, height: 74 })
    assert.deepEqual(byID.get('A')!.rect, { x: 108, y: 540 - 8 - 20, width: 50, height: 20 })
    assert.deepEqual(byID.get('B')!.rect, { x: 108, y: 540 - 8 - 20 - 8 - 30, width: 80, height: 30 })
  })

  await test('a horizontal layout lines children up in a row, aligned to the end when asked', () => {
    const frame = box('F', 0, 0, 500, 100, 'frame')
    frame.layout = { direction: 'horizontal', gap: 10, padding: 5, align: 'end', hugs: false }
    const a = box('A', 200, 200, 50, 20)
    a.parent = 'F'
    const b = box('B', 300, 300, 30, 60)
    b.parent = 'F'
    const out = SketchTree.normalized([frame, a, b])
    const byID = new Map(out.map((e) => [e.id, e]))
    // Not hugging: the frame keeps its box; children pack from its top-left.
    assert.deepEqual(byID.get('F')!.rect, { x: 0, y: 0, width: 500, height: 100 })
    assert.deepEqual(byID.get('A')!.rect, { x: 5, y: 5, width: 50, height: 20 })
    assert.deepEqual(byID.get('B')!.rect, { x: 65, y: 5, width: 30, height: 60 })
  })

  await test('an inner frame is laid out before the outer one measures it', () => {
    const outer = box('O', 0, 1000, 10, 10, 'frame')
    outer.layout = { direction: 'vertical', gap: 0, padding: 10, align: 'start', hugs: true }
    const inner = box('I', 0, 0, 10, 10, 'frame')
    inner.layout = { direction: 'vertical', gap: 0, padding: 0, align: 'start', hugs: true }
    inner.parent = 'O'
    const leaf = box('L', 0, 0, 40, 40)
    leaf.parent = 'I'
    const out = SketchTree.normalized([outer, inner, leaf])
    const byID = new Map(out.map((e) => [e.id, e]))
    assert.deepEqual(byID.get('I')!.rect, { x: 10, y: 1010 - 10 - 40, width: 40, height: 40 })
    assert.deepEqual(byID.get('O')!.rect, { x: 0, y: 1010 - 60, width: 60, height: 60 })
  })

  await test('a group\'s own box is the box round its children', () => {
    const group = box('G', 0, 0, 1, 1, 'group')
    const a = box('A', 10, 10, 10, 10)
    a.parent = 'G'
    const b = box('B', 50, 40, 10, 10)
    b.parent = 'G'
    const out = SketchTree.normalized([group, a, b])
    assert.deepEqual(out[0].rect, { x: 10, y: 10, width: 50, height: 40 })
  })

  await test('a click selects the outermost group, but a frame lets it through', () => {
    const frame = box('F', 0, 0, 100, 100, 'frame')
    const group = box('G', 0, 0, 1, 1, 'group')
    group.parent = 'F'
    const inner = box('H', 0, 0, 1, 1, 'group')
    inner.parent = 'G'
    const leaf = box('L', 10, 10, 10, 10)
    leaf.parent = 'H'
    const loose = box('X', 50, 50, 10, 10)
    loose.parent = 'F'
    const tree = new SketchTree([frame, group, inner, leaf, loose])
    assert.equal(tree.selectable('L'), 'G')
    assert.equal(tree.selectable('L', 'G'), 'H')
    assert.equal(tree.selectable('X'), 'X')
    assert.deepEqual([...tree.outermost(['G', 'L', 'X'])].sort(), ['G', 'X'])
    assert.deepEqual([...tree.expanded(['G'])].sort(), ['G', 'H', 'L'])
  })

  await test('a shape whose middle is inside a frame is adopted by it; one dragged out is set loose', () => {
    const frame = box('F', 0, 0, 100, 100, 'frame')
    const inside = box('A', 40, 40, 20, 20)
    const outside = box('B', 200, 200, 20, 20)
    outside.parent = 'F'
    const out = adopted(['A', 'B'], [frame, inside, outside])
    assert.equal(out.find((e) => e.id === 'A')!.parent, 'F')
    assert.equal(out.find((e) => e.id === 'B')!.parent, null)
  })

  await test('a thing in a group stays in its group when moved', () => {
    const group = box('G', 0, 0, 1, 1, 'group')
    const a = box('A', 500, 500, 10, 10)
    a.parent = 'G'
    const frame = box('F', 490, 490, 100, 100, 'frame')
    const out = adopted(['A'], [frame, group, a])
    assert.equal(out.find((e) => e.id === 'A')!.parent, 'G')
  })

  await test('an empty group is pruned; a frame stays', () => {
    const out = pruned([box('G', 0, 0, 1, 1, 'group'), box('F', 0, 0, 1, 1, 'frame')])
    assert.deepEqual(out.map((e) => e.id), ['F'])
  })

  await test('the direction of a layout is guessed from how the children spread', () => {
    assert.equal(guessedDirection([{ x: 0, y: 0, width: 10, height: 10 }, { x: 100, y: 0, width: 10, height: 10 }]), 'horizontal')
    assert.equal(guessedDirection([{ x: 0, y: 0, width: 10, height: 10 }, { x: 0, y: 100, width: 10, height: 10 }]), 'vertical')
    assert.equal(guessedDirection([{ x: 0, y: 0, width: 10, height: 10 }]), 'vertical')
  })

  await test('children are reordered along the axis before a layout starts', () => {
    const frame = box('F', 0, 0, 100, 100, 'frame')
    const low = box('A', 0, 0, 10, 10)
    low.parent = 'F'
    const high = box('B', 0, 50, 10, 10)
    high.parent = 'F'
    const tree = new SketchTree([frame, low, high])
    const out = ordered(['A', 'B'], 'vertical', [frame, low, high], tree)
    assert.deepEqual(out.map((e) => e.id), ['F', 'B', 'A'])
  })

  await test('copies carry their parent links across and the outermost stay loose', () => {
    const frame = box('F', 0, 0, 100, 100, 'frame')
    const group = box('G', 0, 0, 1, 1, 'group')
    group.parent = 'F'
    const leaf = box('L', 10, 10, 10, 10)
    leaf.parent = 'G'
    let n = 0
    const { copies, roots } = copied(['G'], [frame, group, leaf], { x: 12, y: -12 }, () => `N${++n}`)
    assert.equal(copies.length, 2)
    assert.deepEqual([...roots], ['N1'])
    assert.equal(copies[0].parent, 'F')
    assert.equal(copies[1].parent, 'N1')
    assert.deepEqual(copies[1].rect, { x: 22, y: -2, width: 10, height: 10 })
  })

  await test('a layout the Mac wrote comes back byte for byte', () => {
    const element = SketchElement.from(JSON.parse(MAC_FRAME))
    assert.equal(encodeSwiftJSON(element.encode()), MAC_FRAME)
  })

  await sketchSnapSuite(test, suite)
  await annotationSuite(test, suite)

  // --------------------------------------------------------------------- ink
  suite('Handwriting')

  await test('a stroke round-trips through its JSON', () => {
    const stroke = new InkStroke(
      [{ x: 1, y: 2, w: 2.5 }, { x: 3, y: 4, w: 3 }],
      SketchColor.red,
      'pen',
    )
    const again = InkStroke.from(JSON.parse(JSON.stringify(stroke.encode())))
    assert.deepEqual(again.points, stroke.points)
    assert.ok(again.color.matches(SketchColor.red))
    assert.equal(again.tool, 'pen')
  })

  await test('a marker is written into the file translucent, as the Mac writes it', () => {
    const marker = new InkStroke([{ x: 0, y: 0, w: 8 }], SketchColor.blue, 'marker')
    assert.equal(marker.pdfColor.alpha, 0.35)
    const pen = new InkStroke([{ x: 0, y: 0, w: 2 }], SketchColor.blue, 'pen')
    assert.equal(pen.pdfColor.alpha, 1)
  })

  await test('resampling thins a track to the Mac\'s 1.5-point spacing', () => {
    const dense = Array.from({ length: 100 }, (_, index) => ({ x: index * 0.1, y: 0, w: 2 }))
    const thinned = resample(dense)
    assert.ok(thinned.length < 12, `kept ${thinned.length}`)
    assert.equal(thinned[0].x, 0)
    assert.equal(thinned[thinned.length - 1].x, dense[dense.length - 1].x)
  })

  // ------------------------------------------------------------- the records
  suite('The library\'s records')

  await test('a field this build has never heard of survives a save', () => {
    const meta = new PaperMeta({
      id: 'A', csl: {}, bibKey: 'x', file: {}, addedAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z', somethingNew: { from: 'a later version' },
    })
    const written = meta.encode()
    assert.deepEqual(written.somethingNew, { from: 'a later version' })
  })

  await test('a library written before the flat layout still finds its file', () => {
    const meta = new PaperMeta({ id: 'A', file: { name: 'old-shape.pdf' } })
    assert.equal(meta.file.relativePath, 'old-shape.pdf')
    // And is written back in the current shape.
    assert.equal((meta.encode().file as Record<string, unknown>).name, undefined)
  })

  await test('the newer write wins a state conflict, whole record', () => {
    const older = new PaperState({ isFavorite: true, updatedAt: '2026-01-01T00:00:00Z' })
    const newer = new PaperState({ isFavorite: false, updatedAt: '2026-02-01T00:00:00Z' })
    assert.equal(PaperState.resolve(older, newer).isFavorite, false)
    assert.equal(PaperState.resolve(newer, older).isFavorite, false)
  })

  // ---------------------------------------------------------------- BibTeX
  suite('Exporting BibTeX')

  await test('an entry matches the Swift exporter byte for byte', () => {
    // The expected text below is the output of `BibTeXWriter.write` on the
    // Mac, for this record. Regenerate it with the reference program in
    // `tools/` if the Swift side's rules change.
    const meta = new PaperMeta({
      id: 'X', bibKey: 'min2025vision', file: {},
      addedAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z',
      csl: {
        id: 'min2025vision', type: 'paper-conference',
        title: 'Vision-Language Interactive Relation Mining for Open-Vocabulary Scene Graph Generation',
        'container-title': '2025 IEEE/CVF International Conference on Computer Vision',
        author: [
          { family: 'Min', given: 'Yukuan' },
          { family: 'Almudévar', given: 'Antonio' },
          { literal: 'Association for Computing Machinery' },
        ],
        issued: { 'date-parts': [[2025, 6]] },
        DOI: '10.1109/iccv51701.2025.01556',
        page: '16755–16764',
        volume: '3',
        publisher: 'IEEE',
      },
    })
    const expected = [
      '@inproceedings{min2025vision,',
      '  author    = {Min, Yukuan and Almud{\\\'e}var, Antonio and {Association for Computing Machinery}},',
      '  title     = {Vision-Language Interactive Relation Mining for Open-Vocabulary Scene Graph Generation},',
      '  booktitle = {2025 {IEEE/CVF} International Conference on Computer Vision},',
      '  year      = {2025},',
      '  month     = {jun},',
      '  volume    = {3},',
      '  pages     = {16755--16764},',
      '  publisher = {IEEE},',
      '  doi       = {10.1109/iccv51701.2025.01556}',
      '}',
      '',
    ].join('\n')
    assert.equal(formatEntry(entryFor(meta)), expected)
  })

  await test('an acronym is braced and ordinary title case is not', () => {
    assert.equal(protectTitle('A BiSeNet for 3D scenes'), 'A {BiSeNet} for {3D} scenes')
    assert.equal(protectTitle('Open-Vocabulary Scene Graph'), 'Open-Vocabulary Scene Graph')
  })

  await test('the escaping table is the Swift one', () => {
    assert.equal(escapeLaTeX('Almudévar'), "Almud{\\'e}var")
    assert.equal(escapeLaTeX('α & β'), '$\\alpha$ \\& $\\beta$')
    assert.equal(escapeLaTeX('a—b'), 'a---b')
  })

  // ------------------------------------------------------------------- PDFs
  suite('What goes into the PDF')

  const pdf = findSamplePDF()
  if (pdf) {
    const original = new Uint8Array(fs.readFileSync(pdf))

    await test('elements written into a page come back out of it', async () => {
      const elements = [
        new SketchElement({
          kind: 'rectangle',
          points: [{ x: 100, y: 600 }, { x: 250, y: 700 }],
          text: 'Who?',
          style: SketchStyle.from({ dash: 'dashed', fill: SketchColor.paleYellow.encode() }),
        }),
        (() => {
          const arrow = new SketchElement({ kind: 'arrow', points: [{ x: 300, y: 300 }, { x: 420, y: 380 }] })
          arrow.setMidpoint({ x: 360, y: 420 })
          return arrow
        })(),
        new SketchElement({ kind: 'text', points: [{ x: 90, y: 200 }, { x: 220, y: 230 }], text: 'Why now?' }),
      ]
      const strokes = [new InkStroke(
        [{ x: 50, y: 100, w: 2 }, { x: 80, y: 130, w: 2.4 }, { x: 120, y: 120, w: 2 }],
        SketchColor.red, 'pen',
      )]
      const written = await writeDrawings(original, [{ pageIndex: 0, elements, strokes }])
      const read = await readDrawings(written)
      const page = read.get(0)
      assert.ok(page, 'page 0 should carry a drawing')
      assert.equal(page.elements.length, 3)
      assert.equal(page.strokes.length, 1)
      const box = page.elements.find((e) => e.kind === 'rectangle')!
      assert.equal(box.text, 'Who?')
      assert.equal(box.style.dash, 'dashed')
      assert.ok(box.style.fill?.matches(SketchColor.paleYellow))
      const arrow = page.elements.find((e) => e.kind === 'arrow')!
      assert.ok(arrow.bend, 'the bend must survive the file')
      assert.ok(Math.abs(arrow.midpoint.x - 360) < 0.001)
      assert.ok(Math.abs(arrow.midpoint.y - 420) < 0.001)
    })

    await test('writing twice does not double the annotations', async () => {
      const elements = [new SketchElement({ kind: 'ellipse', points: [{ x: 10, y: 10 }, { x: 60, y: 60 }] })]
      const once = await writeDrawings(original, [{ pageIndex: 0, elements, strokes: [] }])
      const twice = await writeDrawings(once, [{ pageIndex: 0, elements, strokes: [] }])
      assert.equal((await readDrawings(twice)).get(0)?.elements.length, 1)
    })

    await test('clearing a page takes our marks out and leaves the rest', async () => {
      const before = await countAnnotations(original, 0)
      const elements = [new SketchElement({ kind: 'rectangle', points: [{ x: 10, y: 10 }, { x: 60, y: 60 }] })]
      const written = await writeDrawings(original, [{ pageIndex: 0, elements, strokes: [] }])
      const cleared = await writeDrawings(written, [{ pageIndex: 0, elements: [], strokes: [] }])
      assert.equal(await countAnnotations(cleared, 0), before)
    })

    await test('the display copy hides our marks and keeps everyone else\'s', async () => {
      const elements = [new SketchElement({ kind: 'rectangle', points: [{ x: 10, y: 10 }, { x: 60, y: 60 }] })]
      const written = await writeDrawings(original, [{ pageIndex: 0, elements, strokes: [] }])
      const shown = await stripOwnedForDisplay(written)
      assert.equal((await readDrawings(shown)).size, 0)
      assert.equal(await countAnnotations(shown, 0), await countAnnotations(original, 0))
    })

    await test('a stroke keeps its shape through the file', async () => {
      const strokes = [new InkStroke(
        [{ x: 50, y: 100, w: 3 }, { x: 80, y: 130, w: 3 }, { x: 120, y: 120, w: 3 }],
        SketchColor.green, 'pen',
      )]
      const written = await writeDrawings(original, [{ pageIndex: 0, elements: [], strokes }])
      const read = (await readDrawings(written)).get(0)!
      const stroke = read.strokes[0]
      assert.equal(stroke.points.length, 3)
      assert.equal(stroke.points[0].x, 50)
      assert.equal(stroke.points[2].y, 120)
      assert.ok(stroke.color.matches(SketchColor.green))
      assert.ok(Math.abs(stroke.points[0].w - 3) < 0.01)
    })
  } else {
    process.stdout.write('  – no sample PDF on this machine; the file tests were skipped\n')
  }

  // ------------------------------------------------------------ side by side
  suite('Papers side by side, as the Mac arranges them')

  await test('docking on the right puts the paper showing on the left', () => {
    const arranged = splitDock({ left: { top: 'A' } }, 'B', 'right')
    assert.deepEqual(splitPapers(arranged), ['A', 'B'])
    assert.equal(arranged.right?.top, 'B')
  })

  await test('docking on the left slides the rest to the right column, two at most', () => {
    const arranged = splitDock({ left: { top: 'A', bottom: 'B' }, right: { top: 'C', bottom: 'D' } }, 'E', 'left')
    assert.deepEqual(arranged.left, { top: 'E' })
    assert.deepEqual(arranged.right, { top: 'A', bottom: 'B' })
    assert.deepEqual(splitPapers(arranged), ['E', 'A', 'B'])
  })

  await test('a quarter keeps one neighbour in its column and spills the other', () => {
    const arranged = splitDock({ left: { top: 'A', bottom: 'B' }, right: { top: 'C' } }, 'D', 'bottomLeft')
    assert.deepEqual(arranged.left, { top: 'A', bottom: 'D' })
    assert.deepEqual(arranged.right, { top: 'C', bottom: 'B' })
  })

  await test('a right quarter with nothing else becomes the left column', () => {
    const arranged = splitDock({ left: { top: 'A' } }, 'A', 'topRight')
    assert.deepEqual(arranged, { left: { top: 'A' } })
  })

  await test('a paper already in the arrangement moves rather than doubles', () => {
    const arranged = splitDock({ left: { top: 'A' }, right: { top: 'B' } }, 'B', 'left')
    assert.deepEqual(splitPapers(arranged), ['B', 'A'])
  })

  await test('removing a paper closes up the space it leaves', () => {
    const arranged = splitRemove({ left: { top: 'A', bottom: 'B' }, right: { top: 'C' } }, 'A')
    assert.deepEqual(arranged, { left: { top: 'B' }, right: { top: 'C' } })
    const last = splitRemove({ left: { top: 'A' }, right: { top: 'C' } }, 'A')
    assert.deepEqual(last, { left: { top: 'C' }, right: undefined })
  })

  await test('the middle of the page is no zone; the edges are halves and quarters', () => {
    const size = { width: 1000, height: 900 }
    assert.equal(zoneAt(500, 450, size), null)
    assert.equal(zoneAt(350, 450, size), null)
    assert.equal(zoneAt(100, 450, size), 'left')
    assert.equal(zoneAt(900, 450, size), 'right')
    assert.equal(zoneAt(100, 100, size), 'topLeft')
    assert.equal(zoneAt(900, 100, size), 'topRight')
    assert.equal(zoneAt(100, 800, size), 'bottomLeft')
    assert.equal(zoneAt(900, 800, size), 'bottomRight')
  })

  await test('a zone is drawn inset eight points, as on the Mac', () => {
    const rect = zoneRect('right', { width: 1000, height: 900 })
    assert.deepEqual(rect, { x: 504, y: 8, width: 488, height: 884 })
  })

  await test('a new record carries the date the Mac insists on', () => {
    const meta = PaperMeta.make('095886A4-5BB4-4A93-B764-43BE22CD41C1', {
      relativePath: 'a.pdf', byteSize: 1, pageCount: 1, importDigest: 'd', originalName: 'a.pdf',
    }, 'pc')
    const raw = meta.encode() as { provenance?: Record<string, unknown> }
    // Provenance.fetchedAt is not optional on the Mac. Without it the whole
    // record fails to decode and the paper is simply not there.
    assert.ok(raw.provenance?.fetchedAt, 'provenance.fetchedAt is written')
    assert.match(String(raw.provenance?.fetchedAt), /^\d{4}-\d{2}-\d{2}T/)
  })

  await test('what a PDF is, guessed the way the Mac guesses', () => {
    assert.equal(guessKind({ identifier: true, abstract: false, references: false }).kind, 'paper')
    assert.equal(guessKind({ identifier: false, abstract: true, references: true }).kind, 'paper')
    // One without the other is not enough: a report has a summary, and a
    // manual can cite a standard.
    assert.equal(guessKind({ identifier: false, abstract: true, references: false }).kind, 'document')
    assert.equal(guessKind({ identifier: false, abstract: false, references: false }).kind, 'document')
    // Long, with a reference list at the back: a book, as on the Mac. The
    // length alone is not enough, and the references alone are not either.
    assert.equal(
      guessKind({ identifier: false, abstract: false, references: true, pageCount: 548 }).kind, 'book')
    assert.equal(
      guessKind({ identifier: false, abstract: false, references: false, pageCount: 548 }).kind, 'document')
    assert.equal(
      guessKind({ identifier: false, abstract: false, references: true, pageCount: 12 }).kind, 'document')
    assert.equal(
      guessKind({ identifier: true, abstract: true, references: true, pageCount: 548 }).kind, 'paper')

    assert.ok(hasIdentifier('see https://doi.org/10.1145/3292500.3330701 for more'))
    assert.ok(hasIdentifier('arXiv:2403.01234v2 [cs.LG]'))
    assert.ok(!hasIdentifier('call 10.30 on Tuesday'))
    assert.ok(hasAbstract('A Study of Things\nAbstract\nWe show that…'))
    assert.ok(!hasAbstract('Coffee Machine Manual\nHow to descale your machine'))
    assert.ok(hasReferences('…and so on.\nReferences\n[1] Someone, 2020.'))
  })

  await test('a record says nothing about its kind until somebody does', () => {
    const meta = PaperMeta.make('095886A4-5BB4-4A93-B764-43BE22CD41C1', {
      relativePath: 'a.pdf', byteSize: 1, pageCount: 1, importDigest: 'd', originalName: 'a.pdf',
    }, 'pc')
    assert.equal(meta.kindIsUnanswered, true)
    assert.equal(meta.effectiveKind, 'paper')
    assert.ok(!/"kind"/.test(encode(meta.encode())), 'no kind key until there is an answer')
    meta.guessedKind = 'document'
    assert.equal(meta.effectiveKind, 'document')
    meta.kind = 'paper'
    // The answer wins over the guess, always.
    assert.equal(meta.effectiveKind, 'paper')
    assert.match(encode(meta.encode()), /"kind" : "paper"/)
  })

  await test('a folder shelf shows that folder and nothing else', () => {
    const make = (id: string, root: string): Paper => ({
      id,
      meta: new PaperMeta({ id, file: { relativePath: `${id}.pdf` } }),
      state: new PaperState({}),
      exists: true,
      root,
    })
    const before = { papers: store.papers, shelf: store.shelf, roots: store.roots }
    store.papers = [make('a', '/one'), make('b', '/two'), make('c', '/two')]
    store.roots = ['/one', '/two']
    store.shelf = { kind: 'folder', root: '/two' }
    assert.deepEqual(shelfPapers().map((p) => p.id), ['b', 'c'])
    store.shelf = { kind: 'all' }
    assert.equal(shelfPapers().length, 3)
    store.papers = before.papers
    store.shelf = before.shelf
    store.roots = before.roots
  })

  await test('a folder says which cloud it is in, on every desktop', () => {
    // The Mac's own paths, so the two builds agree about the same folder.
    assert.equal(providerOf('/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Papers'), 'iCloudDrive')
    assert.equal(providerOf('/Users/me/Library/CloudStorage/GoogleDrive-me@x.com/My Drive/Papers'), 'googleDrive')
    // And the ones the other two desktops use.
    assert.equal(providerOf('G:\\My Drive\\Papers'), 'googleDrive')
    assert.equal(providerOf('C:\\Users\\me\\OneDrive - Acme\\Papers'), 'oneDrive')
    assert.equal(providerOf('C:\\Users\\me\\iCloudDrive\\Papers'), 'iCloudDrive')
    assert.equal(providerOf('/home/me/Dropbox/Papers'), 'dropbox')
    assert.equal(providerOf('/home/me/Papers'), 'local')
    assert.equal(providerIcon(providerOf('/home/me/Papers')), 'internaldrive')
    assert.equal(providerIcon(providerOf('/home/me/Dropbox/Papers')), 'cloud')
  })

  await test('renaming a paper moves the file and leaves the record alone', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-rename-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(root, '2403.18293v1.pdf'), '%PDF-1.7\n')
      const imported = await library.importPDF(path.join(root, '2403.18293v1.pdf'), 12)
      assert.ok(imported)
      const record = path.join(root, '.papertime', 'papers', imported.id)

      const renamed = await library.rename(imported.id, 'Diffusion Policy')
      assert.ok(!('error' in renamed), 'the rename should have gone through')
      // The extension is kept whatever is typed: a PDF that stops being
      // called .pdf is one the desktop stops opening.
      assert.ok(fs.existsSync(path.join(root, 'Diffusion Policy.pdf')))
      assert.ok(!fs.existsSync(path.join(root, '2403.18293v1.pdf')))
      // Same record, same identifier — marks, ink and notes do not move.
      assert.ok(fs.existsSync(record))
      const meta = new PaperMeta(JSON.parse(fs.readFileSync(path.join(record, 'meta.json'), 'utf8')))
      assert.equal(meta.file.relativePath, 'Diffusion Policy.pdf')
      assert.equal(meta.file.originalName, 'Diffusion Policy.pdf')

      // A name already on another file, and a name that is a path, are both
      // refused — and nothing moves.
      fs.writeFileSync(path.join(root, 'taken.pdf'), '%PDF-1.7\n')
      assert.deepEqual(await library.rename(imported.id, 'taken.pdf'), { error: 'taken' })
      assert.deepEqual(await library.rename(imported.id, '../elsewhere.pdf'), { error: 'notAName' })
      assert.deepEqual(await library.rename(imported.id, '   '), { error: 'empty' })
      assert.ok(fs.existsSync(path.join(root, 'Diffusion Policy.pdf')))
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('a second copy already in the folder gets its own record', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-copy-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(root, 'paper.pdf'), '%PDF-1.7\n% paper\n')
      const first = await library.importPDF(path.join(root, 'paper.pdf'), 2)
      assert.ok(first)

      // The same bytes, under another name, sitting in the library folder.
      fs.copyFileSync(path.join(root, 'paper.pdf'), path.join(root, 'paper copy.pdf'))
      assert.deepEqual(
        (await library.looseFiles()).map((file) => path.basename(file)),
        ['paper copy.pdf'],
      )

      // Matching bytes answer "already brought in" for a file arriving from
      // outside. For a file already in the folder that answer leaves a PDF the
      // list will not show, and "add 1 loose PDF" that stays at 1 for ever.
      const second = await library.importPDF(path.join(root, 'paper copy.pdf'), 2)
      assert.ok(second)
      assert.notEqual(second.id, first.id, 'the copy is a paper of its own')
      assert.deepEqual(await library.looseFiles(), [], 'and nothing is left loose')

      // Handed the very file a record already claims, it is still that paper —
      // otherwise dragging a paper out of the window and back in would leave
      // two records claiming one file.
      const again = await library.importPDF(path.join(root, 'paper.pdf'), 2)
      assert.equal(again?.id, first.id)
      assert.equal((await library.read()).papers.length, 2)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('a renamed paper still speaks for its file', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-rename-claim-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(root, 'before.pdf'), '%PDF-1.7\n% before\n')
      const paper = await library.importPDF(path.join(root, 'before.pdf'), 2)
      assert.ok(paper)
      await library.rename(paper.id, 'after')

      // The record is written with forward slashes and every comparison
      // against it uses them, but `rename` used this machine's separator — so
      // on Windows a renamed paper stopped matching its own file, the folder
      // called it loose, and taking the loose PDFs in made a second record.
      const stored = String(
        ((await library.paper(paper.id))?.meta.file as Record<string, unknown>)?.relativePath ?? '',
      )
      assert.equal(stored, 'after.pdf')
      assert.ok(!stored.includes('\\'), 'a record never holds a backslash')
      assert.deepEqual(await library.looseFiles(), [])

      const again = await library.importPDF(path.join(root, 'after.pdf'), 2)
      assert.equal(again?.id, paper.id, 'and it is still the same paper')
      assert.equal((await library.read()).papers.length, 1)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('one record that will not be read costs one row, not the library', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-short-'))
    try {
      const library = await Library.open(root)
      const ids: string[] = []
      for (const name of ['one.pdf', 'two.pdf', 'three.pdf']) {
        fs.writeFileSync(path.join(root, name), `%PDF-1.7\n% ${name}\n`)
        const row = await library.importPDF(path.join(root, name), 2)
        assert.ok(row)
        ids.push(row.id)
      }
      const meta = path.join(root, '.papertime', 'papers', ids[1], 'meta.json')
      const whole = fs.readFileSync(meta, 'utf8')

      // What a streamed drive hands back for a file that is still on its way:
      // `readFile` resolves with a short buffer and throws nothing, so the
      // damage shows up as a `SyntaxError`, which carries no `code` and walked
      // straight past a test for `ENOENT`. Under one `Promise.all` that
      // rejection took all three papers with it, `snapshot()` turned it into
      // `{ error }`, and a library of eighty read as empty.
      fs.writeFileSync(meta, whole.slice(0, 40))
      const short = await library.read()
      assert.equal(short.papers.length, 2, 'the other two papers should still be here')
      assert.equal(short.trouble.length, 1)
      assert.match(short.trouble[0], /^[0-9A-F-]+\/meta\.json: half-written$/)

      // And its PDF is not loose. A record that is only late still holds its
      // file, so offering it would take the same paper in a second time —
      // another identifier, none of its marks, and both rows on the shelf.
      assert.deepEqual(await library.looseFiles(), [])

      // What the reader asks for by hand still happens. One record nobody can
      // read must not mean a folder that accepts no papers at all: the digest
      // check is short by that record, which is a duplicate you can see, and
      // the alternative is a library that is shut for as long as the file is.
      fs.writeFileSync(path.join(root, 'four.pdf'), '%PDF-1.7\n% four\n')
      const added = await library.importPDF(path.join(root, 'four.pdf'), 2)
      assert.ok(added, 'a paper named by hand goes in although a record is late')
      assert.equal((await library.read()).papers.length, 3)

      // An error that is not ENOENT is the same kind of accident: a drive that
      // would not fetch the file this minute, not a paper that is gone.
      fs.rmSync(meta)
      fs.mkdirSync(meta)
      const io = await library.read()
      assert.equal(io.papers.length, 3)
      assert.equal(io.trouble.length, 1)
      assert.match(io.trouble[0], /EISDIR/)
      fs.rmdirSync(meta)

      // Reading state is a page number and a shelf. Losing it is not losing
      // the paper, so the row comes without it rather than not at all.
      fs.writeFileSync(meta, whole)
      fs.writeFileSync(path.join(root, '.papertime', 'papers', ids[2], 'state.json'), '{"schema":1,"id":"00')
      const all = await library.read()
      assert.equal(all.papers.length, 4)
      assert.equal(all.trouble.length, 0)
      assert.deepEqual(all.papers.find((row) => row.id === ids[2])?.state, {})
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('a record that is only late is never answered by writing over it', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-nowrite-'))
    try {
      const library = await Library.open(root)
      fs.writeFileSync(path.join(root, 'paper.pdf'), '%PDF-1.7\n% body\n')
      const imported = await library.importPDF(path.join(root, 'paper.pdf'), 5)
      assert.ok(imported)

      // Absent and half-written are different answers, and only the first one
      // is safe to paper over with a default. Every reader here either has a
      // default for a file that is not there or reads before it writes, so a
      // half-written record has to throw — and now it throws something a
      // caller can recognise and a person can read.
      const state = path.join(root, '.papertime', 'papers', imported.id, 'state.json')
      assert.equal(await readJSON(path.join(root, '.papertime', 'papers', imported.id, 'nothing.json')), null)
      fs.writeFileSync(state, '{"schema":1,"curr')
      await assert.rejects(() => readJSON(state), (error: Error) => {
        assert.ok(error instanceof RecordUnreadable)
        assert.equal(path.basename(error.file), 'state.json')
        assert.match(error.message, /half-written/)
        return true
      })

      // So a page turned while that file is late does not save over it: the
      // merge cannot happen, and the record on disk is left exactly as found.
      const before = fs.readFileSync(state, 'utf8')
      await assert.rejects(() => library.saveState(imported.id, new PaperState({ currentPage: 7 })))
      assert.equal(fs.readFileSync(state, 'utf8'), before)

      // Repairing records is writing to the folder too, so it waits for a
      // folder that answers in full. The file moved out from under this record
      // and the digest can find it again — but not while a sibling is late,
      // because the set of PDFs no record claims is short by whatever that
      // sibling holds.
      fs.writeFileSync(path.join(root, 'other.pdf'), '%PDF-1.7\n% other\n')
      const other = await library.importPDF(path.join(root, 'other.pdf'), 2)
      assert.ok(other)
      fs.writeFileSync(state, '{}')
      fs.renameSync(path.join(root, 'paper.pdf'), path.join(root, 'paper (1).pdf'))
      const otherMeta = path.join(root, '.papertime', 'papers', other.id, 'meta.json')
      const otherWhole = fs.readFileSync(otherMeta, 'utf8')
      fs.writeFileSync(otherMeta, otherWhole.slice(0, 30))

      const half = await library.read()
      assert.equal(half.trouble.length, 1)
      assert.equal(half.papers.find((row) => row.id === imported.id)?.exists, false)

      // And it happens the moment the folder answers in full again.
      fs.writeFileSync(otherMeta, otherWhole)
      const whole = await library.read()
      assert.deepEqual(whole.trouble, [])
      const healed = whole.papers.find((row) => row.id === imported.id)
      assert.equal(healed?.exists, true)
      assert.equal(path.basename(healed?.file ?? ''), 'paper (1).pdf')
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the rights handlers are the same list the Mac looks for', () => {
    // Run from Portable/, as `npm test` does.
    const swift = fs.readFileSync(
      path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Sources/PaperCore/PDFLock.swift'),
      'utf8',
    )
    const block = /knownHandlers = \[([^\]]*)\]/.exec(swift)?.[1] ?? ''
    const listed = [...block.matchAll(/"([^"]+)"/g)].map((m) => m[1])
    assert.deepEqual(KNOWN_HANDLERS, listed)
  })

  await test('a rights handler is only found when it is in the file', () => {
    const bytes = new TextEncoder().encode('%PDF-1.7 /Encrypt /Filter /MicrosoftIRMServices')
    assert.equal(rightsHandler(bytes), 'MicrosoftIRMServices')
    assert.equal(rightsHandler(new TextEncoder().encode('%PDF-1.7 ordinary paper')), null)
  })

  await test('what is wrong with the bytes, told apart before pdf.js is asked', () => {
    const bytes = (text: string) => new TextEncoder().encode(text)
    const whole = bytes('%PDF-1.7\n1 0 obj\n<<>>\nendobj\ntrailer<<>>\nstartxref\n9\n%%EOF\n')

    assert.equal(diagnose(whole), null)
    assert.ok(looksWhole(whole))

    // A PDF that stops before it ends. pdf.js sometimes recovers these, so
    // this is a sentence to say, never a door to shut — see the handler.
    assert.equal(diagnose(whole.subarray(0, whole.length - 12)), 'cut')

    // The three that can never be parsed, however many times they are read.
    assert.equal(diagnose(new Uint8Array(0)), 'empty')
    assert.equal(diagnose(new Uint8Array(4096)), 'placeholder')
    assert.equal(diagnose(bytes('<!DOCTYPE html><html><body>Sign in</body></html>')), 'webpage')

    const ole = new Uint8Array(512)
    ole.set([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
    assert.equal(containerKind(ole), 'ole')
    assert.equal(diagnose(ole), 'wrapped')

    // A banner glued in front of a real PDF still opens in pdf.js, so the
    // header is looked for in the first kilobyte and not at byte zero.
    assert.equal(diagnose(new Uint8Array([...bytes('   \n'), ...whole])), null)
    // And a PDF is allowed zipped streams inside it without being a zip.
    assert.equal(containerKind(whole), null)
  })

  await test('a container is a rights lock on both desktops', () => {
    // The Mac learned this first and the port dropped it; the Swift side is
    // read here so the two cannot drift apart again in silence.
    const swift = fs.readFileSync(
      path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Sources/PaperCore/PDFLock.swift'),
      'utf8',
    )
    assert.ok(/func isContainer\(/.test(swift), 'the Mac has no container check')
    assert.ok(/if isContainer\(data\) \{ return \.rights/.test(swift), 'the Mac does not use it')
    assert.ok(/0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1/.test(swift), 'the OLE magic differs')

    const ole = new Uint8Array(512)
    ole.set([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
    assert.equal(containerKind(ole), 'ole')
  })

  await test('a paper in a subfolder is a paper, the way it is on the Mac', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'papertime-deep-'))
    try {
      const pdf = '%PDF-1.7\ntrailer<<>>\nstartxref\n9\n%%EOF\n'
      fs.writeFileSync(path.join(root, 'Top.pdf'), pdf)
      fs.mkdirSync(path.join(root, '2026-2학기', 'week 1'), { recursive: true })
      fs.writeFileSync(path.join(root, '2026-2학기', 'lecture06.pdf'), pdf)
      fs.writeFileSync(path.join(root, '2026-2학기', 'week 1', 'Ch1. Introduction.pdf'), pdf)
      // Neither of these is a paper, and the walk must not take them.
      fs.mkdirSync(path.join(root, '.papertime'), { recursive: true })
      fs.writeFileSync(path.join(root, '.papertime', 'hidden.pdf'), pdf)
      fs.mkdirSync(path.join(root, 'Trash'), { recursive: true })
      fs.writeFileSync(path.join(root, 'Trash', 'thrown.pdf'), pdf)

      const library = new Library(root)
      const found = await library.unclaimedFiles(new Set())
      assert.deepEqual(
        found.map((file) => recordPath(root, file)).sort(),
        ['2026-2학기/lecture06.pdf', '2026-2학기/week 1/Ch1. Introduction.pdf', 'Top.pdf'],
      )

      // And the record says it with `/`, because the Mac reads the same
      // record and a backslash names no file there.
      const record = recordPath(root, path.join(root, '2026-2학기', 'week 1', 'Ch1. Introduction.pdf'))
      assert.ok(!record.includes('\\'), record)
      assert.equal(fileForRecordPath(root, record), path.join(root, '2026-2학기', 'week 1', 'Ch1. Introduction.pdf'))

      // A record that holds a paper keeps it out of the loose list, wherever
      // it sits — the two are compared in the record's own spelling.
      const rest = await library.unclaimedFiles(new Set([record]))
      assert.equal(rest.length, 2)
    } finally {
      fs.rmSync(root, { recursive: true, force: true })
    }
  })

  await test('the Mac walks down too, and this is the line that says so', () => {
    const swift = fs.readFileSync(
      path.join(process.cwd(), '..', 'Packages/PaperTimeKit/Sources/LibraryStore/LibraryStore.swift'),
      'utf8',
    )
    // If the Mac ever stops recursing, this port must stop too — and the two
    // drifting apart in silence is exactly how a paper came to exist on one
    // desktop and not the other.
    assert.ok(/Every PDF in the library, wherever it sits under the root/.test(swift))
    assert.ok(!/skipsSubdirectoryDescendants/.test(swift), 'the Mac stopped recursing')
  })

  // ------------------------------------------- what stands in for the paper
  suite('A file that is not the paper says so in its own words')

  const bytesOf = (text: string) => new TextEncoder().encode(text)

  await test('the eight bytes a company machine sent back spell a line', () => {
    // Reported down a phone from a machine where screenshots are not allowed:
    // 3C 23 23 20 4E 41 53 32. Eight numbers to read out, and nobody could see
    // that they say `<## NAS2` until they were decoded by hand.
    const stub = bytesOf('<## NAS2\\vol1\\papers\\2007\\anna-karenina.pdf ##>\r\n')
    assert.equal(headLine(stub), '<## NAS2\\vol1\\papers\\2007\\anna-karenina.pdf ##>')
    assert.equal(diagnose(stub), 'opaque')
  })

  await test('a notice written in Korean is readable too', () => {
    assert.equal(
      headLine(bytesOf('이 문서는 보안 정책에 따라 열 수 없습니다.\n자세한 내용은 IT에 문의하세요.')),
      '이 문서는 보안 정책에 따라 열 수 없습니다.',
    )
  })

  await test('bytes that are not characters have no line', () => {
    assert.equal(headLine(new Uint8Array([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])), null)
    assert.equal(headLine(new Uint8Array(64)), null)
    assert.equal(headLine(bytesOf('ab')), null, 'two characters are not a line')
    assert.equal(headLine(bytesOf('a bellrings')), null, 'a control character is not text')
  })

  await test('a line is a line, not a file', () => {
    assert.equal(headLine(bytesOf('x'.repeat(400)))?.length, 120)
  })

  // ------------------------------------------------ a highlight's line breaks
  suite('A highlight follows the lines of the text')

  /** A run's box, the way the text layer makes one: an em box hanging from
   *  the baseline, mostly above it and only a little below. */
  const run = (baseline: number, em: number, left: number, right: number): RunBox =>
    ({ left, right, top: baseline - em * 0.8, bottom: baseline + em * 0.2 })

  /** A paragraph: `lines` lines of body text, an em of 15 set every 18
   *  points, which is what a real paper measured. */
  const paragraph = (lines: number, em = 15, gap = 18) =>
    Array.from({ length: lines }, (_, index) => run(100 + index * gap, em, 60, 320))

  await test('five lines of body text stay five lines', () => {
    assert.equal(linesFromRuns(paragraph(5)).length, 5)
  })

  await test('runs of unequal height on one line are one line', () => {
    // Measured in the window: a roman and an italic on the same line came
    // back 15.5 and 13 points tall, starting a point apart.
    const line = [
      { left: 60, right: 140, top: 283, bottom: 298.5 },
      { left: 140, right: 190, top: 284, bottom: 297 },
      { left: 190, right: 320, top: 283, bottom: 298.5 },
    ]
    assert.deepEqual(linesFromRuns(line), [{ left: 60, right: 320, top: 283, bottom: 298.5 }])
  })

  await test('a tall run does not drag in the line below it', () => {
    // The bug a reader photographed. Under the old rule one run a quarter
    // taller than the text was enough, and what it took in made the line
    // taller still, so the rest of the selection arrived as one lozenge.
    for (const em of [19, 24, 30, 45, 60, 120, 400]) {
      const runs = [...paragraph(6), run(100, em, 150, 190)]
      const lines = linesFromRuns(runs)
      assert.equal(lines.length, 6, `a run of ${em} points left ${lines.length} lines`)
      // A run within the allowance is text, and a line covers its text; past
      // it the run is furniture and sets no line's height at all.
      const most = em <= 15 * 1.6 ? em : 15
      for (const line of lines) {
        assert.ok(
          line.bottom - line.top <= most + 0.001,
          `a run of ${em} points made a line ${line.bottom - line.top} tall`,
        )
      }
    }
  })

  await test('a formula on a line widens it without heightening it', () => {
    const line = [...paragraph(1), run(100, 40, 150, 190)]
    assert.deepEqual(linesFromRuns(line), [{ left: 60, right: 320, top: 88, bottom: 103 }])
  })

  await test('a drop cap widens the two lines it stands across', () => {
    // It is not a line of its own: it is the first two lines reaching left.
    const lines = linesFromRuns([...paragraph(3), run(118, 39, 30, 58)])
    assert.equal(lines.length, 3)
    assert.equal(lines[0].left, 30)
    assert.equal(lines[1].left, 30)
    assert.equal(lines[2].left, 60)
    for (const line of lines) assert.ok(line.bottom - line.top <= 16)
  })

  await test('a heading the drag ran into is a line of its own', () => {
    const lines = linesFromRuns([run(60, 30, 60, 240), ...paragraph(3)])
    assert.equal(lines.length, 4)
    assert.equal(Math.round(lines[0].bottom - lines[0].top), 30)
  })

  await test('a drag over nothing but a title is ordinary there', () => {
    assert.equal(linesFromRuns([run(60, 30, 60, 240), run(96, 30, 60, 200)]).length, 2)
  })

  await test('a superscript stays on its line', () => {
    // A citation marker: a smaller box, raised, still on the line it marks.
    const line = [run(100, 15, 60, 140), run(95, 10, 140, 146), run(100, 15, 146, 320)]
    assert.deepEqual(linesFromRuns(line), [{ left: 60, right: 320, top: 87, bottom: 103 }])
  })

  await test('two columns on one line are one line, as a drag across them is', () => {
    const merged = linesFromRuns([run(100, 15, 60, 300), run(100, 15, 330, 560)])
    assert.equal(merged.length, 1)
    assert.equal(merged[0].left, 60)
    assert.equal(merged[0].right, 560)
  })

  await test('tight leading is still line by line', () => {
    // A 2007 journal sets 9 on 10, and one on nothing at all still breaks:
    // the boxes hang from their baselines, so they barely meet.
    for (const gap of [17, 15.5, 14, 13]) {
      assert.equal(linesFromRuns(paragraph(6, 15, gap)).length, 6, `at a gap of ${gap}`)
    }
  })

  await test('a line of one run is that run, and nothing selected is no lines', () => {
    assert.deepEqual(
      linesFromRuns([{ left: 10, right: 20, top: 30, bottom: 45 }]),
      [{ left: 10, right: 20, top: 30, bottom: 45 }],
    )
    assert.deepEqual(linesFromRuns([]), [])
  })

  await test('a big selection does not overflow the stack', () => {
    // A fold rather than a spread: 200,000 runs on one line is not a real
    // drag, but a spread of them is a RangeError rather than a wrong answer.
    const many = Array.from({ length: 200_000 }, (_, index) => run(100, 15, index, index + 1))
    const merged = linesFromRuns(many)
    assert.equal(merged.length, 1)
    assert.equal(merged[0].right, 200_000)
  })

  await test('boxes whose sides are getters come back as numbers', () => {
    // The window hands over `DOMRect`s, whose sides live on the prototype.
    // Spreading one gives an empty object, and a line built from that is four
    // NaNs — which reached the PDF as a quad no reader could parse.
    class Rect {
      constructor(private readonly l: number, private readonly t: number) {}
      get left() { return this.l }
      get right() { return this.l + 100 }
      get top() { return this.t }
      get bottom() { return this.t + 15 }
    }
    const lines = linesFromRuns([new Rect(60, 100), new Rect(160, 100)])
    assert.equal(lines.length, 1)
    assert.deepEqual(lines[0], { left: 60, right: 260, top: 100, bottom: 115 })
    for (const side of Object.values(lines[0])) assert.ok(Number.isFinite(side), 'a side came back NaN')
  })

  await test('the lines come back in reading order', () => {
    const shuffled = [paragraph(4)[2], paragraph(4)[0], paragraph(4)[3], paragraph(4)[1]]
    const tops = linesFromRuns(shuffled).map((line) => line.top)
    assert.deepEqual(tops, [...tops].sort((a, b) => a - b))
  })

  process.stdout.write(`\n${passed} passed, ${failed} failed\n`)
  if (failures.length > 0) {
    process.stdout.write(`\n${failures.map((f) => `  ✗ ${f}`).join('\n\n')}\n`)
  }
  process.exit(failed === 0 ? 0 : 1)
}

async function countAnnotations(bytes: Uint8Array, pageIndex: number): Promise<number> {
  const { PDFDocument, PDFName, PDFArray, PDFRef } = await import('pdf-lib')
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  // A list that is an object of its own is counted too: reading only the
  // inline kind is the bug `annotations.ts` is there to catch.
  const raw = document.getPage(pageIndex).node.get(PDFName.of('Annots'))
  const annots = raw instanceof PDFRef ? document.context.lookup(raw) : raw
  return annots instanceof PDFArray ? annots.size() : 0
}

/** A meta.json written by the Mac build, if this machine has one. */
function findSampleMeta(): string | null {
  const root = process.env.PAPERTIME_SAMPLE_LIBRARY
    ?? path.join(os.homedir(), 'Library/Containers/com.imtaeheon.PaperTime/Data/Documents/TestLibrary')
  const papers = path.join(root, '.papertime', 'papers')
  try {
    for (const entry of fs.readdirSync(papers)) {
      const file = path.join(papers, entry, 'meta.json')
      if (fs.existsSync(file)) return file
    }
  } catch {
    return null
  }
  return null
}

function findSamplePDF(): string | null {
  const root = process.env.PAPERTIME_SAMPLE_LIBRARY
    ?? path.join(os.homedir(), 'Library/Containers/com.imtaeheon.PaperTime/Data/Documents/TestLibrary')
  try {
    for (const entry of fs.readdirSync(root)) {
      if (entry.toLowerCase().endsWith('.pdf')) return path.join(root, entry)
    }
  } catch {
    return null
  }
  return null
}

/** Exactly the bytes the Mac build wrote for a page of shapes. */
/** A frame with a layout, as the Mac's encoder writes one. */
const MAC_FRAME = `{
  "clips" : true,
  "createdAt" : 811492215.409792,
  "id" : "0D6D2C54-7B12-4E3C-9C10-2C3B1B2E7A11",
  "kind" : "frame",
  "layout" : {
    "align" : "start",
    "direction" : "vertical",
    "gap" : 8,
    "hugs" : true,
    "padding" : 8
  },
  "name" : "프레임 1",
  "points" : [
    [
      100,
      500
    ],
    [
      200,
      600
    ]
  ],
  "style" : {
    "border" : false,
    "corners" : "round",
    "dash" : "solid",
    "endHead" : "none",
    "opacity" : 1,
    "startHead" : "none",
    "stroke" : {
      "alpha" : 1,
      "blue" : 0.12,
      "green" : 0.1,
      "red" : 0.1
    },
    "textSize" : "medium",
    "width" : 2
  },
  "text" : ""
}`

const MAC_SKETCH = `[
  {
    "createdAt" : 811492215.409792,
    "id" : "491F74F4-ADFC-4AEB-9D7B-63920075D4B2",
    "kind" : "rectangle",
    "points" : [
      [
        99.99999999999996,
        700.0000000000009
      ],
      [
        250.00000000000006,
        620.0000000000009
      ]
    ],
    "style" : {
      "border" : false,
      "corners" : "round",
      "dash" : "dashed",
      "endHead" : "arrow",
      "opacity" : 1,
      "startHead" : "none",
      "stroke" : {
        "alpha" : 1,
        "blue" : 0.12,
        "green" : 0.1,
        "red" : 0.1
      },
      "textSize" : "medium",
      "width" : 2
    },
    "text" : "Who?"
  }
]`

void main()
