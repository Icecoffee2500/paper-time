/**
 * One reader of papers, on a thread of its own.
 *
 * The text service keeps a few of these so a library read for the first time
 * is read several papers at once: pdf.js is one thread's work per document,
 * and a machine with eight cores was reading sixty papers one after another.
 * Each takes a paper's bytes, gives back its pages and the same pages folded,
 * and holds nothing afterwards — one document at a time, destroyed when done.
 *
 * It opens no files. The bytes arrive with the job, and what pdf.js asks for
 * along the way (a character map, a standard font) is asked of the service,
 * which asks the process that can read inside the app's archive.
 */
import { parentPort } from 'node:worker_threads'
import { extractPages } from './textExtract.js'
import { foldText } from '../shared/textFold.js'

type Incoming =
  | { type: 'extract'; job: number; bytes: ArrayBuffer }
  | { type: 'asset'; request: number; data: Uint8Array | null }

const port = parentPort!
const waiting = new Map<number, (data: Uint8Array | null) => void>()
let requests = 0

function asset(kind: 'cmap' | 'font', name: string): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const request = (requests += 1)
    waiting.set(request, (data) => (data ? resolve(data) : reject(new Error(`no ${kind} ${name}`))))
    port.postMessage({ type: 'asset', request, kind, name })
  })
}

port.on('message', (message: Incoming) => {
  if (message.type === 'asset') {
    waiting.get(message.request)?.(message.data)
    waiting.delete(message.request)
    return
  }
  void (async () => {
    try {
      const pages = await extractPages(new Uint8Array(message.bytes), {
        cmap: (name) => asset('cmap', name),
        font: (name) => asset('font', name),
      })
      port.postMessage({ type: 'done', job: message.job, pages, folded: pages.map(foldText) })
    } catch (error) {
      port.postMessage({ type: 'failed', job: message.job, error: String((error as Error)?.message ?? error) })
    }
  })()
})
