/**
 * The passages of papers a note quotes, and where each quotation stands in
 * the note — the Mac's `QuotedPassages`, held to the answers it writes
 * (`Tests/PaperCoreTests/Fixtures/quoted-passages.json`).
 *
 * Command-L writes a passage into a note as a block quote whose page link —
 * `[4쪽](papertime://anchor?p=3&x=…)` — says which page and where on it. That
 * link is the only record there is: nothing goes into the PDF and nothing
 * beside it. So the way back from the page is found by reading the notes. A
 * quotation deleted from its note is gone from the page with it, and a note
 * that arrives from another machine brings its passages along.
 */
import { codeBlocks } from './noteCode.js'
import { parseAnchorURL, type NoteAnchor } from './noteQuote.js'

export interface QuotedPassage {
  /** The link's address as the note spells it: what the note is searched for when the quotation is to be found again. */
  url: string
  pageIndex: number
  /** In the page's own coordinates, origin at the lower left. */
  rect: NoteAnchor['rect']
  /** As written, when the link names a paper. */
  paperID?: string
  /** The `[label](address)` link, in UTF-16 offsets. */
  link: { from: number; to: number }
  /** The quotation the link closes: its block quote's first line to the end of the link's line — or the link's own line. */
  quote: { from: number; to: number }
}

/** `[label](papertime://anchor?…)`. A label may hold escaped brackets, and brackets in pairs as the note's renderer reads them; never a line break. */
const LINK = /\[((?:\\.|[^\\\[\]\n]|\[(?:\\.|[^\\\[\]\n])*\])*)\]\((papertime:\/\/anchor[^)\s]*)\)/g

/**
 * Every passage a note's body links to, in the order they are written. A link
 * inside a fenced block of code is code; one whose address does not say a page
 * and a box with some size to it is nowhere to draw.
 */
export function quotedPassages(body: string): QuotedPassage[] {
  if (!body.includes('papertime://anchor')) return []
  const code = codeBlocks(body).map((block) => block.range)
  const found: QuotedPassage[] = []
  for (const match of body.matchAll(LINK)) {
    const from = match.index ?? 0
    if (code.some((range) => from >= range.from && from < range.to)) continue
    const url = match[2]
    const place = parseAnchorURL(url)
    if (!place || place.pageIndex < 0) continue
    const { x, y, width, height } = place.rect
    if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0) continue
    found.push({
      url,
      pageIndex: place.pageIndex,
      rect: place.rect,
      ...(place.paperID ? { paperID: place.paperID } : {}),
      link: { from, to: from + match[0].length },
      quote: quoteClosedBy(from, body),
    })
  }
  return found
}

/**
 * The passages a note quotes from one paper: the links that name it, and — in
 * a note about that paper — the links that name no paper. (The Mac's ⌘L names
 * the paper every time; this build's names it only when the note is about
 * another one.)
 */
export function quotedPassagesOfPaper(note: { body: string; paperID: string | null }, paperID: string): QuotedPassage[] {
  const wanted = paperID.toUpperCase()
  return quotedPassages(note.body).filter((passage) => (passage.paperID ?? note.paperID ?? '').toUpperCase() === wanted)
}

/** The quotation a link closes. Lines split at `\n` only, a `\r` before it left out — as the Mac reads them. */
function quoteClosedBy(index: number, text: string): { from: number; to: number } {
  const line = lineAt(index, text)
  if (!isQuote(line, text)) return line
  let start = line.from
  while (start > 0) {
    const above = lineAt(start - 1, text)
    // A quote line with a page link of its own ends the quotation before this one.
    if (!isQuote(above, text) || text.slice(above.from, above.to).includes('](papertime://anchor')) break
    start = above.from
  }
  return { from: start, to: line.to }
}

function lineAt(index: number, text: string): { from: number; to: number } {
  const at = Math.min(Math.max(index, 0), text.length)
  const from = at === 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1
  const next = text.indexOf('\n', at)
  let to = next < 0 ? text.length : next
  if (to > from && text[to - 1] === '\r') to -= 1
  return { from, to }
}

/** A block quote's line: up to three spaces, then `>`. */
function isQuote(line: { from: number; to: number }, text: string): boolean {
  let index = line.from
  let spaces = 0
  while (index < line.to && text[index] === ' ' && spaces < 3) {
    index += 1
    spaces += 1
  }
  return index < line.to && text[index] === '>'
}

/** A passage of the open paper that a note quotes: the way back from the page to the quotation (`QuoteLink`). */
export interface QuoteLink {
  noteID: string
  /** The note's name, for the tooltip. */
  noteTitle: string
  modified: number
  passage: QuotedPassage
  /** The quotation as the note writes it — the words the page's text is searched for, to tint the passage and nothing round it. */
  quotation: string
}

/** Every passage of a paper that the notes quote, the newest note's last — so where two notes quote one passage, the newer is on top. */
export function quoteLinksOf(
  notes: readonly { id: string; body: string; paperID: string | null; modified: Date; title: string }[],
  paperID: string,
  title: (note: { title: string; body: string }) => string,
): QuoteLink[] {
  const links: QuoteLink[] = []
  for (const note of notes) {
    if (!note.body.includes('papertime://anchor')) continue
    for (const passage of quotedPassagesOfPaper(note, paperID)) {
      links.push({
        noteID: note.id,
        noteTitle: title(note),
        modified: note.modified.getTime(),
        passage,
        quotation: note.body.slice(passage.quote.from, passage.quote.to),
      })
    }
  }
  return links.sort((a, b) => a.modified - b.modified)
}

/** A box on a page, in the page's own coordinates (y up). */
export interface PageBox { x: number; y: number; width: number; height: number }

/**
 * How much of the accent a quoted passage's wash takes, at rest and under the
 * pointer — the Mac's `QuoteWash.shares`, and the CSS's `--quote-wash` and
 * `--quote-wash-lit`.
 */
export const QUOTE_WASH = { rest: 0.18, lit: 0.3 }

/**
 * Where a quotation's words lie in a stretch of the page's text — so the page
 * can tint exactly the passage that was quoted (`QuotedPassages.span`).
 *
 * The anchor keeps only the box round the passage, and the box of a passage
 * that starts in the middle of a line takes in the words before it. The note
 * still holds the words, so they are looked for in the text that box holds.
 * Only letters and digits are compared — case folded, accents and ligatures
 * taken apart, the dotless ı and ȷ read as i and j — and LaTeX's command words
 * are left out of the quotation. The whole quotation is looked for first; one
 * that was edited, or whose formulas read differently, is placed by the
 * longest stretch of its opening the text holds and the longest of its close —
 * eight letters at the least, or the text's own start and end stand in, less
 * any line there that holds almost nothing of the quotation. Null when neither
 * end is there, and for a quotation of fewer than four letters, which could be
 * found anywhere. The span takes in the punctuation the quotation opens and
 * closes with. Offsets are UTF-16, into `text`, whose lines are its `\n`s.
 */
export function quoteSpan(quotation: string, text: string): { from: number; to: number } | null {
  const words = cleanedQuotation(quotation)
  const wanted = keysOf(words).values
  const page = keysOf(text)
  const found = page.values
  if (wanted.length < 4 || found.length === 0) return null

  let start: number | null = null
  let end: number | null = null
  const head = longestOpening(wanted, found)
  if (head.length === wanted.length) {
    start = head.end - head.length
    end = head.end
  } else {
    const enough = Math.min(wanted.length, 8)
    const tail = longestOpening([...wanted].reverse(), [...found].reverse())
    if (head.length >= enough) start = head.end - head.length
    if (tail.length >= enough) end = found.length - tail.end + tail.length
    // The two ends found out of order: the longer is believed.
    if (start !== null && end !== null && end <= start) {
      if (head.length >= tail.length) end = null
      else start = null
    }
  }
  if (start === null && end === null) return null
  let from = start ?? 0
  let to = end ?? found.length
  if (to <= from) return null
  // Where an end was not found, a line at that end that holds almost nothing
  // of the quotation is a neighbour the box reached into: PDFKit draws the box
  // round a displayed formula as deep as its brackets' font goes, over the
  // line under it.
  const line = lineNumbers(page.from, text)
  const belongs = neighbours(wanted)
  if (end === null) {
    while (to - 1 > from && line[to - 1] > line[from]) {
      let first = to - 1
      while (first > from && line[first - 1] === line[to - 1]) first -= 1
      if (belongs(found.slice(first, to))) break
      to = first
    }
  }
  if (start === null) {
    while (from < to - 1 && line[from] < line[to - 1]) {
      let last = from + 1
      while (last < to && line[last] === line[from]) last += 1
      if (belongs(found.slice(from, last))) break
      from = last
    }
  }

  const scalars: number[] = []
  const offsets: number[] = []
  let offset = 0
  for (const character of text) {
    scalars.push(character.codePointAt(0)!)
    offsets.push(offset)
    offset += character.length
  }
  offsets.push(offset)
  // The quotation's own opening and closing punctuation, where the text has it
  // right against the words — and where it opens or closes with a formula, the
  // formula's marks the text has there: «∇θ» before «L», which the formula's
  // commands do not spell. Any more punctuation than the quotation's own is
  // the sentence's.
  let first = Math.max(offsets.indexOf(page.from[from]), 0)
  const opening = edge(words, false)
  if (opening.math) {
    const core = first
    while (first > 0 && isFormulaMark(scalars[first - 1])) first -= 1
    let marks = scalars.slice(first, core).filter(isPunctuation).length
    while (marks > opening.punctuation && first < core && isPunctuation(scalars[first])) {
      first += 1
      marks -= 1
    }
  } else {
    for (let left = opening.punctuation; left > 0; left -= 1) {
      if (first <= 0 || !isPunctuation(scalars[first - 1])) break
      first -= 1
    }
  }
  let last = offsets.indexOf(page.to[to - 1])
  if (last < 0) last = scalars.length
  const closing = edge(words, true)
  if (closing.math) {
    const core = last
    while (last < scalars.length && isFormulaMark(scalars[last])) last += 1
    let marks = scalars.slice(core, last).filter(isPunctuation).length
    while (marks > closing.punctuation && last > core && isPunctuation(scalars[last - 1])) {
      last -= 1
      marks -= 1
    }
  } else {
    for (let left = closing.punctuation; left > 0; left -= 1) {
      if (last >= scalars.length || !isPunctuation(scalars[last])) break
      last += 1
    }
  }
  return { from: offsets[first], to: offsets[last] }
}

/** Which line of the text each key is on, from where the key's character starts. */
function lineNumbers(starts: readonly number[], text: string): number[] {
  const breaks: number[] = []
  for (let offset = 0; offset < text.length; offset += 1) if (text.charCodeAt(offset) === 10) breaks.push(offset)
  const numbers: number[] = []
  let passed = 0
  for (const at of starts) {
    while (passed < breaks.length && breaks[passed] < at) passed += 1
    numbers.push(passed)
  }
  return numbers
}

/** Whether a line's keys are the quotation's: three in ten of its neighbouring pairs are pairs the quotation has too. A line of one key is if the quotation has that key — an equation's «(3)». */
function neighbours(wanted: readonly number[]): (line: readonly number[]) => boolean {
  const pairs = new Set<string>()
  for (let index = 0; index + 1 < wanted.length; index += 1) pairs.add(`${wanted[index]},${wanted[index + 1]}`)
  const keys = new Set(wanted)
  return (line) => {
    if (line.length < 2) return line.every((key) => keys.has(key))
    let shared = 0
    for (let index = 0; index + 1 < line.length; index += 1) if (pairs.has(`${line[index]},${line[index + 1]}`)) shared += 1
    return shared >= (line.length - 1) * 0.3
  }
}

/** A quotation as words: its page links taken out, and LaTeX's command words (`\theta`) and control symbols (`\{`, `\\`) — with the argument of a command whose argument the page does not print, and an equation's tag as the number the page prints. */
function cleanedQuotation(quotation: string): string {
  const scalars = [...quotation.replace(LINK, ' ')]
  let kept = ''
  let index = 0
  while (index < scalars.length) {
    if (scalars[index] !== '\\') {
      kept += scalars[index]
      index += 1
      continue
    }
    index += 1
    if (index >= scalars.length || !isASCIILetter(scalars[index])) {
      if (index < scalars.length) index += 1
      continue
    }
    let word = ''
    while (index < scalars.length && isASCIILetter(scalars[index])) {
      word += scalars[index]
      index += 1
    }
    if (word !== 'tag' && !UNPRINTED.has(word)) continue
    let next = index
    while (next < scalars.length && scalars[next] === ' ') next += 1
    if (next >= scalars.length || scalars[next] !== '{') continue
    const open = next
    let depth = 0
    while (next < scalars.length) {
      if (scalars[next] === '{') depth += 1
      if (scalars[next] === '}') depth -= 1
      next += 1
      if (depth === 0) break
    }
    // An equation's number is printed in brackets: «(3)».
    if (word === 'tag') kept += `(${scalars.slice(open + 1, Math.max(open + 1, next - 1)).join('')})`
    index = next
  }
  return kept
}

/** Commands whose argument the page does not print: an environment's name (`\begin{equation}`), a label and what refers to it, a citation's key, a colour. */
const UNPRINTED = new Set(['begin', 'end', 'label', 'ref', 'eqref', 'cite', 'color', 'textcolor'])

const isASCIILetter = (character: string) => /^[A-Za-z]$/.test(character)

/** A letter or a digit — not a modifier letter, which is mostly the accents a PDF sets on their own (ˆ). */
const KEY = /^[\p{Lu}\p{Ll}\p{Lt}\p{Lo}\p{Nd}]$/u

/** The letters and digits of a text, folded so two hands' spellings of one passage agree — each with the UTF-16 span of the character it came from. */
function keysOf(text: string): { values: number[]; from: number[]; to: number[] } {
  const keys = { values: [] as number[], from: [] as number[], to: [] as number[] }
  let offset = 0
  for (const character of text) {
    for (const value of characterKeys(character.codePointAt(0)!)) {
      keys.values.push(value)
      keys.from.push(offset)
      keys.to.push(offset + character.length)
    }
    offset += character.length
  }
  return keys
}

/** One character's keys: taken apart (NFKD), each letter or digit of that lowercased; ı and ȷ as i and j. */
function characterKeys(point: number): number[] {
  if (point < 0x80) {
    if (point >= 0x41 && point <= 0x5a) return [point + 0x20]
    if ((point >= 0x61 && point <= 0x7a) || (point >= 0x30 && point <= 0x39)) return [point]
    return []
  }
  const values: number[] = []
  for (const part of String.fromCodePoint(point).normalize('NFKD')) {
    if (!KEY.test(part)) continue
    for (const lower of part.toLowerCase()) {
      if (!KEY.test(lower)) continue
      const value = lower.codePointAt(0)!
      values.push(value === 0x131 ? 0x69 : value === 0x237 ? 0x6a : value)
    }
  }
  return values
}

/** Punctuation a passage can open or close with. Not Markdown's own marks, nor LaTeX's braces. */
function isPunctuation(point: number): boolean {
  const character = String.fromCodePoint(point)
  return /^\p{P}$/u.test(character) && !'*_#{}\\'.includes(character)
}

/** How the words open (or close), before their first (or after their last) letter or digit: how many marks of punctuation, and whether in a formula. */
function edge(words: string, fromEnd: boolean): { punctuation: number; math: boolean } {
  const scalars = [...words]
  if (fromEnd) scalars.reverse()
  let punctuation = 0
  let math = false
  for (const character of scalars) {
    const point = character.codePointAt(0)!
    if (characterKeys(point).length > 0) break
    if (character === '$') math = true
    if (isPunctuation(point)) punctuation += 1
  }
  return { punctuation, math }
}

/** What a formula sets that the words round it are not made of: not a space, not a Latin letter or a digit — a symbol, a bracket, a Greek letter, a glyph the text has no letter for. */
function isFormulaMark(point: number): boolean {
  return !/^\p{White_Space}$/u.test(String.fromCodePoint(point)) && !(point < 0x80 && characterKeys(point).length === 1)
}

/** The longest opening of `pattern` that `text` holds, and where the first such stretch ends (exclusive). Knuth–Morris–Pratt: one pass. */
function longestOpening(pattern: readonly number[], text: readonly number[]): { length: number; end: number } {
  if (pattern.length === 0 || text.length === 0) return { length: 0, end: 0 }
  const failure = new Array<number>(pattern.length).fill(0)
  let matched = 0
  for (let index = 1; index < pattern.length; index += 1) {
    while (matched > 0 && pattern[index] !== pattern[matched]) matched = failure[matched - 1]
    if (pattern[index] === pattern[matched]) matched += 1
    failure[index] = matched
  }
  let best = 0
  let end = 0
  matched = 0
  for (let index = 0; index < text.length; index += 1) {
    const value = text[index]
    while (matched > 0 && (matched === pattern.length || pattern[matched] !== value)) matched = failure[matched - 1]
    if (pattern[matched] === value) matched += 1
    if (matched > best) {
      best = matched
      end = index + 1
      if (best === pattern.length) break
    }
  }
  return { length: best, end }
}
