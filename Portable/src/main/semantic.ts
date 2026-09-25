/**
 * Search by meaning, as the main process runs it.
 *
 * Three things are joined here and nowhere else: the text service, which has
 * every paper's pages (read once, cached — `textService.ts`); the semantic
 * worker, which cuts them, embeds what its cache lacks and answers a query
 * (`semanticWorker.ts` through `semanticClient.ts`); and the window, which
 * asks and is told when the answers would be ready.
 *
 * The build is scheduled, never run at once: five seconds after the library
 * is read, two seconds after the text service says it has warmed, and after
 * a change to the library — as the Mac's `SemanticIndex.schedule` does it. A
 * build whose papers are the papers of the last finished build is skipped
 * before anything is sent. What is sent is the pages the text service already
 * holds; no PDF is opened for this.
 */
import path from 'node:path'
import { SemanticClient } from './semanticClient.js'
import type { SemanticPage } from '../shared/semantic/semanticIndex.js'
import { pickResults, type MeaningHit } from '../shared/semantic/results.js'
import type { TextSource } from './textIndex.js'

export interface SemanticStatus {
  enabled: boolean
  /** Whether a search would answer with anything. */
  ready: boolean
  passages: number
  /** Of a fill under way, or null. */
  progress: { done: number; total: number } | null
}

export interface SemanticHooks {
  /** The papers the text service may be asked about. */
  sources: () => TextSource[]
  /** The pages of these papers from the text service; `unread` are the ones it could not read. */
  texts: (ids: string[]) => Promise<{ papers: { id: string; pages: string[] }[]; unread: string[]; ms: number }>
  enabled: () => boolean
  /** To every window. */
  send: (event: string, payload?: unknown) => void
  /** A line on stderr, for a probe; nothing otherwise. */
  log: (line: string) => void
}

export class SemanticSearch {
  private client: SemanticClient
  private timer: NodeJS.Timeout | null = null
  private building: Promise<void> | null = null
  private filling: number | null = null
  private wanted = false
  private builtSignature = ''
  private passages = 0
  private progress: { done: number; total: number } | null = null
  /** Whether the worker has the current pages: ended workers forget them. */
  private ready = false
  /** Papers whose text the service could not read this time. */
  unread: string[] = []

  constructor(storeDirectory: string, private readonly hooks: SemanticHooks) {
    this.client = new SemanticClient(path.join(storeDirectory, 'vectors.ptsv'))
    this.client.onProgress = (_token, done, total) => {
      this.progress = { done, total }
      this.hooks.send('semantic:progress', this.status())
    }
  }

  /**
   * Ready means every passage has its vector: not while a fill is running.
   * A search in the middle of one would answer from half the library and
   * look like the whole; the footer says what is happening instead.
   */
  status(): SemanticStatus {
    return {
      enabled: this.hooks.enabled(),
      ready: this.hooks.enabled() && this.ready && this.progress === null && this.passages > 0,
      passages: this.passages,
      progress: this.progress,
    }
  }

  /** A build `afterMs` from now, replacing one already waiting. */
  schedule(afterMs: number) {
    if (!this.hooks.enabled()) return
    this.stopped = false
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = null
      void this.build()
    }, afterMs)
  }

  /**
   * Cuts, embeds what is missing, saves. One at a time: a second call while
   * one runs is remembered and run after it, once.
   */
  build(): Promise<void> {
    if (!this.hooks.enabled()) return Promise.resolve()
    if (this.building) {
      this.wanted = true
      return this.building
    }
    this.building = this.run().catch((error: unknown) => {
      // A worker ended on purpose — the switch, or the app quitting — is
      // not a failure worth a line.
      if (!this.ending && !this.stopped) this.hooks.log(`semantic: build failed — ${String((error as Error).message ?? error)}`)
    }).finally(() => {
      this.building = null
      if (this.wanted) {
        this.wanted = false
        this.schedule(1000)
      }
    })
    return this.building
  }

  private async run() {
    const sources = this.hooks.sources()
    const signature = sources.map((one) => `${one.id}\u0000${one.file}`).sort().join('\n')
    if (signature === this.builtSignature && this.ready && this.client.hasPages) {
      this.hooks.log(`semantic: ${sources.length} papers unchanged — nothing to do`)
      return
    }
    const t0 = performance.now()
    const texts = await this.hooks.texts(sources.map((one) => one.id))
    this.unread = texts.unread
    if (!this.hooks.enabled()) return
    const pages: SemanticPage[] = []
    for (const paper of texts.papers) {
      paper.pages.forEach((text, pageIndex) => {
        if (text.trim().length > 0) pages.push({ paperID: paper.id, pageIndex, text })
      })
    }
    const t1 = performance.now()
    const cut = await this.client.setPages(pages)
    this.passages = cut.passages
    this.hooks.log(`semantic: ${texts.papers.length} papers, ${pages.length} pages from the text service in ${Math.round(texts.ms)} ms (${texts.unread.length} unread) · ${cut.passages} passages, ${cut.missing} to embed · cut in ${Math.round(performance.now() - t1)} ms`)
    if (cut.missing > 0) {
      const { token, done } = this.client.fill()
      this.filling = token
      this.progress = { done: 0, total: cut.missing }
      this.hooks.send('semantic:progress', this.status())
      try {
        const filled = await done
        this.hooks.log(`semantic: embedded ${filled.embedded} passages in ${Math.round(filled.ms)} ms (${(filled.ms / Math.max(filled.embedded, 1)).toFixed(1)} ms each)`)
      } finally {
        this.filling = null
        this.progress = null
      }
    } else {
      const swept = await this.client.sweep()
      if (swept.forgotten > 0 || swept.dropped > 0) this.hooks.log(`semantic: forgot ${swept.forgotten} papers, dropped ${swept.dropped} vectors`)
    }
    this.builtSignature = signature
    this.ready = true
    this.hooks.log(`semantic: ready — ${this.passages} passages · ${Math.round(performance.now() - t0)} ms`)
    this.hooks.send('semantic:ready', this.status())
  }

  /**
   * The best passages for a query — at most `k`, at most three from one
   * paper, none at a place `shown` (the exact search's) already has.
   */
  async search(query: string, k = 8, shown: string[] = []): Promise<{ hits: MeaningHit[]; ms: number; ready: boolean }> {
    const text = query.trim()
    const status = this.status()
    if (!status.ready || text.length <= 2) return { hits: [], ms: 0, ready: status.ready }
    // A worker that ended after ten idle minutes has forgotten the pages;
    // the cache on disk has every vector, so giving them back is a read of
    // the text cache, not a rebuild.
    if (!this.client.hasPages) await this.build()
    if (!this.client.hasPages) return { hits: [], ms: 0, ready: false }
    try {
      const { hits, ms } = await this.client.search(text, k * 4)
      return { hits: pickResults(hits, { k, perPaper: 3, shown: new Set(shown) }), ms, ready: true }
    } catch {
      // The worker ended under the question (the switch, or quitting): no
      // answer, and nothing for the window to show.
      return { hits: [], ms: 0, ready: false }
    }
  }

  /** The switch went off: stop what is running and let the worker go. */
  stop() {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    if (this.filling !== null) this.client.cancel(this.filling)
    this.client.end()
    this.ready = false
    this.progress = null
    this.builtSignature = ''
    this.hooks.send('semantic:ready', this.status())
  }

  /** The worker's own account, for a probe. */
  stats() {
    return this.client.stats()
  }

  /** Resolves once a build has finished — for a probe that types next. */
  whenBuilt(): Promise<void> {
    return this.building ?? Promise.resolve()
  }

  private ending = false
  /** The switch went off: a build cut short by that is not a failure. */
  private stopped = false

  end() {
    this.ending = true
    if (this.timer) clearTimeout(this.timer)
    this.client.end()
  }
}
