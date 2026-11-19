/**
 * What every pane in the row wears (1.1, the Mac's `PaneControls`): a ⌄ that
 * says what the pane shows and changes it, and the ×. In a pane's own head —
 * the shelf's, the slip-box's, a project's — beside its controls; over the
 * top-right corner of a pane with no head to put them in (the page, a
 * project's page). The head is also the pane's handle: dragged, the pane
 * moves.
 *
 * The buttons find their pane when they are pressed, by the `data-pane-id`
 * the row puts on each pane: the heads are built by modules that must not
 * import the window's layout, and a head drawn once can stand in whichever
 * pane holds it.
 */
import { el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { L } from '../../shared/lang.js'
import { CONTENT_PANE_DRAG_TYPE } from '../../shared/split.js'

export interface PaneChromeActions {
  /** The ⌄ pressed: what this pane can show. */
  menu: (paneID: string, anchor: Element) => void
  close: (paneID: string) => void
}

let actions: PaneChromeActions | null = null

/** What the buttons do, said once by `layout.ts`. */
export function setPaneChrome(next: PaneChromeActions) {
  actions = next
}

/** The pane a node stands in. */
export function paneOfNode(node: Element): string | null {
  return node.closest<HTMLElement>('[data-pane-id]')?.dataset.paneId ?? null
}

function glyphed(name: string): Node[] {
  const glyph = iconNode(name)
  return glyph ? [glyph] : []
}

/** The ⌄ and the ×, for a head. */
export function paneControls(): HTMLElement[] {
  const menu = el('button', {
    class: 'pane-menu',
    title: L('이 칸에 보일 것', 'What This Pane Shows'),
    'aria-label': L('이 칸에 보일 것', 'What This Pane Shows'),
    'aria-haspopup': 'menu',
  }, glyphed('chevron.down'))
  on(menu, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    const id = paneOfNode(menu)
    if (id) actions?.menu(id, menu)
  })
  const close = el('button', {
    class: 'pane-close',
    title: L('이 칸 닫기', 'Close This Pane'),
    'aria-label': L('칸 닫기', 'Close Pane'),
  }, glyphed('xmark'))
  on(close, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    const id = paneOfNode(close)
    if (id) actions?.close(id)
  })
  // A press on them is not a press on the pane under them, nor the start of a drag.
  for (const button of [menu, close]) {
    on(button, 'mousedown', (event: MouseEvent) => event.stopPropagation())
    button.draggable = false
  }
  return [menu, close]
}

/** A head made the pane's handle: dragged, the pane moves in the row. */
export function paneHandle(node: HTMLElement) {
  node.draggable = true
  node.classList.add('pane-handle')
  on(node, 'dragstart', (event: DragEvent) => {
    // A drag that began on something of its own inside the head is that thing's.
    if (event.target !== node && (event.target as Element).closest?.('[draggable="true"]') !== node) return
    const id = paneOfNode(node)
    if (!id || !event.dataTransfer) {
      event.preventDefault()
      return
    }
    event.dataTransfer.setData(CONTENT_PANE_DRAG_TYPE, id)
    event.dataTransfer.effectAllowed = 'move'
  })
}

/** The ⌄ and × over the top-right corner of a pane with no head, which is its handle too. */
export function paneCorner(): HTMLElement {
  const node = el('div', { class: 'pane-corner', title: L('끌어서 칸 옮기기', 'Drag to Move the Pane') }, paneControls())
  paneHandle(node)
  return node
}

/** The page's corner, one for the window: it stays in the page area whatever the page shows. */
export const pageCorner = paneCorner()
