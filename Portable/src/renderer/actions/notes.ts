/**
 * The ways into a note: from the palette, a search row, a link, ⌘N and ⌘L.
 */
import { changed, noteByID, notesForPaper, paper as findPaper, setShelf, store } from '../state.js'
import { shell, solo } from '../shell.js'
import { focused, reconcileReaders } from '../pageArea.js'
import { openAnchor, showPaper } from './openPapers.js'
import { setInspectorTab } from '../settingsController.js'
import { togglePane } from '../layout.js'
import { createNote } from '../notesModel.js'
import { openNoteInSlipBox, slipBoxEditor } from '../ui/slipBox.js'
import { openEditor as openNoteEditor, openNoteInTab } from '../ui/notesTab.js'
import { toast } from '../ui/toolbar.js'
import { L } from '../../shared/lang.js'
import { passageText, quotationSource } from '../../shared/noteQuote.js'

/** The inspector, open on the Notes tab of the paper in front. */
export function showNoteTab() {
  setInspectorTab('note')
  if (!store.settings.panes.inspector) togglePane('inspector')
  shell.inspector.update()
  shell.toolbar.update()
}

/**
 * A note in the slip-box, beside the list — found: the search and the tag
 * that narrow the list are let go of, or a note just made could be one the
 * list is hiding.
 */
export function revealNoteInSlipBox(id: string) {
  store.slipBox.query = ''
  store.slipBox.tag = null
  setShelf({ kind: 'notes' })
  changed('shelf')
  openNoteInSlipBox(id)
}

/**
 * A note from the palette, a search row or a link: its paper with the Notes
 * tab in front — or, for a note about no paper, the slip-box with the note
 * open beside the list.
 */
export async function openNote(id: string) {
  const note = noteByID(id)
  if (!note || solo) return
  const paper = note.paperID ? findPaper(note.paperID) : undefined
  // Inside the slip-box a link stays in the slip-box, as on the Mac: the
  // note opens beside the list, whichever paper it is about.
  if (paper && store.shelf.kind !== 'notes') {
    if (store.selectedID !== paper.id) await showPaper(paper.id)
    showNoteTab()
    openNoteInTab(id)
    return
  }
  revealNoteInSlipBox(id)
}

/**
 * Command-N: a new note on the paper being read, open in the Notes tab with
 * the caret in it — or, with no paper open or the slip-box showing, a note
 * of your own in the slip-box, as the Mac's ⌘N writes one.
 */
export function newNote() {
  if (solo) return
  if (store.selectedID && findPaper(store.selectedID) && store.shelf.kind !== 'notes') {
    showNoteTab()
    openNoteInTab(createNote(store.selectedID).id)
    shell.inspector.focusNote()
    return
  }
  revealNoteInSlipBox(createNote(null).id)
  slipBoxEditor()?.area.focus()
}

/**
 * Command-L: the selected passage goes into the paper's note as a quotation,
 * with a link back to its page, and the note comes forward — the Markdown
 * the Mac writes, so either build's editor reads it as its own.
 */
export function linkSelectionToNote() {
  const reader = focused()
  const anchor = reader?.selectionAnchor()
  if (!reader || !anchor || !store.selectedID) {
    toast(L('먼저 글을 골라주세요.', 'Select some text first.'))
    return
  }
  const block = quotationSource(
    { pageIndex: anchor.pageIndex, rect: anchor.rect, quotedText: passageText(anchor.text) },
    (page) => L(`${page}쪽`, `p. ${page}`),
  )
  showNoteTab()
  // With no note open, the last one written about this paper carries on —
  // or a new one starts, as on the Mac.
  if (!openNoteEditor()) {
    const latest = notesForPaper(store.selectedID)[0]
    openNoteInTab(latest ? latest.id : createNote(store.selectedID).id)
  }
  if (!shell.inspector.insertIntoNote(block)) return
  reader.hideMarkBar()
}

/**
 * A passage followed out of a note in the slip-box: its paper takes the
 * page area, and the note stays open in the list beside it — pressing the
 * note again brings it back.
 */
export async function openAnchorFromSlipBox(place: { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; paperID?: string }) {
  const open = store.slipBox.openID ? noteByID(store.slipBox.openID) : undefined
  const named = place.paperID ? store.papers.find((entry) => entry.id.toUpperCase() === place.paperID!.toUpperCase())?.id : undefined
  const target = named ?? open?.paperID ?? undefined
  if (!target || !findPaper(target)) {
    toast(L('이 노트의 논문이 라이브러리에 없어요.', "This note's paper is not in the library."))
    return
  }
  store.slipBox.paperID = target
  if (store.selectedID !== target) await showPaper(target)
  else {
    reconcileReaders()
    changed('reader')
  }
  await openAnchor({ ...place, paperID: target })
}
