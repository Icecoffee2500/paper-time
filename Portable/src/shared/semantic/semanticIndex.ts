/**
 * The passages of a library and their vectors, kept together.
 *
 * What a search needs is three things joined: the pages cut into passages
 * (so a hit can say where it is), a vector for each passage (the cache), and
 * a way to score a query against all of them. This joins them and knows
 * which passages the cache lacks, so that a page whose text has not changed
 * costs nothing on the second run.
 *
 * It owns no files and no model: the worker gives it a store it loaded and an
 * embedder it made, and asks it to save when it says it changed.
 */
import { chunksOfPage, type ChunkKey, type SemanticChunk } from './chunker.js'
import type { SemanticEmbedder } from './embedder.js'
import { SemanticVectorStore, type SemanticHit } from './vectorStore.js'

export interface SemanticPage {
  paperID: string
  pageIndex: number
  text: string
}

export interface SemanticResult extends SemanticHit {
  paperID: string
  pageIndex: number
  /** UTF-16 offsets into the page's text. */
  location: number
  length: number
  text: string
}

export class SemanticIndex {
  /** Every passage of every page given, by key; several places may share one. */
  private places = new Map<ChunkKey, SemanticChunk[]>()
  private dirty = false

  constructor(readonly store: SemanticVectorStore) {}

  /** Cuts the pages and remembers where every passage is. Returns the passages the cache lacks. */
  setPages(pages: readonly SemanticPage[]): SemanticChunk[] {
    this.places.clear()
    for (const page of pages) {
      for (const chunk of chunksOfPage(page.text, page.paperID, page.pageIndex)) {
        const list = this.places.get(chunk.key)
        if (list) list.push(chunk)
        else this.places.set(chunk.key, [chunk])
      }
    }
    return this.missing()
  }

  /** The passages that have no vector yet, one per key. */
  missing(): SemanticChunk[] {
    const out: SemanticChunk[] = []
    for (const [key, chunks] of this.places) if (!this.store.contains(key)) out.push(chunks[0])
    return out
  }

  get passageCount(): number {
    return this.places.size
  }

  /**
   * Embeds what is missing, a batch at a time, calling `onProgress` as
   * vectors arrive. Returns how many were embedded. Stops early at `signal`.
   */
  async fill(embedder: SemanticEmbedder, onProgress?: (done: number, total: number) => void, signal?: AbortSignal): Promise<number> {
    const missing = this.missing()
    let done = 0
    await embedder.embedChunks(missing, ({ key, vector }) => {
      this.store.insert(vector, key)
      this.dirty = true
      done += 1
      onProgress?.(done, missing.length)
    }, 16, signal)
    return done
  }

  /** Drops vectors of passages no page has any more. */
  prune(): void {
    const before = this.store.count
    this.store.retain(new Set(this.places.keys()))
    if (this.store.count !== before) this.dirty = true
  }

  /** Whether the store changed since `saved()` was last called. */
  get changed(): boolean {
    return this.dirty
  }

  saved(): void {
    this.dirty = false
  }

  /**
   * The best `k` places for a query vector. A key that several pages share
   * (a running header, a repeated abstract) answers with each place, so `k`
   * is a number of passages, and the places may be a few more.
   */
  search(query: ArrayLike<number>, k: number): SemanticResult[] {
    const out: SemanticResult[] = []
    for (const hit of this.store.search(query, k)) {
      for (const place of this.places.get(hit.key) ?? []) {
        out.push({ ...hit, paperID: place.paperID, pageIndex: place.pageIndex,
          location: place.location, length: place.length, text: place.text })
      }
    }
    return out
  }
}
