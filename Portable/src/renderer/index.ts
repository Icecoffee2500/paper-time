/**
 * The window.
 *
 * Four panels on a ground, a toolbar above them, and the keys that drive the
 * lot. The arrangement is the Mac's, because a person who reads on one
 * machine and writes on another should not have to find anything twice. A
 * window opened for one paper (`--papertime-paper=<id>`) is this same page
 * showing only that reader.
 *
 * This file builds the panes, hands each the actions it offers, and says
 * which pane redraws when what changes. The actions live beside it:
 * `library.ts` (reading and the folders), `actions/*` (what is done to a
 * paper, which papers are open, notes, search), `pageArea.ts` (the readers),
 * `layout.ts` (the columns), `settingsController.ts`, `keys.ts`,
 * `commands.ts` (the menu and the main process's events), `dockDrop.ts`,
 * `listSearch.ts`, `probe.ts`.
 */
import { copyText } from './ui/clipboard.js'
import { call, platform } from './bridge.js'
import { el } from './dom.js'
// Imported for its side effect: the sheet registers its own ⌥⌘/ so nothing
// in the shell has to know it exists.
import './ui/feedback.js'
import { changed, readerState, setShelf, store, subscribe, type InspectorTab, type Shelf, type SketchTool } from './state.js'
import { shell, solo } from './shell.js'
import { buildToolbar, showMenu, toast } from './ui/toolbar.js'
import { buildSidebar } from './ui/sidebar.js'
import { buildPaperList } from './ui/paperList.js'
import { buildInspector } from './ui/inspector.js'
import { buildSlipBox } from './ui/slipBox.js'
import { buildSketchRack } from './ui/sketchToolbar.js'
import { refreshOpenPapers } from './ui/openPapers.js'
import { flushPositions, focused, reconcileReaders, relayoutReadersSoon } from './pageArea.js'
import {
  addLibraryFolder, addPapers, adoptLoose, chooseLibrary, newCollection, reload, removeLibraryFolder, start,
} from './library.js'
import {
  attach, attachmentsMenu, copyKey, detach, editMeta, editState, fileUnder, paperMenu, renamePaper, setKind,
  statusMenu, toggleFavorite,
} from './actions/paper.js'
import {
  closePaper, extendSelection, goBack, goForward, keepPaper, openAnchor, pickPaper, selectAllPapers, showPaper, stepPaper,
  stepPaperTo,
} from './actions/openPapers.js'
import { openAnchorFromSlipBox, openNote } from './actions/notes.js'
import { openPassage, openSearch } from './actions/search.js'
import { clearSearchResults, installListSearch, scanListText } from './listSearch.js'
import { installTheme, openSettings, saveSettings, setInspectorTab } from './settingsController.js'
import { layoutPanes, revealPane, syncListSlot, togglePane } from './layout.js'
import { applyUndo, installKeys, pickTool } from './keys.js'
import { installMainEvents } from './commands.js'
import { installDockDrop, installFileDrop } from './dockDrop.js'
import { installRejectionNotice } from './notices.js'
import { installSheetModality } from './ui/sheet.js'
import { installProbeSurface } from './probe.js'
import { showMoreMenu } from './moreMenu.js'
import { L } from '../shared/lang.js'
import { authorShelf, isPinned } from './state.js'

document.body.dataset.platform = platform
if (solo) document.body.dataset.solo = 'true'

const root = document.getElementById('root')!
shell.panes = el('div', { class: 'panes' })
shell.listSlot = el('div', { class: 'pane-slot' })

// ---------------------------------------------------------------- the panes

const chooseShelf = (shelf: Shelf) => {
  setShelf(shelf)
  changed('shelf')
}

shell.sidebar = buildSidebar({
  select: chooseShelf,
  addFolder: () => void addLibraryFolder(),
  removeFolder: (folder) => void removeLibraryFolder(folder),
  newCollection: () => void newCollection(),
  clearSearch: () => clearSearchResults(),
  revealFolder: (folder) => void call('library:revealFolder', { root: folder }),
  file: (paperIDs, shelf) => void fileUnder(paperIDs, shelf),
})

shell.paperList = buildPaperList({
  chooseLibrary: () => void chooseLibrary(),
  open: (id) => void showPaper(id),
  pick: (id, mode) => pickPaper(id, mode),
  extend: (by) => extendSelection(by),
  selectAll: () => selectAllPapers(),
  stepTo: (index) => stepPaperTo(index),
  openSearch: () => openSearch(),
  statusMenu,
  attachments: attachmentsMenu,
  attach: (children, parent) => void attach(children, parent),
  toggleFavorite: (id) => void toggleFavorite(id),
  togglePin: (id) => {
    if (isPinned(id)) closePaper(id)
    else keepPaper(id, true)
  },
  close: (id) => closePaper(id),
  contextMenu: paperMenu,
  addPapers: () => void addPapers(),
  adoptLoose: () => void adoptLoose(),
  refresh: () => void reload(),
  openPassage: (hit, byMeaning) => void openPassage(hit, byMeaning ? '' : store.searchQuery),
  openNote: (id) => void openNote(id),
  step: (by) => stepPaper(by),
})

/** The slip-box, shown while the sidebar's «Notes» row is chosen: the list
 *  of notes in the list column and the open note in the page area. */
shell.slipBox = buildSlipBox({
  paper: (id) => store.papers.find((entry) => entry.id === id),
  openAnchor: (place) => void openAnchorFromSlipBox(place),
  openNote: (id) => void openNote(id),
})

shell.inspector = buildInspector({
  editMeta: (id, patch) => void editMeta(id, patch),
  editState: (id, patch) => void editState(id, patch),
  reveal: (id) => void call('paper:reveal', { id }),
  rename: renamePaper,
  copyKey: (id) => void copyKey(id),
  setKind: (id, kind) => void setKind(id, kind),
  openAuthor: (name) => {
    const shelf = authorShelf(name)
    if (shelf) chooseShelf(shelf)
  },
  sketchChanged: () => {
    changed('sketch')
    // The style the next shape gets, kept for the next launch.
    saveSettings({ sketchStyle: JSON.stringify(store.sketch.style.encode()) }, { soon: true })
  },
  marks: () => {
    const reader = focused()
    if (!reader) return []
    return reader.marksLoaded ? reader.marksList() : null
  },
  showMarksTab: () => {
    // The Mac's `revealedMarkID`: the inspector shows, on its Marks tab.
    setInspectorTab('marks')
    revealPane('inspector')
  },
  revealMark: (pageIndex, id) => void focused()?.revealMark(pageIndex, id),
  removeMark: (pageIndex, id) => focused()?.removeMark(pageIndex, id),
  commentMark: (pageIndex, id, comment) => focused()?.setMarkComment(pageIndex, id, comment),
  copyText: (text) => {
    if (!text) return
    void copyText(text).then((copied) => toast(copied ? L('복사했어요', 'Copied') : L('복사하지 못했어요', "Paper Time couldn't copy that.")))
  },
  markMenu: (anchor, entries) => showMenu(anchor, entries),
  openNote: (id) => void openNote(id),
  open: (id) => void showPaper(id),
  detach: (id) => void detach(id),
  openAnchor: (place) => void openAnchor(place),
})

/**
 * The rack picks the tool and works the undo stack; everything that acts on
 * the selection goes through `sketchEditor.current`, the view over the page
 * that holds it (`sketchInput.ts`), so the rack, the Tools tab and the keys
 * are three ways of saying the same thing to one place.
 */
shell.rack = buildSketchRack({
  setTool: (tool: SketchTool) => pickTool(tool),
  undo: () => applyUndo(false),
  redo: () => applyUndo(true),
})

shell.toolbar = buildToolbar({
  togglePane,
  back: () => goBack(),
  forward: () => goForward(),
  search: () => openSearch(),
  addPapers: () => void addPapers(),
  setInspectorTab: (tab: InspectorTab) => setInspectorTab(tab),
  moreMenu: showMoreMenu,
  settings: () => openSettings(),
  minimize: () => void call('window:minimize'),
  toggleMaximize: () => void call('window:toggleMaximize'),
  close: () => void call('window:close'),
})

root.append(shell.toolbar.node, shell.panes)

// ------------------------------------------------------------- redrawing

let wasDrawing = false
/** The inspector's tab before the pen came out, to go back to. */
let tabBeforeDrawing: InspectorTab | null = null

/** Picking up the pen brings the Tools tab forward, as it does on the Mac,
 *  and putting it down gives the panel back — the tab that was showing
 *  before, unless another was chosen with the pen in hand. */
function followThePen() {
  const drawing = readerState().drawing
  if (drawing && !wasDrawing) {
    if (store.settings.inspectorTab !== 'tools') {
      tabBeforeDrawing = store.settings.inspectorTab
      store.settings.inspectorTab = 'tools'
      saveSettings({ inspectorTab: 'tools' })
    }
    // The Tools tab is where the drawing's style is set. Not in focus mode,
    // which hid the inspector on purpose.
    revealPane('inspector')
  } else if (!drawing && wasDrawing) {
    if (store.settings.inspectorTab === 'tools' && tabBeforeDrawing) {
      store.settings.inspectorTab = tabBeforeDrawing
      saveSettings({ inspectorTab: tabBeforeDrawing })
      shell.inspector.update()
    }
    tabBeforeDrawing = null
  }
  wasDrawing = drawing
}

/**
 * The rack, the Tools tab and the selection's handles, once a frame. A
 * marquee sweeps the selection on every pointer move, and each move used to
 * build the rack and the whole Tools tab again and draw every page of the
 * paper — sixty times a second, for a box being dragged.
 */
let drawingFrame = 0

function drawingSoon() {
  if (drawingFrame) return
  drawingFrame = requestAnimationFrame(() => {
    drawingFrame = 0
    shell.rack.update()
    if (store.settings.inspectorTab === 'tools') shell.inspector.update()
    const reader = focused()
    reader?.redrawOverlays()
    reader?.update()
  })
}

subscribe((keys) => {
  const onNotesShelf = store.shelf.kind === 'notes' && !solo
  if (keys.has('shelf')) {
    syncListSlot()
    reconcileReaders()
  }
  if (keys.has('notes') || keys.has('slipBox') || keys.has('papers')) {
    if (onNotesShelf) {
      shell.slipBox.update()
      reconcileReaders()
    }
    if (keys.has('notes') && store.settings.inspectorTab === 'note') shell.inspector.update()
    if (keys.has('notes')) shell.sidebar.update()
  }
  if (keys.has('shelf') || keys.has('papers')) scanListText()
  if (keys.has('papers') || keys.has('shelf') || keys.has('selection')) {
    shell.sidebar.update()
    shell.paperList.update()
    shell.inspector.update()
    refreshOpenPapers()
  } else if (keys.has('searchResults')) {
    shell.paperList.update()
  }
  if (keys.has('inspector')) shell.inspector.update()
  if (keys.has('marks') && store.settings.inspectorTab === 'marks') shell.inspector.update()
  if (keys.has('sketch')) {
    followThePen()
    drawingSoon()
  }
  if (keys.has('reader')) focused()?.update()
  shell.toolbar.update()
  tellMenu()
})

/** What the menu bar should say for this window — sent when it changes. */
let menuSaid = ''

function tellMenu() {
  const state = {
    panes: { ...store.settings.panes },
    focus: store.focus.on,
    hasPaper: Boolean(store.selectedID && focused()),
    layout: store.settings.pageLayout,
  }
  const said = JSON.stringify(state)
  if (said === menuSaid) return
  menuSaid = said
  void call('menu:state', state).catch(() => undefined)
}

// Coming to the front, this window speaks for the menu bar again.
window.addEventListener('focus', () => {
  menuSaid = ''
  tellMenu()
})

// ------------------------------------------------------------------- start

installRejectionNotice()
installSheetModality()
installTheme()
installKeys()
installDockDrop()
installFileDrop()
installListSearch()
installMainEvents()
window.addEventListener('resize', () => relayoutReadersSoon())
// Where each paper was left, written as the window goes.
window.addEventListener('beforeunload', () => void flushPositions())
installProbeSurface()
layoutPanes()
void start()
