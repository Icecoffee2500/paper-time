/**
 * The page area: one reader, or up to four side by side.
 *
 * Each pane is a `Reader` of its own, and the one in focus is the paper the
 * window is "about" — the inspector, the notes and the keys act on it. A
 * reader whose paper leaves the page area is taken down, canvases and all.
 * Everything that changes what is in the page area ends in `reconcileReaders`.
 */
import { call } from './bridge.js'
import { clear, el } from './dom.js'
import {
  changed,
  keepOpen,
  panePapers,
  patchPaper,
  paper as findPaper,
  setFocusedReaderState,
  store,
  type Paper,
} from './state.js'
import { shell, solo } from './shell.js'
import { Reader, type ReaderPlace } from './ui/reader.js'
import { FindBar } from './ui/findBar.js'
import { refreshOpenPapers } from './ui/openPapers.js'
import { sketchEditor } from './ui/sketchEditing.js'
import { toast } from './ui/toolbar.js'
import { couldNot } from './notices.js'
import { closePaper } from './actions/openPapers.js'
import { saveSettings } from './settingsController.js'
import { icon } from './icons.js'
import { L } from '../shared/lang.js'
import type { PaperBytesDTO } from '../shared/api.js'
import type { SplitArrangement } from '../shared/split.js'

/** The readers, one per paper in the page area. */
export const readers = new Map<string, Reader>()

/**
 * Find in Document: one bar, over whichever reader is in focus. It goes when
 * that reader stops being the one in focus — its matches belong to that
 * paper.
 */
export const findBar = new FindBar()

export const pageArea = el('div', { class: 'page-area' })
/** Where a paper dragged over the page area would go. */
export const dockZone = el('div', { class: 'dock-zone', 'data-on': 'false' })

/** What the page area shows when nothing is open — the Mac's words for it,
 *  rather than an empty grey page that looks like a paper failing to load. */
const emptyReader = el('div', { class: 'panel reader-panel' }, [
  el('div', { class: 'reader-header' }),
  el('div', { class: 'reader-scroll' }, [
    el('div', { class: 'empty' }, [
      el('span', { html: icon('text.document') }),
      el('h2', { text: L('고른 논문이 없어요', 'No Paper Selected') }),
      el('p', { text: L('읽을 논문을 하나 골라보세요.', 'Choose a paper to start reading.') }),
    ]),
  ]),
])
pageArea.append(emptyReader, dockZone)

/** The reader in focus: the pane showing `store.selectedID`. */
export function focused(): Reader | null {
  return store.selectedID ? readers.get(store.selectedID) ?? null : null
}

setFocusedReaderState(() => focused()?.state ?? null)

/** The file's own name: the last part of where the record says it is. */
export function fileNameOf(entry: Paper | null | undefined): string {
  const relative = String(entry?.meta.file?.relativePath ?? '')
  return relative.split(/[\\/]/).pop() ?? ''
}

function readerFor(id: string, pane: boolean): Reader {
  const existing = readers.get(id)
  if (existing) return existing
  const reader = new Reader({
    changed: () => changed('sketch'),
    toast,
    // The Marks tab follows the page, and a mark clicked there is found in it.
    marksChanged: () => { if (store.selectedID === id) changed('marks') },
    historyChanged: () => changed('history'),
    markShown: (markID) => shell.inspector.showMark(markID),
    activated: () => {
      // A press in a pane makes it the one in use: the pane in focus, and a
      // paper kept open.
      keepOpen(id)
      if (store.selectedID !== id) {
        store.selectedID = id
        saveSettings({ selectedPaperID: id })
        focusChanged()
        changed('papers', 'selection')
      } else {
        changed('papers')
      }
    },
    close: () => closePaper(id),
    reveal: () => void call('paper:reveal', { id }),
    fileName: () => fileNameOf(findPaper(id)),
    guessed: (kind) => {
      // Only ever a guess, and only when nobody has one: the answer belongs
      // to the reader and is given in the inspector.
      const entry = findPaper(id)
      if (!entry || entry.meta.guessedKind || entry.meta.kind) return
      // Unstamped: a guess is not the reader editing the paper.
      void call('paper:meta', { id, patch: { guessedKind: kind }, stamp: false }).then((meta) => {
        if (!meta) return
        patchPaper(id, { meta })
        changed('papers', 'inspector')
      })
    },
  }, { pane })
  readers.set(id, reader)
  void loadInto(reader, id)
  return reader
}

async function loadInto(reader: Reader, id: string) {
  // Nothing in here may throw past this function: a rejected request reaching
  // the window as an unhandled rejection is a blank page with no sentence on
  // it, which is what a locked PDF used to look like.
  let result: PaperBytesDTO
  try {
    result = await call('paper:bytes', { id })
  } catch (error) {
    console.error('paper:bytes failed', error)
    result = { error: L('이 논문의 PDF를 읽지 못했어요.', "Paper Time couldn't read this paper's PDF.") }
  }
  if (!readers.has(id) || readers.get(id) !== reader) return
  if (result.locked) return reader.showLocked(result.locked)
  // Only when there are no bytes at all to try. Everything else goes to pdf.js
  // first: it reads more than this app does, and what was diagnosed only picks
  // the sentence for a failure that has actually happened.
  if (!result.data && result.trouble) {
    return reader.showTrouble(
      result.trouble, result.size ?? 0, () => void loadInto(reader, id),
      undefined, result.head, result.line,
    )
  }
  if (result.error || !result.data) return couldNot('readPDF', result.error ?? 'no bytes')
  await reader.open(id, new Uint8Array(result.data), {
    trouble: result.trouble ?? undefined,
    size: result.size,
    again: () => void loadInto(reader, id),
  })
  reader.setDrawing(reader.state.drawing)
  reader.update()
  // Now that there are pages to scroll: a paper whose reader was rebuilt
  // around it — closing the pane beside it, putting it beside another — goes
  // back to where it was being read rather than to page one.
  const place = inheritedPlaces.get(id)
  if (place) {
    inheritedPlaces.delete(id)
    reader.returnTo(place)
  }
  if (focused() === reader) focusChanged()
}

/** What the page area is showing, so that it is only rebuilt when that
 *  changes. See the note in `reconcileReaders`. */
let showing = ''

/** Where each paper was being read when the slip-box took the page area. */
let placesBeforeNotes: Map<string, ReaderPlace> | null = null

const inheritedDrawing = new Map<string, boolean>()

/** Where a paper was being read, across a rebuild of its reader. */
const inheritedPlaces = new Map<string, ReaderPlace>()

/**
 * Makes the readers match the arrangement: one per paper in the page area,
 * laid out as the arrangement says, the one in focus marked and given the
 * rack. Everything that changes what is in the page area ends here.
 */
export function reconcileReaders() {
  if (!solo && store.shelf.kind === 'notes' && store.slipBox.paperID === null) {
    showSlipBoxDetail()
    return
  }
  const wanted = panePapers()
  const split = store.split
  const previous = focused()
  const shape = [split ? JSON.stringify(split) : 'one', ...wanted].join(' ')
  // A reader keeps its pen state across a change of arrangement — but one
  // built for a pane and one built for the whole area differ in chrome, so
  // the readers are rebuilt when the arrangement appears or goes.
  for (const [id, reader] of [...readers]) {
    if (!wanted.includes(id) || reader.isPane !== Boolean(split)) {
      const drawing = reader.state.drawing
      const place = reader.place()
      reader.dispose()
      readers.delete(id)
      if (wanted.includes(id)) {
        inheritedDrawing.set(id, drawing)
        // A reader built for a pane and one built for the whole area are
        // different objects, so this paper's place cannot simply be restored
        // at the end — it is handed to the reader that replaces this one, and
        // taken up once that one has the pages to scroll.
        if (place.top > 0) inheritedPlaces.set(id, place)
      }
    }
  }
  for (const id of wanted) {
    const reader = readerFor(id, Boolean(split))
    const drawing = inheritedDrawing.get(id) ?? (previous && !readers.has(previous.paperID ?? '') ? previous.state.drawing : undefined)
    if (drawing !== undefined) {
      reader.state.drawing = drawing
      inheritedDrawing.delete(id)
    }
  }

  // Nothing to rebuild if the page area is already showing this. Taking a
  // reader out of the document empties the scroll view inside it, and a
  // reader at the top is a reader on page one — so a rebuild for nothing is
  // a paper that jumps. The library is re-read every time the folder changes
  // and the folder changes every time a mark is saved, which made this the
  // path a highlight took back to the first page. Measured before this:
  // scrolled to 1856, and 0 again two seconds later.
  const standing = wanted.length > 0
    ? wanted.every((id) => pageArea.contains(readers.get(id)?.node ?? null))
    : pageArea.contains(emptyReader)
  if (shape === showing && standing && pageArea.contains(dockZone)) {
    focusChanged()
    return
  }
  showing = shape
  // Where each reader was, to put it back: an arrangement that genuinely
  // changed still rebuilds, and the pane that was only standing beside the
  // one that changed should not lose its place either.
  keepingPlaces(() => {
    clear(pageArea)
    if (split) {
      const column = (ids: string[]) => el('div', { class: 'split-column' }, ids.map((id) => readerFor(id, true).node))
      const grid = el('div', { class: 'split' }, [column(columnIDs(split, 'left'))])
      if (split.right) grid.append(column(columnIDs(split, 'right')))
      pageArea.append(grid)
    } else if (wanted[0]) {
      pageArea.append(readerFor(wanted[0], false).node)
    } else {
      pageArea.append(emptyReader)
    }
    pageArea.append(dockZone)
    focusChanged()
    relayoutReaders()
  })
  // Back from the slip-box: the papers go where they were being read. Not
  // `keepingPlaces`'s doing — it measured them while they were out of the
  // document, at the top.
  if (placesBeforeNotes) {
    const places = placesBeforeNotes
    placesBeforeNotes = null
    for (const [id, place] of places) readers.get(id)?.returnTo(place)
  }
}

/** The page area while the slip-box is open: the note, not a paper. */
function showSlipBoxDetail() {
  const shape = 'slip-box'
  const slipBox = shell.slipBox
  if (showing === shape && pageArea.contains(slipBox.detail)) {
    slipBox.update()
    return
  }
  placesBeforeNotes = new Map([...readers].map(([id, reader]) => [id, reader.place()]))
  showing = shape
  clear(pageArea)
  pageArea.append(slipBox.detail, dockZone)
  if (findBar.isOpen) findBar.close()
  slipBox.update()
}

/**
 * Runs something that re-appends a panel, and puts the papers back afterwards.
 *
 * A scroll view taken out of the document comes back at the top, and a reader
 * at the top is a reader on page one. Every piece of code that re-appends a
 * panel goes through here — measured, toggling the sidebar sent a paper from
 * 1600 to 0, and so did saving a highlight, by way of the library being
 * re-read. The papers go back after the panels have been laid out again, so
 * that a column which has just changed width is measured at its new size.
 */
export function keepingPlaces(rebuild: () => void) {
  const places = new Map([...readers].map(([id, reader]) => [id, reader.place()]))
  rebuild()
  for (const [id, reader] of readers) {
    const place = places.get(id)
    if (place) reader.returnTo(place)
  }
}

export function relayoutReaders() {
  for (const reader of readers.values()) reader.relayout()
}

function columnIDs(split: SplitArrangement, side: 'left' | 'right'): string[] {
  const column = side === 'left' ? split.left : split.right
  if (!column) return []
  return column.bottom ? [column.top, column.bottom] : [column.top]
}

/** The reader the rack and the drawing editor were last given to. */
let focusedBefore: Reader | null = null

/**
 * The pane in focus is the paper the window is about: the rack sits over it,
 * the drawing editor is its own.
 */
export function focusChanged() {
  const reader = focused()
  for (const [id, other] of readers) other.setFocused(id === store.selectedID && Boolean(store.split))
  if (reader !== focusedBefore) {
    focusedBefore = reader
    store.sketch.selection = null
  }
  if (reader) {
    // Moved only when it is somewhere else: appending a node that is already
    // in place still takes it out of the document and puts it back.
    if (shell.rack.node.parentElement !== reader.overlayContainer) reader.overlayContainer.append(shell.rack.node)
    if (reader.state.drawing) reader.setDrawing(true)
    else if (sketchEditor.current) sketchEditor.current = null
  } else {
    sketchEditor.current = null
  }
  // What was found belongs to the paper it was found in.
  if (findBar.isOpen && !findBar.isFor(reader)) findBar.close()
  refreshOpenPapers()
}
