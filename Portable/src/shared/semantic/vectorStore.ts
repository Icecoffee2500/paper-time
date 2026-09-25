/**
 * Every passage's vector, in half precision, keyed by the passage's text —
 * `SemanticVectorStore.swift`, and the same bytes on disk.
 *
 * This is a cache and is treated as one: it lives with the device (next to
 * the text index, never in the library folder, which is synced and belongs
 * to the person), it knows which model made it and will not be read by
 * another, and anything wrong with the file means "start again", not an
 * error to show. Half precision because 384 floats a passage is 1.5 KB and
 * a library of 13,000 passages would be 20 MB — at fp16 it is 10 MB.
 *
 * Search is exact: every vector is scored. At this size that is a few
 * million multiplications, and an approximate index would buy nothing but a
 * chance of missing the best passage.
 *
 * The file: `PTSV`, a format version, the dimension, the count, the model
 * identifier, then every key (16 bytes: the digest's first eight bytes as a
 * little-endian u64, then the next eight) and every vector (2 bytes a
 * component), all little-endian.
 */
import { DIMENSION, MODEL_ID } from './model.js'
import { narrow, widen } from './fp16.js'
import type { ChunkKey } from './chunker.js'

export interface SemanticHit {
  key: ChunkKey
  /** Cosine similarity: the vectors are unit length, so this is the dot product. */
  score: number
}

export class StoreFileError extends Error {
  constructor(readonly reason: 'notAStore' | 'otherVersion' | 'otherModel' | 'otherDimension' | 'truncated', detail?: string) {
    super(detail ? `${reason}: ${detail}` : reason)
  }
}

const MAGIC = [0x50, 0x54, 0x53, 0x56] // "PTSV"
const FORMAT_VERSION = 1
const encoder = new TextEncoder()
const decoder = new TextDecoder()

export class SemanticVectorStore {
  static readonly dimension = DIMENSION

  readonly model: string
  private _keys: ChunkKey[] = []
  private rows = new Map<ChunkKey, number>()
  /** `count × dimension` fp16 bit patterns, row after row. */
  private halves = new Uint16Array(0)
  private used = 0

  constructor(model: string = MODEL_ID) {
    this.model = model
  }

  get count(): number {
    return this._keys.length
  }

  get keys(): readonly ChunkKey[] {
    return this._keys
  }

  contains(key: ChunkKey): boolean {
    return this.rows.has(key)
  }

  /** The stored vector, back in single precision. */
  vector(key: ChunkKey): Float32Array | null {
    const row = this.rows.get(key)
    if (row === undefined) return null
    const out = new Float32Array(DIMENSION)
    widen(this.halves, row * DIMENSION, DIMENSION, out)
    return out
  }

  /**
   * Adds or replaces a vector. It is normalised on the way in, so a caller's
   * rounding never shows up as one passage outscoring another.
   */
  insert(vector: ArrayLike<number>, key: ChunkKey): void {
    if (vector.length !== DIMENSION) throw new Error(`a ${DIMENSION}-dimensional vector`)
    let norm = 0
    for (let i = 0; i < DIMENSION; i++) norm += vector[i] * vector[i]
    norm = Math.sqrt(norm)
    const unit = new Float32Array(DIMENSION)
    const scale = norm > 0 ? 1 / norm : 1
    for (let i = 0; i < DIMENSION; i++) unit[i] = vector[i] * scale
    let row = this.rows.get(key)
    if (row === undefined) {
      row = this._keys.length
      this.rows.set(key, row)
      this._keys.push(key)
      this.grow((row + 1) * DIMENSION)
      this.used = (row + 1) * DIMENSION
    }
    narrow(unit, this.halves, row * DIMENSION)
  }

  private grow(needed: number) {
    if (needed <= this.halves.length) return
    const bigger = new Uint16Array(Math.max(needed, this.halves.length * 2, 64 * DIMENSION))
    bigger.set(this.halves.subarray(0, this.used))
    this.halves = bigger
  }

  /**
   * Keeps only these keys: the passages that still exist. Without this a
   * removed paper's passages would go on taking places in every answer.
   */
  retain(keep: ReadonlySet<ChunkKey>): void {
    if (!this._keys.some((key) => !keep.has(key))) return
    const keptKeys: ChunkKey[] = []
    const kept = new Uint16Array(this.used)
    let at = 0
    this._keys.forEach((key, row) => {
      if (!keep.has(key)) return
      keptKeys.push(key)
      kept.set(this.halves.subarray(row * DIMENSION, (row + 1) * DIMENSION), at)
      at += DIMENSION
    })
    this._keys = keptKeys
    this.halves = kept
    this.used = at
    this.rows = new Map(keptKeys.map((key, row) => [key, row]))
  }

  // MARK: - Search

  /**
   * The `k` passages closest to `query`, best first; ties go to the passage
   * stored first, so the same store always answers the same way.
   */
  search(query: ArrayLike<number>, k: number): SemanticHit[] {
    if (query.length !== DIMENSION) throw new Error(`a ${DIMENSION}-dimensional query`)
    const n = this._keys.length
    if (k <= 0 || n === 0) return []
    const best = new TopK(Math.min(k, n))
    const block = 2048
    const wide = new Float32Array(Math.min(block, n) * DIMENSION)
    const q = Float32Array.from(query)
    for (let start = 0; start < n; start += block) {
      const rows = Math.min(block, n - start)
      widen(this.halves, start * DIMENSION, rows * DIMENSION, wide)
      for (let r = 0; r < rows; r++) {
        let score = 0
        const base = r * DIMENSION
        for (let i = 0; i < DIMENSION; i++) score += wide[base + i] * q[i]
        best.offer(Math.fround(score), start + r)
      }
    }
    return best.sorted().map(({ score, row }) => ({ key: this._keys[row], score }))
  }

  // MARK: - File

  encoded(): Uint8Array {
    const modelBytes = encoder.encode(this.model)
    const n = this._keys.length
    const out = new Uint8Array(20 + modelBytes.length + n * 16 + n * DIMENSION * 2)
    const view = new DataView(out.buffer)
    out.set(MAGIC, 0)
    view.setUint32(4, FORMAT_VERSION, true)
    view.setUint32(8, DIMENSION, true)
    view.setUint32(12, n, true)
    view.setUint32(16, modelBytes.length, true)
    out.set(modelBytes, 20)
    let at = 20 + modelBytes.length
    for (const key of this._keys) {
      writeKey(key, out, at)
      at += 16
    }
    for (let i = 0; i < n * DIMENSION; i++) {
      view.setUint16(at, this.halves[i], true)
      at += 2
    }
    return out
  }

  /** Reads a store, and says why when it will not. */
  static decode(bytes: Uint8Array, model: string = MODEL_ID): SemanticVectorStore {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    if (bytes.length < 4 || MAGIC.some((byte, i) => bytes[i] !== byte)) throw new StoreFileError('notAStore')
    const number = (at: number) => {
      if (at + 4 > bytes.length) throw new StoreFileError('truncated')
      return view.getUint32(at, true)
    }
    const version = number(4)
    if (version !== FORMAT_VERSION) throw new StoreFileError('otherVersion', String(version))
    const dimension = number(8)
    if (dimension !== DIMENSION) throw new StoreFileError('otherDimension', String(dimension))
    const count = number(12)
    const modelLength = number(16)
    if (20 + modelLength > bytes.length) throw new StoreFileError('truncated')
    const stored = decoder.decode(bytes.subarray(20, 20 + modelLength))
    if (stored !== model) throw new StoreFileError('otherModel', stored)
    let at = 20 + modelLength
    if (at + count * 16 + count * dimension * 2 > bytes.length) throw new StoreFileError('truncated')
    const store = new SemanticVectorStore(model)
    const keys: ChunkKey[] = []
    for (let i = 0; i < count; i++) {
      keys.push(readKey(bytes, at))
      at += 16
    }
    const halves = new Uint16Array(count * dimension)
    for (let i = 0; i < halves.length; i++) {
      halves[i] = view.getUint16(at, true)
      at += 2
    }
    store._keys = keys
    store.halves = halves
    store.used = halves.length
    // A key twice in the file keeps its first row, as the Mac keeps it.
    keys.forEach((key, row) => {
      if (!store.rows.has(key)) store.rows.set(key, row)
    })
    return store
  }
}

/** The key's 32 digits as the Mac writes them: two little-endian u64s. */
function writeKey(key: ChunkKey, into: Uint8Array, at: number) {
  for (let half = 0; half < 2; half++) {
    for (let i = 0; i < 8; i++) {
      const digit = half * 16 + i * 2
      into[at + half * 8 + (7 - i)] = parseInt(key.slice(digit, digit + 2), 16)
    }
  }
}

function readKey(from: Uint8Array, at: number): ChunkKey {
  let out = ''
  for (let half = 0; half < 2; half++) {
    for (let i = 7; i >= 0; i--) out += from[at + half * 8 + i].toString(16).padStart(2, '0')
  }
  return out
}

/** A fixed-size min-heap of the best rows so far. */
class TopK {
  private heap: Array<{ score: number; row: number }> = []

  constructor(readonly capacity: number) {}

  /** Worse means lower score, or the same score on a later row. */
  private static worse(a: { score: number; row: number }, b: { score: number; row: number }): boolean {
    return a.score < b.score || (a.score === b.score && a.row > b.row)
  }

  offer(score: number, row: number) {
    const item = { score, row }
    const heap = this.heap
    if (heap.length < this.capacity) {
      heap.push(item)
      let child = heap.length - 1
      while (child > 0) {
        const parent = (child - 1) >> 1
        if (!TopK.worse(heap[child], heap[parent])) break
        ;[heap[child], heap[parent]] = [heap[parent], heap[child]]
        child = parent
      }
    } else if (TopK.worse(heap[0], item)) {
      heap[0] = item
      let parent = 0
      for (;;) {
        const left = 2 * parent + 1
        const right = left + 1
        let worst = parent
        if (left < heap.length && TopK.worse(heap[left], heap[worst])) worst = left
        if (right < heap.length && TopK.worse(heap[right], heap[worst])) worst = right
        if (worst === parent) break
        ;[heap[parent], heap[worst]] = [heap[worst], heap[parent]]
        parent = worst
      }
    }
  }

  sorted(): Array<{ score: number; row: number }> {
    return [...this.heap].sort((a, b) => (TopK.worse(b, a) ? -1 : TopK.worse(a, b) ? 1 : 0))
  }
}
