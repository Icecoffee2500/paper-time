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
import { Library, deviceIdentity, readJSON, writeJSON } from './library.js'
import * as L from './layout.js'
import { PaperMeta, PaperState } from '../shared/model.js'
import { DEFAULT_EXPORT, formatBibliography } from '../shared/bibtex.js'
import { SketchElement } from '../shared/sketch.js'
import { InkStroke } from '../shared/ink.js'
import {
  isOurMark,
  readDrawings,
  readMarks,
  stripOwnedForDisplay,
  writeDrawings,
  type MarkupRecord,
  type PageDrawing,
} from './pdfwrite.js'
import { rememberLibrary, settings, update } from './settings.js'
import { resolveKorean, setKorean } from '../shared/lang.js'
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
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1c1c1e' : '#ebeced',
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

async function snapshot(): Promise<LibrarySnapshot | { error: string }> {
  if (!library) return { error: 'No library is open.' }
  try {
    const papers = await library.papers()
    return {
      root: library.root,
      manifest: await library.manifest(),
      collections: await library.collections(),
      papers: papers.map((row) => ({
        id: row.id,
        meta: row.meta,
        state: row.state,
        exists: row.exists,
      })),
      looseCount: (await library.looseFiles()).length,
    }
  } catch (error) {
    return { error: String((error as Error).message ?? error) }
  }
}

async function openLibrary(root: string) {
  stopWatching?.()
  library = await Library.open(root)
  rememberLibrary(root)
  stopWatching = watchLibrary(root, () => send('library:changed'))
  return snapshot()
}

// MARK: - Requests

/** A request, with the window that made it — dialogs hang off that one. */
type Handler = (args: never, sender: BrowserWindow | null) => unknown | Promise<unknown>

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
    for (const file of await library.looseFiles()) {
      await library.importPDF(file, await pageCount(file))
    }
    return snapshot()
  },

  'library:trash': (async ({ id }: { id: string }) => {
    await library?.trashPaper(id)
    return snapshot()
  }) as Handler,

  'paper:bytes': (async ({ id }: { id: string }) => {
    const row = await library?.paper(id)
    if (!row?.file || !row.exists) return { error: 'The PDF for this paper is not in the folder.' }
    return { data: await stripOwnedForDisplay(await fsp.readFile(row.file)) }
  }) as Handler,

  'paper:state': (async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => {
    if (!library) return null
    const row = await library.paper(id)
    const state = new PaperState(row?.state ?? {})
    // A patch crosses the bridge as JSON, so its dates arrive as strings.
    Object.assign(state, patch, {
      lastOpenedAt: patch.lastOpenedAt ? new Date(String(patch.lastOpenedAt)) : state.lastOpenedAt,
    })
    const saved = await library.saveState(id, state)
    return saved.encode()
  }) as Handler,

  'paper:meta': (async ({ id, patch }: { id: string; patch: Record<string, unknown> }) => {
    if (!library) return null
    const row = await library.paper(id)
    if (!row) return null
    const meta = new PaperMeta(row.meta)
    Object.assign(meta, patch)
    await library.saveMeta(meta)
    return meta.encode()
  }) as Handler,

  'paper:reveal': (async ({ id }: { id: string }) => {
    const row = await library?.paper(id)
    if (row?.file) shell.showItemInFolder(row.file)
  }) as Handler,

  'sketch:load': (async ({ id, pageIndex }: { id: string; pageIndex: number }) =>
    library?.loadSketch(id, pageIndex) ?? null) as Handler,

  'sketch:save': (async ({ id, pageIndex, elements }: { id: string; pageIndex: number; elements: unknown[] }) => {
    await library?.saveSketch(id, pageIndex, elements)
    schedulePDFWrite(id)
  }) as Handler,

  'ink:load': (async ({ id, pageIndex }: { id: string; pageIndex: number }) =>
    library?.loadInk(id, pageIndex) ?? null) as Handler,

  'ink:save': (async ({ id, pageIndex, strokes }: { id: string; pageIndex: number; strokes: unknown[] }) => {
    if (!library) return
    await library.saveInk(id, pageIndex, strokes)
    await supersedeAppleInk(id, pageIndex)
    schedulePDFWrite(id)
  }) as Handler,

  'marks:load': (async ({ id }: { id: string }) => {
    const row = await library?.paper(id)
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
    library?.annotatedPages(id) ?? { sketch: [], ink: [], appleInk: [] }) as Handler,

  'drawing:adoptFromFile': (async ({ id }: { id: string }) => adoptFromFile(id)) as Handler,

  'drawing:flush': (async ({ id }: { id: string }) => flushToPDF(id)) as Handler,

  'bibtex:export': (async ({ ids }: { ids?: string[] }, sender: BrowserWindow | null) => {
    if (!library) return { error: 'No library is open.' }
    const rows = await library.papers()
    const chosen = ids && ids.length > 0 ? rows.filter((row) => ids.includes(row.id)) : rows
    if (chosen.length === 0) return { error: 'There is nothing to export.' }
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

  'collections:save': (async ({ collections }: { collections: unknown[] }) =>
    library?.saveCollections(collections as never) ?? null) as Handler,

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
    library = await Library.open(root)
    if (!probeArgument('library')) rememberLibrary(root)
    stopWatching = watchLibrary(root, () => send('library:changed'))
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
