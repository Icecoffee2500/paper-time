/**
 * The whole slip-box: every note in the library, whichever paper it came
 * from — the Mac's `SlipBoxList` in the list column and `SlipBoxDetail` in
 * the page area, shown while the sidebar's «Notes» row is chosen.
 *
 * Search across the box and the tags written in the notes are the two ways
 * in; the links between notes are the third, and they live in the notes
 * themselves. The list is grouped by the paper each note was written
 * against — the maps first, since a map is where the others live, then the
 * drafts, then the papers, and the notes of no paper last.
 */
import { clear, el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'
import { zettelDisplayTitle } from '../../shared/zettel.js'
import { changed, noteByID, store, type Note, type Paper } from '../state.js'
import { addToMap, createNote, deleteNote, drafts, maps, noteTagCounts, visibleNotes } from '../notesModel.js'
import { editorHost, noteRow, type NoteEditorActions } from './noteEditor.js'
import { showMenu, type MenuEntry } from './toolbar.js'

export interface SlipBoxActions extends NoteEditorActions {
  /** The paper a group is named after, or null when the library no longer has it. */
  paper: (id: string) => Paper | undefined
}

interface NoteGroup {
  id: string
  title: string
  notes: Note[]
}

const host = editorHost()

/** Opens a note beside the list; null puts the editor away. */
export function openNoteInSlipBox(id: string | null) {
  store.slipBox.openID = id
  store.slipBox.paperID = null
  if (id === null) host.drop()
  changed('notes', 'slipBox')
}

export const slipBoxEditor = () => host.current()

export function buildSlipBox(actions: SlipBoxActions): { node: HTMLElement; detail: HTMLElement; update: () => void } {
  // ---- the list column
  const node = el('div', { class: 'panel slipbox' })
  const header = el('div', { class: 'panel-header slipbox-head' })
  const search = el('input', {
    type: 'text', class: 'slipbox-search', placeholder: L('노트 찾기', 'Search notes'),
    'aria-label': L('노트 찾기', 'Search notes'), spellcheck: 'false',
  }) as HTMLInputElement
  const searchBox = el('div', { class: 'slipbox-search-box', html: icon('magnifyingglass') })
  searchBox.append(search)
  const clearSearch = el('button', { class: 'icon-button slipbox-clear', title: L('찾을 말 지우기', 'Clear the search'), html: icon('xmark.circle.fill') })
  searchBox.append(clearSearch)
  on(search, 'input', () => {
    store.slipBox.query = search.value
    update()
  })
  on(search, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  on(clearSearch, 'click', () => {
    search.value = ''
    store.slipBox.query = ''
    update()
  })
  const add = el('button', { class: 'icon-button', title: L('노트·지도·초안 쓰기', 'Write a note, a map, or a draft'), html: icon('square.and.pencil') })
  on(add, 'click', () => {
    showMenu(add, [
      { label: L('새 노트', 'New Note'), icon: 'note', action: () => openNoteInSlipBox(createNote(null).id) },
      { label: L('새 지도', 'New Map'), icon: 'map', action: () => openNoteInSlipBox(createNote(null, 'map').id) },
      { label: L('새 초안', 'New Draft'), icon: 'doc.text', action: () => openNoteInSlipBox(createNote(null, 'draft').id) },
    ], 'right')
  })
  header.append(el('span', { text: L('노트', 'Notes') }), searchBox, add)
  const tags = el('div', { class: 'slipbox-tags' })
  const body = el('div', { class: 'panel-body slipbox-body' })
  node.append(header, tags, body)

  // ---- the page area's half: the note that is open, or an invitation
  const detail = el('div', { class: 'panel slipbox-detail' })

  const groups = (): NoteGroup[] => {
    const visible = visibleNotes()
    const found: NoteGroup[] = []
    const index = new Map<string, number>()
    const mapNotes = visible.filter((note) => note.kind === 'map')
    if (mapNotes.length > 0) found.push({ id: 'maps', title: L('지도', 'Maps'), notes: mapNotes })
    const draftNotes = visible.filter((note) => note.kind === 'draft')
    if (draftNotes.length > 0) found.push({ id: 'drafts', title: L('초안', 'Drafts'), notes: draftNotes })
    for (const note of visible) {
      if (note.kind !== 'note') continue
      // A paper this library no longer has is no group of its own: three
      // chips all saying "Notes of my own" said nothing.
      const paper = note.paperID ? actions.paper(note.paperID) : undefined
      const key = paper ? paper.id : '-'
      const at = index.get(key)
      if (at !== undefined) {
        found[at].notes.push(note)
        continue
      }
      index.set(key, found.length)
      found.push({ id: key, title: paper?.meta.displayTitle ?? L('따로 쓴 노트', 'Notes of my own'), notes: [note] })
    }
    const special = new Set(['maps', 'drafts'])
    return [
      ...found.filter((group) => special.has(group.id)),
      ...found.filter((group) => group.id !== '-' && !special.has(group.id)),
      ...found.filter((group) => group.id === '-'),
    ]
  }

  const rowMenu = (note: Note): MenuEntry[] => {
    const entries: MenuEntry[] = []
    if (note.kind === 'note') {
      const onto = maps()
      const into = drafts()
      if (onto.length > 0) {
        entries.push({ label: L('지도에 올리기', 'Put on Map'), icon: 'map', children: onto.map((map) => ({ label: zettelDisplayTitle(map), action: () => addToMap(note.id, map.id) })) })
      }
      if (into.length > 0) {
        entries.push({ label: L('초안에 넣기', 'Add to Draft'), icon: 'doc.text', children: into.map((draft) => ({ label: zettelDisplayTitle(draft), action: () => addToMap(note.id, draft.id) })) })
      }
      if (entries.length > 0) entries.push({ separator: true })
    }
    entries.push({ label: L('지우기', 'Delete'), icon: 'trash', action: () => deleteNote(note.id) })
    return entries
  }

  function drawTags() {
    clear(tags)
    const counts = noteTagCounts()
    tags.style.display = counts.length > 0 ? '' : 'none'
    for (const { tag, count } of counts) {
      const isOn = store.slipBox.tag === tag
      const chip = el('button', { class: 'slipbox-tag', 'aria-pressed': String(isOn) }, [
        el('span', { text: `#${tag}` }),
        el('span', { class: 'slipbox-tag-count', text: String(count) }),
      ])
      on(chip, 'click', () => {
        store.slipBox.tag = isOn ? null : tag
        update()
      })
      tags.append(chip)
    }
  }

  function drawList() {
    clear(body)
    if (search.value !== store.slipBox.query) search.value = store.slipBox.query
    clearSearch.style.display = store.slipBox.query ? '' : 'none'
    const grouped = groups()
    if (grouped.length === 0) {
      const none = store.notes.length === 0
      body.append(el('div', { class: 'empty' }, [
        el('span', { html: icon('tray') }),
        el('h2', { text: none ? L('아직 노트가 없어요', 'No Notes Yet') : L('맞는 노트가 없어요', 'Nothing Matches') }),
        el('p', {
          text: none
            ? L('읽으면서 쓴 노트가 여기 모여요. 그 노트를 쓰게 만든 구절에 이어진 채로요.', 'Notes you write while reading collect here, linked to the passage that prompted them.')
            : L('찾는 말에 맞는 노트가 없어요.', 'No note matches that search.'),
        }),
      ]))
      return
    }
    for (const group of grouped) {
      // The paper as a chip, the same shape the library folder wears in the
      // source list: a group of notes is named, not ruled off.
      body.append(el('div', { class: 'note-group' }, [
        el('span', { class: group.id === '-' ? 'note-group-name plain' : 'note-group-name', text: group.title, title: group.title }),
      ]))
      for (const note of group.notes) {
        const row = noteRow(note, { selected: store.slipBox.openID === note.id })
        on(row, 'click', () => openNoteInSlipBox(note.id))
        on(row, 'contextmenu', (event: MouseEvent) => {
          event.preventDefault()
          showMenu(row, rowMenu(note))
        })
        body.append(row)
      }
    }
  }

  function drawDetail() {
    const id = store.slipBox.openID
    const note = id ? noteByID(id) : undefined
    if (!note) {
      if (id) store.slipBox.openID = null
      host.drop()
      clear(detail)
      detail.append(el('div', { class: 'empty' }, [
        el('span', { html: icon('note') }),
        el('h2', { text: L('고른 노트가 없어요', 'No Note Selected') }),
        el('p', { text: L('노트를 고르거나 새로 쓰면 돼요.', 'Choose a note, or write a new one.') }),
      ]))
      return
    }
    const editor = host.show(note.id, actions)
    if (editor.node.parentElement !== detail) {
      clear(detail)
      detail.append(editor.node)
    }
  }

  function update() {
    // Not the list while somebody is typing in the search: rebuilding it
    // under the field is fine, the field itself stays.
    drawTags()
    drawList()
    drawDetail()
  }

  update()
  return { node, detail, update }
}
