/**
 * Writing the drawing layer into the PDF itself.
 *
 * This is the second priority of the whole project — "필기가 PDF 파일에
 * 기록됨" — and the reason a Paper Time library is portable at all: the file
 * alone carries everything you can see on the page, so Preview, Acrobat,
 * Zotero or a colleague's reader shows the same marks.
 *
 * The Swift side goes through PDFKit, which builds these annotations for it.
 * There is no PDFKit here, so the dictionaries are written out by hand with
 * pdf-lib. Two consequences worth knowing:
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
import {
  PDFArray,
  PDFDict,
  PDFDocument,
  PDFHexString,
  PDFName,
  PDFNumber,
  PDFRawStream,
  PDFRef,
  PDFString,
  type PDFContext,
  type PDFPage,
} from 'pdf-lib'
import { SketchColor, SketchElement, type Point, type Rect } from '../shared/sketch.js'
import { InkStroke, INK_OWNER } from '../shared/ink.js'
import { rightsHandler, type PDFLock } from '../shared/pdfLock.js'

export const SKETCH_OWNER = 'Paper Time Sketch'
const KEY_SKETCH_ID = 'PTSketchID'
const KEY_SKETCH = 'PTSketch'
const KEY_SKETCH_PART = 'PTSketchPart'
const KEY_INK = 'PTInk'
const KEY_MARKUP_ID = 'PTMarkupID'

/**
 * A PDF text string.
 *
 * pdf-lib's `context.obj()` turns a bare JavaScript string into a `/Name`,
 * so `Contents: 'Why now?'` silently becomes `/Why#20now?` — a name, not the
 * note. Every value that is text goes through here, as a hex string in
 * UTF-16: a note written in Korean is not representable any other way.
 */
function text(value: string) {
  return PDFHexString.fromText(value)
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

export interface MarkupRecord {
  id: string
  kind: 'highlight' | 'underline' | 'strikethrough'
  /**
   * One quad per line of text, each as eight numbers: upper-left,
   * upper-right, lower-left, lower-right — the order `/QuadPoints` specifies,
   * which is not the order anyone would guess.
   */
  quads: number[][]
  color: [number, number, number]
  text: string
  comment?: string
}

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
  const entries: Record<string, unknown> = {
    Subtype: subtype,
    QuadPoints: mark.quads.flat(),
    C: mark.color,
    Contents: text(mark.text),
    [KEY_MARKUP_ID]: text(mark.id),
  }
  if (mark.comment) entries[KEY_MARKUP_ID + 'Comment'] = text(mark.comment)
  return {
    entries,
    rect,
    appearance: content.toString(),
    alphas: mark.kind === 'highlight' ? [{ name: 'PTm', stroke: 1, fill: 1 }] : [],
  }
}

// MARK: - Writing a document

export interface PageDrawing {
  pageIndex: number
  elements: SketchElement[]
  strokes: InkStroke[]
  marks?: MarkupRecord[]
  /**
   * Whether this call owns the page's marks.
   *
   * False leaves every highlight and underline exactly where it was, which is
   * what a save that only touched the pen should do. True replaces the ones
   * carrying our `/PTMarkupID` and leaves anybody else's alone.
   */
  managesMarks?: boolean
}

/**
 * Puts the given pages' drawings into the file, replacing whatever this app
 * had written there before and leaving every other annotation untouched.
 */
export async function writeDrawings(bytes: Uint8Array, pages: PageDrawing[]): Promise<Uint8Array> {
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const context = document.context
  for (const page of pages) {
    const leaf = document.getPage(page.pageIndex)
    if (!leaf) continue
    removeOwned(leaf, context, page.managesMarks ?? false)
    const built: Built[] = [
      ...page.elements.flatMap((element) => {
        const parts = buildElement(element)
        const payload = base64Payload(element)
        return parts.map((part, index) => ({
          ...part,
          entries: {
            ...part.entries,
            T: text(SKETCH_OWNER),
            [KEY_SKETCH_ID]: text(element.id),
            // Only the primary annotation carries the source, so a box and
            // its label do not each claim to be the element.
            ...(index === 0 ? { [KEY_SKETCH]: text(payload) } : {}),
          },
        }))
      }),
      ...page.strokes.map(buildInk).map((part) => ({
        ...part,
        entries: { ...part.entries, T: text(INK_OWNER) },
      })),
      ...(page.managesMarks ? (page.marks ?? []).map(buildMarkup) : []),
    ]
    for (const item of built) {
      attach(leaf, context, item)
    }
  }
  return document.save({ useObjectStreams: false })
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

/** True when the annotation is one this app wrote and may replace. */
function isOwned(dict: PDFDict, includeMarks: boolean): boolean {
  const title = dict.get(PDFName.of('T'))
  const name = title instanceof PDFString || title instanceof PDFHexString ? title.decodeText() : ''
  if (name === SKETCH_OWNER || name === INK_OWNER) return true
  if (dict.get(PDFName.of(KEY_SKETCH_ID))) return true
  if (dict.get(PDFName.of(KEY_INK))) return true
  if (includeMarks && dict.get(PDFName.of(KEY_MARKUP_ID))) return true
  return false
}

function removeOwned(page: PDFPage, context: PDFContext, includeMarks: boolean) {
  const annots = page.node.get(PDFName.of('Annots'))
  if (!(annots instanceof PDFArray)) return
  const keep: unknown[] = []
  for (let index = 0; index < annots.size(); index += 1) {
    const entry = annots.get(index)
    const dict = entry instanceof PDFRef ? context.lookup(entry, PDFDict) : (entry as unknown as PDFDict)
    if (dict instanceof PDFDict && isOwned(dict, includeMarks)) continue
    keep.push(entry)
  }
  page.node.set(PDFName.of('Annots'), context.obj(keep as never))
}

function attach(page: PDFPage, context: PDFContext, item: Built) {
  const dict: Record<string, unknown> = {
    Type: 'Annot',
    Rect: bbox(item.rect),
    F: 4, // Print. Without it some readers show the mark on screen only.
    ...item.entries,
  }
  const annotation = context.obj(dict as never) as unknown as PDFDict
  if (item.appearance) {
    annotation.set(PDFName.of('AP'), context.obj({
      N: appearanceStream(context, item),
    } as never))
  }
  const ref = context.register(annotation)
  const annots = page.node.get(PDFName.of('Annots'))
  if (annots instanceof PDFArray) {
    annots.push(ref)
  } else {
    page.node.set(PDFName.of('Annots'), context.obj([ref] as never))
  }
}

function appearanceStream(context: PDFContext, item: Built): PDFRef {
  const resources: Record<string, unknown> = {}
  if (item.alphas.length > 0) {
    const states: Record<string, unknown> = {}
    for (const alpha of item.alphas) {
      states[alpha.name] = {
        Type: 'ExtGState',
        CA: alpha.stroke,
        ca: alpha.fill,
        ...(alpha.name === 'PTm' ? { BM: 'Multiply' } : {}),
      }
    }
    resources.ExtGState = states
  }
  const body = Buffer.from(item.appearance, 'utf8')
  const stream = PDFRawStream.of(
    context.obj({
      Type: 'XObject',
      Subtype: 'Form',
      FormType: 1,
      BBox: bbox(item.rect),
      Resources: resources,
      Length: body.length,
    } as never) as unknown as PDFDict,
    new Uint8Array(body),
  )
  return context.register(stream)
}

// MARK: - Reading back

/**
 * The elements a page's own annotations describe — for a file that has a
 * drawing in it but no sidecar here yet, which is what a paper annotated on a
 * Mac and opened on Windows looks like.
 */
export async function readDrawings(bytes: Uint8Array): Promise<Map<number, {
  elements: SketchElement[]
  strokes: InkStroke[]
}>> {
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const context = document.context
  const out = new Map<number, { elements: SketchElement[]; strokes: InkStroke[] }>()
  document.getPages().forEach((page, pageIndex) => {
    const annots = page.node.get(PDFName.of('Annots'))
    if (!(annots instanceof PDFArray)) return
    const elements: SketchElement[] = []
    const strokes: InkStroke[] = []
    const seen = new Set<string>()
    for (let index = 0; index < annots.size(); index += 1) {
      const entry = annots.get(index)
      const dict = entry instanceof PDFRef ? context.lookup(entry, PDFDict) : (entry as unknown as PDFDict)
      if (!(dict instanceof PDFDict)) continue
      const payload = dict.get(PDFName.of(KEY_SKETCH))
      if (payload instanceof PDFString || payload instanceof PDFHexString) {
        try {
          const json = Buffer.from(payload.decodeText(), 'base64').toString('utf8')
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
      if (dict.get(PDFName.of(KEY_INK))) {
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
 */
export async function readMarks(bytes: Uint8Array): Promise<Map<number, MarkupRecord[]>> {
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const context = document.context
  const out = new Map<number, MarkupRecord[]>()
  document.getPages().forEach((page, pageIndex) => {
    const annots = page.node.get(PDFName.of('Annots'))
    if (!(annots instanceof PDFArray)) return
    const marks: MarkupRecord[] = []
    for (let index = 0; index < annots.size(); index += 1) {
      const entry = annots.get(index)
      const dict = entry instanceof PDFRef ? context.lookup(entry, PDFDict) : (entry as unknown as PDFDict)
      if (!(dict instanceof PDFDict)) continue
      const subtype = String(dict.get(PDFName.of('Subtype')) ?? '')
      const kind =
        subtype === '/Highlight' ? 'highlight'
        : subtype === '/Underline' ? 'underline'
        : subtype === '/StrikeOut' ? 'strikethrough'
        : null
      if (!kind) continue
      const quadPoints = dict.get(PDFName.of('QuadPoints'))
      if (!(quadPoints instanceof PDFArray)) continue
      const numbers: number[] = []
      for (let k = 0; k < quadPoints.size(); k += 1) {
        const value = quadPoints.get(k)
        if (value instanceof PDFNumber) numbers.push(value.asNumber())
      }
      const quads: number[][] = []
      for (let k = 0; k + 7 < numbers.length; k += 8) quads.push(numbers.slice(k, k + 8))
      if (quads.length === 0) continue
      const colorArray = dict.get(PDFName.of('C'))
      let color: [number, number, number] = [1, 0.84, 0.25]
      if (colorArray instanceof PDFArray && colorArray.size() >= 3) {
        const parts: number[] = []
        for (let k = 0; k < 3; k += 1) {
          const value = colorArray.get(k)
          parts.push(value instanceof PDFNumber ? value.asNumber() : 0)
        }
        color = [parts[0], parts[1], parts[2]]
      }
      const id = dict.get(PDFName.of(KEY_MARKUP_ID))
      const contents = dict.get(PDFName.of('Contents'))
      marks.push({
        id: id instanceof PDFString || id instanceof PDFHexString ? id.decodeText() : `foreign-${pageIndex}-${index}`,
        kind,
        quads,
        color,
        text: contents instanceof PDFString || contents instanceof PDFHexString ? contents.decodeText() : '',
      })
    }
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
  const list = dict.get(PDFName.of('InkList'))
  if (!(list instanceof PDFArray) || list.size() === 0) return null
  const first = list.get(0)
  if (!(first instanceof PDFArray)) return null
  const numbers: number[] = []
  for (let index = 0; index < first.size(); index += 1) {
    const value = first.get(index)
    if (value instanceof PDFNumber) numbers.push(value.asNumber())
  }
  const border = dict.get(PDFName.of('BS'))
  let width = 2
  if (border instanceof PDFDict) {
    const w = border.get(PDFName.of('W'))
    if (w instanceof PDFNumber) width = w.asNumber()
  }
  const colorArray = dict.get(PDFName.of('C'))
  let color = SketchColor.ink
  if (colorArray instanceof PDFArray && colorArray.size() >= 3) {
    const parts: number[] = []
    for (let index = 0; index < 3; index += 1) {
      const value = colorArray.get(index)
      parts.push(value instanceof PDFNumber ? value.asNumber() : 0)
    }
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
 * The file as the reader should show it.
 *
 * Our own ink and shapes are drawn from the sidecars, over the page. The
 * copies in the file would then be drawn twice — once by pdf.js and once by
 * us, a hair out of register — so they are taken out of the bytes handed to
 * the viewer. The file on disk is untouched; this is the same thing the Mac
 * does with `hideOwnedInk` when it lays its overlay over the PDF.
 *
 * Everything else in the file — highlights, notes, a colleague's comments —
 * stays exactly where it was.
 */
/**
 * Whether a file is locked by something other than a password.
 *
 * Both halves have to be true: the document says it is encrypted, *and* one
 * of the rights handlers is named in the bytes. The name alone means nothing
 * — a paper about rights management has these words in its prose, and
 * refusing to open it would be a joke at this app's own expense.
 */
export async function rightsLock(bytes: Uint8Array): Promise<PDFLock | null> {
  let encrypted = false
  try {
    const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
    encrypted = document.isEncrypted
  } catch {
    // Unparseable here is not unparseable everywhere: pdf.js reads more than
    // pdf-lib does, so the reader gets its turn. If it is a rights-locked
    // file, pdf.js says so in its own words and the reader names the handler.
    return null
  }
  if (!encrypted) return null
  const handler = rightsHandler(bytes)
  return handler ? { kind: 'rights', handler } : null
}

export async function stripOwnedForDisplay(bytes: Uint8Array): Promise<Uint8Array> {
  const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false })
  const context = document.context
  let removed = 0
  for (const page of document.getPages()) {
    const annots = page.node.get(PDFName.of('Annots'))
    if (!(annots instanceof PDFArray)) continue
    const keep: unknown[] = []
    for (let index = 0; index < annots.size(); index += 1) {
      const entry = annots.get(index)
      const dict = entry instanceof PDFRef ? context.lookup(entry, PDFDict) : (entry as unknown as PDFDict)
      if (dict instanceof PDFDict && isOwned(dict, true)) {
        removed += 1
        continue
      }
      keep.push(entry)
    }
    if (keep.length !== annots.size()) {
      page.node.set(PDFName.of('Annots'), context.obj(keep as never))
    }
  }
  // Nothing of ours in it: hand back the original bytes rather than a
  // re-encoded copy, which is both faster and less to go wrong.
  if (removed === 0) return bytes
  return document.save({ useObjectStreams: false })
}
