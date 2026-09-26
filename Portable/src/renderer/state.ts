/**
 * What the window knows, and who to tell when it changes.
 *
 * No framework. The app has four panes and one document open at a time, and a
 * store with a subscriber list renders it in a few milliseconds — which keeps
 * the whole renderer readable, and keeps the Windows build and the Linux build
 * from differing by way of somebody's runtime.
 */
import type { LibrarySnapshot, PaperRowDTO } from '../shared/api.js'
import type { TextHit } from '../main/textIndex.js'
import { isLookedUp, type DocumentKind } from '../shared/documentKind.js'
import { foldTitle } from '../shared/textFold.js'
import { paperHaystack, type SearchablePaper } from '../shared/searchRank.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { SketchColor, SketchStyle } from '../shared/sketch.js'
import { splitContains, splitDock, splitPapers, splitRemove, type DockZone, type SplitArrangement } from '../shared/split.js'
import { inCollection } from '../shared/smartRule.js'

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
  | { kind: 'author'; name: string }
  | { kind: 'tag'; id: string }
  /** What the palette's «Show All Results» found: `store.searchQuery`. */
  | { kind: 'search' }

export interface Paper {
  id: string
  meta: PaperMeta
  state: PaperState
  exists: boolean
  /** The folder it came from, when the library reads more than one. */
  root?: string
}

export interface Settings {
  libraryRoot: string | null
  panes: Record<Pane, boolean>
  columns: { sidebar: number; paperList: number; inspector: number }
  inspectorTab: InspectorTab
  sort: { field: 'title' | 'author' | 'year' | 'added' | 'opened'; ascending: boolean }
  appearance: 'system' | 'light' | 'dark'
  /** The words, when the desktop's own language is not what somebody wants. */
  language: 'system' | 'ko' | 'en'
  pageTint: 'none' | 'sepia' | 'grey' | 'night'
  pageLayout: 'single' | 'continuous'
  selectedPaperID: string | null
  /** Latex Suite in the note and on the cards: `@a` into `\alpha`, `//` into a fraction. */
  latexShortcuts: boolean
  /** Search by meaning in the palette. On unless turned off. */
  semanticSearch: boolean
  /** What stands under a title in the list, in order — the Mac's
   *  `listSubtitleFields`, the same comma-separated words. */
  listSubtitle: string
  /** Braces round the capitals of a title in the `.bib`, so a style cannot
   *  lower-case «BERT». The Mac's «Protect Case in Titles». */
  bibtexProtectCase: boolean
}

/** What one reader — one pane — knows about the paper it shows. */
export interface ReaderState {
  pageCount: number
  currentPage: number
  zoom: number
  /** The pen is out: the page takes the mouse instead of the text layer. */
  drawing: boolean
}

export const freshReaderState = (): ReaderState => ({ pageCount: 0, currentPage: 0, zoom: 1, drawing: false })

export interface Store {
  ready: boolean
  error: string | null
  /** Records in the folders this read could not get at, one sentence each. */
  unreadable: string[]
  root: string | null
  /** Every folder being read, the first one first. */
  roots: string[]
  papers: Paper[]
  collections: Collection[]
  tags: Tag[]
  looseCount: number
  /** What the last "add the loose PDFs" could not read, by name. */
  refused: string[]
  shelf: Shelf
  /** The paper showing — with panes side by side, the one in focus. */
  selectedID: string | null
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
  search: { open: boolean; query: string }
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
  toast: string | null
  /** The reader in focus. Each pane has one of these; this is the focused pane's. */
  reader: ReaderState
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
  roots: [],
  papers: [],
  collections: [],
  tags: [],
  looseCount: 0,
  refused: [],
  shelf: { kind: 'all' },
  selectedID: null,
  openPaperIDs: [],
  pinnedPaperIDs: [],
  split: null,
  settings: {
    libraryRoot: null,
    panes: { sidebar: true, paperList: true, reader: true, inspector: true },
    columns: { sidebar: 240, paperList: 320, inspector: 320 },
    inspectorTab: 'details',
    sort: { field: 'added', ascending: false },
    appearance: 'system',
    language: 'system',
    pageTint: 'none',
    pageLayout: 'continuous',
    selectedPaperID: null,
    latexShortcuts: true,
    semanticSearch: true,
    listSubtitle: 'authors,year,venue',
    bibtexProtectCase: true,
  },
  windowState: { maximized: false, fullScreen: false, focused: true },
  trail: [],
  trailIndex: -1,
  travelling: false,
  search: { open: false, query: '' },
  searchQuery: '',
  searchPassages: [],
  searchScanning: false,
  searchMeanings: [],
  toast: null,
  reader: freshReaderState(),
  sketch: { tool: 'select', lastShape: 'rectangle', lastInk: 'pen', style: new SketchStyle(), selection: null },
}

type Listener = (changed: Set<string>) => void
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
const slashed = (path: string) => path.replace(/\\/g, '/').replace(/\/+$/, '')

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
  if (here === null) return slashed(entry.root ?? '') === slashed(folder)
  const base = slashed(folder)
  return here === base || here.startsWith(base + '/')
}

/** The folders one step inside this one that hold papers, and how many each
 *  holds counting everything beneath it. */
export function subfolders(folder: string): { path: string; name: string; count: number }[] {
  const base = slashed(folder)
  const counts = new Map<string, number>()
  for (const entry of store.papers) {
    if (entry.meta.parentID) continue
    const here = folderOf(entry)
    if (here === null || !here.startsWith(base + '/')) continue
    const name = here.slice(base.length + 1).split('/')[0]
    if (!name) continue
    counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  return [...counts]
    .map(([name, count]) => ({ path: `${base}/${name}`, name, count }))
    .sort((a, b) => a.name.localeCompare(b.name))
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
  const groups = new Map<string, Paper[]>()
  for (const entry of papers) {
    const here = folderOf(entry) ?? slashed(entry.root ?? '')
    const found = groups.get(here)
    if (found) found.push(entry)
    else groups.set(here, [entry])
  }
  if (groups.size < 2) return null
  return [...groups]
    .map(([folder, found]) => ({ label: folderLabel(folder), papers: found }))
    .sort((a, b) => a.label.localeCompare(b.label))
}

/** A folder said the way somebody reads it aloud: the library's name, then
 *  the way down. The whole path would be a line of machinery. */
export function folderLabel(folder: string): string {
  return folderTrail(folder).map((one) => one.split('/').filter(Boolean).pop() ?? one).join(' › ')
}

/** The way down to this folder from its library root, root first. */
export function folderTrail(folder: string): string[] {
  const base = slashed(folder)
  const root = store.roots
    .map(slashed)
    .find((one) => base === one || base.startsWith(one + '/'))
  if (!root) return [folder]
  const rest = base.slice(root.length).split('/').filter(Boolean)
  const trail = [root]
  for (const part of rest) trail.push(`${trail[trail.length - 1]}/${part}`)
  return trail
}

/** Where pressing an open folder again goes, or null at a library root. */
export function folderAbove(folder: string): string | null {
  const base = slashed(folder)
  if (store.roots.map(slashed).includes(base)) return null
  const cut = base.lastIndexOf('/')
  return cut > 0 ? base.slice(0, cut) : null
}

export function changed(...keys: string[]) {
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
  store.openPaperIDs = store.openPaperIDs.filter((entry) => entry === keeping)
  if (store.selectedID !== keeping) store.selectedID = keeping
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
  for (const entry of splitPapers(arrangement)) keepOpen(entry)
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

export const canGoBack = () => store.trailIndex > 0
export const canGoForward = () => store.trailIndex < store.trail.length - 1

export function travel(to: number): string | null {
  if (to < 0 || to >= store.trail.length) return null
  store.trailIndex = to
  return store.trail[to]
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
      filtered = all.filter((entry) => isLookedUp(entry.meta.effectiveKind)
        && (entry.meta.confidence === 'needsReview' || entry.meta.confidence === 'unparsed'))
      break
    case 'notes':
      filtered = all.filter((entry) => entry.state.summaryNote.trim().length > 0)
      break
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
      const name = (store.shelf as { kind: 'author'; name: string }).name
      filtered = all.filter((entry) => authorsOf(entry).includes(name))
      break
    }
    case 'search':
      filtered = all.filter((entry) => matchesSearch(entry, store.searchQuery))
      break
  }
  return sorted(filtered)
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

export function authorsOf(entry: Paper): string[] {
  return (entry.meta.csl.author ?? [])
    .map((name) => [name.given, name.family].filter(Boolean).join(' ').trim())
    .filter(Boolean)
}

function sorted(papers: Paper[]): Paper[] {
  const { field, ascending } = store.settings.sort
  const direction = ascending ? 1 : -1
  const key = (entry: Paper): string | number => {
    switch (field) {
      case 'title': return entry.meta.displayTitle.toLowerCase()
      case 'author': return entry.meta.displayAuthors.toLowerCase()
      case 'year': return entry.meta.year ?? 0
      case 'opened': return entry.state.lastOpenedAt?.getTime() ?? 0
      case 'added': default: return entry.meta.addedAt.getTime()
    }
  }
  // Each paper's key worked out once, not once per comparison. Sorting sixty
  // papers makes some three hundred comparisons, and every one of them was
  // lower-casing two titles to answer a question it had answered before.
  const keyed = papers.map((entry) => ({ entry, key: key(entry), title: entry.meta.displayTitle }))
  keyed.sort((a, b) => {
    if (a.key === b.key) return a.title.localeCompare(b.title)
    return (a.key < b.key ? -1 : 1) * direction
  })
  return keyed.map((row) => row.entry)
}

/**
 * Every author in the library, with how many papers each one has.
 *
 * Worked out when the library changes, not when the list is drawn: this walks
 * every author of every paper and then sorts a few hundred names, and the
 * sidebar asks for it on every redraw.
 */
let authorsCounted: { name: string; count: number }[] | null = null
let authorsFor: Paper[] | null = null

export function authorCounts(): { name: string; count: number }[] {
  if (authorsFor === store.papers && authorsCounted) return authorsCounted
  const counts = new Map<string, number>()
  for (const entry of store.papers) {
    for (const name of authorsOf(entry)) {
      counts.set(name, (counts.get(name) ?? 0) + 1)
    }
  }
  authorsCounted = [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => a.name.localeCompare(b.name))
  authorsFor = store.papers
  return authorsCounted
}

export const STROKE_COLORS = SketchColor.strokes
export const FILL_COLORS = SketchColor.fills
