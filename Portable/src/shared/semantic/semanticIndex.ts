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

/** Which note a page of text is, when it is one. */
export interface NoteOrigin {
  id: string
  /** The paper the note is about, or null for a note on its own. */
  paperID: string | null
  /** The note's title, or its first line when it has none. */
  title: string
}

export interface SemanticPage {
  /**
   * The paper's id — or, for a note, `note:<id>`: the manifest keys by
   * this, and a note is a paper of one page as far as the cut and the
   * cache are concerned. `note` says which note.
   */
  paperID: string
  pageIndex: number
  /** The page's text — for a note, its words with the Markdown taken out (`noteText.ts`). */
  text: string
  note?: NoteOrigin
}

export interface SemanticResult extends SemanticHit {
  paperID: string
  pageIndex: number
  /** UTF-16 offsets into the page's text. */
  location: number
  length: number
  text: string
  note?: NoteOrigin
}

export class SemanticIndex {
  /** Every passage of every page given, by key; several places may share one. */
  private places = new Map<ChunkKey, SemanticChunk[]>()
  /** The notes among the pages, by their `note:<id>` paperID. */
  private notes = new Map<string, NoteOrigin>()
  private dirty = false

  constructor(readonly store: SemanticVectorStore) {}

  /** Cuts the pages and remembers where every passage is. Returns the passages the cache lacks. */
  setPages(pages: readonly SemanticPage[]): SemanticChunk[] {
    this.places.clear()
    this.notes.clear()
    for (const page of pages) {
      if (page.note) this.notes.set(page.paperID, page.note)
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

  /** How many notes are among the pages, and how many passages they cut to. */
  get noteCounts(): { notes: number; passages: number } {
    let passages = 0
    for (const chunks of this.places.values()) {
      if (chunks.some((chunk) => this.notes.has(chunk.paperID))) passages += 1
    }
    return { notes: this.notes.size, passages }
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

  /** Every paper among the pages, with the keys its passages have. */
  keysByPaper(): Map<string, ChunkKey[]> {
    const out = new Map<string, ChunkKey[]>()
    for (const [key, chunks] of this.places) {
      for (const id of new Set(chunks.map((chunk) => chunk.paperID))) {
        const list = out.get(id)
        if (list) list.push(key)
        else out.set(id, [key])
      }
    }
    return out
  }

  /**
   * Drops vectors of passages no page has any more — except `alsoKeep`, the
   * keys of papers that are only away for a while (`manifest.ts`).
   */
  prune(alsoKeep?: ReadonlySet<ChunkKey>): void {
    const before = this.store.count
    const keep = new Set(this.places.keys())
    if (alsoKeep) for (const key of alsoKeep) keep.add(key)
    this.store.retain(keep)
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
        const note = this.notes.get(place.paperID)
        out.push({ ...hit, paperID: place.paperID, pageIndex: place.pageIndex,
          location: place.location, length: place.length, text: place.text, ...(note ? { note } : {}) })
      }
    }
    return out
  }
}
