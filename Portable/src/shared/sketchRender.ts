/**
 * One renderer for the drawing layer, ported from `SketchRenderer.swift`.
 *
 * The Swift original draws into a Core Graphics context in page coordinates
 * and is shared by the Mac's overlay, the iPad's and the PDF's copy. This one
 * does the same job for a canvas: the caller hands it a context already put
 * into page space — origin bottom left, y going up — and it draws the same
 * shapes with the same arithmetic, so a page looks the same on Windows as it
 * does on a Mac.
 *
 * The one place the two can differ is where the words break inside a text
 * card: Core Text lays out with the Mac's system font and this lays out with
 * the font the app bundles. The card's own box is stored in the file, so the
 * shape never moves; only a long label's line breaks can land differently.
 */
import {
  SketchColor,
  SketchElement,
  TEXT_POINTS,
  type Head,
  type Point,
  type Rect,
  rectInset,
  rectMaxY,
  rectMidX,
  rectMidY,
} from './sketch.js'

export type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D

/** The space between the words and the edge of the card they sit on. */
export const TEXT_PADDING = 5

/**
 * The face the drawing layer sets its words in.
 *
 * Bundled rather than borrowed from the system: "the system font" is SF Pro on
 * a Mac, Segoe UI on Windows and whatever the distribution chose on Linux, and
 * a note would be a different width on each. Pretendard is drawn to Apple's
 * metrics and carries Korean and Latin in one family, which is what a paper
 * annotated in both needs.
 */
export const SKETCH_FONT_STACK = '"Pretendard Variable", Pretendard, system-ui, sans-serif'

export interface LaidLine {
  text: string
  /** The line's left edge, from the block's left edge. */
  x: number
  /** The baseline, measured down from the block's top. */
  baseline: number
  width: number
}

export interface Layout {
  lines: LaidLine[]
  size: { width: number; height: number }
}

/** A canvas kept aside purely to measure text without disturbing a drawing. */
let scratch: Ctx | null = null
function measuringContext(): Ctx {
  if (scratch) return scratch
  const canvas = document.createElement('canvas')
  scratch = canvas.getContext('2d')!
  return scratch
}

export function fontSpec(points: number): string {
  return `${points}px ${SKETCH_FONT_STACK}`
}

interface Metrics {
  ascent: number
  descent: number
  lineHeight: number
}

function metrics(ctx: Ctx, points: number): Metrics {
  ctx.font = fontSpec(points)
  const m = ctx.measureText('Hg가')
  const ascent = m.fontBoundingBoxAscent || points * 0.95
  const descent = m.fontBoundingBoxDescent || points * 0.25
  return { ascent, descent, lineHeight: ascent + descent }
}

/**
 * Lays text out, wrapped to a width when one is given and as one long line
 * otherwise, and says how big the block came out — `SketchTypesetter.layout`.
 */
export function layoutText(
  text: string,
  size: keyof typeof TEXT_POINTS,
  width: number | null = null,
  centered = false,
): Layout {
  const points = TEXT_POINTS[size]
  const ctx = measuringContext()
  const { ascent, descent, lineHeight } = metrics(ctx, points)
  ctx.font = fontSpec(points)

  const source = text.length === 0 ? ' ' : text
  const column = width === null ? Infinity : Math.max(width, 4)
  const lines: string[] = []
  for (const paragraph of source.split('\n')) {
    if (column === Infinity) {
      lines.push(paragraph)
      continue
    }
    lines.push(...wrap(ctx, paragraph, column))
  }

  const laid: LaidLine[] = []
  let widest = 0
  lines.forEach((line, index) => {
    // The trailing whitespace a wrapped line ends in is not width.
    const measured = ctx.measureText(line.replace(/\s+$/, '')).width
    laid.push({ text: line, x: 0, baseline: ascent + index * lineHeight, width: measured })
    widest = Math.max(widest, measured)
  })

  const blockWidth = width ?? widest
  const positioned = centered
    ? laid.map((line) => ({ ...line, x: (blockWidth - line.width) / 2 }))
    : laid
  const bottom = laid.length === 0 ? 0 : laid[laid.length - 1].baseline + descent
  return { lines: positioned, size: { width: blockWidth, height: bottom } }
}

/**
 * Breaks a paragraph to a column.
 *
 * Words first, and when a single word is wider than the column — a long DOI,
 * or Korean, which has no spaces to break at — character by character, which
 * is what Core Text does with the same text.
 */
function wrap(ctx: Ctx, paragraph: string, column: number): string[] {
  if (paragraph.length === 0) return ['']
  const out: string[] = []
  let line = ''
  const pieces = paragraph.match(/\S+\s*|\s+/g) ?? [paragraph]
  for (const piece of pieces) {
    const candidate = line + piece
    if (ctx.measureText(candidate.replace(/\s+$/, '')).width <= column || line === '') {
      if (ctx.measureText(candidate.replace(/\s+$/, '')).width > column && line === '') {
        // One piece, too wide on its own: break it by character.
        let run = ''
        for (const character of candidate) {
          if (ctx.measureText(run + character).width > column && run !== '') {
            out.push(run)
            run = character
          } else {
            run += character
          }
        }
        line = run
        continue
      }
      line = candidate
    } else {
      out.push(line)
      line = piece.replace(/^\s+/, '')
    }
  }
  out.push(line)
  return out
}

/** How big a block of text is, alone on the page, plus its padding. */
export function cardSize(
  text: string,
  size: keyof typeof TEXT_POINTS,
  width: number | null = null,
): { width: number; height: number } {
  const inner = width === null ? null : width - TEXT_PADDING * 2
  const block = layoutText(text, size, inner).size
  return { width: block.width + TEXT_PADDING * 2, height: block.height + TEXT_PADDING * 2 }
}

// MARK: - Drawing

export interface RenderOptions {
  /** How much of a fill's own alpha to keep. */
  fillAlphaScale?: number
}

export function drawElements(elements: SketchElement[], ctx: Ctx, options: RenderOptions = {}) {
  for (const element of elements) drawElement(element, ctx, options)
}

export function drawElement(element: SketchElement, ctx: Ctx, options: RenderOptions = {}) {
  ctx.save()
  if (element.style.opacity < 0.999) ctx.globalAlpha = element.style.opacity
  switch (element.kind) {
    case 'rectangle':
    case 'ellipse':
      drawBox(element, ctx, options)
      break
    case 'line':
    case 'arrow':
      drawConnector(element, ctx)
      break
    case 'text':
      drawTextCard(element, ctx, options)
      break
  }
  ctx.restore()
}

/** The outline of a box or an oval, or the curve of a connector. */
export function pathOf(element: SketchElement, ctx: Ctx) {
  ctx.beginPath()
  switch (element.kind) {
    case 'rectangle':
    case 'text': {
      const radius = element.cornerRadius
      const box = element.rect
      if (radius > 0 && box.width > radius * 2 && box.height > radius * 2) {
        ctx.roundRect(box.x, box.y, box.width, box.height, radius)
      } else {
        ctx.rect(box.x, box.y, box.width, box.height)
      }
      break
    }
    case 'ellipse': {
      const r = element.rect
      ctx.ellipse(rectMidX(r), rectMidY(r), r.width / 2, r.height / 2, 0, 0, Math.PI * 2)
      break
    }
    case 'line':
    case 'arrow': {
      ctx.moveTo(element.start.x, element.start.y)
      const control = element.control
      if (control) ctx.quadraticCurveTo(control.x, control.y, element.end.x, element.end.y)
      else ctx.lineTo(element.end.x, element.end.y)
      break
    }
  }
}

function applyStroke(element: SketchElement, ctx: Ctx) {
  ctx.strokeStyle = element.style.stroke.css
  ctx.lineWidth = element.style.width
  ctx.lineJoin = 'round'
  ctx.lineCap = 'round'
  ctx.setLineDash(element.style.dashPattern ?? [])
}

function drawBox(element: SketchElement, ctx: Ctx, options: RenderOptions) {
  const scale = options.fillAlphaScale ?? 1
  if (element.style.fill) {
    pathOf(element, ctx)
    ctx.fillStyle = element.style.fill.withAlpha(element.style.fill.alpha * scale).css
    ctx.fill()
  }
  pathOf(element, ctx)
  applyStroke(element, ctx)
  ctx.stroke()
  if (element.text) drawLabel(element, ctx)
}

function drawConnector(element: SketchElement, ctx: Ctx) {
  pathOf(element, ctx)
  applyStroke(element, ctx)
  ctx.stroke()
  // Heads are solid even on a dashed line.
  ctx.setLineDash([])
  drawHead(element, element.style.startHead, element.start, element.startDirection, ctx)
  drawHead(element, element.style.endHead, element.end, element.endDirection, ctx)
}

/** The head's own outline, as points — the PDF copy traces the same ones. */
export function headPolyline(
  head: Head,
  tip: Point,
  d: Point,
  length: number,
  width: number,
): { points: Point[]; filled: boolean; circle?: { center: Point; radius: number } } | null {
  const n = { x: -d.y, y: d.x }
  const base = { x: tip.x - d.x * length, y: tip.y - d.y * length }
  switch (head) {
    case 'none':
      return null
    case 'arrow': {
      const spread = length * 0.5
      return {
        points: [
          { x: base.x + n.x * spread, y: base.y + n.y * spread },
          tip,
          { x: base.x - n.x * spread, y: base.y - n.y * spread },
        ],
        filled: false,
      }
    }
    case 'triangle': {
      const spread = length * 0.42
      return {
        points: [
          tip,
          { x: base.x + n.x * spread, y: base.y + n.y * spread },
          { x: base.x - n.x * spread, y: base.y - n.y * spread },
        ],
        filled: true,
      }
    }
    case 'bar': {
      const spread = length * 0.45
      return {
        points: [
          { x: tip.x + n.x * spread, y: tip.y + n.y * spread },
          { x: tip.x - n.x * spread, y: tip.y - n.y * spread },
        ],
        filled: false,
      }
    }
    case 'dot': {
      const radius = Math.max(width * 1.5, 3)
      return { points: [], filled: true, circle: { center: tip, radius } }
    }
  }
}

function drawHead(element: SketchElement, head: Head, tip: Point, direction: Point, ctx: Ctx) {
  const shape = headPolyline(head, tip, direction, element.headLength, element.style.width)
  if (!shape) return
  ctx.beginPath()
  if (shape.circle) {
    ctx.arc(shape.circle.center.x, shape.circle.center.y, shape.circle.radius, 0, Math.PI * 2)
  } else {
    shape.points.forEach((p, index) => (index === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)))
    if (shape.filled) ctx.closePath()
  }
  if (shape.filled) {
    ctx.fillStyle = element.style.stroke.css
    ctx.fill()
  } else {
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    ctx.stroke()
  }
}

function drawTextCard(element: SketchElement, ctx: Ctx, options: RenderOptions) {
  const scale = options.fillAlphaScale ?? 1
  if (element.style.fill) {
    pathOf(element, ctx)
    ctx.fillStyle = element.style.fill.withAlpha(element.style.fill.alpha * scale).css
    ctx.fill()
  }
  if (element.style.border) {
    pathOf(element, ctx)
    applyStroke(element, ctx)
    ctx.stroke()
  }
  if (!element.text) return
  const inner = rectInset(element.rect, TEXT_PADDING, TEXT_PADDING)
  const layout = layoutText(element.text, element.style.textSize, inner.width)
  drawLines(layout, { x: inner.x, y: rectMaxY(inner) }, element.style.stroke, element.style.textSize, ctx)
}

/** The words inside a box, centred on it. */
function drawLabel(element: SketchElement, ctx: Ctx) {
  const inner = rectInset(element.rect, TEXT_PADDING, TEXT_PADDING)
  if (inner.width <= 4) return
  const layout = layoutText(element.text, element.style.textSize, inner.width, true)
  const top = rectMidY(inner) + layout.size.height / 2
  ctx.save()
  ctx.beginPath()
  ctx.rect(inner.x, inner.y, inner.width, inner.height)
  ctx.clip()
  drawLines(layout, { x: inner.x, y: top }, element.style.stroke, element.style.textSize, ctx)
  ctx.restore()
}

/**
 * Draws laid-out lines with their block's top-left corner at `origin`, in a
 * page-space context.
 *
 * The context has y going up, so the glyphs would come out upside down. Each
 * line is flipped about its own baseline, which is what the iOS overlay does
 * with `flipsText` — the lines keep their places and only the letters turn.
 */
function drawLines(
  layout: Layout,
  origin: Point,
  color: SketchColor,
  size: keyof typeof TEXT_POINTS,
  ctx: Ctx,
) {
  ctx.save()
  ctx.setLineDash([])
  ctx.fillStyle = color.css
  ctx.font = fontSpec(TEXT_POINTS[size])
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'
  for (const line of layout.lines) {
    const x = origin.x + line.x
    const y = origin.y - line.baseline
    ctx.save()
    ctx.translate(x, y)
    ctx.scale(1, -1)
    ctx.fillText(line.text, 0, 0)
    ctx.restore()
  }
  ctx.restore()
}

// MARK: - Ink

import type { InkStroke } from './ink.js'

/**
 * A stroke, drawn as a ribbon rather than a line.
 *
 * A stroke whose nib changes width cannot be one `lineTo` path — the taper is
 * the whole difference between handwriting and a wire. Each segment is drawn
 * as a quad between the two nib widths, and a round cap at each sample closes
 * the joins.
 */
export function drawInkStroke(stroke: InkStroke, ctx: Ctx) {
  const pts = stroke.points
  if (pts.length === 0) return
  ctx.save()
  ctx.fillStyle = stroke.color.css
  if (stroke.tool === 'marker') {
    ctx.globalAlpha = 0.35
    ctx.globalCompositeOperation = 'multiply'
  }
  if (pts.length === 1) {
    ctx.beginPath()
    ctx.arc(pts[0].x, pts[0].y, pts[0].w / 2, 0, Math.PI * 2)
    ctx.fill()
    ctx.restore()
    return
  }
  for (let i = 1; i < pts.length; i += 1) {
    const a = pts[i - 1]
    const b = pts[i]
    const dx = b.x - a.x
    const dy = b.y - a.y
    const length = Math.hypot(dx, dy)
    if (length < 0.0001) continue
    const nx = -dy / length
    const ny = dx / length
    const ra = a.w / 2
    const rb = b.w / 2
    ctx.beginPath()
    ctx.moveTo(a.x + nx * ra, a.y + ny * ra)
    ctx.lineTo(b.x + nx * rb, b.y + ny * rb)
    ctx.lineTo(b.x - nx * rb, b.y - ny * rb)
    ctx.lineTo(a.x - nx * ra, a.y - ny * ra)
    ctx.closePath()
    ctx.fill()
    ctx.beginPath()
    ctx.arc(b.x, b.y, rb, 0, Math.PI * 2)
    ctx.fill()
  }
  ctx.beginPath()
  ctx.arc(pts[0].x, pts[0].y, pts[0].w / 2, 0, Math.PI * 2)
  ctx.fill()
  ctx.restore()
}

export function drawInk(strokes: InkStroke[], ctx: Ctx) {
  for (const stroke of strokes) drawInkStroke(stroke, ctx)
}

export function elementBounds(elements: SketchElement[]): Rect | null {
  if (elements.length === 0) return null
  return elements.map((e) => e.bounds).reduce((a, b) => {
    const minX = Math.min(a.x, b.x)
    const minY = Math.min(a.y, b.y)
    const maxX = Math.max(a.x + a.width, b.x + b.width)
    const maxY = Math.max(a.y + a.height, b.y + b.height)
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
  })
}

// MARK: - Marks

import { cssColor, quadToRect, type Mark } from './marks.js'

/**
 * Highlights and underlines, drawn the way the Mac's overlay draws them.
 *
 * A highlight is a rounded band multiplied onto the paper, so the words stay
 * black and legible under it rather than being tinted; the rounding is half
 * the band's height, which is what makes it read as a stroke of a marker
 * instead of a filled table cell. An underline sits just under the baseline
 * with round caps, at a weight that follows the text size.
 */
export function drawMarks(marks: Mark[], ctx: Ctx) {
  for (const mark of marks) {
    ctx.save()
    if (mark.kind === 'highlight') {
      ctx.globalCompositeOperation = 'multiply'
      ctx.fillStyle = cssColor(mark.color, 1)
      for (const quad of mark.quads) {
        const rect = quadToRect(quad)
        if (rect.width <= 0 || rect.height <= 0) continue
        const radius = Math.min(rect.height / 2, rect.width / 2)
        ctx.beginPath()
        ctx.roundRect(rect.x, rect.y, rect.width, rect.height, radius)
        ctx.fill()
      }
    } else {
      ctx.strokeStyle = cssColor(mark.color, 1)
      ctx.lineCap = 'round'
      for (const quad of mark.quads) {
        const rect = quadToRect(quad)
        if (rect.width <= 0) continue
        const weight = Math.max(rect.height * 0.08, 0.9)
        ctx.lineWidth = weight
        const y = mark.kind === 'strikethrough'
          ? rect.y + rect.height * 0.42
          : rect.y + rect.height * 0.08
        ctx.beginPath()
        ctx.moveTo(rect.x + weight / 2, y)
        ctx.lineTo(rect.x + rect.width - weight / 2, y)
        ctx.stroke()
      }
    }
    ctx.restore()
  }
}
