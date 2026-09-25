/**
 * The process that owns the files, the window and the menu.
 *
 * Everything platform-specific in this app lives in this file and in
 * `menu.ts`: the window's chrome, where its buttons sit, and what the menu bar
 * is called. The window's contents are the same everywhere by construction —
 * one Chromium, one stylesheet, one bundled typeface — which is the point of
 * porting this way rather than three times.
 */
import {
  BrowserWindow, app, dialog, ipcMain, nativeTheme, screen, shell, utilityProcess,
  type UtilityProcess, type WebContents,
} from 'electron'
import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { Worker } from 'node:worker_threads'
import { CHANNEL, type LibrarySnapshot } from '../shared/api.js'
import { Library, claimedBy, deviceIdentity, readJSON, writeJSON } from './library.js'
import * as L from './layout.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { DEFAULT_EXPORT, formatBibliography } from '../shared/bibtex.js'
import { SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import {
  WriteRefused,
  isOurMark,
  keptReason,
  readDrawings,
  readMarks,
  rightsLock,
  stripOwnedForDisplay,
  writeDrawingsDetailed,
  writeRefusal,
  type KeptReason,
  type MarkupRecord,
  type PageDrawing,
} from './pdfwrite.js'
import {
  freshJournal,
  merged,
  reconcile,
  recordChanges,
  upgradeLegacy,
  type Held,
  type Journal,
} from '../shared/markJournal.js'
import { isoTimestamp } from '../shared/coding.js'
import { diagnose, headBytes, headLine, looksWhole, type ByteTrouble } from '../shared/pdfLock.js'
import { holdInMemory, rememberLibrary, settings, update } from './settings.js'
// `L` is the layout module in this file, so the two-language helper comes
// in under a name of its own.
import { L as say, resolveKorean, setKorean } from '../shared/lang.js'
import { buildMenu } from './menu.js'
import { watchLibrary } from './watcher.js'
import { captureAndQuit, probeArgument, runProbe } from './probe.js'
import { capture as captureWindow, send as sendFeedback } from './feedback.js'
import type { ServiceReply, ServiceStats } from './textService.js'
import type { TextSource } from './textIndex.js'
import { SemanticSearch, type NoteSource } from './semantic.js'

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

/**
 * True for any run that is only being looked at: one given a folder, a list of
 * steps, or a picture to take.
 *
 * Such a run must never come in front of what the person at this machine is
 * doing. `BrowserWindow.show()` on a Mac **activates the app** — the window
 * rises over their work and takes the keyboard — which is the thing the Mac
 * build's `Scripts/probe.sh` exists to prevent, and this build had no guard
 * against it at all.
 */
const isProbeRun = () => ['library', 'probe', 'shot'].some((name) => probeArgument(name) != null)

// Nor write anything into their settings: a probe that opens a paper or picks
// an inspector tab is not the person choosing one.
if (isProbeRun()) holdInMemory()

/**
 * A place no display covers: right of the rightmost one, level with the
 * highest. The union of every display rather than the primary one, because a
 * second monitor to the left or above has real pixels at negative coordinates.
 * The window draws and can be captured there like anywhere else; nobody sees it.
 */
function offscreen(width: number): { x: number; y: number } {
  const displays = screen.getAllDisplays().map((one) => one.bounds)
  const right = Math.max(...displays.map((one) => one.x + one.width))
  const top = Math.min(...displays.map((one) => one.y))
  return { x: right + Math.max(width, 400), y: top }
}

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
      // A probe's window sits outside every display, where Chromium counts it
      // as hidden and slows its timers and frames to a crawl — which would
      // make every timing a probe takes a timing of the throttle. Only then.
      backgroundThrottling: !isProbeRun(),
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
  made.once('ready-to-show', () => {
    if (!isProbeRun()) return made.show()
    // Outside every display, shown without activating anything.
    const { width, height } = made.getBounds()
    made.setBounds({ ...offscreen(width), width, height })
    made.showInactive()
  })
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
  // A probe keeps its own window where nobody is, and so neither fills the
  // screen nor writes that place into the settings of whoever uses this copy.
  if (saved.maximized && !isProbeRun()) window.maximize()

  const remember = () => {
    if (!window || window.isDestroyed() || isProbeRun()) return
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

/**
 * Reads the library and says what is in it.
 *
 * `refused` belongs to one press of "add the loose PDFs" and is given here by
 * that handler alone. It was module state for a while, which meant every later
 * snapshot carried it — the note stayed on screen after a reload, after the
 * folder was disconnected, in a window that had nothing to do with it, and
 * there was nothing that would clear it.
 */
async function snapshot(refused: string[] = []): Promise<LibrarySnapshot | { error: string }> {
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
    const readable = new Map<string, TextSource>()
    const notes = new Map<string, NoteSource>()
    for (const folder of read) {
      unreadableRecords.push(...folder.trouble)
      for (const row of folder.papers) {
        ownerByID.set(row.id, folder.one)
        // What the text index reads, kept here so a search never has to ask
        // the folders where a paper's file is.
        if (row.file && row.exists) {
          readable.set(row.id, { id: row.id, file: row.file, title: new PaperMeta(row.meta).displayTitle })
        }
        // The paper's note, for search by meaning: a paper has one, kept
        // in its state, and the index reads it beside the paper's pages.
        const summary = String((row.state as { summaryNote?: unknown }).summaryNote ?? '')
        if (summary.trim().length > 0) notes.set(row.id, { id: row.id, paperID: row.id, markdown: summary })
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
    textSources = readable
    noteSources = notes
    textSourcesSent = false
    // The papers may have changed; search by meaning catches up once things
    // are quiet. Same papers as last time costs a comparison and nothing sent.
    semantic().schedule(5000)
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
      // …and the ones this press of that button could not take in.
      refused,
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

// MARK: - The words inside the papers

/** Every paper with a file to read, from the last read of the folders. */
let textSources = new Map<string, TextSource>()
/** The papers' notes, for search by meaning — one a paper, keyed by the paper. */
let noteSources = new Map<string, NoteSource>()
/** Whether the text service has been told about this list yet. */
let textSourcesSent = false
let textService: UtilityProcess | null = null
/**
 * Which window asked for which search, so its answers go back to it. Every
 * window numbers its own searches from one, so the service is given numbers
 * of this process's own and each is mapped back on the way out.
 */
const textSearches = new Map<number, { target: WebContents; token: number }>()
const textTokens = new Map<string, number>()
let textTokenCount = 0
const textStatsWaiting: ((stats: ServiceStats | null) => void)[] = []
/** Pages asked of the text service for search by meaning, by request number. */
const textTextsWaiting = new Map<number, {
  resolve: (reply: { papers: { id: string; pages: string[] }[]; unread: string[]; ms: number }) => void
  reject: (error: Error) => void
}>()
let textTextsCount = 0

/**
 * Where the text is kept: the app's own folder, never the library's.
 *
 * A probe keeps a folder of its own. It reads a test library, and its
 * clean-up — which takes out the text of papers that are gone — would
 * otherwise judge the person's own cache by the probe's library and empty it.
 */
function textCacheDirectory(): string {
  const chosen = probeArgument('text-cache')
  if (chosen) return chosen
  if (isProbeRun()) return path.join(app.getPath('temp'), 'Paper Time probe', 'Text')
  return path.join(app.getPath('userData'), 'Text')
}

/**
 * Where the vectors are kept: beside the text, under the same rule. One
 * store for the app rather than one per folder — it keys by passage text,
 * and a paper in two folders shares its vectors.
 */
function semanticCacheDirectory(): string {
  const chosen = probeArgument('semantic-cache')
  if (chosen) return chosen
  if (isProbeRun()) return path.join(app.getPath('temp'), 'Paper Time probe', 'Semantic')
  return path.join(app.getPath('userData'), 'Semantic')
}

const semanticProbe = probeArgument('semantic-index') === '1' || probeArgument('semantic-query') != null

let semanticSearch: SemanticSearch | null = null

/** Search by meaning, made the first time anything asks about it. */
function semantic(): SemanticSearch {
  if (semanticSearch) return semanticSearch
  semanticSearch = new SemanticSearch(semanticCacheDirectory(), {
    sources: () => [...textSources.values()],
    notes: () => [...noteSources.values()],
    texts: (ids) => new Promise((resolve, reject) => {
      const token = (textTextsCount += 1)
      textTextsWaiting.set(token, { resolve, reject })
      textsWithSources().postMessage({ type: 'texts', token, ids })
    }),
    enabled: () => settings().semanticSearch !== false,
    send,
    log: (line) => {
      if (semanticProbe || isProbeRun()) process.stderr.write(`${line}\n`)
    },
  })
  return semanticSearch
}

/** The files pdf.js may ask for, by name — nothing with a path in it. */
const ASSET_NAME = /^[A-Za-z0-9][A-Za-z0-9_.+-]*$/

async function textAsset(kind: 'cmap' | 'font', name: string): Promise<Uint8Array | null> {
  // The name comes out of a PDF, which anybody can write. Only a bare file
  // name, only from the two folders the window loads the same files from.
  if (!ASSET_NAME.test(name) || name.includes('..')) return null
  const file = kind === 'cmap'
    ? path.join(__dirname, '../renderer/cmaps', `${name}.bcmap`)
    : path.join(__dirname, '../renderer/standard_fonts', name)
  try {
    return new Uint8Array(await fsp.readFile(file))
  } catch {
    return null
  }
}

/**
 * The text service, started the first time a search needs it.
 *
 * Never at launch: most sessions never search the text at all, and the ones
 * that do start when the palette opens. It ends itself when nobody has asked
 * for ten minutes, and starts again the next time.
 */
function texts(): UtilityProcess {
  if (textService) return textService
  // From the copy the packager leaves outside the archive (see `asarUnpack`
  // in electron-builder.yml): the service starts threads from a file, and a
  // file inside the archive is not one a thread can be started from.
  const script = path.join(__dirname, 'textService.js')
  const unpacked = script.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
  const child = utilityProcess.fork(unpacked !== script && fs.existsSync(unpacked) ? unpacked : script, [], {
    serviceName: 'Paper Time Text',
  })
  child.postMessage({ type: 'configure', directory: textCacheDirectory() })
  textSourcesSent = false
  child.on('message', (message: ServiceReply) => {
    switch (message.type) {
      case 'hits':
      case 'done': {
        const asked = textSearches.get(message.token)
        if (!asked) break
        if (message.type === 'done') {
          textSearches.delete(message.token)
          textTokens.delete(`${asked.target.id}:${asked.token}`)
        }
        if (!asked.target.isDestroyed()) {
          asked.target.send(CHANNEL.event, `text:${message.type}`, { ...message, token: asked.token })
        }
        break
      }
      case 'warmed':
        send('text:warmed', message)
        // The pages are in hand now; search by meaning catches up shortly.
        semantic().schedule(2000)
        break
      case 'texts': {
        const asked = textTextsWaiting.get(message.token)
        if (!asked) break
        textTextsWaiting.delete(message.token)
        asked.resolve({ papers: message.papers, unread: message.unread, ms: message.ms })
        break
      }
      case 'asset':
        void textAsset(message.kind, message.name).then((data) => {
          child.postMessage({ type: 'asset', request: message.request, data })
        })
        break
      case 'stats':
        for (const waiting of textStatsWaiting.splice(0)) waiting(message.stats)
        break
    }
  })
  child.on('exit', () => {
    if (textService === child) textService = null
    // Searches in flight end with the process, and the window is told so
    // rather than left waiting for answers that will not come.
    for (const { target, token } of textSearches.values()) {
      if (!target.isDestroyed()) target.send(CHANNEL.event, 'text:done', { token, searched: 0, found: 0, ms: 0 })
    }
    textSearches.clear()
    textTokens.clear()
    for (const waiting of textStatsWaiting.splice(0)) waiting(null)
    for (const waiting of textTextsWaiting.values()) waiting.reject(new Error('the text service ended'))
    textTextsWaiting.clear()
  })
  textService = child
  return child
}

/** The service, with the latest list of papers it may be asked about. */
function textsWithSources(): UtilityProcess {
  const service = texts()
  if (!textSourcesSent) {
    service.postMessage({
      type: 'sources',
      sources: [...textSources.values()],
      roots: allLibraries().map((one) => one.root),
    })
    textSourcesSent = true
  }
  return service
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
  'settings:set': ((patch: Record<string, unknown>) => {
    const next = update(patch)
    // The switch for search by meaning: off ends the worker and what it was
    // doing; on starts the build the way a library read would.
    if ('semanticSearch' in patch) {
      if (next.semanticSearch === false) semantic().stop()
      else semantic().schedule(500)
    }
    return next
  }) as Handler,

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
    const refused: string[] = []
    for (const one of allLibraries()) {
      for (const file of await one.looseFiles()) {
        try {
          await one.importPDF(file, await pageCount(file))
        } catch {
          refused.push(path.basename(file))
        }
      }
    }
    return snapshot(refused)
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
    // A note that changed goes back into search by meaning once the
    // typing has settled; each keystroke pushes that back.
    if ('summaryNote' in patch) {
      const summary = String(patch.summaryNote ?? '')
      if (summary.trim().length > 0) noteSources.set(id, { id, paperID: id, markdown: summary })
      else noteSources.delete(id)
      semantic().scheduleNotes(5000)
    }
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
    touched(id).sketch.add(pageIndex)
    schedulePDFWrite(id)
  }) as Handler,

  'ink:load': (async ({ id, pageIndex }: { id: string; pageIndex: number }) =>
    (await ownerOf(id))?.loadInk(id, pageIndex) ?? null) as Handler,

  'ink:save': (async ({ id, pageIndex, strokes }: { id: string; pageIndex: number; strokes: unknown[] }) => {
    if (!library) return
    await library.saveInk(id, pageIndex, strokes)
    await supersedeAppleInk(id, pageIndex)
    touched(id).ink.add(pageIndex)
    schedulePDFWrite(id)
  }) as Handler,

  'marks:load': (async ({ id }: { id: string }) => {
    const owner = await ownerOf(id)
    const row = await owner?.paper(id)
    if (!owner || !row?.file || !row.exists) return {}
    const bytes = await fsp.readFile(row.file)
    const found = await readMarks(bytes)
    // This machine's journal from before 0.9.9 said only when each mark was
    // made, which the Mac reads as "taken away". Brought up to date from the
    // file the first time the paper is opened here.
    const own = await ownJournal(id, owner.root)
    if (upgradeLegacy(own.journal, found)) {
      own.journal.updated = isoTimestamp(new Date())
      await keepOwnJournal(id, owner.root, own)
    }
    // What the file holds, overruled by what every device's journal says: a
    // mark made on a Mac a second ago, or one this machine could not put into
    // an encrypted file, is a mark all the same.
    const { pages } = reconcile(found, merged(await journalsFor(id, owner.root)))
    const out: Record<number, MarkupRecord[]> = {}
    for (const [pageIndex, marks] of pages) out[pageIndex] = marks
    // Held here as the window has them, so the next save can tell what the
    // window changed.
    marksInMemory.set(id, out)
    // An encrypted file carries none of what was made on it here, and the
    // window says so the moment the paper opens — not only after the next
    // save is turned away, which after a restart may be never.
    const refused = await writeRefusal(bytes)
    if (refused && await holdsAnything(owner, id, pages)) {
      send('paper:kept', { id, reason: refused })
    }
    return out
  }) as Handler,

  'marks:save': (async ({ id, pageIndex, marks }: { id: string; pageIndex: number; marks: MarkupRecord[] }) => {
    const pages = marksInMemory.get(id) ?? {}
    const before = pages[pageIndex] ?? []
    pages[pageIndex] = marks
    marksInMemory.set(id, pages)
    await recordInJournal(id, pageIndex, before, marks, pages)
    touched(id).marks.add(pageIndex)
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

  // The words inside the papers. The window says which papers, in which
  // order, and under which titles; this process knows where their files are.
  'text:warm': (({ ids }: { ids: string[] }) => {
    textsWithSources().postMessage({ type: 'warm', ids })
  }) as Handler,
  'text:search': (({ token, query, ids, titles, limit }: {
    token: number; query: string; ids: string[]; titles: Record<string, string>; limit?: number
  }, sender: BrowserWindow | null) => {
    if (!sender) return
    const global = (textTokenCount += 1)
    textSearches.set(global, { target: sender.webContents, token })
    textTokens.set(`${sender.webContents.id}:${token}`, global)
    textsWithSources().postMessage({ type: 'search', token: global, query, ids, titles, limit })
  }) as Handler,
  'text:cancel': (({ token }: { token: number }, sender: BrowserWindow | null) => {
    const global = sender ? textTokens.get(`${sender.webContents.id}:${token}`) : undefined
    if (global !== undefined) textService?.postMessage({ type: 'cancel', token: global })
  }) as Handler,
  /** For a probe: what the service has read, and what it cost. */
  'text:stats': () => new Promise<ServiceStats | null>((resolve) => {
    if (!textService) return resolve(null)
    textStatsWaiting.push(resolve)
    textService.postMessage({ type: 'stats' })
  }),

  // Search by meaning. The window says what was typed and which places its
  // exact search already shows; the answer is passages, best first.
  'semantic:search': (({ query, k, shown }: { query: string; k?: number; shown?: string[] }) =>
    semantic().search(query, k ?? 8, shown ?? [])) as Handler,
  'semantic:status': () => semantic().status(),
  /** For a probe: builds now and waits, then says what the worker has. */
  'semantic:build': async () => {
    await semantic().build()
    return { status: semantic().status(), stats: await semantic().stats(), unread: semantic().unread }
  },
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
 * Every page's marks for the papers that are open, as the window has them.
 *
 * Read when the paper opens and replaced page by page as the window saves, so
 * that each save can be told apart from what came before it — which is what
 * goes into the journal. The file itself is written from the journals, not
 * from here: see `writePDF`.
 */
const marksInMemory = new Map<string, Record<number, MarkupRecord[]>>()

/**
 * The pages whose layers this run has saved, per paper.
 *
 * A page is this build's to rewrite for a layer when it has a sidecar here —
 * or when it was saved here and has none any more, because the last stroke on
 * it was rubbed out and an empty sidecar is removed. What a page must never be
 * is rewritten because it merely has something in the file: a page drawn on a
 * Mac carries the Mac's strokes in the PDF and in its `.drawing`, and in no
 * sidecar of this build's, and treating "no sidecar" as "no strokes" rubbed
 * them out of the file the first time this machine saved anything else.
 * Kept for the run; a page saved once stays this build's to write.
 */
const touchedPages = new Map<string, { sketch: Set<number>; ink: Set<number>; marks: Set<number> }>()

function touched(id: string) {
  let pages = touchedPages.get(id)
  if (!pages) {
    pages = { sketch: new Set(), ink: new Set(), marks: new Set() }
    touchedPages.set(id, pages)
  }
  return pages
}

function schedulePDFWrite(id: string) {
  clearTimeout(pending.get(id))
  pending.set(id, setTimeout(() => {
    pending.delete(id)
    flushToPDF(id).catch((error) => send('error', String(error)))
  }, PDF_WRITE_DELAY))
}

/** One write at a time per paper: two would read the same file and race. */
const flushing = new Map<string, Promise<unknown>>()

type FlushResult = { written: number } | { kept: KeptReason } | { error: string }

function flushToPDF(id: string): Promise<FlushResult> {
  const before = flushing.get(id) ?? Promise.resolve()
  const next = before.then(() => writePDF(id), () => writePDF(id))
  flushing.set(id, next)
  void next.finally(() => {
    if (flushing.get(id) === next) flushing.delete(id)
  })
  return next
}

async function writePDF(id: string): Promise<FlushResult> {
  // The folder the paper is in, and every sidecar and journal from there:
  // the file, its drawings and its marks all live in one folder.
  const owner = await ownerOf(id)
  if (!owner) return { error: 'No library is open.' }
  const row = await owner.paper(id)
  if (!row?.file || !row.exists) return { error: 'The PDF is not where the record says it is.' }
  let wanted = new Map<number, MarkupRecord[]>()
  try {
    const pages = await owner.annotatedPages(id)
    const saved = touched(id)
    const was = await fsp.stat(row.file)
    const current = await fsp.readFile(row.file)
    // The marks the file should hold: what it holds now, overruled by every
    // device's journal — this machine's changes are in its own by now, and a
    // Mac that marked the page a second ago is in its. `DocumentSession`
    // writes the file the same way, to agree with all of them.
    const reconciled = reconcile(await readMarks(current), merged(await journalsFor(id, owner.root)))
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
        // Only the marks this app made are ours to rewrite; one that was in
        // the file when it arrived stays where it is, untouched.
        marks: (wanted.get(pageIndex) ?? []).filter(isOurMark),
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
      const placed = await appendVerified(row.file, was, current, written.bytes, written.pages)
      if (placed === 'moved') {
        // Somebody else wrote the file between the read and the write — the
        // Mac through the cloud, most likely. Theirs stands; this save goes
        // again on top of it.
        schedulePDFWrite(id)
        return { written: 0 }
      }
      if (written.stats) {
        const s = written.stats
        process.stderr.write(`pdf append: ${path.basename(row.file)} +${s.bytesAfter - s.bytesBefore} B, xref=${s.xrefKind}, pages=${s.pagesChanged}, added=${s.annotationsAdded}, removed=${s.annotationsRemoved}, freed=${s.objectsFreed}, ${s.ms} ms\n`)
      }
    }
    send('paper:saved', { id })
    return { written: drawings.length }
  } catch (error) {
    if (error instanceof WriteRefused) {
      // Not a failure, and not said as one. Everything is where it was put —
      // the shapes and the strokes in their sidecars, the marks in the
      // journal — and the window says that the file is not where they are.
      // Once the last of them is taken away there is nothing left to say it
      // about, and the line goes.
      const reason = keptReason(error.reason)
      process.stderr.write(`pdf append refused: ${path.basename(row.file)}: ${error.message}\n`)
      const held = await holdsAnything(owner, id, wanted)
      send('paper:kept', { id, reason: held ? reason : null })
      return { kept: reason }
    }
    return { error: String((error as Error).message ?? error) }
  }
}

/**
 * `.papertime/papers/<id>/pdf/base.json`: the length and digest of the file
 * before anything was ever appended to it — what compaction on the Mac
 * rebases onto (`PDFBase`). Written once, never changed; the same bytes the
 * Mac writes, so either build can have been first.
 */
async function recordBaseIfAbsent(root: string, id: string, bytes: Uint8Array) {
  const file = path.join(L.paperDir(root, id), 'pdf', 'base.json')
  if (fs.existsSync(file)) return
  const digest = crypto.createHash('sha256').update(bytes).digest('hex')
  await writeJSON(file, { digest, length: bytes.length })
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
async function appendVerified(file: string, was: fs.Stats, original: Uint8Array, result: Uint8Array, pages: number): Promise<'placed' | 'moved'> {
  const temporary = `${file}.${process.pid}.tmp`
  try {
    await fsp.writeFile(temporary, result)
    const back = await fsp.readFile(temporary)
    if (back.length !== result.length || back.length < original.length) throw new WriteRefused('verification', 'the temporary file is not the right length')
    const wanted = crypto.createHash('sha256').update(original).digest('hex')
    const got = crypto.createHash('sha256').update(back.subarray(0, original.length)).digest('hex')
    if (wanted !== got) throw new WriteRefused('verification', 'the result does not begin with the original bytes')
    const counted = await pageCountWithPDFJS(back)
    if (counted !== pages) throw new WriteRefused('verification', `pdf.js reads ${counted} pages, the file says ${pages}`)
    const now = await fsp.stat(file)
    if (now.size !== was.size || now.mtimeMs !== was.mtimeMs) {
      await fsp.rm(temporary, { force: true })
      return 'moved'
    }
    await fsp.rename(temporary, file)
    return 'placed'
  } catch (error) {
    await fsp.rm(temporary, { force: true })
    throw error
  }
}

/**
 * How many pages pdf.js reads in these bytes — the reader the window uses,
 * asked on a thread of its own so the process that owns the windows never
 * loads a document. The text service's worker script already knows how to
 * be that thread; it is started here for this one answer and let go.
 */
function pageCountWithPDFJS(bytes: Uint8Array): Promise<number> {
  return new Promise((resolve, reject) => {
    const script = path.join(__dirname, 'textWorker.js')
    const unpacked = script.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
    const worker = new Worker(unpacked !== script && fs.existsSync(unpacked) ? unpacked : script)
    const done = (settle: () => void) => {
      settle()
      void worker.terminate()
    }
    worker.on('message', (message: { type: string; pages?: number; error?: string }) => {
      if (message.type === 'pages') done(() => resolve(message.pages ?? -1))
      else if (message.type === 'failed') done(() => reject(new WriteRefused('verification', `pdf.js: ${message.error ?? 'cannot open the result'}`)))
    })
    worker.on('error', (error) => done(() => reject(error)))
    // A copy of its own: a Buffer's `.buffer` is Node's shared pool.
    const owned = new Uint8Array(bytes).buffer
    worker.postMessage({ type: 'pages', job: 1, bytes: owned }, [owned])
  })
}

/**
 * Whether anything this build made is on the paper — a mark, a shape, a
 * stroke — for the line that says the file does not carry it.
 */
async function holdsAnything(owner: Library, id: string, marks: Map<number, MarkupRecord[]>): Promise<boolean> {
  for (const list of marks.values()) if (list.some(isOurMark)) return true
  const drawn = await owner.annotatedPages(id)
  return drawn.sketch.length > 0 || drawn.ink.length > 0
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

// MARK: - The marks journal

/** What the Mac's `DeviceIdentity.platformName` is for this machine. */
const PLATFORM_NAME = process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : 'Mac'

/**
 * This device's journal for each paper, held here once read.
 *
 * Held, not re-read, because it is the one journal nobody else writes, and
 * because a save must not depend on the file coming back: `loaded` is false
 * when the copy on disk would not be read — still arriving down a cloud
 * drive, or damaged — and a journal that was not read is never written over.
 * What is recorded meanwhile is kept here, merged in once it can be read.
 */
const ownJournals = new Map<string, { journal: Journal; loaded: boolean }>()

async function ownJournal(id: string, root: string) {
  const known = ownJournals.get(id)
  if (known?.loaded) return known
  const file = L.marksPath(root, id, deviceIdentity)
  try {
    const disk = asJournal(await readJSON(file)) ?? freshJournal(deviceIdentity, PLATFORM_NAME)
    for (const [key, entry] of Object.entries(known?.journal.entries ?? {})) {
      const there = disk.entries[key]
      if (!there || Date.parse(there.at) < Date.parse(entry.at)) disk.entries[key] = entry
    }
    const own = { journal: disk, loaded: true }
    ownJournals.set(id, own)
    return own
  } catch (error) {
    console.error("marks journal - this device's journal could not be read, and is not written over:", error)
    if (known) return known
    const own = { journal: freshJournal(deviceIdentity, PLATFORM_NAME), loaded: false }
    ownJournals.set(id, own)
    return own
  }
}

async function keepOwnJournal(id: string, root: string, own: { journal: Journal; loaded: boolean }) {
  if (!own.loaded) return
  own.journal.device = deviceIdentity
  own.journal.name = PLATFORM_NAME
  await writeJSON(L.marksPath(root, id, deviceIdentity), own.journal)
}

/** A record read from disk, if it has a journal's shape. */
function asJournal(raw: unknown): Journal | null {
  if (!raw || typeof raw !== 'object') return null
  const journal = raw as Journal
  if (!journal.entries || typeof journal.entries !== 'object') journal.entries = {}
  return journal
}

/**
 * Every device's journal for a paper: the others as their files have them,
 * this one as it is held here. A journal that will not be read is left out —
 * it is somebody's, and it is late, and the file already holds what it said
 * the last time that device wrote it.
 */
async function journalsFor(id: string, root: string): Promise<Held[]> {
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
      if (device === deviceIdentity) continue
      out.push({ device, journal })
    } catch {
      continue
    }
  }
  const own = await ownJournal(id, root)
  out.push({ device: deviceIdentity, journal: own.journal })
  return out
}

/**
 * Records in this device's journal what one save of a page changed.
 *
 * The journal is the fast path between machines: the PDF is the durable
 * record and is rewritten a second or so later, but a small file naming what
 * this device just did lands in the synced folder at once. It is also where a
 * mark stays when the PDF cannot take it. The Mac writes the same shape — a
 * `MarkupDescriptor` for a mark made or changed, nothing for one taken away —
 * and reconciles from it.
 */
async function recordInJournal(
  id: string,
  pageIndex: number,
  before: MarkupRecord[],
  after: MarkupRecord[],
  pages: Record<number, MarkupRecord[]>,
) {
  const owner = await ownerOf(id)
  if (!owner) return
  const own = await ownJournal(id, owner.root)
  const elsewhere = new Set<string>()
  for (const [index, marks] of Object.entries(pages)) {
    if (Number(index) === pageIndex) continue
    for (const mark of marks) elsewhere.add(mark.id.toUpperCase())
  }
  if (!recordChanges(own.journal, pageIndex, before, after, new Date(), elsewhere)) return
  await keepOwnJournal(id, owner.root, own)
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
  // No Dock icon and no menu bar for a probe: an accessory app does not become
  // the active app by being launched, and its windows do not bounce the Dock.
  if (isMac && isProbeRun()) {
    app.setActivationPolicy('accessory')
    app.dock?.hide()
  }
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
  // `--papertime-semantic-index=1` builds the index for the probe library
  // now and says what it cost; `--papertime-semantic-query=<text>` asks it,
  // twice, so the second line shows the cost once the model is warm. Both
  // print to stderr. Then the probe's own steps, if any; otherwise quit.
  if (semanticProbe) void runSemanticProbe().then(() => {
    if (probe && window) void runProbe(window, probe)
    else if (shot && window) void captureAndQuit(window, shot)
    else app.quit()
  })
  else if (probe && window) void runProbe(window, probe)
  else if (shot && window) void captureAndQuit(window, shot)
})

async function runSemanticProbe() {
  const out = (line: string) => process.stderr.write(`${line}\n`)
  if (!library) return out('semantic: no library')
  await semantic().build()
  const stats = await semantic().stats()
  const status = semantic().status()
  out(`semantic: status enabled=${status.enabled} ready=${status.ready} passages=${status.passages} notes=${status.notes} notePassages=${status.notePassages}` +
    (stats ? ` · worker loaded=${stats.loaded} loadMs=${stats.loadMs === null ? '-' : Math.round(stats.loadMs)} vectors=${stats.vectors} rss=${stats.rssMB} MB` : ''))
  const query = probeArgument('semantic-query')
  if (!query) return
  for (const round of [1, 2]) {
    const t0 = performance.now()
    const answer = await semantic().search(query, 8)
    const fromNotes = answer.hits.filter((hit) => hit.note).length
    out(`semantic: “${query}” → ${answer.hits.length} passages (${fromNotes} from notes) in ${(performance.now() - t0).toFixed(1)} ms (worker ${answer.ms.toFixed(1)} ms)${round === 2 ? ' · asked again' : ''}`)
    if (round === 2) break
    answer.hits.forEach((hit, i) => {
      if (hit.note) {
        out(`semantic:   ${i + 1}. ${hit.score.toFixed(3)}  NOTE ${hit.note.id} “${hit.note.title.slice(0, 40)}” @${hit.passage.location}+${hit.passage.length} | ${hit.snippet.slice(0, 90)}`)
        return
      }
      const title = textSources.get(hit.passage.paperID)?.title ?? hit.passage.paperID
      out(`semantic:   ${i + 1}. ${hit.score.toFixed(3)}  ${title.slice(0, 40)} · p${hit.passage.pageIndex + 1} @${hit.passage.location}+${hit.passage.length} | ${hit.snippet.slice(0, 90)}`)
    })
  }
}

app.on('window-all-closed', () => {
  if (!isMac) app.quit()
})

// The text service goes with the app, whatever it was in the middle of.
app.on('will-quit', () => {
  textService?.kill()
  semanticSearch?.end()
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
