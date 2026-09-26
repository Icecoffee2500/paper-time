/**
 * The shelves: everything the library can be narrowed to.
 *
 * The same order as the Mac's — the whole library, then the reading statuses,
 * then favourites and what needs a look, then the slip-box, then collections,
 * tags, and the authors, which are not a list anyone maintains but a list the
 * library already contains.
 */
import { iconNode } from '../icons.js'
import { showMenu } from './toolbar.js'
import { clear, el, on } from '../dom.js'
import {
  authorCounts, folderAbove, folderTrail, isUnderFolder, searchCount, store, subfolders,
  type Paper, type Shelf,
} from '../state.js'
import { isLookedUp } from '../../shared/documentKind.js'
import { L } from '../../shared/lang.js'
import { providerIcon, providerOf } from '../../shared/cloudProvider.js'
import { inCollection } from '../../shared/smartRule.js'
import { PAPER_DRAG_TYPE } from '../../shared/split.js'
import { tagColor } from './paperList.js'

export interface SidebarActions {
  select: (shelf: Shelf) => void
  newCollection: () => void
  /** Another folder, read beside the ones already open. */
  addFolder: () => void
  /** Stops reading a folder. Its files stay where they are. */
  removeFolder: (root: string) => void
  /** Opens the folder in the desktop's own file manager. */
  revealFolder: (root: string) => void
  /** Puts the search away: its row goes, and its shelf with it. */
  clearSearch: () => void
  /** A paper dropped on a row: filed under it — a reading status, the
   *  favourites, a collection, a tag. */
  file: (paperID: string, shelf: Shelf) => void
}

/** One row of the list, as data — what it says and what it stands for. */
interface RowSpec {
  /** Identity across updates: the same row keeps the same node. */
  key: string
  kind: 'row' | 'section' | 'button'
  icon?: string
  label: string
  count?: number
  chip?: boolean
  shelf?: Shelf
  /** For the rows that are not shelves: add a folder, a collection, the graph. */
  press?: () => void
  title?: string
  /** How far in, for a folder inside a folder. */
  indent?: number
  /** A section that folds. The chevron turns and the rows under it go. */
  fold?: { open: boolean; press: () => void }
  /** Right-click, where a row has one. */
  menu?: { label: string; icon?: string; action: () => void }[]
  /** A second, smaller line under the label — the query under «Search Results». */
  detail?: string
  /** An × in the row's corner that puts the row away. */
  dismiss?: { label: string; press: () => void }
  /** Takes a paper dropped on it (`SidebarActions.file`). */
  drop?: boolean
  /** A colour for the row's mark — a tag's own, drawn as the Mac's dot. */
  tint?: string
}

/**
 * How many papers each shelf holds — every count in one walk of the library.
 *
 * Every row used to filter the whole library to take the length of it, and the
 * list is long: the folders, the kinds, three reading statuses, favourites,
 * what needs a look, the slip-box, and one row per collection and per tag. A
 * library of sixty papers with a dozen collections and tags walked itself
 * twenty times to draw a list nobody had asked to change.
 */
interface ShelfCounts {
  all: number
  papers: number
  books: number
  lectures: number
  documents: number
  folders: Map<string, number>
  unread: number
  reading: number
  read: number
  favorites: number
  review: number
  notes: number
  collections: Map<string, number>
  tags: Map<string, number>
}

function shelfCounts(papers: Paper[]): ShelfCounts {
  const counts: ShelfCounts = {
    all: papers.length,
    papers: 0,
    books: 0,
    lectures: 0,
    documents: 0,
    folders: new Map(),
    unread: 0,
    reading: 0,
    read: 0,
    favorites: 0,
    review: 0,
    notes: 0,
    collections: new Map(),
    tags: new Map(),
  }
  const bump = (map: Map<string, number>, key: string) => map.set(key, (map.get(key) ?? 0) + 1)
  for (const entry of papers) {
    if (entry.meta.effectiveKind === 'paper') counts.papers += 1
    else if (entry.meta.effectiveKind === 'book') counts.books += 1
    else if (entry.meta.effectiveKind === 'lecture') counts.lectures += 1
    else counts.documents += 1
    if (entry.root) bump(counts.folders, entry.root)
    if (entry.state.readingStatus === 'unread') counts.unread += 1
    else if (entry.state.readingStatus === 'reading') counts.reading += 1
    else counts.read += 1
    if (entry.state.isFavorite) counts.favorites += 1
    if (isLookedUp(entry.meta.effectiveKind)
      && (entry.meta.confidence === 'needsReview' || entry.meta.confidence === 'unparsed')) {
      counts.review += 1
    }
    if (entry.state.summaryNote.trim().length > 0) counts.notes += 1
    for (const id of entry.meta.collectionIDs) bump(counts.collections, id)
    for (const id of entry.meta.tagIDs) bump(counts.tags, id)
  }
  // A smart collection has no members written down — its count is whoever
  // its rule matches, the same papers its shelf shows.
  for (const collection of store.collections) {
    if (!collection.rule) continue
    counts.collections.set(collection.id, papers.filter((entry) =>
      inCollection(collection, entry.meta, entry.state, store.tags)).length)
  }
  return counts
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
    if (a.kind === 'folder' && b.kind === 'folder') return a.root === b.root
    return true
  }

  /** What the list should say, as a list of rows. */
  let authorsAreShown = (() => {
    try {
      return localStorage.getItem('sidebar.authors') === '1'
    } catch {
      return false
    }
  })()

  function specs(): RowSpec[] {
    const papers = store.papers.filter((entry) => !entry.meta.parentID)
    const counts = shelfCounts(papers)
    const rows: RowSpec[] = []

    // A search is somewhere you can be, not a filter left switched on
    // somewhere off-screen — so it gets a row of its own, at the top, and it
    // can be put away from there, as on the Mac.
    if (store.searchQuery) {
      rows.push({
        key: 'search',
        kind: 'row',
        shelf: { kind: 'search' },
        icon: 'magnifyingglass',
        label: L('찾은 것', 'Search Results'),
        detail: store.searchQuery,
        count: searchCount(),
        dismiss: { label: L('찾기 끝내기', 'Clear Search'), press: actions.clearSearch },
        menu: [{ label: L('찾기 끝내기', 'Clear Search'), icon: 'xmark', action: actions.clearSearch }],
      })
      rows.push({ key: 'gap:0', kind: 'section', label: '' })
    }

    // The libraries, at the top, where the one library's name used to sit. A
    // library used to be a folder; now it is as many folders as you point it
    // at, each keeping its own records — and its own notes, tags and
    // collections — beside its own PDFs, so disconnecting one leaves it
    // exactly as it was.
    rows.push({ key: 'sec:libraries', kind: 'section', label: L('라이브러리', 'Libraries') })
    // Inside a folder the other libraries step out of the way and this one's
    // own folders take their place. A term of lectures is twenty folders, and
    // a list showing every library's every folder at once would become the
    // thing the sidebar was meant to replace — so it shows one path at a
    // time: the way down to where you are, and what is one step further.
    const open = store.shelf.kind === 'folder' ? (store.shelf as { root: string }).root : null
    const trail = open ? folderTrail(open) : []
    const shownRoots = open ? store.roots.filter((root) => trail[0] === root.replace(/\\/g, '/').replace(/\/+$/, '')) : store.roots
    for (const root of shownRoots) {
      rows.push({
        key: `folder:${root}`,
        kind: 'row',
        shelf: { kind: 'folder', root },
        icon: providerIcon(providerOf(root)),
        label: basename(root),
        count: counts.folders.get(root) ?? 0,
        chip: true,
        title: root,
        // Every library can be shown where it is; all but the first can be
        // disconnected (the first is where the library began).
        menu: [
          { label: L('폴더에서 보기', 'Show in Folder'), icon: 'folder', action: () => actions.revealFolder(root) },
          ...(root === store.root
            ? []
            : [{ label: L('연결 해제', 'Disconnect'), icon: 'eject', action: () => actions.removeFolder(root) }]),
        ],
      })
    }
    if (open) {
      for (const [step, path] of trail.slice(1).entries()) {
        rows.push({
          key: `folder:${path}`,
          kind: 'row',
          shelf: { kind: 'folder', root: path },
          icon: path === open ? 'folder.fill' : 'folder',
          label: basename(path),
          count: store.papers.filter((entry) => !entry.meta.parentID && isUnderFolder(entry, path)).length,
          indent: step + 1,
          title: path,
        })
      }
      for (const node of subfolders(open)) {
        rows.push({
          key: `folder:${node.path}`,
          kind: 'row',
          shelf: { kind: 'folder', root: node.path },
          icon: 'folder',
          label: node.name,
          count: node.count,
          indent: trail.length,
          title: node.path,
        })
      }
    } else {
      rows.push({
        key: 'add:folder', kind: 'button', icon: 'plus.circle',
        label: L('라이브러리 더하기…', 'Add Library…'), press: actions.addFolder,
      })
    }
    rows.push({ key: 'gap:1', kind: 'section', label: '' })

    // Three groups with air between them, because the shelves answer three
    // different questions: what a thing is, how far through it you are, and
    // what you did about it. Nine rows in one run made you read all nine to
    // find the one you wanted. No headings — a name over three rows is a
    // label for something that does not need naming.
    rows.push({ key: 'all', kind: 'row', shelf: { kind: 'all' }, icon: 'tray.full', label: L('모두', 'All'), count: counts.all })
    // Shown only once the library holds more than one of them. A shelf that
    // has never seen anything but papers looks exactly as it did.
    //
    // Once they appear, all of them do, empty ones included. The kinds are
    // not a list that grows — they are the answers to one question, and a run
    // that shows two of four says the app knows two.
    const kinds = ([
      ['paper', 'text.document', L('논문', 'Papers'), counts.papers],
      ['book', 'book', L('책', 'Books'), counts.books],
      ['lecture', 'lecture', L('강의자료', 'Course'), counts.lectures],
      ['document', 'doc', L('문서', 'Documents'), counts.documents],
    ] as const)
    if (kinds.filter(([, , , count]) => count > 0).length > 1) {
      for (const [of, glyph, label, count] of kinds) {
        rows.push({
          key: `kind:${of}`, kind: 'row', shelf: { kind: 'kind', of },
          icon: glyph, label, count,
        })
      }
    }
    rows.push({ key: 'gap:2', kind: 'section', label: '' })

    // How far through. One paper is on exactly one of these.
    rows.push({ key: 'status:unread', kind: 'row', shelf: { kind: 'status', status: 'unread' }, icon: 'circle', label: L('안 읽음', 'Unread'), count: counts.unread, drop: true })
    rows.push({ key: 'status:reading', kind: 'row', shelf: { kind: 'status', status: 'reading' }, icon: 'circle.lefthalf.filled', label: L('읽는 중', 'Reading'), count: counts.reading, drop: true })
    rows.push({ key: 'status:read', kind: 'row', shelf: { kind: 'status', status: 'read' }, icon: 'checkmark.circle', label: L('읽음', 'Read'), count: counts.read, drop: true })
    rows.push({ key: 'gap:3', kind: 'section', label: '' })

    // What you did about it, and what is open right now — a row of tabs, as a
    // shelf. From here a paper is closed, or put beside another.
    rows.push({ key: 'favorites', kind: 'row', shelf: { kind: 'favorites' }, icon: 'star', label: L('즐겨찾기', 'Favorites'), count: counts.favorites, drop: true })
    rows.push({ key: 'review', kind: 'row', shelf: { kind: 'review' }, icon: 'exclamationmark.triangle', label: L('살펴볼 것', 'Needs Review'), count: counts.review })
    rows.push({ key: 'open', kind: 'row', shelf: { kind: 'open' }, icon: 'rectangle.on.rectangle', label: L('열린 문서', 'Open Documents'), count: store.openPaperIDs.length })

    rows.push({ key: 'sec:slipbox', kind: 'section', label: L('슬립박스', 'Slip-Box') })
    rows.push({ key: 'notes', kind: 'row', shelf: { kind: 'notes' }, icon: 'note', label: L('노트', 'Notes'), count: counts.notes })

    rows.push({ key: 'sec:collections', kind: 'section', label: L('컬렉션', 'Collections') })
    for (const collection of store.collections) {
      rows.push({
        key: `collection:${collection.id}`,
        kind: 'row',
        shelf: { kind: 'collection', id: collection.id },
        icon: collection.rule ? 'folder.badge.gearshape' : 'folder',
        label: collection.name,
        count: counts.collections.get(collection.id) ?? 0,
        // A smart collection is filled by its rule, not by hand.
        drop: !collection.rule,
      })
    }
    rows.push({
      key: 'add:collection', kind: 'button', icon: 'plus.circle',
      label: L('새 컬렉션…', 'New Collection…'), press: actions.newCollection,
    })

    rows.push({ key: 'sec:tags', kind: 'section', label: L('태그', 'Tags') })
    for (const tag of store.tags) {
      rows.push({
        key: `tag:${tag.id}`,
        kind: 'row',
        shelf: { kind: 'tag', id: tag.id },
        icon: 'tag',
        label: tag.name,
        count: counts.tags.get(tag.id) ?? 0,
        tint: tagColor(tag.color),
        drop: true,
      })
    }

    const authors = authorCounts()
    if (authors.length > 0) {
      // Folded to begin with, and remembered after that. Fifty names is the
      // longest run in this list and the least often wanted, and they pushed
      // the graph off the bottom of it.
      rows.push({
        key: 'sec:authors',
        kind: 'section',
        label: L('저자', 'Authors'),
        fold: {
          open: authorsAreShown,
          press: () => {
            authorsAreShown = !authorsAreShown
            try {
              localStorage.setItem('sidebar.authors', authorsAreShown ? '1' : '0')
            } catch {
              // A window with no storage still folds; it just forgets.
            }
            update()
          },
        },
      })
      for (const author of authorsAreShown ? authors.slice(0, 200) : []) {
        rows.push({
          key: `author:${author.name}`,
          kind: 'row',
          shelf: { kind: 'author', name: author.name },
          icon: 'person',
          label: author.name,
          count: author.count,
        })
      }
    }

    // No «Graph» row. The Mac draws the citation graph there; this build has
    // no graph, and the row it had answered every press with «not in this
    // build yet» — a row that does nothing is worse than no row. It comes
    // back with the graph.
    return rows
  }

  function build(spec: RowSpec): HTMLElement {
    if (spec.kind === 'section') {
      if (!spec.fold) return el('div', { class: 'sidebar-section', text: spec.label })
      const fold = spec.fold
      const head = el('button', {
        class: `sidebar-section sidebar-fold${fold.open ? ' open' : ''}`,
        'aria-expanded': String(fold.open),
      })
      const chevron = iconNode('chevron.right')
      if (chevron) head.append(el('span', { class: 'fold-chevron' }, [chevron]))
      head.append(el('span', { text: spec.label }))
      on(head, 'click', fold.press)
      return head
    }
    const selected = spec.shelf ? same(store.shelf, spec.shelf) : false
    const row = el('button', {
      class: 'row',
      role: spec.shelf ? 'option' : undefined,
      'aria-selected': spec.shelf ? String(selected) : undefined,
    })
    const glyph = el('span', { class: 'row-icon' })
    if (spec.tint) {
      // A tag is its colour on the Mac: a dot, not a luggage label.
      glyph.append(el('span', { class: 'row-dot', style: `background: ${spec.tint}` }))
    } else {
      const drawn = spec.icon ? iconNode(spec.icon) : null
      if (drawn) glyph.append(drawn)
    }
    // A library's name wears the chip the crumb over this list used to wear:
    // it names where something came from.
    const label = el('span', { class: spec.chip ? 'row-label folder-name' : 'row-label', text: spec.label })
    row.append(
      glyph,
      spec.detail
        ? el('span', { class: 'row-lines' }, [label, el('span', { class: 'row-detail', text: spec.detail })])
        : label,
    )
    if (spec.count !== undefined) row.append(el('span', { class: 'row-count', text: String(spec.count) }))
    if (spec.dismiss) {
      // The count steps aside for the × rather than sharing the corner with
      // it: a number with a cross on top of it is two things in one place,
      // and the one you can press has to win.
      const dismiss = spec.dismiss
      const cross = el('span', {
        class: 'row-dismiss',
        role: 'button',
        title: dismiss.label,
        'aria-label': dismiss.label,
      })
      const glyphX = iconNode('xmark')
      if (glyphX) cross.append(glyphX)
      on(cross, 'click', (event: MouseEvent) => {
        event.stopPropagation()
        dismiss.press()
      })
      row.append(cross)
      row.classList.add('dismissable')
    }
    if (spec.title) row.title = spec.title
    if (spec.indent) row.style.paddingLeft = `${8 + spec.indent * 11}px`
    const shelf = spec.shelf
    on(row, 'click', shelf ? () => {
      // Pressing the folder you are already inside goes back out, and out of
      // a library root is out of the folders altogether. A list you can get
      // into and not out of is a list with a trapdoor, and the way out has to
      // be the row your hand is already on.
      if (shelf.kind === 'folder' && same(store.shelf, shelf)) {
        const up = folderAbove(shelf.root)
        actions.select(up ? { kind: 'folder', root: up } : { kind: 'all' })
        return
      }
      actions.select(shelf)
    } : (spec.press ?? (() => {})))
    if (spec.menu) {
      const items = spec.menu
      on(row, 'contextmenu', (event: MouseEvent) => {
        event.preventDefault()
        showMenu(row, items)
      })
    }
    if (spec.drop && shelf) {
      // Filing a paper by dropping it on what it is filed under — the gesture
      // Finder and Mail taught everybody, and the Mac's sidebar takes it too.
      const carries = (event: DragEvent) => Boolean(event.dataTransfer
        && [...event.dataTransfer.types].includes(PAPER_DRAG_TYPE))
      on(row, 'dragover', (event: DragEvent) => {
        if (!carries(event)) return
        event.preventDefault()
        event.stopPropagation()
        if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
        row.classList.add('drop-target')
      })
      on(row, 'dragleave', () => row.classList.remove('drop-target'))
      on(row, 'drop', (event: DragEvent) => {
        row.classList.remove('drop-target')
        if (!carries(event)) return
        event.preventDefault()
        event.stopPropagation()
        const paperID = event.dataTransfer?.getData(PAPER_DRAG_TYPE)
        if (paperID) actions.file(paperID, shelf)
      })
    }
    return row
  }

  /** What has to be redrawn rather than merely re-labelled. */
  function shape(spec: RowSpec): string {
    return `${spec.kind}|${spec.key}|${spec.icon ?? ''}|${spec.label}|${spec.detail ?? ''}|${spec.chip ? 1 : 0}|${spec.menu ? 1 : 0}|${spec.indent ?? 0}|${spec.fold ? (spec.fold.open ? 'v' : '>') : ''}|${spec.drop ? 1 : 0}|${spec.tint ?? ''}`
  }

  let drawnSpecs: RowSpec[] = []
  let drawnNodes: HTMLElement[] = []

  function update() {
    const wanted = specs()
    // The list is the same list nearly every time it is asked for: choosing a
    // paper does not change a single row of it, and moving to another shelf
    // changes two. Rebuilding it meant two hundred and fifty rows and as many
    // icons parsed from markup, for a list that had not moved.
    const sameShape = wanted.length === drawnSpecs.length
      && wanted.every((spec, at) => shape(spec) === shape(drawnSpecs[at]))
    if (!sameShape) {
      clear(body)
      drawnNodes = wanted.map(build)
      body.append(...drawnNodes)
      drawnSpecs = wanted
      return
    }
    for (const [at, spec] of wanted.entries()) {
      const node = drawnNodes[at]
      if (spec.kind === 'section') continue
      if (spec.count !== undefined) {
        const cell = node.querySelector('.row-count')
        const text = String(spec.count)
        if (cell && cell.textContent !== text) cell.textContent = text
      }
      if (spec.shelf) {
        const selected = String(same(store.shelf, spec.shelf))
        if (node.getAttribute('aria-selected') !== selected) node.setAttribute('aria-selected', selected)
      }
    }
    drawnSpecs = wanted
  }

  update()
  return { node, update }
}

export function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}
