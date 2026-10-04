/**
 * Reading a formula off a picture, in a process of its own — `out/main/ocr.js`.
 *
 * The formula lasso's last resort, as on the Mac (`FormulaOCR`): when the
 * rectangle holds no glyphs the reader can use — a scanned page, a formula
 * pasted in as an image, a Word equation in a font with no meanings — the
 * window draws that rectangle of the page and sends the picture here. The
 * model is pix2text's math formula recogniser 1.5 (MIT): a DeiT encoder over
 * a 384×384 picture and a small TrOCR decoder, as ONNX, int8 — the same two
 * files the Mac carries in `App/Resources/MathOCR`, run by onnxruntime-web's
 * Node flavour on WebAssembly threads. One formula is a second or two: the
 * decoder has no cache and re-reads the whole sequence each step.
 *
 * Thirty megabytes of weights and a WebAssembly runtime do not belong in
 * the window, which has a page to draw, nor in the main process, which
 * answers every request the window makes. So they live here, started the
 * first time a formula needs reading and kept for the app's life
 * (`ocrClient.ts`).
 *
 * What comes back is the model's tokens with spaces between, tidied by
 * `shared/formulaOCRText.ts` into Ultracopy's LaTeX.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
// Under `platform: 'node'` the package's `node` export condition resolves
// this to its Node flavour: the same WebAssembly, loaded from disk.
import * as ort from 'onnxruntime-web'
import { tidy } from '../shared/formulaOCRText.js'
import { OCR_SHAPE, OCR_SIDE } from '../shared/formulaOCRInput.js'

/** What the main process says. */
export type OCRRequest =
  | { type: 'configure'; modelDirectory: string; runtimeDirectory: string; threads?: number }
  | { type: 'read'; token: number; pixels: Float32Array }
  | { type: 'stats' }

/** What this process says back. */
export type OCRReply =
  | { type: 'read'; token: number; reading: OCRReading | null }
  | { type: 'stats'; stats: OCRStats }
  | { type: 'error'; token?: number; message: string }

export interface OCRReading {
  /** The formula, wrapped as Ultracopy wraps a displayed one. */
  latex: string
  /** How many ids the decoder produced, the start and the end included. */
  tokens: number
  seconds: number
}

export interface OCRStats {
  loaded: boolean
  loadMs: number | null
  readings: number
  rssMB: number
}

interface ParentPort {
  on(event: 'message', listener: (event: { data: OCRRequest }) => void): void
  postMessage(message: OCRReply): void
}

const port = (process as unknown as { parentPort: ParentPort }).parentPort

function post(message: OCRReply) {
  port.postMessage(message)
}

const ENCODER = 'encoder_model.onnx'
const DECODER = 'decoder_model.onnx'
const VOCABULARY = 'tokenizer.json'
const GLUE = 'ort-wasm-simd-threaded.mjs'
const BINARY = 'ort-wasm-simd-threaded.wasm'

const VOCABULARY_SIZE = 1868
const START = 1n
const END = 2n
const LONGEST = 400

let modelDirectory = ''
let runtimeDirectory = ''
let threads: number | undefined
let loading: Promise<Model> | null = null
let loadMs: number | null = null
let readings = 0

interface Model {
  encoder: ort.InferenceSession
  decoder: ort.InferenceSession
  tokenizer: Tokenizer
}

/**
 * More threads than the semantic worker takes: somebody is waiting for this
 * one. Measured (M-series Mac, int8 decoder at 180 ids): 147 ms a step on
 * one thread, 41 ms on four, 32 ms on eight — a formula of 186 ids is six
 * seconds on four threads, five on eight.
 */
function defaultThreads(): number {
  return Math.max(1, Math.min(8, os.cpus().length - 1))
}

/** The two graphs and the vocabulary, once; kept for the app's life. */
function model(): Promise<Model> {
  if (loading) return loading
  const t0 = performance.now()
  loading = (async () => {
    ort.env.wasm.numThreads = threads ?? defaultThreads()
    ort.env.wasm.wasmPaths = { mjs: pathToFileURL(path.join(runtimeDirectory, GLUE)).href }
    ort.env.wasm.wasmBinary = fs.readFileSync(path.join(runtimeDirectory, BINARY))
    // Nothing here needs a proxy worker; the caller is already off the window.
    ort.env.wasm.proxy = false
    const options: ort.InferenceSession.SessionOptions = { executionProviders: ['wasm'], graphOptimizationLevel: 'all' }
    const encoder = await ort.InferenceSession.create(fs.readFileSync(path.join(modelDirectory, ENCODER)), options)
    const decoder = await ort.InferenceSession.create(fs.readFileSync(path.join(modelDirectory, DECODER)), options)
    const tokenizer = new Tokenizer(fs.readFileSync(path.join(modelDirectory, VOCABULARY), 'utf8'))
    loadMs = performance.now() - t0
    return { encoder, decoder, tokenizer }
  })()
  loading.catch(() => { loading = null })
  return loading
}

/**
 * The picture read: encoded once, decoded greedily one id a step with the
 * whole sequence fed each time, until the end id or four hundred steps.
 * Null when the tokens tidy to nothing.
 */
async function read(pixels: Float32Array): Promise<OCRReading | null> {
  const { encoder, decoder, tokenizer } = await model()
  if (pixels.length !== 3 * OCR_SIDE * OCR_SIDE) throw new Error(`the picture has ${pixels.length} values, not ${3 * OCR_SIDE * OCR_SIDE}`)
  const began = performance.now()
  const encoded = await encoder.run({ pixel_values: new ort.Tensor('float32', pixels, [...OCR_SHAPE]) })
  const hidden = encoded.last_hidden_state
  if (!hidden) throw new Error('the encoder answered with no hidden state')

  const ids: bigint[] = [START]
  for (let step = 0; step < LONGEST; step += 1) {
    const out = await decoder.run({
      input_ids: new ort.Tensor('int64', BigInt64Array.from(ids), [1, ids.length]),
      encoder_hidden_states: hidden,
    })
    const logits = out.logits?.data as Float32Array | undefined
    if (!logits) throw new Error('the decoder answered with no logits')
    const last = logits.length - VOCABULARY_SIZE
    let best = 0
    let bestValue = -Infinity
    for (let k = 0; k < VOCABULARY_SIZE; k += 1) {
      if (logits[last + k] > bestValue) {
        bestValue = logits[last + k]
        best = k
      }
    }
    ids.push(BigInt(best))
    if (BigInt(best) === END) break
  }
  readings += 1
  const raw = tokenizer.decode(ids.map(Number))
  const tidied = tidy(raw)
  if (tidied.body.length === 0) return null
  const latex = tidied.tag !== null
    ? `\\begin{equation} ${tidied.body}\\tag{${tidied.tag}} \\end{equation}`
    : `$$${tidied.body}$$`
  return { latex, tokens: ids.length, seconds: (performance.now() - began) / 1000 }
}

/**
 * Hugging Face's `tokenizer.json`, decoded the byte-level way: a token is
 * GPT-2's unicode spelling of bytes, so the vocabulary's characters go back
 * to bytes before they are read as UTF-8. A plain join of the vocabulary's
 * strings would be wrong — `Ġ` is a space, `Ã©` is «é».
 */
export class Tokenizer {
  private readonly tokens = new Map<number, string>()
  private readonly special = new Set<number>()
  private readonly byteOf = new Map<string, number>()

  constructor(json: string) {
    const parsed = JSON.parse(json) as {
      model?: { vocab?: Record<string, number> }
      added_tokens?: { id?: number; content?: string; special?: boolean }[]
    }
    const vocabulary = parsed.model?.vocab
    if (!vocabulary) throw new Error('tokenizer.json has no vocabulary')
    for (const [token, id] of Object.entries(vocabulary)) this.tokens.set(id, token)
    for (const added of parsed.added_tokens ?? []) {
      if (typeof added.id !== 'number') continue
      if (typeof added.content === 'string') this.tokens.set(added.id, added.content)
      if (added.special === true) this.special.add(added.id)
    }
    // GPT-2's bytes_to_unicode, inverted.
    const bytes: number[] = []
    for (let b = 33; b <= 126; b += 1) bytes.push(b)
    for (let b = 161; b <= 172; b += 1) bytes.push(b)
    for (let b = 174; b <= 255; b += 1) bytes.push(b)
    const characters = [...bytes]
    let next = 0
    for (let b = 0; b < 256; b += 1) {
      if (bytes.includes(b)) continue
      bytes.push(b)
      characters.push(256 + next)
      next += 1
    }
    bytes.forEach((byte, at) => this.byteOf.set(String.fromCodePoint(characters[at]), byte))
  }

  decode(ids: number[]): string {
    const bytes: number[] = []
    for (const id of ids) {
      if (this.special.has(id)) continue
      const token = this.tokens.get(id)
      if (token === undefined) continue
      for (const character of token) {
        const byte = this.byteOf.get(character)
        if (byte !== undefined) bytes.push(byte)
      }
    }
    return new TextDecoder('utf-8').decode(Uint8Array.from(bytes))
  }
}

port.on('message', ({ data }) => {
  void handle(data).catch((error: unknown) => {
    const token = 'token' in data ? data.token : undefined
    post({ type: 'error', token, message: String((error as Error).message ?? error) })
  })
})

async function handle(request: OCRRequest) {
  switch (request.type) {
    case 'configure':
      modelDirectory = request.modelDirectory
      runtimeDirectory = request.runtimeDirectory
      threads = request.threads
      break
    case 'read': {
      // Across the port a typed array may arrive as a plain buffer view.
      const pixels = request.pixels instanceof Float32Array ? request.pixels : new Float32Array(request.pixels as ArrayLike<number>)
      post({ type: 'read', token: request.token, reading: await read(pixels) })
      break
    }
    case 'stats':
      post({ type: 'stats', stats: { loaded: loadMs !== null, loadMs, readings, rssMB: Math.round(process.memoryUsage().rss / 1048576) } })
      break
  }
}
