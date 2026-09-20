/**
 * Handwriting, in a form every platform can hold.
 *
 * The Mac keeps each page's strokes as a `PKDrawing` — PencilKit's own binary,
 * which exists nowhere but Apple's frameworks. So this port keeps its own
 * sidecar, `ink/pNNNN.json`, beside the Mac's `ink/pNNNN.drawing`: the Mac's
 * loader only looks at `.drawing`, so the two never collide.
 *
 * What crosses between them is the PDF. Both sides write their strokes into
 * the file as standard ink annotations marked `/PTInk`, and both sides can
 * read those annotations back into strokes. A page drawn on Windows opens on
 * the Mac through `InkConverter.drawing(fromOwnedInkOn:)`; a page drawn on the
 * Mac opens here the same way. What is lost in that crossing is pressure — a
 * PDF ink annotation has one width for the whole stroke — which is exactly
 * what the Mac loses too, and why both sides keep a sidecar of their own.
 */
import { SketchColor, type Point } from './sketch.js'

/** The name the Mac's `InkConverter` puts on the ink it owns. Matching it is
 *  what makes a stroke drawn here a stroke the Mac will adopt and re-save
 *  rather than a stranger's annotation it must leave alone. */
export const INK_OWNER = 'Paper Time'

export type InkToolKind = 'pen' | 'marker'

/** A sampled point: where the nib was, and how wide it was there. */
export interface InkPoint {
  x: number
  y: number
  /** Nib width in page points at this sample. */
  w: number
}

export class InkStroke {
  constructor(
    public points: InkPoint[],
    public color: SketchColor,
    public tool: InkToolKind = 'pen',
  ) {}

  static from(raw: unknown): InkStroke {
    const r = (raw ?? {}) as Record<string, unknown>
    const pts = ((r.points as number[][]) ?? []).map((p) => ({ x: p[0], y: p[1], w: p[2] ?? 2 }))
    return new InkStroke(pts, SketchColor.from(r.color), (r.tool as InkToolKind) ?? 'pen')
  }

  encode(): Record<string, unknown> {
    return {
      points: this.points.map((p) => [p.x, p.y, p.w]),
      color: this.color.encode(),
      tool: this.tool,
    }
  }

  /** The one width a PDF ink annotation can carry: the mean of the nib. */
  get averageWidth(): number {
    if (this.points.length === 0) return 2
    return this.points.reduce((sum, p) => sum + p.w, 0) / this.points.length
  }

  /** What the file gets. A marker is painted with multiply blending on the
   *  canvas, which a PDF ink annotation cannot express; a translucent stroke
   *  is the closest every reader renders the same way — the same 0.35 the
   *  Mac's converter uses. */
  get pdfColor(): SketchColor {
    return this.tool === 'marker' ? this.color.withAlpha(0.35) : this.color
  }

  get bounds(): { x: number; y: number; width: number; height: number } {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    let widest = 0
    for (const p of this.points) {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x)
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y)
      widest = Math.max(widest, p.w)
    }
    if (!Number.isFinite(minX)) return { x: 0, y: 0, width: 0, height: 0 }
    const pad = widest / 2 + 1
    return { x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2 }
  }

  translated(offset: Point): InkStroke {
    return new InkStroke(
      this.points.map((p) => ({ x: p.x + offset.x, y: p.y + offset.y, w: p.w })),
      this.color,
      this.tool,
    )
  }
}

export function decodeInk(json: string): InkStroke[] {
  const raw = JSON.parse(json)
  return Array.isArray(raw) ? raw.map(InkStroke.from) : []
}

export function encodeInkStrokes(strokes: InkStroke[]): unknown[] {
  return strokes.map((s) => s.encode())
}

/**
 * Thins a raw pointer track to the spacing the Mac samples at.
 *
 * `InkConverter.samplingDistance` is 1.5 page points: fine enough that curves
 * stay smooth at reading zoom, coarse enough that a page of dense handwriting
 * is not a megabyte of coordinates. A mouse reports far more than that.
 */
export const SAMPLING_DISTANCE = 1.5

export function resample(points: InkPoint[], distance = SAMPLING_DISTANCE): InkPoint[] {
  if (points.length < 2) return points
  const out: InkPoint[] = [points[0]]
  for (const p of points.slice(1)) {
    const last = out[out.length - 1]
    if (Math.hypot(p.x - last.x, p.y - last.y) >= distance) out.push(p)
  }
  const final = points[points.length - 1]
  const last = out[out.length - 1]
  if (last.x !== final.x || last.y !== final.y) out.push(final)
  return out
}

/**
 * The nib width for a sample, from the pointer's own pressure.
 *
 * A pen tablet reports pressure; a mouse always reports 0.5, and a trackpad
 * the same, so on those the stroke comes out at its nominal width and the
 * taper is simply absent. That is the honest behaviour: a mouse has no
 * pressure to show.
 */
export function nibWidth(base: number, pressure: number, tool: InkToolKind): number {
  if (tool === 'marker') return base
  const normalised = pressure > 0 && pressure !== 0.5 ? pressure : 0.5
  return base * (0.55 + normalised * 0.9)
}
