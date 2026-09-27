/**
 * What a line of a note is doing at its start — the Mac's
 * `NoteMarkdown.Block(line:)`, the half that reads the marker — and what
 * Return and Tab do with it (`NoteTextView.insertNewline`, `insertTab`).
 *
 * Return continues what the line was doing: another bullet, the next
 * number, another empty checkbox — and an empty item ends the list, which
 * is how every outliner behaves and how nobody has to think about it. Tab
 * indents the item the caret is in rather than dropping a tab into the
 * middle of a sentence.
 */
import { trimWhitespace } from './zettel.js'

export type BlockKind =
  | { kind: 'plain' }
  | { kind: 'heading'; level: number }
  | { kind: 'quote' }
  | { kind: 'bullet' }
  | { kind: 'ordered'; number: number }
  | { kind: 'task'; done: boolean }

export interface Block {
  type: BlockKind
  marker: string
  content: string
  indent: number
  /** A quoted line that was a section title on the page: its level. The
   *  «###» is part of the marker, hidden with the «>». */
  quoteHeading?: number
}

/** ICU's `\s` — the Mac's patterns are written with it. */
const S = '[\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]'
const HEADING = new RegExp(`^(#{1,6})${S}+`, 'u')
const BULLET = new RegExp(`^[-*+]${S}+`, 'u')
const ORDERED = new RegExp(`^(\\d{1,3})[.)]${S}+`, 'u')
const TASK = new RegExp(`^([-*+])${S}+\\[([ xX])\\]${S}+`, 'u')

export function blockOf(line: string): Block {
  let spaces = 0
  while (spaces < line.length && line[spaces] === ' ') spaces += 1
  const indent = Math.floor(spaces / 2)
  const body = line.slice(spaces)
  const lead = line.slice(0, spaces)
  const plain: Block = { type: { kind: 'plain' }, marker: '', content: line, indent }
  if (!/^[#\-*+>0-9]/.test(body)) return plain
  let match: RegExpExecArray | null
  if ((match = TASK.exec(body))) {
    return { type: { kind: 'task', done: match[2].toLowerCase() === 'x' }, marker: lead + match[0], content: body.slice(match[0].length), indent }
  }
  if ((match = HEADING.exec(body))) {
    return { type: { kind: 'heading', level: match[1].length }, marker: lead + match[0], content: body.slice(match[0].length), indent }
  }
  if ((match = BULLET.exec(body))) {
    return { type: { kind: 'bullet' }, marker: lead + match[0], content: body.slice(match[0].length), indent }
  }
  if ((match = ORDERED.exec(body))) {
    return { type: { kind: 'ordered', number: Number(match[1]) || 1 }, marker: lead + match[0], content: body.slice(match[0].length), indent }
  }
  if (body.startsWith('>')) {
    const after = body.startsWith('> ') ? 2 : 1
    let marker = lead + body.slice(0, after)
    let content = body.slice(after)
    // A quotation can hold the section it was taken from; the «###» is part
    // of the marker.
    const heading = HEADING.exec(content)
    let quoteHeading: number | undefined
    if (heading) {
      marker += heading[0]
      quoteHeading = heading[1].length
      content = content.slice(heading[0].length)
    }
    return { type: { kind: 'quote' }, marker, content, indent, ...(quoteHeading ? { quoteHeading } : {}) }
  }
  return plain
}

/** The marker the next line starts with. */
export function continuation(block: Block): string {
  const indent = '  '.repeat(block.indent)
  switch (block.type.kind) {
    case 'bullet': return `${indent}- `
    case 'ordered': return `${indent}${block.type.number + 1}. `
    case 'task': return `${indent}- [ ] `
    case 'quote': return `${indent}> `
    default: return ''
  }
}

/** The line the caret is on: where it starts and what it says, without its break. */
function lineAt(text: string, caret: number): { start: number; line: string } {
  const start = text.lastIndexOf('\n', caret - 1) + 1
  const end = text.indexOf('\n', caret)
  return { start, line: text.slice(start, end < 0 ? text.length : end).replace(/\r$/, '') }
}

/** An edit to make: put `insert` over [from, to), then the caret goes to `caret`. */
export interface LineEdit {
  from: number
  to: number
  insert: string
  caret: number
}

/**
 * What Return does at a caret with nothing selected: null when the line is
 * no list, and the plain new line is right.
 */
export function returnEdit(text: string, caret: number): LineEdit | null {
  const { start, line } = lineAt(text, caret)
  const block = blockOf(line)
  if (block.type.kind === 'plain' || block.marker.length === 0) return null
  if (trimWhitespace(block.content).length === 0) {
    // An empty item: the marker goes, rather than another being made.
    const markerEnd = start + block.marker.length
    const tail = text.slice(markerEnd, caret)
    return { from: start, to: Math.max(caret, markerEnd), insert: `${tail}\n`, caret: start + tail.length + 1 }
  }
  // A heading carries nothing on: the plain new line is right.
  if (continuation(block) === '') return null
  const next = `\n${continuation(block)}`
  return { from: caret, to: caret, insert: next, caret: caret + next.length }
}

/** What Tab (`by: 1`) or Shift-Tab (`by: -1`) does: null off a list line. */
export function indentEdit(text: string, caret: number, by: 1 | -1): LineEdit | null {
  const { start, line } = lineAt(text, caret)
  const kind = blockOf(line).type.kind
  if (kind !== 'bullet' && kind !== 'ordered' && kind !== 'task') return null
  if (by > 0) return { from: start, to: start, insert: '  ', caret: caret + 2 }
  // Already at the left: the key is taken and nothing moves.
  if (!line.startsWith('  ')) return { from: start, to: start, insert: '', caret }
  return { from: start, to: start + 2, insert: '', caret: Math.max(start, caret - 2) }
}

// MARK: - [[ completion

/** The `[[` open on the caret's line and what is typed after it — `openWikiLink(in:)`. */
export function openWikiLink(text: string, caret: number): { from: number; query: string } | null {
  const { start } = lineAt(text, caret)
  const before = text.slice(start, caret)
  const opened = before.lastIndexOf('[[')
  if (opened < 0) return null
  const query = before.slice(opened + 2)
  if (query.includes(']]') || query.includes('\n')) return null
  return { from: start + opened, query }
}

/** The edit that accepting a note makes: `[[id|title]]` over the open link, and a typed `]]` swallowed. */
export function acceptWikiLink(text: string, caret: number, id: string, title: string): LineEdit | null {
  const open = openWikiLink(text, caret)
  if (!open) return null
  const to = text.slice(caret, caret + 2) === ']]' ? caret + 2 : caret
  const insert = `[[${id}|${title}]]`
  return { from: open.from, to, insert, caret: open.from + insert.length }
}
