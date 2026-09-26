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
import { call, droppedPaths, flags, isCommand, onEvent, platform, soloPaperID } from './bridge.js'
import { clear, el, on } from './dom.js'
// Imported for its side effect: the sheet registers its own ⌥⌘/ so nothing
// in the shell has to know it exists.
import { showFeedback } from './ui/feedback.js'
import { showSettings, type SettingsSection } from './ui/settings.js'
import { askForName } from './ui/ask.js'
import { showAttachSheet } from './ui/attachSheet.js'
import { showExportSheet } from './ui/exportSheet.js'
import {
  adopt,
  attachmentsOf,
  canGoBack,
  canGoForward,
  changed,
  closeOpenPaper,
  closeOtherOpenPapers,
  dock,
  failed,
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
  textSources,
  travel,
  undock,
  type InspectorTab,
  type Pane,
  type Shelf,
  type SketchTool,
} from './state.js'
import { buildToolbar, showMenu, toast, type MenuEntry } from './ui/toolbar.js'
import { buildSidebar } from './ui/sidebar.js'
import { buildPaperList } from './ui/paperList.js'
import { buildInspector } from './ui/inspector.js'
import { Reader, type ReaderPlace } from './ui/reader.js'
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
import { closePalette, isPaletteOpen, openPalette } from './ui/search.js'
import { FindBar } from './ui/findBar.js'
import { handleTextEvent, searchText, type TextHit } from './textSearch.js'
import { asTextHit, handleMeaningEvent, meaningStatus, searchMeaning } from './meaningSearch.js'
import { graphemes } from '../shared/textFold.js'
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
import { PAGE_TINTS, tintLabel } from '../shared/pageTint.js'
import { passageText, quotationSource } from '../shared/noteQuote.js'
import { entryFor } from '../shared/bibtex.js'

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
    // A sheet of the window's own: `window.prompt` throws in Electron, so
    // this row used to do nothing at all.
    const name = await askForName({
      title: L('새 컬렉션', 'New Collection'),
      placeholder: L('컬렉션 이름', 'Collection Name'),
      confirm: L('만들기', 'Create'),
    })
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
  clearSearch: () => clearSearchResults(),
  revealFolder: (root: string) => void call('library:revealFolder', { root }),
  file: (paperID: string, shelf: Shelf) => void fileUnder(paperID, shelf),
})

/**
 * A paper dropped on a sidebar row, filed under it — the Mac's `dropTarget`s:
 * a reading status, the favourites, a collection, a tag. Nothing else takes
 * a drop, and a paper already there is left as it is.
 */
async function fileUnder(paperID: string, shelf: Shelf) {
  const entry = findPaper(paperID)
  if (!entry) return
  switch (shelf.kind) {
    case 'status':
      if (entry.state.readingStatus !== shelf.status) await setStatus(paperID, shelf.status)
      return
    case 'favorites':
      if (!entry.state.isFavorite) await setFavorite(paperID, true)
      return
    case 'collection': {
      const collection = store.collections.find((one) => one.id === shelf.id)
      if (!collection || collection.rule || entry.meta.collectionIDs.includes(shelf.id)) return
      await call('paper:meta', { id: paperID, patch: { collectionIDs: [...entry.meta.collectionIDs, shelf.id] } })
      await reload()
      toast(L(`“${collection.name}”에 넣었어요`, `Added to “${collection.name}”`))
      return
    }
    case 'tag': {
      const tag = store.tags.find((one) => one.id === shelf.id)
      if (!tag || entry.meta.tagIDs.includes(shelf.id)) return
      await call('paper:meta', { id: paperID, patch: { tagIDs: [...entry.meta.tagIDs, shelf.id] } })
      await reload()
      return
    }
  }
}

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
  statusMenu: (id, anchor) => {
    const entry = findPaper(id)
    if (!entry) return
    // The Mac's status button: the kind first — a handful of wrongly
    // answered imports is corrected down the list without the inspector —
    // then the reading status, each with its answer ticked.
    showMenu(anchor, [
      { caption: L('종류', 'Kind') },
      ...kindEntries(entry),
      { separator: true },
      { caption: L('읽기 상태', 'Reading Status') },
      ...statusEntries(entry),
    ], 'right')
  },
  attachments: (id, anchor) => {
    const children = attachmentsOf(id)
    if (children.length === 0) return
    showMenu(anchor, [
      { caption: L('보충 자료', 'Supplementary Material') },
      ...children.map((child) => ({
        label: child.meta.displayTitle,
        icon: 'doc',
        children: [
          { label: L('열기', 'Open'), icon: 'text.page', action: () => void showPaper(child.id) },
          { label: L('논문에서 떼기', 'Detach from Paper'), icon: 'paperclip', action: () => void detach(child.id) },
        ],
      })),
    ], 'right')
  },
  attach: (child, parent) => void attach(child, parent),
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
      // A search for the one to go under, as on the Mac — greyed for a paper
      // that is a supplement already, has its own, or has nothing to go under.
      {
        label: L('다른 논문에 붙이기…', 'Attach To…'),
        icon: 'paperclip',
        disabled: Boolean(entry.meta.parentID) || attachmentsOf(id).length > 0 || attachTargets(id).length === 0,
        action: () => showAttachSheet({
          child: { id, title: entry.meta.displayTitle },
          candidates: attachTargets(id),
          attach: (parent) => void attach(id, parent),
        }),
      },
      { separator: true },
      { label: L('폴더에서 보기', 'Show in Folder'), icon: 'folder', action: () => void call('paper:reveal', { id }) },
      ...(isCitable(entry.meta.effectiveKind)
        ? [{ label: L('인용 키 복사', 'Copy Citation Key'), icon: 'doc.on.doc', action: () => copyKey(id) }]
        : []),
      { separator: true },
      // The Mac's row menu has the reading status as a picker of its own.
      { label: L('읽기 상태', 'Reading Status'), icon: 'circle.lefthalf.filled', children: statusEntries(entry) },
      {
        label: entry.state.isFavorite
          ? L('즐겨찾기에서 빼기', 'Remove from Favorites')
          : L('즐겨찾기에 더하기', 'Add to Favorites'),
        icon: 'star',
        action: () => void setFavorite(id, !entry.state.isFavorite),
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
  refresh: () => void reload(),
  openPassage: (hit, byMeaning) => void openPassage(hit, byMeaning ? '' : store.searchQuery),
  openNote: (paperID) => void openNote(paperID),
  step: (by) => stepPaper(by),
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

/** The four kinds as menu rows, the paper's own ticked — the Mac's Kind picker. */
function kindEntries(entry: NonNullable<ReturnType<typeof findPaper>>): MenuEntry[] {
  return ([
    ['paper', L('논문', 'Paper'), 'text.document'],
    ['book', L('책', 'Book'), 'book'],
    ['lecture', L('강의자료', 'Course Material'), 'lecture'],
    ['document', L('일반 문서', 'Document'), 'doc'],
  ] as const).map(([value, label, glyph]) => ({
    label,
    icon: glyph,
    checked: entry.meta.effectiveKind === value,
    action: () => { if (entry.meta.effectiveKind !== value || entry.meta.kindIsUnanswered) void setKind(entry.id, value) },
  }))
}

/** The three reading statuses as menu rows, the paper's own ticked. */
function statusEntries(entry: NonNullable<ReturnType<typeof findPaper>>): MenuEntry[] {
  return ([
    ['unread', L('안 읽음', 'Unread'), 'circle'],
    ['reading', L('읽는 중', 'Reading'), 'circle.lefthalf.filled'],
    ['read', L('읽음', 'Read'), 'checkmark.circle'],
  ] as const).map(([value, label, glyph]) => ({
    label,
    icon: glyph,
    checked: entry.state.readingStatus === value,
    action: () => void setStatus(entry.id, value),
  }))
}

async function setStatus(id: string, readingStatus: 'unread' | 'reading' | 'read') {
  await call('paper:state', { id, patch: { readingStatus } })
  await reload()
}

async function setFavorite(id: string, isFavorite: boolean) {
  await call('paper:state', { id, patch: { isFavorite } })
  await reload()
}

/**
 * Makes one paper another's supplement: it leaves every shelf and hangs off
 * that paper's row by its paperclip. Not onto itself, not onto a paper that
 * is itself a supplement, and not a paper that has supplements of its own —
 * the Mac's rules, one level deep.
 */
async function attach(child: string, parent: string) {
  const entry = findPaper(child)
  const target = findPaper(parent)
  if (!entry || !target || child === parent) return
  if (target.meta.parentID || entry.meta.parentID === parent) return
  if (attachmentsOf(child).length > 0) {
    toast(L('보충 자료가 붙은 논문은 다른 논문에 붙일 수 없어요.', "A paper with supplements of its own can't become one."))
    return
  }
  await call('paper:meta', { id: child, patch: { parentID: parent } })
  await reload()
  // Off the shelves now; if it was the one showing, its paper comes forward
  // (`LibraryModel.attach`).
  if (store.selectedID === child) await showPaper(parent)
  toast(L(`“${target.meta.displayTitle}”에 붙였어요`, `Attached to “${target.meta.displayTitle}”`))
}

/** Every paper another could go under: standing on its own, and not itself. */
function attachTargets(id: string): { id: string; title: string; fileName: string }[] {
  return store.papers
    .filter((entry) => entry.id !== id && !entry.meta.parentID)
    .map((entry) => ({
      id: entry.id,
      title: entry.meta.displayTitle,
      fileName: entry.meta.file.originalName || entry.meta.file.relativePath.split(/[\\/]/).pop() || '',
    }))
}

/** Takes a supplement off its paper: a paper of its own again. */
async function detach(child: string) {
  await call('paper:meta', { id: child, patch: { parentID: null } })
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
  marks: () => focused()?.marksList() ?? [],
  revealMark: (pageIndex, id) => void focused()?.revealMark(pageIndex, id),
  removeMark: (pageIndex, id) => focused()?.removeMark(pageIndex, id),
  commentMark: (pageIndex, id, comment) => focused()?.setMarkComment(pageIndex, id, comment),
  copyText: (text) => {
    if (!text) return
    void navigator.clipboard.writeText(text)
    toast(L('복사했어요', 'Copied'))
  },
  markMenu: (anchor, entries) => showMenu(anchor, entries),
  open: (id) => void showPaper(id),
  detach: (id) => void detach(id),
  openAnchor: (place) => void openAnchor(place),
})

/**
 * A quotation's page link, followed from the note: its paper — the note's
 * own unless the link names another — at the passage's top, as a jump Back
 * comes back from.
 */
async function openAnchor(place: { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; paperID?: string }) {
  const known = place.paperID ? store.papers.find((entry) => entry.id.toUpperCase() === place.paperID!.toUpperCase()) : null
  const id = known?.id ?? store.selectedID
  if (!id) return
  if (id !== store.selectedID) await showPaper(id)
  const reader = readers.get(id)
  if (!reader || !(await reader.whenOpen())) return
  await reader.jumpTo(place.pageIndex, place.rect.y + place.rect.height)
}

// ------------------------------------------------------------ the page area

/**
 * The readers, one per paper in the page area. In the ordinary case that is
 * the one paper showing; with papers side by side, one per pane. A reader
 * whose paper leaves the page area is taken down, canvases and all.
 */
const readers = new Map<string, Reader>()
/**
 * Find in Document: one bar, over whichever reader is in focus. It goes when
 * that reader stops being the one in focus — its matches belong to that
 * paper.
 */
const findBar = new FindBar()
;(window as unknown as { __papertimeFind: unknown }).__papertimeFind = findBar
// For a probe: the reader in focus, and the two ways a search sends somebody
// into a paper — so "does it land on the word" can be checked from inside
// the page, with nothing sent to the desktop.
;(window as unknown as { __papertimeReader: unknown }).__papertimeReader = {
  focused: () => focused(),
  show: (id: string) => showPaper(id),
  openPassage: (hit: TextHit, query: string) => openPassage(hit, query),
  openFind: () => openFind(),
  showAll: (query: string) => showSearchResults(query),
}
const pageArea = el('div', { class: 'page-area' })
const dockZone = el('div', { class: 'dock-zone', 'data-on': 'false' })
/** What the page area shows when nothing is open. */
// The Mac's words for it, rather than an empty grey page that looks like a
// paper failing to load.
const emptyReader = el('div', { class: 'panel reader-panel' }, [
  el('div', { class: 'reader-header' }),
  el('div', { class: 'reader-scroll' }, [
    el('div', { class: 'empty' }, [
      el('span', { html: icon('text.document') }),
      el('h2', { text: L('고른 논문이 없어요', 'No Paper Selected') }),
      el('p', { text: L('읽을 논문을 하나 골라보세요.', 'Choose a paper to start reading.') }),
    ]),
  ]),
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
    // The Marks tab follows the page, and a mark clicked there is found in it.
    marksChanged: () => { if (store.selectedID === id) changed('marks') },
    historyChanged: () => toolbar.update(),
    markShown: (markID) => inspector.showMark(markID),
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
    reveal: () => void call('paper:reveal', { id }),
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
    head?: string
    line?: string | null
  }
  try {
    result = await call('paper:bytes', { id })
  } catch (error) {
    console.error('paper:bytes failed', error)
    result = { error: L('이 논문의 PDF를 읽지 못했어요.', "Paper Time couldn't read this paper's PDF.") }
  }
  if (!readers.has(id) || readers.get(id) !== reader) return
  if (result.locked) return reader.showLocked(result.locked)
  // Only when there are no bytes at all to try. Everything else goes to pdf.js
  // first: it reads more than this app does, and what was diagnosed only picks
  // the sentence for a failure that has actually happened.
  if (!result.data && result.trouble) {
    return reader.showTrouble(
      result.trouble, result.size ?? 0, () => void loadInto(reader, id),
      undefined, result.head, result.line,
    )
  }
  if (result.error || !result.data) return toast(result.error ?? 'unknown error')
  await reader.open(id, new Uint8Array(result.data), {
    trouble: result.trouble,
    size: result.size,
    again: () => void loadInto(reader, id),
  })
  reader.setDrawing(reader.state.drawing)
  reader.update()
  // Now that there are pages to scroll: a paper whose reader was rebuilt
  // around it — closing the pane beside it, putting it beside another — goes
  // back to where it was being read rather than to page one.
  const place = inheritedPlaces.get(id)
  if (place) {
    inheritedPlaces.delete(id)
    reader.returnTo(place)
  }
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
  const shape = [split ? JSON.stringify(split) : 'one', ...wanted].join(' ')
  // A reader keeps its pen state across a change of arrangement — but one
  // built for a pane and one built for the whole area differ in chrome, so
  // the readers are rebuilt when the arrangement appears or goes.
  for (const [id, reader] of [...readers]) {
    if (!wanted.includes(id) || reader.isPane !== Boolean(split)) {
      const drawing = reader.state.drawing
      const place = reader.place()
      reader.dispose()
      readers.delete(id)
      if (wanted.includes(id)) {
        inheritedDrawing.set(id, drawing)
        // A reader built for a pane and one built for the whole area are
        // different objects, so this paper's place cannot simply be restored
        // at the end — it is handed to the reader that replaces this one, and
        // taken up once that one has the pages to scroll.
        if (place.top > 0) inheritedPlaces.set(id, place)
      }
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

  // Nothing to rebuild if the page area is already showing this. Taking a
  // reader out of the document empties the scroll view inside it, and a
  // reader at the top is a reader on page one — so a rebuild for nothing is
  // a paper that jumps. The library is re-read every time the folder changes
  // and the folder changes every time a mark is saved, which made this the
  // path a highlight took back to the first page. Measured before this:
  // scrolled to 1856, and 0 again two seconds later.
  const standing = wanted.length > 0
    ? wanted.every((id) => pageArea.contains(readers.get(id)?.node ?? null))
    : pageArea.contains(emptyReader)
  if (shape === showing && standing && pageArea.contains(dockZone)) {
    focusChanged()
    return
  }
  showing = shape
  // Where each reader was, to put it back: an arrangement that genuinely
  // changed still rebuilds, and the pane that was only standing beside the
  // one that changed should not lose its place either.
  keepingPlaces(() => {
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
  })
}

/** What the page area is showing, so that it is only rebuilt when that
 *  changes. See the note in `reconcileReaders`. */
let showing = ''

/**
 * Runs something that re-appends a panel, and puts the papers back afterwards.
 *
 * A scroll view taken out of the document comes back at the top, and a reader
 * at the top is a reader on page one. Every piece of code that re-appends a
 * panel goes through here — measured, toggling the sidebar sent a paper from
 * 1600 to 0, and so did saving a highlight, by way of the library being
 * re-read. The papers go back after the panels have been laid out again, so
 * that a column which has just changed width is measured at its new size.
 */
function keepingPlaces(rebuild: () => void) {
  const places = new Map([...readers].map(([id, reader]) => [id, reader.place()]))
  rebuild()
  for (const [id, reader] of readers) {
    const place = places.get(id)
    if (place) reader.returnTo(place)
  }
}

const inheritedDrawing = new Map<string, boolean>()

/** Where a paper was being read, across a rebuild of its reader. */
const inheritedPlaces = new Map<string, ReaderPlace>()

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
  // What was found belongs to the paper it was found in.
  if (findBar.isOpen && !findBar.isFor(reader)) findBar.close()
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
    // Counted from nought already; the «− 1» that was here ringed the page
    // before the one being read.
    currentPage: () => reader.state.currentPage,
    draw: (index, width) => reader.thumbnail(index, width),
    // A jump Back comes back from, and one that works with one page showing
    // (the page scrolled to used to be hidden in that layout).
    go: (index) => void reader.jumpTo(index, null),
    outline: () => reader.outline(),
    goToHeading: (entry) => { if (entry.pageIndex !== null) void reader.jumpTo(entry.pageIndex, entry.top) },
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
// Every undo step remembers the paper it was taken in (`applyUndo`).
undoStack.paperOf = () => store.selectedID

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
      // The Mac's word for the same errand: fetch what the folders have and
      // tell the papers to look at their files again.
      { label: L('지금 맞추기', 'Sync Now'), icon: 'arrow.clockwise', action: () => void reload() },
      { label: L('라이브러리 폴더 고르기…', 'Choose Library Folder…'), icon: 'folder', action: () => void chooseLibrary() },
      { separator: true },
      // A picker is a submenu, as the Mac's pickers in a menu are: the whole
      // list of choices inline made this menu taller than a small window.
      {
        label: L('정렬 기준', 'Sort By'),
        icon: 'arrow.up.arrow.down',
        children: (['title', 'author', 'year', 'added', 'opened'] as const).map((field) => ({
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
      },
      {
        label: L('오름차순', 'Ascending'),
        checked: store.settings.sort.ascending,
        action: () => setSort(store.settings.sort.field, !store.settings.sort.ascending),
      },
      { separator: true },
      { caption: L('쪽 배치', 'Page Layout') },
      ...(['continuous', 'single', 'book'] as const).map((layout) => ({
        label: { continuous: L('이어서 보기', 'Continuous'), single: L('한 쪽씩 보기', 'Single Page'), book: L('책처럼 보기', 'Book') }[layout],
        checked: store.settings.pageLayout === layout,
        action: () => setLayout(layout),
      })),
      { separator: true },
      { caption: L('쪽 색조', 'Page Tint') },
      // The custom one draws with the colour chosen in Settings.
      ...PAGE_TINTS.map((tint) => ({
        label: tintLabel(tint),
        checked: store.settings.pageTint === tint,
        action: () => setSettings({ pageTint: tint }),
      })),
      { separator: true },
      {
        label: L('화면 모드', 'Appearance'),
        icon: 'textformat.size',
        children: (['system', 'light', 'dark'] as const).map((appearance) => ({
          label: { system: L('시스템에 따라', 'System'), light: L('밝게', 'Light'), dark: L('어둡게', 'Dark') }[appearance],
          checked: store.settings.appearance === appearance,
          action: () => setSettings({ appearance }),
        })),
      },
      ...moreMenuTail(),
    ], 'right')
  },
  settings: () => openSettings(),
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
  keepingPlaces(() => {
    layoutPanes()
    toolbar.update()
    relayoutReaders()
  })
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
  const snapshot = await call<LibrarySnapshot>('library:import', { root: importDestination() })
  if ('error' in snapshot) return toast(String(snapshot.error))
  adopt(snapshot)
  changed('papers')
}

/**
 * The library a PDF added now goes into: the one whose own shelf is showing,
 * as on the Mac (`importDestination`). Nothing — the first library — on every
 * other shelf, a folder inside a library included.
 */
function importDestination(): string | undefined {
  if (store.shelf.kind !== 'folder') return undefined
  const root = (store.shelf as { root: string }).root
  return store.roots.includes(root) ? root : undefined
}

async function reload() {
  const snapshot = await call<LibrarySnapshot>('library:reload')
  // A folder that would not answer used to end here without a word. The rows
  // already on screen stay where they are; the list says what happened and
  // offers to read again.
  if ('error' in snapshot) {
    failed(String(snapshot.error))
    changed('papers')
    return
  }
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
 * The next or previous paper on the shelf showing — ⌥⌘↓/⌥⌘↑ on the Mac,
 * Ctrl+Alt+↓/↑ here, and ↓/↑ in the list itself. Nothing chosen yet: the
 * first. At either end: nowhere (`RootView.step(by:)`).
 */
function stepPaper(by: number) {
  const papers = shelfPapers()
  if (papers.length === 0) return
  const at = papers.findIndex((entry) => entry.id === store.selectedID)
  if (at < 0) {
    void showPaper(papers[0].id)
    return
  }
  const next = papers[at + by]
  if (next) void showPaper(next.id)
}

/**
 * Back and forward walk the papers you have opened, the way a browser walks
 * pages: going back and then opening something else forgets what lay ahead.
 */
function goBack() {
  // The paper's own history first — the sentence a followed link came from —
  // then the papers (`goBackInHistory` on the Mac).
  const reader = focused()
  if (reader?.canGoBackInDocument) return reader.goBackInDocument()
  if (!canGoBack()) return
  const id = travel(store.trailIndex - 1)
  if (!id) return
  store.travelling = true
  void showPaper(id).finally(() => { store.travelling = false })
}

function goForward() {
  const reader = focused()
  if (reader?.canGoForwardInDocument) return reader.goForwardInDocument()
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
  keepingPlaces(() => {
    layoutPanes()
    toolbar.update()
    relayoutReaders()
  })
}

function setLayout(layout: 'single' | 'continuous' | 'book') {
  store.settings.pageLayout = layout
  for (const reader of readers.values()) reader.setLayout(layout)
  void call('settings:set', { pageLayout: layout })
}

function setSort(field: typeof store.settings.sort.field, ascending: boolean) {
  store.settings.sort = { field, ascending }
  void call('settings:set', { sort: store.settings.sort })
  changed('papers')
}

/**
 * The ⋯ menu's last part, in the Mac's order: the paper's kind (one of the
 * two places it is changed — the row's menu is the other), then sharing, then
 * help.
 *
 * Help is here because on Windows and Linux it has nowhere else to be. The
 * window is frameless there, and Electron draws no menu bar in a frameless
 * window — its keys work, but an item that is only in the menu is an item
 * nobody can reach: «Built together» was one, and «Send Feedback» hid behind
 * Ctrl+Alt+/ alone.
 */
function moreMenuTail(): MenuEntry[] {
  const entry = store.selectedID ? findPaper(store.selectedID) : null
  const kinds: MenuEntry[] = entry
    ? [{ separator: true }, { label: L('종류', 'Kind'), icon: 'text.document', children: kindEntries(entry) }]
    : []
  return [
    ...kinds,
    { separator: true },
    { label: L('BibTeX 내보내기…', 'Export BibTeX…'), icon: 'square.and.arrow.up', action: () => runMenuCommand('exportBibTeX') },
    { separator: true },
    { label: L('한마디 보내기…', 'Send Feedback…'), action: () => void showFeedback() },
    { label: L('함께 만드는 중', 'Built together'), action: () => void call('shell:openExternal', { url: TOGETHER_URL }) },
    { label: L('Paper Time 정보', 'About Paper Time'), icon: 'info', action: () => openSettings('about') },
  ]
}

const TOGETHER_URL = 'https://icecoffee2500.github.io/paper-time/#together'

async function copyKey(id: string) {
  const entry = findPaper(id)
  if (!entry) return
  // The key the exported file gives it — its own, or the one the export
  // makes up — and never its title, which no \cite{} would find.
  await navigator.clipboard.writeText(entryFor(entry.meta).key)
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

/** Search Everything: the palette (`ui/search.ts`), and what its rows do. */
function openSearch(initial = '') {
  openPalette({
    openPaper: (id) => void showPaper(id),
    openPassage: (hit, query) => void openPassage(hit, query),
    openNote: (paperID) => void openNote(paperID),
    openCollection: (id) => selectShelf({ kind: 'collection', id }),
    openTag: (id) => selectShelf({ kind: 'tag', id }),
    showAll: (query) => showSearchResults(query),
    perform: (action) => {
      switch (action) {
        case 'addPDFs': void addPapers(); break
        case 'exportBibTeX': runMenuCommand('exportBibTeX'); break
        case 'refresh': void reload(); break
        case 'settings': openSettings(); break
      }
    },
  }, initial)
}

function closeSearch() {
  closePalette()
}

function selectShelf(shelf: Shelf) {
  store.shelf = shelf
  changed('shelf')
}

/**
 * Opens the paper a word was found in and sends the reader to the line.
 *
 * The reader is asked only once the paper is in it: opening a paper is a
 * round trip for its bytes and a parse, and the line has no place until then.
 */
async function openPassage(hit: TextHit, query: string) {
  const id = hit.passage.paperID
  if (!findPaper(id)) return
  await showPaper(id)
  const reader = readers.get(id)
  if (!reader) return
  if (findBar.isOpen) findBar.close()
  await reader.revealPassage(hit.passage, query)
}

/** A summary note from the palette: its paper, with the note in front. */
async function openNote(paperID: string) {
  await showPaper(paperID)
  showNoteTab()
}

/** The inspector, open on the Notes tab of the paper in front. */
function showNoteTab() {
  if (store.settings.inspectorTab !== 'note') {
    store.settings.inspectorTab = 'note'
    void call('settings:set', { inspectorTab: 'note' })
  }
  if (!store.settings.panes.inspector) togglePane('inspector')
  inspector.update()
  toolbar.update()
}

/**
 * Command-N. The Mac opens a new note on the paper being read; this build
 * keeps one note for each paper, so it opens that note with the caret at its
 * end, which is where the new thought goes. The menu item and its key used to
 * answer «not in this build yet».
 */
function newNote() {
  if (!store.selectedID || !findPaper(store.selectedID)) {
    toast(L('먼저 논문을 열어주세요.', 'Open a paper first.'))
    return
  }
  showNoteTab()
  inspector.focusNote()
}

/**
 * Command-L: the selected passage goes into the paper's note as a quotation,
 * with a link back to its page, and the note comes forward — the Markdown
 * the Mac writes, so either build's editor reads it as its own.
 */
function linkSelectionToNote() {
  const reader = focused()
  const anchor = reader?.selectionAnchor()
  if (!reader || !anchor || !store.selectedID) {
    toast(L('먼저 글을 골라주세요.', 'Select some text first.'))
    return
  }
  const block = quotationSource(
    { pageIndex: anchor.pageIndex, rect: anchor.rect, quotedText: passageText(anchor.text) },
    (page) => L(`${page}쪽`, `p. ${page}`),
  )
  showNoteTab()
  if (!inspector.insertIntoNote(block)) return
  reader.hideMarkBar()
}

/**
 * «Show All Results»: the search becomes a shelf, with its own row at the top
 * of the sidebar, and the list reads the papers' text for the same words.
 */
function showSearchResults(query: string) {
  const trimmed = query.trim()
  if (!trimmed) return
  store.searchQuery = trimmed
  store.shelf = { kind: 'search' }
  changed('shelf', 'papers')
}

function clearSearchResults() {
  store.searchQuery = ''
  if (store.shelf.kind === 'search') store.shelf = { kind: 'all' }
  changed('shelf', 'papers')
}

/**
 * The list's half of a search: the papers that say the words inside them.
 *
 * The same work the palette does, kept when the palette is put away:
 * pressing Return on a search should not throw away the half of the answer
 * that was not in any title. Every paper is read, not four, and the hits go
 * on the list a batch at a frame — the Mac appended them one at a time, and
 * the list redrew itself once per paper.
 */
let listScan: { key: string; stop: (() => void) | null } = { key: '', stop: null }
let listDraw = 0

function scanListText() {
  const key = store.shelf.kind === 'search' ? store.searchQuery : ''
  if (key === listScan.key) return
  listScan.stop?.()
  listScan = { key, stop: null }
  store.searchPassages = []
  store.searchScanning = false
  store.searchMeanings = []
  if (!key || graphemes(key).length <= 1) return
  askListMeaning(key)
  // The papers already on the list by their titles are the ones not to read
  // for the same words again.
  const named = new Set(shelfPapers().map((entry) => entry.id))
  store.searchScanning = true
  listScan.stop = searchText(key, textSources(named), {
    hits: (hits) => {
      store.searchPassages = [...store.searchPassages, ...hits]
      if (!listDraw) {
        listDraw = requestAnimationFrame(() => {
          listDraw = 0
          paperList.update()
        })
      }
    },
    done: () => {
      store.searchScanning = false
      listScan.stop = null
      paperList.update()
    },
  })
}

/**
 * The list's passages by meaning: the palette's rows, kept when the palette
 * is put away. Nothing is asked while the index is not built or the switch
 * is off — the group is left out, not shown empty. The list drops what the
 * words already found when it draws, since those arrive after this answer.
 */
function askListMeaning(key: string) {
  if (graphemes(key).length <= 2 || !meaningStatus().ready) return
  void searchMeaning(key).then((answer) => {
    if (listScan.key !== key || !answer.ready) return
    store.searchMeanings = answer.hits.map(asTextHit)
    paperList.update()
  })
}

function openFind() {
  const reader = focused()
  if (!reader || !reader.document) {
    toast(L('먼저 논문을 열어주세요.', 'Open a paper first.'))
    return
  }
  findBar.open(reader)
}

// ------------------------------------------------------------------- keys

on(window, 'keydown', (event: KeyboardEvent) => {
  const target = event.target as HTMLElement | null
  const typing = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')
  const reader = focused()

  // While the pen is out the page's own editor has the Mac's whole key map
  // — Escape's three steps, the arrows, ⌘C/⌘X/⌘V, Enter into a group — and
  // it goes first. What it does not take falls through to the keys below.
  if (store.reader.drawing && !isPaletteOpen()) {
    const current = sketchEditor.current as SketchInputEditing | null
    if (current && typeof current.handleKey === 'function' && !(typing && event.key !== 'Escape') && current.handleKey(event)) {
      event.preventDefault()
      return
    }
  }

  if (event.key === 'Escape') {
    // Three steps back, in the order a hand expects: finish the words, then
    // drop the selection, then put the tool away.
    if (isPaletteOpen()) return closeSearch()
    if (findBar.isOpen) return findBar.close()
    if (isOpenPapersShowing()) return closeOpenPapers()
    if (reader?.markBarShowing) return reader.hideMarkBar()
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

  // Turned rather than scrolled — one page, or a book's spread — the arrows
  // and Page Up/Down turn.
  if (store.settings.pageLayout !== 'continuous' && !store.reader.drawing && reader) {
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
  // Into the paper the step was taken in, or nowhere. Put into whichever
  // paper happened to be in front, an undo wrote one paper's page over
  // another's.
  const target = snapshot.paperID ? readers.get(snapshot.paperID) ?? null : focused()
  if (!target) return
  // A step may cover two pages — a selection carried from one to the other.
  target.restore(snapshot)
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
  // Glass is the panel's colour, and so goes with the appearance: multiplied
  // onto a light panel, turned to night on a dark one.
  for (const reader of readers.values()) reader.applyTint()
}

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (store.settings.appearance === 'system') applyTheme()
})

// ------------------------------------------------------------- redrawing

let wasDrawing = false
/** The inspector's tab before the pen came out, to go back to. */
let tabBeforeDrawing: InspectorTab | null = null

subscribe((keys) => {
  if (keys.has('shelf') || keys.has('papers')) scanListText()
  if (keys.has('papers') || keys.has('shelf') || keys.has('selection')) {
    sidebar.update()
    paperList.update()
    inspector.update()
    refreshOpenPapers()
  }
  if (keys.has('inspector')) inspector.update()
  if (keys.has('marks') && store.settings.inspectorTab === 'marks') inspector.update()
  if (keys.has('sketch')) {
    // Picking up the pen brings the Tools tab forward, as it does on the Mac,
    // and putting it down gives the panel back — the tab that was showing
    // before, unless another was chosen with the pen in hand. It used to go
    // one way only, so an afternoon in the Notes tab ended on Tools the first
    // time a pen was picked up, and stayed there.
    if (store.reader.drawing && !wasDrawing) {
      if (store.settings.inspectorTab !== 'tools') {
        tabBeforeDrawing = store.settings.inspectorTab
        store.settings.inspectorTab = 'tools'
        void call('settings:set', { inspectorTab: 'tools' })
      }
      // The Mac shows the inspector with the pen: the Tools tab is where the
      // drawing's style is set. Not in focus, which hid it on purpose.
      if (!store.settings.panes.inspector && !beforeFocus && !solo) togglePane('inspector')
    } else if (!store.reader.drawing && wasDrawing) {
      if (store.settings.inspectorTab === 'tools' && tabBeforeDrawing) {
        store.settings.inspectorTab = tabBeforeDrawing
        void call('settings:set', { inspectorTab: tabBeforeDrawing })
        inspector.update()
      }
      tabBeforeDrawing = null
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
    case 'text:hits':
    case 'text:done':
    case 'text:warmed':
      handleTextEvent(event, payload)
      break
    case 'semantic:progress':
    case 'semantic:ready':
      handleMeaningEvent(event, payload)
      break
    case 'menu:feedback':
      void showFeedback()
      break
    case 'library:changed':
      void reload()
      break
    case 'library:opened': {
      // The main process sends whatever `snapshot()` came back with, and that
      // can be `{ error }`, which has no `papers` to map over. Unguarded, the
      // throw landed inside this listener and the window simply stopped.
      const opened = payload as LibrarySnapshot | { error: string }
      if ('error' in opened) failed(String(opened.error))
      else adopt(opened)
      changed('papers', 'shelf')
      break
    }
    case 'window:state':
      store.windowState = payload as typeof store.windowState
      toolbar.update()
      break
    case 'theme:changed':
      if (store.settings.appearance === 'system') applyTheme()
      break
    case 'paper:saved': {
      const { id } = payload as { id: string }
      readers.get(id)?.noteKept(null)
      break
    }
    case 'paper:kept': {
      // What was made here is in Paper Time and not in the file. The reader
      // for that paper says so, once, where it says the page and the zoom;
      // no reason means there is nothing left to say it about.
      const { id, reason } = payload as { id: string; reason: 'encrypted' | 'permissions' | 'structure' | null }
      readers.get(id)?.noteKept(reason)
      break
    }
    case 'menu':
      runMenuCommand(String(payload))
      break
    case 'error':
      toast(String(payload))
      break
  }
})

/**
 * The settings sheet — from the ⚙ in the bar, from the menu, and from
 * `Ctrl+,`, which until now went nowhere at all.
 */
function openSettings(section?: SettingsSection) {
  const sheet = showSettings({
    // Written, applied, and the sheet redrawn — except while a colour is
    // being dragged, when a redraw would close the desktop's picker
    // (`setSettings`, `live`).
    set: setSettings,
    // The same errand as the ⋯ menu's. `library:choose` only asks which
    // folder; this called it and then read the old library again, so the
    // sheet's «Choose…» let somebody pick a folder and changed nothing.
    chooseLibrary: () => void chooseLibrary(),
    feedback: () => void showFeedback(),
  }, section)
  if (sheet) openSettingsSheet = sheet
}

let openSettingsSheet: { redraw: () => void; close: () => void } | undefined

/** What is waiting to be written while a colour is being dragged. */
let pendingSettings: Record<string, unknown> = {}
let pendingSettingsTimer = 0

/**
 * Changes settings from the sheet, the ⋯ menu or a probe, and makes the
 * window follow at once — a sheet that saves and shows nothing is a form.
 *
 * `live` is for a value still moving under the hand, the ground colour while
 * its well is dragged: the page follows every step, the file is written once
 * the hand rests, and the sheet is not drawn again — drawing it again would
 * take the colour well away from under the pointer, and the picker with it.
 */
function setSettings(patch: Record<string, unknown>, options: { live?: boolean } = {}) {
  Object.assign(store.settings, patch)
  if (options.live) {
    Object.assign(pendingSettings, patch)
    clearTimeout(pendingSettingsTimer)
    pendingSettingsTimer = window.setTimeout(flushSettings, 300)
  } else {
    Object.assign(pendingSettings, patch)
    flushSettings()
  }
  if ('appearance' in patch) applyTheme()
  else if ('pageTint' in patch || 'pageTintColor' in patch) {
    for (const reader of readers.values()) reader.applyTint()
  }
  if ('pageLayout' in patch) setLayout(store.settings.pageLayout)
  if ('listSubtitle' in patch) paperList.update()
  if (options.live) return
  changed('settings', 'toolbar')
  openSettingsSheet?.redraw()
}

function flushSettings() {
  clearTimeout(pendingSettingsTimer)
  const patch = pendingSettings
  pendingSettings = {}
  if (Object.keys(patch).length > 0) void call('settings:set', patch)
}

// A colour still resting when the window goes is written as it goes.
on(window, 'beforeunload', flushSettings)

// For a probe: settings changed the way the sheet changes them — held in
// memory by a probe run, like everything else it sets.
;(window as unknown as { __papertimeSettings: unknown }).__papertimeSettings = {
  set: (patch: Record<string, unknown>) => setSettings(patch),
  tint: () => focused()?.tintReport() ?? null,
}

function runMenuCommand(command: string) {
  const reader = focused()
  switch (command) {
    case 'settings': openSettings(); break
    case 'addPapers': void addPapers(); break
    case 'refreshFolder': void reload(); break
    case 'addFolder': addLibraryFolder(); break
    case 'searchEverything': openSearch(); break
    case 'findInDocument': openFind(); break
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
      // The Mac's sheet: the scope, the options, the file previewed.
      showExportSheet({
        view: () => shelfPapers(),
        copy: (text) => {
          void navigator.clipboard.writeText(text)
          toast(L('BibTeX를 복사했어요', 'BibTeX copied'))
        },
        save: async (text) => {
          const result = await call<{ path?: string; cancelled?: boolean }>('bibtex:save', { text })
          if (result.cancelled || !result.path) return false
          toast(L('BibTeX를 저장했어요', 'BibTeX saved'))
          return true
        },
      })
      break
    case 'copyCitationKey':
      if (store.selectedID) void copyKey(store.selectedID)
      break
    case 'focus': toggleFocus(); break
    case 'layoutContinuous': setLayout('continuous'); break
    case 'layoutSinglePage': setLayout('single'); break
    case 'layoutBook': setLayout('book'); break
    case 'openPapers': if (!solo) showOpenPapersPopup(); break
    case 'pages': showPagesPopup(); break
    case 'openInNewWindow': if (store.selectedID) openInWindow(store.selectedID); break
    case 'closeWindow': closeWindowOrPane(); break
    case 'newNote': newNote(); break
    case 'linkToNote': linkSelectionToNote(); break
    case 'nextPage': reader?.turnPage(1); break
    case 'previousPage': reader?.turnPage(-1); break
    case 'nextPaper': stepPaper(1); break
    case 'previousPaper': stepPaper(-1); break
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
  const dropped = droppedPaths(event.dataTransfer?.files)
  const files = dropped.filter((path) => path.toLowerCase().endsWith('.pdf'))
  if (files.length === 0) {
    // Something was dropped and none of it was a paper: say so rather than
    // let the window look broken. A drop that carried nothing at all — a
    // paper being dragged between panes — is not worth a word.
    if (dropped.length > 0) toast(L('PDF만 더할 수 있어요.', 'Only PDFs can be added to the library.'))
    return
  }
  const snapshot = await call<LibrarySnapshot>('library:import', { paths: files, root: importDestination() })
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
    if ('error' in snapshot) {
      // There is a folder in the settings and it would not be read. Saying so
      // is the whole of it: this used to fall through to a window whose list
      // offered to choose a library folder, as though the one already chosen
      // had never existed.
      store.root = saved.libraryRoot
      failed(String(snapshot.error))
      changed('papers', 'shelf')
    } else {
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
