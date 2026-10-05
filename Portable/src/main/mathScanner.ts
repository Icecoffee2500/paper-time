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
import { italicEvidence, type ItalicEvidence } from '../shared/mathReader/reader.js'
import { isLetter, isWhitespace } from '../shared/metadata/chars.js'

interface Font {
  name: string
  widths: Map<number, number>
  defaultWidth: number
  toUnicode: Map<number, string>
  glyphNames: Map<number, string>
  baseEncoding: string | null
  isSymbolic: boolean
  /** Whether the font says it is slanted: a nonzero `/ItalicAngle`, or the
   *  Italic flag, in its descriptor. The file says this outright, whatever
   *  the font is called — URW's clone of Avant Garde names its oblique
   *  "URWGothicL-BookObli", and read by name its letters were upright: the
   *  variables of a slide deck set in it came back as
   *  \mathrm{S}_{\mathrm{i}}, and the line they were on as a sentence (the
   *  Mac's `Font.isItalic`). */
  isItalic: boolean
  /** One byte a glyph for a simple font; two for a composite (Type0) one —
   *  what Word and every "Save as PDF" write (the Mac's `bytesPerCode`). */
  bytesPerCode: number
  /** What one unit of `widths` is in text space: a thousandth, or a Type 3
   *  font's `/FontMatrix` — pdfTeX's bitmap fonts count in pixels, 0.011 of
   *  an em at 600 dpi (the Mac's `widthScale`). */
  widthScale: number
}

/** The name given to a Type 3 font whose letters are double-struck, so the
 *  rest reads it as any blackboard font: \mathbb (`doubleStruckType3`). */
export const DOUBLE_STRUCK_TYPE3 = 'Type3+BBM'

export interface ScannedPage {
  glyphs: Glyph[]
  rules: Rule[]
  cropBox: Rect
}

/** Every page's glyphs, read on demand and kept while the file is the same. */
/** A glyph's name as the TeX tables know it: MathDesign numbers its variants
 *  ("radicalbig3", "parenleftbig4") where every other font writes
 *  "radicalbig" (`PDFContentScanner.plainName`). */
export function plainName(name: string | null, font: string): string | null {
  if (name === null || !/[0-9]$/.test(name)) return name
  const family = (font.split('+').pop() ?? font).toUpperCase()
  if (!family.startsWith('MATHDESIGN')) return name
  const trimmed = name.replace(/[0-9]+$/, '')
  if (trimmed === '') return name
  // The digit is the size: "parenleftbig1" to "parenleftbig4" are \bigl( to \Biggl(.
  const digit = Number(name.slice(trimmed.length))
  if (trimmed.endsWith('big') && digit >= 1 && digit <= 4) return trimmed.slice(0, -3) + ['big', 'Big', 'bigg', 'Bigg'][digit - 1]
  return trimmed
}

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

  private evidence = new Map<number, ItalicEvidence>()

  /**
   * What the paper's first ten pages but this one say about where it keeps
   * its variables, or-ed together — the half of the Mac's
   * `variablesInTextItalic(for:scanned:)` that is not the page itself (a
   * page that draws maths italic letters says no whatever the rest say).
   * The Mac asks these pages while one page is being read, so a glyph of
   * theirs that spells nothing borrows from that page's text; here there is
   * no text, and it spells nothing.
   */
  italicElsewhere(pageIndex: number): ItalicEvidence {
    let ownLetters = false
    let evidence = false
    for (let index = 0; index < Math.min(this.pages.length, 10); index += 1) {
      if (index === pageIndex) continue
      let seen = this.evidence.get(index)
      if (seen === undefined) {
        seen = italicEvidence(this.page(index)?.glyphs ?? [])
        this.evidence.set(index, seen)
      }
      ownLetters = ownLetters || seen.ownLetters
      evidence = evidence || seen.evidence
    }
    return { ownLetters, evidence }
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
  const images = loadImageNames(file, page)
  const glyphs: Glyph[] = []
  const rules: Rule[] = []

  let ctm: Matrix = IDENTITY
  const ctmStack: { ctm: Matrix; charSpacing: number; wordSpacing: number; horizontalScale: number; leading: number; rise: number; fontSize: number; currentFont: Font | null; renderMode: number }[] = []
  let textMatrix: Matrix = IDENTITY
  let lineMatrix: Matrix = IDENTITY
  let fontSize = 0
  let charSpacing = 0
  let wordSpacing = 0
  let horizontalScale = 1
  let leading = 0
  let rise = 0
  let currentFont: Font | null = null
  // The text rendering mode (`Tr`, ISO 32000 §9.3.6). Modes 3 and 7 draw
  // nothing: a scan's OCR layer, and the words iOS lays invisibly over
  // handwriting so it can be searched — "P(Ai)= হ☆০P(Bi)" over a page of
  // sums. A glyph the page does not draw is not on the page, and a rectangle
  // over such a page reads the picture instead.
  let renderMode = 0
  let pendingRect: Rect | null = null
  let pathStart: { x: number; y: number } | null = null
  let pathEnd: { x: number; y: number } | null = null
  // The lowest and highest point the current path reaches, in user space.
  let pathLowY = 0
  let pathHighY = 0
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
      const known = currentFont?.widths.get(code)
      const width = currentFont && known !== undefined ? known * currentFont.widthScale : (currentFont?.defaultWidth ?? 500) / 1000
      const placement = concat(concat([fontSize * horizontalScale, 0, 0, fontSize, 0, rise], textMatrix), ctm)
      const scale = Math.sqrt(Math.abs(placement[0] * placement[3] - placement[1] * placement[2]))
      // A zero in a composite font's ToUnicode says the file does not know
      // the glyph; its code is a glyph number, never a character code.
      let meaning = currentFont?.toUnicode.get(code)
      if (step > 1 && meaning !== undefined && [...meaning].every((c) => c.codePointAt(0) === 0)) meaning = undefined
      // Passed over, not kept, when the page does not draw it.
      if (renderMode !== 3 && renderMode !== 7) glyphs.push({
        code: step > 1 ? -1 : code,
        fontName: currentFont?.name ?? '',
        unicode: meaning ?? (currentFont ? decodeByte(code, currentFont.baseEncoding) : null),
        glyphName: plainName(currentFont?.glyphNames.get(code) ?? null, currentFont?.name ?? ''),
        isSymbolic: step > 1 ? false : currentFont?.isSymbolic ?? true,
        isItalic: currentFont?.isItalic ?? false,
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
    const scale = Math.sqrt(Math.abs(ctm[0] * ctm[3] - ctm[1] * ctm[2]))
    if (!(Math.abs(a.y - b.y) < 1.5 && (pathHighY - pathLowY) * scale < 1.5 && Math.abs(a.x - b.x) > 1)) return
    const thickness = Math.max(lineWidth * scale, 0.4)
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
          // The text state — spacing, scale, leading, rise, the font — is
          // part of the graphics state (ISO 32000 §8.4.1, §9.3.1): what a
          // `q … Q` block set goes back with the block. Kept past the Q, a
          // table's `1.429 Tc` on one cell spread every letter of the
          // cells after it, and «Retraining» came back a letter per column.
          case 'q': ctmStack.push({ ctm, charSpacing, wordSpacing, horizontalScale, leading, rise, fontSize, currentFont, renderMode }); break
          case 'Q': {
            const last = ctmStack.pop()
            if (last) {
              ctm = last.ctm
              charSpacing = last.charSpacing
              wordSpacing = last.wordSpacing
              horizontalScale = last.horizontalScale
              leading = last.leading
              rise = last.rise
              fontSize = last.fontSize
              currentFont = last.currentFont
              renderMode = last.renderMode
            }
            break
          }
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
          // An integer, as `CGPDFScannerPopInteger` takes it: anything else is 0.
          case 'Tr': renderMode = (operands.length > 0 ? intOf(operands[operands.length - 1]) : undefined) ?? 0; break
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
          case 'm': { const v = numbers(2); if (v) { pathStart = { x: v[0], y: v[1] }; pathEnd = null; pathLowY = v[1]; pathHighY = v[1] } break }
          case 'l': { const v = numbers(2); if (v) { pathEnd = { x: v[0], y: v[1] }; pathLowY = Math.min(pathLowY, v[1]); pathHighY = Math.max(pathHighY, v[1]) } break }
          // A curve whose control points all lie on one level is a straight
          // line drawn the long way round: a document converted from HTML
          // draws every fraction bar as `m c c c S`. Its control points'
          // heights say whether it bent.
          case 'c': case 'v': case 'y': {
            const count = op === 'c' ? 6 : 4
            const v = numbers(count)
            if (v) {
              for (let pair = 1; pair < count; pair += 2) { pathLowY = Math.min(pathLowY, v[pair]); pathHighY = Math.max(pathHighY, v[pair]) }
              pathEnd = { x: v[count - 2], y: v[count - 1] }
            }
            break
          }
          case 'w': lineWidth = number() ?? 0; break
          case 're': { const v = numbers(4); if (v) pendingRect = { x: v[0], y: v[1], width: v[2], height: v[3] }; break }
          case 'f': case 'F': case 'f*': fillPendingRect(); break
          // An image drawn thin and wide is a rule too: a document converted
          // from HTML draws its fraction bars as a one-pixel image mask
          // stretched to 80 × 0.5 pt. Forms are not followed.
          case 'Do': {
            const name = operands.length > 0 ? nameOf(operands[operands.length - 1]) : undefined
            if (name !== undefined && images.has(name)) {
              const placed = applyRect({ x: 0, y: 0, width: 1, height: 1 }, ctm)
              if (placed.height < 3 && placed.width > 1) rules.push({ rect: placed })
            }
            break
          }
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

/** The names of the page's image XObjects. */
function loadImageNames(file: PDFFile, page: PDFDict): Set<string> {
  const names = new Set<string>()
  const resources = dictOf(file.resolve(page.get('Resources')))
  const xobjects = resources ? dictOf(file.resolve(resources.get('XObject'))) : undefined
  if (!xobjects) return names
  for (const [key, value] of xobjects.pairs) {
    const resolved = file.resolve(value)
    const dictionary = resolved && typeof resolved === 'object' && 'dict' in resolved ? (resolved as { dict: PDFDict }).dict : dictOf(resolved)
    if (dictionary && nameOf(file.resolve(dictionary.get('Subtype'))) === 'Image') names.add(key)
  }
  return names
}

function loadFonts(file: PDFFile, page: PDFDict): Map<string, Font> {
  const fonts = new Map<string, Font>()
  const resources = dictOf(file.resolve(page.get('Resources')))
  const fontDictionary = resources ? dictOf(file.resolve(resources.get('Font'))) : undefined
  if (!fontDictionary) return fonts
  for (const [key, value] of fontDictionary.pairs) {
    const dictionary = dictOf(file.resolve(value))
    if (!dictionary) continue
    const font: Font = { name: '', widths: new Map(), defaultWidth: 500, toUnicode: new Map(), glyphNames: new Map(), baseEncoding: null, isSymbolic: true, isItalic: false, bytesPerCode: 1, widthScale: 0.001 }
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
    const kind = nameOf(file.resolve(dictionary.get('Subtype')))
    if (kind === 'Type3') {
      const matrix = arrayOf(file.resolve(dictionary.get('FontMatrix')))
      const scale = matrix && matrix.length > 0 ? numberOf(file.resolve(matrix[0])) : undefined
      if (scale !== undefined && scale > 0) font.widthScale = scale
    }
    if (kind === 'Type0') {
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
      // Bit 7 is Italic; the angle is the slant of its stems, in degrees
      // from the vertical (TeX writes −14 for its maths italic, −12 for its
      // sans italic, −9.5 for its slanted).
      const angle = numberOf(file.resolve(descriptor.get('ItalicAngle'))) ?? 0
      font.isItalic = (flags & 64) !== 0 || Math.abs(angle) >= 1
    }
    const toUnicode = decoded(file, dictionary.get('ToUnicode'))
    if (toUnicode) font.toUnicode = toUnicodeTable(latin1(toUnicode))
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
    if (kind === 'Type3' && font.name === '' && drawsDoubleStruck(file, dictionary, font.glyphNames)) {
      font.name = DOUBLE_STRUCK_TYPE3
    }
    fonts.set(key, font)
  }
  return fonts
}

/**
 * Whether a Type 3 font draws double-struck letters — the Mac's
 * `drawsDoubleStruck`. bbm, which draws \mathbbm, has no outlines, so pdfTeX
 * writes it as a bitmap Type 3 font with no name and glyphs called "a80";
 * each glyph's picture says what it is: a double-struck letter's stems are
 * hollow, an enclosed hole the plain letter does not have (𝕀 one, I none;
 * ℙ two, P one). Most of its letters with more holes than they should have
 * make the font double-struck.
 */
function drawsDoubleStruck(file: PDFFile, font: PDFDict, names: Map<number, string>): boolean {
  const procedures = dictOf(file.resolve(font.get('CharProcs')))
  if (!procedures) return false
  let judged = 0
  let hollow = 0
  for (const [code, name] of names) {
    const plain = PLAIN_HOLES.get(code)
    if (plain === undefined) continue
    const data = decoded(file, procedures.get(name))
    const mask = data ? imageMask(data) : null
    if (!mask) continue
    judged += 1
    if (holes(mask) > plain) hollow += 1
  }
  return judged > 0 && hollow * 3 >= judged * 2
}

/** How many holes each letter and digit has in a plain roman face — the
 *  most it has where faces differ (`plainHoles`). */
export const PLAIN_HOLES: Map<number, number> = (() => {
  const table = new Map<number, number>()
  const upper: Record<string, number> = { A: 1, B: 2, D: 1, O: 1, P: 1, Q: 1, R: 1 }
  const lower: Record<string, number> = { a: 1, b: 1, d: 1, e: 1, g: 2, o: 1, p: 1, q: 1 }
  const digits: Record<string, number> = { 0: 2, 4: 1, 6: 1, 8: 2, 9: 1 }
  for (let code = 0x41; code <= 0x5a; code += 1) table.set(code, upper[String.fromCharCode(code)] ?? 0)
  for (let code = 0x61; code <= 0x7a; code += 1) table.set(code, lower[String.fromCharCode(code)] ?? 0)
  for (let code = 0x30; code <= 0x39; code += 1) table.set(code, digits[String.fromCharCode(code)] ?? 0)
  return table
})()

export interface ImageMask { width: number; height: number; painted: boolean[] }

/** A one-bit picture drawn as an unfiltered inline image mask — how pdfTeX
 *  draws each glyph of a bitmap font (`ImageMask(inlineIn:)`). */
export function imageMask(bytes: Uint8Array): ImageMask | null {
  const isSpace = (byte: number) => byte === 0 || byte === 9 || byte === 10 || byte === 12 || byte === 13 || byte === 32
  const isDelimiter = (byte: number) => isSpace(byte) || '/[]<>()'.includes(String.fromCharCode(byte))
  let begin: number | null = null
  for (let at = 0; at + 1 < bytes.length; at += 1) {
    if (bytes[at] === 0x42 && bytes[at + 1] === 0x49 && (at === 0 || isSpace(bytes[at - 1]))
      && (at + 2 >= bytes.length || isDelimiter(bytes[at + 2]))) {
      begin = at + 2
      break
    }
  }
  if (begin === null) return null
  const words: string[] = []
  let data: number | null = null
  let index = begin
  while (index < bytes.length) {
    const byte = bytes[index]
    if (isSpace(byte)) { index += 1; continue }
    // A bracket is a word of one character; anything else runs to the next
    // delimiter — "/W" and "62" are two words.
    let end = index + 1
    if (byte !== 0x5b && byte !== 0x5d) while (end < bytes.length && !isDelimiter(bytes[end])) end += 1
    const word = Buffer.from(bytes.subarray(index, end)).toString('utf8')
    if (word === 'ID') {
      // One white-space byte, and then the picture.
      data = end + 1
      break
    }
    words.push(word)
    index = end
  }
  if (data === null || words.length >= 64) return null
  const value = (...keys: string[]): string | null => {
    const at = words.findIndex((word) => keys.includes(word))
    return at >= 0 && at + 1 < words.length ? words[at + 1] : null
  }
  const whole = (text: string | null) => (text !== null && /^[+-]?\d+$/.test(text) ? Number(text) : null)
  const width = whole(value('/W', '/Width'))
  const height = whole(value('/H', '/Height'))
  const depth = value('/BPC', '/BitsPerComponent')
  if (value('/F', '/Filter') !== null || value('/IM', '/ImageMask') !== 'true' || (depth !== null && depth !== '1')
    || width === null || height === null || width <= 0 || height <= 0 || width * height > 1_000_000) return null
  // A mask paints its zeros, unless its decode array turns that round.
  let inverted = false
  const decode = words.findIndex((word) => word === '/D' || word === '/Decode')
  if (decode >= 0 && decode + 3 < words.length && words[decode + 1] === '[') {
    inverted = words[decode + 2] === '1' && words[decode + 3] === '0'
  }
  const rowBytes = Math.floor((width + 7) / 8)
  if (data + rowBytes * height > bytes.length) return null
  const painted: boolean[] = new Array(width * height).fill(false)
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const bit = (bytes[data + y * rowBytes + Math.floor(x / 8)] >> (7 - (x % 8))) & 1
      painted[y * width + x] = inverted ? bit === 1 : bit === 0
    }
  }
  return { width, height, painted }
}

/** The enclosed holes in a picture, half a percent of it or more — three
 *  pixels at the least (`ImageMask.holes`). */
export function holes(mask: ImageMask): number {
  const wide = mask.width + 2
  const high = mask.height + 2
  const open: boolean[] = new Array(wide * high).fill(true)
  for (let y = 0; y < mask.height; y += 1) {
    for (let x = 0; x < mask.width; x += 1) if (mask.painted[y * mask.width + x]) open[(y + 1) * wide + x + 1] = false
  }
  const seen: boolean[] = new Array(wide * high).fill(false)
  const fill = (start: number): number => {
    const stack = [start]
    seen[start] = true
    let size = 0
    while (stack.length > 0) {
      const cell = stack.pop()!
      size += 1
      const x = cell % wide
      const y = Math.floor(cell / wide)
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const nx = x + dx
        const ny = y + dy
        if (nx < 0 || ny < 0 || nx >= wide || ny >= high) continue
        const next = ny * wide + nx
        if (open[next] && !seen[next]) { seen[next] = true; stack.push(next) }
      }
    }
    return size
  }
  fill(0)
  const smallest = Math.max(3, Math.floor((mask.width * mask.height) / 200))
  let found = 0
  for (let cell = 0; cell < wide * high; cell += 1) {
    if (open[cell] && !seen[cell] && fill(cell) >= smallest) found += 1
  }
  return found
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

/** Swift's `Int(text, radix: 16)` and `UInt16(text, radix: 16)`: a sign may
 *  lead, every digit must be one, and the value must fit. */
function hexValue(text: string, max: number): number | null {
  const match = /^([+-]?)([0-9A-Fa-f]+)$/.exec(text)
  if (!match) return null
  const value = parseInt(match[2], 16)
  if (match[1] === '-') return value === 0 ? 0 : null
  return value <= max ? value : null
}

/**
 * A ToUnicode CMap's `bfchar` and `bfrange` sections, read the way ISO 32000
 * §9.10.3 writes them (`PDFContentScanner.toUnicodeTable`). Every value is
 * UTF-16, four hex digits a unit — so a letter outside the first plane is two
 * of them (𝒒 is D835 DC92). A range either gives the first value and counts
 * up from it, the *last unit* counting — `<04F6> <04F9> <D835DC34>` is 𝐴 to
 * 𝐷 — or gives one value per code in an array.
 */
export function toUnicodeTable(text: string): Map<number, string> {
  const table = new Map<number, string>()
  const units = (hex: string): number[] | null => {
    const out: number[] = []
    for (let index = 0; index + 4 <= hex.length; index += 4) {
      const value = hexValue(hex.slice(index, index + 4), 0xffff)
      if (value === null) return null
      out.push(value)
    }
    // Two digits is one byte: a single-byte value, which a few writers use
    // for plain ASCII.
    if (out.length === 0 && hex.length === 2) {
      const value = hexValue(hex, 0xffff)
      if (value !== null) out.push(value)
    }
    return out.length === 0 ? null : out
  }
  // `String(utf16CodeUnits:count:)`.
  const string = (value: number[]) => String.fromCharCode(...value)

  // The CMap as a list of hex strings, brackets and words. The text is one
  // byte a character (Latin-1), so a Character is a code unit — "\r\n" is
  // one, and neither half is anything a token starts with.
  type Token = { k: 'hex'; v: string } | { k: 'open' } | { k: 'close' } | { k: 'word'; v: string }
  const tokens: Token[] = []
  let index = 0
  while (index < text.length) {
    const character = text[index]
    if (character === '<') {
      const close = text.indexOf('>', index + 1)
      if (close < 0) break
      tokens.push({ k: 'hex', v: [...text.slice(index + 1, close)].filter((one) => !isWhitespace(one)).join('') })
      index = close + 1
    } else if (character === '[') {
      tokens.push({ k: 'open' })
      index += 1
    } else if (character === ']') {
      tokens.push({ k: 'close' })
      index += 1
    } else if (isLetter(character)) {
      const from = index
      while (index < text.length && isLetter(text[index])) index += 1
      tokens.push({ k: 'word', v: text.slice(from, index) })
    } else {
      index += 1
    }
  }

  let position = 0
  const hex = (): string | null => {
    const token = tokens[position]
    if (token === undefined || token.k !== 'hex') return null
    position += 1
    return token.v
  }
  while (position < tokens.length) {
    const token = tokens[position]
    if (token.k !== 'word') { position += 1; continue }
    position += 1
    if (token.v === 'beginbfchar') {
      while (position < tokens.length) {
        if (tokens[position].k === 'word') break
        const codeHex = hex()
        const valueHex = codeHex !== null ? hex() : null
        if (codeHex === null || valueHex === null) { position += 1; continue }
        const code = hexValue(codeHex, Number.MAX_SAFE_INTEGER)
        const value = units(valueHex)
        if (code !== null && value !== null) table.set(code, string(value))
      }
    } else if (token.v === 'beginbfrange') {
      while (position < tokens.length) {
        if (tokens[position].k === 'word') break
        const lowHex = hex()
        const highHex = lowHex !== null ? hex() : null
        const low = highHex !== null ? hexValue(lowHex!, Number.MAX_SAFE_INTEGER) : null
        const high = low !== null ? hexValue(highHex!, Number.MAX_SAFE_INTEGER) : null
        if (low === null || high === null || !(high >= low) || !(high - low < 65536)) { position += 1; continue }
        if (position < tokens.length && tokens[position].k === 'open') {
          position += 1
          let code = low
          while (position < tokens.length) {
            if (tokens[position].k === 'close') { position += 1; break }
            const valueHex = hex()
            if (valueHex !== null) {
              const value = code <= high ? units(valueHex) : null
              if (value !== null) table.set(code, string(value))
              code += 1
            } else {
              position += 1
            }
          }
        } else {
          const startHex = hex()
          const value = startHex !== null ? units(startHex) : null
          if (value !== null) {
            for (let code = low; code <= high; code += 1) {
              table.set(code, string(value))
              value[value.length - 1] = (value[value.length - 1] + 1) & 0xffff
            }
          }
        }
      }
    }
  }
  return table
}
