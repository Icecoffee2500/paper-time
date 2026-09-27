/**
 * The marks journals: this device's, held and written; the others', read.
 *
 * The journal is the fast path between machines. The PDF is the durable
 * record and is rewritten a second or so later, but a small file naming what
 * this device just did lands in the synced folder at once. It is also where a
 * mark stays when the PDF cannot take it. The Mac writes the same shape
 * (`.papertime/papers/<id>/marks/<device>.json`) and reconciles from it.
 *
 * This device's journal is held, not re-read, because it is the one journal
 * nobody else writes, and because a save must not depend on the file coming
 * back: `loaded` is false when the copy on disk would not be read — still
 * arriving down a cloud drive, or damaged — and a journal that was not read
 * is never written over. What is recorded meanwhile is kept here, merged in
 * once it can be read.
 */
import fsp from 'node:fs/promises'
import path from 'node:path'
import {
  freshJournal,
  recordChanges,
  type Held,
  type Journal,
} from '../shared/markJournal.js'
import type { MarkupRecord } from './pdfwrite.js'
import { deviceIdentity, readJSON, writeJSON } from './library.js'
import * as L from './layout.js'

/** What the Mac's `DeviceIdentity.platformName` is for this machine. */
export const PLATFORM_NAME = process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : 'Mac'

export interface OwnJournal {
  journal: Journal
  loaded: boolean
}

export interface JournalOptions {
  device?: string
  platformName?: string
  /** How long after the last change the file is written. The Mac waits 200 ms. */
  writeDelay?: number
}

export class Journals {
  private readonly device: string
  private readonly platformName: string
  private readonly writeDelay: number
  private readonly held = new Map<string, OwnJournal>()
  /** One read at a time per paper: two marks made before the first read came
   *  back each read the file, and the second `set` replaced the first's copy —
   *  with the first mark in it gone. */
  private readonly reading = new Map<string, Promise<OwnJournal>>()
  private readonly writes = new Map<string, { timer: NodeJS.Timeout; write: () => Promise<void> }>()

  constructor(options: JournalOptions = {}) {
    this.device = options.device ?? deviceIdentity
    this.platformName = options.platformName ?? PLATFORM_NAME
    this.writeDelay = options.writeDelay ?? 200
  }

  /** This device's journal for a paper, read once and held. */
  own(id: string, root: string): Promise<OwnJournal> {
    const known = this.held.get(id)
    if (known?.loaded) return Promise.resolve(known)
    const inFlight = this.reading.get(id)
    if (inFlight) return inFlight
    const next = this.read(id, root).finally(() => this.reading.delete(id))
    this.reading.set(id, next)
    return next
  }

  private async read(id: string, root: string): Promise<OwnJournal> {
    const known = this.held.get(id)
    const file = L.marksPath(root, id, this.device)
    try {
      const disk = asJournal(await readJSON(file)) ?? freshJournal(this.device, this.platformName)
      for (const [key, entry] of Object.entries(known?.journal.entries ?? {})) {
        const there = disk.entries[key]
        if (!there || Date.parse(there.at) < Date.parse(entry.at)) disk.entries[key] = entry
      }
      const own = { journal: disk, loaded: true }
      this.held.set(id, own)
      return own
    } catch (error) {
      console.error("marks journal - this device's journal could not be read, and is not written over:", error)
      if (known) return known
      const own = { journal: freshJournal(this.device, this.platformName), loaded: false }
      this.held.set(id, own)
      return own
    }
  }

  /**
   * Writes this device's journal a little after the last change to it — a
   * stroke of the highlighter across a paragraph is several saves, and the
   * journal is a file in a synced folder. What is held here is what the next
   * PDF write reads, so nothing waits on the disk; `flush` writes whatever
   * is still waiting at quit.
   */
  keep(id: string, root: string, own: OwnJournal): void {
    if (!own.loaded) return
    const waiting = this.writes.get(id)
    if (waiting) clearTimeout(waiting.timer)
    const write = async () => {
      this.writes.delete(id)
      own.journal.device = this.device
      own.journal.name = this.platformName
      try {
        await writeJSON(L.marksPath(root, id, this.device), own.journal)
      } catch (error) {
        console.error(`marks journal - ${id} could not be written:`, error)
      }
    }
    this.writes.set(id, { timer: setTimeout(() => void write(), this.writeDelay), write })
  }

  /** Every device's journal for a paper: the others as their files have them,
   *  this one as it is held here. A journal that will not be read is left out —
   *  it is somebody's, and it is late, and the file already holds what it said
   *  the last time that device wrote it. */
  async all(id: string, root: string): Promise<Held[]> {
    const out: Held[] = []
    let names: string[] = []
    try {
      names = await fsp.readdir(L.marksDir(root, id))
    } catch {
      names = []
    }
    for (const name of names) {
      if (!name.endsWith('.json')) continue
      try {
        const journal = asJournal(await readJSON(path.join(L.marksDir(root, id), name)))
        if (!journal) continue
        const device = typeof journal.device === 'string' ? journal.device : name.slice(0, -'.json'.length)
        if (device === this.device) continue
        out.push({ device, journal })
      } catch {
        continue
      }
    }
    const own = await this.own(id, root)
    out.push({ device: this.device, journal: own.journal })
    return out
  }

  /**
   * Records in this device's journal what one save of a page changed — a
   * `MarkupDescriptor` for a mark made or changed, nothing for one taken
   * away, the shape the Mac writes. Returns whether anything changed.
   */
  async record(
    id: string,
    root: string,
    pageIndex: number,
    before: MarkupRecord[],
    after: MarkupRecord[],
    pages: Record<number, MarkupRecord[]>,
    now = new Date(),
  ): Promise<boolean> {
    const own = await this.own(id, root)
    const elsewhere = new Set<string>()
    for (const [index, marks] of Object.entries(pages)) {
      if (Number(index) === pageIndex) continue
      for (const mark of marks) elsewhere.add(mark.id.toUpperCase())
    }
    if (!recordChanges(own.journal, pageIndex, before, after, now, elsewhere)) return false
    this.keep(id, root, own)
    return true
  }

  /** The same, with the other pages' identifiers given by the window. */
  async recordChange(
    id: string,
    root: string,
    pageIndex: number,
    before: MarkupRecord[],
    after: MarkupRecord[],
    elsewhere: Set<string>,
    now = new Date(),
  ): Promise<boolean> {
    const own = await this.own(id, root)
    if (!recordChanges(own.journal, pageIndex, before, after, now, elsewhere)) return false
    this.keep(id, root, own)
    return true
  }

  /** Writes now whatever is waiting. */
  async flush(): Promise<void> {
    const waiting = [...this.writes.values()]
    for (const one of waiting) clearTimeout(one.timer)
    await Promise.allSettled(waiting.map((one) => one.write()))
  }

  /** Lets go of a paper that left the library. */
  async forget(id: string): Promise<void> {
    const waiting = this.writes.get(id)
    if (waiting) {
      clearTimeout(waiting.timer)
      await waiting.write()
    }
    this.held.delete(id)
  }
}

/** A record read from disk, if it has a journal's shape. */
export function asJournal(raw: unknown): Journal | null {
  if (!raw || typeof raw !== 'object') return null
  const journal = raw as Journal
  if (!journal.entries || typeof journal.entries !== 'object') journal.entries = {}
  return journal
}
