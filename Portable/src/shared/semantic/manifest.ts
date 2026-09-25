/**
 * Which papers the vector cache has seen, and when — so that a paper gone
 * for a while keeps its vectors, and a paper gone for good loses them.
 *
 * The store itself keys by passage text and knows nothing of papers, so on
 * its own it can only keep what the current pages cut to and drop the rest.
 * That is the wrong rule for a folder on a disk that is not plugged in, or a
 * cloud folder that is disconnected for a week: plugging it back in would
 * mean embedding it all again. This remembers, for every paper, the keys its
 * pages cut to and the last time it was among the pages given; a prune keeps
 * every key of every paper seen inside the grace, and forgets the others.
 *
 * Plain data, plain functions, no files — the worker reads and writes it
 * beside the store, and a test runs all of it.
 */
import type { ChunkKey } from './chunker.js'

export interface SeenPaper {
  /** Milliseconds since the epoch, the last time its pages were given. */
  seen: number
  keys: ChunkKey[]
}

export interface SeenManifest {
  version: 1
  papers: Record<string, SeenPaper>
}

export const GRACE_MS = 30 * 24 * 60 * 60 * 1000

export function emptyManifest(): SeenManifest {
  return { version: 1, papers: {} }
}

/** A manifest read from disk, or an empty one for anything that is not one. */
export function parseManifest(text: string): SeenManifest {
  try {
    const raw = JSON.parse(text) as Partial<SeenManifest>
    if (raw.version !== 1 || typeof raw.papers !== 'object' || raw.papers === null) return emptyManifest()
    const papers: Record<string, SeenPaper> = {}
    for (const [id, entry] of Object.entries(raw.papers)) {
      if (typeof entry?.seen !== 'number' || !Array.isArray(entry.keys)) continue
      papers[id] = { seen: entry.seen, keys: entry.keys.filter((key): key is ChunkKey => typeof key === 'string') }
    }
    return { version: 1, papers }
  } catch {
    return emptyManifest()
  }
}

/**
 * The manifest after these pages: every paper given is seen now with the keys
 * its pages cut to (replacing what it had — a page whose text changed has new
 * keys and the old ones are only kept through the grace of other papers).
 * Papers not given keep their entry until `retainedKeys` lets it go.
 */
export function noted(manifest: SeenManifest, keysByPaper: ReadonlyMap<string, ChunkKey[]>, now: number): SeenManifest {
  const papers = { ...manifest.papers }
  for (const [id, keys] of keysByPaper) papers[id] = { seen: now, keys: [...keys] }
  return { version: 1, papers }
}

/**
 * The keys a prune keeps, and the manifest with the papers past the grace
 * forgotten. A paper seen inside the grace keeps every key it had, whether
 * or not its pages are among the current ones.
 */
export function retained(manifest: SeenManifest, now: number, grace = GRACE_MS): { keep: Set<ChunkKey>; manifest: SeenManifest; forgotten: string[] } {
  const keep = new Set<ChunkKey>()
  const papers: Record<string, SeenPaper> = {}
  const forgotten: string[] = []
  for (const [id, entry] of Object.entries(manifest.papers)) {
    if (now - entry.seen > grace) {
      forgotten.push(id)
      continue
    }
    papers[id] = entry
    for (const key of entry.keys) keep.add(key)
  }
  return { keep, manifest: { version: 1, papers }, forgotten }
}
