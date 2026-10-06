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
import { codeRowAt, openingFence, wantsClosing } from './noteCode.js'

export type BlockKind =
  | { kind: 'plain' }
  | { kind: 'heading'; level: number }
  | { kind: 'quote' }
  | { kind: 'bullet' }
  | { kind: 'ordered'; number: number }
  | { kind: 'task'; done: boolean }
  /** «+ Title»: a toggle, whose children are the deeper-indented lines under it (Notion). */
  | { kind: 'toggle' }

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
/** A toggle's marker: a plus and one space, which every other reader shows as a bullet. */
const TOGGLE = /^\+ /

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
  if ((match = TOGGLE.exec(body))) {
    return { type: { kind: 'toggle' }, marker: lead + match[0], content: body.slice(match[0].length), indent }
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
    // A toggle's next line is its first child: a plain line, one step in.
    case 'toggle': return `${indent}  `
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
  // A line of fenced code has no marker, whatever it starts with: `- x` in
  // code is not a bullet to carry on (`codeReturnEdit` has code's Return).
  if (codeRowAt(text, caret)) return null
  const { start, line } = lineAt(text, caret)
  const block = blockOf(line)
  if (block.type.kind === 'plain' || block.marker.length === 0) {
    // An empty child line of a toggle steps out to the toggle's own level,
    // as an empty nested item does: Return twice leaves the toggle.
    if (block.type.kind === 'plain' && line.length >= 2 && /^ +$/.test(line) && caret === start + line.length) {
      const header = toggleAbove(text, start, line.length)
      if (header) {
        const lead = ' '.repeat(header.indent * 2)
        return { from: start, to: start + line.length, insert: lead, caret: start + lead.length }
      }
    }
    return null
  }
  if (trimWhitespace(block.content).length === 0) {
    // An empty nested item steps out a level first, as Notion's does; at the
    // left already, the marker goes rather than another being made.
    if (block.indent > 0) return { from: start, to: start + 2, insert: '', caret: Math.max(start, caret - 2) }
    const markerEnd = start + block.marker.length
    const tail = text.slice(markerEnd, caret)
    return { from: start, to: Math.max(caret, markerEnd), insert: `${tail}\n`, caret: start + tail.length + 1 }
  }
  // A heading carries nothing on: the plain new line is right.
  if (continuation(block) === '') return null
  const next = `\n${continuation(block)}`
  return { from: caret, to: caret, insert: next, caret: caret + next.length }
}

/**
 * The toggle a line at `lineStart` with `spaces` of indentation is a child
 * of: the nearest line above with less indentation, when that line is a
 * toggle header. Blank lines between are skipped; a line as deep or deeper
 * is a sibling child. Null when the line is under no toggle.
 */
function toggleAbove(text: string, lineStart: number, spaces: number): Block | null {
  let end = lineStart - 1
  while (end >= 0) {
    const start = text.lastIndexOf('\n', end - 1) + 1
    const line = text.slice(start, end)
    if (line.trim().length > 0) {
      const lead = line.length - line.trimStart().length
      if (lead < spaces) {
        const block = blockOf(line)
        return block.type.kind === 'toggle' ? block : null
      }
    }
    end = start - 1
  }
  return null
}

/**
 * Where a toggle's children end: the last line under the header at
 * `headerStart` that is indented deeper than it — a blank line counting when
 * the next non-blank line is still deeper. The offset is the end of that
 * line, without its break; null when the header has no children.
 */
export function toggleChildrenEnd(text: string, headerStart: number): number | null {
  const header = lineAt(text, headerStart)
  const spaces = header.line.length - header.line.trimStart().length
  let at = header.start + header.line.length
  let lastChildEnd: number | null = null
  while (at < text.length && text[at] === '\n') {
    const start = at + 1
    const end = text.indexOf('\n', start)
    const line = text.slice(start, end < 0 ? text.length : end)
    if (line.trim().length > 0) {
      const lead = line.length - line.trimStart().length
      if (lead <= spaces) break
      lastChildEnd = start + line.length
    }
    at = start + line.length
  }
  return lastChildEnd
}

/** What Tab (`by: 1`) or Shift-Tab (`by: -1`) does: null off a list line. */
export function indentEdit(text: string, caret: number, by: 1 | -1): LineEdit | null {
  if (codeRowAt(text, caret)) return null
  const { start, line } = lineAt(text, caret)
  const kind = blockOf(line).type.kind
  if (kind !== 'bullet' && kind !== 'ordered' && kind !== 'task' && kind !== 'toggle') return null
  if (by > 0) return { from: start, to: start, insert: '  ', caret: caret + 2 }
  // Already at the left: the key is taken and nothing moves.
  if (!line.startsWith('  ')) return { from: start, to: start, insert: '', caret }
  return { from: start, to: start + 2, insert: '', caret: Math.max(start, caret - 2) }
}

/**
 * What Backspace does with the caret right after a marker, nothing selected
 * (Notion): a nested item steps out a level; one at the left loses its
 * marker and is plain words again. Null anywhere else — the ordinary
 * Backspace is right there.
 */
export function backspaceEdit(text: string, caret: number): LineEdit | null {
  if (codeRowAt(text, caret)) return null
  const { start, line } = lineAt(text, caret)
  const block = blockOf(line)
  if (block.type.kind === 'plain' || block.marker.length === 0) return null
  if (caret !== start + block.marker.length) return null
  if (block.indent > 0) return { from: start, to: start + 2, insert: '', caret: caret - 2 }
  return { from: start, to: caret, insert: '', caret: start }
}

// MARK: - Emphasis and wrapping

/** An edit that leaves something selected afterwards. */
export interface SelectionEdit {
  from: number
  to: number
  insert: string
  selectFrom: number
  selectTo: number
}

export type EmphasisMark = '**' | '*' | '`' | '$'

/**
 * ⌘B, ⌘I, ⌘E, ⌘⇧M: the mark put around the selection, or taken off it when it
 * is already there — whether the selection took the marks in or stopped
 * just inside them. With nothing selected, an empty pair with the caret
 * between, and the pair taken away again when the caret already stands in
 * one.
 */
export function toggleEmphasisEdit(text: string, from: number, to: number, mark: EmphasisMark): SelectionEdit {
  const [lo, hi] = from <= to ? [from, to] : [to, from]
  const width = mark.length
  if (lo === hi) {
    if (text.slice(lo - width, lo) === mark && text.slice(lo, lo + width) === mark) {
      return { from: lo - width, to: lo + width, insert: '', selectFrom: lo - width, selectTo: lo - width }
    }
    return { from: lo, to: lo, insert: mark + mark, selectFrom: lo + width, selectTo: lo + width }
  }
  const selected = text.slice(lo, hi)
  // The marks inside the selection: «**bold**» selected whole.
  if (wrappedBy(selected, mark)) {
    const inner = selected.slice(width, selected.length - width)
    return { from: lo, to: hi, insert: inner, selectFrom: lo, selectTo: lo + inner.length }
  }
  // The marks just outside it: «bold» selected inside its stars.
  if (lo >= width && wrappedBy(text.slice(lo - width, hi + width), mark)) {
    return { from: lo - width, to: hi + width, insert: selected, selectFrom: lo - width, selectTo: lo - width + selected.length }
  }
  return { from: lo, to: hi, insert: mark + selected + mark, selectFrom: lo + width, selectTo: lo + width + selected.length }
}

/**
 * Whether `wrapped` is `mark`, something, `mark` — read as Markdown reads
 * stars: «**bold**» is not in italics, and «***both***» is, the odd star
 * being the italic one.
 */
function wrappedBy(wrapped: string, mark: EmphasisMark): boolean {
  const width = mark.length
  if (wrapped.length < 2 * width || !wrapped.startsWith(mark) || !wrapped.endsWith(mark)) return false
  if (mark === '`' || mark === '$') return true
  const lead = wrapped.length - wrapped.replace(/^\*+/, '').length
  const trail = wrapped.length - wrapped.replace(/\*+$/, '').length
  if (mark === '*') return lead % 2 === 1 && trail % 2 === 1
  return lead >= 2 && trail >= 2
}

/** The closing character each opening one takes (Obsidian's pairs). */
const PAIRS: Record<string, string> = {
  '(': ')', '[': ']', '{': '}', '"': '"', "'": "'", '`': '`', '*': '*', '_': '_', '$': '$', '~': '~',
}

/**
 * An opening character typed over a selection wraps it rather than replacing
 * it, and the words stay selected inside the pair. Null when the character
 * opens nothing, and the typing goes in as typed.
 */
export function wrapEdit(text: string, from: number, to: number, typed: string): SelectionEdit | null {
  const close = PAIRS[typed]
  if (close === undefined) return null
  const [lo, hi] = from <= to ? [from, to] : [to, from]
  if (lo === hi) return null
  // In code a star is a star: only brackets and quotes wrap what is selected.
  if (!CODE_WRAPS.has(typed) && codeRowAt(text, lo)) return null
  const selected = text.slice(lo, hi)
  return { from: lo, to: hi, insert: typed + selected + close, selectFrom: lo + 1, selectTo: lo + 1 + selected.length }
}

/**
 * Notion's to-do: «[]» and a space at the start of a line become an empty
 * checkbox. Null unless the line so far, after its indentation, is exactly
 * that.
 */
export function todoShortcutEdit(text: string, caret: number): LineEdit | null {
  if (codeRowAt(text, caret)) return null
  const { start } = lineAt(text, caret)
  const sofar = text.slice(start, caret)
  const spaces = sofar.length - sofar.trimStart().length
  if (sofar.slice(spaces) !== '[]') return null
  const insert = '- [ ] '
  return { from: start + spaces, to: caret, insert, caret: start + spaces + insert.length }
}

/**
 * Notion's toggle: «--» and a space at the start of a line become «+ », a
 * toggle header whose children are the indented lines under it. Null unless
 * the line so far, after its indentation, is exactly the two dashes.
 */
export function toggleShortcutEdit(text: string, caret: number): LineEdit | null {
  if (codeRowAt(text, caret)) return null
  const { start } = lineAt(text, caret)
  const sofar = text.slice(start, caret)
  const spaces = sofar.length - sofar.trimStart().length
  if (sofar.slice(spaces) !== '--') return null
  const insert = '+ '
  return { from: start + spaces, to: caret, insert, caret: start + spaces + insert.length }
}

// MARK: - Auto-pairs

/** The openers that take a different closer. */
const OPENERS: Record<string, string> = { '(': ')', '[': ']', '{': '}' }
/** The characters that close themselves — paired only between non-words, so «don't» and 5$ stay as typed. */
const SYMMETRIC = new Set(['"', '$', '`', '*', '_', '~'])
/** The symmetric characters that double up — `**` and `$$` are marks of their own, as Obsidian knows. */
const DOUBLING = new Set(['*', '_', '$', '~'])
/** Every character a typist may step over when it is already there. */
const CLOSERS = new Set([')', ']', '}', ...SYMMETRIC])
const WORD = /[\p{L}\p{N}]/u

/**
 * What typing one character does at a caret with nothing selected, besides
 * going in — the Mac's rule, keystroke for keystroke. A closer that is
 * already next is stepped over; unless the key is doubling a star, an
 * underscore, a dollar or a tilde it just typed between non-words («*|*»
 * and another star is «**|**», «$|$» and a dollar «$$|$$»). An opener
 * brings its closer with it, the caret between; a quote, a dollar, a
 * backtick, a star, an underscore or a tilde does the same between
 * non-words. Null when the character simply goes in.
 */
export function pairEdit(text: string, caret: number, typed: string): LineEdit | null {
  if (typed.length !== 1) return null
  const fence = fenceTypingEdit(text, caret, typed)
  if (fence) return fence
  if (codeRowAt(text, caret)?.role === 'line') return codePairEdit(text, caret, typed)
  const next = text[caret] ?? ''
  const before = caret > 0 ? text[caret - 1] : ''
  if (CLOSERS.has(typed) && next === typed) {
    const beforeThat = caret > 1 ? text[caret - 2] : ''
    const doubling = DOUBLING.has(typed) && before === typed && (beforeThat === '' || !WORD.test(beforeThat))
    if (!doubling) return { from: caret, to: caret, insert: '', caret: caret + 1 }
  }
  const closer = OPENERS[typed]
  if (closer !== undefined) return { from: caret, to: caret, insert: typed + closer, caret: caret + 1 }
  if (!SYMMETRIC.has(typed)) return null
  if (WORD.test(before) || WORD.test(next)) return null
  return { from: caret, to: caret, insert: typed + typed, caret: caret + 1 }
}

/** Backspace between an empty pair — «(|)», «$|$» — takes both away. Null anywhere else. */
export function pairBackspaceEdit(text: string, caret: number): LineEdit | null {
  if (caret < 1 || caret >= text.length) return null
  const before = text[caret - 1]
  const after = text[caret]
  const pair = OPENERS[before] === after || (SYMMETRIC.has(before) && before === after)
  if (!pair) return null
  return { from: caret - 1, to: caret + 1, insert: '', caret: caret - 1 }
}

/** What wraps a selection in code: brackets and quotes — never a star, an underscore, a dollar or a tilde. */
const CODE_WRAPS = new Set(['(', '[', '{', '"', "'", '`'])
/** What closes itself in code. */
const CODE_QUOTES = new Set(['"', "'", '`'])

/**
 * The third backtick (or tilde) of a fence. A line of nothing but two of
 * them before the caret, and nothing but more of them after it, takes the
 * third as typed — and the marks after the caret, which the pairs put
 * there, go. Typed a key at a time ``` was otherwise ```` with the caret
 * before the last: the first brings its closer, the second steps over it,
 * and the third brought another, so «```python» was never a fence.
 */
export function fenceTypingEdit(text: string, caret: number, typed: string): LineEdit | null {
  if (typed !== '`' && typed !== '~') return null
  const { start, line } = lineAt(text, caret)
  const before = text.slice(start, caret)
  const marks = before.replace(/^ {0,3}/, '')
  if (marks.length < 2 || [...marks].some((one) => one !== typed)) return null
  const after = line.slice(caret - start)
  if ([...after].some((one) => one !== typed)) return null
  return { from: caret, to: start + line.length, insert: typed, caret: caret + 1 }
}

/**
 * Pairs in a line of code, as a code editor makes them: a bracket brings its
 * closer, and a quote does between non-words; a closer already next is
 * stepped over. Markdown's own marks — a star, an underscore, a dollar, a
 * tilde — are only characters there.
 */
function codePairEdit(text: string, caret: number, typed: string): LineEdit | null {
  const next = text[caret] ?? ''
  const before = caret > 0 ? text[caret - 1] : ''
  if ((CODE_QUOTES.has(typed) || typed === ')' || typed === ']' || typed === '}') && next === typed) {
    return { from: caret, to: caret, insert: '', caret: caret + 1 }
  }
  const closer = OPENERS[typed]
  if (closer !== undefined) return { from: caret, to: caret, insert: typed + closer, caret: caret + 1 }
  if (!CODE_QUOTES.has(typed)) return null
  if (WORD.test(before) || WORD.test(next) || CODE_QUOTES.has(before)) return null
  return { from: caret, to: caret, insert: typed + typed, caret: caret + 1 }
}

/** A block's indent: four spaces, as most code is written. */
export const CODE_INDENT = '    '

/**
 * Return in a block, as a code editor has it (`insertCodeNewline`): the next
 * line starts where this one did, and one indent further after a `:` or an
 * opening bracket. Return at the end of an opening fence closes the block
 * below it and leaves the caret on the empty line between (`wantsClosing`).
 * Null on a closing fence and outside code — the plain new line is right.
 */
export function codeReturnEdit(text: string, caret: number): LineEdit | null {
  const row = codeRowAt(text, caret)
  if (!row) return null
  const written = text.slice(row.line.from, row.line.to).replace(/\r$/, '')
  const lineEnd = row.line.from + written.length
  switch (row.role) {
    case 'header': {
      const fence = openingFence(written)
      if (caret !== lineEnd || !fence || !wantsClosing(row.block, text)) return null
      const lead = /^ */.exec(written)?.[0] ?? ''
      const insert = `\n\n${lead}${fence.character.repeat(fence.length)}`
      return { from: lineEnd, to: lineEnd, insert, caret: lineEnd + 1 }
    }
    case 'line': {
      const before = text.slice(row.line.from, caret)
      const indent = /^[ \t]*/.exec(before)?.[0] ?? ''
      const last = before.replace(/[ \t]+$/, '').slice(-1)
      const insert = `\n${indent}${last !== '' && ':{(['.includes(last) ? CODE_INDENT : ''}`
      return { from: caret, to: caret, insert, caret: caret + insert.length }
    }
    case 'close': return null
  }
}

/**
 * Tab and Shift-Tab in a block's code (`indentCode`): four spaces in at the
 * caret, or every line of the selection in or out by four. Null outside a
 * block's lines of code.
 */
export function codeIndentEdit(text: string, from: number, to: number, by: 1 | -1): SelectionEdit | null {
  const [lo, hi] = from <= to ? [from, to] : [to, from]
  const row = codeRowAt(text, lo)
  if (!row || row.role !== 'line') return null
  if (by > 0 && lo === hi) return { from: lo, to: lo, insert: CODE_INDENT, selectFrom: lo + CODE_INDENT.length, selectTo: lo + CODE_INDENT.length }
  const start = text.lastIndexOf('\n', lo - 1) + 1
  // A selection that ends at the start of a line does not take that line.
  const last = hi > lo && text[hi - 1] === '\n' ? hi - 1 : hi
  const lineEnd = text.indexOf('\n', last)
  const end = lineEnd < 0 ? text.length : lineEnd
  const written = text.slice(start, end)
  let removedBeforeCaret = 0
  const changed = written.split('\n').map((line, index) => {
    if (by > 0) return line.length === 0 ? line : CODE_INDENT + line
    const spaces = /^ {0,4}/.exec(line)?.[0].length ?? 0
    if (index === 0) removedBeforeCaret = spaces
    return line.slice(spaces)
  })
  const insert = changed.join('\n')
  if (lo === hi) {
    const caret = Math.max(start, lo - removedBeforeCaret)
    return { from: start, to: end, insert, selectFrom: caret, selectTo: caret }
  }
  return { from: start, to: end, insert, selectFrom: start, selectTo: start + insert.length }
}

// MARK: - Home

/**
 * Where Home (⌘←) goes on a marked line, from `head` characters into it:
 * after the marker when the caret is further in than that, else to the very
 * start — the two places a line with a marker has. Null on a line with no
 * marker, where the editor's own Home is right.
 */
export function homeTarget(line: string, head: number): number | null {
  const block = blockOf(line)
  if (block.marker.length === 0) return null
  const contentStart = block.marker.length
  return head > contentStart ? contentStart : 0
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
