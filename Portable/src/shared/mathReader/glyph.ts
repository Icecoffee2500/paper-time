/**
 * One glyph as the page drew it, and one filled rule — the Mac's
 * `PDFContentScanner.Glyph` and `Rule`, with `isExtension` and `rect` worked
 * out the same way.
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

const families = new Map<string, string>()

/** A font's name without its subset tag, uppercased — Swift's
 *  `split(separator: "+").last`, which leaves the empty pieces out. Kept a
 *  name at a time: a page asks it of the same few dozen names over and over. */
export function familyOf(fontName: string): string {
  let known = families.get(fontName)
  if (known === undefined) {
    const pieces = fontName.split('+').filter((piece) => piece !== '')
    known = (pieces.length > 0 ? pieces[pieces.length - 1] : fontName).toUpperCase()
    families.set(fontName, known)
  }
  return known
}

const SYMBOL_FAMILIES = [
  'CMSY', 'CMBSY', 'LMMATHSYMBOLS', 'TXSY', 'PXSY', 'NEWTXSY', 'NEWPXSY', 'MTSY',
  'EUSM', 'EUSB', 'FOURIER-MATH-SYMBOLS',
]

const EXTENSION_FAMILIES = [
  'CMEX', 'LMMATHEXTENSION', 'TXEX', 'PXEX', 'EUEX', 'FOURIER-MATH-EXTENSION',
  'MTEX', 'MT2EX', 'ESINT',
]

const PIECES = ['tpA', 'exA', 'btA', 'midA']

/**
 * From an extension font — cmex and its kin, where the big operators and the
 * pieces of tall delimiters live, drawn *below* their point rather than above
 * it. Every TeX extension font is built that way, not only Computer Modern's
 * (reading only CMEX put the limits of a sum set in Times on the line
 * above); newtx's own bracket pieces and Euler's arrows and ∞ stand on their
 * point as ordinary glyphs do; and a symbol font's radical sign hangs from
 * the rule it holds up, so it counts as one.
 */
export function isExtension(glyph: Glyph): boolean {
  const family = familyOf(glyph.fontName)
  const name = glyph.glyphName
  if (EXTENSION_FAMILIES.some((prefix) => family.startsWith(prefix))) {
    if (name === null) return true
    if (name === 'infinity') return false
    if (PIECES.some((suffix) => name.endsWith(suffix))) return false
    if (name.startsWith('arrow') && !name.endsWith('half') && !name.endsWith('vertex')
      && !name.endsWith('tp') && !name.endsWith('bt')) return false
    return true
  }
  if (name === null || !name.startsWith('radical') || name.startsWith('radicalvertex')) return false
  return SYMBOL_FAMILIES.some((prefix) => family.startsWith(prefix))
}

/** How far below its reference point an extension glyph reaches, in ems: the
 *  size its name asks for — \big to \Bigg, the display operators, the top and
 *  bottom pieces of a bracket built up for a matrix. */
function reach(name: string | null): number {
  if (name === null) return 1
  // "summationdisplay.1" is the display sum from a second font, and newtx
  // names its pieces "parenlefttpA".
  const dot = name.indexOf('.')
  let glyphName = dot >= 0 ? name.slice(0, dot) : name
  if (glyphName.endsWith('A') && PIECES.some((suffix) => glyphName.endsWith(suffix))) glyphName = glyphName.slice(0, -1)
  if (glyphName.startsWith('paren') || glyphName.startsWith('bracket')) {
    if (glyphName.endsWith('tp') || glyphName.endsWith('bt')) return 1.8
  }
  if (glyphName.startsWith('brace')
    && (glyphName.endsWith('tp') || glyphName.endsWith('bt') || glyphName.endsWith('mid'))) return 0.9
  if (glyphName.endsWith('Bigg')) return 3.0
  if (glyphName.endsWith('bigg')) return 2.4
  if (glyphName.endsWith('Big')) return 1.8
  if (glyphName.endsWith('big')) return 1.2
  if (glyphName.endsWith('display')) return 1.5
  return 1
}

const rects = new WeakMap<Glyph, Rect>()
const extensions = new WeakMap<Glyph, boolean>()

/** `isExtension`, asked once a glyph: the reading asks it of every glyph
 *  many times over. */
export function extension(glyph: Glyph): boolean {
  let known = extensions.get(glyph)
  if (known === undefined) {
    known = isExtension(glyph)
    extensions.set(glyph, known)
  }
  return known
}

/** Where the ink is — standardized, as every CGRect function reads a box. */
export function rectOf(glyph: Glyph): Rect {
  const known = rects.get(glyph)
  if (known) return known
  const height = extension(glyph) ? glyph.size * reach(glyph.glyphName) : glyph.size
  const y = extension(glyph) ? glyph.y - height : glyph.y
  const rect: Rect = {
    x: glyph.width < 0 ? glyph.x + glyph.width : glyph.x,
    y: height < 0 ? y + height : y,
    width: Math.abs(glyph.width),
    height: Math.abs(height),
  }
  rects.set(glyph, rect)
  return rect
}
