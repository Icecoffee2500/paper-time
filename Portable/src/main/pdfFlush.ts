/**
 * The file, written behind the reader.
 *
 * The sidecar is saved the moment a gesture ends, so nothing is ever at risk.
 * Rewriting a twenty-megabyte file on every stroke, though, is how an app
 * starts stuttering under a pen — so the PDF is rewritten 1.5 seconds after
 * the last change, the same wait the Mac takes before reconciling marks into
 * the file. A save the file did not take is tried again — after 1.5, 5 and
 * 15 seconds — and then the reader says the marks are in Paper Time and not
 * in the file, until the next change tries once more.
 */
import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import { renameHeld } from './renameHeld.js'
import path from 'node:path'
import type { KeptReason } from '../shared/api.js'
import { merged, reconcile } from '../shared/markJournal.js'
import { SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import {
  WriteRefused, isOurMark, keptReason, readMarks, writeDrawingsDetailed,
  type MarkupRecord, type PageDrawing,
} from './pdfwrite.js'
import { writeJSON, type Library } from './library.js'
import * as L from './layout.js'
import type { Journals } from './journal.js'
import type { PageCounter } from './pdfBytes.js'
import { noteOwnWrite } from './ownWrites.js'

export const PDF_WRITE_DELAY = 1500
export const FLUSH_RETRY = [1500, 5000, 15000]

/** `retry`: the file changed under the save, which goes again on top of it. */
export type FlushResult = { written: number } | { kept: KeptReason } | { error: string } | { retry: 'moved' }

export interface TouchedPages {
  sketch: Set<number>
  ink: Set<number>
  marks: Set<number>
}

export interface FlushHooks {
  ownerOf: (id: string) => Promise<Library | null>
  journals: Journals
  pageCounter: PageCounter
  /** To every window. */
  send: (event: string, payload?: unknown) => void
  log?: (line: string) => void
  /** For tests: what one write of a paper does. */
  write?: (id: string) => Promise<FlushResult>
  delays?: { write: number; retry: number[] }
}

export class PDFFlusher {
  /**
   * The pages whose layers this run has saved, per paper. A page is this
   * build's to rewrite for a layer when it has a sidecar here — or when it
   * was saved here and has none any more. What a page must never be is
   * rewritten because it merely has something in the file: a page drawn on a
   * Mac carries the Mac's strokes in the PDF and in its `.drawing`, and in no
   * sidecar of this build's, and treating "no sidecar" as "no strokes" rubbed
   * them out of the file.
   */
  private readonly touchedPages = new Map<string, TouchedPages>()
  private readonly pending = new Map<string, NodeJS.Timeout>()
  private readonly attempts = new Map<string, number>()
  /** One write at a time per paper: two would read the same file and race. */
  private readonly flushing = new Map<string, Promise<FlushResult>>()
  private readonly delays: { write: number; retry: number[] }

  constructor(private readonly hooks: FlushHooks) {
    this.delays = hooks.delays ?? { write: PDF_WRITE_DELAY, retry: FLUSH_RETRY }
  }

  touched(id: string): TouchedPages {
    let pages = this.touchedPages.get(id)
    if (!pages) {
      pages = { sketch: new Set(), ink: new Set(), marks: new Set() }
      this.touchedPages.set(id, pages)
    }
    return pages
  }

  /** A change to write into the file: starts the tries afresh. */
  schedule(id: string) {
    this.attempts.delete(id)
    this.hooks.send('paper:saveState', { id, state: 'pending' })
    this.later(id, this.delays.write)
  }

  private later(id: string, delay: number) {
    clearTimeout(this.pending.get(id))
    this.pending.set(id, setTimeout(() => {
      this.pending.delete(id)
      this.hooks.send('paper:saveState', { id, state: 'saving' })
      this.flush(id).then(
        (result) => this.after(id, result),
        (error) => this.after(id, { error: String((error as Error)?.message ?? error) }),
      )
    }, delay))
  }

  private after(id: string, result: FlushResult) {
    if (!('error' in result) && !('retry' in result)) {
      this.attempts.delete(id)
      this.hooks.send('paper:saveState', { id, state: 'idle' })
      return
    }
    const attempt = (this.attempts.get(id) ?? 0) + 1
    if (attempt > this.delays.retry.length) {
      this.attempts.delete(id)
      console.error(`pdf write - ${id} gave up after ${this.delays.retry.length} tries:`, 'error' in result ? result.error : result.retry)
      this.hooks.send('paper:kept', { id, reason: 'io' })
      this.hooks.send('paper:saveState', { id, state: 'idle' })
      return
    }
    this.attempts.set(id, attempt)
    this.later(id, this.delays.retry[attempt - 1])
  }

  /** Writes now, after any write already running for this paper. */
  flush(id: string): Promise<FlushResult> {
    const before = this.flushing.get(id) ?? Promise.resolve()
    const write = () => (this.hooks.write ?? this.write.bind(this))(id)
    const next: Promise<FlushResult> = before.then(write, write)
    this.flushing.set(id, next)
    void next.finally(() => {
      if (this.flushing.get(id) === next) this.flushing.delete(id)
    })
    return next
  }

  /** The window asked: written now, and a file that moved is tried again shortly. */
  async flushAsked(id: string): Promise<{ written: number } | { kept: KeptReason } | { error: string }> {
    const result = await this.flush(id)
    if ('retry' in result) {
      this.later(id, this.delays.retry[0])
      return { written: 0 }
    }
    return result
  }

  /** Whether a write is waiting or running for this paper. */
  busy(id: string): boolean {
    return this.pending.has(id) || this.flushing.has(id)
  }

  /**
   * Finishes what is waiting for a paper before something else happens to its
   * file — a rename, a trip to the Trash.
   */
  async settle(id: string): Promise<void> {
    const timer = this.pending.get(id)
    if (timer) {
      clearTimeout(timer)
      this.pending.delete(id)
      await this.flush(id).catch(() => undefined)
    }
    await this.flushing.get(id)?.catch(() => undefined)
  }

  /** Lets go of a paper that left the library. */
  forget(id: string) {
    clearTimeout(this.pending.get(id))
    this.pending.delete(id)
    this.attempts.delete(id)
    this.touchedPages.delete(id)
  }

  /**
   * Nothing is left half done at quit: the writes still waiting are done now,
   * the ones running are waited for — ten seconds at most, then the app goes
   * whatever is left. Before, a mark made in the last second reached the
   * journal and not the file.
   */
  async drain(capMs = 10_000): Promise<void> {
    const waiting = [...this.pending.keys()]
    for (const id of waiting) clearTimeout(this.pending.get(id))
    this.pending.clear()
    const work = Promise.allSettled([
      ...waiting.map((id) => this.flush(id)),
      ...this.flushing.values(),
    ])
    await Promise.race([work, new Promise((resolve) => setTimeout(resolve, capMs))])
  }

  private async write(id: string): Promise<FlushResult> {
    // The folder the paper is in, and every sidecar and journal from there:
    // the file, its drawings and its marks all live in one folder.
    const owner = await this.hooks.ownerOf(id)
    if (!owner) return { error: 'No library is open.' }
    const row = await owner.paper(id)
    if (!row?.file || !row.exists) return { error: 'The PDF is not where the record says it is.' }
    let wanted = new Map<number, MarkupRecord[]>()
    try {
      const pages = await owner.annotatedPages(id)
      const saved = this.touched(id)
      const was = await fsp.stat(row.file)
      const current = await fsp.readFile(row.file)
      // The marks the file should hold: what it holds now, overruled by every
      // device's journal — this machine's changes are in its own by now, and a
      // Mac that marked the page a second ago is in its. `DocumentSession`
      // writes the file the same way, to agree with all of them.
      const reconciled = reconcile(await readMarks(current), merged(await this.hooks.journals.all(id, owner.root)))
      wanted = reconciled.pages
      const dirty = reconciled.dirty
      const sketchPages = new Set([...pages.sketch, ...saved.sketch])
      const inkPages = new Set([...pages.ink, ...saved.ink])
      const markPages = new Set([...saved.marks, ...dirty])
      const indices = [...new Set([...sketchPages, ...inkPages, ...markPages])].sort((a, b) => a - b)
      const drawings: PageDrawing[] = []
      for (const pageIndex of indices) {
        const managesSketch = sketchPages.has(pageIndex)
        const managesInk = inkPages.has(pageIndex)
        drawings.push({
          pageIndex,
          elements: managesSketch ? ((await owner.loadSketch(id, pageIndex)) ?? []).map(SketchElement.from) : [],
          strokes: managesInk ? ((await owner.loadInk(id, pageIndex)) ?? []).map(InkStroke.from) : [],
          // Every mark, another reader's too: one left as it came stays
          // untouched, one changed here is taken into this app's care, and
          // one removed (here or on the Mac, by the identifier both derive)
          // comes out — the list is this file's own marks, reconciled.
          marks: wanted.get(pageIndex) ?? [],
          foreignComplete: true,
          managesSketch,
          managesInk,
          managesMarks: markPages.has(pageIndex),
        })
      }
      if (drawings.length === 0) return { written: 0 }
      const written = await writeDrawingsDetailed(current, drawings)
      // Nothing to change is nothing to write: the same bytes come back.
      if (written.changed) {
        // The base for compaction, the way the Mac records it: the file as it
        // is just before the first update goes onto it, once.
        await recordBaseIfAbsent(owner.root, id, current)
        const placed = await this.appendVerified(row.file, was, current, written.bytes, written.pages)
        if (placed === 'moved') {
          // Somebody else wrote the file between the read and the write — the
          // Mac through the cloud, most likely. Theirs stands; this save goes
          // again on top of it.
          return { retry: 'moved' }
        }
        if (written.stats) {
          const s = written.stats
          this.hooks.log?.(`pdf append: ${path.basename(row.file)} +${s.bytesAfter - s.bytesBefore} B, xref=${s.xrefKind}, pages=${s.pagesChanged}, added=${s.annotationsAdded}, removed=${s.annotationsRemoved}, freed=${s.objectsFreed}, ${s.ms} ms`)
        }
      }
      this.hooks.send('paper:saved', { id })
      return { written: drawings.length }
    } catch (error) {
      if (error instanceof WriteRefused) {
        // Not a failure, and not said as one. Everything is where it was put —
        // the shapes and the strokes in their sidecars, the marks in the
        // journal — and the window says that the file is not where they are.
        // Once the last of them is taken away there is nothing left to say it
        // about, and the line goes.
        const reason = keptReason(error.reason)
        this.hooks.log?.(`pdf append refused: ${path.basename(row.file)}: ${error.message}`)
        const held = await holdsAnything(owner, id, wanted)
        this.hooks.send('paper:kept', { id, reason: held ? reason : null })
        return { kept: reason }
      }
      return { error: String((error as Error).message ?? error) }
    }
  }

  /**
   * Puts the appended file in the original's place — and only when it is what
   * it claims to be.
   *
   * The paper is the one thing in this library that cannot be regenerated, so
   * nothing replaces it that has not been read back and checked: the file on
   * disk is still the one that was read (size and time), the temporary file
   * begins with the very bytes that were read (length and a digest of the
   * prefix), and pdf.js opens it with the page count our own reader found. A
   * check that fails leaves the original untouched and the marks in the
   * journal. Temporary file beside the original, then rename over it.
   */
  private async appendVerified(file: string, was: fs.Stats, original: Uint8Array, result: Uint8Array, pages: number): Promise<'placed' | 'moved'> {
    const temporary = `${file}.${process.pid}.tmp`
    try {
      await fsp.writeFile(temporary, result)
      const back = await fsp.readFile(temporary)
      if (back.length !== result.length || back.length < original.length) throw new WriteRefused('verification', 'the temporary file is not the right length')
      const wanted = crypto.createHash('sha256').update(original).digest('hex')
      const got = crypto.createHash('sha256').update(back.subarray(0, original.length)).digest('hex')
      if (wanted !== got) throw new WriteRefused('verification', 'the result does not begin with the original bytes')
      let counted: number
      try {
        counted = await this.hooks.pageCounter.count(back)
      } catch (error) {
        throw new WriteRefused('verification', (error as Error).message)
      }
      if (counted !== pages) throw new WriteRefused('verification', `pdf.js reads ${counted} pages, the file says ${pages}`)
      const now = await fsp.stat(file)
      if (now.size !== was.size || now.mtimeMs !== was.mtimeMs) {
        await fsp.rm(temporary, { force: true })
        return 'moved'
      }
      noteOwnWrite(file)
      await renameHeld(temporary, file)
      noteOwnWrite(file)
      return 'placed'
    } catch (error) {
      await fsp.rm(temporary, { force: true })
      throw error
    }
  }
}

/**
 * `.papertime/papers/<id>/pdf/base.json`: the length and digest of the file
 * before anything was ever appended to it — what compaction on the Mac
 * rebases onto (`PDFBase`). Written once, never changed; the same bytes the
 * Mac writes, so either build can have been first.
 */
export async function recordBaseIfAbsent(root: string, id: string, bytes: Uint8Array) {
  const file = path.join(L.paperDir(root, id), 'pdf', 'base.json')
  if (fs.existsSync(file)) return
  const digest = crypto.createHash('sha256').update(bytes).digest('hex')
  await writeJSON(file, { digest, length: bytes.length })
}

/**
 * Whether anything this build made is on the paper — a mark, a shape, a
 * stroke — for the line that says the file does not carry it.
 */
export async function holdsAnything(owner: Library, id: string, marks: Map<number, MarkupRecord[]>): Promise<boolean> {
  for (const list of marks.values()) if (list.some(isOurMark)) return true
  const drawn = await owner.annotatedPages(id)
  return drawn.sketch.length > 0 || drawn.ink.length > 0
}

/**
 * A temporary copy a write left beside a paper when it was cut off — a crash,
 * a power cut, a quit that did not wait — is removed when the library opens:
 * `<paper>.pdf.<pid>.tmp` and older than ten minutes, so no write running
 * now loses its file. Only the folders that hold papers are read, once each.
 */
export async function sweepTemporaries(files: string[], olderThanMs = 10 * 60_000, now = Date.now()): Promise<string[]> {
  const folders = new Set(files.map((file) => path.dirname(file)))
  const removed: string[] = []
  for (const folder of folders) {
    let names: string[] = []
    try {
      names = await fsp.readdir(folder)
    } catch {
      continue
    }
    for (const name of names) {
      if (!/\.pdf\.\d+(\.\d+)?\.tmp$/i.test(name)) continue
      const file = path.join(folder, name)
      try {
        if ((await fsp.stat(file)).mtimeMs < now - olderThanMs) {
          await fsp.rm(file, { force: true })
          removed.push(file)
        }
      } catch {
        // Gone already, or not ours to remove.
      }
    }
  }
  return removed
}

export { renameHeld }
