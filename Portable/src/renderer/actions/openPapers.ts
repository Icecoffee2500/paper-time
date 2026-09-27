/**
 * Which papers are open, which one is showing, and the way back.
 *
 * Showing a paper does not keep it: what is merely shown is a preview on the
 * open shelf and leaves when the next is shown. Clicking into it, pinning it,
 * or putting it beside another keeps it.
 */
import { call } from '../bridge.js'
import {
  changed,
  closeOpenPaper,
  closeOtherOpenPapers,
  dock,
  keepOpen,
  patchPaper,
  paper as findPaper,
  remember,
  shelfPapers,
  store,
  travelBy,
  undock,
} from '../state.js'
import { solo } from '../shell.js'
import { focused, pageArea, readers, reconcileReaders } from '../pageArea.js'
import { saveSettings } from '../settingsController.js'
import { toggleOpenPapers } from '../ui/openPapers.js'
import { togglePages } from '../ui/pages.js'
import { thumbnails } from '../ui/pageThumbnails.js'
import { splitContains, splitPapers, type DockZone, type SplitArrangement } from '../../shared/split.js'

/**
 * Shows a paper. With papers side by side, the paper takes the place of the
 * pane in focus, so the arrangement keeps its shape.
 */
export async function showPaper(id: string) {
  if (store.selectedID === id || !findPaper(id)) return
  const previous = store.selectedID
  if (store.split && !splitContains(store.split, id)) {
    const target = previous && splitContains(store.split, previous) ? previous : splitPapers(store.split)[0]
    store.split = replaceInSplit(store.split, target, id)
  }
  store.selectedID = id
  if (!store.travelling) remember(id)
  saveSettings({ selectedPaperID: id })
  void markOpened(id)
  reconcileReaders()
  changed('papers', 'selection', 'reader')
}

/** Opened now — the row shows it at once, from the record the main process
 *  wrote. The reading status is the reader's to set: opening a paper used to
 *  mark it «reading» by itself, which the Mac never does. */
async function markOpened(id: string) {
  const state = await call('paper:state', { id, patch: { lastOpenedAt: new Date().toISOString() } })
  if (!state) return
  patchPaper(id, { state })
  changed('papers')
}

function replaceInSplit(split: SplitArrangement, from: string, to: string): SplitArrangement {
  const swap = (column: { top: string; bottom?: string } | undefined) => column && {
    top: column.top === from ? to : column.top,
    ...(column.bottom ? { bottom: column.bottom === from ? to : column.bottom } : {}),
  }
  return { left: swap(split.left)!, right: swap(split.right) }
}

/** Keeps a paper on the open shelf without changing what is showing. */
export function keepPaper(id: string, byHand = false) {
  keepOpen(id, byHand)
  changed('papers')
}

/** Closes a paper: out of its pane, off the shelf; its neighbour comes forward. */
export function closePaper(id: string) {
  const wasSelected = store.selectedID === id
  undock(id)
  closeOpenPaper(id)
  if (wasSelected && store.selectedID && store.selectedID !== id && !store.travelling) remember(store.selectedID)
  saveSettings({ selectedPaperID: store.selectedID })
  reconcileReaders()
  changed('papers', 'selection', 'history')
}

export function closeOthers(keeping: string) {
  for (const other of store.openPaperIDs) if (other !== keeping) undock(other)
  closeOtherOpenPapers(keeping)
  saveSettings({ selectedPaperID: store.selectedID })
  reconcileReaders()
  changed('papers', 'selection')
}

/** Puts a paper into a zone of the page area, beside what is showing. */
export function dockPaper(id: string, zone: DockZone) {
  if (!findPaper(id)) return
  dock(id, zone)
  reconcileReaders()
  changed('papers', 'selection')
}

/** A window of its own for one paper — asked for by hand, so pinned, as the
 *  Mac's new window keeps it. */
export function openInWindow(id: string, at?: { x: number; y: number }) {
  keepOpen(id, true)
  changed('papers')
  void call('paper:openWindow', { id, x: at?.x, y: at?.y })
}

async function insideOurWindows(x: number, y: number): Promise<boolean> {
  const bounds = await call('window:bounds')
  return bounds.some((b) => x >= b.x && x <= b.x + b.width && y >= b.y && y <= b.y + b.height)
}

/**
 * The next or previous paper on the shelf showing — ⌥⌘↓/⌥⌘↑ on the Mac,
 * Ctrl+Alt+↓/↑ here, and ↓/↑ in the list itself. Nothing chosen yet: the
 * first. At either end: nowhere (`RootView.step(by:)`).
 */
export function stepPaper(by: number) {
  const papers = shelfPapers()
  if (papers.length === 0) return
  const at = papers.findIndex((entry) => entry.id === store.selectedID)
  if (at < 0) {
    void showPaper(papers[0].id)
    return
  }
  const next = papers[at + by]
  if (next) void showPaper(next.id)
}

/**
 * Back and forward walk the papers you have opened, the way a browser walks
 * pages: going back and then opening something else forgets what lay ahead.
 * The paper's own history comes first — the sentence a followed link came
 * from — then the papers (`goBackInHistory` on the Mac).
 */
export function goBack() {
  const reader = focused()
  if (reader?.canGoBackInDocument) return reader.goBackInDocument()
  walk(-1)
}

export function goForward() {
  const reader = focused()
  if (reader?.canGoForwardInDocument) return reader.goForwardInDocument()
  walk(1)
}

function walk(by: 1 | -1) {
  const id = travelBy(by)
  if (!id) return
  store.travelling = true
  void showPaper(id).finally(() => {
    store.travelling = false
    changed('history')
  })
}

/**
 * ⌘W: with papers side by side, closes the pane in focus and leaves the
 * window standing. With one pane the window closes, as it always did.
 */
export function closeWindowOrPane() {
  if (store.split && store.selectedID && splitContains(store.split, store.selectedID)) {
    closePaper(store.selectedID)
    return
  }
  void call('window:close')
}

/**
 * A quotation's page link, followed from the note: its paper — the note's
 * own unless the link names another — at the passage's top, as a jump Back
 * comes back from.
 */
export async function openAnchor(place: { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; paperID?: string }) {
  const known = place.paperID ? store.papers.find((entry) => entry.id.toUpperCase() === place.paperID!.toUpperCase()) : null
  const id = known?.id ?? store.selectedID
  if (!id) return
  if (id !== store.selectedID) await showPaper(id)
  const reader = readers.get(id)
  if (!reader || !(await reader.whenOpen())) return
  await reader.jumpToPassage(place.pageIndex, place.rect)
}

/** Every page of what is showing, small — the way into a document that has
 *  no headings to list. */
export function showPagesPopup() {
  const reader = focused()
  if (!reader) return
  togglePages(pageArea, {
    pageCount: () => reader.pages.length,
    // Counted from nought already; the «− 1» that was here ringed the page
    // before the one being read.
    currentPage: () => reader.state.currentPage,
    draw: (index, width) => reader.thumbnail(index, width),
    // A jump Back comes back from, and one that works with one page showing
    // (the page scrolled to used to be hidden in that layout).
    go: (index) => void reader.jumpTo(index, null),
    outline: () => reader.outline(),
    goToHeading: (entry) => { if (entry.pageIndex !== null) void reader.jumpTo(entry.pageIndex, entry.top) },
    cancel: () => thumbnails.cancel(),
  })
}

export function showOpenPapersPopup() {
  if (solo) return
  toggleOpenPapers(pageArea, {
    show: (id) => {
      void showPaper(id)
      keepPaper(id)
    },
    close: (id) => closePaper(id),
    openWindow: (id, at) => openInWindow(id, at),
    insideOurWindows,
  })
}
