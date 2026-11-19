/**
 * Supplements under their papers — `LibraryModel.attachSupplements`,
 * `attach`, `detach` and `importSupplements` on the Mac.
 *
 * A conference hands out a paper and its supplement as two PDFs, and the
 * supplement arrived in the list as a paper of its own (2026-11-16:
 * «supplemental은 논문 목록에서 보이는게 아니라 본 논문의 "자료"에
 * 등록되어야지»). One whose paper is certain (`confidentParent`) goes under
 * it — after a batch's lookups finish, and a few seconds after the library
 * opens, for the ones already there — and is one of that paper's materials
 * from then on. A supplement a person took off its paper stays off: that
 * choice is this machine's (`SupplementChoices`), in the app's folder, and a
 * probe keeps it in memory only. A supplement is not a paper to read in a
 * plan's order, so attaching takes it out of every plan.
 */
import fs from 'node:fs'
import path from 'node:path'
import { confidentParent, looksLikeSupplement } from '../shared/attachmentSearch.js'
import { cslFullTitle, PaperMeta } from '../shared/model.js'
import type { Library, PaperRow } from './library.js'
import type { LibrarySet } from './libraries.js'
import type { PlanFiles } from './plans.js'
import type { Records } from './records.js'

/** The supplements a person took off their paper, by id. */
export class SupplementChoices {
  private memory = new Set<string>()

  /** `file` is null for a probe: it remembers nothing. */
  constructor(private readonly file: string | null) {}

  detached(): Set<string> {
    if (!this.file) return new Set(this.memory)
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file, 'utf8')) as unknown
      return new Set(Array.isArray(parsed) ? parsed.filter((one): one is string => typeof one === 'string') : [])
    } catch {
      return new Set()
    }
  }

  remember(id: string) {
    const now = this.detached()
    if (now.has(id)) return
    now.add(id)
    this.store(now)
  }

  forget(id: string) {
    const now = this.detached()
    if (!now.delete(id)) return
    this.store(now)
  }

  private store(ids: Set<string>) {
    if (!this.file) {
      this.memory = new Set(ids)
      return
    }
    try {
      const temporary = `${this.file}.${process.pid}.tmp`
      fs.mkdirSync(path.dirname(this.file), { recursive: true })
      fs.writeFileSync(temporary, JSON.stringify([...ids].sort()))
      fs.renameSync(temporary, this.file)
    } catch {
      // Only a note of what was taken off by hand; losing it may attach it again.
    }
  }
}

export interface SupplementHooks {
  libraries: LibrarySet
  records: Records
  plans: PlanFiles
  choices: SupplementChoices
  /** A record changed: the windows read it again. */
  changed: (id: string) => void
  /** The plans changed: every window reads them again. */
  plansChanged: () => void
  log?: (line: string) => void
}

export class Supplements {
  private running: Promise<number> | null = null
  private timer: ReturnType<typeof setTimeout> | null = null

  constructor(private readonly hooks: SupplementHooks) {}

  /** `attachSupplements`, a little later — a few seconds after a library opens. */
  attachSoon(delay = 4000) {
    if (this.timer) return
    this.timer = setTimeout(() => {
      this.timer = null
      void this.attachAll()
    }, delay)
  }

  /** Every supplement whose paper is certain, attached; how many. One pass at a time. */
  attachAll(): Promise<number> {
    if (this.running) return this.running
    this.running = this.pass().catch((error) => {
      this.hooks.log?.(`supplements: ${(error as Error)?.message ?? error}`)
      return 0
    }).finally(() => { this.running = null })
    return this.running
  }

  private async pass(): Promise<number> {
    const rows: { owner: Library; row: PaperRow; meta: PaperMeta }[] = []
    for (const owner of this.hooks.libraries.all()) {
      for (const row of (await owner.read()).papers) rows.push({ owner, row, meta: new PaperMeta(row.meta) })
    }
    const standing = rows.filter((one) => !one.meta.parentID)
    const candidates = standing
      .filter((one) => !looksLikeSupplement(one.meta.file.originalName, cslFullTitle(one.meta.csl)))
      .map((one) => ({ id: one.row.id, title: one.meta.displayTitle, fileName: one.meta.file.originalName }))
    const leftAlone = this.hooks.choices.detached()
    const parents = new Map(rows.map((one) => [one.row.id, one.meta.parentID]))
    const hasAttachments = (id: string) => [...parents.values()].some((parent) => parent === id)
    let attached = 0
    for (const one of standing) {
      if (leftAlone.has(one.row.id) || hasAttachments(one.row.id)) continue
      const parent = confidentParent(one.meta.file.originalName, cslFullTitle(one.meta.csl), candidates.filter((other) => other.id !== one.row.id))
      if (!parent || parents.get(parent)) continue
      if (await this.attach(one.row.id, parent)) {
        parents.set(one.row.id, parent)
        attached += 1
        this.hooks.log?.(`supplements: ${one.meta.file.originalName} → under ${parent}`)
      }
    }
    return attached
  }

  /** One paper under another, written: its `parentID`, out of every plan, no longer «left alone». */
  async attach(child: string, parent: string): Promise<boolean> {
    if (child === parent) return false
    const owner = await this.hooks.libraries.ownerOf(child)
    if (!owner) return false
    let done = false
    await this.hooks.records.queue(child, async () => {
      const current = await owner.paper(child)
      if (!current) return
      const meta = new PaperMeta(current.meta)
      if (meta.parentID === parent) return
      meta.parentID = parent
      await owner.saveMeta(meta, { baseline: current.meta })
      done = true
    })
    if (!done) return false
    this.hooks.changed(child)
    await this.attached([child])
    return true
  }

  /** What follows an attach made anywhere — the window's own too: out of
   *  the plans, and forgotten as «taken off by hand». */
  async attached(ids: string[]) {
    let plansChanged = false
    const plans = await this.hooks.plans.load()
    for (const id of ids) {
      this.hooks.choices.forget(id)
      for (const one of plans) {
        if (!one.plan.entries.some((entry) => entry.paper === id)) continue
        const done = await this.hooks.plans.edit(one.plan.id, { op: 'remove', papers: [id] })
        if (!('error' in done)) plansChanged = true
      }
    }
    if (plansChanged) this.hooks.plansChanged()
  }

  /** Taken off its paper by hand: not attached again on its own. */
  detached(id: string) {
    this.hooks.choices.remember(id)
  }
}
