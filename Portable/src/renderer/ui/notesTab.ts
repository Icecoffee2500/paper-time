/**
 * The inspector's Notes tab: the slip-box seen from one paper — the Mac's
 * `PaperNotesView`.
 *
 * The notes themselves live in the library's slip-box, not under the paper
 * — a thought is worth keeping past the paper that caused it — so this is
 * the notes written against this paper, and a way to write another. Pressing
 * one opens it in place, with the way back above it.
 */
import { clear, el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'
import { changed, notesForPaper, noteByID, store, type Paper } from '../state.js'
import { createNote, deleteNote } from '../notesModel.js'
import { editorHost, noteRow, type NoteEditorActions } from './noteEditor.js'
import { showMenu } from './toolbar.js'

const host = editorHost()

/** Opens a note in the tab; null goes back to the list. */
export function openNoteInTab(id: string | null) {
  if (store.noteOpenID === id) return
  if (id === null) host.drop()
  store.noteOpenID = id
  changed('notes', 'inspector')
}

/** The editor showing in the tab, if one is. */
export const openEditor = () => host.current()

export function renderNotesTab(body: HTMLElement, paper: Paper, actions: NoteEditorActions) {
  const openID = store.noteOpenID
  const open = openID ? noteByID(openID) : undefined
  // A note of another paper does not belong here: the tab is this paper's.
  if (open && (open.paperID === paper.id || open.paperID === null)) {
    body.append(host.show(open.id, { ...actions, close: () => openNoteInTab(null) }).node)
    return
  }
  if (openID) store.noteOpenID = null
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
  on(add, 'click', () => openNoteInTab(createNote(paper.id).id))
  head.append(add)
  body.append(head)

  if (mine.length === 0) {
    body.append(el('div', { class: 'empty notes-empty' }, [
      el('span', { html: icon('note') }),
      el('h2', { text: L('아직 노트가 없어요', 'No Notes Yet') }),
      el('p', { text: L('노트 하나에 생각 하나. 구절을 고르고 Ctrl+L을 누르면 그 자리에 이어져요.', 'One thought per note. Select a passage and press Ctrl+L to link to it.') }),
    ]))
    return
  }
  const list = el('div', { class: 'note-list', role: 'listbox' })
  for (const note of mine) {
    const row = noteRow(note)
    on(row, 'click', () => openNoteInTab(note.id))
    on(row, 'contextmenu', (event: MouseEvent) => {
      event.preventDefault()
      showMenu(row, [{ label: L('지우기', 'Delete'), icon: 'trash', action: () => deleteNote(note.id) }])
    })
    list.append(row)
  }
  body.append(list)
}

/** Takes the tab back to its list, letting go of whatever editor it had. */
export function resetNotesTab(body?: HTMLElement) {
  host.drop()
  store.noteOpenID = null
  if (body) clear(body)
}
