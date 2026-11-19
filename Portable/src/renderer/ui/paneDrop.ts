/**
 * Dropping into the row of panes (1.1): a sidebar row, or a pane's head.
 *
 * While one is dragged over a pane, three zones stand over it — a new pane
 * on its left, open it here, a new pane on its right — the one under the
 * pointer outlined. Over the «+» column the whole column lights: the pane
 * goes at the end. Papers and notes are not these drags: they keep their own
 * places to go (the sidebar's rows, a plan's order, a project's cards, the
 * page's side-by-side zones), and no zone stands for them.
 */
import { el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import { CONTENT_PANE_DRAG_TYPE, carriesPaneDrop, draggedShelf } from '../../shared/split.js'

import { zoneAcross, type PaneZone } from '../../shared/paneModel.js'

export type { PaneZone } from '../../shared/paneModel.js'

/** What was dropped: a sidebar item, or a pane being moved. */
export type PaneDrop = { shelf: unknown } | { pane: string }

export interface PaneDropActions {
  /** On a pane's zone, or — `target` null — on the «+» column. */
  drop: (target: string | null, zone: PaneZone, what: PaneDrop) => void
}

const overlay = el('div', { class: 'pane-drop', 'data-on': 'false', 'aria-hidden': 'true' })
const zones: Record<PaneZone, HTMLElement> = {
  left: el('div', { class: 'pane-drop-zone', 'data-zone': 'left' }),
  middle: el('div', { class: 'pane-drop-zone', 'data-zone': 'middle' }),
  right: el('div', { class: 'pane-drop-zone', 'data-zone': 'right' }),
}
overlay.append(zones.left, zones.middle, zones.right)

/** The words go in when the zones first stand — read in the window's language then. */
function label() {
  if (zones.left.childElementCount) return
  zones.left.append(el('span', { text: L('왼쪽에 새 칸', 'New Pane on the Left') }))
  zones.middle.append(el('span', { text: L('여기에 열기', 'Open Here') }))
  zones.right.append(el('span', { text: L('오른쪽에 새 칸', 'New Pane on the Right') }))
}

let lit: { target: string | null; zone: PaneZone } | null = null
/** The pane a head drag started from: no zones stand over the pane being moved. */
let movingPane: string | null = null

function light(next: { target: string | null; zone: PaneZone; box: DOMRect | null } | null, panes: HTMLElement) {
  for (const plus of panes.querySelectorAll<HTMLElement>('[data-pane-plus]')) plus.classList.toggle('drop-target', Boolean(next && next.target === null))
  if (!next || next.target === null || !next.box) {
    overlay.dataset.on = 'false'
    lit = next ? { target: next.target, zone: next.zone } : null
    return
  }
  label()
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
function under(event: DragEvent, panes: HTMLElement): { target: string | null; zone: PaneZone; box: DOMRect | null } | null {
  const node = (event.target as Element | null)?.closest?.<HTMLElement>('[data-pane-id], [data-pane-plus]')
  if (!node || !panes.contains(node)) return null
  if (node.dataset.panePlus !== undefined) return { target: null, zone: 'right', box: null }
  const id = node.dataset.paneId!
  if (id === movingPane) return null
  const box = node.getBoundingClientRect()
  return { target: id, zone: zoneAcross((event.clientX - box.left) / Math.max(box.width, 1)), box }
}

/** What a drop carries, read once it is let go of (the data is not readable before). */
function carried(data: DataTransfer | null): PaneDrop | null {
  const pane = data?.getData(CONTENT_PANE_DRAG_TYPE)
  if (pane) return { pane }
  const shelf = draggedShelf(data)
  return shelf ? { shelf } : null
}

export function installPaneDrop(panes: HTMLElement, actions: PaneDropActions) {
  // Taken before anything inside a pane sees it: a board's rows, the page's
  // zones and the sidebar's rows answer papers and notes, and these are neither.
  on(panes, 'dragover', (event: DragEvent) => {
    if (!carriesPaneDrop(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    const spot = under(event, panes)
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
    const spot = under(event, panes) ?? lit
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
  // Escape, or a drop outside the row: the zones go with the drag.
  on(window, 'dragend', () => {
    movingPane = null
    light(null, panes)
  })
}

/** What the zones say now, for a probe. */
export function paneDropShown(): { on: boolean; zone: string | null } {
  return { on: overlay.dataset.on === 'true', zone: Object.entries(zones).find(([, node]) => node.dataset.lit === 'true')?.[0] ?? null }
}
