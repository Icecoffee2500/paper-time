/**
 * Looking papers up, one after another — `LibraryModel.resolveMetadata` and
 * `resolveInBackground` on the Mac.
 *
 * One queue rather than one lookup per paper: sixty at once saturate the
 * registrars (which then rate-limit) and the window they report to. A paper
 * that arrives is read for its signals on the pdf.js thread (never the main
 * process's own), guessed at — paper, book, lecture or document — and, when it
 * is a paper, looked up. A document is not looked up at all: Crossref has
 * nothing to say about a lease, and sending its title out to ask is somebody's
 * business but ours.
 *
 * What comes back is written the Mac's way — the record's CSL, identifiers,
 * confidence, provenance and candidates, a citation key made from the answer
 * — through the same per-paper queue as every other write, against the
 * record the lookup started from, so a title corrected on another machine
 * while this one was asking is not written over (`PaperMeta.resolve`).
 * A record somebody edited by hand (`manual`) is never looked up again.
 *
 * Unlike the Mac, the guess is made even with lookups off: it is read off
 * the file on this machine and asks nobody anything.
 */

import { isoTimestamp, makeUUID } from '../../shared/coding.js'
import { isLookedUp } from '../../shared/documentKind.js'
import { makeKey } from '../../shared/citationKey.js'
import { PaperMeta } from '../../shared/model.js'
import { resolve, type Network, type ResolutionResult } from '../../shared/metadata/resolver.js'
import { guessFromSignals, type DocumentSignals } from '../../shared/metadata/signals.js'
import type { Library } from '../library.js'
import type { LibrarySet } from '../libraries.js'
import type { Records } from '../records.js'

export interface MetadataHooks {
  libraries: LibrarySet
  records: Records
  /** The paper's signals, read off its bytes (`PageCounter.signals`). */
  signals: (file: string) => Promise<DocumentSignals | null>
  /** The way out, or null when lookups may not leave this machine. */
  network: () => Network | null
  contactEmail: () => string | undefined
  /** Whether papers are looked up as they arrive. */
  onImport: () => boolean
  /** The papers being looked up now, whenever that changes (at most every quarter second). */
  resolving: (ids: string[]) => void
  /** A record changed: the windows read it again. */
  changed: (id: string) => void
  /** A line for the probe's log. */
  log?: (line: string) => void
}

export class MetadataQueue {
  private readonly waiting: string[] = []
  private readonly now = new Set<string>()
  private running: Promise<void> | null = null
  private told: ReturnType<typeof setTimeout> | null = null

  constructor(private readonly hooks: MetadataHooks) {}

  /** Papers that just arrived: guessed at, and looked up if that is on. */
  arrived(ids: string[]) {
    this.push(ids, this.hooks.onImport())
  }

  /** Guessed at only — a paper opened that nobody had guessed at. */
  guess(ids: string[]) {
    this.push(ids, false)
  }

  /** «Re-run Metadata» on these papers, or the lookup a document owes now
   *  that somebody said it is a paper. */
  rerun(ids: string[]) {
    this.push(ids, true)
  }

  /** «Resolve Missing Metadata»: every paper not yet confirmed. */
  async pending(): Promise<number> {
    const ids: string[] = []
    for (const library of this.hooks.libraries.all()) {
      for (const row of (await library.read()).papers) {
        const meta = new PaperMeta(row.meta)
        if (isLookedUp(meta.effectiveKind) && (meta.confidence === 'unparsed' || meta.confidence === 'needsReview')) ids.push(row.id)
      }
    }
    this.push(ids, true)
    return ids.length
  }

  get resolvingNow(): string[] {
    return [...this.now]
  }

  /** Everything queued, finished — for a probe that waits on the answers. */
  async drain(): Promise<void> {
    while (this.running) await this.running
  }

  private readonly lookup = new Map<string, boolean>()

  private push(ids: string[], lookUp: boolean) {
    for (const id of ids) {
      this.lookup.set(id, (this.lookup.get(id) ?? false) || lookUp)
      if (!this.waiting.includes(id) && !this.now.has(id)) this.waiting.push(id)
    }
    this.running ??= this.work().finally(() => { this.running = null })
  }

  private async work() {
    for (let id = this.waiting.shift(); id !== undefined; id = this.waiting.shift()) {
      const lookUp = this.lookup.get(id) ?? false
      this.lookup.delete(id)
      this.now.add(id)
      this.tell()
      try {
        await this.one(id, lookUp)
      } catch (error) {
        this.hooks.log?.(`metadata: ${id} failed: ${(error as Error)?.message ?? error}`)
      } finally {
        this.now.delete(id)
        this.tell()
      }
    }
  }

  /** The windows are told what is being looked up, gathered: a library
   *  resolving six hundred papers is not twelve hundred redraws. */
  private tell() {
    if (this.told) return
    this.told = setTimeout(() => {
      this.told = null
      this.hooks.resolving(this.resolvingNow)
    }, 250)
  }

  private async one(id: string, lookUp: boolean) {
    const owner = await this.hooks.libraries.ownerOf(id)
    const row = owner ? await owner.paper(id) : null
    if (!owner || !row?.file) return
    const meta = new PaperMeta(row.meta)
    if (meta.confidence === 'manual') return
    const signals = await this.hooks.signals(row.file)
    if (!signals) return
    const guess = guessFromSignals(signals)
    const guessed = meta.guessedKind === undefined
    if (guessed) meta.guessedKind = guess.kind
    const network = lookUp ? this.hooks.network() : null
    if (!isLookedUp(meta.effectiveKind) || !network) {
      if (guessed) await this.write(owner, id, meta, { stamp: false })
      this.hooks.log?.(`metadata: ${meta.file.originalName} → ${guess.kind} (${guess.reason})${network ? '' : ', not looked up'}`)
      return
    }
    const result = await resolve(network, signals, meta.file.originalName, { contactEmail: this.hooks.contactEmail() })
    apply(meta, result)
    await this.write(owner, id, meta, {})
    this.hooks.log?.(`metadata: ${meta.file.originalName} → ${result.confidence} (${result.provenance.source}${result.provenance.detail ? `, ${result.provenance.detail}` : ''})`)
  }

  private async write(owner: Library, id: string, meta: PaperMeta, options: { stamp?: boolean }) {
    await this.hooks.records.queue(id, async () => {
      // The record as it stands now, merged with what came back: somebody
      // may have tagged the paper while it was being looked up.
      const current = await owner.paper(id)
      if (!current) return
      const now = new PaperMeta(current.meta)
      if (now.confidence === 'manual') return
      now.guessedKind = now.guessedKind ?? meta.guessedKind
      if (options.stamp !== false) {
        now.csl = meta.csl
        now.bibKey = meta.bibKey
        now.confidence = meta.confidence
        now.raw = { ...now.raw, identifiers: meta.raw.identifiers, provenance: meta.raw.provenance, candidates: meta.raw.candidates }
      }
      await owner.saveMeta(now, { ...options, baseline: current.meta })
    })
    this.hooks.changed(id)
  }
}

/** A lookup's conclusion, written onto the record the Mac's way. */
export function apply(meta: PaperMeta, result: ResolutionResult, now = new Date()) {
  const fetchedAt = isoTimestamp(now)
  const provenance = (one: { source: string; detail?: string }) =>
    (one.detail === undefined ? { fetchedAt, source: one.source } : { detail: one.detail, fetchedAt, source: one.source })
  meta.csl = result.csl
  meta.confidence = result.confidence
  meta.raw = {
    ...meta.raw,
    identifiers: result.identifiers,
    provenance: provenance(result.provenance),
    candidates: result.candidates.map((one) => ({
      id: makeUUID(),
      csl: one.csl,
      identifiers: one.identifiers,
      provenance: provenance(one.provenance),
      score: one.score,
      matchExplanation: one.matchExplanation,
    })),
  }
  meta.bibKey = makeKey(result.csl, meta.file.originalName)
  meta.csl = { ...meta.csl, id: meta.bibKey }
}
