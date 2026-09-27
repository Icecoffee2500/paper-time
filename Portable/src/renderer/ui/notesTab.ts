/**
 * The inspector's Notes tab: the slip-box seen from one paper — the Mac's
 * `PaperNotesView`.
 *
 * The notes themselves live in the library's slip-box, not under the paper
 * — a thought is worth keeping past the paper that caused it — so this is
 * the notes written against this paper, and a way to write another. Pressing
 * one opens it in place, with the way back above it.
 */
import { el, on } from '../dom.js'
import { platform } from '../bridge.js'
import { keyFor } from '../../shared/shortcuts.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'
import { changed, notesForPaper, noteByID, panePapers, store, type Paper } from '../state.js'
import { createNote, deleteNote } from '../notesModel.js'
import { editorHost, noteRow, type NoteEditorActions } from './noteEditor.js'
import { showMenu } from './toolbar.js'

/**
 * One editor per paper, as each pane's link keeps its own open note on the
 * Mac (`ReaderLink.openNoteID`): with two papers side by side, going to the
 * other pane and back finds the note still open, caret and all.
 */
const hosts = new Map<string, ReturnType<typeof editorHost>>()

function hostFor(paperID: string) {
  let host = hosts.get(paperID)
  if (!host) hosts.set(paperID, (host = editorHost()))
  return host
}

/** Opens a note in a paper's tab — the paper in front unless another is named; null goes back to the list. */
export function openNoteInTab(id: string | null, paperID: string | null = store.selectedID) {
  if (!paperID) return
  if ((store.noteOpenByPaper.get(paperID) ?? null) === id) return
  if (id === null) {
    hosts.get(paperID)?.drop()
    store.noteOpenByPaper.delete(paperID)
  } else {
    store.noteOpenByPaper.set(paperID, id)
  }
  changed('notes', 'inspector')
}

/** The editor showing in the tab of the paper in front, if one is. */
export const openEditor = () => (store.selectedID ? hosts.get(store.selectedID)?.current() ?? null : null)

export function renderNotesTab(body: HTMLElement, paper: Paper, actions: NoteEditorActions) {
  // The editors of papers no longer on screen are let go of — written out.
  const showing = new Set([...panePapers(), paper.id])
  for (const [id, host] of hosts) {
    if (showing.has(id)) continue
    host.drop()
    hosts.delete(id)
    store.noteOpenByPaper.delete(id)
  }
  const host = hostFor(paper.id)
  const openID = store.noteOpenByPaper.get(paper.id) ?? null
  const open = openID ? noteByID(openID) : undefined
  // A note of another paper does not belong here: the tab is this paper's.
  if (open && (open.paperID === paper.id || open.paperID === null)) {
    body.append(host.show(open.id, { ...actions, close: () => openNoteInTab(null, paper.id) }).node)
    return
  }
  if (openID) store.noteOpenByPaper.delete(paper.id)
  host.drop()

  const mine = notesForPaper(paper.id)
  const head = el('div', { class: 'notes-tab-head' })
  head.append(el('span', {
    class: 'notes-tab-count',
    text: mine.length === 1 ? L('노트 1개', '1 note') : L(`노트 ${mine.length}개`, `${mine.length} notes`),
  }))
  head.append(el('span', { class: 'toolbar-spacer' }))
  const add = el('button', { class: 'plain-button note-new', title: L('이 논문에 새 노트 쓰기', 'Write a new note about this paper'), html: icon('square.and.pencil') })
  add.append(el('span', { text: L('새 노트', 'New Note') }))
  on(add, 'click', () => openNoteInTab(createNote(paper.id).id, paper.id))
  head.append(add)
  body.append(head)

  if (mine.length === 0) {
    const key = keyFor('linkToNote', platform)
    body.append(el('div', { class: 'empty notes-empty' }, [
      el('span', { html: icon('note') }),
      el('h2', { text: L('아직 노트가 없어요', 'No Notes Yet') }),
      el('p', { text: L(`노트 하나에 생각 하나. 구절을 고르고 ${key}을 누르면 그 자리에 이어져요.`, `One thought per note. Select a passage and press ${key} to link to it.`) }),
    ]))
    return
  }
  const list = el('div', { class: 'note-list', role: 'listbox' })
  for (const note of mine) {
    const row = noteRow(note)
    on(row, 'click', () => openNoteInTab(note.id, paper.id))
    on(row, 'contextmenu', (event: MouseEvent) => {
      event.preventDefault()
      showMenu(row, [{ label: L('지우기', 'Delete'), icon: 'trash', action: () => deleteNote(note.id) }])
    })
    list.append(row)
  }
  body.append(list)
}
