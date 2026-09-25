/**
 * The window's side of the text index: ask for a search, take the answers as
 * they come, stop one nobody wants any more.
 *
 * The index lives in a process of its own (`main/textService.ts`), so the
 * palette and the list never wait on pdf.js — a search is a request, and its
 * answers arrive later as events, a batch at a time.
 */
import { call } from './bridge.js'
import { L } from '../shared/lang.js'
import type { TextHit } from '../main/textIndex.js'

export type { TextHit }

/** "Title · p. 9 · 3 matches" under a passage, in the palette and the list. */
export function passageSubtitle(hit: TextHit): string {
  const page = L(`${hit.passage.pageIndex + 1}쪽`, `p. ${hit.passage.pageIndex + 1}`)
  const more = hit.count > 1 ? L(` · ${hit.count}번`, ` · ${hit.count} matches`) : ''
  return `${hit.title} · ${page}${more}`
}

/** A passage, as a name a list row can be told apart by. */
export function passageKey(hit: TextHit): string {
  const { paperID, pageIndex, location, length } = hit.passage
  return `${paperID}#${pageIndex}@${location}+${length}`
}

interface Running {
  hits: (hits: TextHit[]) => void
  done: (summary: { searched: number; found: number; ms: number }) => void
}

const running = new Map<number, Running>()
let tokens = 0

/**
 * Reads the papers ahead of the first query, so it does not have to wait for
 * the library. The most recently opened first.
 */
export function warmText(papers: { id: string }[]) {
  void call('text:warm', { ids: papers.map((one) => one.id) })
}

/**
 * Searches the papers' text for a query, in the order the papers are given.
 * Returns the way to stop it; a search that is stopped says nothing more.
 */
export function searchText(
  query: string,
  papers: { id: string; title: string }[],
  options: {
    limit?: number
    hits: (hits: TextHit[]) => void
    done?: (summary: { searched: number; found: number; ms: number }) => void
  },
): () => void {
  const token = (tokens += 1)
  running.set(token, { hits: options.hits, done: options.done ?? (() => {}) })
  const titles: Record<string, string> = {}
  for (const paper of papers) titles[paper.id] = paper.title
  void call('text:search', { token, query, ids: papers.map((one) => one.id), titles, limit: options.limit })
  return () => {
    if (!running.delete(token)) return
    void call('text:cancel', { token })
  }
}

/**
 * For a probe: a whole search as one promise — every paper given, no limit —
 * timed from this side, so what is measured includes the trip to the index
 * and back. And the index's own account of itself.
 */
;(window as unknown as { __papertimeText: unknown }).__papertimeText = {
  search: (query: string, papers: { id: string; title: string }[], limit?: number) =>
    new Promise((resolve) => {
      const started = performance.now()
      let first: number | null = null
      const hits: TextHit[] = []
      searchText(query, papers, {
        limit,
        hits: (batch) => {
          if (first === null) first = performance.now() - started
          hits.push(...batch)
        },
        done: (summary) => resolve({
          query,
          papers: hits.length,
          matches: hits.reduce((sum, hit) => sum + hit.count, 0),
          firstMs: first,
          ms: performance.now() - started,
          serviceMs: summary.ms,
          searched: summary.searched,
          hits: hits.map((hit) => ({ id: hit.passage.paperID, page: hit.passage.pageIndex, count: hit.count, title: hit.title, snippet: hit.snippet })),
        }),
      })
    }),
  stats: () => call('text:stats'),
  warmed: null as unknown,
}

/** The events from the main process that belong to a search. */
export function handleTextEvent(event: string, payload: unknown): boolean {
  if (event === 'text:warmed') {
    ;(window as unknown as { __papertimeText: { warmed: unknown } }).__papertimeText.warmed = payload
    return true
  }
  if (event !== 'text:hits' && event !== 'text:done') return false
  const message = payload as { token: number; hits?: TextHit[]; searched?: number; found?: number; ms?: number }
  const search = running.get(message.token)
  if (!search) return true
  if (event === 'text:hits') {
    search.hits(message.hits ?? [])
  } else {
    running.delete(message.token)
    search.done({ searched: message.searched ?? 0, found: message.found ?? 0, ms: message.ms ?? 0 })
  }
  return true
}
