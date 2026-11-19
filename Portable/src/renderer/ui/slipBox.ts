/**
 * The slip-box's places, as a list (1.1): 문헌 노트 — the notes written
 * against a paper, a book or a document, narrowed by the source's kind — or
 * 지식, the notes of no paper, in one area or all of them. The Mac's
 * `SlipBoxList` in the list column and `SlipBoxDetail` in the page area,
 * shown while one of the sidebar's slip-box rows is chosen.
 *
 * Search across the place and the tags written in the notes are the two
 * ways in; the links between notes are the third, and they live in the
 * notes themselves. One flat list, in the order chosen — the last edited
 * first, the last written first, or by name — each row saying where the
 * note came from: the source's kind and title, or the area it is filed in.
 */
import { clear, el, on } from '../dom.js'
import { icon, iconNode, type IconName } from '../icons.js'
import { L } from '../../shared/lang.js'
import { trimWhitespace, zettelDisplayTitle } from '../../shared/zettel.js'
import {
  NOTE_ORDERS, areaDepth, areaName, areaTitle, noteDateText, noteOrderFrom, noteOrderLabel, rewrittenAsKnowledge,
} from '../../shared/noteAreas.js'
import type { ShelfKind } from '../../shared/documentKind.js'
import { writeDraggedNote } from '../../shared/split.js'
import { LEGACY } from '../../shared/legacy.js'
import { changed, noteByID, setShelf, store, type Note, type Paper, type Shelf } from '../state.js'
import {
  addToMap, createNote, deleteNote, drafts, literatureKind, literatureKindCounts, maps, moveNoteToArea, noteAreas, noteTagCounts,
  placeNotes, slipBoxList, slipBoxShows, sourceKind, updateNote, visibleNotes,
} from '../notesModel.js'
import { KIND_NAMES } from '../actions/paper.js'
import { editorHost, type NoteEditorActions } from './noteEditor.js'
import { showMenu, showMenuAt, type MenuEntry } from './toolbar.js'
import { shelfHeader, shelfSymbol } from './shelfHeader.js'
import { ensurePagePane } from '../layout.js'

export interface SlipBoxActions extends NoteEditorActions {
  /** The paper a note was written against, or undefined when the library no longer has it. */
  paper: (id: string) => Paper | undefined
  /** The list's order or 문헌 노트's kind, chosen: kept for the next launch. */
  saveListSettings: (patch: { slipBoxNoteOrder?: string; literatureNoteKind?: string }) => void
}

/** The kind of source on a literature note's row — short, one source (`ShelfKind.chip`). */
export function kindChip(kind: ShelfKind): string {
  switch (kind) {
    case 'paper': return L('논문', 'Paper')
    case 'book': return L('책', 'Book')
    case 'document': return L('문서', 'Document')
  }
}

const host = editorHost()

/** Opens a note beside the list; null puts the editor away. */
export function openNoteInSlipBox(id: string | null) {
  const hadPaper = store.slipBox.paperID !== null
  // A note chosen with no page in the row: one comes, to write it in (1.1).
  if (id !== null) ensurePagePane()
  store.slipBox.openID = id
  store.slipBox.paperID = null
  if (id === null) host.drop()
  if (hadPaper) changed('shelf')
  changed('notes', 'slipBox')
}

/**
 * Back from a passage followed out of a note: the list where the note was
 * beside the paper, the note in the page area again (`slipBoxPaper`'s
 * «‹ Notes», and Escape).
 */
export function backToNotes(): boolean {
  if (store.slipBox.paperID === null) return false
  store.slipBox.paperID = null
  changed('shelf', 'slipBox')
  return true
}

export const slipBoxEditor = () => host.current()

export function buildSlipBox(actions: SlipBoxActions): { node: HTMLElement; detail: HTMLElement; side: HTMLElement; update: () => void } {
  // ---- the list column
  const node = el('div', { class: 'panel slipbox' })
  // The head every left column wears (`shelfHeader`): the tile, the name,
  // how many, and the pen; the search under it, full width, the way a
  // table's columns sit under a shelf's head (the Mac's `SlipBoxList`).
  const header = el('div', { class: 'shelf-head-wrap' })
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
  // The order the list is in, and the pen: in 지식 a note of no paper filed
  // in the area shown; in 문헌 노트 a note on the paper chosen in the
  // library — a literature note needs a source.
  const order = el('button', { class: 'icon-button', html: icon('arrow.up.arrow.down') })
  on(order, 'click', () => {
    const current = noteOrderFrom(store.settings.slipBoxNoteOrder)
    showMenu(order, NOTE_ORDERS.map((one) => ({
      label: noteOrderLabel(one),
      checked: one === current,
      action: () => {
        store.settings.slipBoxNoteOrder = one
        actions.saveListSettings({ slipBoxNoteOrder: one })
        update()
      },
    })), 'right')
  })
  const add = el('button', { class: 'icon-button', html: icon('square.and.pencil') }) as HTMLButtonElement
  on(add, 'click', () => {
    const shelf = store.shelf
    if (shelf.kind === 'knowledge') {
      openNoteInSlipBox(createNote(null, 'note', shelf.area ?? '').id)
      return
    }
    const paper = chosenPaper()
    if (!paper) return
    const note = createNote(paper.id)
    // A kind narrowed away would leave the new note with no row lit.
    if (!slipBoxShows(shelf, note, { narrowed: true })) setKindFilter(null)
    openNoteInSlipBox(note.id)
  })
  const searchRow = el('div', { class: 'slipbox-search-row' }, [searchBox])

  /** The paper chosen in the library — what a new literature note is written on. */
  const chosenPaper = (): Paper | undefined => (store.selectedID ? actions.paper(store.selectedID) : undefined)

  /** The place in front: 문헌 노트, or 지식 in one area or all of them. */
  const place = (): Shelf => (store.shelf.kind === 'knowledge' ? store.shelf : { kind: 'notes' })
  const knowledgeArea = (): string | null | undefined => (store.shelf.kind === 'knowledge' ? store.shelf.area : undefined)
  const isLiterature = () => store.shelf.kind !== 'knowledge'

  function placeTitle(): string {
    const area = knowledgeArea()
    return area === undefined ? L('문헌 노트', 'Literature Notes') : areaTitle(area)
  }

  let drawnHead = ''
  function drawHead() {
    const count = placeNotes(place()).length
    const paper = isLiterature() ? chosenPaper() : undefined
    const orderNow = noteOrderFrom(store.settings.slipBoxNoteOrder)
    const key = JSON.stringify([placeTitle(), shelfSymbol(place()), count, paper?.id ?? null, paper?.meta.displayTitle ?? null, orderNow, isLiterature()])
    if (key === drawnHead) return
    drawnHead = key
    order.title = L(`정렬: ${noteOrderLabel(orderNow)}`, `Sort: ${noteOrderLabel(orderNow)}`)
    if (isLiterature()) {
      add.disabled = !paper
      add.title = paper
        ? L(`‘${paper.meta.displayTitle}’에 노트 쓰기`, `Write a Note on “${paper.meta.displayTitle}”`)
        : L('문헌 노트는 논문을 고르고 써요', 'Choose a paper to write a literature note')
    } else {
      add.disabled = false
      add.title = L('새 노트', 'New Note')
    }
    clear(header)
    header.append(shelfHeader({
      icon: shelfSymbol(place()),
      title: placeTitle(),
      subtitle: L(`노트 ${count}개`, count === 1 ? '1 note' : `${count} notes`),
      trailing: [order, add],
      closes: true,
    }))
  }

  // 논문 · 책 · 문서 — the kinds of source 문헌 노트's notes were written
  // against, with how many of each; a press keeps only those.
  const kinds = el('div', { class: 'slipbox-kinds', role: 'group', 'aria-label': L('종류', 'Kind') })
  function setKindFilter(kind: ShelfKind | null) {
    store.settings.literatureNoteKind = kind ?? ''
    actions.saveListSettings({ literatureNoteKind: kind ?? '' })
    update()
  }
  let drawnKinds = ''
  function drawKinds() {
    const counted = isLiterature() ? literatureKindCounts(place()) : []
    const chosen = literatureKind()
    const shows = isLiterature() && (counted.length > 1 || chosen !== null)
    const key = JSON.stringify([shows, counted, chosen])
    if (key === drawnKinds) return
    drawnKinds = key
    clear(kinds)
    kinds.style.display = shows ? '' : 'none'
    if (!shows) return
    const total = counted.reduce((sum, one) => sum + one.count, 0)
    const chip = (kind: ShelfKind | null, count: number) => {
      const button = el('button', { class: 'slipbox-kind', 'aria-pressed': String(chosen === kind), 'data-v': kind ?? '' }, [
        el('span', { text: kind ? KIND_NAMES[kind].shelf() : L('모두', 'All') }),
        el('span', { class: 'slipbox-kind-count', text: String(count) }),
      ])
      on(button, 'click', () => setKindFilter(kind))
      kinds.append(button)
    }
    chip(null, total)
    const present = new Map(counted.map((one) => [one.kind, one.count]))
    for (const kind of ['paper', 'book', 'document'] as ShelfKind[]) {
      if (present.has(kind) || kind === chosen) chip(kind, present.get(kind) ?? 0)
    }
  }

  const tags = el('div', { class: 'slipbox-tags' })
  const body = el('div', { class: 'panel-body slipbox-body' })
  node.append(header, searchRow, kinds, tags, body)

  // ---- the page area's half: the note that is open, or an invitation
  const detail = el('div', { class: 'panel slipbox-detail' })

  // ---- a passage followed out of the note: the paper takes the page area
  // and the note stands where the list was, so the quotation and its page
  // are side by side — with the way back to the list above it. (The Mac
  // puts the paper in the list's column and keeps the note; here the
  // readers live in the page area, and the note is what fits a column.)
  const side = el('div', { class: 'panel slipbox-side' })
  const sideHead = el('div', { class: 'panel-header slipbox-side-head' })
  const back = el('button', { class: 'plain-button note-back', title: L('노트 목록으로 (Esc)', 'Back to Notes (Esc)'), html: icon('chevron.left') })
  back.append(el('span', { text: L('노트', 'Notes') }))
  on(back, 'click', () => backToNotes())
  const sideTitle = el('span', { class: 'slipbox-side-title' })
  sideHead.append(back, sideTitle)
  const sideBody = el('div', { class: 'panel-body slipbox-side-body' })
  side.append(sideHead, sideBody)

  /**
   * A literature note turned into knowledge: a new note of one's own that
   * starts with the way back to its source, open in 지식.
   */
  function rewriteAsKnowledge(note: Note) {
    const fresh = createNote(null)
    updateNote({ ...fresh, body: rewrittenAsKnowledge(note) })
    if (!visibleNotes().some((one) => one.id === fresh.id)) {
      store.slipBox.query = ''
      store.slipBox.tag = null
    }
    setShelf({ kind: 'knowledge', area: null })
    changed('shelf')
    openNoteInSlipBox(fresh.id)
  }

  /** What a right-click on a note offers: where to file it, and the way out (`SlipNoteMenu`). */
  const rowMenu = (note: Note): MenuEntry[] => {
    const entries: MenuEntry[] = [{ label: L('열기', 'Open'), action: () => openNoteInSlipBox(note.id) }]
    if (note.paperID) {
      entries.push({ label: L('지식으로 옮겨 쓰기', 'Rewrite as Knowledge'), icon: 'lightbulb', action: () => rewriteAsKnowledge(note) })
    } else {
      const areas = noteAreas()
      const into: MenuEntry[] = [
        { label: L('분류 안 함', 'Unfiled'), disabled: !note.area, action: () => void moveNoteToArea(note.id, '') },
      ]
      if (areas.length > 0) into.push({ separator: true })
      for (const area of areas) {
        into.push({
          // Spaces that stay spaces: a menu row collapses ordinary ones.
          label: '\u00a0\u00a0'.repeat(areaDepth(area) - 1) + areaName(area),
          disabled: note.area === area,
          action: () => void moveNoteToArea(note.id, area),
        })
      }
      entries.push({ label: L('영역으로 옮기기', 'Move to Area'), icon: 'folder', children: into })
    }
    if (LEGACY.slipBoxStructures && note.kind === 'note') {
      const onto = maps()
      const intoDrafts = drafts()
      if (onto.length > 0) {
        entries.push({ label: L('지도에 올리기', 'Put on Map'), icon: 'map', children: onto.map((map) => ({ label: zettelDisplayTitle(map), action: () => addToMap(note.id, map.id) })) })
      }
      if (intoDrafts.length > 0) {
        entries.push({ label: L('초안에 넣기', 'Add to Draft'), icon: 'doc.text', children: intoDrafts.map((draft) => ({ label: zettelDisplayTitle(draft), action: () => addToMap(note.id, draft.id) })) })
      }
    }
    entries.push({ separator: true })
    entries.push({ label: L('지우기', 'Delete'), icon: 'trash', danger: true, action: () => deleteNote(note.id) })
    return entries
  }

  /**
   * One note in the list: its title, where it came from — the source's kind
   * and title, or the area it is filed in — and when (`SlipNoteRow`).
   */
  function slipRow(note: Note, options: { kind: ShelfKind | null; showsArea: boolean; date: Date }): HTMLElement {
    const row = el('div', {
      class: 'note-row slip-row', role: 'option', draggable: 'true',
      'aria-selected': String(store.slipBox.openID === note.id), 'data-note': note.id,
    })
    const lines = el('div', { class: 'slip-row-lines' }, [el('span', { class: 'note-row-title', text: zettelDisplayTitle(note) })])
    const second = secondLine(note, options)
    if (second) lines.append(second)
    row.append(lines, el('span', { class: 'note-row-date', text: noteDateText(options.date) }))
    return row
  }

  function secondLine(note: Note, options: { kind: ShelfKind | null; showsArea: boolean }): HTMLElement | null {
    if (options.kind) {
      const source = note.paperID ? actions.paper(note.paperID) : undefined
      return el('div', { class: 'slip-row-second' }, [
        el('span', { class: 'slip-kind', 'data-kind': options.kind, text: kindChip(options.kind) }),
        el('span', { class: 'slip-source', text: source?.meta.displayTitle ?? L('라이브러리에 없는 논문', 'A paper no longer here') }),
      ])
    }
    if (options.showsArea) {
      const glyph = iconNode(note.area ? 'folder' : 'tray')
      return el('div', { class: 'slip-row-second slip-area' }, [
        ...(glyph ? [glyph] : []),
        el('span', { text: areaTitle(note.area) }),
      ])
    }
    const preview = note.body.split('\n').find((line) => trimWhitespace(line).length > 0)
    return preview ? el('div', { class: 'slip-row-second' }, [el('span', { class: 'slip-preview', text: trimWhitespace(preview) })]) : null
  }

  let drawnTags = ''
  function drawTags() {
    const counts = noteTagCounts()
    // The same chips, not drawn again: while a note is typed the tags almost
    // never change, and a row of new buttons under the pointer flickers.
    const key = JSON.stringify([counts, store.slipBox.tag])
    if (key === drawnTags) return
    drawnTags = key
    clear(tags)
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

  /** The notes in the order the list shows them — what ↑ and ↓ walk. */
  let shownOrder: string[] = []
  let drawnList = ''

  /** What an empty place says, and with what (`emptyTitle`, `emptyNote`). */
  function emptyPlace(nothingAtAll: boolean): { icon: IconName; title: string; note: string } {
    if (!nothingAtAll) {
      return {
        icon: 'magnifyingglass',
        title: L('맞는 노트가 없어요', 'Nothing Matches'),
        note: L('찾는 말이나 고른 종류에 맞는 노트가 없어요.', 'No note matches the search or the kind chosen.'),
      }
    }
    const area = knowledgeArea()
    if (area === undefined) {
      return {
        icon: shelfSymbol(place()),
        title: L('아직 문헌 노트가 없어요', 'No Literature Notes Yet'),
        note: L('논문을 읽으면서 노트 탭에 쓴 노트가 여기 모여요. 그 노트를 쓰게 만든 구절에 이어진 채로요.',
          'Notes you write in a paper’s Notes tab collect here, linked to the passage that prompted them.'),
      }
    }
    if (area) {
      return {
        icon: shelfSymbol(place()),
        title: L('이 영역에 노트가 없어요', 'Nothing in This Area'),
        note: L('옆 목록의 이 영역으로 노트를 끌어다 놓거나, 연필을 눌러 여기서 새로 써요.',
          'Drag notes onto this area in the sidebar, or press the pencil to write one here.'),
      }
    }
    return {
      icon: shelfSymbol(place()),
      title: L('아직 지식 노트가 없어요', 'No Knowledge Notes Yet'),
      note: L('내 말로 정리한 노트를 여기 써요. 오른쪽 위 연필로 시작해요.', 'Write what you’ve learned in your own words here. Start with the pencil.'),
    }
  }

  function drawList() {
    if (search.value !== store.slipBox.query) search.value = store.slipBox.query
    clearSearch.style.display = store.slipBox.query ? '' : 'none'
    const here = place()
    const shown = slipBoxList(here)
    const count = placeNotes(here).length
    const area = knowledgeArea()
    const byCreated = noteOrderFrom(store.settings.slipBoxNoteOrder) === 'created'
    const literature = isLiterature()
    const rows = shown.map((note) => ({
      note,
      kind: literature ? sourceKind(note) : null,
      // The area is said when the list holds more than one: all of 지식, or
      // an area's notes in the areas inside it.
      showsArea: area === null || (typeof area === 'string' && area !== '' && note.area !== area),
      date: byCreated ? note.created : note.modified,
    }))
    shownOrder = shown.map((note) => note.id)
    // Drawn again only when what it shows changed — every keystroke in the
    // open note used to clear the list and send it back to its top — and at
    // the same scroll when it is.
    const key = JSON.stringify([placeTitle(), count === 0, store.slipBox.openID, noteDateText(new Date(0)),
      rows.map((row) => [row.note.id, zettelDisplayTitle(row.note), row.kind, row.kind && row.note.paperID ? actions.paper(row.note.paperID)?.meta.displayTitle ?? null : null,
        row.showsArea ? row.note.area : null, row.kind || row.showsArea ? null : row.note.body.split('\n').find((line) => trimWhitespace(line).length > 0) ?? null,
        noteDateText(row.date)])])
    if (key === drawnList) return
    drawnList = key
    const scrolled = body.scrollTop
    clear(body)
    restoreScroll(scrolled)
    if (rows.length === 0) {
      const empty = emptyPlace(count === 0)
      body.append(el('div', { class: 'empty' }, [
        el('span', { html: icon(empty.icon) }),
        el('h2', { text: empty.title }),
        el('p', { text: empty.note }),
      ]))
      return
    }
    for (const row of rows) {
      const node = slipRow(row.note, row)
      on(node, 'click', () => {
        openNoteInSlipBox(row.note.id)
        body.focus({ preventScroll: true })
      })
      on(node, 'contextmenu', (event: MouseEvent) => {
        event.preventDefault()
        showMenuAt({ x: event.clientX, y: event.clientY }, rowMenu(row.note))
      })
      // Onto an area in the sidebar, to file it there.
      on(node, 'dragstart', (event: DragEvent) => {
        if (!event.dataTransfer) return
        writeDraggedNote(event.dataTransfer, row.note.id)
        event.dataTransfer.effectAllowed = 'move'
      })
      body.append(node)
    }
    restoreScroll(scrolled)
  }

  function restoreScroll(top: number) {
    if (body.scrollTop !== top) body.scrollTop = top
  }

  // The list takes the keyboard as the Mac's `List(selection:)` does: ↑↓
  // open the note above or below, Home and End the first and the last.
  body.setAttribute('role', 'listbox')
  body.setAttribute('tabindex', '0')
  body.setAttribute('aria-label', L('노트', 'Notes'))
  on(body, 'keydown', (event: KeyboardEvent) => {
    if (event.metaKey || event.ctrlKey || event.altKey || shownOrder.length === 0) return
    const at = store.slipBox.openID ? shownOrder.indexOf(store.slipBox.openID) : -1
    let next: number | null = null
    if (event.key === 'ArrowDown') next = at < 0 ? 0 : Math.min(shownOrder.length - 1, at + 1)
    else if (event.key === 'ArrowUp') next = at < 0 ? shownOrder.length - 1 : Math.max(0, at - 1)
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = shownOrder.length - 1
    else if (event.key === 'Enter' && at >= 0) {
      event.preventDefault()
      event.stopPropagation()
      host.current()?.focus()
      return
    }
    if (next === null) return
    event.preventDefault()
    event.stopPropagation()
    if (next !== at) openNoteInSlipBox(shownOrder[next])
    requestAnimationFrame(() => body.querySelector(`[data-note="${CSS.escape(shownOrder[next!])}"]`)?.scrollIntoView({ block: 'nearest' }))
  })

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
    // Beside a followed paper the note stands in the list's column.
    const into = store.slipBox.paperID !== null ? sideBody : detail
    if (store.slipBox.paperID !== null) sideTitle.textContent = zettelDisplayTitle(note)
    if (editor.node.parentElement !== into) {
      clear(into)
      into.append(editor.node)
    }
  }

  function update() {
    // Not the list while somebody is typing in the search: rebuilding it
    // under the field is fine, the field itself stays.
    drawHead()
    drawKinds()
    drawTags()
    drawList()
    drawDetail()
  }

  update()
  return { node, detail, side, update }
}
