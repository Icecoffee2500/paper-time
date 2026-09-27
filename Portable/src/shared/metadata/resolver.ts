/**
 * `MetadataResolver` and the four clients (MetadataPipeline): a PDF's
 * signals to a bibliographic record. The order is fixed by how far each step
 * can be trusted — an identifier printed on the paper, then the paper's own
 * title confirmed against a registrar, then its typography, and only then a
 * guess the reader is asked to confirm. Nothing below «confirmed» is stored
 * as fact.
 *
 * The network is handed in (`Network`), so the same resolver runs against
 * the registrars in the app and against recorded answers in the tests — the
 * Mac's recorded answers, with the Mac's conclusions to match.
 */

import type { CSLItem } from '../model.js'
import { arxivCSL, parseArxivFeed, type ArxivEntry } from './arxiv.js'
import { crossrefList, decodeCSL, emptyCSL, hasMinimumFields, Malformed, openAlexList, parseJSON } from './csl.js'
import { headerCandidates, mergeHeaders, sortingSurname, type ExtractedHeader, type ProvenanceSource } from './header.js'
import { arxivBaseID, arxivIDFromFileName, identifiers, normalizeArxiv, normalizeDOI, scanIdentifiers, type Identifiers } from './identifiers.js'
import { sanitized } from './sanitizer.js'
import type { DocumentSignals } from './signals.js'
import { assess, CANDIDATE_FLOOR, compareRank, score, type MatchAssessment } from './verifier.js'
import type { Confidence } from '../model.js'

// MARK: - Network

export type FailureKind = 'offline' | 'notFound' | 'rateLimited' | 'badStatus' | 'malformedResponse'

/** `NetworkService.Failure`. */
export class NetworkFailure extends Error {
  constructor(readonly kind: FailureKind, readonly status?: number, readonly retryAfter?: number) {
    super(describe(kind, status))
    this.name = 'NetworkFailure'
  }

  /** Whether the paper should stay queued and be tried again later. */
  get isTransient(): boolean {
    return this.kind === 'offline' || this.kind === 'rateLimited' || this.kind === 'badStatus'
  }
}

function describe(kind: FailureKind, status?: number): string {
  switch (kind) {
    case 'offline': return 'No internet connection.'
    case 'notFound': return 'The record was not found.'
    case 'rateLimited': return 'The service asked us to slow down.'
    case 'badStatus': return `The service returned status ${status}.`
    case 'malformedResponse': return 'The service returned something unreadable.'
  }
}

/** What the resolver asks of the network: a body, or a `NetworkFailure` (or
 *  any other error, which — like a URLError the Mac does not map — ends that
 *  one lookup without making it a reason to try again). */
export interface Network {
  get(url: string, accept: string): Promise<string>
}

// MARK: - URLs, as URLComponents spells them

/** What `URLComponents.queryItems` leaves as it is: letters, digits and
 *  `!$'()*+,-./:;?@_~`. Everything else, UTF-8 and percent-encoded. */
function encodeQueryPart(text: string): string {
  let out = ''
  for (const byte of new TextEncoder().encode(text)) {
    const character = String.fromCharCode(byte)
    out += byte < 0x80 && /[A-Za-z0-9!$'()*+,\-./:;?@_~]/.test(character)
      ? character
      : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`
  }
  return out
}

export function queryURL(base: string, items: [string, string][]): string {
  return `${base}?${items.map(([name, value]) => `${encodeQueryPart(name)}=${encodeQueryPart(value)}`).join('&')}`
}

/** `URL(string: "https://doi.org/\(doi)")`: what a path cannot hold,
 *  percent-encoded — a well-formed escape kept, a `#` starting a fragment. */
export function pathURL(base: string, path: string): string {
  let out = ''
  const bytes = new TextEncoder().encode(path)
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = bytes[index]
    const character = String.fromCharCode(byte)
    if (byte === 0x25) {
      const hex = String.fromCharCode(bytes[index + 1] ?? 0, bytes[index + 2] ?? 0)
      out += /^[0-9A-Fa-f]{2}$/.test(hex) ? '%' : '%25'
    } else if (byte < 0x80 && /[A-Za-z0-9\-._~!$&'()*+,;=:@/?#]/.test(character)) out += character
    else out += `%${byte.toString(16).toUpperCase().padStart(2, '0')}`
  }
  return base + out
}

// MARK: - Clients

const CROSSREF_SELECT = [
  'DOI', 'title', 'subtitle', 'author', 'issued', 'container-title', 'short-container-title', 'type', 'page',
  'volume', 'issue', 'publisher', 'ISSN', 'ISBN', 'URL', 'event',
].join(',')

async function json<T>(network: Network, url: string, read: (text: string) => T, accept = 'application/json'): Promise<T> {
  const text = await network.get(url, accept)
  try {
    return read(text)
  } catch (error) {
    if (error instanceof Malformed) throw new NetworkFailure('malformedResponse')
    throw error
  }
}

/** DOI content negotiation: the registrar's own CSL-JSON. */
export async function fetchDOI(network: Network, doi: string): Promise<CSLItem> {
  const normalised = normalizeDOI(doi)
  if (!normalised) throw new NetworkFailure('notFound')
  const item = await json(network, pathURL('https://doi.org/', normalised), (text) => decodeCSL(parseJSON(text)),
    'application/vnd.citationstyles.csl+json')
  item.DOI = normalised
  return item
}

export async function searchCrossref(network: Network, bibliographic: string, author?: string, rows = 5): Promise<CSLItem[]> {
  const items: [string, string][] = [['query.bibliographic', bibliographic], ['rows', String(rows)], ['select', CROSSREF_SELECT]]
  if (author) items.push(['query.author', author])
  return json(network, queryURL('https://api.crossref.org/works', items), crossrefList)
}

/** OpenAlex's filters treat commas, pipes and colons as separators. */
function openAlexTitle(title: string): string {
  return title.replaceAll(',', ' ').replaceAll('|', ' ').replaceAll(':', ' ').split(' ').filter(Boolean).join(' ')
}

export async function searchOpenAlex(network: Network, title: string, contactEmail?: string, rows = 5): Promise<CSLItem[]> {
  const items: [string, string][] = [['filter', `title.search:${openAlexTitle(title)}`], ['per-page', String(rows)]]
  if (contactEmail !== undefined) items.push(['mailto', contactEmail])
  return json(network, queryURL('https://api.openalex.org/works', items), openAlexList)
}

export async function arxivEntry(network: Network, id: string): Promise<ArxivEntry> {
  const normalised = normalizeArxiv(id)
  if (!normalised) throw new NetworkFailure('notFound')
  const text = await network.get(pathURL('https://export.arxiv.org/api/query?id_list=', normalised), 'application/atom+xml')
  const entries = parseArxivFeed(text)
  if (entries.length === 0) throw new NetworkFailure('notFound')
  return entries[0]
}

// MARK: - Resolution

export interface Provenance {
  source: ProvenanceSource
  detail?: string
}

export interface Candidate {
  csl: CSLItem
  identifiers: Identifiers
  provenance: Provenance
  score: number
  matchExplanation: string
}

export interface ResolutionResult {
  csl: CSLItem
  identifiers: Identifiers
  confidence: Confidence
  provenance: Provenance
  candidates: Candidate[]
  assessment?: MatchAssessment
  /** Set when the attempt failed for a reason that will pass. */
  transientFailure?: NetworkFailure
}

export interface ResolverOptions {
  contactEmail?: string
  /** Extra guesses at the header — the Mac's on-device model sits here. */
  extraHeaders?: (signals: DocumentSignals) => Promise<ExtractedHeader[]>
}

const attempt = async <T>(work: () => Promise<T>): Promise<T | undefined> => {
  try {
    return await work()
  } catch {
    return undefined
  }
}

function candidate(item: CSLItem, ids: Identifiers, source: ProvenanceSource, assessment: MatchAssessment): Candidate {
  return { csl: item, identifiers: ids, provenance: { source }, score: score(assessment), matchExplanation: assessment.explanation }
}

export async function resolve(network: Network, signals: DocumentSignals, originalFileName: string, options: ResolverOptions = {}): Promise<ResolutionResult> {
  const lists = [headerCandidates(signals)]
  if (options.extraHeaders) lists.unshift(await options.extraHeaders(signals))
  const headers = options.extraHeaders ? mergeHeaders(lists) : lists[0]
  const bestHeader = headers[0]

  const found = scanIdentifiers(signals.openingText)
  if (found.arxiv === undefined) {
    const fromName = arxivIDFromFileName(originalFileName)
    if (fromName !== undefined) found.arxiv = fromName
  }

  let fallback: ResolutionResult | undefined
  if (found.doi !== undefined) {
    const result = await resolveByDOI(network, found.doi, bestHeader)
    if (result?.confidence === 'verified') return finish(result)
    fallback = fallback ?? result
  }
  if (found.arxiv !== undefined) {
    const result = await resolveByArxiv(network, found.arxiv, bestHeader)
    if (result?.confidence === 'verified') return finish(result)
    fallback = fallback ?? result
  }
  const byTitle = await resolveByTitle(network, headers, signals, options.contactEmail)
  if (byTitle.confidence === 'verified') return finish(byTitle)
  if (!fallback) return finish(byTitle)
  return finish(hasMinimumFields(fallback.csl) && !hasMinimumFields(byTitle.csl) ? fallback : byTitle)
}

async function resolveByDOI(network: Network, doi: string, header: ExtractedHeader | undefined): Promise<ResolutionResult | undefined> {
  const item = await attempt(() => fetchDOI(network, doi))
  if (!item) return undefined
  const assessment = assess(item, header, true)
  const ids = identifiers({ doi })
  return {
    csl: item,
    identifiers: ids,
    confidence: assessment.verdict,
    provenance: { source: 'doiContentNegotiation', detail: 'doi.org content negotiation' },
    candidates: assessment.verdict === 'verified' ? [] : [candidate(item, ids, 'doiContentNegotiation', assessment)],
    assessment,
  }
}

async function resolveByArxiv(network: Network, arxivID: string, header: ExtractedHeader | undefined): Promise<ResolutionResult | undefined> {
  let item: CSLItem | undefined
  const ids = identifiers({ arxiv: arxivID })
  let source: ProvenanceSource = 'arxiv'
  let detail = `arXiv ${arxivID}`

  // arXiv mints a DataCite DOI for every submission, and doi.org does not
  // hold a paper to one request every three seconds.
  const base = arxivBaseID(identifiers({ arxiv: arxivID }).arxiv) ?? arxivID
  const preprintDOI = normalizeDOI(`10.48550/arXiv.${base}`)
  const fetched = preprintDOI ? await attempt(() => fetchDOI(network, preprintDOI)) : undefined
  if (preprintDOI && fetched) {
    if (fetched.type === 'document' || fetched.type === 'article-journal') fetched.type = 'manuscript'
    fetched.note = `arXiv:${arxivID}`
    if (typeof fetched['container-title'] === 'string' && fetched['container-title'].toLowerCase().includes('arxiv')) fetched['container-title'] = 'arXiv'
    if (typeof fetched.publisher === 'string' && fetched.publisher.toLowerCase().includes('arxiv')) fetched.publisher = 'arXiv'
    item = fetched
    ids.doi = preprintDOI
    source = 'doiContentNegotiation'
    detail = `arXiv DOI ${preprintDOI}`
  }
  if (!item) {
    const entry = await attempt(() => arxivEntry(network, arxivID))
    if (!entry) return undefined
    item = arxivCSL(entry)
    // A preprint later published cites the published version.
    const publishedDOI = entry.doi === undefined ? undefined : normalizeDOI(entry.doi)
    if (publishedDOI) {
      const published = await attempt(() => fetchDOI(network, publishedDOI))
      if (published) {
        item = published
        ids.doi = publishedDOI
        source = 'doiContentNegotiation'
      }
    }
  }
  const assessment = assess(item, header, true)
  return {
    csl: item,
    identifiers: ids,
    confidence: assessment.verdict,
    provenance: { source, detail },
    candidates: assessment.verdict === 'verified' ? [] : [candidate(item, ids, source, assessment)],
    assessment,
  }
}

interface Found {
  item: CSLItem
  identifiers: Identifiers
  source: ProvenanceSource
  header: ExtractedHeader
}

async function resolveByTitle(network: Network, headers: ExtractedHeader[], signals: DocumentSignals, contactEmail?: string): Promise<ResolutionResult> {
  const primary = headers[0]
  if (!primary) {
    return {
      csl: emptyCSL(),
      identifiers: {},
      confidence: 'unparsed',
      provenance: { source: 'heuristic', detail: signals.hasTextLayer ? 'no title could be identified' : 'no text layer; needs text recognition' },
      candidates: [],
    }
  }
  const pool: Found[] = []
  const transient = new Map<number, NetworkFailure>()
  const transientOf = (error: unknown) => error instanceof NetworkFailure && error.isTransient ? error : undefined

  // Only the two strongest guesses are searched: every extra query costs a
  // second of rate limit and adds noise to the ranking.
  for (const [index, header] of headers.slice(0, 2).entries()) {
    const authorHint = header.authors[0] ? sortingSurname(header.authors[0]) : undefined
    try {
      const matches = await searchCrossref(network, header.title, authorHint)
      pool.push(...matches.map((item) => ({ item, identifiers: identifiers({ doi: item.DOI }), source: 'crossref' as const, header })))
    } catch (error) {
      const failure = transientOf(error)
      if (failure) transient.set(index, failure)
    }
    try {
      const matches = await searchOpenAlex(network, header.title, contactEmail)
      pool.push(...matches.map((item) => ({
        item, identifiers: identifiers({ doi: item.DOI, pmid: typeof item.PMID === 'string' ? item.PMID : undefined }),
        source: 'openAlex' as const, header,
      })))
    } catch (error) {
      const failure = transientOf(error)
      if (failure && !transient.has(index)) transient.set(index, failure)
    }
    if (pool.some((one) => assess(one.item, one.header, false).verdict === 'verified')) break
  }

  const assessed = pool
    .map((found) => ({ found, assessment: assess(found.item, found.header, false) }))
    // Stable, best first — Swift's sort keeps equal ranks in the order found.
    .map((one, index) => ({ ...one, index }))
    .sort((a, b) => compareRank(b.assessment, a.assessment) || a.index - b.index)

  const best = assessed[0]
  if (best && best.assessment.verdict === 'verified') {
    return {
      csl: best.found.item,
      identifiers: best.found.identifiers,
      confidence: 'verified',
      provenance: { source: best.found.source, detail: 'title match' },
      candidates: [],
      assessment: best.assessment,
    }
  }
  const plausible = assessed.filter((one) => one.assessment.titleSimilarity >= CANDIDATE_FLOOR)
  const primaryFailure = transient.get(0)
  const detail = plausible.length === 0 && primaryFailure
    ? `could not reach the metadata services: ${primaryFailure.message}`
    : plausible.length === 0 ? 'no registrar match for the extracted title'
      : 'extracted from the document; a match needs confirming'
  const result: ResolutionResult = {
    csl: fallbackItem(primary),
    identifiers: {},
    confidence: 'needsReview',
    provenance: { source: primary.source, detail },
    candidates: plausible.slice(0, 4).map((one) => candidate(one.found.item, one.found.identifiers, one.found.source, one.assessment)),
  }
  if (plausible[0]) result.assessment = plausible[0].assessment
  if (plausible.length === 0 && primaryFailure) result.transientFailure = primaryFailure
  return result
}

/** Every record leaves cleaned, whichever path produced it. */
function finish(result: ResolutionResult): ResolutionResult {
  return { ...result, csl: sanitized(result.csl), candidates: result.candidates.map((one) => ({ ...one, csl: sanitized(one.csl) })) }
}

/** A usable record from what the document itself said. */
function fallbackItem(header: ExtractedHeader): CSLItem {
  const item = emptyCSL()
  item.title = header.title
  item.author = header.authors
  if (header.year !== undefined) item.issued = { 'date-parts': [[header.year]] }
  if (header.venueHint !== undefined) {
    item['container-title'] = header.venueHint
    const lowered = header.venueHint.toLowerCase()
    item.type = ['conference', 'proceedings', 'workshop', 'symposium'].some((word) => lowered.includes(word))
      ? 'paper-conference' : 'article-journal'
  } else item.type = 'document'
  return item
}
