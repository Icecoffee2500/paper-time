/**
 * `NetworkService` (MetadataPipeline): the one way out to the registrars.
 *
 * All four services are free and unauthenticated, and all four ask for the
 * same courtesies — say who you are, stay under their pace, back off when
 * told. Every request goes through one of these so the promise holds when
 * several papers resolve at once. arXiv's pace is far stricter than the
 * rest: asked once a second, it answers «Rate exceeded» and every preprint
 * falls back to a title search.
 *
 * The request itself is handed in (`Send`), so the tests drive the same
 * pacing and retry against recorded answers with a clock that does not wait.
 */

import { NetworkFailure, type Network } from '../../shared/metadata/resolver.js'

export interface Reply {
  status: number
  body: string
  retryAfter?: string
}

/** One request. Throws `NetworkFailure('offline')` when there is no
 *  network, and anything else for a failure that is not a reason to retry. */
export type Send = (url: string, headers: Record<string, string>) => Promise<Reply>

export interface Clock {
  now(): number
  sleep(ms: number): Promise<void>
}

export const realClock: Clock = {
  now: () => Date.now(),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}

/** Seconds between two requests to one host. */
export function minimumInterval(host: string): number {
  if (host.includes('arxiv.org')) return 3.0
  if (host.includes('api.crossref.org')) return 1.0
  if (host.includes('api.openalex.org')) return 0.2
  if (host.includes('semanticscholar.org')) return 1.0
  return 0.5
}

/** `TimeInterval(String)`: a plain decimal number of seconds, or nothing
 *  (an HTTP date is not one). */
function seconds(text: string | undefined): number | undefined {
  if (text === undefined || !/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text)) return undefined
  return Number(text)
}

export class NetworkService implements Network {
  private nextAllowed = new Map<string, number>()
  private readonly userAgent: string

  constructor(private readonly send: Send, contactEmail?: string, private readonly clock: Clock = realClock) {
    // Crossref puts requests that name a contact into a faster pool.
    this.userAgent = `PaperTime/1.0${contactEmail ? ` (mailto:${contactEmail})` : ''}`
  }

  async get(url: string, accept: string): Promise<string> {
    const host = hostOf(url)
    await this.waitForTurn(host)
    return this.perform(url, { 'User-Agent': this.userAgent, Accept: accept }, host, true)
  }

  private async perform(url: string, headers: Record<string, string>, host: string, allowRetry: boolean): Promise<string> {
    const reply = await this.send(url, headers)
    if (reply.status >= 200 && reply.status <= 299) return reply.body
    if (reply.status === 404 || reply.status === 410) throw new NetworkFailure('notFound')
    if (reply.status === 429) {
      const retryAfter = seconds(reply.retryAfter)
      const pause = Math.min(retryAfter ?? 5, 20)
      // The server's own pacing, and one more chance before giving up.
      this.nextAllowed.set(host, this.clock.now() + pause * 1000)
      if (!allowRetry) throw new NetworkFailure('rateLimited', 429, retryAfter)
      await this.clock.sleep(pause * 1000)
      return this.perform(url, headers, host, false)
    }
    throw new NetworkFailure('badStatus', reply.status)
  }

  private async waitForTurn(host: string): Promise<void> {
    const now = this.clock.now()
    const next = this.nextAllowed.get(host)
    if (next !== undefined && next > now) await this.clock.sleep(next - now)
    this.nextAllowed.set(host, this.clock.now() + minimumInterval(host) * 1000)
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return ''
  }
}

/** The error codes that mean there is no network to speak of. The Mac hears
 *  «not connected» from the system; Node hears only that a name did not
 *  resolve or a route is missing, so those count as offline here — a paper
 *  looked up with the Wi-Fi off stays queued instead of being called
 *  unmatchable. */
const OFFLINE = new Set(['ENOTFOUND', 'EAI_AGAIN', 'ENETUNREACH', 'EHOSTUNREACH', 'ECONNRESET', 'ENETDOWN', 'ECONNREFUSED'])

/** `Send` over `fetch`, with the Mac's twenty-second timeout. */
export const fetchSend: Send = async (url, headers) => {
  let response: Response
  try {
    response = await fetch(url, { headers, redirect: 'follow', signal: AbortSignal.timeout(20_000) })
  } catch (error) {
    const code = (error as { cause?: { code?: string } }).cause?.code
    if (code && OFFLINE.has(code)) throw new NetworkFailure('offline')
    throw error
  }
  return { status: response.status, body: await response.text(), retryAfter: response.headers.get('retry-after') ?? undefined }
}
