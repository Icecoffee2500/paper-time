/**
 * One note in the slip-box, and the file it is.
 *
 * The port of the Mac's `Zettel` and `ZettelFile`: a Markdown file with a
 * short `---` header, kept in one folder for the whole library
 * (`.papertime/notes/<id>.md`). The same file is opened on both desktops, so
 * "the same" means the same bytes — a header written one way there and
 * another way here is a whole-file change to every sync client — and the
 * same reading, so a note that the Mac reads as titled, tagged and about
 * paper X is that note here too. `Fixtures/zettel-files.json` is what the
 * Mac writes and reads; `src/test/zettel.ts` runs this against it.
 *
 * ```markdown
 * ---
 * id: 202609081530
 * title: OpenVLA turns a VLM into a policy
 * paper: 4F3A1C08-…
 * tags: vla, robotics
 * created: 2026-09-08T15:30:00Z
 * ---
 *
 * The action head is just detokenised text, which means …
 * See [[202609061204|Discretising continuous actions]].
 * ```
 */

/** What a note is for. A *map* arranges other notes; a *draft* is writing
 *  on its way out of the box. */
export type ZettelKind = 'note' | 'map' | 'draft'

export interface Zettel {
  /** The identifier written on the note, and the name of its file: the
   *  minute it was made. It never changes, so links to it never break. */
  id: string
  kind: ZettelKind
  title: string
  body: string
  /** The paper being read when it was written — an upper-case UUID — or null. */
  paperID: string | null
  created: Date
  modified: Date
}

// MARK: - Foundation's character sets, as the Mac trims and matches with them

/**
 * `CharacterSet.whitespaces`: what a header value and a preview line are
 * trimmed of. Read off Foundation on the Mac, code point by code point —
 * not the documented «Zs and tab»: U+200B is in it.
 */
const WHITESPACE = new Set([0x09, 0x20, 0xa0, 0x1680, ...range(0x2000, 0x200b), 0x202f, 0x205f, 0x3000])
/** `CharacterSet.whitespacesAndNewlines`: what says a title or a body is empty. */
const WHITESPACE_NEWLINES = new Set([...range(0x09, 0x0d), 0x20, 0x85, 0xa0, 0x1680, ...range(0x2000, 0x200b), 0x2028, 0x2029, 0x202f, 0x205f, 0x3000])
/** ICU's `\s`, which the Mac's patterns are written with: Unicode
 *  White_Space — U+0085 in, U+200B out — where JavaScript's has U+FEFF in
 *  and U+0085 out. */
const RS = '\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000'

function range(from: number, to: number): number[] {
  const out: number[] = []
  for (let v = from; v <= to; v += 1) out.push(v)
  return out
}

function trim(text: string, set: Set<number>): string {
  let from = 0
  let to = text.length
  while (from < to && set.has(text.charCodeAt(from))) from += 1
  while (to > from && set.has(text.charCodeAt(to - 1))) to -= 1
  return text.slice(from, to)
}

/** `trimmingCharacters(in: .whitespaces)`. */
export function trimWhitespace(text: string): string {
  return trim(text, WHITESPACE)
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimWhitespaceAndNewlines(text: string): string {
  return trim(text, WHITESPACE_NEWLINES)
}

/**
 * The lines of a text as Swift splits them on `"\n"`: `"\r\n"` is one
 * character there, not a newline followed by something, so a line that ends
 * in one runs on into the next.
 */
function swiftLines(text: string, omitEmpty: boolean): string[] {
  const lines: string[] = []
  let start = 0
  for (let at = 0; at < text.length; at += 1) {
    if (text.charCodeAt(at) !== 10 || (at > 0 && text.charCodeAt(at - 1) === 13)) continue
    const line = text.slice(start, at)
    if (line.length > 0 || !omitEmpty) lines.push(line)
    start = at + 1
  }
  const last = text.slice(start)
  if (last.length > 0 || (!omitEmpty && (text.length > 0 || lines.length === 0))) lines.push(last)
  return lines
}

// MARK: - The file

/** The text of a note on disk: the header, then the note — byte for byte the Mac's. */
export function zettelText(note: Zettel): string {
  let header = '---\n'
  header += `id: ${note.id}\n`
  if (note.kind !== 'note') header += `kind: ${note.kind}\n`
  if (note.title.length > 0) header += `title: ${note.title}\n`
  if (note.paperID) header += `paper: ${note.paperID}\n`
  const tags = zettelTags(note.body)
  if (tags.length > 0) header += `tags: ${tags.join(', ')}\n`
  header += `created: ${isoSeconds(note.created)}\n`
  header += '---\n\n'
  return header + note.body
}

/** `Date.formatted(.iso8601)`: whole seconds, floored, always in UTC. */
export function isoSeconds(date: Date): string {
  const seconds = Math.floor(date.getTime() / 1000)
  const at = new Date(seconds * 1000)
  const pad = (value: number, width = 2) => String(value).padStart(width, '0')
  return `${pad(at.getUTCFullYear(), 4)}-${pad(at.getUTCMonth() + 1)}-${pad(at.getUTCDate())}`
    + `T${pad(at.getUTCHours())}:${pad(at.getUTCMinutes())}:${pad(at.getUTCSeconds())}Z`
}

/**
 * A `created:` value, read the way `Date(_, strategy: .iso8601)` reads it —
 * which is more lenient than the standard and less than a browser. Probed on
 * the Mac: a time zone is required (`Z`, `+09`, `+0900`, `+09:00`), whatever
 * follows it is ignored, single-digit fields pass, hours and minutes and
 * seconds may overflow (`24:00:00` is the next day), a month or day of nought
 * or a month past twelve do not, a fraction has one to nine digits, and the
 * result is kept to the microsecond. A date without a time, a space for the
 * `T`, a lower-case `t` and a comma for the fraction are refused.
 */
export function parseISO8601(text: string): Date | null {
  const match = /^(\d+)-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d{1,9}))?(Z|z|[+-]\d{1,2}(?::?\d{1,2})?(?::?\d{1,2})?)/.exec(text)
  if (!match) return null
  const [, year, month, day, hour, minute, second, fraction, zone] = match
  if (Number(month) < 1 || Number(month) > 12 || Number(day) < 1) return null
  let offset = 0
  if (zone !== 'Z' && zone !== 'z') {
    const parts = /^([+-])(\d{1,2})(?::?(\d{1,2}))?(?::?(\d{1,2}))?$/.exec(zone)
    if (!parts) return null
    const hours = Number(parts[2])
    const minutes = Number(parts[3] ?? 0)
    if (hours > 18 || (hours === 18 && minutes > 0)) return null
    offset = (parts[1] === '-' ? -1 : 1) * (hours * 3600 + minutes * 60 + Number(parts[4] ?? 0))
  }
  const whole = Date.UTC(Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second)) / 1000
  const fractional = fraction ? Math.round(Number(`0.${fraction}`) * 1e6) / 1e6 : 0
  const seconds = whole + fractional - offset
  if (!Number.isFinite(seconds)) return null
  return new Date(seconds * 1000)
}

/** A paper's identifier as `UUID(uuidString:)` takes it: the five groups, in either case, given back in upper case. */
export function paperIDFrom(text: string | undefined): string | null {
  if (!text || !/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(text)) return null
  return text.toUpperCase()
}

/**
 * A note read back from its file — `ZettelFile.note(from:id:modified:)`.
 *
 * The header is there when the text opens with `---` on a line of its own
 * and a second `---` closes it on a line of its own; anything else is all
 * body. Keys are matched in lower case, values trimmed; an id the header
 * does not carry is the file's name, and a creation time it does not carry,
 * or one that will not read, is when the file was last written.
 */
export function zettelFromText(text: string, fallbackID: string, modified: Date): Zettel {
  const fields = new Map<string, string>()
  let body = text
  if (text.startsWith('---\n')) {
    const fence = closingFence(text)
    if (fence) {
      for (const line of swiftLines(text.slice(4, fence.from), true)) {
        const colon = line.indexOf(':')
        if (colon < 0) continue
        fields.set(trimWhitespace(line.slice(0, colon)).toLowerCase(), trimWhitespace(line.slice(colon + 1)))
      }
      body = text.slice(fence.to)
      while (body.startsWith('\n')) body = body.slice(1)
    }
  }
  const kind = fields.get('kind')
  const created = fields.get('created')
  return {
    id: fields.get('id') ?? fallbackID,
    kind: kind === 'map' || kind === 'draft' ? kind : 'note',
    title: fields.get('title') ?? '',
    body,
    paperID: paperIDFrom(fields.get('paper')),
    created: (created === undefined ? null : parseISO8601(created)) ?? modified,
    modified,
  }
}

/**
 * The `---` that closes the header: `\n---` followed by the end, a newline
 * or a bare return. As on the Mac, where `"\r\n"` is one character: a fence
 * whose newline is the tail of one, or that is followed by one, is not one.
 */
function closingFence(text: string): { from: number; to: number } | null {
  let search = 4
  while (true) {
    const found = text.indexOf('\n---', search)
    if (found < 0) return null
    search = found + 1
    if (text.charCodeAt(found - 1) === 13) continue
    const after = found + 4
    if (after === text.length) return { from: found, to: after }
    const next = text.charCodeAt(after)
    if (next === 10) return { from: found, to: after }
    if (next === 13 && text.charCodeAt(after + 1) !== 10) return { from: found, to: after }
  }
}

// MARK: - What the text says

const TAG = new RegExp(`(?:^|[${RS}])#([\\p{L}\\p{N}][\\p{L}\\p{N}_/-]*)`, 'gu')
const LINK = /\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]/g

/** The keywords written in the note as `#tag`, first of each in the order written. */
export function zettelTags(body: string): string[] {
  if (!body.includes('#')) return []
  return unique([...body.matchAll(TAG)].map((match) => match[1]))
}

/** The notes this one points at, by identifier. */
export function zettelLinks(body: string): string[] {
  if (!body.includes('[[')) return []
  return unique([...body.matchAll(LINK)].map((match) => match[1]))
}

function unique(list: string[]): string[] {
  const seen = new Set<string>()
  return list.filter((one) => !seen.has(one) && Boolean(seen.add(one)))
}

const NOTATION = [
  // Formulas, display first: `$$…$$` before `$…$`, or the opening pair of a
  // display formula reads as one empty inline formula.
  /\$\$[\s\S]*?\$\$/g,
  /\$[^$\n]*?\$/g,
  /```[\s\S]*?```/g,
  // Images, before links: an image is a link with a bang on it.
  new RegExp(`!\\[[^\\]]*\\]\\([^)${RS}]*\\)`, 'g'),
]
const LABELLED_LINK = /\[\[([^\]|]+)\|([^\]]*)\]\]/g
const BARE_LINK = /\[\[([^\]|]+)\]\]/g
const MARKDOWN_LINK = new RegExp(`\\[([^\\]\\n]*)\\]\\([^)${RS}]*\\)`, 'g')
const LIST_MARKER = new RegExp(`^[${RS}]*([-*+]|\\p{Nd}+\\.)[${RS}]+`, 'u')
const RUNS = new RegExp(`[${RS}]{2,}`, 'g')
const DOUBLED_PUNCTUATION = new RegExp(`([,;:])([${RS}]*[,;:])+`, 'g')
const SPACE_BEFORE_PUNCTUATION = new RegExp(`[${RS}]+([,.;:!?])`, 'g')

/**
 * The first words of the body, in prose, for a row in a list — the Mac's
 * `Zettel.preview`, step for step. Everything that is notation rather than
 * words comes out: a formula is an object in a note, like a picture.
 */
export function zettelPreview(body: string): string {
  let text = body
  for (const pattern of NOTATION) text = text.replace(pattern, ' ')
  text = text
    .replace(LABELLED_LINK, '$2')
    .replace(BARE_LINK, '$1')
    .replace(MARKDOWN_LINK, '$1')
  const joined = swiftLines(text, true)
    .map((line) => {
      let piece = line
      while (piece.startsWith('#')) piece = piece.slice(1)
      while (piece.startsWith('>')) piece = piece.slice(1)
      piece = piece.replace(LIST_MARKER, '')
      return trimWhitespace(piece.split('**').join('').split('`').join(''))
    })
    .filter((line) => line.length > 0)
    .join(' ')
    // Taking things out leaves gaps, and punctuation that was holding hands
    // with what was taken: "a formula, $x$, should" came out as "a formula, , should".
    .replace(RUNS, ' ')
    .replace(DOUBLED_PUNCTUATION, '$1')
    .replace(SPACE_BEFORE_PUNCTUATION, '$1')
  return trimWhitespace(joined)
}

let segmenter: Intl.Segmenter | null = null

/** The first `count` characters as Swift counts them — graphemes, not code units. */
function prefix(text: string, count: number): string {
  segmenter ??= new Intl.Segmenter('und', { granularity: 'grapheme' })
  let end = 0
  let seen = 0
  for (const part of segmenter.segment(text)) {
    if (seen === count) break
    end = part.index + part.segment.length
    seen += 1
  }
  return text.slice(0, end)
}

/** What a row calls the note: its title, else its first words, else what kind of nothing it is. */
export function zettelDisplayTitle(note: Pick<Zettel, 'title' | 'body'>): string {
  const trimmed = trimWhitespaceAndNewlines(note.title)
  if (trimmed.length > 0) return trimmed
  const firstLine = trimWhitespace(prefix(zettelPreview(note.body), 60))
  if (firstLine.length > 0) return firstLine
  return note.body.includes('$') ? 'Formula' : 'Untitled Note'
}

/**
 * What a row shows under the title: the preview with the title taken off
 * its front when the title *is* the first of it, so a row does not say one
 * thing twice.
 */
export function zettelPreviewBody(note: Pick<Zettel, 'title' | 'body'>): string {
  const full = zettelPreview(note.body)
  const shown = zettelDisplayTitle(note)
  if (trimWhitespaceAndNewlines(note.title).length > 0 || !full.startsWith(shown)) return full
  return trimWhitespace(full.slice(shown.length))
}

export function zettelIsEmpty(note: Pick<Zettel, 'title' | 'body'>): boolean {
  return trimWhitespaceAndNewlines(note.title).length === 0 && trimWhitespaceAndNewlines(note.body).length === 0
}

/** How this note is written into another one. */
export function zettelLinkMarkdown(note: Pick<Zettel, 'id' | 'title' | 'body'>): string {
  return `[[${note.id}|${zettelDisplayTitle(note)}]]`
}

/** One heading of a map and the notes under it. */
export interface MapSection {
  title: string
  entries: { id: string; label: string }[]
}

/** A map's body read as an outline: its headings, and under each the notes it links to. */
export function zettelOutline(body: string): MapSection[] {
  const sections: MapSection[] = [{ title: '', entries: [] }]
  for (const line of swiftLines(body, false)) {
    if (line.startsWith('#')) {
      sections.push({ title: trimWhitespace(line.replace(/^#+/, '')), entries: [] })
      continue
    }
    for (const match of line.matchAll(LINK)) {
      sections[sections.length - 1].entries.push({ id: match[1], label: match[2] ?? '' })
    }
  }
  return sections.filter((section) => section.entries.length > 0 || section.title.length > 0)
}

/**
 * Identifiers are the minute the note was made, in local time, which is
 * short enough to type and long enough to stay unique in a box one person
 * writes. `Zettel.makeID(at:avoiding:)`.
 */
export function makeZettelID(at: Date, taken: Set<string>, random: () => string = randomTail): string {
  const pad = (value: number) => String(value).padStart(2, '0')
  const base = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}${pad(at.getHours())}${pad(at.getMinutes())}`
  if (!taken.has(base)) return base
  for (let suffix = 1; suffix <= 99; suffix += 1) {
    const candidate = `${base}-${suffix}`
    if (!taken.has(candidate)) return candidate
  }
  return `${base}-${random()}`
}

function randomTail(): string {
  return Math.floor(Math.random() * 0x10000).toString(16).toUpperCase().padStart(4, '0')
}
