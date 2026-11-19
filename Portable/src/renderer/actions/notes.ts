/**
 * The ways into a note: from the palette, a search row, a link, ⌘N and ⌘L.
 */
import { changed, isSlipBoxShelf, latestNoteForPaper, noteByID, paper as findPaper, setShelf, slipBoxShelfFor, store } from '../state.js'
import { shell, solo } from '../shell.js'
import { focused, reconcileReaders } from '../pageArea.js'
import { openAnchor, showPaper } from './openPapers.js'
import { saveSettings, setInspectorTab } from '../settingsController.js'
import { revealPane } from '../layout.js'
import {
  createArea, createNote, moveNoteToArea, removeArea, renameArea, slipBoxShows, visibleNotes,
} from '../notesModel.js'
import { areaAfterRename, areaName, areaNameProblem, isAreaName } from '../../shared/noteAreas.js'
import type { AreaRefusal } from '../../shared/api.js'
import { call, platform } from '../bridge.js'
import { askForName } from '../ui/ask.js'
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
  // Where it was left, docked or floating — not the next step of ⌘]'s turn.
  if (!store.settings.panes.inspector) revealPane('inspector')
  shell.inspector.update()
  shell.toolbar.update()
}

/**
 * A note in the slip-box, beside the list — in the place it belongs to: 문헌
 * 노트 for a note on a source, 지식 for one of one's own (`slipBoxScope(for:)`).
 * The place in front is kept when it already holds the note (an area of 지식,
 * say), and so are the search, the tag and the kind narrowing the list, as
 * the Mac keeps them (`SlipBoxDetail`) — unless they hide the very note being
 * opened, which would stand in the editor with no row lit.
 */
export function revealNoteInSlipBox(id: string) {
  const note = noteByID(id)
  const shelf = isSlipBoxShelf(store.shelf) && slipBoxShows(store.shelf, note, { narrowed: false })
    ? store.shelf
    : slipBoxShelfFor(note)
  if (!visibleNotes().some((one) => one.id === id)) {
    store.slipBox.query = ''
    store.slipBox.tag = null
  }
  // The kind chips of 문헌 노트 let it through too.
  if (shelf.kind === 'notes' && note && !slipBoxShows(shelf, note, { narrowed: true })) {
    store.settings.literatureNoteKind = ''
    saveSettings({ literatureNoteKind: '' })
  }
  setShelf(shelf)
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
  if (paper && !isSlipBoxShelf(store.shelf)) {
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
 * Command-N: a new note in the slip-box, with the caret in it (`RootView`'s
 * `.paperTimeNewNote`). In 지식, a note of one's own filed in the area shown;
 * else on the paper chosen, a literature note in 문헌 노트; with none, a
 * note of one's own in 지식. The Notes tab's «New Note» is the way to write
 * one beside the page.
 */
export function newNote() {
  if (solo) return saidInMainWindow()
  const shelf = store.shelf
  let note
  if (shelf.kind === 'knowledge') {
    note = createNote(null, 'note', shelf.area ?? '')
  } else if (store.selectedID && findPaper(store.selectedID)) {
    note = createNote(store.selectedID)
  } else {
    note = createNote(null)
  }
  revealNoteInSlipBox(note.id)
  requestAnimationFrame(() => slipBoxEditor()?.focus())
}

/**
 * A quoted passage was clicked on the page: its note opens where notes are
 * showing, at the quotation, glowing — the Mac's `openQuotation`. A note
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
  if (isSlipBoxShelf(store.shelf) || !own) {
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

// MARK: - Areas of knowledge

/** What to say when an area could not be made, renamed or taken away. */
function sayRefused(why: AreaRefusal, name: string) {
  switch (why) {
    case 'exists': return toast(L(`‘${name}’ 영역이 이미 있어요.`, `There’s already an area called “${name}”.`))
    case 'name': return toast(L('그 이름은 영역 이름으로 쓸 수 없어요.', 'That name can’t be an area’s.'))
    case 'missing': return toast(L('그 영역은 이제 없어요.', 'That area isn’t there anymore.'))
    case 'away': return toast(L('노트 폴더에 닿을 수 없어요. 폴더가 연결돼 있는지 봐주세요.', 'Paper Time can’t reach the notes folder. Check that it’s connected.'))
  }
}

/** The name sheet for an area, as the Mac's `AreaNameSheet` asks it. */
function askAreaName(title: string, confirm: string, initial?: string): Promise<string | null> {
  return askForName({
    title,
    placeholder: L('영역 이름', 'Area Name'),
    confirm,
    initial,
    accepts: (name) => isAreaName(name, platform),
    problem: (name) => areaNameProblem(name, platform),
  })
}

/** «새 영역…» — at the top, or `inside` another area — and the new area shown. */
export async function askNewArea(inside = '') {
  const title = inside ? L(`‘${areaName(inside)}’ 안에 새 영역`, `New Area in “${areaName(inside)}”`) : L('새 영역', 'New Area')
  const name = await askAreaName(title, L('만들기', 'Create'))
  if (!name) return
  const made = await createArea(name, inside)
  if ('error' in made) return sayRefused(made.error, name)
  setShelf({ kind: 'knowledge', area: made.area })
  changed('shelf')
}

/** «이름 바꾸기…» on an area: its folder renamed, and the list in front following it. */
export async function askRenameArea(area: string) {
  const name = await askAreaName(L('영역 이름 바꾸기', 'Rename Area'), L('바꾸기', 'Rename'), areaName(area))
  if (!name) return
  const renamed = await renameArea(area, name)
  if ('error' in renamed) return sayRefused(renamed.error, name)
  const shelf = store.shelf
  if (shelf.kind === 'knowledge' && shelf.area) {
    const now = areaAfterRename(shelf.area, area, renamed.area)
    if (now !== null) {
      setShelf({ kind: 'knowledge', area: now })
      changed('shelf')
    }
  }
}

/** «영역 지우기 — 노트는 위로 옮겨요»: the folder goes, its notes go up one level. */
export async function deleteArea(area: string) {
  const shelf = store.shelf
  if (shelf.kind === 'knowledge' && shelf.area && areaAfterRename(shelf.area, area, '') !== null) {
    setShelf({ kind: 'knowledge', area: null })
    changed('shelf')
  }
  const removed = await removeArea(area)
  if ('error' in removed) sayRefused(removed.error, areaName(area))
}

/** The area's folder in the desktop's file manager. */
export function revealArea(area: string) {
  void call('notes:revealArea', { area })
}

/** A note dropped on an area in the sidebar: filed there. */
export function fileNoteInArea(id: string, area: string) {
  void moveNoteToArea(id, area)
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
