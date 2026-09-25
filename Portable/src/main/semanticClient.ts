/**
 * The main process's handle on the semantic worker.
 *
 * Starts `semantic.js` as a utility process the first time it is asked
 * anything — never at launch — and turns its messages into promises. Ends
 * the process after ten idle minutes; the next question starts it again,
 * and the cache on disk means that costs a model load and nothing more.
 *
 * `main.ts` owns one of these: it hands over the pages the text service has,
 * fills, and answers the palette's `semantic:search`.
 */
import { utilityProcess, type UtilityProcess } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import type { SemanticPage, SemanticResult } from '../shared/semantic/semanticIndex.js'
import type { SemanticReply, SemanticRequest, SemanticStats } from './semanticWorker.js'

const IDLE_MS = 10 * 60 * 1000

export class SemanticClient {
  private child: UtilityProcess | null = null
  private token = 0
  private waiting = new Map<number, { resolve: (reply: SemanticReply) => void; reject: (error: Error) => void }>()
  private untagged: Array<{ type: SemanticReply['type']; resolve: (reply: SemanticReply) => void; reject: (error: Error) => void }> = []
  private idle: NodeJS.Timeout | null = null
  private pagesSent = false

  /**
   * `storeFile` is where the vector cache lives — beside the text index,
   * never in the library folder. `modelDirectory` is where `build.mjs` put
   * the model beside the worker; the default finds it from the archive's
   * unpacked copy.
   */
  constructor(private readonly storeFile: string, private readonly modelDirectory?: string) {}

  private process(): UtilityProcess {
    if (this.child) return this.child
    // From the copy the packager leaves outside the archive (`asarUnpack`):
    // the runtime loads its WebAssembly from a file, and a file inside the
    // archive is not one it can load.
    const script = unpacked(path.join(__dirname, 'semantic.js'))
    const child = utilityProcess.fork(script, [], { serviceName: 'Paper Time Meaning' })
    child.postMessage({
      type: 'configure',
      modelDirectory: this.modelDirectory ?? unpacked(path.join(__dirname, 'semantic')),
      storeFile: this.storeFile,
    } satisfies SemanticRequest)
    child.on('message', (reply: SemanticReply) => this.receive(reply))
    child.on('exit', () => {
      if (this.child === child) this.child = null
      this.pagesSent = false
      const gone = new Error('the semantic worker ended')
      for (const { reject } of this.waiting.values()) reject(gone)
      this.waiting.clear()
      for (const { reject } of this.untagged.splice(0)) reject(gone)
    })
    this.child = child
    return child
  }

  private receive(reply: SemanticReply) {
    this.touch()
    if (reply.type === 'progress') {
      this.onProgress?.(reply.token, reply.done, reply.total)
      return
    }
    if ('token' in reply && reply.token !== undefined) {
      const asked = this.waiting.get(reply.token)
      if (!asked) return
      this.waiting.delete(reply.token)
      if (reply.type === 'error') asked.reject(new Error(reply.message))
      else asked.resolve(reply)
      return
    }
    const at = this.untagged.findIndex((u) => u.type === reply.type || reply.type === 'error')
    if (at < 0) return
    const [asked] = this.untagged.splice(at, 1)
    if (reply.type === 'error') asked.reject(new Error(reply.message))
    else asked.resolve(reply)
  }

  /** Progress of a `fill`, as vectors arrive. */
  onProgress: ((token: number, done: number, total: number) => void) | null = null

  private touch() {
    if (this.idle) clearTimeout(this.idle)
    this.idle = setTimeout(() => this.end(), IDLE_MS)
  }

  private ask<T extends SemanticReply['type']>(request: SemanticRequest & { token: number }, type: T): Promise<Extract<SemanticReply, { type: T }>> {
    return new Promise((resolve, reject) => {
      this.waiting.set(request.token, { resolve: (reply) => resolve(reply as Extract<SemanticReply, { type: T }>), reject })
      this.process().postMessage(request)
      this.touch()
    })
  }

  private askUntagged<T extends SemanticReply['type']>(request: SemanticRequest, type: T): Promise<Extract<SemanticReply, { type: T }>> {
    return new Promise((resolve, reject) => {
      this.untagged.push({ type, resolve: (reply) => resolve(reply as Extract<SemanticReply, { type: T }>), reject })
      this.process().postMessage(request)
      this.touch()
    })
  }

  /** The pages to search; the worker says how many passages the cache lacks. */
  async setPages(pages: SemanticPage[]): Promise<{ passages: number; missing: number; papers: number }> {
    const reply = await this.askUntagged({ type: 'pages', pages }, 'pages')
    this.pagesSent = true
    return { passages: reply.passages, missing: reply.missing, papers: reply.papers }
  }

  /** Forgets papers gone for a month and drops the vectors only they had. */
  async sweep(): Promise<{ forgotten: number; dropped: number }> {
    const reply = await this.askUntagged({ type: 'sweep' }, 'swept')
    return { forgotten: reply.forgotten, dropped: reply.dropped }
  }

  /** Whether a search would answer: the pages are with the worker. */
  get hasPages(): boolean {
    return this.pagesSent
  }

  /** Embeds what the cache lacks and saves it. Returns a token `cancel` takes. */
  fill(): { token: number; done: Promise<{ embedded: number; ms: number }> } {
    const token = ++this.token
    const done = this.ask({ type: 'fill', token }, 'filled').then((r) => ({ embedded: r.embedded, ms: r.ms }))
    return { token, done }
  }

  cancel(token: number): void {
    this.child?.postMessage({ type: 'cancel', token } satisfies SemanticRequest)
  }

  async search(query: string, k = 20): Promise<{ hits: SemanticResult[]; ms: number }> {
    if (!this.pagesSent) return { hits: [], ms: 0 }
    const reply = await this.ask({ type: 'search', token: ++this.token, query, k }, 'hits')
    return { hits: reply.hits, ms: reply.ms }
  }

  async save(): Promise<number> {
    return (await this.askUntagged({ type: 'save' }, 'saved')).bytes
  }

  async stats(): Promise<SemanticStats | null> {
    if (!this.child) return null
    return (await this.askUntagged({ type: 'stats' }, 'stats')).stats
  }

  /** Ends the worker; its cache is on disk. */
  end(): void {
    if (this.idle) clearTimeout(this.idle)
    this.idle = null
    this.child?.kill()
    this.child = null
  }
}

function unpacked(file: string): string {
  const outside = file.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
  return outside !== file && fs.existsSync(outside) ? outside : file
}
