/**
 * Dropping onto the window: a paper onto a half or a quarter of the page
 * area, and PDFs from the desktop into the library.
 */
import { droppedPaths } from './bridge.js'
import { on } from './dom.js'
import { dockZone, pageArea } from './pageArea.js'
import { dockPaper } from './actions/openPapers.js'
import { addPapers } from './library.js'
import { closeOpenPapers } from './ui/openPapers.js'
import { toast } from './ui/toolbar.js'
import { L } from '../shared/lang.js'
import { carriesPapers, draggedPapers, zoneAt, zoneRect, type DockZone } from '../shared/split.js'

/**
 * A paper dragged over the page area — a row of the list, a pane's title, a
 * row of the popup — lights the half or the quarter it would go into, and
 * goes there when dropped. The middle of the page is no zone at all.
 */
let litZone: DockZone | null = null

function lightZone(zone: DockZone | null) {
  litZone = zone
  if (!zone) {
    dockZone.dataset.on = 'false'
    return
  }
  const size = { width: pageArea.clientWidth, height: pageArea.clientHeight }
  const rect = zoneRect(zone, size)
  dockZone.style.left = `${rect.x}px`
  dockZone.style.top = `${rect.y}px`
  dockZone.style.width = `${rect.width}px`
  dockZone.style.height = `${rect.height}px`
  dockZone.dataset.on = 'true'
}

function carriesPaper(event: DragEvent): boolean {
  return carriesPapers(event.dataTransfer)
}

function zoneUnder(event: DragEvent): DockZone | null {
  const box = pageArea.getBoundingClientRect()
  return zoneAt(event.clientX - box.left, event.clientY - box.top, { width: box.width, height: box.height })
}

export function installDockDrop() {
  on(pageArea, 'dragover', (event: DragEvent) => {
    if (!carriesPaper(event)) return
    event.preventDefault()
    event.stopPropagation()
    const zone = zoneUnder(event)
    if (event.dataTransfer) event.dataTransfer.dropEffect = zone ? 'move' : 'none'
    if (zone !== litZone) lightZone(zone)
  })
  on(pageArea, 'dragleave', (event: DragEvent) => {
    if (!pageArea.contains(event.relatedTarget as Node | null)) lightZone(null)
  })
  on(pageArea, 'drop', (event: DragEvent) => {
    if (!carriesPaper(event)) return
    event.preventDefault()
    event.stopPropagation()
    // A pane takes one paper: the one the drag started on leads its list.
    const id = draggedPapers(event.dataTransfer)[0]
    const zone = zoneUnder(event)
    lightZone(null)
    if (!id || !zone) return
    closeOpenPapers()
    dockPaper(id, zone)
  })
  // A drag cancelled with Escape, or let go outside the page area, ends on
  // the element it started from; the highlight goes with it.
  on(window, 'dragend', () => lightZone(null))
}

/** PDFs dropped anywhere on the window go into the library. */
export function installFileDrop() {
  on(window, 'dragover', (event: DragEvent) => {
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = carriesPaper(event) ? 'none' : 'copy'
  })
  on(window, 'drop', (event: DragEvent) => {
    event.preventDefault()
    const dropped = droppedPaths(event.dataTransfer?.files)
    const files = dropped.filter((path) => path.toLowerCase().endsWith('.pdf'))
    if (files.length === 0) {
      // Something was dropped and none of it was a paper: say so rather than
      // let the window look broken. A drop that carried nothing at all — a
      // paper being dragged between panes — is not worth a word.
      if (dropped.length > 0) toast(L('PDF만 더할 수 있어요.', 'Only PDFs can be added to the library.'))
      return
    }
    void addPapers(files)
  })
}
