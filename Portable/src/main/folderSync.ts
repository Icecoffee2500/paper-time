/**
 * Keeping the library in line with its folders.
 *
 * A PDF that appears in a library folder is a paper in that library — that
 * is what choosing a folder means — so it is taken in rather than left
 * behind a button. The Mac has done this since it had folders
 * (`LibraryModel.folderDidChange`). Nothing is moved, renamed or rewritten:
 * the file stays where it landed and only the record beside it is new. Each
 * folder takes in its own.
 *
 * What the watcher reports is sorted first. A write of our own is not a
 * change (`ownWrites`); a temporary file is nobody's yet; a sidecar that
 * arrived from another machine — a journal, a page of ink — is a change to
 * one paper and is said as one, not read as a whole library; a record, a
 * PDF, the slip-box or the vocabulary is the folder changing, and the
 * folder is settled and the window told once.
 *
 * One settling at a time, and every fire gets its own: the watcher fires in
 * bursts and adopting writes records, which fires it again. Importing,
 * adopting the loose PDFs and opening a file from outside go through the
 * same queue, because they change the folder the watcher is reading.
 */
import path from 'node:path'
import { looksWhole } from '../shared/pdfLock.js'
import { isUnder, slashed } from '../shared/paths.js'
import { claimedBy, sha256Bytes, type Library } from './library.js'
import * as L from './layout.js'
import { isOwnWrite } from './ownWrites.js'
import { readWhole, type PageCounter } from './pdfBytes.js'
import { watchLibrary, type ChangedFile } from './watcher.js'

export type Change =
  | { kind: 'ignore' }
  | { kind: 'sidecar'; id: string; layer: 'marks' | 'ink' | 'sketch' | 'pdf' | 'other' }
  | { kind: 'record'; id: string }
  | { kind: 'notes' }
  | { kind: 'vocabulary' }
  | { kind: 'pdf' }
  | { kind: 'unknown' }

const TEMPORARY = /(\.tmp|\.part|\.crdownload|\.download|~)$/i

/** What one changed path means to the library it is under. */
export function classifyChange(root: string, file: ChangedFile): Change {
  if (file === null) return { kind: 'unknown' }
  const name = path.basename(file)
  if (TEMPORARY.test(name) || name.startsWith('~$') || name === '.DS_Store' || name === 'Thumbs.db') return { kind: 'ignore' }
  const inside = slashed(file).slice(slashed(root).length + 1)
  const parts = inside.split('/')
  if (parts[0] === L.SUPPORT_DIR) {
    if (parts[1] === L.PAPERS_DIR && parts[2]) {
      const id = parts[2]
      const leaf = parts[3]
      if (!leaf) return { kind: 'record', id }
      if (leaf === L.META_FILE || leaf === L.STATE_FILE) return { kind: 'record', id }
      const layer = leaf === L.MARKS_DIR ? 'marks' : leaf === L.INK_DIR ? 'ink' : leaf === L.SKETCH_DIR ? 'sketch' : leaf === 'pdf' ? 'pdf' : 'other'
      return { kind: 'sidecar', id, layer }
    }
    if (parts[1] === L.NOTES_DIR) return { kind: 'notes' }
    if (parts[1] === L.MANIFEST_FILE || parts[1] === L.COLLECTIONS_FILE) return { kind: 'vocabulary' }
    return { kind: 'ignore' }
  }
  if (parts[0] === L.TRASH_DIR) return { kind: 'ignore' }
  if (/\.pdf$/i.test(name)) return { kind: 'pdf' }
  return { kind: 'unknown' }
}

export interface SyncHooks {
  libraries: () => Library[]
  /** The loose notes' folder, watched when it is not inside a library. */
  looseNotes: () => string | null
  pageCounter: PageCounter
  send: (event: string, payload?: unknown) => void
  /** Whether the library is empty: nothing is taken in while it is. */
  log?: (line: string) => void
}

export class FolderSync {
  private stops: (() => void)[] = []
  private queue: Promise<unknown> = Promise.resolve()
  private importing = new Set<string>()

  constructor(private readonly hooks: SyncHooks) {}

  /** (Re)arms one watcher per folder, and one for the loose notes. */
  start() {
    this.stop()
    const roots = this.hooks.libraries().map((one) => one.root)
    for (const root of roots) {
      this.stops.push(watchLibrary(root, (changed) => this.changed(root, changed)))
    }
    const loose = this.hooks.looseNotes()
    if (loose && !roots.some((root) => isUnder(loose, root))) {
      this.stops.push(watchLibrary(loose, (changed) => this.changed(loose, changed, true)))
    }
  }

  stop() {
    for (const stop of this.stops) stop()
    this.stops = []
  }

  /** Runs `work` after everything queued: settles, imports, adoptions. */
  run<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work)
    this.queue = next.catch(() => undefined)
    return next
  }

  private changed(root: string, changed: ChangedFile[], notesOnly = false) {
    const papers = new Map<string, Set<string>>()
    let whole = false
    for (const file of changed) {
      if (file !== null && isOwnWrite(file)) continue
      const change = notesOnly ? ({ kind: 'notes' } as Change) : classifyChange(root, file)
      switch (change.kind) {
        case 'ignore':
          break
        case 'sidecar': {
          const layers = papers.get(change.id) ?? new Set<string>()
          layers.add(change.layer)
          papers.set(change.id, layers)
          break
        }
        default:
          whole = true
      }
    }
    if (whole) {
      void this.settle()
      return
    }
    for (const [id, layers] of papers) this.hooks.send('paper:changed', { id, layers: [...layers] })
  }

  /** Brings the library back in line with the folder, then tells the window. */
  settle(): Promise<void> {
    return this.run(() => this.settleNow())
  }

  private async settleNow(): Promise<void> {
    try {
      const read = await Promise.all(this.hooks.libraries().map(async (one) => {
        const { papers, trouble } = await one.read()
        // Taking a PDF in on the app's own account is only safe when every
        // record answered, because the check for one already here is a check
        // against the records. Nothing is lost by waiting: this runs again on
        // the next change to the folder, and on every reload.
        const unclaimed = trouble.length > 0 ? [] : await one.unclaimedFiles(claimedBy(papers))
        return { one, papers, unclaimed }
      }))
      // Papers that were sitting in the folder when it was first opened are
      // a different matter and still wait to be offered, because the user has
      // not yet said that folder full of PDFs is their library — so nothing
      // is taken in while the library is empty.
      const empty = read.every((folder) => folder.papers.length === 0)
      if (!empty) {
        let taken = 0
        for (const folder of read) {
          for (const file of folder.unclaimed) {
            if (this.importing.has(file)) continue
            this.importing.add(file)
            try {
              if (await this.takeIn(folder.one, file)) taken += 1
            } finally {
              this.importing.delete(file)
            }
            // The window hears every twenty-five, so two hundred papers
            // arriving is a list that grows rather than one that appears.
            if (taken > 0 && taken % 25 === 0) this.hooks.send('library:changed')
            await new Promise((resolve) => setImmediate(resolve))
          }
        }
      }
    } catch (error) {
      // A folder that cannot be read right now — a disk unplugged, a cloud
      // drive asleep — is not a reason to stop telling the window.
      this.hooks.log?.(`folder sync - ${String((error as Error)?.message ?? error)}`)
    }
    this.hooks.send('library:changed')
  }

  /**
   * One PDF that appeared in a folder: read once, whole; counted by pdf.js
   * off this thread; refused — left for next time — when it is still coming
   * down or will not open.
   */
  private async takeIn(library: Library, file: string): Promise<boolean> {
    // A file still coming down the cloud drive is not a paper yet. Reading it
    // is what makes Windows fetch a placeholder, so this both waits for it
    // and pulls it; what is still short after that is left for the next time
    // the folder settles.
    const bytes = await readWhole(file)
    if (!looksWhole(bytes)) return false
    const pages = await this.hooks.pageCounter.countOrNull(bytes)
    if (pages === null) return false
    await library.importPDF(file, pages, { digest: sha256Bytes(bytes) })
    return true
  }
}
