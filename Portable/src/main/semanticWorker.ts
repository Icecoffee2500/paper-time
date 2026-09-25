/**
 * Search by meaning, in a process of its own — `out/main/semantic.js`.
 *
 * The model is 43 MB of weights and a WebAssembly runtime on a few threads,
 * and embedding a library is seconds of arithmetic. None of that belongs in
 * the window, which has a page to draw, and none of it belongs in the main
 * process, which answers every request the window makes. So it lives here,
 * in an Electron utility process the main process starts the first time a
 * search by meaning needs it (`semanticClient.ts`), and that ends itself
 * once nobody has asked for a while, giving the memory back.
 *
 * Nothing here knows about papers: the main process sends pages of text, and
 * this cuts them, embeds what the cache lacks, saves the cache beside the
 * text index, and answers queries with places on pages.
 */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { SemanticIndex, type SemanticPage, type SemanticResult } from '../shared/semantic/semanticIndex.js'
import { SemanticVectorStore } from '../shared/semantic/vectorStore.js'
import { MODEL_ID } from '../shared/semantic/model.js'
import type { SemanticEmbedder } from '../shared/semantic/embedder.js'
import { loadEmbedder } from './semanticModel.js'

/** What the main process says. */
export type SemanticRequest =
  | { type: 'configure'; modelDirectory: string; storeFile: string; threads?: number }
  | { type: 'pages'; pages: SemanticPage[] }
  | { type: 'fill'; token: number }
  | { type: 'cancel'; token: number }
  | { type: 'search'; token: number; query: string; k: number }
  | { type: 'save' }
  | { type: 'stats' }

/** What this process says back. */
export type SemanticReply =
  | { type: 'pages'; passages: number; missing: number }
  | { type: 'progress'; token: number; done: number; total: number }
  | { type: 'filled'; token: number; embedded: number; ms: number }
  | { type: 'hits'; token: number; hits: SemanticResult[]; ms: number }
  | { type: 'saved'; bytes: number }
  | { type: 'stats'; stats: SemanticStats }
  | { type: 'error'; token?: number; message: string }

export interface SemanticStats {
  model: string
  loaded: boolean
  loadMs: number | null
  passages: number
  vectors: number
  rssMB: number
}

interface ParentPort {
  on(event: 'message', listener: (event: { data: SemanticRequest }) => void): void
  postMessage(message: SemanticReply): void
}

const port = (process as unknown as { parentPort: ParentPort }).parentPort

function post(message: SemanticReply) {
  port.postMessage(message)
}

let modelDirectory = ''
let storeFile = ''
let threads: number | undefined
let index: SemanticIndex | null = null
let embedder: Promise<SemanticEmbedder> | null = null
let loadMs: number | null = null
const fills = new Map<number, AbortController>()

async function model(): Promise<SemanticEmbedder> {
  if (!embedder) {
    const t0 = performance.now()
    embedder = loadEmbedder({ directory: modelDirectory, threads }).then((loaded) => {
      loadMs = performance.now() - t0
      return loaded
    })
    embedder.catch(() => { embedder = null })
  }
  return embedder
}

function openIndex(): SemanticIndex {
  if (index) return index
  let store = new SemanticVectorStore(MODEL_ID)
  // A cache that cannot be read is rebuilt, and nobody needs to hear about it.
  try {
    if (fs.existsSync(storeFile)) store = SemanticVectorStore.decode(new Uint8Array(fs.readFileSync(storeFile)), MODEL_ID)
  } catch {
    store = new SemanticVectorStore(MODEL_ID)
  }
  index = new SemanticIndex(store)
  return index
}

/** Writes the cache whole and renames it into place: a crash halfway leaves the old cache. */
async function save(): Promise<number> {
  const current = openIndex()
  if (!current.changed) return 0
  const bytes = current.store.encoded()
  await fsp.mkdir(path.dirname(storeFile), { recursive: true })
  const part = `${storeFile}.part`
  await fsp.writeFile(part, bytes)
  await fsp.rename(part, storeFile)
  current.saved()
  return bytes.length
}

port.on('message', ({ data }) => {
  void handle(data).catch((error: unknown) => {
    const token = 'token' in data ? data.token : undefined
    post({ type: 'error', token, message: String((error as Error).message ?? error) })
  })
})

async function handle(request: SemanticRequest) {
  switch (request.type) {
    case 'configure':
      modelDirectory = request.modelDirectory
      storeFile = request.storeFile
      threads = request.threads
      break
    case 'pages': {
      const missing = openIndex().setPages(request.pages)
      post({ type: 'pages', passages: openIndex().passageCount, missing: missing.length })
      break
    }
    case 'fill': {
      const controller = new AbortController()
      fills.set(request.token, controller)
      const t0 = performance.now()
      try {
        const current = openIndex()
        const embedded = await current.fill(await model(), (done, total) => {
          if (done % 16 === 0 || done === total) post({ type: 'progress', token: request.token, done, total })
        }, controller.signal)
        current.prune()
        await save()
        post({ type: 'filled', token: request.token, embedded, ms: performance.now() - t0 })
      } finally {
        fills.delete(request.token)
      }
      break
    }
    case 'cancel':
      fills.get(request.token)?.abort()
      break
    case 'search': {
      const t0 = performance.now()
      const vector = await (await model()).embedQuery(request.query)
      const hits = openIndex().search(vector, request.k)
      post({ type: 'hits', token: request.token, hits, ms: performance.now() - t0 })
      break
    }
    case 'save':
      post({ type: 'saved', bytes: await save() })
      break
    case 'stats':
      post({
        type: 'stats',
        stats: {
          model: MODEL_ID,
          loaded: loadMs !== null,
          loadMs,
          passages: index?.passageCount ?? 0,
          vectors: index?.store.count ?? 0,
          rssMB: Math.round(process.memoryUsage().rss / 1048576),
        },
      })
      break
  }
}
