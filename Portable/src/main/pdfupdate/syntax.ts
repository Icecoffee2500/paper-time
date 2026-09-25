/**
 * A small PDF object model, tokenizer, parser and serializer — just enough to
 * read a file's cross-reference chain, page tree and annotations, and to
 * write new objects in an incremental update (ISO 32000-1 §7.5.6).
 *
 * The port of `PDFSyntax.swift`, kept the same shape on purpose: the two
 * builds append to the same files, and where one of them reads a file
 * differently from the other the marks would go onto a page the reader was
 * not looking at. Nothing here is meant to understand a whole PDF. It reads
 * the few objects a save touches, reads them the way readers do, and says so
 * whenever it had to guess.
 */
import zlib from 'node:zlib'

export class PDFError extends Error {
  constructor(readonly kind: 'syntax' | 'unsupported' | 'missing', message: string, readonly at = 0) {
    super(kind === 'syntax' ? `syntax: ${message} at ${at}` : `${kind}: ${message}`)
    this.name = 'PDFError'
  }
}

export interface PDFRef {
  readonly num: number
  readonly gen: number
}

export const ref = (num: number, gen = 0): PDFRef => ({ num, gen })
export const sameRef = (a: PDFRef, b: PDFRef) => a.num === b.num && a.gen === b.gen
export const refString = (r: PDFRef) => `${r.num} ${r.gen} R`

export type PDFObj =
  | { readonly t: 'null' }
  | { readonly t: 'bool'; readonly v: boolean }
  | { readonly t: 'int'; readonly v: number }
  /** A real number — or an integer too big to hold exactly — kept as the
   *  lexeme the file used, so a re-serialised object says what it said. */
  | { readonly t: 'real'; readonly v: string }
  | { readonly t: 'string'; readonly v: Uint8Array; readonly hex: boolean }
  /** A name, `#xx` escapes decoded, bytes held one-to-one as Latin-1. */
  | { readonly t: 'name'; readonly v: string }
  | { readonly t: 'array'; readonly v: PDFObj[] }
  | { readonly t: 'dict'; readonly v: PDFDict }
  | { readonly t: 'ref'; readonly v: PDFRef }
  /** A stream: its dictionary and its raw (still encoded) bytes. */
  | { readonly t: 'stream'; readonly dict: PDFDict; readonly data: Uint8Array }

export const NULL: PDFObj = { t: 'null' }
export const obj = {
  bool: (v: boolean): PDFObj => ({ t: 'bool', v }),
  int: (v: number): PDFObj => ({ t: 'int', v }),
  real: (v: string): PDFObj => ({ t: 'real', v }),
  string: (v: Uint8Array, hex = false): PDFObj => ({ t: 'string', v, hex }),
  name: (v: string): PDFObj => ({ t: 'name', v }),
  array: (v: PDFObj[]): PDFObj => ({ t: 'array', v }),
  dict: (v: PDFDict): PDFObj => ({ t: 'dict', v }),
  ref: (r: PDFRef): PDFObj => ({ t: 'ref', v: r }),
  stream: (dict: PDFDict, data: Uint8Array): PDFObj => ({ t: 'stream', dict, data }),
}

export const intOf = (o: PDFObj | undefined): number | undefined => (o?.t === 'int' ? o.v : undefined)
export const nameOf = (o: PDFObj | undefined): string | undefined => (o?.t === 'name' ? o.v : undefined)
export const arrayOf = (o: PDFObj | undefined): PDFObj[] | undefined => (o?.t === 'array' ? o.v : undefined)
export const refOf = (o: PDFObj | undefined): PDFRef | undefined => (o?.t === 'ref' ? o.v : undefined)
export const dictOf = (o: PDFObj | undefined): PDFDict | undefined =>
  o?.t === 'dict' ? o.v : o?.t === 'stream' ? o.dict : undefined
export const stringBytesOf = (o: PDFObj | undefined): Uint8Array | undefined => (o?.t === 'string' ? o.v : undefined)
export const isNull = (o: PDFObj | undefined): boolean => o === undefined || o.t === 'null'

export function numberOf(o: PDFObj | undefined): number | undefined {
  if (o?.t === 'int') return o.v
  if (o?.t === 'real') {
    const d = Number(o.v)
    return Number.isFinite(d) ? d : lenientDouble(o.v)
  }
  return undefined
}

/** "--5", "5-", "1.2.3": the longest prefix that parses. */
export function lenientDouble(s: string): number {
  let t = s
  while (t.length > 0) {
    const d = Number(t)
    if (t.trim() !== '' && Number.isFinite(d)) return d
    t = t.slice(0, -1)
  }
  return 0
}

/**
 * Text of a PDF text string: UTF-16BE with BOM, UTF-8 with BOM, or
 * PDFDocEncoding (approximated as Latin-1).
 */
export function textOf(o: PDFObj | undefined): string | undefined {
  const b = stringBytesOf(o)
  if (!b) return undefined
  if (b.length >= 2 && b[0] === 0xfe && b[1] === 0xff) {
    let out = ''
    for (let i = 2; i + 1 < b.length; i += 2) out += String.fromCharCode((b[i] << 8) | b[i + 1])
    return out
  }
  if (b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) {
    return Buffer.from(b.subarray(3)).toString('utf8')
  }
  return Buffer.from(b).toString('latin1')
}

/** A text string as this build writes one: UTF-16BE with a BOM, in hex. */
export function textString(value: string): PDFObj {
  const out = new Uint8Array(2 + value.length * 2)
  out[0] = 0xfe
  out[1] = 0xff
  for (let i = 0; i < value.length; i += 1) {
    const unit = value.charCodeAt(i)
    out[2 + i * 2] = unit >> 8
    out[3 + i * 2] = unit & 0xff
  }
  return obj.string(out, true)
}

export class PDFDict {
  pairs: [string, PDFObj][]

  constructor(pairs: [string, PDFObj][] = []) {
    this.pairs = pairs
  }

  /** The first value under a key. A dictionary that says a key twice is read
   *  differently by different readers — see `count`. */
  get(key: string): PDFObj | undefined {
    for (const [k, v] of this.pairs) if (k === key) return v
    return undefined
  }

  set(key: string, value: PDFObj | undefined) {
    const i = this.pairs.findIndex(([k]) => k === key)
    if (i >= 0) {
      if (value) {
        this.pairs[i] = [key, value]
        // One key, one value, once set on purpose.
        for (let j = this.pairs.length - 1; j > i; j -= 1) if (this.pairs[j][0] === key) this.pairs.splice(j, 1)
      } else {
        this.pairs = this.pairs.filter(([k]) => k !== key)
      }
    } else if (value) {
      this.pairs.push([key, value])
    }
  }

  has(key: string) { return this.get(key) !== undefined }
  get keys() { return this.pairs.map(([k]) => k) }
  count(key: string) { return this.pairs.reduce((n, [k]) => n + (k === key ? 1 : 0), 0) }
  clone() { return new PDFDict(this.pairs.map(([k, v]) => [k, v])) }

  static from(entries: Record<string, PDFObj>): PDFDict {
    return new PDFDict(Object.entries(entries))
  }
}

// MARK: - Character classes

export const isWhite = (c: number) => c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09 || c === 0x0c || c === 0x00

export function isDelim(c: number): boolean {
  switch (c) {
    case 0x28: case 0x29: case 0x3c: case 0x3e: case 0x5b: case 0x5d: case 0x7b: case 0x7d: case 0x2f: case 0x25:
      return true
    default:
      return false
  }
}

export const isRegular = (c: number) => !isWhite(c) && !isDelim(c)

function hexValue(c: number): number {
  if (c >= 0x30 && c <= 0x39) return c - 0x30
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10
  return -1
}

// MARK: - Lexer

export type Tok =
  | { k: 'int'; v: number }
  | { k: 'real'; v: string }
  | { k: 'name'; v: string }
  | { k: 'str'; v: Uint8Array; hex: boolean }
  | { k: 'kw'; v: string }
  | { k: 'aOpen' } | { k: 'aClose' } | { k: 'dOpen' } | { k: 'dClose' } | { k: 'eof' }

/** Reads tokens straight out of the bytes it is given — the file itself. */
export class Lexer {
  constructor(readonly b: Uint8Array, public pos = 0) {}

  skipWhite() {
    const b = this.b
    while (this.pos < b.length) {
      const c = b[this.pos]
      if (isWhite(c)) { this.pos += 1; continue }
      if (c === 0x25) { // % comment to end of line
        while (this.pos < b.length && b[this.pos] !== 0x0a && b[this.pos] !== 0x0d) this.pos += 1
        continue
      }
      break
    }
  }

  next(): Tok {
    this.skipWhite()
    const b = this.b
    if (this.pos >= b.length) return { k: 'eof' }
    const c = b[this.pos]
    switch (c) {
      case 0x5b: this.pos += 1; return { k: 'aOpen' }
      case 0x5d: this.pos += 1; return { k: 'aClose' }
      case 0x3c:
        if (this.pos + 1 < b.length && b[this.pos + 1] === 0x3c) { this.pos += 2; return { k: 'dOpen' } }
        return this.hexString()
      case 0x3e:
        if (this.pos + 1 < b.length && b[this.pos + 1] === 0x3e) { this.pos += 2; return { k: 'dClose' } }
        this.pos += 1
        return { k: 'kw', v: '>' }
      case 0x28: return this.literalString()
      case 0x2f: return this.name()
      case 0x7b: case 0x7d: this.pos += 1; return { k: 'kw', v: String.fromCharCode(c) }
      case 0x29: this.pos += 1; return { k: 'kw', v: ')' }
      default: {
        if (c === 0x2b || c === 0x2d || c === 0x2e || (c >= 0x30 && c <= 0x39)) return this.number()
        const start = this.pos
        while (this.pos < b.length && isRegular(b[this.pos])) this.pos += 1
        if (this.pos === start) this.pos += 1
        return { k: 'kw', v: Buffer.from(b.subarray(start, this.pos)).toString('latin1') }
      }
    }
  }

  private number(): Tok {
    const b = this.b
    const start = this.pos
    let dot = false
    while (this.pos < b.length) {
      const c = b[this.pos]
      if (c >= 0x30 && c <= 0x39) { this.pos += 1; continue }
      if (c === 0x2e) { dot = true; this.pos += 1; continue }
      if (c === 0x2b || c === 0x2d) { this.pos += 1; continue }
      break
    }
    // Something like "12abc" — a keyword that starts with digits.
    if (this.pos < b.length && isRegular(b[this.pos])) {
      while (this.pos < b.length && isRegular(b[this.pos])) this.pos += 1
      return { k: 'kw', v: Buffer.from(b.subarray(start, this.pos)).toString('latin1') }
    }
    const s = Buffer.from(b.subarray(start, this.pos)).toString('latin1')
    if (!dot && /^[+-]?\d+$/.test(s)) {
      const v = Number(s)
      if (Number.isSafeInteger(v)) return { k: 'int', v }
      // One too big to hold exactly keeps its lexeme, so it is written back
      // exactly as it was, and never rounds.
      return { k: 'real', v: s }
    }
    if (!dot) {
      // "-", "+", "--3": broken integers, read leniently.
      const d = lenientDouble(s)
      if (Number.isFinite(d) && Math.abs(d) < 9e15) return { k: 'int', v: Math.trunc(d) }
      return { k: 'real', v: s }
    }
    return { k: 'real', v: s }
  }

  private name(): Tok {
    const b = this.b
    this.pos += 1 // '/'
    const out: number[] = []
    while (this.pos < b.length && isRegular(b[this.pos])) {
      const c = b[this.pos]
      if (c === 0x23 && this.pos + 2 < b.length) {
        const h = hexValue(b[this.pos + 1])
        const l = hexValue(b[this.pos + 2])
        if (h >= 0 && l >= 0) {
          out.push(h * 16 + l)
          this.pos += 3
          continue
        }
      }
      out.push(c)
      this.pos += 1
    }
    return { k: 'name', v: Buffer.from(out).toString('latin1') }
  }

  private hexString(): Tok {
    const b = this.b
    this.pos += 1 // '<'
    const out: number[] = []
    let high = -1
    while (this.pos < b.length && b[this.pos] !== 0x3e) {
      const v = hexValue(b[this.pos])
      if (v >= 0) {
        if (high >= 0) { out.push(high * 16 + v); high = -1 } else { high = v }
      }
      this.pos += 1
    }
    if (high >= 0) out.push(high * 16)
    if (this.pos < b.length) this.pos += 1 // '>'
    return { k: 'str', v: Uint8Array.from(out), hex: true }
  }

  private literalString(): Tok {
    const b = this.b
    this.pos += 1 // '('
    const out: number[] = []
    let depth = 1
    while (this.pos < b.length) {
      const c = b[this.pos]
      if (c === 0x5c) { // backslash
        this.pos += 1
        if (this.pos >= b.length) break
        const e = b[this.pos]
        switch (e) {
          case 0x6e: out.push(0x0a); this.pos += 1; break
          case 0x72: out.push(0x0d); this.pos += 1; break
          case 0x74: out.push(0x09); this.pos += 1; break
          case 0x62: out.push(0x08); this.pos += 1; break
          case 0x66: out.push(0x0c); this.pos += 1; break
          case 0x28: case 0x29: case 0x5c: out.push(e); this.pos += 1; break
          case 0x0d:
            this.pos += 1
            if (this.pos < b.length && b[this.pos] === 0x0a) this.pos += 1
            break
          case 0x0a: this.pos += 1; break
          default:
            if (e >= 0x30 && e <= 0x37) {
              let v = 0
              let n = 0
              while (n < 3 && this.pos < b.length && b[this.pos] >= 0x30 && b[this.pos] <= 0x37) {
                v = v * 8 + (b[this.pos] - 0x30)
                this.pos += 1
                n += 1
              }
              out.push(v & 0xff)
            } else {
              out.push(e)
              this.pos += 1
            }
        }
        continue
      }
      if (c === 0x28) depth += 1
      if (c === 0x29) {
        depth -= 1
        if (depth === 0) { this.pos += 1; break }
      }
      if (c === 0x0d) {
        // An unescaped end of line in a literal reads as a line feed.
        out.push(0x0a)
        this.pos += 1
        if (this.pos < b.length && b[this.pos] === 0x0a) this.pos += 1
        continue
      }
      out.push(c)
      this.pos += 1
    }
    return { k: 'str', v: Uint8Array.from(out), hex: false }
  }
}

// MARK: - Parser

export class Parser {
  lex: Lexer
  /** What this parser had to overlook: a key said twice in one dictionary,
   *  or something that is not a name where a key belongs. Readers differ on
   *  both, so an object that needed either is never written back from its
   *  parse — see `PDFFile.irregular`. */
  duplicateKeys = 0
  skippedTokens = 0

  constructor(bytes: Uint8Array, pos = 0) {
    this.lex = new Lexer(bytes, pos)
  }

  get pos() { return this.lex.pos }
  set pos(value: number) { this.lex.pos = value }
  get sawIrregularity() { return this.duplicateKeys > 0 || this.skippedTokens > 0 }

  object(depth = 0): PDFObj {
    if (depth >= 200) throw new PDFError('syntax', 'nesting too deep', this.pos)
    const at = this.pos
    const t = this.lex.next()
    return this.objectFrom(t, at, depth)
  }

  objectFrom(t: Tok, at: number, depth: number): PDFObj {
    switch (t.k) {
      case 'int': {
        const save = this.lex.pos
        const g = this.lex.next()
        if (g.k === 'int') {
          const r = this.lex.next()
          if (r.k === 'kw' && r.v === 'R') return obj.ref(ref(t.v, g.v))
        }
        this.lex.pos = save
        return obj.int(t.v)
      }
      case 'real': return obj.real(t.v)
      case 'name': return obj.name(t.v)
      case 'str': return obj.string(t.v, t.hex)
      case 'aOpen': {
        const items: PDFObj[] = []
        for (;;) {
          const p = this.lex.pos
          const u = this.lex.next()
          if (u.k === 'aClose') break
          if (u.k === 'eof') throw new PDFError('syntax', 'unterminated array', at)
          if (u.k === 'kw' && u.v === 'endobj') { this.lex.pos = p; this.skippedTokens += 1; break }
          items.push(this.objectFrom(u, p, depth + 1))
        }
        return obj.array(items)
      }
      case 'dOpen': {
        const d = new PDFDict()
        for (;;) {
          const p = this.lex.pos
          const u = this.lex.next()
          if (u.k === 'dClose') break
          if (u.k === 'eof') throw new PDFError('syntax', 'unterminated dictionary', at)
          if (u.k === 'kw' && u.v === 'endobj') { this.lex.pos = p; this.skippedTokens += 1; break }
          if (u.k !== 'name') {
            // Garbage where a key belongs: skipped, as readers do — and
            // noted, because not every reader skips the same way.
            this.skippedTokens += 1
            continue
          }
          const vp = this.lex.pos
          const vt = this.lex.next()
          if (vt.k === 'dClose') { d.pairs.push([u.v, NULL]); this.skippedTokens += 1; break }
          const value = this.objectFrom(vt, vp, depth + 1)
          // Duplicates are kept, so a re-serialised dictionary says exactly
          // what the original said; lookups see the first.
          if (d.has(u.v)) this.duplicateKeys += 1
          d.pairs.push([u.v, value])
        }
        return obj.dict(d)
      }
      case 'kw':
        if (t.v === 'true') return obj.bool(true)
        if (t.v === 'false') return obj.bool(false)
        if (t.v === 'null') return NULL
        throw new PDFError('syntax', `unexpected keyword ${t.v}`, at)
      case 'eof': throw new PDFError('syntax', 'unexpected end of file', at)
      default: throw new PDFError('syntax', 'unexpected token', at)
    }
  }
}

// MARK: - Where the pieces of an object are

export interface SpanPair {
  key: string
  keyStart: number
  valueStart: number
  valueEnd: number
}

/**
 * The byte ranges of a dictionary's or an array's top-level entries, in the
 * object's own text — so a page can be written back as the file wrote it,
 * with only its /Annots changed, rather than as this parser understood it.
 * Anything irregular throws: an object that has to be read leniently is not
 * one to cut and splice.
 */
export interface Spans {
  /** For a dictionary: its keys and values. For an array: its elements, with an empty key. */
  entries: SpanPair[]
  /** Where the closing `>>` or `]` starts. */
  close: number
  /** Where the object's text ends, after the closing delimiter. */
  end: number
}

export function spansOf(bytes: Uint8Array, start: number): Spans {
  const p = new Parser(bytes, start)
  const open = p.lex.next()
  const entries: SpanPair[] = []
  if (open.k === 'dOpen') {
    for (;;) {
      p.lex.skipWhite()
      const keyStart = p.lex.pos
      const t = p.lex.next()
      if (t.k === 'dClose') return { entries, close: p.lex.pos - 2, end: p.lex.pos }
      if (t.k !== 'name') throw new PDFError('syntax', 'not a key', keyStart)
      p.lex.skipWhite()
      const valueStart = p.lex.pos
      const vt = p.lex.next()
      if (vt.k === 'dClose' || vt.k === 'eof') throw new PDFError('syntax', 'key without a value', keyStart)
      p.objectFrom(vt, valueStart, 1)
      entries.push({ key: t.v, keyStart, valueStart, valueEnd: p.lex.pos })
    }
  }
  if (open.k === 'aOpen') {
    for (;;) {
      p.lex.skipWhite()
      const valueStart = p.lex.pos
      const t = p.lex.next()
      if (t.k === 'aClose') return { entries, close: p.lex.pos - 1, end: p.lex.pos }
      if (t.k === 'eof') throw new PDFError('syntax', 'unterminated array', valueStart)
      if (t.k === 'kw') throw new PDFError('syntax', 'keyword in an array', valueStart)
      p.objectFrom(t, valueStart, 1)
      entries.push({ key: '', keyStart: valueStart, valueStart, valueEnd: p.lex.pos })
    }
  }
  throw new PDFError('syntax', 'neither a dictionary nor an array', start)
}

// MARK: - Serializer

/** Bytes, appended to. */
export class Bytes {
  private chunks: Uint8Array[] = []
  length = 0

  push(part: Uint8Array | string) {
    const bytes = typeof part === 'string' ? Buffer.from(part, 'latin1') : part
    this.chunks.push(bytes)
    this.length += bytes.length
  }

  bytes(): Uint8Array {
    return Buffer.concat(this.chunks, this.length)
  }
}

export const Serializer = {
  write(o: PDFObj, out: Bytes) {
    switch (o.t) {
      case 'null': out.push('null'); break
      case 'bool': out.push(o.v ? 'true' : 'false'); break
      case 'int': out.push(String(o.v)); break
      case 'real': out.push(o.v); break
      case 'string': Serializer.writeString(o.v, o.hex, out); break
      case 'name': Serializer.writeName(o.v, out); break
      case 'array':
        out.push('[')
        o.v.forEach((item, i) => {
          if (i > 0) out.push(' ')
          Serializer.write(item, out)
        })
        out.push(']')
        break
      case 'dict': Serializer.writeDict(o.v, out); break
      case 'ref': out.push(refString(o.v)); break
      case 'stream': {
        const dd = o.dict.clone()
        dd.set('Length', obj.int(o.data.length))
        Serializer.writeDict(dd, out)
        out.push('\nstream\n')
        out.push(o.data)
        out.push('\nendstream')
        break
      }
    }
  },

  writeDict(d: PDFDict, out: Bytes) {
    out.push('<<')
    for (const [k, v] of d.pairs) {
      out.push(' ')
      Serializer.writeName(k, out)
      out.push(' ')
      Serializer.write(v, out)
    }
    out.push(' >>')
  },

  writeName(n: string, out: Bytes) {
    let s = '/'
    for (const c of Buffer.from(n, 'latin1')) {
      if (c < 0x21 || c > 0x7e || c === 0x23 || isDelim(c)) s += `#${c.toString(16).toUpperCase().padStart(2, '0')}`
      else s += String.fromCharCode(c)
    }
    out.push(s)
  },

  writeString(bytes: Uint8Array, hex: boolean, out: Bytes) {
    let printable = true
    for (const c of bytes) if (c < 0x20 || c >= 0x7f) { printable = false; break }
    if (hex || !printable) {
      out.push(`<${Buffer.from(bytes).toString('hex').toUpperCase()}>`)
      return
    }
    let s = '('
    for (const c of bytes) {
      if (c === 0x28 || c === 0x29 || c === 0x5c) s += '\\'
      s += String.fromCharCode(c)
    }
    out.push(s + ')')
  },

  bytes(o: PDFObj): Uint8Array {
    const out = new Bytes()
    Serializer.write(o, out)
    return out.bytes()
  },
}

// MARK: - Filters

export const Filters = {
  /** Inflates a zlib stream. Tolerant, like readers are: a stream that is
   *  cut short or carries junk after its end gives what could be decoded. */
  inflate(input: Uint8Array): Uint8Array {
    try {
      return new Uint8Array(zlib.inflateSync(input, { finishFlush: zlib.constants.Z_SYNC_FLUSH }))
    } catch (error) {
      // Junk in the middle: what came before it, as zlib's own inflate would
      // hand it out — the longest prefix that still decodes.
      for (const fraction of [0.75, 0.5, 0.25, 0.125]) {
        const prefix = input.subarray(0, Math.floor(input.length * fraction))
        if (prefix.length === 0) break
        try {
          const partial = zlib.inflateSync(prefix, { finishFlush: zlib.constants.Z_SYNC_FLUSH })
          if (partial.length > 0) return new Uint8Array(partial)
        } catch {
          // shorter still
        }
      }
      throw new PDFError('syntax', `inflate error: ${String((error as Error).message ?? error)}`, 0)
    }
  },

  deflate(input: Uint8Array): Uint8Array {
    return new Uint8Array(zlib.deflateSync(input, { level: 9 }))
  },

  unpredict(data: Uint8Array, parms: PDFDict | undefined): Uint8Array {
    const predictor = parms ? intOf(parms.get('Predictor')) ?? 1 : 1
    if (!parms || predictor <= 1) return data
    const colors = intOf(parms.get('Colors')) ?? 1
    const bpc = intOf(parms.get('BitsPerComponent')) ?? 8
    const columns = intOf(parms.get('Columns')) ?? 1
    if (colors <= 0 || colors > 64 || bpc <= 0 || bpc > 16 || columns <= 0 || columns > 1 << 20) {
      throw new PDFError('unsupported', `predictor with ${colors} colours, ${bpc} bits, ${columns} columns`)
    }
    const bpp = Math.max(1, Math.floor((colors * bpc + 7) / 8))
    const rowLength = Math.floor((columns * colors * bpc + 7) / 8)
    if (rowLength < bpp) throw new PDFError('unsupported', `predictor with ${columns} columns`)
    if (predictor === 2) {
      if (bpc !== 8) throw new PDFError('unsupported', `TIFF predictor with bpc ${bpc}`)
      const out = Uint8Array.from(data)
      for (let i = 0; i < out.length; i += rowLength) {
        for (let j = bpp; j < rowLength && i + j < out.length; j += 1) out[i + j] = (out[i + j] + out[i + j - bpp]) & 0xff
      }
      return out
    }
    // PNG predictors: each row starts with a filter-type byte.
    const rows: Uint8Array[] = []
    let previous = new Uint8Array(rowLength)
    let i = 0
    while (i < data.length) {
      const type = data[i]
      i += 1
      const row = new Uint8Array(rowLength)
      const n = Math.min(rowLength, data.length - i)
      for (let j = 0; j < n; j += 1) row[j] = data[i + j]
      i += n
      switch (type) {
        case 0: break
        case 1: for (let j = bpp; j < rowLength; j += 1) row[j] = (row[j] + row[j - bpp]) & 0xff; break
        case 2: for (let j = 0; j < rowLength; j += 1) row[j] = (row[j] + previous[j]) & 0xff; break
        case 3:
          for (let j = 0; j < rowLength; j += 1) {
            const left = j >= bpp ? row[j - bpp] : 0
            row[j] = (row[j] + Math.floor((left + previous[j]) / 2)) & 0xff
          }
          break
        case 4:
          for (let j = 0; j < rowLength; j += 1) {
            const a = j >= bpp ? row[j - bpp] : 0
            const b = previous[j]
            const c = j >= bpp ? previous[j - bpp] : 0
            const p = a + b - c
            const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c)
            const pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
            row[j] = (row[j] + pred) & 0xff
          }
          break
        default: throw new PDFError('unsupported', `PNG filter type ${type}`)
      }
      rows.push(row)
      previous = row
    }
    return Buffer.concat(rows)
  },

  /** Decodes a stream's data through its filter chain. Only what cross-
   *  reference and object streams use in practice. */
  decode(dict: PDFDict, raw: Uint8Array): Uint8Array {
    let filters: string[] = []
    let parms: (PDFDict | undefined)[] = []
    const filter = dict.get('Filter')
    if (filter?.t === 'name') {
      filters = [filter.v]
      parms = [dictOf(dict.get('DecodeParms'))]
    } else if (filter?.t === 'array') {
      filters = filter.v.map(nameOf).filter((n): n is string => n !== undefined)
      const p = arrayOf(dict.get('DecodeParms')) ?? []
      parms = filters.map((_, i) => (i < p.length ? dictOf(p[i]) : undefined))
    }
    let data = raw
    filters.forEach((f, i) => {
      if (f === 'FlateDecode' || f === 'Fl') data = Filters.unpredict(Filters.inflate(data), parms[i])
      else throw new PDFError('unsupported', `filter ${f}`)
    })
    return data
  },
}
