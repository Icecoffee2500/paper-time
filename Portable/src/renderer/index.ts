/**
 * The window.
 *
 * Four panels on a ground, a toolbar above them, and the keys that drive the
 * lot. The arrangement is the Mac's, down to the eight-point margin and the
 * ten-point gap that doubles as the resize handle, because a person who reads
 * on one machine and writes on another should not have to find anything twice.
 */
import { call, isCommand, onEvent, platform } from './bridge.js'
import { clear, el, on } from './dom.js'
import {
  adopt,
  canGoBack,
  canGoForward,
  changed,
  paper as findPaper,
  remember,
  shelfPapers,
  store,
  subscribe,
  travel,
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
import { buildSketchRack, buildStylePanel, TOOLS } from './ui/sketchToolbar.js'
import { undoStack } from './ui/sketchInput.js'
import type { LibrarySnapshot } from '../shared/api.js'
import { SketchElement, rectInset } from '../shared/sketch.js'
import { icon } from './icons.js'

document.body.dataset.platform = platform

const root = document.getElementById('root')!
const panes = el('div', { class: 'panes' })

// ---------------------------------------------------------------- the panes

const sidebar = buildSidebar({
  select: (shelf: Shelf) => {
    store.shelf = shelf
    changed('shelf')
  },
  newCollection: async () => {
    const name = await prompt('New collection')
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
  openGraph: () => toast('The citation graph is not in this build yet.'),
  chooseLibrary: () => void chooseLibrary(),
})

const paperList = buildPaperList({
  open: (id) => openPaper(id),
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
  contextMenu: (id, anchor) => {
    const entry = findPaper(id)
    if (!entry) return
    showMenu(anchor, [
      { label: 'Open', icon: 'text.page', action: () => openPaper(id) },
      { label: 'Show in Folder', icon: 'folder', action: () => void call('paper:reveal', { id }) },
      { label: 'Copy Citation Key', icon: 'doc.on.doc', action: () => copyKey(id) },
      { separator: true },
      {
        label: entry.state.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
        icon: 'star',
        action: async () => {
          await call('paper:state', { id, patch: { isFavorite: !entry.state.isFavorite } })
          await reload()
        },
      },
      { separator: true },
      {
        label: 'Move to Trash',
        icon: 'trash',
        action: async () => {
          if (!confirm(`Move “${entry.meta.displayTitle}” to the library's Trash?\n\nNothing is deleted — the PDF and its record move to the Trash folder inside the library.`)) return
          await call('library:trash', { id })
          if (store.selectedID === id) store.selectedID = null
          await reload()
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

const reader = new Reader({
  changed: () => changed('sketch'),
  toast,
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
  copyKey,
  openAuthor: (name) => {
    store.shelf = { kind: 'author', name }
    changed('shelf')
  },
})

// -------------------------------------------------------- the drawing layer

const rack = buildSketchRack({
  setTool: (tool: SketchTool) => {
    store.sketch.tool = tool
    changed('sketch')
  },
  restyle: (change) => {
    change(store.sketch.style)
    // A change made with something selected applies to it; with nothing
    // selected it sets what the next thing drawn will look like.
    const selection = store.sketch.selection
    if (selection) {
      const page = reader.pages[selection.pageIndex]
      if (page) {
        for (const element of page.elements) {
          if (selection.ids.includes(element.id)) change(element.style)
        }
        page.redraw()
        void reader.save(page)
      }
    }
    changed('sketch')
  },
  frameSelection: () => frameSelection(),
  bringToFront: () => reorder('front'),
  sendToBack: () => reorder('back'),
  deleteSelection: () => deleteSelection(),
  duplicateSelection: () => duplicateSelection(),
})

const stylePanel = buildStylePanel({
  setTool: (tool) => {
    store.sketch.tool = tool
    changed('sketch')
  },
  restyle: rackRestyle,
  frameSelection: () => frameSelection(),
  bringToFront: () => reorder('front'),
  sendToBack: () => reorder('back'),
  deleteSelection: () => deleteSelection(),
  duplicateSelection: () => duplicateSelection(),
})

function rackRestyle(change: (style: import('../shared/sketch.js').SketchStyle) => void) {
  change(store.sketch.style)
  const selection = store.sketch.selection
  if (selection) {
    const page = reader.pages[selection.pageIndex]
    if (page) {
      for (const element of page.elements) {
        if (selection.ids.includes(element.id)) change(element.style)
      }
      page.redraw()
      void reader.save(page)
    }
  }
  changed('sketch')
}

function selectedPage() {
  const selection = store.sketch.selection
  if (!selection) return null
  return reader.pages[selection.pageIndex] ?? null
}

function selectedElements(): SketchElement[] {
  const page = selectedPage()
  const selection = store.sketch.selection
  if (!page || !selection) return []
  return page.elements.filter((element) => selection.ids.includes(element.id))
}

function deleteSelection() {
  const page = selectedPage()
  const selection = store.sketch.selection
  if (!page || !selection) return
  page.elements = page.elements.filter((element) => !selection.ids.includes(element.id))
  store.sketch.selection = null
  page.redraw()
  void reader.save(page)
  changed('sketch')
}

function duplicateSelection() {
  const page = selectedPage()
  const chosen = selectedElements()
  if (!page || chosen.length === 0) return
  const copies = chosen.map((element) => {
    const copy = element.translated({ x: 12, y: -12 })
    copy.id = crypto.randomUUID().toUpperCase()
    return copy
  })
  page.elements.push(...copies)
  store.sketch.selection = { pageIndex: page.index, ids: copies.map((c) => c.id), strokeIDs: [] }
  page.redraw()
  void reader.save(page)
  changed('sketch')
}

function reorder(where: 'front' | 'back') {
  const page = selectedPage()
  const selection = store.sketch.selection
  if (!page || !selection) return
  const chosen = page.elements.filter((element) => selection.ids.includes(element.id))
  const rest = page.elements.filter((element) => !selection.ids.includes(element.id))
  page.elements = where === 'front' ? [...rest, ...chosen] : [...chosen, ...rest]
  page.redraw()
  void reader.save(page)
}

/**
 * Draws a frame round what is selected — the XMind habit of boxing a thought
 * once it has become one. Handwriting included: the frame takes in the strokes
 * the selection sits over as well as the shapes.
 */
function frameSelection() {
  const page = selectedPage()
  const chosen = selectedElements()
  if (!page || chosen.length === 0) return
  const boxes = chosen.map((element) => element.bounds)
  const box = boxes.reduce((a, b) => {
    const minX = Math.min(a.x, b.x)
    const minY = Math.min(a.y, b.y)
    const maxX = Math.max(a.x + a.width, b.x + b.width)
    const maxY = Math.max(a.y + a.height, b.y + b.height)
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
  })
  const padded = rectInset(box, -8, -8)
  const frame = new SketchElement({
    kind: 'rectangle',
    points: [{ x: padded.x, y: padded.y }, { x: padded.x + padded.width, y: padded.y + padded.height }],
    style: store.sketch.style.copy(),
  })
  frame.style.fill = null
  // Behind what it frames, so the words stay on top.
  page.elements.unshift(frame)
  store.sketch.selection = { pageIndex: page.index, ids: [frame.id], strokeIDs: [] }
  page.redraw()
  void reader.save(page)
  changed('sketch')
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
      { label: 'Refresh Folder', icon: 'arrow.clockwise', action: () => void reload() },
      { label: 'Choose Library Folder…', icon: 'folder', action: () => void chooseLibrary() },
      { separator: true },
      { caption: 'Sort By' },
      ...(['title', 'author', 'year', 'added', 'opened'] as const).map((field) => ({
        label: { title: 'Title', author: 'Author', year: 'Year', added: 'Date Added', opened: 'Last Opened' }[field],
        checked: store.settings.sort.field === field,
        action: () => setSort(field, store.settings.sort.ascending),
      })),
      {
        label: 'Ascending',
        checked: store.settings.sort.ascending,
        action: () => setSort(store.settings.sort.field, !store.settings.sort.ascending),
      },
      { separator: true },
      { caption: 'Page Tint' },
      ...(['none', 'sepia', 'grey', 'night'] as const).map((tint) => ({
        label: { none: 'None', sepia: 'Sepia', grey: 'Grey', night: 'Night' }[tint],
        checked: store.settings.pageTint === tint,
        action: () => {
          store.settings.pageTint = tint
          void call('settings:set', { pageTint: tint })
          reader.applyTint()
        },
      })),
      { separator: true },
      { caption: 'Appearance' },
      ...(['system', 'light', 'dark'] as const).map((appearance) => ({
        label: { system: 'System', light: 'Light', dark: 'Dark' }[appearance],
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
reader.overlayContainer.append(rack.node, stylePanel.node)

// ------------------------------------------------------- laying out the panes

function layoutPanes() {
  clear(panes)
  const visible = store.settings.panes
  const pieces: { pane: Pane; node: HTMLElement; width?: number; resizes?: 'leading' | 'trailing' }[] = []
  if (visible.sidebar) pieces.push({ pane: 'sidebar', node: sidebar.node, width: store.settings.columns.sidebar })
  if (visible.paperList) pieces.push({ pane: 'paperList', node: paperList.node, width: store.settings.columns.paperList })
  if (visible.reader) pieces.push({ pane: 'reader', node: reader.node })
  if (visible.inspector) {
    pieces.push({ pane: 'inspector', node: inspector.node, width: store.settings.columns.inspector, resizes: 'trailing' })
  }

  pieces.forEach((piece, index) => {
    if (piece.width) {
      piece.node.style.flex = `0 0 ${piece.width}px`
      piece.node.style.width = `${piece.width}px`
    } else {
      piece.node.style.flex = '1 1 auto'
      piece.node.style.width = ''
    }
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

function divider(pane: 'sidebar' | 'paperList' | 'inspector', inverted: boolean): HTMLElement {
  const node = el('div', { class: 'divider' })
  on(node, 'pointerdown', (event: PointerEvent) => {
    event.preventDefault()
    node.setPointerCapture(event.pointerId)
    node.classList.add('dragging')
    const startX = event.clientX
    const startWidth = store.settings.columns[pane]
    const move = (moved: PointerEvent) => {
      const travel = inverted ? startX - moved.clientX : moved.clientX - startX
      const widest = Math.max(320, panes.clientWidth - 300)
      store.settings.columns[pane] = Math.min(Math.max(startWidth + travel, 180), widest)
      layoutPanes()
      reader.relayout()
    }
    const up = () => {
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

function togglePane(pane: Pane) {
  store.settings.panes[pane] = !store.settings.panes[pane]
  void call('settings:set', { panes: store.settings.panes })
  layoutPanes()
  toolbar.update()
  reader.relayout()
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
  changed('papers')
}

async function openPaper(id: string) {
  if (store.selectedID === id) return
  store.selectedID = id
  if (!store.travelling) remember(id)
  void call('settings:set', { selectedPaperID: id })
  void call('paper:state', { id, patch: { lastOpenedAt: new Date().toISOString(), readingStatus: statusOnOpen(id) } })
  changed('papers', 'selection')
  const result = await call<{ data: Uint8Array } | { error: string }>('paper:bytes', { id })
  if ('error' in result) return toast(result.error)
  await reader.open(id, new Uint8Array(result.data))
  reader.setDrawing(store.reader.drawing)
  changed('reader')
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
  void openPaper(id).finally(() => { store.travelling = false })
}

function goForward() {
  if (!canGoForward()) return
  const id = travel(store.trailIndex + 1)
  if (!id) return
  store.travelling = true
  void openPaper(id).finally(() => { store.travelling = false })
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
  toast('Citation key copied')
}

// ------------------------------------------------------------------- search

let palette: HTMLElement | null = null

function openSearch() {
  if (palette) return closeSearch()
  const input = el('input', { type: 'text', placeholder: 'Search papers…', spellcheck: 'false' }) as HTMLInputElement
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
        void openPaper(entry.id)
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

  if (event.key === 'Escape') {
    // Three steps back, in the order a hand expects: finish the words, then
    // drop the selection, then put the tool away.
    if (palette) return closeSearch()
    if (store.sketch.selection) {
      store.sketch.selection = null
      reader.redrawAll()
      return changed('sketch')
    }
    if (store.sketch.tool !== 'select') {
      store.sketch.tool = 'select'
      return changed('sketch')
    }
    if (store.reader.drawing) {
      reader.setDrawing(false)
      reader.update()
      return changed('sketch')
    }
    return
  }

  if (typing) return

  if (isCommand(event)) {
    if (event.key === 'z') {
      event.preventDefault()
      applyUndo(event.shiftKey)
      return
    }
    if (event.key === 'd') {
      event.preventDefault()
      duplicateSelection()
      return
    }
    if (event.key === 'a' && store.reader.drawing) {
      event.preventDefault()
      selectAllOnPage()
      return
    }
    return
  }

  if (event.key === 'Delete' || event.key === 'Backspace') {
    if (store.sketch.selection) {
      event.preventDefault()
      deleteSelection()
    }
    return
  }

  if (store.reader.drawing) {
    const tool = TOOLS.find((entry) => entry.key.toLowerCase() === event.key.toLowerCase())
    if (tool) {
      event.preventDefault()
      store.sketch.tool = tool.tool
      return changed('sketch')
    }
    if (event.key.toLowerCase() === 'b') {
      event.preventDefault()
      return frameSelection()
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
  if (!page || !selection) return
  const offset = {
    ArrowLeft: { x: -distance, y: 0 },
    ArrowRight: { x: distance, y: 0 },
    // The page's y goes up, so up on the keyboard is up on the page.
    ArrowUp: { x: 0, y: distance },
    ArrowDown: { x: 0, y: -distance },
  }[key]
  if (!offset) return
  page.elements = page.elements.map((element) =>
    selection.ids.includes(element.id) ? element.translated(offset) : element)
  page.redraw()
  void reader.save(page)
}

function selectAllOnPage() {
  const page = reader.pages[store.reader.currentPage]
  if (!page || page.elements.length === 0) return
  store.sketch.selection = {
    pageIndex: page.index,
    ids: page.elements.map((element) => element.id),
    strokeIDs: [],
  }
  page.redraw()
  changed('sketch')
}

function applyUndo(redo: boolean) {
  const snapshot = redo ? undoStack.redo() : undoStack.undo()
  if (!snapshot) return
  const page = reader.pages[snapshot.pageIndex]
  if (!page) return
  page.elements = snapshot.elements.map((element) => element.copy())
  page.strokes = snapshot.strokes.map((stroke) => stroke.translated({ x: 0, y: 0 }))
  store.sketch.selection = null
  page.redraw()
  void reader.save(page)
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

subscribe((keys) => {
  if (keys.has('papers') || keys.has('shelf') || keys.has('selection')) {
    sidebar.update()
    paperList.update()
    inspector.update()
  }
  if (keys.has('inspector')) inspector.update()
  if (keys.has('sketch')) {
    rack.update()
    stylePanel.update()
    reader.redrawAll()
    reader.update()
  }
  if (keys.has('reader')) reader.update()
  toolbar.update()
})

// --------------------------------------------------------- events from main

onEvent((event, payload) => {
  switch (event) {
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
  switch (command) {
    case 'addPapers': void addPapers(); break
    case 'refreshFolder': void reload(); break
    case 'searchEverything': openSearch(); break
    case 'sidebar': togglePane('sidebar'); break
    case 'paperList': togglePane('paperList'); break
    case 'reader': togglePane('reader'); break
    case 'inspector': togglePane('inspector'); break
    case 'back': goBack(); break
    case 'forward': goForward(); break
    case 'zoomIn': reader.zoomBy(1.15); break
    case 'zoomOut': reader.zoomBy(1 / 1.15); break
    case 'actualSize': reader.setZoom(1); break
    case 'draw':
      reader.setDrawing(!store.reader.drawing)
      reader.update()
      changed('sketch')
      break
    case 'highlight':
      if (!reader.markSelection('highlight')) toast('Select some text first.')
      break
    case 'underline':
      if (!reader.markSelection('underline')) toast('Select some text first.')
      break
    case 'exportBibTeX':
      void (async () => {
        const result = await call<{ written?: number; error?: string; cancelled?: boolean }>(
          'bibtex:export', { ids: shelfPapers().map((entry) => entry.id) },
        )
        if (result.cancelled) return
        if (result.error) return toast(result.error)
        toast(`${result.written} ${result.written === 1 ? 'entry' : 'entries'} exported`)
      })()
      break
    case 'copyCitationKey':
      if (store.selectedID) void copyKey(store.selectedID)
      break
    case 'focus':
      store.settings.panes.sidebar = false
      store.settings.panes.paperList = false
      store.settings.panes.inspector = false
      layoutPanes()
      toolbar.update()
      reader.relayout()
      break
    default:
      toast(`“${command}” is not in this build yet.`)
  }
}

// ---------------------------------------------------------------- dropping

on(window, 'dragover', (event: DragEvent) => {
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
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

on(window, 'resize', () => reader.relayout())

// ------------------------------------------------------------------- start

async function start() {
  const saved = await call<typeof store.settings & { libraryRoot: string | null }>('settings:get')
  Object.assign(store.settings, saved)
  applyTheme()
  layoutPanes()
  toolbar.update()
  store.windowState = await call('window:state')
  reader.watchSelection()

  if (saved.libraryRoot) {
    const snapshot = await call<LibrarySnapshot>('library:reload')
    if (!('error' in snapshot)) {
      adopt(snapshot)
      changed('papers', 'shelf')
      const first = saved.selectedPaperID && findPaper(saved.selectedPaperID)
        ? saved.selectedPaperID
        : shelfPapers()[0]?.id
      if (first) await openPaper(first)
    }
  } else {
    changed('papers')
  }
}

void start()
