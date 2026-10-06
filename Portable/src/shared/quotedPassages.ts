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
  /** The note's name, for the rule's tooltip. */
  noteTitle: string
  modified: number
  passage: QuotedPassage
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
      links.push({ noteID: note.id, noteTitle: title(note), modified: note.modified.getTime(), passage })
    }
  }
  return links.sort((a, b) => a.modified - b.modified)
}

/** A box on a page, in the page's own coordinates (y up). */
export interface PageBox { x: number; y: number; width: number; height: number }

/** The rule's width and its distance from the column's words, in page units — the Mac's `QuoteBar`. */
export const QUOTE_RULE = { width: 2, gap: 4 }

/**
 * Where the rule beside a quoted passage stands, and what a click on it
 * takes: left of the column the passage is set in, not left of the passage —
 * a passage that starts in the middle of a line put it between two words.
 * The column's edge is where the passage's first and last lines begin: the
 * runs on that line, walked left from the passage while the gap between them
 * is a word's and not a gutter's. `view` is the page's box,
 * `[x0, y0, x1, y1]`. Null for a passage with nowhere to stand.
 */
export function quoteRule(passage: PageBox, runs: readonly PageBox[], view: readonly number[]): { rect: PageBox; target: PageBox } | null {
  const [x0, y0, x1, y1] = view
  const { x, y, width, height } = passage
  if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0) return null
  if (x > x1 || x + width < x0 || y > y1 || y + height < y0) return null
  let left = x
  const reach = Math.min(height / 2, 6)
  for (const at of [y + height - reach, y + reach]) {
    const line = runs.filter((run) => run.y - 1 <= at && at <= run.y + run.height + 1).sort((a, b) => a.x - b.x)
    // The run the passage starts in, or the last one before it.
    let index = -1
    for (let i = 0; i < line.length; i += 1) if (line[i].x <= x + 1) index = i
    if (index < 0 || line[index].x + line[index].width < x - line[index].height * 1.2) continue
    while (index > 0) {
      const before = line[index - 1]
      const gap = line[index].x - (before.x + before.width)
      // A word's gap, not a gutter's: about an em.
      if (gap > Math.max(line[index].height, before.height) * 1.2) break
      index -= 1
    }
    // A line that reaches across to the other column is not one this rule can stand beside.
    if (x - line[index].x < (x1 - x0) / 2) left = Math.min(left, line[index].x)
  }
  const ruleX = Math.max(x0 + 1, left - QUOTE_RULE.gap - QUOTE_RULE.width)
  const rect = { x: ruleX, y: y + 1, width: QUOTE_RULE.width, height: Math.max(height - 2, QUOTE_RULE.width) }
  return { rect, target: { x: rect.x - 5, y: rect.y - 1, width: rect.width + 10, height: rect.height + 2 } }
}
