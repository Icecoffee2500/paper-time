/**
 * Text in, unit vectors out: the tokenizer and the model together —
 * `SemanticEmbedder.swift`, over whatever runs the graph.
 *
 * The graph itself is not here. Node loads it one way (`main/semanticModel.ts`,
 * ONNX Runtime's WebAssembly build from files on disk) and a test may hand in
 * anything that answers the same call, so the embedder only knows a
 * `SentenceModel`: padded ids and a mask in, rows of 384 out. Mean pooling
 * and L2 normalisation are inside the graph, so nothing here can pool
 * differently from sentence-transformers.
 *
 * Inputs are padded to a few fixed lengths, as on the Mac. ONNX Runtime does
 * not compile a shape the way the GPU there does, so the reason is a smaller
 * one: a batch sorted by length pads to its own bucket and not to the longest
 * text in the library, and a bucket is a length the runtime's arena has seen
 * before. Padding changes nothing in the vectors (padded positions are masked
 * out of attention and out of the mean).
 */
import type { SemanticChunk, ChunkKey } from './chunker.js'
import { DIMENSION, MAX_TOKENS } from './model.js'
import { WordPiece } from './wordpiece.js'

/** Sequence lengths the input is padded up to. */
export const LENGTHS = [16, 32, 64, 96, 128, 160, 192, 224, 256]
/** The most texts one call takes. */
export const MAX_BATCH = 64

export interface SentenceModel {
  /**
   * `rows × length` token ids (padded with `[PAD]` = 0) and the same shape of
   * 1/0 mask, flattened row after row; back come `rows × DIMENSION` floats.
   */
  run(ids: Int32Array, mask: Int32Array, rows: number, length: number): Promise<Float32Array>
  close?(): Promise<void> | void
}

export interface SemanticEmbedding {
  key: ChunkKey
  vector: Float32Array
}

export class SemanticEmbedder {
  constructor(readonly tokenizer: WordPiece, readonly model: SentenceModel) {}

  /**
   * A query, embedded the way a passage is: the model was trained with no
   * prefix and no separate query encoder, so there is nothing to add.
   */
  async embedQuery(text: string): Promise<Float32Array> {
    return (await this.embedBatch([text]))[0]
  }

  /** Several texts in one call to the model. At most `MAX_BATCH`. */
  async embedBatch(texts: string[]): Promise<Float32Array[]> {
    if (texts.length === 0) return []
    if (texts.length > MAX_BATCH) throw new Error(`the model takes at most ${MAX_BATCH} texts at a time`)
    return this.run(texts.map((text) => this.tokenizer.encode(text, MAX_TOKENS)))
  }

  /**
   * Every passage's vector, a batch at a time, for the passages it is given
   * — pass only those not already in the store. Passages with the same key
   * are embedded once. They come back in their own order within each stretch
   * of `batchSize × 16`: inside a stretch they are sorted by length, so a
   * batch pads to its own length and not to the longest in the library.
   *
   * `signal` stops the work after the batch in flight: nothing keeps running
   * for a palette that has closed.
   */
  async embedChunks(
    chunks: readonly SemanticChunk[],
    onVector: (embedding: SemanticEmbedding) => void,
    batchSize = 16,
    signal?: AbortSignal,
  ): Promise<void> {
    const seen = new Set<ChunkKey>()
    const unique = chunks.filter((chunk) => {
      if (seen.has(chunk.key)) return false
      seen.add(chunk.key)
      return true
    })
    const size = Math.min(Math.max(batchSize, 1), MAX_BATCH)
    for (let stretch = 0; stretch < unique.length; stretch += size * 16) {
      if (signal?.aborted) return
      const window = unique.slice(stretch, stretch + size * 16)
      const encoded = window.map((chunk) => this.tokenizer.encode(chunk.text, MAX_TOKENS))
      const order = encoded.map((_, i) => i).sort((a, b) => encoded[a].length - encoded[b].length)
      for (let start = 0; start < order.length; start += size) {
        if (signal?.aborted) return
        const picked = order.slice(start, start + size)
        const vectors = await this.run(picked.map((i) => encoded[i]))
        picked.forEach((i, at) => onVector({ key: window[i].key, vector: vectors[at] }))
      }
    }
  }

  /** Padded to a bucketed length, run, and renormalised in fp32. */
  private async run(encoded: number[][]): Promise<Float32Array[]> {
    const rows = encoded.length
    const longest = Math.max(2, ...encoded.map((ids) => ids.length))
    const length = LENGTHS.find((l) => l >= longest) ?? longest
    const ids = new Int32Array(rows * length)
    const mask = new Int32Array(rows * length)
    encoded.forEach((tokens, row) => {
      ids.set(tokens, row * length)
      mask.fill(1, row * length, row * length + tokens.length)
    })
    const out = await this.model.run(ids, mask, rows, length)
    const vectors: Float32Array[] = []
    for (let row = 0; row < rows; row++) {
      const vector = out.slice(row * DIMENSION, (row + 1) * DIMENSION)
      let norm = 0
      for (let i = 0; i < DIMENSION; i++) norm += vector[i] * vector[i]
      norm = Math.sqrt(norm)
      if (norm > 0) for (let i = 0; i < DIMENSION; i++) vector[i] /= norm
      vectors.push(vector)
    }
    return vectors
  }
}
