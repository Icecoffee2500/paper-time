/**
 * The four columns and the dividers between them.
 *
 * The arrangement is the Mac's, down to the eight-point margin and the
 * ten-point gap that doubles as the resize handle.
 */
import { clear, el, on } from './dom.js'
import { changed, store, type Pane } from './state.js'
import {
  PAGE_FLOOR, TABLE_LEAST, enterFocus, leaveFocus, restingPanes, showPane, tableAndPageRoom, tableShownWidth, tableWidest, togglePaneState,
  type PaneState,
} from '../shared/paneModel.js'
import { shell, solo } from './shell.js'
import { holdReaderPlaces, keepingPlaces, pageArea, relayoutReaders, returnReaderPlaces } from './pageArea.js'
import { saveSettings } from './settingsController.js'
import { boardInListColumn, boardPlaceNow } from './plans.js'

/** A column's width as the settings keep it: `table` is the list column's
 *  own width while it holds the table. */
type Column = 'sidebar' | 'paperList' | 'inspector' | 'table'

/** The narrowest each column can be dragged — the Mac's floors (the table's
 *  is `TABLE_LEAST`) — and the room the page keeps. */
const COLUMN_MIN: Record<Column, number> = { sidebar: 200, paperList: 240, inspector: 280, table: TABLE_LEAST }
const READER_MIN = PAGE_FLOOR
/** The panes' margin and the gap between two of them — `--margin` and `--gap`. */
const MARGIN = 8
const GAP = 10

/** Which width the list column wears now: the table's or the list's. */
function listColumn(): 'paperList' | 'table' {
  return boardInListColumn() ? 'table' : 'paperList'
}

/** The panes' own width, inside their margins — the window's, before they are laid out. */
function panesWidth(): number {
  const width = shell.panes.clientWidth || window.innerWidth
  return width - 2 * MARGIN
}

/** The room the table and the page share, as the panes stand now. */
function tableRoom(): number {
  const visible = store.settings.panes
  return tableAndPageRoom({
    window: panesWidth(),
    sidebar: visible.sidebar ? store.settings.columns.sidebar : null,
    inspector: visible.inspector ? store.settings.columns.inspector : null,
    gap: GAP,
  })
}

/**
 * The table's width as laid out: what it was given, until the page would
 * lose its reading width — then the table gives way, and has its width back
 * when the room does (`tableShownWidth`, the Mac's `tableShown`).
 */
function tableShownNow(): number {
  return tableShownWidth(store.settings.columns.table, tableRoom())
}

/** A column's width as laid out: the table's as it is shown, the others' as kept. */
function columnWidthNow(pane: Column): number {
  return pane === 'table' ? tableShownNow() : store.settings.columns[pane]
}

/**
 * The window or a column beside it changed width: the table in the list's
 * column takes the width it may have now. Nothing else is laid out again.
 */
export function fitListColumn() {
  if (solo || listColumn() !== 'table' || !store.settings.panes.reader || !store.settings.panes.paperList) return
  if (shell.listSlot.parentElement !== shell.panes) return
  const width = tableShownNow()
  if (shell.listSlot.style.width === `${width}px`) return
  shell.listSlot.style.flex = `0 0 ${width}px`
  shell.listSlot.style.width = `${width}px`
}

/** Which panes were on screen last time, so only a new one is seen arriving. */
let panesShown = new Set<Pane>()

/** The list column: the shelf's table, the old list (search results, an
 *  empty library), or on the Notes shelf the slip-box. */
export function syncListSlot() {
  const notes = store.shelf.kind === 'notes' && !solo
  // A passage followed out of a note: the note beside its paper, where the list was.
  const wanted = notes
    ? (store.slipBox.paperID !== null ? shell.slipBox.side : shell.slipBox.node)
    : boardInListColumn() ? shell.board.node : shell.paperList.node
  if (wanted.parentElement !== shell.listSlot) {
    clear(shell.listSlot)
    shell.listSlot.append(wanted)
  }
}

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
    return
  }
  syncListSlot()
  if (solo) {
    // One paper, and nothing else: the reader fills the window.
    pageArea.style.flex = '1 1 auto'
    panes.append(pageArea)
    return
  }
  const visible = store.settings.panes
  const pieces: { pane: Pane; node: HTMLElement; width?: number; resizes?: 'leading' | 'trailing' }[] = []
  if (visible.sidebar) pieces.push({ pane: 'sidebar', node: shell.sidebar.node, width: store.settings.columns.sidebar })
  // A plan's calendar (or, with the old list back, any board): the board
  // takes the list's place and the page's, and the readers wait out of
  // sight where they were left. A shelf's table stands in the list's
  // column, with the page beside it.
  const place = boardPlaceNow()
  placeWas = place
  const board = place === 'wide'
  if (board) {
    holdReaderPlaces()
    pieces.push({ pane: 'reader', node: shell.board.node })
    shell.board.update()
  } else {
    // With the paper hidden the list is what is being read: it fills the
    // window, as the Mac's does, rather than standing at its width beside
    // nothing.
    if (visible.paperList) {
      pieces.push({ pane: 'paperList', node: shell.listSlot, width: visible.reader ? columnWidthNow(listColumn()) : undefined })
    }
    if (visible.reader) pieces.push({ pane: 'reader', node: pageArea })
  }
  if (visible.inspector) {
    pieces.push({ pane: 'inspector', node: shell.inspector.node, width: store.settings.columns.inspector, resizes: 'trailing' })
  }

  // A pane that was not here a moment ago comes in; the ones that were stay
  // put. Laying them out re-appends every pane, so without this the whole
  // window flinched whenever one of them was opened.
  const arriving = new Set(pieces.map((piece) => piece.pane).filter((pane) => !panesShown.has(pane)))
  panesShown = new Set(pieces.map((piece) => piece.pane))

  pieces.forEach((piece, index) => {
    if (piece.width) {
      piece.node.style.flex = `0 0 ${piece.width}px`
      piece.node.style.width = `${piece.width}px`
    } else {
      piece.node.style.flex = '1 1 auto'
      piece.node.style.width = ''
    }
    piece.node.classList.toggle('pane-arriving', arriving.has(piece.pane))
    panes.append(piece.node)
    const next = pieces[index + 1]
    if (!next) return
    // The divider resizes the fixed column beside it. The inspector is to the
    // right of its own, so the same drag has to make it narrower — without
    // this it grew when the pointer went the other way, which is the one thing
    // a divider must never do.
    const resizesNext = next.resizes === 'trailing'
    const target = resizesNext ? next : piece
    if (!target.width) return
    panes.append(divider(target.pane === 'paperList' ? listColumn() : target.pane as Column, resizesNext))
  })
  // Back from the board: the papers where they were being read.
  if (!board) returnReaderPlaces()
  // The table in the list's column, drawn once it is in place: which
  // columns fit is a question of the width it was given.
  if (place === 'list' && visible.paperList) shell.board.update()
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

/** The panel a column's name stands for. */
function paneNode(pane: Column): HTMLElement {
  if (pane === 'sidebar') return shell.sidebar.node
  if (pane === 'paperList' || pane === 'table') return shell.listSlot
  return shell.inspector.node
}

/**
 * The widest a column may be dragged: what the window has, less every other
 * column showing and the room the page keeps. It used to count this column
 * alone, so three wide columns left the page nothing.
 */
export function widestColumn(pane: Column, windowWidth: number): number {
  const visible = store.settings.panes
  const list = listColumn()
  const shown = (['sidebar', 'paperList', 'inspector'] as const).filter((one) => visible[one])
  const others = shown
    .map((one): Column => (one === 'paperList' ? list : one))
    .filter((one) => one !== pane)
    .reduce((sum, one) => sum + columnWidthNow(one), 0)
  const room = windowWidth - others - (visible.reader ? READER_MIN : 0)
  // The table is dragged no wider than leaves the page a reading width —
  // the same limit it gives way to.
  const widest = pane === 'table' ? Math.min(tableWidest(tableRoom()), room) : room
  // Never below the floor: the table's floor is higher than the list's, and
  // a narrow window can leave less room than that (the Mac's 8acd2dc).
  return Math.max(COLUMN_MIN[pane], widest)
}

function divider(pane: Column, inverted: boolean): HTMLElement {
  const node = el('div', { class: 'divider' })
  on(node, 'pointerdown', (event: PointerEvent) => {
    event.preventDefault()
    node.setPointerCapture(event.pointerId)
    node.classList.add('dragging')
    const startX = event.clientX
    // From the width it is shown at: the table may be giving way, and a
    // drag from the width it was given would jump.
    const startWidth = columnWidthNow(pane)
    const widest = widestColumn(pane, shell.panes.clientWidth)
    // One column gets wider; nothing else about the window changes. Every
    // move used to lay out all four panes again — which took the divider
    // being dragged out of the window and put a new one in its place, and
    // relaid out every page of the paper — sixty times a second.
    let frame = 0
    const settle = () => {
      frame = 0
      const column = paneNode(pane)
      const width = columnWidthNow(pane)
      column.style.flex = `0 0 ${width}px`
      column.style.width = `${width}px`
      // The sidebar or the inspector drawn wider: the table gives way.
      if (pane !== 'table') fitListColumn()
      relayoutReaders()
    }
    const move = (moved: PointerEvent) => {
      const travel = inverted ? startX - moved.clientX : moved.clientX - startX
      store.settings.columns[pane] = Math.min(Math.max(startWidth + travel, COLUMN_MIN[pane]), widest)
      if (!frame) frame = requestAnimationFrame(settle)
    }
    const up = () => {
      if (frame) cancelAnimationFrame(frame)
      settle()
      node.classList.remove('dragging')
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      saveSettings({ columns: store.settings.columns })
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  })
  return node
}

function relayoutPanes() {
  // The window as it is out of focus: a restart comes back to that, not to a
  // window with every column shut.
  saveSettings({ panes: restingPanes(paneState()) })
  keepingPlaces(() => {
    layoutPanes()
    shell.toolbar.update()
    relayoutReaders()
  })
  changed('settings')
}

function paneState(): PaneState {
  return { panes: store.settings.panes, focus: store.focus }
}

function applyPaneState(next: PaneState) {
  store.settings.panes = { ...next.panes }
  store.focus = next.focus
  relayoutPanes()
}

/** A column on or off, by the Mac's rules (`togglePaneState`). */
export function togglePane(pane: Pane) {
  if (solo) return
  applyPaneState(togglePaneState(paneState(), pane))
}

/** Shows a pane that is hidden — the pen bringing the Tools tab, a note
 *  opening in the inspector — in focus mode too, as the Mac does. */
export function revealPane(pane: Pane) {
  if (solo || store.settings.panes[pane]) return
  applyPaneState(showPane(paneState(), pane))
}

/**
 * The paper and nothing else — and the way back. What it hid is remembered,
 * or leaving focus mode means putting three columns back by hand.
 */
export function setFocusMode(on: boolean) {
  if (solo || on === store.focus.on) return
  applyPaneState(on ? enterFocus(paneState()) : leaveFocus(paneState()))
}

export function toggleFocus() {
  setFocusMode(!store.focus.on)
}
