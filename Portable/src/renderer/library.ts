/**
 * Reading the library, and the errands that change which folders are read.
 *
 * Every snapshot the main process hands back — a reading, an import, a
 * folder added or taken away, the loose PDFs taken in, the trash — reaches
 * the window through `applySnapshot`, the one place that lets go of what
 * has left the library. And snapshots are numbered by when they were asked
 * for: one that was asked for before another already shown is dropped
 * rather than shown over it. Two readings used to be in flight at once
 * often enough — the watcher and a star, a menu and a probe — and whichever
 * answered last won, older or not.
 */
import { call, flags, soloPaperID } from './bridge.js'
import {
  adopt,
  changed,
  failed,
  keepOpen,
  paper as findPaper,
  pruneToLibrary,
  setShelf,
  shelfPapers,
  store,
  WINDOW_SETTINGS,
} from './state.js'
import { adoptNotes } from './notesModel.js'
import { readers, reconcileReaders } from './pageArea.js'
import { dockPaper, showPaper } from './actions/openPapers.js'
import { applyTheme } from './settingsController.js'
import { layoutPanes } from './layout.js'
import { shell, solo } from './shell.js'
import { askForName } from './ui/ask.js'
import { toast } from './ui/toolbar.js'
import { couldNot } from './notices.js'
import { L } from '../shared/lang.js'
import { findPath, isUnder } from '../shared/paths.js'
import type { LibrarySnapshot } from '../shared/api.js'
import { SketchStyle } from '../shared/sketch.js'

type SnapshotAnswer = LibrarySnapshot | { error: string; refused?: true }

/** Numbers handed out when a snapshot is asked for, and the newest shown. */
let asked = 0
let shown = 0

/** A ticket for a snapshot about to be asked for. */
function ticket(): number {
  asked += 1
  return asked
}

/**
 * Shows a snapshot: the library, its notes, and whatever has left it let go
 * of. `ticket` is when it was asked for; one older than what is on screen is
 * dropped. Returns whether it was shown.
 */
export function applySnapshot(snapshot: LibrarySnapshot, at: number = ticket()): boolean {
  if (at < shown) return false
  shown = at
  // From the first-run or the unavailable screen into the columns.
  const wasScreen = !store.root || store.unavailable !== null
  adopt(snapshot)
  if (wasScreen) layoutPanes()
  adoptNotes(snapshot.notes, snapshot.notesFolder)
  // Inside a folder that is gone too: a subfolder of a library that is gone
  // is a shelf of nothing.
  if (store.shelf.kind === 'folder' && !store.roots.some((root) => isUnder((store.shelf as { root: string }).root, root))) {
    setShelf({ kind: 'all' })
  }
  pruneToLibrary()
  reconcileReaders()
  changed('papers', 'shelf', 'notes', 'history')
  for (const reader of readers.values()) reader.update()
  return true
}

/** A snapshot, or why not: a refusal is said, a failure is kept. */
function settle(answer: SnapshotAnswer, at: number, failure: 'addPDFs' | 'finish' | 'keep'): boolean {
  if (!('error' in answer)) return applySnapshot(answer, at)
  if ('refused' in answer) toast(answer.error)
  else if (failure === 'keep') {
    failed(String(answer.error))
    changed('papers', 'shelf')
  } else couldNot(failure, answer.error)
  return false
}

// ------------------------------------------------------------------ reading

let reading: Promise<void> | null = null
let readingAgain: Promise<void> | null = null

/**
 * Reads the library again. While a reading is in flight, every further ask
 * becomes one more reading after it — ten changes in a row are two readings,
 * not ten, and the last one sees all of them.
 */
export function reload(): Promise<void> {
  if (!reading) {
    reading = readOnce().finally(() => { reading = null })
    return reading
  }
  if (!readingAgain) {
    readingAgain = reading.then(() => {
      readingAgain = null
      return reload()
    })
  }
  return readingAgain
}

/** How many times the library has been read, for a probe to count. */
export let readings = 0

async function readOnce() {
  readings += 1
  const at = ticket()
  const snapshot = await call('library:reload')
  // A folder that would not answer used to end here without a word. The rows
  // already on screen stay where they are; the list says what happened and
  // offers to read again.
  settle(snapshot, at, 'keep')
}

/** The main process opened a library of its own accord — the File menu. */
export function libraryOpened(answer: LibrarySnapshot | { error: string }) {
  settle(answer, ticket(), 'keep')
}

// ------------------------------------------------------------------ folders

/** A library folder chosen by hand, opened in place of the ones showing. */
export async function chooseLibrary() {
  const chosen = await call('library:choose')
  if (!chosen) return
  const at = ticket()
  settle(await call('library:open', { root: chosen }), at, 'keep')
}

/** A folder by its path — a suggestion on the first-run screen, a library
 *  opened before, the one that was not there tried again. */
export async function openLibraryAt(root: string) {
  const at = ticket()
  settle(await call('library:open', { root }), at, 'finish')
}

/** Another folder, read beside the ones already open. Also on the File menu. */
export async function addLibraryFolder(root?: string) {
  const at = ticket()
  settle(await call('library:addFolder', root ? { root } : {}), at, 'finish')
}

/** A folder let go of — out of the list only; its files stay where they are. */
export async function removeLibraryFolder(root: string) {
  const at = ticket()
  const snapshot = await call('library:removeFolder', { root })
  if ('error' in snapshot) return
  applySnapshot(snapshot, at)
}

/**
 * The library a PDF added now goes into: the one whose own shelf is showing,
 * as on the Mac (`importDestination`). Nothing — the first library — on every
 * other shelf, a folder inside a library included.
 */
export function importDestination(): string | undefined {
  if (store.shelf.kind !== 'folder') return undefined
  return findPath(store.roots, (store.shelf as { root: string }).root)
}

/** PDFs chosen from the open panel, or dropped on the window. */
export async function addPapers(paths?: string[]) {
  const at = ticket()
  const answer = await call('library:import', { paths, root: importDestination() })
  settle(answer, at, 'addPDFs')
  // What happened, said — a PDF dropped a second time used to look like a
  // drop that did nothing (`importDocuments` → added, duplicates).
  if ('error' in answer || !answer.imported) return
  const { added, duplicates, refused } = answer.imported
  const said: string[] = []
  if (added > 0) said.push(L(`논문 ${added}편을 더했어요.`, `Added ${added} paper${added === 1 ? '' : 's'}.`))
  if (duplicates > 0) said.push(L(`${duplicates}편은 이미 있어요.`, `${duplicates} ${duplicates === 1 ? 'was' : 'were'} already here.`))
  if (refused.length > 0) {
    said.push(L(`PDF ${refused.length}개는 읽지 못했어요.`, `${refused.length} PDF${refused.length === 1 ? '' : 's'} couldn't be read.`))
  }
  if (said.length > 0) toast(said.join(' '))
}

/**
 * «Add the n PDFs left in this folder». One at a time: a second press while
 * one runs would take the same files in beside it, against a folder the
 * watcher is also answering. While it runs the row is a count that falls.
 */
export async function adoptLoose() {
  if (store.adopting !== null) return
  store.adopting = store.looseCount
  changed('papers')
  const at = ticket()
  try {
    settle(await call('library:adoptLoose'), at, 'addPDFs')
  } finally {
    store.adopting = null
    changed('papers')
  }
}

/** A collection of the reader's own, named on a sheet of the window's own:
 *  `window.prompt` throws in Electron, so this row used to do nothing. */
export async function newCollection() {
  const name = await askForName({
    title: L('새 컬렉션', 'New Collection'),
    placeholder: L('컬렉션 이름', 'Collection Name'),
    confirm: L('만들기', 'Create'),
  })
  if (!name) return
  const collections = [...store.collections, {
    id: crypto.randomUUID().toUpperCase(),
    name,
    symbolName: 'folder',
    sortIndex: store.collections.length,
  }]
  await call('collections:save', { collections, root: importDestination() })
  await reload()
}

// ------------------------------------------------------------------- start

export async function start() {
  const saved = await call('settings:get')
  // The keys the window keeps, not the window's size and the folder list besides.
  for (const key of WINDOW_SETTINGS) (store.settings as Record<string, unknown>)[key] = saved[key]
  // The Tools tab comes with the pen, not with the window: a window opened
  // on it had a panel about a drawing nobody was making.
  if (store.settings.inspectorTab === 'tools') store.settings.inspectorTab = 'details'
  // The next shape's style, as it was left.
  if (saved.sketchStyle) {
    try {
      store.sketch.style = SketchStyle.from(JSON.parse(saved.sketchStyle))
    } catch {
      // A style this build cannot read: the default one.
    }
  }
  applyTheme()
  layoutPanes()
  shell.toolbar.update()
  store.windowState = await call('window:state')

  if (!saved.libraryRoot) {
    // Nothing to read, and that is known: the first-run screen.
    store.ready = true
    layoutPanes()
    changed('papers')
    return
  }
  const at = ticket()
  const snapshot = await call('library:reload')
  if ('error' in snapshot && snapshot.unavailable) {
    store.root = null
    store.unavailable = { root: snapshot.unavailable, message: snapshot.error }
    store.ready = true
    layoutPanes()
    changed('papers', 'shelf')
    return
  }
  if ('error' in snapshot) {
    // There is a folder in the settings and it would not be read. Saying so
    // is the whole of it: this used to fall through to a window whose list
    // offered to choose a library folder, as though the one already chosen
    // had never existed.
    store.root = saved.libraryRoot
    failed(String(snapshot.error))
    changed('papers', 'shelf')
    return
  }
  // Something newer arrived while this was being read — the File menu opened
  // another folder — and that is what the window shows.
  if (!applySnapshot(snapshot, at)) return
  if (solo) {
    // A window for one paper: that paper, kept, and nothing else.
    const id = soloPaperID!
    if (findPaper(id)) {
      keepOpen(id)
      await showPaper(id)
      document.title = findPaper(id)?.meta.displayTitle ?? 'Paper Time'
    }
    return
  }
  const first = saved.selectedPaperID && findPaper(saved.selectedPaperID)
    ? saved.selectedPaperID
    : shelfPapers()[0]?.id
  if (first) await showPaper(first)
  // `--papertime-split=1`: the first two papers side by side, for a probe
  // that wants to look at the panes without a drag.
  if (flags.split) {
    const second = shelfPapers().find((entry) => entry.id !== store.selectedID)
    if (second) dockPaper(second.id, 'right')
  }
}
