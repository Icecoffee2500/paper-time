/**
 * Reads a passage out of a PDF with its mathematics intact — the Mac's
 * `MathReader`, port for port: what the page draws (which glyph, from which
 * font, at which point, and the thin rectangles filled), put back together
 * the way a person reading the page would write it down. `latex` is the
 * clipboard's one line (Ultracopy); `structured` is the page's shape kept,
 * for a quotation in a note (⌘L).
 *
 * What the Mac asks PDFKit — the selection's line boxes and the page's
 * characters — comes in as `PageInput`, and so does what the paper's other
 * first pages say about where it keeps its variables (the Mac scans them;
 * here the main process does), so the Mac's own answers on the same inputs
 * can be checked here (`src/test/mathReader.ts`); in the window the text
 * layer supplies the rest.
 */
import {
  ZERO_RECT, containsPoint, insetBy, intersection, intersects, isNull, maxX, maxY, midX, midY, minX, minY, offsetBy, union, type Rect,
} from './geometry.js'
import { extension, rectOf, type Glyph, type Rule } from './glyph.js'
import * as TeX from './texGlyphNames.js'
import {
  barToken, closing, family, hasWordSubscript, isAccent, isBigOperator, isDelimiter, isItalicLetter, isMathFont, isOperatorName,
  isRadical, isSpace, isTallVariant, isUnreadable, isUprightLetter, italicVariables, joiningText, latexOf, maxBy, minBy,
  isPiece, opening, ordinarySize, setFallback, setVariablesInTextItalic, sortedBy, spelling as spell, stack, type Context, isBraceFill } from './transcriber.js'
import { canon, chars, count, firstChar, isLetter, isNumber, isWhitespace, lastChar, trimSet } from './swiftText.js'
import { trimWhitespace, trimWhitespaceAndNewlines } from '../zettel.js'

/** One character as the page's text has it, where it sits. `index` is into `pageText`. */
export interface PageCharacter { index: number; rect: Rect; character: string }

/** What one page of a paper says about where the paper keeps its variables
 *  (`italicEvidence`). */
export interface ItalicEvidence { ownLetters: boolean; evidence: boolean }

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
  /** The paper's first ten pages but this one, asked where the paper keeps
   *  its variables, the answers or-ed together — or nothing when the page is
   *  not in a paper, which then answers for itself. */
  italicElsewhere?: ItalicEvidence | null
}

export type PieceKind = 'prose' | 'display' | 'inline' | { heading: number }

export interface Piece {
  kind: PieceKind
  /** Whether the row was a table's (`isTableRow`): its cells of measurements
   *  are not a displayed equation, however much of the line is mathematics. */
  isTable?: boolean
  plain: string
  marked: string
  left: number
  right: number
  baseline: number
  page: number
  scale: number
}

const isHeading = (kind: PieceKind): kind is { heading: number } => typeof kind === 'object'
const maxOf = (values: number[]) => (values.length === 0 ? undefined : values.reduce((a, b) => (a < b ? b : a)))
const minOf = (values: number[]) => (values.length === 0 ? undefined : values.reduce((a, b) => (b < a ? b : a)))
const ascending = (values: number[]) => sortedBy(values, (a, b) => a < b)
const indices = (n: number) => Array.from({ length: n }, (_, i) => i)

function extent(glyphs: Glyph[]): Rect {
  if (glyphs.length === 0) return ZERO_RECT
  return glyphs.slice(1).reduce((box, one) => union(box, rectOf(one)), rectOf(glyphs[0]))
}

/**
 * The passage, with each run of mathematics wrapped in `$…$`, laid out as the
 * page is: a displayed formula on a line of its own — its rows one a line
 * when it has several — the sentence going on on the next line, and a new
 * paragraph after a blank one (the Mac's `latex(from:)`).
 */
export function latex(pages: PageInput[]): string {
  const read = pieces(pages)
  if (read.length === 0) return pages.map((page) => page.selectionString).join('')
  return lines(read, false).join('\n')
}

// MARK: - Pieces

interface Block { rows: Glyph[][]; isFormula: boolean }
interface Layout { blocks: Block[]; variablesInTextItalic: boolean }
type Reached = { block: Block; glyphs: Glyph[] }

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
      // The page, laid out: every row it was set on, gathered into the
      // things they belong to.
      const layout = layoutOf(page)
      setVariablesInTextItalic(layout.variablesInTextItalic)
      try {
        readPage(page, number, layout, out)
      } finally {
        setVariablesInTextItalic(false)
      }
    } finally {
      setFallback(null)
    }
  })
  return out
}

function readPage(page: PageInput, number: number, layout: Layout, out: Piece[]) {
  const boxes = page.lineBoxes
  const rules = markingBraceFills(page.rules, page.glyphs)
  const pageBody = sizeOf(page.glyphs)
  // How wide the page sets its text, so "this line stops short" has
  // something to be short of.
  const extents = layout.blocks.flatMap((block) => {
    const row = block.rows[0]
    if (!row || row.length === 0) return []
    return [extent(row).width]
  })
  const columnWidth = maxOf(extents) ?? page.cropBox.width
  const selected = (glyph: Glyph) => boxes.some((box) => belongs(glyph, box))

  // What the selection reaches. A formula is two-dimensional, so touching
  // one means taking all of it.
  const reachedBlocks = reached(layout, boxes)
  // When a formula is what was asked for, a line the range only clipped was not.
  const wantsFormula = reachedBlocks.some((one) => one.block.isFormula)

  let position = 0
  while (position < reachedBlocks.length) {
    const { block, glyphs } = reachedBlocks[position]
    position += 1
    // Displayed formulas one under another that line up at a relation are
    // the lines of one aligned formula.
    if (block.isFormula) {
      // …lines that break into cells at the same places are a matrix; lines
      // that only start, or are centred, at the same place are an aligned or
      // a gathered formula.
      const aligned = alignedRun(position - 1, reachedBlocks, selected, rules) ?? matrixRun(position - 1, reachedBlocks, rules)
        ?? alignedRun(position - 1, reachedBlocks, selected, rules, false)
      if (aligned !== null) {
        position = aligned.end
        const wrapped = displayed(aligned.latex)
        out.push({
          kind: 'display', plain: wrapped, marked: wrapped,
          left: minX(aligned.bounds), right: maxX(aligned.bounds),
          baseline: aligned.baseline, page: number, scale: 1,
        })
        continue
      }
    }
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
        isTable: isTableRow(block.rows[0]),
        plain: text, marked,
        left: minX(band), right: maxX(band),
        baseline: glyphs[0].y, page: number, scale,
      })
      continue
    }

    // The number a journal prints beside a displayed equation comes along
    // because the whole formula does; LaTeX writes it as \tag, or it is left
    // behind when it was not selected.
    let all = glyphs
    let tag: string | null = null
    const split = numbered(all, sizeOf(all))
    if (split !== null) {
      all = split.formula
      if (split.number.every(selected)) {
        const inner = trimSet(latexOf(split.number, []), '() ')
        if (inner !== '') tag = `\\tag{${inner}}`
      }
    }
    if (all.length === 0) continue
    // Mostly glyphs nothing can read — a Word equation with no cmap and a
    // ToUnicode of zeros — is left out, not written as empty braces.
    const unread = all.filter(isUnreadable).length
    if (unread * 4 > all.length) {
      skippedFormulas += 1
      continue
    }
    const bounds = extent(all)
    let body = latexOf(sortedBy(all, (a, b) => a.x < b.x), rules.filter((rule) => intersects(insetBy(bounds, -2, -2), rule.rect)))
    if (tag !== null) body += tag
    if (body === '') continue
    const standsAlone = all.length > 3
    const wrapped = standsAlone ? displayed(body) : `$${body}$`
    out.push({
      kind: standsAlone ? 'display' : 'inline',
      plain: wrapped, marked: wrapped,
      left: minX(bounds), right: maxX(bounds),
      baseline: all[0].y, page: number, scale: 1,
    })
  }
}

/**
 * What the boxes reach. A formula is two-dimensional — its limits sit under
 * the sign and its numerator over the bar — so touching one means taking all
 * of it; of a line of prose, the glyphs inside (the Mac's `reached(in:boxes:)`).
 */
function reached(layout: Layout, boxes: Rect[]): Reached[] {
  const selected = (glyph: Glyph) => boxes.some((box) => belongs(glyph, box))
  const out: Reached[] = []
  for (const block of layout.blocks) {
    if (block.isFormula) {
      const all = block.rows.flat()
      if (all.some(selected)) out.push({ block, glyphs: all })
    } else {
      const kept = block.rows[0].filter(selected)
      if (kept.length > 0) out.push({ block, glyphs: kept })
    }
  }
  return out
}

/**
 * The formula lasso's snap: the glyphs a rectangle over the page would be
 * read for — the whole formula touched, limits and bar and number included,
 * or the words inside — united, in the page's coordinates as a selection's
 * bounds are (the cropBox's origin not added). Null when the rectangle
 * reaches nothing the page can be read for. This is what the lasso snaps
 * to, so that the box on the page is exactly what Ultracopy will copy (the
 * Mac's `MathReader.extentRead`).
 */
export function extentRead(page: PageInput, rect: Rect): Rect | null {
  if (page.glyphs.length === 0) return null
  const layout = layoutOf(page)
  // A rectangle in page coordinates as a box the reader uses: the cropBox's
  // origin added, a point wider either side — exactly how `lineBoxes` are made.
  const box = insetBy(offsetBy(rect, page.cropBox.x, page.cropBox.y), -1, 0)
  const found = reached(layout, [box])
  const wantsFormula = found.some((one) => one.block.isFormula)
  let all: Rect | null = null
  for (const { block, glyphs } of found) {
    if (!block.isFormula && wantsFormula && glyphs.length * 10 < block.rows[0].length * 9) continue
    for (const glyph of glyphs) all = all ? union(all, rectOf(glyph)) : rectOf(glyph)
  }
  if (!all) return null
  return offsetBy(all, -page.cropBox.x, -page.cropBox.y)
}

/** The relations an aligned formula lines up at. */
const RELATIONS = new Set([
  '=', '<', '>', ':', '\\leq', '\\geq', '\\neq', '\\approx', '\\equiv', '\\sim', '\\simeq',
  '\\propto', '\\in', '\\subset', '\\subseteq', '\\supset', '\\supseteq', '\\to',
  '\\rightarrow', '\\Rightarrow', '\\Leftrightarrow', '\\leftarrow', '\\coloneqq',
  '\\ll', '\\gg', '\\leqslant', '\\geqslant', '\\lesssim', '\\gtrsim', '\\triangleq',
  '\\doteq', '\\cong', '\\mapsto', '\\iff', '\\implies', '\\prec', '\\succ',
  '\\preceq', '\\succeq',
])

interface Run { end: number; latex: string; bounds: Rect; baseline: number }

/**
 * Displayed formulas one under another that line up, as the lines of one
 * formula — what an `align`, a `gather` or an `aligned` sets. `atRelation`:
 * lines that each have a relation at the same place across the page, lined
 * up there with `&`. Otherwise lines a \jot apart that start at the same
 * place (`&` at the head of each), end at the same place, or are centred on
 * one another (`gathered`). One number for the whole is the formula's; a
 * number for each line takes `align` or `gather`.
 */
function alignedRun(start: number, reached: Reached[], selected: (glyph: Glyph) => boolean, rules: Rule[], atRelation = true): Run | null {
  interface Line { glyphs: Glyph[]; tag: string | null; relations: number[]; baseline: number; bounds: Rect; next: number }
  const lineOf = (block: Block, glyphs: Glyph[], next: number): Line | null => {
    if (!block.isFormula || glyphs.length === 0) return null
    let all = glyphs
    let tag: string | null = null
    const split = numbered(all, sizeOf(all))
    if (split !== null) {
      all = split.formula
      if (split.number.every(selected)) {
        const inner = trimSet(latexOf(split.number, []), '() ')
        if (inner !== '') tag = inner
      }
    }
    if (all.length === 0) return null
    const body = ordinarySize(all)
    const standing = all.filter((one) => one.size >= body * 0.92 && RELATIONS.has(spell(one)))
    let baseline: number
    if (standing.length > 0) {
      const first = standing[0]
      const heights = ascending(standing.map((one) => one.y))
      const middle = heights[Math.floor(heights.length / 2)]
      baseline = middle === 0 ? first.y : middle
    } else if (atRelation) {
      return null
    } else {
      baseline = context(all).baseline
    }
    return { glyphs: all, tag, relations: ascending(standing.map((one) => minX(rectOf(one)))), baseline, bounds: extent(all), next }
  }
  const head = lineOf(reached[start].block, reached[start].glyphs, start + 1)
  if (head === null) return null
  const lines = [head]
  // The number of an `equation` round an `aligned` with an even number of
  // lines: between two of its lines, on a row of its own at the right.
  let shared: string | null = null
  let next = start + 1
  while (next < reached.length) {
    const previous = lines[lines.length - 1]
    const body = ordinarySize(previous.glyphs)
    let after = next
    let number: string | null = null
    if (shared === null && !reached[next].block.isFormula && next + 1 < reached.length) {
      const found = standaloneNumber(reached[next].glyphs, maxOf(lines.map((line) => maxX(line.bounds))) ?? 0, body)
      if (found !== null) {
        number = reached[next].glyphs.every(selected) ? found : ''
        after = next + 1
      }
    }
    const candidate = lineOf(reached[after].block, reached[after].glyphs, after + 1)
    if (candidate === null) break
    const drop = previous.baseline - candidate.baseline
    // A line apart — or further, when the limits of the lines' sums fill what
    // is between them: then the ink of one line comes within a \jot of the
    // next's.
    const gap = minY(previous.bounds) - maxY(candidate.bounds)
    if (!(drop > body * 0.9 && (drop < body * 3.5 || (drop < body * 6 && gap < body * 0.9))
      && maxX(candidate.bounds) > minX(previous.bounds) && minX(candidate.bounds) < maxX(previous.bounds))) break
    if (number !== null) {
      const height = reached[next].glyphs[0].y
      if (!(height < previous.baseline && height > candidate.baseline)) break
      shared = number
    }
    lines.push(candidate)
    next = after + 1
  }
  if (lines.length < 2) return null

  // The most lines from the first that line up, and how.
  type Lining = { kind: 'relation'; column: number } | { kind: 'left' } | { kind: 'right' } | { kind: 'centre' }
  const lining = (run: Line[]): Lining | null => {
    if (atRelation) {
      const column = run[0].relations.find((x) => run.slice(1).every((line) => line.relations.some((at) => Math.abs(at - x) < 1)))
      return column === undefined ? null : { kind: 'relation', column }
    }
    const pairs = run.slice(1).map((lower, at) => [run[at], lower] as const)
    // A line apart, not a display apart.
    const tight = pairs.every(([upper, lower]) => minY(upper.bounds) - maxY(lower.bounds) < ordinarySize(upper.glyphs) * 0.9)
    // A bar between two of them, across both, makes them a fraction.
    const barred = pairs.some(([upper, lower]) => rules.some((rule) => midY(rule.rect) < upper.baseline && midY(rule.rect) > lower.baseline
      && maxX(rule.rect) > Math.max(minX(upper.bounds), minX(lower.bounds))
      && minX(rule.rect) < Math.min(maxX(upper.bounds), maxX(lower.bounds))))
    // A table's rows start together too: a row of cells an em or more apart,
    // or of measured numbers, is a table's.
    const tabular = run.some((line) => {
      const body = ordinarySize(line.glyphs)
      let reach = -Number.MAX_VALUE
      let gaps = 0
      for (const glyph of sortedBy(line.glyphs, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))) {
        if (reach > -Number.MAX_VALUE && minX(rectOf(glyph)) - reach >= body * 0.8) gaps += 1
        reach = Math.max(reach, maxX(rectOf(glyph)))
      }
      const measured = line.glyphs.filter((one) => spell(one) === '\\pm').length
      // Nor is a line that could not stand as a display on its own, a step
      // of an algorithm ("7:"), or an item of a list.
      const spelled = sortedBy(line.glyphs, (a, b) => minX(rectOf(a)) < minX(rectOf(b))).map(spell)
      let digits = 0
      while (digits < spelled.length && count(spelled[digits]) === 1 && isNumber(chars(spelled[digits])[0])) digits += 1
      const numbered = digits > 0 && digits < spelled.length && spelled[digits] === ':'
      const bulleted = spelled[0] === '\\bullet' || spelled[0] === '\u2022'
      // Nor is a label in brackets on a line of its own — the "(ℓ₂-CL)" a long
      // equation's name drops to under it.
      const label = spelled[0] === '(' && spelled[spelled.length - 1] === ')' && spelled.length <= 16
      return gaps >= 3 || measured >= 2 || line.glyphs.length <= 3 || numbered || bulleted || label
    })
    if (!tight || barred || tabular) return null
    const same = (value: (line: Line) => number, slack: number) => {
      const values = run.map(value)
      return (maxOf(values) ?? 0) - (minOf(values) ?? 0) < slack
    }
    if (same((line) => minX(line.bounds), 1)) return { kind: 'left' }
    if (same((line) => midX(line.bounds), 1.5)) return { kind: 'centre' }
    if (same((line) => maxX(line.bounds), 1)) return { kind: 'right' }
    return null
  }
  let count_ = lines.length
  let found: Lining | null = null
  while (count_ >= 2) {
    found = lining(lines.slice(0, count_))
    if (found !== null) break
    count_ -= 1
  }
  if (found === null) return null
  const run = lines.slice(0, count_)
  // A number between the lines belongs to the whole only if all of the lines
  // it stood between are in the run.
  const tags = [...run.flatMap((line) => (line.tag !== null ? [line.tag] : [])),
    ...(count_ === lines.length && shared !== null && shared !== '' ? [shared] : [])]
  const written: string[] = []
  for (const line of run) {
    const nearby = rules.filter((rule) => intersects(insetBy(line.bounds, -2, -2), rule.rect))
    let text: string
    if (found.kind === 'relation') {
      const column = found.column
      const left = line.glyphs.filter((one) => minX(rectOf(one)) < column - 0.5)
      const right = line.glyphs.filter((one) => minX(rectOf(one)) >= column - 0.5)
      const before = left.length === 0 ? '' : latexOf(left, nearby)
      text = (before === '' ? '' : before + ' ') + '&' + latexOf(right, nearby)
    } else if (found.kind === 'left') {
      text = '&' + latexOf(line.glyphs, nearby)
    } else if (found.kind === 'right') {
      text = latexOf(line.glyphs, nearby) + ' &'
    } else {
      text = latexOf(line.glyphs, nearby)
    }
    if (tags.length > 1 && line.tag !== null) text += ` \\tag{${line.tag}}`
    written.push(text)
  }
  const centred = found.kind === 'centre'
  const environment = tags.length > 1 ? (centred ? 'gather' : 'align') : (centred ? 'gathered' : 'aligned')
  let written_ = `\\begin{${environment}} ` + written.join(' \\\\ ') + ` \\end{${environment}}`
  if (tags.length === 1) written_ += `\\tag{${tags[0]}}`
  const bounds = run.slice(1).reduce((box, line) => union(box, line.bounds), run[0].bounds)
  return { end: run[run.length - 1].next, latex: written_, bounds, baseline: run[0].baseline }
}

/** A row that is only an equation's number — "(1)", "(2a)" — set well to
 *  the right of the lines it numbers, as its text (`standaloneNumber`). */
function standaloneNumber(glyphs: Glyph[], edge: number, body: number): string | null {
  if (glyphs.length < 3 || glyphs.length > 8) return null
  const left = minOf(glyphs.map((one) => minX(rectOf(one))))
  if (left === undefined || !(left > edge + body)) return null
  const spelled = sortedBy(glyphs, (a, b) => a.x < b.x).map(spell).join('')
  if (!/^\([0-9]+(\.[0-9]+)?[a-z]?\)$/.test(spelled)) return null
  return spelled.slice(1, -1)
}

/** Displayed lines a line apart that break into cells at the same places —
 *  an `array` or a `matrix` with nothing round it — as one `matrix`. */
function matrixRun(start: number, reached: Reached[], rules: Rule[]): Run | null {
  type Cell = { glyphs: Glyph[]; span: Rect }
  const cellsOf = (glyphs: Glyph[]): Cell[] => {
    const body = ordinarySize(glyphs)
    const result: Cell[] = []
    for (const glyph of sortedBy(glyphs, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))) {
      const last = result[result.length - 1]
      if (last !== undefined && minX(rectOf(glyph)) - maxX(last.span) < body * 0.8) {
        last.glyphs.push(glyph)
        last.span = union(last.span, rectOf(glyph))
      } else {
        result.push({ glyphs: [glyph], span: rectOf(glyph) })
      }
    }
    return result
  }
  const lines: { cells: Cell[]; baseline: number }[] = []
  let next = start
  while (next < reached.length && reached[next].block.isFormula && reached[next].block.rows.length === 1) {
    const glyphs = reached[next].glyphs
    const split = cellsOf(glyphs)
    if (split.length < 2) break
    const baseline = context(glyphs).baseline
    const previous = lines[lines.length - 1]
    if (previous !== undefined) {
      const body = ordinarySize(glyphs)
      const drop = previous.baseline - baseline
      if (!(previous.cells.length === split.length && drop > body * 0.9 && drop < body * 1.6
        && previous.cells.every((cell, at) => maxX(cell.span) > minX(split[at].span) && minX(cell.span) < maxX(split[at].span)))) break
    }
    lines.push({ cells: split, baseline })
    next += 1
  }
  if (lines.length < 2) return null
  const cells = lines.map((line) => line.cells.map((cell) => latexOf(cell.glyphs, rules)))
  // What lines up in cells and is not a matrix: a table of results — many
  // columns, most cells a measured number ("93.2 ± 0.3") — and an algorithm,
  // whose lines begin with their numbers ("4:"). Both came back as one
  // \begin{matrix}; each line is its own formula.
  const all = cells.flat()
  const measured = all.filter((cell) => /[0-9]\.[0-9]/.test(cell)).length
  if (!(lines[0].cells.length <= 6 && measured * 2 <= all.length
    && !cells.every((line) => line.length > 0 && /^[0-9]+:$/.test(line[0])))) return null
  const written = cells.map((line) => line.join(' & '))
  const text = '\\begin{matrix} ' + written.join(' \\\\ ') + ' \\end{matrix}'
  const spans = lines.flatMap((line) => line.cells.map((cell) => cell.span))
  const bounds = spans.slice(1).reduce((box, one) => union(box, one), lines[0].cells[0].span)
  return { end: next, latex: text, bounds, baseline: lines[0].baseline }
}

/** A line that holds nothing but mathematics, as a displayed formula — nil
 *  when it is prose with a formula in it, which must stay where it is. */
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
  // What is left once the mathematics is out: an equation carries at most
  // its number and the punctuation that ends the sentence it completes.
  let tag: string | null = null
  let leftovers = trimWhitespace(rest)
  const match = /\(([0-9]+[a-z]?)\)/.exec(leftovers)
  if (match) {
    tag = trimSet(match[0], '()')
    leftovers = leftovers.slice(0, match.index) + leftovers.slice(match.index + match[0].length)
  }
  const remainder = trimSet(leftovers, ' ,.;:\t')
  if (remainder !== '') return null
  let body = joiningText(maths.join(' '))
  if (tag !== null) body += `\\tag{${tag}}`
  return displayed(body)
}

/**
 * A formula set on its own line, as LaTeX that compiles. With no number that
 * is `$$…$$`, which every editor reads. With one, amsmath will not have it
 * there — `\tag` inside `$$` and `align` inside any display are errors,
 * though MathJax lets both pass — so a numbered formula is an `equation`,
 * and lines that each keep a number are the `align` they already are.
 */
export function displayed(body: string): string {
  if (body.startsWith('\\begin{align}') || body.startsWith('\\begin{gather}')) return body
  if (body.includes('\\tag{')) return `\\begin{equation} ${body} \\end{equation}`
  return `$$${body}$$`
}

/** Whether a row is a section title, and how loud a one. */
function heading(scale: number, glyphs: Glyph[], text: string, short: boolean): PieceKind {
  // A title is short and does not end in a full stop.
  const trimmed = trimWhitespace(text)
  if (trimmed.endsWith('.') || trimmed.endsWith(',') || !(count(trimmed) < 90)
    // A formula with its number is an equation, however large its symbols.
    || (trimmed.includes('$') && wordsOutsideFormulas(trimmed) < 2)) return 'prose'
  const bold = glyphs.length > 0 && glyphs.every(isBold)
  if (scale >= 1.12) return { heading: scale >= 1.45 ? 2 : scale >= 1.22 ? 3 : 4 }
  if (bold && short && scale >= 1.0) return { heading: 4 }
  return 'prose'
}

/** How many words of letters a line has outside its `$…$`. */
function wordsOutsideFormulas(text: string): number {
  let words = 0
  let run = 0
  let inMath = false
  const close = () => {
    if (run >= 2) words += 1
    run = 0
  }
  for (const character of chars(text)) {
    if (character === '$') { inMath = !inMath; close(); continue }
    if (inMath) continue
    if (isLetter(character)) run += 1
    else close()
  }
  close()
  return words
}

/** The row, read as `read` reads it, with its bold words wrapped. */
function readMarkingBold(row: Glyph[], rules: Rule[], characters: PageCharacter[], text: string): string {
  // Runs of one weight at a time, made of whole words — and a word with
  // mathematics in it is never a bold word: \mathbf{D}_{1:t} is one formula.
  const body = context(row).bodySize
  const runs: { bold: boolean; glyphs: Glyph[] }[] = []
  for (const word of words(sortedBy(row, (a, b) => a.x < b.x), body)) {
    const formula = word.some(isMathFont) || hasWordSubscript(word, body)
    const bold = !formula && word.every(isBold)
    const last = runs[runs.length - 1]
    if (last !== undefined && last.bold === bold) last.glyphs.push(...word)
    else runs.push({ bold, glyphs: [...word] })
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

/** Whether a glyph was drawn in a bold face — from the font's own name,
 *  without the subset tag in front (six random letters can hold a "BX"). */
export function isBold(glyph: Glyph): boolean {
  const name = family(glyph)
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
  return lines(read, true)
}

/**
 * The pieces as the lines of a note — `markdown`: a title as a title, bold
 * as bold, a blank line round every display — or of a clipboard, where a
 * display breaks its sentence without ending its paragraph: the words after
 * it go on on the next line, unless the page indented them (`lines(of:)`).
 */
export function lines(read: Piece[], markdown: boolean): string[] {
  // The column, as the selected rows drew it.
  const rows = read.filter((piece) => piece.kind !== 'inline')
  const left = minOf(rows.map((piece) => piece.left)) ?? 0
  const right = maxOf(rows.map((piece) => piece.right)) ?? 0
  const column = Math.max(right - left, 1)
  // How far apart two lines of one paragraph sit, as this page set them.
  const gaps: number[] = []
  for (let i = 0; i + 1 < rows.length; i += 1) {
    const above = rows[i]
    const below = rows[i + 1]
    if (above.page !== below.page) continue
    const gap = above.baseline - below.baseline
    if (gap > 1 && gap < 80) gaps.push(gap)
  }
  const sortedGaps = ascending(gaps)
  const leading = sortedGaps.length === 0 ? 0 : sortedGaps[Math.floor(sortedGaps.length / 2)]

  const out: string[] = []
  let paragraph = ''
  let previous: Piece | null = null
  // On a clipboard: that the last thing written was a display.
  let afterDisplay = false
  const close = () => {
    const trimmed = trimWhitespace(paragraph)
    if (trimmed !== '') out.push(trimmed)
    paragraph = ''
  }
  const breakHere = () => {
    close()
    if (out[out.length - 1] !== '' && out.length > 0) out.push('')
  }
  const display = (text: string) => {
    if (markdown) {
      breakHere()
      out.push(text)
      out.push('')
    } else {
      close()
      out.push(spread(text))
      afterDisplay = true
    }
    previous = null
  }
  for (const piece of read) {
    const text = markdown ? piece.marked : piece.plain
    if (isHeading(piece.kind)) {
      breakHere()
      out.push(markdown ? '#'.repeat(piece.kind.heading) + ' ' + text : text)
      out.push('')
      previous = null
      afterDisplay = false
      continue
    }
    if (piece.kind === 'display') {
      display(text)
      continue
    }
    if (piece.kind === 'inline') {
      paragraph += paragraph === '' ? text : ' ' + text
      continue
    }
    // A line that is all mathematics and an equation number is a displayed
    // equation, whatever the row was classified as.
    const equation = piece.isTable ? null : displayedEquation(text)
    if (equation !== null) {
      display(equation)
      continue
    }
    // A table's row is a line of its own: joined into a paragraph, its cells
    // and the next row's ran together.
    if (piece.isTable) {
      close()
      out.push(text)
      previous = piece
      afterDisplay = false
      continue
    }
    // After a display, TeX starts the sentence's next words at the column's
    // edge and a new paragraph a paragraph's indent in from it.
    if (afterDisplay) {
      afterDisplay = false
      if (piece.left > left + 6) out.push('')
    }
    // A paragraph ended if the line before stopped short of the column, or
    // this one sits further below it than lines of a paragraph do.
    if (previous && previous.kind === 'prose') {
      const endedShort = previous.right < right - column * 0.12
      const spaced = leading > 0 && previous.page === piece.page && previous.baseline - piece.baseline > leading * 1.5
      if (endedShort || spaced) breakHere()
    }
    if (paragraph === '') paragraph = text
    else if (paragraph.endsWith('-')) paragraph = paragraph.slice(0, -1) + text
    else paragraph += ' ' + text
    previous = piece
  }
  close()
  while (out.length > 0 && out[out.length - 1] === '') out.pop()
  return out
}

/** The environments whose rows are lines of a display. */
const LINED = new Set([
  'aligned', 'gathered', 'alignedat', 'split', 'align', 'align*', 'gather', 'gather*',
  'alignat', 'alignat*', 'flalign', 'flalign*', 'multline', 'multline*',
])

/**
 * A display of several rows written a row a line, the way it is typed:
 * `$$\begin{aligned}` on its first line, each row on one of its own,
 * `\end{aligned}$$` on the last — and an `equation` round it opened and
 * closed on lines of their own. A matrix or cases inside a row stays in its
 * row, and a formula of one row is left on one line (`spread`).
 */
export function spread(display: string): string {
  if (!display.includes('\\\\')) return display
  const characters = [...display]
  let out = ''
  const stack: string[] = []
  // Whether the display opens with its environment: then that one's rows
  // are the display's lines, whatever it is.
  const opening_ = display.startsWith('$$\\begin{') || display.startsWith('\\begin{')
  let outermost = true
  const trimEnd = () => { while (out.endsWith(' ')) out = out.slice(0, -1) }
  const nameAt = (start: number): { name: string; end: number } | null => {
    if (start >= characters.length || characters[start] !== '{') return null
    const close = characters.indexOf('}', start)
    if (close < 0) return null
    return { name: characters.slice(start + 1, close).join(''), end: close + 1 }
  }
  let at = 0
  const skipSpaces = () => { while (at < characters.length && characters[at] === ' ') at += 1 }
  while (at < characters.length) {
    const rest = characters.length - at
    if (rest >= 7 && characters.slice(at, at + 7).join('') === '\\begin{') {
      const found = nameAt(at + 6)
      if (found !== null) {
        const breaks = LINED.has(found.name) || found.name.startsWith('equation') || (outermost && opening_)
        outermost = false
        stack.push(breaks ? found.name : '')
        out += characters.slice(at, found.end).join('')
        at = found.end
        if (breaks) { out += '\n'; skipSpaces() }
        continue
      }
    }
    if (rest >= 5 && characters.slice(at, at + 5).join('') === '\\end{') {
      const found = nameAt(at + 4)
      if (found !== null) {
        const top = stack.pop()
        if (top !== undefined && top !== '') {
          trimEnd()
          if (!out.endsWith('\n')) out += '\n'
        }
        out += characters.slice(at, found.end).join('')
        at = found.end
        continue
      }
    }
    if (rest >= 2 && characters[at] === '\\' && characters[at + 1] === '\\') {
      const top = stack[stack.length - 1]
      const breaks = top !== undefined && top !== ''
      if (breaks) trimEnd()
      out += '\\\\'
      at += 2
      if (breaks) { out += '\n'; skipSpaces() }
      continue
    }
    if (characters[at] === '\\' && at + 1 < characters.length) {
      out += characters[at] + characters[at + 1]
      at += 2
      continue
    }
    if (characters[at] === ' ' && out.endsWith('\n')) { at += 1; continue }
    if (characters[at] === '\n') { at += 1; continue }
    out += characters[at]
    at += 1
  }
  return out.split('\n').map(trimWhitespace).join('\n')
}

/** What the page's text has at each point, for the glyphs this cannot read
 *  on its own: the character whose box overlaps the glyph the most, and only
 *  if it really does. A maths glyph borrows only punctuation and symbols. */
function characterLookup(characters: PageCharacter[]): (glyph: Glyph) => string | null {
  const boxes = characters.filter((one) => !isWhitespace(one.character))
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
    if (isMathFont(glyph) && (isLetter(best.character) || isNumber(best.character))) return null
    return best.character
  }
}

/** Whether a glyph is inside the selection rather than grazing it: the line
 *  a glyph is on is the line its baseline sits in. */
function belongs(glyph: Glyph, box: Rect): boolean {
  const slack = glyph.size * 0.15
  const r = rectOf(glyph)
  return glyph.y > minY(box) - slack && glyph.y < maxY(box) + slack && maxX(r) > minX(box) && minX(r) < maxX(box)
}

/** A formula split from the number printed beside it, past a gap far wider
 *  than anything inside a formula, in brackets. */
function numbered(glyphs: Glyph[], body: number): { formula: Glyph[]; number: Glyph[] } | null {
  const sorted = sortedBy(glyphs, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))
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

/**
 * Rows gathered into the things they belong to. A paragraph's lines are a
 * baselineskip apart and full of words; the rows of a displayed formula
 * carry none, and something holds them together — a fraction bar between
 * them, a sign or a tall bracket reaching from one to the next, a row of
 * limits under its sign, a pair of tall brackets round them all.
 */
function blocks(rows: Glyph[][], body: number, rules: Rule[]): Glyph[][][] {
  if (rows.length === 0) return []
  const baselines = rows.map((row) => context(row).baseline)
  const extents = rows.map(extent)
  // The lines of cases hold words and are still the formula's.
  const fences = tallFences(rows.flat(), body)
  // A pair of tall brackets holds the rows between them, and the row they
  // stand on — the one they are centred on, whose left side runs up to them;
  // the line of an align passing across them is not held. A brace nothing
  // closes holds the lines that begin beside it: the other column's lines
  // stood beside it too.
  const held = (row: number): number | null => {
    const found = fences.findIndex((one) => {
      const fence = one.region
      if (!(minY(fence) < baselines[row] && maxY(fence) > baselines[row])) return false
      const inside = minX(extents[row]) > minX(fence) - 1 && maxX(extents[row]) < maxX(fence) + 1
        && (one.closed || minX(extents[row]) < minX(fence) + body * 2)
      const standing = rows[row].some((glyph) => (isDelimiter(glyph) || barToken(glyph) !== null || spell(glyph) === '')
        && (Math.abs(maxX(rectOf(glyph)) - minX(fence)) < 1.5 || Math.abs(minX(rectOf(glyph)) - maxX(fence)) < 1.5))
      const centred = minX(extents[row]) < minX(fence) && maxX(extents[row]) > minX(fence) - body * 2
        && Math.abs(midY(fence) - (baselines[row] + body * 0.25)) < body * 0.3
      return inside || standing || centred
    })
    return found >= 0 ? found : null
  }
  const heldBy = indices(rows.length).map(held)
  const prose = indices(rows.length).map((row) => containsProse(rows[row]) && heldBy[row] === null)
  const parent = indices(rows.length)
  const root = (index: number) => {
    let at = index
    while (parent[at] !== at) at = parent[at]
    return at
  }
  const joinRows = (one: number, other: number) => {
    const a = root(one)
    const b = root(other)
    if (a !== b) parent[Math.max(a, b)] = Math.min(a, b)
  }
  const overlap = (one: number, other: number) =>
    maxX(extents[one]) > minX(extents[other]) && minX(extents[one]) < maxX(extents[other])
  // A fraction bar over or under a row, no wider than it: the row is a
  // numerator or a denominator.
  const barBeside = (row: number) => rules.some((rule) => rule.rect.width > 1 && rule.rect.height < rule.rect.width
    && minX(rule.rect) > minX(extents[row]) - 4 && maxX(rule.rect) < maxX(extents[row]) + 4
    && Math.abs(midY(rule.rect) - baselines[row]) < body * 1.2)
  // The rows right over and right under each one in its own column.
  const unders = indices(rows.length).map((row) => maxBy(
    indices(rows.length).filter((at) => baselines[at] < baselines[row] && overlap(at, row)),
    (a, b) => baselines[a] < baselines[b]))
  const overs = indices(rows.length).map((row) => minBy(
    indices(rows.length).filter((at) => baselines[at] > baselines[row] && overlap(at, row)),
    (a, b) => baselines[a] < baselines[b]))
  const small = (index: number) => rows[index].every((one) => one.size < body * 0.8)
  // How far a row is from the line on its far side — a row of limits belongs
  // to the nearer of the two lines it stands between, and the limits of the
  // line beyond are no line; a line of prose is not one it could belong to.
  const gapBelow = (row: number): number | null => {
    let under = unders[row]
    while (under !== undefined && small(under)) under = unders[under]
    return under === undefined || prose[under] ? null : baselines[row] - baselines[under]
  }
  const gapAbove = (row: number): number | null => {
    let over = overs[row]
    while (over !== undefined && small(over)) over = overs[over]
    return over === undefined || prose[over] ? null : baselines[over] - baselines[row]
  }
  // Two rows of scripts one over the other, each the limits of its own line,
  // stand closer than a line and are not one formula.
  const apart = (upper: number, lower: number) => {
    const top = overs[upper]
    const bottom = unders[lower]
    if (!small(upper) || !small(lower) || top === undefined || bottom === undefined || prose[top] || prose[bottom]) return false
    return linked(rows[top], rows[upper], baselines[top], baselines[upper], body, rules)
      && linked(rows[lower], rows[bottom], baselines[lower], baselines[bottom], body, rules)
  }
  for (let row = 0; row < rows.length; row += 1) {
    if (prose[row]) continue
    const under = unders[row]
    const over = overs[row]
    if (under !== undefined && !prose[under] && !apart(row, under)
      && linked(rows[row], rows[under], baselines[row], baselines[under], body, rules,
        { above: gapAbove(row), below: gapBelow(under) })) joinRows(row, under)
    if (over !== undefined && !prose[over] && !apart(over, row)
      && linked(rows[over], rows[row], baselines[over], baselines[row], body, rules,
        { above: gapAbove(over), below: gapBelow(row) })) joinRows(over, row)
    // The lines of a matrix or of cases, held by one pair of tall brackets.
    const fence = heldBy[row]
    if (fence !== null) {
      for (let other = 0; other < rows.length; other += 1) {
        if (other !== row && heldBy[other] === fence) joinRows(row, other)
      }
    }
    // Side by side: only a numerator or a denominator stands a row of its
    // own next to its line; two cells of a table a line down do not.
    for (let other = 0; other < rows.length; other += 1) {
      if (other === row || prose[other] || overlap(other, row)) continue
      const gap = Math.max(minX(extents[other]), minX(extents[row])) - Math.min(maxX(extents[other]), maxX(extents[row]))
      if (gap < body * 0.8 && Math.abs(baselines[other] - baselines[row]) < body * 1.3
        && (barBeside(row) || barBeside(other))) joinRows(row, other)
    }
  }
  const grouped = new Map<number, Glyph[][]>()
  const order: number[] = []
  for (let index = 0; index < rows.length; index += 1) {
    const key = root(index)
    if (!grouped.has(key)) {
      order.push(key)
      grouped.set(key, [])
    }
    grouped.get(key)!.push(rows[index])
  }
  return order.map((key) => grouped.get(key)!)
}

const PAIRS: Record<string, string> = { '(': ')', '[': ']', '\\{': '\\}', '|': '|', '\\|': '\\|', '\\mid': '\\mid' }

/**
 * The brackets two lines tall or more, each as the region it holds: between
 * a pair of them, or after a brace nothing closes — the brace of cases. A
 * tall bracket is one glyph drawn down from its point, or a stack of pieces
 * at one place, or one OpenType glyph standing off the line of what it
 * holds, taken as two lines either side of it.
 */
export interface Fence {
  /** What the bracket holds. */
  region: Rect
  /** Whether a bracket closes it; a brace of cases holds what begins beside
   *  it, as far along as that runs. */
  closed: boolean
}

export function tallFences(glyphs: Glyph[], body: number): Fence[] {
  const sides: { token: string; box: Rect }[] = []
  // A bracket's pieces are one bracket, met once.
  const taken = new Set<number>()
  glyphs.forEach((glyph, index) => {
    if (taken.has(index)) return
    const drawn = spell(glyph)
    const token = opening(glyph) ?? closing(glyph) ?? TeX.fence(glyph.glyphName)
      ?? (['|', '\\|', '\\mid'].includes(drawn) ? drawn : null)
    if (token === null) return
    const x = glyph.x
    const column = indices(glyphs.length).filter((at) => Math.abs(glyphs[at].x - x) < glyph.size * 0.2
      && (opening(glyphs[at]) === token || closing(glyphs[at]) === token || TeX.fence(glyphs[at].glyphName) === token
        || spell(glyphs[at]) === token || spell(glyphs[at]) === ''))
    // This bracket's own pieces, not every bracket at the same place down
    // the page: two of them made a bracket as tall as the lines between.
    const stacked = stack(index, glyphs, column)
    for (const member of stacked.members) taken.add(member)
    let box = stacked.box
    if (stacked.members.length === 1 && isTallVariant(glyph, glyphs, body)) {
      const g = rectOf(glyph)
      box = { x: minX(g), y: glyph.y - body * 2.2, width: g.width, height: body * 4.4 }
    }
    if (!(box.height >= body * 1.8)) return
    sides.push({ token, box })
  })
  const result: Fence[] = []
  const used = new Set<number>()
  const order = sortedBy(indices(sides.length), (a, b) => minX(sides[a].box) < minX(sides[b].box))
  for (const index of order) {
    if (used.has(index)) continue
    const left = sides[index]
    const partner = Object.prototype.hasOwnProperty.call(PAIRS, left.token) ? PAIRS[left.token] : undefined
    if (partner === undefined) continue
    // Its partner is set at the same height: TeX sizes and places the two of
    // a \left–\right pair alike.
    const right = minBy(indices(sides.length).filter((at) => !used.has(at) && at !== index && sides[at].token === partner
      && minX(sides[at].box) > maxX(left.box) - 0.5
      && Math.abs(midY(sides[at].box) - midY(left.box)) < body * 0.3
      && Math.abs(sides[at].box.height - left.box.height) < body * 0.5),
    (a, b) => minX(sides[a].box) < minX(sides[b].box))
    const low = Math.min(minY(left.box), right !== undefined ? minY(sides[right].box) : minY(left.box))
    const high = Math.max(maxY(left.box), right !== undefined ? maxY(sides[right].box) : maxY(left.box))
    let region: Rect
    if (right !== undefined) {
      region = { x: maxX(left.box) - 0.5, y: low, width: minX(sides[right].box) - maxX(left.box) + 1, height: high - low }
    } else if (left.token === '\\{') {
      region = { x: maxX(left.box) - 0.5, y: low, width: body * 40, height: high - low }
    } else {
      continue
    }
    // It holds two lines or more: what is inside, at its own full size,
    // stands a line apart. A tall bracket round one line holds one.
    const inside = glyphs.filter((one) => containsPoint(region, { x: midX(rectOf(one)), y: one.y }) && !isDelimiter(one)
      && spell(one) !== '' && !isBigOperator(one) && (right !== undefined || minX(rectOf(one)) < minX(region) + body * 3))
    const largest = maxOf(inside.map((one) => one.size)) ?? 0
    const heights = inside.filter((one) => one.size >= largest * 0.9).map((one) => one.y)
    const top = maxOf(heights)
    const bottom = minOf(heights)
    if (top === undefined || bottom === undefined || !(top - bottom >= body * 0.9)) continue
    used.add(index)
    if (right !== undefined) used.add(right)
    result.push({ region, closed: right !== undefined })
  }
  return result
}

/** Whether two rows, one right over the other, are parts of one formula.
 *  `farther` is how far each of the two rows is from the row on its other
 *  side — over the upper one, under the lower one — when there is one. */
function linked(
  above: Glyph[], below: Glyph[], aboveBaseline: number, belowBaseline: number, body: number, rules: Rule[],
  farther: { above: number | null; below: number | null } = { above: null, below: null },
): boolean {
  const distance = aboveBaseline - belowBaseline
  // Closer than a line: nothing but a formula stacks rows that tight.
  if (distance < body) return true
  const top = extent(above)
  const bottom = extent(below)
  // A fraction bar with one row on each side of it — as wide as what it
  // divides, which a table's rule between rows of cells is not, and next to
  // both: a numerator stands on its bar and a denominator hangs from it.
  const reach = union(top, bottom)
  const across = (glyph: Glyph, rule: Rule) => midX(rectOf(glyph)) > minX(rule.rect) - 1 && midX(rectOf(glyph)) < maxX(rule.rect) + 1
  if (distance < body * 4.5 && rules.some((rule) => midY(rule.rect) > belowBaseline && midY(rule.rect) < aboveBaseline
    && aboveBaseline - midY(rule.rect) < body * 1.6 && midY(rule.rect) - belowBaseline < body * 2
    && rule.rect.width > 1 && rule.rect.height < rule.rect.width
    && minX(rule.rect) > minX(reach) - 4 && maxX(rule.rect) < maxX(reach) + 4
    && above.some((one) => across(one, rule)) && below.some((one) => across(one, rule)))) return true
  if (!(distance < body * 2)) return false
  // The pieces of one tall sign are one sign: STIX sets a displayed ∫ as its
  // top half on one row and its bottom half on the next.
  const sign = (glyph: Glyph) => isPiece(glyph) || isBigOperator(glyph)
  if (above.some((upper) => sign(upper) && below.some((lower) => sign(lower) && (isPiece(upper) || isPiece(lower))
    && Math.abs(upper.x - lower.x) < upper.size * 0.2
    && Math.abs(minY(rectOf(upper)) - maxY(rectOf(lower))) < upper.size * 0.35))) return true
  // A sign that grows reaching down past the other row's baseline, or
  // standing into what is in it — the \big brackets of two lines set tight
  // come within a point of each other and are not one formula for that.
  const reaches = (row: Glyph[], other: Glyph[], baseline: number) => {
    const span = extent(other)
    return row.some((glyph) => {
      if (!(extension(glyph) || isBigOperator(glyph))) return false
      const ink = rectOf(glyph)
      const wide = maxX(ink) > minX(span) - body * 0.6 && minX(ink) < maxX(span) + body * 0.6
      const overlaps = maxX(ink) > minX(span) && minX(ink) < maxX(span)
        && minY(ink) < maxY(span) - body * 0.2 && maxY(ink) > minY(span) + body * 0.2
      return (wide && minY(ink) < baseline && maxY(ink) > baseline) || overlaps
    })
  }
  if (reaches(above, below, belowBaseline) || reaches(below, above, aboveBaseline)) return true
  // A pair of brackets in one row round what is in the other: one pair, and
  // a tall one, set at one height — the halves of \binom.
  const encloses = (row: Glyph[], other: Glyph[]) => {
    const held = other.filter((one) => spell(one) !== '' && !isDelimiter(one))
    if (held.length === 0) return false
    const span = extent(held)
    const opens = row.filter((one) => opening(one) !== null && maxX(rectOf(one)) <= minX(span) + 1)
    const closes = row.filter((one) => closing(one) !== null && minX(rectOf(one)) >= maxX(span) - 1)
    const open = maxBy(opens, (a, b) => maxX(rectOf(a)) < maxX(rectOf(b)))
    const close = minBy(closes, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))
    if (open === undefined || close === undefined) return false
    const tall = (glyph: Glyph) => rectOf(glyph).height >= body * 1.1 || isTallVariant(glyph, row, body)
    if (!(tall(open) && tall(close) && Math.abs(open.y - close.y) < body * 0.3)) return false
    return minX(span) - maxX(rectOf(open)) < body * 0.6 && minX(rectOf(close)) - maxX(span) < body * 0.6
  }
  if (encloses(above, below) || encloses(below, above)) return true
  // A row of limits — nothing in it at full size — over or under a big
  // operator in the other, or off its corner. Over or under anything else a
  // limit sits close, a line and a half at most: further, it is the limit of
  // the formula on its other side.
  const isLimits = (row: Glyph[], other: Glyph[]) => {
    if (!row.every((one) => one.size < body * 0.8)) return false
    const span = extent(row)
    const signed = other.some((glyph) => {
      if (!isBigOperator(glyph)) return false
      const g = rectOf(glyph)
      return (maxX(g) > minX(span) && minX(g) < maxX(span))
        || (minX(span) > midX(g) && minX(span) - maxX(g) < body * 0.6)
    })
    if (signed) return true
    if (!(distance < body * 1.5)) return false
    return other.some((glyph) => maxX(rectOf(glyph)) > minX(span) && minX(rectOf(glyph)) < maxX(span))
  }
  // A row of limits between two lines is the nearer line's.
  if (farther.above !== null && farther.above < distance && isLimits(above, below) && !isLimits(below, above)) return false
  if (farther.below !== null && farther.below < distance && isLimits(below, above) && !isLimits(above, below)) return false
  return isLimits(above, below) || isLimits(below, above)
}

/** The size a set of glyphs is mostly drawn at. */
function sizeOf(glyphs: Glyph[]): number {
  const sizes = ascending(glyphs.map((one) => one.size))
  return sizes.length === 0 ? 10 : sizes[Math.floor(sizes.length * 0.75)]
}

/**
 * Whether a row belongs to a displayed formula rather than to a sentence:
 * how much of it came from a maths face, counting only the letters set at
 * the line's own size — and a row whose full-size glyphs stand a line apart
 * is a formula however few letters it has.
 */
/** Whether a row is a table's: cells set an em and more apart, three gaps
 *  and more along it, or two measured values ("93.2 ± 0.3") in it. A
 *  formula's own spacing never opens that wide, and a formula carries one ±
 *  at a time. */
export function isTableRow(row: Glyph[]): boolean {
  if (row.length <= 3) return false
  // The rows of a matrix open the same gaps between their columns and are
  // mostly digits too; a tall bracket's piece or a \cdots says which is which.
  if (row.some((glyph) => extension(glyph) || isPiece(glyph) || ['\\cdots', '\\vdots', '\\ddots'].includes(spell(glyph)))) return false
  const body = ordinarySize(row)
  const ordered = sortedBy(row, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))
  let reach = -Number.MAX_VALUE
  let gaps = 0
  for (const glyph of ordered) {
    const r = rectOf(glyph)
    if (reach > -Number.MAX_VALUE && minX(r) - reach >= body * 0.8) gaps += 1
    reach = Math.max(reach, maxX(r))
  }
  const measured = row.filter((one) => spell(one) === '\\pm').length
  // And its cells are numbers: three formulas set a \quad apart on one line
  // open the same gaps and are a display still.
  const digits = row.filter((glyph) => {
    const spelled = spell(glyph)
    return count(spelled) === 1 && isNumber(firstChar(spelled) ?? '')
  }).length
  return (gaps >= 3 && digits * 3 >= row.length) || (measured >= 2 && digits >= 4)
}

function isDisplayRow(row: Glyph[]): boolean {
  if (row.length === 0) return false
  // Cases folded into the row their brace stands on: the "if" of each case is
  // a word of a sentence and still the formula's, which a brace nothing
  // closes, two lines tall, says — and the words of two cases folded
  // together, "iiff", say nothing. A tall pair round a fraction in a sentence
  // is still the sentence's.
  if (tallFences(row, context(row).bodySize).some((fence) => !fence.closed)) return true
  if (containsProse(row)) return false
  // A row of a table is not a formula either, however many of its cells are
  // numbers; read as one it came back as one run of digits.
  if (isTableRow(row)) return false
  const standing = row.filter((one) => one.size >= context(row).bodySize * 0.92 && !extension(one) && !isDelimiter(one)).map((one) => one.y)
  const top = maxOf(standing)
  const bottom = minOf(standing)
  if (top !== undefined && bottom !== undefined && top - bottom >= context(row).bodySize * 0.9 && row.some(isMathFont)) return true
  const body = context(row).bodySize
  const deciding: Glyph[] = []
  // The letters of a name — "sin", "arg" — are part of the formula and do
  // not vote.
  for (const word of words(row, body)) {
    let letters: Glyph[] = []
    const settle = () => {
      const spelled = letters.map(spell).join('')
      if (!isOperatorName(spelled)) deciding.push(...letters)
      letters = []
    }
    for (const glyph of word) {
      if (!(glyph.size >= body * 0.92)) continue
      const token = spell(glyph)
      if (!(count(token) > 1 || isLetter(firstChar(token) ?? ''))) { settle(); continue }
      if (!isMathish(glyph) && count(token) === 1) {
        letters.push(glyph)
      } else {
        settle()
        deciding.push(glyph)
      }
    }
    settle()
  }
  if (deciding.length === 0) return false
  const mathish = deciding.filter(isMathish).length
  if (deciding.length <= 4) return mathish > 0
  if (row.some(isBigOperator)) return mathish >= deciding.length * 0.25
  return mathish >= deciding.length * 0.4
}

/** Whether a row contains ordinary words rather than only symbols — set at
 *  the line's own size, and not a name like "log" that is the formula's. */
function containsProse(row: Glyph[]): boolean {
  const body = context(row).bodySize
  const split = words(row, body)
  return split.some((word, index) => {
    // A name applied to what follows it — \mathrm{Laplace}\left(, \mathrm{Exp}(1) —
    // stands a thin space from its bracket, where a word of a sentence
    // stands a word's space off.
    if (appliesTo(word, index + 1 < split.length ? split[index + 1] : null, body)) return false
    const full = word.filter((one) => one.size >= body * 0.92)
    if (!(full.length >= 2 && !full.some(isMathish))) return false
    const spelled = full.map(spell)
    if (!(spelled.filter((one) => isLetter(firstChar(one) ?? '')).length >= 2)) return false
    return !isOperatorName(spelled.join(''))
  })
}

/** A variant a larger bracket is drawn from: ".s1" to ".s5". */
function isSizeVariant(name: string): boolean {
  const dot = name.lastIndexOf('.')
  if (dot < 0) return false
  const variant = name.slice(dot + 1)
  return variant.startsWith('s') && chars(variant.slice(1)).every(isNumber)
}

/**
 * Glyphs grouped into the rows they were set on. The rows are set by the
 * full-size glyphs; anything smaller hangs from the row it is beside, as a
 * run, and the signs that are drawn from a point off their line — big
 * operators, tall brackets, radicals — wait until the rows are there.
 */
/** Where a glyph stands, to the hundredth of a point (`Place`). */
const place = (glyph: Glyph) => `${Math.round(glyph.x * 100)}|${Math.round(glyph.y * 100)}`

/** The pieces of bars built tall out of several of one bar glyph set one
 *  over another at one place, closer than a line (`barPieces`). */
function barPieces(glyphs: Glyph[]): Set<string> {
  const columns = new Map<number, Glyph[]>()
  for (const glyph of glyphs) {
    if (extension(glyph) || barToken(glyph) === null) continue
    const key = Math.round(glyph.x * 10)
    const column = columns.get(key)
    if (column) column.push(glyph)
    else columns.set(key, [glyph])
  }
  const found = new Set<string>()
  for (const column of columns.values()) {
    if (column.length < 2) continue
    const ordered = sortedBy(column, (a, b) => a.y < b.y)
    for (let at = 0; at + 1 < ordered.length; at += 1) {
      const lower = ordered[at]
      const upper = ordered[at + 1]
      if (upper.y - lower.y < upper.size * 0.8 && barToken(lower) === barToken(upper)) {
        found.add(place(lower))
        found.add(place(upper))
      }
    }
  }
  return found
}

function rowsOf(given: Glyph[], rules: Rule[] = []): Glyph[][] {
  // The tips of an \underbrace or \overbrace spell nothing and stand on no
  // line: hung from the nearest line — the other column's, as it happened —
  // they carried the brace's label there with them, and the label came back
  // inside the formula as its subscripts.
  const glyphs = given.filter((one) => !(one.glyphName?.startsWith('bracehtip') ?? false))
  if (glyphs.length === 0) return []
  const sizes = ascending(glyphs.map((one) => one.size))
  const body = sizes[Math.floor(sizes.length * 0.75)]
  const laid: { baseline: number; glyphs: Glyph[] }[] = []
  // A bracket at one of its larger sizes can be drawn from above its own
  // ink; so can a big operator from a font that is not an extension font.
  const floats = (glyph: Glyph) => {
    if (isBigOperator(glyph)) return true
    if (!isDelimiter(glyph) || glyph.glyphName === null) return false
    return isSizeVariant(glyph.glyphName)
  }
  const floating: Glyph[] = []
  // So do the pieces of a bar built tall out of several of one glyph —
  // STIX's "bar.x", an OpenType font's | set one over another — each a
  // full-size glyph on a line of its own making.
  const pieces = barPieces(glyphs)
  // A radical sign belongs with what it covers, which starts where it ends.
  const radicalSigns: Glyph[] = []
  for (const glyph of sortedBy(glyphs.filter((one) => one.size >= body * 0.9 && !extension(one)), (a, b) => a.y > b.y)) {
    if (floats(glyph) || pieces.has(place(glyph))) { floating.push(glyph); continue }
    if (isRadical(glyph)) { radicalSigns.push(glyph); continue }
    // Two glyphs of one line never share their ink. One drawn over another at
    // the same height is another layer of the page — the words of a figure
    // standing level with a line of its caption — and the line read with it
    // was "tion" interleaved with "I(Z;X)". A glyph printed twice for bold
    // shares its own ink.
    const layered = (row: Glyph[]) => {
      // Only letters and digits say so: the pieces of a long arrow, the
      // stroke through a relation, a mark over its letter all lie over one
      // another on one line.
      const lettered = (one: Glyph) => {
        // (A modifier letter is a letter to Unicode: the hat over ŷ is
        // U+02C6, and is no letter here.)
        if (isAccent(one)) return false
        const drawn = spell(one)
        return drawn !== '' && chars(drawn).every((c) => isLetter(c) || isNumber(c))
      }
      if (!(glyph.width > 0.05) || !lettered(glyph)) return false
      const spelled = spell(glyph)
      const g = rectOf(glyph)
      return row.some((other) => {
        if (!(other.width > 0.05) || !lettered(other)) return false
        const o = rectOf(other)
        const overlap = Math.min(maxX(o), maxX(g)) - Math.max(minX(o), minX(g))
        if (!(overlap > Math.min(other.width, glyph.width) * 0.5)) return false
        const said = spell(other)
        if (said === spelled && Math.abs(other.x - glyph.x) < glyph.size * 0.3) return false
        return true
      })
    }
    const at = laid.findIndex((row) => Math.abs(row.baseline - glyph.y) < body * 0.6 && !layered(row.glyphs))
    if (at >= 0) laid[at].glyphs.push(glyph)
    else laid.push({ baseline: glyph.y, glyphs: [glyph] })
  }

  const placedRadicals: { x: number; y: number }[] = []
  const placed = (glyph: Glyph) => placedRadicals.some((one) => one.x === glyph.x && one.y === glyph.y)
  for (const sign of [...radicalSigns, ...glyphs.filter((one) => extension(one) && isRadical(one))]) {
    // Its roof starts where it ends; what is under the roof is on its row.
    const s = rectOf(sign)
    const roofs = rules.filter((rule) => Math.abs(minX(rule.rect) - maxX(s)) < Math.max(1, sign.size * 0.15)
      && midY(rule.rect) > sign.y - sign.size * 3 && midY(rule.rect) < sign.y + sign.size * 2.5)
    const under = minBy(indices(laid.length).filter((row) => Math.abs(laid[row].baseline - sign.y) < body * 2
      && laid[row].glyphs.some((glyph) => Math.abs(minX(rectOf(glyph)) - maxX(s)) < Math.max(1, sign.size * 0.15)
        && roofs.some((rule) => midY(rule.rect) > glyph.y && midY(rule.rect) - glyph.y < body * 2))),
    (a, b) => Math.abs(laid[a].baseline - sign.y) < Math.abs(laid[b].baseline - sign.y))
    if (under !== undefined) {
      laid[under].glyphs.push(sign)
      placedRadicals.push({ x: sign.x, y: sign.y })
    } else if (!extension(sign)) {
      floating.push(sign)
    }
  }
  // Each goes beside the row it belongs to, and a sign placed can bring the
  // next one to its row: the ∑ of "∑∏P", STIX's, stood too far from the P to
  // be beside it until the ∏ was.
  const pending = [...floating]
  // A piece of a bar built tall is placed where the whole bar stands: from
  // its lowest piece. Measured each from its own point, the top pieces of a
  // \big| lifted into an exponent stood a line and a half over the line and
  // made a row of their own, and took the exponent's sum with them.
  const feet = new Map<number, number>()
  for (const glyph of floating) {
    if (!pieces.has(place(glyph))) continue
    const column = Math.round(glyph.x * 10)
    feet.set(column, Math.min(feet.get(column) ?? glyph.y, glyph.y))
  }
  const foot = (glyph: Glyph) => (pieces.has(place(glyph)) ? feet.get(Math.round(glyph.x * 10)) ?? glyph.y : glyph.y)
  let placedOne = true
  while (placedOne) {
    placedOne = false
    let at = 0
    while (at < pending.length) {
      const glyph = pending[at]
      const span = insetBy(rectOf(glyph), -body * 0.9, 0)
      const nearest = minBy(indices(laid.length).filter((row) => beside(span, laid[row].glyphs, body)),
        (a, b) => Math.abs(laid[a].baseline - foot(glyph)) < Math.abs(laid[b].baseline - foot(glyph)))
      if (nearest !== undefined && Math.abs(laid[nearest].baseline - foot(glyph)) < body * 1.3) {
        laid[nearest].glyphs.push(glyph)
        pending.splice(at, 1)
        placedOne = true
      } else {
        at += 1
      }
    }
  }
  for (const glyph of pending) {
    const at = laid.findIndex((row) => Math.abs(row.baseline - foot(glyph)) < body * 0.6)
    if (at >= 0) laid[at].glyphs.push(glyph)
    else laid.push({ baseline: foot(glyph), glyphs: [glyph] })
  }

  // A big operator, or a piece of a tall delimiter, hangs from a point above
  // its own ink: it joins the row whose baseline runs through it. A piece no
  // row runs through — the top of a brace over two cases — joins the piece
  // it stands on: the nearest row was the line of prose over the display.
  const hung: { glyph: Glyph; row: number }[] = []
  let waiting: Glyph[] = []
  for (const glyph of glyphs.filter((one) => extension(one) && !(isRadical(one) && placed(one)))) {
    const ink = rectOf(glyph)
    const through = indices(laid.length).filter((row) => laid[row].baseline > minY(ink) - 1 && laid[row].baseline < maxY(ink) + 1)
    const nearest = minBy(through, (a, b) => Math.abs(laid[a].baseline - midY(ink)) < Math.abs(laid[b].baseline - midY(ink)))
    if (nearest !== undefined) {
      laid[nearest].glyphs.push(glyph)
      hung.push({ glyph, row: nearest })
    } else {
      waiting.push(glyph)
    }
  }
  const standsOn = (glyph: Glyph): number | undefined => hung.find((other) =>
    Math.abs(other.glyph.x - glyph.x) < glyph.size * 0.2
      && maxY(rectOf(other.glyph)) > minY(rectOf(glyph)) - glyph.size * 0.3
      && minY(rectOf(other.glyph)) < maxY(rectOf(glyph)) + glyph.size * 0.3)?.row
  let progress = true
  while (progress && waiting.length > 0) {
    progress = false
    for (let index = waiting.length - 1; index >= 0; index -= 1) {
      const glyph = waiting[index]
      const row = standsOn(glyph)
      if (row === undefined) continue
      laid[row].glyphs.push(glyph)
      hung.push({ glyph, row })
      waiting = waiting.slice(0, index).concat(waiting.slice(index + 1))
      progress = true
    }
  }
  // What is left goes where its neighbours go: a \big| lifted into an
  // exponent is nearer the line of prose over the display than the display's
  // own line, but nothing of that prose is anywhere near it, and the r_{ij}
  // it stands against is the display's. The neighbours are asked whatever
  // their size — the rows hold only the full-size glyphs yet, and a sum in an
  // exponent has none of those beside it. And a bar built of pieces goes as
  // one: measured each from its own middle, its top went to that prose and
  // its foot stayed with the formula.
  const stacks: Glyph[][] = []
  for (const glyph of sortedBy(waiting, (a, b) => a.y < b.y)) {
    const g = rectOf(glyph)
    const at = stacks.findIndex((stack) => stack.some((other) => {
      const o = rectOf(other)
      return Math.abs(other.x - glyph.x) < glyph.size * 0.2
        && maxY(o) > minY(g) - glyph.size * 0.3 && minY(o) < maxY(g) + glyph.size * 0.3
    }))
    if (at >= 0) stacks[at].push(glyph)
    else stacks.push([glyph])
  }
  for (const stack of stacks) {
    const ink = extent(stack)
    if (laid.length === 0) { laid.push({ baseline: midY(ink), glyphs: stack }); continue }
    const nearestRow = (y: number) => minBy(indices(laid.length), (a, b) => Math.abs(laid[a].baseline - y) < Math.abs(laid[b].baseline - y))!
    const places = new Set(stack.map(place))
    const votes = new Map<number, number>()
    // A neighbour is near in height as well — the "end." of the sentence over
    // a display stood right over the display's sum — and only the nearest of
    // them vote: the three letters under a \widetilde were outvoted by the
    // line of prose under them.
    const neighbours = glyphs.filter((glyph) => {
      if (places.has(place(glyph)) || extension(glyph)) return false
      const g = rectOf(glyph)
      return maxX(g) > minX(ink) - body * 0.6 && minX(g) < maxX(ink) + body * 0.6
        && Math.abs(glyph.y - midY(ink)) < body * 1.3
    })
    const closest = minOf(neighbours.map((glyph) => Math.abs(glyph.y - midY(ink)))) ?? 0
    for (const glyph of neighbours) {
      if (!(Math.abs(glyph.y - midY(ink)) <= closest + body * 0.3)) continue
      const row = nearestRow(glyph.y)
      votes.set(row, (votes.get(row) ?? 0) + 1)
    }
    const most = maxOf([...votes.values()]) ?? 0
    const chosen = minBy([...votes.entries()].filter(([, count]) => count === most).map(([row]) => row),
      (a, b) => Math.abs(laid[a].baseline - midY(ink)) < Math.abs(laid[b].baseline - midY(ink)))
    laid[chosen ?? nearestRow(midY(ink))].glyphs.push(...stack)
  }

  // Small glyphs hang from the row they are beside, as runs: nearness in
  // height alone sent the upper limit of a displayed sum to the prose above.
  // Nor does a script stand over the ink of its line's own words: a run of
  // letters that does is another layer — the labels of a figure, level with
  // a line of its caption, came back as the caption's subscripts.
  const layeredRun = (run: Glyph[], row: { baseline: number; glyphs: Glyph[] }) => {
    const lettered = (one: Glyph) => {
      if (!(one.width > 0.05) || isAccent(one)) return false
      const drawn = spell(one)
      return drawn !== '' && chars(drawn).every((c) => isLetter(c) || isNumber(c))
    }
    const letters = run.filter(lettered)
    if (letters.length < 2) return false
    // The line's own words round the run — eight letters of the text face
    // within two ems of it, which is a passage of prose and not a formula:
    // the limits under \lim and \max, and a sub-subscript of a wide
    // exponent, stand over the formula's own few letters and are its.
    // Counted round the run, not along the row: before the columns are cut
    // apart a row holds the other column's line too, and its prose let the
    // limits under a \max be taken for a figure's. (Not the scripts already
    // hung from the line: the second row of a \substack stands under the
    // first.)
    const span = extent(run)
    const own = onOwnLine(row, body).filter((one) => one.size >= body * 0.9 && lettered(one) && !isMathFont(one)
      && chars(spell(one)).every((c) => isLetter(c))
      && maxX(rectOf(one)) > minX(span) - body * 2 && minX(rectOf(one)) < maxX(span) + body * 2)
    if (own.length < 8) return false
    const over = letters.filter((glyph) => {
      const g = rectOf(glyph)
      return own.some((other) => {
        const o = rectOf(other)
        return Math.min(maxX(o), maxX(g)) - Math.max(minX(o), minX(g)) > Math.min(other.width, glyph.width) * 0.5
      })
    })
    return over.length * 2 > letters.length
  }
  // A run of small glyphs that is a line of prose in its own right — a
  // caption, a footnote, a table set smaller than the text — is a line, not
  // a script: a dozen letters of the text face along one baseline, wide as
  // eight of them. Hung as a script, a caption's second line became the
  // subscripts of its first, letter by letter. Such a line takes scripts of
  // its own only from right beside its baseline; the next line of the
  // caption is not one.
  const isLineOfText = (run: Glyph[], level: number): boolean => {
    const letters = run.filter((one) => {
      if (!(one.width > 0.05) || isAccent(one) || isMathFont(one) || Math.abs(one.y - level) >= one.size * 0.1) return false
      const drawn = spell(one)
      return drawn !== '' && chars(drawn).every((c) => isLetter(c))
    })
    if (letters.length < 12) return false
    const size = maxOf(run.map((one) => one.size)) ?? body
    const span = extent(run)
    // Not the label of a brace, however long: "continual learning excess
    // risk" under an \underbrace is the formula's.
    if (rules.some((rule) => rule.brace === true && maxX(rule.rect) > minX(span) && minX(rule.rect) < maxX(span)
      && Math.abs(midY(rule.rect) - level) < size * 2.2)) return false
    return span.width >= size * 8
  }
  const textLines = new Set<number>()
  const unplaced: { run: Glyph[]; level: number }[] = []
  // The brace this run is the label of, if it is one: centred on the brace,
  // on its label side, within a line or two of it. (A label is centred on
  // its brace; the upper limits of the sums in the line below stand on the
  // label's level too, and are not it.)
  const braceLabelled = (span: Rect, level: number): Rule | undefined => {
    const middle = midX(span)
    return rules.find((rule) => rule.brace === true && middle > minX(rule.rect) && middle < maxX(rule.rect)
      && Math.abs(middle - midX(rule.rect)) < Math.max(span.width / 2, body)
      && (level < midY(rule.rect)) === (rule.braceLabelBelow ?? true) && Math.abs(midY(rule.rect) - level) < body * 2.5)
  }
  for (const run of smallRuns(glyphs.filter((one) => one.size < body * 0.9 && !extension(one)), body)) {
    const largest = maxOf(run.map((one) => one.size)) ?? body
    const levels = ascending(run.filter((one) => one.size >= largest * 0.95).map((one) => one.y))
    const level = levels[Math.floor(levels.length / 2)]
    const span = extent(run)
    if (isLineOfText(run, level)) {
      laid.push({ baseline: level, glyphs: [...run] })
      textLines.add(laid.length - 1)
      continue
    }
    // A brace's label goes with the row the brace braces, below — not with
    // whatever line happens to run beside it: the label under the second
    // term of (7) hung from the line that held the "(7)" and the other
    // column's sentence.
    if (braceLabelled(span, level) !== undefined) {
      unplaced.push({ run, level })
      continue
    }
    const nearest = minBy(indices(laid.length).filter((row) => beside(span, laid[row].glyphs, body) && !layeredRun(run, laid[row])
      && !(textLines.has(row) && Math.abs(laid[row].baseline - level) > largest * 0.6)),
      (a, b) => Math.abs(laid[a].baseline - level) < Math.abs(laid[b].baseline - level))
    // Close enough to hang from this row; further off, it came from the line
    // above or below, clipped by the band. An exponent with a sum in it is
    // lifted higher — TeX raises it clear of the limits hanging under the sum
    // — so a run that starts or ends against a sign that grows, or a tall
    // bracket, may stand a whole line up.
    const againstASign = (row: Glyph[]) => row.some((glyph) => {
      if (!(isDelimiter(glyph) || isBigOperator(glyph) || extension(glyph))) return false
      const g = rectOf(glyph)
      return (minX(span) >= maxX(g) - 1 && minX(span) - maxX(g) < body * 0.5)
        || (maxX(span) <= minX(g) + 1 && minX(g) - maxX(span) < body * 0.5)
    })
    if (nearest !== undefined && Math.abs(laid[nearest].baseline - level) < body * (againstASign(laid[nearest].glyphs) ? 1.0 : 0.85)) {
      laid[nearest].glyphs.push(...run)
    } else {
      unplaced.push({ run, level })
    }
  }
  // A part stacked over another small part of a row belongs to it a little
  // further off: the numerator of a fraction inside a fraction in a sentence.
  for (const { run, level } of unplaced) {
    const span = extent(run)
    const middle = midX(span)
    // The label of a brace goes with the row it braces, however far the
    // brace stands from that row — under the limits of the sums in it, a
    // line and a half down.
    const brace = braceLabelled(span, level)
    if (brace) {
      const below = brace.braceLabelBelow ?? true
      // The row it braces is the nearest on its far side with a glyph larger
      // than the label over it — not the second rows of the \substack limits
      // in it, which stand nearer still and are the label's size; a
      // denominator's row is folded into the line afterwards and takes the
      // label along. (Larger than the label, not the page's body: a
      // displayed equation set \small is braced too.)
      const labelSize = maxOf(run.map((one) => one.size)) ?? body
      const host = minBy(indices(laid.length).filter((row) => (laid[row].baseline > midY(brace.rect)) === below
        && laid[row].glyphs.some((one) => one.size >= labelSize * 1.15 && midX(rectOf(one)) > minX(brace.rect) && midX(rectOf(one)) < maxX(brace.rect))),
        (a, b) => Math.abs(laid[a].baseline - midY(brace.rect)) < Math.abs(laid[b].baseline - midY(brace.rect)))
      if (host !== undefined) { laid[host].glyphs.push(...run); continue }
    }
    // A line of small text on this run's own baseline is this run's line
    // before anything is: the numbers of a table set small stand on the line
    // of their row's name, and stacked on the row above instead they read
    // letter by letter with its numbers.
    const line = indices(laid.length).find((row) => textLines.has(row) && Math.abs(laid[row].baseline - level) < body * 0.25)
    if (line !== undefined) { laid[line].glyphs.push(...run); continue }
    // A limit is its sign's and nothing else's: the upper limits of a line of
    // a derivation set tight stood under a point from the lower limits of the
    // line above.
    const sign = signOf(span, level, laid, body)
    // Whether the row holds a script this run stands a line of script under,
    // over the same place.
    const secondRow = (row: Glyph[]) => row.some((other) => other.size < body * 0.9
      && maxX(rectOf(other)) > minX(span) && minX(rectOf(other)) < maxX(span)
      && other.y - level > other.size * 0.6 && other.y - level < other.size * 1.6)
    const stacked = minBy(indices(laid.length).filter((row) => {
      if (sign !== undefined && row !== sign) return false
      if (layeredRun(run, laid[row])) return false
      const distance = Math.abs(laid[row].baseline - level)
      return (distance < body * 1.05 && !textLines.has(row) && laid[row].glyphs.some((one) => one.size < body * 0.9
        && maxX(rectOf(one)) > minX(span) && minX(rectOf(one)) < maxX(span)))
        // The script of a tall bracket or a sign that grows, lifted as high
        // as they are tall — STIX's sum lifts its upper limit a third of an
        // em higher than Computer Modern's.
        || (distance < body * 1.5 && laid[row].glyphs.some((glyph) => (isDelimiter(glyph) || isBigOperator(glyph) || extension(glyph))
          && minX(span) >= maxX(rectOf(glyph)) - 1 && minX(span) - maxX(rectOf(glyph)) < body * 0.5))
        // The second row of a \substack beside a sum in a sentence, a line of
        // script under the first.
        || (distance < body * 1.6 && level < laid[row].baseline && secondRow(laid[row].glyphs)
          && laid[row].glyphs.some((glyph) => isBigOperator(glyph)
            && minX(span) >= maxX(rectOf(glyph)) - 1 && minX(span) - maxX(rectOf(glyph)) < body * 1.5))
        // Over a bar the row has something under, or under one it has
        // something over.
        || (distance < body * 1.6 && rules.some((rule) => {
          if (rule.brace === true || !(middle > minX(rule.rect) && middle < maxX(rule.rect))) return false
          const over = level > midY(rule.rect)
          return laid[row].glyphs.some((one) => midX(rectOf(one)) > minX(rule.rect) && midX(rectOf(one)) < maxX(rule.rect)
            && (one.y > midY(rule.rect)) !== over && Math.abs(one.y - midY(rule.rect)) < body * 1.2)
        }))
    }), (a, b) => Math.abs(laid[a].baseline - level) < Math.abs(laid[b].baseline - level))
    if (stacked !== undefined) {
      laid[stacked].glyphs.push(...run)
    } else {
      // Nothing to hang from, but a row on the same line: the limits under
      // two sums side by side are one row — and the numbers of a table set
      // small stand on the line of their row's name.
      const at = laid.findIndex((row) => Math.abs(row.baseline - level) < body * 0.25)
      if (at >= 0) laid[at].glyphs.push(...run)
      else laid.push({ baseline: level, glyphs: run })
    }
  }

  const result = folded(sortedBy(laid, (a, b) => a.baseline > b.baseline), body, rules)
    .map((row) => sortedBy(row.glyphs, (a, b) => a.x < b.x))
  return gatheringBrackets(splitAtGutters(result, glyphs))
}

/** A bracket built from pieces belongs on its formula's line. Each piece goes
 *  to the row its own ink runs through, and a line of the other column can
 *  run through one: the top of the tall "(" round a displayed sum stood level
 *  with a line of prose across the gutter and went to it. Cut at the gutter,
 *  it was a line of its own — "() ()" — and the bracket's foot, left below the
 *  formula's line without it, was read as the subscript of the W before it. A
 *  row that holds nothing but pieces of brackets gives each of them to the row
 *  the rest of its bracket is in. Nothing else moves: the pieces of a brace
 *  are meant to be spread over the rows of its cases. */
function gatheringBrackets(given: Glyph[][]): Glyph[][] {
  const strays = (row: Glyph[]) => row.length > 0 && row.every(isPiece)
  if (!given.some(strays)) return given
  const touches = (one: Glyph, other: Glyph) => isPiece(other) && Math.abs(one.x - other.x) < one.size * 0.2
    && maxY(rectOf(other)) > minY(rectOf(one)) - one.size * 0.3 && minY(rectOf(other)) < maxY(rectOf(one)) + one.size * 0.3
  const rows = given.map((row) => [...row])
  let moved = true
  while (moved) {
    moved = false
    for (let index = 0; index < rows.length; index += 1) {
      if (!strays(rows[index])) continue
      const kept: Glyph[] = []
      for (const piece of rows[index]) {
        // The nearest row, of those not made of pieces alone, that holds
        // another piece of its bracket.
        const gap = (row: number) => minOf(rows[row].filter((one) => touches(piece, one)).map((one) =>
          Math.max(minY(rectOf(one)) - maxY(rectOf(piece)), minY(rectOf(piece)) - maxY(rectOf(one)), 0))) ?? Number.MAX_VALUE
        const home = minBy(indices(rows.length).filter((other) =>
          other !== index && !strays(rows[other]) && rows[other].some((one) => touches(piece, one))), (a, b) => gap(a) < gap(b))
        if (home !== undefined) {
          rows[home].push(piece)
          rows[home] = sortedBy(rows[home], (a, b) => a.x < b.x)
          moved = true
        } else {
          kept.push(piece)
        }
      }
      rows[index] = kept
    }
  }
  return rows.filter((row) => row.length > 0)
}

/** Small glyphs gathered into the runs they were set in: touching, at much
 *  the same height. */
function smallRuns(glyphs: Glyph[], body: number): Glyph[][] {
  if (glyphs.length === 0) return []
  const ordered = glyphs.map((glyph, offset) => ({ glyph, offset }))
    .sort((a, b) => (a.glyph.y !== b.glyph.y ? (a.glyph.y > b.glyph.y ? -1 : 1) : a.offset - b.offset))
    .map((one) => one.glyph)
  const parent = indices(ordered.length)
  const root = (index: number) => {
    let at = index
    while (parent[at] !== at) {
      parent[at] = parent[parent[at]]
      at = parent[at]
    }
    return at
  }
  for (let index = 0; index < ordered.length; index += 1) {
    let other = index + 1
    while (other < ordered.length && ordered[index].y - ordered[other].y < body * 0.55) {
      const one = rectOf(ordered[index])
      const two = rectOf(ordered[other])
      const gap = Math.max(minX(one), minX(two)) - Math.min(maxX(one), maxX(two))
      if (gap < body * 0.5) {
        const a = root(index)
        const b = root(other)
        if (a !== b) parent[Math.max(a, b)] = Math.min(a, b)
      }
      other += 1
    }
  }
  const runs = new Map<number, Glyph[]>()
  const order: number[] = []
  for (let index = 0; index < ordered.length; index += 1) {
    const key = root(index)
    if (!runs.has(key)) {
      order.push(key)
      runs.set(key, [])
    }
    runs.get(key)!.push(ordered[index])
  }
  return order.map((key) => runs.get(key)!)
}

/** Whether a run is beside a row: some glyph of the row is over it, under
 *  it, or within a little over half an em of it. */
function beside(span: Rect, row: Glyph[], body: number): boolean {
  return row.some((one) => maxX(rectOf(one)) > minX(span) - body * 0.6 && minX(rectOf(one)) < maxX(span) + body * 0.6)
}

/** Rows cut apart at the page's gutters — a strip with no ink in it, top to
 *  bottom. A row that steps over the gutter is left whole. */
function splitAtGutters(laid: Glyph[][], glyphs: Glyph[]): Glyph[][] {
  const found = gutters(laid, glyphs)
  if (found.length === 0) return laid
  const result: Glyph[][] = []
  for (const row of laid) {
    const parts: Glyph[][] = []
    let rest = row
    for (const gutter of found) {
      if (rest.some((one) => minX(rectOf(one)) < gutter && maxX(rectOf(one)) > gutter)) continue
      const before = rest.filter((one) => maxX(rectOf(one)) <= gutter)
      const after = rest.filter((one) => minX(rectOf(one)) >= gutter)
      if (before.length === 0 || after.length === 0) continue
      parts.push(before)
      rest = after
    }
    parts.push(rest)
    result.push(...parts.filter((part) => part.length > 0))
  }
  return result
}

/** The x positions where the page has a strip of nothing running down it,
 *  judged against the page's own density. */
function gutters(laid: Glyph[][], glyphs: Glyph[]): number[] {
  if (!(laid.length >= 10 && glyphs.length > 0)) return []
  const left = minOf(glyphs.map((one) => minX(rectOf(one)))) ?? 0
  const right = maxOf(glyphs.map((one) => maxX(rectOf(one)))) ?? 0
  if (!(right - left > 200)) return []
  // A gutter is not a margin, so the edges of the text are left out.
  const from = left + (right - left) * 0.15
  const to = right - (right - left) * 0.15
  const step = 2
  const samples: { x: number; crossings: number }[] = []
  let x = from
  while (x <= to) {
    const at = x
    samples.push({ x: at, crossings: laid.reduce((n, row) => n + (row.some((one) => minX(rectOf(one)) < at && maxX(rectOf(one)) > at) ? 1 : 0), 0) })
    x += step
  }
  if (!(samples.length > 8)) return []
  const ordered = ascending(samples.map((sample) => sample.crossings))
  const median = ordered[Math.floor(ordered.length / 2)]
  // A page with little on it has no gutter worth finding.
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

/**
 * Rows that are only part of a line, folded into the line they belong to. A
 * numerator sits nearer the line above than the line it is part of; what
 * settles it is that type never overlaps — the line a fragment belongs to is
 * the one with no ink at those x positions.
 */
/**
 * Whether a word is a name applied to what follows it (`appliesTo`): letters
 * set upright at the line's size, then a bracket right after them — in the
 * word, "Exp(1)", or opening the next one a thin space off.
 */
export function appliesTo(word: Glyph[], next: Glyph[] | null, body: number): boolean {
  const ordered = sortedBy(word, (a, b) => minX(rectOf(a)) < minX(rectOf(b)))
  let count = 0
  while (count < ordered.length && ordered[count].size >= body * 0.92 && isUprightLetter(ordered[count])) count += 1
  if (count < 2) return false
  const last = ordered[count - 1]
  // On one line: a label set on its side in a figure is no name.
  if (!ordered.slice(0, count).every((one) => Math.abs(one.y - last.y) < last.size * 0.05)) return false
  // The bracket, not a piece of it at the same place that spells nothing.
  const opener = (glyphs: Glyph[]): Glyph | undefined => {
    const start = minOf(glyphs.map((one) => minX(rectOf(one))))
    if (start === undefined) return undefined
    return glyphs.find((one) => minX(rectOf(one)) < start + 0.5 && opening(one) !== null)
  }
  if (count < ordered.length) {
    const after = opener(ordered.slice(count))
    return after !== undefined && minX(rectOf(after)) - maxX(rectOf(last)) < body * 0.2
  }
  if (next === null) return false
  const found = opener(next)
  if (found === undefined) return false
  // A bracket from an extension font carries a little room of its own.
  return minX(rectOf(found)) - maxX(rectOf(last)) < body * (extension(found) ? 0.3 : 0.2)
}

/** The row whose big operator a run of small glyphs is a limit of: centred
 *  over or under the sign, up to a line and a half over its row or a line and
 *  a bit under. */
function signOf(span: Rect, level: number, rows: { baseline: number; glyphs: Glyph[] }[], body: number): number | undefined {
  return minBy(indices(rows.length).filter((row) => {
    const lift = level - rows[row].baseline
    if (!((lift > 0 && lift < body * 1.6) || (lift < 0 && -lift < body * 1.4))) return false
    return rows[row].glyphs.some((glyph) => {
      const g = rectOf(glyph)
      return isBigOperator(glyph) && maxX(g) > minX(span) && minX(g) < maxX(span)
        && Math.abs(midX(span) - midX(g)) < Math.max(span.width, g.width) * 0.5 + 1
    })
  }), (a, b) => Math.abs(rows[a].baseline - level) < Math.abs(rows[b].baseline - level))
}

function folded(input: { baseline: number; glyphs: Glyph[] }[], body: number, rules: Rule[] = []): { baseline: number; glyphs: Glyph[] }[] {
  if (input.length <= 1) return input
  const laid = input.map((row) => ({ baseline: row.baseline, glyphs: [...row.glyphs] }))
  let index = 0
  while (index < laid.length) {
    const row = laid[index]
    const span = extent(row.glyphs)
    const neighbours = [index - 1, index + 1].filter((at) => at >= 0 && at < laid.length)
    // A row of limits folds into its sign's line or into none.
    const limitOf = row.glyphs.every((one) => one.size < body * 0.8) ? signOf(span, row.baseline, laid, body) : undefined
    const host = minBy(neighbours.filter((other) => {
      if (limitOf !== undefined && other !== limitOf) return false
      const theirs = extent(laid[other].glyphs)
      // The pieces of a tall bracket stand where the bracket does, over and
      // under the line's own: that is no second line.
      const own = row.glyphs.filter((one) => !isPiece(one) && barToken(one) === null && spell(one) !== '')
      // Only a fragment folds, and only into a line it is part of — measured
      // from the row, or from where the line's own glyphs stand.
      const distance = Math.min(Math.abs(laid[other].baseline - row.baseline),
        Math.abs(context(laid[other].glyphs).baseline - row.baseline))
      // Over or under what the line already folded in — the numerator over a
      // denominator still looking for a home — only with a bar between them:
      // without one the two are two lines, and folded they read letter for
      // letter through each other.
      const foldedIn = laid[other].glyphs.filter((one) => Math.abs(one.y - laid[other].baseline) >= body * 0.25)
      const barred = !collides(own, foldedIn) || rules.some((rule) => {
        const [low, high] = row.baseline < laid[other].baseline
          ? [row.baseline, maxOf(foldedIn.map((one) => one.y)) ?? laid[other].baseline]
          : [minOf(foldedIn.map((one) => one.y)) ?? laid[other].baseline, row.baseline]
        return midY(rule.rect) > low && midY(rule.rect) < high
          && maxX(rule.rect) > minX(span) && minX(rule.rect) < maxX(span)
      })
      return span.width < theirs.width * 0.75
        && distance < body * 0.9
        && beside(span, laid[other].glyphs, body)
        && !collides(own, onOwnLine(laid[other], body))
        && barred
    }), (a, b) => Math.abs(laid[a].baseline - row.baseline) < Math.abs(laid[b].baseline - row.baseline))
    if (host === undefined) { index += 1; continue }
    laid[host].glyphs.push(...row.glyphs)
    laid.splice(index, 1)
    // The host may itself be a fragment of the line beyond it.
    index = Math.min(host, index)
  }
  return laid
}

/** The glyphs a row was set on its own baseline — not the fragments folded into it. */
function onOwnLine(row: { baseline: number; glyphs: Glyph[] }, body: number): Glyph[] {
  return row.glyphs.filter((one) => Math.abs(one.y - row.baseline) < body * 0.25)
}

/** Whether two rows have ink at the same x — a count, not a single hit: one
 *  or two of those is kerning, most of a row is another line. */
function collides(one: Glyph[], other: Glyph[]): boolean {
  if (one.length === 0 || other.length === 0) return false
  const theirs = sortedBy(other.map((g) => [minX(rectOf(g)), maxX(rectOf(g))] as const), (a, b) => a[0] < b[0])
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

/** One word of a row as it will be written: mathematics or not, and whether
 *  it follows the one before without a space. */
interface Word { isMath: boolean; text: string; tight: boolean }

/**
 * One row of prose. Words are rebuilt from what the page drew; a word with a
 * glyph this cannot read is taken from the page's text instead — a whole
 * word, which is contiguous there, where a single glyph is matched by place.
 */
function read(row: Glyph[], rules: Rule[], characters: PageCharacter[], text: string): string {
  const ctx = context(row)
  // Only this line's characters are worth searching.
  const band = extent(row)
  const near = characters.filter((one) => maxY(one.rect) > minY(band) && minY(one.rect) < maxY(band))
  const all = keepingRadicands(words(row, ctx.bodySize), rules)
  // A name set upright a thin space before the bracket of the formula it is
  // applied to is the formula's: "Laplace $\bigl(E\bigr)$" is
  // $\mathrm{Laplace}\bigl(E\bigr)$.
  let joined = 0
  while (joined + 1 < all.length) {
    if (!isFormula(all[joined], joined, all, ctx, rules) && isFormula(all[joined + 1], joined + 1, all, ctx, rules)
      && appliesTo(all[joined], all[joined + 1], ctx.bodySize)) {
      all[joined + 1] = [...all[joined], ...all[joined + 1]]
      all.splice(joined, 1)
      continue
    }
    joined += 1
  }
  const pieces: Word[] = []
  const prose = (word: Glyph[], tight = false): Word => {
    const spelled = word.map(spell)
    if (spelled.some((one) => one === '')) {
      const borrowed = spellingFrom(word, near, text)
      if (borrowed !== null && agrees(borrowed, spelled)) return { isMath: false, text: borrowed, tight }
    }
    return { isMath: false, text: composed(spelled.join('')), tight }
  }
  const formulas = all.map((word, position) => isFormula(word, position, all, ctx, rules))
  all.forEach((word, position) => {
    if (!formulas[position]) {
      pieces.push(prose(word))
      return
    }
    // The text face's punctuation after a formula ends the sentence — unless
    // a formula follows it across no more than a thin space.
    const next = position + 1
    const continued = next < all.length && formulas[next]
      && (minOf(all[next].map((one) => minX(rectOf(one)))) ?? 0) - (maxOf(word.map((one) => maxX(rectOf(one)))) ?? 0) < ctx.bodySize * 0.25
    const { lead, core, trail } = continued ? { lead: [] as Glyph[], core: word, trail: [] as Glyph[] } : peeled(word)
    if (lead.length > 0) pieces.push(prose(lead))
    // Left out when most of it cannot be read (see `pieces`).
    const unread = core.filter(isUnreadable).length
    if (unread * 4 > core.length) {
      skippedFormulas += 1
      return
    }
    const written = latexOf(core, rules, ctx)
    if (written !== '') pieces.push({ isMath: true, text: written, tight: lead.length > 0 })
    if (trail.length > 0) pieces.push(prose(trail, true))
  })
  return assemble(unbracketed(merged(pieces)))
}

/** Words put back together under the roof of a radical: TeX spaces the "+"
 *  of \sqrt{x^2+y^2} as it would anywhere. */
function keepingRadicands(all: Glyph[][], rules: Rule[]): Glyph[][] {
  const roofs = rules.filter((rule) => all.some((word) => word.some((glyph) => isRadical(glyph)
    && Math.abs(minX(rule.rect) - maxX(rectOf(glyph))) < Math.max(1, glyph.size * 0.15))))
  if (roofs.length === 0) return all
  const result: Glyph[][] = []
  for (const word of all) {
    const last = result[result.length - 1]
    const roof = last === undefined ? undefined : roofs.find((one) =>
      last.some((glyph) => isRadical(glyph) && maxX(rectOf(glyph)) <= minX(one.rect) + 1)
      && word.some((glyph) => midX(rectOf(glyph)) > minX(one.rect) && midX(rectOf(glyph)) < maxX(one.rect)))
    if (last !== undefined && roof !== undefined) result[result.length - 1] = [...last, ...word]
    else result.push(word)
  }
  return result
}

/**
 * Whether a word of a row is mathematics: one with a glyph from a maths font
 * in it is, and one with a subscript Word set on the line, and a name with a
 * script on it. On a page that sets its variables in the text italic, so is
 * an italic letter with a script, and one standing alone between words that
 * are not in italics — "for each *i*" — which an emphasised sentence is not.
 */
function isFormula(word: Glyph[], position: number, all: Glyph[][], ctx: Context, rules: Rule[]): boolean {
  const body = ctx.bodySize
  if (word.some(isMathFont) || hasWordSubscript(word, body)) return true
  // Something set small right over or under a glyph at the line's size is a
  // formula whatever its face: a sentence never stacks its letters, and
  // \overset{\text{def}}{=} is all roman.
  if (word.some((small) => small.size < body * 0.92 && word.some((full) => full.size >= body * 0.92
    && Math.min(maxX(rectOf(small)), maxX(rectOf(full))) - Math.max(minX(rectOf(small)), minX(rectOf(full))) > small.width * 0.5
    && Math.abs(small.y - full.y) > body * 0.35))) return true
  const scriptedHere = (one: Glyph) => one.size < body * 0.92 && Math.abs(one.y - ctx.baseline) > body * 0.08
  const letters = word.filter((one) => one.size >= body * 0.92)
  const lead: Glyph[] = []
  for (const one of letters) {
    if (!isUprightLetter(one)) break
    lead.push(one)
  }
  if (lead.length > 0 && isOperatorName(lead.map(spell).join('')) && word.some(scriptedHere)) return true
  if (!italicVariables() || !word.some(isItalicLetter)) return false
  const full = word.filter((one) => one.size >= body * 0.92 && !isAccent(one))
  // Every run of italic letters in it is a variable or two, not a word.
  if (longestItalicRun(full) > 2) return false
  const scripted = word.some(scriptedHere)
  if (scripted && full.length <= 3) return true
  // Over and under a bar: a fraction.
  if (rules.some((rule) => word.some((one) => midX(rectOf(one)) > minX(rule.rect) && midX(rectOf(one)) < maxX(rule.rect) && one.y > midY(rule.rect))
    && word.some((one) => midX(rectOf(one)) > minX(rule.rect) && midX(rectOf(one)) < maxX(rule.rect) && one.y < midY(rule.rect)))) return true
  const marks = full.map(spell)
  if (marks.some((one) => ['(', ')', '[', ']', '|', '=', '+', ',', '\\{', '\\}'].includes(one))) return true
  // A variable or two standing alone between words that are not in italics.
  if (!(full.length <= 2 && full.every((one) => isLetter(firstChar(spell(one)) ?? ''))
    && !COMMON_SHORT_WORDS.has(marks.join('').toLowerCase()))) return false
  // Stressed: a word of three italic letters or more, or a short English one.
  const emphasised = (at: number) => {
    if (at < 0 || at >= all.length) return false
    const around = all[at].filter((one) => one.size >= body * 0.92)
    if (longestItalicRun(around) >= 3) return true
    const spelled = around.map(spell).join('').toLowerCase()
    return around.every(isItalicLetter) && COMMON_SHORT_WORDS.has(spelled)
  }
  return !emphasised(position - 1) && !emphasised(position + 1)
}

/** The longest run of italic letters in a row of glyphs. */
function longestItalicRun(glyphs: Glyph[]): number {
  let longest = 0
  let run = 0
  for (const glyph of glyphs) {
    run = isItalicLetter(glyph) ? run + 1 : 0
    longest = Math.max(longest, run)
  }
  return longest
}

/** English words of two letters, which a paper sets in italics to stress
 *  them and never means as a product of two variables. */
const COMMON_SHORT_WORDS = new Set([
  'an', 'as', 'at', 'be', 'by', 'do', 'et', 'al', 'go', 'he', 'if', 'in', 'is', 'it',
  'me', 'my', 'no', 'of', 'on', 'or', 'so', 'to', 'up', 'us', 'we', 'vs', 'cf', 'eg', 'ie',
])

const SENTENCE_MARKS = ['.', ',', ';', ':']

/** A formula word with the sentence's punctuation taken off its end: the
 *  full stops and commas the text face set after it. */
function peeled(word: Glyph[]): { lead: Glyph[]; core: Glyph[]; trail: Glyph[] } {
  let core = word
  let trail: Glyph[] = []
  const textual = (glyph: Glyph, marks: string[]) => !isMathFont(glyph) && marks.includes(canon(spell(glyph)))
  // Only at the line's size: the full stop of "a.s." over an arrow is the label's.
  const largest = maxOf(word.map((one) => one.size)) ?? 0
  while (core.length > 1 && textual(core[core.length - 1], SENTENCE_MARKS) && core[core.length - 1].size >= largest * 0.92) {
    trail.unshift(core[core.length - 1])
    core = core.slice(0, -1)
  }
  // The sentence's apostrophe and the letter after it, in the text face:
  // "Yᵢ’s" is $Y_i$'s, not $Y_i'\mathrm{s}$.
  let apostrophe = -1
  for (let at = core.length - 1; at >= 0; at -= 1) {
    if (textual(core[at], ["'", '\u2019'])) { apostrophe = at; break }
  }
  if (apostrophe > 0 && core.slice(0, apostrophe).some(isMathFont)) {
    const after = core.slice(apostrophe + 1)
    if (after.length <= 2 && after.every((glyph) => !isMathFont(glyph) && spell(glyph) !== ''
      && chars(spell(glyph)).every(isLetter))) {
      trail = [...core.slice(apostrophe), ...trail]
      core = core.slice(0, apostrophe)
    }
  }
  return { lead: [], core, trail }
}

/**
 * The size a line is mostly set in, and where its baseline runs: the largest
 * size on the row, leaving out the signs that grow to fit and the pieces of a
 * tall bracket that draw nothing — nothing on a line is set larger than it.
 */
function context(row: Glyph[]): Context {
  const ordinary = row.filter((one) => !extension(one) && !isBigOperator(one) && !isDelimiter(one) && spell(one) !== '')
  const body = maxOf(ordinary.map((one) => one.size))
    ?? maxOf(row.filter((one) => !extension(one)).map((one) => one.size)) ?? maxOf(row.map((one) => one.size)) ?? 10
  const full = ordinary.filter((one) => one.size >= body * 0.92)
  const sample = ascending((full.length === 0 ? row : full).map((one) => one.y))
  return { bodySize: body, baseline: sample[Math.floor(sample.length / 2)] }
}

/** The relations and operators a formula is held together by. */
const JOINERS = new Set([
  '=', '+', '-', '<', '>', ':', '/', '\\leq', '\\geq', '\\neq', '\\approx',
  '\\sim', '\\equiv', '\\to', '\\in', '\\cdot', '\\times', '\\pm',
  '\\backslash', '\\setminus',
])

/** What a formula can end with and still be waiting for more. */
const OPEN_ENDS = [
  '=', '+', '-', '<', '>', ':', '/', '\\leq', '\\geq', '\\neq', '\\approx', '\\sim',
  '\\simeq', '\\equiv', '\\to', '\\rightarrow', '\\leftarrow', '\\mapsto', '\\in',
  '\\notin', '\\cdot', '\\times', '\\pm', '\\mp', '\\div', '\\ll', '\\gg',
  '\\propto', '\\le', '\\ge', '\\ne', '\\ast', '\\circ', '\\Rightarrow',
  '\\Leftarrow', '\\Leftrightarrow', '\\coloneqq',
]

/** A number, as ICU reads `^…$`: a line break may end it. */
const isNumberWord = (text: string) => /^[0-9]+([.,][0-9]+)?(?:\r\n|[\n\v\f\r\u0085\u2028\u2029])?$/.test(text)
const endsOpen = (text: string) => { const trimmed = trimWhitespace(text); return OPEN_ENDS.some((end) => trimmed.endsWith(end)) }
const startsOpen = (text: string) => { const trimmed = trimWhitespace(text); return OPEN_ENDS.some((end) => trimmed.startsWith(end)) }

/** How many brackets a formula leaves open. */
function balance(text: string): number {
  let open = 0
  for (const character of chars(text)) {
    if (character === '(' || character === '[') open += 1
    else if (character === ')' || character === ']') open -= 1
  }
  return open
}

/**
 * A formula put back together where the spaces cut it up: TeX sets thin
 * spaces round a relation that look like word spaces, a roman name beside a
 * formula is part of it, and so is a number a relation in it is waiting for.
 */
function merged(input: Word[]): Word[] {
  const pieces = input.map((piece) => ({ ...piece }))
  for (let index = 0; index < pieces.length; index += 1) {
    if (pieces[index].isMath) continue
    const word = pieces[index].text
    const before = index > 0 && pieces[index - 1].isMath
    const after = index + 1 < pieces.length && pieces[index + 1].isMath
    // "x_1, . . . , x_n": the dots, and the comma before them.
    if (count(word) >= 2 && /^\.+$/.test(word)) {
      const comma = index > 1 && pieces[index - 1].text === ',' && pieces[index - 2].isMath
      if (before || after || comma) {
        pieces[index] = { isMath: true, text: '\\ldots', tight: false }
        if (comma) pieces[index - 1].isMath = true
      }
      continue
    }
    if (isOperatorName(word) && (before || after) && !pieces[index].tight) {
      pieces[index] = { isMath: true, text: '\\' + word, tight: false }
    } else if (isNumberWord(word) && !pieces[index].tight) {
      const joined = index >= 2 && !pieces[index - 1].isMath && JOINERS.has(pieces[index - 1].text) && pieces[index - 2].isMath
      const joining = index + 2 < pieces.length && !pieces[index + 1].isMath && JOINERS.has(pieces[index + 1].text) && pieces[index + 2].isMath
      if ((before && endsOpen(pieces[index - 1].text)) || (after && startsOpen(pieces[index + 1].text)) || joined || joining) {
        pieces[index] = { isMath: true, text: word, tight: false }
      }
    }
  }
  // A bracket the formula opened and the sentence's face closed is the formula's.
  for (let index = 0; index < pieces.length; index += 1) {
    if (pieces[index].isMath) continue
    const word = pieces[index].text
    if ((word === ')' || word === ']') && index > 0 && pieces[index - 1].isMath && balance(pieces[index - 1].text) > 0) {
      pieces[index].isMath = true
      pieces[index].tight = false
    } else if ((word === '(' || word === '[') && index + 1 < pieces.length && pieces[index + 1].isMath
      && balance(pieces[index + 1].text) < 0) {
      pieces[index].isMath = true
      pieces[index + 1].tight = false
    }
  }
  const result: Word[] = []
  for (const piece of pieces) {
    const last = result[result.length - 1]
    if (piece.isMath && !piece.tight && result.length >= 2 && JOINERS.has(last.text) && !last.tight
      && result[result.length - 2].isMath) {
      const joiner = result.pop()!.text
      const first = result.pop()!
      result.push({ ...first, text: `${first.text} ${joiner} ${piece.text}` })
    } else if (piece.isMath && !piece.tight && last !== undefined && last.isMath) {
      result.pop()
      result.push({ ...last, text: last.text + spacer(last.text, piece.text) + piece.text })
    } else {
      result.push(piece)
    }
  }
  return result
}

/** Whether two halves of one formula need a space between them. */
function spacer(first: string, second: string): string {
  const last = lastChar(first)
  if (last !== undefined && ['(', '[', '{', '_', '^'].includes(canon(last))) return ''
  const next = firstChar(second)
  if (next !== undefined && [',', ';', ':', '.', ')', ']', '}', '!', '?'].includes(canon(next))) return ''
  return ' '
}

/** A bracket the sentence opened or closed round a formula, given back to
 *  the sentence: "($x$, $y$)", not "$(x$, $y)$". */
function unbracketed(input: Word[]): Word[] {
  const result: Word[] = []
  for (const original of input) {
    if (!original.isMath) { result.push(original); continue }
    const piece = { ...original }
    const trailing: Word[] = []
    for (;;) {
      const last = lastChar(piece.text)
      if (!(last === ')' || last === ']') || !(balance(piece.text) < 0) || !(count(piece.text) > 1)) break
      piece.text = piece.text.slice(0, -1)
      trailing.unshift({ isMath: false, text: last, tight: true })
    }
    for (;;) {
      const first = firstChar(piece.text)
      if (!(first === '(' || first === '[') || !(balance(piece.text) > 0) || !(count(piece.text) > 1)) break
      piece.text = piece.text.slice(1)
      result.push({ isMath: false, text: first, tight: piece.tight })
      piece.tight = true
    }
    piece.text = trimWhitespace(piece.text)
    result.push(piece)
    result.push(...trailing)
  }
  return result
}

function assemble(pieces: Word[]): string {
  let out = ''
  for (const piece of pieces) {
    const text = piece.isMath ? `$${piece.text}$` : piece.text
    if (out !== '' && !piece.tight) out += ' '
    out += text
  }
  return out
}

/** The marks a text font draws on their own, and what they are as combining
 *  characters. */
const MARKS: Record<string, string> = {
  '\u00A8': '\u0308', '\u02C6': '\u0302', '\u02DC': '\u0303',
  '\u00AF': '\u0304', '\u02D9': '\u0307', '\u02C7': '\u030C',
  '\u00B4': '\u0301', '\u02DA': '\u030A', '\u02DD': '\u030B',
  '\u00B8': '\u0327', '\u02D8': '\u0306',
}
const markOf = (character: string) => {
  const key = canon(character)
  return Object.prototype.hasOwnProperty.call(MARKS, key) ? MARKS[key] : undefined
}

/** TeX sets an accent and its letter as two glyphs, the mark first; put back
 *  together the way it looks, "na¨ıve" is "naïve". */
function composed(text: string): string {
  const all = chars(text)
  if (!all.some((one) => markOf(one) !== undefined)) return text
  let result = ''
  let pending: string | null = null
  for (const character of all) {
    const mark = markOf(character)
    if (mark !== undefined) {
      pending = mark
      continue
    }
    // The dot came off the "i" to make room for the accent.
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

/** A row split where the spaces are. */
function words(row: Glyph[], body: number): Glyph[][] {
  const out: Glyph[][] = []
  let spaced = false
  for (const glyph of row) {
    // Word and every "Save as PDF" draw their spaces as glyphs.
    if (isSpace(glyph)) {
      spaced = true
      continue
    }
    const word = out[out.length - 1]
    // Dots in a row are one thing, however TeX spaced them.
    if (word !== undefined && !spaced && spell(glyph) === '.' && word.every((one) => spell(one) === '.')
      && minX(rectOf(glyph)) - maxX(rectOf(word[word.length - 1])) < body * 0.3) {
      word.push(glyph)
      continue
    }
    // The gap is from the end of everything so far: the root of \sqrt[3]{x}
    // sits inside the radical sign.
    const last = word === undefined ? undefined
      : maxBy(word.filter((one) => one.width > 0.05), (a, b) => maxX(rectOf(a)) < maxX(rectOf(b))) ?? word[word.length - 1]
    if (word !== undefined && last !== undefined && !spaced && !isGap(last, glyph, body)) word.push(glyph)
    else out.push([glyph])
    spaced = false
  }
  return out
}

/** Whether a word borrowed from the page's text spells the letters the
 *  glyphs could read, in order — the text and its boxes do not always agree. */
function agrees(borrowed: string, spelled: string[]): boolean {
  const keep = (text: string) => chars(text).filter((one) => isLetter(one) || isNumber(one)).map(canon)
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

/** What the page's text says the word is: the characters its glyphs sit on,
 *  in the page's own order. */
function spellingFrom(word: Glyph[], characters: PageCharacter[], text: string): string | null {
  const span = extent(word)
  const covered = characters.filter((one) => {
    const overlap = intersection(one.rect, span)
    if (isNull(overlap)) return false
    return overlap.width * overlap.height > one.rect.width * one.rect.height * 0.5
  })
  const from = minOf(covered.map((one) => one.index))
  const to = maxOf(covered.map((one) => one.index))
  if (from === undefined || to === undefined || !(to >= from && to < text.length && to - from < 64)) return null
  // The page's text is cut by character, the way the Mac cuts it (`NSString`
  // by the index of a `Character`), and half a surrogate pair becomes U+FFFD
  // as it does when Swift makes the piece a `String`.
  const spelled = trimWhitespaceAndNewlines(wellFormed(text.slice(from, to + 1)))
  return spelled === '' ? null : spelled
}

function wellFormed(text: string): string {
  return text.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, '\uFFFD')
}

/**
 * A gap wide enough to be a word space rather than the space inside a
 * formula. In prose almost any gap is a space; a formula is full of thin
 * spaces that are not, so where mathematics is involved it takes a wider one.
 */
function isGap(first: Glyph, second: Glyph, body: number): boolean {
  const width = minX(rectOf(second)) - maxX(rectOf(first))
  if (!(width > 0)) return false
  // A formula's glyph beside a word of the sentence's is spaced as words are.
  const mathematical = isMathFont(first) || isMathFont(second)
  const small = Math.min(first.size, second.size) < body * 0.92
  if (mathematical && !small
    && ((!isMathFont(first) && isProseMark(first)) || (!isMathFont(second) && isProseMark(second)))) {
    return width > body * 0.12
  }
  // Anything set smaller than the line is a script, and a script has no words.
  const formula = Math.min(first.size, second.size) < body * 0.92
    || isMathFont(first) || isMathFont(second)
    || (italicVariables() && ((isItalicLetter(first) && isFormulaMark(second)) || (isFormulaMark(first) && isItalicLetter(second))))
  // Against a glyph that grows — a radical, the pieces of a tall bar — TeX
  // sets a thick space and the glyph's own side bearing, which together pass
  // for a narrow word space: a \big| after a root, and a root after a sum's
  // limits, began a new word, and the exponent they were in ended there.
  // (Not against a word of the sentence: mathptmx's ∫ is a point smaller
  // than the line, and "Inline:" is still a word before it.)
  const prose = (!isMathFont(first) && isProseMark(first)) || (!isMathFont(second) && isProseMark(second))
  if (formula && !prose && (extension(first) || extension(second))) return width > body * 0.32
  return width > body * (formula ? 0.22 : 0.09)
}

/** What a word of a sentence begins and ends with: a Latin letter, and the
 *  colon or semicolon after one. */
function isProseMark(glyph: Glyph): boolean {
  const drawn = canon(spell(glyph))
  if (drawn === ':' || drawn === ';') return true
  return drawn !== '' && /^[A-Za-z]+$/.test(drawn) && !(italicVariables() && isItalicLetter(glyph))
}

/** What a formula set in a text face is held together by. */
function isFormulaMark(glyph: Glyph): boolean {
  return isItalicLetter(glyph) || isMathFont(glyph) || ['(', ')', '[', ']', '+', '=', '|', ','].includes(spell(glyph))
}

// MARK: - Pages

/** Whether a glyph belongs to a formula by its face alone. */
function isMathish(glyph: Glyph): boolean {
  return isMathFont(glyph) || (italicVariables() && isItalicLetter(glyph))
}

/** The maths fonts that carry only Greek, because the paper sets its Latin
 *  variables in the text face's italic. */
const GREEK_ONLY = [
  'RTXMI', 'RTXBMI', 'RPXMI', 'RPXBMI', 'STANDARDSYML-SLANT', 'PAZOMATH-ITALIC',
  'PAZOMATH-BOLDITALIC', 'FOURIER-MATH-LETTERS-ITALIC', 'FOURIER-MATH-LETTERS-BOLD-ITALIC',
]

/**
 * What one page says about where a paper keeps its variables: whether a
 * maths font on it draws a Latin letter (then the maths italic is the
 * paper's own), and whether anything on it says the text italic is used
 * for mathematics — Greek from a font that carries only the Greek for such a
 * paper, or an italic letter with a script on it.
 */
export function italicEvidence(glyphs: Glyph[]): ItalicEvidence {
  let evidence = false
  for (const glyph of glyphs) {
    if (!isMathFont(glyph)) continue
    if (/^[A-Za-z]$/.test(spell(glyph))) return { ownLetters: true, evidence: false }
    const upper = family(glyph)
    if (GREEK_ONLY.some((prefix) => upper.startsWith(prefix))) evidence = true
  }
  if (evidence) return { ownLetters: false, evidence: true }
  const small = sortedBy(glyphs.filter((one) => !extension(one)), (a, b) => minX(rectOf(a)) < minX(rectOf(b)))
  for (const letter of glyphs) {
    if (!isItalicLetter(letter)) continue
    const l = rectOf(letter)
    // A script starts where its letter ends.
    let low = 0
    let high = small.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if (minX(rectOf(small[middle])) < maxX(l) - 1) low = middle + 1
      else high = middle
    }
    let index = low
    while (index < small.length && minX(rectOf(small[index])) < maxX(l) + letter.size * 0.15) {
      const script = small[index]
      const offset = Math.abs(script.y - letter.y)
      const drawn = spell(script)
      if (script.size < letter.size * 0.8 && offset > letter.size * 0.08 && offset < letter.size * 0.6
        && drawn !== '' && isLetter(firstChar(drawn) ?? '')) return { ownLetters: false, evidence: true }
      index += 1
    }
  }
  return { ownLetters: false, evidence: false }
}

/**
 * Whether a paper sets its variables in the italic of its text face, as
 * mathptmx, txfonts, pxfonts, mathpazo and fourier do — asked of the paper,
 * not the page: the page answers first (a page with maths italic letters of
 * its own says no at once), then its first pages.
 */
function variablesInTextItalic(page: PageInput): boolean {
  const here = italicEvidence(page.glyphs)
  if (here.ownLetters) return false
  const elsewhere = page.italicElsewhere
  if (!elsewhere) return here.evidence
  return !elsewhere.ownLetters && (here.evidence || elsewhere.evidence)
}

/** A page is laid out once, because a selection asks about all of it. */
const layouts = new WeakMap<Glyph[], { page: PageInput; layout: Layout }>()

/** The page's rules with the fills of its \underbrace and \overbrace marks
 *  named as such. The tips that would identify them are dropped before any
 *  row is laid (`rowsOf`), so they have to be named here, while the tips are
 *  still in hand: unnamed, a fill drawn as a short image under ℓ_B became an
 *  \underline on the B, and a fill with a label under it a fraction bar with
 *  the label for a denominator. Named, the transcriber writes the brace with
 *  its label (`fractionBars`). */
function markingBraceFills(rules: Rule[], glyphs: Glyph[]): Rule[] {
  const tips = glyphs.filter((one) => one.glyphName?.startsWith('bracehtip') === true)
  if (tips.length === 0) return rules
  const plain: Rule[] = []
  const fills: Rule[] = []
  for (const rule of rules) (isBraceFill(rule, glyphs) ? fills : plain).push(rule)
  // TeX draws a brace as two fills with a pair of tips meeting in the middle
  // (\downbracefill: tip, fill, tip, tip, fill, tip), so one brace is two
  // rules; read as two, each took half the formula and half the label. Fills
  // on one level with exactly the middle pair between them — two tips' width
  // — are one brace; two braces side by side have a space between them as
  // well, and stay two.
  // (Joined by level, not by order along the page: two braces under
  // neighbouring terms stand a point apart in height and overlap.)
  const tipWidth = maxOf(tips.map((tip) => tip.width)) ?? 5
  const merged: Rule[] = []
  for (const fill of sortedBy(fills, (a, b) => minX(a.rect) < minX(b.rect))) {
    const at = merged.findIndex((other) => Math.abs(midY(other.rect) - midY(fill.rect)) < 1
      && minX(fill.rect) >= maxX(other.rect) - 1 && minX(fill.rect) - maxX(other.rect) < tipWidth * 2 + 1)
    if (at >= 0) merged[at] = { rect: union(merged[at].rect, fill.rect), brace: true }
    else merged.push({ ...fill, brace: true })
  }
  // The brace reaches a tip's width past its fills on either side, and what
  // stands over the tips — the bracket that opens the braced formula — is
  // braced too.
  // Its end tips say which way it faces: an \underbrace ends in tips that
  // point up, and its label is under it; an \overbrace ends in tips that
  // point down.
  return [...plain, ...merged.map((brace) => {
    const end = tips.find((tip) => Math.abs(maxX(rectOf(tip)) - minX(brace.rect)) < 1 && Math.abs(tip.y - midY(brace.rect)) < tipWidth * 3)
    const braceLabelBelow = end ? (end.glyphName?.startsWith('bracehtipup') ?? true) : true
    return { rect: insetBy(brace.rect, -tipWidth, 0), brace: true, braceLabelBelow }
  })]
}

function layoutOf(page: PageInput): Layout {
  const known = layouts.get(page.glyphs)
  if (known && known.page.rules === page.rules && known.page.characters === page.characters
    && known.page.italicElsewhere?.ownLetters === page.italicElsewhere?.ownLetters
    && known.page.italicElsewhere?.evidence === page.italicElsewhere?.evidence) return known.layout
  const rules = markingBraceFills(page.rules, page.glyphs)
  const laidRows = rowsOf(page.glyphs, rules)
  const body = sizeOf(page.glyphs)
  const italic = variablesInTextItalic(page)
  const before = italicVariables()
  setVariablesInTextItalic(italic)
  try {
    const grouped = blocks(laidRows, body, rules)
    // Rows stacked closer than a line are a formula's rows — when something
    // in them came from a maths font.
    const laid: Layout = {
      // A row of nothing but the pieces of a tall bracket is the bracket's,
      // not a row: two rows made a sentence round a \left( a display.
      blocks: grouped.map((group) => {
        const own = group.filter((row) => row.some((one) => !isPiece(one) && spell(one) !== ''))
        // (Rows of small type — a footnote's — stack closer than the text's
        // lines do and are not a formula's for it.)
        const stacked = own.length > 1 && group.some((row) => row.some(isMathish))
          && own.some((row) => context(row).bodySize >= body * 0.9)
        // The rows of a table stack a line apart too, and their cells of
        // measurements are mathematics to the glyph: a block whose every
        // row is a table's is the table, not a formula.
        // (Most of its rows: the header row names its columns in words.)
        const tabular = own.length > 0 && own.filter(isTableRow).length * 2 >= own.length
        return { rows: group, isFormula: !tabular && (stacked || isDisplayRow(own[0] ?? group[0])) }
      }),
      variablesInTextItalic: italic,
    }
    layouts.set(page.glyphs, { page, layout: laid })
    return laid
  } finally {
    setVariablesInTextItalic(before)
  }
}

