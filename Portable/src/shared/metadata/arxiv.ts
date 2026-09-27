/**
 * arXiv's Atom API (`ArxivFeedParser`, `ArxivEntry.asCSLItem`).
 *
 * Foundation's `XMLParser` reads the feed on the Mac; here a small reader
 * does the same few things it is asked: elements by their qualified name
 * (`arxiv:doi`, namespaces not processed), attributes, character data with
 * the five named entities and numeric references decoded, comments and
 * processing instructions skipped. CDATA is dropped, as the Mac's delegate
 * never asks for it. Anything that does not parse throws, as `parse()` does.
 */

import type { CSLItem } from '../model.js'
import { parseName } from '../model.js'
import { emptyCSL, Malformed } from './csl.js'
import { trimWhitespaceAndNewlines } from '../zettel.js'

export interface ArxivEntry {
  id: string
  arxivID: string
  title: string
  summary: string
  authors: string[]
  /** [year, month, day] of `published`, in UTC. */
  published: number[]
  doi?: string
  journalRef?: string
  primaryCategory?: string
  categories: string[]
  comment?: string
  pdfURL?: string
}

type Event =
  | { kind: 'start'; name: string; attributes: Record<string, string> }
  | { kind: 'end'; name: string }
  | { kind: 'text'; text: string }

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/g, (whole, body: string) => {
    if (body.startsWith('#x')) return String.fromCodePoint(parseInt(body.slice(2), 16))
    if (body.startsWith('#')) return String.fromCodePoint(parseInt(body.slice(1), 10))
    const named: Record<string, string> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" }
    if (body in named) return named[body]
    throw new Malformed(`entity ${whole}`)
  })
}

/** The document as a stream of events, checked for balance. */
function* events(xml: string): Generator<Event> {
  const open: string[] = []
  let at = 0
  let sawRoot = false
  while (at < xml.length) {
    const lt = xml.indexOf('<', at)
    const textEnd = lt < 0 ? xml.length : lt
    if (textEnd > at) {
      const text = xml.slice(at, textEnd)
      if (open.length > 0) yield { kind: 'text', text: decodeEntities(text) }
      else if (text.trim()) throw new Malformed('text outside the root')
    }
    if (lt < 0) break
    if (xml.startsWith('<!--', lt)) {
      const end = xml.indexOf('-->', lt + 4)
      if (end < 0) throw new Malformed('comment')
      at = end + 3
      continue
    }
    if (xml.startsWith('<?', lt)) {
      const end = xml.indexOf('?>', lt + 2)
      if (end < 0) throw new Malformed('instruction')
      at = end + 2
      continue
    }
    if (xml.startsWith('<![CDATA[', lt)) {
      const end = xml.indexOf(']]>', lt + 9)
      if (end < 0) throw new Malformed('cdata')
      at = end + 3
      continue
    }
    if (xml.startsWith('<!', lt)) {
      const end = xml.indexOf('>', lt + 2)
      if (end < 0) throw new Malformed('declaration')
      at = end + 1
      continue
    }
    const tag = /^<(\/?)([A-Za-z_:][-A-Za-z0-9_:.]*)((?:\s+[A-Za-z_:][-A-Za-z0-9_:.]*\s*=\s*(?:"[^"<]*"|'[^'<]*'))*)\s*(\/?)>/.exec(xml.slice(lt))
    if (!tag) throw new Malformed('tag')
    const [whole, closing, name, rawAttributes, selfClosing] = tag
    at = lt + whole.length
    if (closing) {
      if (selfClosing || rawAttributes.trim() || open.pop() !== name) throw new Malformed(`</${name}>`)
      yield { kind: 'end', name }
      continue
    }
    if (open.length === 0 && sawRoot) throw new Malformed('second root')
    sawRoot = true
    const attributes: Record<string, string> = {}
    for (const one of rawAttributes.matchAll(/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"<]*)"|'([^'<]*)')/g)) {
      attributes[one[1]] = decodeEntities(one[2] ?? one[3] ?? '')
    }
    yield { kind: 'start', name, attributes }
    if (selfClosing) yield { kind: 'end', name }
    else open.push(name)
  }
  if (open.length > 0 || !sawRoot) throw new Malformed('unclosed')
}

/** `ArxivFeedParser.parse`. */
export function parseArxivFeed(xml: string): ArxivEntry[] {
  const entries: ArxivEntry[] = []
  let inEntry = false
  let text = ''
  let entry = blank()
  // The whole document is read before anything is handed back — a feed that
  // breaks half way is an unreadable feed, not half a feed.
  for (const event of [...events(xml)]) {
    if (event.kind === 'start') {
      text = ''
      if (event.name === 'entry') {
        inEntry = true
        entry = blank()
      } else if (inEntry && event.name === 'link') {
        if (event.attributes.title === 'pdf') entry.pdfURL = event.attributes.href
      } else if (inEntry && event.name === 'arxiv:primary_category') {
        entry.primaryCategory = event.attributes.term
      } else if (inEntry && event.name === 'category') {
        if (event.attributes.term !== undefined) entry.categories.push(event.attributes.term)
      }
    } else if (event.kind === 'text') {
      if (inEntry) text += event.text
    } else {
      if (!inEntry) continue
      const value = trimWhitespaceAndNewlines(text)
      switch (event.name) {
        case 'id': entry.id = value; break
        case 'title': entry.title = value; break
        case 'summary': entry.summary = value; break
        case 'name': if (value) entry.authors.push(value); break
        case 'published': entry.publishedRaw = value; break
        case 'arxiv:doi': entry.doi = value || undefined; break
        case 'arxiv:journal_ref': entry.journalRef = value || undefined; break
        case 'arxiv:comment': entry.comment = value || undefined; break
        case 'entry':
          entries.push(finish(entry))
          inEntry = false
          break
      }
    }
  }
  return entries
}

interface Building extends Omit<ArxivEntry, 'arxivID' | 'published'> { publishedRaw: string }

function blank(): Building {
  return { id: '', title: '', summary: '', authors: [], publishedRaw: '', categories: [] }
}

function finish(entry: Building): ArxivEntry {
  const { publishedRaw, ...rest } = entry
  return { ...rest, arxivID: lastPathComponent(entry.id), published: utcDay(publishedRaw) }
}

/** `URL(string:)?.lastPathComponent ?? id`. */
function lastPathComponent(id: string): string {
  let path: string
  try {
    path = new URL(id).pathname
  } catch {
    const slash = id.lastIndexOf('/')
    return slash >= 0 && slash < id.length - 1 ? id.slice(slash + 1) : id
  }
  const parts = decodeURIComponent(path).split('/').filter(Boolean)
  return parts.length > 0 ? parts[parts.length - 1] : '/'
}

/** The year, month and day of an ISO 8601 time, in UTC — the epoch when it
 *  does not read, as the Mac falls back to `Date(timeIntervalSince1970: 0)`. */
function utcDay(raw: string): number[] {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/.exec(raw)
  const date = match ? new Date(raw) : new Date(0)
  const time = Number.isNaN(date.getTime()) ? new Date(0) : date
  return [time.getUTCFullYear(), time.getUTCMonth() + 1, time.getUTCDate()]
}

/** `ArxivEntry.asCSLItem`. */
export function arxivCSL(entry: ArxivEntry): CSLItem {
  const item = emptyCSL()
  const set = (key: string, one: unknown) => { if (one !== undefined) item[key] = one }
  set('DOI', entry.doi)
  item.type = entry.doi === undefined && entry.journalRef === undefined ? 'manuscript' : 'article-journal'
  item.title = trimWhitespaceAndNewlines(entry.title.replace(/\p{White_Space}+/gu, ' '))
  set('abstract', entry.summary ? entry.summary : undefined)
  item.author = entry.authors.map(parseName)
  item.issued = { 'date-parts': [entry.published] }
  item.URL = entry.id
  set('container-title', entry.journalRef)
  item.note = entry.primaryCategory ? `arXiv:${entry.arxivID} [${entry.primaryCategory}]` : `arXiv:${entry.arxivID}`
  const v = entry.arxivID.lastIndexOf('v')
  const suffix = v >= 0 ? entry.arxivID.slice(v + 1) : ''
  if (suffix && /^\p{N}+$/u.test(suffix)) item.version = suffix
  return item
}
