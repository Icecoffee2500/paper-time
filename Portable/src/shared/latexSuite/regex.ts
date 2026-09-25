/**
 * What a regex trigger can possibly match, read off its pattern once when the
 * snippets load — `LatexSuiteRegex.swift` in TypeScript.
 *
 * Every trigger is anchored at the caret, so a match ends with the key just
 * typed (or, on Tab, the character before the caret). Of the forty-nine
 * default patterns a typed letter can end at most a handful, and how far back
 * a match can start follows from the pattern too: a match is made of
 * characters its bounded parts match — at most `bounded` of them — and
 * characters its `*`, `+` and `{n,}` repeat, which all belong to `reach`. So
 * walking back from the caret, a match cannot start before the (`bounded` +
 * 1)-th character outside `reach`. Latex Suite matches against the whole
 * document before the caret; this gives the same answer from a window, which
 * matters on a long note where forty-nine patterns over twenty thousand
 * characters is most of a keystroke.
 *
 * This reads the portable dialect `Scripts/latex-suite-data.mjs` writes, not
 * regular expressions in general. Anything it does not recognise it answers
 * conservatively, so it can only make the engine run a pattern that then
 * fails, never skip one that would have matched.
 *
 * JavaScript reads the dialect natively and by code unit, which is the
 * reference behaviour, so unlike the Mac engine nothing here has to hide
 * surrogates from the regular expression.
 */
import { isASCIILetter, isDigit } from './text.js'

/** A set of UTF-16 code units: exact for ASCII, and beyond it only "maybe some". */
export class UnitSet {
  constructor(readonly bits: Uint32Array = new Uint32Array(4), public other = false) {}

  static all(): UnitSet {
    return new UnitSet(Uint32Array.from([0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff]), true)
  }

  contains(unit: number): boolean {
    if (unit < 128) return ((this.bits[unit >> 5] >>> (unit & 31)) & 1) === 1
    return this.other
  }

  insert(unit: number) {
    if (unit < 128) this.bits[unit >> 5] |= 1 << (unit & 31)
    else this.other = true
  }

  insertRange(from: number, to: number) {
    if (from > to) return
    if (to >= 128) this.other = true
    for (let u = from; u <= Math.min(to, 127); u += 1) this.insert(u)
  }

  union(o: UnitSet): UnitSet {
    const bits = new Uint32Array(4)
    for (let k = 0; k < 4; k += 1) bits[k] = this.bits[k] | o.bits[k]
    return new UnitSet(bits, this.other || o.other)
  }

  /** The complement: every ASCII unit not in the set, and (not knowing which) all of the rest. */
  inverted(): UnitSet {
    const bits = new Uint32Array(4)
    for (let k = 0; k < 4; k += 1) bits[k] = ~this.bits[k] >>> 0
    return new UnitSet(bits, true)
  }

  equals(o: UnitSet): boolean {
    return this.other === o.other && this.bits.every((b, k) => b === o.bits[k])
  }
}

interface ShapeNode {
  nullable: boolean
  /** Null when unbounded. */
  maxLength: number | null
  last: UnitSet
  /** Every unit this can match anywhere. */
  chars: UnitSet
  bounded: number
  reach: UnitSet
}

/** A lookaround: it matches nothing. */
const emptyNode = (): ShapeNode => ({ nullable: true, maxLength: 0, last: new UnitSet(), chars: new UnitSet(), bounded: 0, reach: new UnitSet() })
const unknownNode = (): ShapeNode => ({ nullable: true, maxLength: null, last: UnitSet.all(), chars: UnitSet.all(), bounded: 0, reach: UnitSet.all() })
const unitNode = (set: UnitSet): ShapeNode => ({ nullable: false, maxLength: 1, last: set, chars: set, bounded: 1, reach: new UnitSet() })

export class PatternShape {
  /** The longest match in UTF-16 units, or null when it is unbounded. */
  readonly maxLength: number | null
  /** The units a match can end with, or null when the pattern can match the empty string. */
  readonly last: UnitSet | null
  /** At most this many characters of a match lie outside `reach`. */
  readonly bounded: number
  /** Every character a repeat without an upper bound can take. */
  readonly reach: UnitSet
  /** How many characters in front of the window a lookbehind may read (Infinity: anything). */
  readonly behind: number

  constructor(pattern: string) {
    const parser = new ShapeParser(pattern)
    const node = parser.alternation()
    if (parser.failed || parser.i !== pattern.length) {
      this.maxLength = null
      this.last = UnitSet.all()
      this.bounded = 0
      this.reach = UnitSet.all()
      this.behind = Infinity
      return
    }
    this.maxLength = node.maxLength
    this.last = node.nullable ? null : node.last
    this.bounded = node.bounded
    this.reach = node.reach
    this.behind = parser.behind
  }
}

class ShapeParser {
  i = 0
  failed = false
  behind = 0

  constructor(readonly units: string) {}

  peek(k = 0): number | null {
    return this.i + k < this.units.length ? this.units.charCodeAt(this.i + k) : null
  }

  alternation(): ShapeNode {
    const branches = [this.sequence()]
    while (this.peek() === 124) { // |
      this.i += 1
      branches.push(this.sequence())
    }
    if (branches.length === 1) return branches[0]
    return {
      nullable: branches.some((b) => b.nullable),
      maxLength: branches.every((b) => b.maxLength !== null) ? Math.max(...branches.map((b) => b.maxLength as number)) : null,
      last: branches.reduce((s, b) => s.union(b.last), new UnitSet()),
      chars: branches.reduce((s, b) => s.union(b.chars), new UnitSet()),
      bounded: Math.max(0, ...branches.map((b) => b.bounded)),
      reach: branches.reduce((s, b) => s.union(b.reach), new UnitSet()),
    }
  }

  sequence(): ShapeNode {
    const items: ShapeNode[] = []
    for (;;) {
      const c = this.peek()
      if (c === null || c === 124 || c === 41) break // | )
      const atom = this.atom()
      if (!atom) return unknownNode()
      items.push(this.quantified(atom))
      if (this.failed) return unknownNode()
    }
    let last = new UnitSet()
    for (let k = items.length - 1; k >= 0; k -= 1) {
      last = last.union(items[k].last)
      if (!items[k].nullable) break
    }
    let length: number | null = 0
    for (const item of items) {
      length = length !== null && item.maxLength !== null ? length + item.maxLength : null
    }
    return {
      nullable: items.every((item) => item.nullable),
      maxLength: length,
      last,
      chars: items.reduce((s, item) => s.union(item.chars), new UnitSet()),
      bounded: items.reduce((n, item) => n + item.bounded, 0),
      reach: items.reduce((s, item) => s.union(item.reach), new UnitSet()),
    }
  }

  quantified(atom: ShapeNode): ShapeNode {
    const c = this.peek()
    if (c === null) return atom
    let min = 1
    let max: number | null = 1
    switch (c) {
      case 42: min = 0; max = null; this.i += 1; break // *
      case 43: min = 1; max = null; this.i += 1; break // +
      case 63: min = 0; max = 1; this.i += 1; break // ?
      case 123: { // {n}, {n,}, {n,m}
        let j = this.i + 1
        let n = 0
        let digits = 0
        while (j < this.units.length && isDigit(this.units.charCodeAt(j))) {
          n = n * 10 + this.units.charCodeAt(j) - 48
          j += 1
          digits += 1
        }
        if (digits === 0) {
          this.failed = true
          return atom
        }
        min = n
        max = n
        if (j < this.units.length && this.units.charCodeAt(j) === 44) { // ,
          j += 1
          let m = 0
          let mDigits = 0
          while (j < this.units.length && isDigit(this.units.charCodeAt(j))) {
            m = m * 10 + this.units.charCodeAt(j) - 48
            j += 1
            mDigits += 1
          }
          max = mDigits > 0 ? m : null
        }
        if (!(j < this.units.length && this.units.charCodeAt(j) === 125)) {
          this.failed = true
          return atom
        }
        this.i = j + 1
        break
      }
      default:
        return atom
    }
    if (this.peek() === 63) this.i += 1 // lazy
    const nullable = min === 0 || atom.nullable
    if (max === null) {
      // Unbounded: whatever it repeats is reach, however often.
      return {
        nullable,
        maxLength: atom.maxLength === 0 ? 0 : null,
        last: atom.last,
        chars: atom.chars,
        bounded: 0,
        reach: atom.reach.union(atom.chars),
      }
    }
    return {
      nullable,
      maxLength: atom.maxLength === null ? null : atom.maxLength * max,
      last: max === 0 ? new UnitSet() : atom.last,
      chars: max === 0 ? new UnitSet() : atom.chars,
      bounded: atom.bounded * max,
      reach: atom.reach,
    }
  }

  atom(): ShapeNode | null {
    const c = this.peek()
    if (c === null) return null
    switch (c) {
      case 40: { // (
        this.i += 1
        let look = false
        let lookBehind = false
        if (this.peek() === 63) { // ?
          if (this.peek(1) === 58) {
            this.i += 2 // (?:
          } else if (this.peek(1) === 61 || this.peek(1) === 33) {
            this.i += 2 // (?= (?!
            look = true
          } else if (this.peek(1) === 60 && (this.peek(2) === 61 || this.peek(2) === 33)) {
            this.i += 3 // (?<= (?<!
            look = true
            lookBehind = true
          } else {
            this.failed = true
            return null
          }
        }
        const inner = this.alternation()
        if (this.peek() !== 41) {
          this.failed = true
          return null
        }
        this.i += 1
        if (lookBehind) this.behind = Math.max(this.behind, inner.maxLength ?? Infinity)
        return look ? emptyNode() : inner
      }
      case 91: // [
        return unitNode(this.characterClass())
      case 92: // \
        return this.escape()
      case 46: case 94: case 36: // . ^ $ do not occur in the dialect
        this.failed = true
        return null
      default: {
        this.i += 1
        const set = new UnitSet()
        set.insert(c)
        return unitNode(set)
      }
    }
  }

  escape(): ShapeNode {
    this.i += 1
    const c = this.peek()
    if (c === null) {
      this.failed = true
      return unknownNode()
    }
    this.i += 1
    const set = new UnitSet()
    switch (c) {
      case 110: set.insert(10); break // \n
      case 114: set.insert(13); break // \r
      case 116: set.insert(9); break // \t
      case 117: { // \uXXXX
        const u = this.hex4()
        if (u === null) {
          this.failed = true
          return unknownNode()
        }
        set.insert(u)
        break
      }
      default:
        // A backreference or a class escape: the dialect has none, and
        // guessing what one spans could skip a pattern that matches.
        if (isASCIILetter(c) || isDigit(c)) {
          this.failed = true
          return unknownNode()
        }
        set.insert(c)
    }
    return unitNode(set)
  }

  hex4(): number | null {
    if (this.i + 4 > this.units.length) return null
    const digits = this.units.slice(this.i, this.i + 4)
    if (!/^[0-9A-Fa-f]{4}$/.test(digits)) return null
    this.i += 4
    return parseInt(digits, 16)
  }

  /** One class member: a unit, `'unknown'` for an escape only a whole class can mean, null at the end. */
  classUnit(): number | 'unknown' | null {
    const c = this.peek()
    if (c === null) {
      this.failed = true
      return null
    }
    if (c !== 92) {
      this.i += 1
      return c
    }
    this.i += 1
    const e = this.peek()
    if (e === null) {
      this.failed = true
      return null
    }
    this.i += 1
    switch (e) {
      case 110: return 10
      case 114: return 13
      case 116: return 9
      case 117: return this.hex4() ?? 'unknown'
      default:
        if (isASCIILetter(e) || isDigit(e)) return 'unknown'
        return e
    }
  }

  characterClass(): UnitSet {
    this.i += 1
    let negated = false
    if (this.peek() === 94) {
      negated = true
      this.i += 1
    }
    const set = new UnitSet()
    let unknown = false
    while (this.peek() !== null && this.peek() !== 93) {
      const first = this.classUnit()
      if (first === null) return UnitSet.all()
      const next = this.peek(1)
      if (this.peek() === 45 && next !== null && next !== 93) { // a-b
        this.i += 1
        const second = this.classUnit()
        if (second === null) return UnitSet.all()
        if (first !== 'unknown' && second !== 'unknown') set.insertRange(first, second)
        else unknown = true
      } else if (first !== 'unknown') {
        set.insert(first)
      } else {
        unknown = true
      }
    }
    if (this.peek() !== 93) {
      this.failed = true
      return UnitSet.all()
    }
    this.i += 1
    if (unknown) return UnitSet.all()
    return negated ? set.inverted() : set
  }
}

export interface RegexMatch {
  index: number
  whole: string
  /** The capture groups (index 0 is the first group), null for one that did not take part. */
  groups: (string | null)[]
  /** The same groups as document ranges. */
  groupRanges: ({ from: number; to: number } | null)[]
  named: Map<string, string>
}

/**
 * The text a regex trigger is matched against: everything from the start of
 * the document to the caret, plus the key — shown to the pattern only as far
 * back as its shape says it can reach, with as many characters in front as
 * its lookbehinds read (one, for the rewritten `^` and `\b`).
 */
export class RegexInput {
  constructor(readonly doc: string, readonly to: number, readonly key: string) {}

  /** The length of the text the trigger is matched against. */
  get count(): number {
    return this.to + this.key.length
  }

  unit(i: number): number {
    return i < this.to ? this.doc.charCodeAt(i) : this.key.charCodeAt(i - this.to)
  }

  /** Where a match of `shape` can start at the earliest. */
  windowStart(shape: PatternShape): number {
    const count = this.count
    if (shape.maxLength !== null) return Math.max(0, count - shape.maxLength)
    let outside = 0
    let i = count
    while (i > 0) {
      if (!shape.reach.contains(this.unit(i - 1))) {
        outside += 1
        if (outside > shape.bounded) break
      }
      i -= 1
    }
    return i
  }

  /** `regex` must carry the `g` and `d` flags: the search starts at the window, and the captures come with their offsets. */
  match(regex: RegExp, shape: PatternShape, groupNames: (string | null)[]): RegexMatch | null {
    const count = this.count
    if (shape.last) {
      if (count === 0) return null
      if (!shape.last.contains(this.unit(count - 1))) return null
    }
    const start = this.windowStart(shape)
    const base = shape.behind === Infinity ? 0 : Math.max(0, start - shape.behind)
    const text = (base < this.to ? this.doc.slice(base, this.to) : '') + this.key.slice(Math.max(0, base - this.to))
    regex.lastIndex = start - base
    const m = regex.exec(text) as (RegExpExecArray & { indices?: [number, number][] }) | null
    if (!m) return null
    const groups: (string | null)[] = []
    const ranges: ({ from: number; to: number } | null)[] = []
    const named = new Map<string, string>()
    for (let g = 1; g < m.length; g += 1) {
      const value = m[g] === undefined ? null : m[g]
      const at = m.indices?.[g]
      groups.push(value)
      ranges.push(value !== null && at ? { from: base + at[0], to: base + at[1] } : null)
      const name = groupNames[g - 1]
      if (name) named.set(name, value ?? '')
    }
    return { index: base + m.index, whole: m[0], groups, groupRanges: ranges, named }
  }
}
