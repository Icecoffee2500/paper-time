/**
 * What the palette is handed for a query: the Mac's `SemanticIndex.hits`
 * rule — at most `k` passages, at most three from any one paper, and a
 * passage the exact search already shows left out.
 *
 * Three per paper because a paper about the thing asked for has a dozen
 * passages that all score well, and eight rows from one paper is one answer
 * eight times. The exact hits come first in the palette, so a passage that
 * is already there by its words is not shown a second time by its meaning.
 */
import type { SemanticResult } from './semanticIndex.js'

export interface MeaningHit {
  passage: { paperID: string; pageIndex: number; location: number; length: number }
  /** The passage's words, at most 160 characters. */
  snippet: string
  score: number
}

/** "paperID#page" — the exact hits' places, as `pickResults` is told them. */
export function placeKey(place: { paperID: string; pageIndex: number }): string {
  return `${place.paperID}#${place.pageIndex}`
}

export function pickResults(
  found: readonly SemanticResult[],
  options: { k?: number; perPaper?: number; shown?: ReadonlySet<string> } = {},
): MeaningHit[] {
  const k = options.k ?? 8
  const perPaper = options.perPaper ?? 3
  const shown = options.shown ?? new Set<string>()
  const counts = new Map<string, number>()
  const seen = new Set<string>()
  const out: MeaningHit[] = []
  for (const hit of found) {
    if (out.length >= k) break
    const count = counts.get(hit.paperID) ?? 0
    if (count >= perPaper) continue
    if (shown.has(placeKey(hit))) continue
    // The same passage twice on one page — a running header — is one place.
    const at = `${placeKey(hit)}@${hit.location}`
    if (seen.has(at)) continue
    seen.add(at)
    counts.set(hit.paperID, count + 1)
    out.push({
      passage: { paperID: hit.paperID, pageIndex: hit.pageIndex, location: hit.location, length: hit.length },
      snippet: hit.text.split(/\s+/).filter(Boolean).join(' ').slice(0, 160),
      score: hit.score,
    })
  }
  return out
}
