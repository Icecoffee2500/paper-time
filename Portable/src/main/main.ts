/**
 * The process that owns the files, the window and the menu.
 *
 * Everything platform-specific in this app lives in this file and in
 * `menu.ts`: the window's chrome, where its buttons sit, and what the menu bar
 * is called. The window's contents are the same everywhere by construction —
 * one Chromium, one stylesheet, one bundled typeface — which is the point of
 * porting this way rather than three times.
 */
import { BrowserWindow, app, dialog, ipcMain, nativeTheme, shell } from 'electron'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { CHANNEL, type LibrarySnapshot } from '../shared/api.js'
import { Library, claimedBy, deviceIdentity, readJSON, writeJSON } from './library.js'
import * as L from './layout.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { DEFAULT_EXPORT, formatBibliography } from '../shared/bibtex.js'
import { SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import {
  isOurMark,
  readDrawings,
  readMarks,
  rightsLock,
  stripOwnedForDisplay,
  writeDrawings,
  type MarkupRecord,
  type PageDrawing,
} from './pdfwrite.js'
import { diagnose, headBytes, headLine, looksWhole, type ByteTrouble } from '../shared/pdfLock.js'
import { rememberLibrary, settings, update } from './settings.js'
// `L` is the layout module in this file, so the two-language helper comes
// in under a name of its own.
import { L as say, resolveKorean, setKorean } from '../shared/lang.js'
import { buildMenu } from './menu.js'
import { watchLibrary } from './watcher.js'
import { captureAndQuit, probeArgument, runProbe } from './probe.js'
import { capture as captureWindow, send as sendFeedback } from './feedback.js'

const isMac = process.platform === 'darwin'
/** See `--papertime-chrome` in `preload.ts`. */
const chromeOverride = probeArgument('chrome')
/**
 * Decided here, once, and handed to the window as an argument: the menu is
 * built in this process and the interface in the other, and the two must not
 * answer the question separately and disagree. Settled at `whenReady` because
 * neither the locale nor the settings file is readable before that.
 */
let wantsKorean = false

/** `--papertime-split=1`: the first two papers side by side, for a probe. */
const wantsSplit = probeArgument('split') === '1'

let window: BrowserWindow | null = null
let library: Library | null = null
/**
 * The folders opened beside the first one.
 *
 * Every folder is a library in its own right — its own `.papertime` beside
 * its own PDFs — and they are read together into one list. The first one
 * holds the slip-box, the tags and the collections, because those are about
 * the whole library rather than about a folder.
 */
let extraLibraries: Library[] = []

const allLibraries = (): Library[] => (library ? [library, ...extraLibraries] : [])

/** True when this run was told which folder to open, so it is a probe. */
const isProbeLibrary = () => probeArgument('library') != null

/** Which folders were open beside the first — unless this run is a probe. */
function rememberExtras() {
  if (isProbeLibrary()) return
  update({ extraRoots: extraLibraries.map((one) => one.root) })
}

/** Which folder holds a paper, filled in as the list is read. */
const ownerByID = new Map<string, Library>()

/** The folder that holds a paper, and so the one that writes it. */
async function ownerOf(id: string): Promise<Library | null> {
  const known = ownerByID.get(id)
  if (known) return known
  for (const one of allLibraries()) {
    if (await one.paper(id)) {
      ownerByID.set(id, one)
      return one
    }
  }
  return library
}
let stopWatching: (() => void) | null = null

/** What every window should hear: the library changed, the theme changed. */
function send(event: string, payload?: unknown) {
  for (const target of BrowserWindow.getAllWindows()) {
    if (!target.isDestroyed()) target.webContents.send(CHANNEL.event, event, payload)
  }
}

/** A menu command goes to the window it was meant for — the one in front. */
function sendToFocused(event: string, payload?: unknown) {
  const target = BrowserWindow.getFocusedWindow() ?? window
  target?.webContents.send(CHANNEL.event, event, payload)
}

function sendTo(target: BrowserWindow | null, event: string, payload?: unknown) {
  if (target && !target.isDestroyed()) target.webContents.send(CHANNEL.event, event, payload)
}

// MARK: - The window

interface WindowShape {
  width: number
  height: number
  x?: number
  y?: number
}

/**
 * One window, the library's or a paper's own. Both are the same page with
 * the same chrome; a paper's window is told which paper it is for and shows
 * that paper's reader and nothing else.
 */
function makeWindow(shape: WindowShape, extraArguments: string[] = []): BrowserWindow {
  const made = new BrowserWindow({
    width: shape.width,
    height: shape.height,
    x: shape.x,
    y: shape.y,
    minWidth: 720,
    minHeight: 480,
    show: false,
    title: 'Paper Time',
    // The toolbar is the app's, not the system's, so the frame goes. On a Mac
    // the traffic lights stay where a Mac user reaches for them; on Windows
    // and Linux the window's own buttons are drawn in the toolbar's right end,
    // where those desktops put them. Everything between the two ends is the
    // same pixel for pixel.
    frame: false,
    titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
    trafficLightPosition: isMac ? { x: 14, y: 16 } : undefined,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#202024' : '#ebeced',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      spellcheck: true,
      // The renderer gets its own argv; the app's is not passed down, so the
      // one flag the window needs is handed over explicitly.
      additionalArguments: [
        ...(chromeOverride ? [`--papertime-chrome=${chromeOverride}`] : []),
        `--papertime-lang=${wantsKorean ? 'ko' : 'en'}`,
        ...extraArguments,
      ],
    },
  })

  made.loadFile(path.join(__dirname, '../renderer/index.html'))
  made.once('ready-to-show', () => made.show())
  for (const event of ['maximize', 'unmaximize', 'enter-full-screen', 'leave-full-screen', 'focus', 'blur']) {
    made.on(event as 'maximize', () => sendTo(made, 'window:state', windowState(made)))
  }

  // A page in the reader must never navigate the app away from itself, and a
  // link in a paper belongs in the user's browser, not inside this window.
  made.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  made.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file://')) event.preventDefault()
  })
  return made
}

function createWindow() {
  const saved = settings().window
  window = makeWindow(saved, wantsSplit ? ['--papertime-split=1'] : [])
  if (saved.maximized) window.maximize()

  const remember = () => {
    if (!window || window.isDestroyed()) return
    const bounds = window.getBounds()
    update({ window: { ...bounds, maximized: window.isMaximized() } })
  }
  window.on('resize', remember)
  window.on('move', remember)
  window.on('closed', () => {
    window = null
  })
}

/**
 * A window of its own for one paper, the way a browser tab torn off becomes
 * a window. Put with its top-left corner near the point when there is one —
 * where a drag ended — and beside the main window otherwise.
 */
function createPaperWindow(id: string, at?: { x: number; y: number }) {
  const shape: WindowShape = { width: 900, height: 760 }
  if (at) {
    shape.x = Math.round(at.x - 40)
    shape.y = Math.round(at.y - 20)
  } else if (window && !window.isDestroyed()) {
    const bounds = window.getBounds()
    shape.x = bounds.x + 60
    shape.y = bounds.y + 60
  }
  const made = makeWindow(shape, [`--papertime-paper=${id}`])
  paperWindows.add(made)
  made.on('closed', () => paperWindows.delete(made))
  return made
}

const paperWindows = new Set<BrowserWindow>()

function windowState(target: BrowserWindow | null = window) {
  const live = target && !target.isDestroyed() ? target : null
  return {
    maximized: live?.isMaximized() ?? false,
    fullScreen: live?.isFullScreen() ?? false,
    focused: live?.isFocused() ?? true,
  }
}

/** Every window of ours, in screen points. */
function allBounds() {
  return BrowserWindow.getAllWindows()
    .filter((target) => !target.isDestroyed() && target.isVisible())
    .map((target) => target.getBounds())
}

// MARK: - The library

/** What the last "add the loose PDFs" could not read, by name. */
let refusedLastAdoption: string[] = []

async function snapshot(): Promise<LibrarySnapshot | { error: string }> {
  if (!library) return { error: 'No library is open.' }
  try {
    const rows: LibrarySnapshot['papers'] = []
    let loose = 0
    const unreadableRecords: string[] = []
    ownerByID.clear()
    // Every folder at once, and each folder's loose PDFs worked out from the
    // records just read rather than by reading them all again. One of the
    // folders is often on a cloud drive that has to wake up, and it used to
    // hold up the ones on this machine.
    const folders = allLibraries()
    const read = await Promise.all(folders.map(async (one) => {
      const { papers, trouble } = await one.read()
      // A PDF whose record would not be read is not a loose PDF. It is a paper
      // whose record is late, and offering it takes the same paper in a second
      // time: another identifier, none of its marks, both rows on the shelf.
      // The count waits for a folder that answers in full, and the window says
      // how many records it is waiting on.
      const free = trouble.length > 0 ? [] : await one.unclaimedFiles(claimedBy(papers))
      return { one, papers, loose: free.length, trouble }
    }))
    for (const folder of read) {
      unreadableRecords.push(...folder.trouble)
      for (const row of folder.papers) {
        ownerByID.set(row.id, folder.one)
        rows.push({
          id: row.id,
          meta: row.meta,
          state: row.state,
          exists: row.exists,
          // Which folder it came from: the sidebar groups by this, and
          // nothing else needs to know.
          root: folder.one.root,
        })
      }
      loose += folder.loose
    }
    await settleVocabulary(rows)
    const { tags, collections } = await vocabulary()
    return {
      root: library.root,
      roots: allLibraries().map((one) => one.root),
      manifest: { ...(await library.manifest()), tags },
      collections: { ...(await library.collections()), collections },
      papers: rows,
      looseCount: loose,
      // Records the folders hold and this pass could not read. A count and the
      // names, rather than a silence: one record arriving half written used to
      // take every paper with it and leave a window with nothing to say.
      unreadable: unreadableRecords,
      // …and the ones the last press of that button could not take in.
      refused: refusedLastAdoption,
    }
  } catch (error) {
    return { error: String((error as Error).message ?? error) }
  }
}

/**
 * Every folder's tags and collections, merged into the one list the window
 * shows.
 *
 * A tag and a collection are names the reader gave a shelf, and they are kept
 * in the folder whose papers wear them rather than in one folder for all of
 * them — so a folder carried to another machine arrives with its papers still
 * tagged and still filed. A name two folders use is written in both under the
 * same identifier and shows once here.
 */
async function vocabulary(): Promise<{ tags: Tag[]; collections: Collection[] }> {
  const tags: Tag[] = []
  const seenTags = new Set<string>()
  const collections: Collection[] = []
  const seenCollections = new Set<string>()
  for (const one of allLibraries()) {
    for (const tag of (await one.manifest()).tags ?? []) {
      if (seenTags.has(tag.id)) continue
      seenTags.add(tag.id)
      tags.push(tag)
    }
    for (const collection of (await one.collections()).collections ?? []) {
      if (seenCollections.has(collection.id)) continue
      seenCollections.add(collection.id)
      collections.push(collection)
    }
  }
  // The name breaks a tie, as on the Mac: every folder numbers its own
  // collections from nought.
  collections.sort((a, b) =>
    (a.sortIndex ?? 0) - (b.sortIndex ?? 0) || a.name.localeCompare(b.name))
  return { tags, collections }
}

/**
 * Writes into each folder the tags and collections its own papers wear.
 *
 * A library that was one folder kept all of it in that folder, and a tag put
 * on a paper while its folder was away was written where the paper was not.
 * Both are mended by the same pass, which runs on every read and writes
 * nothing at all once every folder has what it needs.
 */
async function settleVocabulary(rows: LibrarySnapshot['papers']): Promise<void> {
  const libraries = allLibraries()
  if (libraries.length < 2) return
  const { tags, collections } = await vocabulary()
  for (const one of libraries) {
    const mine = rows.filter((row) => row.root === one.root)
    if (mine.length === 0) continue
    const wanted = (key: 'tagIDs' | 'collectionIDs') =>
      new Set(mine.flatMap((row) => (row.meta[key] as string[] | undefined) ?? []))

    const manifest = await one.manifest()
    const has = new Set((manifest.tags ?? []).map((tag) => tag.id))
    const missingTags = tags.filter((tag) => wanted('tagIDs').has(tag.id) && !has.has(tag.id))
    if (missingTags.length > 0) {
      await one.saveManifest({ ...manifest, tags: [...(manifest.tags ?? []), ...missingTags] })
    }

    const set = await one.collections()
    const holds = new Set((set.collections ?? []).map((entry) => entry.id))
    const missing = collections.filter(
      (entry) => wanted('collectionIDs').has(entry.id) && !holds.has(entry.id),
    )
    if (missing.length > 0) {
      await one.saveCollections([...(set.collections ?? []), ...missing])
    }
  }
}

async function openLibrary(root: string) {
  stopWatching?.()
  library = await Library.open(root)
  if (!isProbeLibrary()) rememberLibrary(root)
  // All of them at once, and in the order they were remembered whatever
  // order they answer in: that order is the sidebar's list of libraries, and
  // a folder on a cloud drive that has to wake up should not hold up a folder
  // on this machine.
  const extras = (settings().extraRoots ?? []).filter((extra) => extra !== root)
  extraLibraries = (await Promise.all(extras.map(async (extra) => {
    // A folder on a disk that is not plugged in is not an error worth
    // stopping the library for; it comes back when the disk does.
    try { return await Library.open(extra) } catch { return null }
  }))).filter((one): one is Library => one !== null)
  startWatchingFolders()
  return snapshot()
}

let extraWatchers: (() => void)[] = []

/** One watcher per folder: a PDF dropped into any of them is a paper here. */
function startWatchingFolders() {
  stopWatching?.()
  for (const stop of extraWatchers) stop()
  extraWatchers = []
  const roots = allLibraries().map((one) => one.root)
  stopWatching = roots[0] ? watchLibrary(roots[0], () => void folderDidChange()) : null
  for (const root of roots.slice(1)) {
    extraWatchers.push(watchLibrary(root, () => void folderDidChange()))
  }
}

/**
 * One settling at a time, and every fire gets its own.
 *
 * The watcher fires in bursts and adopting writes records, which fires it
 * again: two passes running together would write two records for one file,
 * and a pass that simply dropped the fires arriving while it ran would miss
 * the paper that landed a moment after it looked. So they queue.
 */
let settling: Promise<void> | null = null

/**
 * Brings the library back in line with the folder.
 *
 * A PDF that appears in a library folder is a paper in that library — that
 * is what choosing a folder means — so it is taken in rather than left
 * behind a button. The Mac has done this since it had folders
 * (`LibraryModel.folderDidChange`), and this side did not: a paper
 * downloaded into the folder on Windows became `+1` on the count of a button
 * beside a list of a hundred and sixty rows, which is the same as not
 * appearing at all. Two builds reading one folder have to agree about what
 * arriving in it means.
 *
 * Nothing is moved, renamed or rewritten: the file stays where it landed and
 * only the record beside it is new. Each folder takes in its own.
 *
 * Papers that were sitting in the folder when it was first opened are a
 * different matter and still wait to be offered, because the user has not yet
 * said that folder full of PDFs is their library — so nothing is taken in
 * while the library is empty.
 */
function folderDidChange(): Promise<void> {
  settling = (settling ?? Promise.resolve()).then(settleFolder)
  return settling
}

async function settleFolder(): Promise<void> {
  try {
    const read = await Promise.all(allLibraries().map(async (one) => {
      const { papers, trouble } = await one.read()
      // Taking a PDF in on the app's own account is only safe when every
      // record answered, because the check for one already here is a check
      // against the records. Nothing is lost by waiting: this runs again on
      // the next change to the folder, and on every reload.
      const unclaimed = trouble.length > 0 ? [] : await one.unclaimedFiles(claimedBy(papers))
      return { one, papers, unclaimed }
    }))
    const empty = read.every((folder) => folder.papers.length === 0)
    if (!empty) {
      for (const folder of read) {
        for (const file of folder.unclaimed) {
          // A file still coming down the cloud drive is not a paper yet.
          // Reading it is what makes Windows fetch a placeholder, so this
          // both waits for it and pulls it; what is still short after that
          // is left for the next time the folder settles.
          if (!looksWhole(await readWhole(file))) continue
          await folder.one.importPDF(file, await pageCount(file))
        }
      }
    }
  } catch {
    // A folder that cannot be read right now — a disk unplugged, a cloud
    // drive asleep — is not a reason to stop telling the window.
  }
  send('library:changed')
}

// MARK: - Requests

/** A request, with the window that made it — dialogs hang off that one. */
type Handler = (args: never, sender: BrowserWindow | null) => unknown | Promise<unknown>

/**
 * The file, read until all of it is there.
 *
 * `fs.promises.readFile` resolves with a short buffer and throws nothing —
 * measured, 32 MB back from a 96 MB file with no error — and on a cloud
 * folder that is the ordinary way to meet a paper that is still coming down.
 * The Mac has `FileOperations.ensureDownloaded` for this. Node has no
 * cloud-filter API at all, and what makes Windows and Google Drive fetch a
 * placeholder is reading it, so reading again is the whole of the remedy.
 *
 * Bounded, and only for the troubles that reading again can cure. A file
 * somebody is still writing would otherwise hold this open for ever, and a
 * container or a sign-in page will read the same however many times it is
 * asked. A whole file costs one read and no wait.
 */
const READ_AGAIN: ReadonlySet<ByteTrouble> = new Set(['cut', 'placeholder', 'empty'] as ByteTrouble[])

async function readWhole(file: string): Promise<Uint8Array> {
  let bytes = await fsp.readFile(file)
  for (let attempt = 1; attempt < 6; attempt += 1) {
    if (looksWhole(bytes)) break
    const trouble = diagnose(bytes)
    if (!trouble || !READ_AGAIN.has(trouble)) break
    await new Promise((resolve) => setTimeout(resolve, 250))
    bytes = await fsp.readFile(file)
  }
  return bytes
}

const handlers: Record<string, Handler> = {
  // The effective root, not the remembered one: a probe run opens a folder
  // of its own and the window must be told about that one.
  'settings:get': () => ({ ...settings(), libraryRoot: library?.root ?? settings().libraryRoot }),
  'settings:set': ((patch: Record<string, unknown>) => update(patch)) as Handler,

  'library:choose': async (_args: never, sender: BrowserWindow | null) => {
    const result = await dialog.showOpenDialog(sender ?? window!, {
      title: 'Choose your library folder',
      message: 'Pick the folder your papers live in — a cloud folder works, and is how a library follows you between machines.',
      properties: ['openDirectory', 'createDirectory'],
      buttonLabel: 'Use This Folder',
    })
    if (result.canceled || result.filePaths.length === 0) return null
    return result.filePaths[0]
  },

  'library:open': (async ({ root }: { root: string }) => openLibrary(root)) as Handler,
  'library:reload': async () => snapshot(),

  'library:import': (async ({ paths }: { paths?: string[] }, sender: BrowserWindow | null) => {
    if (!library) return { error: 'No library is open.' }
    let chosen = paths
    if (!chosen || chosen.length === 0) {
      const result = await dialog.showOpenDialog(sender ?? window!, {
        title: 'Add PDFs',
        message: 'Choose PDFs to add to the library',
        filters: [{ name: 'PDF', extensions: ['pdf'] }],
        properties: ['openFile', 'multiSelections'],
      })
      if (result.canceled) return snapshot()
      chosen = result.filePaths
    }
    for (const file of chosen) {
      await library.importPDF(file, await pageCount(file))
    }
    return snapshot()
  }) as Handler,

  'library:adoptLoose': async () => {
    if (!library) return { error: 'No library is open.' }
    // Each folder takes in its own: adopting a PDF must never move it to
    // another folder.
    //
    // One file at a time, and a file that will not be read does not take the
    // rest of the folder with it: this loop used to throw on the first
    // unreadable PDF, so two hundred good papers waited behind one bad one and
    // the window was told nothing at all.
    refusedLastAdoption = []
    for (const one of allLibraries()) {
      for (const file of await one.looseFiles()) {
        try {
          await one.importPDF(file, await pageCount(file))
        } catch {
          refusedLastAdoption.push(path.basename(file))
        }
      }
    }
    return snapshot()
  },

  // Another folder, read beside the ones already open. Nothing is copied or
  // moved: it keeps its own `.papertime`, so disconnecting leaves it exactly
  // as it was.
  'library:addFolder': (async ({ root }: { root?: string }, sender: BrowserWindow | null) => {
    let chosen = root
    if (!chosen) {
      const result = await dialog.showOpenDialog(sender ?? window!, {
        title: 'Add a folder',
        message: 'Choose another folder to read beside this one. Its papers join the same list, and nothing is moved.',
        properties: ['openDirectory', 'createDirectory'],
        buttonLabel: 'Open This Folder Too',
      })
      if (result.canceled || result.filePaths.length === 0) return snapshot()
      chosen = result.filePaths[0]
    }
    if (!library || chosen === library.root) return snapshot()
    if (extraLibraries.some((one) => one.root === chosen)) return snapshot()
    extraLibraries.push(await Library.open(chosen))
    rememberExtras()
    startWatchingFolders()
    return snapshot()
  }) as Handler,

  /** Stops reading a folder. Its files and its records stay where they are. */
  'library:removeFolder': (async ({ root }: { root: string }) => {
    extraLibraries = extraLibraries.filter((one) => one.root !== root)
    rememberExtras()
    startWatchingFolders()
    return snapshot()
  }) as Handler,

  'library:trash': (async ({ id }: { id: string }) => {
    await (await ownerOf(id))?.trashPaper(id)
    return snapshot()
  }) as Handler,

  'paper:bytes': (async ({ id }: { id: string }) => {
    // Nothing in here throws. A rejected request reaches the window as an
    // unhandled rejection, which is a blank page with nothing said on it —
    // which is where the whole of this began.
    try {
      const row = await (await ownerOf(id))?.paper(id)
      if (!row?.file || !row.exists) return { error: 'The PDF for this paper is not in the folder.' }
      const bytes = await readWhole(row.file)
      const trouble = diagnose(bytes)
      const lock = await rightsLock(bytes)
      if (lock) return { locked: lock }
      // The diagnosis is never a door. pdf.js reads more than anything here
      // does — it opens a paper with four kilobytes of a filter's banner glued
      // to the front, and one whose last kilobytes are gone — so the bytes
      // always go to it, and what was found only chooses the sentence if it
      // fails. Refusing them was a regression the moment it was written:
      // papers that opened before it stopped opening.
      const about = { trouble, size: bytes.length, head: headBytes(bytes), line: headLine(bytes) }
      try {
        return { data: await stripOwnedForDisplay(bytes), ...about }
      } catch (error) {
        // Our own annotations could not be taken out, which is no reason to
        // refuse the file — pdf.js parses more than pdf-lib does. It is handed
        // the bytes as they are, ours included. The trouble goes through
        // exactly as diagnosed: a whole file that pdf-lib choked on is not a
        // file that is still arriving, and calling it one told somebody that
        // 1.6 MB of a 1.6 MB file had turned up.
        console.error('paper:bytes - reading the annotations failed, showing the file as it is:', error)
        return { data: bytes, ...about }
      }
    } catch (error) {
      console.error('paper:bytes -', error)
      return { error: 'The PDF for this paper could not be read.' }
    }
  }) as Handler,

  'paper:state': (async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => {
    const owner = await ownerOf(id)
    if (!owner) return null
    const row = await owner.paper(id)
    const state = new PaperState(row?.state ?? {})
    // A patch crosses the bridge as JSON, so its dates arrive as strings.
    Object.assign(state, patch, {
      lastOpenedAt: patch.lastOpenedAt ? new Date(String(patch.lastOpenedAt)) : state.lastOpenedAt,
    })
    const saved = await owner.saveState(id, state)
    return saved.encode()
  }) as Handler,

  'paper:meta': (async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => {
    const owner = await ownerOf(id)
    if (!owner) return null
    const row = await owner.paper(id)
    if (!row) return null
    const meta = new PaperMeta(row.meta)
    Object.assign(meta, patch)
    await owner.saveMeta(meta)
    return meta.encode()
  }) as Handler,

  // Renaming the file, from the inspector. The reader may have it open: the
  // window is told, and re-reads the paper from its new name.
  'paper:rename': (async ({ id, name }: { id: string; name: string }) => {
    const owner = await ownerOf(id)
    if (!owner) return { error: 'missing' }
    const result = await owner.rename(id, name)
    if ('error' in result) return result
    send('library:changed')
    return { name: result.file ? path.basename(result.file) : name }
  }) as Handler,

  'paper:reveal': (async ({ id }: { id: string }) => {
    const row = await (await ownerOf(id))?.paper(id)
    if (row?.file) shell.showItemInFolder(row.file)
  }) as Handler,

  'sketch:load': (async ({ id, pageIndex }: { id: string; pageIndex: number }) =>
    (await ownerOf(id))?.loadSketch(id, pageIndex) ?? null) as Handler,

  'sketch:save': (async ({ id, pageIndex, elements }: { id: string; pageIndex: number; elements: unknown[] }) => {
    await (await ownerOf(id))?.saveSketch(id, pageIndex, elements)
    schedulePDFWrite(id)
  }) as Handler,

  'ink:load': (async ({ id, pageIndex }: { id: string; pageIndex: number }) =>
    (await ownerOf(id))?.loadInk(id, pageIndex) ?? null) as Handler,

  'ink:save': (async ({ id, pageIndex, strokes }: { id: string; pageIndex: number; strokes: unknown[] }) => {
    if (!library) return
    await library.saveInk(id, pageIndex, strokes)
    await supersedeAppleInk(id, pageIndex)
    schedulePDFWrite(id)
  }) as Handler,

  'marks:load': (async ({ id }: { id: string }) => {
    const row = await (await ownerOf(id))?.paper(id)
    if (!row?.file || !row.exists) return {}
    const found = await readMarks(await fsp.readFile(row.file))
    const out: Record<number, MarkupRecord[]> = {}
    for (const [pageIndex, marks] of found) out[pageIndex] = marks
    // Held here too, so a save that only touched the pen can put every page's
    // marks back exactly as they were.
    marksInMemory.set(id, out)
    return out
  }) as Handler,

  'marks:save': (async ({ id, pageIndex, marks }: { id: string; pageIndex: number; marks: MarkupRecord[] }) => {
    const pages = marksInMemory.get(id) ?? {}
    pages[pageIndex] = marks
    marksInMemory.set(id, pages)
    await noteMarksInJournal(id, marks)
    schedulePDFWrite(id)
  }) as Handler,

  'drawing:pages': (async ({ id }: { id: string }) =>
    (await ownerOf(id))?.annotatedPages(id) ?? { sketch: [], ink: [], appleInk: [] }) as Handler,

  'drawing:adoptFromFile': (async ({ id }: { id: string }) => adoptFromFile(id)) as Handler,

  'drawing:flush': (async ({ id }: { id: string }) => flushToPDF(id)) as Handler,

  'bibtex:export': (async ({ ids }: { ids?: string[] }, sender: BrowserWindow | null) => {
    if (!library) return { error: 'No library is open.' }
    const { papers: rows, trouble } = await library.read()
    const chosen = ids && ids.length > 0 ? rows.filter((row) => ids.includes(row.id)) : rows
    if (chosen.length === 0) return { error: 'There is nothing to export.' }
    // A list that is short by a paper is a list; a bibliography that is short
    // by a paper is a file that looks complete with a citation missing from
    // it, found by LaTeX weeks later. So the one place that will not carry on
    // with a folder read in part is this one — unless every paper that was
    // asked for is in hand, which is the ordinary case of exporting a
    // selection out of a library whose late record is somewhere else.
    if (trouble.length > 0 && chosen.length !== (ids?.length ?? -1)) {
      return {
        error: say(
          `기록 ${trouble.length}개가 아직 안 와서 지금 내보내면 빠지는 논문이 있어요.`,
          `${trouble.length} record${trouble.length === 1 ? '' : 's'} `
            + `${trouble.length === 1 ? "hasn't" : "haven't"} arrived, so this export would be short.`,
        ),
      }
    }
    const text = formatBibliography(chosen.map((row) => new PaperMeta(row.meta)), DEFAULT_EXPORT)
    const result = await dialog.showSaveDialog(sender ?? window!, {
      title: 'Export BibTeX',
      defaultPath: `${path.basename(library.root)}.bib`,
      filters: [{ name: 'BibTeX', extensions: ['bib'] }],
    })
    if (result.canceled || !result.filePath) return { cancelled: true }
    await fsp.writeFile(result.filePath, text, 'utf8')
    return { written: chosen.length, path: result.filePath }
  }) as Handler,

  // The window sends the whole list; it is put back folder by folder. Each
  // folder keeps the collections it already had, and a new one goes into the
  // first — the folder a paper added now would go into.
  'collections:save': (async ({ collections }: { collections: unknown[] }) => {
    const all = collections as Collection[]
    const libraries = allLibraries()
    if (libraries.length === 0) return null
    const known = new Set<string>()
    const held: { one: (typeof libraries)[number]; ids: Set<string> }[] = []
    for (const one of libraries) {
      const ids = new Set(((await one.collections()).collections ?? []).map((entry) => entry.id))
      for (const id of ids) known.add(id)
      held.push({ one, ids })
    }
    for (const [index, { one, ids }] of held.entries()) {
      const mine = all.filter((entry) => ids.has(entry.id) || (index === 0 && !known.has(entry.id)))
      if (mine.length === 0 && ids.size === 0) continue
      await one.saveCollections(mine)
    }
    return null
  }) as Handler,

  'window:minimize': (_args: never, sender: BrowserWindow | null) => (sender ?? window)?.minimize(),
  'window:toggleMaximize': (_args: never, sender: BrowserWindow | null) => {
    const target = sender ?? window
    if (target?.isMaximized()) target.unmaximize()
    else target?.maximize()
  },
  'window:close': (_args: never, sender: BrowserWindow | null) => (sender ?? window)?.close(),
  'window:state': (_args: never, sender: BrowserWindow | null) => windowState(sender ?? window),
  'window:bounds': () => allBounds(),
  'paper:openWindow': (({ id, x, y }: { id: string; x?: number; y?: number }) => {
    createPaperWindow(id, typeof x === 'number' && typeof y === 'number' ? { x, y } : undefined)
  }) as Handler,
  // The app speaks to the outside world here and nowhere else, and only
  // because somebody pressed 보내기.
  'feedback:capture': (_args: never, sender: BrowserWindow | null) => captureWindow(sender ?? window),
  'feedback:send': ((report: {
    kind: 'bug' | 'wish'
    body: string
    name: string
    reply?: string | null
    shot?: string | null
  }) =>
    sendFeedback({
      ...report,
      context: {
        window: window && !window.isDestroyed()
          ? `${window.getBounds().width}×${window.getBounds().height}`
          : undefined,
        layout: settings().pageLayout,
        paperCount: library?.papers.length,
        libraryCloud: undefined,
        recent: [],
      },
    })) as Handler,

  'shell:openExternal': (({ url }: { url: string }) => {
    if (/^https?:/.test(url)) shell.openExternal(url)
  }) as Handler,
}

ipcMain.handle(CHANNEL.invoke, async (event, name: string, args: unknown) => {
  const handler = handlers[name]
  if (!handler) throw new Error(`Unknown request: ${name}`)
  return handler(args as never, BrowserWindow.fromWebContents(event.sender))
})

// MARK: - The file, written behind the reader

/**
 * How long after the last stroke the PDF itself is rewritten.
 *
 * The sidecar is saved the moment a gesture ends, so nothing is ever at risk.
 * Rewriting a twenty-megabyte file on every stroke, though, is how an app
 * starts stuttering under a pen — the same reason the Mac waits 1.5 seconds
 * before reconciling marks into the file.
 */
const PDF_WRITE_DELAY = 1500
const pending = new Map<string, NodeJS.Timeout>()

/**
 * Every page's marks for the papers that are open.
 *
 * Marks live in the PDF and nowhere else — that is how a highlight made here
 * shows up in Preview — so a save has to put back the pages it is not
 * changing as well as the one it is. Read once when the paper opens, kept
 * here, written whole.
 */
const marksInMemory = new Map<string, Record<number, MarkupRecord[]>>()

function schedulePDFWrite(id: string) {
  clearTimeout(pending.get(id))
  pending.set(id, setTimeout(() => {
    pending.delete(id)
    flushToPDF(id).catch((error) => send('error', String(error)))
  }, PDF_WRITE_DELAY))
}

async function flushToPDF(id: string): Promise<{ written: number } | { error: string }> {
  if (!library) return { error: 'No library is open.' }
  const row = await library.paper(id)
  if (!row?.file || !row.exists) return { error: 'The PDF is not where the record says it is.' }
  try {
    const pages = await library.annotatedPages(id)
    const marks = marksInMemory.get(id) ?? {}
    const inFile = await readDrawings(await fsp.readFile(row.file))
    // Every page that has anything of ours on it, or had something on it that
    // has since been rubbed out and must now come out of the file too.
    const indices = [...new Set([
      ...pages.sketch,
      ...pages.ink,
      ...Object.keys(marks).map(Number),
      ...inFile.keys(),
    ])].sort((a, b) => a - b)
    const drawings: PageDrawing[] = []
    for (const pageIndex of indices) {
      const elements = ((await library.loadSketch(id, pageIndex)) ?? []).map(SketchElement.from)
      const strokes = ((await library.loadInk(id, pageIndex)) ?? []).map(InkStroke.from)
      const pageMarks = marks[pageIndex]
      drawings.push({
        pageIndex,
        elements,
        strokes,
        // Only the marks this app made are ours to rewrite; one that was in
        // the file when it arrived stays where it is, untouched.
        marks: pageMarks?.filter(isOurMark),
        managesMarks: pageMarks !== undefined,
      })
    }
    if (drawings.length === 0) return { written: 0 }
    const bytes = await writeDrawings(await fsp.readFile(row.file), drawings)
    await writeAtomically(row.file, bytes)
    send('paper:saved', { id })
    return { written: drawings.length }
  } catch (error) {
    return { error: String((error as Error).message ?? error) }
  }
}

/**
 * Replaces a PDF without ever leaving it half-written.
 *
 * The user's papers are the one thing in this app that cannot be regenerated,
 * and a PDF is rewritten whole. Temporary file, then rename over the original.
 */
async function writeAtomically(file: string, bytes: Uint8Array) {
  const temporary = `${file}.${process.pid}.tmp`
  await fsp.writeFile(temporary, bytes)
  await fsp.rename(temporary, file)
}

/**
 * Builds sidecars for a paper whose drawing is only in the PDF.
 *
 * That is what a paper annotated on a Mac looks like the first time it is
 * opened here: the shapes are in the file, carrying their own JSON in
 * `/PTSketch`, and the pen's strokes are ordinary ink annotations. Both come
 * across; what does not is the pressure in the Mac's `.drawing`, which no
 * format but PencilKit's own can hold.
 */
async function adoptFromFile(id: string) {
  if (!library) return { pages: {}, unreadable: [] as number[] }
  const row = await library.paper(id)
  if (!row?.file || !row.exists) return { pages: {}, unreadable: [] as number[] }
  const found = await readDrawings(await fsp.readFile(row.file))
  const pages: Record<number, { elements: unknown[]; strokes: unknown[] }> = {}
  for (const [pageIndex, drawing] of found) {
    // Shapes are lossless in the file — the annotation carries the element's
    // own JSON — so a sidecar built from it is exactly the sidecar the Mac
    // had, and worth writing.
    if (!(await library.loadSketch(id, pageIndex)) && drawing.elements.length > 0) {
      await library.saveSketch(id, pageIndex, drawing.elements.map((e) => e.encode()))
    }
    // Ink is not. The strokes in the file have one width each, where the
    // Mac's `.drawing` still holds the pressure at every point. They are
    // handed to the window to *show* — a reader must see the handwriting on
    // the page — but no sidecar is written for them, because writing one
    // would be this machine claiming a page it has not been asked to touch.
    pages[pageIndex] = {
      elements: drawing.elements.map((e) => e.encode()),
      strokes: drawing.strokes.map((s) => s.encode()),
    }
  }

  // A page whose handwriting exists only as PencilKit's own file, which no
  // format outside Apple's frameworks can read. Rather than quietly showing a
  // page with the writing missing, the window is told which pages they are.
  const unreadable: number[] = []
  const pageList = await library.annotatedPages(id)
  for (const pageIndex of pageList.appleInk) {
    if (await library.loadInk(id, pageIndex)) continue
    if ((found.get(pageIndex)?.strokes.length ?? 0) > 0) continue
    unreadable.push(pageIndex)
  }
  return { pages, unreadable }
}

/**
 * Moves the Mac's PencilKit sidecar aside once this machine has drawn on that
 * page.
 *
 * Both sidecars would otherwise claim the same page and the two machines would
 * show different things: the Mac reads its `.drawing` in preference to the
 * file, so it would keep showing the page as it was before the pen touched it
 * here. Renamed rather than deleted — the pressure in it is the user's work,
 * and nothing in this app deletes that. With the `.drawing` out of the way the
 * Mac falls back to the ink in the PDF, which is what both sides now agree on.
 */
async function supersedeAppleInk(id: string, pageIndex: number) {
  if (!library) return
  const file = L.appleInkPath(library.root, id, pageIndex)
  if (!fs.existsSync(file)) return
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  await fsp.rename(file, `${file}.superseded-${stamp}`)
}

/**
 * Records in this device's journal that it made these marks.
 *
 * The journal is the fast path between machines: the PDF is the durable
 * record and is rewritten a second or so later, but a small file naming what
 * this device just did lands in the synced folder immediately. The Mac writes
 * the same shape — a device name and a map of mark id to when it was made —
 * and reconciles from it.
 */
async function noteMarksInJournal(id: string, marks: MarkupRecord[]) {
  if (!library) return
  const file = L.marksPath(library.root, id, deviceIdentity)
  const existing = (await readJSON(file)) ?? {}
  const entries = (existing.entries as Record<string, unknown>) ?? {}
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  for (const mark of marks) {
    if (!isOurMark(mark)) continue
    if (!entries[mark.id]) entries[mark.id] = { at: now }
  }
  await writeJSON(file, {
    ...existing,
    device: deviceIdentity,
    name: process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : 'Mac',
    entries,
    updated: now,
  })
}

/** How many pages a PDF has, read without rendering it. */
async function pageCount(file: string): Promise<number> {
  try {
    const { PDFDocument } = await import('pdf-lib')
    const document = await PDFDocument.load(await fsp.readFile(file), {
      ignoreEncryption: true,
      updateMetadata: false,
    })
    return document.getPageCount()
  } catch {
    return 0
  }
}

// MARK: - Launch

// Windows groups taskbar buttons and notifications by this, not by the
// executable's name. Without it a pinned Paper Time and a running Paper Time
// are two different buttons.
if (process.platform === 'win32') app.setAppUserModelId('com.imtaeheon.PaperTime')

/**
 * Wayland, when the session is Wayland.
 *
 * Electron still defaults to X11 through XWayland, which on a fractional-scale
 * display means a blurred window and a pen whose coordinates are a scale
 * factor out — on a drawing app, the second one is fatal. The hint uses
 * Wayland where the session offers it and falls back to X11 where it does not.
 */
if (process.platform === 'linux' && !app.commandLine.hasSwitch('ozone-platform-hint')) {
  app.commandLine.appendSwitch('ozone-platform-hint', 'auto')
}

app.whenReady().then(async () => {
  wantsKorean = resolveKorean(settings().language, app.getLocale())
  setKorean(wantsKorean)
  createWindow()
  buildMenu({
    send: sendToFocused,
    chooseLibrary: async () => {
      const chosen = await handlers['library:choose'](undefined as never, window)
      if (typeof chosen === 'string') {
        await openLibrary(chosen)
        send('library:opened', await snapshot())
      }
    },
  })
  // `--papertime-library=<path>` opens a folder without disturbing whichever
  // one the user last had open — the same isolation the Mac build uses so a
  // test never touches a real library.
  const root = probeArgument('library') ?? settings().libraryRoot
  if (root && fs.existsSync(root)) {
    if (isProbeLibrary()) {
      // A probe opens its own folder and remembers nothing — not the folder,
      // and not the ones beside it, which belong to whoever uses this copy.
      library = await Library.open(root)
      extraLibraries = []
      startWatchingFolders()
    } else {
      // Through the same door a chosen folder goes through, so the folders
      // opened beside it come back too. They did not, for a while: the
      // library was opened here and the extras only in `openLibrary`, so
      // every launch forgot them.
      await openLibrary(root)
    }
    send('library:opened', await snapshot())
  }
  nativeTheme.on('updated', () => send('theme:changed', nativeTheme.shouldUseDarkColors))

  const probe = probeArgument('probe')
  const shot = probeArgument('shot')
  if (probe && window) void runProbe(window, probe)
  else if (shot && window) void captureAndQuit(window, shot)
})

app.on('window-all-closed', () => {
  if (!isMac) app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})

/** Papers dropped on the app's icon, or opened from a file manager. */
app.on('open-file', async (event, file) => {
  event.preventDefault()
  if (!library) return
  await library.importPDF(file, await pageCount(file))
  send('library:changed')
})

export { deviceIdentity, readJSON, writeJSON }
