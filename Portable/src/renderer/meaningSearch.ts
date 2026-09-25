/**
 * The window's side of search by meaning: ask, and know whether asking
 * would answer.
 *
 * The index lives in a process of its own (`main/semantic.ts` drives
 * `main/semanticWorker.ts`), so this is a request and its answer, and two
 * events — one as the index fills, one when it is ready — that the palette
 * draws its footer and its section from.
 */
import { call } from './bridge.js'
import { L } from '../shared/lang.js'
import type { MeaningHitDTO, SemanticStatusDTO } from '../shared/api.js'
import { store } from './state.js'
import type { TextHit } from './textSearch.js'

export type MeaningHit = MeaningHitDTO

let status: SemanticStatusDTO = { enabled: true, ready: false, passages: 0, progress: null }
let asked = false
const listeners = new Set<(status: SemanticStatusDTO) => void>()

/** What the main process last said; asked once, then kept by the events. */
export function meaningStatus(): SemanticStatusDTO {
  if (!asked) {
    asked = true
    void call<SemanticStatusDTO>('semantic:status').then(setStatus)
  }
  return status
}

function setStatus(next: SemanticStatusDTO) {
  status = next
  for (const listener of listeners) listener(next)
}

/** Told when the status changes; returns the way to stop being told. */
export function onMeaningStatus(listener: (status: SemanticStatusDTO) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/**
 * The passages nearest in meaning to the query — none at the places `shown`
 * (`"paperID#page"`) already has, none at all while the index is not built.
 */
export async function searchMeaning(query: string, shown: string[] = [], k = 8): Promise<{ hits: MeaningHit[]; ms: number; ready: boolean }> {
  const answer = await call<{ hits: MeaningHit[]; ms: number; ready: boolean }>('semantic:search', { query, k, shown })
  if (!answer.ready && status.ready) setStatus({ ...status, ready: false })
  return answer
}

/** A meaning hit as the reader takes it: the same shape as a text hit. */
export function asTextHit(hit: MeaningHit): TextHit {
  const paper = store.papers.find((one) => one.id === hit.passage.paperID)
  return { passage: hit.passage, title: paper?.meta.displayTitle ?? '', snippet: hit.snippet, count: 1 }
}

/** «뜻으로 찾기 준비 중 · 120/630» — the palette's footer while the index fills. */
export function meaningFooter(status: SemanticStatusDTO): string | null {
  if (!status.enabled || !status.progress) return null
  const { done, total } = status.progress
  return L(`뜻으로 찾기 준비 중 · ${done}/${total}`, `Getting ready to search by meaning · ${done}/${total}`)
}

/** The events from the main process that belong to search by meaning. */
export function handleMeaningEvent(event: string, payload: unknown): boolean {
  if (event !== 'semantic:progress' && event !== 'semantic:ready') return false
  asked = true
  setStatus(payload as SemanticStatusDTO)
  return true
}

/**
 * For a probe: the index as data — build it and wait, ask it, and read what
 * the main process says about it — with no key sent anywhere.
 */
;(window as unknown as { __papertimeMeaning: unknown }).__papertimeMeaning = {
  status: () => call('semantic:status'),
  build: () => call('semantic:build'),
  search: (query: string, k?: number) => searchMeaning(query, [], k),
  /** Resolves once the index says it is ready, or after `ms`. */
  whenReady: (ms = 120_000) => new Promise<SemanticStatusDTO>((resolve) => {
    const done = (next: SemanticStatusDTO) => {
      if (!next.ready) return false
      stop()
      resolve(next)
      return true
    }
    const stop = onMeaningStatus(done)
    const timer = setTimeout(() => { stop(); resolve(status) }, ms)
    void call<SemanticStatusDTO>('semantic:status').then((next) => { if (done(next)) clearTimeout(timer) })
  }),
}
