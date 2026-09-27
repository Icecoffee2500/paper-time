/**
 * The folders that are open, read together into one list.
 *
 * Every folder is a library in its own right — its own `.papertime` beside
 * its own PDFs. The first one is the first one only in the sidebar's order;
 * a paper's records, sidecars and notes live in the folder that holds the
 * paper, and `ownerOf` says which that is.
 */
import fs from 'node:fs'
import path from 'node:path'
import { app } from 'electron'
import type { LibrarySnapshot, NoteDTO, NotesFolderDTO } from '../shared/api.js'
import { PaperMeta, type Collection, type Tag } from '../shared/model.js'
import { findPath, isUnder, samePath } from '../shared/paths.js'
import { L as say } from '../shared/lang.js'
import { Library, claimedBy } from './library.js'
import type { TextSource } from './textIndex.js'
import { mergeVocabulary, missingVocabulary, type FolderVocabulary } from './vocabulary.js'
import { settings, update } from './settings.js'

export interface FolderRead {
  library: Library
  papers: Awaited<ReturnType<Library['read']>>['papers']
  trouble: string[]
  loose: number
  vocabulary: FolderVocabulary
}

export interface SnapshotExtras {
  notes: NoteDTO[]
  notesFolder: NotesFolderDTO
}

export interface LibrarySetHooks {
  /** Whether this run is a probe: a probe remembers nothing. */
  remembers: () => boolean
  /** The slip-box, read with the folders. */
  notes: (folders: string[], folderOfPaper: (id: string) => string | null) => Promise<SnapshotExtras>
  /** After every read: what the text index may be asked about. */
  onRead: (sources: Map<string, TextSource>) => void
}

export class LibrarySet {
  first: Library | null = null
  extras: Library[] = []
  /** Which folder holds a paper, filled in as the list is read. */
  private readonly ownerByID = new Map<string, Library>()
  /** The window's first `library:reload` waits for the launch's open. */
  private opening: Promise<unknown> | null = null

  constructor(private readonly hooks: LibrarySetHooks) {}

  all(): Library[] {
    return this.first ? [this.first, ...this.extras] : []
  }

  get roots(): string[] {
    return this.all().map((one) => one.root)
  }

  /** The folder that holds a paper, and so the one that writes it — or null. */
  async ownerOf(id: string): Promise<Library | null> {
    const known = this.ownerByID.get(id)
    if (known) return known
    for (const one of this.all()) {
      if (await one.paper(id)) {
        this.ownerByID.set(id, one)
        return one
      }
    }
    // No folder has it. Not the first folder: a sidecar written there for a
    // paper it does not hold is a ghost record folder nothing reads back.
    return null
  }

  /** How many papers the last read found. */
  get paperCount(): number {
    return this.ownerByID.size
  }

  forgetPaper(id: string) {
    this.ownerByID.delete(id)
  }

  /** The library a PDF added now goes into: the one asked for when it is open, else the first. */
  destination(root: string | undefined): Library | null {
    if (!this.first) return null
    return (root ? this.all().find((one) => samePath(one.root, root)) : undefined) ?? this.first
  }

  /**
   * Opens the first folder and, through the same door a chosen folder goes
   * through, the folders remembered beside it. All at once, and in the order
   * they were remembered whatever order they answer in: that order is the
   * sidebar's list, and a folder on a cloud drive that has to wake up should
   * not hold up a folder on this machine.
   */
  open(root: string): Promise<void> {
    const work = (async () => {
      this.first = await Library.open(root)
      if (this.hooks.remembers()) rememberLibrary(root)
      const extras = this.hooks.remembers()
        ? (settings().extraRoots ?? []).filter((extra) => !samePath(extra, root))
        : []
      this.extras = (await Promise.all(dedupe(extras).map(async (extra) => {
        // A folder on a disk that is not plugged in is not an error worth
        // stopping the library for; it comes back when the disk does.
        try {
          return await Library.open(extra)
        } catch {
          return null
        }
      }))).filter((one): one is Library => one !== null)
    })()
    this.opening = work
    return work
  }

  /** Another folder, read beside the ones open. Nothing is copied or moved. */
  async attach(root: string): Promise<{ error: string; refused: true } | null> {
    const refusal = folderRefusal(root)
    if (refusal) return { error: refusal, refused: true }
    // Already being read, or inside or around one that is: two libraries over
    // the same files would show every paper twice and write each record from
    // two places.
    const overlapping = this.all().find((one) => isUnder(root, one.root) || isUnder(one.root, root))
    if (overlapping) {
      if (samePath(overlapping.root, root)) return null
      return {
        error: say(
          '이미 연 라이브러리 안에 있거나 그것을 품은 폴더예요.',
          'That folder is inside a library that is already open, or holds one.',
        ),
        refused: true,
      }
    }
    // A folder that cannot take a `.papertime` — a read-only share, one this
    // account may not write — is said, not thrown: the throw reached the
    // window as a rejection nobody caught, and the person saw nothing.
    let opened: Library
    try {
      opened = await Library.open(root)
    } catch {
      return {
        error: say('이 폴더에는 쓸 수 없어서 라이브러리로 열지 못했어요.', "Paper Time can't write to that folder, so it can't open it as a library."),
        refused: true,
      }
    }
    this.extras.push(opened)
    this.rememberExtras()
    return null
  }

  /** Stops reading a folder. Its files and its records stay where they are. */
  detach(root: string) {
    this.extras = this.extras.filter((one) => !samePath(one.root, root))
    for (const [id, owner] of this.ownerByID) if (samePath(owner.root, root)) this.ownerByID.delete(id)
    this.rememberExtras(root)
  }

  /**
   * Which folders are open beside the first — unless this run is a probe.
   * The ones remembered stay remembered even while unplugged: a folder that
   * would not open at launch is not one the reader disconnected.
   */
  private rememberExtras(removed?: string) {
    if (!this.hooks.remembers()) return
    const open = this.extras.map((one) => one.root)
    const stored = settings().extraRoots ?? []
    const kept = dedupe([...stored, ...open]).filter((one) =>
      !(removed && samePath(one, removed)) && !(this.first && samePath(one, this.first.root)))
    update({ extraRoots: kept })
  }

  /**
   * Reads every folder and says what is in it: one read per folder, of its
   * records, its manifest and its collections, and the slip-box with them.
   *
   * `refused` belongs to one press of "add the loose PDFs" and is given here
   * by that handler alone.
   */
  async snapshot(refused: string[] = []): Promise<LibrarySnapshot | { error: string }> {
    if (this.opening) {
      await this.opening.catch(() => undefined)
      this.opening = null
    }
    if (!this.first) return { error: say('열린 라이브러리가 없어요.', 'No library is open.') }
    try {
      const folders = await this.readAll()
      const rows: LibrarySnapshot['papers'] = []
      const unreadable: string[] = []
      let loose = 0
      // Built fresh and swapped in once the read is whole: cleared up front,
      // every save that arrived during a slow read found no owner.
      const owners = new Map<string, Library>()
      const readable = new Map<string, TextSource>()
      for (const folder of folders) {
        unreadable.push(...folder.trouble)
        for (const row of folder.papers) {
          owners.set(row.id, folder.library)
          if (row.file && row.exists) {
            readable.set(row.id, { id: row.id, file: row.file, title: new PaperMeta(row.meta).displayTitle })
          }
          rows.push({ id: row.id, meta: row.meta, state: row.state, exists: row.exists, root: folder.library.root })
        }
        loose += folder.loose
      }
      this.ownerByID.clear()
      for (const [id, one] of owners) this.ownerByID.set(id, one)
      this.hooks.onRead(readable)
      const extras = await this.hooks.notes(folders.map((one) => one.library.root), (id) => owners.get(id)?.root ?? null)
      const vocabulary = await this.settleVocabulary(rows, folders)
      const first = folders[0]
      return {
        root: this.first.root,
        roots: this.roots,
        manifest: { ...first.vocabulary.manifest, tags: vocabulary.tags },
        collections: { ...first.vocabulary.collectionSet, collections: vocabulary.collections },
        papers: rows,
        looseCount: loose,
        unreadable,
        refused,
        notes: extras.notes,
        notesFolder: extras.notesFolder,
      }
    } catch (error) {
      return { error: String((error as Error).message ?? error) }
    }
  }

  /** Every folder at once, each read once. */
  async readAll(): Promise<(FolderRead & { vocabulary: FolderVocabulary & { manifest: Record<string, unknown>; collectionSet: Record<string, unknown> } })[]> {
    return Promise.all(this.all().map(async (one) => {
      const [{ papers, trouble }, manifest, collectionSet] = await Promise.all([one.read(), one.manifest(), one.collections()])
      // A PDF whose record would not be read is not a loose PDF. It is a paper
      // whose record is late, and offering it takes the same paper in a second
      // time: another identifier, none of its marks, both rows on the shelf.
      const free = trouble.length > 0 ? [] : await one.unclaimedFiles(claimedBy(papers))
      return {
        library: one,
        papers,
        trouble,
        loose: free.length,
        vocabulary: {
          root: one.root,
          tags: (manifest.tags ?? []) as Tag[],
          collections: (collectionSet.collections ?? []) as Collection[],
          manifest: manifest as unknown as Record<string, unknown>,
          collectionSet: collectionSet as unknown as Record<string, unknown>,
        },
      }
    }))
  }

  /** Every folder's tags and collections, merged — and each folder given what its papers wear. */
  private async settleVocabulary(rows: LibrarySnapshot['papers'], folders: FolderRead[]) {
    const perFolder = folders.map((one) => one.vocabulary)
    const merged = mergeVocabulary(perFolder)
    const missing = missingVocabulary(
      rows.map((row) => ({
        root: row.root ?? '',
        tagIDs: (row.meta.tagIDs as string[] | undefined) ?? [],
        collectionIDs: (row.meta.collectionIDs as string[] | undefined) ?? [],
      })),
      perFolder,
      merged,
    )
    await fillIn(missing, folders)
    return merged
  }

  /**
   * A paper was just given tags or collections: its folder gets their
   * definitions if only another folder had them. The window no longer reads
   * the library again after a write, and that reading was where this used to
   * happen — without it, a tag put on a paper in a second folder would be a
   * name that folder cannot spell when it is carried to another machine.
   */
  async wear(owner: Library, meta: { tagIDs?: unknown; collectionIDs?: unknown }) {
    if (this.all().length < 2) return
    const tagIDs = Array.isArray(meta.tagIDs) ? meta.tagIDs as string[] : []
    const collectionIDs = Array.isArray(meta.collectionIDs) ? meta.collectionIDs as string[] : []
    if (tagIDs.length === 0 && collectionIDs.length === 0) return
    const folders = await Promise.all(this.all().map(async (library) => {
      const [manifest, collectionSet] = await Promise.all([library.manifest(), library.collections()])
      return {
        library,
        vocabulary: {
          root: library.root,
          tags: (manifest.tags ?? []) as Tag[],
          collections: (collectionSet.collections ?? []) as Collection[],
        },
      }
    }))
    const missing = missingVocabulary(
      [{ root: owner.root, tagIDs, collectionIDs }],
      folders.map((one) => one.vocabulary),
    )
    await fillIn(missing, folders)
  }
}

/** Writes into each folder the definitions it was found to be missing. */
async function fillIn(
  missing: { root: string; tags: Tag[]; collections: Collection[] }[],
  folders: { library: Library; vocabulary: { tags: Tag[]; collections: Collection[] } }[],
) {
  for (const one of missing) {
    const folder = folders.find((entry) => entry.library.root === one.root)
    if (!folder) continue
    if (one.tags.length > 0) {
      await folder.library.saveManifest({ ...(await folder.library.manifest()), tags: [...folder.vocabulary.tags, ...one.tags] })
    }
    if (one.collections.length > 0) {
      await folder.library.saveCollections([...folder.vocabulary.collections, ...one.collections])
    }
  }
}

function rememberLibrary(root: string) {
  const recent = [root, ...settings().recentLibraries.filter((entry) => !samePath(entry, root))].slice(0, 8)
  update({ libraryRoot: root, recentLibraries: recent })
}

function dedupe(roots: string[]): string[] {
  const out: string[] = []
  for (const one of roots) if (!findPath(out, one)) out.push(one)
  return out
}

/**
 * Why a folder the window names is not one to open as a library, or null.
 * The window is a page: what it sends is checked here before anything is
 * written into a folder — a library writes its `.papertime` inside, and the
 * top of a drive or a whole home folder is not somewhere to do that.
 */
export function folderRefusal(root: string | undefined): string | null {
  const no = say('이 폴더는 라이브러리로 열 수 없어요.', "Paper Time can't open that folder as a library.")
  if (!root || typeof root !== 'string' || !path.isAbsolute(root)) return no
  try {
    if (!fs.statSync(root).isDirectory()) return no
  } catch {
    return say('폴더를 찾지 못했어요.', "Paper Time couldn't find that folder.")
  }
  const resolved = path.resolve(root)
  if (samePath(resolved, path.parse(resolved).root) || samePath(resolved, app.getPath('home'))) return no
  return null
}
