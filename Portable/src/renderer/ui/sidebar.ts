/**
 * The shelves: everything the library can be narrowed to.
 *
 * The same order as the Mac's — the whole library, then the reading statuses,
 * then favourites and what needs a look, then the slip-box, then collections,
 * tags, and the authors, which are not a list anyone maintains but a list the
 * library already contains.
 */
import { icon } from '../icons.js'
import { showMenu } from './toolbar.js'
import { clear, el, on } from '../dom.js'
import { authorCounts, store, type Shelf } from '../state.js'
import { L } from '../../shared/lang.js'
import { providerIcon, providerOf } from '../../shared/cloudProvider.js'

export interface SidebarActions {
  select: (shelf: Shelf) => void
  newCollection: () => void
  openGraph: () => void
  /** Another folder, read beside the ones already open. */
  addFolder: () => void
  /** Stops reading a folder. Its files stay where they are. */
  removeFolder: (root: string) => void
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

  function row(shelf: Shelf, name: string, label: string, count?: number, chip = false) {
    const selected = same(store.shelf, shelf)
    const node = el('button', { class: 'row', role: 'option', 'aria-selected': String(selected) }, [
      el('span', { class: 'row-icon', html: icon(name) }),
      // A library's name wears the chip the crumb over this list used to
      // wear: it names where something came from.
      el('span', { class: chip ? 'row-label folder-name' : 'row-label', text: label }),
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

    // The libraries, at the top, where the one library's name used to sit. A
    // library used to be a folder; now it is as many folders as you point it
    // at, each keeping its own records — and its own notes, tags and
    // collections — beside its own PDFs, so disconnecting one leaves it
    // exactly as it was.
    body.append(section(L('라이브러리', 'Libraries')))
    for (const root of store.roots) {
      const folderRow = row(
        { kind: 'folder', root },
        providerIcon(providerOf(root)),
        basename(root),
        count((e) => e.root === root),
        true,
      )
      folderRow.title = root
      if (root !== store.root) {
        on(folderRow, 'contextmenu', (event: MouseEvent) => {
          event.preventDefault()
          showMenu(folderRow, [
            { label: L('연결 해제', 'Disconnect'), icon: 'eject', action: () => actions.removeFolder(root) },
          ])
        })
      }
      body.append(folderRow)
    }
    const addFolder = el('button', { class: 'row' }, [
      el('span', { class: 'row-icon', html: icon('plus.circle') }),
      el('span', { class: 'row-label', text: L('라이브러리 더하기…', 'Add Library…') }),
    ])
    on(addFolder, 'click', actions.addFolder)
    body.append(addFolder, el('div', { class: 'sidebar-section', text: '' }))

    body.append(
      row({ kind: 'all' }, 'tray.full', L('모두', 'All'), papers.length),
      // What is open right now — a row of tabs, as a shelf. From here a
      // paper is closed, or put beside another.
      row({ kind: 'open' }, 'rectangle.on.rectangle', L('열린 논문', 'Open Papers'), store.openPaperIDs.length),
      // Shown only once the library holds both. A shelf that has never seen
      // anything but papers looks exactly as it did.
      ...(count((e) => e.meta.effectiveKind === 'document') > 0
        && count((e) => e.meta.effectiveKind === 'paper') > 0
        ? [
            row({ kind: 'kind', of: 'paper' }, 'text.document', L('논문', 'Papers'),
              count((e) => e.meta.effectiveKind === 'paper')),
            row({ kind: 'kind', of: 'document' }, 'note', L('문서', 'Documents'),
              count((e) => e.meta.effectiveKind === 'document')),
          ]
        : []),
      row({ kind: 'status', status: 'unread' }, 'circle', L('안 읽음', 'Unread'), count((e) => e.state.readingStatus === 'unread')),
      row({ kind: 'status', status: 'reading' }, 'circle.lefthalf.filled', L('읽는 중', 'Reading'), count((e) => e.state.readingStatus === 'reading')),
      row({ kind: 'status', status: 'read' }, 'checkmark.circle', L('읽음', 'Read'), count((e) => e.state.readingStatus === 'read')),
      row({ kind: 'favorites' }, 'star', L('즐겨찾기', 'Favorites'), count((e) => e.state.isFavorite)),
      row({ kind: 'review' }, 'exclamationmark.triangle', L('살펴볼 것', 'Needs Review'),
        count((e) => e.meta.effectiveKind === 'paper'
          && (e.meta.confidence === 'needsReview' || e.meta.confidence === 'unparsed'))),
    )

    body.append(section(L('슬립박스', 'Slip-Box')))
    body.append(row({ kind: 'notes' }, 'note', L('노트', 'Notes'), count((e) => e.state.summaryNote.trim().length > 0)))

    body.append(section(L('컬렉션', 'Collections')))
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
      el('span', { class: 'row-label', text: L('새 컬렉션…', 'New Collection…') }),
    ])
    on(add, 'click', actions.newCollection)
    body.append(add)

    body.append(section(L('태그', 'Tags')))
    for (const tag of store.tags) {
      body.append(row({ kind: 'tag', id: tag.id }, 'tag', tag.name, count((e) => e.meta.tagIDs.includes(tag.id))))
    }

    const authors = authorCounts()
    if (authors.length > 0) {
      body.append(section(L('저자', 'Authors')))
      for (const author of authors.slice(0, 200)) {
        body.append(row({ kind: 'author', name: author.name }, 'person', author.name, author.count))
      }
    }

    const graph = el('button', { class: 'row' }, [
      el('span', { class: 'row-icon', html: icon('graph') }),
      el('span', { class: 'row-label', text: L('그래프', 'Graph') }),
    ])
    on(graph, 'click', actions.openGraph)
    body.append(el('div', { class: 'sidebar-section', text: '' }), graph)
  }

  update()
  return { node, update }
}

export function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}
