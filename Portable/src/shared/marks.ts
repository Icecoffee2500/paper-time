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
