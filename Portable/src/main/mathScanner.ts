/**
 * What a PDF page actually draws — the Mac's `PDFContentScanner`, on the
 * PDF reader this build already has (`pdfupdate/`), so the two builds read
 * the same glyphs from the same bytes: which glyph, from which font (by its
 * `BaseFont`, its `ToUnicode`, its `Differences` names and the encoding its
 * Type 1 program carries in the clear), at which point, and the thin filled
 * rectangles a page uses for fraction bars. `shared/mathReader/` reads the
 * mathematics back out of them.
 *
 * CoreGraphics' own habits are kept, because the Mac's answers came from
 * them: only the page's content streams are read (no form XObjects), codes
 * are one byte — two for a composite (Type0) font —, `q`/`Q` keep only the CTM, a `B` strokes and does not fill
 * (the later callback replaced the earlier), and a rectangle waits for the
 * next fill however many `n`s come between.
 */
import { Lexer, Parser, PDFDict, Filters, arrayOf, dictOf, intOf, nameOf, numberOf, stringBytesOf, type PDFObj } from './pdfupdate/syntax.js'
import { PDFFile } from './pdfupdate/file.js'
import { Opened } from './pdfupdate/writer.js'
import { IDENTITY, applyPoint, applyRect, concat, type Matrix, type Rect } from '../shared/mathReader/geometry.js'
import type { Glyph, Rule } from '../shared/mathReader/glyph.js'
import { decodeByte } from '../shared/mathReader/texGlyphNames.js'

interface Font {
  name: string
  widths: Map<number, number>
  defaultWidth: number
  toUnicode: Map<number, string>
  glyphNames: Map<number, string>
  baseEncoding: string | null
  isSymbolic: boolean
  /** One byte a glyph for a simple font; two for a composite (Type0) one —
   *  what Word and every "Save as PDF" write (the Mac's `bytesPerCode`). */
  bytesPerCode: number
}

export interface ScannedPage {
  glyphs: Glyph[]
  rules: Rule[]
  cropBox: Rect
}

/** Every page's glyphs, read on demand and kept while the file is the same. */
export class MathScanner {
  private file: PDFFile
  private pages: { dict: PDFDict }[]
  private scanned = new Map<number, ScannedPage>()

  constructor(bytes: Uint8Array) {
    this.file = new PDFFile(bytes)
    try {
      Opened.openSecurity(this.file, new Uint8Array())
    } catch {
      // A file this cannot decrypt reads as nothing: the quotation falls back to the text.
    }
    this.pages = this.file.pages()
  }

  get pageCount() { return this.pages.length }

  page(index: number): ScannedPage | null {
    const known = this.scanned.get(index)
    if (known) return known
    const page = this.pages[index]
    if (!page) return null
    let result: ScannedPage
    try {
      result = scan(this.file, page.dict)
    } catch {
      result = { glyphs: [], rules: [], cropBox: box(this.file, page.dict) }
    }
    this.scanned.set(index, result)
    return result
  }
}

function box(file: PDFFile, page: PDFDict): Rect {
  const array = arrayOf(file.resolve(page.get('CropBox'))) ?? arrayOf(file.resolve(page.get('MediaBox')))
  const values = (array ?? []).map((one) => numberOf(file.resolve(one)) ?? 0)
  if (values.length < 4) return { x: 0, y: 0, width: 612, height: 792 }
  const x = Math.min(values[0], values[2])
  const y = Math.min(values[1], values[3])
  return { x, y, width: Math.abs(values[2] - values[0]), height: Math.abs(values[3] - values[1]) }
}

function decoded(file: PDFFile, o: PDFObj | undefined): Uint8Array | null {
  const stream = file.resolve(o)
  if (stream.t !== 'stream') return null
  try {
    return Filters.decode(stream.dict, stream.data)
  } catch {
    return null
  }
}

const latin1 = (bytes: Uint8Array) => Buffer.from(bytes).toString('latin1')

function scan(file: PDFFile, page: PDFDict): ScannedPage {
  const fonts = loadFonts(file, page)
  const glyphs: Glyph[] = []
  const rules: Rule[] = []

  let ctm: Matrix = IDENTITY
  const ctmStack: Matrix[] = []
  let textMatrix: Matrix = IDENTITY
  let lineMatrix: Matrix = IDENTITY
  let fontSize = 0
  let charSpacing = 0
  let wordSpacing = 0
  let horizontalScale = 1
  let leading = 0
  let rise = 0
  let currentFont: Font | null = null
  let pendingRect: Rect | null = null
  let pathStart: { x: number; y: number } | null = null
  let pathEnd: { x: number; y: number } | null = null
  let lineWidth = 1

  const translate = (x: number, y: number): Matrix => [1, 0, 0, 1, x, y]
  const nextLine = () => {
    lineMatrix = concat(translate(0, -leading), lineMatrix)
    textMatrix = lineMatrix
  }
  const show = (bytes: Uint8Array) => {
    const step = currentFont?.bytesPerCode ?? 1
    for (let index = 0; index + step <= bytes.length; index += step) {
      let code = 0
      for (let byte = 0; byte < step; byte += 1) code = (code << 8) | bytes[index + byte]
      const width = (currentFont?.widths.get(code) ?? currentFont?.defaultWidth ?? 500) / 1000
      const placement = concat(concat([fontSize * horizontalScale, 0, 0, fontSize, 0, rise], textMatrix), ctm)
      const scale = Math.sqrt(Math.abs(placement[0] * placement[3] - placement[1] * placement[2]))
      // A zero in a composite font's ToUnicode says the file does not know
      // the glyph; its code is a glyph number, never a character code.
      let meaning = currentFont?.toUnicode.get(code)
      if (step > 1 && meaning !== undefined && [...meaning].every((c) => c.codePointAt(0) === 0)) meaning = undefined
      glyphs.push({
        code: step > 1 ? -1 : code,
        fontName: currentFont?.name ?? '',
        unicode: meaning ?? (currentFont ? decodeByte(code, currentFont.baseEncoding) : null),
        glyphName: currentFont?.glyphNames.get(code) ?? null,
        isSymbolic: step > 1 ? false : currentFont?.isSymbolic ?? true,
        size: scale,
        x: placement[4],
        y: placement[5],
        width: width * scale,
      })
      let advance = width * fontSize + charSpacing
      // Word spacing is for the single byte 32 only (ISO 32000 §9.3.3).
      if (code === 32 && step === 1) advance += wordSpacing
      textMatrix = concat(translate(advance * horizontalScale, 0), textMatrix)
    }
  }
  const fillPendingRect = () => {
    if (!pendingRect) return
    const rect = pendingRect
    pendingRect = null
    const transformed = applyRect(rect, ctm)
    if (transformed.height < 3 && transformed.width > 1) rules.push({ rect: transformed })
  }
  const strokePendingLine = () => {
    const start = pathStart
    const end = pathEnd
    pathStart = null
    pathEnd = null
    if (!start || !end) return
    const a = applyPoint(start, ctm)
    const b = applyPoint(end, ctm)
    if (!(Math.abs(a.y - b.y) < 1.5 && Math.abs(a.x - b.x) > 1)) return
    const thickness = Math.max(lineWidth * Math.sqrt(Math.abs(ctm[0] * ctm[3] - ctm[1] * ctm[2])), 0.4)
    rules.push({ rect: { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y) - thickness / 2, width: Math.abs(b.x - a.x), height: thickness } })
  }

  const operands: PDFObj[] = []
  const numbers = (n: number): number[] | null => {
    if (operands.length < n) return null
    const values = operands.slice(operands.length - n).map((o) => numberOf(o))
    return values.every((v) => v !== undefined) ? (values as number[]) : null
  }
  const number = (): number | null => numbers(1)?.[0] ?? null

  for (const content of contentStreams(file, page)) {
    const parser = new Parser(content)
    for (;;) {
      const at = parser.pos
      let token
      try {
        token = parser.lex.next()
      } catch {
        break
      }
      if (token.k === 'eof') break
      if (token.k === 'kw' && !['true', 'false', 'null'].includes(token.v)) {
        const op = token.v
        switch (op) {
          case 'q': ctmStack.push(ctm); break
          case 'Q': { const last = ctmStack.pop(); if (last) ctm = last; break }
          case 'cm': { const v = numbers(6); if (v) ctm = concat(v as Matrix, ctm); break }
          case 'BT': textMatrix = IDENTITY; lineMatrix = IDENTITY; break
          case 'Tf': {
            const size = operands.length > 0 ? numberOf(operands[operands.length - 1]) : undefined
            const name = operands.length > 1 ? nameOf(operands[operands.length - 2]) : undefined
            fontSize = size ?? 0
            currentFont = name !== undefined ? fonts.get(name) ?? null : null
            break
          }
          case 'Td': { const v = numbers(2); if (v) { lineMatrix = concat(translate(v[0], v[1]), lineMatrix); textMatrix = lineMatrix } break }
          case 'TD': { const v = numbers(2); if (v) { leading = -v[1]; lineMatrix = concat(translate(v[0], v[1]), lineMatrix); textMatrix = lineMatrix } break }
          case 'Tm': { const v = numbers(6); if (v) { lineMatrix = v as Matrix; textMatrix = lineMatrix } break }
          case 'T*': nextLine(); break
          case 'TL': leading = number() ?? 0; break
          case 'Tc': charSpacing = number() ?? 0; break
          case 'Tw': wordSpacing = number() ?? 0; break
          case 'Tz': horizontalScale = (number() ?? 0) / 100; break
          case 'Ts': rise = number() ?? 0; break
          case 'Tj': { const s = stringBytesOf(operands[operands.length - 1]); if (s) show(s); break }
          case "'": { const s = stringBytesOf(operands[operands.length - 1]); if (s) { nextLine(); show(s) } break }
          case 'TJ': {
            const array = arrayOf(operands[operands.length - 1])
            if (!array) break
            for (const item of array) {
              const s = stringBytesOf(item)
              if (s) { show(s); continue }
              const shift = numberOf(item)
              if (shift !== undefined) textMatrix = concat(translate(-shift / 1000 * fontSize * horizontalScale, 0), textMatrix)
            }
            break
          }
          case 'm': { const v = numbers(2); if (v) { pathStart = { x: v[0], y: v[1] }; pathEnd = null } break }
          case 'l': { const v = numbers(2); if (v) pathEnd = { x: v[0], y: v[1] }; break }
          case 'w': lineWidth = number() ?? 0; break
          case 're': { const v = numbers(4); if (v) pendingRect = { x: v[0], y: v[1], width: v[2], height: v[3] }; break }
          case 'f': case 'F': case 'f*': fillPendingRect(); break
          case 'S': case 's': case 'B': case 'B*': strokePendingLine(); break
          case 'BI': skipInlineImage(parser); break
          default: break
        }
        operands.length = 0
        continue
      }
      try {
        operands.push(parser.objectFrom(token, at, 0))
      } catch {
        break
      }
    }
  }
  return { glyphs, rules, cropBox: box(file, page) }
}

/** The page's content, stream after stream, as one reader would see it. */
function contentStreams(file: PDFFile, page: PDFDict): Uint8Array[] {
  const contents = file.resolve(page.get('Contents'))
  const list = contents.t === 'array' ? contents.v : [page.get('Contents')]
  const out: Uint8Array[] = []
  for (const one of list) {
    const data = decoded(file, one)
    if (data) out.push(data)
  }
  return out
}

/** An inline image's bytes are not tokens: skip to the `EI` after `ID`. */
function skipInlineImage(parser: Parser) {
  const lex: Lexer = parser.lex
  const b = lex.b
  let i = lex.pos
  while (i + 1 < b.length && !(b[i] === 0x49 && b[i + 1] === 0x44 && (i + 2 >= b.length || b[i + 2] <= 0x20))) i += 1
  i += 2
  while (i + 1 < b.length && !((b[i - 1] <= 0x20) && b[i] === 0x45 && b[i + 1] === 0x49 && (i + 2 >= b.length || b[i + 2] <= 0x20))) i += 1
  lex.pos = Math.min(b.length, i + 2)
}

function loadFonts(file: PDFFile, page: PDFDict): Map<string, Font> {
  const fonts = new Map<string, Font>()
  const resources = dictOf(file.resolve(page.get('Resources')))
  const fontDictionary = resources ? dictOf(file.resolve(resources.get('Font'))) : undefined
  if (!fontDictionary) return fonts
  for (const [key, value] of fontDictionary.pairs) {
    const dictionary = dictOf(file.resolve(value))
    if (!dictionary) continue
    const font: Font = { name: '', widths: new Map(), defaultWidth: 500, toUnicode: new Map(), glyphNames: new Map(), baseEncoding: null, isSymbolic: true, bytesPerCode: 1 }
    const baseFont = nameOf(file.resolve(dictionary.get('BaseFont')))
    if (baseFont !== undefined) font.name = baseFont
    const firstChar = intOf(file.resolve(dictionary.get('FirstChar'))) ?? 0
    const widths = arrayOf(file.resolve(dictionary.get('Widths')))
    widths?.forEach((one, index) => {
      const width = numberOf(file.resolve(one))
      if (width !== undefined) font.widths.set(firstChar + index, width)
    })
    // A composite font: two bytes a glyph, and its widths and its
    // descriptor are on the one font it descends to.
    let descendant: PDFDict | undefined
    if (nameOf(file.resolve(dictionary.get('Subtype'))) === 'Type0') {
      font.bytesPerCode = 2
      const descendants = arrayOf(file.resolve(dictionary.get('DescendantFonts')))
      descendant = descendants && descendants[0] ? dictOf(file.resolve(descendants[0])) : undefined
      if (descendant) {
        font.defaultWidth = numberOf(file.resolve(descendant.get('DW'))) ?? 1000
        const cidWidths = arrayOf(file.resolve(descendant.get('W')))
        if (cidWidths) font.widths = parseCIDWidths(file, cidWidths)
      }
    }
    const descriptor = dictOf(file.resolve((descendant ?? dictionary).get('FontDescriptor')))
    if (descriptor) {
      const flags = intOf(file.resolve(descriptor.get('Flags'))) ?? 0
      font.isSymbolic = (flags & 4) !== 0
    }
    const toUnicode = decoded(file, dictionary.get('ToUnicode'))
    if (toUnicode) font.toUnicode = parseToUnicode(latin1(toUnicode))
    const encoding = file.resolve(dictionary.get('Encoding'))
    if (encoding.t === 'dict') {
      font.glyphNames = parseDifferences(file, encoding.v)
      const base = nameOf(file.resolve(encoding.v.get('BaseEncoding')))
      if (base !== undefined) font.baseEncoding = base
    }
    if (encoding.t === 'name') font.baseEncoding = encoding.v
    const builtIn = builtInEncoding(file, descriptor)
    if (builtIn.size > 0) {
      const merged = new Map(builtIn)
      for (const [code, name] of font.glyphNames) merged.set(code, name)
      font.glyphNames = merged
    }
    fonts.set(key, font)
  }
  return fonts
}

/** A composite font's `/W`: `c [w₁ w₂ …]` from `c` on, or `c₁ c₂ w` for a run. */
function parseCIDWidths(file: PDFFile, array: PDFObj[]): Map<number, number> {
  const widths = new Map<number, number>()
  let index = 0
  while (index < array.length) {
    const first = intOf(file.resolve(array[index]))
    if (first === undefined) { index += 1; continue }
    const run = index + 1 < array.length ? arrayOf(file.resolve(array[index + 1])) : undefined
    if (run) {
      run.forEach((one, offset) => {
        const width = numberOf(file.resolve(one))
        if (width !== undefined) widths.set(first + offset, width)
      })
      index += 2
      continue
    }
    const last = index + 1 < array.length ? intOf(file.resolve(array[index + 1])) : undefined
    const width = index + 2 < array.length ? numberOf(file.resolve(array[index + 2])) : undefined
    if (last !== undefined && width !== undefined && last >= first && last - first < 65_536) {
      for (let code = first; code <= last; code += 1) widths.set(code, width)
    }
    index += 3
  }
  return widths
}

function parseDifferences(file: PDFFile, encoding: PDFDict): Map<number, string> {
  const names = new Map<number, string>()
  const array = arrayOf(file.resolve(encoding.get('Differences')))
  if (!array) return names
  let code = 0
  for (const item of array) {
    const value = file.resolve(item)
    if (value.t === 'int') {
      code = value.v
      continue
    }
    if (value.t === 'name') {
      names.set(code, value.v)
      code += 1
    }
  }
  return names
}

function builtInEncoding(file: PDFFile, descriptor: PDFDict | undefined): Map<number, string> {
  const names = new Map<number, string>()
  if (!descriptor) return names
  const data = decoded(file, descriptor.get('FontFile'))
  if (!data) return names
  const window = data.subarray(0, Math.min(data.length, 60_000))
  const marker = Buffer.from(window).indexOf('eexec', 0, 'latin1')
  const head = marker >= 0 ? data.subarray(0, marker) : data.subarray(0, 20_000)
  const text = latin1(head)
  for (const match of text.matchAll(/dup\s+(\d+)\s*\/([A-Za-z0-9._]+)\s+put/g)) names.set(Number(match[1]), match[2])
  return names
}

/** UTF-16, four hex digits a unit — a letter outside the first plane is two (𝒒 is D835 DC92). */
function hexCharacters(hex: string): string | null {
  const units: number[] = []
  for (let index = 0; index + 4 <= hex.length; index += 4) {
    const value = parseInt(hex.slice(index, index + 4), 16)
    if (Number.isNaN(value)) return null
    units.push(value)
  }
  return units.length === 0 ? null : String.fromCharCode(...units)
}

function parseToUnicode(text: string): Map<number, string> {
  const table = new Map<number, string>()
  for (const section of text.split('beginbfchar').slice(1)) {
    const body = section.split('endbfchar')[0] ?? ''
    for (const match of body.matchAll(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g)) {
      const code = parseInt(match[1], 16)
      const value = hexCharacters(match[2])
      if (value !== null && Number.isFinite(code)) table.set(code, value)
    }
  }
  for (const section of text.split('beginbfrange').slice(1)) {
    const body = section.split('endbfrange')[0] ?? ''
    for (const match of body.matchAll(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g)) {
      const low = parseInt(match[1], 16)
      const high = parseInt(match[2], 16)
      const start = parseInt(match[3], 16)
      if (!Number.isFinite(low) || !Number.isFinite(high) || !Number.isFinite(start) || start > 0xffffffff) continue
      for (let offset = 0; offset <= Math.max(high - low, 0); offset += 1) {
        const scalar = start + offset
        if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) continue
        table.set(low + offset, String.fromCodePoint(scalar))
      }
    }
  }
  return table
}
