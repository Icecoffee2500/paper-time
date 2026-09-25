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
import { isPinned, papersByFolder, shelfPapers, store, type Paper } from '../state.js'
import { showMenu } from './toolbar.js'
import { basename } from './sidebar.js'
import { L } from '../../shared/lang.js'
import { PAPER_DRAG_TYPE } from '../../shared/split.js'
import { passageKey, passageSubtitle, type TextHit } from '../textSearch.js'
import { noteSubtitle } from '../meaningSearch.js'
import { placeKey } from '../../shared/semantic/results.js'

export interface PaperListActions {
  chooseLibrary: () => void
  open: (id: string) => void
  cycleStatus: (id: string) => void
  toggleFavorite: (id: string) => void
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
  /** A passage found by meaning inside a paper's note: that paper, with the note in front. */
  openNote: (paperID: string) => void
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
  const node = el('div', { class: 'panel' })
  const header = el('div', { class: 'panel-header' })
  const body = el('div', { class: 'panel-body' })
  node.append(header, body)

  /** The rows on screen, by paper, so a redraw can keep the ones it has. */
  // A row, or a folder's name over the rows that came out of it.
  let shown: { id: string; shape: string; row: BuiltRow | null; node?: HTMLElement }[] = []
  let shownHeader = ''

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

    // The header only when it has changed: clearing and refilling it on every
    // redraw threw away a button somebody might have been about to press.
    // The refused files by name, not by count: after a press, the number left
    // loose and the number refused are the same number, so two presses that
    // failed on different files had the same key — and the note's tooltip,
    // which is only written when the key changes, went on naming the files
    // from the press before.
    const headerKey = `${shelfTitle()}|${store.looseCount}|${store.refused.join('\u0000')}`
      + `|${store.unreadable.length}|${store.error ?? ''}`
    if (headerKey !== shownHeader) {
      shownHeader = headerKey
      clear(header)
      header.append(el('span', { text: shelfTitle() }))
      header.append(el('span', { class: 'toolbar-spacer' }))
      // The folder answered in part, or would not answer at all. Either way
      // the list is short by papers that are still in the folder, and a short
      // list that says nothing is the whole of what went wrong here. It comes
      // before the loose-PDF button because that button is the one thing a
      // half-read folder is not allowed to offer.
      const short = missingNote()
      if (short) {
        const note = el('span', { class: 'panel-note', text: short })
        note.title = [
          L('클라우드 폴더라면 파일이 아직 내려오는 중일 수 있어요. 논문은 폴더에 그대로 있어요.',
            'On a cloud drive, a record may still be on its way down. Your papers are still in the folder.'),
          ...store.unreadable,
        ].join('\n')
        const again = el('button', { class: 'plain-button', text: L('다시 읽기', 'Try Again') })
        on(again, 'click', actions.refresh)
        header.append(note, again)
      }
      if (store.looseCount > 0) {
        const adopt = el('button', {
          class: 'plain-button',
          text: L(
            `PDF ${store.looseCount}개 더하기`,
            `Add ${store.looseCount} loose PDF${store.looseCount === 1 ? '' : 's'}`,
          ),
        })
        on(adopt, 'click', actions.adoptLoose)
        header.append(adopt)
      }
      // The half of the answer that was missing. These files were left without
      // a record, so the count above did not move — and a button that answers
      // with the same number and nothing else is a button people press again.
      if (store.refused.length > 0) {
        const count = store.refused.length
        const note = el('span', {
          class: 'panel-note',
          text: L(
            `PDF ${count}개는 더하지 못했어요`,
            `${count} PDF${count === 1 ? '' : 's'} couldn't be added`,
          ),
        })
        note.title = [
          L('파일을 읽을 수 없었어요. 클라우드 폴더라면 아직 내려오는 중일 수 있어요.',
            "These files couldn't be read. On a cloud drive, they may still be on their way down."),
          ...store.refused.slice(0, 8),
        ].join('\n')
        header.append(note)
      }
    }

    if (papers.length === 0 && !hasPassages && meanings.length === 0) {
      shown = []
      clear(body)
      body.append(emptyState(actions))
      return
    }

    // Choosing a paper changes one attribute on two rows; it used to throw
    // away every row in the list and build them again, icons and all. A row
    // is rebuilt only when its shape changes — when it gains the × of a kept
    // paper, say — and otherwise it is told what to say.
    // On a kind's shelf the rows come from every folder at once, so each
    // folder's name goes over its own papers. Everywhere else the list is one
    // list and a heading would be a label on a thing with no counterpart.
    type Wanted = { head: string | null; entry: Paper | null; hit?: TextHit; note?: string; shape: string; id: string }
    const heading = (label: string): Wanted => ({ head: label, entry: null, shape: `head|${label}`, id: `head|${label}` })
    const groups = papersByFolder(papers)
    let wanted: Wanted[] = groups
      ? groups.flatMap((group) => [
        heading(group.label),
        ...group.papers.map((entry) => ({ head: null, entry, shape: rowShape(entry), id: entry.id })),
      ])
      : papers.map((entry) => ({ head: null, entry, shape: rowShape(entry), id: entry.id }))
    if (hasPassages) {
      // The search found words inside the papers too: the titles first — a
      // title match is the surer thing — then the papers that say it inside.
      if (papers.length > 0) wanted = [heading(L('제목에서', 'In the Titles')), ...wanted]
      wanted.push(heading(L('논문 안에서', 'In the Papers')))
      for (const hit of passages) {
        const key = passageKey(hit)
        wanted.push({ head: null, entry: null, hit, shape: `passage|${key}`, id: `passage|${key}` })
      }
      if (store.searchScanning) wanted.push({ head: null, entry: null, note: 'scanning', shape: 'note|scanning', id: 'note|scanning' })
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
          const node = el('div', { class: 'list-note' }, [
            el('span', { class: 'spinner' }),
            el('span', { text: L('논문 본문을 읽는 중…', 'Reading the papers…') }),
          ])
          body.append(node)
          return { id, shape, row: null }
        }
        if (head !== null || entry === null) {
          body.append(el('div', { class: 'list-group', text: head ?? '' }))
          return { id, shape, row: null }
        }
        const row = kept.get(`${id}|${shape}`) ?? paperRow(entry, actions)
        row.apply(entry)
        body.append(row.node)
        return { id, shape, row }
      })
      return
    }
    for (const [at, { entry }] of wanted.entries()) if (entry) shown[at].row?.apply(entry)
  }

  update()
  return { node, update }
}

/**
 * What about a row cannot be changed in place — whether it has a × on it, or
 * a note saying the file is gone. Everything else is text and an attribute.
 */
function rowShape(entry: Paper): string {
  const onShelf = store.shelf.kind === 'open'
  return `${entry.exists ? 1 : 0}|${onShelf ? (isPinned(entry.id) ? 'close' : 'preview') : ''}`
}

/** A row, and the way to tell it what it now says. */
interface BuiltRow {
  node: HTMLElement
  apply: (entry: Paper) => void
}

function paperRow(entry: Paper, actions: PaperListActions): BuiltRow {
  const id = entry.id
  const row = el('div', { class: 'paper-row', role: 'option', draggable: 'true' })

  // Pinned, or not. A pin is something you do: the app keeps a paper on the
  // Open Papers shelf when you use it, and that belongs on the shelf, not
  // here — reading a paper should not appear to pin it.
  const pin = el('button', { class: 'paper-pin' })
  on(pin, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.togglePin(id)
  })

  const status = el('button', { class: 'paper-status' })
  on(status, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.cycleStatus(id)
  })

  const title = el('div', { class: 'paper-title' })
  const subtitle = el('div', { class: 'paper-subtitle' })
  const main = el('div', { class: 'paper-main' }, [title, subtitle])
  if (!entry.exists) {
    main.append(el('div', {
      class: 'paper-subtitle',
      style: 'color: var(--danger)',
      text: L('폴더에 PDF가 없어요', 'Missing from the folder'),
    }))
  }
  if (store.shelf.kind === 'open' && !isPinned(id)) {
    main.append(el('div', { class: 'paper-subtitle paper-preview', text: L('미리보기', 'Preview') }))
  }

  const star = el('button', { class: 'paper-star' })
  on(star, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.toggleFavorite(id)
  })

  row.append(pin, main, star, status)
  if (store.shelf.kind === 'open' && isPinned(id)) {
    // Kept open: closed here, the way a tab is.
    const close = el('button', {
      class: 'paper-close',
      title: L('닫기', 'Close'),
      'aria-label': L('닫기', 'Close'),
    })
    const cross = iconNode('xmark')
    if (cross) close.append(cross)
    on(close, 'click', (event: MouseEvent) => {
      event.stopPropagation()
      actions.close(id)
    })
    row.append(close)
  }
  on(row, 'click', () => actions.open(id))
  on(row, 'contextmenu', (event: MouseEvent) => {
    event.preventDefault()
    actions.contextMenu(id, row)
  })
  on(row, 'dragstart', (event: DragEvent) => {
    if (!event.dataTransfer) return
    event.dataTransfer.setData(PAPER_DRAG_TYPE, id)
    event.dataTransfer.setData('text/plain', title.textContent ?? '')
    event.dataTransfer.effectAllowed = 'copyMove'
  })

  /** The parts of a row that change without the row changing shape. */
  let drawnPin: string | null = null
  let drawnStar: string | null = null
  let drawnStatus: string | null = null

  function swap(holder: HTMLElement, name: string, drawn: string | null): string {
    if (drawn === name) return name
    holder.replaceChildren()
    const glyph = iconNode(name as Parameters<typeof iconNode>[0])
    if (glyph) holder.append(glyph)
    return name
  }

  function apply(now: Paper) {
    const selected = String(store.selectedID === now.id)
    if (row.getAttribute('aria-selected') !== selected) row.setAttribute('aria-selected', selected)

    const kept = isPinned(now.id)
    drawnPin = swap(pin, kept ? 'pin.fill' : 'pin', drawnPin)
    pin.dataset.on = String(kept)
    pin.title = kept ? L('고정한 논문 — 누르면 닫아요', 'Pinned — click to close') : L('고정하기', 'Pin')
    pin.setAttribute('aria-label', kept ? L('고정함', 'Pinned') : L('고정하지 않음', 'Not pinned'))

    drawnStar = swap(star, now.state.isFavorite ? 'star.fill' : 'star', drawnStar)
    star.dataset.on = String(now.state.isFavorite)
    star.title = now.state.isFavorite
      ? L('즐겨찾기에서 빼기', 'Remove from favourites')
      : L('즐겨찾기에 더하기', 'Add to favourites')

    drawnStatus = swap(status, STATUS_ICON[now.state.readingStatus], drawnStatus)
    status.title = L(
      `읽기 상태: ${statusName(now.state.readingStatus)}`,
      `Reading status: ${now.state.readingStatus}`,
    )

    if (title.textContent !== now.meta.displayTitle) title.textContent = now.meta.displayTitle
    const said = [
      now.meta.displayAuthors,
      now.meta.year ? String(now.meta.year) : '',
      now.meta.venue ?? '',
    ].filter(Boolean).join(' · ')
    if (subtitle.textContent !== said) subtitle.textContent = said
  }

  apply(entry)
  return { node: row, apply }
}

/**
 * One paper whose *text* holds the query: the sentence it is in, and where.
 * Pressing it opens the paper at that line rather than at the page it was
 * left on.
 */
function passageRow(hit: TextHit, actions: PaperListActions, byMeaning = false): HTMLElement {
  const note = hit.note
  const icon = iconNode(note ? 'note' : 'text.magnifyingglass')
  const row = el('div', { class: 'passage-row', role: 'option' }, [
    el('span', { class: 'passage-icon' }, icon ? [icon] : []),
    el('div', { class: 'paper-main' }, [
      el('div', { class: 'passage-snippet', text: hit.snippet }),
      el('div', { class: 'paper-subtitle', text: note ? noteSubtitle(hit) : passageSubtitle(hit) }),
    ]),
  ])
  on(row, 'click', () => (note ? actions.openNote(note.paperID ?? note.id) : actions.openPassage(hit, byMeaning)))
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

/**
 * What the list is short by, when it is short by something.
 *
 * Two different shortfalls and one sentence each. The folder gave nothing:
 * whatever is on screen is from before. The folder gave some of its records
 * and not the rest: the list is short by exactly that many papers, all of
 * which are still in the folder.
 *
 * Not "못 읽었어요" for the second one — read and unread are what this app
 * calls a paper you have or have not got to, and a record the folder has not
 * handed over yet is neither.
 */
function missingNote(): string | null {
  if (store.error) return L('라이브러리를 읽지 못했어요', "Couldn't read the library")
  const count = store.unreadable.length
  if (count === 0) return null
  return L(
    `기록 ${count}개가 아직 안 왔어요`,
    `${count} record${count === 1 ? '' : 's'} ${count === 1 ? "hasn't" : "haven't"} arrived`,
  )
}

function emptyState(actions: PaperListActions): HTMLElement {
  const wrap = el('div', { class: 'empty' })
  // A folder that would not be read comes first, because every sentence under
  // it would be untrue: the library is not empty and no folder needs choosing.
  // It used to say nothing at all — one record arriving half written took
  // every paper down with it and left a window with no explanation in it.
  if (store.error) {
    const again = el('button', { class: 'filled-button', text: L('다시 읽기', 'Try Again') })
    on(again, 'click', actions.refresh)
    wrap.append(
      el('h2', { text: L('라이브러리를 읽지 못했어요', "Couldn't read the library") }),
      el('p', {
        text: L(
          '논문은 폴더에 그대로 있어요. 클라우드 폴더라면 파일이 아직 내려오는 중일 수 있어요.',
          'Your papers are still in the folder. On a cloud drive, a file may still be on its way down.',
        ),
      }),
      el('p', { class: 'fine words', text: store.error }),
      again,
    )
    return wrap
  }
  if (!store.root) {
    const choose = el('button', { class: 'filled-button', text: L('라이브러리 폴더 고르기…', 'Choose Library Folder…') })
    on(choose, 'click', actions.chooseLibrary)
    wrap.append(
      el('h2', { text: L('아직 라이브러리 폴더가 없어요', 'No library folder yet') }),
      el('p', {
        text: L(
          '논문이 들어 있는 폴더를 골라주세요. 클라우드 폴더도 돼요. 그러면 라이브러리가 기기를 따라다녀요 — 맥에서 표시한 것이 PC에서도 그대로 보여요.',
          'Choose the folder your papers live in. Pick a cloud folder and the library '
            + 'travels with you — the same papers, the same marks, on a Mac and on a PC.',
        ),
      }),
      choose,
    )
    return wrap
  }
  if (store.papers.length === 0) {
    const add = el('button', { class: 'filled-button', text: L('PDF 더하기', 'Add PDFs') })
    on(add, 'click', actions.addPapers)
    wrap.append(
      el('h2', { text: L('아직 아무것도 없어요', 'Nothing here yet') }),
      el('p', {
        text: L(
          'PDF를 더하거나 창에 끌어다 놓아보세요. 논문은 폴더 안에서 제 이름을 그대로 지켜요.',
          'Add a PDF, or drop one on the window. Papers keep their own names in the folder.',
        ),
      }),
      add,
    )
    return wrap
  }
  if (store.shelf.kind === 'open') {
    wrap.append(
      el('h2', { text: L('열린 문서가 없어요', 'Nothing is open') }),
      el('p', {
        text: L(
          '논문을 클릭해 들어가거나 핀을 누르면 여기에 남아요.',
          'Click into a paper, or pin it, and it stays here.',
        ),
      }),
    )
    return wrap
  }
  if (store.shelf.kind === 'search') {
    // Not "this shelf is empty": a search that found nothing is a search,
    // and what helps is a different word.
    wrap.append(
      el('h2', { text: L(`“${store.searchQuery}”에 맞는 논문이 없어요`, `No Results for “${store.searchQuery}”`) }),
      el('p', { text: L('다른 말로 찾아보세요.', 'Check the spelling or try a new search.') }),
    )
    return wrap
  }
  wrap.append(el('h2', { text: L('이 선반은 비어 있어요', 'Nothing on this shelf') }))
  return wrap
}

export { showMenu }
