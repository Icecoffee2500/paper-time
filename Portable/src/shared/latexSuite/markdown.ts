/**
 * Where a Markdown note has math, code and comments — read the way Latex
 * Suite reads it. `LatexSuiteMarkdown.swift` in TypeScript.
 *
 * Latex Suite does not ask the editor where math is; it parses the note with
 * `@lezer/markdown` (CommonMark + GFM) plus its own `$`/`$$`, `%%comment%%`,
 * `[[wikilink]]` and `==highlight==` rules, and asks that tree. So this is a
 * port of the parts of that parser that decide whether a `$` can open math:
 * the block structure (containers, fences, `$$` blocks, indented code, HTML
 * blocks, block comments, tables) and, inside paragraphs, the inline
 * constructs that swallow a `$` before the math rule sees it (code spans,
 * escapes, HTML tags and autolinks, link destinations, wikilinks, comments,
 * bare URLs). Emphasis, entities, hard breaks, strikethrough and highlights are
 * left out on purpose: none of them can contain or hide a `$`.
 *
 * The block pass walks line starts from the top of the document to the
 * caret's block — block structure cannot be read backwards from the caret,
 * because whether a ```` ``` ```` line opens or closes a fence depends on every
 * fence above it. The character-level work (inline parsing) is done only for
 * the paragraphs that touch the caret.
 */
import { BACKSLASH, DOLLAR, isASCIILetter, isDigit, isMarkdownSpace, isSpace, isWord, lineEndOf, slice, type Span } from './text.js'

export interface Fence {
  from: number
  to: number
  openMark: Span
  info: Span | null
  closeMark: Span | null
  codeText: Span[]
}

export interface DisplayBlock {
  from: number
  to: number
  open: Span
  close: Span | null
  content: Span[]
  /** Whether a line after the first carried a `>` marker: those markers are
   *  children of the block too, between the opening `$$` and what follows it. */
  hasMarkers: boolean
}

/** A paragraph, heading or table cell: text the inline rules run over.
 *  `blanks` are container prefixes (`> `, list indentation) on continuation
 *  lines, which lezer replaces with spaces (`Line.scrub`). */
export interface Section {
  from: number
  to: number
  blanks: Span[]
}

export interface InlineMath {
  from: number
  to: number
  /** The delimiters, `${}`/`{}$` included when the math uses them. */
  open: Span
  close: Span
  display: boolean
}

export class Markdown {
  fences: Fence[] = []
  displayBlocks: DisplayBlock[] = []
  sections: Section[] = []
  inlineMath: InlineMath[] = []
  inlineCode: Span[] = []

  /**
   * Parses `source` far enough to answer questions about `[low, high]`: every
   * block that starts at or before its upper end, and the inline content of
   * the sections that touch it.
   */
  constructor(readonly source: string, low: number, high: number) {
    const parser = new BlockParser(source)
    parser.run(high)
    this.fences = parser.fences
    this.displayBlocks = parser.displayBlocks
    this.sections = parser.sections
    for (const section of this.sections) {
      if (!(section.from <= high && section.to >= low)) continue
      const inline = new InlineParser(source, section)
      inline.parse(high)
      this.inlineMath.push(...inline.math)
      this.inlineCode.push(...inline.code)
    }
    this.inlineMath.sort((a, b) => a.from - b.from)
  }

  text(range: Span): string {
    return slice(this.source, range.from, range.to)
  }
}

// MARK: - Block structure (lezer-markdown's BlockContext)

type ContainerType = 'document' | 'blockquote' | 'bulletList' | 'orderedList' | 'listItem'

interface Container {
  type: ContainerType
  value: number
}

class Line {
  start = 0
  length = 0
  baseIndent = 0
  basePos = 0
  depth = 0
  pos = 0
  indent = 0
  next = -1
  /** Blockquote markers matched on this line. */
  marks = 0
}

type Outcome = 'no' | 'container' | 'leaf' | 'stop'

/** The block parsers, in the order lezer tries them. */
const BLOCK_STARTS = ['indentedCode', 'fencedCode', 'displayMath', 'blockquote', 'horizontalRule',
  'bulletList', 'orderedList', 'atxHeading', 'htmlBlock', 'blockComment'] as const

class BlockParser {
  private line = new Line()
  private lineEnd = 0
  private atEnd = false
  private stack: Container[] = [{ type: 'document', value: 0 }]
  private stopped = false

  fences: Fence[] = []
  displayBlocks: DisplayBlock[] = []
  sections: Section[] = []

  constructor(private readonly doc: string) {}

  // MARK: Line helpers

  /** The character at `i` of the current line, -1 outside it. */
  private ch(i: number): number {
    return i >= 0 && i < this.line.length ? this.doc.charCodeAt(this.line.start + i) : -1
  }

  private skipSpace(from: number): number {
    let i = from
    while (i < this.line.length && isMarkdownSpace(this.ch(i))) i += 1
    return i
  }

  private skipSpaceBack(from: number, to: number): number {
    let i = from
    while (i > to && isMarkdownSpace(this.ch(i - 1))) i -= 1
    return i
  }

  private countIndent(to: number, from = 0, indent = 0): number {
    let result = indent
    for (let i = from; i < to; i += 1) result += this.ch(i) === 9 ? 4 - (result % 4) : 1
    return result
  }

  private findColumn(goal: number): number {
    let i = 0
    let indent = 0
    while (i < this.line.length && indent < goal) {
      indent += this.ch(i) === 9 ? 4 - (indent % 4) : 1
      i += 1
    }
    return i
  }

  private forwardInner() {
    const line = this.line
    const newPos = this.skipSpace(line.basePos)
    line.indent = this.countIndent(newPos, line.pos, line.indent)
    line.pos = newPos
    line.next = newPos === line.length ? -1 : this.ch(newPos)
  }

  private forward() {
    if (this.line.basePos > this.line.pos) this.forwardInner()
  }

  private moveBase(to: number) {
    this.line.basePos = to
    this.line.baseIndent = this.countIndent(to, this.line.pos, this.line.indent)
  }

  private moveBaseColumn(indent: number) {
    this.line.baseIndent = indent
    this.line.basePos = this.findColumn(indent)
  }

  // MARK: Reading lines

  private readLine() {
    const line = this.line
    const end = lineEndOf(this.doc, line.start)
    this.lineEnd = end
    line.length = end - line.start
    line.baseIndent = 0
    line.basePos = 0
    line.pos = 0
    line.indent = 0
    line.marks = 0
    this.forwardInner()
    line.depth = 1
    while (line.depth < this.stack.length) {
      if (!this.skipMarkup(line.depth)) {
        this.forward()
        break
      }
      this.forward()
      line.depth += 1
    }
  }

  /** Moves to the next line; false at the end of the document. */
  private nextLine(): boolean {
    if (this.lineEnd >= this.doc.length) {
      this.line.start = this.doc.length
      this.atEnd = true
      this.readLine()
      return false
    }
    this.line.start = this.lineEnd + 1
    this.readLine()
    return true
  }

  private prevLineEnd(): number {
    return this.atEnd ? this.line.start : this.line.start - 1
  }

  private peekLine(): Span {
    const start = this.lineEnd + 1
    if (start > this.doc.length) return { from: this.doc.length, to: this.doc.length }
    return { from: start, to: lineEndOf(this.doc, start) }
  }

  private skipMarkup(depth: number): boolean {
    const line = this.line
    const block = this.stack[depth]
    switch (block.type) {
      case 'document':
        return true
      case 'blockquote':
        if (line.next !== 62) return false
        line.marks += 1
        this.moveBase(line.pos + (isMarkdownSpace(this.ch(line.pos + 1)) ? 2 : 1))
        return true
      case 'listItem':
        if (line.indent < line.baseIndent + block.value && line.next > -1) return false
        this.moveBaseColumn(line.baseIndent + block.value)
        return true
      case 'bulletList':
      case 'orderedList': {
        if (line.pos === line.length
          || (depth !== this.stack.length - 1 && line.indent >= this.stack[line.depth + 1].value + line.baseIndent)) {
          return true
        }
        if (line.indent >= line.baseIndent + 4) return false
        const size = block.type === 'orderedList' ? this.isOrderedList(false) : this.isBulletList(false)
        return size > 0
          && (block.type !== 'bulletList' || this.isHorizontalRule(false) < 0)
          && this.ch(line.pos + size - 1) === block.value
      }
    }
  }

  // MARK: Line tests

  private isFencedCode(): number {
    const line = this.line
    if (!(line.next === 96 || line.next === 126)) return -1
    let p = line.pos + 1
    while (p < line.length && this.ch(p) === line.next) p += 1
    if (p < line.pos + 3) return -1
    if (line.next === 96) {
      for (let i = p; i < line.length; i += 1) if (this.ch(i) === 96) return -1
    }
    return p
  }

  private isBlockquote(): number {
    return this.line.next !== 62 ? -1 : this.ch(this.line.pos + 1) === 32 ? 2 : 1
  }

  private isHorizontalRule(breaking: boolean): number {
    const line = this.line
    if (!(line.next === 42 || line.next === 45 || line.next === 95)) return -1
    let count = 1
    for (let p = line.pos + 1; p < line.length; p += 1) {
      const c = this.ch(p)
      if (c === line.next) count += 1
      else if (!isMarkdownSpace(c)) return -1
    }
    // Setext headings take precedence.
    if (breaking && line.next === 45 && this.isSetextUnderline() > -1 && line.depth === this.stack.length) return -1
    return count < 3 ? -1 : 1
  }

  private inList(type: ContainerType): boolean {
    return this.stack.some((c) => c.type === type)
  }

  private isBulletList(breaking: boolean): number {
    const line = this.line
    const n = line.next
    if (!(n === 45 || n === 43 || n === 42)) return -1
    if (!(line.pos === line.length - 1 || isMarkdownSpace(this.ch(line.pos + 1)))) return -1
    if (breaking && !this.inList('bulletList') && this.skipSpace(line.pos + 2) >= line.length) return -1
    return 1
  }

  private isOrderedList(breaking: boolean): number {
    const line = this.line
    let p = line.pos
    let next = line.next
    for (;;) {
      if (isDigit(next)) p += 1
      else break
      if (p === line.length) return -1
      next = this.ch(p)
    }
    if (p === line.pos || p > line.pos + 9 || (next !== 46 && next !== 41)
      || (p < line.length - 1 && !isMarkdownSpace(this.ch(p + 1)))) {
      return -1
    }
    if (breaking && !this.inList('orderedList')
      && (this.skipSpace(p + 1) === line.length || p > line.pos + 1 || line.next !== 49)) {
      return -1
    }
    return p + 1 - line.pos
  }

  private isAtxHeading(): number {
    const line = this.line
    if (line.next !== 35) return -1
    let p = line.pos + 1
    while (p < line.length && this.ch(p) === 35) p += 1
    if (p < line.length && this.ch(p) !== 32) return -1
    const size = p - line.pos
    return size > 6 ? -1 : size
  }

  private isSetextUnderline(): number {
    const line = this.line
    if ((line.next !== 45 && line.next !== 61) || line.indent >= line.baseIndent + 4) return -1
    let p = line.pos + 1
    while (p < line.length && this.ch(p) === line.next) p += 1
    const end = p
    while (p < line.length && isMarkdownSpace(this.ch(p))) p += 1
    return p === line.length ? end : -1
  }

  private isHTMLBlock(breaking: boolean): number {
    if (this.line.next !== 60) return -1
    const rest = this.doc.slice(this.line.start + this.line.pos, this.line.start + this.line.length)
    const count = HTML_BLOCK_STARTS.length - (breaking ? 1 : 0)
    for (let i = 0; i < count; i += 1) if (HTML_BLOCK_STARTS[i].test(rest)) return i
    return -1
  }

  private getListIndent(pos: number): number {
    const line = this.line
    const indentAfter = this.countIndent(pos, line.pos, line.indent)
    const skipped = this.skipSpace(pos)
    const indented = this.countIndent(skipped, pos, indentAfter)
    return indented >= indentAfter + 5 || skipped === line.length ? indentAfter + 1 : indented
  }

  private isDisplayBlockStart(): number {
    const line = this.line
    if (!(line.next === DOLLAR && line.indent - line.baseIndent <= 3)) return -1
    let p = line.pos + 1
    while (p < line.length && this.ch(p) === line.next) p += 1
    if (p < line.pos + 2) return -1
    for (let i = p; i < line.length; i += 1) if (this.ch(i) === DOLLAR) return -1
    return p
  }

  private isDisplayBlockEnd(length: number): Span | null {
    const line = this.line
    let start = line.pos
    while (start < line.length && this.ch(start) !== DOLLAR) start += 1
    let p = start
    while (p < line.length && this.ch(p) === DOLLAR) p += 1
    return p - start >= length && this.skipSpace(p) === line.length ? { from: start, to: p } : null
  }

  private isBlockCommentBegin(): boolean {
    const line = this.line
    if (!(line.next === 37 && this.ch(line.pos + 1) === 37)) return false
    for (let i = line.pos + 2; i < line.length - 1; i += 1) {
      if (this.ch(i) === 37 && this.ch(i + 1) === 37) return false
    }
    return true
  }

  private commentEnd(): number {
    for (let i = this.line.pos; i < this.line.length; i += 1) {
      if (this.ch(i) === 37 && this.ch(i + 1) === 37) return i
    }
    return -1
  }

  // MARK: The block loop

  private start(parser: (typeof BLOCK_STARTS)[number]): Outcome {
    switch (parser) {
      case 'indentedCode': return this.indentedCode()
      case 'fencedCode': return this.fencedCode()
      case 'displayMath': return this.displayMath()
      case 'blockquote': return this.blockquote()
      case 'horizontalRule': return this.horizontalRule()
      case 'bulletList': return this.bulletList()
      case 'orderedList': return this.orderedList()
      case 'atxHeading': return this.atxHeading()
      case 'htmlBlock': return this.htmlBlock()
      case 'blockComment': return this.blockComment()
    }
  }

  run(limit: number) {
    const line = this.line
    line.start = 0
    this.readLine()
    outer: while (!this.stopped) {
      // Close the containers this line did not continue, skip blank lines.
      for (;;) {
        while (line.depth < this.stack.length) this.stack.pop()
        if (line.pos < line.length) break
        if (!this.nextLine()) return
      }
      if (line.start > limit) return
      blocks: for (;;) {
        for (const parser of BLOCK_STARTS) {
          const outcome = this.start(parser)
          if (outcome === 'no') continue
          if (outcome === 'leaf') continue outer
          if (outcome === 'stop') return
          this.forward()
          continue blocks
        }
        break
      }
      if (line.pos === line.length) {
        if (!this.nextLine()) return
        continue
      }
      this.paragraph()
    }
  }

  private startContainer(type: ContainerType, value = 0) {
    this.stack.push({ type, value })
  }

  private indentedCode(): Outcome {
    const line = this.line
    const base = line.baseIndent + 4
    if (line.indent < base) return 'no'
    while (this.nextLine() && line.depth >= this.stack.length) {
      if (line.pos === line.length) continue
      if (line.indent < base) break
    }
    return 'leaf'
  }

  private fencedCode(): Outcome {
    const line = this.line
    const fenceEnd = this.isFencedCode()
    if (fenceEnd < 0) return 'no'
    const from = line.start + line.pos
    const fenceChar = line.next
    const length = fenceEnd - line.pos
    const infoFrom = this.skipSpace(fenceEnd)
    const infoTo = this.skipSpaceBack(line.length, infoFrom)
    const fence: Fence = {
      from,
      to: from,
      openMark: { from, to: from + length },
      info: infoFrom < infoTo ? { from: line.start + infoFrom, to: line.start + infoTo } : null,
      closeMark: null,
      codeText: [],
    }
    const addCodeText = (range: Span) => {
      const last = fence.codeText[fence.codeText.length - 1]
      if (last && last.to === range.from) fence.codeText[fence.codeText.length - 1] = { from: last.from, to: range.to }
      else fence.codeText.push(range)
    }
    let first = true
    let empty = true
    let hasLine = false
    while (this.nextLine() && line.depth >= this.stack.length) {
      let i = line.pos
      if (line.indent - line.baseIndent < 4) {
        while (i < line.length && this.ch(i) === fenceChar) i += 1
      }
      if (i - line.pos >= length && this.skipSpace(i) === line.length) {
        if (empty && hasLine) addCodeText({ from: line.start - 1, to: line.start })
        fence.closeMark = { from: line.start + line.pos, to: line.start + i }
        this.nextLine()
        break
      }
      hasLine = true
      if (!first) {
        addCodeText({ from: line.start - 1, to: line.start })
        empty = false
      }
      const textStart = line.start + line.basePos
      const textEnd = line.start + line.length
      if (textStart < textEnd) {
        addCodeText({ from: textStart, to: textEnd })
        empty = false
      }
      first = false
    }
    fence.to = this.prevLineEnd()
    this.fences.push(fence)
    return 'leaf'
  }

  /**
   * Latex Suite's `$$` block (mathjax-parser.ts, blockParserDisplayMath):
   * fenced like ```` ``` ````, closed by the first line whose first run of `$`
   * is long enough and followed only by space.
   */
  private displayMath(): Outcome {
    const line = this.line
    const dollarEnd = this.isDisplayBlockStart()
    if (dollarEnd < 0) return 'no'
    const startPos = line.start + line.pos
    const length = dollarEnd - line.pos
    const firstEqChar = this.skipSpace(dollarEnd)
    let endLine = line.start + line.length
    const block: DisplayBlock = {
      from: startPos,
      to: endLine,
      open: { from: startPos, to: line.start + dollarEnd },
      close: null,
      content: [],
      hasMarkers: false,
    }
    const add = (range: Span) => {
      const last = block.content[block.content.length - 1]
      if (last && last.to === range.from) block.content[block.content.length - 1] = { from: last.from, to: range.to }
      else block.content.push(range)
    }
    let first = true
    if (firstEqChar < line.length) {
      add({ from: line.start + firstEqChar, to: line.start + line.length })
      first = false
    }
    const depth = this.stack.length
    while (this.nextLine() && ((line.length > 0 && depth >= 2) || depth < 2)) {
      endLine = line.start + line.length
      if (line.marks > 0) block.hasMarkers = true
      const end = this.isDisplayBlockEnd(length)
      if (end) {
        const endFrom = line.start + end.from
        if (line.start + line.basePos < endFrom) {
          add({ from: line.start - 1, to: line.start })
          add({ from: line.start + line.basePos, to: endFrom })
        }
        block.close = { from: endFrom, to: line.start + end.to }
        this.nextLine()
        break
      }
      if (!first) add({ from: line.start - 1, to: line.start })
      const textStart = line.start + line.basePos
      const textEnd = line.start + line.length
      if (textStart < textEnd) add({ from: textStart, to: textEnd })
      first = false
    }
    block.to = endLine
    this.displayBlocks.push(block)
    return 'leaf'
  }

  private blockquote(): Outcome {
    const size = this.isBlockquote()
    if (size < 0) return 'no'
    this.startContainer('blockquote')
    this.moveBase(this.line.pos + size)
    return 'container'
  }

  private horizontalRule(): Outcome {
    if (this.isHorizontalRule(false) < 0) return 'no'
    this.nextLine()
    return 'leaf'
  }

  private bulletList(): Outcome {
    const line = this.line
    if (this.isBulletList(false) < 0) return 'no'
    if (this.stack[this.stack.length - 1]?.type !== 'bulletList') this.startContainer('bulletList', line.next)
    const newBase = this.getListIndent(line.pos + 1)
    this.startContainer('listItem', newBase - line.baseIndent)
    this.moveBaseColumn(newBase)
    return 'container'
  }

  private orderedList(): Outcome {
    const line = this.line
    const size = this.isOrderedList(false)
    if (size < 0) return 'no'
    if (this.stack[this.stack.length - 1]?.type !== 'orderedList') this.startContainer('orderedList', this.ch(line.pos + size - 1))
    const newBase = this.getListIndent(line.pos + size)
    this.startContainer('listItem', newBase - line.baseIndent)
    this.moveBaseColumn(newBase)
    return 'container'
  }

  private atxHeading(): Outcome {
    const line = this.line
    const size = this.isAtxHeading()
    if (size < 0) return 'no'
    const off = line.pos
    const endOfSpace = this.skipSpaceBack(line.length, off)
    let after = endOfSpace
    while (after > off && this.ch(after - 1) === line.next) after -= 1
    if (after === endOfSpace || after === off || !isMarkdownSpace(this.ch(after - 1))) after = line.length
    const from = line.start + off + size + 1
    const to = line.start + after
    if (from < to) this.sections.push({ from, to, blanks: [] })
    this.nextLine()
    return 'leaf'
  }

  private htmlBlock(): Outcome {
    const line = this.line
    const kind = this.isHTMLBlock(false)
    if (kind < 0) return 'no'
    const end = HTML_BLOCK_ENDS[kind]
    let trailing = end !== null
    const ends = () => {
      const text = this.doc.slice(line.start, line.start + line.length)
      if (end) return end.test(text)
      return /^[ \t]*$/.test(text)
    }
    while (!ends() && this.nextLine()) {
      if (line.depth < this.stack.length) {
        trailing = false
        break
      }
    }
    if (trailing) this.nextLine()
    return 'leaf'
  }

  private blockComment(): Outcome {
    const line = this.line
    if (!this.isBlockCommentBegin()) return 'no'
    while (this.nextLine()) {
      const end = this.commentEnd()
      if (end === -1) continue
      const endPos = line.start + end + 2
      if (endPos < line.start + line.length) {
        this.sections.push({ from: endPos, to: line.start + line.length, blanks: [] })
      }
      this.nextLine()
      return 'leaf'
    }
    // An unclosed block comment consumes every line to the end without
    // leaving a node, and the parse then finishes (the parser returns false
    // after moving the line, and the empty last line ends the document).
    return 'stop'
  }

  // MARK: Paragraphs, headings, tables

  private paragraph() {
    const line = this.line
    const leafStart = line.start + line.pos
    const section: Section = { from: leafStart, to: line.start + line.length, blanks: [] }
    const tableCandidate = this.hasPipe({ from: leafStart, to: line.start + line.length })
    let tableRows: Section[] | null = null
    let tableChecked = false
    while (this.nextLine()) {
      if (line.pos === line.length) break
      if (line.indent < line.baseIndent + 4 && this.endsLeaf(tableCandidate)) break
      // Leaf parsers, in lezer's order: the table, then setext headings.
      if (tableCandidate) {
        if (!tableChecked) {
          tableChecked = true
          const rest = { from: line.start + line.pos, to: line.start + line.length }
          if ((line.next === 45 || line.next === 58 || line.next === 124)
            && isDelimiterLine(this.doc, rest)
            && rowCount(this.doc, { from: section.from, to: section.to }, null) === rowCount(this.doc, rest, null)) {
            const header: Section[] = []
            rowCount(this.doc, { from: section.from, to: section.to }, header)
            tableRows = header
          }
        } else if (tableRows) {
          rowCount(this.doc, { from: line.start + line.pos, to: line.start + line.length }, tableRows)
        }
      }
      if (line.depth >= this.stack.length && this.isSetextUnderline() > -1) {
        this.nextLine()
        this.sections.push(section)
        return
      }
      if (line.baseIndent > 0 && line.basePos > 0) {
        section.blanks.push({ from: line.start, to: line.start + line.basePos })
      }
      section.to = line.start + line.length
    }
    if (tableRows) this.sections.push(...tableRows)
    else this.sections.push(section)
  }

  private hasPipe(range: Span): boolean {
    // Most lines have no pipe at all, and a paragraph can be one long line.
    const first = this.doc.indexOf('|', range.from)
    if (first === -1 || first >= range.to) return false
    for (let i = range.from; i < range.to; i += 1) {
      const c = this.doc.charCodeAt(i)
      if (c === 124) return true
      if (c === 92) i += 1
    }
    return false
  }

  private endsLeaf(tableCandidate: boolean): boolean {
    const line = this.line
    if (this.isAtxHeading() >= 0 || this.isFencedCode() >= 0 || this.isBlockquote() >= 0
      || this.isBulletList(true) >= 0 || this.isOrderedList(true) >= 0
      || this.isHorizontalRule(true) >= 0 || this.isHTMLBlock(true) >= 0) {
      return true
    }
    // GFM: a line with a pipe followed by a matching delimiter row starts a table.
    if (!tableCandidate && this.hasPipe({ from: line.start + line.basePos, to: line.start + line.length })) {
      const next = this.peekLine()
      if (isDelimiterLine(this.doc, next)) {
        const here = { from: line.start + line.basePos, to: line.start + line.length }
        const nextRow = { from: next.from + Math.min(line.basePos, next.to - next.from), to: next.to }
        if (rowCount(this.doc, here, null) === rowCount(this.doc, nextRow, null)) return true
      }
    }
    return this.isDisplayBlockStart() >= 0 || this.isBlockCommentBegin()
  }
}

// MARK: - GFM tables

/** `/^[>\s]*\|?(\s*:?-+:?\s*\|)+(\s*:?-+:?\s*)?$/`, by hand. */
function isDelimiterLine(doc: string, range: Span): boolean {
  let i = range.from
  const end = range.to
  while (i < end && (doc.charCodeAt(i) === 62 || isSpace(doc.charCodeAt(i)))) i += 1
  // The leading run may have eaten spaces that belong to the first cell; that
  // is harmless because `\s*` would have taken them anyway.
  if (i < end && doc.charCodeAt(i) === 124) i += 1
  let cells = 0
  for (;;) {
    let j = i
    while (j < end && isSpace(doc.charCodeAt(j))) j += 1
    if (j < end && doc.charCodeAt(j) === 58) j += 1
    const dashes = j
    while (j < end && doc.charCodeAt(j) === 45) j += 1
    if (j === dashes) break
    if (j < end && doc.charCodeAt(j) === 58) j += 1
    while (j < end && isSpace(doc.charCodeAt(j))) j += 1
    if (j < end && doc.charCodeAt(j) === 124) {
      cells += 1
      i = j + 1
      continue
    }
    // The optional last cell without a closing pipe.
    return cells > 0 && j === end
  }
  if (cells === 0) return false
  let j = i
  while (j < end && isSpace(doc.charCodeAt(j))) j += 1
  return j === end
}

/** lezer's `parseRow`: the number of cells, and optionally each cell as an inline section. */
function rowCount(doc: string, range: Span, cells: Section[] | null): number {
  let count = 0
  let first = true
  let cellStart = -1
  let cellEnd = -1
  let escaped = false
  for (let i = range.from; i < range.to; i += 1) {
    const next = doc.charCodeAt(i)
    if (next === 124 && !escaped) {
      if (!first || cellStart > -1) count += 1
      first = false
      if (cellStart > -1) cells?.push({ from: cellStart, to: cellEnd, blanks: [] })
      cellStart = -1
      cellEnd = -1
    } else if (escaped || (next !== 32 && next !== 9)) {
      if (cellStart < 0) cellStart = i
      cellEnd = i + 1
    }
    escaped = !escaped && next === BACKSLASH
  }
  if (cellStart > -1) {
    count += 1
    cells?.push({ from: cellStart, to: cellEnd, blanks: [] })
  }
  return count
}

// MARK: - HTML blocks and tags

/** lezer-markdown's HTMLBlockStyle openers, in order — its own JavaScript patterns. */
const HTML_BLOCK_STARTS: RegExp[] = [
  /^<(?:script|pre|style)(?:\s|>|$)/i,
  /^\s*<!--/,
  /^\s*<\?/,
  /^\s*<![A-Z]/,
  /^\s*<!\[CDATA\[/,
  /^\s*<\/?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|section|source|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|\/?>|$)/i,
  /^\s*(?:<\/[a-z][\w-]*\s*>|<[a-z][\w-]*(\s+[a-z:_][\w\-.]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*>)\s*$/i,
]

/** The matching closers; null means "an empty line". */
const HTML_BLOCK_ENDS: (RegExp | null)[] = [/<\/(?:script|pre|style)>/i, /-->/, /\?>/, />/, /\]\]>/, null, null]

/** The inline HTMLTag parser's four patterns, tried in its order on the text after `<` (sticky: anchored there). */
const INLINE_HTML: RegExp[] = [
  /(?:[a-z][-\w+.]+:[^\s>]+|[a-z\d.!#$%&'*+/=?^_`{|}~-]+@[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?(?:\.[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?)*)>/iy,
  /!--[^>](?:-[^-]|[^-])*?-->/y,
  /\?[\s\S]*?\?>/y,
  /(?:![A-Z][\s\S]*?>|!\[CDATA\[[\s\S]*?\]\]>|\/\s*[a-zA-Z][\w-]*\s*>|\s*[a-zA-Z][\w-]*(\s+[a-zA-Z:_][\w\-.:]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*(\/\s*)?>)/y,
]

function inlineHTMLLength(text: string, from: number): number | null {
  for (const regex of INLINE_HTML) {
    regex.lastIndex = from
    const m = regex.exec(text)
    if (m) return m[0].length
  }
  return null
}

// MARK: - Inline constructs (lezer-markdown's InlineContext)

type Part =
  | { kind: 'linkStart'; from: number; to: number; image: boolean; open: boolean }
  | { kind: 'element' }
  | { kind: 'removed' }

/** What `nextCandidate` looks for: a character an inline rule starts with, a
 *  word character, or one of the other three `autolink` looks at (`.` `+` `-`). */
const RULE = 1
const WORD = 2
const LINK = 3
const CANDIDATE = new Uint8Array(128)
for (const c of '\\`<[!]%$') CANDIDATE[c.charCodeAt(0)] = RULE
for (let c = 0; c < 128; c += 1) if (isWord(c)) CANDIDATE[c] = WORD
for (const c of '.+-') CANDIDATE[c.charCodeAt(0)] = LINK

const ESCAPABLE = new Set(Array.from('!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~', (c) => c.charCodeAt(0)))
const TRAILING_PUNCTUATION = new Set([63, 33, 46, 44, 58, 42, 95, 126])

class InlineParser {
  private text: string
  private readonly offset: number
  private parts: Part[] = []
  math: InlineMath[] = []
  code: Span[] = []
  /** Where the section has an `@`, relative to its start: an e-mail autolink
   *  needs one close ahead, and most paragraphs have none. */
  private readonly ats: number[]

  constructor(doc: string, section: Section) {
    this.offset = section.from
    let text = doc.slice(section.from, section.to)
    if (section.blanks.length > 0) {
      const units = text.split('')
      for (const blank of section.blanks) {
        for (let i = blank.from; i < blank.to; i += 1) {
          if (i >= section.from && i < section.to) units[i - section.from] = ' '
        }
      }
      text = units.join('')
    }
    this.text = text
    this.ats = []
    for (let i = text.indexOf('@'); i !== -1; i = text.indexOf('@', i + 1)) this.ats.push(i)
  }

  private get end(): number {
    return this.offset + this.text.length
  }

  private char(pos: number): number {
    return pos >= this.end || pos < this.offset ? -1 : this.text.charCodeAt(pos - this.offset)
  }

  private skipSpace(from: number): number {
    let i = from
    while (i < this.end && isMarkdownSpace(this.char(i))) i += 1
    return i
  }

  /**
   * Reads the constructs that start at or before `limit`. Nothing that starts
   * later can change them — lezer reads inline content strictly left to right,
   * and a construct's own end is found by scanning ahead — so the rest of a
   * long paragraph is not read on every keystroke.
   */
  parse(limit = Infinity) {
    let pos = this.offset
    const stop = limit === Infinity ? this.end : Math.min(this.end, limit + 1)
    const at = { k: 0 }
    for (;;) {
      pos = this.nextCandidate(pos, stop, at)
      if (pos >= stop) break
      const next = this.char(pos)
      const to = this.parseAt(pos, next)
      pos = to !== null ? to : pos + 1
    }
  }

  /**
   * The first position from `from` where `parseAt` could find anything: one of
   * the characters an inline rule starts with, or the start of a word that
   * could begin a bare URL (`www.`, `http`, `mailto:`, `xmpp:`) or an e-mail
   * address (an `@` within reach).
   */
  private nextCandidate(from: number, stop: number, at: { k: number }): number {
    const text = this.text
    const n = stop - this.offset
    let i = from - this.offset
    // A walk over the paragraph before the caret is most of a keystroke in a
    // long one, so each unit is looked up once and "was the one before a word
    // character" is carried along rather than read again.
    let prevWord = i > 0 && isWord(text.charCodeAt(i - 1))
    for (; i < n; i += 1) {
      const c = text.charCodeAt(i)
      const kind = c < 128 ? CANDIDATE[c] : 0
      if (kind === RULE) return i + this.offset // \ ` < [ ! ] % $
      if (kind !== 0 && !prevWord) { // what `autolink` looks at, at the start of a word
        if (c === 119 || c === 104 || c === 109 || c === 120) return i + this.offset // w h m x
        while (at.k < this.ats.length && this.ats[at.k] <= i) at.k += 1
        if (at.k < this.ats.length && this.ats[at.k] <= i + 100) return i + this.offset
      }
      prevWord = kind === WORD
    }
    return stop
  }

  private parseAt(start: number, next: number): number | null {
    switch (next) {
      case 92: { // Escape
        const c = this.char(start + 1)
        if (start !== this.end - 1 && c >= 0 && ESCAPABLE.has(c)) {
          this.parts.push({ kind: 'element' })
          return start + 2
        }
        break
      }
      case 96: { // InlineCode
        const to = this.inlineCode(start)
        if (to !== null) return to
        break
      }
      case 60: // HTMLTag and autolinks
        if (start !== this.end - 1) {
          const length = inlineHTMLLength(this.text, start + 1 - this.offset)
          if (length !== null) {
            this.parts.push({ kind: 'element' })
            return start + 1 + length
          }
        }
        break
      case 91: case 33: { // Wikilink, Link, Image
        const to = this.wikilink(start, next)
        if (to !== null) return to
        if (next === 91) {
          this.parts.push({ kind: 'linkStart', from: start, to: start + 1, image: false, open: true })
          return start + 1
        }
        if (this.char(start + 1) === 91) {
          this.parts.push({ kind: 'linkStart', from: start, to: start + 2, image: true, open: true })
          return start + 2
        }
        break
      }
      case 93: { // LinkEnd
        const to = this.linkEnd(start)
        if (to !== null) return to
        break
      }
      default:
        break
    }
    const link = this.autolink(start)
    if (link !== null) return link
    if (next === 37 && this.char(start + 1) === 37) { // ObsidianComment
      for (let i = start + 2; i < this.end - 1; i += 1) {
        if (this.char(i) === 37 && this.char(i + 1) === 37) {
          this.parts.push({ kind: 'element' })
          return i + 2
        }
      }
    }
    if (next === DOLLAR) return this.inlineMathAt(start)
    return null
  }

  private inlineCode(start: number): number | null {
    if (start > 0 && this.char(start - 1) === 96) return null
    let pos = start + 1
    while (pos < this.end && this.char(pos) === 96) pos += 1
    const size = pos - start
    let current = 0
    while (pos < this.end) {
      if (this.char(pos) === 96) {
        current += 1
        if (current === size && this.char(pos + 1) !== 96) {
          this.code.push({ from: start, to: pos + 1 })
          this.parts.push({ kind: 'element' })
          return pos + 1
        }
      } else {
        current = 0
      }
      pos += 1
    }
    return null
  }

  private wikilink(start: number, next: number): number | null {
    const isLink = next === 91 && this.char(start + 1) === 91
    const isEmbed = !isLink && next === 33 && this.char(start + 1) === 91 && this.char(start + 2) === 91
    if (!isLink && !isEmbed) return null
    for (let i = start + (isEmbed ? 1 : 0) + 2; i < this.end; i += 1) {
      if (this.char(i) === 93 && this.char(i + 1) === 93) {
        this.parts.push({ kind: 'element' })
        return i + 2
      }
    }
    return null
  }

  private linkEnd(start: number): number | null {
    for (let i = this.parts.length - 1; i >= 0; i -= 1) {
      const part = this.parts[i]
      if (part.kind !== 'linkStart') continue
      if (!part.open || (this.skipSpace(part.to) === start && this.char(start + 1) !== 40 && this.char(start + 1) !== 91)) {
        this.parts[i] = { kind: 'removed' }
        return null
      }
      this.parts.splice(i)
      const linkTo = this.finishLink(start + 1)
      this.parts.push({ kind: 'element' })
      if (!part.image) {
        for (let j = 0; j < i; j += 1) {
          const other = this.parts[j]
          if (other.kind === 'linkStart' && !other.image) this.parts[j] = { ...other, open: false }
        }
      }
      return linkTo
    }
    return null
  }

  private finishLink(startPos: number): number {
    const next = this.char(startPos)
    if (next === 40) {
      let pos = this.skipSpace(startPos + 1)
      const dest = this.parseURL(pos)
      if (dest !== null) {
        pos = this.skipSpace(dest)
        if (pos !== dest) {
          const title = this.parseLinkTitle(pos)
          if (title !== null) pos = this.skipSpace(title)
        }
      }
      if (this.char(pos) === 41) return pos + 1
    } else if (next === 91) {
      const label = this.parseLinkLabel(startPos)
      if (label !== null) return label
    }
    return startPos
  }

  /** The end of a link destination starting at `start`, or null. */
  private parseURL(start: number): number | null {
    if (this.char(start) === 60) {
      for (let pos = start + 1; pos < this.end; pos += 1) {
        const c = this.char(pos)
        if (c === 62) return pos + 1
        if (c === 60 || c === 10) return null
      }
      return null
    }
    let depth = 0
    let pos = start
    let escaped = false
    while (pos < this.end) {
      const c = this.char(pos)
      if (isMarkdownSpace(c)) {
        break
      } else if (escaped) {
        escaped = false
      } else if (c === 40) {
        depth += 1
      } else if (c === 41) {
        if (depth === 0) break
        depth -= 1
      } else if (c === 92) {
        escaped = true
      }
      pos += 1
    }
    return pos > start ? pos : null
  }

  private parseLinkTitle(start: number): number | null {
    const next = this.char(start)
    if (!(next === 39 || next === 34 || next === 40)) return null
    const close = next === 40 ? 41 : next
    let escaped = false
    for (let pos = start + 1; pos < this.end; pos += 1) {
      const c = this.char(pos)
      if (escaped) escaped = false
      else if (c === close) return pos + 1
      else if (c === 92) escaped = true
    }
    return null
  }

  private parseLinkLabel(start: number): number | null {
    const first = start + 1
    const limit = Math.min(this.end, first + 999)
    let escaped = false
    for (let pos = first; pos < limit; pos += 1) {
      const c = this.char(pos)
      if (escaped) escaped = false
      else if (c === 93) return pos + 1
      else if (c === 91) return null
      else if (c === 92) escaped = true
    }
    return null
  }

  private get hasOpenLink(): boolean {
    return this.parts.some((p) => p.kind === 'linkStart')
  }

  // GFM autolinks: bare `www.` and `http(s)://` URLs, and e-mail addresses.
  private autolink(absPos: number): number | null {
    const text = this.text
    const pos = absPos - this.offset
    if (pos > 0 && isWord(text.charCodeAt(pos - 1))) return null
    const c = this.char(absPos)
    if (!(isWord(c) || c === 46 || c === 43 || c === 45)) return null
    let endPos = -1
    // Each branch needs its own first character (or an `@` in reach), so a
    // word that cannot start any of them is not tried against all five.
    if (c === 119 && text.startsWith('www.', pos)) {
      endPos = this.urlEnd(pos + 4)
      if (endPos > -1 && this.hasOpenLink) endPos = pos + this.noBracketPrefix(pos, endPos)
    } else if (c === 104 && (text.startsWith('http://', pos) || text.startsWith('https://', pos))) {
      endPos = this.urlEnd(pos + (text.charCodeAt(pos + 4) === 115 ? 8 : 7))
      if (endPos > -1 && this.hasOpenLink) endPos = pos + this.noBracketPrefix(pos, endPos)
    } else if (this.atWithin(pos) && this.emailLocalEnd(pos) !== null) {
      endPos = this.emailEnd(pos)
    } else if ((c === 109 || c === 120) && (text.startsWith('mailto:', pos) || text.startsWith('xmpp:', pos))) {
      const xmpp = text.charCodeAt(pos) === 120
      endPos = this.emailEnd(pos + (xmpp ? 5 : 7))
      if (endPos > -1 && xmpp && endPos < text.length && text.charCodeAt(endPos) === 47) {
        let j = endPos + 1
        while (j < text.length) {
          const u = text.charCodeAt(j)
          if (!(isASCIILetter(u) || isDigit(u) || u === 64 || u === 46)) break
          j += 1
        }
        if (j > endPos + 1) endPos = j
      }
    }
    if (endPos < 0) return null
    this.parts.push({ kind: 'element' })
    return endPos + this.offset
  }

  private isURLWord(c: number): boolean {
    return isWord(c) || c === 45
  }

  /** `[\w-]+(\.[\w-]+)+(:\d+)?(\/[^\s<]*)?` from `from`, then GFM's trailing-punctuation rules. */
  private urlEnd(from: number): number {
    const text = this.text
    const n = text.length
    let i = from
    while (i < n && this.isURLWord(text.charCodeAt(i))) i += 1
    if (i === from) return -1
    let labels = 1
    let lastLabels: [Span, Span] = [{ from, to: i }, { from, to: i }]
    while (i < n && text.charCodeAt(i) === 46) {
      let j = i + 1
      while (j < n && this.isURLWord(text.charCodeAt(j))) j += 1
      if (j === i + 1) break
      lastLabels = [lastLabels[1], { from: i + 1, to: j }]
      labels += 1
      i = j
    }
    if (labels < 2) return -1
    for (let k = lastLabels[0].from; k < lastLabels[1].to; k += 1) if (text.charCodeAt(k) === 95) return -1
    if (i < n && text.charCodeAt(i) === 58) {
      let j = i + 1
      while (j < n && isDigit(text.charCodeAt(j))) j += 1
      if (j > i + 1) i = j
    }
    if (i < n && text.charCodeAt(i) === 47) {
      i += 1
      while (i < n && !isSpace(text.charCodeAt(i)) && text.charCodeAt(i) !== 60) i += 1
    }
    let endPos = i
    while (endPos > from) {
      const last = text.charCodeAt(endPos - 1)
      if (TRAILING_PUNCTUATION.has(last)) {
        endPos -= 1
      } else if (last === 41 && this.count(41, from, endPos) > this.count(40, from, endPos)) {
        endPos -= 1
      } else if (last === 59) {
        const entity = this.trailingEntity(from, endPos)
        if (entity === null) break
        endPos = entity
      } else {
        break
      }
    }
    return endPos
  }

  private count(c: number, from: number, to: number): number {
    let n = 0
    for (let i = from; i < to; i += 1) if (this.text.charCodeAt(i) === c) n += 1
    return n
  }

  /** `/&(?:#\d+|#x[a-f\d]+|\w+);$/` against text[from..<to]: where it starts. */
  private trailingEntity(from: number, to: number): number | null {
    const text = this.text
    for (let j = to - 2; j >= from; j -= 1) {
      const u = text.charCodeAt(j)
      if (u === 38) {
        const body = text.slice(j + 1, to - 1)
        if (body.length === 0) return null
        if (Array.from(body).every((ch) => isWord(ch.charCodeAt(0)))) return j
        if (body.charCodeAt(0) === 35) {
          const rest = body.slice(1)
          if (rest.length > 0 && /^[0-9]+$/.test(rest)) return j
          if (rest.length > 1 && rest.charCodeAt(0) === 120 && /^[0-9a-f]*$/.test(rest.slice(1))) return j
        }
        return null
      }
      if (!(isWord(u) || u === 35)) return null
    }
    return null
  }

  private noBracketPrefix(from: number, to: number): number {
    const text = this.text
    let i = from
    while (i < to) {
      const c = text.charCodeAt(i)
      if (c === 93) break
      if (c === 91) {
        let j = i + 1
        while (j < to && text.charCodeAt(j) !== 93) j += 1
        if (j >= to) break
        i = j + 1
        continue
      }
      i += 1
    }
    return i - from
  }

  private isEmailLocal(c: number): boolean {
    return isWord(c) || c === 46 || c === 43 || c === 45
  }

  /** Whether an `@` sits within the hundred characters after `pos`, where `emailLocalEnd` could find it. */
  private atWithin(pos: number): boolean {
    let lo = 0
    let hi = this.ats.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if (this.ats[mid] <= pos) lo = mid + 1
      else hi = mid
    }
    return lo < this.ats.length && this.ats[lo] <= pos + 100
  }

  /** `[\w.+-]{1,100}@` at `pos`: the index of the `@`. */
  private emailLocalEnd(pos: number): number | null {
    const text = this.text
    let i = pos
    while (i < text.length && i - pos < 100 && this.isEmailLocal(text.charCodeAt(i))) i += 1
    return i > pos && i < text.length && text.charCodeAt(i) === 64 ? i : null
  }

  /** `[\w.+-]+@[\w-]+(\.[\w.-]+)+`, then GFM's rules for its last character. */
  private emailEnd(from: number): number {
    const text = this.text
    const n = text.length
    let i = from
    while (i < n && this.isEmailLocal(text.charCodeAt(i))) i += 1
    if (!(i > from && i < n && text.charCodeAt(i) === 64)) return -1
    i += 1
    const domain = i
    while (i < n && this.isURLWord(text.charCodeAt(i))) i += 1
    if (i <= domain) return -1
    let groups = 0
    while (i < n && text.charCodeAt(i) === 46) {
      let j = i + 1
      while (j < n && (this.isURLWord(text.charCodeAt(j)) || text.charCodeAt(j) === 46)) j += 1
      if (j === i + 1) break
      groups += 1
      i = j
    }
    if (groups === 0) return -1
    const last = text.charCodeAt(i - 1)
    if (last === 95 || last === 45) return -1
    return i - (last === 46 ? 1 : 0)
  }

  /** Latex Suite's inline math rule (mathjax-parser.ts, lines 34–106). */
  private inlineMathAt(start: number): number | null {
    const display = this.char(start + 1) === DOLLAR
    if (!display && isMarkdownSpace(this.char(start + 1))) return null
    const delimiter = display ? 2 : 1
    let contentStart = start + delimiter
    let i = contentStart
    while (i < this.end) {
      const c = this.char(i)
      if (c === 92) {
        i += 2
        continue
      }
      if (c === 10) return null
      if (c !== DOLLAR) {
        i += 1
        continue
      }
      const nextChar = this.char(i + 1)
      if (display) {
        if (nextChar !== DOLLAR) {
          i += 1
          continue
        }
      } else if (isMarkdownSpace(this.char(i - 1)) || isDigit(nextChar)) {
        i += 1
        continue
      }
      const endPos = i + delimiter
      let closingStart = i
      if (!display && endPos - start >= 6
        && this.char(start + 1) === 123 && this.char(start + 2) === 125 && this.char(i - 2) === 123 && this.char(i - 1) === 125) {
        contentStart += 2
        closingStart -= 2
      }
      this.math.push({ from: start, to: endPos, open: { from: start, to: contentStart }, close: { from: closingStart, to: endPos }, display })
      this.parts.push({ kind: 'element' })
      return endPos
    }
    if (display) {
      this.math.push({ from: start, to: start + 2, open: { from: start, to: start + 1 }, close: { from: start + 1, to: start + 2 }, display: false })
      this.parts.push({ kind: 'element' })
      return start + 2
    }
    return null
  }
}
