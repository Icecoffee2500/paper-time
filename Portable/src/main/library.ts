/**
 * Reading and writing a library folder.
 *
 * The folder is the database. There is no index to fall out of step, and no
 * migration to run when a Mac and a PC take turns with the same folder in a
 * cloud drive — a paper is a PDF beside a small JSON record, and adding one on
 * one machine is a file appearing on the other.
 *
 * Every write goes through `writeJSON`, which writes to a neighbouring
 * temporary file and renames it over the target. A rename within a directory
 * is atomic on every filesystem this app will meet, so a library folder is
 * never left holding half a record because a laptop lid closed mid-save.
 */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import crypto from 'node:crypto'
import os from 'node:os'
import { encodeSwiftJSON, isoTimestamp, makeUUID } from '../shared/coding.js'
import {
  PaperMeta,
  PaperState,
  newCollectionSet,
  newManifest,
  type Collection,
  type CollectionSet,
  type LibraryManifest,
  type RawRecord,
} from '../shared/model.js'
import * as L from './layout.js'

/**
 * This machine's name in a record's `updatedBy`, and the file name of its
 * marks journal. The Mac writes `Mac-XXXXXXXX`; this writes the same shape so
 * a folder's journals read as a list of machines rather than a list of guesses.
 */
export const deviceIdentity = (() => {
  const platform = process.platform === 'win32' ? 'Win' : process.platform === 'linux' ? 'Linux' : 'Mac'
  const hash = crypto.createHash('sha256').update(os.hostname()).digest('hex').slice(0, 8).toUpperCase()
  return `${platform}-${hash}`
})()

/** Why a name was refused. The window says it in the reader's language. */
export type RenameFailure = 'empty' | 'notAName' | 'taken' | 'missing'

export interface PaperRow {
  id: string
  meta: RawRecord
  state: RawRecord
  /** Absolute path of the PDF, or null when the record has lost its file. */
  file: string | null
  exists: boolean
}

export async function readJSON(file: string): Promise<RawRecord | null> {
  try {
    const text = await fsp.readFile(file, 'utf8')
    return JSON.parse(text) as RawRecord
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
}

let writeCounter = 0

export async function writeJSON(file: string, value: unknown): Promise<void> {
  await fsp.mkdir(path.dirname(file), { recursive: true })
  const text = encodeSwiftJSON(value)
  // Unique per write, not merely per process: two saves of the same page can
  // overlap — a stroke finishing while the previous one is still being
  // written — and a shared temporary name means one rename finds nothing
  // there. The counter costs nothing and the collision is silent data loss.
  writeCounter += 1
  const temporary = `${file}.${process.pid}.${writeCounter}.tmp`
  try {
    await fsp.writeFile(temporary, text, 'utf8')
    await fsp.rename(temporary, file)
  } catch (error) {
    await fsp.rm(temporary, { force: true })
    throw error
  }
}

// MARK: - The library

export class Library {
  constructor(public root: string) {}

  static async open(root: string): Promise<Library> {
    const library = new Library(root)
    await fsp.mkdir(L.papersDir(root), { recursive: true })
    if (!fs.existsSync(L.manifestPath(root))) {
      await writeJSON(L.manifestPath(root), newManifest(path.basename(root)))
    }
    if (!fs.existsSync(L.collectionsPath(root))) {
      await writeJSON(L.collectionsPath(root), newCollectionSet(deviceIdentity))
    }
    return library
  }

  async manifest(): Promise<LibraryManifest> {
    return ((await readJSON(L.manifestPath(this.root))) as LibraryManifest | null)
      ?? newManifest(path.basename(this.root))
  }

  async saveManifest(manifest: LibraryManifest): Promise<void> {
    await writeJSON(L.manifestPath(this.root), manifest)
  }

  async collections(): Promise<CollectionSet> {
    return ((await readJSON(L.collectionsPath(this.root))) as CollectionSet | null)
      ?? newCollectionSet(deviceIdentity)
  }

  async saveCollections(collections: Collection[]): Promise<CollectionSet> {
    const set: CollectionSet = {
      ...(await this.collections()),
      schema: 1,
      collections,
      updatedAt: isoTimestamp(new Date()),
      updatedBy: deviceIdentity,
    }
    await writeJSON(L.collectionsPath(this.root), set)
    return set
  }

  /**
   * Every record in the folder, with the PDF each one points at.
   *
   * All of them at once. Read one after another it was two file reads per
   * paper in a queue of one, and a folder in the cloud answers each of them
   * with a round trip — sixty papers meant a hundred and twenty waits that
   * had no reason to be in a line.
   */
  async papers(): Promise<PaperRow[]> {
    let entries: string[]
    try {
      entries = await fsp.readdir(L.papersDir(this.root))
    } catch {
      return []
    }
    const read = entries
      .filter((id) => !id.startsWith('.'))
      .map(async (id): Promise<PaperRow | null> => {
        const [meta, state] = await Promise.all([
          readJSON(L.metaPath(this.root, id)),
          readJSON(L.statePath(this.root, id)),
        ])
        if (!meta) return null
        const relative = String((meta.file as RawRecord | undefined)?.relativePath ?? '')
        const file = relative ? path.join(this.root, relative) : null
        return { id, meta, state: state ?? {}, file, exists: file ? fs.existsSync(file) : false }
      })
    return (await Promise.all(read)).filter((row): row is PaperRow => row !== null)
  }

  async paper(id: string): Promise<PaperRow | null> {
    const meta = await readJSON(L.metaPath(this.root, id))
    if (!meta) return null
    const state = (await readJSON(L.statePath(this.root, id))) ?? {}
    const relative = String((meta.file as RawRecord | undefined)?.relativePath ?? '')
    const file = relative ? path.join(this.root, relative) : null
    return { id, meta, state, file, exists: file ? fs.existsSync(file) : false }
  }

  /**
   * Gives the PDF a new name on disk.
   *
   * The library is a folder of PDFs under the names a person gave them, so
   * the name in the app and the name in the file manager have to be the same
   * name: renaming here renames the file. Only the file moves — the record
   * folder is named after the paper's identifier, so marks, ink, notes and
   * reading state follow the paper without being touched.
   *
   * Refusals come back as a word, not a sentence: the window says it in
   * whichever language it is being read in.
   */
  async rename(id: string, proposed: string): Promise<PaperRow | { error: RenameFailure }> {
    const row = await this.paper(id)
    if (!row || !row.file) return { error: 'missing' }

    let name = proposed.trim().replace(/^\.+/, '').trim()
    if (!name) return { error: 'empty' }
    if (/[/\\:*?"<>|]/.test(name)) return { error: 'notAName' }

    const current = row.file
    const extension = path.extname(current)
    if (extension && path.extname(name).toLowerCase() !== extension.toLowerCase()) {
      name += extension
    }
    if (name === path.basename(current)) return row
    if (!fs.existsSync(current)) return { error: 'missing' }

    const destination = path.join(path.dirname(current), name)
    // On a disk that does not mind case — every Windows one, most Macs — the
    // destination of a rename that only changes a letter's case is this same
    // file, and the move is how the case is changed.
    const caseOnly = destination.toLowerCase() === current.toLowerCase()
    if (!caseOnly && fs.existsSync(destination)) return { error: 'taken' }

    await fsp.rename(current, destination)

    const meta = new PaperMeta(row.meta)
    meta.file = {
      ...meta.file,
      relativePath: path.relative(this.root, destination),
      originalName: name,
    }
    await this.saveMeta(meta)
    return (await this.paper(id)) ?? row
  }

  async saveMeta(meta: PaperMeta): Promise<void> {
    meta.updatedAt = new Date()
    meta.updatedBy = deviceIdentity
    await writeJSON(L.metaPath(this.root, meta.id), meta.encode())
  }

  /**
   * Saves reading state, re-reading first so a change that arrived from
   * another machine while this one held the paper is not silently dropped.
   */
  async saveState(id: string, state: PaperState): Promise<PaperState> {
    const onDisk = await readJSON(L.statePath(this.root, id))
    state.updatedAt = new Date()
    state.updatedBy = deviceIdentity
    let winner = state
    if (onDisk) {
      const remote = new PaperState(onDisk)
      // Only a genuinely newer write from elsewhere can win; this one's stamp
      // was just set, so in the ordinary case it is this one.
      winner = PaperState.resolve(state, remote)
    }
    await writeJSON(L.statePath(this.root, id), winner.encode())
    return winner
  }

  // MARK: - Importing

  /**
   * Copies a PDF into the library and writes its record.
   *
   * A file already in the library is adopted where it lies rather than
   * duplicated, and a file whose bytes match a paper already here is not
   * imported twice — the same two rules the Mac importer follows.
   */
  async importPDF(source: string, pageCount: number): Promise<PaperRow | null> {
    const digest = await sha256(source)
    const existing = await this.papers()
    const already = existing.find(
      (row) => String((row.meta.file as RawRecord)?.importDigest ?? '') === digest,
    )
    if (already) return already

    const inside = path.resolve(source).startsWith(path.resolve(this.root) + path.sep)
    let relative: string
    if (inside) {
      relative = path.relative(this.root, source)
    } else {
      const name = L.availableFileName(path.basename(source), this.root)
      await fsp.copyFile(source, path.join(this.root, name))
      relative = name
    }
    const stat = await fsp.stat(path.join(this.root, relative))
    const id = makeUUID()
    const meta = PaperMeta.make(
      id,
      {
        relativePath: relative,
        byteSize: stat.size,
        pageCount,
        importDigest: digest,
        originalName: path.basename(source),
      },
      deviceIdentity,
    )
    await writeJSON(L.metaPath(this.root, id), meta.encode())
    await writeJSON(L.statePath(this.root, id), new PaperState({}).encode())
    return this.paper(id)
  }

  /** PDFs sitting in the folder that no record points at. */
  async looseFiles(): Promise<string[]> {
    return this.unclaimedFiles(claimedBy(await this.papers()))
  }

  /**
   * The same answer, for a caller that has just read the records.
   *
   * The cheap counterpart to `looseFiles()`, and the Mac has the same pair
   * (`unclaimedDocumentURLs(claiming:)`): working out which PDFs are spoken
   * for used to read every record from disk a second time, so one refresh
   * decoded the whole library twice.
   */
  async unclaimedFiles(claimed: Set<string>): Promise<string[]> {
    const found: string[] = []
    for (const entry of await fsp.readdir(this.root, { withFileTypes: true })) {
      if (!entry.isFile()) continue
      if (!entry.name.toLowerCase().endsWith('.pdf')) continue
      if (claimed.has(entry.name)) continue
      found.push(path.join(this.root, entry.name))
    }
    return found
  }

  /**
   * Moves a paper's PDF and record to the library's Trash.
   *
   * Nothing is deleted: the folder keeps what it held, one level down, so a
   * paper removed by accident is still a paper.
   */
  async trashPaper(id: string): Promise<void> {
    const row = await this.paper(id)
    if (!row) return
    const stamp = new Date().toISOString().replace(/[:.]/g, '-')
    const destination = path.join(L.trashDir(this.root), `${stamp}-${id}`)
    await fsp.mkdir(destination, { recursive: true })
    if (row.file && fs.existsSync(row.file)) {
      await fsp.rename(row.file, path.join(destination, path.basename(row.file)))
    }
    const record = L.paperDir(this.root, id)
    if (fs.existsSync(record)) {
      await fsp.rename(record, path.join(destination, 'record'))
    }
  }

  // MARK: - The drawing layer's sidecars

  async loadSketch(id: string, pageIndex: number): Promise<unknown[] | null> {
    try {
      const text = await fsp.readFile(L.sketchPath(this.root, id, pageIndex), 'utf8')
      const parsed = JSON.parse(text)
      return Array.isArray(parsed) ? parsed : null
    } catch {
      return null
    }
  }

  async saveSketch(id: string, pageIndex: number, elements: unknown[]): Promise<void> {
    const file = L.sketchPath(this.root, id, pageIndex)
    if (elements.length === 0) {
      await fsp.rm(file, { force: true })
      return
    }
    await writeJSON(file, elements)
  }

  async loadInk(id: string, pageIndex: number): Promise<unknown[] | null> {
    try {
      const text = await fsp.readFile(L.inkPath(this.root, id, pageIndex), 'utf8')
      const parsed = JSON.parse(text)
      return Array.isArray(parsed) ? parsed : null
    } catch {
      return null
    }
  }

  async saveInk(id: string, pageIndex: number, strokes: unknown[]): Promise<void> {
    const file = L.inkPath(this.root, id, pageIndex)
    if (strokes.length === 0) {
      await fsp.rm(file, { force: true })
      return
    }
    await writeJSON(file, strokes)
  }

  /** Pages with a drawing of either kind, so the reader knows what to load. */
  async annotatedPages(id: string): Promise<{ sketch: number[]; ink: number[]; appleInk: number[] }> {
    const listing = async (dir: string, extension: string) => {
      try {
        return (await fsp.readdir(dir))
          .map((name) => L.pageIndexFromFileName(name, extension))
          .filter((index): index is number => index !== null)
          .sort((a, b) => a - b)
      } catch {
        return []
      }
    }
    return {
      sketch: await listing(L.sketchDir(this.root, id), '.json'),
      ink: await listing(L.inkDir(this.root, id), '.json'),
      appleInk: await listing(L.inkDir(this.root, id), '.drawing'),
    }
  }
}

export async function sha256(file: string): Promise<string> {
  const hash = crypto.createHash('sha256')
  await new Promise<void>((resolve, reject) => {
    const stream = fs.createReadStream(file)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolve())
    stream.on('error', reject)
  })
  return hash.digest('hex')
}

/** Which PDFs a set of records speaks for, by the name each one points at. */
export function claimedBy(rows: PaperRow[]): Set<string> {
  return new Set(
    rows
      .map((row) => String((row.meta.file as RawRecord)?.relativePath ?? ''))
      .filter(Boolean),
  )
}
