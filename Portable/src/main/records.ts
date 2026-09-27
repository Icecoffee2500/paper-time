/**
 * Writing a paper's record — `meta.json` and `state.json` — one change at a
 * time per paper.
 *
 * Two patches to one paper used to race: each read the record, applied its
 * change and wrote, and the second write carried the first change away.
 * The star pressed while the rating was being saved, the status changed
 * twice quickly. Every write to a paper's record now waits for the one
 * before it, and the merge with what arrived from another machine happens
 * inside the wait.
 */
import { PaperMeta, PaperState } from '../shared/model.js'
import type { Library } from './library.js'

export type Patch = Record<string, unknown>

export class Records {
  private readonly chains = new Map<string, Promise<unknown>>()

  /** Runs `work` after everything queued for this paper. */
  queue<T>(id: string, work: () => Promise<T>): Promise<T> {
    const before = this.chains.get(id) ?? Promise.resolve()
    const next = before.then(work, work)
    this.chains.set(id, next)
    void next.finally(() => {
      if (this.chains.get(id) === next) this.chains.delete(id)
    })
    return next
  }

  /**
   * Reading state. `null` takes a field off — a rating taken back to none —
   * and the Mac's record has no key for a nil Optional, so none is written.
   * A patch crosses the bridge as JSON, so its dates arrive as strings.
   */
  state(owner: Library, id: string, patch: Patch): Promise<Record<string, unknown> | null> {
    return this.queue(id, async () => {
      const row = await owner.paper(id)
      if (!row) return null
      const state = new PaperState(row.state ?? {})
      const cleared = withoutNulls(patch)
      Object.assign(state, cleared, {
        lastOpenedAt: cleared.lastOpenedAt ? new Date(String(cleared.lastOpenedAt)) : state.lastOpenedAt,
      })
      const saved = await owner.saveState(id, state)
      return saved.encode()
    })
  }

  /**
   * The record. `stamp: false` writes without `updatedAt`/`updatedBy` — for
   * the app's own guess about a paper it only opened, which is not the
   * reader editing it and must not make this machine the last to have
   * changed it. A guess is written only where the record has neither an
   * answer nor a guess already: two windows guessing at once, or a Mac that
   * guessed first, are not overruled.
   */
  meta(owner: Library, id: string, patch: Patch, options: { stamp?: boolean } = {}): Promise<Record<string, unknown> | null> {
    return this.queue(id, async () => {
      const row = await owner.paper(id)
      if (!row) return null
      const meta = new PaperMeta(row.meta)
      const cleared = withoutNulls(acceptedMetaPatch(patch))
      if (options.stamp === false) {
        if ('guessedKind' in cleared && (meta.kind || meta.guessedKind)) return meta.encode()
      }
      // The fields this build carries raw — the lookup's candidates, the
      // identifiers, where the record came from — go into the record as it
      // is written; the typed ones onto the typed fields.
      for (const key of ['candidates', 'identifiers', 'provenance']) {
        if (!(key in cleared)) continue
        meta.raw = { ...meta.raw, [key]: cleared[key] }
        delete cleared[key]
      }
      Object.assign(meta, cleared)
      const written = await owner.saveMeta(meta, { ...options, baseline: row.meta })
      return written.encode()
    })
  }
}

const KINDS = ['paper', 'book', 'lecture', 'document']
const CONFIDENCES = ['unparsed', 'needsReview', 'verified', 'manual']

/**
 * The fields of a record the window may change, each of the kind it must be.
 * Anything else — the file's place and digest, the dates, the identity — is
 * the main process's to write, and a patch naming it is not a patch.
 */
export function acceptedMetaPatch(patch: Patch): Patch {
  const out: Patch = {}
  const strings = (value: unknown) => Array.isArray(value) && value.every((one) => typeof one === 'string')
  for (const [key, value] of Object.entries(patch ?? {})) {
    switch (key) {
      case 'csl':
        if (value && typeof value === 'object' && !Array.isArray(value)) out.csl = value
        break
      case 'bibKey':
        if (typeof value === 'string') out.bibKey = value
        break
      case 'confidence':
        if (typeof value === 'string' && CONFIDENCES.includes(value)) out.confidence = value
        break
      case 'kind':
      case 'guessedKind':
        if (value === null || (typeof value === 'string' && KINDS.includes(value))) out[key] = value
        break
      case 'tagIDs':
      case 'collectionIDs':
        if (strings(value)) out[key] = value
        break
      case 'parentID':
        if (value === null || typeof value === 'string') out.parentID = value
        break
      case 'candidates':
        if (Array.isArray(value)) out.candidates = value
        break
      case 'identifiers':
      case 'provenance':
        if (value && typeof value === 'object' && !Array.isArray(value)) out[key] = value
        break
    }
  }
  return out
}

/** `null` in a patch means «take it off»; JSON cannot carry `undefined`. */
export function withoutNulls(patch: Patch): Patch {
  return Object.fromEntries(Object.entries(patch).map(([key, value]) => [key, value === null ? undefined : value]))
}
