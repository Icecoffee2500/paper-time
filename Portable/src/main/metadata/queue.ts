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
import { publishedRecord, resolve, type Network, type ResolutionResult } from '../../shared/metadata/resolver.js'
import type { Identifiers } from '../../shared/metadata/identifiers.js'
import type { PaperRow } from '../library.js'
import { guessFromSignals, type DocumentSignals } from '../../shared/metadata/signals.js'
import type { Library } from '../library.js'
import type { LibrarySet } from '../libraries.js'
import type { Records } from '../records.js'

export interface MetadataHooks {
  libraries: LibrarySet
  records: Records
  /** The paper's signals, read off its bytes (`PageCounter.signals`) —
   *  from its file, or from the address it came from. */
  signals: (row: PaperRow) => Promise<DocumentSignals | null>
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
  /** Everything queued is done — the supplements among what came in go to their papers. */
  idle?: () => void
  /** When each preprint was last asked about its published version — on
   *  this machine, in the app's own folder, not in the library (a probe's in
   *  memory only). Milliseconds since 1970, by paper id. */
  publishedChecks?: { load: () => Record<string, number>; save: (dates: Record<string, number>) => void }
}

/** Whether a record may be a preprint: arXiv's DOI, a manuscript, or no venue
 *  or arXiv's (`LibraryModel.mayBePreprint`). */
export function mayBePreprint(meta: PaperMeta): boolean {
  const ids = (meta.raw.identifiers ?? {}) as Identifiers
  const doi = ids.doi ?? (typeof meta.csl.DOI === 'string' ? meta.csl.DOI : undefined)
  if (doi !== undefined && doi.toLowerCase().startsWith('10.48550/arxiv.')) return true
  if (meta.csl.type === 'manuscript') return true
  const container = typeof meta.csl['container-title'] === 'string' ? meta.csl['container-title'].trim() : ''
  return container === '' || container.toLowerCase().includes('arxiv')
}

const FORTNIGHT = 14 * 86_400_000

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
   *  that somebody said it is a paper. A confirmed record keeps its citation
   *  key and gives way only to another confirmed one; a guess is simply
   *  looked up again (the Mac's `refreshing: confidence == .verified`). */
  rerun(ids: string[]) {
    for (const id of ids) if (this.refreshing.get(id) !== 'always') this.refreshing.set(id, 'ifVerified')
    this.push(ids, true)
  }

  /** «Refresh All Metadata»: every record the app found, found again with
   *  the engine as it is now — all but the ones a person wrote or chose and
   *  the supplements. Keys stay (a `.tex` file cites them); a confirmed
   *  record gives way only to another confirmed one. */
  async refreshAll(): Promise<number> {
    const ids: string[] = []
    for (const library of this.hooks.libraries.all()) {
      for (const row of (await library.read()).papers) {
        const meta = new PaperMeta(row.meta)
        if (isLookedUp(meta.effectiveKind) && meta.confidence !== 'manual' && !meta.parentID) ids.push(row.id)
      }
    }
    for (const id of ids) this.refreshing.set(id, 'always')
    this.push(ids, true)
    return ids.length
  }

  private readonly refreshing = new Map<string, 'ifVerified' | 'always'>()
  private publishedTimer: ReturnType<typeof setTimeout> | null = null
  private publishedRun: Promise<void> | null = null

  /**
   * The library's preprints, looked at again for where they were published
   * (`LibraryModel.checkPublishedVersions`): a paper is posted months before
   * it is accepted, so the record taken when it was added says «arXiv» long
   * after the paper has a venue. Each — a confirmed record of arXiv's, or
   * one with no venue — at most once a fortnight, a few seconds after the
   * library opens, one at a time. Nothing a person chose is touched, the
   * citation key stays, and a paper still unpublished is left as it was.
   */
  checkPublishedSoon(delay = 8000) {
    if (this.publishedTimer || this.publishedRun) return
    this.publishedTimer = setTimeout(() => {
      this.publishedTimer = null
      this.publishedRun = this.checkPublished().catch((error) => {
        this.hooks.log?.(`metadata: published check failed: ${(error as Error)?.message ?? error}`)
      }).finally(() => { this.publishedRun = null })
    }, delay)
  }

  /** The check that `checkPublishedSoon` starts, run now — a probe waits on it. */
  async checkPublished(): Promise<void> {
    if (!this.hooks.onImport()) return
    const network = this.hooks.network()
    if (!network) return
    const asked = this.hooks.publishedChecks?.load() ?? {}
    const now = Date.now()
    const due: { owner: Library; row: PaperRow }[] = []
    for (const library of this.hooks.libraries.all()) {
      for (const row of (await library.read()).papers) {
        const meta = new PaperMeta(row.meta)
        const last = asked[row.id]
        if (isLookedUp(meta.effectiveKind) && meta.confidence === 'verified' && !meta.parentID && mayBePreprint(meta)
          && (last === undefined || now - last > FORTNIGHT)) due.push({ owner: library, row })
      }
    }
    for (const { owner, row } of due) {
      await this.upgrade(network, owner, row)
      asked[row.id] = Date.now()
      this.hooks.publishedChecks?.save(asked)
    }
  }

  private async upgrade(network: Network, owner: Library, row: PaperRow) {
    const meta = new PaperMeta(row.meta)
    if (meta.confidence === 'manual') return
    // The first page, for the venue printed on it; a paper with no file
    // here is still asked by its identifier.
    const signals = row.file ? await this.hooks.signals(row) : null
    const firstPage = signals ? signals.firstPageLines.join('\n') : ''
    const ids = (meta.raw.identifiers ?? {}) as Identifiers
    const found = await publishedRecord(network, meta.csl, ids, firstPage)
    if (!found) return
    await this.hooks.records.queue(row.id, async () => {
      const current = await owner.paper(row.id)
      if (!current) return
      const latest = new PaperMeta(current.meta)
      if (latest.confidence === 'manual') return
      const fetchedAt = isoTimestamp(new Date())
      latest.csl = { ...found.csl, id: latest.bibKey }
      latest.raw = {
        ...latest.raw,
        identifiers: found.identifiers,
        provenance: found.provenance.detail === undefined
          ? { fetchedAt, source: found.provenance.source }
          : { detail: found.provenance.detail, fetchedAt, source: found.provenance.source },
      }
      await owner.saveMeta(latest, { baseline: current.meta })
    })
    this.hooks.changed(row.id)
    this.hooks.log?.(`metadata: ${meta.file.originalName} → published: ${found.csl['container-title'] ?? '—'} (${found.provenance.detail ?? found.provenance.source})`)
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
    this.running ??= this.work().finally(() => {
      this.running = null
      // With their titles read, the supplements among them go to their papers.
      this.hooks.idle?.()
    })
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
    const asked = this.refreshing.get(id)
    this.refreshing.delete(id)
    const owner = await this.hooks.libraries.ownerOf(id)
    const row = owner ? await owner.paper(id) : null
    if (!owner || !row?.file) return
    const meta = new PaperMeta(row.meta)
    if (meta.confidence === 'manual') return
    const signals = await this.hooks.signals(row)
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
    const refreshing = asked === 'always' || (asked === 'ifVerified' && meta.confidence === 'verified')
    // A lookup that failed — offline, rate-limited — must not turn a good
    // record into a guess.
    if (refreshing && meta.confidence === 'verified' && result.confidence !== 'verified') {
      this.hooks.log?.(`metadata: ${meta.file.originalName} → kept (the lookup said ${result.confidence})`)
      return
    }
    const key = meta.bibKey
    apply(meta, result)
    if (refreshing && key) {
      meta.bibKey = key
      meta.csl = { ...meta.csl, id: key }
    }
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
