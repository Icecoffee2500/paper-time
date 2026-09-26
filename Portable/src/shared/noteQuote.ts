/**
 * A passage going into a note as a quotation — Command-L, the Mac's
 * `NoteAnchor` and `NoteMarkdown.quotationSource`, character for character.
 *
 * The note is plain Markdown, so the passage is a block quote and the way
 * back to the page is an ordinary link on its last line:
 *
 *     > the encoder is trained with a masked objective [p. 4](papertime://anchor?p=3&x=145.00&y=95.00&w=366.00&h=12.00)
 *
 * The same bytes on both desktops, because the same note is opened on both:
 * a quotation written here has to be a quotation the Mac's editor sets as
 * one, with its page chip, and follows back to the page.
 */

export interface NoteAnchor {
  pageIndex: number
  /** In the page's own coordinates, origin at the lower left — PDFKit's. */
  rect: { x: number; y: number; width: number; height: number }
  quotedText: string
  /** Only when the passage is not from the note's own paper. */
  paperID?: string
}

/** `papertime://anchor?p=…&x=…&y=…&w=…&h=…`, with `%.2f` numbers as Swift writes them. */
export function anchorURL(anchor: NoteAnchor): string {
  const format = (value: number) => (Object.is(value, -0) ? 0 : value).toFixed(2)
  const query = [
    `p=${anchor.pageIndex}`,
    `x=${format(anchor.rect.x)}`,
    `y=${format(anchor.rect.y)}`,
    `w=${format(anchor.rect.width)}`,
    `h=${format(anchor.rect.height)}`,
  ]
  if (anchor.paperID) query.push(`paper=${anchor.paperID.toUpperCase()}`)
  return `papertime://anchor?${query.join('&')}`
}

/** Reads a link written by either build back into a place: the page and the box. */
export function parseAnchorURL(url: string): { pageIndex: number; rect: NoteAnchor['rect']; paperID?: string } | null {
  const match = /^papertime:\/\/anchor\?(.*)$/.exec(url.trim())
  if (!match) return null
  const items = new Map<string, string>()
  for (const part of match[1].split('&')) {
    const cut = part.indexOf('=')
    if (cut > 0) items.set(part.slice(0, cut), decodeURIComponent(part.slice(cut + 1)))
  }
  const value = (name: string) => {
    const text = items.get(name)
    return text !== undefined && /^[+-]?(\d+\.?\d*|\.\d+)$/.test(text) ? Number(text) : null
  }
  const p = value('p'), x = value('x'), y = value('y'), w = value('w'), h = value('h')
  if (p === null || x === null || y === null || w === null || h === null) return null
  const paperID = items.get('paper')
  return { pageIndex: Math.trunc(p), rect: { x, y, width: w, height: h }, ...(paperID ? { paperID } : {}) }
}

/** What the link reads as when the passage has no words: its first seven, or the page. */
export function anchorLabel(anchor: NoteAnchor): string {
  const words = anchor.quotedText.replace(/\n/g, ' ').split(' ').filter((word) => word.length > 0)
  const short = words.slice(0, 7).join(' ')
  const ellipsis = words.length > 7 ? '…' : ''
  return short ? `${short}${ellipsis}` : `p. ${anchor.pageIndex + 1}`
}

/** Brackets and backslashes would end the link's label early. */
export function escapeLabel(text: string): string {
  return text.replace(/[\\[\]]/g, (character) => `\\${character}`)
}

/** A line of the passage, broken where a displayed formula wants a line of its own. */
export function quotationLines(text: string): string[] {
  const lines: string[] = []
  const add = (piece: string) => {
    const trimmed = piece.trim()
    if (trimmed) lines.push(trimmed)
  }
  let index = 0
  for (const match of text.matchAll(/\$\$[^$]+\$\$/g)) {
    add(text.slice(index, match.index))
    add(match[0])
    index = (match.index ?? 0) + match[0].length
  }
  add(text.slice(index))
  return lines.length === 0 ? [text] : lines
}

/**
 * The Markdown for the passage: `> ` on every line, the page's link after the
 * last word — or on a line of its own under a displayed formula or a heading.
 * `pageWord` says «4쪽» or «p. 4», in the window's language, as the Mac does.
 */
export function quotationSource(anchor: NoteAnchor, pageWord: (page: number) => string): string {
  const text = anchor.quotedText.trim()
  const quoted = text ? text : anchorLabel(anchor)
  const lines = quoted.split('\n').flatMap((line) => {
    const trimmed = line.trim()
    return trimmed ? quotationLines(trimmed) : ['']
  })
  const citation = `[${escapeLabel(pageWord(anchor.pageIndex + 1))}](${anchorURL(anchor)})`
  const last = lines[lines.length - 1]
  if (last !== undefined && !last.startsWith('$$') && !last.startsWith('#')) {
    lines[lines.length - 1] = `${last} ${citation}`
  } else {
    lines.push(citation)
  }
  return lines.map((line) => (line ? `> ${line}\n` : '>\n')).join('')
}

/**
 * Where the block goes in the note: at the caret, on a line of its own, with
 * a line left after it to go on writing in — `NoteEditor.insert(_:into:)`.
 * Answers with what to type at the caret and where the caret ends up.
 */
export function quotationInsertion(note: string, caret: number, block: string): { insert: string; caret: number } {
  const at = Math.max(0, Math.min(caret, note.length))
  const head = note.slice(0, at)
  const tail = note.slice(at)
  const before = head.length > 0 && !head.endsWith('\n') ? '\n' : ''
  const after = tail.startsWith('\n') ? '' : '\n'
  const insert = before + block + after
  return { insert, caret: at + insert.length }
}

/**
 * The words of a selection on the page, as one passage.
 *
 * The page's text layer breaks at the end of every printed line, and a
 * quotation that kept those breaks would be a ragged column of fragments. A
 * word hyphenated at a line's end is joined again («mas-/ked» → «masked»);
 * a compound broken at one of its own hyphens keeps it («state-of-/the-art»).
 */
export function passageText(raw: string): string {
  return raw
    .replace(/\r\n?/g, '\n')
    .replace(/(\S+)-\n(?=[a-z])/g, (_, word: string) =>
      word.includes('-') || !/[A-Za-z]$/.test(word) ? `${word}-` : word)
    .replace(/[ \t]*\n[ \t]*/g, ' ')
    .replace(/[ \t]{2,}/g, ' ')
    .trim()
}
