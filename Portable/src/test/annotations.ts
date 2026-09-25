/**
 * What the file's own annotations go through when this build writes it.
 *
 * Every fixture here is made in the test, with pdf-lib, and made in the three
 * shapes a page's list of annotations comes in: inline, the way pdfTeX writes
 * it; an object of its own, the way PDFKit writes every page it saves; and a
 * page the Mac has appended to, the way its incremental writer leaves one. The
 * encrypted files are the one exception to "made in the test", because
 * pdf-lib cannot encrypt: three tiny ones, made once with qpdf from a page of
 * our own (`encryptedFixtures.ts`). No paper from the corpus is read, and
 * nothing derived from one is kept.
 *
 * `PAPERTIME_MAC_SAVED_PDF=<file>` adds one real file the Mac saved, when a
 * machine has one to hand; it is only read, never written.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import {
  PDFArray,
  PDFDict,
  PDFDocument,
  PDFHexString,
  PDFName,
  PDFRef,
  PDFString,
  type PDFContext,
} from 'pdf-lib'
import {
  WriteRefused,
  isEncryptedPDF,
  readDrawings,
  readMarks,
  stripOwnedForDisplay,
  writeDrawings,
  type MarkupRecord,
} from '../main/pdfwrite.js'
import { namesEncryption } from '../shared/pdfLock.js'
import { SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import { SketchColor } from '../shared/sketch.js'
import { rectToQuad } from '../shared/marks.js'
import { encodeSwiftJSON } from '../shared/coding.js'
import { AES_128, AES_256_OBJECT_STREAMS, RC4_128, bytesOf } from './encryptedFixtures.js'
import {
  describe,
  isLegacyAddition,
  markFrom,
  merged,
  reconcile,
  recordChanges,
  upgradeLegacy,
  type Journal,
} from '../shared/markJournal.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const MAC_MARK_ID = '0B2B0799-5C7E-4F1B-9A62-3D0E7B8C1A2F'
const MAC_NOTE_ID = '7A1C2E3F-4B5D-4E6F-8A9B-0C1D2E3F4A5B'
const MAC_SKETCH_ID = '491F74F4-ADFC-4AEB-9D7B-63920075D4B2'

const hex = (value: string) => PDFHexString.fromText(value)

/** Every annotation on every page, as the objects the list points at. */
async function listing(bytes: Uint8Array) {
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const context = document.context
  return document.getPages().map((page) => {
    const raw = page.node.get(PDFName.of('Annots'))
    const indirect = raw instanceof PDFRef ? raw.toString() : null
    const array = raw instanceof PDFRef ? context.lookup(raw) : raw
    const entries: string[] = []
    const subtypes: string[] = []
    if (array instanceof PDFArray) {
      for (let index = 0; index < array.size(); index += 1) {
        const entry = array.get(index)
        entries.push(entry.toString())
        const dict = entry instanceof PDFRef ? context.lookup(entry) : entry
        subtypes.push(dict instanceof PDFDict ? String(dict.get(PDFName.of('Subtype'))) : '?')
      }
    }
    return { indirect, entries, subtypes }
  })
}

function annotation(context: PDFContext, fields: Record<string, unknown>): PDFRef {
  return context.register(context.obj({ Type: 'Annot', F: 4, ...fields } as never))
}

/** The Mac's text markup: one annotation per line, one `/PTMarkupID` for all. */
function macHighlight(context: PDFContext, lines: number[][], comment: string): PDFRef[] {
  return lines.map(([x, y, width, height]) => {
    const quad = rectToQuad({ x, y, width, height })
    return annotation(context, {
      Subtype: 'Highlight',
      Rect: [x, y, x + width, y + height],
      QuadPoints: quad,
      C: [1, 0.84, 0.25],
      Contents: hex(comment),
      PTComment: hex(comment),
      PTMarkupID: PDFString.of(MAC_MARK_ID),
      T: hex('임태헌'),
      Border: [0, 0, 0],
    })
  })
}

function sketchPayload(): string {
  const element = new SketchElement({
    id: MAC_SKETCH_ID,
    kind: 'rectangle',
    points: [{ x: 100, y: 600 }, { x: 250, y: 700 }],
  })
  return Buffer.from(JSON.stringify(element.encode()), 'utf8').toString('base64')
}

interface Built {
  bytes: Uint8Array
  /** How many annotations each page began with. */
  counts: number[]
}

/**
 * A two-page paper with the annotations a real one carries: the paper's own
 * links, a colleague's highlight, and everything the Mac puts on a page — a
 * three-line highlight with a comment, a note with its popup, a shape and a
 * pen stroke.
 */
async function paper(shape: 'inline' | 'object' | 'shared', options: { dangling?: boolean } = {}): Promise<Built> {
  const document = await PDFDocument.create()
  const first = document.addPage([612, 792])
  const second = document.addPage([612, 792])
  const context = document.context
  const links = Array.from({ length: 6 }, (_, index) => annotation(context, {
    Subtype: 'Link',
    Rect: [72, 700 - index * 14, 200, 710 - index * 14],
    Border: [0, 0, 0],
    A: { S: 'URI', URI: PDFString.of(`https://example.org/${index}`) },
  }))
  const colleague = annotation(context, {
    Subtype: 'Highlight',
    Rect: [72, 400, 300, 412],
    QuadPoints: rectToQuad({ x: 72, y: 400, width: 228, height: 12 }),
    C: [0.2, 0.8, 0.3],
    Contents: hex('a colleague'),
    T: hex('Someone Else'),
  })
  const macMark = macHighlight(context, [[72, 500, 400, 11], [72, 486, 400, 11], [72, 472, 210, 11]], '왜 여기서?')
  const noteRef = context.nextRef()
  const popup = annotation(context, { Subtype: 'Popup', Rect: [124, 514, 196, 550], Parent: noteRef })
  context.assign(noteRef, context.obj({
    Type: 'Annot',
    Subtype: 'Text',
    Rect: [100, 490, 120, 510],
    Contents: hex('A sticky note'),
    PTMarkupID: PDFString.of(MAC_NOTE_ID),
    Popup: popup,
  } as never))
  const square = annotation(context, {
    Subtype: 'Square',
    Rect: [100, 600, 250, 700],
    T: PDFString.of('Paper Time Sketch'),
    PTSketchID: PDFString.of(MAC_SKETCH_ID),
    PTSketch: PDFString.of(sketchPayload()),
    BS: { W: 2 },
    C: [0.1, 0.1, 0.12],
  })
  const ink = annotation(context, {
    Subtype: 'Ink',
    Rect: [40, 90, 130, 140],
    InkList: [[50, 100, 80, 130, 120, 120]],
    BS: { W: 2.5 },
    C: [0.1, 0.2, 0.8],
    T: PDFString.of('Paper Time'),
    PTInk: PDFString.of('Paper Time'),
  })
  const onFirst: PDFRef[] = [...links, colleague, ...macMark, noteRef, popup, square, ink]
  if (options.dangling) onFirst.push(PDFRef.of(9999))
  const onSecond = links.slice(0, 2)
  if (shape === 'inline') {
    first.node.set(PDFName.of('Annots'), context.obj(onFirst))
    second.node.set(PDFName.of('Annots'), context.obj(onSecond))
  } else if (shape === 'object') {
    first.node.set(PDFName.of('Annots'), context.register(context.obj(onFirst)))
    second.node.set(PDFName.of('Annots'), context.register(context.obj(onSecond)))
  } else {
    const list = context.register(context.obj(onFirst))
    first.node.set(PDFName.of('Annots'), list)
    second.node.set(PDFName.of('Annots'), list)
  }
  const bytes = await document.save({ useObjectStreams: false })
  const counts = shape === 'shared' ? [onFirst.length, onFirst.length] : [onFirst.length, onSecond.length]
  return { bytes, counts }
}

/** A highlight made here, as the window hands it over. */
function portableMark(id = 'C0FFEE00-1111-4222-8333-444455556666'): MarkupRecord {
  return {
    id,
    kind: 'highlight',
    quads: [rectToQuad({ x: 72, y: 300, width: 250, height: 11 })],
    color: [1, 0.84, 0.25],
    text: 'the passage',
  }
}

const latin1 = (bytes: Uint8Array) => Buffer.from(bytes).toString('latin1')

/**
 * Appends one incremental update to a file, the way the Mac's writer does:
 * the new and changed objects after the old bytes, a cross-reference section
 * naming only them, and a trailer pointing back at the one before.
 */
function appendUpdate(base: Uint8Array, objects: [number, string][], root: string, size: number): Uint8Array {
  const text = latin1(base)
  const prev = Number(/startxref\s+(\d+)\s+%%EOF\s*$/.exec(text)?.[1])
  assert.ok(Number.isFinite(prev), 'the base must end in a startxref')
  let body = text.endsWith('\n') ? '' : '\n'
  let cursor = base.length + body.length
  const offsets: [number, number][] = []
  for (const [number, content] of objects) {
    const chunk = `${number} 0 obj\n${content}\nendobj\n`
    offsets.push([number, cursor])
    body += chunk
    cursor += Buffer.byteLength(chunk, 'latin1')
  }
  let xref = 'xref\n'
  for (const [number, offset] of [...offsets].sort((a, b) => a[0] - b[0])) {
    xref += `${number} 1\n${String(offset).padStart(10, '0')} 00000 n \n`
  }
  xref += `trailer\n<< /Size ${size} /Root ${root} /Prev ${prev} >>\nstartxref\n${cursor}\n%%EOF\n`
  return new Uint8Array(Buffer.concat([Buffer.from(base), Buffer.from(body + xref, 'latin1')]))
}

/**
 * A pdfTeX-shaped paper — an inline list of links — that the Mac has saved a
 * highlight, a shape and a stroke into, incrementally: the original bytes
 * untouched, and after them a new list as an object of its own, the page
 * pointed at it, and the three annotations.
 */
async function macIncremental(): Promise<{ bytes: Uint8Array; base: Uint8Array; links: number }> {
  const document = await PDFDocument.create()
  const page = document.addPage([612, 792])
  const context = document.context
  const links = Array.from({ length: 5 }, (_, index) => annotation(context, {
    Subtype: 'Link',
    Rect: [72, 700 - index * 14, 200, 710 - index * 14],
    A: { S: 'URI', URI: PDFString.of(`https://example.org/${index}`) },
  }))
  page.node.set(PDFName.of('Annots'), context.obj(links))
  const base = await document.save({ useObjectStreams: false })

  const again = await PDFDocument.load(base, { updateMetadata: false })
  const pageRef = again.getPage(0).ref
  const node = again.getPage(0).node.clone(again.context)
  const next = again.context.largestObjectNumber + 1
  const list = next
  const lines = [next + 1, next + 2]
  const square = next + 3
  const ink = next + 4
  node.set(PDFName.of('Annots'), PDFRef.of(list))
  const markup = (number: number, y: number) => [number, [
    '<< /Type /Annot /Subtype /Highlight /F 4',
    `/Rect [72 ${y} 472 ${y + 11}] /QuadPoints [72 ${y + 11} 472 ${y + 11} 72 ${y} 472 ${y}]`,
    '/C [0.42 0.71 0.98] /Contents <FEFFC65C0020C5ECAE30C11C003F> /PTComment <FEFFC65C0020C5ECAE30C11C003F>',
    `/PTMarkupID (${MAC_MARK_ID}) /T <FEFFC784D0DCD5CC> /Border [0 0 0] >>`,
  ].join('\n')] as [number, string]
  const objects: [number, string][] = [
    [pageRef.objectNumber, node.toString()],
    [list, `[${[...links.map((ref) => ref.toString()), ...[...lines, square, ink].map((n) => `${n} 0 R`)].join(' ')}]`],
    markup(lines[0], 500),
    markup(lines[1], 486),
    [square, `<< /Type /Annot /Subtype /Square /F 4 /Rect [100 600 250 700] /T (Paper Time Sketch) /PTSketchID (${MAC_SKETCH_ID}) /PTSketch (${sketchPayload()}) /BS << /W 2 >> /C [0.1 0.1 0.12] >>`],
    [ink, '<< /Type /Annot /Subtype /Ink /F 4 /Rect [40 90 130 140] /InkList [[50 100 80 130 120 120]] /BS << /W 2.5 >> /C [0.1 0.2 0.8] /T (Paper Time) /PTInk (Paper Time) >>'],
  ]
  const root = String(again.context.trailerInfo.Root)
  return { bytes: appendUpdate(base, objects, root, ink + 1), base, links: links.length }
}

/** The same file with an `/Encrypt` in its trailer, as pdf-lib sees one. */
async function encrypted(): Promise<Uint8Array> {
  const document = await PDFDocument.load((await paper('object')).bytes, { updateMetadata: false })
  const context = document.context
  context.trailerInfo.Encrypt = context.register(context.obj({
    Filter: 'Standard',
    V: 1,
    R: 2,
    O: PDFHexString.of('00'.repeat(32)),
    U: PDFHexString.of('00'.repeat(32)),
    P: -4,
  } as never))
  return document.save({ useObjectStreams: false })
}

export async function annotationSuite(test: Test, suite: (name: string) => void) {
  suite('Every annotation on the page survives a save')

  for (const shape of ['inline', 'object'] as const) {
    await test(`a highlight on a page whose list is ${shape === 'inline' ? 'inline' : 'an object of its own'} adds one and keeps the rest`, async () => {
      const { bytes, counts } = await paper(shape)
      const before = await listing(bytes)
      // As `writePDF` calls it: the page's marks of ours, and the new one.
      const ours = ((await readMarks(bytes)).get(0) ?? []).filter((mark) => !mark.id.startsWith('foreign-'))
      const written = await writeDrawings(bytes, [{
        pageIndex: 0, elements: [], strokes: [], marks: [...ours, portableMark()],
        managesMarks: true, managesSketch: false, managesInk: false,
      }])
      const after = await listing(written)
      // Every entry exactly where it was — the Mac's three lines too, which
      // are already in the file as the mark says — and the new one after.
      assert.equal(after[0].entries.length, counts[0] + 1)
      assert.deepEqual(after[0].entries.slice(0, counts[0]), before[0].entries, 'in the order they were in')
      assert.equal(after[0].subtypes[counts[0]], '/Highlight')
      assert.deepEqual(after[1], before[1], 'the other page is untouched')
      if (shape === 'object') {
        assert.equal(after[0].indirect, before[0].indirect, 'the same list object, edited where it is')
      } else {
        assert.equal(after[0].indirect, null, 'an inline list stays inline')
      }
    })
  }

  await test('the Mac\'s marks read back from a list that is an object of its own', async () => {
    const { bytes } = await paper('object')
    const marks = await readMarks(bytes)
    const drawings = await readDrawings(bytes)
    const page = marks.get(0) ?? []
    const mac = page.find((mark) => mark.id === MAC_MARK_ID)
    assert.ok(mac, 'the Mac\'s highlight must be read')
    assert.equal(mac.quads.length, 3, 'three lines, one mark')
    assert.equal(mac.comment, '왜 여기서?')
    assert.equal(mac.text, '', 'the comment is not the quoted text')
    assert.equal(page.filter((mark) => mark.id.startsWith('foreign-')).length, 1, 'and the colleague\'s')
    assert.equal(page.length, 2, 'the note is not a highlight')
    assert.equal(drawings.get(0)?.elements.length, 1)
    assert.equal(drawings.get(0)?.strokes.length, 1)
  })

  await test('rewriting the Mac\'s marks keeps them, with their comment', async () => {
    const { bytes } = await paper('object')
    const marks = (await readMarks(bytes)).get(0) ?? []
    const ours = marks.filter((mark) => !mark.id.startsWith('foreign-'))
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [...ours, portableMark()],
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    const again = (await readMarks(written)).get(0) ?? []
    const mac = again.find((mark) => mark.id === MAC_MARK_ID)
    assert.ok(mac)
    assert.equal(mac.comment, '왜 여기서?')
    assert.equal(mac.quads.length, 3)
    assert.ok(again.some((mark) => mark.id === portableMark().id))
    const text = latin1(written)
    assert.ok(!text.includes('/PTMarkupIDComment'), 'the old key is not written')
    const after = await listing(written)
    assert.ok(after[0].subtypes.includes('/Text') && after[0].subtypes.includes('/Popup'),
      'the Mac\'s note and its popup stay')
    assert.equal(after[0].subtypes.filter((kind) => kind === '/Link').length, 6)
  })

  await test('only a mark that changed is written again', async () => {
    const { bytes, counts } = await paper('object')
    const before = await listing(bytes)
    const ours = ((await readMarks(bytes)).get(0) ?? []).filter((mark) => !mark.id.startsWith('foreign-'))
    // Nothing changed: nothing written, the same bytes back.
    const same = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: ours,
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.equal(same, bytes)
    // The Mac's mark recoloured here: its three lines out, one mark in, and
    // everything else the same objects in the same order.
    const recoloured = ours.map((mark) => ({ ...mark, color: [0.99, 0.56, 0.66] as [number, number, number] }))
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: recoloured,
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    const after = await listing(written)
    assert.equal(after[0].entries.length, counts[0] - 3 + 1)
    assert.deepEqual(after[0].entries.slice(0, counts[0] - 3), before[0].entries.filter((_, index) => ![7, 8, 9].includes(index)))
    // And taken away here: out of the file, and nothing else with it.
    const removed = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [],
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.deepEqual((await listing(removed))[0].entries, before[0].entries.filter((_, index) => ![7, 8, 9].includes(index)))
  })

  await test('a shape the Mac wrote and nobody changed stays the Mac\'s', async () => {
    const { bytes } = await paper('object')
    const elements = (await readDrawings(bytes)).get(0)?.elements ?? []
    assert.equal(elements.length, 1)
    const same = await writeDrawings(bytes, [{ pageIndex: 0, elements, strokes: [], managesInk: false }])
    assert.equal(same, bytes, 'the same element makes nothing to write')
    const moved = elements[0].copy()
    moved.points = moved.points.map((point) => ({ x: point.x + 10, y: point.y }))
    const written = await writeDrawings(bytes, [{ pageIndex: 0, elements: [moved], strokes: [], managesInk: false }])
    const back = (await readDrawings(written)).get(0)?.elements ?? []
    assert.equal(back.length, 1)
    assert.equal(back[0].points[0].x, 110)
  })

  await test('a page that shares its list with another is copied, not edited for both', async () => {
    const { bytes, counts } = await paper('shared')
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [],
      managesMarks: false, managesSketch: true, managesInk: false,
    }])
    const after = await listing(written)
    const before = await listing(bytes)
    assert.equal(after[1].indirect, before[1].indirect, 'the second page keeps the list')
    assert.equal(after[1].entries.length, counts[1], 'with everything in it')
    assert.notEqual(after[0].indirect, before[0].indirect, 'the first page has a copy of its own')
    assert.equal(after[0].entries.length, counts[0] - 1, 'less the shape, which was ours')
  })

  await test('a dangling reference in the list is kept, and read past', async () => {
    const { bytes } = await paper('object', { dangling: true })
    const marks = await readMarks(bytes)
    assert.ok(marks.get(0)?.some((mark) => mark.id === MAC_MARK_ID))
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [portableMark()],
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    assert.ok((await listing(written))[0].entries.includes('9999 0 R'))
  })

  await test('a page nobody drew on here keeps the Mac\'s strokes and shapes', async () => {
    const { bytes } = await paper('object')
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [portableMark()],
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    const drawings = await readDrawings(written)
    assert.equal(drawings.get(0)?.strokes.length, 1)
    assert.equal(drawings.get(0)?.elements.length, 1)
  })

  await test('a page drawn on here replaces the strokes it owns', async () => {
    const { bytes } = await paper('object')
    const stroke = new InkStroke([{ x: 10, y: 10, w: 2 }, { x: 40, y: 40, w: 2 }], SketchColor.red, 'pen')
    const written = await writeDrawings(bytes, [{ pageIndex: 0, elements: [], strokes: [stroke], managesSketch: false }])
    const strokes = (await readDrawings(written)).get(0)?.strokes ?? []
    assert.equal(strokes.length, 1)
    assert.equal(strokes[0].points[0].x, 10)
  })

  await test('nothing to change gives back the same bytes', async () => {
    const { bytes } = await paper('object')
    const written = await writeDrawings(bytes, [{
      pageIndex: 1, elements: [], strokes: [], managesSketch: true, managesInk: true,
    }])
    assert.equal(written, bytes)
  })

  await test('a page index past the end is skipped, not thrown on', async () => {
    const { bytes } = await paper('object')
    const written = await writeDrawings(bytes, [{ pageIndex: 7, elements: [], strokes: [], marks: [portableMark()], managesMarks: true }])
    assert.equal(written, bytes)
  })

  await test('the display copy hides what the window draws and nothing else', async () => {
    const { bytes, counts } = await paper('object')
    const shown = await stripOwnedForDisplay(bytes)
    const after = await listing(shown)
    // Taken out: the Mac's three highlight lines, its shape, its stroke.
    assert.equal(after[0].entries.length, counts[0] - 5)
    assert.deepEqual(
      [...new Set(after[0].subtypes)].sort(),
      ['/Highlight', '/Link', '/Popup', '/Text'],
      'links, the colleague\'s highlight and the Mac\'s note stay for pdf.js to draw',
    )
  })

  suite('A file the Mac saved incrementally')

  await test('its list, its marks, its shape and its stroke read back', async () => {
    const { bytes } = await macIncremental()
    const marks = (await readMarks(bytes)).get(0) ?? []
    assert.equal(marks.length, 1)
    assert.equal(marks[0].id, MAC_MARK_ID)
    assert.equal(marks[0].quads.length, 2)
    assert.equal(marks[0].comment, '왜 여기서?')
    const drawing = (await readDrawings(bytes)).get(0)
    assert.equal(drawing?.elements.length, 1)
    assert.equal(drawing?.strokes.length, 1)
  })

  await test('a highlight made here keeps its links, its shape and its stroke', async () => {
    const { bytes, links } = await macIncremental()
    const before = await listing(bytes)
    assert.ok(before[0].indirect, 'the update made the list an object of its own')
    const ours = ((await readMarks(bytes)).get(0) ?? []).filter((mark) => !mark.id.startsWith('foreign-'))
    const written = await writeDrawings(bytes, [{
      pageIndex: 0, elements: [], strokes: [], marks: [...ours, portableMark()],
      managesMarks: true, managesSketch: false, managesInk: false,
    }])
    const after = await listing(written)
    assert.equal(after[0].indirect, before[0].indirect)
    assert.equal(after[0].subtypes.filter((kind) => kind === '/Link').length, links)
    assert.equal(after[0].subtypes.filter((kind) => kind === '/Square').length, 1)
    assert.equal(after[0].subtypes.filter((kind) => kind === '/Ink').length, 1)
    const marks = (await readMarks(written)).get(0) ?? []
    assert.deepEqual(marks.map((mark) => mark.id).sort(), [MAC_MARK_ID, portableMark().id].sort())
  })

  const real = process.env.PAPERTIME_MAC_SAVED_PDF
  if (real && fs.existsSync(real)) {
    await test('a real file the Mac saved keeps every annotation on the page a highlight goes on', async () => {
      const bytes = new Uint8Array(fs.readFileSync(real))
      const before = await listing(bytes)
      const page = Math.max(0, before.findIndex((one) => one.entries.length > 0))
      const ours = ((await readMarks(bytes)).get(page) ?? []).filter((mark) => !mark.id.startsWith('foreign-'))
      const written = await writeDrawings(bytes, [{
        pageIndex: page, elements: [], strokes: [], marks: [...ours, portableMark()],
        managesMarks: true, managesSketch: false, managesInk: false,
      }])
      const after = await listing(written)
      // Every entry that is not one of our highlights is still there — the
      // links above all, which is what the old write took with it.
      const kept = before[page].entries.filter((_, index) =>
        !['/Highlight', '/Underline', '/StrikeOut'].includes(before[page].subtypes[index]))
      for (const entry of kept) assert.ok(after[page].entries.includes(entry), `${entry} must stay`)
      assert.ok(((await readMarks(written)).get(page) ?? []).some((mark) => mark.id === portableMark().id))
      for (let index = 0; index < before.length; index += 1) {
        if (index !== page) assert.deepEqual(after[index].entries, before[index].entries)
      }
    })
  }

  suite('An encrypted file is written with its own key, or not at all')

  await test('the trailer\'s /Encrypt is found, and /EncryptMetadata is not it', () => {
    const bytes = (text: string) => new Uint8Array(Buffer.from(text, 'latin1'))
    assert.ok(namesEncryption(bytes('trailer\n<< /Size 9 /Encrypt 8 0 R /Root 1 0 R >>')))
    assert.ok(namesEncryption(bytes('<< /Type /XRef /Encrypt << /Filter /Standard >> >>')))
    assert.ok(!namesEncryption(bytes('<< /EncryptMetadata false >>')))
    assert.ok(!namesEncryption(bytes('%PDF-1.7 nothing here')))
  })

  await test('an /Encrypt whose key nobody has is refused, and the bytes left alone', async () => {
    // Zeroed /O and /U: no password reproduces them, so the empty one does
    // not either — the file asks for a password this build was not given.
    const bytes = await encrypted()
    await assert.rejects(
      writeDrawings(bytes, [{ pageIndex: 0, elements: [], strokes: [], marks: [portableMark()], managesMarks: true }]),
      (error: unknown) => error instanceof WriteRefused && error.reason === 'needsPassword',
    )
  })

  await test('nothing is read from it as ours, and nothing is hidden from pdf.js', async () => {
    const bytes = await encrypted()
    assert.equal((await readMarks(bytes)).size, 0)
    assert.equal((await readDrawings(bytes)).size, 0)
    assert.equal(await stripOwnedForDisplay(bytes), bytes)
  })

  for (const [name, base64] of [
    ['AES-128', AES_128],
    ['AES-256 in object streams', AES_256_OBJECT_STREAMS],
    ['RC4-128', RC4_128],
  ] as const) {
    await test(`a file qpdf encrypted with ${name} takes a mark, encrypted with the file's key, and reads it back`, async () => {
      const bytes = bytesOf(base64)
      assert.ok(namesEncryption(bytes))
      assert.ok(await isEncryptedPDF(bytes))
      const written = await writeDrawings(bytes, [{ pageIndex: 0, elements: [], strokes: [], marks: [portableMark()], managesMarks: true }])
      assert.notEqual(written, bytes)
      assert.deepEqual([...written.subarray(0, bytes.length)], [...bytes], 'the original bytes come first')
      const back = (await readMarks(written)).get(0) ?? []
      assert.ok(back.some((mark) => mark.id === portableMark().id), 'the mark reads back through the key')
      // In the clear nowhere: the identifier is in the file only as ciphertext.
      const utf16 = Buffer.from(`\ufeff${portableMark().id}`, 'utf16le').swap16()
      assert.ok(!Buffer.from(written).includes(utf16))
      // For the screen, ours is taken out again — by the same kind of update.
      const shown = await stripOwnedForDisplay(written)
      assert.notEqual(shown, written)
      assert.equal((await readMarks(shown)).size, 0)
    })
  }

  await test('the same page unencrypted is written into, link and all', async () => {
    // The control for the three above: what is refused there is the
    // encryption, not the page.
    const document = await PDFDocument.create()
    const page = document.addPage([300, 200])
    const context = document.context
    page.node.set(PDFName.of('Annots'), context.register(context.obj([annotation(context, {
      Subtype: 'Link', Rect: [40, 60, 140, 72], Border: [0, 0, 0],
    })])))
    const bytes = await document.save({ useObjectStreams: false })
    assert.ok(!namesEncryption(bytes))
    assert.ok(!(await isEncryptedPDF(bytes)))
    const written = await writeDrawings(bytes, [{ pageIndex: 0, elements: [], strokes: [], marks: [portableMark()], managesMarks: true }])
    assert.deepEqual((await listing(written))[0].subtypes, ['/Link', '/Highlight'])
  })

  suite('The comment key')

  await test('a comment is written under /PTComment, and /Contents carries it', async () => {
    const { bytes } = await paper('inline')
    const mark = { ...portableMark(), comment: '다시 보기' }
    const written = await writeDrawings(bytes, [{ pageIndex: 1, elements: [], strokes: [], marks: [mark], managesMarks: true }])
    const document = await PDFDocument.load(written, { updateMetadata: false })
    const list = document.getPage(1).node.get(PDFName.of('Annots')) as PDFArray
    const dict = document.context.lookup(list.get(list.size() - 1)) as PDFDict
    assert.equal((dict.get(PDFName.of('PTComment')) as PDFHexString).decodeText(), '다시 보기')
    assert.equal((dict.get(PDFName.of('Contents')) as PDFHexString).decodeText(), '다시 보기')
    assert.equal(dict.get(PDFName.of('PTMarkupIDComment')), undefined)
    const back = (await readMarks(written)).get(1)?.find((one) => one.id === mark.id)
    assert.equal(back?.comment, '다시 보기')
  })

  await test('a comment written under the old key is still read', async () => {
    const document = await PDFDocument.create()
    const page = document.addPage([612, 792])
    const context = document.context
    page.node.set(PDFName.of('Annots'), context.obj([annotation(context, {
      Subtype: 'Highlight',
      Rect: [72, 300, 322, 311],
      QuadPoints: rectToQuad({ x: 72, y: 300, width: 250, height: 11 }),
      C: [1, 0.84, 0.25],
      Contents: hex('the passage'),
      PTMarkupID: hex(portableMark().id),
      PTMarkupIDComment: hex('예전 메모'),
    })]))
    const marks = (await readMarks(await document.save({ useObjectStreams: false }))).get(0) ?? []
    assert.equal(marks[0].comment, '예전 메모')
    assert.equal(marks[0].text, 'the passage', 'the old files kept the quotation in /Contents')
  })

  suite('The marks journal, as the Mac reads it')

  await test('a journal written here is the Mac\'s bytes, and a removal says so', () => {
    const journal: Journal = {
      device: 'Win-1A2B3C4D',
      name: 'Windows',
      updated: '2026-09-25T02:00:00Z',
      entries: {},
    }
    const mark: MarkupRecord = {
      id: 'C0FFEE00-1111-4222-8333-444455556666',
      kind: 'highlight',
      quads: [rectToQuad({ x: 72, y: 300.25, width: 250.5, height: 11 })],
      color: [0.42, 0.71, 0.98],
      text: 'the passage',
      comment: '메모',
    }
    recordChanges(journal, 3, [], [mark], new Date('2026-09-25T02:00:00Z'))
    recordChanges(journal, 3, [mark], [], new Date('2026-09-25T02:00:05Z'))
    recordChanges(journal, 3, [], [{ ...mark, id: 'D0FFEE00-1111-4222-8333-444455556666' }], new Date('2026-09-25T02:00:09Z'))
    // One line more than the Mac writes, on purpose: a removal written here
    // says `null` where the Mac leaves the key out. Swift decodes both as a
    // removal; this build tells from it that the entry is not one from before
    // 0.9.9. Everything else is the Mac's to the byte.
    const written = encodeSwiftJSON(journal)
    assert.ok(written.includes('"descriptor" : null'))
    assert.equal(written.replace(',\n      "descriptor" : null', ''), MAC_JOURNAL)
  })

  await test('a mark goes through the journal and comes back the same', () => {
    const mark: MarkupRecord = { ...portableMark(), comment: 'why', color: [0.99, 0.56, 0.66] }
    const back = markFrom(describe(mark, 2, '2026-09-25T02:00:00Z'))
    assert.ok(back)
    assert.deepEqual(back.quads, mark.quads)
    assert.deepEqual(back.color, mark.color)
    assert.equal(back.comment, 'why')
    assert.equal(back.text, mark.text)
    assert.equal(back.id, mark.id)
  })

  await test('an unchanged mark is not written again, and a removal says null', () => {
    const journal: Journal = { device: 'Win-X', name: 'Windows', updated: '', entries: {} }
    const mark = portableMark()
    assert.ok(recordChanges(journal, 0, [], [mark], new Date()))
    assert.ok(!recordChanges(journal, 0, [mark], [{ ...mark }], new Date()))
    assert.ok(recordChanges(journal, 0, [mark], [], new Date()))
    assert.equal(journal.entries[mark.id].descriptor, null)
    const other: Journal = { device: 'Win-X', name: 'Windows', updated: '', entries: {} }
    assert.ok(!recordChanges(other, 0, [mark], [], new Date(), new Set([mark.id])), 'still on another page')
  })

  await test('the newest word wins, and a tie goes to the device that sorts first', () => {
    const words = merged([
      { device: 'Mac-B', journal: { device: 'Mac-B', name: 'Mac', updated: '', entries: { A: { at: '2026-09-25T02:00:00Z', descriptor: null } } } },
      { device: 'Mac-A', journal: { device: 'Mac-A', name: 'Mac', updated: '', entries: { A: { at: '2026-09-25T02:00:00Z' }, B: { at: '2026-09-25T01:00:00Z' } } } },
      { device: 'Win-C', journal: { device: 'Win-C', name: 'Windows', updated: '', entries: { B: { at: '2026-09-25T03:00:00Z', descriptor: null } } } },
    ])
    assert.equal(words.get('A')?.device, 'Mac-A')
    assert.equal(words.get('B')?.device, 'Win-C')
  })

  await test('what the file holds, overruled by the journals', () => {
    const inFile = portableMark('AAAAAAAA-1111-4222-8333-444455556666')
    const kept = portableMark('BBBBBBBB-1111-4222-8333-444455556666')
    const file = new Map([[0, [inFile, kept]]])
    const added = describe({ ...portableMark('CCCCCCCC-1111-4222-8333-444455556666'), text: 'kept out of the file' }, 4, '2026-09-25T02:00:00Z')
    const words = merged([
      { device: 'Mac-A', journal: { device: 'Mac-A', name: 'Mac', updated: '', entries: {
        [inFile.id]: { at: '2026-09-25T02:00:00Z' },
        [kept.id]: { at: '2026-09-25T02:00:00Z', descriptor: describe(kept, 0, '2026-09-25T01:00:00Z') },
        [added.id]: { at: '2026-09-25T02:00:00Z', descriptor: added },
      } } },
    ])
    const { pages, dirty } = reconcile(file, words)
    assert.deepEqual(pages.get(0)?.map((mark) => mark.id), [kept.id], 'the Mac took one away')
    assert.equal(pages.get(4)?.[0].text, 'kept out of the file')
    assert.deepEqual([...dirty].sort(), [0, 4])
  })

  await test('a mark already in the file as described makes nothing to write', () => {
    const mark = portableMark()
    const words = merged([{ device: 'Mac-A', journal: { device: 'Mac-A', name: 'Mac', updated: '', entries: {
      [mark.id]: { at: '2026-09-25T02:00:00Z', descriptor: describe(mark, 0, '2026-09-25T02:00:00Z') },
    } } }])
    const { dirty } = reconcile(new Map([[0, [mark]]]), words)
    assert.equal(dirty.size, 0)
  })

  await test('an entry from before 0.9.9 is a mark being made, not taken away', () => {
    assert.ok(isLegacyAddition({ at: '2026-09-20T10:11:12Z' }, 'Win-1A2B3C4D'))
    assert.ok(isLegacyAddition({ at: '2026-09-20T10:11:12Z' }, 'Linux-1A2B3C4D'))
    assert.ok(!isLegacyAddition({ at: '2026-09-20T10:11:12Z', descriptor: null }, 'Win-1A2B3C4D'))
    assert.ok(!isLegacyAddition({ at: '2026-09-20T10:11:12Z' }, 'Mac-1A2B3C4D'), 'the Mac writes removals so')
    const mark = portableMark()
    const words = merged([{ device: 'Linux-1', journal: { device: 'Linux-1', name: 'Linux', updated: '', entries: { [mark.id]: { at: '2026-09-20T10:11:12Z' } } } }])
    assert.deepEqual(reconcile(new Map([[0, [mark]]]), words).pages.get(0)?.map((one) => one.id), [mark.id])
  })

  await test('this device\'s old entries are given their marks from the file', () => {
    const mark = portableMark()
    const gone = 'EEEEEEEE-1111-4222-8333-444455556666'
    const removed = 'FFFFFFFF-1111-4222-8333-444455556666'
    const journal: Journal = { device: 'Win-X', name: 'Windows', updated: '', entries: {
      [mark.id]: { at: '2026-09-20T10:11:12Z' },
      [gone]: { at: '2026-09-20T10:11:12Z' },
      [removed]: { at: '2026-09-21T10:11:12Z', descriptor: null },
    } }
    const file = new Map([[0, [mark, portableMark(removed)]]])
    assert.ok(upgradeLegacy(journal, file))
    assert.equal(journal.entries[mark.id].descriptor?.createdAt, '2026-09-20T10:11:12Z')
    assert.equal(journal.entries[mark.id].descriptor?.pageIndex, 0)
    assert.ok(!('descriptor' in journal.entries[gone]), 'a mark no longer in the file stays gone')
    assert.equal(journal.entries[removed].descriptor, null, 'a removal stays a removal')
    assert.ok(!upgradeLegacy(journal, file), 'once is enough')
  })

  await test('a note is left for the Mac', () => {
    const words = merged([{ device: 'Mac-A', journal: { device: 'Mac-A', name: 'Mac', updated: '', entries: {
      N: { at: '2026-09-25T02:00:00Z', descriptor: { ...describe(portableMark('N'), 0, ''), kind: 'note' } },
    } } }])
    const { pages, dirty } = reconcile(new Map(), words)
    assert.equal(pages.size, 0)
    assert.equal(dirty.size, 0)
  })
}

/**
 * What `JSONCoding.encode(MarkJournal)` writes for the journal the first test
 * builds — one mark made, taken away, and another made after — produced by
 * the Mac's own encoder from this build's file, which it decoded as one
 * removal and one highlight.
 */
const MAC_JOURNAL = `{
  "device" : "Win-1A2B3C4D",
  "entries" : {
    "C0FFEE00-1111-4222-8333-444455556666" : {
      "at" : "2026-09-25T02:00:05Z"
    },
    "D0FFEE00-1111-4222-8333-444455556666" : {
      "at" : "2026-09-25T02:00:09Z",
      "descriptor" : {
        "color" : "blue",
        "comment" : "메모",
        "createdAt" : "2026-09-25T02:00:09Z",
        "id" : "D0FFEE00-1111-4222-8333-444455556666",
        "kind" : "highlight",
        "pageIndex" : 3,
        "quotedText" : "the passage",
        "rects" : [
          [
            [
              72,
              300.25
            ],
            [
              250.5,
              11
            ]
          ]
        ]
      }
    }
  },
  "name" : "Windows",
  "updated" : "2026-09-25T02:00:09Z"
}`

