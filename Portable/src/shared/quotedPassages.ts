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
 * eight letters at the least, or the text's own start and end stand in. Null
 * when neither end is there. The span takes in the punctuation the quotation
 * opens and closes with. Offsets are UTF-16, into `text`.
 */
export function quoteSpan(quotation: string, text: string): { from: number; to: number } | null {
  const words = cleanedQuotation(quotation)
  const wanted = keysOf(words).values
  const page = keysOf(text)
  const found = page.values
  if (wanted.length === 0 || found.length === 0) return null

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
  const from = start ?? 0
  const to = end ?? found.length
  if (to <= from) return null

  const scalars: number[] = []
  const offsets: number[] = []
  let offset = 0
  for (const character of text) {
    scalars.push(character.codePointAt(0)!)
    offsets.push(offset)
    offset += character.length
  }
  offsets.push(offset)
  let lower = page.from[from]
  let upper = page.to[to - 1]
  // The quotation's own opening and closing punctuation, where the text has it right against the words.
  let first = Math.max(offsets.indexOf(lower), 0)
  for (let left = edgePunctuation(words, false); left > 0; left -= 1) {
    if (first <= 0 || !isPunctuation(scalars[first - 1])) break
    first -= 1
    lower = offsets[first]
  }
  let last = offsets.indexOf(upper)
  if (last < 0) last = scalars.length
  for (let left = edgePunctuation(words, true); left > 0; left -= 1) {
    if (last >= scalars.length || !isPunctuation(scalars[last])) break
    last += 1
    upper = offsets[last]
  }
  return { from: lower, to: upper }
}

/** A quotation as words: its page links taken out, and LaTeX's command words (`\theta`) and control symbols (`\{`, `\\`). */
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
    if (index < scalars.length && isASCIILetter(scalars[index])) {
      while (index < scalars.length && isASCIILetter(scalars[index])) index += 1
    } else if (index < scalars.length) {
      index += 1
    }
  }
  return kept
}

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

/** How many marks of punctuation the words open (or close) with, before their first (or after their last) letter or digit. */
function edgePunctuation(words: string, fromEnd: boolean): number {
  const scalars = [...words]
  if (fromEnd) scalars.reverse()
  let count = 0
  for (const character of scalars) {
    const point = character.codePointAt(0)!
    if (characterKeys(point).length > 0) break
    if (isPunctuation(point)) count += 1
  }
  return count
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
