/**
 * Writing the drawing layer into the PDF itself.
 *
 * This is the second priority of the whole project — "필기가 PDF 파일에
 * 기록됨" — and the reason a Paper Time library is portable at all: the file
 * alone carries everything you can see on the page, so Preview, Acrobat,
 * Zotero or a colleague's reader shows the same marks.
 *
 * The Swift side goes through PDFKit, which builds these annotations for it.
 * There is no PDFKit here, so the dictionaries are written out by hand, and
 * appended to the file as an incremental update by `pdfupdate/` — the port
 * of the Mac's writer, so the two builds leave a paper's bytes alone in the
 * same way and refuse the same files. Two consequences worth knowing:
 *
 *  - Each annotation gets an appearance stream (`/AP`) drawn here rather than
 *    left for the reader to synthesise. Readers disagree about how to draw a
 *    bare `/Square`, and some draw nothing at all.
 *  - A translucent fill is written as real transparency through an
 *    `ExtGState`. PDFKit refuses `/CA` from `setValue(forAnnotationKey:)`, so
 *    the Mac has to flatten a wash onto white; writing the file directly, this
 *    port does not. `/IC` still carries the flattened colour for readers that
 *    ignore the appearance stream, so nothing looks wrong anywhere.
 *
 * Every annotation carries its own source in `/PTSketch`, so whichever side
 * reads the file rebuilds exactly what was drawn regardless of any of this.
 */
import { PDFArray, PDFDict as LibDict, PDFDocument, PDFName, PDFRef as LibRef, type PDFContext } from 'pdf-lib'
import { NewObjects, Opened, Refusal, type PageAnnots, type Stats } from './pdfupdate/writer.js'
import { PDFFile } from './pdfupdate/file.js'
import { StandardSecurity } from './pdfupdate/crypt.js'
import { fingerprint } from './pdfupdate/canonical.js'
import {
  PDFDict,
  arrayOf,
  dictOf,
  nameOf,
  numberOf,
  obj,
  stringBytesOf,
  textOf,
  textString,
  type PDFObj,
  type PDFRef,
} from './pdfupdate/syntax.js'
import { SketchColor, SketchElement, type Point, type Rect } from '../shared/sketch.js'
import { InkStroke, INK_OWNER } from '../shared/ink.js'
import { containerKind, namesEncryption, rightsHandler, type PDFLock } from '../shared/pdfLock.js'
import type { Mark } from '../shared/marks.js'
import { sameMark } from '../shared/markJournal.js'

export const SKETCH_OWNER = 'Paper Time Sketch'
const KEY_SKETCH_ID = 'PTSketchID'
const KEY_SKETCH = 'PTSketch'
const KEY_SKETCH_PART = 'PTSketchPart'
const KEY_INK = 'PTInk'
const KEY_MARKUP_ID = 'PTMarkupID'
/**
 * The reader's comment on a mark, kept apart from `/Contents` — the Mac's
 * `TextMarkupWriter.commentKey`. `/Contents` holds the comment too when there
 * is one, because that is what every other reader shows, and the quoted text
 * when there is not; this key is how the comment is told from a quotation.
 */
const KEY_COMMENT = 'PTComment'
/**
 * Where this build put the comment before 0.9.9 — a key the Mac has never
 * read, so a comment written here was invisible there. Still read, so a file
 * written then does not lose the comment the first time it comes back
 * through; never written again.
 */
const KEY_COMMENT_BEFORE = 'PTMarkupIDComment'

/** Why a file was left as it was: what the appender refused. */
export type RefusedReason = 'encrypted' | 'needsPassword' | 'permissions' | 'structure' | 'verification'

/**
 * Why a file was left as it was.
 *
 * The appender refuses, and writes nothing, when the file is one it cannot
 * add to honestly: encrypted by a handler it does not know or with a
 * password nobody gave (`encrypted`, `needsPassword`), certified or
 * permissioned against annotations (`permissions`), readable only by
 * guessing at its structure (`structure`), or when the result did not read
 * back as it should (`verification`). The drawing stays in its sidecars and
 * the marks in the journal, and the window says so. There is no fallback to
 * rewriting the file: a rewrite takes the original bytes away for good.
 */
export class WriteRefused extends Error {
  constructor(readonly reason: RefusedReason, why = '') {
    super(`Not written: ${reason}${why ? ` (${why})` : ''}.`)
    this.name = 'WriteRefused'
  }

  static from(error: unknown): WriteRefused | null {
    if (!(error instanceof Refusal)) return null
    switch (error.kind) {
      case 'encrypted': return new WriteRefused('encrypted', error.message)
      case 'needsPassword': return new WriteRefused('needsPassword', error.message)
      case 'permissions': return new WriteRefused('permissions', error.message)
      case 'verificationFailed': return new WriteRefused('verification', error.message)
      default: return new WriteRefused('structure', error.message)
    }
  }
}

/** The three things the window can say about a refusal. */
export type KeptReason = 'encrypted' | 'permissions' | 'structure'

export function keptReason(reason: RefusedReason): KeptReason {
  switch (reason) {
    case 'encrypted': case 'needsPassword': return 'encrypted'
    case 'permissions': return 'permissions'
    default: return 'structure'
  }
}

/**
 * A PDF text string.
 *
 * pdf-lib's `context.obj()` turns a bare JavaScript string into a `/Name`,
 * so `Contents: 'Why now?'` silently becomes `/Why#20now?` — a name, not the
 * note. Every value that is text goes through here, as a hex string in
 * UTF-16: a note written in Korean is not representable any other way.
 */
function text(value: string): PDFObj {
  return textString(value)
}

// MARK: - A tiny content-stream builder

/** Builds the operators of an appearance stream in page coordinates. */
class Content {
  private parts: string[] = []

  push(line: string) {
    this.parts.push(line)
    return this
  }

  save() { return this.push('q') }
  restore() { return this.push('Q') }

  gs(name: string) { return this.push(`/${name} gs`) }

  strokeColor(c: SketchColor) {
    return this.push(`${n(c.red)} ${n(c.green)} ${n(c.blue)} RG`)
  }

  fillColor(c: SketchColor) {
    return this.push(`${n(c.red)} ${n(c.green)} ${n(c.blue)} rg`)
  }

  lineWidth(width: number) { return this.push(`${n(width)} w`) }
  roundCaps() { return this.push('1 J').push('1 j') }

  dash(pattern: number[] | null) {
    if (!pattern || pattern.length === 0) return this.push('[] 0 d')
    return this.push(`[${pattern.map((v) => n(Math.max(v, 0.01))).join(' ')}] 0 d`)
  }

  moveTo(p: Point) { return this.push(`${n(p.x)} ${n(p.y)} m`) }
  lineTo(p: Point) { return this.push(`${n(p.x)} ${n(p.y)} l`) }

  curveTo(c1: Point, c2: Point, to: Point) {
    return this.push(`${n(c1.x)} ${n(c1.y)} ${n(c2.x)} ${n(c2.y)} ${n(to.x)} ${n(to.y)} c`)
  }

  /** A quadratic as PDF's cubic — the elevation every bent arrow goes through. */
  quadTo(control: Point, from: Point, to: Point) {
    const c1 = { x: from.x + (2 / 3) * (control.x - from.x), y: from.y + (2 / 3) * (control.y - from.y) }
    const c2 = { x: to.x + (2 / 3) * (control.x - to.x), y: to.y + (2 / 3) * (control.y - to.y) }
    return this.curveTo(c1, c2, to)
  }

  rect(r: Rect) { return this.push(`${n(r.x)} ${n(r.y)} ${n(r.width)} ${n(r.height)} re`) }

  roundedRect(r: Rect, radius: number) {
    const k = 0.5523 * radius
    const x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
    this.moveTo({ x: x0 + radius, y: y0 })
    this.lineTo({ x: x1 - radius, y: y0 })
    this.curveTo({ x: x1 - radius + k, y: y0 }, { x: x1, y: y0 + radius - k }, { x: x1, y: y0 + radius })
    this.lineTo({ x: x1, y: y1 - radius })
    this.curveTo({ x: x1, y: y1 - radius + k }, { x: x1 - radius + k, y: y1 }, { x: x1 - radius, y: y1 })
    this.lineTo({ x: x0 + radius, y: y1 })
    this.curveTo({ x: x0 + radius - k, y: y1 }, { x: x0, y: y1 - radius + k }, { x: x0, y: y1 - radius })
    this.lineTo({ x: x0, y: y0 + radius })
    this.curveTo({ x: x0, y: y0 + radius - k }, { x: x0 + radius - k, y: y0 }, { x: x0 + radius, y: y0 })
    return this.close()
  }

  ellipse(r: Rect) {
    const cx = r.x + r.width / 2
    const cy = r.y + r.height / 2
    const rx = r.width / 2
    const ry = r.height / 2
    const kx = 0.5523 * rx
    const ky = 0.5523 * ry
    this.moveTo({ x: cx + rx, y: cy })
    this.curveTo({ x: cx + rx, y: cy + ky }, { x: cx + kx, y: cy + ry }, { x: cx, y: cy + ry })
    this.curveTo({ x: cx - kx, y: cy + ry }, { x: cx - rx, y: cy + ky }, { x: cx - rx, y: cy })
    this.curveTo({ x: cx - rx, y: cy - ky }, { x: cx - kx, y: cy - ry }, { x: cx, y: cy - ry })
    this.curveTo({ x: cx + kx, y: cy - ry }, { x: cx + rx, y: cy - ky }, { x: cx + rx, y: cy })
    return this.close()
  }

  polygon(points: Point[], close = false) {
    points.forEach((p, index) => (index === 0 ? this.moveTo(p) : this.lineTo(p)))
    if (close) this.close()
    return this
  }

  close() { return this.push('h') }
  stroke() { return this.push('S') }
  fill() { return this.push('f') }
  fillAndStroke() { return this.push('B') }

  toString() { return this.parts.join('\n') }
}

/** PDF numbers: no exponent, and short enough not to bloat the file. */
function n(value: number): string {
  if (!Number.isFinite(value)) return '0'
  const rounded = Math.round(value * 1000) / 1000
  return Object.is(rounded, -0) ? '0' : String(rounded)
}

// MARK: - Assembling one annotation

interface Built {
  /** The annotation dictionary's entries, minus the appearance. */
  entries: Record<string, unknown>
  rect: Rect
  /** The appearance stream's operators, in page coordinates. */
  appearance: string
  /** Alpha values the appearance needs, as ExtGState resources. */
  alphas: { name: string; stroke: number; fill: number }[]
}

function bbox(rect: Rect): number[] {
  return [rect.x, rect.y, rect.x + rect.width, rect.y + rect.height]
}

function colorArray(c: SketchColor): number[] {
  return [c.red, c.green, c.blue]
}

function borderStyle(width: number, dash: number[] | null): Record<string, unknown> {
  const bs: Record<string, unknown> = { Type: 'Border', W: width, S: dash ? 'D' : 'S' }
  if (dash) bs.D = dash.map((v) => Math.max(v, 0.5))
  return bs
}

const LINE_ENDING: Record<string, string> = {
  none: 'None',
  bar: 'None',
  arrow: 'OpenArrow',
  triangle: 'ClosedArrow',
  dot: 'Circle',
}

/**
 * One sketch element as the annotations that stand for it.
 *
 * The same mapping the Swift writer uses, so a page written on either side
 * reads the same in a third-party viewer: a box is a `Square`, an oval a
 * `Circle`, a straight connector a `Line` with its ends declared, a bent one
 * (or one ending in a bar, which `/LE` has no name for) an `Ink` tracing the
 * curve, and words a `FreeText`.
 */
function buildElement(element: SketchElement): Built[] {
  const style = element.style
  const dash = style.dashPattern
  const out: Built[] = []
  const alphaName = 'PTa'
  const wantsAlpha = style.opacity < 0.999 || (style.fill?.alpha ?? 1) < 0.999

  const alphas = (fillAlpha: number) =>
    wantsAlpha
      ? [{ name: alphaName, stroke: style.opacity, fill: style.opacity * fillAlpha }]
      : []

  if (element.kind === 'rectangle' || element.kind === 'ellipse') {
    const rect = element.bounds
    const content = new Content()
    content.save().roundCaps().lineWidth(style.width).dash(dash)
    if (wantsAlpha) content.gs(alphaName)
    const shape = () => {
      if (element.kind === 'ellipse') content.ellipse(element.rect)
      else if (element.cornerRadius > 0 && element.rect.width > element.cornerRadius * 2 && element.rect.height > element.cornerRadius * 2)
        content.roundedRect(element.rect, element.cornerRadius)
      else content.rect(element.rect)
    }
    if (style.fill) {
      content.fillColor(style.fill).strokeColor(style.stroke)
      shape()
      content.fillAndStroke()
    } else {
      content.strokeColor(style.stroke)
      shape()
      content.stroke()
    }
    content.restore()
    const entries: Record<string, unknown> = {
      Subtype: element.kind === 'ellipse' ? 'Circle' : 'Square',
      C: colorArray(style.stroke),
      BS: borderStyle(style.width, dash),
    }
    if (style.fill) entries.IC = colorArray(style.fill.flattenedOnWhite)
    out.push({ entries, rect, appearance: content.toString(), alphas: alphas(style.fill?.alpha ?? 1) })
    if (element.text) out.push(buildLabel(element))
    return out
  }

  if (element.kind === 'text') {
    return [buildFreeText(element)]
  }

  // A connector.
  const rect = element.bounds
  const straight = element.control === null && style.startHead !== 'bar' && style.endHead !== 'bar'
  const content = new Content()
  content.save().roundCaps().lineWidth(style.width).dash(dash).strokeColor(style.stroke)
  if (wantsAlpha) content.gs(alphaName)
  content.moveTo(element.start)
  const control = element.control
  if (control) content.quadTo(control, element.start, element.end)
  else content.lineTo(element.end)
  content.stroke()
  // Heads are solid even on a dashed line.
  content.dash(null)
  for (const [head, tip, direction] of [
    [style.startHead, element.start, element.startDirection],
    [style.endHead, element.end, element.endDirection],
  ] as const) {
    const shape = headShape(head, tip, direction, element.headLength, style.width)
    if (!shape) continue
    if (shape.circle) {
      content.fillColor(style.stroke)
      content.ellipse({
        x: shape.circle.center.x - shape.circle.radius,
        y: shape.circle.center.y - shape.circle.radius,
        width: shape.circle.radius * 2,
        height: shape.circle.radius * 2,
      })
      content.fill()
    } else if (shape.filled) {
      content.fillColor(style.stroke)
      content.polygon(shape.points, true)
      content.fill()
    } else {
      content.polygon(shape.points, false)
      content.stroke()
    }
  }
  content.restore()

  if (straight) {
    return [{
      entries: {
        Subtype: 'Line',
        L: [element.start.x, element.start.y, element.end.x, element.end.y],
        LE: [LINE_ENDING[style.startHead], LINE_ENDING[style.endHead]],
        C: colorArray(style.stroke),
        IC: colorArray(style.stroke),
        BS: borderStyle(style.width, dash),
      },
      rect,
      appearance: content.toString(),
      alphas: alphas(1),
    }]
  }

  // Bent, or ending in a bar: traced as ink, the way the Swift writer does it.
  const paths: number[][] = [flatten(element.polyline())]
  for (const [head, tip, direction] of [
    [style.startHead, element.start, element.startDirection],
    [style.endHead, element.end, element.endDirection],
  ] as const) {
    const shape = headShape(head, tip, direction, element.headLength, style.width)
    if (!shape || shape.circle) continue
    const points = [...shape.points]
    if (head === 'triangle' && points.length > 0) points.push(points[0])
    paths.push(flatten(points))
  }
  return [{
    entries: {
      Subtype: 'Ink',
      InkList: paths,
      C: colorArray(style.stroke),
      BS: borderStyle(style.width, dash),
    },
    rect,
    appearance: content.toString(),
    alphas: alphas(1),
  }]
}

function flatten(points: Point[]): number[] {
  return points.flatMap((p) => [p.x, p.y])
}

function headShape(
  head: string,
  tip: Point,
  d: Point,
  length: number,
  width: number,
): { points: Point[]; filled: boolean; circle?: { center: Point; radius: number } } | null {
  const nx = -d.y
  const ny = d.x
  const base = { x: tip.x - d.x * length, y: tip.y - d.y * length }
  switch (head) {
    case 'none': return null
    case 'arrow': {
      const s = length * 0.5
      return { points: [
        { x: base.x + nx * s, y: base.y + ny * s }, tip, { x: base.x - nx * s, y: base.y - ny * s },
      ], filled: false }
    }
    case 'triangle': {
      const s = length * 0.42
      return { points: [
        tip, { x: base.x + nx * s, y: base.y + ny * s }, { x: base.x - nx * s, y: base.y - ny * s },
      ], filled: true }
    }
    case 'bar': {
      const s = length * 0.45
      return { points: [
        { x: tip.x + nx * s, y: tip.y + ny * s }, { x: tip.x - nx * s, y: tip.y - ny * s },
      ], filled: false }
    }
    case 'dot':
      return { points: [], filled: true, circle: { center: tip, radius: Math.max(width * 1.5, 3) } }
    default: return null
  }
}

/**
 * A text card, or the words inside a box.
 *
 * No appearance stream: laying out text into one means embedding a font, and a
 * note written in Korean would need most of a CJK face carried in every PDF
 * the app touches. `/DA` and `/Contents` are what a `FreeText` is specified to
 * carry, and PDFKit, Preview and Acrobat all lay it out from those. Our own
 * two readers never look at it — they draw from `/PTSketch`.
 */
function buildFreeText(element: SketchElement): Built {
  const style = element.style
  const c = style.stroke
  return {
    entries: {
      Subtype: 'FreeText',
      Contents: text(element.text),
      DA: text(`${n(c.red)} ${n(c.green)} ${n(c.blue)} rg /Helv ${n(style.textPoints)} Tf`),
      Q: 0,
      C: style.fill ? colorArray(style.fill.flattenedOnWhite) : [],
      BS: borderStyle(style.border ? style.width : 0, style.border ? style.dashPattern : null),
    },
    rect: element.rect,
    appearance: '',
    alphas: [],
  }
}

function buildLabel(element: SketchElement): Built {
  const padding = 5
  const inner = {
    x: element.rect.x + padding,
    y: element.rect.y + padding,
    width: Math.max(element.rect.width - padding * 2, 1),
    height: Math.max(element.rect.height - padding * 2, 1),
  }
  const c = element.style.stroke
  return {
    entries: {
      Subtype: 'FreeText',
      Contents: text(element.text),
      DA: text(`${n(c.red)} ${n(c.green)} ${n(c.blue)} rg /Helv ${n(element.style.textPoints)} Tf`),
      Q: 1,
      C: [],
      BS: borderStyle(0, null),
      [KEY_SKETCH_PART]: text('label'),
    },
    rect: inner,
    appearance: '',
    alphas: [],
  }
}

function buildInk(stroke: InkStroke): Built {
  const width = stroke.averageWidth
  const color = stroke.pdfColor
  const rect = stroke.bounds
  const content = new Content()
  content.save().roundCaps().lineWidth(width).strokeColor(color)
  if (color.alpha < 0.999) content.gs('PTa')
  content.polygon(stroke.points.map((p) => ({ x: p.x, y: p.y })))
  content.stroke().restore()
  return {
    entries: {
      Subtype: 'Ink',
      InkList: [flatten(stroke.points.map((p) => ({ x: p.x, y: p.y })))],
      C: colorArray(color),
      BS: borderStyle(width, null),
      [KEY_INK]: text(INK_OWNER),
    },
    rect,
    appearance: content.toString(),
    alphas: color.alpha < 0.999 ? [{ name: 'PTa', stroke: color.alpha, fill: color.alpha }] : [],
  }
}

// MARK: - Marks

/**
 * A highlight, underline or strikethrough, as the window and the file know it.
 *
 * `quads` is one quad per line of text, each as eight numbers: upper-left,
 * upper-right, lower-left, lower-right — the order `/QuadPoints` specifies,
 * which is not the order anyone would guess.
 */
export type MarkupRecord = Mark

/** The five the Mac offers, in `MarkupColor`. */
export const MARKUP_COLORS: Record<string, [number, number, number]> = {
  yellow: [1.0, 0.84, 0.25],
  green: [0.45, 0.83, 0.51],
  blue: [0.42, 0.71, 0.98],
  pink: [0.99, 0.56, 0.66],
  purple: [0.75, 0.6, 0.96],
}

export function nearestMarkupColor(rgb: [number, number, number]): string {
  let best = 'yellow'
  let closest = Infinity
  for (const [name, value] of Object.entries(MARKUP_COLORS)) {
    const distance =
      (value[0] - rgb[0]) ** 2 + (value[1] - rgb[1]) ** 2 + (value[2] - rgb[2]) ** 2
    if (distance < closest) {
      closest = distance
      best = name
    }
  }
  return best
}

function buildMarkup(mark: MarkupRecord): Built {
  const xs = mark.quads.flatMap((q) => [q[0], q[2], q[4], q[6]])
  const ys = mark.quads.flatMap((q) => [q[1], q[3], q[5], q[7]])
  const rect: Rect = {
    x: Math.min(...xs), y: Math.min(...ys),
    width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys),
  }
  const subtype = mark.kind === 'highlight' ? 'Highlight' : mark.kind === 'underline' ? 'Underline' : 'StrikeOut'
  const color = new SketchColor(mark.color[0], mark.color[1], mark.color[2])
  const content = new Content()
  content.save()
  if (mark.kind === 'highlight') {
    // Multiply, so the words stay legible under the wash — what every reader
    // does with a highlight and what the app's own overlay does on screen.
    content.gs('PTm').fillColor(color)
    for (const q of mark.quads) {
      content.polygon([
        { x: q[0], y: q[1] }, { x: q[2], y: q[3] }, { x: q[6], y: q[7] }, { x: q[4], y: q[5] },
      ], true)
      content.fill()
    }
  } else {
    content.strokeColor(color).lineWidth(1).roundCaps()
    for (const q of mark.quads) {
      const top = mark.kind === 'strikethrough'
      const y = top ? (q[1] + q[5]) / 2 : Math.min(q[5], q[7]) + 1
      content.moveTo({ x: q[4], y }).lineTo({ x: q[6], y }).stroke()
    }
  }
  content.restore()
  // What `TextMarkupWriter.apply` writes: the comment is the `/Contents` every
  // reader shows when there is one, the quotation when there is not, and the
  // comment again under its own key so it can be told from a quotation.
  const entries: Record<string, unknown> = {
    Subtype: subtype,
    QuadPoints: mark.quads.flat(),
    C: mark.color,
    Contents: text(mark.comment ? mark.comment : mark.text),
    [KEY_MARKUP_ID]: text(mark.id),
  }
  if (mark.comment) entries[KEY_COMMENT] = text(mark.comment)
  return {
    entries,
    rect,
    appearance: content.toString(),
    alphas: mark.kind === 'highlight' ? [{ name: 'PTm', stroke: 1, fill: 1 }] : [],
  }
}


// MARK: - From a built annotation to the file's objects

/**
 * A value of the kind the builders above write — a number, a list of them,
 * a name as a bare string, a text string already made, a nested record —
 * as a PDF object. Bare strings are names, as pdf-lib read them when the
 * builders were written for it: `Subtype: 'Square'` is `/Square`.
 */
function toObj(value: unknown): PDFObj {
  if (value === null || value === undefined) return obj.array([])
  if (typeof value === 'number') return num(value)
  if (typeof value === 'boolean') return obj.bool(value)
  if (typeof value === 'string') return obj.name(value)
  if (Array.isArray(value)) return obj.array(value.map(toObj))
  if (typeof value === 'object' && 't' in (value as object)) return value as PDFObj
  const d = new PDFDict()
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) d.pairs.push([k, toObj(v)])
  return obj.dict(d)
}

/**
 * A number as the file gets it: the same lexeme `n()` gives the appearance
 * stream, so that an annotation read back from the file and one built again
 * from the same stroke say the same thing byte for byte — which is what
 * lets a second save of the same page find nothing to write.
 */
function num(value: number): PDFObj {
  const s = n(value)
  return /^-?\d+$/.test(s) ? obj.int(Number(s)) : obj.real(s)
}

/** The annotation's dictionary, without its appearance. */
function annotationDict(item: Built): PDFDict {
  const d = new PDFDict()
  d.pairs.push(['Type', obj.name('Annot')])
  d.pairs.push(['Rect', obj.array(bbox(item.rect).map(num))])
  d.pairs.push(['F', obj.int(4)]) // Print. Without it some readers show the mark on screen only.
  for (const [k, v] of Object.entries(item.entries)) d.set(k, toObj(v))
  return d
}

/** The annotation as an object of its own, appearance and all. */
function register(fresh: NewObjects, item: Built): PDFRef {
  const dict = annotationDict(item)
  if (item.appearance) {
    const resources = new PDFDict()
    if (item.alphas.length > 0) {
      const states = new PDFDict()
      for (const alpha of item.alphas) {
        const state = PDFDict.from({ Type: obj.name('ExtGState'), CA: num(alpha.stroke), ca: num(alpha.fill) })
        if (alpha.name === 'PTm') state.set('BM', obj.name('Multiply'))
        states.set(alpha.name, obj.dict(state))
      }
      resources.set('ExtGState', obj.dict(states))
    }
    const body = new Uint8Array(Buffer.from(item.appearance, 'utf8'))
    const stream = obj.stream(PDFDict.from({
      Type: obj.name('XObject'),
      Subtype: obj.name('Form'),
      FormType: obj.int(1),
      BBox: obj.array(bbox(item.rect).map(num)),
      Resources: obj.dict(resources),
    }), body)
    dict.set('AP', obj.dict(PDFDict.from({ N: obj.ref(fresh.add(stream)) })))
  }
  return fresh.add(obj.dict(dict))
}

// MARK: - Writing a document

export interface PageDrawing {
  pageIndex: number
  elements: SketchElement[]
  strokes: InkStroke[]
  marks?: MarkupRecord[]
  /**
   * Whether this call owns the page's shapes. True unless said otherwise:
   * the shapes in the file are rebuilt from `elements`, so an empty list
   * takes them all out.
   */
  managesSketch?: boolean
  /**
   * Whether this call owns the page's ink, likewise. False leaves every
   * stroke in the file exactly as it is — which is what a page drawn on a
   * Mac and never touched here needs: its strokes are in the file and in the
   * Mac's `.drawing`, and in no sidecar of this build's, so "no strokes"
   * would otherwise mean "rub them all out".
   */
  managesInk?: boolean
  /**
   * Whether this call owns the page's marks.
   *
   * False leaves every highlight and underline exactly where it was, which is
   * what a save that only touched the pen should do. True replaces the ones
   * carrying our `/PTMarkupID` and leaves anybody else's alone.
   */
  managesMarks?: boolean
}

export interface WriteOptions {
  /** The user password, for a file that asks for one. */
  password?: string
}

export interface Written {
  /** The original bytes followed by the update — or the very bytes given,
   *  when there was nothing to change. */
  bytes: Uint8Array
  changed: boolean
  /** How many pages the file has, as this reader counts them. */
  pages: number
  stats: Stats | null
}

/**
 * Puts the given pages' drawings into the file, replacing whatever this app
 * had written there before and leaving every other annotation untouched —
 * as an incremental update. The bytes handed back start with the bytes
 * given, byte for byte; the update follows. Nothing to change hands back
 * the very bytes given.
 *
 * Every other annotation means every one: the paper's own links, a
 * colleague's comments, a note made on the Mac. The page's list of them is
 * written again with the same entries in the same order and ours changed;
 * nothing in it is dropped that this call did not put there.
 *
 * Throws `WriteRefused` for a file that cannot be added to honestly — see
 * the class — before touching anything.
 */
export async function writeDrawings(bytes: Uint8Array, pages: PageDrawing[], options: WriteOptions = {}): Promise<Uint8Array> {
  return (await writeDrawingsDetailed(bytes, pages, options)).bytes
}

export async function writeDrawingsDetailed(bytes: Uint8Array, pages: PageDrawing[], options: WriteOptions = {}): Promise<Written> {
  let opened: Opened
  try {
    opened = Opened.open(bytes, { password: Buffer.from(options.password ?? '', 'utf8') })
  } catch (error) {
    throw WriteRefused.from(error) ?? error
  }
  const count = opened.pages.length
  const fresh = opened.newObjects()
  const edits = []
  try {
    for (const page of pages) {
      // A mark another device journalled for a page this copy of the file
      // does not have: skipped, so that one bad page does not lose the save
      // of every other.
      if (!Number.isInteger(page.pageIndex) || page.pageIndex < 0 || page.pageIndex >= count) continue
      const layers: Layers = {
        sketch: page.managesSketch ?? true,
        ink: page.managesInk ?? true,
        marks: page.managesMarks ?? false,
      }
      const existing = opened.annots(page.pageIndex)
      const { remove, add } = planPage(existing, opened.file, layers, page)
      if (remove.length === 0 && add.length === 0) continue
      edits.push({ index: page.pageIndex, removed: remove, added: add.map((item) => register(fresh, item)) })
    }
    if (edits.length === 0) return { bytes, changed: false, pages: count, stats: null }
    const outcome = opened.perform(edits, fresh)
    if (outcome.kind === 'unchanged') return { bytes, changed: false, pages: count, stats: outcome.stats }
    return { bytes: outcome.bytes, changed: true, pages: count, stats: outcome.stats }
  } catch (error) {
    throw WriteRefused.from(error) ?? error
  }
}

/**
 * Whether this build can write into the file, asked without writing: the
 * reason it would refuse, or null. For the process that has to tell the
 * window why a save stays in Paper Time the moment a paper opens.
 */
export async function writeRefusal(bytes: Uint8Array, options: WriteOptions = {}): Promise<KeptReason | null> {
  try {
    Opened.open(bytes, { password: Buffer.from(options.password ?? '', 'utf8') })
    return null
  } catch (error) {
    const refused = WriteRefused.from(error)
    return refused ? keptReason(refused.reason) : 'structure'
  }
}

/**
 * What one page's write takes out and puts in.
 *
 * A shape or a mark that is already in the file exactly as it should be is
 * left alone — the same object, with whatever the writer that made it put in
 * it: the Mac's appearance, its date, its three annotations for three lines.
 * Rewriting it anyway was harmless to the eye and cost everything else: a
 * page the Mac saved came back with its marks folded into this build's shape,
 * which the Mac then took for changed and rewrote, and so on, every save on
 * either side. Only what changed is replaced.
 *
 * The pen's strokes are matched by fingerprint — the digest of the
 * annotation's own dictionary, what `AnnotationFingerprint` does on the Mac:
 * a stroke the file already holds as this build would write it stays, so
 * that a save which changed nothing appends nothing, and one that added a
 * stroke appends that stroke and not the four hundred beside it.
 */
function planPage(
  existing: PageAnnots,
  file: PDFFile,
  layers: Layers,
  page: PageDrawing,
): { remove: number[]; add: Built[] } {
  const remove: number[] = []
  const add: Built[] = []
  const sketches = new Map<string, { indices: number[]; payload: string | null }>()
  const marks = new Map<string, { indices: number[]; mark: MarkupRecord }>()
  const inks = new Map<string, number[]>()
  existing.dicts.forEach((dict, index) => {
    if (!dict) return
    if (layers.sketch && isSketch(dict)) {
      const id = textValue(dict, KEY_SKETCH_ID)
      if (!id) {
        remove.push(index)
        return
      }
      const group = sketches.get(id) ?? { indices: [], payload: null }
      group.indices.push(index)
      const payload = textValue(dict, KEY_SKETCH)
      if (payload !== null) group.payload = payload
      sketches.set(id, group)
    } else if (layers.ink && isInk(dict)) {
      const key = fingerprint(obj.dict(dict), file)
      inks.set(key, [...(inks.get(key) ?? []), index])
    } else if (layers.marks && isManagedMark(dict)) {
      const id = textValue(dict, KEY_MARKUP_ID)!.toUpperCase()
      const shape = markupShape(dict)!
      const known = marks.get(id)
      if (known) {
        known.indices.push(index)
        known.mark.quads.push(...shape.quads)
        return
      }
      marks.set(id, {
        indices: [index],
        mark: {
          id,
          kind: shape.kind,
          quads: [...shape.quads],
          color: colorOf(dict),
          text: '',
          comment: textValue(dict, KEY_COMMENT) || textValue(dict, KEY_COMMENT_BEFORE) || '',
        },
      })
    }
  })

  if (layers.sketch) {
    for (const element of page.elements) {
      const group = sketches.get(element.id)
      sketches.delete(element.id)
      if (group && samePayload(group.payload, element)) continue
      if (group) remove.push(...group.indices)
      const payload = base64Payload(element)
      add.push(...buildElement(element).map((part, index) => ({
        ...part,
        entries: {
          ...part.entries,
          T: text(SKETCH_OWNER),
          [KEY_SKETCH_ID]: text(element.id),
          // Only the primary annotation carries the source, so a box and
          // its label do not each claim to be the element.
          ...(index === 0 ? { [KEY_SKETCH]: text(payload) } : {}),
        },
      })))
    }
    for (const group of sketches.values()) remove.push(...group.indices)
  }

  if (layers.ink) {
    for (const stroke of page.strokes) {
      const built = { ...buildInk(stroke) }
      built.entries = { ...built.entries, T: text(INK_OWNER) }
      const key = fingerprint(obj.dict(annotationDict(built)), file)
      const same = inks.get(key)
      if (same && same.length > 0) {
        same.shift()
        continue
      }
      add.push(built)
    }
    for (const left of inks.values()) remove.push(...left)
  }

  if (layers.marks) {
    for (const mark of page.marks ?? []) {
      if (mark.quads.length === 0) continue
      const id = mark.id.toUpperCase()
      const group = marks.get(id)
      marks.delete(id)
      if (group && sameMark(group.mark, mark)) continue
      if (group) remove.push(...group.indices)
      add.push(buildMarkup(mark))
    }
    for (const group of marks.values()) remove.push(...group.indices)
  }
  return { remove: [...new Set(remove)].sort((a, b) => a - b), add }
}

/** Whether a `/PTSketch` already says what this element would say. */
function samePayload(payload: string | null, element: SketchElement): boolean {
  if (payload === null) return false
  try {
    const json = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'))
    // Compared as values, not bytes: the Mac's encoder and this one may
    // spell the same number or the same slash differently.
    return stableStringify(json) === stableStringify(JSON.parse(JSON.stringify(element.encode())))
  } catch {
    return false
  }
}

function colorOf(dict: PDFDict): [number, number, number] {
  const colorArray = arrayOf(dict.get('C'))
  if (!colorArray || colorArray.length < 3) return [1, 0.84, 0.25]
  const parts = colorArray.slice(0, 3).map((value) => numberOf(value) ?? 0)
  return [parts[0], parts[1], parts[2]]
}

function base64Payload(element: SketchElement): string {
  // Sorted keys, no spacing: the same element must always make the same
  // bytes, or the Mac's "already written" check can never be true.
  const encoded = stableStringify(element.encode())
  return Buffer.from(encoded, 'utf8').toString('base64')
}

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`
  const record = value as Record<string, unknown>
  const keys = Object.keys(record).filter((key) => record[key] !== undefined).sort()
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`).join(',')}}`
}

// MARK: - A page's annotations

/** Which of this app's layers a write replaces on a page. */
interface Layers {
  sketch: boolean
  ink: boolean
  marks: boolean
}

function textValue(dict: PDFDict, key: string): string | null {
  return textOf(dict.get(key)) ?? null
}

/** A shape or a card from either build: `/PTSketchID`, or the sketch owner. */
function isSketch(dict: PDFDict): boolean {
  return dict.has(KEY_SKETCH_ID) || textValue(dict, 'T') === SKETCH_OWNER
}

/**
 * A pen stroke from either build — `InkConverter.isOwned`: `/PTInk`, or an
 * ink annotation titled "Paper Time". A bent arrow is ink too, and it is the
 * sketch's.
 */
function isInk(dict: PDFDict): boolean {
  if (isSketch(dict)) return false
  if (dict.has(KEY_INK)) return true
  return textValue(dict, 'T') === INK_OWNER
}

const MARKUP_KINDS: Record<string, MarkupRecord['kind']> = {
  Highlight: 'highlight',
  Underline: 'underline',
  StrikeOut: 'strikethrough',
}

/**
 * The line quads of a highlight, an underline or a strikethrough.
 *
 * Null for anything else — and for one without `/QuadPoints`, which this
 * build cannot draw and so must never take out of a file it could not put
 * back into.
 */
function markupShape(dict: PDFDict): { kind: MarkupRecord['kind']; quads: number[][] } | null {
  const kind = MARKUP_KINDS[nameOf(dict.get('Subtype')) ?? '']
  if (!kind) return null
  const quadPoints = arrayOf(dict.get('QuadPoints'))
  if (!quadPoints) return null
  const numbers = quadPoints.map(numberOf).filter((v): v is number => v !== undefined)
  const quads: number[][] = []
  for (let k = 0; k + 7 < numbers.length; k += 8) quads.push(numbers.slice(k, k + 8))
  return quads.length > 0 ? { kind, quads } : null
}

/**
 * A mark this build reads back as its own and writes out again.
 *
 * Exactly those — a markup with our identifier and lines to draw. A note the
 * Mac pinned to the page carries the identifier too, but it is not a
 * highlight, nothing here reads it back, and so nothing here may take it out:
 * doing so deleted the note and left its popup behind.
 */
function isManagedMark(dict: PDFDict): boolean {
  return textValue(dict, KEY_MARKUP_ID) !== null && markupShape(dict) !== null
}

function isReplaced(dict: PDFDict, layers: Layers): boolean {
  if (layers.sketch && isSketch(dict)) return true
  if (layers.ink && isInk(dict)) return true
  if (layers.marks && isManagedMark(dict)) return true
  return false
}

// MARK: - Reading back

/**
 * The file, opened to read our own annotations out of: the chain walked as
 * a reader walks it, the key found when the file is encrypted with the
 * standard handler and the empty user password. Null when nothing can be
 * read — another handler, a password — and then nothing is ours: every
 * string in such a file is ciphertext, and an identifier read from it would
 * be noise standing in for a mark.
 */
function openForReading(bytes: Uint8Array, password = ''): { file: PDFFile; pages: ReturnType<PDFFile['pages']> } | null {
  let file: PDFFile
  try {
    file = new PDFFile(bytes)
  } catch {
    return null
  }
  if (file.isEncrypted) {
    const encrypt = dictOf(file.resolveQuietly(file.trailer.get('Encrypt')))
    if (!encrypt) return null
    const id0 = stringBytesOf(arrayOf(file.trailer.get('ID'))?.[0]) ?? new Uint8Array()
    try {
      file.security = new StandardSecurity(encrypt, id0, Buffer.from(password, 'utf8'))
    } catch {
      return null
    }
  }
  try {
    return { file, pages: file.pages() }
  } catch {
    return null
  }
}

/** The annotation dictionaries a page lists, in order. */
function annotationsOf(file: PDFFile, info: { dict: PDFDict }): PDFDict[] {
  const list = arrayOf(file.resolveQuietly(info.dict.get('Annots'))) ?? []
  return list.map((entry) => dictOf(file.resolveQuietly(entry))).filter((d): d is PDFDict => d !== undefined)
}

/**
 * Whether the file is encrypted at all — any `/Encrypt` in the trailer.
 * Whether this build can still write into it is `writeRefusal`'s question:
 * an encrypted paper that opens without asking is written into, with the
 * file's own key.
 */
export async function isEncryptedPDF(bytes: Uint8Array): Promise<boolean> {
  if (namesEncryption(bytes)) return true
  try {
    return new PDFFile(bytes).isEncrypted
  } catch {
    return false
  }
}

/**
 * The elements a page's own annotations describe — for a file that has a
 * drawing in it but no sidecar here yet, which is what a paper annotated on a
 * Mac and opened on Windows looks like.
 */
export async function readDrawings(bytes: Uint8Array, options: WriteOptions = {}): Promise<Map<number, {
  elements: SketchElement[]
  strokes: InkStroke[]
}>> {
  const out = new Map<number, { elements: SketchElement[]; strokes: InkStroke[] }>()
  const opened = openForReading(bytes, options.password)
  if (!opened) return out
  opened.pages.forEach((info, pageIndex) => {
    const elements: SketchElement[] = []
    const strokes: InkStroke[] = []
    const seen = new Set<string>()
    for (const dict of annotationsOf(opened.file, info)) {
      const payload = textValue(dict, KEY_SKETCH)
      if (payload !== null) {
        try {
          const json = Buffer.from(payload, 'base64').toString('utf8')
          const element = SketchElement.from(JSON.parse(json))
          if (!seen.has(element.id)) {
            seen.add(element.id)
            elements.push(element)
          }
        } catch {
          // A payload this build cannot read is left alone rather than
          // guessed at; the annotation itself still shows in the file.
        }
        continue
      }
      if (dict.has(KEY_INK)) {
        const stroke = inkFrom(dict)
        if (stroke) strokes.push(stroke)
      }
    }
    if (elements.length > 0 || strokes.length > 0) out.set(pageIndex, { elements, strokes })
  })
  return out
}

/**
 * The marks a page carries, ours and anyone else's.
 *
 * A highlight in a PDF is `/QuadPoints` — four corners per line of text — and
 * a colour. That is all it is, in every reader, which is why a mark made here
 * shows up in Preview and in a colleague's Acrobat without either of them
 * knowing anything about this app.
 *
 * One mark per identifier, as `TextMarkupWriter.descriptors(in:)` reads them:
 * the Mac writes a highlight across three lines as three annotations that
 * share one `/PTMarkupID`, and read one by one they were three marks — the
 * journal, which keeps one entry per identifier, then kept only the last line.
 */
export async function readMarks(bytes: Uint8Array, options: WriteOptions = {}): Promise<Map<number, MarkupRecord[]>> {
  const out = new Map<number, MarkupRecord[]>()
  const opened = openForReading(bytes, options.password)
  if (!opened) return out
  opened.pages.forEach((info, pageIndex) => {
    const marks: MarkupRecord[] = []
    const byID = new Map<string, MarkupRecord>()
    annotationsOf(opened.file, info).forEach((dict, index) => {
      const shape = markupShape(dict)
      if (!shape) return
      const color = colorOf(dict)
      const own = textValue(dict, KEY_MARKUP_ID)
      const id = own ? own.toUpperCase() : `foreign-${pageIndex}-${index}`
      const known = byID.get(id)
      if (known) {
        known.quads.push(...shape.quads)
        return
      }
      const contents = textValue(dict, 'Contents') ?? ''
      const comment = own ? (textValue(dict, KEY_COMMENT) || textValue(dict, KEY_COMMENT_BEFORE) || '') : ''
      const mark: MarkupRecord = {
        id,
        kind: shape.kind,
        quads: shape.quads,
        color,
        // With a comment the Mac puts the comment in `/Contents`, not the
        // quotation; this build used to keep the quotation there. Whichever
        // it is, the comment is not the text that was marked.
        text: comment && contents === comment ? '' : contents,
      }
      if (comment) mark.comment = comment
      byID.set(id, mark)
      marks.push(mark)
    })
    if (marks.length > 0) out.set(pageIndex, marks)
  })
  return out
}

/** True for a mark this app made, as opposed to one that was already there. */
export function isOurMark(mark: MarkupRecord): boolean {
  return !mark.id.startsWith('foreign-')
}

/**
 * A stroke from a plain ink annotation.
 *
 * This is what the Mac's `InkConverter.drawing(fromOwnedInkOn:)` does in the
 * other direction: the pressure is gone — a PDF ink annotation has one width
 * for the whole stroke — but the shape, the width and the colour are not, and
 * once it is a stroke it can be erased and redrawn like any other.
 */
function inkFrom(dict: PDFDict): InkStroke | null {
  const list = arrayOf(dict.get('InkList'))
  if (!list || list.length === 0) return null
  const first = arrayOf(list[0])
  if (!first) return null
  const numbers = first.map(numberOf).filter((v): v is number => v !== undefined)
  const border = dictOf(dict.get('BS'))
  const width = numberOf(border?.get('W')) ?? 2
  const colorArray = arrayOf(dict.get('C'))
  let color = SketchColor.ink
  if (colorArray && colorArray.length >= 3) {
    const parts = colorArray.slice(0, 3).map((value) => numberOf(value) ?? 0)
    color = new SketchColor(parts[0], parts[1], parts[2])
  }
  const points = []
  for (let index = 0; index + 1 < numbers.length; index += 2) {
    points.push({ x: numbers[index], y: numbers[index + 1], w: width })
  }
  if (points.length === 0) return null
  return new InkStroke(points, color, 'pen')
}

/**
 * Whether a file is locked by something other than a password.
 *
 * Both halves have to be true: the document says it is encrypted, *and* one
 * of the rights handlers is named in the bytes. The name alone means nothing
 * — a paper about rights management has these words in its prose, and
 * refusing to open it would be a joke at this app's own expense.
 */
export async function rightsLock(bytes: Uint8Array): Promise<PDFLock | null> {
  // A container is not a PDF that failed to parse, it is a different file
  // wearing the paper's name — the shape a rights agent leaves behind when it
  // takes the PDF away. Asked first, because pdf-lib will throw on it and the
  // throw says nothing about why.
  if (containerKind(bytes)) {
    return { kind: 'rights', handler: rightsHandler(bytes) ?? '' }
  }
  let encrypted = false
  try {
    const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
    encrypted = document.isEncrypted
  } catch {
    // Unparseable here is not unparseable everywhere: pdf.js reads more than
    // pdf-lib does, so the reader gets its turn. But a file that names a
    // rights handler and will not parse is not a file pdf.js is going to do
    // better with, and letting it through cost an afternoon — it came out as
    // "the file may be damaged" for a file Acrobat opens perfectly well.
    //
    // This is the line the port dropped. The Mac has always had it:
    // `guard let document else { return rightsHandler(in: data).map(.rights) }`
    // in `PDFLock.of(document:data:)`.
    const handler = rightsHandler(bytes)
    return handler ? { kind: 'rights', handler } : null
  }
  if (!encrypted) return null
  const handler = rightsHandler(bytes)
  return handler ? { kind: 'rights', handler } : null
}

/**
 * The file as the reader should show it.
 *
 * Our own ink and shapes are drawn from the sidecars, over the page. The
 * copies in the file would then be drawn twice — once by pdf.js and once by
 * us, a hair out of register — so they are taken out of the bytes handed to
 * the viewer. The file on disk is untouched; this is the same thing the Mac
 * does with `hideOwnedInk` when it lays its overlay over the PDF.
 *
 * Taken out the way everything else is put in: as an incremental update,
 * in memory, that lists each page without ours. It works on an encrypted
 * file too, which the old whole-file rewrite could not — and it costs a few
 * kilobytes instead of a copy of the paper. A file the appender refuses is
 * rewritten by pdf-lib for the screen only, as before; an encrypted one it
 * refuses is shown as it is.
 *
 * Only what the window draws itself is taken out: the pen's strokes, the
 * shapes, and the marks `readMarks` hands it. Everything else in the file —
 * a note pinned on the Mac, a colleague's comments, the links — stays
 * exactly where it was.
 */
export async function stripOwnedForDisplay(bytes: Uint8Array, options: WriteOptions = {}): Promise<Uint8Array> {
  const everything: Layers = { sketch: true, ink: true, marks: true }
  try {
    const opened = Opened.open(bytes, { password: Buffer.from(options.password ?? '', 'utf8') })
    const fresh = opened.newObjects()
    const edits = []
    for (let index = 0; index < opened.pages.length; index += 1) {
      const existing = opened.annots(index)
      const owned: number[] = []
      existing.dicts.forEach((dict, k) => { if (dict && isReplaced(dict, everything)) owned.push(k) })
      if (owned.length > 0) edits.push({ index, removed: owned, added: [] })
    }
    if (edits.length === 0) return bytes
    const outcome = opened.perform(edits, fresh, { freeRemovedObjects: false })
    return outcome.kind === 'appended' ? outcome.bytes : bytes
  } catch (error) {
    if (!(error instanceof Refusal)) throw error
  }
  if (namesEncryption(bytes)) return bytes
  return stripWithPDFLib(bytes, everything)
}

/** The screen copy for a file the appender would not touch: pdf-lib's
 *  whole-file rewrite, never written to disk. */
async function stripWithPDFLib(bytes: Uint8Array, layers: Layers): Promise<Uint8Array> {
  let document: PDFDocument
  try {
    document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  } catch {
    return bytes
  }
  if (document.isEncrypted) return bytes
  const context = document.context
  let removed = 0
  for (const page of document.getPages()) {
    const raw = page.node.get(PDFName.of('Annots'))
    const resolved = raw instanceof LibRef ? context.lookup(raw) : raw
    if (!(resolved instanceof PDFArray)) continue
    const owned: number[] = []
    for (let index = 0; index < resolved.size(); index += 1) {
      const entry = resolved.get(index)
      const dict = entry instanceof LibRef ? context.lookup(entry) : entry
      if (dict instanceof LibDict && isReplaced(fromLibDict(dict, context), layers)) owned.push(index)
    }
    for (const index of owned.reverse()) resolved.remove(index)
    removed += owned.length
  }
  if (removed === 0) return bytes
  return document.save({ useObjectStreams: false })
}

/** Enough of a pdf-lib dictionary, as ours, for the ownership tests. */
function fromLibDict(dict: LibDict, context: PDFContext): PDFDict {
  const out = new PDFDict()
  for (const [key, value] of dict.entries()) {
    const name = key.decodeText()
    const resolved = value instanceof LibRef ? context.lookup(value) : value
    const text = String(resolved)
    if (text.startsWith('/')) out.pairs.push([name, obj.name(text.slice(1))])
    else if (resolved && typeof (resolved as unknown as { decodeText?: () => string }).decodeText === 'function') {
      out.pairs.push([name, textString((resolved as unknown as { decodeText: () => string }).decodeText())])
    } else if (resolved instanceof PDFArray) out.pairs.push([name, obj.array([])])
    else out.pairs.push([name, obj.name('')])
  }
  return out
}
