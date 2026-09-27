/**
 * One glyph as the page drew it, and one filled rule — the Mac's
 * `PDFContentScanner.Glyph` and `Rule`, with `rect` worked out the same way.
 */
import { type Rect } from './geometry.js'

export interface Glyph {
  code: number
  /** The font's own name, subset prefix and all: "AAAABQ+CMMI10". */
  fontName: string
  unicode: string | null
  glyphName: string | null
  isSymbolic: boolean
  size: number
  /** The origin on its baseline, in page coordinates. */
  x: number
  y: number
  width: number
}

export interface Rule { rect: Rect }

/** From an extension font (cmex and kin), where the big operators and tall delimiters live. */
export function isExtension(glyph: Glyph): boolean {
  const family = glyph.fontName.split('+').pop() ?? glyph.fontName
  return family.toUpperCase().startsWith('CMEX')
}

/** How far below its reference point a cmex glyph reaches, in ems. */
function reach(name: string | null): number {
  if (name === null) return 1
  if (name.endsWith('Bigg')) return 3.0
  if (name.endsWith('bigg')) return 2.4
  if (name.endsWith('Big')) return 1.8
  if (name.endsWith('big')) return 1.2
  if (name.endsWith('display')) return 1.5
  return 1
}

const rects = new WeakMap<Glyph, Rect>()

/** Where the ink is. */
export function rectOf(glyph: Glyph): Rect {
  const known = rects.get(glyph)
  if (known) return known
  let rect: Rect
  if (!isExtension(glyph)) rect = { x: glyph.x, y: glyph.y, width: glyph.width, height: glyph.size }
  else {
    const height = glyph.size * reach(glyph.glyphName)
    rect = { x: glyph.x, y: glyph.y - height, width: glyph.width, height }
  }
  rects.set(glyph, rect)
  return rect
}
