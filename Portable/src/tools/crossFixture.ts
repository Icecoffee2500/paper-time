/**
 * A PDF with annotations written by this build's appender — the file the
 * Mac's compaction has to fold.
 *
 * Run through `tools/cross-fixture.mjs`. Without `--base` it makes the two
 * Helvetica pages the tests use and appends one save carrying one of every
 * kind of mark this build writes: a highlight of two lines with a comment,
 * an underline without one, a box and a card of the sketch layer, and a pen
 * stroke. That is `Tests/PDFUpdateTests/Fixtures/portable-appended.pdf`,
 * which the Swift tests hold the comparison to. With `--saves N` it appends
 * N further saves that toggle a second box on and off, ending with it off,
 * so a file long enough to be due for compaction ends in the same state it
 * began in — what the Mac's session will rebuild.
 */
import fs from 'node:fs'
import { PDFDocument, PDFHexString, PDFName, PDFString, StandardFonts, type PDFContext } from 'pdf-lib'
import { writeDrawingsDetailed, type MarkupRecord, type PageDrawing } from '../main/pdfwrite.js'
import { InkStroke } from '../shared/ink.js'
import { rectToQuad } from '../shared/marks.js'
import { SketchColor, SketchElement, SketchStyle } from '../shared/sketch.js'

export const MARK_ID = 'C3A6D2E0-5B1F-4E7A-9C2D-1F0E8B7A6D5C'
export const UNDERLINE_ID = '7D4B9F21-3C8E-4A6D-B1F5-2E9C0A7D4B31'
export const BOX_ID = '491F74F4-ADFC-4AEB-9D7B-63920075D4B2'
export const CARD_ID = 'A0E1F2D3-C4B5-4A69-8778-9695A4B3C2D1'
export const EXTRA_ID = '5E6F7A8B-9C0D-4E1F-A2B3-C4D5E6F7A8B9'

const hex = (value: string) => PDFHexString.fromText(value)

function annotation(context: PDFContext, fields: Record<string, unknown>) {
  return context.register(context.obj({ Type: 'Annot', F: 4, ...fields } as never))
}

/** Two pages of Helvetica text; page 0 carries a highlight and its popup
 *  made by "another app", page 1 a link — the Mac's fixture, in pdf-lib. */
export async function basePages(): Promise<Uint8Array> {
  const document = await PDFDocument.create()
  const font = await document.embedFont(StandardFonts.Helvetica)
  const first = document.addPage([612, 792])
  const second = document.addPage([612, 792])
  first.drawText('The office of the reader is to read, and to mark what was read.', { x: 72, y: 700, size: 12, font })
  first.drawText('A second line, for a second quad.', { x: 72, y: 300, size: 12, font })
  first.drawText('And a third, under a line.', { x: 72, y: 286, size: 12, font })
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
  first.node.set(PDFName.of('Annots'), context.obj([highlightRef, popup]))
  second.node.set(PDFName.of('Annots'), context.obj([link]))
  return document.save({ useObjectStreams: false })
}

// A shape carries the moment it was made; made once so every save replays
// the same shape.
const MADE = new Date(Date.UTC(2026, 8, 26, 9, 0, 0))

export function marks(): MarkupRecord[] {
  return [
    {
      id: MARK_ID,
      kind: 'highlight',
      quads: [rectToQuad({ x: 72, y: 300, width: 250, height: 11 }), rectToQuad({ x: 72, y: 286, width: 120, height: 11 })],
      color: [1, 0.84, 0.25],
      text: 'A second line, for a second quad. And a third',
      comment: 'why here? — 여기가 왜',
    },
    {
      id: UNDERLINE_ID,
      kind: 'underline',
      quads: [rectToQuad({ x: 72, y: 698, width: 200, height: 12 })],
      color: [0.42, 0.71, 0.98],
      text: 'The office of the reader is to read',
    },
  ]
}

export function elements(extra: boolean): SketchElement[] {
  const dashed = new SketchStyle()
  dashed.stroke = new SketchColor(0.85, 0.2, 0.2)
  dashed.width = 1.5
  const box = new SketchElement({ id: BOX_ID, kind: 'rectangle', points: [{ x: 100, y: 600 }, { x: 250, y: 680 }], style: dashed, createdAt: MADE })
  const card = new SketchElement({ id: CARD_ID, kind: 'text', points: [{ x: 320, y: 600 }, { x: 480, y: 660 }], text: 'a card with $x^2$', createdAt: MADE })
  const out = [box, card]
  if (extra) out.push(new SketchElement({ id: EXTRA_ID, kind: 'ellipse', points: [{ x: 320, y: 500 }, { x: 400, y: 560 }], createdAt: MADE }))
  return out
}

export function strokes(): InkStroke[] {
  const points = []
  for (let k = 0; k <= 40; k += 1) {
    const t = k / 40
    points.push({ x: 80 + 200 * t, y: 420 + 30 * Math.sin(t * Math.PI * 2), w: 2 })
  }
  return [new InkStroke(points, new SketchColor(0.1, 0.2, 0.7), 'pen')]
}

function page0(extra: boolean): PageDrawing {
  return { pageIndex: 0, elements: elements(extra), strokes: strokes(), marks: marks(), managesMarks: true, managesSketch: true, managesInk: true }
}

export interface Made {
  bytes: Uint8Array
  /** How many updates were appended. */
  saves: number
}

/** `base` plus the first save, plus `more` toggling saves that end where they began. */
export async function crossFixture(base: Uint8Array, more = 0): Promise<Made> {
  let bytes = base
  let saves = 0
  const first = await writeDrawingsDetailed(bytes, [page0(false)])
  if (!first.changed) throw new Error('the first save wrote nothing')
  bytes = first.bytes
  saves += 1
  let extra = false
  for (let k = 0; k < more; k += 1) {
    extra = !extra
    const next = await writeDrawingsDetailed(bytes, [page0(extra)])
    if (!next.changed) throw new Error(`save ${k + 2} wrote nothing`)
    bytes = next.bytes
    saves += 1
  }
  if (extra) {
    const last = await writeDrawingsDetailed(bytes, [page0(false)])
    if (!last.changed) throw new Error('the closing save wrote nothing')
    bytes = last.bytes
    saves += 1
  }
  return { bytes, saves }
}

export async function main(argv: string[]) {
  const option = (name: string) => {
    const k = argv.indexOf(`--${name}`)
    return k >= 0 ? argv[k + 1] : undefined
  }
  const out = option('out')
  if (!out) throw new Error('usage: --out <pdf> [--base <pdf> | --base-out <pdf>] [--saves N]')
  const baseFile = option('base')
  const base = baseFile ? new Uint8Array(fs.readFileSync(baseFile)) : await basePages()
  const made = await crossFixture(base, Number(option('saves') ?? 0))
  const baseOut = option('base-out')
  if (baseOut) fs.writeFileSync(baseOut, base)
  fs.writeFileSync(out, made.bytes)
  process.stdout.write(`${out}: ${base.length} B base + ${made.saves} save(s) = ${made.bytes.length} B\n`)
}
