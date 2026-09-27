/**
 * The list of papers on whichever shelf is showing.
 *
 * A row is the title, who wrote it and where, and three things you can act
 * on without opening anything: the pin at the head of the row, which keeps
 * the paper open, and on the right the star and the reading status, which
 * cycles. On the Open Papers shelf a kept row has an × as well, the way a
 * tab does. Every row can be dragged — to the page's edge, to put the paper
 * beside the one showing.
 */
import { iconNode } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { isCommand } from '../bridge.js'
import {
  attachmentsOf, draggedFrom, isOpenPaper, isPinned, isSelected, papersByFolder, shelfPapers, store, tagByID,
  type Paper, type PickMode,
} from '../state.js'
import { parseSubtitle, subtitleLine, type SubtitleField } from '../../shared/subtitle.js'
import type { TagColor } from '../../shared/model.js'
import { needsReview } from '../../shared/documentKind.js'
import { showMenu } from './toolbar.js'
import { basename } from './sidebar.js'
import { L } from '../../shared/lang.js'
import { carriesPapers, draggedPapers, writeDraggedPapers } from '../../shared/split.js'
import { passageKey, passageSubtitle, type TextHit } from '../textSearch.js'
import { noteSubtitle } from '../meaningSearch.js'
import { placeKey } from '../../shared/semantic/results.js'

export interface PaperListActions {
  chooseLibrary: () => void
  open: (id: string) => void
  /** A row pressed with the keys held: alone, a run (shift), one more or
   *  one fewer (Ctrl, ⌘ on a Mac) — `PaperTable.clicked`. */
  pick: (id: string, mode: PickMode) => void
  /** ⇧↑/⇧↓: the run grows or shrinks by a row. */
  extend: (by: number) => void
  /** Ctrl+A: every row on the shelf. */
  selectAll: () => void
  /** Home, End and the page keys: a row by its place. */
  stepTo: (index: number) => void
  /** The list pulled down past its top: Search Everything. */
  openSearch: () => void
  /** The reading status and the kind, as a menu off the row's status button —
   *  the Mac's: three states in a fixed order are two wrong guesses before the
   *  right one when they cycle. */
  statusMenu: (id: string, anchor: Element) => void
  toggleFavorite: (id: string) => void
  /** The supplements hanging off a paper, from its paperclip. */
  attachments: (id: string, anchor: Element) => void
  /** Papers dropped on another's row: they go under that one, as supplementary material. */
  attach: (children: string[], parent: string) => void
  /** The pin: keep the paper open, or close it. */
  togglePin: (id: string) => void
  /** The × on the Open Papers shelf. */
  close: (id: string) => void
  contextMenu: (id: string, anchor: Element) => void
  addPapers: () => void
  adoptLoose: () => void
  /** Read the folders again, after one of them would not answer. */
  refresh: () => void
  /** A passage the search found inside a paper: that paper, at that line. */
  /** `byMeaning`: the reader goes to the passage itself, not to the words typed — which it need not say. */
  openPassage: (hit: TextHit, byMeaning?: boolean) => void
  /** A passage found by meaning inside a note: that note, wherever it is shown. */
  /** A note found by a search: the slip-box, at the words found by meaning. */
  openNote: (noteID: string, words?: string) => void
  /** ↓ and ↑ in the list: the next or previous paper on the shelf. */
  step: (by: number) => void
}

const STATUS_ICON = {
  unread: 'circle',
  reading: 'circle.lefthalf.filled',
  read: 'checkmark.circle',
} as const

function statusName(status: keyof typeof STATUS_ICON): string {
  return { unread: L('안 읽음', 'Unread'), reading: L('읽는 중', 'Reading'), read: L('읽음', 'Read') }[status]
}

export function buildPaperList(actions: PaperListActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'panel paper-list' })
  const header = el('div', { class: 'panel-header' })
  // Focusable, so the arrows have somewhere to go once a row is pressed —
  // the Mac's list takes the keyboard the same way. A listbox, with the
  // rows its options.
  const body = el('div', {
    class: 'panel-body paper-list-body',
    tabindex: '-1',
    role: 'listbox',
    'aria-multiselectable': 'true',
  })
  const pullHint = el('div', { class: 'pull-hint', 'aria-hidden': 'true' })
  const pullGlyph = iconNode('text.magnifyingglass')
  if (pullGlyph) pullHint.append(pullGlyph)
  pullHint.append(el('span', { text: L('전부 찾기', 'Search Everything') }))
  const bodyHolder = el('div', { class: 'paper-list-holder' }, [body, pullHint])
  node.append(header, bodyHolder)

  /** How many rows one page of the list holds, for the page keys. */
  const rowsPerPage = () => {
    const row = body.querySelector<HTMLElement>('.paper-row')
    return Math.max(1, Math.floor(body.clientHeight / Math.max(row?.offsetHeight ?? 56, 1)) - 1)
  }
  const reveal = () => requestAnimationFrame(() => {
    const lead = (store.selectionLead && body.querySelector(`.paper-row[data-id="${store.selectionLead}"]`))
      || body.querySelector('.paper-row[aria-selected="true"]')
    lead?.scrollIntoView({ block: 'nearest' })
  })
  on(body, 'keydown', (event: KeyboardEvent) => {
    // Anywhere in the list, not only on the list itself: a row's star took
    // the keyboard when it was pressed, and the arrows went dead after it.
    const target = event.target as HTMLElement
    if (!body.contains(target) || target.closest('input, textarea, [contenteditable="true"]')) return
    const shelf = shelfPapers()
    const at = shelf.findIndex((entry) => entry.id === store.selectedID)
    const handled = (() => {
      if (isCommand(event) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === 'a') {
        actions.selectAll()
        return true
      }
      if (event.altKey || event.ctrlKey || event.metaKey) return false
      switch (event.key) {
        case 'ArrowDown':
        case 'ArrowUp': {
          const by = event.key === 'ArrowDown' ? 1 : -1
          if (event.shiftKey) actions.extend(by)
          else actions.step(by)
          return true
        }
        case 'Home': actions.stepTo(0); return true
        case 'End': actions.stepTo(shelf.length - 1); return true
        case 'PageDown': actions.stepTo((at < 0 ? 0 : at) + rowsPerPage()); return true
        case 'PageUp': actions.stepTo((at < 0 ? 0 : at) - rowsPerPage()); return true
      }
      return false
    })()
    if (!handled) return
    event.preventDefault()
    event.stopPropagation()
    reveal()
  })

  // Pulled down past its top, the list opens Search Everything — the Mac's
  // gesture. The pull uncovers the words first and going on past them is
  // what opens it, so the gesture is something you can stop doing.
  const PULL = 72
  let pull = 0
  let pullDecay = 0
  const drawPull = () => {
    const progress = Math.min(Math.max(pull / (PULL * 0.66), 0), 1)
    pullHint.style.opacity = String(progress)
    pullHint.style.transform = `translateY(${Math.max(0, pull * 0.34) + 4}px) scale(${0.92 + progress * 0.08})`
    pullHint.dataset.armed = String(pull > PULL * 0.9)
  }
  on(body, 'wheel', (event: WheelEvent) => {
    if (body.scrollTop > 0 || event.deltaY >= 0) {
      if (pull > 0 && event.deltaY > 0) {
        pull = 0
        drawPull()
      }
      return
    }
    pull += -event.deltaY * (event.deltaMode === 1 ? 16 : 1) * 0.5
    drawPull()
    clearTimeout(pullDecay)
    pullDecay = window.setTimeout(() => {
      pull = 0
      drawPull()
    }, 180)
    if (pull > PULL) {
      pull = 0
      drawPull()
      actions.openSearch()
    }
  }, { passive: true })

  /** The rows on screen, by paper, so a redraw can keep the ones it has. */
  // A row, or a folder's name over the rows that came out of it.
  let shown: { id: string; shape: string; row: BuiltRow | null; node?: HTMLElement }[] = []
  let shownHeader = ''
  /** The empty screen on show, so a redraw that would draw the same one
   *  keeps the node — and the button somebody is about to press. */
  let shownEmpty = ''

  function update() {
    const papers = shelfPapers()
    const searching = store.shelf.kind === 'search'
    // Whether the text of the papers has something to say about this search.
    const passages = searching ? store.searchPassages : []
    const hasPassages = searching && (store.searchScanning || passages.length > 0)
    // A passage the words found is above already; the same place again by
    // its meaning is not news twice (the palette's rule, `placeKey`).
    const meanings = searching
      ? store.searchMeanings.filter((hit) => !passages.some((seen) => placeKey(seen.passage) === placeKey(hit.passage)))
      : []

    // The header is the shelf's name and nothing else: what the folder has
    // to say — records late, PDFs left, files refused — stands as rows at
    // the top of the list, where it never fights the name for room.
    const title = shelfTitle()
    if (title !== shownHeader) {
      shownHeader = title
      clear(header)
      header.append(el('span', { class: 'panel-title', text: title }))
    }
    // Parsed once for the list, not once per row: the setting is a string
    // taken apart, and sixty rows took it apart sixty times.
    const fields = parseSubtitle(store.settings.listSubtitle)

    const notes = folderNotes()
    if (papers.length === 0 && !hasPassages && meanings.length === 0) {
      const key = emptyKey()
      if (shown.length === 0 && shownEmpty === key) return
      shown = []
      shownEmpty = key
      clear(body)
      body.append(emptyState(actions))
      return
    }
    shownEmpty = ''

    // Choosing a paper changes one attribute on two rows; it used to throw
    // away every row in the list and build them again, icons and all. A row
    // is rebuilt only when its shape changes — when it gains the × of a kept
    // paper, say — and otherwise it is told what to say.
    // On a kind's shelf the rows come from every folder at once, so each
    // folder's name goes over its own papers. Everywhere else the list is one
    // list and a heading would be a label on a thing with no counterpart.
    type Wanted = { head: string | null; entry: Paper | null; hit?: TextHit; note?: FolderNote; shape: string; id: string }
    const heading = (label: string): Wanted => ({ head: label, entry: null, shape: `head|${label}`, id: `head|${label}` })
    const groups = papersByFolder(papers)
    let wanted: Wanted[] = groups
      ? groups.flatMap((group) => [
        heading(group.label),
        ...group.papers.map((entry) => ({ head: null, entry, shape: rowShape(entry), id: entry.id })),
      ])
      : papers.map((entry) => ({ head: null, entry, shape: rowShape(entry), id: entry.id }))
    // The folder's own rows first, above every paper (`tableEntries`).
    wanted = [
      ...notes.map((note): Wanted => ({ head: null, entry: null, note, shape: `note|${note.key}`, id: `note|${note.kind}` })),
      ...wanted,
    ]
    if (hasPassages) {
      // The search found words inside the papers too: the titles first — a
      // title match is the surer thing — then the papers that say it inside.
      if (papers.length > 0) wanted = [heading(L('제목에서', 'In the Titles')), ...wanted]
      wanted.push(heading(L('논문 안에서', 'In the Papers')))
      for (const hit of passages) {
        const key = passageKey(hit)
        wanted.push({ head: null, entry: null, hit, shape: `passage|${key}`, id: `passage|${key}` })
      }
      if (store.searchScanning) {
        const scanning: FolderNote = { kind: 'scanning', key: 'scanning' }
        wanted.push({ head: null, entry: null, note: scanning, shape: 'note|scanning', id: 'note|scanning' })
      }
    }
    if (meanings.length > 0) {
      wanted.push(heading(L('뜻이 비슷한 구절', 'Similar in Meaning')))
      for (const hit of meanings) {
        const key = passageKey(hit)
        wanted.push({ head: null, entry: null, hit, shape: `meaning|${key}`, id: `meaning|${key}` })
      }
    }
    const sameShape = wanted.length === shown.length
      && wanted.every(({ id, shape }, at) => shown[at].id === id && shown[at].shape === shape)
    if (!sameShape) {
      const kept = new Map(shown.map((row) => [`${row.id}|${row.shape}`, row.row]))
      const keptNodes = new Map(shown.filter((row) => row.node).map((row) => [row.id, row.node!]))
      clear(body)
      shown = wanted.map(({ head, entry, hit, note, shape, id }) => {
        if (hit) {
          // Built once each: a passage says the same thing for as long as it
          // is on the list, and the list is rebuilt as each batch arrives.
          const node = keptNodes.get(id) ?? passageRow(hit, actions, id.startsWith('meaning|'))
          body.append(node)
          return { id, shape, row: null, node }
        }
        if (note) {
          const node = noteRow(note, actions)
          body.append(node)
          return { id, shape, row: null }
        }
        if (head !== null || entry === null) {
          body.append(el('div', { class: 'list-group', text: head ?? '' }))
          return { id, shape, row: null }
        }
        const row = kept.get(`${id}|${shape}`) ?? paperRow(entry, actions)
        row.apply(entry, fields)
        body.append(row.node)
        return { id, shape, row }
      })
      return
    }
    for (const [at, { entry }] of wanted.entries()) if (entry) shown[at].row?.apply(entry, fields)
  }

  update()
  return { node, update }
}

/**
 * What about a row cannot be changed in place — whether it has a × on it, or
 * a note saying the file is gone. Everything else is text and an attribute.
 */
function rowShape(entry: Paper): string {
  // The × on the Open shelf is for every paper kept open — pinned or kept by
  // use — as on the Mac: one kept by clicking into it had no way off the
  // shelf but the menu.
  const closable = store.shelf.kind === 'open' && isOpenPaper(entry.id)
  return `${entry.exists ? 1 : 0}|${closable ? 'close' : ''}`
}

/** A row, and the way to tell it what it now says. */
interface BuiltRow {
  node: HTMLElement
  apply: (entry: Paper, fields: SubtitleField[]) => void
}

/** A tag's colour, as the Mac's semantic palette has it (`Tag.Color.swiftUIColor`)
 *  — a token, so it is the dark palette's in the dark. */
export function tagColor(color: TagColor | string): string {
  const known = ['red', 'orange', 'yellow', 'green', 'mint', 'teal', 'blue', 'indigo', 'purple', 'pink', 'gray']
  return `var(--tag-${known.includes(color) ? color : 'gray'})`
}

/** Which way a press picks: shift a run, the command key one more or fewer. */
function modeOf(event: MouseEvent): PickMode {
  if (event.shiftKey) return 'extend'
  if (isCommand(event)) return 'toggle'
  return 'only'
}

/** A control inside a row: pressed, it does its one thing, and the keyboard
 *  stays with the list rather than with it — Tab does not walk five buttons
 *  a row, and ↓ still moves after a star is pressed. */
function rowControl(className: string, press: (event: MouseEvent) => void): HTMLButtonElement {
  const button = el('button', { class: className, tabindex: '-1' }) as HTMLButtonElement
  on(button, 'mousedown', (event: MouseEvent) => {
    event.preventDefault()
    ;(button.closest('.paper-list-body') as HTMLElement | null)?.focus({ preventScroll: true })
  })
  on(button, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    press(event)
  })
  return button
}

function paperRow(entry: Paper, actions: PaperListActions): BuiltRow {
  const id = entry.id
  const row = el('div', { class: 'paper-row', role: 'option', draggable: 'true', id: `paper-row-${id}` })
  row.dataset.id = id

  // Pinned, or not. A pin is something you do: the app keeps a paper on the
  // Open Papers shelf when you use it, and that belongs on the shelf, not
  // here — reading a paper should not appear to pin it.
  const pin = rowControl('paper-pin', () => actions.togglePin(id))
  const status = rowControl('paper-status', () => actions.statusMenu(id, status))
  status.setAttribute('aria-haspopup', 'menu')

  const title = el('div', { class: 'paper-title' })
  const subtitle = el('div', { class: 'paper-subtitle' })
  // The tags it wears, in their colours, as the Mac's row has them.
  const tagRow = el('div', { class: 'paper-tags' })
  const main = el('div', { class: 'paper-main' }, [title, subtitle, tagRow])
  if (!entry.exists) {
    // Not on the Mac's row, which finds a missing file only on opening it.
    // Kept here on purpose: a row that cannot open should say so.
    main.append(el('div', {
      class: 'paper-subtitle',
      style: 'color: var(--danger)',
      text: L('폴더에 PDF가 없어요', 'Missing from the folder'),
    }))
  }

  const star = rowControl('paper-star', () => actions.toggleFavorite(id))

  // The paperclip and how many: a supplement is kept off every shelf, so
  // this is the way to it — a badge alone would say it exists and give no
  // way to reach it.
  const clip = rowControl('paper-clip', () => actions.attachments(id, clip))
  clip.setAttribute('aria-haspopup', 'menu')
  const clipGlyph = iconNode('paperclip')
  const clipCount = el('span')
  if (clipGlyph) clip.append(clipGlyph)
  clip.append(clipCount)

  // What the record needs: the one cue on «All» that says which rows belong
  // on the «Needs Review» shelf.
  const flag = el('span', { class: 'paper-flag' })

  row.append(pin, main, clip, star, status)
  if (rowShape(entry).endsWith('close')) {
    // Kept open: closed here, the way a tab is.
    const close = rowControl('paper-close', () => actions.close(id))
    close.title = L('닫기', 'Close')
    close.setAttribute('aria-label', L('닫기', 'Close'))
    const cross = iconNode('xmark')
    if (cross) close.append(cross)
    row.append(close)
  }
  row.append(flag)
  on(row, 'click', (event: MouseEvent) => {
    // The list takes the keyboard, so ↓ and ↑ walk it from here.
    ;(row.closest('.paper-list-body') as HTMLElement | null)?.focus({ preventScroll: true })
    actions.pick(id, modeOf(event))
  })
  on(row, 'contextmenu', (event: MouseEvent) => {
    event.preventDefault()
    // The row under the pointer is the one the menu is about — and the one
    // the inspector shows while it is up. A row already among the chosen
    // keeps the choice.
    if (!isSelected(id)) actions.pick(id, 'only')
    actions.contextMenu(id, row)
  })
  on(row, 'dragstart', (event: DragEvent) => {
    if (!event.dataTransfer) return
    const ids = draggedFrom(id)
    writeDraggedPapers(event.dataTransfer, ids)
    event.dataTransfer.setData('text/plain', ids.length === 1 ? (title.textContent ?? '') : ids
      .map((one) => store.papers.find((paper) => paper.id === one)?.meta.displayTitle ?? '').join('\n'))
    event.dataTransfer.effectAllowed = 'copyMove'
  })
  // Dropping papers on another makes them that one's supplements, as on the
  // Mac — from this list, the open-papers popup or a pane's title alike. The
  // drag cannot be read before the drop, so a paper dropped on itself is
  // turned away there.
  let over = 0
  on(row, 'dragenter', (event: DragEvent) => {
    if (!carriesPapers(event.dataTransfer)) return
    over += 1
    row.classList.add('drop-target')
  })
  on(row, 'dragover', (event: DragEvent) => {
    if (!carriesPapers(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    // One of the drag's own `copyMove`: anything else and the drop is refused.
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    row.classList.add('drop-target')
  })
  on(row, 'dragleave', () => {
    over = Math.max(0, over - 1)
    if (over === 0) row.classList.remove('drop-target')
  })
  on(row, 'drop', (event: DragEvent) => {
    over = 0
    row.classList.remove('drop-target')
    if (!carriesPapers(event.dataTransfer)) return
    event.preventDefault()
    event.stopPropagation()
    const children = draggedPapers(event.dataTransfer).filter((one) => one !== id)
    if (children.length > 0) actions.attach(children, id)
  })

  /** The parts of a row that change without the row changing shape. */
  let drawnPin: string | null = null
  let drawnStar: string | null = null
  let drawnStatus: string | null = null
  let drawnFlag: false | 'review' | 'resolving' | null = null

  function swap(holder: HTMLElement, name: string, drawn: string | null): string {
    if (drawn === name) return name
    holder.replaceChildren()
    const glyph = iconNode(name as Parameters<typeof iconNode>[0])
    if (glyph) holder.append(glyph)
    return name
  }

  function apply(now: Paper, fields: SubtitleField[]) {
    const selected = String(isSelected(now.id))
    if (row.getAttribute('aria-selected') !== selected) row.setAttribute('aria-selected', selected)

    const kept = isPinned(now.id)
    drawnPin = swap(pin, kept ? 'pin.fill' : 'pin', drawnPin)
    pin.dataset.on = String(kept)
    pin.title = kept ? L('고정한 논문 — 누르면 닫아요', 'Pinned — click to close') : L('고정하기', 'Pin')
    pin.setAttribute('aria-label', kept ? L('열어 둔 논문', 'Kept open') : L('열어 두지 않음', 'Not kept open'))

    drawnStar = swap(star, now.state.isFavorite ? 'star.fill' : 'star', drawnStar)
    star.dataset.on = String(now.state.isFavorite)
    star.title = now.state.isFavorite
      ? L('즐겨찾기에서 빼기', 'Remove from Favorites')
      : L('즐겨찾기에 더하기', 'Add to Favorites')
    star.setAttribute('aria-label', now.state.isFavorite ? L('즐겨찾기', 'Favorite') : L('즐겨찾기 아님', 'Not a favorite'))

    drawnStatus = swap(status, STATUS_ICON[now.state.readingStatus], drawnStatus)
    status.dataset.on = String(now.state.readingStatus === 'read')
    const statusSaid = L(`읽기 상태: ${statusName(now.state.readingStatus)}`, `Reading status: ${statusName(now.state.readingStatus)}`)
    status.title = statusSaid
    status.setAttribute('aria-label', statusSaid)

    if (title.textContent !== now.meta.displayTitle) title.textContent = now.meta.displayTitle
    // The fields the reader chose (Settings → Under the Title), in their order.
    const said = subtitleLine(now.meta, fields)
    if (subtitle.textContent !== said) subtitle.textContent = said
    subtitle.style.display = said ? '' : 'none'

    const tags = now.meta.tagIDs
      .map((tagID) => tagByID(tagID))
      .filter((tag): tag is NonNullable<typeof tag> => Boolean(tag))
    const tagKey = tags.map((tag) => `${tag.id}:${tag.name}:${tag.color}`).join('|')
    if (tagRow.dataset.key !== tagKey) {
      tagRow.dataset.key = tagKey
      tagRow.replaceChildren(...tags.map((tag) => el('span', {
        class: 'paper-tag',
        text: tag.name,
        style: `--tag: ${tagColor(tag.color)}`,
      })))
      tagRow.style.display = tags.length > 0 ? '' : 'none'
    }

    const supplements = attachmentsOf(now.id).length
    clip.style.display = supplements > 0 ? '' : 'none'
    clipCount.textContent = supplements > 0 ? String(supplements) : ''
    clip.title = L('보충 자료', 'Supplementary material')
    clip.setAttribute('aria-label', L(`보충 자료 ${supplements}개`, `${supplements} supplementary file${supplements === 1 ? '' : 's'}`))

    // While the paper is being looked up the triangle's place turns: the
    // record may be about to answer the question the triangle asks.
    const resolving = store.resolving.has(now.id)
    const wants: false | 'review' | 'resolving' = resolving ? 'resolving' : needsReview(now.meta) ? 'review' : false
    if (wants !== drawnFlag) {
      drawnFlag = wants
      flag.replaceChildren()
      if (wants === 'resolving') {
        flag.append(el('span', { class: 'spinner' }))
        const said = L('서지를 찾는 중', 'Resolving metadata')
        flag.removeAttribute('title')
        flag.setAttribute('aria-label', said)
        flag.setAttribute('role', 'img')
      } else if (wants) {
        const glyph = iconNode('exclamationmark.triangle.fill')
        if (glyph) flag.append(glyph)
        const said = L('서지를 한번 봐주세요', 'Check this record')
        flag.title = said
        flag.setAttribute('aria-label', said)
        flag.setAttribute('role', 'img')
      } else {
        flag.removeAttribute('title')
        flag.removeAttribute('aria-label')
        flag.removeAttribute('role')
      }
      flag.style.display = wants ? '' : 'none'
    }
  }

  return { node: row, apply }
}

/** A row that speaks for the folder, not for a paper (`Entry.note`). */
interface FolderNote {
  kind: 'failures' | 'adopting' | 'loose' | 'refused' | 'scanning'
  /** What it says, so a change of count or of names redraws it. */
  key: string
}

/** The folder's rows, in the Mac's order: records late, then the PDFs being
 *  added or left to add, then the ones that could not be. */
function folderNotes(): FolderNote[] {
  const notes: FolderNote[] = []
  if (store.unreadable.length > 0) notes.push({ kind: 'failures', key: `failures|${store.unreadable.join('\u0000')}` })
  if (store.adopting !== null) notes.push({ kind: 'adopting', key: `adopting|${store.adopting}` })
  else if (store.looseCount > 0 && store.unreadable.length === 0) notes.push({ kind: 'loose', key: `loose|${store.looseCount}` })
  if (store.refused.length > 0) notes.push({ kind: 'refused', key: `refused|${store.refused.join('\u0000')}` })
  return notes
}

/** Why records are missing, and which — the tooltip over the row. */
function unreadableDescription(): string {
  const count = store.unreadable.length
  return [
    L(
      `논문 ${count}편의 기록이 아직 안 왔어요. 논문은 폴더에 그대로 있어요. 클라우드 폴더라면 파일이 아직 내려오는 중일 수 있어요.`,
      `${count} of this library's records haven't arrived. Your papers are still in the folder. On a cloud drive, a record may still be on its way down.`,
    ),
    ...store.unreadable,
  ].join('\n')
}

/** Which files the last adoption could not take, by name — eight, and how
 *  many more, rather than eight and silence. */
function refusedDescription(): string {
  const rest = store.refused.length - Math.min(8, store.refused.length)
  return L('파일을 읽을 수 없었어요. 클라우드 폴더라면 아직 내려오는 중일 수 있어요.\n\n',
    "These files couldn't be read. On a cloud drive, they may still be on their way down.\n\n")
    + store.refused.slice(0, 8).join('\n')
    + (rest > 0 ? L(`\n…그리고 ${rest}개 더`, `\n…and ${rest} more`) : '')
}

function noteRow(note: FolderNote, actions: PaperListActions): HTMLElement {
  const glyph = (name: Parameters<typeof iconNode>[0]) => {
    const drawn = iconNode(name)
    return drawn ? [drawn] : []
  }
  switch (note.kind) {
    case 'failures': {
      const count = store.unreadable.length
      const row = el('button', { class: 'list-note' }, [
        ...glyph('icloud.slash'),
        el('span', {
          text: L(`기록 ${count}개가 아직 안 왔어요`, `${count} record${count === 1 ? '' : 's'} ${count === 1 ? "hasn't" : "haven't"} arrived`),
        }),
      ])
      row.title = unreadableDescription()
      on(row, 'click', actions.refresh)
      return row
    }
    case 'adopting':
      // Two hundred files is a wait, and a button that looks the same all
      // the way through it is a button people press again.
      return el('div', { class: 'list-note quiet' }, [
        el('span', { class: 'spinner' }),
        el('span', { text: L(`PDF ${store.adopting ?? 0}개 더하는 중…`, `Adding ${store.adopting ?? 0} PDFs…`) }),
      ])
    case 'loose': {
      const count = store.looseCount
      const row = el('button', { class: 'list-note' }, [
        ...glyph('tray.and.arrow.down'),
        el('span', { text: L(`이 폴더에 남은 PDF ${count}개 더하기`, `Add ${count} more PDF${count === 1 ? '' : 's'} from this folder`) }),
      ])
      on(row, 'click', actions.adoptLoose)
      return row
    }
    case 'refused': {
      const count = store.refused.length
      const row = el('div', { class: 'list-note quiet' }, [
        ...glyph('exclamationmark.triangle'),
        el('span', { text: L(`PDF ${count}개는 더하지 못했어요`, `${count} PDF${count === 1 ? '' : 's'} couldn't be added`) }),
      ])
      row.title = refusedDescription()
      return row
    }
    case 'scanning':
      return el('div', { class: 'list-note' }, [
        el('span', { class: 'spinner' }),
        el('span', { text: L('논문 본문을 읽는 중…', 'Reading the papers…') }),
      ])
  }
}

/**
 * One paper whose *text* holds the query: the sentence it is in, and where.
 * Pressing it opens the paper at that line rather than at the page it was
 * left on.
 */
function passageRow(hit: TextHit, actions: PaperListActions, byMeaning = false): HTMLElement {
  const note = hit.note
  const icon = iconNode(note ? 'note' : 'text.magnifyingglass')
  const row = el('div', { class: 'passage-row', role: 'button', tabindex: '-1' }, [
    el('span', { class: 'passage-icon' }, icon ? [icon] : []),
    el('div', { class: 'paper-main' }, [
      el('div', { class: 'passage-snippet', text: hit.snippet }),
      el('div', { class: 'paper-subtitle', text: note ? noteSubtitle(hit) : passageSubtitle(hit) }),
    ]),
  ])
  on(row, 'click', () => (note ? actions.openNote(note.id, byMeaning ? hit.snippet : undefined) : actions.openPassage(hit, byMeaning)))
  return row
}

function shelfTitle(): string {
  switch (store.shelf.kind) {
    case 'search': return L('찾은 것', 'Search Results')
    case 'all': return L('모두', 'All')
    case 'kind':
      return ({
        paper: L('논문', 'Papers'),
        book: L('책', 'Books'),
        lecture: L('강의자료', 'Course Material'),
        document: L('문서', 'Documents'),
      } as Record<string, string>)[(store.shelf as { of: string }).of] ?? L('모두', 'All')
    case 'folder':
      return basename((store.shelf as { root: string }).root)
    case 'open': return L('열린 문서', 'Open Documents')
    case 'status': return statusName(store.shelf.status)
    case 'favorites': return L('즐겨찾기', 'Favorites')
    case 'review': return L('살펴볼 것', 'Needs Review')
    case 'notes': return L('노트', 'Notes')
    case 'collection':
      return store.collections.find((c) => c.id === (store.shelf as { id: string }).id)?.name ?? L('컬렉션', 'Collection')
    case 'tag':
      return store.tags.find((t) => t.id === (store.shelf as { id: string }).id)?.name ?? L('태그', 'Tag')
    case 'author': return (store.shelf as { name: string }).name
  }
}

/** Which empty screen is showing, so it is not built again for nothing. */
function emptyKey(): string {
  return [
    store.error ?? '', store.root ?? '', store.papers.length, store.unreadable.length, store.looseCount,
    store.adopting ?? '', store.shelf.kind, shelfTitle(), store.searchQuery,
  ].join('|')
}

/** What an empty shelf says. Each is empty for its own reason, and the
 *  reason tells you whether anything is wrong — nothing is, in every case
 *  here (the Mac's `emptyShelf`). */
function emptyShelf(): { title: string; icon: Parameters<typeof iconNode>[0]; note: string } {
  const shelf = store.shelf
  switch (shelf.kind) {
    case 'status':
      if (shelf.status === 'unread') {
        return { title: L('안 읽은 논문이 없어요', 'Nothing Unread'), icon: 'circle', note: L('여기 있는 논문은 모두 열어봤어요.', 'Every paper here has been opened.') }
      }
      if (shelf.status === 'reading') {
        return { title: L('읽는 중인 논문이 없어요', 'Nothing Being Read'), icon: 'circle.lefthalf.filled', note: L('논문을 읽는 중으로 바꿔두면 여기서 기다려요.', 'Mark a paper as Reading and it waits here.') }
      }
      return { title: L('읽은 논문이 아직 없어요', 'Nothing Read Yet'), icon: 'checkmark.circle', note: L('읽음으로 바꾼 논문이 여기 모여요.', 'Papers marked as Read collect here.') }
    case 'favorites':
      return { title: L('즐겨찾기가 아직 없어요', 'No Favorites'), icon: 'star', note: L('논문에 별을 달아두면 언제든 여기서 찾을 수 있어요.', 'Star a paper and it stays here.') }
    case 'review':
      return { title: L('살펴볼 것이 없어요', 'Nothing to Review'), icon: 'exclamationmark.triangle', note: L('서지를 한번 봐야 할 논문이 없어요.', 'Every record looks right.') }
    case 'collection':
      return { title: L('이 컬렉션은 비어 있어요', 'This Collection Is Empty'), icon: 'folder', note: L('옆 목록의 컬렉션 위로 논문을 끌어다 놓아보세요.', 'Drag papers onto it in the sidebar.') }
    case 'tag':
      return { title: L('이 태그를 단 논문이 없어요', 'Nothing With This Tag'), icon: 'tag', note: L('논문에 이 태그를 달면 여기 나와요.', 'Tag a paper and it appears here.') }
    case 'author':
      return { title: L('이 저자의 논문이 없어요', 'Nothing by This Author'), icon: 'person', note: L('이 이름이 실린 논문이 라이브러리에 없어요.', 'No paper here carries this name.') }
    case 'open':
      // Not the Mac's catch-all: the Open shelf is empty for a reason that
      // can be said, and saying it teaches the shelf.
      return { title: L('열린 문서가 없어요', 'Nothing Is Open'), icon: 'rectangle.on.rectangle', note: L('논문을 클릭해 들어가거나 핀을 누르면 여기에 남아요.', 'Click into a paper, or pin it, and it stays here.') }
    default:
      return { title: L('아직 아무것도 없어요', 'Nothing Here'), icon: 'tray', note: L('이 선반은 비어 있어요.', 'This shelf is empty.') }
  }
}

function emptyState(actions: PaperListActions): HTMLElement {
  const wrap = el('div', { class: 'empty' })
  const say = (icon: Parameters<typeof iconNode>[0] | null, title: string, note: string | null, ...rest: HTMLElement[]) => {
    const glyph = icon ? iconNode(icon) : null
    if (glyph) wrap.append(el('span', { class: 'empty-icon' }, [glyph]))
    wrap.append(el('h2', { text: title }))
    if (note) wrap.append(el('p', { text: note }))
    wrap.append(...rest)
    return wrap
  }
  const button = (text: string, press: () => void) => {
    const made = el('button', { class: 'filled-button', text })
    on(made, 'click', press)
    return made
  }
  // A folder that would not be read comes first, because every sentence under
  // it would be untrue: the library is not empty and no folder needs choosing.
  if (store.error) {
    return say('icloud.slash', L('라이브러리를 읽지 못했어요', "Couldn't Read the Library"),
      L('논문은 폴더에 그대로 있어요. 클라우드 폴더라면 파일이 아직 내려오는 중일 수 있어요.',
        'Your papers are still in the folder. On a cloud drive, a file may still be on its way down.'),
      el('p', { class: 'fine words', text: store.error }),
      button(L('다시 읽기', 'Try Again'), actions.refresh))
  }
  if (!store.root) {
    return say('folder', L('아직 라이브러리 폴더가 없어요', 'No Library Folder Yet'),
      L('논문이 들어 있는 폴더를 골라주세요. 클라우드 폴더도 돼요. 그러면 라이브러리가 기기를 따라다녀요 — 맥에서 표시한 것이 PC에서도 그대로 보여요.',
        'Choose the folder your papers live in. Pick a cloud folder and the library '
          + 'travels with you — the same papers, the same marks, on a Mac and on a PC.'),
      button(L('라이브러리 폴더 고르기…', 'Choose Library Folder…'), actions.chooseLibrary))
  }
  if (store.papers.length === 0) {
    // Records that have not arrived come before an empty library: the papers
    // are in the folder, and «nothing here» would tell someone whose cloud
    // drive is still syncing that their library is empty.
    if (store.unreadable.length > 0) {
      return say('icloud.slash', L('기록이 아직 안 왔어요', "Some Records Didn't Arrive"), unreadableDescription().split('\n')[0],
        button(L('다시 읽기', 'Try Again'), actions.refresh))
    }
    if (store.adopting !== null) {
      return say(null, L(`PDF ${store.adopting}개 더하는 중…`, `Adding ${store.adopting} PDFs…`), null, el('span', { class: 'spinner' }))
    }
    // Pointing the app at a folder that already holds PDFs is the obvious
    // thing to do; landing on an empty library after doing it is not.
    if (store.looseCount > 0) {
      const count = store.looseCount
      return say('tray.and.arrow.down', L('이 폴더에서 찾은 논문', 'Papers Found in This Folder'),
        L(`이 폴더에 PDF가 벌써 ${count}개 있어요. 더하면 하나씩 서지를 찾아 기록을 만들어요. PDF는 있던 자리에 그대로 있어요 — 옮기지도, 이름을 바꾸지도, 복사하지도 않아요.`,
          `This folder already holds ${count} ${count === 1 ? 'PDF' : 'PDFs'}. Adding them looks up each one and gives it a record. Paper Time never moves, renames or copies a file.`),
        button(L(`PDF ${count}개 더하기`, `Add ${count} PDF${count === 1 ? '' : 's'}`), actions.adoptLoose))
    }
    return say('doc', L('아직 논문이 없어요', 'No Papers Yet'),
      L('PDF를 여기 끌어다 놓아보세요. 도구 막대의 PDF 더하기로 골라도 돼요.', 'Drag in a PDF, or choose Add PDFs.'),
      button(L('PDF 더하기', 'Add PDFs'), actions.addPapers))
  }
  if (store.shelf.kind === 'search') {
    // Not "this shelf is empty": a search that found nothing is a search,
    // and what helps is a different word.
    return say('magnifyingglass', L(`“${store.searchQuery}”에 맞는 논문이 없어요`, `No Results for “${store.searchQuery}”`),
      L('다른 말로 찾아보세요.', 'Check the spelling or try a new search.'))
  }
  const shelf = emptyShelf()
  return say(shelf.icon, shelf.title, shelf.note)
}

export { showMenu }
