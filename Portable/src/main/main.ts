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
import { buildMenu } from './menu.js'
import { watchLibrary } from './watcher.js'
import { captureAndQuit, probeArgument, runProbe } from './probe.js'

const isMac = process.platform === 'darwin'
/** See `--papertime-chrome` in `preload.ts`. */
const chromeOverride = probeArgument('chrome')

let window: BrowserWindow | null = null
let library: Library | null = null
let stopWatching: (() => void) | null = null

function send(event: string, payload?: unknown) {
  window?.webContents.send(CHANNEL.event, event, payload)
}

// MARK: - The window

function createWindow() {
  const saved = settings().window
  window = new BrowserWindow({
    width: saved.width,
    height: saved.height,
    x: saved.x,
    y: saved.y,
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
      additionalArguments: chromeOverride ? [`--papertime-chrome=${chromeOverride}`] : [],
    },
  })

  if (saved.maximized) window.maximize()
  window.loadFile(path.join(__dirname, '../renderer/index.html'))
  window.once('ready-to-show', () => window?.show())

  const remember = () => {
    if (!window || window.isDestroyed()) return
    const bounds = window.getBounds()
    update({ window: { ...bounds, maximized: window.isMaximized() } })
  }
  window.on('resize', remember)
  window.on('move', remember)
  for (const event of ['maximize', 'unmaximize', 'enter-full-screen', 'leave-full-screen']) {
    window.on(event as 'maximize', () => send('window:state', windowState()))
  }
  window.on('focus', () => send('window:state', windowState()))
  window.on('blur', () => send('window:state', windowState()))
  window.on('closed', () => {
    window = null
  })

  // A page in the reader must never navigate the app away from itself, and a
  // link in a paper belongs in the user's browser, not inside this window.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  window.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('file://')) event.preventDefault()
  })
}

function windowState() {
  return {
    maximized: window?.isMaximized() ?? false,
    fullScreen: window?.isFullScreen() ?? false,
    focused: window?.isFocused() ?? true,
  }
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

type Handler = (args: never) => unknown | Promise<unknown>

const handlers: Record<string, Handler> = {
  // The effective root, not the remembered one: a probe run opens a folder
  // of its own and the window must be told about that one.
  'settings:get': () => ({ ...settings(), libraryRoot: library?.root ?? settings().libraryRoot }),
  'settings:set': ((patch: Record<string, unknown>) => update(patch)) as Handler,

  'library:choose': async () => {
    const result = await dialog.showOpenDialog(window!, {
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

  'library:import': (async ({ paths }: { paths?: string[] }) => {
    if (!library) return { error: 'No library is open.' }
    let chosen = paths
    if (!chosen || chosen.length === 0) {
      const result = await dialog.showOpenDialog(window!, {
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

  'bibtex:export': (async ({ ids }: { ids?: string[] }) => {
    if (!library) return { error: 'No library is open.' }
    const rows = await library.papers()
    const chosen = ids && ids.length > 0 ? rows.filter((row) => ids.includes(row.id)) : rows
    if (chosen.length === 0) return { error: 'There is nothing to export.' }
    const text = formatBibliography(chosen.map((row) => new PaperMeta(row.meta)), DEFAULT_EXPORT)
    const result = await dialog.showSaveDialog(window!, {
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

  'window:minimize': () => window?.minimize(),
  'window:toggleMaximize': () => (window?.isMaximized() ? window.unmaximize() : window?.maximize()),
  'window:close': () => window?.close(),
  'window:state': () => windowState(),
  'shell:openExternal': (({ url }: { url: string }) => {
    if (/^https?:/.test(url)) shell.openExternal(url)
  }) as Handler,
}

ipcMain.handle(CHANNEL.invoke, async (_event, name: string, args: unknown) => {
  const handler = handlers[name]
  if (!handler) throw new Error(`Unknown request: ${name}`)
  return handler(args as never)
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

app.whenReady().then(async () => {
  createWindow()
  buildMenu({
    send,
    chooseLibrary: async () => {
      const chosen = await handlers['library:choose'](undefined as never)
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
