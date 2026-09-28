/**
 * Reads a passage out of a PDF with its mathematics intact — the Mac's
 * `MathReader`, port for port: what the page draws (which glyph, from which
 * font, at which point, and the thin rectangles filled), put back together
 * the way a person reading the page would write it down. `latex` is the
 * clipboard's one line (Ultracopy); `structured` is the page's shape kept,
 * for a quotation in a note (⌘L).
 *
 * What the Mac asks PDFKit — the selection's line boxes and the page's
 * characters — comes in as `PageInput`, so the Mac's own answers on the same
 * inputs can be checked here (`src/test/mathReader.ts`); in the window the
 * text layer supplies them.
 */
import {
  ZERO_RECT, insetBy, intersection, intersects, isEmpty, isNull, maxX, maxY, midX, midY, minX, minY, union, type Rect,
} from './geometry.js'
import { isExtension, rectOf, type Glyph, type Rule } from './glyph.js'
import * as TeX from './texGlyphNames.js'
import { hasWordSubscript, isMathFont, isOperatorName, isSpace, joiningText, latexOf, setFallback, spelling as spell, type Context } from './transcriber.js'
import { trimWhitespace, trimWhitespaceAndNewlines } from '../zettel.js'

/** One character as the page's text has it, where it sits. `index` is into `pageText`. */
export interface PageCharacter { index: number; rect: Rect; character: string }

export interface PageInput {
  glyphs: Glyph[]
  rules: Rule[]
  /** The selection's lines on this page, in page coordinates, a point wider either side (`lineBoxes`). */
  lineBoxes: Rect[]
  characters: PageCharacter[]
  pageText: string
  /** What the selection says as plain text — for a page with nothing to scan. */
  selectionString: string
  cropBox: Rect
}

export type PieceKind = 'prose' | 'display' | 'inline' | { heading: number }

export interface Piece {
  kind: PieceKind
  plain: string
  marked: string
  left: number
  right: number
  baseline: number
  page: number
  scale: number
}

const isLetterChar = (c: string | undefined) => c !== undefined && /^\p{L}/u.test(c)
const isNumberChar = (c: string | undefined) => c !== undefined && /^\p{N}/u.test(c)
const WHITE = /^[\t-\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]$/u
const isWhitespaceChar = (c: string) => WHITE.test([...c][0] ?? '')
const count = (s: string) => [...s].length
const firstOf = (s: string) => [...s][0]
const lastOf = (s: string) => { const a = [...s]; return a[a.length - 1] }
const isHeading = (kind: PieceKind): kind is { heading: number } => typeof kind === 'object'

function trimSet(text: string, set: string): string {
  const chars = [...text]
  let from = 0
  let to = chars.length
  while (from < to && set.includes(chars[from])) from += 1
  while (to > from && set.includes(chars[to - 1])) to -= 1
  return chars.slice(from, to).join('')
}

function extent(glyphs: Glyph[]): Rect {
  if (glyphs.length === 0) return ZERO_RECT
  return glyphs.slice(1).reduce((box, g) => union(box, rectOf(g)), rectOf(glyphs[0]))
}

/** The passage, with each run of mathematics wrapped in `$…$` — one line. */
export function latex(pages: PageInput[]): string {
  const read = pieces(pages)
  if (read.length === 0) return pages.map((page) => page.selectionString).join('')
  return join(read.map((piece) => piece.plain))
}

// MARK: - Pieces

interface Block { rows: Glyph[][]; isFormula: boolean }

/** How many formulas the last reading left out because the file does not
 *  say what their glyphs are (the Mac's `skippedFormulas`). */
let skippedFormulas = 0
export function leftOutFormulas(): number { return skippedFormulas }

export function pieces(pages: PageInput[]): Piece[] {
  skippedFormulas = 0
  const out: Piece[] = []
  pages.forEach((page, number) => {
    setFallback(characterLookup(page.characters))
    try {
      if (page.glyphs.length === 0) {
        if (page.selectionString) out.push({ kind: 'prose', plain: page.selectionString, marked: page.selectionString, left: 0, right: 0, baseline: 0, page: 0, scale: 1 })
        return
      }
      const layout = layoutOf(page.glyphs)
      const boxes = page.lineBoxes
      const rules = page.rules
      const pageBody = sizeOf(page.glyphs)
      const extents = layout.flatMap((block) => {
        const row = block.rows[0]
        if (!row || row.length === 0) return []
        return [extent(row).width]
      })
      const columnWidth = extents.length > 0 ? Math.max(...extents) : page.cropBox.width
      const selected = (glyph: Glyph) => boxes.some((box) => belongs(glyph, box))

      const reached: { block: Block; glyphs: Glyph[] }[] = []
      for (const block of layout) {
        if (block.isFormula) {
          const all = block.rows.flat()
          if (all.some(selected)) reached.push({ block, glyphs: all })
        } else {
          const kept = block.rows[0].filter(selected)
          if (kept.length > 0) reached.push({ block, glyphs: kept })
        }
      }
      const wantsFormula = reached.some((one) => one.block.isFormula)

      for (const { block, glyphs } of reached) {
        if (!block.isFormula) {
          const whole = block.rows[0].length
          if (wantsFormula && glyphs.length * 10 < whole * 9) continue
          const band = extent(glyphs)
          const nearby = rules.filter((rule) => intersects(insetBy(band, -2, -2), rule.rect))
          const text = read(glyphs, nearby, page.characters, page.pageText)
          if (text === '') continue
          const marked = readMarkingBold(glyphs, nearby, page.characters, page.pageText)
          const scale = sizeOf(glyphs) / Math.max(pageBody, 1)
          out.push({
            kind: heading(scale, glyphs, text, band.width < columnWidth * 0.55),
            plain: text, marked,
            left: minX(band), right: maxX(band),
            baseline: glyphs[0].y, page: number, scale,
          })
          continue
        }
        let all = glyphs
        let tag: string | null = null
        const split = numbered(all, sizeOf(all))
        if (split) {
          all = split.formula
          if (split.number.every(selected)) {
            const inner = trimSet(latexOf(split.number, []), '() ')
            if (inner !== '') tag = `\\tag{${inner}}`
          }
        }
        if (all.length === 0) continue
        // Mostly glyphs nothing can read — a Word equation with no cmap and a
        // ToUnicode of zeros — is left out, not written as empty braces.
        const unread = all.filter((g) => spell(g) === '').length
        if (unread * 4 > all.length) {
          skippedFormulas += 1
          continue
        }
        const bounds = extent(all)
        let body = latexOf([...all].sort((a, b) => a.x - b.x), rules.filter((rule) => intersects(insetBy(bounds, -2, -2), rule.rect)))
        if (tag !== null) body += tag
        if (body === '') continue
        const displayed = all.length > 3
        const wrapped = displayed ? `$$${body}$$` : `$${body}$`
        out.push({
          kind: displayed ? 'display' : 'inline',
          plain: wrapped, marked: wrapped,
          left: minX(bounds), right: maxX(bounds),
          baseline: all[0].y, page: number, scale: 1,
        })
      }
    } finally {
      setFallback(null)
    }
  })
  return out
}

function displayedEquation(line: string): string | null {
  const text = trimWhitespace(line)
  if (!text.includes('$')) return null
  const maths: string[] = []
  let rest = ''
  let index = 0
  for (;;) {
    const open = text.indexOf('$', index)
    if (open < 0) break
    rest += text.slice(index, open)
    const close = text.indexOf('$', open + 1)
    if (close < 0) {
      rest += text.slice(open)
      index = text.length
      break
    }
    maths.push(text.slice(open + 1, close))
    index = close + 1
  }
  rest += text.slice(index)
  if (maths.length === 0) return null
  let tag: string | null = null
  let leftovers = trimWhitespace(rest)
  const match = /\(([0-9]+[a-z]?)\)/.exec(leftovers)
  if (match) {
    tag = trimSet(match[0], '()')
    leftovers = leftovers.slice(0, match.index) + leftovers.slice(match.index + match[0].length)
  }
  const remainder = trimSet(leftovers, ' ,.;:\t')
  if (remainder !== '') return null
  let body = upright(maths.join(' '))
  if (tag !== null) body += `\\tag{${tag}}`
  return `$$${body}$$`
}

function upright(latexText: string): string {
  let out = ''
  let letters = ''
  const chars = [...latexText]
  let index = 0
  const flush = () => {
    if (letters === '') return
    out += count(letters) >= 3 ? `\\text{${letters}}` : letters
    letters = ''
  }
  while (index < chars.length) {
    const character = chars[index]
    if (character === '\\') {
      flush()
      out += character
      index += 1
      while (index < chars.length && isLetterChar(chars[index])) {
        out += chars[index]
        index += 1
      }
      continue
    }
    if (isLetterChar(character) && character.charCodeAt(0) < 128) letters += character
    else {
      flush()
      out += character
    }
    index += 1
  }
  flush()
  return joiningText(out)
}

function wordsOutsideFormulas(text: string): number {
  let outside = ''
  let inMath = false
  for (const character of text) {
    if (character === '$') { inMath = !inMath; outside += ' '; continue }
    if (!inMath) outside += character
  }
  return outside.split(/[^\p{L}]/u).filter((word) => count(word) >= 2).length
}

function heading(scale: number, glyphs: Glyph[], text: string, short: boolean): PieceKind {
  const trimmed = trimWhitespace(text)
  if (trimmed.endsWith('.') || trimmed.endsWith(',') || !(count(trimmed) < 90)) return 'prose'
  if (trimmed.includes('$') && wordsOutsideFormulas(trimmed) < 2) return 'prose'
  const bold = glyphs.length > 0 && glyphs.every(isBold)
  if (scale >= 1.12) return { heading: scale >= 1.45 ? 2 : scale >= 1.22 ? 3 : 4 }
  if (bold && short && scale >= 1.0) return { heading: 4 }
  return 'prose'
}

function readMarkingBold(row: Glyph[], rules: Rule[], characters: PageCharacter[], text: string): string {
  const runs: { bold: boolean; glyphs: Glyph[] }[] = []
  for (const glyph of [...row].sort((a, b) => a.x - b.x)) {
    const bold = isBold(glyph)
    const lastRun = runs[runs.length - 1]
    if (lastRun && lastRun.bold === bold) lastRun.glyphs.push(glyph)
    else runs.push({ bold, glyphs: [glyph] })
  }
  if (!(runs.some((run) => run.bold) && runs.length > 1)) return read(row, rules, characters, text)
  let out = ''
  for (const run of runs) {
    const piece = trimWhitespace(read(run.glyphs, rules, characters, text))
    if (piece === '') continue
    if (out !== '') out += ' '
    out += run.bold ? `**${piece}**` : piece
  }
  return out
}

export function isBold(glyph: Glyph): boolean {
  const name = glyph.fontName.toUpperCase()
  return name.includes('BOLD') || name.includes('BX') || name.includes('-BD')
    || name.includes('MEDI') || name.includes('SEMIB') || name.includes('HEAVY')
    || name.includes('BLACK') || name.endsWith('-B')
}

/** The passage as Markdown with the page's shape kept; an empty string is a paragraph break. */
export function structured(pages: PageInput[]): string[] {
  const read = pieces(pages)
  if (read.length === 0) {
    const plain = trimWhitespaceAndNewlines(pages.map((page) => page.selectionString).join(''))
    return plain === '' ? [] : [plain]
  }
  const rows = read.filter((piece) => piece.kind !== 'inline')
  const left = rows.length > 0 ? Math.min(...rows.map((piece) => piece.left)) : 0
  const right = rows.length > 0 ? Math.max(...rows.map((piece) => piece.right)) : 0
  const column = Math.max(right - left, 1)
  const gaps: number[] = []
  for (let i = 0; i + 1 < rows.length; i += 1) {
    const above = rows[i]
    const below = rows[i + 1]
    if (above.page !== below.page) continue
    const gap = above.baseline - below.baseline
    if (gap > 1 && gap < 80) gaps.push(gap)
  }
  gaps.sort((a, b) => a - b)
  const leading = gaps.length === 0 ? 0 : gaps[Math.floor(gaps.length / 2)]

  const lines: string[] = []
  let paragraph = ''
  let previous: Piece | null = null
  const close = () => {
    const trimmed = trimWhitespace(paragraph)
    if (trimmed !== '') lines.push(trimmed)
    paragraph = ''
  }
  const breakHere = () => {
    close()
    if (lines[lines.length - 1] !== '' && lines.length > 0) lines.push('')
  }
  for (const piece of read) {
    if (isHeading(piece.kind)) {
      breakHere()
      lines.push('#'.repeat(piece.kind.heading) + ' ' + piece.marked)
      lines.push('')
      previous = null
      continue
    }
    if (piece.kind === 'display') {
      breakHere()
      lines.push(piece.marked)
      lines.push('')
      previous = null
      continue
    }
    if (piece.kind === 'inline') {
      paragraph += paragraph === '' ? piece.marked : ' ' + piece.marked
      continue
    }
    const equation = displayedEquation(piece.marked)
    if (equation !== null) {
      breakHere()
      lines.push(equation)
      lines.push('')
      previous = null
      continue
    }
    if (previous && previous.kind === 'prose') {
      const endedShort = previous.right < right - column * 0.12
      const spaced = leading > 0 && previous.page === piece.page && previous.baseline - piece.baseline > leading * 1.5
      if (endedShort || spaced) breakHere()
    }
    if (paragraph === '') paragraph = piece.marked
    else if (paragraph.endsWith('-')) paragraph = paragraph.slice(0, -1) + piece.marked
    else paragraph += ' ' + piece.marked
    previous = piece
  }
  close()
  while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
}

function characterLookup(characters: PageCharacter[]): (glyph: Glyph) => string | null {
  const boxes = characters.filter((c) => !isWhitespaceChar(c.character))
  return (glyph) => {
    const g = rectOf(glyph)
    let best: { character: string; area: number } | null = null
    for (const box of boxes) {
      const overlap = intersection(box.rect, g)
      if (isNull(overlap)) continue
      const area = overlap.width * overlap.height
      if (!(area > g.width * g.height * 0.3)) continue
      if (best === null || area > best.area) best = { character: box.character, area }
    }
    if (best === null) return null
    if (isMathFont(glyph) && (isLetterChar(best.character) || isNumberChar(best.character))) return null
    return best.character
  }
}

function belongs(glyph: Glyph, box: Rect): boolean {
  const slack = glyph.size * 0.15
  const r = rectOf(glyph)
  return glyph.y > minY(box) - slack && glyph.y < maxY(box) + slack && maxX(r) > minX(box) && minX(r) < maxX(box)
}

function numbered(glyphs: Glyph[], body: number): { formula: Glyph[]; number: Glyph[] } | null {
  const sorted = [...glyphs].sort((a, b) => minX(rectOf(a)) - minX(rectOf(b)))
  if (!(sorted.length > 5)) return null
  let cut: number | null = null
  for (let index = sorted.length - 1; index > Math.max(sorted.length - 9, 1); index -= 1) {
    if (minX(rectOf(sorted[index])) - maxX(rectOf(sorted[index - 1])) > body * 1.5) {
      cut = index
      break
    }
  }
  if (cut === null) return null
  const number = sorted.slice(cut)
  if (!(spell(number[0]) === '(' && spell(number[number.length - 1]) === ')' && number.length >= 3)) return null
  return { formula: sorted.slice(0, cut), number }
}

function blocks(rows: Glyph[][], body: number): Glyph[][][] {
  const out: Glyph[][][] = []
  let lastBaseline: number | null = null
  let lastWasProse = true
  for (const row of rows) {
    const baseline = context(row).baseline
    const prose = containsProse(row)
    const close = lastBaseline !== null ? lastBaseline - baseline < body : false
    if (!prose && !lastWasProse && close && out.length > 0) out[out.length - 1].push(row)
    else out.push([row])
    lastBaseline = baseline
    lastWasProse = prose
  }
  return out
}

function sizeOf(glyphs: Glyph[]): number {
  const sizes = glyphs.map((g) => g.size).sort((a, b) => a - b)
  return sizes.length === 0 ? 10 : sizes[Math.floor(sizes.length * 0.75)]
}

function isDisplayRow(row: Glyph[]): boolean {
  if (row.length === 0) return false
  if (containsProse(row)) return false
  const body = context(row).bodySize
  const deciding = row.filter((glyph) => {
    if (!(glyph.size >= body * 0.92)) return false
    const t = spell(glyph)
    return count(t) > 1 || isLetterChar(firstOf(t))
  })
  if (deciding.length === 0) return false
  const mathish = deciding.filter(isMathFont).length
  if (deciding.length <= 4) return mathish > 0
  if (row.some((glyph) => TeX.isBigOperator(glyph.glyphName))) return mathish >= deciding.length * 0.25
  return mathish >= deciding.length * 0.4
}

function containsProse(row: Glyph[]): boolean {
  const body = context(row).bodySize
  return words(row, body).some((word) => {
    const full = word.filter((g) => g.size >= body * 0.92)
    if (!(full.length >= 2 && !full.some(isMathFont))) return false
    const spelled = full.map(spell)
    if (!(spelled.filter((s) => isLetterChar(firstOf(s))).length >= 2)) return false
    return !isOperatorName(spelled.join(''))
  })
}

function rows(glyphs: Glyph[]): Glyph[][] {
  if (glyphs.length === 0) return []
  const sizes = glyphs.map((g) => g.size).sort((a, b) => a - b)
  const body = sizes[Math.floor(sizes.length * 0.75)]
  const laidRows: { baseline: number; glyphs: Glyph[] }[] = []
  for (const glyph of glyphs.filter((g) => g.size >= body * 0.9 && !isExtension(g)).sort((a, b) => b.y - a.y)) {
    const at = laidRows.findIndex((row) => Math.abs(row.baseline - glyph.y) < body * 0.6)
    if (at >= 0) laidRows[at].glyphs.push(glyph)
    else laidRows.push({ baseline: glyph.y, glyphs: [glyph] })
  }
  for (const glyph of glyphs.filter((g) => g.size < body * 0.9 && !isExtension(g))) {
    let nearest: number | null = null
    for (let i = 0; i < laidRows.length; i += 1) {
      if (nearest === null || Math.abs(laidRows[i].baseline - glyph.y) < Math.abs(laidRows[nearest].baseline - glyph.y)) nearest = i
    }
    if (nearest !== null && Math.abs(laidRows[nearest].baseline - glyph.y) < body * 0.85) laidRows[nearest].glyphs.push(glyph)
    else laidRows.push({ baseline: glyph.y, glyphs: [glyph] })
  }
  for (const glyph of glyphs.filter(isExtension)) {
    const ink = rectOf(glyph)
    const through = laidRows.map((_, i) => i).filter((i) => laidRows[i].baseline > minY(ink) - 1 && laidRows[i].baseline < maxY(ink) + 1)
    const candidates = through.length === 0 ? laidRows.map((_, i) => i) : through
    let nearest: number | null = null
    for (const i of candidates) {
      if (nearest === null || Math.abs(laidRows[i].baseline - midY(ink)) < Math.abs(laidRows[nearest].baseline - midY(ink))) nearest = i
    }
    if (nearest !== null) laidRows[nearest].glyphs.push(glyph)
    else laidRows.push({ baseline: midY(ink), glyphs: [glyph] })
  }
  const laid = folded([...laidRows].sort((a, b) => b.baseline - a.baseline), body)
    .map((row) => [...row.glyphs].sort((a, b) => a.x - b.x))
  return splitAtGutters(laid, glyphs)
}

function splitAtGutters(laid: Glyph[][], glyphs: Glyph[]): Glyph[][] {
  const found = gutters(laid, glyphs)
  if (found.length === 0) return laid
  const result: Glyph[][] = []
  for (const row of laid) {
    const parts: Glyph[][] = []
    let rest = row
    for (const gutter of found) {
      if (rest.some((g) => minX(rectOf(g)) < gutter && maxX(rectOf(g)) > gutter)) continue
      const before = rest.filter((g) => maxX(rectOf(g)) <= gutter)
      const after = rest.filter((g) => minX(rectOf(g)) >= gutter)
      if (before.length === 0 || after.length === 0) continue
      parts.push(before)
      rest = after
    }
    parts.push(rest)
    result.push(...parts.filter((part) => part.length > 0))
  }
  return result
}

function gutters(laid: Glyph[][], glyphs: Glyph[]): number[] {
  if (!(laid.length >= 10 && glyphs.length > 0)) return []
  const left = Math.min(...glyphs.map((g) => minX(rectOf(g))))
  const right = Math.max(...glyphs.map((g) => maxX(rectOf(g))))
  if (!(right - left > 200)) return []
  const from = left + (right - left) * 0.15
  const to = right - (right - left) * 0.15
  const step = 2
  const samples: { x: number; crossings: number }[] = []
  let x = from
  while (x <= to) {
    const at = x
    samples.push({ x: at, crossings: laid.reduce((n, row) => n + (row.some((g) => minX(rectOf(g)) < at && maxX(rectOf(g)) > at) ? 1 : 0), 0) })
    x += step
  }
  if (!(samples.length > 8)) return []
  const ordered = samples.map((s) => s.crossings).sort((a, b) => a - b)
  const median = ordered[Math.floor(ordered.length / 2)]
  if (!(median >= 5)) return []
  const quiet = Math.max(1, Math.floor(median / 5))
  const out: number[] = []
  let runStart: number | null = null
  let runEnd: number | null = null
  for (const sample of samples) {
    if (sample.crossings <= quiet) {
      if (runStart === null) runStart = sample.x
      runEnd = sample.x
      continue
    }
    if (runStart !== null && runEnd !== null && runEnd - runStart >= 8) out.push((runStart + runEnd) / 2)
    runStart = null
    runEnd = null
  }
  if (runStart !== null && runEnd !== null && runEnd - runStart >= 8) out.push((runStart + runEnd) / 2)
  return out
}

function folded(input: { baseline: number; glyphs: Glyph[] }[], body: number): { baseline: number; glyphs: Glyph[] }[] {
  if (input.length <= 1) return input
  const laid = input.map((row) => ({ baseline: row.baseline, glyphs: [...row.glyphs] }))
  let index = 0
  while (index < laid.length) {
    const row = laid[index]
    const span = extent(row.glyphs)
    const neighbours = [index - 1, index + 1].filter((i) => i >= 0 && i < laid.length)
    let host: number | null = null
    for (const other of neighbours) {
      const theirs = extent(laid[other].glyphs)
      const fits = span.width < theirs.width * 0.75
        && Math.abs(laid[other].baseline - row.baseline) < body * 0.9
        && !collides(row.glyphs, onOwnLine(laid[other], body))
      if (!fits) continue
      if (host === null || Math.abs(laid[other].baseline - row.baseline) < Math.abs(laid[host].baseline - row.baseline)) host = other
    }
    if (host === null) {
      index += 1
      continue
    }
    laid[host].glyphs.push(...row.glyphs)
    laid.splice(index, 1)
    index = Math.min(host, index)
  }
  return laid
}

function onOwnLine(row: { baseline: number; glyphs: Glyph[] }, body: number): Glyph[] {
  return row.glyphs.filter((g) => Math.abs(g.y - row.baseline) < body * 0.25)
}

function collides(one: Glyph[], other: Glyph[]): boolean {
  if (one.length === 0 || other.length === 0) return false
  const theirs = other.map((g) => [minX(rectOf(g)), maxX(rectOf(g))] as const).sort((a, b) => a[0] - b[0])
  let hits = 0
  for (const glyph of one) {
    const r = rectOf(glyph)
    const slack = Math.min(r.width, 2) * 0.5
    const low = minX(r) + slack
    const high = maxX(r) - slack
    if (!(low < high)) continue
    let start = theirs.length
    let lo = 0
    let hi = theirs.length
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2)
      if (theirs[mid][1] > low) {
        start = mid
        hi = mid
      } else lo = mid + 1
    }
    if (start < theirs.length && theirs[start][0] < high) hits += 1
  }
  return hits > one.length * 0.2
}

function read(row: Glyph[], rules: Rule[], characters: PageCharacter[], text: string): string {
  const ctx = context(row)
  const band = extent(row)
  const near = characters.filter((c) => maxY(c.rect) > minY(band) && minY(c.rect) < maxY(band))
  const parts: { isMath: boolean; text: string }[] = []
  for (const word of words(row, ctx.bodySize)) {
    if (word.some(isMathFont) || hasWordSubscript(word, ctx.bodySize)) {
      const unread = word.filter((g) => spell(g) === '').length
      if (unread * 4 > word.length) {
        skippedFormulas += 1
        continue
      }
      const l = latexOf(word, rules, ctx)
      if (l !== '') parts.push({ isMath: true, text: l })
      continue
    }
    const spelled = word.map(spell)
    const found = spelled.some((s) => s === '') ? spellingFrom(word, near, text) : null
    const borrowed = found !== null && agrees(found, spelled) ? found : null
    if (borrowed !== null) parts.push({ isMath: false, text: borrowed })
    else parts.push({ isMath: false, text: composed(spelled.join('')) })
  }
  return assemble(merged(parts))
}

function context(row: Glyph[]): Context {
  const ordinary = row.filter((g) => !isExtension(g))
  const body = ordinary.length > 0 ? Math.max(...ordinary.map((g) => g.size)) : row.length > 0 ? Math.max(...row.map((g) => g.size)) : 10
  const full = ordinary.filter((g) => g.size >= body * 0.92)
  const sample = (full.length === 0 ? row : full).map((g) => g.y).sort((a, b) => a - b)
  return { bodySize: body, baseline: sample[Math.floor(sample.length / 2)] }
}

const JOINERS = new Set(['=', '+', '-', '<', '>', '\\leq', '\\geq', '\\neq', '\\approx', '\\sim', '\\equiv', '\\to', '\\in', '\\cdot', '\\times', '\\pm'])

function merged(parts: { isMath: boolean; text: string }[]): { isMath: boolean; text: string }[] {
  const result: { isMath: boolean; text: string }[] = []
  for (const part of parts) {
    if (part.isMath && result.length >= 2 && JOINERS.has(result[result.length - 1].text) && result[result.length - 2].isMath) {
      const joiner = result.pop()!.text
      const before = result.pop()!.text
      result.push({ isMath: true, text: `${before} ${joiner} ${part.text}` })
    } else if (part.isMath && result.length > 0 && result[result.length - 1].isMath) {
      const previous = result.pop()!
      result.push({ isMath: true, text: previous.text + spacer(previous.text, part.text) + part.text })
    } else {
      result.push(part)
    }
  }
  return result
}

function spacer(before: string, after: string): string {
  const l = lastOf(before)
  if (l !== undefined && '([{_^'.includes(l)) return ''
  const n = firstOf(after)
  if (n !== undefined && ',;:.)]}!?'.includes(n)) return ''
  return ' '
}

function assemble(parts: { isMath: boolean; text: string }[]): string {
  return parts.map((part) => (part.isMath ? `$${part.text}$` : part.text)).join(' ')
}

const MARKS: Record<string, string> = {
  '\u00A8': '\u0308', '\u02C6': '\u0302', '\u02DC': '\u0303',
  '\u00AF': '\u0304', '\u02D9': '\u0307', '\u02C7': '\u030C',
  '\u00B4': '\u0301', '\u02DA': '\u030A', '\u02DD': '\u030B',
  '\u00B8': '\u0327', '\u02D8': '\u0306',
}

function composed(text: string): string {
  if (![...text].some((c) => MARKS[c] !== undefined)) return text
  let result = ''
  let pending: string | null = null
  for (const character of text) {
    if (MARKS[character] !== undefined) {
      pending = MARKS[character]
      continue
    }
    const letter = pending === null ? character : character === '\u0131' ? 'i' : character === '\u0237' ? 'j' : character
    result += letter
    if (pending !== null) {
      result += pending
      pending = null
    }
  }
  if (pending !== null) result += pending
  return result.normalize('NFC')
}

function words(row: Glyph[], body: number): Glyph[][] {
  const out: Glyph[][] = []
  // Word draws its spaces as glyphs, so nothing between two words is a gap.
  let spaced = false
  for (const glyph of row) {
    if (isSpace(glyph)) {
      spaced = true
      continue
    }
    const lastWord = out[out.length - 1]
    const lastGlyph = lastWord?.[lastWord.length - 1]
    if (lastGlyph && !spaced && !isGap(lastGlyph, glyph, body)) lastWord.push(glyph)
    else out.push([glyph])
    spaced = false
  }
  return out
}

/** Whether a word borrowed from PDFKit's text spells the letters the glyphs
 *  could read, in order — the text and its boxes do not always agree. */
function agrees(borrowed: string, spelled: string[]): boolean {
  const keep = (text: string) => [...text].filter((c) => /[\p{L}\p{N}]/u.test(c))
  const known = keep(spelled.join(''))
  if (known.length === 0) return true
  const remaining = keep(borrowed)
  let at = 0
  for (const character of known) {
    const found = remaining.indexOf(character, at)
    if (found < 0) return false
    at = found + 1
  }
  return true
}

function spellingFrom(word: Glyph[], characters: PageCharacter[], text: string): string | null {
  const span = extent(word)
  const covered = characters.filter((c) => {
    const overlap = intersection(c.rect, span)
    if (isNull(overlap)) return false
    return overlap.width * overlap.height > c.rect.width * c.rect.height * 0.5
  })
  if (covered.length === 0) return null
  const from = Math.min(...covered.map((c) => c.index))
  const to = Math.max(...covered.map((c) => c.index))
  if (!(to >= from && to < text.length && to - from < 64)) return null
  // The page's text is cut by character, the way the Mac cuts it (`NSString`
  // by the index of a `Character`), and half a surrogate pair becomes U+FFFD
  // as it does when Swift makes the piece a `String`.
  const spelled = trimWhitespaceAndNewlines(wellFormed(text.slice(from, to + 1)))
  return spelled === '' ? null : spelled
}

function wellFormed(text: string): string {
  return text.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '\uFFFD')
}

function isGap(a: Glyph, b: Glyph, body: number): boolean {
  const width = minX(rectOf(b)) - maxX(rectOf(a))
  if (!(width > 0)) return false
  const formula = Math.min(a.size, b.size) < body * 0.92 || isMathFont(a) || isMathFont(b)
  return width > body * (formula ? 0.22 : 0.09)
}

// MARK: - Pages

const layouts = new WeakMap<Glyph[], Block[]>()

function layoutOf(glyphs: Glyph[]): Block[] {
  const known = layouts.get(glyphs)
  if (known) return known
  const grouped = blocks(rows(glyphs), sizeOf(glyphs))
  const laid = grouped.map((group) => ({ rows: group, isFormula: group.length > 1 || isDisplayRow(group[0]) }))
  layouts.set(glyphs, laid)
  return laid
}

export function join(lines: string[]): string {
  let result = ''
  lines.forEach((line, index) => {
    const trimmed = trimWhitespace(line)
    if (index === 0) result = trimmed
    else if (result.endsWith('-')) result = result.slice(0, -1) + trimmed
    else result += ' ' + trimmed
  })
  return result
}

export { isEmpty, midX }
