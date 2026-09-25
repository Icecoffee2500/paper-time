/**
 * Search by meaning, between the worker and the palette: what a query is
 * answered with, which vectors a prune keeps, and what the switch defaults
 * to. All of it runs without a window, a worker or the model.
 */
import assert from 'node:assert/strict'
import { chunkKey, chunksOfPage } from '../shared/semantic/chunker.js'
import { SemanticIndex, type SemanticResult } from '../shared/semantic/semanticIndex.js'
import { SemanticVectorStore } from '../shared/semantic/vectorStore.js'
import { DIMENSION } from '../shared/semantic/model.js'
import { emptyManifest, GRACE_MS, noted, parseManifest, retained } from '../shared/semantic/manifest.js'
import { pickResults, placeKey } from '../shared/semantic/results.js'
import { plainNoteText } from '../shared/semantic/noteText.js'
import { store } from '../renderer/state.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

const DAY = 24 * 60 * 60 * 1000

function found(paperID: string, pageIndex: number, score: number, text = `passage of ${paperID} ${pageIndex}`, location = 0): SemanticResult {
  return { key: chunkKey(text), score, paperID, pageIndex, location, length: text.length, text }
}

function unit(seed: number): Float32Array {
  const v = new Float32Array(DIMENSION)
  v[seed % DIMENSION] = 1
  return v
}

export async function semanticPaletteSuite(test: Test, suite: (name: string) => void) {
  suite('What the palette is handed — the Mac\'s rule')

  await test('at most eight, at most three from one paper, best first', () => {
    const hits: SemanticResult[] = []
    for (let i = 0; i < 6; i++) hits.push(found('A', i, 0.9 - i * 0.01))
    for (let i = 0; i < 6; i++) hits.push(found('B', i, 0.8 - i * 0.01))
    for (let i = 0; i < 6; i++) hits.push(found('C', i, 0.7 - i * 0.01))
    const picked = pickResults(hits)
    assert.equal(picked.length, 8)
    assert.deepEqual(picked.map((h) => h.passage.paperID), ['A', 'A', 'A', 'B', 'B', 'B', 'C', 'C'])
    assert.ok(picked.every((h, i) => i === 0 || picked[i - 1].score >= h.score))
  })

  await test('a place the exact search already shows is left out', () => {
    const hits = [found('A', 3, 0.9), found('A', 4, 0.8), found('B', 0, 0.7)]
    const picked = pickResults(hits, { shown: new Set([placeKey({ paperID: 'A', pageIndex: 3 })]) })
    assert.deepEqual(picked.map((h) => `${h.passage.paperID}#${h.passage.pageIndex}`), ['A#4', 'B#0'])
  })

  await test('the snippet is the passage\'s words, tidied and at most 160 characters', () => {
    const long = 'word  '.repeat(60)
    const [picked] = pickResults([found('A', 0, 0.5, long)])
    assert.equal(picked.snippet.length, 160)
    assert.ok(!picked.snippet.includes('  '))
  })

  await test('the same key twice on one page is one row', () => {
    const [a, b] = [found('A', 0, 0.9, 'header', 10), found('A', 0, 0.9, 'header', 10)]
    assert.equal(pickResults([a, b]).length, 1)
    // …but at two places on the page it is two.
    assert.equal(pickResults([a, { ...b, location: 400 }]).length, 2)
  })

  suite('A paper away for a while keeps its vectors')

  await test('the manifest notes every paper given, with its keys', () => {
    const index = new SemanticIndex(new SemanticVectorStore())
    index.setPages([
      { paperID: 'A', pageIndex: 0, text: 'alpha '.repeat(120) },
      { paperID: 'B', pageIndex: 0, text: 'beta '.repeat(30) },
    ])
    const byPaper = index.keysByPaper()
    assert.deepEqual([...byPaper.keys()].sort(), ['A', 'B'])
    assert.equal(byPaper.get('A')!.length, chunksOfPage('alpha '.repeat(120), 'A', 0).length)
    const manifest = noted(emptyManifest(), byPaper, 1000)
    assert.equal(manifest.papers.A.seen, 1000)
    assert.deepEqual(manifest.papers.B.keys, byPaper.get('B'))
  })

  await test('within the grace a paper not among the pages keeps its vectors; past it they go', () => {
    const store = new SemanticVectorStore()
    const index = new SemanticIndex(store)
    const pagesA = [{ paperID: 'A', pageIndex: 0, text: 'alpha '.repeat(30) }]
    const pagesB = [{ paperID: 'B', pageIndex: 0, text: 'beta '.repeat(30) }]
    index.setPages([...pagesA, ...pagesB])
    let seed = 0
    for (const key of index.missing().map((c) => c.key)) store.insert(unit(seed++), key)
    let manifest = noted(emptyManifest(), index.keysByPaper(), 0)
    const keysB = manifest.papers.B.keys
    assert.equal(store.count, 2)

    // B's folder is disconnected: only A's pages come. Ten days on.
    index.setPages(pagesA)
    manifest = noted(manifest, index.keysByPaper(), 10 * DAY)
    let kept = retained(manifest, 10 * DAY)
    index.prune(kept.keep)
    assert.equal(store.count, 2, 'B kept through the grace')
    assert.deepEqual(kept.forgotten, [])

    // Forty days on, still without B.
    manifest = noted(kept.manifest, index.keysByPaper(), 40 * DAY)
    kept = retained(manifest, 40 * DAY)
    index.prune(kept.keep)
    assert.equal(store.count, 1)
    assert.deepEqual(kept.forgotten, ['B'])
    assert.ok(!store.contains(keysB[0]))
    assert.equal(GRACE_MS, 30 * DAY)
  })

  await test('a page whose text changed replaces its keys, and the old vector goes at once', () => {
    const store = new SemanticVectorStore()
    const index = new SemanticIndex(store)
    index.setPages([{ paperID: 'A', pageIndex: 0, text: 'one '.repeat(30) }])
    const [before] = index.missing().map((c) => c.key)
    store.insert(unit(1), before)
    let manifest = noted(emptyManifest(), index.keysByPaper(), 0)
    index.setPages([{ paperID: 'A', pageIndex: 0, text: 'two '.repeat(30) }])
    manifest = noted(manifest, index.keysByPaper(), 1)
    const kept = retained(manifest, 1)
    index.prune(kept.keep)
    assert.ok(!store.contains(before))
    assert.equal(manifest.papers.A.keys.length, 1)
    assert.notEqual(manifest.papers.A.keys[0], before)
  })

  await test('a manifest that is not one reads as empty', () => {
    assert.deepEqual(parseManifest('garbage'), emptyManifest())
    assert.deepEqual(parseManifest('{"version":2,"papers":{}}'), emptyManifest())
    const good = parseManifest('{"version":1,"papers":{"A":{"seen":5,"keys":["k",3]}}}')
    assert.deepEqual(good.papers.A, { seen: 5, keys: ['k'] })
  })

  suite('Notes among the passages — the Mac\'s rule')

  await test('a note\'s Markdown comes out and its words stay, as on the Mac', () => {
    // The same note as `NoteTextTests.markdown` in the Swift tests, held
    // to the same answer: both builds must cut a note to the same passages.
    const note = [
      '## Why models forget',
      '> The **first task\'s** accuracy _drops_ once the *second* is trained.',
      '- See [[202609061204|the EWC note]] and [the paper](https://arxiv.org/abs/1612.00796).',
      '1. `Fisher` diagonal',
      '![figure](fig.png) shows it. #catastrophic-forgetting',
    ].join('\n')
    assert.equal(plainNoteText(note), [
      'Why models forget',
      'The first task\'s accuracy drops once the second is trained.',
      'See the EWC note and the paper.',
      'Fisher diagonal',
      'figure shows it. catastrophic-forgetting',
    ].join('\n'))
  })

  await test('a formula keeps its letters and loses its dollars; fences and front matter go', () => {
    const plain = plainNoteText('Loss $$\\mathcal{L}_{\\text{rollout}}$$ and $x^2$ inline.')
    assert.ok(!plain.includes('$'))
    assert.ok(plain.includes('\\mathcal{L}_{\\text{rollout}}'))
    assert.ok(plain.includes('x^2'))
    const fenced = plainNoteText('---\nid: 1\n---\n```python\nx = 1\n```\n\n---\n\nafter')
    assert.ok(!fenced.includes('```') && !fenced.includes('id: 1') && !fenced.includes('---'))
    assert.ok(fenced.includes('x = 1') && fenced.includes('after'))
  })

  await test('the same words on a page and in a note share one key', () => {
    const words = 'Elastic weight consolidation slows learning.'
    const [page] = chunksOfPage(words, 'A', 0)
    const [note] = chunksOfPage(plainNoteText('> ' + words), 'note:1', 0)
    assert.equal(page.key, note.key)
  })

  await test('a note\'s passage comes back as a note, two a note at most, mixed with the papers by score', () => {
    const store = new SemanticVectorStore()
    const index = new SemanticIndex(store)
    index.setPages([
      { paperID: 'A', pageIndex: 0, text: 'alpha '.repeat(30) },
      { paperID: 'note:N', pageIndex: 0, text: Array.from({ length: 180 }, (_, i) => `w${i}`).join(' '), note: { id: 'N', paperID: 'A', title: 'A thought' } },
    ])
    assert.deepEqual(index.noteCounts, { notes: 1, passages: 3 })
    const found: SemanticResult[] = index.missing().map((chunk, i) => ({
      key: chunk.key, score: 0.9 - i * 0.1, paperID: chunk.paperID, pageIndex: chunk.pageIndex,
      location: chunk.location, length: chunk.length, text: chunk.text,
      ...(chunk.paperID === 'note:N' ? { note: { id: 'N', paperID: 'A', title: 'A thought' } } : {}),
    }))
    const picked = pickResults(found)
    assert.equal(picked.length, 3, 'one from the paper, two of the note\'s three')
    assert.equal(picked[0].note, undefined)
    assert.deepEqual(picked[1].note, { id: 'N', paperID: 'A', title: 'A thought' })
    assert.equal(picked.filter((h) => h.note).length, 2)
    assert.ok(picked.every((h, i) => i === 0 || picked[i - 1].score >= h.score))
  })

  await test('a note that quotes its paper is not a second row for the same words', () => {
    const words = 'the same passage in both '.repeat(8)
    const [page] = chunksOfPage(words, 'A', 3)
    const [note] = chunksOfPage(words, 'note:N', 0)
    const asFound = (chunk: typeof page, score: number, noted: boolean): SemanticResult => ({
      key: chunk.key, score, paperID: chunk.paperID, pageIndex: chunk.pageIndex,
      location: chunk.location, length: chunk.length, text: chunk.text,
      ...(noted ? { note: { id: 'N', paperID: 'A', title: 'Quote' } } : {}),
    })
    const picked = pickResults([asFound(page, 0.9, false), asFound(note, 0.9, true)])
    assert.equal(picked.length, 1)
    assert.equal(picked[0].passage.paperID, 'A')
  })

  suite('The switch')

  await test('search by meaning is on unless turned off', () => {
    assert.equal(store.settings.semanticSearch, true)
  })
}
