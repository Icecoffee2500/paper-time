/**
 * Reading a paper's bytes, and asking pdf.js how many pages they hold —
 * without loading a document in the process that owns the windows.
 */
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { Worker } from 'node:worker_threads'
import { diagnose, looksWhole, type ByteTrouble } from '../shared/pdfLock.js'
import type { DocumentSignals } from '../shared/metadata/signals.js'
import { textAsset } from './textAssets.js'

/**
 * The file, read until all of it is there.
 *
 * `fs.promises.readFile` resolves with a short buffer and throws nothing —
 * measured, 32 MB back from a 96 MB file with no error — and on a cloud
 * folder that is the ordinary way to meet a paper that is still coming down.
 * The Mac has `FileOperations.ensureDownloaded` for this. Node has no
 * cloud-filter API at all, and what makes Windows and Google Drive fetch a
 * placeholder is reading it, so reading again is the whole of the remedy.
 *
 * Bounded, and only for the troubles that reading again can cure. A file
 * somebody is still writing would otherwise hold this open for ever, and a
 * container or a sign-in page will read the same however many times it is
 * asked. A whole file costs one read and no wait.
 */
const READ_AGAIN: ReadonlySet<ByteTrouble> = new Set(['cut', 'placeholder', 'empty'] as ByteTrouble[])

export async function readWhole(file: string, delay = (ms: number) => new Promise((r) => setTimeout(r, ms))): Promise<Uint8Array> {
  let bytes = await fsp.readFile(file)
  for (let attempt = 1; attempt < 6; attempt += 1) {
    if (looksWhole(bytes)) return bytes
    const trouble = diagnose(bytes)
    if (!trouble || !READ_AGAIN.has(trouble)) return bytes
    await delay(250 * attempt)
    bytes = await fsp.readFile(file)
  }
  return bytes
}

/** The last `count` bytes of a file, without reading the rest of it. */
export async function tailBytes(file: string, count = 2048): Promise<Uint8Array> {
  const handle = await fsp.open(file, 'r')
  try {
    const { size } = await handle.stat()
    const length = Math.min(count, size)
    const out = new Uint8Array(length)
    await handle.read(out, 0, length, size - length)
    return out
  } finally {
    await handle.close()
  }
}

/**
 * How many pages pdf.js reads — the reader the window uses — on a thread of
 * its own. One worker, kept while jobs keep coming and let go once they
 * stop: adopting two hundred papers is two hundred counts, and starting a
 * thread with pdf.js in it for each one was most of the time.
 */
export class PageCounter {
  private worker: Worker | null = null
  private jobs = 0
  private readonly waiting = new Map<number, { resolve: (value: never) => void; reject: (e: Error) => void }>()
  private idle: NodeJS.Timeout | null = null

  constructor(private readonly script: string = workerScript(), private readonly idleMs = 30_000) {}

  count(bytes: Uint8Array): Promise<number> {
    return this.ask<number>('pages', bytes)
  }

  /** What the paper says about itself (`DocumentSignals`), read on the same
   *  thread — pdf.js, off the main process's thread. */
  signals(bytes: Uint8Array): Promise<DocumentSignals> {
    return this.ask<DocumentSignals>('signals', bytes)
  }

  private ask<T>(type: 'pages' | 'signals', bytes: Uint8Array): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const job = (this.jobs += 1)
      this.waiting.set(job, { resolve: resolve as (value: never) => void, reject })
      // A copy of its own: a Buffer's `.buffer` is Node's shared pool.
      const owned = new Uint8Array(bytes).buffer
      try {
        this.start().postMessage({ type, job, bytes: owned }, [owned])
      } catch (error) {
        this.waiting.delete(job)
        reject(error as Error)
      }
      this.touch()
    })
  }

  /** The count, or null when pdf.js could not open the bytes. */
  async countOrNull(bytes: Uint8Array): Promise<number | null> {
    try {
      return await this.count(bytes)
    } catch {
      return null
    }
  }

  private start(): Worker {
    if (this.worker) return this.worker
    const worker = new Worker(this.script)
    worker.on('message', (message: {
      type: string; job?: number; pages?: number; signals?: DocumentSignals; error?: string
      request?: number; kind?: 'cmap' | 'font'; name?: string
    }) => {
      if (message.type === 'asset') {
        // A character map or a standard font, for the signals' text.
        void textAsset(message.kind!, message.name!).then((data) => worker.postMessage({ type: 'asset', request: message.request, data }))
        return
      }
      if (message.job === undefined) return
      const asked = this.waiting.get(message.job)
      if (!asked) return
      this.waiting.delete(message.job)
      if (message.type === 'pages') asked.resolve((message.pages ?? -1) as never)
      else if (message.type === 'signals') asked.resolve(message.signals as never)
      else if (message.type === 'failed') asked.reject(new Error(`pdf.js: ${message.error ?? 'cannot open the file'}`))
    })
    const gone = (error?: Error) => {
      if (this.worker === worker) this.worker = null
      for (const asked of this.waiting.values()) asked.reject(error ?? new Error('the page counter ended'))
      this.waiting.clear()
    }
    worker.on('error', gone)
    worker.on('exit', () => gone())
    this.worker = worker
    return worker
  }

  private touch() {
    if (this.idle) clearTimeout(this.idle)
    this.idle = setTimeout(() => {
      this.idle = null
      if (this.waiting.size === 0) this.end()
    }, this.idleMs)
  }

  end() {
    if (this.idle) clearTimeout(this.idle)
    this.idle = null
    const worker = this.worker
    this.worker = null
    void worker?.terminate()
  }
}

/** The text worker's script, from outside the archive where a thread can start it. */
export function workerScript(): string {
  const script = path.join(__dirname, 'textWorker.js')
  const unpacked = script.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
  return unpacked !== script && fs.existsSync(unpacked) ? unpacked : script
}
