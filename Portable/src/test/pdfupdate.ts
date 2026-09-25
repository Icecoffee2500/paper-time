/**
 * The appender against every shape of file it has to read, with the checks
 * the app relies on after every save — the same protocol the Mac's
 * `IncrementalUpdateTests` runs, so that a file either build saved reads the
 * same to the other: the paper's bytes are still there, byte for byte;
 * the marks read back; the text of every page is what it was (pdf.js, the
 * reader the window uses); another app's annotations are the same objects
 * in the same order; the chain points back where it should; and a save that
 * changes nothing writes nothing.
 *
 * The fixtures are made here with pdf-lib in the shapes a file comes in —
 * classic table, cross-reference stream with object streams, a list of
 * annotations inline, as an object of its own, shared by two pages — plus
 * the Mac's own TeX fixture (`ligatures.pdf`) and small encrypted files
 * made once with qpdf (`encryptedFixtures.ts`).
 *
 * `PAPERTIME_CORPUS=<dir>` runs the protocol over every PDF in a folder and
 * leaves each save in `PAPERTIME_CORPUS_OUT/<name>/` for the independent
 * checkers (qpdf, pypdf, MuPDF, pdf.js). `PAPERTIME_MAC_APPENDED_PDF=<file>`
 * reads a file the Mac appended to and appends onto it.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { PDFDocument, PDFHexString, PDFName, PDFRef, PDFString, StandardFonts, type PDFContext } from 'pdf-lib'
import * as pdfjs from 'pdfjs-dist/legacy/build/pdf.mjs'
import {
  WriteRefused,
  readDrawings,
  readMarks,
  stripOwnedForDisplay,
  writeDrawings,
  writeDrawingsDetailed,
  writeRefusal,
  type MarkupRecord,
  type PageDrawing,
} from '../main/pdfwrite.js'
import { PDFFile } from '../main/pdfupdate/file.js'
import { Filters, arrayOf, dictOf, intOf, nameOf, refOf, stringBytesOf, type PDFObj } from '../main/pdfupdate/syntax.js'
import { StandardSecurity } from '../main/pdfupdate/crypt.js'
import { isOurs } from '../main/pdfupdate/canonical.js'
import { SketchColor, SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import { rectToQuad } from '../shared/marks.js'
import {
  AES_128,
  AES_128_NO_ANNOTATIONS,
  AES_256_OBJECT_STREAMS,
  AES_256_OBJECT_STREAMS_EMPTY,
  AES_256_USER_PASSWORD,
  RC4_128,
  RC4_40,
  bytesOf,
} from './encryptedFixtures.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const MARK_ID = 'C0FFEE00-1111-4222-8333-444455556666'
const SKETCH_ID = '491F74F4-ADFC-4AEB-9D7B-63920075D4B2'
const SECRET = 'secret words — 비밀'

// MARK: - What the app writes, in miniature

function mark(): MarkupRecord {
  return {
    id: MARK_ID,
    kind: 'highlight',
    quads: [rectToQuad({ x: 72, y: 300, width: 250, height: 11 }), rectToQuad({ x: 72, y: 286, width: 120, height: 11 })],
    color: [1, 0.84, 0.25],
    text: 'the passage',
    comment: SECRET,
  }
}

// Made once: a shape carries the moment it was made, and a save that replays
// it must replay the same shape.
const SQUARE = new SketchElement({ id: SKETCH_ID, kind: 'rectangle', points: [{ x: 100, y: 600 }, { x: 250, y: 700 }] })
const STROKE = new InkStroke([{ x: 50, y: 100, w: 2 }, { x: 80, y: 130, w: 2 }, { x: 120, y: 120, w: 2 }], SketchColor.ink, 'pen')

const square = () => SQUARE
const stroke = () => STROKE

/** Save 1: one of every kind. The stroke goes on the second page when there is one. */
const everything = (pages = 2): PageDrawing[] => [
  { pageIndex: 0, elements: [square()], strokes: pages > 1 ? [] : [stroke()], marks: [mark()], managesMarks: true, managesInk: pages === 1 },
  ...(pages > 1 ? [{ pageIndex: 1, elements: [], strokes: [stroke()], managesSketch: false }] : []),
]

/** Save 3: the highlight goes; the shape and the stroke stay. */
const withoutMark = (pages = 2): PageDrawing[] => [
  { pageIndex: 0, elements: [square()], strokes: pages > 1 ? [] : [stroke()], marks: [], managesMarks: true, managesInk: pages === 1 },
  ...(pages > 1 ? [{ pageIndex: 1, elements: [], strokes: [stroke()], managesSketch: false }] : []),
]

// MARK: - Fixtures

const hex = (value: string) => PDFHexString.fromText(value)

function annotation(context: PDFContext, fields: Record<string, unknown>): PDFRef {
  return context.register(context.obj({ Type: 'Annot', F: 4, ...fields } as never))
}

type Shape = 'table' | 'stream' | 'indirect' | 'shared' | 'certified' | 'padded'

/**
 * Two pages of Helvetica text; page 0 carries a highlight and its popup made
 * by "another app", page 1 a link — the Mac's fixture, in pdf-lib.
 */
async function fixture(shape: Shape): Promise<Uint8Array> {
  const document = await PDFDocument.create()
  const font = await document.embedFont(StandardFonts.Helvetica)
  const first = document.addPage([612, 792])
  const second = document.addPage([612, 792])
  first.drawText('The office of the reader is to read, and to mark what was read.', { x: 72, y: 700, size: 12, font })
  first.drawText('A second line, for a second quad.', { x: 72, y: 300, size: 12, font })
  second.drawText('Page two: the office of the writer is to append.', { x: 72, y: 700, size: 12, font })
  const context = document.context
  const highlightRef = context.nextRef()
  const popup = annotation(context, { Subtype: 'Popup', Rect: [400, 700, 500, 760], Parent: highlightRef, Open: false })
  context.assign(highlightRef, context.obj({
    Type: 'Annot', Subtype: 'Highlight', F: 4, Rect: [72, 696, 300, 712],
    QuadPoints: rectToQuad({ x: 72, y: 696, width: 228, height: 16 }), C: [0.2, 0.8, 0.3],
    Contents: hex('a colleague'), T: hex('Someone Else'), Popup: popup,
  } as never))
  const link = annotation(context, {
    Subtype: 'Link', Rect: [72, 696, 300, 712], Border: [0, 0, 0], A: { S: 'URI', URI: PDFString.of('https://example.org/') },
  })
  if (shape === 'indirect') {
    first.node.set(PDFName.of('Annots'), context.register(context.obj([highlightRef, popup])))
    second.node.set(PDFName.of('Annots'), context.register(context.obj([link])))
  } else if (shape === 'shared') {
    const list = context.register(context.obj([highlightRef, popup]))
    first.node.set(PDFName.of('Annots'), list)
    second.node.set(PDFName.of('Annots'), list)
  } else {
    first.node.set(PDFName.of('Annots'), context.obj([highlightRef, popup]))
    second.node.set(PDFName.of('Annots'), context.obj([link]))
  }
  if (shape === 'certified') {
    // ISO 32000-1 §12.8.2.2: a certification that allows no changes at all.
    const params = context.obj({ Type: 'TransformParams', P: 1, V: '1.2' } as never)
    const reference = context.obj({ Type: 'SigRef', TransformMethod: 'DocMDP', TransformParams: params } as never)
    const signature = context.register(context.obj({ Type: 'Sig', Filter: 'Adobe.PPKLite', Reference: [reference] } as never))
    document.catalog.set(PDFName.of('Perms'), context.obj({ DocMDP: signature } as never))
  }
  if (shape === 'padded') {
    // Room in the page dictionary to write a second /Annots into, without
    // moving a byte of anything after it.
    first.node.set(PDFName.of('PTPad'), PDFString.of('x'.repeat(40)))
  }
  return document.save({ useObjectStreams: shape === 'stream' })
}

const latin1 = (bytes: Uint8Array) => Buffer.from(bytes).toString('latin1')

const macFixture = path.join(__dirname, '../../../Packages/PaperTimeKit/Tests/PDFUpdateTests/Fixtures/ligatures.pdf')

// MARK: - Reading the result as readers do

/** Every page's text and annotation subtypes, as pdf.js sees them. */
async function readWithPDFJS(bytes: Uint8Array, password = ''): Promise<{ texts: string[]; annots: string[][] }> {
  const modules = path.join(__dirname, '../../node_modules/pdfjs-dist')
  const task = pdfjs.getDocument({
    // A copy that is a plain Uint8Array: pdf.js refuses a Buffer.
    data: new Uint8Array(bytes),
    password,
    cMapUrl: `${modules}/cmaps/`,
    cMapPacked: true,
    standardFontDataUrl: `${modules}/standard_fonts/`,
    useSystemFonts: true,
    disableFontFace: true,
    isEvalSupported: false,
    verbosity: 0,
  })
  const document = await task.promise
  try {
    const texts: string[] = []
    const annots: string[][] = []
    for (let number = 1; number <= document.numPages; number += 1) {
      const page = await document.getPage(number)
      const content = await page.getTextContent()
      texts.push((content.items as { str?: string }[]).map((item) => item.str ?? '').join(''))
      annots.push((await page.getAnnotations()).map((a: { subtype: string }) => a.subtype))
      page.cleanup()
    }
    return { texts, annots }
  } finally {
    await document.destroy()
  }
}

/** The file's chain, as our own reader walks it. */
function chain(bytes: Uint8Array, password = '') {
  const file = new PDFFile(bytes)
  if (file.isEncrypted && !file.repaired) {
    const encrypt = dictOf(file.resolve(file.trailer.get('Encrypt')))!
    const id0 = stringBytesOf(arrayOf(file.trailer.get('ID'))?.[0]) ?? new Uint8Array()
    file.security = new StandardSecurity(encrypt, id0, Buffer.from(password, 'utf8'))
  }
  return file
}

/** The references a page's /Annots holds, in order — another app's only
 *  when asked, since a file that went through this build before already
 *  holds ours, and ours are exactly what a save may replace. */
function annotRefs(file: PDFFile, index: number, foreignOnly = false): string[] {
  const page = file.pages()[index]
  return (arrayOf(file.resolve(page.dict.get('Annots'))) ?? [])
    .filter((e) => !foreignOnly || !isOurs(file.resolveQuietly(e)))
    .map((e) => {
      const r = refOf(e)
      return r ? `${r.num} ${r.gen} R` : 'direct'
    })
}

/**
 * Whether the current version of the file — every object in use, decrypted —
 * still holds `needle` in a string or a stream: where a deleted comment
 * must no longer be.
 */
function currentVersionHolds(needle: string, file: PDFFile): string[] {
  const utf8 = Buffer.from(needle, 'utf8')
  const utf16 = Buffer.from(`﻿${needle}`, 'utf16le').swap16()
  const contains = (hay: Uint8Array) => Buffer.from(hay).includes(utf8) || Buffer.from(hay).includes(utf16)
  const search = (o: PDFObj): boolean => {
    switch (o.t) {
      case 'string': return contains(o.v)
      case 'array': return o.v.some(search)
      case 'dict': return o.v.pairs.some(([, v]) => search(v))
      case 'stream': {
        let data = o.data
        try { data = Filters.decode(o.dict, o.data) } catch { /* as it is */ }
        return o.dict.pairs.some(([, v]) => search(v)) || contains(data)
      }
      default: return false
    }
  }
  const found: string[] = []
  for (const num of [...file.entries.keys()].sort((a, b) => a - b)) {
    if (!file.isInUse(num)) continue
    let o: PDFObj
    try { o = file.object(num) } catch { continue }
    if (search(o)) found.push(`${num} ${nameOf(dictOf(o)?.get('Subtype')) ?? nameOf(dictOf(o)?.get('Type')) ?? '?'}`)
  }
  return found
}

// MARK: - The protocol

export interface ProtocolResult {
  issues: string[]
  appended: number[]
  ms: number[]
  saves: Uint8Array[]
}

/**
 * Four saves on one file — add, the same again, remove, the same again —
 * and the things that must hold after each. Returns what did not.
 */
export async function protocol(original: Uint8Array, password = ''): Promise<ProtocolResult> {
  const issues: string[] = []
  const appended: number[] = []
  const ms: number[] = []
  const saves: Uint8Array[] = []
  const options = { password }
  const before = chain(original, password)
  const pages = before.pages().length
  const inkPage = pages > 1 ? 1 : 0
  const pdfjs0 = await readWithPDFJS(original, password)

  // 1. Every kind of mark.
  let t = Date.now()
  const first = await writeDrawingsDetailed(original, everything(pages), options)
  ms.push(Date.now() - t)
  if (!first.changed) return { issues: ['save 1 wrote nothing'], appended, ms, saves }
  const once = first.bytes
  saves.push(once)
  appended.push(once.length - original.length)
  if (Buffer.compare(Buffer.from(once.subarray(0, original.length)), Buffer.from(original)) !== 0) issues.push('save 1: the original bytes changed')
  const after = chain(once, password)
  if (after.repaired) issues.push('save 1: our reader repairs the result')
  if (intOf(after.sections[0]?.trailer.get('Prev')) !== before.startxref) issues.push('save 1: /Prev is not the old startxref')
  if (after.sections.length !== before.sections.length + 1) issues.push(`save 1: ${after.sections.length} sections`)
  const id0 = (f: PDFFile) => Buffer.from(stringBytesOf(arrayOf(f.trailer.get('ID'))?.[0]) ?? []).toString('hex')
  if (id0(before) && id0(after) !== id0(before)) issues.push('save 1: /ID[0] changed')
  if (after.sections[0]?.kind !== before.sections[0]?.kind) issues.push(`save 1: the new section is a ${after.sections[0]?.kind}`)
  const marks1 = (await readMarks(once, options)).get(0) ?? []
  const ours1 = marks1.find((m) => m.id === MARK_ID)
  if (!ours1) issues.push('save 1: the mark is not on page 0')
  else if (ours1.comment !== SECRET || ours1.quads.length !== 2) issues.push(`save 1: the mark reads ${JSON.stringify(ours1)}`)
  const drawings1 = await readDrawings(once, options)
  if (!drawings1.get(0)?.elements.some((e) => e.id === SKETCH_ID)) issues.push('save 1: no square on page 0')
  if ((drawings1.get(inkPage)?.strokes.length ?? 0) !== 1) issues.push(`save 1: no stroke on page ${inkPage}`)
  // Another app's annotations are the same objects, in the same order.
  const foreign0 = annotRefs(before, 0, true)
  const refs1 = annotRefs(after, 0, true)
  if (refs1.join() !== foreign0.join()) issues.push(`save 1: /Annots of page 0 is ${refs1} (was ${foreign0})`)
  const pdfjs1 = await readWithPDFJS(once, password)
  if (pdfjs1.texts.length !== pdfjs0.texts.length) issues.push(`save 1: pdf.js reads ${pdfjs1.texts.length} pages instead of ${pdfjs0.texts.length}`)
  else {
    const changed = pdfjs0.texts.map((text, i) => (text !== pdfjs1.texts[i] ? i : -1)).filter((i) => i >= 0)
    if (changed.length > 0) issues.push(`save 1: the text changed on pages ${changed}`)
  }
  if (!pdfjs1.annots[0]?.includes('Highlight') || !pdfjs1.annots[0]?.includes('Square')) issues.push(`save 1: pdf.js sees ${pdfjs1.annots[0]} on page 0`)
  if (!pdfjs1.annots[inkPage]?.includes('Ink')) issues.push(`save 1: pdf.js sees ${pdfjs1.annots[inkPage]} on page ${inkPage}`)
  const shown = await stripOwnedForDisplay(once, options)
  if (shown === once) issues.push('save 1: nothing hidden for the screen')
  else {
    const screen = await readWithPDFJS(shown, password)
    if (screen.annots[0]?.includes('Highlight') && screen.annots[0].filter((s) => s === 'Highlight').length !== pdfjs0.annots[0].filter((s) => s === 'Highlight').length) {
      issues.push(`save 1: the screen copy still shows ours: ${screen.annots[0]}`)
    }
    if (screen.annots[0]?.includes('Square') || screen.annots[inkPage]?.includes('Ink')) issues.push('save 1: the screen copy still shows the drawing')
  }

  // 2. The same marks again: nothing to write.
  t = Date.now()
  const again = await writeDrawings(once, everything(pages), options)
  ms.push(Date.now() - t)
  appended.push(again.length - once.length)
  if (again !== once) issues.push(`save 2: a replay wrote ${again.length - once.length} bytes`)
  saves.push(again)

  // 3. The highlight goes.
  t = Date.now()
  const third = await writeDrawingsDetailed(once, withoutMark(pages), options)
  ms.push(Date.now() - t)
  if (!third.changed) return { issues: [...issues, 'save 3 wrote nothing'], appended, ms, saves }
  const twice = third.bytes
  saves.push(twice)
  appended.push(twice.length - once.length)
  if (Buffer.compare(Buffer.from(twice.subarray(0, once.length)), Buffer.from(once)) !== 0) issues.push('save 3: earlier bytes changed')
  if ((third.stats?.annotationsRemoved ?? 0) < 1) issues.push(`save 3: removed ${third.stats?.annotationsRemoved}`)
  if ((third.stats?.objectsFreed ?? 0) === 0) issues.push('save 3: nothing freed')
  const marks3 = (await readMarks(twice, options)).get(0) ?? []
  if (marks3.some((m) => m.id === MARK_ID)) issues.push('save 3: the removed mark is still there')
  if (!(await readDrawings(twice, options)).get(0)?.elements.some((e) => e.id === SKETCH_ID)) issues.push('save 3: the square went too')
  const third_ = chain(twice, password)
  if (annotRefs(third_, 0, true).join() !== foreign0.join()) issues.push('save 3: another app\'s marks changed')
  const holders = currentVersionHolds(SECRET, third_)
  if (holders.length > 0) issues.push(`save 3: the deleted comment is still in the current version, in ${holders}`)
  if (currentVersionHolds(SECRET, after).length === 0) issues.push('save 1: the comment is not where the check looks')
  const pdfjs3 = await readWithPDFJS(twice, password)
  const changed3 = pdfjs0.texts.map((text, i) => (text !== pdfjs3.texts[i] ? i : -1)).filter((i) => i >= 0)
  if (changed3.length > 0) issues.push(`save 3: the text changed on pages ${changed3}`)

  // 4. Nothing more.
  t = Date.now()
  const fourth = await writeDrawings(twice, withoutMark(pages), options)
  ms.push(Date.now() - t)
  appended.push(fourth.length - twice.length)
  if (fourth !== twice) issues.push(`save 4: nothing wrote ${fourth.length - twice.length} bytes`)
  saves.push(fourth)
  return { issues, appended, ms, saves }
}

async function refusal(bytes: Uint8Array, password = ''): Promise<WriteRefused['reason'] | null> {
  try {
    await writeDrawings(bytes, everything(), { password })
    return null
  } catch (error) {
    if (error instanceof WriteRefused) return error.reason
    throw error
  }
}

// MARK: - The suite

export async function pdfUpdateSuite(test: Test, suite: (name: string) => void) {
  suite('Marks go into the PDF as an incremental update')

  const shapes: [string, () => Promise<Uint8Array>][] = [
    ['classic table', () => fixture('table')],
    ['cross-reference stream, pages in object streams', () => fixture('stream')],
    ['indirect /Annots', () => fixture('indirect')],
    ['one /Annots array on two pages', () => fixture('shared')],
  ]
  if (fs.existsSync(macFixture)) shapes.push(['the Mac\'s TeX fixture (ligatures.pdf)', () => fsp.readFile(macFixture)])
  for (const [name, make] of shapes) {
    await test(`${name}: four saves append, replay nothing, remove, nothing`, async () => {
      const { issues, appended } = await protocol(await make())
      assert.deepEqual(issues, [])
      assert.ok(appended[0] > 0 && appended[1] === 0 && appended[2] > 0 && appended[3] === 0, `appended ${appended}`)
      assert.ok(appended[2] < 4096, `a removal appends a small tail, not ${appended[2]} B`)
    })
  }

  await test('the same file and the same marks make the same bytes', async () => {
    const bytes = await fixture('stream')
    const a = await writeDrawings(bytes, everything())
    const b = await writeDrawings(bytes, everything())
    assert.equal(Buffer.compare(Buffer.from(a), Buffer.from(b)), 0)
  })

  await test('one stroke more appends that stroke, not the page\'s others', async () => {
    const bytes = await fixture('table')
    const strokes = Array.from({ length: 40 }, (_, k) => new InkStroke(
      [{ x: 50 + k, y: 100, w: 2 }, { x: 80 + k, y: 130, w: 2 }], SketchColor.ink, 'pen',
    ))
    const first = await writeDrawingsDetailed(bytes, [{ pageIndex: 1, elements: [], strokes, managesSketch: false }])
    const more = await writeDrawingsDetailed(first.bytes, [{ pageIndex: 1, elements: [], strokes: [...strokes, stroke()], managesSketch: false }])
    assert.ok(more.changed)
    assert.equal(more.stats?.annotationsAdded, 1)
    assert.equal(more.stats?.annotationsRemoved, 0)
    assert.ok(more.bytes.length - first.bytes.length < (first.bytes.length - bytes.length) / 10)
  })

  suite('Encrypted files are written with their own key')

  const encrypted: [string, string, string][] = [
    ['RC4-40', RC4_40, ''],
    ['RC4-128', RC4_128, ''],
    ['AES-128', AES_128, ''],
    ['AES-256 in object streams', AES_256_OBJECT_STREAMS, ''],
    ['AES-256 in object streams, made by qpdf 12', AES_256_OBJECT_STREAMS_EMPTY, ''],
    ['AES-256 with a user password, given', AES_256_USER_PASSWORD, 'secret'],
  ]
  for (const [name, base64, password] of encrypted) {
    await test(`${name}: the four saves, and the marks read back decrypted`, async () => {
      const bytes = bytesOf(base64)
      const { issues, appended } = await protocol(bytes, password)
      assert.deepEqual(issues, [])
      assert.ok(appended[1] === 0 && appended[3] === 0, `replays appended ${appended}`)
      // Nothing of ours in the clear: the comment is in the file only as
      // ciphertext.
      const once = (await writeDrawingsDetailed(bytes, everything(), { password })).bytes
      assert.ok(!latin1(once).includes(Buffer.from(`﻿${SECRET}`, 'utf16le').swap16().toString('latin1')))
    })
  }

  suite('What the appender refuses, it leaves alone')

  await test('a user password nobody gave', async () => {
    const bytes = bytesOf(AES_256_USER_PASSWORD)
    assert.equal(await refusal(bytes), 'needsPassword')
    assert.equal(await writeRefusal(bytes), 'encrypted')
    assert.equal((await readMarks(bytes)).size, 0, 'nothing is read as ours through a wrong key')
    assert.equal(await stripOwnedForDisplay(bytes), bytes)
  })

  await test('permissions that forbid annotations', async () => {
    const bytes = bytesOf(AES_128_NO_ANNOTATIONS)
    assert.equal(await refusal(bytes), 'permissions')
    assert.equal(await writeRefusal(bytes), 'permissions')
  })

  await test('a certified document that allows no changes', async () => {
    assert.equal(await refusal(await fixture('certified')), 'permissions')
  })

  await test('a broken startxref is refused, not repaired by rewriting', async () => {
    const text = latin1(await fixture('table'))
    const broken = text.replace(/startxref\n(\d+)/, (_, n: string) => `startxref\n${Number(n) + 37}`)
    assert.notEqual(broken, text)
    assert.equal(await refusal(Buffer.from(broken, 'latin1')), 'structure')
  })

  await test('an object found only by scanning is a guess, and a guess is refused', async () => {
    const bytes = await fixture('table')
    const text = latin1(bytes)
    // Page 0's entry in the table, pointed four bytes early.
    const page0 = new PDFFile(bytes).pages()[0].ref.num
    const at = text.indexOf(`\n${page0} 0 obj`)
    assert.ok(at > 0)
    const entry = `${String(at + 1).padStart(10, '0')} 00000 n`
    const wrong = `${String(at - 3).padStart(10, '0')} 00000 n`
    assert.ok(text.includes(entry), 'the fixture has the entry the test expects')
    assert.equal(await refusal(Buffer.from(text.replace(entry, wrong), 'latin1')), 'structure')
  })

  await test('a page that says /Annots twice is refused: readers disagree about which one counts', async () => {
    const text = latin1(await fixture('padded'))
    const pad = `/PTPad (${'x'.repeat(40)})`
    assert.ok(text.includes(pad))
    const list = /\/Annots (\[[^\]]*\])/.exec(text)?.[1]
    assert.ok(list)
    const twice = `/Annots ${list}`.padEnd(pad.length, ' ')
    assert.equal(twice.length, pad.length)
    assert.equal(await refusal(Buffer.from(text.replace(pad, twice), 'latin1')), 'structure')
  })

  await test('nothing is ever rewritten: a refused file comes back untouched, marks and all', async () => {
    const bytes = bytesOf(AES_128_NO_ANNOTATIONS)
    await assert.rejects(writeDrawings(bytes, everything()), (error: unknown) => error instanceof WriteRefused)
    assert.equal((await readMarks(bytes)).size, 0)
  })

  suite('Across the two builds')

  const macAppended = process.env.PAPERTIME_MAC_APPENDED_PDF
  if (macAppended && fs.existsSync(macAppended)) {
    await test('a file the Mac appended to reads its marks here, and takes another update', async () => {
      const bytes = await fsp.readFile(macAppended)
      const file = chain(bytes)
      assert.ok(file.sections.length >= 2, 'the Mac left at least one revision')
      const marks = await readMarks(bytes)
      assert.ok([...marks.values()].some((page) => page.some((m) => !m.id.startsWith('foreign-'))), 'the Mac\'s marks read back')
      const { issues, appended } = await protocol(bytes)
      assert.deepEqual(issues, [])
      assert.ok(appended[1] === 0 && appended[3] === 0)
    })
  }

  const corpus = process.env.PAPERTIME_CORPUS
  if (corpus && fs.existsSync(corpus)) {
    const out = process.env.PAPERTIME_CORPUS_OUT ?? path.join(corpus, 'out')
    const files = (await fsp.readdir(corpus)).filter((name) => name.toLowerCase().endsWith('.pdf')).sort()
    for (const name of files) {
      await test(`corpus: ${name}`, async () => {
        const bytes = await fsp.readFile(path.join(corpus, name))
        const { issues, appended, ms, saves } = await protocol(bytes)
        const folder = path.join(out, name.replace(/\.pdf$/i, ''))
        await fsp.mkdir(folder, { recursive: true })
        await fsp.writeFile(path.join(folder, 'original.pdf'), bytes)
        for (let k = 0; k < saves.length; k += 1) await fsp.writeFile(path.join(folder, `save${k + 1}.pdf`), saves[k])
        process.stdout.write(`    ${name}: ${bytes.length} B, appended ${appended.join('/')} B, ${ms.join('/')} ms\n`)
        assert.deepEqual(issues, [])
      })
    }
  }
}
