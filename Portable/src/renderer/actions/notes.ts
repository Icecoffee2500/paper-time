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
import { L } from '../../shared/lang.js'
import { passageText, quotationSource } from '../../shared/noteQuote.js'
import type { QuoteLink } from '../../shared/quotedPassages.js'
import { latex, leftOutFormulas, structured } from '../../shared/mathReader/reader.js'
import { copyText } from '../ui/clipboard.js'

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
    slipBoxEditor()?.reveal(words)
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
  requestAnimationFrame(() => slipBoxEditor()?.focus())
}

/**
 * The rule beside a quoted passage was clicked: its note opens where notes
 * are showing, at the quotation, glowing — the Mac's `openQuotation`. A note
 * about this paper, or about none, opens in the paper's Notes tab; another
 * paper's note that quotes this one opens in the slip-box with the paper
 * beside it, which is where a note about another paper is read — and so
 * does any note while the slip-box is showing.
 */
export async function openQuotation(paperID: string, link: QuoteLink) {
  const note = noteByID(link.noteID)
  if (!note) return
  if (solo) return saidInMainWindow()
  const own = note.paperID === null || note.paperID.toUpperCase() === paperID.toUpperCase()
  if (store.shelf.kind === 'notes' || !own) {
    revealNoteInSlipBox(note.id)
    // The paper stays where it was being read, the note beside it.
    store.slipBox.paperID = paperID
    changed('shelf', 'slipBox')
    if (store.selectedID !== paperID) await showPaper(paperID)
    else {
      reconcileReaders()
      changed('reader')
    }
    requestAnimationFrame(() => slipBoxEditor()?.revealQuotation(link.passage.url))
    return
  }
  if (store.selectedID !== paperID) await showPaper(paperID)
  showNoteTab()
  openNoteInTab(note.id, paperID)
  requestAnimationFrame(() => openNoteEditor()?.revealQuotation(link.passage.url))
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
export async function linkSelectionToNote() {
  const reader = focused()
  // The lasso's rectangle before any selection: while it is out there is no
  // selection, and what it caught is what was meant (`ReaderLink.selectionAnchor`).
  const lassoed = reader?.state.lasso ? reader.lassoAnchor() : null
  const anchor = lassoed ?? reader?.selectionAnchor()
  if (!reader || !anchor || !store.selectedID) {
    toast(reader?.state.lasso ? catchFirst() : L('먼저 글을 골라주세요.', 'Select some text first.'))
    return
  }
  // The page's shape, kept — a section title as a title, a displayed
  // equation on its own line with its number, the bold lead-in still bold —
  // read the way the Mac reads it (`MathReader.structured`); the words alone
  // when the page could not be read that way.
  let shaped = lassoed && reader.caught?.needsOCR
    ? []
    : structured(await (lassoed ? reader.lassoForMath() : reader.selectionForMath()).catch(() => []))
  // The lasso's last resort: a rectangle the page could not be read for is
  // read off its picture (`FormulaOCR`), and the quotation waits for it.
  let readOffPicture = false
  if (lassoed && shaped.length === 0) {
    toast(readingPicture())
    const reading = await reader.readCaughtByOCR().catch(() => null)
    if (!reading || !reader.state.lasso) {
      toast(noFormulaInside())
      return
    }
    shaped = [reading.latex]
    readOffPicture = true
  }
  const block = quotationSource(
    { pageIndex: anchor.pageIndex, rect: anchor.rect, quotedText: shaped.length > 0 ? shaped.join('\n') : passageText(anchor.text) },
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
  if (readOffPicture) {
    toast(L('그림에서 수식을 읽었어요. 틀린 데가 있는지 봐주세요.', 'Read the formula off the picture — check it over.'))
    return
  }
  const left = leftOutSentence(false)
  if (left) toast(left)
}

/** What to say when the last reading left formulas out — the file does not
 *  say what their symbols are (the Mac's `MathReader.leftOutSentence`). */
function leftOutSentence(copied: boolean): string | null {
  const count = leftOutFormulas()
  if (count === 0) return null
  const which = count === 1 ? 'one formula' : `${count} formulas`
  const whose = count === 1 ? 'its' : 'their'
  return copied
    ? L(`수식 ${count}개는 빼고 복사했어요. 파일에 그 기호가 무엇인지 적혀 있지 않아요.`, `Copied without ${which}. The file doesn't say what ${whose} symbols are.`)
    : L(`수식 ${count}개는 빼고 넣었어요. 파일에 그 기호가 무엇인지 적혀 있지 않아요.`, `Linked without ${which}. The file doesn't say what ${whose} symbols are.`)
}

/**
 * Ultracopy: the selection copied with its formulas as LaTeX, read off what
 * the page draws (`MathReader.latex`) — so a formula survives the trip into
 * a note or a paper instead of arriving as «p» with its subscript missing.
 */
export async function ultracopySelection() {
  const reader = focused()
  // The lasso's rectangle, while the lasso is out.
  if (reader?.state.lasso) {
    if (!reader.caught) return toast(catchFirst())
    const text = reader.caught.needsOCR ? '' : latex(await reader.lassoForMath().catch(() => []))
    if (!text) {
      // Nothing the reader could use: the picture is read instead, and the
      // clipboard waits for the model (a second or two).
      toast(readingPicture())
      const reading = await reader.readCaughtByOCR().catch(() => null)
      if (!reading) return toast(noFormulaInside())
      if (await copyText(reading.latex)) toast(L('그림에서 읽어 복사했어요. 틀린 데가 있는지 봐주세요.', 'Read off the picture and copied — check it over.'))
      return
    }
    if (await copyText(text)) toast(leftOutSentence(true) ?? L('수식까지 복사했어요.', 'Copied with formulas.'))
    return
  }
  const pages = reader ? await reader.selectionForMath().catch(() => []) : []
  if (!reader || pages.length === 0) {
    toast(L('먼저 글을 골라주세요.', 'Select some text first.'))
    return
  }
  const text = latex(pages)
  if (!text) return
  if (await copyText(text)) toast(leftOutSentence(true) ?? L('수식까지 복사했어요.', 'Copied with formulas.'))
}

/** The lasso is out and holds nothing yet. */
const catchFirst = () => L('먼저 수식을 사각형으로 잡아주세요.', 'Catch a formula in a rectangle first.')
/** The model is reading the picture; a second or two. */
const readingPicture = () => L('그림에서 수식을 읽는 중…', 'Reading the formula off the picture…')
/** The picture held no formula the model could read. */
const noFormulaInside = () => L('사각형 안에서 읽을 수식이 없어요.', 'No formula to read inside the rectangle.')

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
