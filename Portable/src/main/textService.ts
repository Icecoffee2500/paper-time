/**
 * The text of the papers, kept in a process of its own.
 *
 * Reading sixty PDFs is seconds of pdf.js and a few hundred megabytes while
 * it lasts. None of that belongs in the window, which has a page to draw, and
 * none of it belongs in the main process either, which answers every request
 * the window makes: a query that waited behind a paper being parsed would be
 * a palette that stops answering the keyboard. So the index lives here, in an
 * Electron utility process that the main process starts the first time a
 * search needs it — never at launch — and that ends itself once nobody has
 * searched for a while, giving all of that memory back.
 *
 * Papers the cache does not have are read by a few threads at once
 * (`textWorker.ts`). Queries are answered here, on this thread, between them.
 */
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Worker } from 'node:worker_threads'
import { TextIndex, type ReadText, type TextHit, type TextSource } from './textIndex.js'
import { diagnose, looksWhole, type ByteTrouble } from '../shared/pdfLock.js'

/** What the main process says. */
export type ServiceRequest =
  | { type: 'configure'; directory: string; width?: number }
  | { type: 'sources'; sources: TextSource[]; roots: string[] }
  | { type: 'warm'; ids: string[] }
  | { type: 'search'; token: number; query: string; ids: string[]; titles: Record<string, string>; limit?: number }
  | { type: 'cancel'; token: number }
  | { type: 'asset'; request: number; data: Uint8Array | null }
  | { type: 'stats' }

/** What this process says back. */
export type ServiceReply =
  | { type: 'hits'; token: number; hits: TextHit[] }
  | { type: 'done'; token: number; searched: number; found: number; ms: number }
  | { type: 'warmed'; loaded: number; total: number; ms: number; removed: number }
  | { type: 'asset'; request: number; kind: 'cmap' | 'font'; name: string }
  | { type: 'stats'; stats: ServiceStats }

export interface ServiceStats {
  loaded: number
  fromCache: number
  extracted: number
  refused: number
  width: number
  warmMs: number | null
  rssMB: number
  peakRssMB: number
  /** The character maps and fonts pdf.js asked for, and how many came. */
  assets: { asked: number; found: number }
}

interface ParentPort {
  on(event: 'message', listener: (event: { data: ServiceRequest }) => void): void
  postMessage(message: ServiceReply): void
}

const port = (process as unknown as { parentPort: ParentPort }).parentPort

function post(message: ServiceReply) {
  port.postMessage(message)
}

// MARK: - The readers

/**
 * The file, read until all of it is there — `readWhole` in `main.ts`.
 *
 * `readFile` hands back a short buffer and throws nothing when a cloud file
 * is still coming down, and reading it again is what makes the drive fetch
 * it. Bounded, and only for the troubles reading again can cure.
 */
const READ_AGAIN: ReadonlySet<ByteTrouble> = new Set(['cut', 'placeholder', 'empty'] as ByteTrouble[])

async function readWhole(file: string): Promise<Uint8Array> {
  let bytes: Uint8Array = await fsp.readFile(file)
  for (let attempt = 1; attempt < 6; attempt += 1) {
    if (looksWhole(bytes)) break
    const trouble = diagnose(bytes)
    if (!trouble || !READ_AGAIN.has(trouble)) break
    await new Promise((resolve) => setTimeout(resolve, 250))
    bytes = await fsp.readFile(file)
  }
  return bytes
}

/** The files pdf.js asks for, asked of the main process once each. */
const assets = new Map<string, Promise<Uint8Array | null>>()
const assetRequests = new Map<number, (data: Uint8Array | null) => void>()
let assetCount = 0
let assetsFound = 0

function asset(kind: 'cmap' | 'font', name: string): Promise<Uint8Array | null> {
  const key = `${kind}/${name}`
  const known = assets.get(key)
  if (known) return known
  const asked = new Promise<Uint8Array | null>((resolve) => {
    const request = (assetCount += 1)
    assetRequests.set(request, resolve)
    post({ type: 'asset', request, kind, name })
  })
  assets.set(key, asked)
  return asked
}

interface Job {
  source: TextSource
  resolve: (read: ReadText) => void
  reject: (error: Error) => void
}

/**
 * A few threads reading papers, and the queue in front of them.
 *
 * Width four at most, and two fewer than the machine has cores: the window
 * and the main process need a core each, and a laptop with four is the
 * machine this must not make stutter. Measured on the Mac with PDFKit, four
 * readers took a first read of sixty papers from 15.1 s to 4.1 s. The threads
 * end a few seconds after the queue empties.
 */
class Readers {
  private readonly idle: Worker[] = []
  private readonly busy = new Map<Worker, Job>()
  private readonly queue: Job[] = []
  private jobs = 0
  private readonly pending = new Map<number, Job>()
  private stopping: ReturnType<typeof setTimeout> | null = null
  readonly width = Math.max(1, Math.min(4, (os.availableParallelism?.() ?? os.cpus().length) - 2))

  read(source: TextSource): Promise<ReadText> {
    return new Promise((resolve, reject) => {
      this.queue.push({ source, resolve, reject })
      this.pump()
    })
  }

  private pump() {
    if (this.stopping) {
      clearTimeout(this.stopping)
      this.stopping = null
    }
    while (this.queue.length > 0 && this.busy.size < this.width) {
      const job = this.queue.shift()!
      const worker = this.idle.pop() ?? this.spawn()
      this.busy.set(worker, job)
      void this.start(worker, job)
    }
    if (this.queue.length === 0 && this.busy.size === 0) {
      this.stopping = setTimeout(() => this.stop(), 5000)
    }
  }

  private async start(worker: Worker, job: Job) {
    let bytes: Uint8Array
    try {
      bytes = await readWhole(job.source.file)
    } catch (error) {
      this.finish(worker, job, error as Error)
      return
    }
    const number = (this.jobs += 1)
    this.pending.set(number, job)
    // Copied into a buffer of its own, which is then handed over rather than
    // copied again: the reader thread owns it from here.
    const owned = bytes.slice().buffer
    worker.postMessage({ type: 'extract', job: number, bytes: owned }, [owned])
  }

  private spawn(): Worker {
    // This script is itself run from outside the archive in a packaged app,
    // and the worker's script sits beside it there (`asarUnpack`).
    const worker = new Worker(path.join(__dirname, 'textWorker.js'))
    worker.on('message', (message: {
      type: string; job?: number; pages?: string[]; folded?: string[]; error?: string
      request?: number; kind?: 'cmap' | 'font'; name?: string
    }) => {
      if (message.type === 'asset') {
        void asset(message.kind!, message.name!).then((data) => {
          worker.postMessage({ type: 'asset', request: message.request, data })
        })
        return
      }
      const job = this.pending.get(message.job!)
      if (!job) return
      this.pending.delete(message.job!)
      if (message.type === 'done') {
        job.resolve({ pages: message.pages!, folded: message.folded! })
        this.finish(worker, job)
      } else {
        this.finish(worker, job, new Error(message.error ?? 'could not read'))
      }
    })
    worker.on('error', () => this.lost(worker))
    worker.on('exit', () => this.lost(worker))
    return worker
  }

  private finish(worker: Worker, job: Job, error?: Error) {
    if (error) job.reject(error)
    this.busy.delete(worker)
    this.idle.push(worker)
    this.pump()
  }

  /** A thread that died takes its job with it, and nothing else. */
  private lost(worker: Worker) {
    const job = this.busy.get(worker)
    this.busy.delete(worker)
    const at = this.idle.indexOf(worker)
    if (at >= 0) this.idle.splice(at, 1)
    if (job) {
      for (const [number, pending] of this.pending) if (pending === job) this.pending.delete(number)
      job.reject(new Error('the reader stopped'))
    }
    this.pump()
  }

  private stop() {
    this.stopping = null
    for (const worker of this.idle.splice(0)) {
      worker.removeAllListeners('exit')
      void worker.terminate()
    }
  }
}

// MARK: - The index

let index: TextIndex | null = null
const readers = new Readers()
const sources = new Map<string, TextSource>()
let roots: string[] = []
const cancelled = new Set<number>()
let warming = 0
let warmMs: number | null = null
let peakRss = 0

function watchMemory() {
  peakRss = Math.max(peakRss, process.memoryUsage().rss)
}
setInterval(watchMemory, 500).unref()

/**
 * Reads every paper it is given, the most recently opened first, so the
 * first query finds them waiting. A second warm-up stops the first.
 */
async function warm(ids: string[]) {
  if (!index) return
  const mine = (warming += 1)
  const started = performance.now()
  const list = ids.map((id) => sources.get(id)).filter((one): one is TextSource => Boolean(one))
  await index.revalidate(list)
  const queue = [...list]
  await Promise.all(Array.from({ length: readers.width }, async () => {
    while (queue.length > 0 && warming === mine) {
      await index!.load(queue.shift()!)
    }
  }))
  if (warming !== mine) return
  warmMs = performance.now() - started
  // Every paper the library has, not only the ones asked for: a paper left
  // out of this warm-up because it is an attachment is still a paper.
  const removed = await index.cleanup(new Set(sources.keys()), roots)
  watchMemory()
  post({ type: 'warmed', loaded: index.size, total: list.length, ms: warmMs, removed })
}

async function search(request: Extract<ServiceRequest, { type: 'search' }>) {
  if (!index) return post({ type: 'done', token: request.token, searched: 0, found: 0, ms: 0 })
  const started = performance.now()
  const list = request.ids
    .map((id) => {
      const known = sources.get(id)
      return known ? { ...known, title: request.titles[id] ?? known.title } : null
    })
    .filter((one): one is TextSource => one !== null)
  const result = await index.search(request.query, list, {
    limit: request.limit,
    cancelled: () => cancelled.has(request.token),
    emit: (hits) => {
      if (!cancelled.has(request.token)) post({ type: 'hits', token: request.token, hits })
    },
  })
  cancelled.delete(request.token)
  watchMemory()
  post({ type: 'done', token: request.token, ...result, ms: performance.now() - started })
}

/**
 * Nobody has searched for ten minutes: the text goes, and the memory with
 * it. The cache stays on disk, so coming back costs a read of it, not of the
 * papers.
 */
let idle: ReturnType<typeof setTimeout> | null = null

function stillWanted() {
  if (idle) clearTimeout(idle)
  idle = setTimeout(() => process.exit(0), 10 * 60 * 1000)
}

port.on('message', ({ data: request }) => {
  stillWanted()
  switch (request.type) {
    case 'configure':
      index = new TextIndex({
        directory: request.directory,
        extract: (source) => readers.read(source),
        ahead: readers.width,
      })
      break
    case 'sources':
      sources.clear()
      for (const source of request.sources) sources.set(source.id, source)
      roots = request.roots
      break
    case 'warm':
      void warm(request.ids)
      break
    case 'search':
      void search(request)
      break
    case 'cancel':
      cancelled.add(request.token)
      break
    case 'asset':
      if (request.data) assetsFound += 1
      assetRequests.get(request.request)?.(request.data)
      assetRequests.delete(request.request)
      break
    case 'stats':
      watchMemory()
      post({
        type: 'stats',
        stats: {
          loaded: index?.size ?? 0,
          fromCache: index?.counts.fromCache ?? 0,
          extracted: index?.counts.extracted ?? 0,
          refused: index?.counts.refused ?? 0,
          width: readers.width,
          warmMs,
          rssMB: Math.round(process.memoryUsage().rss / 1e6),
          peakRssMB: Math.round(peakRss / 1e6),
          assets: { asked: assets.size, found: assetsFound },
        },
      })
      break
  }
})

stillWanted()
