/**
 * What the window knows, and who to tell when it changes.
 *
 * No framework. The app has four panes and one document open at a time, and a
 * store with a subscriber list renders it in a few milliseconds — which keeps
 * the whole renderer readable, and keeps the Windows build and the Linux build
 * from differing by way of somebody's runtime.
 */
import type { LibrarySnapshot, PaperRowDTO } from '../shared/api.js'
import { PaperMeta, PaperState, type Collection, type Tag } from '../shared/model.js'
import { SketchColor, SketchStyle } from '../shared/sketch.js'

export type Pane = 'sidebar' | 'paperList' | 'reader' | 'inspector'
export type InspectorTab = 'details' | 'marks' | 'note' | 'tools'
export type SketchTool =
  | 'select' | 'frame' | 'pen' | 'highlighter' | 'eraser'
  | 'rectangle' | 'ellipse' | 'arrow' | 'line' | 'text'

/** Which shelf of the library is showing. */
export type Shelf =
  | { kind: 'all' }
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

export interface Store {
  ready: boolean
  error: string | null
  root: string | null
  papers: Paper[]
  collections: Collection[]
  tags: Tag[]
  looseCount: number
  shelf: Shelf
  selectedID: string | null
  settings: Settings
  windowState: { maximized: boolean; fullScreen: boolean; focused: boolean }
  /** The papers opened, in order — what the back and forward arrows walk. */
  trail: string[]
  trailIndex: number
  /** Set while travelling, so the trail does not record its own footsteps. */
  travelling: boolean
  search: { open: boolean; query: string }
  toast: string | null
  reader: {
    pageCount: number
    currentPage: number
    zoom: number
    /** The pen is out: the page takes the mouse instead of the text layer. */
    drawing: boolean
  }
  sketch: {
    tool: SketchTool
    style: SketchStyle
    /** Which page's elements are selected, and which of them. */
    selection: { pageIndex: number; ids: string[]; strokeIDs: number[] } | null
  }
}

export const store: Store = {
  ready: false,
  error: null,
  root: null,
  papers: [],
  collections: [],
  tags: [],
  looseCount: 0,
  shelf: { kind: 'all' },
  selectedID: null,
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
  reader: { pageCount: 0, currentPage: 0, zoom: 1, drawing: false },
  sketch: { tool: 'select', style: new SketchStyle(), selection: null },
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
  }
}

export function paper(id: string | null): Paper | null {
  if (!id) return null
  return store.papers.find((entry) => entry.id === id) ?? null
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
    case 'status':
      filtered = all.filter((entry) => entry.state.readingStatus === (store.shelf as never as { status: string }).status)
      break
    case 'favorites':
      filtered = all.filter((entry) => entry.state.isFavorite)
      break
    case 'review':
      filtered = all.filter((entry) => entry.meta.confidence === 'needsReview' || entry.meta.confidence === 'unparsed')
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
