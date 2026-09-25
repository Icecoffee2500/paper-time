/**
 * The model, loaded from files on disk into ONNX Runtime's WebAssembly build.
 *
 * WebAssembly rather than the native `onnxruntime-node`. Measured on the
 * same fp16-stored model (M1 Pro, 16 passages of 128 tokens a call): native
 * 9.3 ms a passage and 2.7 ms a query, WebAssembly on four threads 26 ms and
 * 4.8 ms. Native is faster, and it is also a native binary for each of
 * Windows and Linux on x64 and arm64, unpacked from the archive and shipped
 * from one Mac that can run none of them. The WebAssembly build is one file
 * that runs wherever Chromium does, and a library of 60 papers (about
 * 13,000 passages) embeds once, in a process of its own, in a few minutes;
 * a query answers in a frame. When a Windows machine can check a native
 * build, `loadModel` is the one place to swap.
 *
 * The runtime asks for its glue module by URL and its binary by bytes, and
 * both are given here from the folder `build.mjs` lays out beside the
 * worker — never fetched. The model's weights are stored in fp16 and cast
 * to fp32 as the session is made (`Scripts/semantic-onnx.py`), so the
 * arithmetic is fp32 and the mask needs no special value: the WebAssembly
 * build has few fp16 kernels and the −10000 trick the Core ML conversion
 * needs does not arise.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
// Under `platform: 'node'` the package's `node` export condition resolves
// this to its Node flavour (`ort.node.min.js`): the same WebAssembly, loaded
// from disk instead of a script tag.
import * as ort from 'onnxruntime-web'
import { DIMENSION, MODEL_FILE, VOCAB_FILE } from '../shared/semantic/model.js'
import { SemanticEmbedder, type SentenceModel } from '../shared/semantic/embedder.js'
import { WordPiece } from '../shared/semantic/wordpiece.js'

export interface ModelFiles {
  /** Where `MODEL_FILE`, `VOCAB_FILE` and the runtime's two files are. */
  directory: string
  /** Threads for the runtime; default: a few, never all of them. */
  threads?: number
}

const GLUE = 'ort-wasm-simd-threaded.mjs'
const BINARY = 'ort-wasm-simd-threaded.wasm'

let configured = false

function configure(directory: string, threads: number) {
  if (configured) return
  configured = true
  ort.env.wasm.numThreads = threads
  ort.env.wasm.wasmPaths = { mjs: pathToFileURL(path.join(directory, GLUE)).href }
  ort.env.wasm.wasmBinary = fs.readFileSync(path.join(directory, BINARY))
  // Nothing here needs a proxy worker; the caller is already off the window.
  ort.env.wasm.proxy = false
}

export function defaultThreads(): number {
  return Math.max(1, Math.min(4, os.cpus().length - 1))
}

/** The graph as a `SentenceModel`. Takes a few hundred milliseconds. */
export async function loadModel(files: ModelFiles): Promise<SentenceModel> {
  configure(files.directory, files.threads ?? defaultThreads())
  const bytes = fs.readFileSync(path.join(files.directory, MODEL_FILE))
  const session = await ort.InferenceSession.create(bytes, {
    executionProviders: ['wasm'],
    graphOptimizationLevel: 'all',
  })
  return {
    async run(ids, mask, rows, length) {
      const shape = [rows, length]
      const feeds = {
        input_ids: new ort.Tensor('int64', BigInt64Array.from(ids, BigInt), shape),
        attention_mask: new ort.Tensor('int64', BigInt64Array.from(mask, BigInt), shape),
      }
      const out = await session.run(feeds)
      const data = out.embedding.data as Float32Array
      if (data.length !== rows * DIMENSION) throw new Error(`the model answered ${data.length} numbers for ${rows} rows`)
      return data
    },
    async close() {
      await session.release()
    },
  }
}

/** The tokenizer and the model, from one folder. */
export async function loadEmbedder(files: ModelFiles): Promise<SemanticEmbedder> {
  const vocabulary = fs.readFileSync(path.join(files.directory, VOCAB_FILE), 'utf8')
  const model = await loadModel(files)
  return new SemanticEmbedder(new WordPiece(vocabulary), model)
}
