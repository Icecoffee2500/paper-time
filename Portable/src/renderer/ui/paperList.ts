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

export interface PaperListActions {
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
        text: `Add ${store.looseCount} loose PDF${store.looseCount === 1 ? '' : 's'}`,
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
    title: `Reading status: ${entry.state.readingStatus}`,
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
      text: 'The PDF is not in the folder',
    }))
  }

  const star = el('button', {
    class: 'paper-star',
    'data-on': String(entry.state.isFavorite),
    title: entry.state.isFavorite ? 'Remove from favourites' : 'Add to favourites',
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
    case 'all': return 'All Papers'
    case 'status': return { unread: 'Unread', reading: 'Reading', read: 'Read' }[store.shelf.status]
    case 'favorites': return 'Favorites'
    case 'review': return 'Needs Review'
    case 'notes': return 'Notes'
    case 'collection':
      return store.collections.find((c) => c.id === (store.shelf as { id: string }).id)?.name ?? 'Collection'
    case 'tag':
      return store.tags.find((t) => t.id === (store.shelf as { id: string }).id)?.name ?? 'Tag'
    case 'author': return (store.shelf as { name: string }).name
  }
}

function emptyState(actions: PaperListActions): HTMLElement {
  const wrap = el('div', { class: 'empty' })
  if (!store.root) {
    wrap.append(
      el('h2', { text: 'No library folder yet' }),
      el('p', { text: 'Choose the folder your papers live in. A cloud folder works, and is how a library follows you between machines.' }),
    )
    return wrap
  }
  if (store.papers.length === 0) {
    const add = el('button', { class: 'filled-button', text: 'Add PDFs' })
    on(add, 'click', actions.addPapers)
    wrap.append(
      el('h2', { text: 'Nothing here yet' }),
      el('p', { text: 'Add a PDF, or drop one on the window. Papers keep their own names in the folder.' }),
      add,
    )
    return wrap
  }
  wrap.append(el('h2', { text: 'Nothing on this shelf' }))
  return wrap
}

export { showMenu }
