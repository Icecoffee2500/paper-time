/**
 * A note as one HTML document — what «Export as PDF…» prints. The same plan
 * the editor draws from (`shared/noteMarkdown.ts`), with no caret anywhere:
 * headings sized, list items under their markers, quotations with their
 * rule, emphasis without its stars, formulas set by MathJax, tables as
 * tables. A passage or a note link is its words; there is nothing to press
 * on paper.
 *
 * Pure apart from the typesetter it is handed, so a test can run it with a
 * stub and no window (`src/test/noteHTML.ts`).
 */
import { blankingCode, emphasisClasses, emphasisPieces, markerClass, planNote, type InlineToken, type PlannedLine } from '../../../shared/noteMarkdown.js'
import { numberFormulas, type MathSetter, type Numbered } from '../../../shared/mathJax.js'
import { parseTable, tableBlocks, type Table } from '../../../shared/noteTable.js'
import { codeBlocks, codeLanguageName, codeOf, type CodeBlock } from '../../../shared/noteCode.js'
import { highlightCode } from '../../../shared/codeHighlight.js'

export interface NoteHTMLOptions {
  /** MathJax, or a stand-in: `typesetter().set` in the window. */
  set: MathSetter['set']
  /** The page's language, for `<html lang>`. */
  lang?: string
  /** The room a numbered formula spreads over, in MathJax's pixels (an `ex`
   *  is eight). The default is an A4 page inside 0.6-inch margins. */
  room?: number
}

/** A4 inside 0.6-inch margins, at 96 dpi, in MathJax's pixels — the note's text is 16px, so an `ex` is 0.442 of that. */
const PAGE_ROOM = Math.round((210 - 2 * 15.24) / 25.4 * 96 * 8 / (16 * 0.442))

const uncounted: Numbered = { start: 0, known: {} }

export function escapeHTML(text: string): string {
  return text.replace(/[&<>"]/g, (one) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[one] ?? one)
}

/** The whole document: a title, the note under it, and the style it is printed with. */
export function noteHTML(title: string, source: string, options: NoteHTMLOptions): string {
  const body = noteBodyHTML(source, options)
  return [
    '<!doctype html>',
    `<html lang="${escapeHTML(options.lang ?? 'en')}">`,
    '<head>',
    '<meta charset="utf-8">',
    `<title>${escapeHTML(title)}</title>`,
    `<style>${NOTE_STYLE}</style>`,
    '</head>',
    '<body>',
    '<article class="note">',
    `<h1 class="note-title">${escapeHTML(title)}</h1>`,
    body,
    '</article>',
    '</body>',
    '</html>',
  ].join('\n')
}

/** The note's lines alone, each as the element it is. */
export function noteBodyHTML(source: string, options: NoteHTMLOptions): string {
  const plan = planNote(source, null)
  const counted = numbering(source, plan, options.set)
  const tables = new Set(tableBlocks(blankingCode(source, codeBlocks(source))).map((one) => `${one.from}:${one.to}`))
  const out: string[] = []
  for (const line of plan) {
    // A block of code is printed whole at its header; its other lines are in it.
    if (line.code) {
      if (line.code.role === 'header') out.push(codeBlockHTML(line.code.block, source))
      continue
    }
    if (tables.has(`${line.from}:${line.to}`)) {
      const table = parseTable(source.slice(line.from, line.to))
      if (table) {
        out.push(tableHTML(table))
        continue
      }
    }
    out.push(lineHTML(line, source, counted, options))
  }
  return out.join('\n')
}

/** As `markdownView.numbering`: the formulas counted from the top, when any takes a number or names one. */
function numbering(source: string, plan: readonly PlannedLine[], set: MathSetter['set']): Map<number, Numbered> {
  const counted = new Map<number, Numbered>()
  if (!source.includes('\\begin') && !source.includes('\\label') && !source.includes('\\ref')) return counted
  const formulas = plan.flatMap((line) => line.tokens.filter((token) => token.kind === 'math'))
  if (!formulas.length) return counted
  const steps = numberFormulas(formulas as { latex: string; display: boolean }[], set)
  formulas.forEach((token, index) => counted.set(token.from, steps[index]))
  return counted
}

function lineHTML(line: PlannedLine, source: string, counted: Map<number, Numbered>, options: NoteHTMLOptions): string {
  const { block } = line
  const inner = contentHTML(line, source, counted, options)
  const classes = ['nm-line']
  switch (block.type.kind) {
    case 'heading': {
      const level = Math.min(6, Math.max(1, block.type.level))
      return `<h${level} class="nm-line nm-h nm-h${level}">${inner}</h${level}>`
    }
    case 'bullet':
    case 'ordered':
    case 'task':
    // A toggle prints open, its children under it as they are.
    case 'toggle': {
      classes.push('nm-list', `nm-indent-${Math.min(block.indent, 6)}`)
      const shown = line.shownMarker.replace('\t', '')
      const done = block.type.kind === 'task' && block.type.done
      const marker = `<span class="${markerClass(shown, done)}">${escapeHTML(shown)}</span>`
      const words = done ? `<span class="nm-done">${inner}</span>` : inner
      return `<div class="${classes.join(' ')}">${marker}${words}</div>`
    }
    case 'quote': {
      classes.push('nm-quote')
      if (block.quoteHeading) classes.push('nm-h', `nm-h${block.quoteHeading}`)
      const edge = line.quoteEdge
      if (edge?.opens) classes.push('nm-q-open')
      if (edge?.closes) classes.push('nm-q-close')
      if (edge?.anchored || block.quoteHeading) classes.push('nm-q-anchored')
      const words = block.quoteHeading ? inner : `<span class="nm-quote-words${edge?.anchored ? ' nm-anchored' : ''}">${inner}</span>`
      return `<div class="${classes.join(' ')}">${words}</div>`
    }
    default:
      // A div, not a p: a formula across lines is a block, and a p cannot hold one.
      if (line.alone) classes.push('nm-display-line')
      return `<div class="${classes.join(' ')}">${inner}</div>`
  }
}

/** The words of a line after its marker, each inline piece as the editor shows it. */
function contentHTML(line: PlannedLine, source: string, counted: Map<number, Numbered>, options: NoteHTMLOptions): string {
  const parts: string[] = []
  let at = line.markerEnd
  for (const token of line.tokens) {
    if (token.from > at) parts.push(escapeHTML(source.slice(at, token.from)))
    parts.push(tokenHTML(token, source, line, counted, options))
    at = token.to
  }
  if (line.to > at) parts.push(escapeHTML(source.slice(at, line.to)))
  return parts.join('')
}

function tokenHTML(token: InlineToken, source: string, line: PlannedLine, counted: Map<number, Numbered>, options: NoteHTMLOptions): string {
  switch (token.kind) {
    case 'anchor': {
      const quote = line.block.type.kind === 'quote'
      const whole = token.from === line.markerEnd && token.to === line.to
      const kind = !token.passage ? 'nm-link' : quote ? (whole ? 'nm-quoted-words' : 'nm-page-chip') : 'nm-chip'
      return `<span class="${kind}">${escapeHTML(token.label)}</span>`
    }
    case 'note':
      return `<span class="nm-note-link">${escapeHTML(token.title || token.id)}</span>`
    case 'dollar':
      return '$'
    case 'emphasis': {
      const tag = token.mono ? 'code' : token.bold ? 'strong' : 'em'
      return `<${tag} class="${emphasisClasses(token)}">${escapeHTML(token.text)}</${tag}>`
    }
    case 'math': {
      const text = source.slice(token.from, token.to)
      const block = text.includes('\n')
      const count = counted.get(token.from) ?? uncounted
      const room = options.room ?? PAGE_ROOM
      const svg = options.set(token.latex, token.display, count.start, count.known, room)?.svg ?? null
      const classes = block ? 'nm-math nm-math-block' : token.display ? 'nm-math nm-math-display' : 'nm-math'
      const alone = line.alone && !block ? ' nm-math-alone' : ''
      if (!svg) return `<span class="nm-math nm-math-raw">${escapeHTML(text)}</span>`
      const tag = block ? 'div' : 'span'
      return `<${tag} class="${classes}${alone}">${fitNumbered(svg, room)}</${tag}>`
    }
  }
}

/**
 * As `markdownView.fitNumbered`: a numbered formula comes laid out for a
 * page as wide as it likes (`width="100%"`, a `min-width`); it is given the
 * page's width so the numbers stand at the right-hand edge and a formula
 * wider than the page is set smaller to fit.
 */
export function fitNumbered(svg: string, room: number): string {
  const open = /<svg\b[^>]*>/.exec(svg)
  if (!open || !/\swidth="100%"/.test(open[0]) || /\sviewBox=/.test(open[0])) return svg
  const style = /\sstyle="([^"]*)"/.exec(open[0])?.[1] ?? ''
  const least = parseFloat(/min-width:\s*(-?[\d.]+)ex/.exec(style)?.[1] ?? '0') * 8
  const high = parseFloat(/\sheight="(-?[\d.]+)ex"/.exec(open[0])?.[1] ?? '0') * 8
  const wide = Math.max(least, room)
  if (!(wide > 0) || !(high > 0)) return svg
  let tag = open[0].replace(/\sstyle="[^"]*"/, ` style="${style.replace(/min-width:\s*[^;]*;?/, '')}"`)
  tag = tag.replace(/<svg\b/, `<svg viewBox="0 0 ${wide} ${high}"`)
  return svg.slice(0, open.index) + tag + svg.slice(open.index + open[0].length)
}

/**
 * A block of code as the editor draws it (`codeRanges`): its language in a
 * chip on the box's cool wash, every line numbered, the code in its colours —
 * and no copy pill, there is nothing to press on paper.
 */
export function codeBlockHTML(block: CodeBlock, source: string): string {
  const code = codeOf(block, source)
  const runs = highlightCode(code, block.language)
  const coloured = (from: number, to: number) => {
    let out = ''
    let at = from
    for (const run of runs) {
      if (run.to <= from || run.from >= to) continue
      const start = Math.max(run.from, from)
      const end = Math.min(run.to, to)
      if (start > at) out += escapeHTML(code.slice(at, start))
      out += `<span class="nm-tok-${run.role}">${escapeHTML(code.slice(start, end))}</span>`
      at = end
    }
    return out + escapeHTML(code.slice(at, to))
  }
  let offset = 0
  const lines = block.lines.map((line, index) => {
    const length = line.to - line.from
    const html = `<div class="nm-codeblock-line"><span class="nm-codeblock-n">${index + 1}</span><span class="nm-codeblock-code">${coloured(offset, offset + length) || '&#8203;'}</span></div>`
    offset += length + 1
    return html
  }).join('')
  const name = block.language ? `<span class="nm-codeblock-lang">${escapeHTML(codeLanguageName(block.language))}</span>` : ''
  return `<div class="nm-codeblock"><div class="nm-codeblock-head">${name}</div><div class="nm-codeblock-body">${lines}</div></div>`
}

/** A table as a table — the editor's `TableWidget`, in markup. */
export function tableHTML(table: Table): string {
  // A cell's emphasis as emphasis, as the editor sets it (`TableWidget`).
  const plain = (cell: string) => emphasisPieces(cell).map((piece) => {
    const classes = emphasisClasses(piece)
    if (!classes) return escapeHTML(piece.text)
    const tag = piece.mono ? 'code' : piece.bold ? 'strong' : 'em'
    return `<${tag} class="${classes}">${escapeHTML(piece.text)}</${tag}>`
  }).join('')
  const align = (index: number) => {
    const one = table.alignments[index]
    return one === 'center' ? 'center' : one === 'right' ? 'right' : 'left'
  }
  const head = table.header.map((cell, index) => `<th style="text-align:${align(index)}">${plain(cell)}</th>`).join('')
  const rows = table.rows.map((row) => `<tr>${row.map((cell, index) => `<td style="text-align:${align(index)}">${plain(cell)}</td>`).join('')}</tr>`).join('')
  return `<div class="nm-table"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>`
}

/**
 * The editor's rules (`style.css`, `.nm-*`), for paper: black on white, the
 * bundled face when the window's folder is at hand (`<base>`) and the
 * system's otherwise, the same sizes and the same hanging indents.
 */
export const NOTE_STYLE = `
@font-face { font-family: 'Pretendard Variable'; src: url('fonts/PretendardVariable.woff2') format('woff2-variations'); font-weight: 45 920; font-style: normal; font-display: block; }
:root { --text: #000; --text-secondary: #555; --text-tertiary: #8a8a8a; --accent: #0a5fd6; --rule: #d6d6d6; }
html, body { margin: 0; padding: 0; background: #fff; color: var(--text); }
body { font-family: 'Pretendard Variable', Pretendard, -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, 'Apple SD Gothic Neo', 'Malgun Gothic', sans-serif; font-size: 16px; line-height: 1.48; word-break: keep-all; overflow-wrap: break-word; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.note { max-width: 100%; }
.note-title { font-size: 28px; font-weight: 700; line-height: 1.2; margin: 0 0 18px; }
.nm-line { margin: 0; padding: 0 0 11px; min-height: 1.48em; }
.nm-h { padding-top: 18px; padding-bottom: 6px; font-weight: 600; line-height: 1.25; margin: 0; }
h1.nm-h, .nm-h1 { font-size: 24px; font-weight: 700; }
h2.nm-h, .nm-h2 { font-size: 20px; }
h3.nm-h, .nm-h3 { font-size: 17.44px; }
h4.nm-h, h5.nm-h, h6.nm-h { font-size: 16px; }
.nm-list { text-indent: -14.88px; }
.nm-indent-0 { padding-left: 24px; }
.nm-indent-1 { padding-left: 48px; }
.nm-indent-2 { padding-left: 72px; }
.nm-indent-3 { padding-left: 96px; }
.nm-indent-4 { padding-left: 120px; }
.nm-indent-5 { padding-left: 144px; }
.nm-indent-6 { padding-left: 168px; }
.nm-marker { display: inline-block; width: 14.88px; text-indent: 0; color: var(--text-secondary); white-space: nowrap; }
.nm-marker-label { width: auto; min-width: 48px; margin-left: -33.12px; padding-right: 0.3em; box-sizing: border-box; text-align: right; }
.nm-indent-0 .nm-marker-label { min-width: 24px; margin-left: -9.12px; }
.nm-done { color: var(--text-secondary); text-decoration: line-through; }
.nm-quote { position: relative; padding: 3px 0 3px 20.4px; }
.nm-quote::before, .nm-quote::after { content: ''; position: absolute; top: 0; bottom: 0; left: 7.4px; }
.nm-quote::before { width: 2.5px; background: #b4b4b4; }
.nm-quote.nm-q-anchored::before { background: rgba(10, 95, 214, 0.55); }
.nm-quote.nm-q-anchored::after { right: 0; background: rgba(10, 95, 214, 0.05); }
.nm-quote.nm-q-open::before, .nm-quote.nm-q-open::after { border-top-left-radius: 1.25px; border-top-right-radius: 4px; }
.nm-quote.nm-q-close::before, .nm-quote.nm-q-close::after { border-bottom-left-radius: 1.25px; border-bottom-right-radius: 4px; }
.nm-quote.nm-q-open { margin-top: 3px; }
.nm-quote.nm-q-close { margin-bottom: 8px; }
.nm-quote-words { font-style: italic; color: var(--text-secondary); }
.nm-quote-words.nm-anchored { color: var(--text); }
.nm-chip, .nm-page-chip { color: var(--accent); background: rgba(10, 95, 214, 0.12); border-radius: 5.5px; padding: 1.5px 4.5px; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
.nm-page-chip { font-size: 12.16px; font-style: normal; }
.nm-quoted-words { font-style: italic; color: var(--text); }
.nm-link, .nm-note-link { color: var(--accent); text-decoration: underline; }
.nm-bold { font-weight: 700; }
.nm-italic { font-style: italic; }
.nm-mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85em; color: #eb5757; background: rgba(135, 131, 120, 0.15); border-radius: 4px; padding: 0.2em 0.4em; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
.nm-math svg { vertical-align: middle; }
.nm-math-display, .nm-math-block { max-width: 100%; }
.nm-math-display svg, .nm-math-block svg { max-width: 100%; height: auto; }
.nm-math-display { display: inline-block; }
.nm-math-block { display: block; text-align: center; padding: 6px 0 11px; break-inside: avoid; }
.nm-display-line { text-align: center; }
.nm-math-alone { display: inline-block; width: 100%; text-align: center; }
.nm-math-raw { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 14.7px; color: var(--text-secondary); }
.nm-codeblock { margin: 6px 0 17px; border-radius: 14px; background: rgba(30, 90, 200, 0.05); }
.nm-codeblock-head { display: flex; align-items: center; height: 34px; padding: 0 6px; }
.nm-codeblock-lang { height: 22px; padding: 0 9px; border-radius: 11px; line-height: 22px; font-size: 12px; font-weight: 600; color: var(--accent); background: rgba(10, 95, 214, 0.12); }
.nm-codeblock-body { padding: 2px 14px 14px 0; }
.nm-codeblock-line { display: flex; break-inside: avoid; }
.nm-codeblock-n { flex: none; width: 33px; padding-right: 9px; text-align: right; font: 11.52px/18px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-variant-numeric: tabular-nums; color: var(--text-tertiary); }
.nm-codeblock-code { flex: 1; min-width: 0; font: 13.6px/18px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace, 'Pretendard Variable', Pretendard; white-space: pre-wrap; overflow-wrap: anywhere; tab-size: 4; }
.nm-tok-keyword { color: #9b2393; }
.nm-tok-string { color: #c41a16; }
.nm-tok-number { color: #1c00cf; }
.nm-tok-comment { color: #5d6c79; }
.nm-tok-type { color: #0b4f79; }
.nm-tok-function { color: #326d74; }
.nm-tok-builtIn { color: #6c36a9; }
.nm-tok-meta { color: #643820; }
.nm-tok-attribute { color: #815f03; }
.nm-table { margin: 4px 0 6px; max-width: 100%; break-inside: avoid; }
.nm-table table { border-collapse: separate; border-spacing: 0; border: 1px solid var(--rule); border-radius: 6px; overflow: hidden; font-size: inherit; line-height: 1.45; }
.nm-table th, .nm-table td { padding: 5px 9px; vertical-align: top; }
.nm-table th { font-weight: 650; background: rgba(0, 0, 0, 0.05); }
.nm-table th + th, .nm-table td + td { border-left: 1px solid var(--rule); }
.nm-table tr + tr td, .nm-table tbody tr:first-child td { border-top: 1px solid var(--rule); }
`
