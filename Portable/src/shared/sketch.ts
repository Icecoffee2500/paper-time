/**
 * The drawing layer's model, ported from `InkEngine/Sketch.swift`.
 *
 * Everything is in PDF page coordinates — origin bottom-left, y up — so an
 * element means the same thing on a Mac, on Windows and inside the file. The
 * JSON here is the same JSON the Swift side writes: `points` as `[x, y]`
 * pairs, `createdAt` in seconds since 2001, absent fields rather than nulls.
 * A drawing made on one machine opens on the other with the same curve.
 */
import { appleTimestamp, dateFromAppleTimestamp, makeUUID } from './coding.js'

export interface Point {
  x: number
  y: number
}

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

export const point = (x: number, y: number): Point => ({ x, y })

export function rectFrom(a: Point, b: Point): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(b.x - a.x),
    height: Math.abs(b.y - a.y),
  }
}

export function rectInset(r: Rect, dx: number, dy: number): Rect {
  return { x: r.x + dx, y: r.y + dy, width: r.width - dx * 2, height: r.height - dy * 2 }
}

export function rectContains(r: Rect, p: Point): boolean {
  return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height
}

/** Whether `inner` lies wholly inside `outer`. */
export function rectContainsRect(outer: Rect, inner: Rect): boolean {
  return inner.x >= outer.x && inner.y >= outer.y
    && rectMaxX(inner) <= rectMaxX(outer) && rectMaxY(inner) <= rectMaxY(outer)
}

export function rectUnion(a: Rect, b: Rect): Rect {
  const minX = Math.min(a.x, b.x)
  const minY = Math.min(a.y, b.y)
  const maxX = Math.max(a.x + a.width, b.x + b.width)
  const maxY = Math.max(a.y + a.height, b.y + b.height)
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
}

export function rectUnionAll(rects: Rect[]): Rect | null {
  if (rects.length === 0) return null
  return rects.reduce(rectUnion)
}

export function rectIntersects(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

export const rectMidX = (r: Rect) => r.x + r.width / 2
export const rectMidY = (r: Rect) => r.y + r.height / 2
export const rectMaxX = (r: Rect) => r.x + r.width
export const rectMaxY = (r: Rect) => r.y + r.height

// MARK: - Colour

export class SketchColor {
  constructor(
    public red: number,
    public green: number,
    public blue: number,
    public alpha = 1,
  ) {}

  static from(raw: unknown): SketchColor {
    const r = (raw ?? {}) as Record<string, number>
    return new SketchColor(r.red ?? 0, r.green ?? 0, r.blue ?? 0, r.alpha ?? 1)
  }

  encode(): Record<string, number> {
    return { red: this.red, green: this.green, blue: this.blue, alpha: this.alpha }
  }

  withAlpha(alpha: number): SketchColor {
    return new SketchColor(this.red, this.green, this.blue, alpha)
  }

  /** `rgba()` for a canvas or a swatch. */
  get css(): string {
    const to255 = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255)
    return `rgba(${to255(this.red)}, ${to255(this.green)}, ${to255(this.blue)}, ${this.alpha})`
  }

  /** Opaque, as if laid on white paper at its own alpha — what the PDF copy
   *  gets, since an annotation's interior colour has no alpha of its own. */
  get flattenedOnWhite(): SketchColor {
    const flatten = (c: number) => c + (1 - c) * (1 - this.alpha)
    return new SketchColor(flatten(this.red), flatten(this.green), flatten(this.blue))
  }

  /** The same to the eye. The file rounds, so equality would be wrong. */
  matches(other: SketchColor): boolean {
    return (
      Math.abs(this.red - other.red) < 0.02 &&
      Math.abs(this.green - other.green) < 0.02 &&
      Math.abs(this.blue - other.blue) < 0.02 &&
      Math.abs(this.alpha - other.alpha) < 0.02
    )
  }

  // The pen's seven inks.
  static readonly ink = new SketchColor(0.1, 0.1, 0.12)
  static readonly grey = new SketchColor(0.55, 0.55, 0.58)
  static readonly red = new SketchColor(0.9, 0.2, 0.18)
  static readonly orange = new SketchColor(0.96, 0.55, 0.12)
  static readonly green = new SketchColor(0.16, 0.62, 0.32)
  static readonly blue = new SketchColor(0.12, 0.36, 0.98)
  static readonly purple = new SketchColor(0.52, 0.3, 0.88)

  static readonly strokes = [
    SketchColor.ink, SketchColor.grey, SketchColor.red, SketchColor.orange,
    SketchColor.green, SketchColor.blue, SketchColor.purple,
  ]

  // The fills: the highlighter's colours, pale and translucent, so the
  // paper's own words stay legible under a shape drawn over them.
  static readonly paleYellow = new SketchColor(1.0, 0.9, 0.55, 0.6)
  static readonly paleGreen = new SketchColor(0.68, 0.9, 0.7, 0.6)
  static readonly paleBlue = new SketchColor(0.66, 0.83, 0.99, 0.6)
  static readonly palePink = new SketchColor(0.99, 0.75, 0.8, 0.6)
  static readonly palePurple = new SketchColor(0.85, 0.77, 0.98, 0.6)
  static readonly paleGrey = new SketchColor(0.8, 0.81, 0.84, 0.6)

  static readonly fills = [
    SketchColor.paleYellow, SketchColor.paleGreen, SketchColor.paleBlue,
    SketchColor.palePink, SketchColor.palePurple, SketchColor.paleGrey,
  ]
}

// MARK: - Style

export type Dash = 'solid' | 'dashed' | 'dotted'
export type Corners = 'sharp' | 'round'
export type Head = 'none' | 'arrow' | 'triangle' | 'bar' | 'dot'
export type TextSize = 'small' | 'medium' | 'large'
export type TextAlign = 'left' | 'center' | 'right'

export const TEXT_POINTS: Record<TextSize, number> = { small: 9, medium: 12, large: 17 }
export const STYLE_WIDTHS = [1, 2, 3.5]

export class SketchStyle {
  stroke: SketchColor = SketchColor.ink
  fill: SketchColor | null = null
  width = 2
  dash: Dash = 'solid'
  corners: Corners = 'round'
  startHead: Head = 'none'
  endHead: Head = 'arrow'
  opacity = 1
  textSize: TextSize = 'medium'
  border = false
  /** For a box, an oval or a frame: the edge left undrawn. The opposite
   *  sense to `border`, so files from before it existed keep their edges. */
  strokeHidden = false
  /** A corner radius set by hand, in page points; null is the automatic one. */
  cornerRadius: number | null = null
  /** Lettering in exact points, when set by hand; null is `textSize`. */
  fontSize: number | null = null
  textAlign: TextAlign = 'left'
  /** A font family chosen by name; null is the bundled face. */
  fontName: string | null = null

  /** Every field defaults, so a file written by a version that knows more
   *  fields still reads, and one written by a version that knew fewer does
   *  too. The Swift initialiser is forgiving in exactly this way. */
  static from(raw: unknown): SketchStyle {
    const style = new SketchStyle()
    const r = (raw ?? {}) as Record<string, unknown>
    if (r.stroke) style.stroke = SketchColor.from(r.stroke)
    style.fill = r.fill ? SketchColor.from(r.fill) : null
    if (typeof r.width === 'number') style.width = r.width
    if (typeof r.dash === 'string') style.dash = r.dash as Dash
    if (typeof r.corners === 'string') style.corners = r.corners as Corners
    if (typeof r.startHead === 'string') style.startHead = r.startHead as Head
    if (typeof r.endHead === 'string') style.endHead = r.endHead as Head
    if (typeof r.opacity === 'number') style.opacity = r.opacity
    if (typeof r.textSize === 'string') style.textSize = r.textSize as TextSize
    if (typeof r.border === 'boolean') style.border = r.border
    if (typeof r.strokeHidden === 'boolean') style.strokeHidden = r.strokeHidden
    if (typeof r.cornerRadius === 'number') style.cornerRadius = r.cornerRadius
    if (typeof r.fontSize === 'number') style.fontSize = r.fontSize
    if (typeof r.textAlign === 'string') style.textAlign = r.textAlign as TextAlign
    if (typeof r.fontName === 'string') style.fontName = r.fontName
    return style
  }

  // The newer fields are written only when set — exactly as the Mac writes
  // them — so a file this build merely opened comes back byte for byte.
  encode(): Record<string, unknown> {
    return {
      stroke: this.stroke.encode(),
      fill: this.fill ? this.fill.encode() : undefined,
      width: this.width,
      dash: this.dash,
      corners: this.corners,
      startHead: this.startHead,
      endHead: this.endHead,
      opacity: this.opacity,
      textSize: this.textSize,
      border: this.border,
      strokeHidden: this.strokeHidden ? true : undefined,
      cornerRadius: this.cornerRadius ?? undefined,
      fontSize: this.fontSize ?? undefined,
      textAlign: this.textAlign !== 'left' ? this.textAlign : undefined,
      fontName: this.fontName ?? undefined,
    }
  }

  /** The size the words are set in. */
  get points(): number {
    return this.fontSize ?? TEXT_POINTS[this.textSize]
  }

  /** Whether this kind of element draws its outline in this style. */
  drawsOutline(kind: Kind): boolean {
    switch (kind) {
      case 'text': return this.border
      case 'rectangle': case 'ellipse': case 'frame': return !this.strokeHidden
      case 'line': case 'arrow': return true
      case 'group': return false
    }
  }

  copy(): SketchStyle {
    return SketchStyle.from(JSON.parse(JSON.stringify(this.encode())))
  }

  /** Dashes grow with the line, so a bold dashed line is not a dotted one. */
  get dashPattern(): number[] | null {
    switch (this.dash) {
      case 'solid': return null
      case 'dashed': return [Math.max(this.width * 3, 4), Math.max(this.width * 2.2, 3)]
      case 'dotted': return [0.01, Math.max(this.width * 2, 2.5)]
    }
  }

  get textPoints(): number {
    return TEXT_POINTS[this.textSize]
  }
}

// MARK: - Element

export type Kind = 'rectangle' | 'ellipse' | 'line' | 'arrow' | 'text' | 'frame' | 'group'
export type TextSizing = 'autoWidth' | 'autoHeight'

/** How a frame arranges its children — `SketchLayout` on the Mac. Carried
 *  and drawn here; the arranging itself is the Mac's, for now. */
export interface SketchLayout {
  direction: 'vertical' | 'horizontal'
  gap: number
  padding: number
  align: 'start' | 'center' | 'end'
  hugs: boolean
}

export class SketchElement {
  id: string
  kind: Kind
  /** Two points: opposite corners for a box, the ends for a connector. */
  points: Point[]
  /** How far the middle of a connector is pulled off the straight path. */
  bend: Point | null
  style: SketchStyle
  text: string
  createdAt: Date
  /** The frame or group this lies in. Coordinates stay the page's. */
  parent: string | null = null
  /** What a frame or group is called, when it has been named. */
  name: string | null = null
  /** For a frame: whether what spills past its edge is hidden. */
  clips = false
  layout: SketchLayout | null = null
  /** For a text card; null in files from before there was a choice. */
  textSizing: TextSizing | null = null
  /**
   * Fields this build does not know, kept and written back as they came —
   * a newer Mac may have put something here, and dropping it would be
   * silent data loss on the next save.
   */
  private extra: Record<string, unknown> = {}
  /**
   * The number the file actually held.
   *
   * `Date` counts whole milliseconds and Swift writes rather more precision
   * than that — 811492215.409792 comes back as …4089999. Re-encoding would
   * then change the timestamp of every shape in a file this build merely
   * opened, which is a whole-file diff in a synced folder for no reason. The
   * original is kept and written back; `createdAt` is for reading.
   */
  private createdAtRaw: number | null = null

  constructor(init: {
    id?: string
    kind: Kind
    points: Point[]
    bend?: Point | null
    style?: SketchStyle
    text?: string
    createdAt?: Date
  }) {
    this.id = init.id ?? makeUUID()
    this.kind = init.kind
    this.points = init.points
    this.bend = init.bend ?? null
    this.style = init.style ?? new SketchStyle()
    this.text = init.text ?? ''
    this.createdAt = init.createdAt ?? new Date()
  }

  static from(raw: unknown): SketchElement {
    const r = (raw ?? {}) as Record<string, unknown>
    const pairs = (r.points as number[][]) ?? []
    const bend = r.bend as number[] | undefined
    const element = new SketchElement({
      id: r.id ? String(r.id) : undefined,
      kind: r.kind as Kind,
      points: pairs.map((p) => point(p[0], p[1])),
      bend: bend ? point(bend[0], bend[1]) : null,
      style: SketchStyle.from(r.style),
      text: typeof r.text === 'string' ? r.text : '',
      createdAt: typeof r.createdAt === 'number' ? dateFromAppleTimestamp(r.createdAt) : new Date(),
    })
    if (typeof r.createdAt === 'number') element.createdAtRaw = r.createdAt
    if (typeof r.parent === 'string') element.parent = r.parent
    if (typeof r.name === 'string') element.name = r.name
    if (typeof r.clips === 'boolean') element.clips = r.clips
    if (r.layout && typeof r.layout === 'object') {
      const l = r.layout as Record<string, unknown>
      element.layout = {
        direction: l.direction === 'horizontal' ? 'horizontal' : 'vertical',
        gap: typeof l.gap === 'number' ? l.gap : 8,
        padding: typeof l.padding === 'number' ? l.padding : 8,
        align: l.align === 'center' || l.align === 'end' ? l.align : 'start',
        hugs: typeof l.hugs === 'boolean' ? l.hugs : true,
      }
    }
    if (r.textSizing === 'autoWidth' || r.textSizing === 'autoHeight') element.textSizing = r.textSizing
    const known = new Set(['id', 'kind', 'points', 'bend', 'style', 'text', 'createdAt', 'parent', 'name', 'clips', 'layout', 'textSizing'])
    for (const key of Object.keys(r)) if (!known.has(key)) element.extra[key] = r[key]
    return element
  }

  encode(): Record<string, unknown> {
    return {
      ...this.extra,
      id: this.id,
      kind: this.kind,
      points: this.points.map((p) => [p.x, p.y]),
      bend: this.bend ? [this.bend.x, this.bend.y] : undefined,
      style: this.style.encode(),
      text: this.text,
      createdAt: this.createdAtRaw ?? appleTimestamp(this.createdAt),
      parent: this.parent ?? undefined,
      name: this.name ?? undefined,
      clips: this.clips ? true : undefined,
      layout: this.layout ?? undefined,
      textSizing: this.textSizing ?? undefined,
    }
  }

  copy(): SketchElement {
    return SketchElement.from(JSON.parse(JSON.stringify(this.encode())))
  }

  /** For a copy made now: the file's own timestamp is not this element's. */
  resetCreatedAt() {
    this.createdAtRaw = null
  }

  get isBox(): boolean {
    return this.kind === 'rectangle' || this.kind === 'ellipse' || this.kind === 'text' || this.kind === 'frame'
  }

  get isContainer(): boolean {
    return this.kind === 'frame' || this.kind === 'group'
  }

  /** How a text card sizes itself; the old files were all made to a width. */
  get sizing(): TextSizing {
    return this.textSizing ?? 'autoHeight'
  }

  get isConnector(): boolean {
    return this.kind === 'line' || this.kind === 'arrow'
  }

  get start(): Point {
    return this.points[0] ?? point(0, 0)
  }

  get end(): Point {
    return this.points.length > 1 ? this.points[1] : this.start
  }

  get rect(): Rect {
    return rectFrom(this.start, this.end)
  }

  setRect(r: Rect) {
    this.points = [point(r.x, r.y), point(rectMaxX(r), rectMaxY(r))]
  }

  /** The quadratic's control point, in page coordinates. */
  get control(): Point | null {
    if (!this.isConnector || !this.bend) return null
    if (Math.hypot(this.bend.x, this.bend.y) <= 0.5) return null
    return point(
      (this.start.x + this.end.x) / 2 + this.bend.x,
      (this.start.y + this.end.y) / 2 + this.bend.y,
    )
  }

  /** Where the bend handle sits: the curve at t = 0.5, or the midpoint. */
  get midpoint(): Point {
    const control = this.control
    if (!control) return point((this.start.x + this.end.x) / 2, (this.start.y + this.end.y) / 2)
    return point(
      0.25 * this.start.x + 0.5 * control.x + 0.25 * this.end.x,
      0.25 * this.start.y + 0.5 * control.y + 0.25 * this.end.y,
    )
  }

  /** Bends the curve so it passes through `p` — the quadratic inverted. */
  setMidpoint(p: Point) {
    const control = point(
      2 * p.x - (this.start.x + this.end.x) / 2,
      2 * p.y - (this.start.y + this.end.y) / 2,
    )
    const offset = point(
      control.x - (this.start.x + this.end.x) / 2,
      control.y - (this.start.y + this.end.y) / 2,
    )
    this.bend = Math.hypot(offset.x, offset.y) < 1 ? null : offset
  }

  /** One segment when straight, a sampled curve when bent. */
  polyline(samples = 24): Point[] {
    if (!this.isConnector) return []
    const control = this.control
    if (!control) return [this.start, this.end]
    const out: Point[] = []
    for (let step = 0; step <= samples; step += 1) {
      const t = step / samples
      const u = 1 - t
      out.push(point(
        u * u * this.start.x + 2 * u * t * control.x + t * t * this.end.x,
        u * u * this.start.y + 2 * u * t * control.y + t * t * this.end.y,
      ))
    }
    return out
  }

  get startDirection(): Point {
    const toward = this.control ?? this.end
    return unit(point(this.start.x - toward.x, this.start.y - toward.y))
  }

  get endDirection(): Point {
    const from = this.control ?? this.start
    return unit(point(this.end.x - from.x, this.end.y - from.y))
  }

  get headLength(): number {
    return Math.max(8, this.style.width * 4.5)
  }

  /** A share of the smaller side, so a small box is not all corner. */
  get cornerRadius(): number {
    const r0 = this.rect
    if (this.style.cornerRadius !== null) {
      return Math.max(0, Math.min(this.style.cornerRadius, Math.min(r0.width, r0.height) / 2))
    }
    if (this.style.corners !== 'round') return 0
    const r = this.rect
    return Math.min(Math.min(r.width, r.height) * 0.22, 10)
  }

  /** Everything the element covers — heads, half the line width and all. */
  get bounds(): Rect {
    let box: Rect
    if (this.isConnector) {
      const line = this.polyline()
      box = line.reduce<Rect>(
        (acc, p) => rectUnion(acc, { x: p.x, y: p.y, width: 0, height: 0 }),
        { x: line[0].x, y: line[0].y, width: 0, height: 0 },
      )
      box = rectInset(box, -this.headLength, -this.headLength)
    } else {
      box = this.rect
    }
    const pad = this.style.width / 2 + 1
    return rectInset(box, -pad, -pad)
  }

  /**
   * Whether a point on the page is on the element.
   *
   * A line is hit along its length; a box along its edge, and anywhere inside
   * when it is filled or has words in it; a text card anywhere on it. The
   * tolerance is in page points and grows as the reader zooms out, so the
   * target under the pointer stays the same size on screen.
   */
  hits(p: Point, tolerance: number): boolean {
    const reach = tolerance + this.style.width / 2
    switch (this.kind) {
      case 'line':
      case 'arrow': {
        const line = this.polyline()
        for (let i = 1; i < line.length; i += 1) {
          if (distanceToSegment(p, line[i - 1], line[i]) <= reach) return true
        }
        return false
      }
      case 'text':
        return rectContains(rectInset(this.rect, -tolerance, -tolerance), p)
      case 'group':
        // Never hit for itself; a click on a child is what selects it.
        return false
      case 'rectangle':
      case 'frame': {
        const outer = rectInset(this.rect, -reach, -reach)
        if (!rectContains(outer, p)) return false
        if (this.style.fill || this.text) return true
        const inner = rectInset(this.rect, reach, reach)
        return !(inner.width > 0 && inner.height > 0 && rectContains(inner, p))
      }
      case 'ellipse': {
        const r = this.rect
        if (r.width <= 0 || r.height <= 0) return false
        const dx = (p.x - rectMidX(r)) / (r.width / 2)
        const dy = (p.y - rectMidY(r)) / (r.height / 2)
        const radial = Math.hypot(dx, dy)
        const band = reach / Math.max(Math.min(r.width, r.height) / 2, 0.001)
        if (this.style.fill || this.text) return radial <= 1 + band
        return Math.abs(radial - 1) <= band
      }
    }
  }

  translated(offset: Point): SketchElement {
    const copy = this.copy()
    copy.id = this.id
    copy.points = this.points.map((p) => point(p.x + offset.x, p.y + offset.y))
    return copy
  }

  /** Scaled into a new box, as the resize handles do it. */
  fitted(box: Rect, old: Rect): SketchElement {
    const copy = this.copy()
    copy.id = this.id
    if (old.width <= 0.001 || old.height <= 0.001) return copy
    const map = (p: Point) =>
      point(
        box.x + ((p.x - old.x) / old.width) * box.width,
        box.y + ((p.y - old.y) / old.height) * box.height,
      )
    copy.points = this.points.map(map)
    if (this.bend) {
      copy.bend = point(
        (this.bend.x / old.width) * box.width,
        (this.bend.y / old.height) * box.height,
      )
    }
    return copy
  }
}

export function unit(v: Point): Point {
  const length = Math.hypot(v.x, v.y)
  if (length <= 0.0001) return point(1, 0)
  return point(v.x / length, v.y / length)
}

export function distanceToSegment(p: Point, a: Point, b: Point): number {
  const dx = b.x - a.x
  const dy = b.y - a.y
  const length = dx * dx + dy * dy
  if (length <= 0.0001) return Math.hypot(p.x - a.x, p.y - a.y)
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - The tree

/** The direct children of a container, in the order they lie. */
export function childrenOf(elements: SketchElement[], id: string): SketchElement[] {
  return elements.filter((element) => element.parent === id)
}

/** Everything inside a container, at any depth. */
export function descendantIDs(elements: SketchElement[], id: string): Set<string> {
  const out = new Set<string>()
  const walk = (parent: string) => {
    for (const child of elements) {
      if (child.parent === parent && !out.has(child.id)) {
        out.add(child.id)
        walk(child.id)
      }
    }
  }
  walk(id)
  return out
}

/** These ids and everything inside them. */
export function expandedIDs(elements: SketchElement[], ids: string[]): Set<string> {
  const out = new Set(ids)
  for (const id of ids) for (const inner of descendantIDs(elements, id)) out.add(inner)
  return out
}

/**
 * What a click on an element selects — Figma's rule: the outermost group
 * round it, while a frame lets the click through to its children.
 */
export function selectableFor(elements: SketchElement[], id: string): string {
  const byID = new Map(elements.map((element) => [element.id, element]))
  let chosen = id
  let current = byID.get(id)?.parent ?? null
  const seen = new Set([id])
  while (current && !seen.has(current)) {
    const ancestor = byID.get(current)
    if (!ancestor) break
    seen.add(current)
    if (ancestor.kind === 'group') chosen = ancestor.id
    current = ancestor.parent
  }
  return chosen
}

/** Everything an element covers, its descendants included. */
export function treeBounds(elements: SketchElement[], id: string): Rect | null {
  const element = elements.find((e) => e.id === id)
  if (!element) return null
  if (element.kind === 'group') {
    const inner = childrenOf(elements, id).map((child) => treeBounds(elements, child.id)).filter((r): r is Rect => r !== null)
    return inner.length === 0 ? element.rect : rectUnionAll(inner)
  }
  if (element.isConnector) return element.bounds
  return element.rect
}

// MARK: - A page's worth

export function decodeSketch(json: string): SketchElement[] {
  const raw = JSON.parse(json)
  if (!Array.isArray(raw)) return []
  return raw.map(SketchElement.from)
}

export function encodeSketchElements(elements: SketchElement[]): unknown[] {
  return elements.map((e) => e.encode())
}
