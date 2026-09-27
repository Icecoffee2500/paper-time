/**
 * Highlights and underlines.
 *
 * These are ordinary PDF text-markup annotations — the same `Highlight` and
 * `Underline` every reader knows — so a passage marked here is marked in
 * Preview, in Acrobat and in a colleague's copy. The file is the storage;
 * there is no sidecar, because there is nothing a sidecar would add.
 *
 * On screen the app draws them itself, with rounded ends, rather than letting
 * the PDF renderer draw the bare rectangles: a highlight with square corners
 * ruled across a line of text is the look of a PDF viewer, and this is not
 * one. The copies in the file are hidden while ours are drawn, the same trick
 * the pen's ink uses.
 */
import type { Rect } from './sketch.js'

export type MarkKind = 'highlight' | 'underline' | 'strikethrough'

/** The five the Mac offers, as `MarkupColor` defines them. */
export const MARK_COLORS: Record<string, [number, number, number]> = {
  yellow: [1.0, 0.84, 0.25],
  green: [0.45, 0.83, 0.51],
  blue: [0.42, 0.71, 0.98],
  pink: [0.99, 0.56, 0.66],
  purple: [0.75, 0.6, 0.96],
}

export const MARK_COLOR_NAMES = Object.keys(MARK_COLORS)

export interface Mark {
  id: string
  kind: MarkKind
  /** Eight numbers per line: upper-left, upper-right, lower-left, lower-right. */
  quads: number[][]
  color: [number, number, number]
  text: string
  /**
   * The reader's own words about the passage, when there are any — the Mac's
   * `MarkupDescriptor.comment`. Nothing here writes one yet, but a mark made
   * on the Mac arrives with it, and a mark that went through this build and
   * came out without it would have lost what the person wrote.
   */
  comment?: string
  /**
   * When the mark was made, as the journal has it (`.iso8601`). Carried so
   * that writing the journal again does not re-date a mark from another
   * machine to the moment this one happened to touch it.
   */
  createdAt?: string
  /**
   * A mark another reader made — Preview's, Acrobat's — named by where it is
   * (`derivedMarkID`) rather than by an identifier of ours. It can be
   * recoloured, noted and removed all the same; the first change takes it
   * into this app's care, as the Mac's `TextMarkupWriter.adopt` does.
   */
  foreign?: boolean
}

/**
 * Which of the five a colour is nearest — `MarkupColor.nearest`. A grey or a
 * black is nobody's colour and is called yellow, on both builds; every place
 * that names a colour asks here, so the editor rings the swatch the journal
 * writes.
 */
export function nearestColorName(rgb: [number, number, number]): string {
  const [red, green, blue] = rgb
  if (Math.max(red, green, blue) - Math.min(red, green, blue) <= 0.18) return 'yellow'
  let best = 'yellow'
  let closest = Infinity
  for (const [name, value] of Object.entries(MARK_COLORS)) {
    const distance = (value[0] - red) ** 2 + (value[1] - green) ** 2 + (value[2] - blue) ** 2
    if (distance < closest) {
      closest = distance
      best = name
    }
  }
  return best
}

/** A colour moved toward grey `toward` (1 white, 0 black) — `Tone.blended`. */
export function blended(rgb: [number, number, number], toward: number, by: number): [number, number, number] {
  return rgb.map((value) => value + (toward - value) * by) as [number, number, number]
}

/**
 * How one line of a mark is drawn, in page units — the Mac's `RoundedMarks`,
 * number for number, so one file looks the same on both desktops: a band
 * blended a third of the way to white (more under the pointer, with a thin
 * edge), its corners at 0.3 of the height to at most 3.5 points; a line
 * deepened toward black, 0.085 of the height thick (0.13 under the pointer)
 * and never under a point, at the foot of the words or through their middle.
 */
export function markLine(kind: MarkKind, color: [number, number, number], rect: Rect, hovered = false):
  | { band: Rect; radius: number; fill: [number, number, number]; edge: [number, number, number] | null }
  | { from: { x: number; y: number }; to: { x: number; y: number }; width: number; ink: [number, number, number] } {
  if (kind === 'highlight') {
    return {
      band: rect,
      radius: Math.min(rect.height * 0.3, 3.5),
      fill: blended(color, 1, hovered ? 0.55 : 0.35),
      edge: hovered ? blended(color, 0, 0.15) : null,
    }
  }
  const width = Math.max(1, rect.height * (hovered ? 0.13 : 0.085))
  // Page space: y grows upward, so the foot of the words is the rectangle's y.
  const y = kind === 'underline' ? rect.y + width / 2 : rect.y + rect.height / 2
  return {
    from: { x: rect.x + width / 2, y },
    to: { x: rect.x + rect.width - width / 2, y },
    width,
    ink: hovered ? color : blended(color, 0, 0.3),
  }
}

export function quadToRect(quad: number[]): Rect {
  const xs = [quad[0], quad[2], quad[4], quad[6]]
  const ys = [quad[1], quad[3], quad[5], quad[7]]
  const minX = Math.min(...xs)
  const minY = Math.min(...ys)
  return { x: minX, y: minY, width: Math.max(...xs) - minX, height: Math.max(...ys) - minY }
}

/** A line's rectangle as the four corners `/QuadPoints` wants. */
export function rectToQuad(rect: Rect): number[] {
  const top = rect.y + rect.height
  return [rect.x, top, rect.x + rect.width, top, rect.x, rect.y, rect.x + rect.width, rect.y]
}

export function cssColor(rgb: [number, number, number], alpha = 1): string {
  const to255 = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255)
  return `rgba(${to255(rgb[0])}, ${to255(rgb[1])}, ${to255(rgb[2])}, ${alpha})`
}
