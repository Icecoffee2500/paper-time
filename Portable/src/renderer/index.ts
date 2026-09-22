/**
 * The window.
 *
 * Four panels on a ground, a toolbar above them, and the keys that drive the
 * lot. The arrangement is the Mac's, down to the eight-point margin and the
 * ten-point gap that doubles as the resize handle, because a person who reads
 * on one machine and writes on another should not have to find anything twice.
 *
 * The page area holds one reader, or up to four side by side; each pane is a
 * `Reader` of its own, and the one in focus is the paper the window is
 * "about" — the inspector, the notes and the keys act on it. A window opened
 * for one paper (`--papertime-paper=<id>`) is this same page showing only
 * that reader.
 */
import { call, flags, isCommand, onEvent, platform, soloPaperID } from './bridge.js'
import { clear, el, on } from './dom.js'
// Imported for its side effect: the sheet registers its own ⌥⌘/ so nothing
// in the shell has to know it exists.
import { showFeedback } from './ui/feedback.js'
import {
  adopt,
  canGoBack,
  canGoForward,
  changed,
  closeOpenPaper,
  closeOtherOpenPapers,
  dock,
  isOpenPaper,
  isPinned,
  keepOpen,
  panePapers,
  paper as findPaper,
  remember,
  shelfPapers,
  store,
  setSketchTool,
  subscribe,
  travel,
  undock,
  type InspectorTab,
  type Pane,
  type Shelf,
  type SketchTool,
} from './state.js'
import { buildToolbar, showMenu, toast } from './ui/toolbar.js'
import { buildSidebar } from './ui/sidebar.js'
import { buildPaperList } from './ui/paperList.js'
import { buildInspector } from './ui/inspector.js'
import { Reader } from './ui/reader.js'
import { buildSketchRack, TOOLS } from './ui/sketchToolbar.js'
import { undoStack, type SketchInputEditing } from './ui/sketchInput.js'
import { sketchEditor, sketchSelectionChanged } from './ui/sketchEditing.js'
import {
  closeOpenPapers,
  isOpenPapersShowing,
  refreshOpenPapers,
  toggleOpenPapers,
} from './ui/openPapers.js'
import { closePages, isPagesShowing, togglePages } from './ui/pages.js'
import type { LibrarySnapshot, WindowBounds } from '../shared/api.js'
import { expandedIDs } from '../shared/sketch.js'
import {
  DOCK_ZONES,
  PAPER_DRAG_TYPE,
  splitContains,
  splitPapers,
  zoneAt,
  zoneRect,
  type DockZone,
  type SplitArrangement,
} from '../shared/split.js'
import { icon } from './icons.js'
import { L } from '../shared/lang.js'
import { type ByteTrouble, type PDFLock } from '../shared/pdfLock.js'
import { isCitable, isLookedUp, type DocumentKind } from '../shared/documentKind.js'

document.body.dataset.platform = platform
/** This window shows one paper on its own: no library columns. */
const solo = soloPaperID !== null
if (solo) document.body.dataset.solo = 'true'
// For the in-page probe (`--papertime-probe`): the drawing contract, so a
// test can stand in for the page's editor and look at the Tools tab.
;(window as unknown as { __papertimeSketch: unknown }).__papertimeSketch = { sketchEditor, sketchSelectionChanged, store }

const root = document.getElementById('root')!
const panes = el('div', { class: 'panes' })

// ---------------------------------------------------------------- the panes

/** Another folder, read beside the ones already open. Also on the File menu. */
function addLibraryFolder() {
  void (async () => {
    const snapshot = await call<LibrarySnapshot>('library:addFolder', {})
    if ('error' in snapshot) return
    adopt(snapshot)
    changed('papers', 'shelf', 'sidebar')
  })()
}

const sidebar = buildSidebar({
  select: (shelf: Shelf) => {
    store.shelf = shelf
    changed('shelf')
  },
  addFolder: () => addLibraryFolder(),
  removeFolder: (root: string) => {
    void (async () => {
      const snapshot = await call<LibrarySnapshot>('library:removeFolder', { root })
      if ('error' in snapshot) return
      // Papers from that folder are gone: whatever was showing goes with them.
      if (store.shelf.kind === 'folder' && store.shelf.root === root) store.shelf = { kind: 'all' }
      adopt(snapshot)
      store.openPaperIDs = store.openPaperIDs.filter((id) => findPaper(id))
      for (const id of panePapers()) if (!findPaper(id)) undock(id)
      if (store.selectedID && !findPaper(store.selectedID)) store.selectedID = null
      reconcileReaders()
      changed('papers', 'shelf', 'sidebar')
    })()
  },
  newCollection: async () => {
    const name = await prompt(L('새 컬렉션', 'New collection'))
    if (!name) return
    const collections = [...store.collections, {
      id: crypto.randomUUID().toUpperCase(),
      name,
      symbolName: 'folder',
      sortIndex: store.collections.length,
    }]
    await call('collections:save', { collections })
    await reload()
  },
  openGraph: () => toast(L('인용 그래프는 아직 이 빌드에 없어요.', 'The citation graph is not in this build yet.')),
})

const ZONE_LABELS = (): Record<DockZone, string> => ({
  left: L('왼쪽에', 'Left Half'),
  right: L('오른쪽에', 'Right Half'),
  topLeft: L('왼쪽 위에', 'Top Left'),
  topRight: L('오른쪽 위에', 'Top Right'),
  bottomLeft: L('왼쪽 아래에', 'Bottom Left'),
  bottomRight: L('오른쪽 아래에', 'Bottom Right'),
})

const ZONE_ICONS: Record<DockZone, string> = {
  left: 'rectangle.lefthalf.inset.filled',
  right: 'rectangle.righthalf.inset.filled',
  topLeft: 'rectangle.inset.topleft.filled',
  topRight: 'rectangle.inset.topright.filled',
  bottomLeft: 'rectangle.inset.bottomleft.filled',
  bottomRight: 'rectangle.inset.bottomright.filled',
}

const paperList = buildPaperList({
  chooseLibrary: () => void chooseLibrary(),
  open: (id) => void showPaper(id),
  cycleStatus: async (id) => {
    const entry = findPaper(id)
    if (!entry) return
    const next = { unread: 'reading', reading: 'read', read: 'unread' } as const
    await call('paper:state', { id, patch: { readingStatus: next[entry.state.readingStatus] } })
    await reload()
  },
  toggleFavorite: async (id) => {
    const entry = findPaper(id)
    if (!entry) return
    await call('paper:state', { id, patch: { isFavorite: !entry.state.isFavorite } })
    await reload()
  },
  togglePin: (id) => {
    if (isPinned(id)) closePaper(id)
    else keepPaper(id, true)
  },
  close: (id) => closePaper(id),
  contextMenu: (id, anchor) => {
    const entry = findPaper(id)
    if (!entry) return
    const labels = ZONE_LABELS()
    showMenu(anchor, [
      { label: L('열기', 'Open'), icon: 'text.page', action: () => void showPaper(id) },
      // Beside the paper already open: a half, or a quarter, of the page.
      {
        label: L('나란히 열기', 'Open Side by Side'),
        icon: 'rectangle.split.2x1',
        children: DOCK_ZONES.flatMap((zone, index) => [
          ...(index === 2 ? [{ separator: true }] : []),
          { label: labels[zone], icon: ZONE_ICONS[zone], action: () => dockPaper(id, zone) },
        ]),
      },
      ...(isOpenPaper(id)
        ? [
            { label: L('닫기', 'Close'), icon: 'xmark.circle', action: () => closePaper(id) },
            ...(store.openPaperIDs.length > 1
              ? [{ label: L('다른 논문 모두 닫기', 'Close Other Papers'), icon: 'xmark.circle.fill', action: () => closeOthers(id) }]
              : []),
          ]
        : [{ label: L('열어 두기', 'Keep Open'), icon: 'pin', action: () => keepPaper(id, true) }]),
      { label: L('새 창으로 열기', 'Open in New Window'), icon: 'macwindow.badge.plus', action: () => openInWindow(id) },
      { separator: true },
      // The same answer the inspector asks for, where a handful of rows can
      // be corrected one after another — which is what a wrongly answered
      // import feels like. The one it already is is left out: a menu offering
      // what has already happened is a menu item that does nothing.
      ...([
        ['paper', L('논문으로 바꾸기', 'Make It a Paper'), 'text.document'],
        ['book', L('책으로 바꾸기', 'Make It a Book'), 'book'],
        ['lecture', L('강의자료로 바꾸기', 'Make It Course Material'), 'lecture'],
        ['document', L('일반 문서로 바꾸기', 'Make It a Document'), 'note'],
      ] as const)
        .filter(([value]) => value !== entry.meta.effectiveKind)
        .map(([value, label, glyph]) => ({
          label, icon: glyph, action: () => void setKind(id, value),
        })),
      { separator: true },
      { label: L('폴더에서 보기', 'Show in Folder'), icon: 'folder', action: () => void call('paper:reveal', { id }) },
      ...(isCitable(entry.meta.effectiveKind)
        ? [{ label: L('인용 키 복사', 'Copy Citation Key'), icon: 'doc.on.doc', action: () => copyKey(id) }]
        : []),
      { separator: true },
      {
        label: entry.state.isFavorite
          ? L('즐겨찾기에서 빼기', 'Remove from Favorites')
          : L('즐겨찾기에 더하기', 'Add to Favorites'),
        icon: 'star',
        action: async () => {
          await call('paper:state', { id, patch: { isFavorite: !entry.state.isFavorite } })
          await reload()
        },
      },
      { separator: true },
      {
        label: L('휴지통에 넣기', 'Move to Trash'),
        icon: 'trash',
        action: async () => {
          if (!confirm(L(
            `“${entry.meta.displayTitle}”\n\n라이브러리 휴지통에 넣을까요? 아무것도 지우지 않아요. PDF와 그 기록은 라이브러리 안 휴지통 폴더로 옮겨가요.`,
            `Move “${entry.meta.displayTitle}” to the library's Trash?\n\nThe PDF and its record move to the Trash folder inside the library. Nothing is deleted.`,
          ))) return
          await call('library:trash', { id })
          undock(id)
          closeOpenPaper(id)
          if (store.selectedID === id) store.selectedID = null
          await reload()
          reconcileReaders()
        },
      },
    ])
  },
  addPapers: () => void addPapers(),
  adoptLoose: async () => {
    const snapshot = await call<LibrarySnapshot>('library:adoptLoose')
    if ('error' in snapshot) return toast(String(snapshot.error))
    adopt(snapshot)
    changed('papers')
  },
})

/** The answer to "a paper, a book, course material, or a document?", from the
 *  inspector or the row's menu. */
async function setKind(id: string, kind: DocumentKind) {
  // Nothing but a paper has a registrar to disagree with, so nothing else
  // stays on the shelf of things to look at.
  const patch: Record<string, unknown> = { kind }
  if (!isLookedUp(kind)) patch.confidence = 'unparsed'
  // Nothing is cleared for course material or a document. A book clears the
  // journal's fields below because a book is exported and would print a
  // volume it never had; these two are not exported at all, so throwing away
  // what somebody typed would cost them something and buy nothing.
  if (kind === 'book') {
    // Called a book, it is written down as one — so the export says `@book`
    // and the citation prints a publisher rather than a journal. The
    // journal's own fields go, or a textbook prints as a volume and an issue
    // of a journal it was never in.
    const entry = findPaper(id)
    const csl = { ...(entry?.meta.csl ?? {}) } as Record<string, unknown>
    if (csl.type !== 'book' && csl.type !== 'chapter') csl.type = 'book'
    for (const key of ['container-title', 'container-title-short', 'volume', 'issue', 'page', 'ISSN']) {
      delete csl[key]
    }
    patch.csl = csl
  }
  await call('paper:meta', { id, patch })
  await reload()
}

/** Why a name was refused, in the reader's own language. */
const RENAME_TROUBLE = (): Record<string, string> => ({
  empty: L('이름을 적어주세요.', 'Type a name.'),
  notAName: L('이름에 «/»나 «:» 같은 글자는 쓸 수 없어요.',
    'A name cannot contain / \\ : * ? " < > or |.'),
  taken: L('같은 이름의 파일이 이미 있어요.', 'A file with that name is already there.'),
  missing: L('파일이 있던 자리에 없어요.', 'Paper Time cannot find the file.'),
})

const inspector = buildInspector({
  editMeta: async (id, patch) => {
    await call('paper:meta', { id, patch })
    await reload()
  },
  editState: async (id, patch) => {
    await call('paper:state', { id, patch })
    await reload()
  },
  reveal: (id) => void call('paper:reveal', { id }),
  rename: async (id, name) => {
    const result = await call('paper:rename', { id, name }) as { error?: string } | null
    if (result?.error) return RENAME_TROUBLE()[result.error] ?? null
    await reload()
    return null
  },
  copyKey,
  setKind,
  openAuthor: (name) => {
    store.shelf = { kind: 'author', name }
    changed('shelf')
  },
  sketchChanged: () => changed('sketch'),
})

// ------------------------------------------------------------ the page area

/**
 * The readers, one per paper in the page area. In the ordinary case that is
 * the one paper showing; with papers side by side, one per pane. A reader
 * whose paper leaves the page area is taken down, canvases and all.
 */
const readers = new Map<string, Reader>()
const pageArea = el('div', { class: 'page-area' })
const dockZone = el('div', { class: 'dock-zone', 'data-on': 'false' })
/** What the page area shows when nothing is open. */
const emptyReader = el('div', { class: 'panel reader-panel' }, [
  el('div', { class: 'reader-header' }),
  el('div', { class: 'reader-scroll' }),
])
pageArea.append(emptyReader, dockZone)

/** The reader in focus: the pane showing `store.selectedID`. */
function focused(): Reader | null {
  return store.selectedID ? readers.get(store.selectedID) ?? null : null
}

function readerFor(id: string, pane: boolean): Reader {
  const existing = readers.get(id)
  if (existing) return existing
  const reader = new Reader({
    changed: () => changed('sketch'),
    toast,
    activated: () => {
      // A press in a pane makes it the one in use: the pane in focus, and a
      // paper kept open.
      keepOpen(id)
      if (store.selectedID !== id) {
        store.selectedID = id
        void call('settings:set', { selectedPaperID: id })
        focusChanged()
        changed('papers', 'selection')
      } else {
        changed('papers')
      }
    },
    close: () => closePaper(id),
    fileName: () => {
      const paper = store.papers.find((p) => p.id === id)
      const relative = String((paper?.meta.file as Record<string, unknown> | undefined)?.relativePath ?? '')
      return relative.split(/[\\/]/).pop() ?? ''
    },
    guessed: (kind) => {
      // Only ever a guess, and only when nobody has one: the answer belongs
      // to the reader and is given in the inspector.
      const paper = store.papers.find((p) => p.id === id)
      if (!paper || paper.meta.guessedKind || paper.meta.kind) return
      paper.meta.guessedKind = kind
      void call('paper:meta', { id, patch: { guessedKind: kind } })
      changed('papers', 'inspector')
    },
  }, { pane })
  readers.set(id, reader)
  void loadInto(reader, id)
  return reader
}

async function loadInto(reader: Reader, id: string) {
  // Nothing in here may throw past this function: a rejected request reaching
  // the window as an unhandled rejection is a blank page with no sentence on
  // it, which is what a locked PDF used to look like.
  let result: {
    data?: Uint8Array
    error?: string
    locked?: PDFLock
    trouble?: ByteTrouble
    size?: number
  }
  try {
    result = await call('paper:bytes', { id })
  } catch (error) {
    console.error('paper:bytes failed', error)
    result = { error: L('이 논문의 PDF를 읽지 못했어요.', "Paper Time couldn't read this paper's PDF.") }
  }
  if (!readers.has(id) || readers.get(id) !== reader) return
  if (result.locked) return reader.showLocked(result.locked)
  // Bytes that are not a PDF at all never reach pdf.js: it would answer with
  // the same six words for every one of them, and the reader can say which.
  if (!result.data && result.trouble) {
    return reader.showTrouble(result.trouble, result.size ?? 0, () => void loadInto(reader, id))
  }
  if (result.error || !result.data) return toast(result.error ?? 'unknown error')
  await reader.open(id, new Uint8Array(result.data), {
    trouble: result.trouble,
    size: result.size,
    again: () => void loadInto(reader, id),
  })
  reader.setDrawing(reader.state.drawing)
  reader.update()
  if (focused() === reader) focusChanged()
}

/**
 * Makes the readers match the arrangement: one per paper in the page area,
 * laid out as the arrangement says, the one in focus marked and given the
 * rack. Everything that changes what is in the page area ends here.
 */
function reconcileReaders() {
  const wanted = panePapers()
  const split = store.split
  const previous = focused()
  // A reader keeps its pen state across a change of arrangement — but one
  // built for a pane and one built for the whole area differ in chrome, so
  // the readers are rebuilt when the arrangement appears or goes.
  for (const [id, reader] of [...readers]) {
    if (!wanted.includes(id) || reader.isPane !== Boolean(split)) {
      const drawing = reader.state.drawing
      reader.dispose()
      readers.delete(id)
      if (wanted.includes(id)) inheritedDrawing.set(id, drawing)
    }
  }
  for (const id of wanted) {
    const reader = readerFor(id, Boolean(split))
    const drawing = inheritedDrawing.get(id) ?? (previous && !readers.has(previous.paperID ?? '') ? previous.state.drawing : undefined)
    if (drawing !== undefined) {
      reader.state.drawing = drawing
      inheritedDrawing.delete(id)
    }
  }

  clear(pageArea)
  if (split) {
    const column = (ids: string[]) => el('div', { class: 'split-column' }, ids.map((id) => readerFor(id, true).node))
    const grid = el('div', { class: 'split' }, [column(columnIDs(split, 'left'))])
    if (split.right) grid.append(column(columnIDs(split, 'right')))
    pageArea.append(grid)
  } else if (wanted[0]) {
    pageArea.append(readerFor(wanted[0], false).node)
  } else {
    pageArea.append(emptyReader)
  }
  pageArea.append(dockZone)
  focusChanged()
  for (const reader of readers.values()) reader.relayout()
}

const inheritedDrawing = new Map<string, boolean>()

function columnIDs(split: SplitArrangement, side: 'left' | 'right'): string[] {
  const column = side === 'left' ? split.left : split.right
  if (!column) return []
  return column.bottom ? [column.top, column.bottom] : [column.top]
}

/**
 * The pane in focus is the paper the window is about: its state is the
 * store's, the rack sits over it, the drawing editor is its own.
 */
function focusChanged() {
  const reader = focused()
  for (const [id, other] of readers) other.setFocused(id === store.selectedID && Boolean(store.split))
  if (reader) {
    if (store.reader !== reader.state) {
      store.reader = reader.state
      store.sketch.selection = null
    }
    reader.overlayContainer.append(rack.node)
    if (reader.state.drawing) reader.setDrawing(true)
    else if (sketchEditor.current) sketchEditor.current = null
  } else {
    store.reader = { pageCount: 0, currentPage: 0, zoom: 1, drawing: false }
    sketchEditor.current = null
  }
  refreshOpenPapers()
}

// ---------------------------------------------------------- open papers

/** Keeps a paper on the open shelf without changing what is showing. */
function keepPaper(id: string, byHand = false) {
  keepOpen(id, byHand)
  changed('papers')
}

/** Closes a paper: out of its pane, off the shelf; its neighbour comes forward. */
function closePaper(id: string) {
  const wasSelected = store.selectedID === id
  undock(id)
  closeOpenPaper(id)
  if (wasSelected && store.selectedID && store.selectedID !== id && !store.travelling) remember(store.selectedID)
  void call('settings:set', { selectedPaperID: store.selectedID })
  reconcileReaders()
  changed('papers', 'selection')
}

function closeOthers(keeping: string) {
  for (const other of store.openPaperIDs) if (other !== keeping) undock(other)
  closeOtherOpenPapers(keeping)
  void call('settings:set', { selectedPaperID: store.selectedID })
  reconcileReaders()
  changed('papers', 'selection')
}

/** Puts a paper into a zone of the page area, beside what is showing. */
function dockPaper(id: string, zone: DockZone) {
  if (!findPaper(id)) return
  dock(id, zone)
  reconcileReaders()
  changed('papers', 'selection')
}

function openInWindow(id: string, at?: { x: number; y: number }) {
  keepOpen(id)
  changed('papers')
  void call('paper:openWindow', { id, x: at?.x, y: at?.y })
}

async function insideOurWindows(x: number, y: number): Promise<boolean> {
  const bounds = await call<WindowBounds[]>('window:bounds')
  return bounds.some((b) => x >= b.x && x <= b.x + b.width && y >= b.y && y <= b.y + b.height)
}

/** Every page of what is showing, small — the way into a document that has
 *  no headings to list. */
function showPagesPopup() {
  const reader = focused()
  if (!reader) return
  togglePages(pageArea, {
    pageCount: () => reader.pages_count,
    currentPage: () => Math.max(0, reader.state.currentPage - 1),
    draw: (index, width) => reader.thumbnail(index, width),
    go: (index) => reader.scrollToPage(index),
  })
}

function showOpenPapersPopup() {
  toggleOpenPapers(pageArea, {
    show: (id) => {
      void showPaper(id)
      keepPaper(id)
    },
    close: (id) => closePaper(id),
    openWindow: (id, at) => openInWindow(id, at),
    insideOurWindows,
  })
}

// ------------------------------------------------------------- drop zones

/**
 * A paper dragged over the page area — a row of the list, a pane's title, a
 * row of the popup — lights the half or the quarter it would go into, and
 * goes there when dropped. The middle of the page is no zone at all.
 */
let litZone: DockZone | null = null

function lightZone(zone: DockZone | null) {
  litZone = zone
  if (!zone) {
    dockZone.dataset.on = 'false'
    return
  }
  const size = { width: pageArea.clientWidth, height: pageArea.clientHeight }
  const rect = zoneRect(zone, size)
  dockZone.style.left = `${rect.x}px`
  dockZone.style.top = `${rect.y}px`
  dockZone.style.width = `${rect.width}px`
  dockZone.style.height = `${rect.height}px`
  dockZone.dataset.on = 'true'
}

function carriesPaper(event: DragEvent): boolean {
  return Boolean(event.dataTransfer && [...event.dataTransfer.types].includes(PAPER_DRAG_TYPE))
}

on(pageArea, 'dragover', (event: DragEvent) => {
  if (!carriesPaper(event)) return
  event.preventDefault()
  event.stopPropagation()
  const box = pageArea.getBoundingClientRect()
  const zone = zoneAt(event.clientX - box.left, event.clientY - box.top, { width: box.width, height: box.height })
  if (event.dataTransfer) event.dataTransfer.dropEffect = zone ? 'move' : 'none'
  if (zone !== litZone) lightZone(zone)
})
on(pageArea, 'dragleave', (event: DragEvent) => {
  if (!pageArea.contains(event.relatedTarget as Node | null)) lightZone(null)
})
on(pageArea, 'drop', (event: DragEvent) => {
  if (!carriesPaper(event)) return
  event.preventDefault()
  event.stopPropagation()
  const id = event.dataTransfer?.getData(PAPER_DRAG_TYPE)
  const box = pageArea.getBoundingClientRect()
  const zone = zoneAt(event.clientX - box.left, event.clientY - box.top, { width: box.width, height: box.height })
  lightZone(null)
  if (!id || !zone) return
  closeOpenPapers()
  dockPaper(id, zone)
})
// A drag cancelled with Escape, or let go outside the window, sends no
// leave; the highlight is cleared when the drag ends, and whenever the mouse
// is found with no button down.
on(window, 'dragend', () => lightZone(null))
on(window, 'mousemove', (event: MouseEvent) => {
  if (litZone && event.buttons === 0) lightZone(null)
})

// -------------------------------------------------------- the drawing layer

/**
 * The rack picks the tool and works the undo stack; everything that acts on
 * the selection goes through `sketchEditor.current`, the view over the page
 * that holds it (`sketchInput.ts`), so the rack, the Tools tab and the keys
 * below are three ways of saying the same thing to one place.
 */
const rack = buildSketchRack({
  setTool: (tool: SketchTool) => pickTool(tool),
  undo: () => applyUndo(false),
  redo: () => applyUndo(true),
})

function pickTool(tool: SketchTool) {
  setSketchTool(tool)
  changed('sketch')
}

function selectedPage() {
  const selection = store.sketch.selection
  if (!selection) return null
  return focused()?.pages[selection.pageIndex] ?? null
}

// -------------------------------------------------------------- the toolbar

const toolbar = buildToolbar({
  togglePane: (pane: Pane) => togglePane(pane),
  back: () => goBack(),
  forward: () => goForward(),
  search: () => openSearch(),
  addPapers: () => void addPapers(),
  setInspectorTab: (tab: InspectorTab) => {
    store.settings.inspectorTab = tab
    void call('settings:set', { inspectorTab: tab })
    changed('inspector')
  },
  moreMenu: (anchor) => {
    showMenu(anchor, [
      { label: L('폴더에서 새로 읽기', 'Refresh Folder'), icon: 'arrow.clockwise', action: () => void reload() },
      { label: L('라이브러리 폴더 고르기…', 'Choose Library Folder…'), icon: 'folder', action: () => void chooseLibrary() },
      { separator: true },
      { caption: L('정렬 기준', 'Sort By') },
      ...(['title', 'author', 'year', 'added', 'opened'] as const).map((field) => ({
        label: {
          title: L('제목', 'Title'),
          author: L('저자', 'Author'),
          year: L('해', 'Year'),
          added: L('더한 날', 'Date Added'),
          opened: L('마지막으로 연 날', 'Last Opened'),
        }[field],
        checked: store.settings.sort.field === field,
        action: () => setSort(field, store.settings.sort.ascending),
      })),
      {
        label: L('오름차순', 'Ascending'),
        checked: store.settings.sort.ascending,
        action: () => setSort(store.settings.sort.field, !store.settings.sort.ascending),
      },
      { separator: true },
      { caption: L('쪽 배치', 'Page Layout') },
      ...(['continuous', 'single'] as const).map((layout) => ({
        label: { continuous: L('이어서 보기', 'Continuous'), single: L('한 쪽씩 보기', 'Single Page') }[layout],
        checked: store.settings.pageLayout === layout,
        action: () => setLayout(layout),
      })),
      { separator: true },
      { caption: L('쪽 색조', 'Page Tint') },
      ...(['none', 'sepia', 'grey', 'night'] as const).map((tint) => ({
        label: { none: L('없음', 'None'), sepia: L('세피아', 'Sepia'), grey: L('회색', 'Grey'), night: L('밤', 'Night') }[tint],
        checked: store.settings.pageTint === tint,
        action: () => {
          store.settings.pageTint = tint
          void call('settings:set', { pageTint: tint })
          for (const reader of readers.values()) reader.applyTint()
        },
      })),
      { separator: true },
      { caption: L('화면 모드', 'Appearance') },
      ...(['system', 'light', 'dark'] as const).map((appearance) => ({
        label: { system: L('시스템에 따라', 'System'), light: L('밝게', 'Light'), dark: L('어둡게', 'Dark') }[appearance],
        checked: store.settings.appearance === appearance,
        action: () => {
          store.settings.appearance = appearance
          void call('settings:set', { appearance })
          applyTheme()
        },
      })),
    ], 'right')
  },
  minimize: () => void call('window:minimize'),
  toggleMaximize: () => void call('window:toggleMaximize'),
  close: () => void call('window:close'),
})

root.append(toolbar.node, panes)

// ------------------------------------------------------- laying out the panes

/** Which panes were on screen last time, so only a new one is seen arriving. */
let panesShown = new Set<Pane>()

function layoutPanes() {
  clear(panes)
  if (solo) {
    // One paper, and nothing else: the reader fills the window.
    pageArea.style.flex = '1 1 auto'
    panes.append(pageArea)
    return
  }
  const visible = store.settings.panes
  const pieces: { pane: Pane; node: HTMLElement; width?: number; resizes?: 'leading' | 'trailing' }[] = []
  if (visible.sidebar) pieces.push({ pane: 'sidebar', node: sidebar.node, width: store.settings.columns.sidebar })
  if (visible.paperList) pieces.push({ pane: 'paperList', node: paperList.node, width: store.settings.columns.paperList })
  if (visible.reader) pieces.push({ pane: 'reader', node: pageArea })
  if (visible.inspector) {
    pieces.push({ pane: 'inspector', node: inspector.node, width: store.settings.columns.inspector, resizes: 'trailing' })
  }

  // A pane that was not here a moment ago comes in; the ones that were stay
  // put. Laying them out re-appends every pane, so without this the whole
  // window flinched whenever one of them was opened.
  const arriving = new Set(pieces.map((piece) => piece.pane).filter((pane) => !panesShown.has(pane)))
  panesShown = new Set(pieces.map((piece) => piece.pane))

  pieces.forEach((piece, index) => {
    if (piece.width) {
      piece.node.style.flex = `0 0 ${piece.width}px`
      piece.node.style.width = `${piece.width}px`
    } else {
      piece.node.style.flex = '1 1 auto'
      piece.node.style.width = ''
    }
    piece.node.classList.toggle('pane-arriving', arriving.has(piece.pane))
    panes.append(piece.node)
    const next = pieces[index + 1]
    if (!next) return
    // The divider resizes the fixed column beside it. The inspector is to the
    // right of its own, so the same drag has to make it narrower — without
    // this it grew when the pointer went the other way, which is the one thing
    // a divider must never do.
    const resizesNext = next.resizes === 'trailing'
    const target = resizesNext ? next : piece
    if (!target.width) return
    panes.append(divider(target.pane as 'sidebar' | 'paperList' | 'inspector', resizesNext))
  })
}

function relayoutReaders() {
  for (const reader of readers.values()) reader.relayout()
}

function divider(pane: 'sidebar' | 'paperList' | 'inspector', inverted: boolean): HTMLElement {
  const node = el('div', { class: 'divider' })
  on(node, 'pointerdown', (event: PointerEvent) => {
    event.preventDefault()
    node.setPointerCapture(event.pointerId)
    node.classList.add('dragging')
    const startX = event.clientX
    const startWidth = store.settings.columns[pane]
    // One column gets wider; nothing else about the window changes. Every
    // move used to lay out all four panes again — which took the divider
    // being dragged out of the window and put a new one in its place, and
    // relaid out every page of the paper — sixty times a second.
    let frame = 0
    const settle = () => {
      frame = 0
      const column = paneNode(pane)
      const width = store.settings.columns[pane]
      column.style.flex = `0 0 ${width}px`
      column.style.width = `${width}px`
      relayoutReaders()
    }
    const move = (moved: PointerEvent) => {
      const travel = inverted ? startX - moved.clientX : moved.clientX - startX
      const widest = Math.max(320, panes.clientWidth - 300)
      store.settings.columns[pane] = Math.min(Math.max(startWidth + travel, 180), widest)
      if (!frame) frame = requestAnimationFrame(settle)
    }
    const up = () => {
      if (frame) cancelAnimationFrame(frame)
      settle()
      node.classList.remove('dragging')
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      void call('settings:set', { columns: store.settings.columns })
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  })
  return node
}

/** The panel a column's name stands for. */
function paneNode(pane: 'sidebar' | 'paperList' | 'inspector'): HTMLElement {
  if (pane === 'sidebar') return sidebar.node
  if (pane === 'paperList') return paperList.node
  return inspector.node
}

function togglePane(pane: Pane) {
  if (solo) return
  store.settings.panes[pane] = !store.settings.panes[pane]
  void call('settings:set', { panes: store.settings.panes })
  layoutPanes()
  toolbar.update()
  relayoutReaders()
}

// ------------------------------------------------------------------ actions

async function chooseLibrary() {
  const chosen = await call<string | null>('library:choose')
  if (!chosen) return
  const snapshot = await call<LibrarySnapshot>('library:open', { root: chosen })
  if ('error' in snapshot) return toast(String(snapshot.error))
  adopt(snapshot)
  changed('papers', 'shelf')
}

async function addPapers() {
  const snapshot = await call<LibrarySnapshot>('library:import', {})
  if ('error' in snapshot) return toast(String(snapshot.error))
  adopt(snapshot)
  changed('papers')
}

async function reload() {
  const snapshot = await call<LibrarySnapshot>('library:reload')
  if ('error' in snapshot) return
  const selected = store.selectedID
  adopt(snapshot)
  store.selectedID = selected
  // Papers gone from the folder leave the shelf and the page area.
  store.openPaperIDs = store.openPaperIDs.filter((id) => findPaper(id))
  for (const id of panePapers()) if (!findPaper(id)) undock(id)
  if (store.selectedID && !findPaper(store.selectedID)) store.selectedID = null
  reconcileReaders()
  changed('papers')
  for (const reader of readers.values()) reader.update()
}

/**
 * Shows a paper. Not kept: what is merely shown is a preview on the open
 * shelf and leaves when the next is shown. Clicking into it, pinning it, or
 * putting it beside another keeps it.
 *
 * With papers side by side, the paper takes the place of the pane in focus,
 * so the arrangement keeps its shape.
 */
async function showPaper(id: string) {
  if (store.selectedID === id) return
  const previous = store.selectedID
  if (store.split && !splitContains(store.split, id)) {
    const target = previous && splitContains(store.split, previous) ? previous : splitPapers(store.split)[0]
    store.split = replaceInSplit(store.split, target, id)
  }
  store.selectedID = id
  if (!store.travelling) remember(id)
  void call('settings:set', { selectedPaperID: id })
  void call('paper:state', { id, patch: { lastOpenedAt: new Date().toISOString(), readingStatus: statusOnOpen(id) } })
  reconcileReaders()
  changed('papers', 'selection', 'reader')
}

function replaceInSplit(split: SplitArrangement, from: string, to: string): SplitArrangement {
  const swap = (column: { top: string; bottom?: string } | undefined) => column && {
    top: column.top === from ? to : column.top,
    ...(column.bottom ? { bottom: column.bottom === from ? to : column.bottom } : {}),
  }
  return { left: swap(split.left)!, right: swap(split.right) }
}

function statusOnOpen(id: string): string {
  const entry = findPaper(id)
  return entry?.state.readingStatus === 'unread' ? 'reading' : (entry?.state.readingStatus ?? 'reading')
}

/**
 * Back and forward walk the papers you have opened, the way a browser walks
 * pages: going back and then opening something else forgets what lay ahead.
 */
function goBack() {
  if (!canGoBack()) return
  const id = travel(store.trailIndex - 1)
  if (!id) return
  store.travelling = true
  void showPaper(id).finally(() => { store.travelling = false })
}

function goForward() {
  if (!canGoForward()) return
  const id = travel(store.trailIndex + 1)
  if (!id) return
  store.travelling = true
  void showPaper(id).finally(() => { store.travelling = false })
}

/**
 * The paper and nothing else — and the way back.
 *
 * What it hid has to be remembered, or leaving focus mode means putting three
 * columns back by hand. Leaving restores exactly what was open on the way in.
 */
let beforeFocus: typeof store.settings.panes | null = null

function toggleFocus() {
  if (solo) return
  if (beforeFocus) {
    store.settings.panes = { ...beforeFocus }
    beforeFocus = null
  } else {
    beforeFocus = { ...store.settings.panes }
    store.settings.panes = { sidebar: false, paperList: false, reader: true, inspector: false }
  }
  void call('settings:set', { panes: store.settings.panes })
  layoutPanes()
  toolbar.update()
  relayoutReaders()
}

function setLayout(layout: 'single' | 'continuous') {
  store.settings.pageLayout = layout
  for (const reader of readers.values()) reader.setLayout(layout)
  void call('settings:set', { pageLayout: layout })
}

function setSort(field: typeof store.settings.sort.field, ascending: boolean) {
  store.settings.sort = { field, ascending }
  void call('settings:set', { sort: store.settings.sort })
  changed('papers')
}

async function copyKey(id: string) {
  const entry = findPaper(id)
  if (!entry) return
  await navigator.clipboard.writeText(entry.meta.bibKey || entry.meta.displayTitle)
  toast(L('인용 키를 복사했어요', 'Citation key copied'))
}

/**
 * ⌘W: with papers side by side, closes the pane in focus and leaves the
 * window standing. With one pane the window closes, as it always did.
 */
function closeWindowOrPane() {
  if (store.split && store.selectedID && splitContains(store.split, store.selectedID)) {
    closePaper(store.selectedID)
    return
  }
  void call('window:close')
}

// ------------------------------------------------------------------- search

let palette: HTMLElement | null = null

function openSearch() {
  if (palette) return closeSearch()
  const input = el('input', { type: 'text', placeholder: L('논문 찾기…', 'Search papers…'), spellcheck: 'false' }) as HTMLInputElement
  const results = el('div', { class: 'results' })
  const box = el('div', { class: 'palette' }, [input, results])
  const scrim = el('div', { class: 'scrim' })
  on(scrim, 'mousedown', closeSearch)

  const render = () => {
    clear(results)
    const query = input.value.trim().toLowerCase()
    if (!query) return
    const matches = store.papers
      .filter((entry) =>
        entry.meta.displayTitle.toLowerCase().includes(query) ||
        entry.meta.displayAuthors.toLowerCase().includes(query) ||
        (entry.meta.venue ?? '').toLowerCase().includes(query) ||
        entry.meta.bibKey.toLowerCase().includes(query))
      .slice(0, 40)
    for (const entry of matches) {
      const row = el('div', { class: 'paper-row' }, [
        el('span', { class: 'paper-status', html: icon('text.page') }),
        el('div', { class: 'paper-main' }, [
          el('div', { class: 'paper-title', text: entry.meta.displayTitle }),
          el('div', { class: 'paper-subtitle', text: [entry.meta.displayAuthors, entry.meta.year].filter(Boolean).join(' · ') }),
        ]),
      ])
      on(row, 'click', () => {
        closeSearch()
        void showPaper(entry.id)
      })
      results.append(row)
    }
  }

  on(input, 'input', render)
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Escape') closeSearch()
    if (event.key === 'Enter') {
      const first = results.querySelector('.paper-row') as HTMLElement | null
      first?.click()
    }
  })
  document.body.append(scrim, box)
  palette = box
  ;(box as unknown as { scrim: HTMLElement }).scrim = scrim
  input.focus()
}

function closeSearch() {
  if (!palette) return
  ;(palette as unknown as { scrim: HTMLElement }).scrim?.remove()
  palette.remove()
  palette = null
}

// ------------------------------------------------------------------- keys

on(window, 'keydown', (event: KeyboardEvent) => {
  const target = event.target as HTMLElement | null
  const typing = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')
  const reader = focused()

  // While the pen is out the page's own editor has the Mac's whole key map
  // — Escape's three steps, the arrows, ⌘C/⌘X/⌘V, Enter into a group — and
  // it goes first. What it does not take falls through to the keys below.
  if (store.reader.drawing && !palette) {
    const current = sketchEditor.current as SketchInputEditing | null
    if (current && typeof current.handleKey === 'function' && !(typing && event.key !== 'Escape') && current.handleKey(event)) {
      event.preventDefault()
      return
    }
  }

  if (event.key === 'Escape') {
    // Three steps back, in the order a hand expects: finish the words, then
    // drop the selection, then put the tool away.
    if (palette) return closeSearch()
    if (isOpenPapersShowing()) return closeOpenPapers()
    if (store.sketch.selection) {
      store.sketch.selection = null
      reader?.redrawAll()
      return changed('sketch')
    }
    if (store.sketch.tool !== 'select') {
      setSketchTool('select')
      return changed('sketch')
    }
    if (store.reader.drawing && reader) {
      reader.setDrawing(false)
      reader.update()
      return changed('sketch')
    }
    return
  }

  if (typing) return

  const editor = sketchEditor.current

  if (isCommand(event)) {
    // ⇧⌘O: the open papers, over the page. ⌘W: the pane in focus, or the
    // window. Both are menu items too; these catch the key where a desktop
    // hands it to the page first.
    if (event.shiftKey && event.key.toLowerCase() === 'o') {
      event.preventDefault()
      showOpenPapersPopup()
      return
    }
    if (event.key.toLowerCase() === 'w' && !event.shiftKey && !event.altKey) {
      if (store.split) {
        event.preventDefault()
        closeWindowOrPane()
      }
      return
    }
    if (event.key === 'z') {
      event.preventDefault()
      applyUndo(event.shiftKey)
      return
    }
    if (!store.reader.drawing) return
    // Figma's keys for the tree, on the selection the page holds.
    if (event.key.toLowerCase() === 'g') {
      event.preventDefault()
      if (event.altKey) editor?.frameSelection()
      else if (event.shiftKey) editor?.ungroupSelection()
      else editor?.groupSelection()
      return
    }
    if (event.key.toLowerCase() === 'd') {
      event.preventDefault()
      editor?.duplicateSelection()
      return
    }
    if (event.key === 'a' || event.key === 'A') {
      event.preventDefault()
      editor?.selectAllOnPage()
      return
    }
    if (event.shiftKey && (event.code === 'BracketRight' || event.key === ']' || event.key === '}')) {
      event.preventDefault()
      editor?.bringSelectionToFront()
      return
    }
    if (event.shiftKey && (event.code === 'BracketLeft' || event.key === '[' || event.key === '{')) {
      event.preventDefault()
      editor?.sendSelectionToBack()
      return
    }
    return
  }

  if (event.key === 'Delete' || event.key === 'Backspace') {
    if (store.sketch.selection) {
      event.preventDefault()
      editor?.deleteSelection()
    }
    return
  }

  if (store.settings.pageLayout === 'single' && !store.reader.drawing && reader) {
    if (event.key === 'PageDown' || event.key === 'ArrowRight') {
      event.preventDefault()
      return reader.turnPage(1)
    }
    if (event.key === 'PageUp' || event.key === 'ArrowLeft') {
      event.preventDefault()
      return reader.turnPage(-1)
    }
  }

  if (store.reader.drawing) {
    if (event.altKey) return
    // ⇧A is auto layout before A is the arrow tool.
    if (event.shiftKey && event.key === 'A') {
      event.preventDefault()
      editor?.toggleAutoLayout()
      return
    }
    if (event.shiftKey) return
    const tool = TOOLS.find((entry) => entry.key.toLowerCase() === event.key.toLowerCase())
    if (tool) {
      event.preventDefault()
      return pickTool(tool.tool)
    }
    if (event.key.toLowerCase() === 'b') {
      event.preventDefault()
      editor?.frameSelection()
      return
    }
    if (event.key === 'Enter' && store.sketch.selection) {
      event.preventDefault()
      editor?.editSelectedText()
      return
    }
    if (event.key.startsWith('Arrow') && store.sketch.selection) {
      event.preventDefault()
      nudge(event.key, event.shiftKey ? 10 : 1)
      return
    }
  }
})

function nudge(key: string, distance: number) {
  const page = selectedPage()
  const selection = store.sketch.selection
  const reader = focused()
  if (!page || !selection || !reader) return
  const offset = {
    ArrowLeft: { x: -distance, y: 0 },
    ArrowRight: { x: distance, y: 0 },
    // The page's y goes up, so up on the keyboard is up on the page.
    ArrowUp: { x: 0, y: distance },
    ArrowDown: { x: 0, y: -distance },
  }[key]
  if (!offset) return
  const moving = expandedIDs(page.elements, selection.ids)
  page.elements = page.elements.map((element) =>
    moving.has(element.id) ? element.translated(offset) : element)
  page.redraw()
  void reader.save(page)
}

function applyUndo(redo: boolean) {
  const snapshot = redo ? undoStack.redo() : undoStack.undo()
  if (!snapshot) return
  // A step may cover two pages — a selection carried from one to the other.
  focused()?.restore(snapshot)
  store.sketch.selection = null
  changed('sketch')
}

// ------------------------------------------------------------------ theme

function applyTheme() {
  const choice = store.settings.appearance
  if (choice === 'system') {
    document.documentElement.removeAttribute('data-theme')
    document.documentElement.setAttribute(
      'data-theme',
      window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
    )
  } else {
    document.documentElement.setAttribute('data-theme', choice)
  }
}

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (store.settings.appearance === 'system') applyTheme()
})

// ------------------------------------------------------------- redrawing

let wasDrawing = false

subscribe((keys) => {
  if (keys.has('papers') || keys.has('shelf') || keys.has('selection')) {
    sidebar.update()
    paperList.update()
    inspector.update()
    refreshOpenPapers()
  }
  if (keys.has('inspector')) inspector.update()
  if (keys.has('sketch')) {
    // Picking up the pen brings the Tools tab forward, as it does on the Mac;
    // putting it down leaves the tab where it is.
    if (store.reader.drawing && !wasDrawing && store.settings.inspectorTab !== 'tools') {
      store.settings.inspectorTab = 'tools'
      void call('settings:set', { inspectorTab: 'tools' })
    }
    wasDrawing = store.reader.drawing
    rack.update()
    if (store.settings.inspectorTab === 'tools') inspector.update()
    const reader = focused()
    reader?.redrawAll()
    reader?.update()
  }
  if (keys.has('reader')) focused()?.update()
  toolbar.update()
})

// --------------------------------------------------------- events from main

onEvent((event, payload) => {
  switch (event) {
    case 'menu:feedback':
      void showFeedback()
      break
    case 'library:changed':
      void reload()
      break
    case 'library:opened':
      adopt(payload as LibrarySnapshot)
      changed('papers', 'shelf')
      break
    case 'window:state':
      store.windowState = payload as typeof store.windowState
      toolbar.update()
      break
    case 'theme:changed':
      if (store.settings.appearance === 'system') applyTheme()
      break
    case 'paper:saved':
      break
    case 'menu':
      runMenuCommand(String(payload))
      break
    case 'error':
      toast(String(payload))
      break
  }
})

function runMenuCommand(command: string) {
  const reader = focused()
  switch (command) {
    case 'addPapers': void addPapers(); break
    case 'refreshFolder': void reload(); break
    case 'addFolder': addLibraryFolder(); break
    case 'searchEverything': openSearch(); break
    case 'sidebar': togglePane('sidebar'); break
    case 'paperList': togglePane('paperList'); break
    case 'reader': togglePane('reader'); break
    case 'inspector': togglePane('inspector'); break
    case 'back': goBack(); break
    case 'forward': goForward(); break
    case 'zoomIn': reader?.zoomBy(1.15); break
    case 'zoomOut': reader?.zoomBy(1 / 1.15); break
    case 'actualSize': reader?.setZoom(1); break
    case 'draw':
      if (!reader) break
      reader.setDrawing(!reader.state.drawing)
      reader.update()
      changed('sketch')
      break
    case 'highlight':
      if (!reader?.markSelection('highlight')) toast(L('먼저 글을 골라주세요.', 'Select some text first.'))
      break
    case 'underline':
      if (!reader?.markSelection('underline')) toast(L('먼저 글을 골라주세요.', 'Select some text first.'))
      break
    case 'exportBibTeX':
      void (async () => {
        const result = await call<{ written?: number; error?: string; cancelled?: boolean }>(
          'bibtex:export', { ids: shelfPapers().map((entry) => entry.id) },
        )
        if (result.cancelled) return
        if (result.error) return toast(result.error)
        toast(L(
          `${result.written}편을 내보냈어요`,
          `Exported ${result.written} ${result.written === 1 ? 'entry' : 'entries'}`,
        ))
      })()
      break
    case 'copyCitationKey':
      if (store.selectedID) void copyKey(store.selectedID)
      break
    case 'focus': toggleFocus(); break
    case 'layoutContinuous': setLayout('continuous'); break
    case 'layoutSinglePage': setLayout('single'); break
    case 'openPapers': if (!solo) showOpenPapersPopup(); break
    case 'pages': showPagesPopup(); break
    case 'openInNewWindow': if (store.selectedID) openInWindow(store.selectedID); break
    case 'closeWindow': closeWindowOrPane(); break
    default:
      toast(L(`“${command}”은 아직 이 빌드에 없어요.`, `“${command}” is not in this build yet.`))
  }
}

// ---------------------------------------------------------------- dropping

on(window, 'dragover', (event: DragEvent) => {
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = carriesPaper(event) ? 'none' : 'copy'
})

on(window, 'drop', async (event: DragEvent) => {
  event.preventDefault()
  const files = [...(event.dataTransfer?.files ?? [])]
    .map((file) => (file as File & { path?: string }).path)
    .filter((path): path is string => Boolean(path) && path.toLowerCase().endsWith('.pdf'))
  if (files.length === 0) return
  const snapshot = await call<LibrarySnapshot>('library:import', { paths: files })
  if ('error' in snapshot) return toast(String(snapshot.error))
  adopt(snapshot)
  changed('papers')
})

on(window, 'resize', () => relayoutReaders())

// ------------------------------------------------------------------- start

async function start() {
  const saved = await call<typeof store.settings & { libraryRoot: string | null }>('settings:get')
  Object.assign(store.settings, saved)
  applyTheme()
  layoutPanes()
  toolbar.update()
  store.windowState = await call('window:state')

  if (saved.libraryRoot) {
    const snapshot = await call<LibrarySnapshot>('library:reload')
    if (!('error' in snapshot)) {
      adopt(snapshot)
      changed('papers', 'shelf')
      if (solo) {
        // A window for one paper: that paper, kept, and nothing else.
        if (findPaper(soloPaperID!)) {
          keepOpen(soloPaperID!)
          await showPaper(soloPaperID!)
          document.title = findPaper(soloPaperID!)?.meta.displayTitle ?? 'Paper Time'
        }
        return
      }
      const first = saved.selectedPaperID && findPaper(saved.selectedPaperID)
        ? saved.selectedPaperID
        : shelfPapers()[0]?.id
      if (first) await showPaper(first)
      // `--papertime-split=1`: the first two papers side by side, for a
      // probe that wants to look at the panes without a drag.
      if (flags.split) {
        const second = shelfPapers().find((entry) => entry.id !== store.selectedID)
        if (second) dockPaper(second.id, 'right')
      }
    }
  } else {
    changed('papers')
  }
}

void start()
