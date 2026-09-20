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
import { PaperMeta, PaperState } from '../shared/model.js'
import { entryFor, formatEntry, protectTitle } from '../shared/bibtex.js'
import { escapeLaTeX } from '../shared/latexTable.js'
import { readDrawings, writeDrawings, stripOwnedForDisplay } from '../main/pdfwrite.js'
import { encodeSwiftJSON as encode } from '../shared/coding.js'

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

  process.stdout.write(`\n${passed} passed, ${failed} failed\n`)
  if (failures.length > 0) {
    process.stdout.write(`\n${failures.map((f) => `  ✗ ${f}`).join('\n\n')}\n`)
  }
  process.exit(failed === 0 ? 0 : 1)
}

async function countAnnotations(bytes: Uint8Array, pageIndex: number): Promise<number> {
  const { PDFDocument, PDFName, PDFArray } = await import('pdf-lib')
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const annots = document.getPage(pageIndex).node.get(PDFName.of('Annots'))
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
