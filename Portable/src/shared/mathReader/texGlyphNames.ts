/**
 * What a TeX font calls its glyphs, and what that is in LaTeX — the Mac's
 * `TeXGlyphNames`. The tables are not transcribed: `texTables.json` is what
 * the Swift's own tables hold, and the Mathematical Alphanumeric Symbols are
 * what its own function answered for every code point
 * (`Scripts/mathreader-fixtures.sh`). What is left here is the reasoning:
 * which font's names mean what, and in which order they are asked.
 */
import tables from './texTables.json'
import { familyOf } from './glyph.js'
import { canon, chars, count, firstChar, isLetter, isNumber, keyed, lastChar } from './swiftText.js'

type Table = Record<string, string>
const T = tables as unknown as {
  byName: Table; msam: Table; msbm: Table; txsyc: Table; unicodeCommands: Table
  mathAlphanumeric: Record<string, [string, string]>
  mathItalic: Table; symbols: Table; blackboard: Table; extensions: Table; roman: Table
  macRoman: Table; winAnsi: Table
}

// Keyed as a Swift dictionary is: by canonical equivalence.
const byName = keyed(Object.entries(T.byName))
const msam = keyed(Object.entries(T.msam))
const msbm = keyed(Object.entries(T.msbm))
const txsyc = keyed(Object.entries(T.txsyc))
const unicodeCommands = keyed(Object.entries(T.unicodeCommands))

/** The command a formula spells a character with (`unicodeCommands[c]`). */
export function unicodeCommand(character: string): string | undefined {
  return unicodeCommands.get(canon(character))
}

export const family = familyOf

/**
 * The LaTeX for a glyph, given its name and the font it came from. A name
 * the font gave the glyph is the truth; failing that, a text font means the
 * encoding it declares, and only a symbolic one is read through Computer
 * Modern's tables.
 */
export function latex(name: string | null, code: number, fontName: string, unicode: string | null, isSymbolic = true): string | null {
  const resolved = resolve(name, code, fontName, unicode, isSymbolic)
  if (resolved === null) return null
  // A font that holds one alphabet, and not the plain one, draws every
  // letter in that alphabet — CMSY's "N" is a script N. A double-struck
  // font's digits are double-struck too: bbm's 𝟙 is \mathbb{1}.
  if (count(resolved) === 1) {
    const character = firstChar(resolved) ?? ''
    const style = letterStyle(fontName)
    if (style !== null && (isLetter(character) || (isNumber(character) && style === '\\mathbb'))) {
      return `${style}{${resolved}}`
    }
  }
  // A font that says what its glyphs mean writes a formula's letters as the
  // Mathematical Alphanumeric Symbols — "𝑎", not "a" — which LaTeX cannot take.
  const scalars = [...resolved].map((one) => one.codePointAt(0)!)
  if (scalars.some((value) => mathAlphanumeric(value) !== null)) return latexOfScalars(scalars) ?? resolved
  return resolved
}

function resolve(name: string | null, code: number, fontName: string, unicode: string | null, isSymbolic: boolean): string | null {
  if (name !== null) {
    // The AMS fonts, and the tx and px fonts made after them, give their own
    // meaning to names other fonts use: "star" is ★ in msam.
    const table = amsTable(fontName)
    const ams = table ? table.get(canon(name)) ?? table.get(canon(stripped(name))) : undefined
    if (ams !== undefined) return ams
    const arev = arevName(name, fontName)
    if (arev !== null) return arev
    const named = byName.get(canon(name)) ?? byName.get(canon(stripped(name)))
    if (named !== undefined) return named
    if (count(name) === 1) return name
    // newtx's and newtxsf's own names: "bbE" for the double-struck E (in
    // zsfmia and txmia), "upnabla", "uppartial" and "upalpha" for the
    // upright forms. Read as codes they were "(" and "+".
    const newtx = newtxName(name)
    if (newtx !== null) return newtx
    // "u1D437", "uni2260": a glyph named after its code point.
    const scalars = unicodeName(name)
    if (scalars !== null) return latexOfScalars(scalars)
  }
  if (!isSymbolic && unicode !== null && unicode !== '') return unicode
  const command = standardEncoding(code, fontName)
  if (command !== null) return command
  if (unicode !== null && unicode !== '') return unicode
  // A font this knows nothing about, which says nothing about itself: its
  // codes may at least be ASCII. (Asked last.)
  return asciiIfPrintable(code)
}

/** newtx's names for glyphs other fonts name by code point: "bbA"–"bbZ" and
 *  "bbk" are \mathbb, "upnabla" and "uppartial" the upright signs, "upalpha"
 *  the upright Greek (written as the Greek — LaTeX's \alpha). */
export function newtxName(name: string): string | null {
  const all = chars(name)
  if (all.length === 3 && all[0] === 'b' && all[1] === 'b') {
    const letter = lastChar(name) ?? ''
    if (/^[A-Za-z]$/.test(letter)) return `\\mathbb{${letter}}`
  }
  if (!(all.length > 2 && all[0] === 'u' && all[1] === 'p')) return null
  const rest = '\\' + all.slice(2).join('')
  return isGreekCommand(rest) ? rest : null
}

/** Whether a command names a Greek letter, ∇ or ∂ — the letters a text face
 *  carries for a paper that sets its formulas in the text face. */
export function isGreekCommand(command: string): boolean {
  return GREEK_COMMANDS.has(command)
}

/** The Swift's `greekLetters`: what the Mathematical Alphanumeric Symbols'
 *  Greek block spells, in its order (the plain capitals and "o" among them
 *  are the letters Unicode shares with Latin). */
const GREEK_LETTERS = [
  'A', 'B', '\\Gamma', '\\Delta', 'E', 'Z', 'H', '\\Theta', 'I', 'K', '\\Lambda', 'M', 'N',
  '\\Xi', 'O', '\\Pi', 'P', '\\varTheta', '\\Sigma', 'T', '\\Upsilon', '\\Phi', 'X',
  '\\Psi', '\\Omega', '\\nabla',
  '\\alpha', '\\beta', '\\gamma', '\\delta', '\\varepsilon', '\\zeta', '\\eta',
  '\\theta', '\\iota', '\\kappa', '\\lambda', '\\mu', '\\nu', '\\xi', 'o', '\\pi',
  '\\rho', '\\varsigma', '\\sigma', '\\tau', '\\upsilon', '\\varphi', '\\chi',
  '\\psi', '\\omega', '\\partial', '\\epsilon', '\\vartheta', '\\varkappa', '\\phi',
  '\\varrho', '\\varpi',
]

const GREEK_COMMANDS = new Set([...GREEK_LETTERS.filter((one) => one.startsWith('\\')), '\\Omega', '\\digamma'])

/**
 * Arev's own names for its maths letters: the letters a formula would confuse
 * with symbols — a, i, l, u, v, w, x, I — are variant shapes in the font's
 * private-use area, named "uniEB" + 0x80 + the letter's ASCII code
 * ("uniEBF8" is x); f is the florin; three upright Greek capitals are
 * private-use too (`TeXGlyphNames.arevName`).
 */
export function arevName(name: string, fontName: string): string | null {
  if (!family(fontName).startsWith('AREVSANS')) return null
  if (name === 'florin') return 'f'
  if (name.startsWith('uniEB') && name.length === 7) {
    const code = parseInt(name.slice(5), 16)
    if (!Number.isNaN(code) && code >= 0x80 + 0x41 && code <= 0x80 + 0x7a) {
      const letter = String.fromCharCode(code - 0x80)
      if (/^[A-Za-z]$/.test(letter)) return letter
    }
  }
  switch (name) {
    case 'uniEF13': return '\\Gamma'
    case 'uniEF23': return '\\Sigma'
    case 'uniEF26': return '\\Phi'
    default: return null
  }
}

/** The AMS fonts' own names, for the fonts that use them. */
function amsTable(fontName: string): Map<string, string> | null {
  const upper = family(fontName)
  // (cmbright's AMS fonts are hfbright's HFBRAS and HFBRBS.)
  if (['MSAM', 'TXSYA', 'PXSYA', 'HFBRAS'].some((prefix) => upper.startsWith(prefix))) return msam
  if (['MSBM', 'TXSYB', 'PXSYB', 'TXSYM', 'PXSYM', 'HFBRBS'].some((prefix) => upper.startsWith(prefix))) return msbm
  if (['TXSYC', 'PXSYC'].some((prefix) => upper.startsWith(prefix))) return txsyc
  return null
}

/** The command that sets every letter of a font that draws one alphabet
 *  other than the plain one, or nil for a font whose letters are letters. */
export function letterStyle(fontName: string): string | null {
  const upper = family(fontName)
  // The tx and px fonts first, where one prefix covers several fonts that
  // each draw a different alphabet.
  for (const prefix of ['TXSY', 'PXSY', 'NTXSY', 'NPXSY']) {
    if (!upper.startsWith(prefix)) continue
    const rest = upper.slice(prefix.length)
    if (rest.startsWith('M') || rest.startsWith('B')) return '\\mathbb'
    if (rest === '' || rest.startsWith('S')) return '\\mathcal'
    return null
  }
  if (upper.startsWith('TXBSY') || upper.startsWith('PXBSY')) return '\\mathcal'
  // Fraktur in txmia and pxmia (and newtx's txmiaX, newpx's pxmiaX).
  if (upper.startsWith('TXMIA') || upper.startsWith('PXMIA')) return '\\mathfrak'
  // Fourier's and mathpazo's alphabets are fonts of their own.
  if (upper.startsWith('FOURIER-MATH-CAL')) return '\\mathcal'
  if (upper.startsWith('FOURIER-MATH-BLACKBOARD') || upper.startsWith('PAZOMATHBLACKBOARD')) return '\\mathbb'
  if (upper.startsWith('CMSY') || upper.startsWith('CMBSY') || upper.startsWith('EUSM')
    || upper.startsWith('EUSB') || upper.startsWith('LMMATHSYMBOLS')
    || upper.startsWith('HFBRSY') || upper.startsWith('CMBRSY')) return '\\mathcal'
  if (upper.startsWith('EUFM') || upper.startsWith('EUFB')) return '\\mathfrak'
  if (upper.startsWith('RSFS')) return '\\mathscr'
  if (upper.startsWith('BBOLD') || upper.startsWith('DSROM') || upper.startsWith('DSSS')
    || upper.startsWith('MSBM') || upper.startsWith('BBM') || upper.includes('STBB')
    || upper.startsWith('HFBRBS')) return '\\mathbb'
  return null
}

// MARK: - Names that are code points

/** The code points a glyph name spells, when it is one of the names the Adobe
 *  Glyph List reserves for that: "uniXXXX" (several in a row for a
 *  ligature) or "uXXXX" to "uXXXXXX". A variant suffix is dropped. */
export function unicodeName(name: string): number[] | null {
  const dot = name.indexOf('.')
  const body = dot >= 0 ? name.slice(0, dot) : name
  if (body.startsWith('uni')) {
    const hex = body.slice(3)
    if (!/^[0-9A-Fa-f]+$/.test(hex) || hex.length % 4 !== 0) return null
    const scalars: number[] = []
    for (let at = 0; at < hex.length; at += 4) scalars.push(parseInt(hex.slice(at, at + 4), 16))
    return scalars
  }
  if (body.startsWith('u')) {
    const hex = body.slice(1)
    if (!(hex.length >= 4 && hex.length <= 6) || !/^[0-9A-Fa-f]+$/.test(hex)) return null
    return [parseInt(hex, 16)]
  }
  return null
}

/** `Unicode.Scalar(value)` exists. */
const isScalar = (value: number) => value >= 0 && value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff)

/** What a run of code points is in LaTeX: a styled letter written with its
 *  style, a symbol as its command, anything else as the character itself. */
export function latexOfScalars(scalars: number[]): string | null {
  let out = ''
  for (const value of scalars) {
    // The script small l is \ell — STIX draws its \ell from there.
    if (value === 0x1d4c1) { out += '\\ell'; continue }
    const letter = mathAlphanumeric(value)
    if (letter !== null) {
      out += styled(letter.base, letter.style)
    } else if (isScalar(value)) {
      const character = String.fromCodePoint(value)
      out += unicodeCommand(character) ?? character
    } else {
      return null
    }
  }
  return out === '' ? null : out
}

/** How a letter is set in a formula (`TeXGlyphNames.MathStyle`, by name). */
export type MathStyle = 'italic' | 'upright' | 'bold' | 'boldItalic' | 'script' | 'boldScript' | 'fraktur'
  | 'boldFraktur' | 'doubleStruck' | 'sans' | 'sansBold' | 'sansItalic' | 'sansBoldItalic' | 'mono'

/** The letter with its style written round it. */
export function styled(base: string, style: MathStyle): string {
  const greek = base.startsWith('\\')
  switch (style) {
    case 'italic': return base
    case 'upright': return greek ? base : `\\mathrm{${base}}`
    case 'bold': return greek ? `\\boldsymbol{${base}}` : `\\mathbf{${base}}`
    case 'boldItalic': return `\\boldsymbol{${base}}`
    case 'script': return `\\mathcal{${base}}`
    case 'boldScript': return `\\boldsymbol{\\mathcal{${base}}}`
    case 'fraktur': return `\\mathfrak{${base}}`
    case 'boldFraktur': return `\\boldsymbol{\\mathfrak{${base}}}`
    case 'doubleStruck': return `\\mathbb{${base}}`
    case 'sans': case 'sansItalic': return `\\mathsf{${base}}`
    case 'sansBold': case 'sansBoldItalic': return `\\boldsymbol{\\mathsf{${base}}}`
    case 'mono': return `\\mathtt{${base}}`
  }
}

/** A letter or digit of the Mathematical Alphanumeric Symbols, or one Unicode
 *  had already put among the Letterlike Symbols: which, and in which style. */
export function mathAlphanumeric(value: number): { base: string; style: MathStyle } | null {
  const known = T.mathAlphanumeric[String(value)]
  return known ? { base: known[0], style: known[1] as MathStyle } : null
}

// MARK: - Names

/** A piece of a drawing rather than a symbol — the tips and middle of a
 *  horizontal brace, the shaft of a tall arrow: it spells nothing, without
 *  being unreadable. */
export function isDecoration(name: string | null): boolean {
  if (name === null) return false
  return name.startsWith('braceh') || name.startsWith('braceex') || name.startsWith('bracketleftex')
    || name.startsWith('bracketrightex') || name.startsWith('parenleftex')
    || name.startsWith('parenrightex') || name.startsWith('arrowvertex')
    || name.startsWith('arrowdblvertex') || name.startsWith('radicalvertex')
    || name === 'bracerightmid' || name === 'braceleftmid' || name === 'braceleftbt'
    || name === 'bracerightbt' || name === 'bracelefttp' || name === 'bracerighttp'
}

const BIG_OPERATOR_STEMS = new Set([
  'summation', 'product', 'integral', 'union', 'intersection', 'coproduct', 'logicaland',
  'logicalor', 'circleplus', 'circlemultiply', 'circledot', 'unionmulti', 'unionsq',
  'contintegral',
])

/** A large operator that takes limits: a name with a size on it — the
 *  symbol fonts name the small ∪ after the same thing as the big one — or
 *  one of the few that exist only as operators. */
export function isBigOperator(name: string | null): boolean {
  if (name === null) return false
  const stem = stripped(name)
  for (const size of ['text', 'display']) {
    if (stem.endsWith(size)) return BIG_OPERATOR_STEMS.has(stem.slice(0, stem.length - size.length))
  }
  return ['summation', 'product', 'integral', 'coproduct', 'contintegral'].includes(stem)
}

/** A glyph name without its variant suffix: "summationdisplay.1" is the
 *  display sum from a second font. */
export function stripped(name: string): string {
  const dot = name.indexOf('.')
  return dot <= 0 ? name : name.slice(0, dot)
}

/** An accent that grows to cover what is under it: \widehat, \widetilde. */
export function isWideAccent(name: string | null): boolean {
  if (name === null) return false
  const stem = stripped(name)
  return stem.startsWith('hatwide') || stem.startsWith('tildewide')
}

export function openingDelimiter(name: string | null): string | null {
  if (name === null) return null
  if (name.startsWith('parenleft')) return '('
  if (name.startsWith('bracketleft')) return '['
  if (name.startsWith('braceleft')) return '\\{'
  if (name.startsWith('angbracketleft')) return '\\langle'
  if (name.startsWith('floorleft')) return '\\lfloor'
  if (name.startsWith('ceilingleft')) return '\\lceil'
  return null
}

export function closingDelimiter(name: string | null): string | null {
  if (name === null) return null
  if (name.startsWith('parenright')) return ')'
  if (name.startsWith('bracketright')) return ']'
  if (name.startsWith('braceright')) return '\\}'
  if (name.startsWith('angbracketright')) return '\\rangle'
  if (name.startsWith('floorright')) return '\\rfloor'
  if (name.startsWith('ceilingright')) return '\\rceil'
  return null
}

/** A bar that fences rather than opens or closes: | and ‖ (and newtx's tall
 *  bar, built from "barex" pieces). */
export function fence(name: string | null): string | null {
  if (name === null) return null
  // STIX builds a tall bar from "bar.x" pieces: the bar with its variant suffix.
  const stem = stripped(name)
  if (name.startsWith('vextenddouble') || stem === 'bardbl' || name.startsWith('bardblex')) return '\\|'
  if (name.startsWith('vextendsingle') || stem === 'bar' || name.startsWith('barex')) return '|'
  return null
}

/** The accent a glyph is, by its name. (An arrow from the symbol font is an
 *  arrow: the "→" of n\to\infty is not \vec{n}.) */
export function accent(name: string | null): string | null {
  if (name === null) return null
  switch (stripped(name)) {
    case 'circumflex': case 'hatwide': case 'hatwider': case 'hatwidest': return '\\hat'
    case 'tilde': case 'tildewide': case 'tildewider': case 'tildewidest': return '\\tilde'
    case 'macron': return '\\bar'
    case 'dotaccent': case 'dotacc': return '\\dot'
    case 'dieresis': case 'ddotacc': return '\\ddot'
    case 'dddotacc': return '\\dddot'
    case 'ddddotacc': return '\\ddddot'
    case 'caron': return '\\check'
    case 'breve': return '\\breve'
    case 'acute': return '\\acute'
    case 'grave': return '\\grave'
    case 'ring': return '\\mathring'
    case 'vector': case 'vec': return '\\vec'
    default: return null
  }
}

// MARK: - Standard encodings

/** Computer Modern has not moved a glyph since 1979, so a font that names
 *  nothing can still be read by knowing which font it is. */
function standardEncoding(code: number, fontName: string): string | null {
  const upper = family(fontName)
  const key = String(code)
  if (upper.startsWith('CMMI')) return T.mathItalic[key] ?? null
  if (upper.startsWith('CMSY')) return T.symbols[key] ?? null
  if (upper.startsWith('MSBM')) return T.blackboard[key] ?? null
  if (upper.startsWith('CMEX')) return T.extensions[key] ?? null
  // Roman and sans text fonts: ASCII, with the handful TeX moves.
  if (['CMR', 'CMB', 'CMTI', 'CMTT', 'SF', 'CMSS'].some((prefix) => upper.startsWith(prefix))) {
    return T.roman[key] ?? asciiIfPrintable(code)
  }
  return null
}

function asciiIfPrintable(code: number): string | null {
  return code >= 0x20 && code < 0x7f ? String.fromCharCode(code) : null
}

/** A byte read through the encoding a font declares (`PDFContentScanner.decode`), ligatures written out. */
export function decodeByte(code: number, encoding: string | null): string | null {
  if (code < 0x20 || encoding === null) return null
  const table = encoding === 'MacRomanEncoding' ? T.macRoman : encoding === 'WinAnsiEncoding' ? T.winAnsi : null
  return table?.[String(code)] ?? null
}
