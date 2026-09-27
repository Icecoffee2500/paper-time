/**
 * The words inside the papers, read in a process of their own.
 *
 * The text service is started the first time a search needs it — never at
 * launch: most sessions never search the text at all — and ends itself
 * once nobody has asked for ten minutes. This is the main process's end of
 * it: which window asked for which search, so its answers go back to it;
 * the pages search by meaning asks for; the assets pdf.js asks for.
 */
import { textAsset } from './textAssets.js'
import { utilityProcess, type UtilityProcess, type WebContents } from 'electron'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { CHANNEL } from '../shared/api.js'
import type { ServiceReply, ServiceStats } from './textService.js'
import type { TextSource } from './textIndex.js'

export interface Texts {
  papers: { id: string; pages: string[] }[]
  unread: string[]
  ms: number
}

export interface TextBridgeHooks {
  directory: () => string
  sources: () => TextSource[]
  roots: () => string[]
  send: (event: string, payload?: unknown) => void
  /** The pages are in hand: search by meaning catches up shortly. */
  onWarmed: () => void
}

export class TextBridge {
  private service: UtilityProcess | null = null
  private sourcesSent = false
  /** Every window numbers its own searches from one, so the service is given
   *  numbers of this process's own and each is mapped back on the way out. */
  private readonly searches = new Map<number, { target: WebContents; token: number }>()
  private readonly tokens = new Map<string, number>()
  private tokenCount = 0
  private readonly statsWaiting: ((stats: ServiceStats | null) => void)[] = []
  private readonly textsWaiting = new Map<number, { resolve: (texts: Texts) => void; reject: (error: Error) => void }>()
  private textsCount = 0

  constructor(private readonly hooks: TextBridgeHooks) {}

  /** The list of papers changed: the service is told before its next errand. */
  sourcesChanged() {
    this.sourcesSent = false
  }

  /** Stops a warm-up the palette asked for, when the palette goes. */
  stopWarming() {
    this.withSources().postMessage({ type: 'warm-cancel' })
  }

  warm(ids: string[]) {
    this.withSources().postMessage({ type: 'warm', ids })
  }

  search(sender: WebContents, token: number, query: string, ids: string[], titles: Record<string, string>, limit?: number) {
    const global = (this.tokenCount += 1)
    this.searches.set(global, { target: sender, token })
    this.tokens.set(`${sender.id}:${token}`, global)
    this.withSources().postMessage({ type: 'search', token: global, query, ids, titles, limit })
  }

  cancel(sender: WebContents, token: number) {
    const key = `${sender.id}:${token}`
    const global = this.tokens.get(key)
    if (global === undefined) return
    // Both ends let go: a cancelled search never says `done`.
    this.tokens.delete(key)
    this.searches.delete(global)
    this.service?.postMessage({ type: 'cancel', token: global })
  }

  /** A window closed: its searches are nobody's now. */
  forgetWindow(contents: WebContents) {
    for (const [global, asked] of this.searches) {
      if (asked.target !== contents) continue
      this.searches.delete(global)
      this.tokens.delete(`${contents.id}:${asked.token}`)
      this.service?.postMessage({ type: 'cancel', token: global })
    }
  }

  /** For a probe: what the service has read, and what it cost. */
  stats(): Promise<ServiceStats | null> {
    return new Promise((resolve) => {
      if (!this.service) return resolve(null)
      this.statsWaiting.push(resolve)
      this.service.postMessage({ type: 'stats' })
    })
  }

  /** The pages of these papers, for search by meaning. */
  texts(ids: string[]): Promise<Texts> {
    return new Promise((resolve, reject) => {
      const token = (this.textsCount += 1)
      this.textsWaiting.set(token, { resolve, reject })
      this.withSources().postMessage({ type: 'texts', token, ids })
    })
  }

  end() {
    this.service?.kill()
  }

  private withSources(): UtilityProcess {
    const service = this.start()
    if (!this.sourcesSent) {
      service.postMessage({ type: 'sources', sources: this.hooks.sources(), roots: this.hooks.roots() })
      this.sourcesSent = true
    }
    return service
  }

  private start(): UtilityProcess {
    if (this.service) return this.service
    // From the copy the packager leaves outside the archive (see `asarUnpack`
    // in electron-builder.yml): the service starts threads from a file, and a
    // file inside the archive is not one a thread can be started from.
    const script = path.join(__dirname, 'textService.js')
    const unpacked = script.replace(/app\.asar(?=[\\/])/, 'app.asar.unpacked')
    const child = utilityProcess.fork(unpacked !== script && fs.existsSync(unpacked) ? unpacked : script, [], {
      serviceName: 'Paper Time Text',
    })
    child.postMessage({ type: 'configure', directory: this.hooks.directory() })
    this.sourcesSent = false
    child.on('message', (message: ServiceReply) => {
      switch (message.type) {
        case 'hits':
        case 'done': {
          const asked = this.searches.get(message.token)
          if (!asked) break
          if (message.type === 'done') {
            this.searches.delete(message.token)
            this.tokens.delete(`${asked.target.id}:${asked.token}`)
          }
          if (!asked.target.isDestroyed()) {
            asked.target.send(CHANNEL.event, `text:${message.type}`, { ...message, token: asked.token })
          }
          break
        }
        case 'warmed':
          this.hooks.send('text:warmed', message)
          this.hooks.onWarmed()
          break
        case 'texts': {
          const asked = this.textsWaiting.get(message.token)
          if (!asked) break
          this.textsWaiting.delete(message.token)
          asked.resolve({ papers: message.papers, unread: message.unread, ms: message.ms })
          break
        }
        case 'asset':
          void textAsset(message.kind, message.name).then((data) => {
            child.postMessage({ type: 'asset', request: message.request, data })
          })
          break
        case 'stats':
          for (const waiting of this.statsWaiting.splice(0)) waiting(message.stats)
          break
      }
    })
    child.on('exit', () => {
      if (this.service === child) this.service = null
      // Searches in flight end with the process, and the window is told so
      // rather than left waiting for answers that will not come.
      for (const { target, token } of this.searches.values()) {
        if (!target.isDestroyed()) target.send(CHANNEL.event, 'text:done', { token, searched: 0, found: 0, ms: 0 })
      }
      this.searches.clear()
      this.tokens.clear()
      for (const waiting of this.statsWaiting.splice(0)) waiting(null)
      for (const waiting of this.textsWaiting.values()) waiting.reject(new Error('the text service ended'))
      this.textsWaiting.clear()
    })
    this.service = child
    return child
  }
}

