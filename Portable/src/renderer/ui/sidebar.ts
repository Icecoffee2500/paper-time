/**
 * The shelves: everything the library can be narrowed to.
 *
 * The same order as the Mac's — the whole library, then the reading statuses,
 * then favourites and what needs a look, then the slip-box, then collections,
 * tags, and the authors, which are not a list anyone maintains but a list the
 * library already contains.
 */
import { hasIcon, iconNode, type IconName } from '../icons.js'
import { showMenu, type MenuEntry } from './toolbar.js'
import { clear, el, on } from '../dom.js'
import {
  authorCounts, folderAbove, folderTrail, isUnderFolder, sameShelf, searchCount, shelfCounts, store, subfolders,
  type Shelf,
} from '../state.js'
import { L } from '../../shared/lang.js'
import { providerIcon, providerOf } from '../../shared/cloudProvider.js'
import { samePath } from '../../shared/paths.js'
import { carriesPapers, draggedPapers } from '../../shared/split.js'
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
  file: (paperIDs: string[], shelf: Shelf) => void
}

/** One row of the list, as data — what it says and what it stands for. */
interface RowSpec {
  /** Identity across updates: the same row keeps the same node. */
  key: string
  kind: 'row' | 'section' | 'button'
  icon?: IconName
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
  menu?: MenuEntry[]
  /** A second, smaller line under the label — the query under «Search Results». */
  detail?: string
  /** An × in the row's corner that puts the row away. */
  dismiss?: { label: string; press: () => void }
  /** Takes a paper dropped on it (`SidebarActions.file`). */
  drop?: boolean
  /** A colour for the row's mark — a tag's own, drawn as the Mac's dot. */
  tint?: string
  /** The shelf's own colour when it is the one lit (`ScopeRow.symbolColor`):
   *  states take the system's colours for states, places the accent. */
  hue?: 'reading' | 'read' | 'favorites' | 'review'
}

/** How many authors show before «Show All N» — ten fit without turning the
 *  list into a directory (`authorsSection`). */
const AUTHORS_SHOWN = 10

export function buildSidebar(actions: SidebarActions): { node: HTMLElement; update: () => void } {
  // On the ground, not a white card: the Mac's source list is part of the
  // window's background.
  const node = el('div', { class: 'panel sidebar-column' })
  const body = el('div', { class: 'panel-body' })
  node.append(body)

  const same = sameShelf
  /** The one lit shape, behind the rows: it travels from the row you were
   *  on to the one you chose, as the Mac's glass does, rather than blinking
   *  out in one place and in at another. */
  const lit = el('div', { class: 'sidebar-lit', 'aria-hidden': 'true' })
  /** «Show All N» under the authors, for this window. */
  let showsAllAuthors = false

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
    // A trail that no library starts is a folder whose library is gone:
    // every library shows rather than none — none left no way out.
    const trailRoots = open ? store.roots.filter((root) => samePath(trail[0], root)) : []
    const shownRoots = trailRoots.length > 0 ? trailRoots : store.roots
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
          // Apart, and in red: this one takes a library out of the list.
          ...(root === store.root
            ? []
            : [
                { separator: true },
                { label: L('연결 해제', 'Disconnect'), icon: 'eject', danger: true, action: () => actions.removeFolder(root) },
              ]),
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
    rows.push({ key: 'status:reading', kind: 'row', shelf: { kind: 'status', status: 'reading' }, icon: 'circle.lefthalf.filled', label: L('읽는 중', 'Reading'), count: counts.reading, drop: true, hue: 'reading' })
    rows.push({ key: 'status:read', kind: 'row', shelf: { kind: 'status', status: 'read' }, icon: 'checkmark.circle', label: L('읽음', 'Read'), count: counts.read, drop: true, hue: 'read' })
    rows.push({ key: 'gap:3', kind: 'section', label: '' })

    // What you did about it, and what is open right now — a row of tabs, as a
    // shelf. From here a paper is closed, or put beside another.
    rows.push({ key: 'favorites', kind: 'row', shelf: { kind: 'favorites' }, icon: 'star', label: L('즐겨찾기', 'Favorites'), count: counts.favorites, drop: true, hue: 'favorites' })
    rows.push({ key: 'review', kind: 'row', shelf: { kind: 'review' }, icon: 'exclamationmark.triangle', label: L('살펴볼 것', 'Needs Review'), count: counts.review, hue: 'review' })
    rows.push({ key: 'open', kind: 'row', shelf: { kind: 'open' }, icon: 'rectangle.on.rectangle', label: L('열린 문서', 'Open Documents'), count: store.openPaperIDs.length })

    rows.push({ key: 'sec:slipbox', kind: 'section', label: L('슬립박스', 'Slip-Box') })
    rows.push({ key: 'notes', kind: 'row', shelf: { kind: 'notes' }, icon: 'note', label: L('노트', 'Notes'), count: counts.notes })

    rows.push({ key: 'sec:collections', kind: 'section', label: L('컬렉션', 'Collections') })
    for (const collection of store.collections) {
      rows.push({
        key: `collection:${collection.id}`,
        kind: 'row',
        shelf: { kind: 'collection', id: collection.id },
        // The symbol the collection was given on the Mac, where this build
        // can draw it.
        icon: collection.rule
          ? 'folder.badge.gearshape'
          : (collection.symbolName && hasIcon(collection.symbolName) ? collection.symbolName as IconName : 'folder'),
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
      // The names that keep coming back, most papers first; the rest one
      // press away.
      const shown = showsAllAuthors ? authors : authors.slice(0, AUTHORS_SHOWN)
      for (const author of authorsAreShown ? shown : []) {
        rows.push({
          key: `author:${author.key}`,
          kind: 'row',
          shelf: { kind: 'author', key: author.key, name: author.name },
          icon: 'person',
          label: author.name,
          count: author.count,
        })
      }
      if (authorsAreShown && authors.length > AUTHORS_SHOWN) {
        rows.push({
          key: `authors:${showsAllAuthors ? 'fewer' : 'all'}`,
          kind: 'button',
          label: showsAllAuthors ? L('줄이기', 'Show Fewer') : L(`${authors.length}명 모두 보기`, `Show All ${authors.length}`),
          press: () => {
            showsAllAuthors = !showsAllAuthors
            update()
          },
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
    // A row is not a <button>: the search row's × is a button of its own,
    // and a button inside a button is neither — Tab never reached it.
    const row = el('div', {
      class: spec.kind === 'button' ? 'row row-action' : 'row',
      role: spec.shelf ? 'option' : 'button',
      tabindex: '0',
      'aria-selected': spec.shelf ? String(selected) : undefined,
    })
    if (spec.hue) row.dataset.hue = spec.hue
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
    if (spec.chip) label.dataset.full = spec.label
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
      const cross = el('button', {
        class: 'row-dismiss',
        title: dismiss.label,
        'aria-label': dismiss.label,
      })
      const glyphX = iconNode('xmark')
      if (glyphX) cross.append(glyphX)
      on(cross, 'click', (event: MouseEvent) => {
        event.stopPropagation()
        dismiss.press()
      })
      on(cross, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
      row.append(cross)
      row.classList.add('dismissable')
    }
    if (spec.title) row.title = spec.title
    if (spec.indent) row.style.paddingLeft = `${8 + spec.indent * 11}px`
    const shelf = spec.shelf
    const press = shelf ? () => {
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
    } : (spec.press ?? (() => {}))
    on(row, 'click', press)
    on(row, 'keydown', (event: KeyboardEvent) => {
      if (event.target !== row || (event.key !== 'Enter' && event.key !== ' ')) return
      event.preventDefault()
      press()
    })
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
      // Counted in and out: the pointer crossing from the row onto its own
      // icon is a `dragleave` too, and the ring blinked at every edge.
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
        if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
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
        const ids = draggedPapers(event.dataTransfer)
        if (ids.length > 0) actions.file(ids, shelf)
      })
    }
    return row
  }

  /** What has to be redrawn rather than merely re-labelled. */
  function shape(spec: RowSpec): string {
    return `${spec.kind}|${spec.key}|${spec.icon ?? ''}|${spec.label}|${spec.detail ?? ''}|${spec.chip ? 1 : 0}|${spec.menu ? spec.menu.length : 0}|${spec.indent ?? 0}|${spec.fold ? (spec.fold.open ? 'v' : '>') : ''}|${spec.drop ? 1 : 0}|${spec.tint ?? ''}`
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
      body.append(lit, ...drawnNodes)
      drawnSpecs = wanted
      fitChips()
      placeLit(false)
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
    placeLit(true)
  }

  /** The lit shape under the chosen row, in the shelf's colour. */
  function placeLit(travel: boolean) {
    const at = drawnSpecs.findIndex((spec) => spec.shelf && same(store.shelf, spec.shelf))
    const row = at >= 0 ? drawnNodes[at] : null
    if (!row || !row.isConnected || row.offsetHeight === 0) {
      lit.dataset.on = 'false'
      return
    }
    // A list rebuilt is not a row left: the shape is put, not sent.
    lit.classList.toggle('still', !travel || lit.dataset.on !== 'true')
    lit.dataset.on = 'true'
    lit.dataset.hue = drawnSpecs[at].hue ?? ''
    lit.style.transform = `translateY(${row.offsetTop}px)`
    lit.style.height = `${row.offsetHeight}px`
    lit.style.left = `${row.offsetLeft}px`
    lit.style.width = `${row.offsetWidth}px`
  }

  /**
   * A library's name shortened in the middle, as the Mac's chip is
   * (`truncationMode(.middle)`): «2026-1학기…강화학습» keeps the part that
   * tells one term from another, which an ellipsis at the end cut off.
   */
  function fitChips() {
    for (const chip of body.querySelectorAll<HTMLElement>('.folder-name[data-full]')) {
      const full = chip.dataset.full ?? ''
      chip.textContent = full
      if (chip.scrollWidth <= chip.clientWidth + 1) continue
      const letters = [...full]
      let low = 1
      let high = letters.length - 1
      let best = `${letters[0] ?? ''}…`
      while (low <= high) {
        const keep = Math.floor((low + high) / 2)
        const head = Math.ceil(keep / 2)
        const tail = keep - head
        const text = `${letters.slice(0, head).join('')}…${tail > 0 ? letters.slice(-tail).join('') : ''}`
        chip.textContent = text
        if (chip.scrollWidth <= chip.clientWidth + 1) {
          best = text
          low = keep + 1
        } else {
          high = keep - 1
        }
      }
      chip.textContent = best
    }
  }

  // The column changes width by hand; the chips and the lit shape follow.
  new ResizeObserver(() => {
    fitChips()
    placeLit(false)
  }).observe(node)

  update()
  return { node, update }
}

export function basename(p: string): string {
  const parts = p.split(/[\\/]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}
