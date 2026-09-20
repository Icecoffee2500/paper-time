/**
 * The shelves: everything the library can be narrowed to.
 *
 * The same order as the Mac's — the whole library, then the reading statuses,
 * then favourites and what needs a look, then the slip-box, then collections,
 * tags, and the authors, which are not a list anyone maintains but a list the
 * library already contains.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { authorCounts, store, type Shelf } from '../state.js'

export interface SidebarActions {
  select: (shelf: Shelf) => void
  newCollection: () => void
  openGraph: () => void
  chooseLibrary: () => void
}

export function buildSidebar(actions: SidebarActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'panel' })
  const body = el('div', { class: 'panel-body' })
  node.append(body)

  function same(a: Shelf, b: Shelf): boolean {
    if (a.kind !== b.kind) return false
    if (a.kind === 'collection' && b.kind === 'collection') return a.id === b.id
    if (a.kind === 'tag' && b.kind === 'tag') return a.id === b.id
    if (a.kind === 'author' && b.kind === 'author') return a.name === b.name
    if (a.kind === 'status' && b.kind === 'status') return a.status === b.status
    return true
  }

  function row(shelf: Shelf, name: string, label: string, count?: number) {
    const selected = same(store.shelf, shelf)
    const node = el('button', { class: 'row', role: 'option', 'aria-selected': String(selected) }, [
      el('span', { class: 'row-icon', html: icon(name) }),
      el('span', { class: 'row-label', text: label }),
    ])
    if (count !== undefined) node.append(el('span', { class: 'row-count', text: String(count) }))
    on(node, 'click', () => actions.select(shelf))
    return node
  }

  function section(label: string) {
    return el('div', { class: 'sidebar-section', text: label })
  }

  function update() {
    clear(body)
    const papers = store.papers.filter((entry) => !entry.meta.parentID)
    const count = (predicate: (entry: (typeof papers)[number]) => boolean) =>
      papers.filter(predicate).length

    const crumb = el('div', { class: 'library-crumb' }, [
      el('span', { text: 'Library' }),
      el('span', { class: 'name', text: store.root ? basename(store.root) : 'None' }),
    ])
    on(crumb, 'click', actions.chooseLibrary)
    crumb.style.cursor = 'default'
    crumb.title = store.root ?? 'Choose a library folder'
    body.append(crumb)

    body.append(
      row({ kind: 'all' }, 'tray.full', 'All Papers', papers.length),
      row({ kind: 'status', status: 'unread' }, 'circle', 'Unread', count((e) => e.state.readingStatus === 'unread')),
      row({ kind: 'status', status: 'reading' }, 'circle.lefthalf.filled', 'Reading', count((e) => e.state.readingStatus === 'reading')),
      row({ kind: 'status', status: 'read' }, 'checkmark.circle', 'Read', count((e) => e.state.readingStatus === 'read')),
      row({ kind: 'favorites' }, 'star', 'Favorites', count((e) => e.state.isFavorite)),
      row({ kind: 'review' }, 'exclamationmark.triangle', 'Needs Review',
        count((e) => e.meta.confidence === 'needsReview' || e.meta.confidence === 'unparsed')),
    )

    body.append(section('Slip-Box'))
    body.append(row({ kind: 'notes' }, 'note', 'Notes', count((e) => e.state.summaryNote.trim().length > 0)))

    body.append(section('Collections'))
    for (const collection of store.collections) {
      body.append(row(
        { kind: 'collection', id: collection.id },
        collection.rule ? 'folder.badge.gearshape' : 'folder',
        collection.name,
        count((e) => e.meta.collectionIDs.includes(collection.id)),
      ))
    }
    const add = el('button', { class: 'row' }, [
      el('span', { class: 'row-icon', html: icon('plus.circle') }),
      el('span', { class: 'row-label', text: 'New Collection…' }),
    ])
    on(add, 'click', actions.newCollection)
    body.append(add)

    body.append(section('Tags'))
    for (const tag of store.tags) {
      body.append(row({ kind: 'tag', id: tag.id }, 'tag', tag.name, count((e) => e.meta.tagIDs.includes(tag.id))))
    }

    const authors = authorCounts()
    if (authors.length > 0) {
      body.append(section('Authors'))
      for (const author of authors.slice(0, 200)) {
        body.append(row({ kind: 'author', name: author.name }, 'person', author.name, author.count))
      }
    }

    const graph = el('button', { class: 'row' }, [
      el('span', { class: 'row-icon', html: icon('graph') }),
      el('span', { class: 'row-label', text: 'Graph' }),
    ])
    on(graph, 'click', actions.openGraph)
    body.append(el('div', { class: 'sidebar-section', text: '' }), graph)
  }

  update()
  return { node, update }
}

function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}
