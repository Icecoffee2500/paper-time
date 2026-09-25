/**
 * Search by meaning, held to the Mac and to sentence-transformers.
 *
 * Three things have to agree across the two builds: the token ids (or a
 * passage is a different point in the space), the passages and their keys
 * (or the same page is cached twice), and the bytes of the vector cache (or
 * one build's cache is the other's "start again"). The ids and the vectors
 * are held to the reference the Mac's tests read (`minilm-reference.json`,
 * written by `Scripts/semantic-reference.py`); the passages and the cache
 * are held to the real Swift (`fixtures/macSemantic.*`, written by
 * `tools/generate-semantic-fixtures.mjs`).
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { hex, sha256 } from '../shared/semantic/sha256.js'
import { fromHalf, toHalf } from '../shared/semantic/fp16.js'
import { WordPiece } from '../shared/semantic/wordpiece.js'
import { chunkKey, chunksOfPage, type SemanticChunk } from '../shared/semantic/chunker.js'
import { DIMENSION, MODEL_ID, VOCAB_FILE } from '../shared/semantic/model.js'
import { SemanticVectorStore, StoreFileError } from '../shared/semantic/vectorStore.js'
import { SemanticEmbedder } from '../shared/semantic/embedder.js'
import { defaultThreads, loadEmbedder } from '../main/semanticModel.js'

type Test = (name: string, body: () => void | Promise<void>) => Promise<void>

interface Reference {
  max_seq_length: number
  tokens: { text: string; ids: number[]; note?: string }[]
  passages: { text: string; vector: number[] }[]
  queries: { text: string; vector: number[] }[]
  top5: { query: string; passages: number[] }[]
}

interface MacFixture {
  chunks: {
    text: string
    paperID: string
    pageIndex: number
    windowWords: number
    overlapWords: number
    chunks: { location: number; length: number; text: string; key: string }[]
  }[]
  store: { keys: string[]; first: number[]; bytes: number }
}

const repo = path.join(__dirname, '../..', '..')
const fixtures = path.join(__dirname, '../../src/test/fixtures')
/** Where `build.mjs` puts the model, the vocabulary and the runtime's files. */
const modelDirectory = path.join(__dirname, '../main/semantic')

const reference = JSON.parse(fs.readFileSync(
  path.join(repo, 'Packages/PaperTimeKit/Tests/SemanticTests/Fixtures/minilm-reference.json'), 'utf8')) as Reference
const mac = JSON.parse(fs.readFileSync(path.join(fixtures, 'macSemantic.json'), 'utf8')) as MacFixture

function dot(a: ArrayLike<number>, b: ArrayLike<number>): number {
  let sum = 0
  for (let i = 0; i < a.length; i++) sum += a[i] * b[i]
  return sum
}

/** Indices of the `k` best-scoring rows, best first; ties to the earlier row. */
function topIndices(scores: number[], k: number): number[] {
  return scores.map((_, i) => i).sort((a, b) => scores[b] - scores[a] || a - b).slice(0, k)
}

/** `Randoms` from the Mac's `VectorStoreTests`, arithmetic for arithmetic. */
class Randoms {
  constructor(private state: bigint) {}

  next(): number {
    this.state = (this.state * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn
    return Number(this.state >> 11n) / 2 ** 53
  }

  unit(d = DIMENSION): Float32Array {
    const v = new Float32Array(d)
    for (let i = 0; i < d; i++) v[i] = Math.fround(this.next() * 2 - 1)
    let sum = 0
    for (let i = 0; i < d; i++) sum = Math.fround(sum + Math.fround(v[i] * v[i]))
    const n = Math.fround(Math.sqrt(sum))
    for (let i = 0; i < d; i++) v[i] = Math.fround(v[i] / n)
    return v
  }
}

const key = (i: number) => chunkKey(`passage ${i}`)

export async function semanticSuite(test: Test, suite: (name: string) => void) {
  // ------------------------------------------------------------ tokenizer
  suite('The tokenizer gives Hugging Face\'s ids')
  const tokenizer = new WordPiece(fs.readFileSync(path.join(modelDirectory, VOCAB_FILE), 'utf8'))

  await test('the vocabulary is the model\'s: 30,522 entries', () => {
    assert.equal(tokenizer.vocab.size, 30522)
  })

  await test(`every one of ${reference.tokens.length} reference strings, id for id`, () => {
    assert.equal(reference.tokens.length, 51)
    const wrong: string[] = []
    for (const item of reference.tokens) {
      const ids = tokenizer.encode(item.text, reference.max_seq_length)
      if (ids.join() !== item.ids.join()) {
        wrong.push(`${JSON.stringify(item.text.slice(0, 40))}: ${ids.slice(0, 24)} ≠ ${item.ids.slice(0, 24)}`)
      }
    }
    assert.equal(wrong.length, 0, `${wrong.length} differ:\n${wrong.join('\n')}`)
  })

  await test('a text longer than the model reads is cut to 256 ids, [SEP] last', () => {
    const long = reference.tokens.find((t) => t.note !== undefined)!
    const ids = tokenizer.encode(long.text)
    assert.equal(ids.length, 256)
    assert.equal(ids[0], 101)
    assert.equal(ids[ids.length - 1], 102)
    assert.ok(tokenizer.piecesOf(long.text).length > 254)
  })

  /**
   * The edges the fixture does not reach, each pinning one rule, with the ids
   * `BertTokenizerFast` (tokenizers 0.22.2) gave — the Mac's `TokenizerTests`
   * list, case for case. Several are about which Unicode the rules are read
   * from: the reference's categories are frozen at Unicode 8.0, so a mark or
   * punctuation added later is a letter to the model. The Mac cuts the OS's
   * tables at that version by each scalar's age; here the tables were written
   * by asking the reference about every code point, so the cut is in them.
   */
  const edges: [string, number[]][] = [
    ['[MASK] x [CLS]', [101, 103, 1060, 101, 102]],        // special tokens are found first, anywhere
    ['[mask]', [101, 1031, 7308, 1033, 102]],              // …but only as written
    ['a[SEP]b', [101, 1037, 102, 1038, 102]],              // …even inside a word
    ['x [PAD] y', [101, 1060, 0, 1061, 102]],
    ['İstanbul', [101, 9960, 102]],                         // NFD strips the dot before lowercasing
    ['ΣΑΣ', [101, 1173, 14608, 29733, 102]],                // lowercase by character: σ, not ς
    ['ẞ', [101, 1096, 102]],
    ['ǅ', [101, 100, 102]],
    ['a­b', [101, 11113, 102]],                       // Cf is dropped
    ['x‍y', [101, 1060, 2100, 102]],                   // and joins what was either side
    ['ab', [101, 11113, 102]],                        // Co is dropped
    ['a\u000Bb', [101, 11113, 102]],                        // a control that is also white space: dropped
    ['a b', [101, 1037, 1038, 102]],                   // white space that is not a control: a break
    ['a　b', [101, 1037, 1038, 102]],
    ['a ͸ b', [101, 1037, 100, 1038, 102]],            // unassigned is not dropped
    ['a \u{1F970} b', [101, 1037, 100, 1038, 102]],         // an emoji newer than Unicode 9 is a word
    ['a⹂b', [101, 1037, 100, 1038, 102]],              // punctuation from Unicode 7: split off
    ['a⹅b', [101, 100, 102]],                          // punctuation from Unicode 10: part of the word
    ['ab᪰', [101, 11113, 102]],                        // a mark from Unicode 7: stripped
    ['q᫁', [101, 100, 102]],                           // a mark from Unicode 14: kept
    ['aࣔb', [101, 100, 102]],                          // a mark from Unicode 9: kept, so 8.0 is the cut
    ['a᙭b', [101, 1037, 100, 1038, 102]],              // Po in 8.0, So now: still punctuation
    ['a᜴b', [101, 11113, 102]],                        // Mn in 8.0, Mc now: still stripped
    ['aᢅb', [101, 100, 102]],                          // Lo in 8.0, Mn now: still a letter
    ['a\u{2B820}b', [101, 100, 102]],                       // the library's CJK range starts at 2B920…
    ['a\u{2B920}b', [101, 1037, 100, 1038, 102]],           // …so this one is split off and that one is not
    ['x⃝', [101, 100, 102]],                           // an enclosing mark (Me) is not Mn
    ['a·b', [101, 1037, 1087, 1038, 102]],                  // Po outside ASCII is punctuation
    ['a´b', [101, 1037, 29658, 2497, 102]],                 // Sk outside ASCII is not
    ['a^b', [101, 1037, 1034, 1038, 102]],                  // Sk inside ASCII is
    ['ﬁ', [101, 1984, 102]],                           // NFD, not NFKD: the ligature stays
    ['é'.repeat(101), [101, 100, 102]],                // 101 characters once decomposed
  ]
  await test(`the ${edges.length} edges the fixture does not reach`, () => {
    const wrong = edges
      .filter(([text, ids]) => tokenizer.encode(text).join() !== ids.join())
      .map(([text, ids]) => `${JSON.stringify(text.slice(0, 20))}: ${tokenizer.encode(text)} ≠ ${ids}`)
    assert.equal(wrong.length, 0, wrong.join('\n'))
  })

  await test('a limit stops the work, not only the output', () => {
    const text = 'catastrophic forgetting '.repeat(400)
    const ids = tokenizer.encode(text, 16)
    assert.equal(ids.length, 16)
    assert.deepEqual(ids, [101, ...tokenizer.piecesOf(text).slice(0, 14), 102])
  })

  // -------------------------------------------------------------- chunker
  suite('Pages cut into passages, as the Mac cuts them')

  await test('SHA-256 is SHA-256', () => {
    for (const text of ['', 'hello', 'a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), '강화학습 😀 ' + 'x'.repeat(1000)]) {
      assert.equal(hex(sha256(text)), createHash('sha256').update(text).digest('hex'))
    }
  })

  await test('the key is the first half of the text\'s SHA-256', () => {
    assert.equal(chunkKey('hello'), '2cf24dba5fb0a30e26e83b2ac5b9e29e')
  })

  await test(`every one of ${mac.chunks.length} pages cuts into the Mac's passages, key for key`, () => {
    for (const page of mac.chunks) {
      const ours = chunksOfPage(page.text, page.paperID, page.pageIndex, page.windowWords, page.overlapWords)
      assert.deepEqual(
        ours.map(({ location, length, text, key }) => ({ location, length, text, key })),
        page.chunks,
        `page ${page.pageIndex} ${JSON.stringify(page.text.slice(0, 30))}`,
      )
      for (const chunk of ours) {
        assert.equal(chunk.paperID, page.paperID)
        // The range covers the passage on the page, white space and all.
        const original = page.text.slice(chunk.location, chunk.location + chunk.length)
        assert.equal(original.split(/\p{White_Space}+/u).join(' '), chunk.text)
      }
    }
  })

  await test('a page with no words has no passages', () => {
    assert.deepEqual(chunksOfPage('', 'p', 0), [])
    assert.deepEqual(chunksOfPage(' \n\t　 ', 'p', 0), [])
  })

  await test('the key is the text\'s, not its line breaks\' or its place\'s', () => {
    const a = chunksOfPage('machine\nunlearning  removes data', 'p', 0)[0]
    const b = chunksOfPage('machine unlearning removes\tdata', 'q', 9)[0]
    assert.equal(a.key, b.key)
    assert.notEqual(a.key, chunksOfPage('machine unlearning removes datum', 'p', 0)[0].key)
  })

  // ----------------------------------------------------------------- fp16
  suite('Half precision, bit for bit')

  await test('a value survives the round trip as fp16 keeps it', () => {
    const cases = [0, -0, 1, -1, 0.5, 65504, 1e-8, 6.1e-5, 5.96e-8, 3.05e-5, Math.PI, -0.1234567, 1e5, Infinity, -Infinity]
    for (const value of cases) {
      const back = fromHalf(toHalf(value))
      if (!Number.isFinite(value)) assert.equal(back, Math.abs(value) > 65504 ? value : value)
      else if (Math.abs(value) > 65504) assert.equal(back, Math.sign(value) * Infinity)
      else assert.ok(Math.abs(back - value) <= Math.max(Math.abs(value) * 2 ** -11, 2 ** -25), `${value} → ${back}`)
    }
    assert.ok(Number.isNaN(fromHalf(toHalf(NaN))))
    assert.equal(toHalf(-0), 0x8000)
    assert.equal(toHalf(65504), 0x7bff)
    assert.equal(toHalf(65520), 0x7c00)              // rounds up into infinity
    assert.equal(toHalf(2 ** -24), 0x0001)           // the smallest subnormal
    assert.equal(toHalf(2 ** -25), 0x0000)           // a tie, to even
    assert.equal(toHalf(2 ** -25 * 1.5), 0x0001)
    assert.equal(toHalf(1 + 2 ** -11), 0x3c00)       // a tie, to even
    assert.equal(toHalf(1 + 3 * 2 ** -11), 0x3c02)   // a tie, to even (odd → up)
  })

  await test('every fp16 pattern reads back to the value it means', () => {
    for (let half = 0; half < 0x10000; half++) {
      const value = fromHalf(half)
      if (Number.isNaN(value)) continue
      assert.equal(toHalf(value), half === 0x8000 ? 0x8000 : half, `pattern ${half.toString(16)}`)
    }
  })

  // ---------------------------------------------------------------- store
  suite('The vector cache, the same bytes as the Mac\'s')

  await test('fifty of the Mac\'s vectors write the Mac\'s file, byte for byte', () => {
    const random = new Randoms(3n)
    const store = new SemanticVectorStore()
    let first: Float32Array | null = null
    for (let i = 0; i < 50; i++) {
      const v = random.unit()
      first ??= v
      store.insert(v, key(i))
    }
    assert.deepEqual(Array.from(first!.slice(0, 3)), mac.store.first.slice(0, 3).map(Math.fround))
    assert.deepEqual(store.keys, mac.store.keys)
    const ours = store.encoded()
    const theirs = new Uint8Array(fs.readFileSync(path.join(fixtures, 'macSemantic.bin')))
    assert.equal(ours.length, theirs.length)
    assert.equal(ours.length, 4 + 4 * 4 + MODEL_ID.length + 50 * 16 + 50 * 384 * 2)
    let differ = -1
    for (let i = 0; i < ours.length; i++) if (ours[i] !== theirs[i]) { differ = i; break }
    assert.equal(differ, -1, `first differing byte at ${differ}`)
  })

  await test('the Mac\'s file reads back: its keys, its vectors, its search', () => {
    const theirs = new Uint8Array(fs.readFileSync(path.join(fixtures, 'macSemantic.bin')))
    const store = SemanticVectorStore.decode(theirs)
    assert.equal(store.count, 50)
    assert.deepEqual(store.keys, mac.store.keys)
    const first = store.vector(key(0))!
    assert.ok(mac.store.first.every((x, i) => Math.abs(x - first[i]) < 1e-3))
    assert.deepEqual(store.encoded(), theirs)
    const hits = store.search(first, 3)
    assert.equal(hits[0].key, key(0))
    assert.ok(hits[0].score > 0.999)
  })

  await test('a vector comes back as fp16 would keep it, and unit length', () => {
    const random = new Randoms(1n)
    const store = new SemanticVectorStore()
    const v = random.unit().map((x) => x * 3)
    store.insert(v, key(0))
    const back = store.vector(key(0))!
    assert.ok(Math.abs(Math.sqrt(dot(back, back)) - 1) < 1e-3)
    assert.ok(back.every((x, i) => Math.abs(x - v[i] / 3) < 1e-3))
    assert.ok(store.contains(key(0)))
    assert.ok(!store.contains(key(1)))
  })

  await test('a key inserted twice holds the second vector once', () => {
    const random = new Randoms(2n)
    const store = new SemanticVectorStore()
    store.insert(random.unit(), key(0))
    const second = random.unit()
    store.insert(second, key(0))
    assert.equal(store.count, 1)
    assert.ok(dot(store.vector(key(0))!, second) > 0.9999)
  })

  await test('another model\'s cache, a damaged one, or none at all is refused by name', () => {
    const store = new SemanticVectorStore('some-other-model')
    store.insert(new Randoms(4n).unit(), key(0))
    const data = store.encoded()
    assert.throws(() => SemanticVectorStore.decode(data), (e: StoreFileError) => e.reason === 'otherModel')
    assert.throws(() => SemanticVectorStore.decode(data.subarray(0, data.length - 1), 'some-other-model'),
      (e: StoreFileError) => e.reason === 'truncated')
    assert.throws(() => SemanticVectorStore.decode(new TextEncoder().encode('not a store')),
      (e: StoreFileError) => e.reason === 'notAStore')
  })

  await test('retaining drops the passages that are gone and keeps the rest intact', () => {
    const random = new Randoms(5n)
    const store = new SemanticVectorStore()
    for (let i = 0; i < 20; i++) store.insert(random.unit(), key(i))
    const kept = [...Array(20).keys()].filter((i) => i % 3 === 0)
    const before = kept.map((i) => store.vector(key(i))!)
    store.retain(new Set(kept.map(key)))
    assert.equal(store.count, kept.length)
    assert.deepEqual(store.keys, kept.map(key))
    kept.forEach((i, at) => assert.deepEqual(store.vector(key(i)), before[at]))
    assert.ok(!store.contains(key(1)))
    assert.deepEqual(SemanticVectorStore.decode(store.encoded()).keys, kept.map(key))
  })

  await test('search scores every vector: the same answer as doing it by hand', () => {
    const random = new Randoms(6n)
    const store = new SemanticVectorStore()
    for (let i = 0; i < 5000; i++) store.insert(random.unit(), key(i))
    for (let round = 0; round < 5; round++) {
      const query = random.unit()
      const byHand = store.keys.map((k) => dot(store.vector(k)!, query))
      const expected = topIndices(byHand, 10).map((i) => store.keys[i])
      const hits = store.search(query, 10)
      assert.deepEqual(hits.map((h) => h.key), expected)
      hits.forEach((hit, at) => assert.ok(Math.abs(hit.score - byHand[topIndices(byHand, 10)[at]]) < 1e-4))
      for (let i = 1; i < hits.length; i++) assert.ok(hits[i - 1].score >= hits[i].score)
    }
  })

  await test('asking for more than there is returns all of it, best first; ties keep their order', () => {
    const store = new SemanticVectorStore()
    const v = new Float32Array(384)
    v[0] = 1
    store.insert(v, key(0))
    store.insert(v, key(1))
    const w = new Float32Array(384)
    w[1] = 1
    store.insert(w, key(2))
    const hits = store.search(v, 10)
    assert.deepEqual(hits.map((h) => h.key), [key(0), key(1), key(2)])
    assert.deepEqual(hits.map((h) => h.score), [1, 1, 0])
    assert.deepEqual(new SemanticVectorStore().search(v, 5), [])
    assert.deepEqual(store.search(v, 0), [])
  })

  // ------------------------------------------------------------ embeddings
  suite('Embeddings agree with sentence-transformers')

  let embedder: SemanticEmbedder | null = null
  let passages: Float32Array[] = []
  let queries: Float32Array[] = []
  let loadMs = 0

  await test('the model loads from the files beside the worker', async () => {
    const t0 = performance.now()
    embedder = await loadEmbedder({ directory: modelDirectory })
    loadMs = performance.now() - t0
  })

  /**
   * The bar is per vector, not on average: one passage that lands somewhere
   * else is one passage that is never found. Measured: the lowest cosine is
   * 0.99999 and above (fp32 arithmetic on fp16-stored weights), so 0.9999 —
   * the Mac's own bar — leaves room without letting a broken pipeline through.
   */
  await test('each vector is within 0.9999 of the reference, and every query ranks the passages in the same order', async () => {
    assert.ok(embedder, 'no model')
    passages = await embedder.embedBatch(reference.passages.map((p) => p.text))
    queries = []
    for (const query of reference.queries) queries.push(await embedder.embedQuery(query.text))
    const cosines = [
      ...passages.map((v, i) => dot(v, reference.passages[i].vector)),
      ...queries.map((v, i) => dot(v, reference.queries[i].vector)),
    ]
    assert.equal(cosines.length, 30)
    const lowest = Math.min(...cosines)
    const differ = reference.top5.flatMap((order, i) => {
      const scores = passages.map((p) => dot(p, queries[i]))
      return topIndices(scores, 5).join() === order.passages.join() ? [] : [i]
    })
    process.stdout.write(`      lowest cosine ${lowest.toFixed(7)} over 30 texts; top-5 identical on ${15 - differ.length} of 15 queries\n`)
    assert.ok(lowest >= 0.9999, `lowest cosine ${lowest}`)
    assert.deepEqual(differ, [], `top-5 order differs for queries ${differ}`)
  })

  await test('a passage alone, in a batch, or padded next to a 256-token text is the same vector', async () => {
    assert.ok(embedder, 'no model')
    const texts = reference.passages.map((p) => p.text)
    const batched = await embedder.embedBatch(texts)
    for (let i = 0; i < texts.length; i++) {
      assert.ok(dot(await embedder.embedQuery(texts[i]), batched[i]) > 0.99999)
    }
    const long = reference.tokens.find((t) => t.note !== undefined)!.text
    const pair = await embedder.embedBatch(['catastrophic forgetting', long])
    assert.ok(dot(pair[0], await embedder.embedQuery('catastrophic forgetting')) > 0.99999)
  })

  await test('the stream covers every distinct passage once and stops when told', async () => {
    assert.ok(embedder, 'no model')
    const page = reference.passages.map((p) => p.text).join(' ')
    let chunks = chunksOfPage(`${page} ${page} ${page}`, 'paper', 0, 20, 5)
    chunks = [...chunks, ...chunks]
    const distinct = new Set(chunks.map((c) => c.key))
    const seen: string[] = []
    await embedder.embedChunks(chunks, (e) => {
      seen.push(e.key)
      assert.equal(e.vector.length, 384)
    }, 4)
    assert.equal(seen.length, distinct.size)
    assert.deepEqual(new Set(seen), distinct)

    const many: SemanticChunk[] = Array.from({ length: 400 }, (_, i) => ({
      paperID: 'paper', pageIndex: 0, location: 0, length: 1,
      text: `passage number ${i} about forgetting`, key: chunkKey(`p${i}`),
    }))
    const controller = new AbortController()
    let count = 0
    await embedder.embedChunks(many, () => {
      count += 1
      if (count === 8) controller.abort()
    }, 8, controller.signal)
    assert.equal(count, 8)
  })

  await test('a vector into the store and out again ranks as the reference ranks', async () => {
    assert.ok(embedder, 'no model')
    const store = new SemanticVectorStore()
    passages.forEach((v, i) => store.insert(v, chunkKey(reference.passages[i].text)))
    const read = SemanticVectorStore.decode(store.encoded())
    // Left for the Swift side to open: `tools/mac-semantic verify out/test/portable-store.bin`.
    fs.writeFileSync(path.join(__dirname, 'portable-store.bin'), store.encoded())
    reference.top5.forEach((order, i) => {
      const hits = read.search(queries[i], 5).map((h) => read.keys.indexOf(h.key))
      assert.deepEqual(hits, order.passages, `query ${i}`)
    })
  })

  suite('How long it takes (reported, not judged)')

  await test('ms per passage and per query', async () => {
    assert.ok(embedder, 'no model')
    // Passages as the chunker makes them — 100 words — from the reference's
    // texts in rotated orders, so that no two are the same.
    const texts = reference.passages.map((p) => p.text)
    const chunks: SemanticChunk[] = []
    for (let round = 0; chunks.length < 64; round++) {
      const page = [...texts.slice(round), ...texts.slice(0, round)].join(' ')
      chunks.push(...chunksOfPage(page, 'p', round))
    }
    chunks.length = 64
    await embedder.embedChunks(chunks.slice(0, 16), () => {}, 16)   // warm
    let t0 = performance.now()
    await embedder.embedChunks(chunks, () => {}, 16)
    const perPassage = (performance.now() - t0) / chunks.length
    await embedder.embedQuery('warm')
    t0 = performance.now()
    for (const query of reference.queries) await embedder.embedQuery(query.text)
    const perQuery = (performance.now() - t0) / reference.queries.length
    const tokens = chunks.reduce((sum, c) => sum + tokenizer.encode(c.text).length, 0) / chunks.length
    process.stdout.write(`      load ${loadMs.toFixed(0)} ms; ${perPassage.toFixed(1)} ms/passage (${chunks.length} passages of ~${tokens.toFixed(0)} tokens, batches of 16, ${defaultThreads()} threads); ${perQuery.toFixed(1)} ms/query\n`)
  })

  await (embedder as SemanticEmbedder | null)?.model.close?.()
}
