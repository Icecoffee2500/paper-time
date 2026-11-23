/**
 * What the format panel does to a note, as edits of its Markdown — the
 * Mac's `NoteFormat`, function for function.
 *
 * Pure: the note as written and the selection in it go in, one replacement
 * and the selection after it come out. The editor makes the replacement as
 * one step of its history.
 */
import { blockOf, type Block } from './noteBlocks.js'
import { DEFAULT_HIGHLIGHT, highlightLead, holdsMarkup, inlineTokens } from './noteMarkdown.js'
import { ALIGN_CLOSE, SPAN_CLOSE, alignOpen, emptyStyle, isEmptyStyle, readAlignment, wrapping, type NoteAlignment, type NoteSpanStyle } from './noteSpan.js'

export interface FormatEdit {
  from: number
  to: number
  insert: string
  /** What is selected afterwards, in the note as it then is; equal for a caret. */
  selectFrom: number
  selectTo: number
}

export type Paragraph = 'title' | 'heading' | 'subheading' | 'body' | 'quote'
export const PARAGRAPHS: Paragraph[] = ['title', 'heading', 'subheading', 'body', 'quote']
export const PARAGRAPH_PREFIX: Record<Paragraph, string> = { title: '# ', heading: '## ', subheading: '### ', body: '', quote: '> ' }

export type ListKind = 'none' | 'bullet' | 'numbered' | 'task' | 'toggle'
export const LISTS: ListKind[] = ['none', 'bullet', 'numbered', 'task', 'toggle']

/** The size a line's words are set at with no span: the body's 16, a heading's by its level (`style.css`). */
export function ownSize(block: Block): number {
  if (block.type.kind !== 'heading') return 16
  const level = block.type.level
  return level <= 1 ? 24 : level === 2 ? 20 : level === 3 ? 17.44 : 16
}

/** The format where the selection begins. */
export interface FormatState {
  style: NoteSpanStyle
  paragraph: Paragraph
  list: ListKind
  alignment: NoteAlignment
  /** The size the words are set at, whether or not a span says so. */
  size: number
  /** The size they would be with no span. */
  ownSize: number
}

function isListItem(block: Block): boolean {
  const kind = block.type.kind
  return kind === 'bullet' || kind === 'ordered' || kind === 'task' || kind === 'toggle'
}

/** The line a position is on, without what ends it. */
export function contentRange(text: string, index: number): { from: number; to: number } {
  const at = Math.min(Math.max(index, 0), text.length)
  const from = at <= 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1
  let to = text.indexOf('\n', at)
  if (to < 0) to = text.length
  if (to > from && text[to - 1] === '\r') to -= 1
  return { from, to }
}

/** Every line a selection touches, each without what ends it. A selection that ends at the very start of a line does not touch it. */
export function contentRanges(text: string, from: number, to: number): { from: number; to: number }[] {
  const ranges: { from: number; to: number }[] = []
  let index = from
  for (;;) {
    const line = contentRange(text, index)
    if (ranges.length === 0 || line.from < to) ranges.push(line)
    const next = text.indexOf('\n', line.to)
    if (next < 0) break
    index = next + 1
    if (index >= to) break
  }
  return ranges
}

export function formatState(source: string, from: number, to: number): FormatState {
  const at = Math.min(Math.max(from, 0), source.length)
  const line = contentRange(source, at)
  const block = blockOf(source.slice(line.from, line.to))
  const state: FormatState = { style: emptyStyle(), paragraph: 'body', list: 'none', alignment: 'left', size: 16, ownSize: 16 }
  switch (block.type.kind) {
    case 'heading': state.paragraph = block.type.level <= 1 ? 'title' : block.type.level === 2 ? 'heading' : 'subheading'; break
    case 'quote': state.paragraph = 'quote'; break
    case 'bullet': state.list = 'bullet'; break
    case 'ordered': state.list = 'numbered'; break
    case 'task': state.list = 'task'; break
    case 'toggle': state.list = 'toggle'; break
    default: break
  }
  const aligned = readAlignment(block.content)
  if (aligned) state.alignment = aligned.alignment
  state.ownSize = ownSize(block)
  state.size = state.ownSize
  const offset = at - line.from - block.marker.length
  if (offset >= 0 && holdsMarkup(block.content)) {
    for (const token of inlineTokens(block.content)) {
      // A selection is asked where it begins; a caret, where it stands —
      // after the letter before it, as typing would be.
      const inside = to > from ? token.from <= offset && offset < token.to : token.from < offset && offset <= token.to
      if (!inside) continue
      if (token.kind === 'styled') state.style = { ...token.style }
      else if (token.kind === 'emphasis' && !token.mono) {
        state.style.bold = token.bold
        state.style.italic = token.italic
      } else if (token.kind === 'highlight') state.style.highlight = token.color ?? DEFAULT_HIGHLIGHT
      break
    }
  }
  if (state.style.size !== null) state.size = state.style.size
  return state
}

// MARK: - Characters

export type Change = Partial<NoteSpanStyle>

function applied(style: NoteSpanStyle, change: Change): NoteSpanStyle {
  return { ...style, ...change }
}

/** One line's words with the change made between two offsets, and what was changed in the line as rebuilt. */
function restyled(content: string, from: number, to: number, change: Change): { text: string; changed: { from: number; to: number } | null } {
  let result = ''
  let first: number | null = null
  let end = 0
  const emit = (piece: string, changed = false) => {
    if (piece === '') return
    if (changed && first === null) first = result.length
    result += piece
    if (changed) end = result.length
  }
  const sub = (lower: number, upper: number) => upper > lower ? content.slice(lower, upper) : ''
  /** A stretch with no markup in it. */
  const plain = (lower: number, upper: number) => {
    const lo = Math.max(lower, from)
    const hi = Math.min(upper, to)
    if (hi <= lo) return emit(sub(lower, upper))
    emit(sub(lower, lo))
    const style = applied(emptyStyle(), change)
    // The spaces at either end stay outside: a span that opens on a space is
    // a space underlined, and Markdown's marks do not close after one.
    const words = sub(lo, hi)
    const core = words.replace(/^[ \t]+|[ \t]+$/g, '')
    if (core === '' || isEmptyStyle(style)) {
      emit(words)
    } else {
      const lead = /^[ \t]*/.exec(words)?.[0] ?? ''
      emit(lead)
      emit(wrapping(style, core), true)
      emit(words.slice(lead.length + core.length))
    }
    emit(sub(hi, upper))
  }
  /** Words already set some way, between `lower` and `upper`. */
  const piece = (lower: number, upper: number, old: NoteSpanStyle) => {
    let lo = Math.max(lower, from)
    let hi = Math.min(upper, to)
    // Only the marks were reached: all of the words, then.
    if (hi <= lo) { lo = lower; hi = upper }
    emit(wrapping(old, sub(lower, lo)))
    emit(wrapping(applied(old, change), sub(lo, hi)), true)
    emit(wrapping(old, sub(hi, upper)))
  }
  let index = 0
  const tokens = holdsMarkup(content) ? inlineTokens(content) : []
  for (const token of tokens) {
    if (token.from > index) plain(index, token.from)
    const reached = token.from < to && token.to > from
    if (reached && token.kind === 'styled') {
      piece(token.from + token.lead, token.to - SPAN_CLOSE.length, token.style)
    } else if (reached && token.kind === 'emphasis' && !token.mono) {
      const width = token.bold && token.italic ? 3 : token.bold ? 2 : 1
      piece(token.from + width, token.to - width, { ...emptyStyle(), bold: token.bold, italic: token.italic })
    } else if (reached && token.kind === 'highlight') {
      piece(token.from + highlightLead(token.color), token.to - 2, { ...emptyStyle(), highlight: token.color ?? DEFAULT_HIGHLIGHT })
    } else {
      emit(content.slice(token.from, token.to))
    }
    index = token.to
  }
  if (index < content.length) plain(index, content.length)
  return { text: result, changed: first === null ? null : { from: first, to: end } }
}

const LETTER = /^[\p{L}\p{N}\p{M}]$/u

/** The word a caret is in or beside — or the styled words it is in. */
function wordAt(text: string, caret: number): { from: number; to: number } | null {
  const line = contentRange(text, caret)
  const block = blockOf(text.slice(line.from, line.to))
  const start = line.from + block.marker.length
  const content = block.content
  const offset = caret - start
  if (offset < 0) return null
  if (holdsMarkup(content)) {
    for (const token of inlineTokens(content)) {
      if (token.from <= offset && offset <= token.to) {
        if (token.kind === 'styled' || token.kind === 'highlight' || (token.kind === 'emphasis' && !token.mono)) {
          return { from: start + token.from, to: start + token.to }
        }
        return null
      }
    }
  }
  const isLetter = (index: number) => {
    if (index < 0 || index >= content.length) return false
    const unit = content.charCodeAt(index)
    // Half of a pair: part of a word all the same.
    if (unit >= 0xd800 && unit <= 0xdfff) return true
    return LETTER.test(content[index])
  }
  let lower = offset
  let upper = offset
  while (isLetter(lower - 1)) lower -= 1
  while (isLetter(upper)) upper += 1
  return upper > lower ? { from: start + lower, to: start + upper } : null
}

/**
 * Sets the selected words that way — or, with nothing selected, the word
 * the caret is in. Words already in a span keep what they had and take the
 * change; words in Markdown's bold or italic become a span when the change
 * is more than those can say, and stay Markdown when it is not; a highlight
 * is one more thing words can be, with the rest. Links, formulas and code
 * are left as they are.
 */
export function setStyle(change: Change, source: string, from: number, to: number): FormatEdit | null {
  let lo = Math.min(Math.max(Math.min(from, to), 0), source.length)
  let hi = Math.min(Math.max(from, to), source.length)
  if (hi === lo) {
    const word = wordAt(source, lo)
    if (!word) return null
    lo = word.from
    hi = word.to
  }
  const lines = contentRanges(source, lo, hi)
  if (lines.length === 0) return null
  const whole = { from: lines[0].from, to: lines[lines.length - 1].to }
  let out = ''
  let cursor = whole.from
  let changedFrom: number | null = null
  let changedTo = 0
  for (const line of lines) {
    out += source.slice(cursor, line.from)
    const block = blockOf(source.slice(line.from, line.to))
    const marker = block.marker.length
    const a = Math.max(lo, line.from + marker) - line.from - marker
    const b = Math.min(hi, line.to) - line.from - marker
    out += block.marker
    if (b > a) {
      const base = out.length
      const made = restyled(block.content, a, b, change)
      out += made.text
      if (made.changed) {
        changedFrom ??= base + made.changed.from
        changedTo = base + made.changed.to
      }
    } else {
      out += block.content
    }
    cursor = line.to
  }
  if (changedFrom === null || out === source.slice(whole.from, whole.to)) return null
  return { from: whole.from, to: whole.to, insert: out, selectFrom: whole.from + changedFrom, selectTo: whole.from + changedTo }
}

// MARK: - Paragraphs

/** Each line the selection touches, written again by `rewrite` — null leaves a line as it is. A caret stays as far from the end of its line as it was; a selection becomes the lines. */
function rewritingLines(source: string, from: number, to: number, rewrite: (block: Block, many: boolean) => string | null): FormatEdit | null {
  const lo = Math.min(Math.max(Math.min(from, to), 0), source.length)
  const hi = Math.min(Math.max(from, to), source.length)
  const lines = contentRanges(source, lo, hi)
  if (lines.length === 0) return null
  const whole = { from: lines[0].from, to: lines[lines.length - 1].to }
  let out = ''
  let cursor = whole.from
  let caret = lo
  for (const line of lines) {
    out += source.slice(cursor, line.from)
    const written = source.slice(line.from, line.to)
    const made = rewrite(blockOf(written), lines.length > 1) ?? written
    if (hi === lo) {
      const fromEnd = line.to - lo
      caret = whole.from + out.length + Math.max(0, made.length - Math.min(fromEnd, made.length))
      // Never left of the words: a caret that was in a marker now gone
      // stands where the words begin.
      caret = Math.max(caret, whole.from + out.length + Math.min(blockOf(made).marker.length, made.length))
    }
    out += made
    cursor = line.to
  }
  if (out === source.slice(whole.from, whole.to)) return null
  return hi === lo
    ? { from: whole.from, to: whole.to, insert: out, selectFrom: caret, selectTo: caret }
    : { from: whole.from, to: whole.to, insert: out, selectFrom: whole.from, selectTo: whole.from + out.length }
}

function unaligned(words: string): string {
  const wrapped = readAlignment(words)
  return wrapped ? words.slice(wrapped.from, wrapped.to) : words
}

/** Makes each selected line that kind of paragraph. A list's item stays a list's item when it is asked to be body, which it is. */
export function setParagraph(paragraph: Paragraph, source: string, from: number, to: number): FormatEdit | null {
  return rewritingLines(source, from, to, (block) => {
    if (isListItem(block) && paragraph === 'body') return null
    if (block.content === '' && block.marker === '' && paragraph === 'body') return null
    // A quotation keeps to its rule, as a list's item to its edge.
    const words = paragraph === 'quote' ? unaligned(block.content) : block.content
    return PARAGRAPH_PREFIX[paragraph] + words
  })
}

/** Makes each selected line an item of that kind of list, or takes it out of its list. An item keeps how far in it is. */
export function setList(list: ListKind, source: string, from: number, to: number): FormatEdit | null {
  let number = 0
  return rewritingLines(source, from, to, (block, many) => {
    // A blank line between items is not an item.
    if (many && block.content === '' && block.marker === '') return null
    const lead = /^ */.exec(block.marker)?.[0] ?? ''
    number += 1
    // An item keeps to its list's edge: a line set to the centre or the
    // right gives that up to become one.
    const words = list !== 'none' ? unaligned(block.content) : block.content
    switch (list) {
      case 'none': return isListItem(block) ? words : null
      case 'bullet': return `${lead}- ${words}`
      case 'numbered': return `${lead}${number}. ${words}`
      case 'task': return block.type.kind === 'task' ? null : `${lead}- [ ] ${words}`
      case 'toggle': return `${lead}+ ${words}`
    }
  })
}

/** Sets each selected line that way across the page: a paragraph or a heading. A list's items and a quotation keep their own edge. */
export function setAlignment(alignment: NoteAlignment, source: string, from: number, to: number): FormatEdit | null {
  return rewritingLines(source, from, to, (block) => {
    if (block.type.kind !== 'plain' && block.type.kind !== 'heading') return null
    const words = unaligned(block.content)
    if (words === '') return null
    return block.marker + (alignment === 'left' ? words : alignOpen(alignment) + words + ALIGN_CLOSE)
  })
}

// MARK: - Pictures

/** Puts a picture on a line of its own, after the line the caret is on — or on that line, when it is empty — and leaves the caret on the line under it. */
export function insertPicture(path: string, source: string, caret: number): FormatEdit {
  const line = contentRange(source, caret)
  const written = `![](${path})`
  if (source.slice(line.from, line.to).trim() === '') {
    const at = line.from + written.length + 1
    return { from: line.from, to: line.to, insert: `${written}\n`, selectFrom: at, selectTo: at }
  }
  const insert = `\n\n${written}\n`
  return { from: line.to, to: line.to, insert, selectFrom: line.to + insert.length, selectTo: line.to + insert.length }
}

// MARK: - Tags left without their pair

const TAG = /<span style="[^"\n]*">|<\/span>|<p align="(?:left|center|right|justify)">|<\/p>/g

/**
 * A line with its tags in order again (`NoteFormat.tidy`): a closing span
 * with no opening one before it goes, and an opening one never closed, and
 * a span with nothing in it; alignment is the whole line's or nobody's —
 * the line keeps the alignment it opens with, wrapped round all of its
 * words, and a line that does not open with one has none. The words are
 * never touched.
 */
export function tidyLine(line: string): string {
  let out = ''
  let at = 0
  for (const edit of tidyEdits(line)) {
    out += line.slice(at, edit.from) + edit.insert
    at = edit.to
  }
  return out + line.slice(at)
}

/** What `tidyLine` takes out of a line and puts into it, in order: the tags alone, so a caret among the words stays where it is. */
export function tidyEdits(line: string): { from: number; to: number; insert: string }[] {
  if (!line.includes('<')) return []
  const block = blockOf(line)
  const content = block.content
  const base = block.marker.length
  const tags = [...content.matchAll(new RegExp(TAG.source, 'g'))].map((match) => ({ from: match.index ?? 0, to: (match.index ?? 0) + match[0].length, text: match[0] }))
  if (tags.length === 0) return []
  const kept = tags.map(() => false)
  let alignment = -1
  let open: number | null = null
  tags.forEach((tag, index) => {
    if (tag.text.startsWith('<p')) {
      if (tag.from === 0) alignment = index
    } else if (tag.text === ALIGN_CLOSE) {
      // Put back at the end of the line below.
    } else if (tag.text === SPAN_CLOSE) {
      // Closed, with words between.
      if (open !== null && tags[open].to < tag.from) {
        kept[open] = true
        kept[index] = true
      }
      open = null
    } else {
      open = index
    }
  })
  const last = tags[tags.length - 1]
  const closes = alignment >= 0 && last.text === ALIGN_CLOSE && last.to === content.length
  if (alignment >= 0) kept[alignment] = true
  if (closes) kept[tags.length - 1] = true
  const edits = tags.filter((_, index) => !kept[index]).map((tag) => ({ from: base + tag.from, to: base + tag.to, insert: '' }))
  if (alignment >= 0 && !closes) edits.push({ from: line.length, to: line.length, insert: ALIGN_CLOSE })
  return edits
}
