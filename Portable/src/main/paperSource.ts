/**
 * Papers that come from an address rather than a file.
 *
 * `source.json` beside a record (the Mac's `PaperSource`) says where its PDF
 * came from. A paper whose PDF is not in the folder but has one of these is
 * opened from the address — on a computer that keeps no PDF files (a company
 * machine whose security agent swallows them; «Keep PDFs out of files» in
 * Settings), and on one that merely has not got the file yet. The bytes are
 * held in memory for the session (`FetchedPapers`) and fetched again next
 * time; marks, ink, sketches and notes live in `.papertime` as always.
 *
 * Fetching goes through Chromium (`net.fetch`), not Node: a company network
 * has a proxy and a certificate of its own, and Chromium takes both from the
 * desktop where Node's `fetch` sees neither.
 */
import { net } from 'electron'
import { isoTimestamp } from '../shared/coding.js'
import {
  addressLookup, addressPDF, addressText, openAccessPDFs, publisherPDFs, readPaperAddress, type PaperAddress,
} from '../shared/paperAddress.js'
import { looksLikePDF } from '../shared/pdfLock.js'

export interface PaperSource {
  /** What was typed, as the Mac's `PaperAddress.text` writes it. */
  address: string
  /** Where the PDF was fetched from — the address that answered with bytes. */
  pdf: string
  fetchedAt: string
}

export function makeSource(address: PaperAddress, pdf: string): PaperSource {
  return { address: addressText(address), pdf, fetchedAt: isoTimestamp(new Date()) }
}

import type { FetchFailure } from '../shared/api.js'
export type { FetchFailure }

export class FetchError extends Error {
  constructor(readonly why: FetchFailure, detail?: string) {
    super(detail ?? why)
  }
}

/** The most a paper may be: a scanned book is a few hundred megabytes, and
 *  anything past this is not a paper. */
export const MOST_BYTES = 400 * 1024 * 1024

export interface Fetched {
  bytes: Buffer
  /** The address the bytes came from, after redirects. */
  pdf: string
}

/** One request, through Chromium. `rewrite` is the probe's: every address
 *  sent somewhere of its own. */
export type Fetch = (url: string, accept: string) => Promise<{ status: number; url: string; body: Buffer; type: string }>

export const chromiumFetch: Fetch = async (url, accept) => {
  const response = await net.fetch(url, {
    headers: { Accept: accept, 'User-Agent': 'PaperTime/1.0' },
    redirect: 'follow',
    signal: AbortSignal.timeout(90_000),
  })
  const body = Buffer.from(await response.arrayBuffer())
  return { status: response.status, url: response.url || url, body, type: response.headers.get('content-type') ?? '' }
}

function offline(error: unknown): boolean {
  const text = String((error as { message?: string })?.message ?? error)
  return /ERR_INTERNET_DISCONNECTED|ERR_NAME_NOT_RESOLVED|ERR_NETWORK_CHANGED|ERR_ADDRESS_UNREACHABLE|ERR_CONNECTION_(REFUSED|RESET|TIMED_OUT)|ENOTFOUND|EAI_AGAIN|ENETUNREACH/i.test(text)
}

/** The PDF at an address, or why not. HTML in its place is `noPDF`: a
 *  publisher's page, a login wall, a company's stub. */
export async function fetchPDF(url: string, fetch: Fetch = chromiumFetch): Promise<Fetched> {
  let reply: Awaited<ReturnType<Fetch>>
  try {
    reply = await fetch(url, 'application/pdf,*/*;q=0.8')
  } catch (error) {
    throw new FetchError(offline(error) ? 'offline' : 'failed', String(error))
  }
  if (reply.status === 404 || reply.status === 410) throw new FetchError('notFound', `HTTP ${reply.status}`)
  if (reply.status < 200 || reply.status > 299) throw new FetchError('failed', `HTTP ${reply.status}`)
  if (reply.body.length > MOST_BYTES) throw new FetchError('tooLarge')
  if (!looksLikePDF(new Uint8Array(reply.body))) throw new FetchError('noPDF', `not a PDF (${reply.type || 'no type'})`)
  return { bytes: reply.body, pdf: reply.url }
}

/**
 * The paper an address names. An arXiv address and a plain one are fetched
 * as they are; a DOI is asked about at OpenAlex, and each open-access copy
 * it knows of is tried in turn until one answers with a PDF — then the
 * publisher's own file, guessed from the DOI's prefix, which a subscribed
 * network gets. When OpenAlex itself cannot be asked (a company proxy turns
 * it away) the guesses are still tried, and the lookup's failure is what is
 * reported if none answers. The Mac's `PaperFetcher.fetch`.
 */
export async function fetchByAddress(text: string, fetch: Fetch = chromiumFetch): Promise<{ address: PaperAddress; fetched: Fetched }> {
  const address = readPaperAddress(text)
  if (!address) throw new FetchError('notAnAddress')
  const direct = addressPDF(address)
  if (direct) return { address, fetched: await fetchPDF(direct, fetch) }
  const lookup = addressLookup(address)
  if (!lookup || address.kind !== 'doi') throw new FetchError('noPDF')
  let answer = ''
  let lookupFailure: FetchError | null = null
  try {
    const reply = await fetch(lookup, 'application/json')
    if (reply.status === 404) lookupFailure = new FetchError('notFound', `OpenAlex HTTP ${reply.status}`)
    else if (reply.status >= 200 && reply.status <= 299) answer = reply.body.toString('utf8')
    else lookupFailure = new FetchError('failed', `OpenAlex HTTP ${reply.status}`)
  } catch (error) {
    if (offline(error)) throw new FetchError('offline', String(error))
    lookupFailure = new FetchError('failed', `OpenAlex: ${String(error)}`)
  }
  // An open copy that answered with an error is worth reporting; a
  // publisher's guess that did is not — most of them are 403s.
  let last: FetchError = lookupFailure ?? new FetchError('noPDF')
  for (const candidate of openAccessPDFs(answer)) {
    try {
      return { address, fetched: await fetchPDF(candidate, fetch) }
    } catch (error) {
      if (!(error instanceof FetchError)) throw error
      if (error.why === 'offline') throw error
      last = error
    }
  }
  for (const guess of publisherPDFs(address.doi, answer)) {
    try {
      return { address, fetched: await fetchPDF(guess, fetch) }
    } catch (error) {
      if (!(error instanceof FetchError)) throw error
      if (error.why === 'offline') throw error
    }
  }
  // A DOI OpenAlex does not know, or whose copies have gone, is a paper
  // without an open PDF — not an address with nothing at it.
  if (last.why === 'notFound') throw new FetchError('noPDF', last.message)
  throw last
}

/**
 * The bytes of papers that have no file, for the session. Bounded: the
 * oldest go when the lot would pass `MOST_HELD`, and are fetched again when
 * next opened.
 */
export class FetchedPapers {
  private held = new Map<string, Buffer>()
  private size = 0
  static readonly MOST_HELD = 600 * 1024 * 1024
  /** Fetches under way, so two readers of one paper make one request. */
  private pending = new Map<string, Promise<Buffer>>()

  get(id: string): Buffer | undefined {
    const bytes = this.held.get(id)
    if (bytes) {
      // Most recently used last.
      this.held.delete(id)
      this.held.set(id, bytes)
    }
    return bytes
  }

  put(id: string, bytes: Buffer) {
    this.forget(id)
    this.held.set(id, bytes)
    this.size += bytes.length
    for (const [oldest, old] of this.held) {
      if (this.size <= FetchedPapers.MOST_HELD || oldest === id) break
      this.held.delete(oldest)
      this.size -= old.length
    }
  }

  forget(id: string) {
    const old = this.held.get(id)
    if (old) {
      this.held.delete(id)
      this.size -= old.length
    }
  }

  /** The bytes, from memory or from the source — one fetch however many ask. */
  async bytes(id: string, source: PaperSource, fetch: Fetch = chromiumFetch): Promise<Buffer> {
    const held = this.get(id)
    if (held) return held
    let under = this.pending.get(id)
    if (!under) {
      under = fetchPDF(source.pdf, fetch).then((fetched) => {
        this.put(id, fetched.bytes)
        return fetched.bytes
      }).finally(() => this.pending.delete(id))
      this.pending.set(id, under)
    }
    return under
  }

  stats() {
    return { papers: this.held.size, bytes: this.size }
  }
}

/**
 * A paper's bytes: its file when it has one, else its source. Every reader
 * of a PDF in the main process goes through here, so a paper from an address
 * is read everywhere a file is — the page, the drawings in it, the text
 * index, the lookup's signals.
 */
export async function bytesOf(
  row: { id: string; file: string | null; exists: boolean; source?: PaperSource },
  held: FetchedPapers, readFile: (file: string) => Promise<Buffer | Uint8Array>, fetch: Fetch = chromiumFetch,
): Promise<Buffer> {
  if (row.file && row.exists) {
    const read = await readFile(row.file)
    return Buffer.isBuffer(read) ? read : Buffer.from(read.buffer, read.byteOffset, read.byteLength)
  }
  if (row.source) return held.bytes(row.id, row.source, fetch)
  throw new FetchError('notFound', 'The PDF for this paper is not in the folder.')
}
