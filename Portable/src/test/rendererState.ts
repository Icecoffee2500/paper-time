/**
 * The window's store without a window (`WR4`): which papers are open, the
 * panes side by side, the trail Back walks, a record put in place without a
 * reading, and what goes when a paper leaves the library — with Windows
 * roots as well as these.
 */
import assert from 'node:assert/strict'
import {
  canGoBack,
  canGoForward,
  changed,
  closeOpenPaper,
  dock,
  folderTrail,
  isOpenPaper,
  isPinned,
  keepOpen,
  panePapers,
  patchPaper,
  paper as findPaper,
  pruneToLibrary,
  readerState,
  remember,
  setFocusedReaderState,
  setShelf,
  store,
  subscribe,
  travelBy,
  undock,
  type Change,
  type Paper,
} from '../renderer/state.js'
import { setPathPlatform } from '../shared/paths.js'
import { PaperMeta, PaperState } from '../shared/model.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

function paper(id: string, root = '/lib', relativePath = `${id}.pdf`): Paper {
  return { id, meta: new PaperMeta({ id, file: { relativePath } } as never), state: new PaperState({}), exists: true, root }
}

/** A library of these papers, and nothing open. */
function library(...ids: string[]) {
  store.papers = ids.map((id) => paper(id))
  store.roots = ['/lib']
  store.selectedID = null
  store.openPaperIDs = []
  store.pinnedPaperIDs = []
  store.split = null
  store.trail = []
  store.trailIndex = -1
  store.travelling = false
  store.slipBox = { openID: null, query: '', tag: null, paperID: null }
  store.shelf = { kind: 'all' }
}

/** Shows a paper the way `showPaper` does, without a page area. */
function show(id: string) {
  store.selectedID = id
  if (!store.travelling) remember(id)
}

export async function rendererStateSuite(test: Test, suite: (name: string) => void) {
  suite('The window’s store: open papers, panes, the trail')

  await test('keeping a paper by hand pins it; being clicked into only keeps it', () => {
    library('A', 'B')
    keepOpen('A')
    keepOpen('B', true)
    assert.ok(isOpenPaper('A') && isOpenPaper('B'))
    assert.equal(isPinned('A'), false)
    assert.equal(isPinned('B'), true)
    keepOpen('ghost', true)
    assert.equal(isOpenPaper('ghost'), false, 'a paper not in the library is not kept')
  })

  await test('closing the paper showing brings its neighbour on the shelf forward', () => {
    library('A', 'B', 'C')
    for (const id of ['A', 'B', 'C']) keepOpen(id)
    store.selectedID = 'B'
    closeOpenPaper('B')
    assert.equal(store.selectedID, 'C')
    closeOpenPaper('C')
    assert.equal(store.selectedID, 'A')
    closeOpenPaper('A')
    assert.equal(store.selectedID, null)
  })

  await test('docking beside the paper showing makes two panes; undocking one leaves one reader', () => {
    library('A', 'B', 'C')
    store.selectedID = 'A'
    dock('B', 'right')
    assert.deepEqual(panePapers(), ['A', 'B'])
    assert.ok(isOpenPaper('A') && isOpenPaper('B'), 'every paper in the arrangement is kept')
    dock('C', 'bottomRight')
    assert.equal(panePapers().length, 3)
    undock('C')
    undock('B')
    assert.equal(store.split, null)
    assert.deepEqual(panePapers(), ['A'])
  })

  await test('Back skips the paper already showing and papers that have left', () => {
    library('A', 'B', 'C')
    show('A')
    show('B')
    show('C')
    // A closed pane moved the focus back to B and B was remembered again:
    // the step before is B itself, which used to make Back do nothing once.
    show('B')
    assert.deepEqual(store.trail, ['A', 'B', 'C', 'B'])
    store.papers = store.papers.filter((entry) => entry.id !== 'C')
    assert.ok(canGoBack())
    assert.equal(travelBy(-1), 'A', 'past B (showing) and C (gone)')
    store.selectedID = 'A'
    assert.equal(canGoBack(), false)
    assert.ok(canGoForward())
    assert.equal(travelBy(1), 'B')
  })

  await test('going back and opening another forgets what lay ahead', () => {
    library('A', 'B', 'C')
    show('A')
    show('B')
    store.travelling = true
    store.selectedID = travelBy(-1)
    store.travelling = false
    show('C')
    assert.deepEqual(store.trail, ['A', 'C'])
  })

  await test('a paper leaving the library leaves the shelf, the panes, the trail and the slip-box', () => {
    library('A', 'B', 'C')
    for (const id of ['A', 'B', 'C']) keepOpen(id, true)
    show('A')
    show('B')
    show('C')
    store.selectedID = 'B'
    dock('C', 'right')
    store.slipBox.paperID = 'C'
    store.papers = store.papers.filter((entry) => entry.id !== 'C' && entry.id !== 'B')
    pruneToLibrary()
    assert.deepEqual(store.openPaperIDs, ['A'])
    assert.deepEqual(store.pinnedPaperIDs, ['A'])
    assert.equal(store.split, null)
    assert.equal(store.selectedID, null)
    assert.equal(store.slipBox.paperID, null)
    assert.deepEqual(store.trail, ['A'])
    assert.equal(store.trailIndex, 0)
  })

  await test('pruning keeps the place on the trail when what is before it stays', () => {
    library('A', 'B', 'C', 'D')
    for (const id of ['A', 'B', 'C', 'D']) show(id)
    store.trailIndex = 2 // on C, D ahead
    store.papers = store.papers.filter((entry) => entry.id !== 'B')
    pruneToLibrary()
    assert.deepEqual(store.trail, ['A', 'C', 'D'])
    assert.equal(store.trail[store.trailIndex], 'C')
  })

  await test('a written record replaces the row in a new array, and the index follows', () => {
    library('A', 'B')
    const before = store.papers
    const row = findPaper('A')!
    patchPaper('A', { state: { ...row.state.encode(), isFavorite: true } })
    assert.notEqual(store.papers, before, 'replaced, not changed in place')
    assert.equal(before[0].state.isFavorite, false)
    assert.equal(findPaper('A')!.state.isFavorite, true)
    assert.equal(findPaper('B'), before[1], 'the other rows are the same objects')
    patchPaper('A', { meta: { ...row.meta.encode(), parentID: 'B' } })
    assert.equal(findPaper('A')!.meta.parentID, 'B')
    assert.equal(findPaper('A')!.state.isFavorite, true, 'the state written before is kept')
    patchPaper('nobody', { state: {} })
    assert.equal(store.papers.length, 2)
  })

  await test('choosing the Notes shelf lets go of the paper the slip-box lent the page area', () => {
    library('A')
    store.slipBox.paperID = 'A'
    setShelf({ kind: 'tag', id: 't' })
    assert.equal(store.slipBox.paperID, 'A')
    setShelf({ kind: 'notes' })
    assert.equal(store.slipBox.paperID, null)
  })

  await test('changes are named: a listener hears the names it was sent', () => {
    const heard: Change[][] = []
    const stop = subscribe((keys) => heard.push([...keys]))
    changed('papers', 'history')
    stop()
    changed('shelf')
    assert.deepEqual(heard, [['papers', 'history']])
  })

  await test('the reader state is read from the reader in focus, and blank with none', () => {
    const own = { pageCount: 9, currentPage: 3, zoom: 1, drawing: true }
    let focusedOne: typeof own | null = own
    setFocusedReaderState(() => focusedOne)
    assert.equal(readerState().drawing, true)
    focusedOne = null
    assert.equal(readerState().drawing, false)
    assert.equal(readerState().pageCount, 0)
    setFocusedReaderState(() => null)
  })

  await test('the way down a Windows library starts at its root as stored', () => {
    setPathPlatform('win32')
    try {
      store.roots = ['C:\\Papers', 'D:\\Lectures']
      assert.deepEqual(folderTrail('c:/papers/2026/week 1'), ['C:\\Papers', 'C:/Papers/2026', 'C:/Papers/2026/week 1'])
      assert.deepEqual(folderTrail('D:\\Lectures'), ['D:\\Lectures'])
    } finally {
      setPathPlatform(process.platform)
    }
  })
}
