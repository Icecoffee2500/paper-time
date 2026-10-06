/**
 * The note set as it is typed — the Mac's `NoteMarkdown` render, as
 * CodeMirror decorations over the Markdown itself (`shared/noteMarkdown.ts`
 * is the plan; `src/test/noteMarkdown.ts` checks it against the Mac).
 *
 * The file is still the Markdown, character for character: nothing here
 * changes the text, it only decides how each piece of it is drawn. The line
 * under the caret is drawn as written — a heading's or a quotation's marker
 * and every inline delimiter in the accent colour, nothing hidden — so the
 * line being edited is the source and the rest is read set. A list's marker
 * is the one thing drawn set on that line too: a bullet is a bullet, never
 * «- » (Notion), the caret steps over it and never rests inside it. A
 * passage is a chip, a note link its title, a formula set by MathJax,
 * emphasis without its stars; headings are sized, list items hang under
 * their first word, and a quotation has its rule and — when it came off a
 * page — its wash. A toggle («+ ») folds the lines indented under it away
 * with a press on its marker, and the fold remembers the header's words.
 */
import { EditorSelection, EditorState, Prec, RangeSetBuilder, StateEffect, StateField, type Extension, type Range } from '@codemirror/state'
import { Decoration, EditorView, WidgetType, keymap, type DecorationSet } from '@codemirror/view'
import { blankingCode, emphasisClasses, emphasisPieces, emphasisWidth, markerClass, planNote, type InlineToken, type PlannedLine } from '../../../shared/noteMarkdown.js'
import { toggleChildrenEnd } from '../../../shared/noteBlocks.js'
import { L } from '../../../shared/lang.js'
import { parseTable, tableBlocks, type Table } from '../../../shared/noteTable.js'
import { typesetNumbered, typesetter } from '../../sketchMath.js'
import { numberFormulas, signature, type Numbered } from '../../../shared/mathJax.js'
import { codeBlocks, codeLanguageName, codeOf, type CodeBlock, type CodeRow } from '../../../shared/noteCode.js'
import { highlightCode } from '../../../shared/codeHighlight.js'
import { copyText } from '../clipboard.js'
import { icon } from '../../icons.js'

/** Shows the Markdown as it is written — «Show Markdown» (`showsRawText`). */
export const setRaw = StateEffect.define<boolean>()
export const rawField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setRaw)) return effect.value
    return value
  },
})

class MarkerWidget extends WidgetType {
  constructor(readonly text: string, readonly done: boolean) { super() }
  override eq(other: MarkerWidget) { return other.text === this.text && other.done === this.done }
  toDOM() {
    const span = document.createElement('span')
    span.className = markerClass(this.text, this.done)
    span.textContent = this.text
    return span
  }
}

// MARK: - Toggles

/** The toggles folded shut, each by its header's words without their indentation («+ Title»). */
export const toggleFold = StateEffect.define<{ key: string; folded: boolean }>()
export const foldedField = StateField.define<ReadonlySet<string>>({
  create: () => new Set(),
  update(value, tr) {
    let next: Set<string> | null = null
    for (const effect of tr.effects) {
      if (!effect.is(toggleFold)) continue
      next ??= new Set(value)
      if (effect.value.folded) next.add(effect.value.key)
      else next.delete(effect.value.key)
    }
    return next ?? value
  },
})

/** What a fold is keyed by: the header line as written, less its indentation. */
export function toggleKey(header: string): string {
  return header.trimStart()
}

/** A toggle's marker: ▾ open, ▸ shut, and a press turns it. */
class ToggleWidget extends WidgetType {
  constructor(readonly key: string, readonly folded: boolean) { super() }
  override eq(other: ToggleWidget) { return other.key === this.key && other.folded === this.folded }
  toDOM(view: EditorView) {
    const span = document.createElement('span')
    span.className = 'nm-marker nm-toggle'
    span.textContent = this.folded ? '▸' : '▾'
    span.title = this.folded ? L('펼치기', 'Expand') : L('접기', 'Collapse')
    // The press must not move the caret or take the focus from the note.
    span.addEventListener('mousedown', (event) => event.preventDefault())
    span.addEventListener('click', (event) => {
      event.preventDefault()
      view.dispatch({ effects: toggleFold.of({ key: this.key, folded: !this.folded }) })
    })
    return span
  }
}

/** What stands where a toggle's children were: one ellipsis, and a press opens them again. */
class FoldedWidget extends WidgetType {
  constructor(readonly key: string) { super() }
  override eq(other: FoldedWidget) { return other.key === this.key }
  toDOM(view: EditorView) {
    const node = document.createElement('div')
    node.className = 'nm-folded'
    node.textContent = '…'
    node.addEventListener('mousedown', (event) => event.preventDefault())
    node.addEventListener('click', () => view.dispatch({ effects: toggleFold.of({ key: this.key, folded: false }) }))
    return node
  }
  override get estimatedHeight() { return 20 }
}

class MathWidget extends WidgetType {
  constructor(
    readonly latex: string, readonly display: boolean, readonly block: boolean, readonly source: string,
    /** Its place in the note's numbering (`numberFormulas`). */
    readonly counted: Numbered,
    /** One displayed formula and nothing else on its line: set across all of it. */
    readonly alone: boolean,
  ) { super() }
  override eq(other: MathWidget) {
    return other.latex === this.latex && other.display === this.display && other.block === this.block
      && other.alone === this.alone && other.counted.start === this.counted.start
      && signature(other.counted.known) === signature(this.counted.known)
  }
  toDOM(view: EditorView) {
    const node = document.createElement(this.block ? 'div' : 'span')
    node.className = this.block ? 'nm-math nm-math-block' : this.display ? 'nm-math nm-math-display' : 'nm-math'
    if (this.alone && !this.block) node.classList.add('nm-math-alone')
    // The room a `multline` spreads over, and a numbered formula's numbers
    // stand at the end of: the line's, in MathJax's pixels (an `ex` is eight).
    const room = view.contentDOM.clientWidth ? view.contentDOM.clientWidth * 8 / exPixels(view.contentDOM) : undefined
    const markup = typesetNumbered(this.latex, this.display, this.counted.start, this.counted.known, room)?.svg ?? null
    // A formula that does not set is shown as it is written, quietly — never
    // an error box in the middle of somebody's sentence.
    if (markup) {
      node.innerHTML = markup
      const svg = node.querySelector('svg')
      if (svg && svg.getAttribute('width') === '100%' && !svg.hasAttribute('viewBox')) fitNumbered(svg, room)
    } else {
      node.classList.add('nm-math-raw')
      node.textContent = this.source
    }
    return node
  }
  override ignoreEvent() { return false }
}

/** How many pixels an `ex` of the note's text is, which MathJax's sizes are in. */
let measuredEx = 0
function exPixels(inside: HTMLElement): number {
  if (measuredEx > 0) return measuredEx
  const probe = document.createElement('div')
  probe.style.cssText = 'position:absolute;visibility:hidden;height:10ex;width:0'
  inside.append(probe)
  measuredEx = probe.getBoundingClientRect().height / 10 || 8
  probe.remove()
  return measuredEx
}

/**
 * A formula with numbers comes from MathJax laid out for a page as wide as
 * it likes and never narrower than itself (a `min-width`) — and a `min-width`
 * wins over the note's `max-width`, so a numbered line wider than the note
 * pushed the note off the right-hand edge, numbers and all. It is given the
 * note's width instead, as the Mac gives it (`MathSVG`): the numbers at the
 * right-hand edge, and a formula wider than the note set smaller to fit.
 */
function fitNumbered(svg: SVGSVGElement, room: number | undefined) {
  const style = svg.getAttribute('style') ?? ''
  const least = parseFloat(/min-width:\s*(-?[\d.]+)ex/.exec(style)?.[1] ?? '0') * 8
  const high = parseFloat(svg.getAttribute('height') ?? '0') * 8
  const wide = Math.max(least, room ?? 0)
  if (!(wide > 0) || !(high > 0)) return
  svg.setAttribute('viewBox', `0 0 ${wide} ${high}`)
  svg.setAttribute('style', style.replace(/min-width:\s*[^;]*;?/, ''))
}

/** A table, drawn while the caret is elsewhere (the Mac's `NoteTableDrawing`).
 *  A press puts the caret in it, and its lines show as they are written. */
class TableWidget extends WidgetType {
  constructor(readonly table: Table, readonly source: string) { super() }
  override eq(other: TableWidget) { return other.source === this.source }
  toDOM(view: EditorView) {
    const frame = document.createElement('div')
    frame.className = 'nm-table'
    const grid = document.createElement('table')
    // A cell's emphasis is set as emphasis (`NoteTableDrawing.text`); it was
    // only taken out, so `*기울*` stayed as written.
    const fill = (into: HTMLElement, cell: string) => {
      for (const piece of emphasisPieces(cell)) {
        const classes = emphasisClasses(piece)
        if (!classes) { into.append(piece.text); continue }
        const span = document.createElement(piece.mono ? 'code' : piece.bold ? 'strong' : 'em')
        span.className = classes
        span.textContent = piece.text
        into.append(span)
      }
    }
    const align = (index: number) => {
      const one = this.table.alignments[index]
      return one === 'center' ? 'center' : one === 'right' ? 'right' : 'left'
    }
    const head = grid.createTHead().insertRow()
    this.table.header.forEach((cell, index) => {
      const th = document.createElement('th')
      fill(th, cell)
      th.style.textAlign = align(index)
      head.append(th)
    })
    const body = grid.createTBody()
    for (const row of this.table.rows) {
      const tr = body.insertRow()
      row.forEach((cell, index) => {
        const td = tr.insertCell()
        fill(td, cell)
        td.style.textAlign = align(index)
      })
    }
    frame.append(grid)
    frame.addEventListener('mousedown', (event) => {
      event.preventDefault()
      const at = view.posAtDOM(frame)
      view.dispatch({ selection: { anchor: at } })
      view.focus()
    })
    return frame
  }
  override ignoreEvent() { return true }
}

// MARK: - Fenced code

/** What a block's copy button copies with: the clipboard — or, in a probe, a stand-in that never touches it. */
let copier: (text: string) => Promise<boolean> = copyText
export function setCodeCopier(next: (text: string) => Promise<boolean>) {
  copier = next
}

/** A digit of the numbers' face (16 × 0.72, monospaced): what the gutter is measured in. */
const NUMBER_DIGIT = 6.912

/**
 * The room a block's numbers take (`NoteCodeStyle.Block.gutter`): two digits
 * at least, so a block that grows past nine lines does not shift its code.
 */
export function codeGutter(lines: number): number {
  const digits = Math.max(2, String(Math.max(lines, 1)).length)
  return Math.ceil(digits * NUMBER_DIGIT) + 14
}

/**
 * A block's header while the caret is elsewhere: its language's name, and the
 * copy button at the other end (`NoteLayoutFragment.drawCodeBlock`). A press
 * on the name puts the caret on the fence, which then shows as written.
 */
class CodeHeaderWidget extends WidgetType {
  constructor(readonly name: string) { super() }
  override eq(other: CodeHeaderWidget) { return other.name === this.name }
  toDOM(view: EditorView) {
    const head = document.createElement('span')
    head.className = 'nm-code-head'
    const label = document.createElement('span')
    label.className = 'nm-code-lang'
    label.textContent = this.name
    const button = document.createElement('button')
    button.type = 'button'
    button.className = 'nm-code-copy'
    const paint = (copied: boolean) => {
      button.innerHTML = `${icon(copied ? 'checkmark' : 'doc.on.doc')}<span>${copied ? L('복사했어요', 'Copied') : L('복사', 'Copy')}</span>`
    }
    paint(false)
    // The press must not move the caret or take the focus from the note.
    button.addEventListener('mousedown', (event) => event.preventDefault())
    button.addEventListener('click', (event) => {
      event.preventDefault()
      const source = view.state.doc.toString()
      const start = view.state.doc.lineAt(view.posAtDOM(head)).from
      const block = codeBlocks(source).find((one) => one.open.from === start)
      if (!block) return
      void copier(codeOf(block, source)).then((copied) => {
        if (!copied) return
        paint(true)
        window.setTimeout(() => paint(false), 1600)
      })
    })
    head.append(label, button)
    return head
  }
  // The button's press is the button's; one on the name is the editor's.
  override ignoreEvent(event: Event) {
    return event.target instanceof Element && event.target.closest('.nm-code-copy') !== null
  }
}

/** A row's look: the box's slice, the row's paddings and its number (`style.css`, `.nm-code`). */
function codeLineDecoration(row: CodeRow, revealed: boolean): Decoration {
  const classes = ['nm-line', 'nm-code', `nm-code-${row.role}`]
  if (row.role === 'line' && row.number === 1) classes.push('nm-code-first')
  if (row.isLast) classes.push('nm-code-last')
  // The closing fence is the box's foot while the caret is elsewhere.
  if (row.role === 'close' && !revealed) classes.push('nm-code-foot')
  if (revealed) classes.push('nm-revealed')
  const attributes: Record<string, string> = { class: classes.join(' '), style: `--code-gutter: ${codeGutter(row.block.lines.length)}px` }
  if (row.role === 'line') attributes['data-n'] = String(row.number)
  return Decoration.line({ attributes })
}

/**
 * A line of a fenced block, drawn: the header its language and copy button
 * (the fence as written, its marks in the accent, while the caret is on it),
 * a line of code in its colours (`highlightCode`, the same as the Mac's), the
 * closing fence nothing to see — the box's foot — until the caret is on it.
 */
function codeRanges(line: PlannedLine, row: CodeRow, source: string, out: Range<Decoration>[], colours: Map<CodeBlock, ReturnType<typeof highlightCode>>) {
  out.push(codeLineDecoration(row, line.revealed).range(line.from))
  switch (row.role) {
    case 'header': {
      if (!line.revealed) {
        const name = row.block.language ? codeLanguageName(row.block.language) : ''
        out.push(Decoration.replace({ widget: new CodeHeaderWidget(name) }).range(line.from, line.to))
        return
      }
      const marks = /^[ `~]*/.exec(source.slice(line.from, line.to))?.[0].length ?? 0
      if (marks > 0) out.push(syntax.range(line.from, line.from + marks))
      if (line.to > line.from + marks) out.push(Decoration.mark({ class: 'nm-code-info' }).range(line.from + marks, line.to))
      return
    }
    case 'close':
      if (line.to > line.from) out.push((line.revealed ? syntax : hidden).range(line.from, line.to))
      return
    case 'line': {
      let runs = colours.get(row.block)
      if (!runs) {
        runs = highlightCode(codeOf(row.block, source), row.block.language)
        colours.set(row.block, runs)
      }
      // The block's colours are in its code's offsets; this line's start there is `offset`.
      const end = row.offset + (line.to - line.from)
      for (const run of runs) {
        if (run.to <= row.offset || run.from >= end) continue
        const from = line.from + Math.max(run.from, row.offset) - row.offset
        const to = line.from + Math.min(run.to, end) - row.offset
        if (to > from) out.push(Decoration.mark({ class: `nm-tok-${run.role}` }).range(from, to))
      }
      return
    }
  }
}

const hidden = Decoration.replace({})
/** A marker or a delimiter on the line being edited: there, in the accent. */
const syntax = Decoration.mark({ class: 'nm-syntax' })

function lineClasses(line: PlannedLine): string {
  const { block } = line
  const classes = ['nm-line']
  switch (block.type.kind) {
    case 'heading': classes.push('nm-h', `nm-h${block.type.level}`); break
    case 'bullet':
    case 'ordered':
    case 'task':
    case 'toggle': classes.push('nm-list', `nm-indent-${Math.min(block.indent, 6)}`); break
    case 'quote': {
      classes.push('nm-quote')
      if (block.quoteHeading) classes.push('nm-h', `nm-h${block.quoteHeading}`)
      const edge = line.quoteEdge
      if (edge?.opens) classes.push('nm-q-open')
      if (edge?.closes) classes.push('nm-q-close')
      if (edge?.anchored || block.quoteHeading) classes.push('nm-q-anchored')
      break
    }
    default: break
  }
  if (line.revealed) classes.push('nm-revealed')
  return classes.join(' ')
}

const uncounted: Numbered = { start: 0, known: {} }

/**
 * The note's formulas counted from its top, by where each is in the source:
 * an `equation` takes the next number wherever the caret is, so every
 * formula is counted — the one being typed too — before any is drawn
 * (`NoteMarkdown.numbered`).
 */
function numbering(source: string, plan: readonly PlannedLine[]): Map<number, Numbered> {
  const counted = new Map<number, Numbered>()
  // Nothing takes a number or refers to one without one of these.
  if (!source.includes('\\begin') && !source.includes('\\label') && !source.includes('\\ref')) return counted
  const formulas = plan.flatMap((line) => line.tokens.filter((token) => token.kind === 'math'))
  if (!formulas.length) return counted
  const steps = numberFormulas(formulas as { latex: string; display: boolean }[], typesetter().set)
  formulas.forEach((token, index) => counted.set(token.from, steps[index]))
  return counted
}

/** The pieces of a line other than its marker: what is hidden, what is marked, what is replaced. */
function tokenRanges(token: InlineToken, source: string, line: PlannedLine, out: Range<Decoration>[], counted: Map<number, Numbered>) {
  const { from, to } = token
  switch (token.kind) {
    case 'anchor': {
      const labelEnd = source.indexOf('](', from)
      if (labelEnd < 0 || labelEnd >= to) return
      const quote = line.block.type.kind === 'quote'
      const whole = from === line.markerEnd && to === line.to
      const kind = !token.passage ? 'nm-link' : quote ? (whole ? 'nm-quoted-words' : 'nm-page-chip') : 'nm-chip'
      out.push(hidden.range(from, from + 1))
      if (labelEnd > from + 1) out.push(Decoration.mark({ class: kind, attributes: { 'data-anchor': token.url, title: token.passage ? '' : token.url } }).range(from + 1, labelEnd))
      // A bracket or a backslash in the label travels escaped; the label is
      // shown as it reads (`NoteMarkdown.unescape`).
      for (let at = from + 1; at < labelEnd - 1; at += 1) {
        if (source[at] !== '\\') continue
        out.push(hidden.range(at, at + 1))
        at += 1
      }
      out.push(hidden.range(labelEnd, to))
      return
    }
    case 'note': {
      const bar = source.indexOf('|', from)
      const titled = bar >= 0 && bar < to - 2
      const shownFrom = titled ? bar + 1 : from + 2
      out.push(hidden.range(from, shownFrom))
      if (to - 2 > shownFrom) out.push(Decoration.mark({ class: 'nm-note-link', attributes: { 'data-note': token.id } }).range(shownFrom, to - 2))
      out.push(hidden.range(to - 2, to))
      return
    }
    case 'math': {
      const text = source.slice(from, to)
      const block = text.includes('\n')
      const widget = new MathWidget(token.latex, token.display, block, text, counted.get(from) ?? uncounted, line.alone)
      out.push(Decoration.replace({ widget, block }).range(from, to))
      return
    }
    case 'dollar':
      out.push(hidden.range(from, from + 1))
      return
    case 'emphasis': {
      const width = emphasisWidth(token)
      out.push(hidden.range(from, from + width))
      out.push(Decoration.mark({ class: emphasisClasses(token) }).range(from + width, to - width))
      out.push(hidden.range(to - width, to))
      return
    }
  }
}

/** The opening and the closing of a formula, as they are written: `$`, `$$`, `\(`, `\[`, `\begin{…}`, `\eqref{`. */
const MATH_OPEN = /^(\$\$|\$|\\\(|\\\[|\\begin\{[^}\n]*\}|\\(?:eq)?ref\{)/
const MATH_CLOSE = /(\$\$|\$|\\\)|\\\]|\\end\{[^}\n]*\}|\})$/

/**
 * The pieces of the line being edited: nothing hidden, nothing replaced,
 * only the characters that are Markdown rather than words — a link's
 * brackets, a note link's `[[` and `]]`, a formula's dollars, emphasis's
 * stars, an escaped dollar's backslash — in the accent (`nm-syntax`).
 */
function syntaxRanges(token: InlineToken, source: string, out: Range<Decoration>[]) {
  const { from, to } = token
  const paint = (a: number, b: number) => { if (b > a) out.push(syntax.range(a, b)) }
  switch (token.kind) {
    case 'anchor': {
      const labelEnd = source.indexOf('](', from)
      if (labelEnd < 0 || labelEnd >= to) return
      paint(from, from + 1)
      paint(labelEnd, to)
      return
    }
    case 'note': {
      const bar = source.indexOf('|', from)
      const titled = bar >= 0 && bar < to - 2
      paint(from, titled ? bar + 1 : from + 2)
      paint(to - 2, to)
      return
    }
    case 'math': {
      const text = source.slice(from, to)
      const open = MATH_OPEN.exec(text)?.[0].length ?? 0
      const close = MATH_CLOSE.exec(text.slice(open))?.[0].length ?? 0
      paint(from, from + open)
      paint(to - close, to)
      return
    }
    case 'dollar':
      paint(from, from + 1)
      return
    case 'emphasis': {
      // And what the marks do, done already, as Obsidian does it: the words
      // between `**` bold while their line is being written (the Mac's
      // `styleAsWritten`). Code is tinted with its backticks.
      const width = emphasisWidth(token)
      if (token.mono) out.push(Decoration.mark({ class: 'nm-mono' }).range(from, to))
      else if (to - from > 2 * width) out.push(Decoration.mark({ class: emphasisClasses(token) }).range(from + width, to - width))
      paint(from, from + width)
      paint(to - width, to)
      return
    }
  }
}

/** What the note is drawn with, and the list markers among it — the ranges the caret steps over. */
export interface Drawn {
  decorations: DecorationSet
  /** A bullet, a number or a checkbox: a marker drawn as the thing it is, whichever line the caret is on. */
  markers: DecorationSet
  /** The markers of a list's lines — a bullet, a number, a box, a toggle's arrow — which a caret never rests before or inside. */
  listMarkers: DecorationSet
  /** The children of the toggles folded shut, in the source. */
  folded: { from: number; to: number; key: string }[]
}

const nothingDrawn: Drawn = { decorations: Decoration.none, markers: Decoration.none, listMarkers: Decoration.none, folded: [] }

/** The children of the toggles folded shut, for a probe: where each fold begins. */
export function foldedRanges(state: EditorState): { from: number; to: number }[] {
  return state.field(decorationField).folded.map(({ from, to }) => ({ from, to }))
}

export function noteDecorations(state: EditorState): Drawn {
  if (state.field(rawField, false)) return nothingDrawn
  const source = state.doc.toString()
  const heads = state.selection.ranges.map((range) => range.head)
  // Planned with no caret, so every line has its pieces; a line with a caret
  // on it is then drawn as written and its pieces are left alone.
  const plan = planNote(source, null).map((line) => ({ ...line, revealed: heads.some((head) => head >= line.from && head <= line.to) }))
  const ranges: Range<Decoration>[] = []
  const markers: Range<Decoration>[] = []
  const listMarkers: Range<Decoration>[] = []
  const folded: Drawn['folded'] = []
  const shut = state.field(foldedField, false) ?? new Set<string>()
  const counted = numbering(source, plan)
  // No table is looked for inside fenced code.
  const tables = new Set(tableBlocks(blankingCode(source, codeBlocks(source))).map((one) => `${one.from}:${one.to}`))
  const colours = new Map<CodeBlock, ReturnType<typeof highlightCode>>()
  // A toggle folded shut: its children, from the end of its line to the end
  // of their last, stand as one block the caret steps over.
  let fold: { from: number; to: number } | null = null
  plan.forEach((line) => {
    // A line inside a fold is not drawn: the fold stands for it.
    if (fold && line.from > fold.from && line.to <= fold.to) return
    if (line.block.type.kind === 'toggle') {
      const key = toggleKey(source.slice(line.from, line.to))
      const end = shut.has(key) ? toggleChildrenEnd(source, line.from) : null
      if (end !== null && end > line.to) {
        const block = Decoration.replace({ widget: new FoldedWidget(key), block: true }).range(line.to, end)
        ranges.push(block)
        markers.push(block)
        folded.push({ from: line.to, to: end, key })
        fold = { from: line.to, to: end }
      }
    }
    if (line.code) {
      codeRanges(line, line.code, source, ranges, colours)
      return
    }
    // A table off the caret is a grid, and nothing else is drawn over it.
    if (!line.revealed && tables.has(`${line.from}:${line.to}`)) {
      const text = source.slice(line.from, line.to)
      const table = parseTable(text)
      if (table) {
        ranges.push(Decoration.replace({ widget: new TableWidget(table, text), block: true }).range(line.from, line.to))
        return
      }
    }
    const pieces = line.revealed ? [] : line.tokens
    // Every document line the block covers carries its look: a `$$` block is several.
    const first = state.doc.lineAt(line.from)
    const last = state.doc.lineAt(line.to)
    const classes = lineClasses(line) + (line.alone && !line.revealed ? ' nm-display-line' : '')
    for (let number = first.number; number <= last.number; number += 1) {
      ranges.push(Decoration.line({ class: classes }).range(state.doc.line(number).from))
    }
    const { block } = line
    if (line.markerEnd > line.from) {
      if (block.type.kind === 'heading' || block.type.kind === 'quote') {
        // Out of sight while the caret is elsewhere: a heading is read as
        // one and a quotation keeps its bar. On the caret's line the marker
        // is there to see and to edit, in the accent, as the Mac shows it.
        if (line.revealed) {
          ranges.push(syntax.range(line.from, line.markerEnd))
        } else {
          const marker = hidden.range(line.from, line.markerEnd)
          ranges.push(marker)
          markers.push(marker)
        }
      } else if (block.type.kind === 'toggle') {
        const key = toggleKey(source.slice(line.from, line.to))
        const marker = Decoration.replace({ widget: new ToggleWidget(key, shut.has(key)) }).range(line.from, line.markerEnd)
        ranges.push(marker)
        markers.push(marker)
        listMarkers.push(marker)
      } else {
        // A bullet is a bullet, on the caret's line too (Notion): never «- ».
        const shown = line.shownMarker.replace('\t', '')
        const done = block.type.kind === 'task' && block.type.done
        const marker = Decoration.replace({ widget: new MarkerWidget(shown, done) }).range(line.from, line.markerEnd)
        ranges.push(marker)
        markers.push(marker)
        listMarkers.push(marker)
      }
    }
    // The words' own look: a quotation's italics and colour, a done task struck through.
    if (line.to > line.markerEnd) {
      if (block.type.kind === 'quote' && !block.quoteHeading) ranges.push(Decoration.mark({ class: line.quoteEdge?.anchored ? 'nm-quote-words nm-anchored' : 'nm-quote-words' }).range(line.markerEnd, line.to))
      if (block.type.kind === 'task' && block.type.done) ranges.push(Decoration.mark({ class: 'nm-done' }).range(line.markerEnd, line.to))
    }
    if (!line.revealed) for (const token of pieces) tokenRanges(token, source, line, ranges, counted)
    else for (const token of line.tokens) syntaxRanges(token, source, ranges)
  })
  return { decorations: Decoration.set(ranges, true), markers: Decoration.set(markers, true), listMarkers: Decoration.set(listMarkers, true), folded }
}

const decorationField = StateField.define<Drawn>({
  create: (state) => noteDecorations(state),
  update(value, tr) {
    const redrawn = tr.effects.some((effect) => effect.is(setRaw) || effect.is(toggleFold))
    if (!tr.docChanged && !tr.selection && !redrawn) return value
    return noteDecorations(tr.state)
  },
  provide: (field) => [
    EditorView.decorations.from(field, (drawn) => drawn.decorations),
    // The arrow keys step over a marker as over one character.
    EditorView.atomicRanges.of((view) => view.state.field(field).markers),
  ],
})

/** The marker's end a caret put inside a marker — by a press, a drag, anything — goes to; or the head as it is. */
function outsideMarkers(markers: DecorationSet, head: number): number {
  let moved = head
  markers.between(head, head, (from, to) => {
    if (from < head && head < to) {
      moved = to
      return false
    }
    return undefined
  })
  return moved
}

/**
 * A caret that lands on the far end of a fold — where the last folded line
 * ends, which nobody can see — goes on to the next line when it was moving
 * right, and back to the header's end when it was moving left: the fold is
 * stepped over like one character.
 */
function pastFold(folded: Drawn['folded'], head: number, wasAt: number, length: number): number {
  const fold = folded.find((one) => one.to === head)
  if (!fold || wasAt === head) return head
  if (wasAt < head) return fold.to < length ? fold.to + 1 : fold.from
  return fold.from
}

/**
 * A caret at the start of a list's line, or inside its marker, goes to the
 * marker's words — or, when it got there stepping left from those words, on
 * to the end of the line above. There is nothing before a drawn marker to
 * type into: a caret left there (a press on the bullet's left half, Home
 * twice) put what was typed in front of the marker, «x- a», and the item
 * was gone. `wasAt` is null when the caret did not step there — a press, an
 * edit.
 */
function besideListMarker(markers: DecorationSet, head: number, wasAt: number | null): number {
  let moved = head
  markers.between(head, head, (from, to) => {
    if (from <= head && head < to) {
      moved = wasAt === to && from > 0 ? from - 1 : to
      return false
    }
    return undefined
  })
  return moved
}

/** A caret never rests inside a marker: there is nothing there to type into. */
const caretOutOfMarkers = EditorState.transactionFilter.of((tr) => {
  if (!tr.selection) return tr
  const { markers, listMarkers, folded } = tr.state.field(decorationField)
  if (markers.size === 0) return tr
  const wasAt = tr.startState.selection.main.head
  const stepped = !tr.docChanged && !tr.isUserEvent('select.pointer')
  let moved = false
  const ranges = tr.selection.ranges.map((range) => {
    let head = outsideMarkers(markers, range.head)
    if (range.empty) head = besideListMarker(listMarkers, head, stepped ? wasAt : null)
    if (range.empty && !tr.docChanged) head = pastFold(folded, head, wasAt, tr.state.doc.length)
    if (head === range.head) return range
    moved = true
    return range.empty ? EditorSelection.cursor(head) : EditorSelection.range(range.anchor, head)
  })
  if (!moved) return tr
  return [tr, { selection: EditorSelection.create(ranges, tr.selection.mainIndex), sequential: true }]
})

/** A passage found in the note glows for a moment where it is (`reveal`). */
export const flash = StateEffect.define<{ from: number; to: number } | null>()
const flashField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    for (const effect of tr.effects) {
      if (!effect.is(flash)) continue
      if (!effect.value || effect.value.to <= effect.value.from) return Decoration.none
      const builder = new RangeSetBuilder<Decoration>()
      builder.add(effect.value.from, effect.value.to, Decoration.mark({ class: 'nm-flash' }))
      return builder.finish()
    }
    return tr.docChanged ? value.map(tr.changes) : value
  },
  provide: (field) => EditorView.decorations.from(field),
})

/**
 * A deletion that would reach into a fold opens the toggle instead: nothing
 * folded away is taken out of sight — Backspace at the start of the line
 * after a shut toggle, or Delete at the end of its header, shows what it
 * would have deleted.
 */
function unfoldsBeforeDeleting(view: EditorView, direction: -1 | 1): boolean {
  const { folded } = view.state.field(decorationField)
  if (folded.length === 0) return false
  const range = view.state.selection.main
  const from = range.empty ? (direction < 0 ? range.head - 1 : range.head) : range.from
  const to = range.empty ? (direction < 0 ? range.head : range.head + 1) : range.to
  const touched = folded.filter((fold) => from <= fold.to && to >= fold.from)
  if (touched.length === 0) return false
  view.dispatch({ effects: touched.map((fold) => toggleFold.of({ key: fold.key, folded: false })) })
  return true
}

const foldGuard = Prec.high(keymap.of([
  { key: 'Backspace', run: (view) => unfoldsBeforeDeleting(view, -1) },
  { key: 'Delete', run: (view) => unfoldsBeforeDeleting(view, 1) },
]))

export function markdownView(): Extension {
  return [
    rawField, foldedField, decorationField, caretOutOfMarkers, foldGuard, flashField,
    EditorView.editorAttributes.compute([rawField], (state) => ({ class: state.field(rawField) ? 'nm-raw' : '' })),
  ]
}
