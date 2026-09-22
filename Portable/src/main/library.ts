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
        const file = relative ? L.fileForRecordPath(this.root, relative) : null
        return { id, meta, state: state ?? {}, file, exists: file ? fs.existsSync(file) : false }
      })
    const rows = (await Promise.all(read)).filter((row): row is PaperRow => row !== null)
    await this.heal(rows)
    return rows
  }

  async paper(id: string): Promise<PaperRow | null> {
    const meta = await readJSON(L.metaPath(this.root, id))
    if (!meta) return null
    const state = (await readJSON(L.statePath(this.root, id))) ?? {}
    const relative = String((meta.file as RawRecord | undefined)?.relativePath ?? '')
    const file = relative ? path.join(this.root, relative) : null
    const row = { id, meta, state, file, exists: file ? fs.existsSync(file) : false }
    // A record that has lost its file is found again among the whole folder's
    // — which PDFs are free to be claimed is a question about all the records,
    // so this reads them. Only a paper that is already broken pays for it.
    if (!row.exists) return (await this.papers()).find((one) => one.id === id) ?? row
    return row
  }

  /**
   * Gives back the PDFs the records have lost.
   *
   * A record points at a name, and the name is the one part of a paper that
   * other software changes underneath it: a rename in the file manager, a
   * cloud client spelling a name in the characters its filesystem allows, two
   * desktops that write the same Korean syllable differently. The bytes do not
   * change, and the record kept their digest from the day the paper arrived,
   * so the file is still identifiable. The Mac has always found it this way —
   * `LibraryStore.load` calls `findDocument(matching:)` on every load — and
   * this build had nothing of the kind.
   *
   * That absence is why this class of trouble was permanent on Windows and
   * invisible on a Mac: the Mac repairs the record the moment it reads it, so
   * the library looks healthy there forever, while the same record on Windows
   * is a row that says the PDF is missing, a page that stays blank, and a
   * re-import that finds the digest, hands back the same broken record and
   * appears to do nothing at all.
   */
  private async heal(rows: PaperRow[]): Promise<void> {
    const lost = rows.filter(
      (row) => !row.exists && String((row.meta.file as RawRecord)?.importDigest ?? ''),
    )
    if (!lost.length) return
    const free = await this.unclaimedFiles(claimedBy(rows))
    if (!free.length) return
    for (const row of lost) {
      const info = row.meta.file as RawRecord
      const wanted = String(info.importDigest)
      const size = Number(info.byteSize ?? 0)
      for (let at = 0; at < free.length; at += 1) {
        const file = free[at]
        // The record carries the byte size, and comparing two numbers rules
        // out every other paper in the folder without reading one of them.
        const stat = await fsp.stat(file).catch(() => null)
        if (!stat) continue
        if (size > 0 && stat.size !== size) continue
        if ((await digestOfFile(file)) !== wanted) continue
        free.splice(at, 1)
        await this.claim(row, file)
        break
      }
    }
  }

  /** Points a record at the file its digest found, in hand and on disk. */
  private async claim(row: PaperRow, file: string): Promise<void> {
    const was = String((row.meta.file as RawRecord).relativePath ?? '')
    const relative = path.relative(this.root, file)
    row.meta = {
      ...row.meta,
      file: { ...(row.meta.file as RawRecord), relativePath: relative },
    }
    row.file = file
    row.exists = true
    if (!nameIsPossibleHere(was)) return
    const meta = new PaperMeta(row.meta)
    // Written, not saved: a repair is not an edit, and stamping it would make
    // this machine the last to have changed a paper it only opened.
    await writeJSON(L.metaPath(this.root, meta.id), meta.encode())
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
    if (already?.exists) return already
    if (already) {
      // The same bytes, and the record that holds them has lost its file. The
      // reader adding it again is answering the question the row is asking, so
      // the record takes this file rather than a second record being made for
      // a paper the library already has — and rather than the guard handing
      // back the broken row, which is what made re-adding the PDF look like it
      // did nothing. A file from outside is copied in first, as any import is.
      const inside = path.resolve(source).startsWith(path.resolve(this.root) + path.sep)
      let found = source
      if (!inside) {
        const name = L.availableFileName(path.basename(source), this.root)
        const landing = path.join(this.root, name)
        await fsp.copyFile(source, landing + '.part')
        await fsp.rename(landing + '.part', landing)
        found = landing
      }
      await this.claim(already, found)
      // Named by hand, so the name is this folder's name and travels: the
      // reserve `claim` keeps for a spelling only this desktop can hold does
      // not apply.
      await this.saveMeta(new PaperMeta(already.meta))
      return (await this.paper(already.id)) ?? already
    }

    const inside = path.resolve(source).startsWith(path.resolve(this.root) + path.sep)
    let relative: string
    if (inside) {
      relative = L.recordPath(this.root, source)
    } else {
      const name = L.availableFileName(path.basename(source), this.root)
      // Copied beside its own name and then renamed into place, because a
      // rename inside one folder is the one filesystem move that cannot be
      // caught half-done. A plain copyFile leaves a growing file where the
      // paper should be, and opening it during those seconds hands pdf.js
      // half a PDF — measured: 253,952 bytes of a 52,944,683-byte paper, and
      // the same "Invalid PDF structure." this was all about. The library
      // only ever lists `.pdf`, so a `.part` left by a crash stays invisible.
      const landing = path.join(this.root, name)
      await fsp.copyFile(source, landing + '.part')
      await fsp.rename(landing + '.part', landing)
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
    for (const file of await this.documentFiles()) {
      if (claimed.has(L.recordPath(this.root, file))) continue
      found.push(file)
    }
    return found
  }

  /**
   * Every PDF under the library, wherever it sits.
   *
   * This read one level and asked each entry whether it was a plain file, and
   * both halves of that were wrong.
   *
   * One level, because the folder was assumed flat. The Mac has never assumed
   * it — `LibraryStore.documentURLs()` says "wherever it sits under the root"
   * and walks down — so a paper filed in `2026/` was a paper on one desktop
   * and did not exist on the other. Nothing was said about it either: an
   * unseen file is not counted, so the «add the PDFs in this folder» button
   * simply did not appear, and the library looked complete.
   *
   * And `isFile()`, because a dirent that says no is not a file that says no.
   * libuv's `fs__scandir` tests the reparse bit before the file branch and
   * never looks at the tag, so on Windows every OneDrive file that has not
   * been fetched arrives here as a link — while `stat` calls it a file and
   * `readFile` returns every byte. So anything the listing declines to type
   * is asked again, one `stat` at a time, and only where it matters.
   *
   * Bounded, because this walks a cloud folder: the support folder and the
   * Trash are stepped over whole, dot-folders are not entered, and eight
   * levels is deeper than any library anybody files by hand.
   */
  private async documentFiles(): Promise<string[]> {
    const found: string[] = []
    const skip = new Set([L.SUPPORT_DIR, L.TRASH_DIR])

    const walk = async (folder: string, depth: number): Promise<void> => {
      let entries
      try {
        entries = await fsp.readdir(folder, { withFileTypes: true })
      } catch {
        return
      }
      const deeper: string[] = []
      for (const entry of entries) {
        if (entry.name.startsWith('.') || skip.has(entry.name)) continue
        const full = path.join(folder, entry.name)
        let isDirectory = entry.isDirectory()
        let isFile = entry.isFile()
        // Only the ones the listing declined to type, so a folder on a real
        // disk costs no extra call at all.
        if (!isDirectory && !isFile) {
          try {
            const about = await fsp.stat(full)
            isDirectory = about.isDirectory()
            isFile = about.isFile()
          } catch {
            continue
          }
        }
        if (isDirectory) {
          if (depth < 8) deeper.push(full)
          continue
        }
        if (isFile && entry.name.toLowerCase().endsWith('.pdf')) found.push(full)
      }
      // One level at a time rather than all at once: on a streamed drive each
      // listing is a round trip, and a hundred of them in flight is what the
      // launch path was already taught not to do.
      for (const one of deeper) await walk(one, depth + 1)
    }

    await walk(this.root, 0)
    return found.sort((a, b) => path.basename(a).localeCompare(path.basename(b)))
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

/**
 * A file's digest, remembered for as long as the file has not changed.
 *
 * Finding a paper by its bytes means hashing the PDFs it might be, and a
 * library folder is usually a cloud folder where reading a file is a
 * download. Size and modification time decide whether the last answer still
 * stands, so a folder holding one PDF that matches nothing costs one `stat`
 * per refresh rather than one hash.
 */
const rememberedDigests = new Map<string, { at: string; digest: string }>()

async function digestOfFile(file: string): Promise<string | null> {
  try {
    const stat = await fsp.stat(file)
    const at = `${stat.size}:${stat.mtimeMs}`
    const known = rememberedDigests.get(file)
    if (known?.at === at) return known.digest
    const digest = await sha256(file)
    rememberedDigests.set(file, { at, digest })
    return digest
  } catch {
    return null
  }
}

/**
 * Whether a name could be the name of a file on this desktop.
 *
 * Windows will not hold `?`, `:` or `|` in a file name, so a cloud client
 * hands it the same paper under a name it can hold: `Localized?.pdf` arrives
 * as `Localized_.pdf`. The folder's name is still the one with the `?` in it
 * — this machine is reading a local spelling of it — so writing the local
 * spelling into the shared record would break the Mac the way the Mac's name
 * broke this one, and leave the two rewriting one record forever.
 *
 * On macOS and Linux every Windows name is also a name here, so this answers
 * yes, the repair is written, and the record travels: which is what the Mac
 * has always done.
 */
function nameIsPossibleHere(relative: string): boolean {
  if (process.platform !== 'win32') return true
  // eslint-disable-next-line no-control-regex
  return !/[<>:"|?* -]/.test(relative)
}

/** Which PDFs a set of records speaks for, by the name each one points at. */
export function claimedBy(rows: PaperRow[]): Set<string> {
  return new Set(
    rows
      .map((row) => String((row.meta.file as RawRecord)?.relativePath ?? ''))
      .filter(Boolean),
  )
}
