/**
 * Dropping into the row of panes (1.1): a sidebar row, a pane's head, or a
 * paper.
 *
 * While a sidebar row or a pane's head is dragged over a pane, three zones
 * stand over it — a new pane on its left, open it here, a new pane on its
 * right — the one under the pointer outlined. Over the «+» column the whole
 * column lights: the pane goes at the end.
 *
 * A paper dragged over any pane but the page (the page has zones of its own,
 * `dockDrop.ts`) opens beside the page's paper: with a page open the whole
 * pane is one zone, «논문 옆에 나란히 열기»; with none, the three zones say
 * where a page comes (the Mac's `PaneDropDelegate`, 2026-11-18). Whatever
 * inside a pane takes papers itself — a plan's table, a project's cards, a
 * row to attach to — takes them first: it says so by `preventDefault`, and
 * no zone stands over it.
 */
import { el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import { CONTENT_PANE_DRAG_TYPE, READER_PANE_DRAG_TYPE, carriesPaneDrop, carriesPapers, draggedPapers, draggedShelf } from '../../shared/split.js'

import { zoneAcross, type PaneZone } from '../../shared/paneModel.js'

export type { PaneZone } from '../../shared/paneModel.js'

/** What was dropped: a sidebar item, a pane being moved, or a paper (and the side-by-side pane it was dragged by). */
export type PaneDrop = { shelf: unknown } | { pane: string } | { paper: string; moving?: string }

export interface PaneDropActions {
  /** On a pane's zone, or — `target` null — on the «+» column. */
  drop: (target: string | null, zone: PaneZone, what: PaneDrop) => void
  /** Whether a page pane is open for a dragged paper to stand beside: then a pane is one zone. */
  besidePage: () => boolean
}

const overlay = el('div', { class: 'pane-drop', 'data-on': 'false', 'aria-hidden': 'true' })
const zones: Record<PaneZone, HTMLElement> = {
  left: el('div', { class: 'pane-drop-zone', 'data-zone': 'left' }),
  middle: el('div', { class: 'pane-drop-zone', 'data-zone': 'middle' }),
  right: el('div', { class: 'pane-drop-zone', 'data-zone': 'right' }),
}
overlay.append(zones.left, zones.middle, zones.right)

/**
 * What the zones say: a sidebar item or a pane gets a new pane either side;
 * a paper, a paper pane either side when there is no page, and with a page
 * one zone across the pane.
 */
type Mode = 'pane' | 'paper' | 'beside'

function say(node: HTMLElement, text: string) {
  const span = node.firstElementChild as HTMLElement | null
  if (span?.textContent === text) return
  node.replaceChildren(el('span', { text }))
}

/** The words, in the window's language as it is now. */
function label(mode: Mode) {
  overlay.dataset.mode = mode === 'beside' ? 'one' : 'three'
  if (mode === 'beside') {
    say(zones.middle, L('논문 옆에 나란히 열기', 'Open Beside the Paper'))
    return
  }
  const paper = mode === 'paper'
  say(zones.left, paper ? L('왼쪽에 논문 칸', 'Paper on the Left') : L('왼쪽에 새 칸', 'New Pane on the Left'))
  say(zones.middle, L('여기에 열기', 'Open Here'))
  say(zones.right, paper ? L('오른쪽에 논문 칸', 'Paper on the Right') : L('오른쪽에 새 칸', 'New Pane on the Right'))
}

type Spot = { target: string | null; zone: PaneZone; box: DOMRect | null; mode: Mode }

let lit: { target: string | null; zone: PaneZone } | null = null
/** The pane a head drag started from: no zones stand over the pane being moved. */
let movingPane: string | null = null

function light(next: Spot | null, panes: HTMLElement) {
  for (const plus of panes.querySelectorAll<HTMLElement>('[data-pane-plus]')) plus.classList.toggle('drop-target', Boolean(next && next.target === null))
  if (!next || next.target === null || !next.box) {
    overlay.dataset.on = 'false'
    lit = next ? { target: next.target, zone: next.zone } : null
    return
  }
  label(next.mode)
  if (!overlay.isConnected) document.body.append(overlay)
  Object.assign(overlay.style, {
    left: `${next.box.left}px`,
    top: `${next.box.top}px`,
    width: `${next.box.width}px`,
    height: `${next.box.height}px`,
  })
  overlay.dataset.on = 'true'
  for (const [zone, node] of Object.entries(zones)) node.dataset.lit = String(zone === next.zone)
  lit = { target: next.target, zone: next.zone }
}

/** The pane or the «+» column under the pointer, and the zone. */
function under(event: DragEvent, panes: HTMLElement, mode: Mode): Spot | null {
  const node = (event.target as Element | null)?.closest?.<HTMLElement>('[data-pane-id], [data-pane-plus]')
  if (!node || !panes.contains(node)) return null
  if (node.dataset.panePlus !== undefined) return { target: null, zone: 'right', box: null, mode }
  const id = node.dataset.paneId!
  // A paper over the page is the page's own zones' to answer (`dockDrop.ts`).
  if (mode !== 'pane' && node.dataset.paneKind === 'page') return null
  if (mode === 'pane' && id === movingPane) return null
  const box = node.getBoundingClientRect()
  // With a page to stand beside, the whole pane is the one zone.
  if (mode === 'beside') return { target: id, zone: 'middle', box, mode }
  return { target: id, zone: zoneAcross((event.clientX - box.left) / Math.max(box.width, 1)), box, mode }
}

/** What a drop carries, read once it is let go of (the data is not readable before). */
function carried(data: DataTransfer | null): PaneDrop | null {
  const pane = data?.getData(CONTENT_PANE_DRAG_TYPE)
  if (pane) return { pane }
  const shelf = draggedShelf(data)
  return shelf ? { shelf } : null
}

/** The paper a paper drag carries — the one it started on leads its list — and the side-by-side pane it was dragged by. */
function carriedPaper(data: DataTransfer | null): PaneDrop | null {
  const paper = draggedPapers(data)[0]
  if (!paper) return null
  const moving = data?.getData(READER_PANE_DRAG_TYPE) || undefined
  return { paper, moving }
}

/** A paper drag, and not a sidebar item's or a pane's (those carry no paper). */
function paperDrag(data: DataTransfer | null | undefined): boolean {
  return carriesPapers(data) && !carriesPaneDrop(data)
}

export function installPaneDrop(panes: HTMLElement, actions: PaneDropActions) {
  // Taken before anything inside a pane sees it: a board's rows, the page's
  // zones and the sidebar's rows answer papers and notes, and these are neither.
  on(panes, 'dragover', (event: DragEvent) => {
    if (!carriesPaneDrop(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    const spot = under(event, panes, 'pane')
    if (event.dataTransfer) event.dataTransfer.dropEffect = spot ? 'move' : 'none'
    light(spot, panes)
  }, { capture: true })
  on(panes, 'dragleave', (event: DragEvent) => {
    if (!carriesPaneDrop(event.dataTransfer)) return
    const into = event.relatedTarget as Node | null
    if (!into || !panes.contains(into)) light(null, panes)
  }, { capture: true })
  on(panes, 'drop', (event: DragEvent) => {
    if (!carriesPaneDrop(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    const spot = under(event, panes, 'pane') ?? lit
    const what = carried(event.dataTransfer)
    light(null, panes)
    movingPane = null
    if (!spot || !what) return
    actions.drop(spot.target, spot.zone, what)
  }, { capture: true })
  // The pane a head drag began on, so no zones stand over it.
  on(document, 'dragstart', (event: DragEvent) => {
    movingPane = (event.target as Element | null)?.closest?.<HTMLElement>('.pane-handle, .reader-header')
      ? ((event.target as Element).closest<HTMLElement>('[data-pane-id]')?.dataset.paneId ?? null)
      : null
  }, { capture: true })
  // A paper: answered after whatever inside the pane would take it first.
  // The dragover a handler inside stopped never reaches here, so a pass that
  // did not come through says so to the next one, and the zones go.
  let seen: DragEvent | null = null
  let through = true
  const paperMode = (): Mode => (actions.besidePage() ? 'beside' : 'paper')
  on(panes, 'dragover', (event: DragEvent) => {
    if (!paperDrag(event.dataTransfer)) return
    if (!through) light(null, panes)
    seen = event
    through = false
  }, { capture: true })
  on(panes, 'dragover', (event: DragEvent) => {
    if (event !== seen) return
    through = true
    if (!paperDrag(event.dataTransfer)) return
    if (event.defaultPrevented) {
      light(null, panes)
      return
    }
    const spot = under(event, panes, paperMode())
    light(spot, panes)
    if (!spot) return
    event.preventDefault()
    event.stopPropagation()
    // One of the drags' own: the list's `copyMove`, a pane title's `move`.
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  })
  on(panes, 'dragleave', (event: DragEvent) => {
    if (!paperDrag(event.dataTransfer)) return
    const into = event.relatedTarget as Node | null
    if (!into || !panes.contains(into)) light(null, panes)
  })
  on(panes, 'drop', (event: DragEvent) => {
    if (!paperDrag(event.dataTransfer)) return
    if (event.defaultPrevented) {
      light(null, panes)
      return
    }
    const spot = under(event, panes, paperMode()) ?? lit
    const what = carriedPaper(event.dataTransfer)
    light(null, panes)
    if (!spot || !what) return
    event.preventDefault()
    event.stopPropagation()
    actions.drop(spot.target, spot.zone, what)
  })
  // Escape, or a drop outside the row: the zones go with the drag.
  on(window, 'dragend', () => {
    movingPane = null
    seen = null
    through = true
    light(null, panes)
  })
}

/** What the zones say now, for a probe. */
export function paneDropShown(): { on: boolean; zone: string | null; mode: string | null; words: string[] } {
  const one = overlay.dataset.mode === 'one'
  return {
    on: overlay.dataset.on === 'true',
    zone: Object.entries(zones).find(([, node]) => node.dataset.lit === 'true')?.[0] ?? null,
    mode: overlay.dataset.mode ?? null,
    words: (one ? [zones.middle] : [zones.left, zones.middle, zones.right]).map((node) => node.textContent ?? ''),
  }
}
