/**
 * A CSL record as the Mac reads one (`CSLItem.init(from:)`) and the three
 * registrars' answers mapped into it (`CrossrefDTO`, `OpenAlexDTO`). What
 * comes back from a registrar is written into `meta.json`, and the Mac's
 * decoder decides which fields survive — so the port keeps exactly those,
 * spelled the same, or the two builds would write the same paper two ways.
 *
 * Where the Swift decoder would throw, these throw (`Malformed`): a Crossref
 * page with one unreadable work is an unreadable page on the Mac too.
 */

import type { CSLDate, CSLItem, CSLName } from '../model.js'
import { cslFullTitle } from '../model.js'
import { firstYear, swiftInt } from './text.js'
import { trimWhitespace, trimWhitespaceAndNewlines } from '../zettel.js'
import { parseName } from '../model.js'

export class Malformed extends Error {
  constructor(what: string) {
    super(`malformed: ${what}`)
    this.name = 'Malformed'
  }
}

const CSL_TYPES = new Set([
  'article-journal', 'paper-conference', 'book', 'chapter', 'thesis', 'report', 'dataset', 'software',
  'webpage', 'patent', 'speech', 'manuscript', 'document',
])

type JSONValue = unknown
type Obj = Record<string, JSONValue>

const isObject = (value: JSONValue): value is Obj => typeof value === 'object' && value !== null && !Array.isArray(value)

/** `decodeIfPresent(String.self)`: absent or null is nothing, anything but a
 *  string throws. */
function strictString(object: Obj, key: string): string | undefined {
  const value = object[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string') throw new Malformed(key)
  return value
}

/** `decodeIfPresent(Int.self)`: a whole number, or it throws. */
function strictInt(value: JSONValue, key: string): number | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new Malformed(key)
  return value
}

function strictDouble(object: Obj, key: string): number | undefined {
  const value = object[key]
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number') throw new Malformed(key)
  return value
}

function strictStrings(object: Obj, key: string): string[] | undefined {
  const value = object[key]
  if (value === undefined || value === null) return undefined
  if (!Array.isArray(value) || value.some((one) => typeof one !== 'string')) throw new Malformed(key)
  return value as string[]
}

function strictObject(object: Obj, key: string): Obj | undefined {
  const value = object[key]
  if (value === undefined || value === null) return undefined
  if (!isObject(value)) throw new Malformed(key)
  return value
}

function strictArray(object: Obj, key: string): JSONValue[] | undefined {
  const value = object[key]
  if (value === undefined || value === null) return undefined
  if (!Array.isArray(value)) throw new Malformed(key)
  return value
}

/** `[[Int]]`. */
function dateParts(value: JSONValue, key: string): number[][] | undefined {
  if (value === undefined || value === null) return undefined
  if (!Array.isArray(value)) throw new Malformed(key)
  return value.map((row) => {
    if (!Array.isArray(row)) throw new Malformed(key)
    return row.map((one) => {
      const int = strictInt(one, key)
      if (int === undefined) throw new Malformed(key)
      return int
    })
  })
}

/** `CSLDate`'s synthesized decoder. */
export function decodeDate(value: JSONValue): CSLDate | undefined {
  if (value === undefined || value === null) return undefined
  if (!isObject(value)) throw new Malformed('date')
  const out: CSLDate = {}
  const parts = dateParts(value['date-parts'], 'date-parts')
  if (parts !== undefined) out['date-parts'] = parts
  const raw = strictString(value, 'raw')
  if (raw !== undefined) out.raw = raw
  const literal = strictString(value, 'literal')
  if (literal !== undefined) out.literal = literal
  return out
}

const NAME_KEYS = ['family', 'given', 'literal', 'suffix', 'dropping-particle', 'non-dropping-particle'] as const

/** `CSLName`'s synthesized decoder. */
function decodeName(value: JSONValue): CSLName {
  if (!isObject(value)) throw new Malformed('name')
  const out: CSLName = {}
  for (const key of NAME_KEYS) {
    const one = strictString(value, key)
    if (one !== undefined) out[key] = one
  }
  return out
}

/** `(try? decode([CSLName].self)) ?? []`: one bad name and the list is empty. */
function names(value: JSONValue): CSLName[] {
  if (!Array.isArray(value)) return []
  try {
    return value.map(decodeName)
  } catch {
    return []
  }
}

/** `decodeStringOrFirst`: a string, or the first of a list of strings. */
function stringOrFirst(object: Obj, key: string): string | undefined {
  const value = object[key]
  if (typeof value === 'string') return value
  if (Array.isArray(value) && value.every((one) => typeof one === 'string')) return value[0] as string | undefined
  return undefined
}

/** `decodeLooseString`: numbers where CSL wants strings. */
function looseString(object: Obj, key: string): string | undefined {
  const value = object[key]
  if (typeof value === 'string') return value
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value === Math.round(value) ? String(Math.trunc(value)) : swiftDouble(value)
  }
  return undefined
}

/** `String(Double)` for the numbers a registrar sends. */
function swiftDouble(value: number): string {
  const text = String(value)
  return /[.eE]/.test(text) ? text.replace(/e\+?/, 'e+').replace('e+-', 'e-') : `${text}.0`
}

/** The CSL fields the Mac keeps, in the order it declares them. */
const STRICT = ['title', 'subtitle', 'title-short', 'event-place', 'publisher', 'publisher-place', 'DOI', 'URL', 'abstract', 'note', 'language', 'genre'] as const
const FIRST = ['container-title', 'container-title-short', 'collection-title', 'event-title', 'ISSN', 'ISBN'] as const
const LOOSE = ['volume', 'issue', 'page', 'number-of-pages', 'number', 'edition', 'version', 'PMID'] as const

/** An empty record: `CSLItem()`. */
export function emptyCSL(): CSLItem {
  return { id: '', type: 'document', author: [], editor: [] }
}

/** `CSLItem.init(from:)` on a parsed JSON value. Throws where it throws. */
export function decodeCSL(value: JSONValue): CSLItem {
  if (!isObject(value)) throw new Malformed('item')
  const item: CSLItem = emptyCSL()
  item.id = typeof value.id === 'string' ? value.id : ''
  item.type = typeof value.type === 'string' && CSL_TYPES.has(value.type) ? value.type : 'document'
  const set = (key: string, one: unknown) => { if (one !== undefined) item[key] = one }
  set('title', strictString(value, 'title'))
  set('subtitle', strictString(value, 'subtitle'))
  set('title-short', strictString(value, 'title-short'))
  item.author = names(value.author)
  item.editor = names(value.editor)
  set('issued', decodeDate(value.issued))
  set('accessed', decodeDate(value.accessed))
  for (const key of FIRST) set(key, stringOrFirst(value, key))
  for (const key of STRICT) if (key !== 'title' && key !== 'subtitle' && key !== 'title-short') set(key, strictString(value, key))
  for (const key of LOOSE) set(key, looseString(value, key))
  return item
}

/** `CSLDate.year`. */
export function dateYear(date: CSLDate | undefined): number | undefined {
  if (!date) return undefined
  const first = date['date-parts']?.[0]?.[0]
  if (first !== undefined) return first
  for (const text of [date.raw, date.literal]) {
    if (text === undefined) continue
    const year = firstYear(text)
    if (year !== undefined) return year
  }
  return undefined
}

export const itemYear = (item: CSLItem): number | undefined => dateYear(item.issued)

/** `hasMinimumFields`: a title, an author and a year. */
export function hasMinimumFields(item: CSLItem): boolean {
  const title = item.title
  if (typeof title !== 'string' || !trimWhitespace(title)) return false
  return (item.author?.length ?? 0) > 0 && itemYear(item) !== undefined
}

export { cslFullTitle as fullTitle }

// MARK: - Crossref

/** `CSLType.fromCrossref`. */
export function cslTypeFromCrossref(raw: string): string {
  switch (raw) {
    case 'journal-article': return 'article-journal'
    case 'proceedings-article': return 'paper-conference'
    case 'book': case 'monograph': case 'edited-book': case 'reference-book': return 'book'
    case 'book-chapter': case 'book-section': case 'book-part': return 'chapter'
    case 'dissertation': return 'thesis'
    case 'report': case 'report-component': return 'report'
    case 'dataset': return 'dataset'
    case 'posted-content': return 'manuscript'
    default: return 'document'
  }
}

interface CrossrefAuthor { given?: string; family?: string; name?: string }

function crossrefAuthors(object: Obj, key: string): CrossrefAuthor[] | undefined {
  const list = strictArray(object, key)
  return list?.map((one) => {
    if (!isObject(one)) throw new Malformed(key)
    const author = { given: strictString(one, 'given'), family: strictString(one, 'family'), name: strictString(one, 'name') }
    strictString(one, 'sequence')
    strictString(one, 'ORCID')
    return author
  })
}

function crossrefName(author: CrossrefAuthor): CSLName {
  if (author.family === undefined && author.given === undefined && author.name) return { literal: author.name }
  const out: CSLName = {}
  if (author.family !== undefined) out.family = author.family
  if (author.given !== undefined) out.given = author.given
  return out
}

function crossrefDate(object: Obj, key: string): number[][] | undefined {
  const date = strictObject(object, key)
  return date ? dateParts(date['date-parts'], key) : undefined
}

/** Tags off a JATS abstract, and the five entities Crossref sends. */
function stripJATS(raw: string): string {
  let text = raw.replace(/<[^>]+>/g, '')
  for (const [entity, replacement] of [['&quot;', '"'], ['&lt;', '<'], ['&gt;', '>'], ['&#38;', '&'], ['&amp;', '&']]) {
    text = text.replaceAll(entity, replacement)
  }
  return trimWhitespaceAndNewlines(text)
}

/** One Crossref work, decoded the way `CrossrefWork` is and mapped as
 *  `asCSLItem` maps it. */
export function crossrefWork(value: JSONValue): CSLItem {
  if (!isObject(value)) throw new Malformed('work')
  const doi = strictString(value, 'DOI')
  const type = strictString(value, 'type')
  const title = strictStrings(value, 'title')
  const subtitle = strictStrings(value, 'subtitle')
  const container = strictStrings(value, 'container-title')
  const shortContainer = strictStrings(value, 'short-container-title')
  const author = crossrefAuthors(value, 'author')
  const editor = crossrefAuthors(value, 'editor')
  const dates = ['issued', 'published', 'published-print', 'published-online'].map((key) => crossrefDate(value, key))
  const page = strictString(value, 'page')
  const volume = strictString(value, 'volume')
  const issue = strictString(value, 'issue')
  const publisher = strictString(value, 'publisher')
  const publisherLocation = strictString(value, 'publisher-location')
  const issn = strictStrings(value, 'ISSN')
  const isbn = strictStrings(value, 'ISBN')
  const abstract = strictString(value, 'abstract')
  const url = strictString(value, 'URL')
  const event = strictObject(value, 'event')
  const eventName = event ? strictString(event, 'name') : undefined
  const eventLocation = event ? strictString(event, 'location') : undefined
  const articleNumber = strictString(value, 'article-number')
  const language = strictString(value, 'language')
  strictDouble(value, 'score')
  strictInt(value['is-referenced-by-count'], 'is-referenced-by-count')

  const item = emptyCSL()
  const set = (key: string, one: unknown) => { if (one !== undefined) item[key] = one }
  set('DOI', doi)
  item.type = cslTypeFromCrossref(type ?? '')
  set('title', title?.[0])
  set('subtitle', subtitle?.[0])
  set('container-title', container?.[0])
  set('container-title-short', shortContainer?.[0])
  item.author = (author ?? []).map(crossrefName)
  item.editor = (editor ?? []).map(crossrefName)
  const parts = dates.find((one) => one !== undefined && one.length > 0)
  if (parts) item.issued = { 'date-parts': parts }
  set('page', page)
  set('volume', volume)
  set('issue', issue)
  set('publisher', publisher)
  set('publisher-place', publisherLocation)
  set('ISSN', issn?.[0])
  set('ISBN', isbn?.[0])
  set('abstract', abstract === undefined ? undefined : stripJATS(abstract))
  set('URL', url)
  set('event-title', eventName)
  set('event-place', eventLocation)
  set('number', articleNumber)
  set('language', language)
  return item
}

/** `GET /works?query…`: `message` is `{items}`, or — with `select` — the
 *  works themselves. */
export function crossrefList(text: string): CSLItem[] {
  const root = parse(text)
  if (!isObject(root)) throw new Malformed('response')
  const message = root.message
  if (isObject(message)) {
    const items = strictArray(message, 'items')
    strictInt(message['total-results'], 'total-results')
    return (items ?? []).map(crossrefWork)
  }
  if (Array.isArray(message)) return message.map(crossrefWork)
  throw new Malformed('message')
}

/** `GET /works/{doi}`. */
export function crossrefSingle(text: string): CSLItem {
  const root = parse(text)
  if (!isObject(root)) throw new Malformed('response')
  return crossrefWork(root.message)
}

function parse(text: string): JSONValue {
  try {
    return JSON.parse(text)
  } catch {
    throw new Malformed('json')
  }
}

export { parse as parseJSON }

// MARK: - OpenAlex

function openAlexLocation(object: Obj, key: string): { source?: Obj; landing?: string } | undefined {
  const location = strictObject(object, key)
  if (!location) return undefined
  const source = strictObject(location, 'source')
  if (source) {
    strictString(source, 'display_name'); strictString(source, 'issn_l'); strictStrings(source, 'issn')
    strictString(source, 'publisher'); strictString(source, 'type')
  }
  const landing = strictString(location, 'landing_page_url')
  strictString(location, 'pdf_url')
  return { source, landing }
}

const OPENALEX_TYPES: Record<string, string> = {
  article: 'article-journal', preprint: 'manuscript', 'book-chapter': 'chapter', book: 'book',
  dissertation: 'thesis', dataset: 'dataset', report: 'report', 'proceedings-article': 'paper-conference',
}

/** One OpenAlex work, decoded as `OpenAlexWork` and mapped as `asCSLItem`. */
export function openAlexWork(value: JSONValue): CSLItem {
  if (!isObject(value)) throw new Malformed('work')
  strictString(value, 'id')
  const doi = strictString(value, 'doi')
  const title = strictString(value, 'title')
  const displayName = strictString(value, 'display_name')
  const year = strictInt(value.publication_year, 'publication_year')
  const date = strictString(value, 'publication_date')
  const type = strictString(value, 'type')
  const primary = openAlexLocation(value, 'primary_location')
  const authorships = strictArray(value, 'authorships')?.map((one) => {
    if (!isObject(one)) throw new Malformed('authorships')
    const author = strictObject(one, 'author')
    const name = author ? strictString(author, 'display_name') : undefined
    if (author) strictString(author, 'orcid')
    strictArray(one, 'institutions')?.forEach((institution) => {
      if (!isObject(institution)) throw new Malformed('institutions')
      strictString(institution, 'display_name')
    })
    strictString(one, 'author_position')
    return name
  })
  const biblio = strictObject(value, 'biblio')
  const volume = biblio ? strictString(biblio, 'volume') : undefined
  const issue = biblio ? strictString(biblio, 'issue') : undefined
  const firstPage = biblio ? strictString(biblio, 'first_page') : undefined
  const lastPage = biblio ? strictString(biblio, 'last_page') : undefined
  const language = strictString(value, 'language')
  const ids = strictObject(value, 'ids')
  const pmid = ids ? strictString(ids, 'pmid') : undefined
  if (ids) { strictString(ids, 'openalex'); strictString(ids, 'doi'); strictString(ids, 'mag') }
  const best = openAlexLocation(value, 'best_oa_location')

  const item = emptyCSL()
  const set = (key: string, one: unknown) => { if (one !== undefined) item[key] = one }
  set('DOI', doi === undefined ? undefined : doi.startsWith('https://doi.org/') ? doi.slice('https://doi.org/'.length) : doi)
  set('title', title ?? displayName)
  item.type = (type !== undefined && OPENALEX_TYPES[type]) || 'document'
  const source = primary?.source
  set('container-title', source ? strictString(source, 'display_name') : undefined)
  set('ISSN', source ? (strictString(source, 'issn_l') ?? strictStrings(source, 'issn')?.[0]) : undefined)
  set('publisher', source ? strictString(source, 'publisher') : undefined)
  set('URL', primary?.landing ?? best?.landing)
  item.author = (authorships ?? []).filter((name): name is string => name !== undefined).map(parseName)
  set('volume', volume)
  set('issue', issue)
  set('page', firstPage && lastPage ? `${firstPage}-${lastPage}` : firstPage)
  set('language', language)
  set('PMID', pmid === undefined ? undefined
    : pmid.startsWith('https://pubmed.ncbi.nlm.nih.gov/') ? pmid.slice('https://pubmed.ncbi.nlm.nih.gov/'.length) : pmid)
  if (date !== undefined) {
    // `split(separator: "-").compactMap { Int($0) }`: empty pieces dropped.
    const parts = date.split('-').filter(Boolean).map(swiftInt).filter((one): one is number => one !== undefined)
    if (parts.length > 0) item.issued = { 'date-parts': [parts] }
    else if (year !== undefined) item.issued = { 'date-parts': [[year]] }
  } else if (year !== undefined) item.issued = { 'date-parts': [[year]] }
  return item
}

/** `GET /works?filter=…`. */
export function openAlexList(text: string): CSLItem[] {
  const root = parse(text)
  if (!isObject(root)) throw new Malformed('response')
  const results = strictArray(root, 'results')
  const meta = strictObject(root, 'meta')
  if (meta) strictInt(meta.count, 'count')
  return (results ?? []).map(openAlexWork)
}
