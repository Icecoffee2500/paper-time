/**
 * A note as it is shown while it is written — the Mac's `NoteMarkdown`
 * render loop, as a plan rather than an attributed string: for every line,
 * what kind of block it is, the marker and what stands in for it, and the
 * inline pieces (a passage, a note link, a formula, emphasis) with what each
 * shows instead of its source. The editor turns the plan into decorations;
 * `displayRuns` turns it into what the Mac's `PAPERTIME_DUMP_NOTE` prints,
 * so the two can be compared run for run (`src/test/noteMarkdown.ts`).
 *
 * The line the caret is on is shown as it is written — every marker and
 * every delimiter — as on the Mac: a note is edited in its source and read
 * set, and the line under the hand is the one being edited.
 */
import { blockOf, type Block } from './noteBlocks.js'
import { codeBlocks, codeLanguageName, codeRows, type CodeBlock, type CodeRow } from './noteCode.js'
import { firstFormula, lineRanges, mathBlocks, type TextSpan } from './noteMath.js'
import { tableBlocks } from './noteTable.js'
import { listNumbersOf } from './noteList.js'
import { parseAnchorURL } from './noteQuote.js'

/** What stands in for a heading's or a quotation's marker: nothing to see. */
export const HIDDEN_MARKER = '\u200b'

export type InlineToken =
  | { kind: 'anchor'; from: number; to: number; label: string; url: string; passage: boolean }
  | { kind: 'note'; from: number; to: number; id: string; title: string }
  | { kind: 'math'; from: number; to: number; latex: string; display: boolean }
  | { kind: 'emphasis'; from: number; to: number; text: string; bold: boolean; italic: boolean; mono: boolean }
  /** `\$`: a dollar written so it does not open a formula, shown as the dollar it is. */
  | { kind: 'dollar'; from: number; to: number }

/** Which ends of a quotation a line owns, and whether it came off a page. */
export interface QuoteEdge { opens: boolean; closes: boolean; anchored: boolean }

export interface PlannedLine {
  /** The line in the source, without its line break; a `$$` block spans several. */
  from: number
  to: number
  block: Block
  quoteEdge: QuoteEdge | null
  /** The caret is on it: shown as written. */
  revealed: boolean
  /** The marker's end in the source (`from` + its length). */
  markerEnd: number
  /** What the marker shows while the line is not being edited. */
  shownMarker: string
  /** The inline pieces, in source coordinates; none on a revealed line. */
  tokens: InlineToken[]
  /** One displayed formula and nothing else — set as a paper sets one: in the
   *  middle of the line, and one with numbers across all of it
   *  (`NoteMarkdown.standsAlone`). Not while the line is being edited. */
  alone: boolean
  /** A line of a fenced block: what it is in the block. Its words are code —
   *  no marker, no pieces, whatever it starts with. */
  code: CodeRow | null
}

/**
 * The source with every fenced block's characters but its line breaks turned
 * to spaces (`NoteMarkdown.blankingCode`): what the readers of mathematics and
 * tables are given, so nothing inside code is read as either, at the same
 * offsets.
 */
export function blankingCode(source: string, blocks: readonly CodeBlock[]): string {
  if (blocks.length === 0) return source
  let out = ''
  let at = 0
  for (const block of blocks) {
    out += source.slice(at, block.range.from) + source.slice(block.range.from, block.range.to).replace(/[^\n]/g, ' ')
    at = block.range.to
  }
  return out + source.slice(at)
}

/** The lines, a `$$` that opens on one line and closes on another read as one. */
export function noteLines(source: string, code: readonly CodeBlock[] = codeBlocks(source)): TextSpan[] {
  const ranges = lineRanges(source)
  // A table's lines too, for the same reason: one thing over several lines.
  // Neither is looked for inside fenced code.
  const read = blankingCode(source, code)
  const joined = [...mathBlocks(read), ...tableBlocks(read)].sort((a, b) => a.from - b.from)
  for (const block of joined.reverse()) {
    const first = ranges.findIndex((one) => one.from === block.from)
    const last = ranges.findIndex((one) => one.to === block.to)
    if (first < 0 || last < first) continue
    ranges.splice(first, last - first + 1, { from: block.from, to: block.to })
  }
  return ranges
}

/** A number as a spreadsheet names its columns, in lower case: 1 → a, 26 → z, 27 → aa. */
export function letters(n: number): string {
  let out = ''
  let left = Math.max(1, Math.trunc(n))
  while (left > 0) {
    left -= 1
    out = String.fromCharCode(97 + (left % 26)) + out
    left = Math.trunc(left / 26)
  }
  return out
}

const ROMAN: [number, string][] = [
  [1000, 'm'], [900, 'cm'], [500, 'd'], [400, 'cd'], [100, 'c'], [90, 'xc'],
  [50, 'l'], [40, 'xl'], [10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i'],
]

/** A number in lower-case roman numerals: 4 → iv, 14 → xiv, 900 → cm. */
export function roman(n: number): string {
  let out = ''
  let left = Math.max(1, Math.trunc(n))
  for (const [value, glyphs] of ROMAN) {
    while (left >= value) {
      out += glyphs
      left -= value
    }
  }
  return out
}

/**
 * What a marker shows, by how deep the item is (the Mac's `shownMarker`):
 * a bullet goes • ◦ ▪ and round again; a number goes 1. a. i. and round
 * again — as Notion and Word count nested lists. A number is the one the item
 * shows where it stands (`listNumbers`), not the one written: an item moved in
 * with Tab kept its «2.» and was shown «b.».
 */
export function shownMarker(block: Block, shown?: number): string {
  switch (block.type.kind) {
    case 'plain': return ''
    case 'heading':
    case 'quote': return HIDDEN_MARKER
    case 'bullet': return `${['•', '◦', '▪'][block.indent % 3]}\t`
    // Open, in the plan: the editor alone knows which toggles are folded.
    case 'toggle': return '▾\t'
    case 'ordered': {
      const n = shown ?? block.type.number
      switch (block.indent % 3) {
        case 1: return `${letters(n)}.\t`
        case 2: return `${roman(n)}.\t`
        default: return `${n}.\t`
      }
    }
    case 'task': return block.type.done ? '☑\t' : '☐\t'
  }
}

/** The whole note, planned; `caret` is where the typist is, in the source. */
export function planNote(source: string, caret: number | null = null): PlannedLine[] {
  const fenced = codeBlocks(source)
  const rows = codeRows(source, fenced)
  const ranges = noteLines(source, fenced)
  const plain = (content: string): Block => ({ type: { kind: 'plain' }, marker: '', content, indent: 0 })
  const blocks = ranges.map((range) => {
    const text = source.slice(range.from, range.to)
    return rows.has(range.from) ? plain(text) : blockOf(text)
  })
  const numbers = listNumbersOf(ranges, source, (range) => rows.has(range.from))
  const edges: (QuoteEdge | null)[] = blocks.map((block, index) => block.type.kind !== 'quote' ? null : {
    opens: index === 0 || blocks[index - 1].type.kind !== 'quote',
    closes: index === blocks.length - 1 || blocks[index + 1].type.kind !== 'quote',
    anchored: false,
  })
  // An address anywhere in a quotation belongs to all of it.
  for (let start = 0; start < blocks.length;) {
    if (blocks[start].type.kind !== 'quote') {
      start += 1
      continue
    }
    let end = start
    while (end + 1 < blocks.length && blocks[end + 1].type.kind === 'quote') end += 1
    if (blocks.slice(start, end + 1).some((block) => block.content.includes('](papertime://anchor'))) {
      for (let index = start; index <= end; index += 1) edges[index]!.anchored = true
    }
    start = end + 1
  }
  return ranges.map((range, index) => {
    const block = blocks[index]
    const revealed = caret !== null && caret >= range.from && caret <= range.to
    const code = rows.get(range.from) ?? null
    if (code) {
      return { from: range.from, to: range.to, block, quoteEdge: null, revealed, markerEnd: range.from, shownMarker: '', tokens: [], alone: false, code }
    }
    const markerEnd = range.from + block.marker.length
    const tokens = revealed || !holdsMarkup(block.content)
      ? []
      : inlineTokens(block.content).map((token) => ({ ...token, from: token.from + markerEnd, to: token.to + markerEnd }))
    return {
      from: range.from, to: range.to, block, quoteEdge: edges[index], revealed, markerEnd,
      shownMarker: shownMarker(block, numbers.get(range.from)), tokens, alone: !revealed && standsAlone(block), code: null,
    }
  })
}

/**
 * Whether a line is one displayed formula and nothing else. A list item or a
 * heading keeps its own shape whatever it holds.
 */
export function standsAlone(block: Block): boolean {
  if (block.type.kind !== 'plain' && block.type.kind !== 'quote') return false
  if (!holdsMarkup(block.content)) return false
  const first = inlineTokens(block.content)[0]
  if (!first || first.kind !== 'math' || !first.display) return false
  const blank = /^\p{White_Space}*$/u
  return blank.test(block.content.slice(0, first.from)) && blank.test(block.content.slice(first.to))
}

// MARK: - Inline

/** Brackets inside a label only in pairs, as CommonMark has them — the Mac's `linkPattern`: a quotation's words often hold a citation, «[48] solves … [3쪽](…)». */
const LINK = /\[((?:\\.|[^\\\[\]\n]|\[(?:\\.|[^\\\[\]\n])*\])*)\]\((papertime:\/\/[^)\s]+)\)/g
const WIKI = /\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]/g
const DOLLAR = /\\\$/g
const EMPHASIS = /(\*\*\*)([^*\n]+)(\*\*\*)|(\*\*)([^*\n]+)(\*\*)|(\*)([^*\n]+)(\*)|(`)([^`\n]+)(`)/g

/** How many characters each side of emphasised words are its marks: `*`, `**`, `***`, or a backtick (`NoteMarkdown.emphasisWidth`). */
export function emphasisWidth(token: { bold: boolean; italic: boolean; mono: boolean }): number {
  return token.mono ? 1 : (token.bold ? 2 : 0) + (token.italic ? 1 : 0)
}

/** The classes emphasised words are drawn with. */
export function emphasisClasses(token: { bold: boolean; italic: boolean; mono: boolean }): string {
  if (token.mono) return 'nm-mono'
  return [token.bold ? 'nm-bold' : '', token.italic ? 'nm-italic' : ''].filter(Boolean).join(' ')
}

/** What stands either side of a code span's letters on the Mac, where its tint reaches (`NoteMarkdown.codePad`); here CSS padding does it. */
export const CODE_PAD = '\u202f'

/** A table cell's words in pieces: emphasis set as emphasis, the rest as written with stray `**`, `__` and backticks dropped (`NoteTableDrawing.text`). */
export function emphasisPieces(cell: string): { text: string; bold: boolean; italic: boolean; mono: boolean }[] {
  const pieces: { text: string; bold: boolean; italic: boolean; mono: boolean }[] = []
  const plain = (text: string) => {
    const left = text.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '')
    if (left) pieces.push({ text: left, bold: false, italic: false, mono: false })
  }
  let at = 0
  // A fresh one: `matchAll` starts where the shared expression's
  // `lastIndex` was left by the last line read.
  for (const match of cell.matchAll(new RegExp(EMPHASIS.source, 'g'))) {
    plain(cell.slice(at, match.index))
    const [bold, italic, mono, text] = match[2] !== undefined ? [true, true, false, match[2]]
      : match[5] !== undefined ? [true, false, false, match[5]]
        : match[8] !== undefined ? [false, true, false, match[8]] : [false, false, true, match[11]]
    pieces.push({ text: text as string, bold: bold as boolean, italic: italic as boolean, mono: mono as boolean })
    at = (match.index ?? 0) + match[0].length
  }
  plain(cell.slice(at))
  return pieces
}

/** Whether a line could hold a link, a note link, a formula or emphasis — they all begin with one of five
 *  characters: a formula with `$` or, written as LaTeX writes it, with a backslash. */
export function holdsMarkup(line: string): boolean {
  return /[[$*`\\]/.test(line)
}

function firstFrom(pattern: RegExp, text: string, from: number): RegExpExecArray | null {
  pattern.lastIndex = from
  return pattern.exec(text)
}

/** `NoteMarkdown.unescape`: a backslash keeps the character after it. */
export function unescapeLabel(text: string): string {
  let out = ''
  let escaped = false
  for (const character of text) {
    if (escaped) {
      out += character
      escaped = false
    } else if (character === '\\') {
      escaped = true
    } else {
      out += character
    }
  }
  return escaped ? `${out}\\` : out
}


/**
 * The inline pieces of one line's content, in order — `nextToken`: the
 * earliest match wins, and where two begin at the same character the
 * shorter one does (a `[[note]]` and a link whose label was allowed to run
 * past it both start at that bracket).
 */
export function inlineTokens(content: string): InlineToken[] {
  const tokens: InlineToken[] = []
  let index = 0
  while (index < content.length) {
    let best: InlineToken | null = null
    const consider = (token: InlineToken | null) => {
      if (!token) return
      if (!best || token.from < best.from || (token.from === best.from && token.to - token.from < best.to - best.from)) best = token
    }
    const link = firstFrom(LINK, content, index)
    if (link) {
      const url = link[2]
      consider({ kind: 'anchor', from: link.index, to: link.index + link[0].length, label: unescapeLabel(link[1]), url, passage: parseAnchorURL(url) !== null })
    }
    const wiki = firstFrom(WIKI, content, index)
    if (wiki) consider({ kind: 'note', from: wiki.index, to: wiki.index + wiki[0].length, id: wiki[1], title: wiki[2] ?? wiki[1] })
    // One with nothing in it is still a formula — shown as it was typed, and the line is read on after it.
    const math = firstFormula(content, index)
    if (math) consider({ kind: 'math', from: math.range.from, to: math.range.to, latex: math.latex, display: math.display })
    const dollar = firstFrom(DOLLAR, content, index)
    if (dollar) consider({ kind: 'dollar', from: dollar.index, to: dollar.index + 2 })
    const emphasis = firstFrom(EMPHASIS, content, index)
    if (emphasis) {
      // `***both***` is bold and italic — what Ctrl+B then Ctrl+I make of a selection.
      const groups: [number, boolean, boolean, boolean][] = [[2, true, true, false], [5, true, false, false], [8, false, true, false], [11, false, false, true]]
      for (const [group, bold, italic, mono] of groups) {
        if (emphasis[group] === undefined) continue
        consider({ kind: 'emphasis', from: emphasis.index, to: emphasis.index + emphasis[0].length, text: emphasis[group], bold, italic, mono })
        break
      }
    }
    const token = best as InlineToken | null
    if (!token) break
    tokens.push(token)
    index = token.to
  }
  return tokens
}

// MARK: - As the Mac's dump prints it

export interface DisplayRun {
  text: string
  marks: string
}

/** The step a list or a quotation is set in by: one and a half body sizes (`NoteTypography.baseSize` 16). */
const STEP = 16 * 1.5

/** `style.headIndent` of a line's paragraph, as the dump prints it (`Int`). */
export function headIndent(block: Block): number {
  switch (block.type.kind) {
    case 'bullet':
    case 'ordered':
    case 'task':
    case 'toggle': return Math.trunc(STEP * (block.indent + 1))
    case 'quote': return Math.trunc(STEP * 0.85)
    default: return 0
  }
}

/**
 * The note as `NoteMarkdown.dump` prints it: runs of shown text, each with
 * the marks the dump names (QUOTE, PASSAGE, LINK, CODE, CODEBLOCK, italic, indent N, center), runs of
 * the same marks joined. A formula is one object replacement character; a
 * fenced block's header is its language's name (nothing to see when it has
 * none), its closing fence nothing to see.
 */
export function displayRuns(source: string): DisplayRun[] {
  const pieces: DisplayRun[] = []
  const put = (text: string, marks: string[]) => {
    if (!text) return
    const key = marks.length === 0 ? '—' : marks.join('+')
    const last = pieces[pieces.length - 1]
    if (last && last.marks === key) last.text += text
    else pieces.push({ text, marks: key })
  }
  const lines = planNote(source)
  lines.forEach((line, index) => {
    if (line.code) {
      const row = line.code
      const shown = row.role === 'line' ? source.slice(line.from, line.to)
        : row.role === 'header' && row.block.language !== '' ? codeLanguageName(row.block.language) : HIDDEN_MARKER
      put(shown, ['CODEBLOCK'])
      if (index < lines.length - 1) put('\n', ['CODEBLOCK'])
      return
    }
    const { block } = line
    const quote = block.type.kind === 'quote'
    const indent = headIndent(block)
    // A formula on a line of its own is set in the middle of the line (`standsAlone`).
    const withIndent = (marks: string[]) => [...marks, ...(indent > 0 ? [`indent ${indent}`] : []), ...(line.alone ? ['center'] : [])]
    if (block.marker.length > 0) put(line.shownMarker, withIndent(quote ? ['QUOTE'] : []))
    const contentItalic = quote && block.quoteHeading === undefined
    const plain = (text: string) => put(text, withIndent([...(quote ? ['QUOTE'] : []), ...(contentItalic ? ['italic'] : [])]))
    let at = line.markerEnd
    for (const token of line.tokens) {
      if (token.from > at) plain(source.slice(at, token.from))
      switch (token.kind) {
        case 'anchor':
          if (!token.passage) put(token.label, withIndent(['LINK']))
          else if (quote) {
            const whole = token.from === line.markerEnd && token.to === line.to
            put(token.label, withIndent(whole ? ['QUOTE', 'PASSAGE', 'italic'] : ['PASSAGE']))
          } else put(token.label, withIndent(['PASSAGE']))
          break
        case 'note':
          put(token.title || token.id, withIndent(['LINK']))
          break
        case 'math':
          put('\ufffc', withIndent([]))
          break
        case 'dollar':
          plain('$')
          break
        case 'emphasis': {
          // The Mac pads code with a narrow space each side, where its tint reaches.
          if (token.mono) { put(CODE_PAD + token.text + CODE_PAD, withIndent(['CODE'])); break }
          const quoted = quote && block.quoteHeading === undefined
          put(token.text, withIndent(token.italic || quoted ? ['italic'] : []))
          break
        }
      }
      at = token.to
    }
    if (line.to > at) plain(source.slice(at, line.to))
    if (index < lines.length - 1) put('\n', withIndent([]))
  })
  return pieces
}
