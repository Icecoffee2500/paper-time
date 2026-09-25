/**
 * Changes, and where a position goes through them — `LatexSuiteChanges.swift`
 * in TypeScript.
 *
 * Positions are mapped with CodeMirror's exact rules, because where a caret or
 * a tabstop lands after an edit is part of what Latex Suite does.
 */
import { isHighSurrogate, isLowSurrogate, isEmpty, slice, type Span } from './text.js'

/** A replacement inside one transaction, in the coordinates of the document before it. */
export interface Change {
  from: number
  to: number
  insert: string
}

/** A change as the public API hands it out. */
export interface PublicChange {
  from: number
  to: number
  text: string
}

export type MapMode = 'simple' | 'trackDel'

/**
 * A set of simultaneous replacements, read the way CodeMirror reads a
 * `ChangeSet`: every position refers to the document before the set.
 */
export class ChangeSet {
  /** Sorted by `from`, not overlapping. Equal positions keep their order. */
  readonly changes: Change[]

  constructor(changes: Change[]) {
    // `sort` is stable, so equal positions keep the order they came in.
    this.changes = [...changes].sort((a, b) => a.from - b.from)
  }

  static readonly empty = new ChangeSet([])

  get isEmpty(): boolean {
    return this.changes.length === 0
  }

  apply(doc: string): string {
    let out = ''
    let pos = 0
    for (const change of this.changes) {
      if (change.from > pos) out += doc.slice(pos, change.from)
      out += change.insert
      pos = Math.max(pos, change.to)
    }
    if (pos < doc.length) out += doc.slice(pos)
    return out
  }

  /**
   * `ChangeDesc.mapPos`: where `pos` goes. `assoc` < 0 keeps it before text
   * inserted exactly there, > 0 moves it after. With `trackDel`, null when the
   * position was inside replaced text.
   */
  map(pos: number, assoc: number, mode: MapMode = 'simple'): number | null {
    let posA = 0
    let posB = 0
    for (const change of this.changes) {
      // The unchanged stretch before this change.
      if (change.from > pos) return posB + (pos - posA)
      posB += change.from - posA
      posA = change.from
      const length = change.to - change.from
      const inserted = change.insert.length
      const endA = change.to
      if (mode === 'trackDel' && posA < pos && endA > pos) return null
      if (endA > pos || (endA === pos && assoc < 0 && length === 0)) {
        return pos === posA || assoc < 0 ? posB : posB + inserted
      }
      posB += inserted
      posA = endA
    }
    return posB + (pos - posA)
  }

  mapped(pos: number, assoc: number): number {
    return this.map(pos, assoc) ?? pos
  }

  /**
   * A selection range mapped the way `SelectionRange.map` does: a caret with
   * `assoc`, a range with its ends pulled inward (the start after text
   * inserted there, the end before it), whatever `assoc` says.
   */
  mapRange(range: Span, assoc: number): Span {
    if (isEmpty(range)) {
      const p = this.mapped(range.from, assoc)
      return { from: p, to: p }
    }
    const a = this.mapped(range.from, 1)
    const b = this.mapped(range.to, -1)
    return { from: Math.min(a, b), to: Math.max(a, b) }
  }
}

/**
 * `EditorSelection.create`: sorted, with overlapping ranges merged (an empty
 * range touching the previous one's end merges too).
 */
export function normalizedSelection(ranges: Span[]): Span[] {
  if (ranges.length <= 1) return ranges.map((r) => ({ ...r }))
  const sorted = ranges.map((r) => ({ ...r })).sort((a, b) => a.from - b.from)
  let i = 1
  while (i < sorted.length) {
    const range = sorted[i]
    const prev = sorted[i - 1]
    if (isEmpty(range) ? range.from <= prev.to : range.from < prev.to) {
      sorted[i - 1] = { from: prev.from, to: Math.max(range.to, prev.to) }
      sorted.splice(i, 1)
    } else {
      i += 1
    }
  }
  return sorted
}

type Piece = { original: Span } | { inserted: string }
const pieceLength = (p: Piece) => ('original' in p ? p.original.to - p.original.from : p.inserted.length)

/**
 * Folds a sequence of transactions into one list of changes against the
 * document the first one started from. Each transaction's changes are in the
 * coordinates of the document before it.
 */
export function compose(start: string, transactions: ChangeSet[]): Change[] {
  // A piece table: runs of the original text and inserted text, in order.
  const pieces: Piece[] = [{ original: { from: 0, to: start.length } }]

  const split = (pos: number): number => {
    let offset = 0
    for (let i = 0; i < pieces.length; i += 1) {
      const n = pieceLength(pieces[i])
      if (offset === pos) return i
      if (pos < offset + n) {
        const k = pos - offset
        const piece = pieces[i]
        if ('original' in piece) {
          const r = piece.original
          pieces.splice(i, 1, { original: { from: r.from, to: r.from + k } }, { original: { from: r.from + k, to: r.to } })
        } else {
          const u = piece.inserted
          pieces.splice(i, 1, { inserted: u.slice(0, k) }, { inserted: u.slice(k) })
        }
        return i + 1
      }
      offset += n
    }
    return pieces.length
  }

  for (const set of transactions) {
    // Right to left, so each change's positions are still the ones it was written in.
    for (let c = set.changes.length - 1; c >= 0; c -= 1) {
      const change = set.changes[c]
      const lower = split(change.from)
      const upper = split(change.to)
      pieces.splice(lower, upper - lower, ...(change.insert.length === 0 ? [] : [{ inserted: change.insert }]))
    }
  }

  const out: Change[] = []
  let aPos = 0
  let pending = ''
  for (const piece of pieces) {
    if (pieceLength(piece) === 0) continue
    if ('original' in piece) {
      if (piece.original.from !== aPos || pending.length > 0) {
        out.push({ from: aPos, to: piece.original.from, insert: pending })
        pending = ''
      }
      aPos = piece.original.to
    } else {
      pending += piece.inserted
    }
  }
  if (aPos !== start.length || pending.length > 0) {
    out.push({ from: aPos, to: start.length, insert: pending })
  }
  return out
}

/**
 * The changes as the public API hands them out: each one cut down to what
 * really changes, and never cutting a surrogate pair in half.
 *
 * A replacement can put back text it took away — `([^\\])(alpha)` takes the
 * character before the name and writes it again in front of `\alpha`. When that
 * character is the second half of an emoji, the plugin replaces half a pair
 * with the same half. A JavaScript string could carry that half, but an editor
 * handed half a pair would draw two broken glyphs for a moment, and the Mac
 * engine cannot hold one at all — so the two engines hand out the same changes.
 */
export function publicChanges(changes: Change[], doc: string): PublicChange[] {
  const out: PublicChange[] = []
  for (const change of changes) {
    let from = change.from
    let to = change.to
    let insert = change.insert
    let head = 0
    let tail = insert.length
    while (from < to && head < tail && doc.charCodeAt(from) === insert.charCodeAt(head)) {
      from += 1
      head += 1
    }
    while (to > from && tail > head && doc.charCodeAt(to - 1) === insert.charCodeAt(tail - 1)) {
      to -= 1
      tail -= 1
    }
    insert = insert.slice(head, tail)
    // A pair cut by the start: in the text (the high half stays, the low half
    // is replaced) or in the result (the replacement begins with the low half
    // of the high one in front).
    if (from > 0 && isHighSurrogate(doc.charCodeAt(from - 1))
      && ((from < doc.length && isLowSurrogate(doc.charCodeAt(from)))
        || (insert.length > 0 && isLowSurrogate(insert.charCodeAt(0))))) {
      from -= 1
      insert = doc[from] + insert
    }
    if (to < doc.length && isLowSurrogate(doc.charCodeAt(to))
      && ((to > from && isHighSurrogate(doc.charCodeAt(to - 1)))
        || (insert.length > 0 && isHighSurrogate(insert.charCodeAt(insert.length - 1))))) {
      insert += doc[to]
      to += 1
    }
    if (from === to && insert.length === 0) continue
    out.push({ from, to, text: insert })
  }
  return out
}

// MARK: - Overlapping specs (ChangeSet.of)

/**
 * A `ChangeSet` the way CodeMirror stores it: sections of `[length, inserted]`
 * (`inserted` -1 for text left alone), and the text each change puts in. Only
 * needed for what `ChangeSet.of` does with specs that overlap — two carets
 * inside one trigger — where the answer depends on CodeMirror's own mapping
 * rules, so they are ported as they are (`addSection`, `SectionIter`, `mapSet`).
 */
export class Sections {
  sections: number[] = []
  inserted: string[] = []

  add(len: number, ins: number, join = false) {
    if (len === 0 && ins <= 0) return
    const last = this.sections.length - 2
    if (last >= 0 && ins <= 0 && ins === this.sections[last + 1]) {
      this.sections[last] += len
    } else if (last >= 0 && len === 0 && this.sections[last] === 0) {
      this.sections[last + 1] += ins
    } else if (join && last >= 0) {
      this.sections[last] += len
      this.sections[last + 1] += ins
    } else {
      this.sections.push(len, ins)
    }
  }

  addInsert(value: string) {
    if (value.length === 0) return
    const index = (this.sections.length - 2) >> 1
    if (index < this.inserted.length) {
      this.inserted[this.inserted.length - 1] += value
    } else {
      while (this.inserted.length < index) this.inserted.push('')
      this.inserted.push(value)
    }
  }

  /** One batch of in-order, non-overlapping changes over a text of `length`. */
  static of(changes: Change[], length: number): Sections {
    const set = new Sections()
    let pos = 0
    for (const change of changes) {
      if (change.from === change.to && change.insert.length === 0) continue
      if (change.from > pos) set.add(change.from - pos, -1)
      set.add(change.to - change.from, change.insert.length)
      set.addInsert(change.insert)
      pos = change.to
    }
    if (pos < length) set.add(length - pos, -1)
    return set
  }

  /**
   * `iterChanges(…, individual: true)`: the same edit as simultaneous changes,
   * one per section — not merged, because where a caret maps to depends on the
   * boundary between two changes that touch.
   */
  get changes(): Change[] {
    const out: Change[] = []
    let posA = 0
    for (let i = 0; i < this.sections.length; i += 2) {
      const len = this.sections[i]
      const ins = this.sections[i + 1]
      const index = i >> 1
      if (ins >= 0) {
        const text = ins > 0 && index < this.inserted.length ? this.inserted[index] : ''
        out.push({ from: posA, to: posA + len, insert: text })
      }
      posA += len
    }
    return out
  }

  /** `composeSets(this, other, true)`: this set, then `other` on its result. Null where CodeMirror would throw. */
  composed(other: Sections): Sections | null {
    const result = new Sections()
    const a = new SectionIter(this)
    const b = new SectionIter(other)
    let open = false
    for (;;) {
      if (a.done && b.done) return result
      if (a.ins === 0) { // a deletion in this set
        result.add(a.len, 0, open)
        a.next()
      } else if (b.len === 0 && !b.done) { // an insertion in the other
        result.add(0, b.ins, open)
        result.addInsert(b.text)
        b.next()
      } else if (a.done || b.done) {
        return null
      } else {
        const n = Math.min(a.len2, b.len)
        const before = result.sections.length
        if (a.ins === -1) {
          const insB = b.ins === -1 ? -1 : b.off !== 0 ? 0 : b.ins
          result.add(n, insB, open)
          if (insB > 0) result.addInsert(b.text)
        } else if (b.ins === -1) {
          result.add(a.off !== 0 ? 0 : a.len, n, open)
          result.addInsert(a.textBit(n))
        } else {
          result.add(a.off !== 0 ? 0 : a.len, b.off !== 0 ? 0 : b.ins, open)
          if (b.off === 0) result.addInsert(b.text)
        }
        open = (a.ins > n || (b.ins >= 0 && b.len > n)) && (open || result.sections.length > before)
        a.forward2(n)
        b.forward(n)
      }
    }
  }

  /** `mapSet(this, other, before, true)`: this set, applied after `other`. Null where CodeMirror would throw. */
  mappedOver(other: Sections, before = false): Sections | null {
    const result = new Sections()
    const a = new SectionIter(this)
    const b = new SectionIter(other)
    let inserted = -1
    for (;;) {
      if ((a.done && b.len !== 0) || (b.done && a.len !== 0)) return null
      if (a.ins === -1 && b.ins === -1) {
        const n = Math.min(a.len, b.len)
        result.add(n, -1)
        a.forward(n)
        b.forward(n)
      } else if (b.ins >= 0 && (a.ins < 0 || inserted === a.i || (a.off === 0 && (b.len < a.len || (b.len === a.len && !before))))) {
        let n = b.len
        result.add(b.ins, -1)
        while (n > 0) {
          const piece = Math.min(a.len, n)
          if (a.ins >= 0 && inserted < a.i && a.len <= piece) {
            result.add(0, a.ins)
            result.addInsert(a.text)
            inserted = a.i
          }
          a.forward(piece)
          n -= piece
        }
        b.next()
      } else if (a.ins >= 0) {
        let n = 0
        let left = a.len
        while (left > 0) {
          if (b.ins === -1) {
            const piece = Math.min(left, b.len)
            n += piece
            left -= piece
            b.forward(piece)
          } else if (b.ins === 0 && b.len < left) {
            left -= b.len
            b.next()
          } else {
            break
          }
        }
        result.add(n, inserted < a.i ? a.ins : 0)
        if (inserted < a.i) result.addInsert(a.text)
        inserted = a.i
        a.forward(a.len - left)
      } else if (a.done && b.done) {
        return result
      } else {
        return null
      }
    }
  }
}

class SectionIter {
  i = 0
  len = 0
  ins = 0
  off = 0

  constructor(readonly set: Sections) {
    this.next()
  }

  next() {
    if (this.i < this.set.sections.length) {
      this.len = this.set.sections[this.i]
      this.ins = this.set.sections[this.i + 1]
      this.i += 2
    } else {
      this.len = 0
      this.ins = -2
    }
    this.off = 0
  }

  get done(): boolean {
    return this.ins === -2
  }

  get len2(): number {
    return this.ins < 0 ? this.len : this.ins
  }

  get text(): string {
    const index = (this.i - 2) >> 1
    return index >= this.set.inserted.length ? '' : this.set.inserted[index]
  }

  textBit(n: number): string {
    const index = (this.i - 2) >> 1
    if (index >= this.set.inserted.length) return ''
    return slice(this.set.inserted[index], this.off, this.off + n)
  }

  forward(n: number) {
    if (n === this.len) {
      this.next()
    } else {
      this.len -= n
      this.off += n
    }
  }

  forward2(n: number) {
    if (this.ins === -1) {
      this.forward(n)
    } else if (n === this.ins) {
      this.next()
    } else {
      this.ins -= n
      this.off += n
    }
  }
}

/**
 * `ChangeSet.of(specs)` for specs in the order Latex Suite queued them. In
 * order and apart, that is just the changes together; a spec that starts
 * before the previous one ended begins a new set, mapped over everything
 * before it and composed on (`total.compose(set.map(total))`).
 */
export function changeSetOf(specs: Change[], doc: string): ChangeSet {
  let total: Sections | null = null
  let batch: Change[] = []
  let pos = 0
  const flush = () => {
    if (batch.length === 0) return
    const set = Sections.of(batch, doc.length)
    if (total) {
      const mapped = set.mappedOver(total)
      const composed = mapped ? total.composed(mapped) : null
      if (composed) total = composed
    } else {
      total = set
    }
    batch = []
    pos = 0
  }
  for (const spec of specs) {
    if (spec.from === spec.to && spec.insert.length === 0) continue
    if (spec.from < pos) flush()
    batch.push(spec)
    pos = spec.to
  }
  flush()
  return new ChangeSet(total ? (total as Sections).changes : [])
}
