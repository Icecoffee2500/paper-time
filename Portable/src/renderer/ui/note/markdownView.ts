/**
 * The note set as it is typed — the Mac's `NoteMarkdown` render, as
 * CodeMirror decorations over the Markdown itself (`shared/noteMarkdown.ts`
 * is the plan; `src/test/noteMarkdown.ts` checks it against the Mac).
 *
 * The file is still the Markdown, character for character: nothing here
 * changes the text, it only decides how each piece of it is drawn. The line
 * under the caret is drawn as written, markers in the tertiary colour, so the
 * line being edited is the source and the rest is read set. A passage is a
 * chip, a note link its title, a formula set by MathJax, emphasis without its
 * stars; headings are sized, list items hang under their first word, and a
 * quotation has its rule and — when it came off a page — its wash.
 */
import { RangeSetBuilder, StateEffect, StateField, type EditorState, type Extension, type Range } from '@codemirror/state'
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view'
import { planNote, type InlineToken, type PlannedLine } from '../../../shared/noteMarkdown.js'
import { parseTable, tableBlocks, type Table } from '../../../shared/noteTable.js'
import { typesetNumbered, typesetter } from '../../sketchMath.js'
import { numberFormulas, signature, type Numbered } from '../../../shared/mathJax.js'

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
    span.className = `nm-marker${this.text === '•' ? '' : ' nm-marker-wide'}${this.done ? ' nm-marker-done' : ''}`
    span.textContent = this.text
    return span
  }
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
    const plain = (cell: string) => cell.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '')
    const align = (index: number) => {
      const one = this.table.alignments[index]
      return one === 'center' ? 'center' : one === 'right' ? 'right' : 'left'
    }
    const head = grid.createTHead().insertRow()
    this.table.header.forEach((cell, index) => {
      const th = document.createElement('th')
      th.textContent = plain(cell)
      th.style.textAlign = align(index)
      head.append(th)
    })
    const body = grid.createTBody()
    for (const row of this.table.rows) {
      const tr = body.insertRow()
      row.forEach((cell, index) => {
        const td = tr.insertCell()
        td.textContent = plain(cell)
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

const hidden = Decoration.replace({})

function lineClasses(line: PlannedLine): string {
  const { block } = line
  const classes = ['nm-line']
  switch (block.type.kind) {
    case 'heading': classes.push('nm-h', `nm-h${block.type.level}`); break
    case 'bullet':
    case 'ordered':
    case 'task': classes.push('nm-list', `nm-indent-${Math.min(block.indent, 6)}`); break
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
      const width = token.bold ? 2 : 1
      out.push(hidden.range(from, from + width))
      out.push(Decoration.mark({ class: token.mono ? 'nm-mono' : token.bold ? 'nm-bold' : 'nm-italic' }).range(from + width, to - width))
      out.push(hidden.range(to - width, to))
      return
    }
  }
}

export function noteDecorations(state: EditorState): DecorationSet {
  if (state.field(rawField, false)) return Decoration.none
  const source = state.doc.toString()
  const heads = state.selection.ranges.map((range) => range.head)
  // Planned with no caret, so every line has its pieces; a line with a caret
  // on it is then drawn as written and its pieces are left alone.
  const plan = planNote(source, null).map((line) => ({ ...line, revealed: heads.some((head) => head >= line.from && head <= line.to) }))
  const ranges: Range<Decoration>[] = []
  const counted = numbering(source, plan)
  const tables = new Set(tableBlocks(source).map((one) => `${one.from}:${one.to}`))
  plan.forEach((line) => {
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
      if (line.revealed) ranges.push(Decoration.mark({ class: 'nm-syntax' }).range(line.from, line.markerEnd))
      else if (block.type.kind === 'heading' || block.type.kind === 'quote') ranges.push(hidden.range(line.from, line.markerEnd))
      else {
        const shown = line.shownMarker.replace('\t', '')
        const done = block.type.kind === 'task' && block.type.done
        ranges.push(Decoration.replace({ widget: new MarkerWidget(shown, done) }).range(line.from, line.markerEnd))
      }
    }
    // The words' own look: a quotation's italics and colour, a done task struck through.
    if (line.to > line.markerEnd) {
      if (block.type.kind === 'quote' && !block.quoteHeading) ranges.push(Decoration.mark({ class: line.quoteEdge?.anchored ? 'nm-quote-words nm-anchored' : 'nm-quote-words' }).range(line.markerEnd, line.to))
      if (block.type.kind === 'task' && block.type.done) ranges.push(Decoration.mark({ class: 'nm-done' }).range(line.markerEnd, line.to))
    }
    if (!line.revealed) for (const token of pieces) tokenRanges(token, source, line, ranges, counted)
  })
  return Decoration.set(ranges, true)
}

const decorationField = StateField.define<DecorationSet>({
  create: (state) => noteDecorations(state),
  update(value, tr) {
    const rawChanged = tr.effects.some((effect) => effect.is(setRaw))
    if (!tr.docChanged && !tr.selection && !rawChanged) return value
    return noteDecorations(tr.state)
  },
  provide: (field) => EditorView.decorations.from(field),
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

export function markdownView(): Extension {
  return [
    rawField, decorationField, flashField,
    EditorView.editorAttributes.compute([rawField], (state) => ({ class: state.field(rawField) ? 'nm-raw' : '' })),
  ]
}
