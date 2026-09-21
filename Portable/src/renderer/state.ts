/**
 * What the window knows, and who to tell when it changes.
 *
 * No framework. The app has four panes and one document open at a time, and a
 * store with a subscriber list renders it in a few milliseconds — which keeps
 * the whole renderer readable, and keeps the Windows build and the Linux build
 * from differing by way of somebody's runtime.
 */
import type { LibrarySnapshot, PaperRowDTO } from '../shared/api.js'
import { type DocumentKind } from '../shared/documentKind.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { SketchColor, SketchStyle } from '../shared/sketch.js'
import { splitContains, splitDock, splitPapers, splitRemove, type DockZone, type SplitArrangement } from '../shared/split.js'

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
  pageTint: 'none' | 'sepia' | 'grey' | 'night'
  pageLayout: 'single' | 'continuous'
  selectedPaperID: string | null
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
  root: string | null
  /** Every folder being read, the first one first. */
  roots: string[]
  papers: Paper[]
  collections: Collection[]
  tags: Tag[]
  looseCount: number
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
  root: null,
  roots: [],
  papers: [],
  collections: [],
  tags: [],
  looseCount: 0,
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
    pageTint: 'none',
    pageLayout: 'continuous',
    selectedPaperID: null,
  },
  windowState: { maximized: false, fullScreen: false, focused: true },
  trail: [],
  trailIndex: -1,
  travelling: false,
  search: { open: false, query: '' },
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
export function changed(...keys: string[]) {
  const set = new Set(keys)
  for (const listener of listeners) listener(set)
}

export function adopt(snapshot: LibrarySnapshot) {
  store.root = snapshot.root
  store.roots = snapshot.roots ?? (snapshot.root ? [snapshot.root] : [])
  store.papers = snapshot.papers.map(toPaper)
  store.collections = ((snapshot.collections?.collections as Collection[]) ?? []).slice()
  store.tags = ((snapshot.manifest?.tags as Tag[]) ?? []).slice()
  store.looseCount = snapshot.looseCount
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

export function paper(id: string | null): Paper | null {
  if (!id) return null
  return store.papers.find((entry) => entry.id === id) ?? null
}

// MARK: - The open shelf

export function isOpenPaper(id: string): boolean {
  return store.openPaperIDs.includes(id)
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
  return store.pinnedPaperIDs.includes(id)
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
      filtered = all.filter((entry) => entry.root === root)
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
      // A document has no registrar to disagree with, so it is never a thing
      // to review.
      filtered = all.filter((entry) => entry.meta.effectiveKind === 'paper'
        && (entry.meta.confidence === 'needsReview' || entry.meta.confidence === 'unparsed'))
      break
    case 'notes':
      filtered = all.filter((entry) => entry.state.summaryNote.trim().length > 0)
      break
    case 'collection': {
      const id = (store.shelf as { kind: 'collection'; id: string }).id
      filtered = all.filter((entry) => entry.meta.collectionIDs.includes(id))
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
  }
  return sorted(filtered)
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
  return [...papers].sort((a, b) => {
    const left = key(a)
    const right = key(b)
    if (left === right) return a.meta.displayTitle.localeCompare(b.meta.displayTitle)
    return (left < right ? -1 : 1) * direction
  })
}

/** Every author in the library, with how many papers each one has. */
export function authorCounts(): { name: string; count: number }[] {
  const counts = new Map<string, number>()
  for (const entry of store.papers) {
    for (const name of authorsOf(entry)) {
      counts.set(name, (counts.get(name) ?? 0) + 1)
    }
  }
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

export const STROKE_COLORS = SketchColor.strokes
export const FILL_COLORS = SketchColor.fills
