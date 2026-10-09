/**
 * The sidebar and the paper list without a window (`WR9`): which row is lit,
 * the folders read off the papers — with Windows roots — the shelf's order,
 * the authors as people, the rows chosen, and what a drag carries.
 */
import assert from 'node:assert/strict'
import {
  authorCounts, authorShelf, closeOtherOpenPapers, draggedFrom, extendRun, folderAbove, folderLabel, folderTrail,
  isPinned, keepOpen, papersByFolder, pickRow, sameShelf, selectedPapers, shelfCounts, shelfPapers, sorted, store,
  subfolders, type Paper, type Shelf,
} from '../renderer/state.js'
import { authorKey, sortingSurname } from '../shared/authorKey.js'
import { needsReview } from '../shared/documentKind.js'
import { parseSubtitle } from '../shared/subtitle.js'
import { draggedPapers, writeDraggedPapers } from '../shared/split.js'
import { setPathPlatform } from '../shared/paths.js'
import { PaperMeta, PaperState, type CSLName } from '../shared/model.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Made {
  id: string
  root?: string
  path?: string
  title?: string
  authors?: CSLName[]
  year?: number
  added?: string
  parent?: string
  kind?: string
  confidence?: string
}

function made(one: Made): Paper {
  const csl: Record<string, unknown> = { title: one.title ?? one.id }
  if (one.authors) csl.author = one.authors
  if (one.year) csl.issued = { 'date-parts': [[one.year]] }
  return {
    id: one.id,
    meta: new PaperMeta({
      id: one.id,
      csl,
      file: { relativePath: one.path ?? `${one.id}.pdf`, originalName: `${one.id}.pdf` },
      addedAt: one.added ?? '2026-01-01T00:00:00Z',
      ...(one.parent ? { parentID: one.parent } : {}),
      ...(one.kind ? { kind: one.kind } : {}),
      ...(one.confidence ? { confidence: one.confidence } : {}),
    } as never),
    state: new PaperState({}),
    exists: true,
    root: one.root ?? '/lib',
  }
}

function library(papers: Paper[], roots = ['/lib']) {
  store.papers = papers
  store.roots = roots
  store.folders = []
  store.root = roots[0]
  store.shelf = { kind: 'all' }
  store.selectedID = null
  store.selection = []
  store.selectionAnchor = null
  store.openPaperIDs = []
  store.pinnedPaperIDs = []
  store.split = null
  store.tags = []
  store.collections = []
  store.notes = []
}

/** A DataTransfer, as far as a drag needs one. */
function transfer(): DataTransfer {
  const data = new Map<string, string>()
  return {
    setData: (type: string, value: string) => void data.set(type, value),
    getData: (type: string) => data.get(type) ?? '',
    get types() { return [...data.keys()] },
  } as unknown as DataTransfer
}

export async function libraryListSuite(test: Test, suite: (name: string) => void) {
  suite('The sidebar and the paper list')

  await test('one row is lit: every kind of shelf by what tells it apart', () => {
    setPathPlatform('win32')
    const shelves: Shelf[] = [
      { kind: 'all' }, { kind: 'open' }, { kind: 'favorites' }, { kind: 'review' }, { kind: 'notes' }, { kind: 'search' },
      { kind: 'kind', of: 'paper' }, { kind: 'kind', of: 'book' },
      { kind: 'status', status: 'unread' }, { kind: 'status', status: 'read' },
      { kind: 'collection', id: 'C1' }, { kind: 'collection', id: 'C2' },
      { kind: 'tag', id: 'T1' }, { kind: 'tag', id: 'T2' },
      { kind: 'author', key: 'lecun|y', name: 'Yann LeCun' }, { kind: 'author', key: 'hinton|g', name: 'Geoffrey Hinton' },
      { kind: 'folder', root: 'D:\\Papers' }, { kind: 'folder', root: 'D:\\Papers\\2026' },
    ]
    for (const [i, a] of shelves.entries()) {
      for (const [j, b] of shelves.entries()) {
        assert.equal(sameShelf(a, b), i === j, `${JSON.stringify(a)} vs ${JSON.stringify(b)}`)
      }
    }
    assert.ok(sameShelf({ kind: 'folder', root: 'D:\\Papers' }, { kind: 'folder', root: 'd:/papers/' }), 'a path as Windows compares it')
    assert.ok(sameShelf({ kind: 'author', key: 'lecun|y', name: 'Y. LeCun' }, { kind: 'author', key: 'lecun|y', name: 'Yann LeCun' }))
    setPathPlatform(process.platform)
  })

  await test('the folders under a Windows library, in Finder order, and the way back up', () => {
    setPathPlatform('win32')
    const root = 'D:\\Papers'
    library([
      made({ id: 'a', root, path: '2026/Week 10/a.pdf' }),
      made({ id: 'b', root, path: '2026/Week 2/b.pdf' }),
      made({ id: 'c', root, path: '2026/Week 1/c.pdf' }),
      made({ id: 'd', root, path: '2026/Week 2/d.pdf' }),
      made({ id: 's', root, path: '2026/Week 2/s.pdf', parent: 'd' }),
      made({ id: 'e', root, path: 'e.pdf' }),
    ], [root])
    const weeks = subfolders('D:/Papers/2026')
    assert.deepEqual(weeks.map((one) => one.name), ['Week 1', 'Week 2', 'Week 10'], 'numeric, as Finder sorts')
    assert.deepEqual(weeks.map((one) => one.count), [1, 2, 1], 'a supplement is not a paper of the folder')
    assert.deepEqual(folderTrail('D:/Papers/2026/Week 2'), [root, 'D:/Papers/2026', 'D:/Papers/2026/Week 2'])
    assert.equal(folderTrail('D:/Papers/2026')[0], root, 'the first step is the row as it is stored, so it lights')
    assert.equal(folderAbove('D:/Papers/2026'), root, 'going up to the library is going to its row')
    assert.equal(folderAbove(root), null)
    assert.equal(folderAbove('d:\\papers\\'), null, 'a root however it is spelt')
    assert.equal(folderLabel('D:/Papers/2026/Week 2'), 'Papers › 2026 › Week 2')
    setPathPlatform(process.platform)
  })

  await test('a kind’s shelf groups by folder, in Finder order, and only across more than one', () => {
    setPathPlatform('win32')
    library([
      made({ id: 'a', root: 'C:\\lib', path: 'w10/a.pdf' }),
      made({ id: 'b', root: 'C:\\lib', path: 'w2/b.pdf' }),
      made({ id: 'c', root: 'C:\\lib', path: 'w1/c.pdf' }),
    ], ['C:\\lib'])
    store.shelf = { kind: 'kind', of: 'paper' }
    const groups = papersByFolder(store.papers)
    assert.deepEqual(groups?.map((one) => one.label), ['lib › w1', 'lib › w2', 'lib › w10'])
    store.shelf = { kind: 'all' }
    assert.equal(papersByFolder(store.papers), null, 'not on any other shelf')
    store.shelf = { kind: 'kind', of: 'paper' }
    assert.equal(papersByFolder([store.papers[0]]), null, 'one group needs no heading')
    setPathPlatform(process.platform)
  })

  await test('the shelf’s order is the Mac’s: every field, both ways, ties as they came', () => {
    const papers = [
      made({ id: '1', title: 'Élan vital', authors: [{ family: 'Zhou', given: 'Y' }], year: 2021, added: '2026-01-03T00:00:00Z' }),
      made({ id: '2', title: 'attention', authors: [{ family: 'Vaswani', given: 'A' }, { family: 'Shazeer' }], year: 2017, added: '2026-01-01T00:00:00Z' }),
      made({ id: '3', title: 'Paper 10', year: 2021, added: '2026-01-02T00:00:00Z' }),
      made({ id: '4', title: '강화학습', authors: [{ family: 'van', given: 'X', 'non-dropping-particle': 'de' }], added: '2026-01-04T00:00:00Z' }),
      made({ id: '5', title: 'Paper 2', authors: [{ literal: 'OpenAI' }], year: 2023, added: '2026-01-05T00:00:00Z' }),
    ]
    const ids = (field: string, ascending: boolean) => sorted(papers, { field, ascending }).map((one) => one.id).join('')
    assert.equal(ids('added', true), '23145')
    assert.equal(ids('added', false), '54132')
    // Case aside, accents kept, digits as written (localizedCaseInsensitiveCompare).
    assert.equal(ids('title', true), '21354')
    assert.equal(ids('title', false), '45312')
    // The first author's surname, particles and all; nobody's last.
    assert.equal(ids('author', true), '4521' + '3')
    assert.equal(ids('author', false), '3' + '1254')
    // No year before every year; the two of 2021 keep the order they came in.
    assert.equal(ids('year', true), '42135')
    assert.equal(ids('year', false), '51324')
  })

  await test('an author is a person: keys join spellings, supplements do not count, most papers first', () => {
    assert.equal(authorKey({ family: 'LeCun', given: 'Yann' }), 'lecun|y')
    assert.equal(authorKey({ family: 'LeCun', given: 'Y.' }), 'lecun|y')
    assert.equal(authorKey({ family: 'Almudévar', given: 'Émile' }), 'almudevar|e')
    assert.equal(authorKey({ given: 'Nobody' }), null)
    assert.equal(sortingSurname({ family: 'Beethoven', 'non-dropping-particle': 'van' }), 'van Beethoven')
    assert.equal(sortingSurname({ literal: 'OpenAI' }), 'OpenAI')
    library([
      made({ id: 'a', authors: [{ family: 'LeCun', given: 'Y.' }, { family: 'Bengio', given: 'Yoshua' }] }),
      made({ id: 'b', authors: [{ family: 'LeCun', given: 'Yann' }] }),
      made({ id: 'c', authors: [{ family: 'Hinton', given: 'Geoffrey' }] }),
      made({ id: 's', authors: [{ family: 'Hinton', given: 'G' }], parent: 'c' }),
    ])
    const ranked = authorCounts()
    assert.deepEqual(ranked.map((one) => `${one.name}:${one.count}`), ['Yann LeCun:2', 'Geoffrey Hinton:1', 'Yoshua Bengio:1'])
    const shelf = authorShelf({ family: 'LeCun', given: 'Y.' })
    assert.deepEqual(shelf, { kind: 'author', key: 'lecun|y', name: 'Yann LeCun' })
    store.shelf = shelf!
    assert.deepEqual(shelfPapers().map((one) => one.id).sort(), ['a', 'b'], 'the shelf holds both spellings')
  })

  await test('one walk counts every shelf; review is a looked-up paper that came back unsure', () => {
    library([
      made({ id: 'a', confidence: 'needsReview' }),
      made({ id: 'b', confidence: 'unparsed', kind: 'book' }),
      made({ id: 'c', confidence: 'verified' }),
    ])
    const counts = shelfCounts(store.papers)
    assert.equal(counts.all, 3)
    assert.equal(counts.review, 1, 'a book has no registrar to disagree with')
    assert.equal(counts.books, 1)
    assert.ok(needsReview(store.papers[0].meta))
    assert.equal(needsReview(store.papers[1].meta), false)
  })

  await test('«Close Other Papers» lets go of the others’ pins', () => {
    library([made({ id: 'A' }), made({ id: 'B' }), made({ id: 'C' })])
    keepOpen('A', true)
    keepOpen('B', true)
    keepOpen('C')
    store.selectedID = 'B'
    closeOtherOpenPapers('A')
    assert.deepEqual(store.openPaperIDs, ['A'])
    assert.equal(isPinned('B'), false, 'a closed paper is not pinned')
    assert.equal(isPinned('A'), true)
    assert.equal(store.selectedID, 'A')
  })

  await test('rows chosen as a Mac list chooses them: alone, a run, one more or fewer', () => {
    const order = ['a', 'b', 'c', 'd', 'e']
    let now = pickRow({ selection: [], anchor: null, showing: null }, 'b', 'only', order)
    assert.deepEqual(now, { selection: ['b'], anchor: 'b', showing: 'b' })
    now = pickRow(now, 'd', 'extend', order)
    assert.deepEqual(now.selection, ['b', 'c', 'd'])
    assert.equal(now.showing, 'b', 'the paper showing stays while it is among them')
    assert.equal(now.anchor, 'b', 'a run keeps its start')
    now = pickRow(now, 'a', 'toggle', order)
    assert.deepEqual(now.selection, ['b', 'c', 'd', 'a'])
    now = pickRow(now, 'b', 'toggle', order)
    assert.deepEqual(now.selection, ['c', 'd', 'a'])
    assert.notEqual(now.showing, 'b', 'the one dropped is not the one showing')
    assert.ok(now.selection.includes(now.showing!))
    now = pickRow({ selection: ['c'], anchor: 'c', showing: 'c' }, 'c', 'toggle', order)
    assert.deepEqual(now, { selection: [], anchor: 'c', showing: null }, 'nothing chosen is nothing showing')
    // The keyboard's run is exactly anchor to lead.
    const run = extendRun({ selection: ['b', 'c', 'd'], anchor: 'b', showing: 'b' }, 'c', order)
    assert.deepEqual(run.selection, ['b', 'c'])
    assert.deepEqual(extendRun({ selection: ['c'], anchor: 'c', showing: 'c' }, 'a', order).selection, ['a', 'b', 'c'])
  })

  await test('a drag from a chosen row carries them all; from another row, itself', () => {
    library([made({ id: 'a' }), made({ id: 'b' }), made({ id: 'c' })])
    store.selection = ['a', 'b']
    store.selectedID = 'a'
    assert.deepEqual(selectedPapers(), ['a', 'b'])
    assert.deepEqual(draggedFrom('b'), ['a', 'b'])
    assert.deepEqual(draggedFrom('c'), ['c'])
    store.selectedID = 'c'
    assert.deepEqual(selectedPapers(), ['c'], 'shown by other means, a paper is the selection alone')
    const data = transfer()
    writeDraggedPapers(data, ['a', 'b'])
    assert.deepEqual(draggedPapers(data), ['a', 'b'])
    const single = transfer()
    single.setData('application/x-papertime-paper', 'c')
    assert.deepEqual(draggedPapers(single), ['c'], 'one identifier, from the popup or a pane, reads the same')
  })

  await test('the subtitle setting reads as the Mac reads it, repeats and all', () => {
    assert.deepEqual(parseSubtitle('year,authors,year'), ['year', 'authors', 'year'])
    assert.deepEqual(parseSubtitle('nonsense'), ['authors', 'year', 'venue'])
  })
}
