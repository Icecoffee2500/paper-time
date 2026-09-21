/**
 * The open papers, summoned over the page — ⇧⌘O, as on the Mac.
 *
 * A list of what is open, the one showing marked; a click shows another,
 * ⌘-click opens it in a window of its own, and a row dragged off every
 * window of ours becomes a window where it lands, the way a browser's tab
 * does. Dragged to the page's edge it docks there instead — the page area's
 * own drop handling takes that, since the row travels under the same type
 * as a row of the list.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { isOpenPaper, store, type Paper, paper as findPaper } from '../state.js'
import { isCommand } from '../bridge.js'
import { L } from '../../shared/lang.js'
import { PAPER_DRAG_TYPE } from '../../shared/split.js'

export interface OpenPapersActions {
  /** Shows a paper and keeps it: chosen from this list, it is in use. */
  show: (id: string) => void
  close: (id: string) => void
  /** A window of its own, put where the drag ended when there was one. */
  openWindow: (id: string, at?: { x: number; y: number }) => void
  /** Whether a point on the screen lies inside any window of ours. */
  insideOurWindows: (x: number, y: number) => Promise<boolean>
}

let current: { node: HTMLElement; dispose: () => void } | null = null

export function isOpenPapersShowing(): boolean {
  return current !== null
}

export function closeOpenPapers() {
  current?.dispose()
  current = null
}

/** Redraws the list when the open papers or the one showing change. */
export function refreshOpenPapers() {
  if (current) (current.node as HTMLElement & { refresh?: () => void }).refresh?.()
}

/** What the popup lists: the kept papers in order, then the preview. */
export function popupPapers(): Paper[] {
  const ids = [...store.openPaperIDs]
  if (store.selectedID && !ids.includes(store.selectedID)) ids.push(store.selectedID)
  return ids.map((id) => findPaper(id)).filter((entry): entry is Paper => Boolean(entry))
}

export function toggleOpenPapers(host: HTMLElement, actions: OpenPapersActions) {
  if (current) return closeOpenPapers()
  showOpenPapers(host, actions)
}

export function showOpenPapers(host: HTMLElement, actions: OpenPapersActions) {
  closeOpenPapers()
  const node = el('div', { class: 'open-papers', role: 'dialog', 'aria-label': L('열린 논문', 'Open Papers') })
  const list = el('div', { class: 'open-papers-list' })
  node.append(
    el('div', { class: 'open-papers-head' }, [
      el('span', { text: L('열린 논문', 'Open Papers') }),
      el('span', { class: 'toolbar-spacer' }),
      el('span', { class: 'open-papers-hint', text: L('끌어서 옆에, 창 밖으로 끌면 새 창', 'Drag beside · drag out for a window') }),
    ]),
    list,
  )

  const refresh = () => {
    clear(list)
    const papers = popupPapers()
    if (papers.length === 0) {
      list.append(el('div', { class: 'open-papers-empty', text: L('열린 논문이 없어요.', 'Nothing is open.') }))
      return
    }
    for (const entry of papers) list.append(row(entry))
  }

  const row = (entry: Paper): HTMLElement => {
    const showing = store.selectedID === entry.id
    const kept = isOpenPaper(entry.id)
    const subtitle = [entry.meta.displayAuthors, entry.meta.year ? String(entry.meta.year) : ''].filter(Boolean).join(' · ')
    const line = el('div', { class: 'open-papers-sub' }, [el('span', { text: subtitle })])
    if (!kept) line.append(el('span', { class: 'open-papers-preview', text: L('미리보기', 'Preview') }))
    const body = el('div', { class: 'open-papers-main' }, [
      el('div', { class: 'open-papers-title', text: entry.meta.displayTitle }),
      line,
    ])
    const item = el('div', { class: 'open-papers-row', 'data-showing': String(showing), draggable: 'true' }, [
      el('span', { class: 'open-papers-dot' }),
      body,
    ])
    const windowButton = el('button', {
      class: 'icon-button',
      title: L('새 창으로 열기 (⌘클릭, ⌘↩)', 'Open in New Window (⌘-click, ⌘↩)'),
      html: icon('macwindow.badge.plus'),
    })
    on(windowButton, 'click', (event: MouseEvent) => {
      event.stopPropagation()
      actions.openWindow(entry.id)
    })
    const closeButton = el('button', {
      class: 'icon-button',
      title: L('닫기 (⌫)', 'Close (⌫)'),
      html: icon('xmark'),
    })
    on(closeButton, 'click', (event: MouseEvent) => {
      event.stopPropagation()
      actions.close(entry.id)
      refresh()
    })
    item.append(windowButton, closeButton)
    on(item, 'click', (event: MouseEvent) => {
      if (isCommand(event)) actions.openWindow(entry.id)
      else actions.show(entry.id)
      refresh()
    })
    on(item, 'dragstart', (event: DragEvent) => {
      if (!event.dataTransfer) return
      event.dataTransfer.setData(PAPER_DRAG_TYPE, entry.id)
      event.dataTransfer.setData('text/plain', entry.meta.displayTitle)
      event.dataTransfer.effectAllowed = 'copyMove'
    })
    on(item, 'dragend', (event: DragEvent) => {
      // Nothing took it, and it ended off every window of ours: that is
      // "dragged out", and a new window is made there.
      if (event.dataTransfer?.dropEffect !== 'none') return
      const x = event.screenX
      const y = event.screenY
      void actions.insideOurWindows(x, y).then((inside) => {
        if (!inside) actions.openWindow(entry.id, { x, y })
      })
    })
    return item
  }

  // ↑ and ↓ move along the list, showing each paper as they pass — the keys
  // the list column answers to, so the popup answers to them too.
  const step = (offset: number) => {
    const all = popupPapers()
    if (all.length === 0) return
    const index = all.findIndex((entry) => entry.id === store.selectedID)
    if (index < 0) return actions.show(all[0].id)
    const next = Math.min(Math.max(index + offset, 0), all.length - 1)
    if (next !== index) actions.show(all[next].id)
    refresh()
  }

  const onKey = (event: KeyboardEvent) => {
    switch (event.key) {
      case 'Escape':
        event.preventDefault()
        event.stopPropagation()
        return closeOpenPapers()
      case 'ArrowDown':
        event.preventDefault()
        event.stopPropagation()
        return step(1)
      case 'ArrowUp':
        event.preventDefault()
        event.stopPropagation()
        return step(-1)
      case 'Enter':
        event.preventDefault()
        event.stopPropagation()
        if (store.selectedID) {
          if (isCommand(event)) return actions.openWindow(store.selectedID)
          actions.show(store.selectedID)
        }
        return closeOpenPapers()
      case 'Delete':
      case 'Backspace':
        event.preventDefault()
        event.stopPropagation()
        if (store.selectedID) actions.close(store.selectedID)
        return refresh()
    }
  }
  const onPress = (event: MouseEvent) => {
    if (!node.contains(event.target as Node)) closeOpenPapers()
  }
  window.addEventListener('keydown', onKey, true)
  // After this click has finished, so the ⇧⌘O that opened it — or the
  // button — does not also close it.
  setTimeout(() => document.addEventListener('mousedown', onPress, true), 0)

  ;(node as HTMLElement & { refresh?: () => void }).refresh = refresh
  refresh()
  host.append(node)
  current = {
    node,
    dispose: () => {
      window.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onPress, true)
      node.remove()
    },
  }
}
