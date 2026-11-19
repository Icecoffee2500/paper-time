/**
 * The window's columns: the sidebar, the row of panes, the «+» column, the
 * inspector — and the dividers between them.
 *
 * The arrangement is the Mac's, down to the eight-point margin and the
 * ten-point gap that doubles as the resize handle. The row of panes is one to
 * four content panes (1.1, `shared/paneModel.ts`): the list, the page, pinned
 * sidebar items and notes, in the order the hand put them. One arrangement
 * for the window, kept in the settings — not one per place, and no companion
 * pane with rules of its own.
 */
import { clear, el, on } from './dom.js'
import { changed, setShelf, store, type Pane, type Shelf } from './state.js'
import {
  MAX_PANES, PAGE_FLOOR, TABLE_LEAST, chooseInspector, closePane, cycleInspector, defaultRow, enterFocus, ensureList, ensurePage, fitWidths, flexiblePane,
  focusedPanes, insertPane, leaveFocus, movePane, paneOf, paperDropOn, readPanes, reopenPane, restingPanes, rowOf, sameContent, setContent, showPane,
  showsPlusColumn, tableAndPageRoom, tableShownWidth, tableWidest, togglePaneKind, togglePaneState, writePanes, type ContentPane, type InspectorPlace,
  type InspectorShowing, type PaneContent, type PaneRow, type PaneState,
} from '../shared/paneModel.js'
import { dockPaper, keepPaper, showPaper } from './actions/openPapers.js'
import { flags } from './bridge.js'
import { shell, solo } from './shell.js'
import { holdReaderPlaces, keepingPlaces, pageArea, relayoutReaders, returnReaderPlaces } from './pageArea.js'
import { saveSettings } from './settingsController.js'
import { boardInListColumn, boardPlaceNow } from './plans.js'
import { keepPaneViews, paneSymbol, paneTitle, paneView, shelfContent, shelfOfContent } from './ui/paneViews.js'
import { paneOfNode, setPaneChrome } from './ui/paneChrome.js'
import { buildInspectorFrame, type InspectorFrame } from './ui/inspectorFloat.js'
import { installPaneDrop, type PaneDrop, type PaneZone } from './ui/paneDrop.js'
import { dismissToast, showMenu, toast, toastShows, type MenuEntry } from './ui/toolbar.js'
import { icon } from './icons.js'
import { L } from '../shared/lang.js'

/** A column's width as the settings keep it: `table` is the list's own width while it holds the table. */
type Column = 'sidebar' | 'paperList' | 'inspector' | 'table'

/** The narrowest each column can be dragged — the Mac's floors (the table's
 *  is `TABLE_LEAST`) — and the room the page keeps. */
const COLUMN_MIN: Record<Column, number> = { sidebar: 200, paperList: 240, inspector: 280, table: TABLE_LEAST }
const READER_MIN = PAGE_FLOOR
/** A pinned pane's and a note pane's own width, until it is dragged — and how far it can be. */
const PANE_WIDTH: Record<'shelf' | 'note', number> = { shelf: 420, note: 360 }
const PANE_MIN = 260
const PANE_MAX = 960
/** The «+» column at the row's end. */
const PLUS_WIDTH = 22

/** Whether the «+» column stands: out of focus, and while the row has room (`showsPlusColumn`). */
function plusShown(): boolean {
  return showsPlusColumn(store.row, store.focus.on)
}
/** The panes' margin and the gap between two of them — `--margin` and `--gap`. */
const MARGIN = 8
const GAP = 10

// MARK: - The row as it stands

/** Which width the list's pane wears now: the table's or the list's. */
function listColumn(): 'paperList' | 'table' {
  return boardInListColumn() ? 'table' : 'paperList'
}

/** The panes shown now: in focus mode the page alone. */
export function shownPanes(): ContentPane[] {
  if (solo) return []
  return store.focus.on ? focusedPanes(store.row) : store.row.panes
}

/** A plan's calendar takes the list's pane and the page's: the page waits out of sight. */
function boardWide(): boolean {
  return boardPlaceNow() === 'wide' && shownPanes().some((pane) => pane.content.kind === 'list')
}

/** The panes laid out: the shown ones, less the page while the calendar has its room. */
function laidOut(): ContentPane[] {
  const wide = boardWide()
  return shownPanes().filter((pane) => !(wide && pane.content.kind === 'page'))
}

/** The inspector stands in the row: shown, and not floating. */
function inspectorDocked(): boolean {
  return store.settings.panes.inspector && !store.inspectorPlace.floating && !store.focus.on
}

/** The panes' own width, inside their margins. */
function panesWidth(): number {
  const width = shell.panes.clientWidth || window.innerWidth
  return width - 2 * MARGIN
}

/** A pinned pane's or a note pane's width as laid out. */
function ownWidth(pane: ContentPane): number {
  if (pane.content.kind === 'shelf' || pane.content.kind === 'note') return pane.width ?? PANE_WIDTH[pane.content.kind]
  return pane.width ?? READER_MIN
}

/** The room the table and the page share, as the panes stand now: the other panes take theirs first. */
function tableRoom(): number {
  const row = laidOut()
  const flex = flexiblePane(row)
  const others = row.filter((pane) => pane.content.kind !== 'list' && pane.id !== flex).map(ownWidth)
  if (plusShown()) others.push(PLUS_WIDTH)
  return tableAndPageRoom({
    window: panesWidth(),
    sidebar: store.settings.panes.sidebar && !store.focus.on ? store.settings.columns.sidebar : null,
    inspector: inspectorDocked() ? store.settings.columns.inspector : null,
    others,
    gap: GAP,
  })
}

/** The table's width as laid out: what it was given, until the page would lose its reading width (`tableShownWidth`). */
function tableShownNow(): number {
  return tableShownWidth(store.settings.columns.table, tableRoom())
}

/** A column's width as laid out: the table's as it is shown, the others' as kept. */
function columnWidthNow(column: Column): number {
  return column === 'table' ? tableShownNow() : store.settings.columns[column]
}

/** A pane's width as laid out, when it stands at one. */
function paneWidthNow(pane: ContentPane): number {
  return pane.content.kind === 'list' ? columnWidthNow(listColumn()) : ownWidth(pane)
}

/**
 * The widths the fixed panes stand at now: what each wants, until the row has
 * less room than that — then each gives way toward its floor (`fitWidths`),
 * the page keeping a reading width first.
 */
function fittedWidths(): Map<string, number> {
  const row = laidOut()
  const flex = flexiblePane(row)
  const fixed = row.filter((pane) => pane.id !== flex)
  const focus = store.focus.on
  const sidebar = store.settings.panes.sidebar && !focus
  const plus = plusShown()
  const pieces = (sidebar ? 1 : 0) + row.length + (plus ? 1 : 0) + (inspectorDocked() ? 1 : 0)
  const flexPane = row.find((pane) => pane.id === flex)
  const room = panesWidth() - Math.max(pieces - 1, 0) * GAP
    - (sidebar ? store.settings.columns.sidebar : 0)
    - (inspectorDocked() ? store.settings.columns.inspector : 0)
    - (plus ? PLUS_WIDTH : 0)
    - (flexPane ? (flexPane.content.kind === 'page' ? READER_MIN : PANE_MIN) : 0)
  const widths = fitWidths(fixed.map((pane) => ({ wanted: paneWidthNow(pane), least: pane.content.kind === 'list' ? 200 : PANE_MIN })), room)
  return new Map(fixed.map((pane, index) => [pane.id, widths[index]]))
}

/**
 * The window or a column beside it changed width: the fixed panes — the
 * table in the list's pane first of all — take the widths they may have
 * now. Nothing else is laid out again.
 */
export function fitListColumn() {
  if (solo) return
  for (const [id, width] of fittedWidths()) {
    const node = shell.panes.querySelector<HTMLElement>(`:scope > [data-pane-id="${CSS.escape(id)}"]`)
    if (!node || node.style.width === `${width}px`) continue
    node.style.flex = `0 0 ${width}px`
    node.style.width = `${width}px`
  }
}

/** Which panes were on screen last time, so only a new one is seen arriving. */
let panesShown = new Set<string>()

/** The list's pane: the shelf's table, the old list (search results, an
 *  empty library), on a slip-box shelf the slip-box, and on the projects'
 *  the list of projects. */
export function syncListSlot() {
  const notes = (store.shelf.kind === 'notes' || store.shelf.kind === 'knowledge') && !solo
  // A passage followed out of a note: the note beside its paper, where the list was.
  const wanted = notes
    ? (store.slipBox.paperID !== null ? shell.slipBox.side : shell.slipBox.node)
    : store.shelf.kind === 'projects' && !solo ? (store.slipBox.paperID !== null ? shell.projects.sideNode : shell.projects.listNode)
    : boardInListColumn() ? shell.board.node : shell.paperList.node
  if (wanted.parentElement !== shell.listSlot) {
    clear(shell.listSlot)
    shell.listSlot.append(wanted)
  }
}

/** The node a pane is laid out with. */
function paneNode(pane: ContentPane, wide: boolean): HTMLElement {
  switch (pane.content.kind) {
    case 'list': return wide ? shell.board.node : shell.listSlot
    case 'page': return pageArea
    default: return paneView(pane).node
  }
}

// MARK: - The «+» column

const plusColumn = el('div', { class: 'pane-plus', 'data-pane-plus': '' })
const plusGlyph = el('span', { class: 'pane-plus-glyph', html: icon('plus') })
const plusButton = el('button', { class: 'pane-plus-button' }, [plusGlyph])
plusColumn.append(plusButton)
// The menu hangs off the «+» itself, at the column's middle, not off the column's top.
on(plusButton, 'click', () => showPlusMenu(plusGlyph))

/** The words on it go in when it is first laid out, in the window's language then. */
function labelPlus() {
  const words = L('칸 더하기 — 닫은 칸도 여기서 다시 열어요', 'Add a pane — and reopen a closed one')
  plusButton.title = words
  plusButton.setAttribute('aria-label', L('칸 더하기', 'Add a Pane'))
}

// MARK: - The inspector

let inspectorFrame: InspectorFrame | null = null

function frame(): InspectorFrame {
  inspectorFrame ??= buildInspectorFrame(shell.inspector.node, {
    place: () => store.inspectorPlace,
    moved: (place, done) => {
      store.inspectorPlace = place
      if (done) savePanes()
    },
    float: () => setInspectorFloating(true),
    dock: () => setInspectorFloating(false),
    close: () => hideInspector(),
    area: () => shell.panes.getBoundingClientRect(),
  })
  return inspectorFrame
}

/** «띄우기» and «붙이기»: the panes get the docked inspector's room back, or give it again. */
export function setInspectorFloating(floating: boolean) {
  if (solo) return
  if (store.inspectorPlace.floating === floating && store.settings.panes.inspector) return
  applyInspector({ shown: true, floating })
}

/** Whether the inspector shows now, and how. */
export function inspectorShowing(): InspectorShowing {
  return { shown: store.settings.panes.inspector, floating: store.inspectorPlace.floating }
}

/** The inspector as asked: shown or not, docked or floating — laid out once. */
function applyInspector(next: InspectorShowing) {
  if (solo) return
  store.inspectorPlace = { ...store.inspectorPlace, floating: next.floating }
  if (next.shown !== store.settings.panes.inspector) {
    applyPaneState({ ...paneState(), panes: { ...store.settings.panes, inspector: next.shown } })
  } else {
    relayoutPanes()
  }
}

/** ⌘] and the toolbar's button: floating, docked, gone, and floating again (`cycleInspector`). */
export function cycleInspectorPane() {
  applyInspector(cycleInspector(inspectorShowing()))
}

/** «옆에 붙여 보기» and «띄워 보기»: shown that way — or, already shown that way, put away (`chooseInspector`). */
export function showInspector(floating: boolean) {
  applyInspector(chooseInspector(inspectorShowing(), floating))
}

/** The inspector's ×, docked or floating: put away. */
export function hideInspector() {
  if (!store.settings.panes.inspector) return
  applyInspector({ shown: false, floating: store.inspectorPlace.floating })
}

/** The menus' two choices for the inspector — the «+» column's, and the toolbar button's right-click. */
export function inspectorChoices(): MenuEntry[] {
  const now = inspectorShowing()
  return [
    { label: L('옆에 붙여 보기', 'Show Docked'), icon: 'sidebar.right', checked: now.shown && !now.floating, action: () => showInspector(false) },
    { label: L('띄워 보기', 'Show Floating'), icon: 'macwindow.on.rectangle', checked: now.shown && now.floating, action: () => showInspector(true) },
  ]
}

// MARK: - Laying out

export function layoutPanes() {
  const panes = shell.panes
  clear(panes)
  // No library yet, or the one chosen is not there: the whole window says
  // so, not the list column between empty panels.
  if (!solo && store.ready && (!store.root || store.unavailable)) {
    if (store.unavailable) shell.setup.showUnavailable(store.unavailable.root, store.unavailable.message)
    else shell.setup.showSetup()
    panes.append(shell.setup.node)
    panesShown = new Set()
    inspectorFrame?.hide()
    return
  }
  syncListSlot()
  if (solo) {
    // One paper, and nothing else: the reader fills the window.
    pageArea.style.flex = '1 1 auto'
    panes.append(pageArea)
    return
  }
  labelPlus()
  const visible = store.settings.panes
  const focus = store.focus.on
  type Piece = { key: string; node: HTMLElement; width?: number; resizes?: 'trailing'; target?: Column | { pane: string } }
  const pieces: Piece[] = []
  if (visible.sidebar && !focus) pieces.push({ key: 'sidebar', node: shell.sidebar.node, width: store.settings.columns.sidebar, target: 'sidebar' })
  // A plan's calendar (or, with the old list back, any board): the board
  // takes the list's pane and the page's, and the readers wait out of sight
  // where they were left.
  const place = boardPlaceNow()
  placeWas = place
  const wide = boardWide()
  if (wide) {
    holdReaderPlaces()
    shell.board.update()
  } else {
    // Back inside the list's pane, the board is that pane's again — not a
    // pane of its own with a name it wore while it stood wide.
    delete shell.board.node.dataset.paneId
    delete shell.board.node.dataset.paneKind
  }
  const row = laidOut()
  const widths = fittedWidths()
  for (const pane of row) {
    const node = paneNode(pane, wide)
    node.dataset.paneId = pane.id
    node.dataset.paneKind = pane.content.kind
    pieces.push({
      key: pane.id,
      node,
      width: widths.get(pane.id),
      target: pane.content.kind === 'list' ? listColumn() : { pane: pane.id },
    })
  }
  // Not when four panes are open: it could only say «칸은 네 개까지예요», and
  // the panes take its room.
  if (plusShown()) pieces.push({ key: 'plus', node: plusColumn, width: PLUS_WIDTH })
  if (inspectorDocked()) {
    shell.inspector.node.style.flex = ''
    pieces.push({ key: 'inspector', node: shell.inspector.node, width: store.settings.columns.inspector, resizes: 'trailing', target: 'inspector' })
  }
  panes.dataset.single = String(store.row.panes.length <= 1)
  panes.dataset.full = String(store.row.panes.length >= MAX_PANES)

  // A pane that was not here a moment ago comes in; the ones that were stay
  // put. Laying them out re-appends every pane, so without this the whole
  // window flinched whenever one of them was opened.
  const arriving = new Set(pieces.map((piece) => piece.key).filter((key) => !panesShown.has(key)))
  panesShown = new Set(pieces.map((piece) => piece.key))

  pieces.forEach((piece, index) => {
    if (piece.width) {
      piece.node.style.flex = `0 0 ${piece.width}px`
      piece.node.style.width = `${piece.width}px`
    } else {
      piece.node.style.flex = '1 1 auto'
      piece.node.style.width = ''
    }
    piece.node.classList.toggle('pane-arriving', arriving.has(piece.key) && piece.key !== 'plus')
    panes.append(piece.node)
    const next = pieces[index + 1]
    if (!next) return
    // The divider resizes the fixed column beside it — the one on its left,
    // or, when that one takes what room is left, the one on its right. The
    // inspector is to the right of its own, so the same drag has to make it
    // narrower — without this it grew when the pointer went the other way,
    // which is the one thing a divider must never do.
    if (next.resizes === 'trailing' && next.target) {
      panes.append(divider(next.target, true))
    } else if (piece.width && piece.target) {
      panes.append(divider(piece.target, false))
    } else if (next.width && next.target && next.key !== 'plus') {
      panes.append(divider(next.target, true))
    } else {
      panes.append(el('div', { class: 'pane-gap' }))
    }
  })
  // The inspector floating: over the window, with its room given back.
  if (visible.inspector && store.inspectorPlace.floating && !focus) frame().show()
  else inspectorFrame?.hide()
  // Drawn only where it can be seen: closed, or out of focus mode's way, it
  // was rebuilt on every change for nobody (the Mac's `dockedInspectorShown`).
  shell.inspector.refreshIfStale()
  // Back from the board: the papers where they were being read.
  if (!wide) returnReaderPlaces()
  // The table in the list's pane, drawn once it is in place: which columns
  // fit is a question of the width it was given.
  if (place === 'list' && row.some((pane) => pane.content.kind === 'list')) shell.board.update()
  keepPaneViews(new Set(store.row.panes.map((pane) => pane.id)))
}

/** Where the board stood at the last layout. */
let placeWas: 'wide' | 'list' | 'none' = 'none'

/** The shelf or the library changed: the board comes, goes or moves when its place says so. */
export function syncBoard() {
  if (solo || boardPlaceNow() === placeWas) return
  keepingPlaces(() => {
    layoutPanes()
    relayoutReaders()
  })
  shell.toolbar.update()
}

/** The node a divider's target is laid out with. */
function targetNode(target: Column | { pane: string }): HTMLElement | null {
  if (typeof target === 'object') return shell.panes.querySelector<HTMLElement>(`[data-pane-id="${CSS.escape(target.pane)}"]`)
  if (target === 'sidebar') return shell.sidebar.node
  if (target === 'inspector') return shell.inspector.node
  return shell.panes.querySelector<HTMLElement>('[data-pane-kind="list"]')
}

function targetWidth(target: Column | { pane: string }): number {
  if (typeof target === 'object') {
    const pane = store.row.panes.find((one) => one.id === target.pane)
    return pane ? paneWidthNow(pane) : PANE_MIN
  }
  return columnWidthNow(target)
}

/** The width a divider's target stands at on screen — given way in a crowded row, perhaps. */
function shownWidth(target: Column | { pane: string }): number {
  const node = targetNode(target)
  return node ? node.getBoundingClientRect().width : targetWidth(target)
}

/**
 * The widest a column or a pane may be dragged: what the window has, less
 * every other column showing and the room the page keeps. It used to count
 * this column alone, so three wide columns left the page nothing.
 */
export function widestColumn(target: Column | { pane: string }, windowWidth: number): number {
  const row = laidOut()
  const flex = flexiblePane(row)
  const own = typeof target === 'object' ? target.pane : target === 'paperList' || target === 'table' ? row.find((pane) => pane.content.kind === 'list')?.id : null
  let others = 0
  if (store.settings.panes.sidebar && target !== 'sidebar' && !store.focus.on) others += store.settings.columns.sidebar
  if (inspectorDocked() && target !== 'inspector') others += store.settings.columns.inspector
  for (const pane of row) if (pane.id !== own && pane.id !== flex) others += paneWidthNow(pane)
  const room = windowWidth - others - (flex ? READER_MIN : 0)
  // The table is dragged no wider than leaves the page a reading width — the same limit it gives way to.
  const widest = target === 'table' ? Math.min(tableWidest(tableRoom()), room)
    : typeof target === 'object' ? Math.min(PANE_MAX, room) : room
  // Never below the floor: the table's floor is higher than the list's, and
  // a narrow window can leave less room than that (the Mac's 8acd2dc).
  return Math.max(typeof target === 'object' ? PANE_MIN : COLUMN_MIN[target], widest)
}

function divider(target: Column | { pane: string }, inverted: boolean): HTMLElement {
  const node = el('div', { class: 'divider' })
  on(node, 'pointerdown', (event: PointerEvent) => {
    event.preventDefault()
    node.setPointerCapture(event.pointerId)
    node.classList.add('dragging')
    const startX = event.clientX
    // From the width it is shown at: the table may be giving way, and a
    // drag from the width it was given would jump.
    const startWidth = shownWidth(target)
    const widest = widestColumn(target, shell.panes.clientWidth)
    const least = typeof target === 'object' ? PANE_MIN : COLUMN_MIN[target]
    // One column gets wider; nothing else about the window changes. Every
    // move used to lay out all the panes again — sixty times a second.
    let frameID = 0
    const settle = () => {
      frameID = 0
      const column = targetNode(target)
      if (column && typeof target !== 'object' && target !== 'paperList' && target !== 'table') {
        const width = targetWidth(target)
        column.style.flex = `0 0 ${width}px`
        column.style.width = `${width}px`
      }
      // Every fixed pane at the width it may have now — the one dragged
      // included, and the table giving way to a column drawn wider.
      fitListColumn()
      relayoutReaders()
    }
    const move = (moved: PointerEvent) => {
      const travel = inverted ? startX - moved.clientX : moved.clientX - startX
      const width = Math.min(Math.max(startWidth + travel, least), widest)
      if (typeof target === 'object') {
        const pane = store.row.panes.find((one) => one.id === target.pane)
        if (pane) pane.width = Math.round(width)
      } else {
        store.settings.columns[target] = width
      }
      if (!frameID) frameID = requestAnimationFrame(settle)
    }
    const up = () => {
      if (frameID) cancelAnimationFrame(frameID)
      settle()
      node.classList.remove('dragging')
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      if (typeof target === 'object') savePanes()
      else saveSettings({ columns: store.settings.columns })
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  })
  return node
}

// MARK: - Changing the window

function paneState(): PaneState {
  return { panes: store.settings.panes, focus: store.focus }
}

/** The list and paper switches say what the row holds — out of focus mode, which has its own. */
function syncSwitches() {
  if (store.focus.on) return
  store.settings.panes = {
    ...store.settings.panes,
    paperList: paneOf(store.row, 'list') !== null,
    reader: paneOf(store.row, 'page') !== null,
  }
}

/**
 * The arrangement into the settings. A probe neither reads nor writes it: it
 * shares the settings file with the copy in use, and must leave nothing of
 * itself there.
 */
function savePanes() {
  if (solo) return
  const resting = restingPanes(paneState())
  if (flags.probe) {
    saveSettings({ panes: resting })
    return
  }
  const text = writePanes(store.row, store.inspectorPlace)
  store.settings.paneRow = text
  saveSettings({ panes: resting, paneRow: text }, { soon: true })
}

function relayoutPanes() {
  syncSwitches()
  savePanes()
  keepingPlaces(() => {
    layoutPanes()
    shell.toolbar.update()
    relayoutReaders()
  })
  changed('settings', 'panes')
}

function applyPaneState(next: PaneState) {
  store.settings.panes = { ...next.panes }
  store.focus = next.focus
  relayoutPanes()
}

/** A new row put up: written down and laid out. */
function commitRow(next: PaneRow) {
  store.row = next
  relayoutPanes()
}

const freshID = () => crypto.randomUUID().slice(0, 8)

/** The window opening: the arrangement as it was left — or, in a probe, the one every window starts with. */
export function restorePanes() {
  if (solo) return
  const stored = flags.probe ? null : readPanes(store.settings.paneRow)
  if (stored) {
    store.row = rowOf(stored.panes)
    store.inspectorPlace = stored.inspector
  } else if (flags.probe) {
    store.row = defaultRow()
  } else {
    // Before there was a row: the two switches say which of the two.
    const switches = store.settings.panes
    const panes: ContentPane[] = []
    if (switches.paperList) panes.push({ id: 'list', content: { kind: 'list' }, width: null })
    if (switches.reader || panes.length === 0) panes.push({ id: 'page', content: { kind: 'page' }, width: null })
    store.row = rowOf(panes)
  }
  syncSwitches()
}

/** The pane that was the page until something was dropped in its middle: the next paper opens to its right. */
let pageWasHere: string | null = null

/**
 * A paper chosen with no page pane: one comes, to the right of the pane the
 * choice was made in (or of the one that was the page), else at the end.
 */
export function ensurePagePane() {
  if (solo || paneOf(store.row, 'page')) return
  const from = pageWasHere && store.row.panes.some((pane) => pane.id === pageWasHere) ? pageWasHere : store.activePane
  pageWasHere = null
  commitRow(ensurePage(store.row, from, freshID()).row)
}

/** A sidebar row pressed with no list pane: one comes, at the left. */
export function ensureListPane() {
  if (solo || paneOf(store.row, 'list')) return
  commitRow(ensureList(store.row, freshID()).row)
}

/** «칸은 네 개까지예요.» */
function sayFull() {
  toast(L('칸은 네 개까지예요.', 'Four panes at most.'))
}

/** The capsule after a close: the pane's name and the way back, for five seconds. */
let reopenOffer = ''

function offerReopen(name: string) {
  reopenOffer = L(`${name} 칸을 닫았어요`, `Closed ${name}`)
  toast(reopenOffer, { label: L('다시 열기', 'Reopen'), press: () => reopenClosedPane() }, { ms: 5000 })
}

/** Whether the capsule after a close still stands — ⌘Z reopens while it does. */
export function reopenOffered(): boolean {
  return reopenOffer !== '' && toastShows(reopenOffer)
}

/** A pane's ×. The last one stays: there must be something to look at. */
export function closeContentPane(id: string) {
  if (solo) return
  const pane = store.row.panes.find((one) => one.id === id)
  if (!pane) return
  const name = paneTitle(pane)
  const change = closePane(store.row, id)
  if (change.refused) return
  if (lentList === id) lentList = null
  commitRow(change.row)
  offerReopen(name)
}

/** The last closed pane back where it stood — the capsule, ⌘Z, ⇧⌘T — or the one at `at` on the stack. */
export function reopenClosedPane(at?: number) {
  if (solo) return
  let row = store.row
  let index = at ?? row.closed.length - 1
  while (index >= 0) {
    const change = reopenPane(row, index)
    if (change.refused === 'full') return sayFull()
    if (change.refused === 'taken') {
      // A list or a page open again already: that one is not coming back, the one before it may.
      row = change.row
      if (at !== undefined) break
      index = row.closed.length - 1
      continue
    }
    if (change.refused) break
    if (reopenOffer) dismissToast(reopenOffer)
    reopenOffer = ''
    commitRow(change.row)
    return
  }
  if (row !== store.row) store.row = row
}

/** A pane added at the row's end — the «+» column's menu. */
function addPane(content: PaneContent) {
  const change = insertPane(store.row, { id: freshID(), content }, store.row.panes.length)
  if (change.refused === 'full') return sayFull()
  if (change.refused) return
  commitRow(change.row)
}

/** The ⌄'s choice. In the list's pane a shelf is the sidebar's row pressed; the page given something else is that thing, and the next paper opens beside it. */
export function choosePaneContent(id: string, content: PaneContent) {
  const pane = store.row.panes.find((one) => one.id === id)
  if (!pane) return
  if (pane.content.kind === 'list' && content.kind === 'shelf') {
    const shelf = shelfOfContent(content)
    if (shelf) chooseShelfHere(shelf)
    return
  }
  if (pane.content.kind === 'page' && content.kind !== 'page') pageWasHere = id
  commitRow(setContent(store.row, id, content).row)
}

/** The same as pressing the sidebar's row. */
function chooseShelfHere(shelf: Shelf) {
  setShelf(shelf)
  changed('shelf')
}

/**
 * A sidebar row or a pane's head let go of over the row. In the middle of the
 * list's pane a shelf is the sidebar's row pressed; in the page's middle the
 * page becomes that shelf (and the next paper opens beside it); a pane's head
 * in another's middle trades places with it. On either side, a new pane — or
 * the moved one — stands there. `target` null is the «+» column: at the end.
 */
export function dropOnPane(target: string | null, zone: PaneZone, what: PaneDrop) {
  if (solo) return
  if ('paper' in what) return dropPaperOnPane(target, zone, what.paper, what.moving)
  const shelf = 'shelf' in what ? (what.shelf as Shelf) : null
  const moving = 'pane' in what ? what.pane : null
  if (target === null) {
    if (moving) {
      const last = store.row.panes[store.row.panes.length - 1]
      if (last && last.id !== moving) commitRow(movePane(store.row, moving, last.id, 'right').row)
      return
    }
    if (shelf) addPane(shelfContent(shelf))
    return
  }
  const pane = store.row.panes.find((one) => one.id === target)
  if (!pane) return
  if (moving) {
    if (moving === target) return
    commitRow(movePane(store.row, moving, target, zone === 'middle' ? 'swap' : zone).row)
    return
  }
  if (!shelf) return
  if (zone === 'middle') {
    choosePaneContent(target, shelfContent(shelf))
    return
  }
  const at = store.row.panes.indexOf(pane) + (zone === 'right' ? 1 : 0)
  const change = insertPane(store.row, { id: freshID(), content: shelfContent(shelf) }, at)
  if (change.refused === 'full') return sayFull()
  if (change.refused) return
  commitRow(change.row)
}

/**
 * A paper let go of over a pane that is not the page — or over the «+»
 * column (`target` null). Papers stand side by side on the page, so with a
 * page open it opens beside the page's paper, on the side that faces the
 * pane it was put on; with none, a page comes where it was put, showing it
 * (`paperDropOn`, the Mac's `AppModel.dropPaper`). The same paper twice is
 * one more pane of it. Dragged by a side-by-side pane's title (`moving`),
 * that pane moves rather than a new one opening.
 */
export function dropPaperOnPane(target: string | null, zone: PaneZone, id: string, moving?: string) {
  if (solo) return
  const plan = paperDropOn(store.row, target, zone)
  if (!plan) return
  if (plan.kind === 'beside') {
    // Nothing on the page to stand beside: the paper is simply shown there.
    if (!store.selectedID && !store.split) {
      void showPaper(id)
      keepPaper(id)
      return
    }
    dockPaper(id, plan.side, moving)
    return
  }
  const change = insertPane(store.row, { id: freshID(), content: { kind: 'page' } }, plan.at)
  if (change.refused === 'full') return sayFull()
  if (change.refused) return
  commitRow(change.row)
  void showPaper(id, false, { arrange: false })
  keepPaper(id)
}

/**
 * A note or a pinned item opened beside the work in front — a project's note,
 * its «Show Papers Beside». A pane showing it already is enough; a note pane
 * that stands takes the note; otherwise one comes, to the right of the pane
 * in use.
 */
export function openBeside(content: PaneContent) {
  if (solo) return
  if (store.row.panes.some((pane) => sameContent(pane.content, content))) return
  if (content.kind === 'note') {
    const notePane = store.row.panes.find((pane) => pane.content.kind === 'note')
    if (notePane) {
      setPaneNote(notePane.id, content.note)
      return
    }
  }
  const from = store.row.panes.findIndex((pane) => pane.id === store.activePane)
  const change = insertPane(store.row, { id: freshID(), content }, from >= 0 ? from + 1 : store.row.panes.length)
  if (change.refused === 'full') return sayFull()
  if (change.refused) return
  commitRow(change.row)
}

/** A note pane's note picked, or put back for another: written down; the pane draws itself again. */
export function setPaneNote(id: string, note: string | null) {
  store.row = { ...store.row, panes: store.row.panes.map((pane) => (pane.id === id && pane.content.kind === 'note' ? { ...pane, content: { kind: 'note', note } } : pane)) }
  savePanes()
  changed('panes')
}

// MARK: - The menus

/** What a pane can show — the ⌄'s list, and the «+»'s. `current` is checked. */
export function paneChoices(apply: (content: PaneContent) => void, current?: PaneContent): MenuEntry[] {
  const currentShelf = current?.kind === 'shelf' ? current.shelf : current?.kind === 'list' ? shelfContent(store.shelf).shelf : null
  const shelfItem = (label: string, glyph: string, shelf: Shelf): MenuEntry => {
    const content = shelfContent(shelf)
    return { label, icon: glyph, checked: currentShelf === content.shelf, action: () => apply(content) }
  }
  return [
    shelfItem(L('논문', 'Papers'), 'text.document', { kind: 'kind', of: 'paper' }),
    shelfItem(L('책', 'Books'), 'book', { kind: 'kind', of: 'book' }),
    shelfItem(L('문서', 'Documents'), 'doc', { kind: 'kind', of: 'document' }),
    shelfItem(L('이번 주', 'This Week'), 'calendar', { kind: 'week' }),
    {
      label: L('계획', 'Plans'),
      icon: 'point.topleft.down.to.point.bottomright.curvepath',
      children: store.plans.length === 0
        ? [{ label: L('계획이 없어요', 'No Plans'), disabled: true }]
        : store.plans.map((one) => shelfItem(one.plan.name, 'point.topleft.down.to.point.bottomright.curvepath', { kind: 'plan', id: one.plan.id })),
    },
    shelfItem(L('문헌 노트', 'Literature Notes'), 'text.quote', { kind: 'notes' }),
    shelfItem(L('지식', 'Knowledge'), 'lightbulb', { kind: 'knowledge', area: null }),
    {
      label: L('프로젝트', 'Projects'),
      icon: 'flag',
      children: [
        shelfItem(L('모든 프로젝트', 'All Projects'), 'flag', { kind: 'projects', id: null }),
        ...(store.projects.length ? [{ separator: true } as MenuEntry] : []),
        ...store.projects.map((one) => shelfItem(one.project.name, 'flag', { kind: 'projects', id: one.project.id })),
      ],
    },
    { label: L('노트', 'Note'), icon: 'square.and.pencil', checked: current?.kind === 'note', action: () => apply({ kind: 'note', note: null }) },
  ]
}

/** The ⌄ on a pane's head: what this pane shows. */
export function showPaneMenu(id: string, anchor: Element) {
  const pane = store.row.panes.find((one) => one.id === id)
  if (!pane) return
  showMenu(anchor, [
    { caption: L('이 칸에 보일 것', 'Show in This Pane') },
    ...paneChoices((content) => choosePaneContent(id, content), pane.content),
  ], 'right')
}

/** The «+» column's menu: a new pane, and the closed ones to open again. */
export function showPlusMenu(anchor: Element) {
  const entries: MenuEntry[] = [{ caption: L('새 칸', 'New Pane') }]
  if (!paneOf(store.row, 'page')) {
    entries.push({ label: L('논문', 'Paper'), detail: L('고른 논문을 읽는 칸', 'Where the chosen paper opens'), icon: 'text.page', action: () => addPane({ kind: 'page' }) })
  }
  entries.push(...paneChoices(addPane))
  const closed = store.row.closed
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry }) => !(entry.pane.content.kind === 'list' || entry.pane.content.kind === 'page') || !paneOf(store.row, entry.pane.content.kind))
    .reverse()
  entries.push({ separator: true }, {
    label: L('닫은 칸 다시 열기', 'Reopen Closed Pane'),
    icon: 'arrow.uturn.backward',
    children: closed.length === 0
      ? [{ label: L('닫은 칸이 없어요', 'No Closed Panes'), disabled: true }]
      : closed.map(({ entry, index }) => ({ label: paneTitle(entry.pane), icon: paneSymbol(entry.pane), action: () => reopenClosedPane(index) })),
  })
  // The inspector, docked or floating — wherever it was left, and whether it
  // shows at all (the Mac's `inspectorItems`, 2026-11-18: «info 창을 한번
  // 지우면, 그 다음에 floating으로 띄우고 싶으면 어떻게 해야 하지?»).
  entries.push({ separator: true }, { caption: L('인스펙터', 'Inspector') }, ...inspectorChoices())
  showMenu(anchor, entries, 'right')
}

// MARK: - The toolbar's switches and focus mode

/**
 * The list's pane lent to a paper opened from the slip-box or a project —
 * the note or the project stands there beside the paper — and taken back
 * when the paper goes, without a capsule: nobody closed it.
 */
let lentList: string | null = null

export function lendListColumn() {
  if (solo || paneOf(store.row, 'list')) return
  const change = ensureList(store.row, freshID())
  lentList = change.pane ?? null
  commitRow(change.row)
}

export function returnListColumn() {
  if (!lentList) return
  const id = lentList
  lentList = null
  const change = closePane(store.row, id)
  if (change.refused) return
  commitRow({ ...change.row, closed: store.row.closed })
}

/**
 * A column on or off. The sidebar and the inspector are switches; the list
 * and the paper are panes in the row — closed onto the stack, or back where
 * they were (`togglePaneKind`). Asking for the paper in focus mode, which is
 * the paper and nothing else, leaves focus mode.
 */
export function togglePane(pane: Pane) {
  if (solo) return
  if (pane === 'inspector') {
    cycleInspectorPane()
    return
  }
  if (pane === 'sidebar') {
    applyPaneState(togglePaneState(paneState(), pane))
    return
  }
  if (pane === 'paperList') lentList = null
  if (store.focus.on) {
    const out = leaveFocus(paneState())
    store.settings.panes = { ...out.panes }
    store.focus = out.focus
    if (pane === 'reader' || paneOf(store.row, 'list')) {
      relayoutPanes()
      return
    }
  }
  commitRow(togglePaneKind(store.row, pane === 'paperList' ? 'list' : 'page', freshID()).row)
}

/** Shows a pane that is hidden — the pen bringing the Tools tab, a note
 *  opening in the inspector, a paper opened — in focus mode too, as the Mac does. */
export function revealPane(pane: Pane) {
  if (solo) return
  if (pane === 'reader') return ensurePagePane()
  if (pane === 'paperList') return ensureListPane()
  if (store.settings.panes[pane]) return
  applyPaneState(showPane(paneState(), pane))
}

/**
 * The paper and nothing else — and the way back. What it hid is remembered,
 * or leaving focus mode means putting three columns back by hand.
 */
export function setFocusMode(on: boolean) {
  if (solo || on === store.focus.on) return
  if (on && !paneOf(store.row, 'page')) store.row = ensurePage(store.row, null, freshID()).row
  applyPaneState(on ? enterFocus(paneState()) : leaveFocus(paneState()))
}

export function toggleFocus() {
  setFocusMode(!store.focus.on)
}

// MARK: - Installing

/** The ⌄, the ×, the drops and the presses that say which pane is in use. */
export function installPanes() {
  if (solo) return
  setPaneChrome({ menu: showPaneMenu, close: closeContentPane })
  // The inspector's «띄우기» and × stand over its corner from the start.
  frame()
  installPaneDrop(shell.panes, { drop: dropOnPane, besidePage: () => paneOf(store.row, 'page') !== null })
  // The pane a press lands in is the one in use: a paper chosen there opens beside it.
  on(shell.panes, 'pointerdown', (event: PointerEvent) => {
    const id = paneOfNode(event.target as Element)
    if (id) store.activePane = id
  }, { capture: true })
}

/** The inspector's place as it would be written — for a probe. */
export function inspectorPlaceNow(): InspectorPlace & { showing: boolean } {
  return { ...store.inspectorPlace, showing: inspectorFrame?.showing() ?? false }
}
