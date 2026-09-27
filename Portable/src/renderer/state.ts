/**
 * What the window knows, and who to tell when it changes.
 *
 * No framework. The app has four panes and one document open at a time, and a
 * store with a subscriber list renders it in a few milliseconds — which keeps
 * the whole renderer readable, and keeps the Windows build and the Linux build
 * from differing by way of somebody's runtime.
 */
import type { Settings as AppSettings } from '../shared/appSettings.js'
import { findPath, isInside, isUnder, pathKey, samePath, slashed } from '../shared/paths.js'
import type { LibrarySnapshot, NoteDTO, NotesFolderDTO, PaperRowDTO } from '../shared/api.js'
import type { Zettel } from '../shared/zettel.js'
import type { TextHit } from '../main/textIndex.js'
import { needsReview, type DocumentKind } from '../shared/documentKind.js'
import { authorKey, caseInsensitiveOrder, nameShown, sortingSurname, standardOrder } from '../shared/authorKey.js'
import { foldTitle } from '../shared/textFold.js'
import { paperHaystack, type SearchablePaper } from '../shared/searchRank.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { SketchColor, SketchStyle } from '../shared/sketch.js'
import { splitContains, splitDock, splitPapers, splitRemove, type DockZone, type SplitArrangement } from '../shared/split.js'
import { DEFAULT_TINT_COLOR, type PageTint } from '../shared/pageTint.js'
import { inCollection } from '../shared/smartRule.js'
import type { PaneState } from '../shared/paneModel.js'

export type Pane = 'sidebar' | 'paperList' | 'reader' | 'inspector'
export type InspectorTab = 'details' | 'marks' | 'note' | 'tools'
export type SketchTool =
  | 'select' | 'frame' | 'pen' | 'highlighter' | 'eraser'
  | 'rectangle' | 'ellipse' | 'arrow' | 'line' | 'text'

/** Which shelf of the library is showing. */
export type Shelf =
  | { kind: 'all' }
  /** The two kinds, which only appear as rows once a library holds both. */
  | { kind: 'kind'; of: DocumentKind }
  | { kind: 'folder'; root: string }
  | { kind: 'open' }
  | { kind: 'status'; status: 'unread' | 'reading' | 'read' }
  | { kind: 'favorites' }
  | { kind: 'review' }
  | { kind: 'notes' }
  | { kind: 'collection'; id: string }
  /** One person, by `authorKey` — «Y. LeCun» and «Yann LeCun» are one shelf. */
  | { kind: 'author'; key: string; name: string }
  | { kind: 'tag'; id: string }
  /** What the palette's «Show All Results» found: `store.searchQuery`. */
  | { kind: 'search' }

/** One note of the slip-box, and the box it was read from. */
export interface Note extends Zettel {
  /** A library's root, the loose folder — or '' for a note not yet written anywhere. */
  box: string
}

export interface Paper {
  id: string
  meta: PaperMeta
  state: PaperState
  exists: boolean
  /** The folder it came from, when the library reads more than one. */
  root?: string
}

/**
 * The settings the window reads and changes — the file's own type
 * (`shared/appSettings.ts`), kept to the keys the window uses. Written out by
 * hand here once, it drifted: the window stored an inspector tab the file's
 * type did not have.
 */
export const WINDOW_SETTINGS = [
  'libraryRoot', 'panes', 'columns', 'inspectorTab', 'sort', 'appearance', 'language', 'pageTint',
  'pageTintColor', 'pageLayout', 'selectedPaperID', 'latexShortcuts', 'semanticSearch', 'listSubtitle',
  'bibtexProtectCase', 'bibtexPreprintStyle', 'bibtexIncludeUnverified', 'sketchStyle',
] as const satisfies readonly (keyof AppSettings)[]

export type Settings = Pick<AppSettings, (typeof WINDOW_SETTINGS)[number]>

/** What one reader — one pane — knows about the paper it shows. */
export interface ReaderState {
  pageCount: number
  currentPage: number
  zoom: number
  /** The pen is out: the page takes the mouse instead of the text layer. */
  drawing: boolean
  /** A followed link can be walked back, or forward again, inside this paper. */
  canGoBack?: boolean
  canGoForward?: boolean
}

export const freshReaderState = (): ReaderState => ({ pageCount: 0, currentPage: 0, zoom: 1, drawing: false })

/**
 * The reader in focus's own state, read where it lives.
 *
 * Every pane has a reader and every reader its state; the toolbar, the rack
 * and the keys ask about the one in focus. This used to be a field the page
 * area overwrote with a reference to that reader's object whenever the focus
 * moved — an alias nobody knew was one — and a stale alias was a toolbar
 * asking a disposed reader whether Back was possible.
 */
let focusedReaderState: () => ReaderState | null = () => null
const NOTHING_OPEN: ReaderState = Object.freeze(freshReaderState()) as ReaderState

export function readerState(): ReaderState {
  return focusedReaderState() ?? NOTHING_OPEN
}

/** Where `readerState()` reads from: the page area, once there is one. */
export function setFocusedReaderState(source: () => ReaderState | null) {
  focusedReaderState = source
}

export interface Store {
  ready: boolean
  error: string | null
  /** Records in the folders this read could not get at, one sentence each. */
  unreadable: string[]
  root: string | null
  /** The library in the settings that is not there now, and why — the
   *  window shows it by name instead of the columns. */
  unavailable: { root: string; message: string } | null
  /** Every folder being read, the first one first. */
  roots: string[]
  papers: Paper[]
  collections: Collection[]
  tags: Tag[]
  looseCount: number
  /** What the last "add the loose PDFs" could not read, by name. */
  refused: string[]
  /**
   * The slip-box: every note in every open folder and the loose ones, in
   * the order they were written — a list that re-sorted itself by the last
   * edit moved the note just touched to the top, as the Mac found.
   */
  notes: Note[]
  /** Where the notes about no paper live. */
  notesFolder: NotesFolderDTO | null
  /** The note open in the inspector's Notes tab, or null for the list. */
  noteOpenID: string | null
  /** The slip-box shelf: the note open beside the list, the search and the
   *  tag narrowing it, and the paper shown instead after a link was followed. */
  slipBox: { openID: string | null; query: string; tag: string | null; paperID: string | null }
  shelf: Shelf
  /** The paper showing — with panes side by side, the one in focus. */
  selectedID: string | null
  /**
   * The rows chosen in the list, as the Mac's `selection: Set<UUID>`: a
   * shift-click takes a run, a Ctrl-click (⌘ on a Mac) adds or drops one,
   * and a drag that starts on any of them carries them all. The paper
   * showing is one of them; anything that shows a paper by other means —
   * the palette, Back, a supplement — makes the selection that paper alone
   * (`selectedPapers`).
   */
  selection: string[]
  /** Where a shift-click's run starts, and where the keyboard's run has got to. */
  selectionAnchor: string | null
  selectionLead: string | null
  /** «Add n PDFs» under way: how many are left, or null. */
  adopting: number | null
  /**
   * The papers kept open this session, in the order they were kept.
   *
   * Not every paper looked at: walking down the list shows each in turn, and
   * a shelf that kept all of them would be the list again. A paper is kept
   * when it is *used* — clicked into, put beside another, pinned — the way an
   * editor's preview tab becomes a real tab once you type in it. The one
   * merely showing is a preview, and leaves when the next one is shown.
   * Per session, as on the Mac: never written to the settings file.
   */
  openPaperIDs: string[]
  /** The ones somebody pinned, as against the ones the app kept. */
  pinnedPaperIDs: string[]
  /** Papers side by side, when they are. Null is the one reader as always. */
  split: SplitArrangement | null
  settings: Settings
  windowState: { maximized: boolean; fullScreen: boolean; focused: boolean }
  /** The papers opened, in order — what the back and forward arrows walk. */
  trail: string[]
  trailIndex: number
  /** Set while travelling, so the trail does not record its own footsteps. */
  travelling: boolean
  /**
   * The query behind the search shelf, kept apart from the shelf itself — as
   * the Mac keeps `searchQuery` apart from its scope. A search is somewhere
   * you can be, and somewhere you can go back to after looking at another
   * shelf: its row stays at the top of the sidebar until it is put away.
   */
  searchQuery: string
  /** What the same query found inside the papers, for the list. */
  searchPassages: TextHit[]
  /** Whether the list is still reading the papers for it. */
  searchScanning: boolean
  /** And what says the same thing in other words — none until the index is built. */
  searchMeanings: TextHit[]
  /** Focus mode, and the list and inspector it hid (`shared/paneModel.ts`). */
  focus: PaneState['focus']
  sketch: {
    tool: SketchTool
    /** The shape tool last used — the one the rack's shapes button shows. */
    lastShape: SketchTool
    /** The pen-group tool last used — pen, highlighter or eraser. */
    lastInk: SketchTool
    style: SketchStyle
    /** Which page's elements are selected, and which of them. */
    selection: { pageIndex: number; ids: string[]; strokeIDs: number[] } | null
  }
}

/** The rack's groups, as Figma has them: one button each, the members behind a chevron. */
export const SHAPE_TOOLS: SketchTool[] = ['rectangle', 'ellipse', 'line', 'arrow']
export const INK_TOOLS: SketchTool[] = ['pen', 'highlighter', 'eraser']

/**
 * Picks a tool and remembers which member of its group it was, so the group's
 * button keeps showing the tool you reached for last. Every path that changes
 * the tool goes through here; the store's field alone forgets.
 */
export function setSketchTool(tool: SketchTool) {
  store.sketch.tool = tool
  if (SHAPE_TOOLS.includes(tool)) store.sketch.lastShape = tool
  if (INK_TOOLS.includes(tool)) store.sketch.lastInk = tool
}

export const store: Store = {
  ready: false,
  error: null,
  unreadable: [],
  root: null,
  unavailable: null,
  roots: [],
  papers: [],
  collections: [],
  tags: [],
  looseCount: 0,
  refused: [],
  notes: [],
  notesFolder: null,
  noteOpenID: null,
  slipBox: { openID: null, query: '', tag: null, paperID: null },
  shelf: { kind: 'all' },
  selectedID: null,
  selection: [],
  selectionAnchor: null,
  selectionLead: null,
  adopting: null,
  openPaperIDs: [],
  pinnedPaperIDs: [],
  split: null,
  settings: {
    libraryRoot: null,
    panes: { sidebar: true, paperList: true, reader: true, inspector: true },
    columns: { sidebar: 232, paperList: 320, inspector: 360 },
    inspectorTab: 'details',
    sort: { field: 'added', ascending: false },
    appearance: 'system',
    language: 'system',
    pageTint: 'none',
    pageTintColor: DEFAULT_TINT_COLOR,
    pageLayout: 'continuous',
    selectedPaperID: null,
    latexShortcuts: true,
    semanticSearch: true,
    listSubtitle: 'authors,year,venue',
    bibtexProtectCase: true,
    bibtexPreprintStyle: 'eprint',
    bibtexIncludeUnverified: false,
    sketchStyle: null,
  },
  windowState: { maximized: false, fullScreen: false, focused: true },
  trail: [],
  trailIndex: -1,
  travelling: false,
  searchQuery: '',
  searchPassages: [],
  searchScanning: false,
  searchMeanings: [],
  focus: { on: false, before: { paperList: true, inspector: true } },
  sketch: { tool: 'select', lastShape: 'rectangle', lastInk: 'pen', style: new SketchStyle(), selection: null },
}

/**
 * What can change, for the panes to decide whether they care. A name nobody
 * listens for is a name the compiler no longer lets anyone emit.
 *
 * - `papers`: the library's rows, or a paper's record, or the open shelf.
 * - `shelf`: which shelf is showing.
 * - `selection`: the paper in focus.
 * - `reader`: the reader in focus should redraw its chrome.
 * - `history`: Back or Forward became possible or impossible.
 * - `inspector`, `marks`, `notes`, `slipBox`, `sketch`, `settings`: their panes.
 * - `searchResults`: the list's passages for the search shelf arrived.
 */
export type Change =
  | 'papers' | 'shelf' | 'selection' | 'reader' | 'history'
  | 'inspector' | 'marks' | 'notes' | 'slipBox' | 'sketch' | 'settings' | 'searchResults'

type Listener = (changed: Set<Change>) => void
const listeners = new Set<Listener>()

export function subscribe(listener: Listener): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/**
 * Announces what changed so each pane can decide whether it cares. Re-rendering
 * the reader because a sidebar row was hovered would throw away a page of
 * canvases for nothing.
 */
/**
 * The folders inside folders, which is what a term of lectures looks like.
 *
 * All of this is read off the papers rather than off the disk: the tree is
 * then exactly what the list can show, and it costs no round trip on a cloud
 * folder. The same is true on the Mac (`LibraryModel.subfolders(of:)`), and
 * the two have to agree because they are looking at the same folder.
 *
 * Every comparison is done with `/`, because a record says `/` on every
 * desktop while a root on Windows says `\`.
 */
export { slashed }

/** The folder a paper's PDF sits in, or null when the record says nothing. */
export function folderOf(entry: Paper): string | null {
  const relative = String(entry.meta.file?.relativePath ?? '')
  if (!relative || !entry.root) return null
  const parts = slashed(relative).split('/')
  parts.pop()
  return [slashed(entry.root), ...parts].join('/')
}

/** Whether a paper sits at or under a folder — a term shows the term. */
export function isUnderFolder(entry: Paper, folder: string): boolean {
  const here = folderOf(entry)
  if (here === null) return samePath(entry.root ?? '', folder)
  return isUnder(here, folder)
}

/** The folders one step inside this one that hold papers, and how many each
 *  holds counting everything beneath it. */
export function subfolders(folder: string): { path: string; name: string; count: number }[] {
  const base = slashed(folder)
  const counts = new Map<string, number>()
  for (const entry of store.papers) {
    if (entry.meta.parentID) continue
    const here = folderOf(entry)
    if (here === null || !isInside(here, base)) continue
    // The same number of letters either way: only case is folded.
    const name = here.slice(base.length + 1).split('/')[0]
    if (!name) continue
    counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  return [...counts]
    .map(([name, count]) => ({ path: `${base}/${name}`, name, count }))
    // Finder's order: «Week 2» before «Week 10» (`localizedStandardCompare`).
    .sort((a, b) => standardOrder.compare(a.name, b.name))
}

/**
 * The shelf's papers gathered by the folder they sit in, or null.
 *
 * A kind's shelf takes papers out of every folder at once — the whole point
 * of it — and sixty rows from four folders in one run is sixty rows you
 * cannot place. Null everywhere else: a folder's own shelf is already one
 * folder, and a heading over one group is a label on a thing with no
 * counterpart. The Mac does the same (`LibraryModel.visibleByFolder`).
 */
export function papersByFolder(papers: Paper[]): { label: string; papers: Paper[] }[] | null {
  if (store.shelf.kind !== 'kind') return null
  const groups = new Map<string, { folder: string; papers: Paper[] }>()
  for (const entry of papers) {
    const here = folderOf(entry) ?? slashed(entry.root ?? '')
    const key = pathKey(here)
    const found = groups.get(key)
    if (found) found.papers.push(entry)
    else groups.set(key, { folder: here, papers: [entry] })
  }
  if (groups.size < 2) return null
  return [...groups.values()]
    .map(({ folder, papers: found }) => ({ label: folderLabel(folder), papers: found }))
    .sort((a, b) => standardOrder.compare(a.label, b.label))
}

/** A folder said the way somebody reads it aloud: the library's name, then
 *  the way down. The whole path would be a line of machinery. */
export function folderLabel(folder: string): string {
  // Split on either separator: the first step is the root as it is stored —
  // `D:\Papers` on Windows — and that spelt the whole drive path into the
  // heading.
  return folderTrail(folder).map((one) => one.split(/[\\/]/).filter(Boolean).pop() ?? one).join(' › ')
}

/** The way down to this folder from its library root, root first. */
export function folderTrail(folder: string): string[] {
  const base = slashed(folder)
  // The root as the library row has it — `D:\Papers`, not `D:/Papers` — so
  // the first step of the way down is that row, and lights it.
  const root = store.roots.find((one) => isUnder(base, one))
  if (!root) return [folder]
  const rest = base.slice(slashed(root).length).split('/').filter(Boolean)
  const trail = [root]
  let at = slashed(root)
  for (const part of rest) {
    at = `${at}/${part}`
    trail.push(at)
  }
  return trail
}

/** Where pressing an open folder again goes, or null at a library root. */
export function folderAbove(folder: string): string | null {
  const base = slashed(folder)
  if (findPath(store.roots, base)) return null
  const cut = base.lastIndexOf('/')
  if (cut <= 0) return null
  const above = base.slice(0, cut)
  // Up to the library itself: the root as it is stored, so the library row
  // lights and a PDF added now goes into that library.
  return findPath(store.roots, above) ?? above
}

export function changed(...keys: Change[]) {
  const set = new Set(keys)
  for (const listener of listeners) listener(set)
}

/**
 * The library would not be read.
 *
 * Kept, not shrugged off. Whatever is on screen stays there — a folder that
 * failed to answer once usually answers a moment later — but the window stops
 * behaving as though nothing had happened. Every caller of this used to be a
 * bare `return`, and one of them fell through to a window offering to choose a
 * library folder over a folder that was already chosen.
 */
export function failed(message: string) {
  store.error = message
  store.ready = true
}

/** A note as it came over the bridge, with its dates back. */
export function noteFromDTO(dto: NoteDTO): Note {
  return {
    id: dto.id, kind: dto.kind, title: dto.title, body: dto.body, paperID: dto.paperID,
    created: new Date(dto.created), modified: new Date(dto.modified), box: dto.box,
  }
}

export function noteDTO(note: Note): NoteDTO {
  return {
    id: note.id, kind: note.kind, title: note.title, body: note.body, paperID: note.paperID,
    created: note.created.getTime(), modified: note.modified.getTime(), box: note.box,
  }
}

export function noteByID(id: string): Note | undefined {
  return store.notes.find((note) => note.id === id)
}

/** The notes written while reading one paper, newest first. */
export function notesForPaper(paperID: string): Note[] {
  return store.notes.filter((note) => note.paperID === paperID).reverse()
}

export function adopt(snapshot: LibrarySnapshot) {
  store.unreadable = snapshot.unreadable ?? []
  store.root = snapshot.root
  store.roots = snapshot.roots ?? (snapshot.root ? [snapshot.root] : [])
  store.papers = snapshot.papers.map(toPaper)
  store.collections = ((snapshot.collections?.collections as Collection[]) ?? []).slice()
  store.tags = ((snapshot.manifest?.tags as Tag[]) ?? []).slice()
  store.looseCount = snapshot.looseCount
  store.refused = snapshot.refused ?? []
  store.ready = true
  store.error = null
  store.unavailable = null
}

function toPaper(row: PaperRowDTO): Paper {
  return {
    id: row.id,
    meta: new PaperMeta(row.meta),
    state: new PaperState(row.state),
    exists: row.exists,
    root: row.root,
  }
}

/**
 * The papers by identifier, and the two shelves as sets.
 *
 * All three were being walked linearly from inside loops over the library —
 * every row in the list asked whether it was pinned and whether it was open,
 * and the reader asked for papers by identifier on every redraw. The arrays
 * are never mutated in place, always replaced, so holding the array a set was
 * made from is enough to know the set is still the answer.
 */
let papersByID: Map<string, Paper> | null = null
let papersIndexed: Paper[] | null = null
let openSet: Set<string> | null = null
let openIndexed: string[] | null = null
let pinnedSet: Set<string> | null = null
let pinnedIndexed: string[] | null = null

export function paper(id: string | null): Paper | null {
  if (!id) return null
  if (papersIndexed !== store.papers || !papersByID) {
    papersByID = new Map(store.papers.map((entry) => [entry.id, entry]))
    papersIndexed = store.papers
  }
  return papersByID.get(id) ?? null
}

/**
 * The supplements that hang off a paper — every paper whose `parentID` is it.
 * Worked out once per read of the library: every row asks.
 */
let childrenByParent: Map<string, Paper[]> | null = null
let childrenIndexed: Paper[] | null = null

export function attachmentsOf(id: string): Paper[] {
  if (childrenIndexed !== store.papers || !childrenByParent) {
    childrenByParent = new Map()
    for (const entry of store.papers) {
      const parent = entry.meta.parentID
      if (!parent) continue
      const list = childrenByParent.get(parent)
      if (list) list.push(entry)
      else childrenByParent.set(parent, [entry])
    }
    childrenIndexed = store.papers
  }
  return childrenByParent.get(id) ?? []
}

/** A tag by identifier, without walking the tags for every row. */
let tagsByID: Map<string, Tag> | null = null
let tagsIndexed: Tag[] | null = null

export function tagByID(id: string): Tag | undefined {
  if (tagsIndexed !== store.tags || !tagsByID) {
    tagsByID = new Map(store.tags.map((tag) => [tag.id, tag]))
    tagsIndexed = store.tags
  }
  return tagsByID.get(id)
}

// MARK: - The open shelf

export function isOpenPaper(id: string): boolean {
  if (openIndexed !== store.openPaperIDs || !openSet) {
    openSet = new Set(store.openPaperIDs)
    openIndexed = store.openPaperIDs
  }
  return openSet.has(id)
}

/**
 * Keeps a paper on the open shelf.
 *
 * `byHand` is somebody asking — the pin, the row's menu, a paper put beside
 * another. Clicking into a paper is not that: for a while both lit the pin
 * at the head of the row, so reading a paper appeared to pin it, and a pin
 * is something you do. What the app does on its own is visible on the shelf
 * and nowhere else.
 */
export function keepOpen(id: string, byHand = false) {
  if (!paper(id)) return
  if (byHand) store.pinnedPaperIDs = [...new Set([...store.pinnedPaperIDs, id])]
  if (store.openPaperIDs.includes(id)) return
  store.openPaperIDs = [...store.openPaperIDs, id]
}

export function isPinned(id: string): boolean {
  if (pinnedIndexed !== store.pinnedPaperIDs || !pinnedSet) {
    pinnedSet = new Set(store.pinnedPaperIDs)
    pinnedIndexed = store.pinnedPaperIDs
  }
  return pinnedSet.has(id)
}

/**
 * Takes a paper off the open shelf. If it was the one showing, its neighbour
 * on the shelf comes forward; with the shelf empty, nothing is showing.
 */
export function closeOpenPaper(id: string) {
  store.pinnedPaperIDs = store.pinnedPaperIDs.filter((entry) => entry !== id)
  const at = store.openPaperIDs.indexOf(id)
  if (at >= 0) store.openPaperIDs = store.openPaperIDs.filter((entry) => entry !== id)
  if (store.selectedID !== id) return
  const next = at >= 0 && at < store.openPaperIDs.length
    ? store.openPaperIDs[at]
    : store.openPaperIDs[store.openPaperIDs.length - 1]
  store.selectedID = next ?? null
}

export function closeOtherOpenPapers(keeping: string) {
  // The pins go too: a closed paper that still answers «pinned» keeps a
  // filled pin on every shelf that closes nothing when pressed.
  store.pinnedPaperIDs = store.pinnedPaperIDs.filter((entry) => entry === keeping)
  store.openPaperIDs = store.openPaperIDs.filter((entry) => entry === keeping)
  if (store.selectedID !== keeping) store.selectedID = keeping
}

// MARK: - The rows chosen

export type PickMode = 'only' | 'extend' | 'toggle'

export interface Picking {
  selection: string[]
  anchor: string | null
  showing: string | null
}

/** The rows chosen: the selection, or the paper showing alone. */
export function selectedPapers(): string[] {
  const showing = store.selectedID
  if (!showing) return []
  return store.selection.includes(showing) ? store.selection : [showing]
}

let selectedSet: Set<string> | null = null
let selectedFor: { selection: string[]; showing: string | null } | null = null

export function isSelected(id: string): boolean {
  if (!selectedFor || selectedFor.selection !== store.selection || selectedFor.showing !== store.selectedID || !selectedSet) {
    selectedSet = new Set(selectedPapers())
    selectedFor = { selection: store.selection, showing: store.selectedID }
  }
  return selectedSet.has(id)
}

/** What a drag that starts on this row carries: every chosen row when it is
 *  one of them, else itself — `draggedPapers(startingAt:)`. */
export function draggedFrom(id: string): string[] {
  const chosen = selectedPapers()
  return chosen.includes(id) ? chosen : [id]
}

/** Which paper shows once the rows chosen change — the Mac's
 *  `selection.didSet`: one row is that paper, none is nothing, and a paper
 *  still among many stays. */
function showingFor(selection: string[], showing: string | null, pressed: string | null): string | null {
  if (selection.length === 0) return null
  if (selection.length === 1) return selection[0]
  if (showing && selection.includes(showing)) return showing
  return pressed && selection.includes(pressed) ? pressed : selection[selection.length - 1]
}

/**
 * A row pressed, the three things a list does (`PaperTable.clicked`): a
 * plain press is this row alone, shift takes the run from the last row
 * pressed to this one, and Ctrl (⌘ on a Mac) adds or drops this one.
 * `order` is the list's rows, top to bottom.
 */
export function pickRow(now: Picking, id: string, mode: PickMode, order: string[]): Picking {
  const current = now.showing
    ? (now.selection.includes(now.showing) ? now.selection : [now.showing])
    : now.selection
  if (mode === 'extend' && now.anchor) {
    const from = order.indexOf(now.anchor)
    const to = order.indexOf(id)
    if (from >= 0 && to >= 0) {
      const run = order.slice(Math.min(from, to), Math.max(from, to) + 1)
      const selection = [...current, ...run.filter((one) => !current.includes(one))]
      return { selection, anchor: now.anchor, showing: showingFor(selection, now.showing, id) }
    }
  }
  if (mode === 'toggle') {
    const selection = current.includes(id) ? current.filter((one) => one !== id) : [...current, id]
    return { selection, anchor: id, showing: showingFor(selection, now.showing, id) }
  }
  return { selection: [id], anchor: id, showing: id }
}

/** ⇧↑ and ⇧↓: the run from the anchor to the row the keyboard has got to,
 *  and nothing else — the way a list's keyboard extends. */
export function extendRun(now: Picking, lead: string, order: string[]): Picking {
  const anchor = now.anchor && order.includes(now.anchor) ? now.anchor : (now.showing ?? lead)
  const from = order.indexOf(anchor)
  const to = order.indexOf(lead)
  if (from < 0 || to < 0) return { selection: [lead], anchor: lead, showing: lead }
  const selection = order.slice(Math.min(from, to), Math.max(from, to) + 1)
  return { selection, anchor, showing: showingFor(selection, now.showing, lead) }
}

// MARK: - Side by side

/**
 * Puts a paper into a zone of the page area. With nothing side by side yet,
 * the paper already showing takes the other half. Put beside another, a
 * paper is in use: every paper in the arrangement stays on the open shelf.
 */
export function dock(id: string, zone: DockZone) {
  const current = store.selectedID
  const base: SplitArrangement = store.split
    ?? (current ? { left: { top: current } } : { left: { top: id } })
  const arrangement = splitDock(base, id, zone)
  // Put beside another by hand, a paper is pinned — the Mac's `dock`.
  for (const entry of splitPapers(arrangement)) keepOpen(entry, true)
  store.split = splitPapers(arrangement).length > 1 ? arrangement : null
  if (current === null) store.selectedID = id
}

/**
 * Takes a paper out of the side-by-side arrangement. One pane left is no
 * arrangement at all; that paper is simply the one showing.
 */
export function undock(id: string) {
  const arrangement = store.split
  if (!arrangement || !splitContains(arrangement, id)) return
  const remaining = splitRemove(arrangement, id)
  const papers = splitPapers(remaining)
  if (papers.length <= 1) {
    store.split = null
    const last = papers[0]
    if (last && (store.selectedID === id || store.selectedID === null)) store.selectedID = last
  } else {
    store.split = remaining
    if (store.selectedID === id) store.selectedID = papers[0]
  }
}

/** The papers in panes, left column first — or just the one showing. */
export function panePapers(): string[] {
  if (store.split) return splitPapers(store.split)
  return store.selectedID ? [store.selectedID] : []
}

// MARK: - The trail behind the arrows

/**
 * Records a paper as opened.
 *
 * Browser semantics, and deliberately so: going back and then opening
 * something else forgets what lay ahead, because the forward list described a
 * path you have now left. Opening the paper you are already on is not a step.
 */
export function remember(id: string | null) {
  if (!id) return
  if (store.trail[store.trailIndex] === id) return
  if (store.trailIndex < store.trail.length - 1) {
    store.trail = store.trail.slice(0, store.trailIndex + 1)
  }
  store.trail.push(id)
  store.trailIndex = store.trail.length - 1
}

/** The next step along the trail that would show something: not the paper
 *  already showing — the step would do nothing, and Back would seem to stick
 *  — and not one that has left the library. */
function stepAlong(by: 1 | -1): number | null {
  for (let at = store.trailIndex + by; at >= 0 && at < store.trail.length; at += by) {
    const id = store.trail[at]
    if (id !== store.selectedID && paper(id)) return at
  }
  return null
}

export const canGoBack = () => stepAlong(-1) !== null
export const canGoForward = () => stepAlong(1) !== null

/** Walks the trail one showable step, and says which paper that is. */
export function travelBy(by: 1 | -1): string | null {
  const at = stepAlong(by)
  if (at === null) return null
  store.trailIndex = at
  return store.trail[at]
}

// MARK: - Changing the store

/**
 * Chooses a shelf. The Notes shelf shows the slip-box, so a paper the
 * slip-box put in the page area last time is let go of — by every way in.
 */
export function setShelf(shelf: Shelf) {
  store.shelf = shelf
  if (shelf.kind === 'notes') store.slipBox.paperID = null
}

/**
 * One paper's record as the main process just wrote it, put in place without
 * reading the library again. A star used to cost a read of every record in
 * every folder, and the watcher read them all once more.
 *
 * The array is replaced, never changed in place: the indexes above are kept
 * by the array they were made from.
 */
export function patchPaper(id: string, written: { meta?: Record<string, unknown> | null; state?: Record<string, unknown> | null }) {
  const at = store.papers.findIndex((entry) => entry.id === id)
  if (at < 0) return
  const before = store.papers[at]
  const next: Paper = {
    ...before,
    meta: written.meta ? new PaperMeta(written.meta as never) : before.meta,
    state: written.state ? new PaperState(written.state as never) : before.state,
  }
  store.papers = [...store.papers.slice(0, at), next, ...store.papers.slice(at + 1)]
}

/**
 * Lets go of every paper that has left the library: off the open shelf, out
 * of the panes, off the trail, out of the page area the slip-box lent it.
 * One place, run on every reading — three of the four ways a library is read
 * again used to do part of this, and the fourth none of it.
 */
export function pruneToLibrary() {
  const here = (id: string | null) => Boolean(id && paper(id))
  if (store.openPaperIDs.some((id) => !here(id))) store.openPaperIDs = store.openPaperIDs.filter(here)
  if (store.pinnedPaperIDs.some((id) => !here(id))) store.pinnedPaperIDs = store.pinnedPaperIDs.filter(here)
  if (store.selection.some((id) => !here(id))) store.selection = store.selection.filter(here)
  for (const id of panePapers()) if (!here(id)) undock(id)
  if (store.selectedID && !here(store.selectedID)) store.selectedID = null
  if (store.slipBox.paperID && !here(store.slipBox.paperID)) store.slipBox.paperID = null
  if (store.trail.some((id) => !here(id))) {
    const trail: string[] = []
    let index = -1
    store.trail.forEach((id, at) => {
      if (here(id) && trail[trail.length - 1] !== id) trail.push(id)
      if (at === store.trailIndex) index = trail.length - 1
    })
    store.trail = trail
    store.trailIndex = trail.length === 0 ? -1 : Math.max(0, index)
  }
}

// MARK: - Which papers a shelf holds

export function shelfPapers(): Paper[] {
  const all = store.papers.filter((entry) => !entry.meta.parentID)
  let filtered = all
  switch (store.shelf.kind) {
    case 'all': break
    case 'kind': {
      const of = (store.shelf as { kind: 'kind'; of: DocumentKind }).of
      filtered = all.filter((entry) => entry.meta.effectiveKind === of)
      break
    }
    case 'folder': {
      const root = (store.shelf as { kind: 'folder'; root: string }).root
      filtered = all.filter((entry) => isUnderFolder(entry, root))
      break
    }
    case 'open': {
      // In the order they were kept, not the list's sort: this shelf is a
      // row of tabs. The preview — showing, not kept — is last.
      const ids = [...store.openPaperIDs]
      if (store.selectedID && !ids.includes(store.selectedID)) ids.push(store.selectedID)
      return ids.map((id) => paper(id)).filter((entry): entry is Paper => Boolean(entry) && !entry!.meta.parentID)
    }
    case 'status':
      filtered = all.filter((entry) => entry.state.readingStatus === (store.shelf as never as { status: string }).status)
      break
    case 'favorites':
      filtered = all.filter((entry) => entry.state.isFavorite)
      break
    case 'review':
      // Neither a book nor a document has a registrar to disagree with, so
      // neither is ever a thing to review.
      filtered = all.filter((entry) => needsReview(entry.meta))
      break
    case 'notes': {
      // The papers with a note written against them, for the arrows to
      // walk; the column itself shows the slip-box.
      const noted = new Set(store.notes.map((note) => note.paperID))
      filtered = all.filter((entry) => noted.has(entry.id))
      break
    }
    case 'collection': {
      // A smart collection is whoever its rule matches — the Mac's
      // `SmartRuleEvaluator`; filtering by membership left every smart
      // collection made there empty here.
      const id = (store.shelf as { kind: 'collection'; id: string }).id
      const collection = store.collections.find((entry) => entry.id === id)
      filtered = collection
        ? all.filter((entry) => inCollection(collection, entry.meta, entry.state, store.tags))
        : all.filter((entry) => entry.meta.collectionIDs.includes(id))
      break
    }
    case 'tag': {
      const id = (store.shelf as { kind: 'tag'; id: string }).id
      filtered = all.filter((entry) => entry.meta.tagIDs.includes(id))
      break
    }
    case 'author': {
      const key = (store.shelf as { kind: 'author'; key: string }).key
      filtered = all.filter((entry) => authorKeysOf(entry).has(key))
      break
    }
    case 'search':
      filtered = all.filter((entry) => matchesSearch(entry, store.searchQuery))
      break
  }
  return sorted(filtered)
}

/**
 * Whether two shelves are the same shelf — which row is lit. Every kind of
 * shelf by what tells it apart: comparing only `kind` lit all four kind rows
 * at once, and a folder by its path as the desktop compares paths.
 */
export function sameShelf(a: Shelf, b: Shelf): boolean {
  if (a.kind !== b.kind) return false
  switch (a.kind) {
    case 'collection': return a.id === (b as typeof a).id
    case 'tag': return a.id === (b as typeof a).id
    case 'author': return a.key === (b as typeof a).key
    case 'status': return a.status === (b as typeof a).status
    case 'folder': return samePath(a.root, (b as typeof a).root)
    case 'kind': return a.of === (b as typeof a).of
    default: return true
  }
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
export interface ShelfCounts {
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

export function shelfCounts(papers: Paper[]): ShelfCounts {
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
    if (needsReview(entry.meta)) counts.review += 1
    for (const id of entry.meta.collectionIDs) bump(counts.collections, id)
    for (const id of entry.meta.tagIDs) bump(counts.tags, id)
  }
  // Every note in the box, as the Mac's row counts them — not the papers.
  counts.notes = store.notes.length
  // A smart collection has no members written down — its count is whoever
  // its rule matches, the same papers its shelf shows.
  for (const collection of store.collections) {
    if (!collection.rule) continue
    counts.collections.set(collection.id, papers.filter((entry) =>
      inCollection(collection, entry.meta, entry.state, store.tags)).length)
  }
  return counts
}

// MARK: - Searching

/** A paper as search reads it. */
export function searchable(entry: Paper): SearchablePaper {
  return {
    id: entry.id,
    title: entry.meta.displayTitle,
    authors: entry.meta.csl.author ?? [],
    displayAuthors: entry.meta.displayAuthors,
    venue: entry.meta.venue,
    year: entry.meta.year,
    bibKey: entry.meta.bibKey,
    originalName: entry.meta.file.originalName,
    parentID: entry.meta.parentID,
    lastOpenedAt: entry.state.lastOpenedAt,
  }
}

/**
 * Each paper's folded fields, worked out once per read of the library rather
 * than once per paper per keystroke — the list and the sidebar's count both
 * ask on every redraw.
 */
let haystacks: Map<string, string> | null = null
let haystacksFor: Paper[] | null = null

function haystackOf(entry: Paper): string {
  if (haystacksFor !== store.papers || !haystacks) {
    haystacks = new Map()
    haystacksFor = store.papers
  }
  let known = haystacks.get(entry.id)
  if (known === undefined) {
    known = paperHaystack(searchable(entry))
    haystacks.set(entry.id, known)
  }
  return known
}

/** Whether a paper is one the search shelf shows — `LibraryModel.matches`. */
export function matchesSearch(entry: Paper, query: string): boolean {
  const folded = foldTitle(query.trim())
  if (!folded) return false
  return haystackOf(entry).includes(folded)
}

/** How many papers the search shelf holds, for the sidebar's count. */
export function searchCount(): number {
  if (!store.searchQuery) return 0
  return store.papers.filter((entry) => !entry.meta.parentID && matchesSearch(entry, store.searchQuery)).length
}

/**
 * The papers whose text is searched, the one opened most recently first —
 * which is nearly always the one the answer is in — leaving out the ones
 * already named: a paper about unlearning says so on its first page, and
 * listing it again under its own title quoted back says nothing new.
 */
export function textSources(excluding: Set<string> = new Set()): { id: string; title: string }[] {
  return store.papers
    .filter((entry) => !entry.meta.parentID && entry.exists && !excluding.has(entry.id))
    .sort((a, b) => (b.state.lastOpenedAt?.getTime() ?? 0) - (a.state.lastOpenedAt?.getTime() ?? 0))
    .map((entry) => ({ id: entry.id, title: entry.meta.displayTitle }))
}

/** The people on a paper, one key each (`LibraryModel.authorKeys(of:)`). */
export function authorKeysOf(entry: Paper): Set<string> {
  const keys = new Set<string>()
  for (const name of entry.meta.csl.author ?? []) {
    const key = authorKey(name)
    if (key) keys.add(key)
  }
  return keys
}

/**
 * The shelf's order, the Mac's `comparator`: a title by its words, case
 * aside; an author by the first author's surname, and a paper nobody wrote
 * after everybody who did; a year, and a paper with none before the rest.
 * The direction turns every one of them round, and papers that tie keep the
 * order they came in (the sort is stable) — breaking a tie by title while
 * ignoring the direction read a descending list A to Z inside each year.
 */
export function sorted(papers: Paper[], sort: { field: string; ascending: boolean } = store.settings.sort): Paper[] {
  const { field, ascending } = sort
  const direction = ascending ? 1 : -1
  const key = (entry: Paper): string | number => {
    switch (field) {
      case 'title': return entry.meta.displayTitle
      case 'author': {
        const first = entry.meta.csl.author?.[0]
        return (first && sortingSurname(first)) || 'zzz'
      }
      case 'year': return entry.meta.year ?? 0
      case 'opened': return entry.state.lastOpenedAt?.getTime() ?? 0
      case 'added': default: return entry.meta.addedAt.getTime()
    }
  }
  // Each paper's key worked out once, not once per comparison.
  const keyed = papers.map((entry) => ({ entry, key: key(entry) }))
  keyed.sort((a, b) => {
    const order = typeof a.key === 'string' && typeof b.key === 'string'
      ? caseInsensitiveOrder.compare(a.key, b.key)
      : (a.key as number) - (b.key as number)
    return order * direction
  })
  return keyed.map((row) => row.entry)
}

/**
 * Every author in the library, ranked the Mac's way (`rebuildAuthorRanking`):
 * one row per person however their name was written, the fullest spelling
 * seen, counted over the papers a shelf shows — not their supplements, or
 * the row said twelve where the shelf held ten — most papers first.
 *
 * Worked out when the library changes, not when the list is drawn.
 */
let authorsCounted: { key: string; name: string; count: number }[] | null = null
let authorsFor: Paper[] | null = null

export function authorCounts(): { key: string; name: string; count: number }[] {
  if (authorsFor === store.papers && authorsCounted) return authorsCounted
  const counts = new Map<string, number>()
  const names = new Map<string, string>()
  for (const entry of store.papers) {
    if (entry.meta.parentID) continue
    const seen = new Set<string>()
    for (const author of entry.meta.csl.author ?? []) {
      const key = authorKey(author)
      if (!key) continue
      // Once per paper: a name written twice on one paper is one paper.
      if (!seen.has(key)) counts.set(key, (counts.get(key) ?? 0) + 1)
      seen.add(key)
      const shown = nameShown(author)
      // «Yann LeCun» over «Y. LeCun».
      if ([...shown].length > [...(names.get(key) ?? '')].length) names.set(key, shown)
    }
  }
  authorsCounted = [...counts]
    .map(([key, count]) => ({ key, name: names.get(key) ?? key, count }))
    .sort((a, b) => (a.count === b.count ? caseInsensitiveOrder.compare(a.name, b.name) : b.count - a.count))
  authorsFor = store.papers
  return authorsCounted
}

/** The author shelf for a name as a paper writes it. */
export function authorShelf(name: import('../shared/model.js').CSLName): Shelf | null {
  const key = authorKey(name)
  if (!key) return null
  const ranked = authorCounts().find((one) => one.key === key)
  return { kind: 'author', key, name: ranked?.name ?? nameShown(name) }
}

export const STROKE_COLORS = SketchColor.strokes
export const FILL_COLORS = SketchColor.fills
