/**
 * Dropping onto the window: a paper onto the page — beside the paper there,
 * or in its place — and PDFs from the desktop into the library.
 */
import { call, droppedPaths } from './bridge.js'
import { el, on } from './dom.js'
import { dockZone, pageArea, readers } from './pageArea.js'
import { dockPaper, openInPane } from './actions/openPapers.js'
import { addLibraryFolder, addPapers, openLibraryAt } from './library.js'
import { store } from './state.js'
import { closeOpenPapers } from './ui/openPapers.js'
import { toast } from './ui/toolbar.js'
import { L } from '../shared/lang.js'
import {
  READER_PANE_DRAG_TYPE, carriesPapers, dockTarget, draggedPapers, zoneRect, zoneSide, type DockTarget, type Rect,
} from '../shared/split.js'

/**
 * A paper dragged over the page — a row of a list, a side-by-side pane's
 * title, a row of the popup — lights where it would go (the Mac's
 * `DockDropDelegate.target`, 2026-11-18). With one reader, a half or a
 * quarter at either side puts it beside, and the middle opens it here in
 * place of the paper shown. With papers side by side, a thin strip at
 * either edge adds a pane while there are fewer than four, and anywhere
 * else is the pane under the pointer: its paper is replaced — or, dragged
 * by another pane's title, the two trade places.
 */
let litTarget = ''
const words = el('span', { class: 'dock-zone-words' })
dockZone.append(words)

/** The side-by-side panes' boxes, in the page's own coordinates. */
function paneFrames(): Record<string, Rect> {
  const page = pageArea.getBoundingClientRect()
  const frames: Record<string, Rect> = {}
  for (const [key, reader] of readers) {
    if (!reader.node.isConnected || !pageArea.contains(reader.node)) continue
    const box = reader.node.getBoundingClientRect()
    frames[key] = { x: box.left - page.left, y: box.top - page.top, width: box.width, height: box.height }
  }
  return frames
}

function light(target: DockTarget | null, frames: Record<string, Rect>) {
  const key = target ? JSON.stringify(target) : ''
  if (key === litTarget) return
  litTarget = key
  if (!target) {
    dockZone.dataset.on = 'false'
    return
  }
  const size = { width: pageArea.clientWidth, height: pageArea.clientHeight }
  let rect: Rect
  if (target.kind === 'zone') {
    rect = zoneRect(target.zone, size)
    words.textContent = zoneSide(target.zone) === 'left'
      ? L('왼쪽에 나란히', 'Side by Side on the Left')
      : L('오른쪽에 나란히', 'Side by Side on the Right')
  } else {
    const frame = target.pane ? frames[target.pane] : undefined
    rect = frame
      ? { x: frame.x + 6, y: frame.y + 6, width: frame.width - 12, height: frame.height - 12 }
      : { x: size.width * 0.3 + 4, y: 8, width: size.width * 0.4 - 8, height: size.height - 16 }
    words.textContent = target.pane ? L('이 칸에 열기', 'Open in This Pane') : L('여기에 열기', 'Open Here')
  }
  dockZone.dataset.kind = target.kind
  dockZone.style.left = `${rect.x}px`
  dockZone.style.top = `${rect.y}px`
  dockZone.style.width = `${rect.width}px`
  dockZone.style.height = `${rect.height}px`
  dockZone.dataset.on = 'true'
}

function carriesPaper(event: DragEvent): boolean {
  return carriesPapers(event.dataTransfer)
}

function targetUnder(event: DragEvent, frames: Record<string, Rect>): DockTarget | null {
  const box = pageArea.getBoundingClientRect()
  return dockTarget(event.clientX - box.left, event.clientY - box.top, { width: box.width, height: box.height }, store.split, frames)
}

export function installDockDrop() {
  on(pageArea, 'dragover', (event: DragEvent) => {
    if (!carriesPaper(event)) return
    event.preventDefault()
    event.stopPropagation()
    const frames = paneFrames()
    const target = targetUnder(event, frames)
    if (event.dataTransfer) event.dataTransfer.dropEffect = target ? 'move' : 'none'
    light(target, frames)
  })
  on(pageArea, 'dragleave', (event: DragEvent) => {
    if (!pageArea.contains(event.relatedTarget as Node | null)) light(null, {})
  })
  on(pageArea, 'drop', (event: DragEvent) => {
    if (!carriesPaper(event)) return
    event.preventDefault()
    event.stopPropagation()
    // A pane takes one paper: the one the drag started on leads its list.
    const id = draggedPapers(event.dataTransfer)[0]
    // Begun on a pane's title, the drag moves that pane; begun anywhere else
    // it opens one more — a second pane of the same paper, when the paper
    // is in one already.
    const pane = event.dataTransfer?.getData(READER_PANE_DRAG_TYPE) || undefined
    const target = targetUnder(event, paneFrames())
    light(null, {})
    if (!id || !target) return
    closeOpenPapers()
    if (target.kind === 'zone') dockPaper(id, target.zone, pane)
    else openInPane(id, target.pane, pane)
  })
  // A drag cancelled with Escape, or let go outside the page area, ends on
  // the element it started from; the highlight goes with it.
  on(window, 'dragend', () => light(null, {}))
}

/** Where the page's zone stands now, and what it says — for a probe. */
export function dockZoneShown(): { on: boolean; kind: string | null; words: string; rect: Rect | null } {
  const on = dockZone.dataset.on === 'true'
  return {
    on,
    kind: on ? dockZone.dataset.kind ?? null : null,
    words: on ? words.textContent ?? '' : '',
    rect: on ? { x: dockZone.offsetLeft, y: dockZone.offsetTop, width: dockZone.offsetWidth, height: dockZone.offsetHeight } : null,
  }
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
    if (files.length === 0 && dropped.length > 0) {
      // A folder dropped on the window is a library: the first one, when
      // there is none yet, or one more beside the ones open — the Mac takes
      // a folder dropped on its icon the same way.
      void (async () => {
        const folders: string[] = []
        for (const one of dropped) if (await call('path:isFolder', { path: one })) folders.push(one)
        if (folders.length === 0) {
          toast(L('PDF나 폴더만 더할 수 있어요.', 'Only PDFs and folders can be added to the library.'))
          return
        }
        for (const folder of folders) {
          if (!store.root) await openLibraryAt(folder)
          else await addLibraryFolder(folder)
        }
      })()
      return
    }
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
