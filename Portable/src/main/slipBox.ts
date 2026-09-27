/**
 * Where notes are kept, and which box each one belongs in.
 *
 * The port of the Mac's `SlipBox`, `LooseNotes` and the file half of
 * `NotesModel`. A library folder keeps the notes about its own papers beside
 * them (`.papertime/notes/<id>.md`), so the folder is whole wherever it goes;
 * the app keeps the notes that are about no paper — a loose thought, a map,
 * a draft — in a folder of its own, or in one the reader chose so those
 * follow them between machines too. The boxes are read together, so what the
 * window sees is still one box.
 *
 * Every write is the Mac's: the same bytes into the same file name, so a
 * note written here is that note there, and a folder carried across is not
 * rewritten by the other build the first time it looks at it.
 */
import { noteOwnWrite } from './ownWrites.js'
import { samePath } from '../shared/paths.js'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import * as L from './layout.js'
import { zettelFromText, zettelIsEmpty, zettelText, type Zettel } from '../shared/zettel.js'
import type { NoteDTO, NotesFolderDTO } from '../shared/api.js'

/** One place notes are kept: a library's box, or the loose one. */
/**
 * Whether two folders are one. By the spelling folded as the disk folds it,
 * and then by the disk itself — the same device and file number — for the
 * spellings that still differ (a link, `C:\Users\x` against a mapped
 * drive). Taken for two folders, one «move» copied every note onto itself
 * and then removed it: on Windows, choosing the folder the notes were
 * already in, spelled with a different case, deleted them.
 */
export function sameFolder(a: string, b: string): boolean {
  if (samePath(path.resolve(a), path.resolve(b))) return true
  try {
    const one = fs.statSync(a)
    const other = fs.statSync(b)
    return one.dev === other.dev && one.ino === other.ino && one.ino !== 0
  } catch {
    return false
  }
}

export class SlipBoxFolder {
  /**
   * `id` tells boxes apart and is what a note remembers about where it came
   * from: a library's root for its box, the folder itself for a loose one.
   */
  constructor(readonly id: string, readonly directory: string, readonly chosen = false) {}

  static forLibrary(root: string): SlipBoxFolder {
    return new SlipBoxFolder(root, L.slipBoxDir(root))
  }

  /**
   * Whether the folder is there to be written to. Only a chosen folder can
   * be away — an unplugged disk, a cloud drive signed out of — and one in a
   * trash is away too: a bookmark follows its folder there, and notes
   * written into the trash are notes on their way out.
   */
  isReachable(): boolean {
    if (!this.chosen) return true
    try {
      if (!fs.statSync(this.directory).isDirectory()) return false
    } catch {
      return false
    }
    return !inATrash(this.directory)
  }

  private async files(): Promise<string[]> {
    let entries: string[]
    try {
      entries = await fsp.readdir(this.directory)
    } catch {
      return []
    }
    return entries.filter((name) => !name.startsWith('.') && name.endsWith('.md')).sort()
  }

  async noteIDs(): Promise<string[]> {
    return (await this.files()).map((name) => name.slice(0, -3))
  }

  /** Every note here, newest first. */
  async loadNotes(): Promise<Zettel[]> {
    const notes = await Promise.all((await this.files()).map(async (name) => {
      const file = path.join(this.directory, name)
      try {
        const [text, stat] = await Promise.all([fsp.readFile(file, 'utf8'), fsp.stat(file)])
        return zettelFromText(text, name.slice(0, -3), stat.mtime)
      } catch {
        return null
      }
    }))
    return notes.filter((note): note is Zettel => note !== null).sort((a, b) => b.modified.getTime() - a.modified.getTime())
  }

  noteFile(id: string): string {
    return path.join(this.directory, `${id}.md`)
  }

  /** Writes a note; an empty one takes its file away instead. Throws when a chosen folder is not there. */
  async saveNote(note: Zettel): Promise<void> {
    if (!this.isReachable()) throw new Error(`The notes folder is not there: ${this.directory}`)
    const file = this.noteFile(note.id)
    if (zettelIsEmpty(note)) {
      await fsp.rm(file, { force: true })
      return
    }
    await fsp.mkdir(this.directory, { recursive: true })
    // Beside its own name and then renamed into place: a rename inside one
    // folder is the one move that cannot be caught half-done.
    const temporary = `${file}.${process.pid}.tmp`
    try {
      await fsp.writeFile(temporary, zettelText(note), 'utf8')
      noteOwnWrite(file)
      await fsp.rename(temporary, file)
      noteOwnWrite(file)
    } catch (error) {
      await fsp.rm(temporary, { force: true })
      throw error
    }
  }

  async deleteNote(id: string): Promise<void> {
    await fsp.rm(this.noteFile(id), { force: true })
  }

  /**
   * Takes the notes with it — `LooseNotes.move(into:)`.
   *
   * Every `.md` is copied across and then removed here; a name already taken
   * in the new folder is left alone and kept here, because the one thing that
   * must not happen is writing over a note — unless what is there is this
   * very file, byte for byte, which is a note that has already moved. A
   * chosen folder that is not there is never made here: made again where it
   * used to be, it is a second, empty folder the real one never sees.
   */
  async move(into: SlipBoxFolder): Promise<{ moved: number; kept: number }> {
    if (sameFolder(this.directory, into.directory)) return { moved: 0, kept: 0 }
    const names = await this.files()
    if (names.length === 0) return { moved: 0, kept: 0 }
    if (!into.isReachable()) return { moved: 0, kept: names.length }
    await fsp.mkdir(into.directory, { recursive: true })
    let moved = 0
    let kept = 0
    for (const name of names) {
      const file = path.join(this.directory, name)
      const landing = path.join(into.directory, name)
      try {
        if (fs.existsSync(landing)) {
          if ((await fsp.readFile(file)).equals(await fsp.readFile(landing))) {
            await fsp.rm(file, { force: true })
            moved += 1
          } else {
            kept += 1
          }
          continue
        }
        await fsp.copyFile(file, landing)
        await fsp.rm(file, { force: true })
        moved += 1
      } catch {
        kept += 1
      }
    }
    return { moved, kept }
  }
}

/** Whether a path is inside a desktop's trash — the Mac's, Windows' or a freedesktop one. */
export function inATrash(folder: string): boolean {
  const parts = folder.split(/[\\/]/)
  return parts.some((part, at) =>
    part === '.Trash' || part.toLowerCase() === '$recycle.bin'
    || (part === 'Trash' && parts[at - 1] === 'share' && parts[at - 2] === '.local'))
}

/** A note as it crosses to the window: dates as milliseconds, and the box it is in. */
export function noteDTO(note: Zettel, box: string): NoteDTO {
  return {
    id: note.id, kind: note.kind, title: note.title, body: note.body, paperID: note.paperID,
    created: note.created.getTime(), modified: note.modified.getTime(), box,
  }
}

export function noteFromDTO(dto: NoteDTO): Zettel {
  return {
    id: dto.id, kind: dto.kind, title: dto.title, body: dto.body, paperID: dto.paperID,
    created: new Date(dto.created), modified: new Date(dto.modified),
  }
}

/**
 * The boxes, read together — the file half of the Mac's `NotesModel`.
 *
 * The loose box first, then one per library folder, then whatever a move
 * left behind. A note is read from the first box that has it and written
 * back to the box it came from; a note two boxes hold under one name is
 * never moved between them, since moving one would write over the other.
 * `settle` puts each note where it belongs: the folder of the paper it is
 * about, or the loose box when it is about none.
 *
 * One thing at a time. Reading, settling and writing all touch the same
 * files, and two of them interleaved could write a note into the folder it
 * was just moved out of.
 */
export class NotesStore {
  private loose: SlipBoxFolder
  private readonly appFolder: SlipBoxFolder
  private folders: SlipBoxFolder[] = []
  private leftBehind: SlipBoxFolder[] = []
  /** Which box each note came from, so it goes back to the same one. */
  private boxByNote = new Map<string, string>()
  private sharedNames = new Set<string>()
  /** Set when a note could not be written into the chosen folder and went into the app's own. */
  private wentAway = false
  private folderOfPaper: (paperID: string) => string | null = () => null
  private queue: Promise<unknown> = Promise.resolve()

  /**
   * `chosen` is the folder the reader picked for the notes about no paper,
   * or null for the app's own. Decided before anything is read, so the
   * first reading is of the right box — and a chosen folder that is not
   * there keeps the app's own as the box for this run, without being
   * forgotten.
   */
  constructor(appFolder: string, chosen: string | null) {
    this.appFolder = new SlipBoxFolder(appFolder, appFolder)
    const picked = chosen ? new SlipBoxFolder(chosen, chosen, true) : null
    this.loose = picked?.isReachable() ? picked : this.appFolder
    this.chosenPath = chosen
    try {
      fs.mkdirSync(appFolder, { recursive: true })
    } catch {
      // Written to later, if it can be.
    }
  }

  private chosenPath: string | null

  /** The library folders whose boxes are read, and where each paper is. */
  setFolders(roots: string[], folderOfPaper: (paperID: string) => string | null) {
    this.folders = roots.map((root) => this.folders.find((one) => one.id === root) ?? SlipBoxFolder.forLibrary(root))
    this.folderOfPaper = folderOfPaper
  }

  private boxes(): SlipBoxFolder[] {
    const kept = this.leftBehind.filter((one) => one.id !== this.loose.id)
    return [this.loose, ...this.folders, ...kept]
  }

  private box(id: string): SlipBoxFolder | undefined {
    return this.boxes().find((one) => one.id === id)
  }

  /** Where a note is written: the box it was read from, else the folder of the paper it is about, else the loose box. */
  private boxFor(note: Zettel): SlipBoxFolder {
    const known = this.boxByNote.get(note.id)
    if (known) {
      const found = this.box(known)
      if (found) return found
    }
    if (note.paperID) {
      const root = this.folderOfPaper(note.paperID)
      const folder = root ? this.folders.find((one) => one.id === root) : null
      if (folder) return folder
    }
    return this.loose
  }

  private run<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work)
    this.queue = next.catch(() => undefined)
    return next
  }

  /** Every note, each with the box it is in, settled into the right boxes. */
  load(): Promise<NoteDTO[]> {
    return this.run(async () => {
      const reading = this.boxes()
      const read = await Promise.all(reading.map((box) => box.loadNotes()))
      const loaded = new Map<string, Zettel>()
      const homes = new Map<string, string>()
      const shared = new Set<string>()
      const order: string[] = []
      for (const [at, box] of reading.entries()) {
        for (const note of read[at]) {
          const home = homes.get(note.id)
          const other = loaded.get(note.id)
          if (home !== undefined && other) {
            // Two boxes cannot both own a note. One keeps it and the other
            // copy is left alone — nobody's writing is thrown away to tidy
            // an index. The one that was showing keeps showing; seen for the
            // first time, the newer of the two.
            shared.add(note.id)
            const owner = this.boxByNote.get(note.id)
            const ownerHasIt = owner === home || owner === box.id
            const takesIt = ownerHasIt
              ? owner === box.id && home !== box.id
              : note.modified.getTime() > other.modified.getTime()
            if (takesIt) {
              homes.set(note.id, box.id)
              loaded.set(note.id, note)
            }
            continue
          }
          homes.set(note.id, box.id)
          loaded.set(note.id, note)
          order.push(note.id)
        }
      }
      this.boxByNote = homes
      this.sharedNames = shared
      const notes = order.map((id) => loaded.get(id)!)
      await this.settle(notes)
      return notes.map((note) => noteDTO(note, this.boxByNote.get(note.id) ?? this.loose.id))
    })
  }

  /**
   * Puts each note in the box it belongs to: the folder of the paper it is
   * about, or the loose box when it is about no paper. A note with a paper
   * moves only while that paper's folder is open — a note moved into a
   * folder that is away is a note nobody can see.
   */
  private async settle(notes: Zettel[]): Promise<void> {
    for (const note of notes) {
      if (this.sharedNames.has(note.id)) continue
      const sourceID = this.boxByNote.get(note.id)
      const source = sourceID ? this.box(sourceID) : undefined
      if (!source) continue
      let target: SlipBoxFolder
      if (note.paperID) {
        const root = this.folderOfPaper(note.paperID)
        const folder = root ? this.folders.find((one) => one.id === root) : null
        if (!folder) continue
        target = folder
      } else {
        target = this.loose
      }
      if (target.id === source.id) continue
      try {
        await target.saveNote(note)
      } catch {
        continue
      }
      await source.deleteNote(note.id)
      this.boxByNote.set(note.id, target.id)
    }
  }

  /**
   * Writes one note into the box it belongs to — into the app's own folder
   * when the chosen one refuses it (an unplugged disk, a drive signed out of
   * while the app was open). The note is kept either way, and the next
   * launch carries it across.
   */
  save(dto: NoteDTO): Promise<NoteDTO> {
    return this.run(async () => {
      const note = noteFromDTO(dto)
      let home = this.boxFor(note)
      try {
        await home.saveNote(note)
      } catch (error) {
        if (home.id !== this.loose.id || !this.loose.chosen || this.loose.isReachable()) throw error
        await this.appFolder.saveNote(note)
        home = this.appFolder
        if (!this.leftBehind.some((one) => one.id === this.appFolder.id)) this.leftBehind.push(this.appFolder)
        this.wentAway = true
      }
      if (zettelIsEmpty(note)) this.boxByNote.delete(note.id)
      else this.boxByNote.set(note.id, home.id)
      return noteDTO(note, home.id)
    })
  }

  delete(id: string): Promise<void> {
    return this.run(async () => {
      const known = this.boxByNote.get(id)
      const home = (known ? this.box(known) : undefined) ?? this.loose
      await home.deleteNote(id)
      this.boxByNote.delete(id)
    })
  }

  /**
   * Carries the notes about no paper into another folder and reads them from
   * there. Going to a chosen folder also brings along what is in the app's
   * own — notes that fell back there while the old choice was away. A name
   * already taken in the new folder is not written over: that note stays
   * where it was and is still read from there.
   */
  relocate(to: string | null): Promise<{ moved: number; kept: number }> {
    return this.run(async () => {
      const box = to ? new SlipBoxFolder(to, to, true) : this.appFolder
      this.chosenPath = to
      if (sameFolder(box.directory, this.loose.directory)) return { moved: 0, kept: 0 }
      const old = this.loose
      const first = await this.carry(old, box)
      this.loose = box
      let second = { moved: 0, kept: 0 }
      if (!sameFolder(box.directory, this.appFolder.directory) && !sameFolder(old.directory, this.appFolder.directory)) {
        second = await this.carry(this.appFolder, box)
      }
      this.wentAway = false
      return { moved: first.moved + second.moved, kept: first.kept + second.kept }
    })
  }

  /** Carries into the chosen folder whatever is in the app's own: the notes written while the chosen one could not be reached. */
  catchUp(): Promise<{ moved: number; kept: number }> {
    return this.run(async () => {
      if (this.loose.id === this.appFolder.id) return { moved: 0, kept: 0 }
      return this.carry(this.appFolder, this.loose)
    })
  }

  private async carry(old: SlipBoxFolder, into: SlipBoxFolder): Promise<{ moved: number; kept: number }> {
    const result = await old.move(into)
    const stillThere = new Set(await old.noteIDs())
    for (const [id, home] of this.boxByNote) {
      if (home === old.id && !stillThere.has(id)) this.boxByNote.set(id, into.id)
    }
    this.leftBehind = this.leftBehind.filter((one) => one.id !== into.id && one.id !== old.id)
    if (stillThere.size > 0) this.leftBehind.push(old)
    return result
  }

  /** Where the notes about no paper are, for the settings and the sidebar. */
  info(): NotesFolderDTO {
    return {
      loose: this.loose.directory,
      chosen: this.loose.chosen,
      chosenPath: this.chosenPath,
      appFolder: this.appFolder.directory,
      away: this.chosenPath !== null && !this.loose.chosen || this.wentAway,
      leftBehind: this.leftBehind.filter((one) => one.id !== this.loose.id).map((one) => one.directory),
    }
  }
}
