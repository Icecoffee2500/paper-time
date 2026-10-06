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
import { lineRanges, mathBlocks, type TextSpan } from './noteMath.js'
import { tableBlocks } from './noteTable.js'

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
const ORDERED = new RegExp(`^(\\d{1,3})[.)]${S}+`, 'u')
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

/** An edit to make: put `insert` over [from, to), then the caret goes to `caret`. */
export interface ListEdit {
  from: number
  to: number
  insert: string
  caret: number
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
    line.number = Number(match[1]) || 1
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
function difference(before: string, after: string, caret: number): ListEdit {
  let head = 0
  while (head < before.length && head < after.length && before.charCodeAt(head) === after.charCodeAt(head)) head += 1
  let tail = 0
  while (tail < before.length - head && tail < after.length - head
    && before.charCodeAt(before.length - 1 - tail) === after.charCodeAt(after.length - 1 - tail)) tail += 1
  return { from: head, to: before.length - tail, insert: after.slice(head, after.length - tail), caret }
}
