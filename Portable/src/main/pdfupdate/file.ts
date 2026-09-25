/**
 * A PDF file, read far enough to find any object by number: the cross-
 * reference chain (tables and streams, /Prev and /XRefStm), object streams,
 * and the page tree. The port of `PDFFile.swift`.
 *
 * Read the way readers read, with one difference — every place where a
 * reader would quietly repair something, this one also writes down that it
 * did. A save that rests on a repair is refused: if this reader and pdf.js
 * (or PDFKit, on the Mac) repaired the same file differently, the marks
 * would go onto a page the user was not looking at.
 */
import {
  Filters,
  Lexer,
  NULL,
  PDFDict,
  PDFError,
  Parser,
  arrayOf,
  dictOf,
  intOf,
  nameOf,
  obj,
  ref,
  refOf,
  type PDFObj,
  type PDFRef,
} from './syntax.js'
import type { StandardSecurity } from './crypt.js'

export type Entry =
  | { kind: 'free'; gen: number }
  | { kind: 'offset'; offset: number; gen: number }
  | { kind: 'compressed'; stream: number; index: number }

export type SectionKind = 'table' | 'stream'

export interface Section {
  kind: SectionKind
  offset: number
  trailer: PDFDict
}

export interface PageInfo {
  ref: PDFRef
  dict: PDFDict
}

interface ObjectStream {
  data: Uint8Array
  objects: Map<number, PDFObj>
  spans: Map<number, [number, number]>
}

/** Keys of a section that describe the section itself, not the file. */
export const SECTION_KEYS = new Set(['Prev', 'XRefStm', 'Type', 'W', 'Index', 'Filter', 'DecodeParms', 'Length', 'N', 'First'])

const STARTXREF = Buffer.from('startxref', 'latin1')
const ENDSTREAM = Buffer.from('endstream', 'latin1')
const TRAILER = Buffer.from('trailer', 'latin1')

export class PDFFile {
  readonly bytes: Uint8Array
  readonly entries = new Map<number, Entry>()
  /** Newest first, as the chain is walked. */
  readonly sections: Section[] = []
  startxref = -1
  /** Trailer keys as the newest section that has each one says them. */
  trailer = new PDFDict()
  /** True when the chain could not be read as written and objects were
   *  found by scanning the file instead. */
  repaired = false
  readonly notes: string[] = []
  /** How many times an object was handed out that this reader had to guess
   *  at — found by scanning because its offset was wrong, or its stream's
   *  length repaired. Counted per read, not per object. */
  guessedReads = 0
  private guessed = new Set<number>()
  /** Objects whose parse had to overlook something. Never written back
   *  from the parse. */
  readonly irregular = new Set<number>()

  private cache = new Map<number, PDFObj>()
  /** Where each uncompressed object's value lies in the file. */
  private bodies = new Map<number, [number, number]>()
  private objectStreams = new Map<number, ObjectStream>()
  private scanIndex: Map<number, { offset: number; gen: number }> | null = null
  private _security: StandardSecurity | null = null

  constructor(bytes: Uint8Array) {
    if (bytes.length === 0) throw new PDFError('missing', 'bytes')
    this.bytes = bytes
    this.readChain()
  }

  get count() { return this.bytes.length }

  /** Set for an encrypted file once its key is known: objects read from
   *  then on come back decrypted. */
  get security() { return this._security }
  set security(value: StandardSecurity | null) {
    this._security = value
    this.cache.clear()
    this.objectStreams.clear()
  }

  /** Runs `body` and says whether anything it read was a guess — without
   *  counting that against the caller. */
  tolerant<T>(body: () => T): [T, boolean] {
    const before = this.guessedReads
    const result = body()
    const hit = this.guessedReads > before
    this.guessedReads = before
    return [result, hit]
  }

  private note(s: string) { this.notes.push(s) }

  // MARK: Cross-reference chain

  private findStartXRef(): number | null {
    const b = this.bytes
    // Readers look well past the last kilobyte: files with a megabyte of
    // zeros after %%EOF open everywhere, so they are read here too.
    const window = Math.min(b.length, 1 << 20)
    const floor = Math.max(0, b.length - window)
    let i = b.length - STARTXREF.length
    while (i >= floor) {
      if (b[i] === 0x73 && this.matches(STARTXREF, i)) {
        const lex = new Lexer(b, i + STARTXREF.length)
        const t = lex.next()
        return t.k === 'int' ? t.v : null
      }
      i -= 1
    }
    return null
  }

  private matches(needle: Uint8Array, i: number): boolean {
    const b = this.bytes
    if (i < 0 || i + needle.length > b.length) return false
    for (let k = 0; k < needle.length; k += 1) if (b[i + k] !== needle[k]) return false
    return true
  }

  private readChain() {
    const sx = this.findStartXRef()
    if (sx === null) {
      this.note('no startxref')
      this.reconstruct()
      return
    }
    this.startxref = sx
    let next: number | null = sx
    const visited = new Set<number>()
    try {
      while (next !== null) {
        const off: number = next
        if (visited.has(off)) throw new PDFError('syntax', 'xref loop', off)
        visited.add(off)
        const [section, xrefStm, freedHere] = this.readSection(off)
        this.sections.push(section)
        if (xrefStm !== null && !visited.has(xrefStm)) {
          visited.add(xrefStm)
          // Hybrid file: the stream belongs to this section, filling in what
          // its table left free or unsaid — never what a newer section
          // already decided.
          this.readSection(xrefStm, freedHere)
          this.note(`hybrid XRefStm at ${xrefStm}`)
        }
        next = intOf(section.trailer.get('Prev')) ?? null
      }
    } catch (error) {
      this.note(`chain unreadable: ${String((error as Error).message ?? error)}`)
      this.entries.clear()
      this.sections.length = 0
      this.reconstruct()
      return
    }
    for (const s of [...this.sections].reverse()) {
      for (const [k, v] of s.trailer.pairs) if (!SECTION_KEYS.has(k)) this.trailer.set(k, v)
    }
    if (!refOf(this.trailer.get('Root'))) {
      this.note('no /Root in trailer')
      this.reconstruct()
    }
  }

  /** Reads the section at an offset. Entries already known (from a newer
   *  section) are kept. Returns the section, its /XRefStm if it has one, and
   *  the numbers this table was the first to call free. */
  private readSection(off: number, fill: Set<number> | null = null): [Section, number | null, Set<number>] {
    const b = this.bytes
    if (off < 0 || off >= b.length) throw new PDFError('syntax', 'xref offset out of range', off)
    const lex = new Lexer(b, off)
    const t = lex.next()
    const freedHere = new Set<number>()
    if (t.k === 'kw' && t.v === 'xref') {
      if (fill) throw new PDFError('syntax', '/XRefStm points at a table', off)
      const p = new Parser(b, lex.pos)
      for (;;) {
        const before = p.pos
        const t1 = p.lex.next()
        if (t1.k === 'kw' && t1.v === 'trailer') break
        const t2 = p.lex.next()
        if (t1.k !== 'int' || t2.k !== 'int') throw new PDFError('syntax', 'bad xref subsection', before)
        const first0 = t1.v
        const count = t2.v
        if (count < 0 || first0 < 0 || count > 10_000_000) throw new PDFError('syntax', `xref subsection ${first0} ${count}`, before)
        let first = first0
        for (let i = 0; i < count; i += 1) {
          const o = p.lex.next()
          const g = p.lex.next()
          const k = p.lex.next()
          if (o.k !== 'int' || g.k !== 'int' || k.k !== 'kw' || (k.v !== 'n' && k.v !== 'f')) {
            throw new PDFError('syntax', 'bad xref entry', p.pos)
          }
          // The classic off-by-one: a table that starts at 1 but opens with
          // object 0's free entry.
          if (i === 0 && first === 1 && k.v === 'f' && g.v === 65535 && o.v === 0) first = 0
          const num = first + i
          const entry: Entry = k.v === 'n' ? { kind: 'offset', offset: o.v, gen: g.v } : { kind: 'free', gen: g.v }
          if (!this.entries.has(num)) {
            this.entries.set(num, entry)
            if (k.v === 'f') freedHere.add(num)
          }
        }
      }
      const trailerObj = p.object()
      if (trailerObj.t !== 'dict') throw new PDFError('syntax', 'trailer is not a dictionary', p.pos)
      return [{ kind: 'table', offset: off, trailer: trailerObj.v }, intOf(trailerObj.v.get('XRefStm')) ?? null, freedHere]
    }
    // A cross-reference stream.
    const p = new Parser(b, off)
    const [, o] = this.parseIndirect(p, off, false, null)
    if (o.t !== 'stream' || nameOf(o.dict.get('Type')) !== 'XRef') {
      throw new PDFError('syntax', 'startxref points at neither a table nor an xref stream', off)
    }
    const dict = o.dict
    const data = Filters.decode(dict, o.data)
    const w = (arrayOf(dict.get('W')) ?? []).map(intOf)
    if (w.length !== 3 || w.some((x) => x === undefined || x < 0 || x > 8)) {
      throw new PDFError('syntax', 'xref stream without a usable /W', off)
    }
    const widths = w as number[]
    const size = intOf(dict.get('Size')) ?? 0
    const index = (arrayOf(dict.get('Index')) ?? []).map(intOf).filter((x): x is number => x !== undefined)
    const ranges = index.length > 0 ? index : [0, size]
    const rowWidth = widths[0] + widths[1] + widths[2]
    if (rowWidth <= 0) throw new PDFError('syntax', 'xref stream with /W [0 0 0]', off)
    let cursor = 0
    const field = (width: number, fallback: number) => {
      if (width <= 0) return fallback
      let v = 0
      for (let k = 0; k < width; k += 1) {
        v = v * 256 + (cursor < data.length ? data[cursor] : 0)
        cursor += 1
      }
      return v
    }
    for (let pair = 0; pair + 1 < ranges.length; pair += 2) {
      const first = ranges[pair]
      const count = ranges[pair + 1]
      if (first < 0 || count < 0 || count > 10_000_000) throw new PDFError('syntax', `/Index ${first} ${count} in xref stream`, off)
      for (let i = 0; i < count; i += 1) {
        if (cursor + rowWidth > data.length) break
        const type = field(widths[0], 1)
        const f2 = field(widths[1], 0)
        const f3 = field(widths[2], 0)
        const num = first + i
        let entry: Entry
        if (type === 0) entry = { kind: 'free', gen: f3 }
        else if (type === 1) entry = { kind: 'offset', offset: f2, gen: f3 }
        else if (type === 2) entry = { kind: 'compressed', stream: f2, index: f3 }
        else continue // reserved types are ignored
        if (fill) {
          if (!this.entries.has(num) || fill.has(num)) this.entries.set(num, entry)
        } else if (!this.entries.has(num)) {
          this.entries.set(num, entry)
          if (entry.kind === 'free') freedHere.add(num)
        }
      }
    }
    return [{ kind: 'stream', offset: off, trailer: dict }, null, freedHere]
  }

  /** Reads "num gen obj … endobj" at an offset: the reference, the object,
   *  and where the object's value lies in the file. */
  private parseIndirect(p: Parser, off: number, resolveLength: boolean, expected: number | null): [PDFRef, PDFObj, [number, number]] {
    const b = this.bytes
    p.pos = off
    const n = p.lex.next()
    const g = p.lex.next()
    const kw = p.lex.next()
    if (n.k !== 'int' || g.k !== 'int' || kw.k !== 'kw' || kw.v !== 'obj') throw new PDFError('syntax', 'no object header', off)
    const num = n.v
    const gen = g.v
    if (expected !== null && expected !== num) throw new PDFError('syntax', `object ${num} where ${expected} should be`, off)
    p.lex.skipWhite()
    const bodyStart = p.pos
    const o = p.object()
    const bodyEnd = p.pos
    if (p.sawIrregularity) this.irregular.add(num)
    if (o.t !== 'dict') return [ref(num, gen), o, [bodyStart, bodyEnd]]
    const save = p.pos
    const s = p.lex.next()
    if (!(s.k === 'kw' && s.v === 'stream')) {
      p.pos = save
      return [ref(num, gen), o, [bodyStart, bodyEnd]]
    }
    let start = p.pos
    if (start < b.length && b[start] === 0x0d) start += 1
    if (start < b.length && b[start] === 0x0a) start += 1
    const dict = o.v
    let length: number | undefined
    const declared = dict.get('Length')
    if (declared?.t === 'int') length = declared.v
    else if (declared?.t === 'ref' && resolveLength) {
      try { length = intOf(this.object(declared.v.num)) } catch { length = undefined }
    }
    let end: number | null = null
    if (length !== undefined && length >= 0 && length <= b.length - start) {
      const lx = new Lexer(b, start + length)
      const e = lx.next()
      if (e.k === 'kw' && e.v === 'endstream') end = start + length
    }
    if (end === null) {
      // /Length is wrong or missing: find endstream, as readers do — and
      // remember that this object was a guess.
      let i = start
      while (i + ENDSTREAM.length <= b.length) {
        if (b[i] === 0x65 && this.matches(ENDSTREAM, i)) break
        i += 1
      }
      let e = Math.min(i, b.length)
      if (e > start && b[e - 1] === 0x0a) e -= 1
      if (e > start && b[e - 1] === 0x0d) e -= 1
      end = e
      this.note(`stream ${num} length repaired`)
      this.guessed.add(num)
    }
    const data = b.subarray(start, end)
    return [ref(num, gen), obj.stream(dict, data), [bodyStart, bodyEnd]]
  }

  // MARK: Repair

  /** Builds an index of every "n g obj" in the file, last one winning —
   *  what readers do with a file whose cross-reference table cannot be
   *  trusted. */
  private buildScanIndex(): Map<number, { offset: number; gen: number }> {
    if (this.scanIndex) return this.scanIndex
    const b = this.bytes
    const index = new Map<number, { offset: number; gen: number }>()
    const n = b.length
    const integer = (from: number, to: number): number | null => {
      if (to - from <= 0 || to - from >= 16) return null
      let v = 0
      for (let k = from; k < to; k += 1) v = v * 10 + (b[k] - 0x30)
      return v
    }
    const isDigit = (c: number) => c >= 0x30 && c <= 0x39
    const white = (c: number) => c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09 || c === 0x0c || c === 0x00
    let i = 0
    while (i < n - 3) {
      // Look for "obj" preceded by "<digits> <digits> ".
      if (b[i] === 0x6f && b[i + 1] === 0x62 && b[i + 2] === 0x6a && (i + 3 >= n || !isRegularByte(b[i + 3]))) {
        let j = i - 1
        while (j >= 0 && white(b[j])) j -= 1
        const genEnd = j + 1
        while (j >= 0 && isDigit(b[j])) j -= 1
        const genStart = j + 1
        if (genStart < genEnd) {
          while (j >= 0 && white(b[j])) j -= 1
          const numEnd = j + 1
          while (j >= 0 && isDigit(b[j])) j -= 1
          const numStart = j + 1
          if (numStart < numEnd && numEnd < genStart && (j < 0 || !isRegularByte(b[j]))) {
            const num = integer(numStart, numEnd)
            const gen = integer(genStart, genEnd)
            if (num !== null && gen !== null) index.set(num, { offset: numStart, gen })
          }
        }
        i += 3
        continue
      }
      i += 1
    }
    this.scanIndex = index
    return index
  }

  private reconstruct() {
    this.repaired = true
    const index = this.buildScanIndex()
    this.entries.clear()
    for (const [num, loc] of index) this.entries.set(num, { kind: 'offset', offset: loc.offset, gen: loc.gen })
    // The last trailer with a /Root, or failing that a catalog.
    const b = this.bytes
    let found: PDFDict | null = null
    let i = 0
    while (i + TRAILER.length <= b.length) {
      if (b[i] === 0x74 && this.matches(TRAILER, i)) {
        const p = new Parser(b, i + TRAILER.length)
        try {
          const d = p.object()
          if (d.t === 'dict' && d.v.has('Root')) found = d.v
        } catch {
          // not a trailer
        }
      }
      i += 1
    }
    const numbers = [...index.keys()].sort((a, c) => a - c)
    if (!found) {
      for (const num of numbers) {
        let d: PDFDict | undefined
        try { d = dictOf(this.object(num)) } catch { d = undefined }
        if (d && nameOf(d.get('Type')) === 'XRef' && d.has('Root')) found = d
      }
    }
    if (!found) {
      for (const num of numbers) {
        let d: PDFDict | undefined
        try { d = dictOf(this.object(num)) } catch { d = undefined }
        const loc = index.get(num)
        if (d && nameOf(d.get('Type')) === 'Catalog' && loc) found = PDFDict.from({ Root: obj.ref(ref(num, loc.gen)) })
      }
    }
    if (!found) throw new PDFError('missing', 'trailer')
    for (const [k, v] of found.pairs) if (!SECTION_KEYS.has(k)) this.trailer.set(k, v)
  }

  // MARK: Objects

  get size(): number {
    const declared = intOf(this.trailer.get('Size')) ?? 0
    let highest = 0
    for (const num of this.entries.keys()) if (num + 1 > highest) highest = num + 1
    return Math.max(declared, highest)
  }

  get isEncrypted() { return this.trailer.has('Encrypt') }

  entry(num: number) { return this.entries.get(num) }

  generation(num: number): number {
    const e = this.entries.get(num)
    return e?.kind === 'offset' ? e.gen : 0
  }

  isInUse(num: number): boolean {
    const e = this.entries.get(num)
    if (e?.kind === 'offset') return e.offset > 0
    return e?.kind === 'compressed'
  }

  object(num: number): PDFObj {
    const hit = this.cache.get(num)
    if (hit) {
      if (this.guessed.has(num)) this.guessedReads += 1
      return hit
    }
    let result: PDFObj
    const e = this.entries.get(num)
    if (!e || e.kind === 'free') {
      result = NULL
    } else if (e.kind === 'offset' && e.offset === 0) {
      // Quartz leaves entries "in use at offset 0" for objects it dropped —
      // hundreds of them across ordinary files. Nothing lives at offset 0
      // but the header; readers take them as null.
      result = NULL
    } else if (e.kind === 'offset') {
      let found: PDFObj
      const p = new Parser(this.bytes, e.offset)
      let parsed: [PDFRef, PDFObj, [number, number]] | null = null
      try {
        parsed = this.parseIndirect(p, e.offset, true, num)
      } catch {
        parsed = null
      }
      if (parsed) {
        found = parsed[1]
        this.bodies.set(num, parsed[2])
      } else {
        const loc = this.buildScanIndex().get(num)
        if (!loc) throw new PDFError('missing', `object ${num} at ${e.offset}`)
        const q = new Parser(this.bytes, loc.offset)
        const [, o] = this.parseIndirect(q, loc.offset, true, num)
        this.note(`object ${num} found by scan (xref offset ${e.offset} wrong)`)
        this.guessed.add(num)
        found = o
      }
      const encryptRef = refOf(this.trailer.get('Encrypt'))
      if (this._security && num !== encryptRef?.num) {
        found = this._security.decrypting(found, ref(num, e.gen))
      }
      result = found
    } else {
      result = this.compressedObject(num, e.stream)
    }
    if (this.guessed.has(num)) this.guessedReads += 1
    this.cache.set(num, result)
    return result
  }

  resolve(o: PDFObj | undefined): PDFObj {
    if (!o) return NULL
    if (o.t === 'ref') return this.object(o.v.num)
    return o
  }

  /** Like `resolve`, but a reference that cannot be read is null rather than a throw. */
  resolveQuietly(o: PDFObj | undefined): PDFObj {
    try { return this.resolve(o) } catch { return NULL }
  }

  private loadObjectStream(stm: number): ObjectStream {
    const loaded = this.objectStreams.get(stm)
    if (loaded) return loaded
    const o = this.object(stm)
    if (o.t !== 'stream') throw new PDFError('syntax', `object stream ${stm} is not a stream`, 0)
    const data = Filters.decode(o.dict, o.data)
    const n = intOf(o.dict.get('N')) ?? 0
    const first = intOf(o.dict.get('First')) ?? 0
    if (n < 0 || n > 1_000_000 || first < 0 || first > data.length) {
      throw new PDFError('syntax', `object stream ${stm} with /N ${n} /First ${first}`, 0)
    }
    const result: ObjectStream = { data, objects: new Map(), spans: new Map() }
    const header = new Lexer(data)
    const offsets: [number, number][] = []
    for (let k = 0; k < n; k += 1) {
      const on = header.next()
      const oo = header.next()
      if (on.k !== 'int' || oo.k !== 'int' || oo.v < 0) break
      offsets.push([on.v, first + oo.v])
    }
    for (const [on, start] of offsets) {
      if (start >= data.length) continue
      const p = new Parser(data, start)
      let parsed: PDFObj
      try {
        parsed = p.object()
      } catch {
        // Readers skip an object they cannot parse; so does this one, but
        // it remembers that it did.
        this.guessed.add(on)
        continue
      }
      if (p.sawIrregularity) this.irregular.add(on)
      result.objects.set(on, parsed)
      result.spans.set(on, [start, p.pos])
    }
    this.objectStreams.set(stm, result)
    return result
  }

  private compressedObject(num: number, stm: number): PDFObj {
    return this.loadObjectStream(stm).objects.get(num) ?? NULL
  }

  /** An object's value exactly as the file writes it, and whether it came
   *  out of an object stream — for writing it back with one entry changed.
   *  Null when the object could not be read as written. In an encrypted
   *  file the text of an uncompressed object is its ciphertext. */
  rawText(num: number): { text: Uint8Array; inObjectStream: boolean } | null {
    try { this.object(num) } catch { return null }
    // An irregular object may still be spliced — its bytes are kept as they
    // were — but one that was a guess may not.
    if (this.guessed.has(num)) return null
    const e = this.entries.get(num)
    if (e?.kind === 'offset') {
      const body = this.bodies.get(num)
      if (!body) return null
      return { text: this.bytes.subarray(body[0], body[1]), inObjectStream: false }
    }
    if (e?.kind === 'compressed') {
      const loaded = this.objectStreams.get(e.stream)
      const span = loaded?.spans.get(num)
      if (!loaded || !span) return null
      return { text: loaded.data.subarray(span[0], span[1]), inObjectStream: true }
    }
    return null
  }

  // MARK: Page tree

  pages(): PageInfo[] {
    const rootRef = refOf(this.trailer.get('Root'))
    const catalog = rootRef ? dictOf(this.object(rootRef.num)) : undefined
    if (!catalog) throw new PDFError('missing', 'catalog')
    const pagesRef = refOf(catalog.get('Pages'))
    if (!pagesRef) throw new PDFError('missing', '/Pages')
    const result: PageInfo[] = []
    const visited = new Set<number>()
    const walk = (r: PDFRef, depth: number) => {
      if (depth >= 64 || visited.has(r.num)) throw new PDFError('unsupported', `page tree cycle at ${r.num}`)
      visited.add(r.num)
      const node = dictOf(this.object(r.num))
      if (!node) return
      const type = nameOf(node.get('Type'))
      if (type === 'Pages' || (type === undefined && node.has('Kids'))) {
        for (const kid of arrayOf(this.resolve(node.get('Kids'))) ?? []) {
          const kr = refOf(kid)
          if (!kr) throw new PDFError('unsupported', 'direct page object in /Kids')
          // A reference whose generation is not the one the table gives:
          // readers disagree about whether that is the page.
          const e = this.entries.get(kr.num)
          if (e?.kind === 'offset' && e.gen !== kr.gen) {
            throw new PDFError('unsupported', `/Kids says ${kr.num} ${kr.gen} R, the table says generation ${e.gen}`)
          }
          walk(kr, depth + 1)
        }
      } else {
        result.push({ ref: r, dict: node })
      }
    }
    walk(pagesRef, 0)
    return result
  }
}

function isRegularByte(c: number): boolean {
  if (c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09 || c === 0x0c || c === 0x00) return false
  switch (c) {
    case 0x28: case 0x29: case 0x3c: case 0x3e: case 0x5b: case 0x5d: case 0x7b: case 0x7d: case 0x2f: case 0x25:
      return false
    default:
      return true
  }
}
