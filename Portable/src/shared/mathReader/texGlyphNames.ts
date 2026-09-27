/**
 * What a TeX font calls its glyphs, and what that is in LaTeX — the Mac's
 * `TeXGlyphNames`. The tables are not transcribed: `texTables.json` is what
 * the Swift's own tables hold (`Scripts/mathreader-fixtures.sh tables`).
 */
import tables from './texTables.json'

const T = tables as unknown as Record<'byName' | 'mathItalic' | 'symbols' | 'blackboard' | 'extensions' | 'roman' | 'macRoman' | 'winAnsi', Record<string, string>>

const isLetter = (s: string) => /^\p{L}/u.test(s)
export const family = (fontName: string) => (fontName.split('+').pop() ?? fontName).toUpperCase()

export function latex(name: string | null, code: number, fontName: string, unicode: string | null, isSymbolic = true): string | null {
  const resolved = resolve(name, code, fontName, unicode, isSymbolic)
  if (resolved === null) return null
  // Computer Modern's symbol font holds no upright letters: a letter from it is a script one.
  if ([...resolved].length === 1 && isLetter(resolved) && isCalligraphic(fontName)) return `\\mathcal{${resolved}}`
  return resolved
}

function resolve(name: string | null, code: number, fontName: string, unicode: string | null, isSymbolic: boolean): string | null {
  if (name !== null && T.byName[name] !== undefined) return T.byName[name]
  if (name !== null && [...name].length === 1) return name
  if (!isSymbolic && unicode) return unicode
  const standard = standardEncoding(code, fontName)
  if (standard !== null) return standard
  if (unicode) return unicode
  return null
}

function isCalligraphic(fontName: string): boolean {
  const upper = family(fontName)
  return upper.startsWith('CMSY') || upper.startsWith('CMBSY')
}

export function isBigOperator(name: string | null): boolean {
  if (name === null) return false
  return ['summation', 'product', 'integral', 'union', 'intersection', 'coproduct', 'logicaland', 'logicalor'].some((prefix) => name.startsWith(prefix))
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

export function fence(name: string | null): string | null {
  if (name === null) return null
  if (name.startsWith('vextenddouble') || name === 'bardbl') return '\\|'
  if (name.startsWith('vextendsingle') || name === 'bar') return '|'
  return null
}

export function accent(name: string | null): string | null {
  switch (name) {
    case 'circumflex': case 'hatwide': case 'hatwider': case 'hatwidest': return '\\hat'
    case 'tilde': case 'tildewide': case 'tildewider': case 'tildewidest': return '\\tilde'
    case 'macron': return '\\bar'
    case 'dotaccent': return '\\dot'
    case 'vector': case 'arrowright': return '\\vec'
    default: return null
  }
}

function standardEncoding(code: number, fontName: string): string | null {
  const upper = family(fontName)
  const key = String(code)
  if (upper.startsWith('CMMI')) return T.mathItalic[key] ?? null
  if (upper.startsWith('CMSY')) return T.symbols[key] ?? null
  if (upper.startsWith('MSBM')) return T.blackboard[key] ?? null
  if (upper.startsWith('CMEX')) return T.extensions[key] ?? null
  if (['CMR', 'CMB', 'CMTI', 'CMTT', 'SF', 'CMSS'].some((prefix) => upper.startsWith(prefix))) return T.roman[key] ?? asciiIfPrintable(code)
  return asciiIfPrintable(code)
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
