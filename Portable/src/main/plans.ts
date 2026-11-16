/**
 * The reading plans on disk: the plans themselves, the day each paper is to
 * be read, and what is kept beside a paper — the Mac's files, byte for byte
 * (`readingPlan.ts`, `encodeSwiftJSON`).
 *
 *   <library>/.papertime/plans/<id>.json
 *   <library>/.papertime/papers/<id>/plan.json
 *   <library>/.papertime/papers/<id>/links.json
 *
 * Every plan lives in one library folder and is written back there. Every
 * edit reads the file again first and applies the one change to what is on
 * disk, so two machines editing a plan through a cloud folder do not put
 * their whole copies over each other. One edit at a time per file.
 */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { shell } from 'electron'
import { probe } from './probeMode.js'
import { isInside, samePath } from '../shared/paths.js'
import { isoTimestamp, makeUUID } from '../shared/coding.js'
import {
  isDay, materialAddress, materialKindOfAddress, materialKindOfFile, newPlan, readLinks, readPlan,
  type PaperLink, type ReadingPlan,
} from '../shared/readingPlan.js'
import { acceptedEdit, applyPlanEdit } from '../shared/planEdit.js'
import * as L from './layout.js'
import { readJSON, writeJSON, type Library } from './library.js'
import { noteOwnWrite } from './ownWrites.js'

import type { PlanDTO } from '../shared/api.js'

/** Every plan in one library folder, in name order. A file that does not read is left alone. */
export async function readPlans(root: string): Promise<ReadingPlan[]> {
  let names: string[]
  try {
    names = await fsp.readdir(L.plansDir(root))
  } catch {
    return []
  }
  const plans = await Promise.all(names
    .filter((name) => name.endsWith('.json') && !name.startsWith('.'))
    .map(async (name) => readPlan(await readJSON(path.join(L.plansDir(root), name)).catch(() => null))))
  return plans.filter((plan): plan is ReadingPlan => plan !== null)
}

/** Plans from every folder, one per id — the first folder that has it wins. */
export async function readAllPlans(libraries: Library[]): Promise<PlanDTO[]> {
  const out: PlanDTO[] = []
  const seen = new Set<string>()
  for (const library of libraries) {
    for (const plan of await readPlans(library.root)) {
      const key = plan.id.toUpperCase()
      if (seen.has(key)) continue
      seen.add(key)
      out.push({ root: library.root, plan })
    }
  }
  return out.sort((a, b) => a.plan.createdAt < b.plan.createdAt ? -1 : a.plan.createdAt > b.plan.createdAt ? 1 : 0)
}

/** Writes or removes a file as ours, so the watcher does not answer it. */
async function remove(file: string) {
  noteOwnWrite(file)
  noteOwnWrite(path.dirname(file))
  await fsp.rm(file, { force: true })
}

export class PlanFiles {
  /** Which folder each plan was read from. */
  private readonly rootOf = new Map<string, string>()
  /** One write at a time per file. */
  private readonly queues = new Map<string, Promise<unknown>>()

  constructor(private readonly libraries: () => Library[]) {}

  private inLine<T>(key: string, work: () => Promise<T>): Promise<T> {
    const before = this.queues.get(key) ?? Promise.resolve()
    const next = before.then(work, work)
    this.queues.set(key, next.catch(() => undefined))
    return next
  }

  async load(): Promise<PlanDTO[]> {
    const plans = await readAllPlans(this.libraries())
    for (const one of plans) this.rootOf.set(one.plan.id, one.root)
    return plans
  }

  private async locate(id: string): Promise<string | null> {
    const known = this.rootOf.get(id)
    if (known && fs.existsSync(L.planPath(known, id))) return known
    await this.load()
    return this.rootOf.get(id) ?? null
  }

  /** A new plan in `root` (the folder being looked at) or the first folder. */
  async create(name: string, root: string | undefined, papers: string[]): Promise<PlanDTO | { error: string }> {
    const all = this.libraries()
    const library = (root ? all.find((one) => samePath(one.root, root)) : undefined) ?? all[0]
    if (!library) return { error: 'No library is open.' }
    const plan = newPlan(name.trim() || 'Plan')
    plan.entries = [...new Set(papers)].map((paper) => ({ paper }))
    await writeJSON(L.planPath(library.root, plan.id), plan)
    this.rootOf.set(plan.id, library.root)
    return { root: library.root, plan }
  }

  /** One change, made to the file as it is now. */
  edit(id: string, raw: unknown): Promise<PlanDTO | { error: string }> {
    const edit = acceptedEdit(raw)
    if (!edit) return Promise.resolve({ error: 'Not an edit.' })
    return this.inLine(`plan:${id}`, async () => {
      const root = await this.locate(id)
      if (!root) return { error: 'The plan is gone.' }
      const file = L.planPath(root, id)
      const plan = readPlan(await readJSON(file))
      if (!plan) return { error: 'The plan could not be read.' }
      applyPlanEdit(plan, edit)
      await writeJSON(file, plan)
      return { root, plan }
    })
  }

  /** To the trash, or gone when the desktop has none. */
  remove(id: string): Promise<boolean> {
    return this.inLine(`plan:${id}`, async () => {
      const root = await this.locate(id)
      if (!root) return false
      const file = L.planPath(root, id)
      noteOwnWrite(file)
      noteOwnWrite(path.dirname(file))
      // A probe's plans are its own scratch: gone outright, never into the
      // Trash of the person whose machine it runs on.
      if (probe.isRun) {
        await fsp.rm(file, { force: true })
      } else {
        try {
          await shell.trashItem(file)
        } catch {
          await fsp.rm(file, { force: true })
        }
      }
      this.rootOf.delete(id)
      return true
    })
  }
}

/** The days, set or cleared: `plan.json` written, or taken away. */
export async function setDays(owner: (id: string) => Promise<Library | null>, changes: { id: string; date: string | null }[]) {
  const written: { id: string; date: string | null }[] = []
  for (const change of changes) {
    if (typeof change?.id !== 'string' || (change.date !== null && !isDay(change.date))) continue
    const library = await owner(change.id)
    if (!library) continue
    const file = L.schedulePath(library.root, change.id)
    if (change.date) await writeJSON(file, { ...((await readJSON(file).catch(() => null)) ?? {}), date: change.date })
    else await remove(file)
    written.push({ id: change.id, date: change.date })
  }
  return written
}

/** What is kept beside a paper, read now. */
async function linksOf(library: Library, id: string): Promise<{ file: string; value: { links: PaperLink[]; [key: string]: unknown } }> {
  const file = L.linksPath(library.root, id)
  const value = readLinks(await readJSON(file).catch(() => null)) ?? { links: [] }
  return { file, value }
}

async function saveLinks(file: string, value: { links: PaperLink[] }) {
  if (value.links.length === 0) await remove(file)
  else await writeJSON(file, value)
}

export type LinkResult = { links: PaperLink[] } | { error: 'notAnAddress' | 'pdf' | 'missing' | 'failed' }

/**
 * Something put beside a paper: an address, or files copied in beside its
 * PDF. A PDF is refused — every PDF in a library folder is a paper of the
 * library, and one copied in as a material would be taken in as a paper of
 * its own; it is put under the paper as a supplement instead.
 */
export async function addLinks(library: Library, id: string, input: { url?: string; files?: string[] }): Promise<LinkResult> {
  const row = await library.paper(id)
  if (!row) return { error: 'missing' }
  const made: PaperLink[] = []
  const now = isoTimestamp(new Date())
  if (typeof input.url === 'string') {
    const address = materialAddress(input.url)
    if (!address) return { error: 'notAnAddress' }
    made.push({ id: makeUUID(), kind: materialKindOfAddress(address), url: address, addedAt: now })
  }
  if (Array.isArray(input.files)) {
    const files = input.files.filter((one) => typeof one === 'string' && path.isAbsolute(one))
    if (files.some((one) => /\.pdf$/i.test(one))) return { error: 'pdf' }
    // Beside the PDF, inside the library; at its top for a paper with no file.
    const beside = row.file && isInside(path.dirname(row.file), library.root) ? path.dirname(row.file) : library.root
    for (const source of files) {
      try {
        if (!(await fsp.stat(source)).isFile()) continue
        const name = L.availableFileName(path.basename(source), beside)
        const target = path.join(beside, name)
        noteOwnWrite(target)
        noteOwnWrite(beside)
        await fsp.copyFile(source, target, fs.constants.COPYFILE_EXCL)
        noteOwnWrite(target)
        made.push({ id: makeUUID(), kind: materialKindOfFile(name), file: L.recordPath(library.root, target), addedAt: now })
      } catch {
        return { error: 'failed' }
      }
    }
  }
  if (made.length === 0) return { links: (await linksOf(library, id)).value.links }
  const { file, value } = await linksOf(library, id)
  value.links = [...value.links, ...made]
  await saveLinks(file, value)
  return { links: value.links }
}

/** One material renamed (null: its own name again) or taken off. A copied file stays where it is. */
export async function editLink(library: Library, id: string, linkID: string, change: { title?: string | null; remove?: boolean }): Promise<PaperLink[]> {
  const { file, value } = await linksOf(library, id)
  if (change.remove) value.links = value.links.filter((link) => link.id !== linkID)
  else {
    value.links = value.links.map((link) => {
      if (link.id !== linkID) return link
      const next: PaperLink = { ...link }
      if (change.title && change.title.trim()) next.title = change.title.trim()
      else delete next.title
      return next
    })
  }
  await saveLinks(file, value)
  return value.links
}

/** Opens a material: an address in the browser, a file with the desktop's app for it. */
export async function openLink(library: Library, id: string, linkID: string): Promise<boolean> {
  const { value } = await linksOf(library, id)
  const link = value.links.find((one) => one.id === linkID)
  if (!link) return false
  if (link.url) {
    if (!/^https?:\/\//i.test(link.url)) return false
    await shell.openExternal(link.url)
    return true
  }
  if (link.file) {
    // A path read from a file that came through a cloud folder: never outside the library.
    const target = L.fileForRecordPath(library.root, link.file)
    if (!isInside(target, library.root)) return false
    return (await shell.openPath(target)) === ''
  }
  return false
}
