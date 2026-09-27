/**
 * The ways into a note: from the palette, a search row, a link, ⌘N and ⌘L.
 */
import { changed, latestNoteForPaper, noteByID, paper as findPaper, setShelf, store } from '../state.js'
import { shell, solo } from '../shell.js'
import { focused, reconcileReaders } from '../pageArea.js'
import { openAnchor, showPaper } from './openPapers.js'
import { setInspectorTab } from '../settingsController.js'
import { togglePane } from '../layout.js'
import { createNote, visibleNotes } from '../notesModel.js'
import { openNoteInSlipBox, slipBoxEditor } from '../ui/slipBox.js'
import { openEditor as openNoteEditor, openNoteInTab } from '../ui/notesTab.js'
import { toast } from '../ui/toolbar.js'
import { revealWords } from '../ui/noteEditor.js'
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
 * A note in the slip-box, beside the list. The search and the tag narrowing
 * the list are kept, as the Mac keeps them (`SlipBoxDetail`) — unless they
 * hide the very note being opened, which would stand in the editor with no
 * row lit.
 */
export function revealNoteInSlipBox(id: string) {
  if (!visibleNotes().some((note) => note.id === id)) {
    store.slipBox.query = ''
    store.slipBox.tag = null
  }
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
  if (!note) return
  if (solo) return saidInMainWindow()
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
 * A note from Search Everything, where the Mac opens it: the slip-box, with
 * the note beside the list, whichever paper it is about — and, for a passage
 * found by meaning, at that passage.
 */
export function openNoteFromSearch(id: string, words?: string) {
  if (!noteByID(id)) return
  if (solo) return saidInMainWindow()
  revealNoteInSlipBox(id)
  if (!words) return
  requestAnimationFrame(() => {
    const area = slipBoxEditor()?.area
    if (area) revealWords(area, words)
  })
}

/**
 * Command-N: a new note in the slip-box, with the caret in it — about the
 * paper chosen, if one is, so it is filed under that paper (`RootView`'s
 * `.paperTimeNewNote`: `scope = .notes` and a note about `selectedPaperID`).
 * The Notes tab's «New Note» is the way to write one beside the page.
 */
export function newNote() {
  if (solo) return saidInMainWindow()
  const paperID = store.selectedID && findPaper(store.selectedID) ? store.selectedID : null
  revealNoteInSlipBox(createNote(paperID).id)
  requestAnimationFrame(() => slipBoxEditor()?.area.focus())
}

/** A window for one paper has no slip-box: the note is for the main window. */
function saidInMainWindow() {
  toast(L('노트는 메인 창에서 열 수 있어요.', 'Notes open in the main window.'))
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
  // With no note open, the one last written in about this paper carries on
  // — or a new one starts (`PaperNotesView`, both builds).
  if (!openNoteEditor()) {
    const latest = latestNoteForPaper(store.selectedID)
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
  // The note goes where the list was, and the paper takes the page area.
  changed('shelf')
  if (store.selectedID !== target) await showPaper(target)
  else {
    reconcileReaders()
    changed('reader')
  }
  await openAnchor({ ...place, paperID: target })
}
