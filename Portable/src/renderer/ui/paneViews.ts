/**
 * The panes the row holds besides the list and the page (1.1): a sidebar
 * item pinned — its table, its notes, its projects — and a note. They were
 * the companion's three faces once; each is a pane of its own now, as many
 * as the row has room for.
 *
 * A pinned shelf is drawn by the same code the list's column uses, told
 * which shelf is its own: the board (`buildPlanBoard`'s scope), the projects
 * (`buildProjects`' pin). The slip-box's places get a list of their own,
 * smaller than the slip-box: a note pressed in it opens on the page.
 */
import { clear, el, on } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { L } from '../../shared/lang.js'
import { writeDraggedNote } from '../../shared/split.js'
import { areaTitle, noteOrderFrom, sortNotes } from '../../shared/noteAreas.js'
import { zettelDisplayTitle } from '../../shared/zettel.js'
import { paneShelfKey, type ContentPane, type PaneContent } from '../../shared/paneModel.js'
import { isSlipBoxShelf, noteByID, projectByID, readingShelf, store, type Note, type Shelf } from '../state.js'
import { createNote, placeNotes } from '../notesModel.js'
import { editorHost, noteRow, type NoteEditorActions } from './noteEditor.js'
import { shelfHeader, shelfSymbol, shelfTone } from './shelfHeader.js'
import { shelfTitle } from './paperList.js'
import { buildPlanBoard, type PlanBoardActions } from './planBoard.js'
import { buildProjects, type ProjectActions } from './projects.js'
import { paneCorner } from './paneChrome.js'
import { kindChip } from './slipBox.js'

export interface PaneViewActions extends PlanBoardActions, Pick<NoteEditorActions, 'openAnchor'> {
  /** A paper pressed in a pinned pane: on the page, beside this pane. */
  openPaper: (paneID: string, id: string) => void
  /** A note pressed in a pinned list of notes: on the page. */
  openNote: (id: string) => void
  /** A note pane's note picked, or put back (null). */
  setNote: (paneID: string, id: string | null) => void
  /** What a pinned project asks of the window. */
  project: Omit<ProjectActions, 'openPaper'>
}

let actions: PaneViewActions | null = null

export function setPaneViewActions(next: PaneViewActions) {
  actions = next
}

export interface PaneView {
  node: HTMLElement
  /** What it was built for; another content is another view. */
  key: string
  update: () => void
  /** Only the chosen paper moved. */
  mark: () => void
  dispose: () => void
}

const views = new Map<string, PaneView>()

/** The shelf a pane pins, or null for one this build cannot read (an id from another day). */
export function shelfOfContent(content: PaneContent): Shelf | null {
  if (content.kind !== 'shelf') return null
  try {
    const value = JSON.parse(content.shelf) as Shelf
    return value && typeof value === 'object' && typeof value.kind === 'string' ? value : null
  } catch {
    return null
  }
}

/** A shelf as a pane keeps it. */
export const shelfContent = (shelf: Shelf): { kind: 'shelf'; shelf: string } => ({ kind: 'shelf', shelf: paneShelfKey(shelf) })

/** What a pane is called — on its head, in the menus, on the capsule after it closes. */
export function paneTitle(pane: ContentPane): string {
  const content = pane.content
  switch (content.kind) {
    case 'list': return readingShelf(store.shelf, shelfTitle)
    case 'page': {
      if (isSlipBoxShelf(store.shelf) && store.slipBox.paperID === null) return L('노트', 'Note')
      if (store.shelf.kind === 'projects' && store.slipBox.paperID === null) return L('프로젝트', 'Project')
      return L('논문', 'Paper')
    }
    case 'note': {
      const note = content.note ? noteByID(content.note) : undefined
      return note ? zettelDisplayTitle(note) : L('노트', 'Note')
    }
    case 'shelf': {
      const shelf = shelfOfContent(content)
      return shelf ? readingShelf(shelf, shelfTitle) : L('칸', 'Pane')
    }
  }
}

/** The symbol a pane's name goes with. */
export function paneSymbol(pane: ContentPane): IconName {
  const content = pane.content
  switch (content.kind) {
    case 'list': return shelfSymbol(store.shelf)
    case 'page': return 'text.page'
    case 'note': return 'square.and.pencil'
    case 'shelf': {
      const shelf = shelfOfContent(content)
      return shelf ? shelfSymbol(shelf) : 'square.dashed'
    }
  }
}

function contentKey(content: PaneContent): string {
  // A note pane is one view whichever note it holds: the picker and the
  // editor are its two faces.
  return content.kind === 'shelf' ? `shelf:${content.shelf}` : content.kind
}

/** The view for a pinned or note pane, made when it is first wanted and kept while the pane shows the same thing. */
export function paneView(pane: ContentPane): PaneView {
  const key = contentKey(pane.content)
  const kept = views.get(pane.id)
  if (kept && kept.key === key) return kept
  kept?.dispose()
  const made = pane.content.kind === 'note' ? noteView(pane.id) : shelfView(pane.id, shelfOfContent(pane.content))
  made.node.dataset.paneId = pane.id
  views.set(pane.id, made)
  made.update()
  return made
}

/** The views of the panes that are gone, let go of. */
export function keepPaneViews(ids: Set<string>) {
  for (const [id, view] of [...views]) {
    if (ids.has(id)) continue
    view.dispose()
    views.delete(id)
  }
}

/** Every pinned and note pane drawn again — the library or the notes changed. */
export function updatePaneViews() {
  for (const view of views.values()) if (view.node.isConnected) view.update()
}

export function markPaneViews() {
  for (const view of views.values()) if (view.node.isConnected) view.mark()
}

// MARK: - A pinned shelf

function shelfView(paneID: string, shelf: Shelf | null): PaneView {
  const key = shelf ? `shelf:${paneShelfKey(shelf)}` : 'shelf:?'
  if (!shelf) return missingView(key)
  if (isSlipBoxShelf(shelf)) return notesListView(paneID, shelf, key)
  if (shelf.kind === 'projects') return projectView(paneID, shelf.id, key)
  const board = buildPlanBoard({
    refresh: () => actions?.refresh(),
    adoptLoose: () => actions?.adoptLoose(),
  }, {
    shelf: () => shelf,
    open: (id) => actions?.openPaper(paneID, id),
  })
  board.node.classList.add('pinned-board')
  return { node: board.node, key, update: () => board.update(), mark: () => board.mark(), dispose: () => board.dispose() }
}

/** A pinned item the library no longer has — a plan deleted, a tag gone. */
function missingView(key: string): PaneView {
  const node = el('div', { class: 'panel pane-missing' })
  const head = el('div', { class: 'shelf-head-wrap' }, [shelfHeader({ icon: 'square.dashed', title: L('없는 항목', 'Missing Item'), closes: true })])
  node.append(head, el('div', { class: 'empty' }, [
    el('span', { html: icon('square.dashed') }),
    el('h2', { text: L('이 칸에 보일 것이 없어요', 'Nothing to Show Here') }),
    el('p', { text: L('⌄를 눌러 다른 것을 띄워 보세요.', 'Press ⌄ to show something else.') }),
  ]))
  return { node, key, update: () => {}, mark: () => {}, dispose: () => {} }
}

/** 문헌 노트, 지식 or one area, pinned: its notes, searched; one pressed opens on the page. */
function notesListView(paneID: string, shelf: Shelf, key: string): PaneView {
  const node = el('div', { class: 'panel pinned-notes' })
  const head = el('div', { class: 'shelf-head-wrap' })
  const search = el('input', {
    type: 'text', class: 'slipbox-search', placeholder: L('노트 찾기', 'Search notes'), 'aria-label': L('노트 찾기', 'Search notes'), spellcheck: 'false',
  }) as HTMLInputElement
  const searchBox = el('div', { class: 'slipbox-search-box', html: icon('magnifyingglass') })
  searchBox.append(search)
  const list = el('div', { class: 'panel-body pinned-notes-list', role: 'listbox', 'aria-label': L('노트', 'Notes') })
  node.append(head, el('div', { class: 'slipbox-search-row' }, [searchBox]), list)
  let query = ''
  on(search, 'input', () => {
    query = search.value
    update()
  })
  on(search, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  let drawn = ''

  function update() {
    const all = placeNotes(shelf)
    const folded = query.trim().toLowerCase()
    const shown = sortNotes(folded ? all.filter((note) => zettelDisplayTitle(note).toLowerCase().includes(folded) || note.body.toLowerCase().includes(folded)) : all,
      noteOrderFrom(store.settings.slipBoxNoteOrder))
    const title = readingShelf(shelf, shelfTitle)
    const signature = JSON.stringify([title, all.length, shown.map((note) => [note.id, zettelDisplayTitle(note), note.modified.getTime(), note.paperID])])
    if (signature === drawn) return
    drawn = signature
    clear(head)
    head.append(shelfHeader({
      icon: shelfSymbol(shelf), tone: shelfTone(shelf), title,
      subtitle: L(`노트 ${all.length}개`, all.length === 1 ? '1 note' : `${all.length} notes`),
      closes: true,
    }))
    const top = list.scrollTop
    clear(list)
    if (shown.length === 0) {
      list.append(el('div', { class: 'empty' }, [
        el('span', { html: icon('note') }),
        el('h2', { text: folded ? L('맞는 노트가 없어요', 'Nothing Matches') : L('아직 노트가 없어요', 'No Notes Yet') }),
      ]))
      return
    }
    for (const note of shown) list.append(noteListRow(note))
    list.scrollTop = top
  }

  function noteListRow(note: Note): HTMLElement {
    const source = note.paperID
      ? store.papers.find((entry) => entry.id === note.paperID)
      : undefined
    const row = noteRow(note, { source: source ? `${kindChip(source.meta.shelfKind)} · ${source.meta.displayTitle}` : note.paperID ? undefined : areaTitle(note.area) })
    row.draggable = true
    row.tabIndex = 0
    on(row, 'click', () => actions?.openNote(note.id))
    on(row, 'keydown', (event: KeyboardEvent) => {
      if (event.key !== 'Enter') return
      event.preventDefault()
      actions?.openNote(note.id)
    })
    // Onto a project's materials, or an area in the sidebar, as from the slip-box.
    on(row, 'dragstart', (event: DragEvent) => {
      if (!event.dataTransfer) return
      writeDraggedNote(event.dataTransfer, note.id)
      event.dataTransfer.effectAllowed = 'copyMove'
    })
    return row
  }

  return { node, key, update, mark: () => {}, dispose: () => {} }
}

/** 프로젝트, pinned: the list of them; one project pinned: its page. */
function projectView(paneID: string, id: string | null, key: string): PaneView {
  const projects = buildProjects({
    ...(actions?.project ?? { openNote: () => {}, openPlan: () => {}, showPapers: () => {}, papersShown: () => true, listShown: () => true }),
    openPaper: (paper) => actions?.openPaper(paneID, paper),
  }, () => id)
  if (id === null) {
    return { node: projects.listNode, key, update: () => projects.update(), mark: () => {}, dispose: () => {} }
  }
  // A project's page has no head of its own to hold the ⌄ and the ×.
  const node = projects.pageNode
  node.classList.add('has-corner')
  node.append(paneCorner())
  return {
    node,
    key,
    update: () => {
      // A project that was deleted says so rather than showing the list in its place.
      if (!projectByID(id)) node.dataset.missing = 'true'
      projects.update()
    },
    mark: () => {},
    dispose: () => {},
  }
}

// MARK: - A note

/** One note: picked from the notes, then written in — what the companion's note was. */
function noteView(paneID: string): PaneView {
  const host = editorHost()
  const node = el('div', { class: 'panel note-pane' })
  const head = el('div', { class: 'shelf-head-wrap' })
  const body = el('div', { class: 'note-pane-body' })
  node.append(head, body)
  const noteID = (): string | null => {
    const pane = store.row.panes.find((one) => one.id === paneID)
    return pane?.content.kind === 'note' ? pane.content.note : null
  }

  // ---- the picker
  let query = ''
  const search = el('input', {
    type: 'text', class: 'slipbox-search', placeholder: L('노트 찾기', 'Search notes'), spellcheck: 'false', 'aria-label': L('노트 찾기', 'Search notes'),
  }) as HTMLInputElement
  on(search, 'input', () => {
    query = search.value
    drawPicker()
  })
  on(search, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  const searchBox = el('div', { class: 'slipbox-search-box', html: icon('magnifyingglass') })
  searchBox.append(search)
  const list = el('div', { class: 'panel-body pinned-notes-list', role: 'listbox', 'aria-label': L('노트', 'Notes') })
  // The pen beside the search, where a narrow pane keeps it: a head that
  // gives way would take the one way to a new note with it.
  const pen = el('button', { class: 'icon-button', title: L('새 지식 노트', 'New Knowledge Note'), 'aria-label': L('새 지식 노트', 'New Knowledge Note'), html: icon('square.and.pencil') })
  on(pen, 'click', () => actions?.setNote(paneID, createNote(null).id))
  const picker = el('div', { class: 'note-pane-view' }, [el('div', { class: 'slipbox-search-row note-pane-search' }, [searchBox, pen]), list])

  // ---- the editor, and the way back to the notes above it
  const back = el('button', { class: 'plain-button note-back note-pane-back' }, [el('span', { html: icon('chevron.left') }), el('span', { text: L('다른 노트', 'Other Notes') })])
  on(back, 'click', () => actions?.setNote(paneID, null))
  const editorSlot = el('div', { class: 'note-pane-editor' })
  const editing = el('div', { class: 'note-pane-view' }, [el('div', { class: 'note-pane-back-row' }, [back]), editorSlot])
  const editorActions: NoteEditorActions = {
    openAnchor: (place) => actions?.openAnchor(place),
    // A link followed in the pane's note opens that note here.
    openNote: (id) => actions?.setNote(paneID, id),
  }

  let drawnHead = ''
  function drawHead(note: Note | undefined) {
    const signature = JSON.stringify([note?.id ?? null, note ? zettelDisplayTitle(note) : null])
    if (signature === drawnHead) return
    drawnHead = signature
    clear(head)
    head.append(shelfHeader({
      icon: 'square.and.pencil',
      title: note ? zettelDisplayTitle(note) : L('노트', 'Note'),
      subtitle: note ? (note.paperID ? L('문헌 노트', 'Literature note') : areaTitle(note.area)) : L('쓸 노트를 골라요', 'Choose a note to write in'),
      closes: true,
    }))
  }

  let drawnList = ''
  function drawPicker() {
    const folded = query.trim().toLowerCase()
    const notes = [...store.notes]
      .sort((a, b) => b.modified.getTime() - a.modified.getTime())
      .filter((one) => !folded || zettelDisplayTitle(one).toLowerCase().includes(folded) || one.body.toLowerCase().includes(folded))
      .slice(0, 200)
    const signature = JSON.stringify([folded, notes.map((one) => [one.id, zettelDisplayTitle(one), one.paperID, one.area])])
    if (signature === drawnList) return
    drawnList = signature
    clear(list)
    if (notes.length === 0) {
      list.append(el('div', { class: 'empty' }, [
        el('span', { html: icon('note') }),
        el('h2', { text: folded ? L('맞는 노트가 없어요', 'Nothing Matches') : L('아직 노트가 없어요', 'No Notes Yet') }),
      ]))
      return
    }
    for (const note of notes) {
      const row = noteRow(note, { source: note.paperID ? L('문헌 노트', 'Literature note') : areaTitle(note.area) })
      row.draggable = true
      on(row, 'click', () => actions?.setNote(paneID, note.id))
      on(row, 'dragstart', (event: DragEvent) => {
        if (!event.dataTransfer) return
        writeDraggedNote(event.dataTransfer, note.id)
        event.dataTransfer.effectAllowed = 'copyMove'
      })
      list.append(row)
    }
  }

  function update() {
    const id = noteID()
    const note = id ? noteByID(id) : undefined
    drawHead(note)
    if (note) {
      if (body.firstChild !== editing) {
        clear(body)
        body.append(editing)
      }
      const editor = host.show(note.id, editorActions)
      if (editor.node.parentElement !== editorSlot) {
        clear(editorSlot)
        editorSlot.append(editor.node)
      }
      return
    }
    host.drop()
    if (body.firstChild !== picker) {
      clear(body)
      body.append(picker)
    }
    drawPicker()
  }

  return { node, key: 'note', update, mark: () => {}, dispose: () => host.drop() }
}

