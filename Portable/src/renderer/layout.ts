/**
 * The four columns and the dividers between them.
 *
 * The arrangement is the Mac's, down to the eight-point margin and the
 * ten-point gap that doubles as the resize handle.
 */
import { clear, el, on } from './dom.js'
import { changed, store, type Pane } from './state.js'
import { shell, solo } from './shell.js'
import { keepingPlaces, pageArea, relayoutReaders } from './pageArea.js'
import { saveSettings } from './settingsController.js'

type Column = 'sidebar' | 'paperList' | 'inspector'

/** The narrowest a column can be dragged, and the room the page keeps. */
const COLUMN_MIN = 180
const READER_MIN = 300

/** Which panes were on screen last time, so only a new one is seen arriving. */
let panesShown = new Set<Pane>()

/** The list column: the papers, or on the Notes shelf the slip-box. */
export function syncListSlot() {
  const wanted = store.shelf.kind === 'notes' && !solo ? shell.slipBox.node : shell.paperList.node
  if (wanted.parentElement !== shell.listSlot) {
    clear(shell.listSlot)
    shell.listSlot.append(wanted)
  }
}

export function layoutPanes() {
  const panes = shell.panes
  clear(panes)
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
  if (visible.paperList) pieces.push({ pane: 'paperList', node: shell.listSlot, width: store.settings.columns.paperList })
  if (visible.reader) pieces.push({ pane: 'reader', node: pageArea })
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
    panes.append(divider(target.pane as Column, resizesNext))
  })
}

/** The panel a column's name stands for. */
function paneNode(pane: Column): HTMLElement {
  if (pane === 'sidebar') return shell.sidebar.node
  if (pane === 'paperList') return shell.listSlot
  return shell.inspector.node
}

/**
 * The widest a column may be dragged: what the window has, less every other
 * column showing and the room the page keeps. It used to count this column
 * alone, so three wide columns left the page nothing.
 */
export function widestColumn(pane: Column, windowWidth: number): number {
  const visible = store.settings.panes
  const others = (['sidebar', 'paperList', 'inspector'] as const)
    .filter((one) => one !== pane && visible[one])
    .reduce((sum, one) => sum + store.settings.columns[one], 0)
  const room = windowWidth - others - (visible.reader ? READER_MIN : 0)
  return Math.max(COLUMN_MIN, room)
}

function divider(pane: Column, inverted: boolean): HTMLElement {
  const node = el('div', { class: 'divider' })
  on(node, 'pointerdown', (event: PointerEvent) => {
    event.preventDefault()
    node.setPointerCapture(event.pointerId)
    node.classList.add('dragging')
    const startX = event.clientX
    const startWidth = store.settings.columns[pane]
    const widest = widestColumn(pane, shell.panes.clientWidth)
    // One column gets wider; nothing else about the window changes. Every
    // move used to lay out all four panes again — which took the divider
    // being dragged out of the window and put a new one in its place, and
    // relaid out every page of the paper — sixty times a second.
    let frame = 0
    const settle = () => {
      frame = 0
      const column = paneNode(pane)
      const width = store.settings.columns[pane]
      column.style.flex = `0 0 ${width}px`
      column.style.width = `${width}px`
      relayoutReaders()
    }
    const move = (moved: PointerEvent) => {
      const travel = inverted ? startX - moved.clientX : moved.clientX - startX
      store.settings.columns[pane] = Math.min(Math.max(startWidth + travel, COLUMN_MIN), widest)
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
  saveSettings({ panes: store.settings.panes })
  keepingPlaces(() => {
    layoutPanes()
    shell.toolbar.update()
    relayoutReaders()
  })
  changed('settings')
}

/** A pane on or off. By hand in focus mode, that ends focus mode: the way
 *  back would undo what was just chosen. */
export function togglePane(pane: Pane) {
  if (solo) return
  store.focusBefore = null
  store.settings.panes = { ...store.settings.panes, [pane]: !store.settings.panes[pane] }
  relayoutPanes()
}

/** Shows a pane that is hidden — the pen bringing the inspector, a note
 *  opening in it. Not in focus mode, which hid it on purpose. */
export function revealPane(pane: Pane) {
  if (solo || store.settings.panes[pane] || store.focusBefore) return
  store.settings.panes = { ...store.settings.panes, [pane]: true }
  relayoutPanes()
}

/**
 * The paper and nothing else — and the way back.
 *
 * What it hid has to be remembered, or leaving focus mode means putting three
 * columns back by hand. Leaving restores exactly what was open on the way in.
 */
export function toggleFocus() {
  if (solo) return
  if (store.focusBefore) {
    store.settings.panes = { ...store.focusBefore }
    store.focusBefore = null
  } else {
    store.focusBefore = { ...store.settings.panes }
    store.settings.panes = { sidebar: false, paperList: false, reader: true, inspector: false }
  }
  relayoutPanes()
}
