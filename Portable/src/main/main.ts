/**
 * The launch script: composes the modules that own the files, the windows
 * and the menu, and answers the app's lifecycle.
 *
 * Everything platform-specific lives in this process — `windows.ts` for the
 * frame, `menu.ts` for the bar — and the window's contents are the same
 * everywhere by construction: one Chromium, one stylesheet, one bundled
 * typeface, which is the point of porting this way rather than three times.
 */
import { BrowserWindow, app, nativeTheme, systemPreferences } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import type { LibrarySnapshot, NoteDTO } from '../shared/api.js'
import { resolveKorean, setKorean } from '../shared/lang.js'
import { zettelDisplayTitle } from '../shared/zettel.js'
import { flushSettings, holdInMemory, settings } from './settings.js'
import { DEFAULT_MENU_STATE, buildMenu } from './menu.js'
import type { MenuState } from '../shared/api.js'
import { NotesStore } from './slipBox.js'
import { captureAndQuit, runProbe } from './probe.js'
import { markCleanExit, markRunning, noteAction } from './feedback.js'
import { runLibraryProbes } from './probeReports.js'
import { probe } from './probeMode.js'
import { Windows } from './windows.js'
import { LibrarySet } from './libraries.js'
import { FolderSync } from './folderSync.js'
import { Journals } from './journal.js'
import { PDFFlusher, sweepTemporaries } from './pdfFlush.js'
import { PageCounter } from './pdfBytes.js'
import { Records } from './records.js'
import { TextBridge } from './textBridge.js'
import { SemanticSearch, type NoteSource } from './semantic.js'
import type { TextSource } from './textIndex.js'
import { registerIPC } from './ipc.js'
import type { Context, Handlers } from './handlers/context.js'
import { libraryHandlers } from './handlers/library.js'
import { paperHandlers } from './handlers/paper.js'
import { drawingHandlers } from './handlers/drawing.js'
import { notesHandlers } from './handlers/notes.js'
import { windowHandlers } from './handlers/window.js'
import { textHandlers } from './handlers/text.js'
import { pageCount } from './handlers/shared.js'

const isMac = process.platform === 'darwin'

// Nor write anything into their settings: a probe that opens a paper or picks
// an inspector tab is not the person choosing one.
if (probe.isRun) holdInMemory()

/**
 * Decided here, once, and handed to the window as an argument: the menu is
 * built in this process and the interface in the other, and the two must not
 * answer the question separately and disagree. Settled at `whenReady`
 * because neither the locale nor the settings file is readable before that.
 */
let wantsKorean = false

/** What the window in front last said about itself. */
let menuState: MenuState = DEFAULT_MENU_STATE

/** The menu bar, in the language the app speaks now, for the window in front. */
function installMenu() {
  buildMenu({
    // A command from the menu bar, by name, for a report's «last few actions».
    send: (event: string, payload?: unknown) => {
      if (event === 'menu' && typeof payload === 'string') noteAction(payload)
      windows.sendToFocused(event, payload)
    },
    chooseLibrary: async () => {
      const chosen = await handlers['library:choose'](undefined, windows.main)
      if (typeof chosen === 'string') send('library:opened', await openLibrary(chosen))
    },
  }, menuState)
}

// MARK: - The modules

const windows = new Windows({
  chromeOverride: probe.argument('chrome'),
  korean: () => wantsKorean,
  split: probe.argument('split') === '1',
})
const send = windows.send.bind(windows)
const log = (line: string) => process.stderr.write(`${line}\n`)

/** Every paper with a file to read, from the last read of the folders. */
let textSources = new Map<string, TextSource>()
/** The slip-box's notes, for search by meaning, by note. */
const noteSources = new Map<string, NoteSource>()

const text = new TextBridge({
  directory: () => probe.textCacheDirectory(),
  sources: () => [...textSources.values()],
  roots: () => libraries.roots,
  send,
  onWarmed: () => semantic().schedule(2000),
})

const semanticProbe = probe.argument('semantic-index') === '1' || probe.argument('semantic-query') != null
let semanticSearch: SemanticSearch | null = null

/** Search by meaning, made the first time anything asks about it. */
function semantic(): SemanticSearch {
  if (semanticSearch) return semanticSearch
  semanticSearch = new SemanticSearch(probe.semanticCacheDirectory(), {
    sources: () => [...textSources.values()],
    notes: () => [...noteSources.values()],
    texts: (ids) => text.texts(ids),
    enabled: () => settings().semanticSearch !== false,
    send,
    log: (line) => {
      if (semanticProbe || probe.isRun) log(line)
    },
  })
  return semanticSearch
}

/** Every note with words in it, as the index takes it — the Mac's `semanticSources`. */
function noteSource(note: Pick<NoteDTO, 'id' | 'title' | 'body' | 'paperID'>): NoteSource | null {
  if (note.title.trim().length === 0 && note.body.trim().length === 0) return null
  return { id: note.id, paperID: note.paperID, markdown: note.body, title: zettelDisplayTitle(note as NoteDTO) }
}

/**
 * The slip-box's boxes: one per folder, plus the loose one. Made when a
 * library is opened, because where the loose notes go for a probe run is
 * beside the probe's own library — the Mac's `<name>-loose-notes` — and
 * never the folder that belongs to whoever uses this copy.
 */
let notesStore: NotesStore | null = null

function openNotes(root: string): NotesStore {
  const appFolder = probe.hasLibrary ? probe.looseNotesFolder(root) : path.join(app.getPath('userData'), 'Notes')
  // `--papertime-notes-chosen=<path>` stands in for the stored choice, so
  // the way a launch finds the chosen folder can be run without one.
  const chosen = probe.hasLibrary ? probe.argument('notes-chosen') : settings().notesFolder
  const store = new NotesStore(appFolder, chosen)
  notesStore = store
  // Whatever fell back into the app's folder while the chosen one was away
  // goes across first, before the notes are read.
  if (chosen) void store.catchUp()
  return store
}

const notes = (): NotesStore => notesStore ?? openNotes(libraries.first?.root ?? app.getPath('temp'))

const libraries = new LibrarySet({
  remembers: () => !probe.hasLibrary,
  notes: async (folders, folderOfPaper) => {
    const box = notes()
    box.setFolders(folders, folderOfPaper)
    const rows = await box.load()
    noteSources.clear()
    for (const row of rows) {
      const source = noteSource(row)
      if (source) noteSources.set(row.id, source)
    }
    return { notes: rows, notesFolder: box.info() }
  },
  onRead: (sources) => {
    textSources = sources
    text.sourcesChanged()
    // The papers may have changed; search by meaning catches up once things
    // are quiet. Same papers as last time costs a comparison and nothing sent.
    semantic().schedule(5000)
  },
})

const pageCounter = new PageCounter()
const journals = new Journals()
const flush = new PDFFlusher({ ownerOf: (id) => libraries.ownerOf(id), journals, pageCounter, send, log })
const records = new Records()
const sync = new FolderSync({
  libraries: () => libraries.all(),
  looseNotes: () => notesStore?.info().loose ?? null,
  pageCounter,
  send,
  log,
})

/** Opens a folder as the library — the launch's, or one chosen — and re-arms the watchers. */
async function openLibrary(root: string): Promise<LibrarySnapshot | { error: string }> {
  sync.stop()
  await libraries.open(root)
  openNotes(root)
  sync.start()
  return libraries.snapshot()
}

const context: Context = {
  libraries, sync, flush, journals, records, text, semantic, notes, windows, pageCounter,
  isProbe: probe.hasLibrary,
  probeLibrary: probe.argument('library') ?? null,
  snapshot: (refused) => libraries.snapshot(refused),
  openLibrary,
  menuStateChanged: (state) => {
    if (JSON.stringify(state) === JSON.stringify(menuState)) return
    menuState = state
    installMenu()
  },
  languageChanged: () => {
    // Said in the new language at once: the menu built again and every
    // window made again where it stands. It used to wait for a restart.
    wantsKorean = resolveKorean(settings().language, app.getLocale())
    setKorean(wantsKorean)
    installMenu()
    windows.recreate()
  },
  notesChanged: (saved, removed) => {
    if (saved) {
      const source = noteSource(saved)
      if (source) noteSources.set(saved.id, source)
      else noteSources.delete(saved.id)
    }
    if (removed) noteSources.delete(removed)
    semantic().scheduleNotes(5000)
  },
}

const handlers: Handlers = {
  ...libraryHandlers(context),
  ...paperHandlers(context),
  ...drawingHandlers(context),
  ...notesHandlers(context),
  ...windowHandlers(context),
  ...textHandlers(context),
} as Handlers

registerIPC(handlers)

// MARK: - Launch

// Windows groups taskbar buttons and notifications by this, not by the
// executable's name. Without it a pinned Paper Time and a running Paper Time
// are two different buttons.
if (process.platform === 'win32') app.setAppUserModelId('com.imtaeheon.PaperTime')

/**
 * Wayland, when the session is Wayland. Electron still defaults to X11
 * through XWayland, which on a fractional-scale display means a blurred
 * window and a pen whose coordinates are a scale factor out — on a drawing
 * app, the second one is fatal.
 */
if (process.platform === 'linux' && !app.commandLine.hasSwitch('ozone-platform-hint')) {
  app.commandLine.appendSwitch('ozone-platform-hint', 'auto')
}

/**
 * One copy at a time. A second launch — a PDF opened from Explorer, the
 * Start menu pressed twice — hands its files to the first and leaves: two
 * processes on one `settings.json` and one library each wrote over the
 * other. A probe is not the reader's copy and takes no lock.
 */
if (!probe.isRun && !app.requestSingleInstanceLock()) app.exit(0)

app.on('second-instance', (_event, argv) => {
  const target = windows.main && !windows.main.isDestroyed() ? windows.main : BrowserWindow.getAllWindows()[0]
  if (target) {
    if (target.isMinimized()) target.restore()
    target.show()
    target.focus()
  }
  void openFiles(pdfsIn(argv))
})

/** The PDFs named on a command line: what Explorer's «Open with» passes. */
function pdfsIn(argv: string[]): string[] {
  return argv.slice(1).filter((one) => !one.startsWith('-') && /\.pdf$/i.test(one) && fs.existsSync(one))
}

/** PDFs handed to the app from outside, into the first library. */
async function openFiles(files: string[]) {
  const first = libraries.first
  if (!first || files.length === 0) return
  await sync.run(async () => {
    for (const file of files) {
      try {
        await first.importPDF(file, await pageCount(pageCounter, file))
      } catch (error) {
        console.error(`open file - ${file} could not be added:`, error)
      }
    }
  })
  send('library:changed')
}

// Whatever slips past every other guard is said, not thrown: an exception
// nobody catches in the main process takes every window with it.
process.on('uncaughtException', (error) => console.error('uncaught -', error))
process.on('unhandledRejection', (reason) => console.error('unhandled rejection -', reason))

app.whenReady().then(async () => {
  // A probe is told which folder to open. One that is not — only steps or a
  // picture — would open the reader's own library and notes, and write them.
  if (probe.isRun && !probe.hasLibrary) {
    log('probe: refusing to run without --papertime-library=<folder>')
    app.exit(2)
    return
  }
  // No Dock icon and no menu bar for a probe: an accessory app does not become
  // the active app by being launched, and its windows do not bounce the Dock.
  if (isMac && probe.isRun) {
    app.setActivationPolicy('accessory')
    app.dock?.hide()
  }
  wantsKorean = resolveKorean(probe.language() ?? settings().language, app.getLocale())
  setKorean(wantsKorean)
  markRunning(probe.isRun)
  windows.createMain()
  installMenu()
  // `--papertime-library=<path>` opens a folder without disturbing whichever
  // one the user last had open — the same isolation the Mac build uses so a
  // test never touches a real library. The window's first `library:reload`
  // waits for this open (`LibrarySet.opening`).
  const root = probe.argument('library') ?? settings().libraryRoot
  if (root && fs.existsSync(root)) {
    try {
      send('library:opened', await openLibrary(root))
      void sweepTemporaries([...textSources.values()].map((one) => one.file))
      if (!probe.isRun) await openFiles(pdfsIn(process.argv.slice(app.isPackaged ? 0 : 1)))
    } catch (error) {
      console.error('launch - the library could not be opened:', error)
      send('library:opened', { error: String((error as Error)?.message ?? error) })
    }
  }
  nativeTheme.on('updated', () => send('theme:changed', nativeTheme.shouldUseDarkColors))
  // The accent is the desktop's: when it changes there, the window follows.
  if (process.platform === 'win32') {
    systemPreferences.on('accent-color-changed', () => send('theme:changed', nativeTheme.shouldUseDarkColors))
  }
  app.on('web-contents-created', (_event, contents) => contents.on('destroyed', () => text.forgetWindow(contents)))

  const steps = probe.argument('probe')
  const shot = probe.argument('shot')
  // `--papertime-semantic-index=1` builds the index for the probe library
  // now and says what it cost; `--papertime-semantic-query=<text>` asks it.
  // Then the probe's own steps, if any; otherwise quit.
  const then = () => {
    if (steps && windows.main) void runProbe(windows.main, steps)
    else if (shot && windows.main) void captureAndQuit(windows.main, shot)
    else if (semanticProbe) app.quit()
  }
  // `--papertime-add-folder=`, `--papertime-adopt-loose=1`,
  // `--papertime-folders=1`: the library's errands, said the Mac's way.
  const reports = probe.hasLibrary
    ? runLibraryProbes({ argument: probe.argument, libraries, notes, handlers }).catch((error) => log(`probe: ${String(error)}`))
    : Promise.resolve()
  void reports.then(() => {
    if (semanticProbe) void runSemanticProbe().then(then)
    else then()
  })
})

async function runSemanticProbe() {
  if (!libraries.first) return log('semantic: no library')
  await semantic().build()
  const stats = await semantic().stats()
  const status = semantic().status()
  log(`semantic: status enabled=${status.enabled} ready=${status.ready} passages=${status.passages} notes=${status.notes} notePassages=${status.notePassages}` +
    (stats ? ` · worker loaded=${stats.loaded} loadMs=${stats.loadMs === null ? '-' : Math.round(stats.loadMs)} vectors=${stats.vectors} rss=${stats.rssMB} MB` : ''))
  const query = probe.argument('semantic-query')
  if (!query) return
  for (const round of [1, 2]) {
    const t0 = performance.now()
    const answer = await semantic().search(query, 8)
    const fromNotes = answer.hits.filter((hit) => hit.note).length
    log(`semantic: “${query}” → ${answer.hits.length} passages (${fromNotes} from notes) in ${(performance.now() - t0).toFixed(1)} ms (worker ${answer.ms.toFixed(1)} ms)${round === 2 ? ' · asked again' : ''}`)
    if (round === 2) break
    answer.hits.forEach((hit, i) => {
      if (hit.note) {
        log(`semantic:   ${i + 1}. ${hit.score.toFixed(3)}  NOTE ${hit.note.id} “${hit.note.title.slice(0, 40)}” @${hit.passage.location}+${hit.passage.length} | ${hit.snippet.slice(0, 90)}`)
        return
      }
      const title = textSources.get(hit.passage.paperID)?.title ?? hit.passage.paperID
      log(`semantic:   ${i + 1}. ${hit.score.toFixed(3)}  ${title.slice(0, 40)} · p${hit.passage.pageIndex + 1} @${hit.passage.location}+${hit.passage.length} | ${hit.snippet.slice(0, 90)}`)
    })
  }
}

app.on('window-all-closed', () => {
  if (!isMac) app.quit()
})

/**
 * Nothing is left half done at quit: the PDF writes still waiting are done
 * now, the ones running are waited for, and the journals and settings still
 * held are written — ten seconds at most, then the app goes whatever is
 * left.
 */
let drained = false
let draining = false

app.on('before-quit', (event) => {
  if (drained) return
  event.preventDefault()
  if (draining) return
  draining = true
  void Promise.allSettled([flush.drain(), journals.flush()]).finally(() => {
    flushSettings()
    drained = true
    app.quit()
  })
})

// The text service goes with the app, whatever it was in the middle of.
app.on('will-quit', () => {
  markCleanExit(probe.isRun)
  sync.stop()
  text.end()
  pageCounter.end()
  semanticSearch?.end()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) windows.createMain()
})

/** Papers dropped on the app's icon, or opened from a file manager. */
app.on('open-file', (event, file) => {
  event.preventDefault()
  void openFiles([file])
})
