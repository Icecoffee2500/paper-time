/**
 * The list of papers on whichever shelf is showing.
 *
 * A row is the title, who wrote it and where, and two things you can act on
 * without opening anything: the reading status on the left, which cycles, and
 * the star on the right.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { shelfPapers, store, type Paper } from '../state.js'
import { showMenu } from './toolbar.js'
import { L } from '../../shared/lang.js'

export interface PaperListActions {
  chooseLibrary: () => void
  open: (id: string) => void
  cycleStatus: (id: string) => void
  toggleFavorite: (id: string) => void
  contextMenu: (id: string, anchor: Element) => void
  addPapers: () => void
  adoptLoose: () => void
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

  function update() {
    clear(header)
    clear(body)
    const papers = shelfPapers()
    header.append(el('span', { text: shelfTitle() }))
    header.append(el('span', { class: 'toolbar-spacer' }))
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

    if (papers.length === 0) {
      body.append(emptyState(actions))
      return
    }

    for (const entry of papers) {
      body.append(paperRow(entry, actions))
    }
  }

  update()
  return { node, update }
}

function paperRow(entry: Paper, actions: PaperListActions): HTMLElement {
  const selected = store.selectedID === entry.id
  const row = el('div', { class: 'paper-row', role: 'option', 'aria-selected': String(selected) })

  const status = el('button', {
    class: 'paper-status',
    title: L(`읽기 상태: ${statusName(entry.state.readingStatus)}`, `Reading status: ${entry.state.readingStatus}`),
    html: icon(STATUS_ICON[entry.state.readingStatus]),
  })
  on(status, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.cycleStatus(entry.id)
  })

  const subtitleParts = [
    entry.meta.displayAuthors,
    entry.meta.year ? String(entry.meta.year) : '',
    entry.meta.venue ?? '',
  ].filter(Boolean)

  const main = el('div', { class: 'paper-main' }, [
    el('div', { class: 'paper-title', text: entry.meta.displayTitle }),
    el('div', { class: 'paper-subtitle', text: subtitleParts.join(' · ') }),
  ])
  if (!entry.exists) {
    main.append(el('div', {
      class: 'paper-subtitle',
      style: 'color: var(--danger)',
      text: L('PDF가 폴더에 없다', 'The PDF is not in the folder'),
    }))
  }

  const star = el('button', {
    class: 'paper-star',
    'data-on': String(entry.state.isFavorite),
    title: entry.state.isFavorite
      ? L('즐겨찾기에서 빼기', 'Remove from favourites')
      : L('즐겨찾기에 더하기', 'Add to favourites'),
    html: icon(entry.state.isFavorite ? 'star.fill' : 'star'),
  })
  on(star, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.toggleFavorite(entry.id)
  })

  row.append(status, main, star)
  on(row, 'click', () => actions.open(entry.id))
  on(row, 'contextmenu', (event: MouseEvent) => {
    event.preventDefault()
    actions.contextMenu(entry.id, row)
  })
  return row
}

function shelfTitle(): string {
  switch (store.shelf.kind) {
    case 'all': return L('모든 논문', 'All Papers')
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

function emptyState(actions: PaperListActions): HTMLElement {
  const wrap = el('div', { class: 'empty' })
  if (!store.root) {
    const choose = el('button', { class: 'filled-button', text: L('라이브러리 폴더 고르기…', 'Choose Library Folder…') })
    on(choose, 'click', actions.chooseLibrary)
    wrap.append(
      el('h2', { text: L('아직 라이브러리 폴더가 없다', 'No library folder yet') }),
      el('p', {
        text: L(
          '논문이 있는 폴더를 고른다. 클라우드 폴더도 되고, 그게 라이브러리가 기기를 따라다니는 길이다 — 같은 논문, 같은 표시가 맥에서도 PC에서도.',
          'Choose the folder your papers live in. A cloud folder works, and is how a '
            + 'library follows you between machines — the same papers, the same marks, on a Mac '
            + 'and on a PC.',
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
      el('h2', { text: L('아직 아무것도 없다', 'Nothing here yet') }),
      el('p', {
        text: L(
          'PDF를 더하거나 창에 끌어다 놓는다. 논문은 폴더 안에서 제 이름을 그대로 지킨다.',
          'Add a PDF, or drop one on the window. Papers keep their own names in the folder.',
        ),
      }),
      add,
    )
    return wrap
  }
  wrap.append(el('h2', { text: L('이 선반은 비어 있다', 'Nothing on this shelf') }))
  return wrap
}

export { showMenu }
