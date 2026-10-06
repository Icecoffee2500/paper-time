/**
 * How a note's numbered lists count, and what moving an item in or out a
 * level does to the numbers written in the note — the Mac's `NoteList`, held
 * to the answers it writes (`Tests/PaperCoreTests/Fixtures/note-lists.json`).
 *
 * A numbered item shows where it stands, not what is written in front of it:
 * it counts on from the item before it at its depth. Reading the written
 * number instead, an item moved in under another with Tab kept its «2.» and
 * was shown «b.». A list at the left starts at its first item's number; a list
 * set in under an item starts at 1. A list is broken by a line at its depth
 * that is not one of its items — an item closed by the other mark («1)» after
 * «1.») is another list's — and by any shallower line; blank lines and deeper
 * lines leave it whole. A `$$` block or a table over several lines is
 * one line, and fenced code is never an item. Offsets are UTF-16.
 */
import { codeBlocks } from './noteCode.js'
import { lineRanges, mathBlocks, mathSpanAt, type TextSpan } from './noteMath.js'
import { tableBlocks } from './noteTable.js'
import { trimWhitespace } from './zettel.js'

/** A line as the lists read it (`NoteList.Line`). */
interface Line {
  range: TextSpan
  depth: number
  blank: boolean
  item: boolean
  number: number | null
  digits: TextSpan | null
  /** What closes the number: «.» or «)». */
  delimiter: string
  contentStart: number
  code: boolean
}

/** ICU's `\s` — the Mac's patterns are written with it. */
const S = '[\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]'
const ORDERED = new RegExp(`^(\\p{Nd}{1,3})[.)]${S}+`, 'u')
const TASK = new RegExp(`^([-*+])${S}+\\[([ xX])\\]${S}+`, 'u')
const TOGGLE = /^\+ /
const BULLET = new RegExp(`^[-*+]${S}+`, 'u')
const BLANK = /^\p{White_Space}*$/u

/** What every numbered item shows, by where its line starts. */
export function listNumbers(source: string): Map<number, number> {
  return shownOf(linesOf(source))
}

/** The same, off lines a renderer has already read — its own, with formulas and tables joined. */
export function listNumbersOf(lines: readonly TextSpan[], source: string, isCode: (line: TextSpan) => boolean): Map<number, number> {
  return shownOf(lines.map((range) => readLine(range, source, isCode(range))))
}

function shownOf(lines: Line[]): Map<number, number> {
  const shown = new Map<number, number>()
  counted(lines).forEach((count, index) => {
    if (count.shown !== null) shown.set(lines[index].range.from, count.shown)
  })
  return shown
}

/**
 * An edit to make: put `insert` over [from, to), then the caret goes to
 * `caret` — or, when `length` is there, the selection runs from it for that
 * many characters.
 */
export interface ListEdit {
  from: number
  to: number
  insert: string
  caret: number
  length?: number
}

/**
 * Tab (`step` 1) or ⇧Tab (−1) on a list item (`NoteList.shift`): the item goes
 * a level in or out with what is under it, and its list is numbered as it is
 * shown; an item that comes to start a list starts it at 1, and the caret
 * keeps its place in the item's words. Null off a list item and in fenced
 * code; an item at the left on ⇧Tab gets an edit that changes nothing.
 */
export function shiftItem(source: string, caret: number, step: 1 | -1): ListEdit | null {
  const all = linesOf(source)
  const index = all.findIndex((line) => line.range.from <= caret && caret <= line.range.to)
  if (index < 0) return null
  const line = all[index]
  if (line.code || !line.item) return null
  if (step < 0 && line.depth === 0) return { from: caret, to: caret, insert: '', caret }

  // The item and what is under it: the lines after it that are deeper, and
  // the blank lines among them.
  let last = index
  let next = index + 1
  while (next < all.length) {
    if (all[next].blank) {
      next += 1
      continue
    }
    if (all[next].depth <= line.depth) break
    last = next
    next += 1
  }
  const span = { from: line.range.from, to: all[last].range.to }
  const code = codeBlocks(source).map((block) => block.range)
  const spanned = source.slice(span.from, span.to)
  const moved = lineRanges(spanned).map((physical) => {
    const absolute = span.from + physical.from
    let written = spanned.slice(physical.from, physical.to)
    const isBlank = BLANK.test(written)
    const isCode = code.some((block) => absolute >= block.from && absolute < block.to)
    if (!isBlank && !isCode) {
      if (step > 0) {
        written = `  ${written}`
      } else {
        let spaces = 0
        while (spaces < 2 && written[spaces] === ' ') spaces += 1
        written = written.slice(spaces)
      }
    }
    return written
  })
  let updated = source.slice(0, span.from) + moved.join('\n') + source.slice(span.to)

  // An item that comes to start a list starts it at 1.
  let read = linesOf(updated)
  const at = read.findIndex((one) => one.range.from === line.range.from)
  if (at < 0) return null
  if (read[at].number !== null && read[at].digits && counted(read)[at].starts && read[at].number !== 1) {
    const digits = read[at].digits!
    updated = updated.slice(0, digits.from) + '1' + updated.slice(digits.to)
    read = linesOf(updated)
  }

  // The list numbered as it is shown, from the bottom up so the places above
  // stay where they are.
  const shown = counted(read)
  const [lower, upper] = region(at, read)
  for (let row = upper; row >= lower; row -= 1) {
    const written = read[row].number
    const number = shown[row].shown
    const digits = read[row].digits
    if (written === null || number === null || !digits || written === number) continue
    updated = updated.slice(0, digits.from) + String(number) + updated.slice(digits.to)
  }
  read = linesOf(updated)

  // The caret, in the same place among the item's words.
  const offset = caret - line.range.from
  const markerBefore = line.contentStart - line.range.from
  const markerAfter = read[at].contentStart - read[at].range.from
  const landed = read[at].range.from + (offset >= markerBefore ? offset - markerBefore + markerAfter : markerAfter)
  return difference(source, updated, landed)
}

/**
 * Tab or ⇧Tab over a selection (`NoteList.shift(in:selection:by:)`): every
 * line from the first one selected to the last — and what is under the last,
 * as for one item — goes a level in or out, and the selection stays on the
 * same words. A selection that ends at the start of a line does not take that
 * line. The first line selected has to be a list item; ⇧Tab leaves a line at
 * the left where it is. With nothing selected, `shiftItem`.
 */
export function shiftSelection(source: string, from: number, to: number, step: 1 | -1): ListEdit | null {
  const [lo, hi] = from <= to ? [from, to] : [to, from]
  if (lo === hi) return shiftItem(source, lo, step)
  const all = linesOf(source)
  const indexOf = (offset: number) => all.findIndex((line) => line.range.from <= offset && offset <= line.range.to)
  let end = hi
  if (end > lo && end > 0 && end <= source.length && source.charCodeAt(end - 1) === 10) end -= 1
  const first = indexOf(lo)
  let last = indexOf(end)
  if (first < 0 || last < first || all[first].code || !all[first].item) return null
  const items = all.slice(first, last + 1).filter((line) => line.item).map((line) => line.depth)
  const depth = items.length > 0 ? Math.min(...items) : all[first].depth
  let next = last + 1
  while (next < all.length) {
    if (all[next].blank) {
      next += 1
      continue
    }
    if (all[next].depth <= depth) break
    last = next
    next += 1
  }
  const moving = all.slice(first, last + 1).filter((line) => !line.blank && !line.code)
  if (step < 0 && moving.every((line) => line.depth === 0)) return { from: lo, to: lo, insert: '', caret: lo, length: hi - lo }

  // Every line of them in or out by two spaces, from the bottom up so the
  // places above stay where they are. What is carried along — the
  // selection's ends, and where each moved line starts — moves with the
  // words: a place at a line's start stays at its start.
  const code = codeBlocks(source).map((block) => block.range)
  const span = { from: all[first].range.from, to: all[last].range.to }
  const edits: { start: number; spaces: number }[] = []
  for (const physical of lineRanges(source.slice(span.from, span.to))) {
    const start = span.from + physical.from
    const written = source.slice(start, span.from + physical.to)
    if (BLANK.test(written) || code.some((block) => start >= block.from && start < block.to)) continue
    let spaces = 2
    if (step < 0) {
      spaces = 0
      while (spaces < 2 && written[spaces] === ' ') spaces += 1
    }
    if (spaces > 0) edits.push({ start, spaces })
  }
  // The selection's two ends first, then where each moved line starts.
  let carried = [lo, hi, ...edits.map((edit) => edit.start)]
  let updated = source
  for (const edit of [...edits].reverse()) {
    if (step > 0) {
      updated = updated.slice(0, edit.start) + '  ' + updated.slice(edit.start)
      carried = carried.map((at) => (at > edit.start ? at + 2 : at))
    } else {
      updated = updated.slice(0, edit.start) + updated.slice(edit.start + edit.spaces)
      carried = carried.map((at) => (at > edit.start + edit.spaces ? at - edit.spaces : at > edit.start ? edit.start : at))
    }
  }

  // An item that comes to start a list starts it at 1.
  const read = linesOf(updated)
  const counts = counted(read)
  const moved = new Set(carried.slice(2))
  for (let row = read.length - 1; row >= 0; row -= 1) {
    if (!moved.has(read[row].range.from)) continue
    const number = read[row].number
    const digits = read[row].digits
    if (number === null || number === 1 || !counts[row].starts || read[row].depth !== 0 || !digits) continue
    updated = updated.slice(0, digits.from) + '1' + updated.slice(digits.to)
    const delta = 1 - (digits.to - digits.from)
    carried = carried.map((at) => (at >= digits.to ? at + delta : at))
  }
  const result = numbered(updated, carried.slice(2), carried)
  return difference(source, result.text, result.carried[0], Math.max(0, result.carried[1] - result.carried[0]))
}

// MARK: - Return, Backspace, Delete

/**
 * Return with nothing selected (`NoteList.newLine`): what the line was doing
 * goes on — the next bullet, the next number, another empty box, another line
 * of the quotation, a toggle's first child — and the list is numbered as it
 * is shown. An empty item steps out a level, as ⇧Tab moves it; at the left it
 * ends the list, the marker going and the line breaking, so a blank line
 * stands between the list and what is written next. An empty line of a
 * toggle's children steps out to the toggle's own level. On a toggle whose
 * children are folded away (`folded`), the new line goes after them. Null
 * where Return is a line break and nothing more: plain words, a heading,
 * fenced code.
 */
export function newLine(source: string, caret: number, folded = false): ListEdit | null {
  if (caret < 0 || caret > source.length || inCode(caret, source)) return null
  // Inside a formula, Return breaks the formula's line, not the item.
  if (mathSpanAt(source, caret)) return null
  const line = physicalLine(caret, source)
  const written = source.slice(line.from, line.to)
  const head = headOf(written)
  if (!head || head.kind === 'heading') return stepOutOfToggle(line, written, caret, source) ?? keepingIndent(line, caret, source)
  const wordsStart = line.from + head.length
  // A quotation's «>» is there to see on the line being edited, and a caret
  // before it is a line break before the quotation. A list's marker is
  // drawn: a caret before it is at its words.
  if (head.kind === 'quote' && caret < wordsStart) return null
  const at = Math.max(caret, wordsStart)
  if (trimWhitespace(source.slice(wordsStart, line.to)).length === 0) {
    if (depthOf(head) > 0) {
      if (isListHead(head)) return shiftItem(source, wordsStart, -1)
      return finished(source, { from: line.from, to: line.from + 2 }, '', wordsStart - 2)
    }
    return finished(source, line, '\n', line.from + 1)
  }
  const lead = ' '.repeat(head.spaces)
  // At the start of a toggle's words the new line is an empty toggle above
  // it, as at the start of an item's: its words are its title.
  if (head.kind === 'toggle' && at === wordsStart) {
    const above = `${lead}+ \n`
    return finished(source, { from: line.from, to: line.from }, above, at + above.length)
  }
  if (head.kind === 'toggle' && folded) {
    const end = childrenEnd(line.from, source)
    if (end !== null) return finished(source, { from: end, to: end }, `\n${lead}`, end + 1 + head.spaces)
  }
  let marker: string
  switch (head.kind) {
    case 'bullet': marker = `${lead}${head.mark} `; break
    case 'ordered': marker = `${lead}${(head.number ?? 0) + 1}${head.mark} `; break
    case 'task': marker = `${lead}${head.mark} [ ] `; break
    case 'quote': marker = `${lead}> `; break
    // A toggle's next line is its first child: a plain line, one step in.
    default: marker = `${lead}  `
  }
  return finished(source, { from: at, to: at }, `\n${marker}`, at + 1 + marker.length)
}

/**
 * Backspace with nothing selected and the caret at the edge of a line's
 * marker (`NoteList.backspace`): a nested item steps out a level (with what
 * is under it, as ⇧Tab moves it), and one at the left loses its marker and
 * is plain words again. A list's marker is drawn, so its edge is both the
 * start of its words and the start of the line; a quotation's or a
 * heading's is shown as written on the line being edited, and its edge is
 * where its words start. Null anywhere else.
 */
export function backspaceAt(source: string, caret: number): ListEdit | null {
  if (caret < 0 || caret > source.length) return null
  const line = physicalLine(caret, source)
  const head = headOf(source.slice(line.from, line.to))
  if (!head) return null
  const wordsStart = line.from + head.length
  if (isListHead(head) ? caret > wordsStart : caret !== wordsStart) return null
  if (inCode(caret, source)) return null
  if (depthOf(head) > 0) {
    if (isListHead(head)) return shiftItem(source, wordsStart, -1)
    return finished(source, { from: line.from, to: line.from + 2 }, '', wordsStart - 2)
  }
  return finished(source, { from: line.from, to: line.from + head.length }, '', line.from)
}

/**
 * Delete with nothing selected, at the end of a line, before a line with a
 * marker (`NoteList.deleteForward`): the next line's words join this one,
 * without its marker. From an empty line it is the empty line that goes,
 * and the item below keeps its marker. Null anywhere else.
 */
export function deleteForwardAt(source: string, caret: number): ListEdit | null {
  if (caret < 0 || caret >= source.length) return null
  const line = physicalLine(caret, source)
  if (caret !== line.to) return null
  let nextStart = caret
  while (nextStart < source.length && source.charCodeAt(nextStart) === 13) nextStart += 1
  if (nextStart >= source.length || source.charCodeAt(nextStart) !== 10) return null
  nextStart += 1
  const next = physicalLine(nextStart, source)
  const head = headOf(source.slice(next.from, next.to))
  if (!head || inCode(caret, source) || inCode(nextStart, source)) return null
  if (trimWhitespace(source.slice(line.from, line.to)).length === 0) {
    return finished(source, { from: line.from, to: nextStart }, '', line.from + head.length)
  }
  return finished(source, { from: caret, to: nextStart + head.length }, '', caret)
}

/**
 * A space typed with nothing selected (`NoteList.shortcut`), after «[]» at
 * the start of a line or of a bullet's words — a box to tick — or after «--»
 * at the start of a line — a toggle. Null anywhere else.
 */
export function shortcutAt(source: string, caret: number): ListEdit | null {
  if (caret < 2 || caret > source.length) return null
  const two = source.slice(caret - 2, caret)
  if (two !== '[]' && two !== '--') return null
  const line = physicalLine(caret, source)
  const sofar = source.slice(line.from, caret)
  let spaces = 0
  while (spaces < sofar.length && sofar[spaces] === ' ') spaces += 1
  const typed = sofar.slice(spaces)
  const start = line.from + spaces
  let made: string
  const boxed = BOXED_BULLET.exec(typed)
  if (typed === '[]') made = '- [ ] '
  else if (typed === '--') made = '+ '
  else if (boxed) made = `${boxed[1]} [ ] `
  else return null
  if (inCode(caret, source)) return null
  return { from: start, to: caret, insert: made, caret: start + made.length }
}

/** «- []», a bullet with a box typed as its words. */
const BOXED_BULLET = new RegExp(`^([-*])${S}+\\[\\]$`, 'u')

/** What a line starts with, read the way the renderer reads it (`NoteList.Head`). */
interface Head {
  kind: 'bullet' | 'ordered' | 'task' | 'toggle' | 'quote' | 'heading'
  /** The indentation, in spaces. */
  spaces: number
  /** The indentation and the marker together: where the words start. */
  length: number
  /** A bullet's or a box's character, or what closes a number: a list goes on in its own marks. */
  mark: string
  number: number | null
}

const depthOf = (head: Head) => Math.floor(head.spaces / 2)
const isListHead = (head: Head) => head.kind !== 'quote' && head.kind !== 'heading'

// The renderer's own patterns (`NoteMarkdown.Block`), for the lines that are
// not counted: a heading's, and a toggle's and a bullet's as it tells them apart.
const HEADING = new RegExp(`^(#{1,6})${S}+`, 'u')
const BLOCK_TOGGLE = new RegExp(`^\\+${S}+`, 'u')
const BLOCK_BULLET = new RegExp(`^[-*]${S}+`, 'u')

function headOf(line: string): Head | null {
  let spaces = 0
  while (spaces < line.length && line[spaces] === ' ') spaces += 1
  const body = line.slice(spaces)
  if (!/^[#\-*+>0-9]/.test(body)) return null
  let match: RegExpExecArray | null
  if ((match = TASK.exec(body))) return { kind: 'task', spaces, length: spaces + match[0].length, mark: match[1], number: null }
  if ((match = HEADING.exec(body))) return { kind: 'heading', spaces, length: spaces + match[0].length, mark: '', number: null }
  if ((match = BLOCK_TOGGLE.exec(body))) return { kind: 'toggle', spaces, length: spaces + match[0].length, mark: '+', number: null }
  if ((match = BLOCK_BULLET.exec(body))) return { kind: 'bullet', spaces, length: spaces + match[0].length, mark: body[0], number: null }
  if ((match = ORDERED.exec(body))) return { kind: 'ordered', spaces, length: spaces + match[0].length, mark: body[match[1].length], number: written(match[1]) }
  if (body.startsWith('>')) {
    let length = body.length > 1 && body[1] === ' ' ? 2 : 1
    // A quotation can hold the section it was taken from; its «###» is part of the marker.
    const heading = HEADING.exec(body.slice(length))
    if (heading) length += heading[0].length
    return { kind: 'quote', spaces, length: spaces + length, mark: '>', number: null }
  }
  return null
}

/** A number as Swift's `Int(_:)` reads it, and 1 for what it cannot. */
function written(digits: string): number {
  return /^[0-9]+$/.test(digits) ? Number(digits) : 1
}

/** The line an offset is on, without its break — split at «\n» alone, as the renderer splits a note. */
function physicalLine(offset: number, source: string): TextSpan {
  const at = Math.min(Math.max(offset, 0), source.length)
  // (`lastIndexOf` reads a place before the start as the start itself.)
  const from = at === 0 ? 0 : source.lastIndexOf('\n', at - 1) + 1
  const newline = source.indexOf('\n', at)
  let to = newline < 0 ? source.length : newline
  while (to > from && source.charCodeAt(to - 1) === 13) to -= 1
  return { from, to }
}

/** Whether the line an offset is on is fenced code. */
function inCode(offset: number, source: string): boolean {
  const start = physicalLine(offset, source).from
  return codeBlocks(source).some((block) => (start >= block.range.from && start < block.range.to) || start === block.range.from)
}

/** An empty line among a toggle's children — spaces only, two or more, the caret at its end — steps out to the toggle's own level. */
function stepOutOfToggle(line: TextSpan, written: string, caret: number, source: string): ListEdit | null {
  if (written.length < 2 || !/^ +$/.test(written) || caret !== line.to) return null
  let end = line.from - 1
  while (end >= 0) {
    const above = physicalLine(end, source)
    const words = source.slice(above.from, above.to)
    if (trimWhitespace(words).length > 0) {
      let lead = 0
      while (lead < words.length && words[lead] === ' ') lead += 1
      if (lead < written.length) {
        const head = headOf(words)
        if (!head || head.kind !== 'toggle') return null
        return finished(source, line, ' '.repeat(head.spaces), line.from + head.spaces)
      }
    }
    end = above.from - 1
  }
  return null
}

/**
 * Return on a line set in with no marker goes on at the same indent
 * (`NoteList.keepingIndent`) — CodeMirror's own `insertNewlineAndIndent`,
 * whose rules these are, so the Mac's Return keeps a toggle's children
 * together as this one always did. Null for a line at the left.
 */
function keepingIndent(line: TextSpan, caret: number, source: string): ListEdit | null {
  let columns = 0
  let at = line.from
  while (at < line.to && (source[at] === ' ' || source[at] === '\t')) {
    columns = source[at] === '\t' ? columns + 4 - (columns % 4) : columns + 1
    at += 1
  }
  if (columns === 0) return null
  let from = caret
  let to = caret
  while (to < line.to && /\s/.test(source[to])) to += 1
  if (from > line.from && from < line.from + 100 && !/\S/.test(source.slice(line.from, from))) from = line.from
  const insert = `\n${' '.repeat(columns)}`
  return { from, to, insert, caret: from + insert.length }
}

/** Where a toggle's children end (`NoteList.childrenEnd`): the end of the last line under it that is deeper. */
function childrenEnd(start: number, source: string): number | null {
  const all = linesOf(source)
  const index = all.findIndex((line) => line.range.from === start)
  if (index < 0) return null
  let last: number | null = null
  for (let next = index + 1; next < all.length; next += 1) {
    if (all[next].blank) continue
    if (all[next].depth <= all[index].depth) break
    last = next
  }
  return last === null ? null : all[last].range.to
}

/** An edit made, and the lists round it numbered as they are shown, the caret carried along. */
function finished(source: string, range: TextSpan, insert: string, caret: number): ListEdit {
  const changed = source.slice(0, range.from) + insert + source.slice(range.to)
  const result = numbered(changed, [range.from, caret], [caret])
  return difference(source, result.text, result.carried[0])
}

/** The lists round these places numbered as they are shown, and the positions carried through the digits that changed. */
function numbered(source: string, places: number[], positions: number[]): { text: string; carried: number[] } {
  const read = linesOf(source)
  const shown = counted(read)
  const rows = new Set<number>()
  for (const place of places) {
    const index = read.findIndex((line) => line.range.from <= place && place <= line.range.to)
    if (index < 0) continue
    const [lower, upper] = region(index, read)
    for (let row = lower; row <= upper; row += 1) rows.add(row)
  }
  let text = source
  let carried = positions
  for (const row of [...rows].sort((a, b) => b - a)) {
    const written = read[row].number
    const number = shown[row].shown
    const digits = read[row].digits
    if (written === null || number === null || written === number || !digits) continue
    const replacement = String(number)
    text = text.slice(0, digits.from) + replacement + text.slice(digits.to)
    const delta = replacement.length - (digits.to - digits.from)
    carried = carried.map((at) => (at >= digits.to ? at + delta : at))
  }
  return { text, carried }
}

// MARK: - Reading

/** The note's lines as the lists read them: a formula or a table over several lines is one. */
function linesOf(source: string): Line[] {
  const code = codeBlocks(source).map((block) => block.range)
  const ranges = lineRanges(source)
  const searched = blanking(source, code)
  const joined = [...mathBlocks(searched), ...tableBlocks(searched)].sort((a, b) => a.from - b.from)
  for (const block of joined.reverse()) {
    const first = ranges.findIndex((one) => one.from === block.from)
    const last = ranges.findIndex((one) => one.to === block.to)
    if (first < 0 || last < first) continue
    ranges.splice(first, last - first + 1, { from: block.from, to: block.to })
  }
  return ranges.map((range) => readLine(range, source, code.some((block) => (range.from >= block.from && range.from < block.to) || range.from === block.from)))
}

/** One line's depth and marker, read off its first physical line the way the renderer's `blockOf` reads them. */
function readLine(range: TextSpan, source: string, code: boolean): Line {
  const whole = source.slice(range.from, range.to)
  const breakAt = whole.indexOf('\n')
  const first = breakAt < 0 ? whole : whole.slice(0, breakAt)
  let spaces = 0
  while (spaces < first.length && first[spaces] === ' ') spaces += 1
  const body = first.slice(spaces)
  const blank = BLANK.test(body)
  const line: Line = { range, depth: Math.floor(spaces / 2), blank, item: false, number: null, digits: null, delimiter: '', contentStart: range.from + spaces, code }
  // A marker starts with a digit, a dash, a star or a plus.
  if (code || blank || !/^[0-9\-*+]/.test(body)) return line
  let match = ORDERED.exec(body)
  if (match) {
    line.item = true
    line.number = written(match[1])
    line.digits = { from: range.from + spaces, to: range.from + spaces + match[1].length }
    line.delimiter = body[match[1].length]
    line.contentStart = range.from + spaces + match[0].length
    return line
  }
  match = TASK.exec(body) ?? TOGGLE.exec(body) ?? BULLET.exec(body)
  if (match) {
    line.item = true
    line.contentStart = range.from + spaces + match[0].length
  }
  return line
}

/** Each line's shown number, and whether it starts its list. */
function counted(lines: readonly Line[]): { shown: number | null; starts: boolean }[] {
  const open = new Map<number, { next: number; delimiter: string }>()
  return lines.map((line) => {
    if (line.blank) return { shown: null, starts: false }
    for (const depth of [...open.keys()]) if (depth > line.depth) open.delete(depth)
    if (line.number === null) {
      open.delete(line.depth)
      return { shown: null, starts: false }
    }
    const run = open.get(line.depth)
    if (run && run.delimiter === line.delimiter) {
      open.set(line.depth, { next: run.next + 1, delimiter: line.delimiter })
      return { shown: run.next, starts: false }
    }
    const start = line.depth === 0 ? line.number : 1
    open.set(line.depth, { next: start + 1, delimiter: line.delimiter })
    return { shown: start, starts: true }
  })
}

/** The list a line is in: the lines round it that are items, deeper than the left, or blank. */
function region(index: number, lines: readonly Line[]): [number, number] {
  const inList = (line: Line) => line.blank || line.item || line.depth > 0
  let lower = index
  let upper = index
  while (lower > 0 && inList(lines[lower - 1])) lower -= 1
  while (upper + 1 < lines.length && inList(lines[upper + 1])) upper += 1
  return [lower, upper]
}

/** The text with every fenced block's characters but its line breaks made spaces. */
function blanking(source: string, code: readonly TextSpan[]): string {
  if (code.length === 0) return source
  const units = source.split('')
  for (const block of code) {
    for (let index = block.from; index < Math.min(block.to, units.length); index += 1) {
      if (units[index] !== '\n') units[index] = ' '
    }
  }
  return units.join('')
}

/** The one change between two texts: what they share at either end left out. */
function difference(before: string, after: string, caret: number, length = 0): ListEdit {
  let head = 0
  while (head < before.length && head < after.length && before.charCodeAt(head) === after.charCodeAt(head)) head += 1
  // Never between the halves of a character written as two units.
  while (head > 0 && isLead(before.charCodeAt(head - 1))) head -= 1
  let tail = 0
  while (tail < before.length - head && tail < after.length - head
    && before.charCodeAt(before.length - 1 - tail) === after.charCodeAt(after.length - 1 - tail)) tail += 1
  while (tail > 0 && isTrail(before.charCodeAt(before.length - tail))) tail -= 1
  return { from: head, to: before.length - tail, insert: after.slice(head, after.length - tail), caret, ...(length > 0 ? { length } : {}) }
}

const isLead = (unit: number) => unit >= 0xd800 && unit <= 0xdbff
const isTrail = (unit: number) => unit >= 0xdc00 && unit <= 0xdfff
