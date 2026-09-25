/**
 * The words inside the papers, so search can find a sentence and not only a
 * title — the port of the Mac's `PaperTextIndex`.
 *
 * You remember that somebody defined the thing, not who, and the title you
 * are offered does not contain the word you are thinking of — the fourth page
 * does. This keeps the text of every paper so the word can be found in it,
 * and keeps enough of where it was found to walk back to it: the page, and
 * the range of characters on that page, which is all the reader needs to put
 * the line on screen.
 *
 * The text is read once and kept in a cache folder of the app's own, because
 * reading it is most of the cost and the answer never changes while the file
 * does not. Nothing here belongs in the library folder: it is derived, it is
 * rebuildable, and a folder people sync should hold what they wrote, not what
 * we worked out. The folded text is kept beside the pages as well — folding
 * is a second pass over every character, and doing it again every session
 * made the first query of each session the slow one (on the Mac, 2.39 s for
 * sixty papers).
 *
 * Plain Node and nothing else, so the whole of it runs in a test.
 */
import fsp from 'node:fs/promises'
import path from 'node:path'
import { foldText, foldVersion, foldWithMap, snippetAround } from '../shared/textFold.js'

/** A paper as the index needs it: something to read, and something to call
 *  it in a result. */
export interface TextSource {
  id: string
  file: string
  title: string
}

/** Where a word was found, in the coordinates the reader can act on. */
export interface Passage {
  paperID: string
  pageIndex: number
  /** Into the page's text, which is the text layer's runs end to end. */
  location: number
  length: number
}

/** One paper's answer to a query: where the first match is, what it says,
 *  and how many more there are. */
export interface TextHit {
  passage: Passage
  title: string
  /** The sentence around the match, whitespace tidied. */
  snippet: string
  count: number
}

/** What reading a paper gives: its pages, and the same pages folded. */
export interface ReadText {
  pages: string[]
  folded: string[]
}

export type Extractor = (source: TextSource) => Promise<ReadText>

interface PaperText extends ReadText {
  file: string
  size: number
  mtimeMs: number
}

interface Stamp {
  size: number
  mtimeMs: number
}

/** Bumped when the file's shape changes. */
const CACHE_VERSION = 1

/**
 * The same file, as far as a stat can say. A second of slack on the time, as
 * the Mac has it: a cloud drive and a FAT stick both round it.
 */
function sameStamp(a: Stamp, b: Stamp): boolean {
  return a.size === b.size && Math.abs(a.mtimeMs - b.mtimeMs) < 1000
}

async function stampOf(file: string): Promise<Stamp | null> {
  try {
    const stat = await fsp.stat(file)
    return { size: stat.size, mtimeMs: stat.mtimeMs }
  } catch {
    return null
  }
}

export class TextIndex {
  private readonly memory = new Map<string, PaperText>()
  private readonly loading = new Map<string, Promise<PaperText | null>>()
  /**
   * Papers that would not be read this session, by the file and stamp they
   * had. Not written down: a paper the cloud has not brought down yet is a
   * paper that will read fine in a minute. But not tried again on every
   * keystroke either — only once the file has changed.
   */
  private readonly refused = new Map<string, string>()
  readonly counts = { fromCache: 0, extracted: 0, refused: 0 }

  constructor(private readonly options: {
    directory: string
    extract: Extractor
    /** How many papers may be read at once; the reader queues the rest. */
    ahead?: number
  }) {}

  get directory(): string {
    return this.options.directory
  }

  /** How many papers' text is in hand right now. */
  get size(): number {
    return this.memory.size
  }

  isLoaded(source: TextSource): boolean {
    return this.memory.get(source.id)?.file === source.file
  }

  /** The paper's text: from memory, from the cache, or read from the file. */
  load(source: TextSource): Promise<PaperText | null> {
    const known = this.memory.get(source.id)
    if (known && known.file === source.file) return Promise.resolve(known)
    const pending = this.loading.get(source.id)
    if (pending) return pending
    const work = this.read(source).finally(() => this.loading.delete(source.id))
    this.loading.set(source.id, work)
    return work
  }

  private async read(source: TextSource): Promise<PaperText | null> {
    const stamp = await stampOf(source.file)
    if (!stamp) return null
    const cached = await this.readCache(source, stamp)
    if (cached) {
      this.memory.set(source.id, cached)
      this.counts.fromCache += 1
      return cached
    }
    const key = `${source.file}\u0000${stamp.size}\u0000${stamp.mtimeMs}`
    if (this.refused.get(source.id) === key) return null
    let read: ReadText
    try {
      read = await this.options.extract(source)
    } catch {
      this.refused.set(source.id, key)
      this.counts.refused += 1
      return null
    }
    const entry: PaperText = { file: source.file, size: stamp.size, mtimeMs: stamp.mtimeMs, ...read }
    this.memory.set(source.id, entry)
    this.counts.extracted += 1
    // Written down only if the file is still the one that was read: a paper
    // saved while it was being read would otherwise be remembered with the
    // words of the version before.
    const after = await stampOf(source.file)
    if (after && sameStamp(after, stamp)) await this.writeCache(source.id, entry)
    return entry
  }

  /**
   * Drops what is in memory for papers whose file has changed since it was
   * read, so the next search reads them again. One stat each, all at once —
   * on a cloud drive a stat is a round trip, and sixty in a row is a second.
   */
  async revalidate(sources: TextSource[]): Promise<number> {
    const checks = sources
      .filter((source) => this.memory.has(source.id))
      .map(async (source) => {
        const known = this.memory.get(source.id)!
        const stamp = await stampOf(source.file)
        if (known.file === source.file && stamp && sameStamp(stamp, known)) return 0
        this.memory.delete(source.id)
        return 1
      })
    return (await Promise.all(checks)).reduce<number>((sum, one) => sum + one, 0)
  }

  // MARK: - Searching

  /**
   * One paper's answer to a folded query, as `PaperTextIndex.hit` has it: the
   * number of matches, and where the first one sits in the page as written.
   */
  hit(needle: string, source: TextSource, text: ReadText): TextHit | null {
    if (needle.length <= 1) return null
    let count = 0
    let firstPage = -1
    let firstAt = -1
    for (let index = 0; index < text.folded.length; index += 1) {
      const page = text.folded[index]
      let from = 0
      for (;;) {
        const at = page.indexOf(needle, from)
        if (at < 0) break
        count += 1
        if (firstPage < 0) {
          firstPage = index
          firstAt = at
        }
        from = at + Math.max(needle.length, 1)
      }
    }
    if (firstPage < 0) return null

    // Back to the characters on the page, folding only as far as the match:
    // the rest of the page cannot change where it began.
    const original = text.pages[firstPage]
    const end = firstAt + needle.length
    const mapped = foldWithMap(original, end)
    const start = firstAt < mapped.map.length ? mapped.map[firstAt] : 0
    const stop = end < mapped.map.length ? mapped.map[end] : original.length
    const location = start
    const length = Math.max(stop - start, 1)
    return {
      passage: { paperID: source.id, pageIndex: firstPage, location, length },
      title: source.title,
      snippet: snippetAround(original, location, length),
      count,
    }
  }

  /**
   * Every paper that holds the query, in the order given, as they are read.
   *
   * In order rather than as they finish: the order is by when each paper was
   * last opened, and the answer somebody wants is nearly always in the paper
   * they had open last. The next few are read while one is being searched,
   * so a library read for the first time is read `ahead` at a time.
   *
   * Hits go out in batches — whatever was found since the last wait, or the
   * last sixteen milliseconds — because a list that takes them one at a time
   * redraws itself once per paper.
   */
  async search(query: string, sources: TextSource[], options: {
    limit?: number
    cancelled: () => boolean
    emit: (hits: TextHit[]) => void
  }): Promise<{ searched: number; found: number }> {
    const needle = foldText(query)
    if (needle.length <= 1) return { searched: 0, found: 0 }
    const ahead = Math.max(this.options.ahead ?? 1, 1)
    let batch: TextHit[] = []
    let found = 0
    let searched = 0
    let flushed = performance.now()
    const flush = () => {
      if (batch.length === 0) return
      options.emit(batch)
      batch = []
      flushed = performance.now()
    }
    for (let index = 0; index < sources.length; index += 1) {
      if (options.cancelled()) break
      const source = sources[index]
      let text: ReadText | null | undefined = this.memory.get(source.id)
      if (!text || this.memory.get(source.id)?.file !== source.file) {
        flush()
        for (const next of sources.slice(index + 1, index + ahead)) void this.load(next)
        text = await this.load(source)
        if (options.cancelled()) break
      }
      searched += 1
      if (!text) continue
      const hit = this.hit(needle, source, text)
      if (hit) {
        batch.push(hit)
        found += 1
        if (options.limit !== undefined && found >= options.limit) break
      }
      if (performance.now() - flushed > 16) flush()
    }
    flush()
    return { searched, found }
  }

  // MARK: - Keeping it

  private fileFor(id: string): string {
    return path.join(this.options.directory, `${id}.json`)
  }

  /**
   * Two lines: what the text is of — the file, its size and time, which fold
   * — and then the text. The first line alone answers "is this still good?"
   * and "is this paper still anywhere?", so a clean-up never parses a body.
   */
  private async readCache(source: TextSource, stamp: Stamp): Promise<PaperText | null> {
    let raw: string
    try {
      raw = await fsp.readFile(this.fileFor(source.id), 'utf8')
    } catch {
      return null
    }
    const cut = raw.indexOf('\n')
    if (cut < 0) return null
    try {
      const header = JSON.parse(raw.slice(0, cut)) as {
        version?: number; fold?: string; file?: string; size?: number; mtimeMs?: number
      }
      if (header.version !== CACHE_VERSION || header.fold !== foldVersion()) return null
      if (header.file !== source.file) return null
      if (typeof header.size !== 'number' || typeof header.mtimeMs !== 'number') return null
      if (!sameStamp(stamp, { size: header.size, mtimeMs: header.mtimeMs })) return null
      const body = JSON.parse(raw.slice(cut + 1)) as ReadText
      if (!Array.isArray(body.pages) || !Array.isArray(body.folded) || body.pages.length !== body.folded.length) {
        return null
      }
      return { file: source.file, size: stamp.size, mtimeMs: stamp.mtimeMs, pages: body.pages, folded: body.folded }
    } catch {
      return null
    }
  }

  private async writeCache(id: string, entry: PaperText) {
    const header = {
      version: CACHE_VERSION, fold: foldVersion(), id, file: entry.file, size: entry.size, mtimeMs: entry.mtimeMs,
    }
    const target = this.fileFor(id)
    const temporary = `${target}.${process.pid}.tmp`
    try {
      await fsp.mkdir(this.options.directory, { recursive: true })
      await fsp.writeFile(temporary, `${JSON.stringify(header)}\n${JSON.stringify({ pages: entry.pages, folded: entry.folded })}`)
      await fsp.rename(temporary, target)
    } catch {
      // A cache that cannot be written is a cache that is read again next
      // time; nothing is lost.
      await fsp.rm(temporary, { force: true }).catch(() => {})
    }
  }

  /**
   * Takes out what is kept for papers that are gone.
   *
   * Gone means not in the library now *and* not anywhere this could still be
   * asked for: its file has disappeared, or it was a file in one of the open
   * folders. A paper in a folder that is only disconnected, or on a disk that
   * is not plugged in, keeps its text — connecting the folder again should
   * not mean reading it all again. Leftovers from a write that was cut short
   * go too.
   */
  async cleanup(live: Set<string>, roots: string[]): Promise<number> {
    let names: string[]
    try {
      names = await fsp.readdir(this.options.directory)
    } catch {
      return 0
    }
    const inside = (file: string) => roots.some((root) => {
      const relative = path.relative(root, file)
      return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative)
    })
    let removed = 0
    for (const name of names) {
      const full = path.join(this.options.directory, name)
      if (name.endsWith('.tmp')) {
        const stat = await fsp.stat(full).catch(() => null)
        // Only one that nothing is still writing: older than a minute.
        if (stat && Date.now() - stat.mtimeMs > 60_000) {
          await fsp.rm(full, { force: true })
          removed += 1
        }
        continue
      }
      if (!name.endsWith('.json')) continue
      const id = name.slice(0, -'.json'.length)
      if (live.has(id)) continue
      const file = await headerFile(full)
      if (file === null) continue
      if (file === undefined || inside(file) || (await stampOf(file)) === null) {
        await fsp.rm(full, { force: true })
        this.memory.delete(id)
        removed += 1
      }
    }
    return removed
  }
}

/**
 * The file a cache entry was made from, reading no more than its first line.
 * `undefined` for an entry that says nothing sensible (which goes), `null`
 * when the entry could not be read at all (which stays, for now).
 */
async function headerFile(entry: string): Promise<string | null | undefined> {
  let handle: fsp.FileHandle | null = null
  try {
    handle = await fsp.open(entry, 'r')
    const buffer = Buffer.alloc(16384)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
    const text = buffer.subarray(0, bytesRead).toString('utf8')
    const cut = text.indexOf('\n')
    if (cut < 0) return undefined
    const header = JSON.parse(text.slice(0, cut)) as { file?: unknown }
    return typeof header.file === 'string' ? header.file : undefined
  } catch {
    return null
  } finally {
    await handle?.close().catch(() => {})
  }
}
