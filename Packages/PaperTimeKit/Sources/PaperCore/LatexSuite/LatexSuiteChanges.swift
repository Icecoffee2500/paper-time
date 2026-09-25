import Foundation

/// A replacement inside one transaction, in the coordinates of the document
/// before that transaction.
struct LSChange {
    var from: Int
    var to: Int
    var insert: LSUnits
}

/// A set of simultaneous replacements, read the way CodeMirror reads a
/// `ChangeSet`: every position refers to the document before the set, and
/// positions are mapped with CodeMirror's exact rules, because where a caret
/// or a tabstop lands after an edit is part of what Latex Suite does.
struct LSChangeSet {
    /// Sorted by `from`, not overlapping. Equal positions keep their order.
    private(set) var changes: [LSChange]

    init(_ changes: [LSChange]) {
        self.changes = changes.enumerated()
            .sorted { $0.element.from != $1.element.from ? $0.element.from < $1.element.from : $0.offset < $1.offset }
            .map(\.element)
    }

    static let empty = LSChangeSet([])

    var isEmpty: Bool { changes.isEmpty }

    func apply(_ doc: LSUnits) -> LSUnits {
        var out = LSUnits()
        out.reserveCapacity(doc.count + changes.reduce(0) { $0 + $1.insert.count })
        var pos = 0
        for change in changes {
            if change.from > pos { out += doc[pos..<change.from] }
            out += change.insert
            pos = Swift.max(pos, change.to)
        }
        if pos < doc.count { out += doc[pos...] }
        return out
    }

    enum MapMode { case simple, trackDel }

    /// `ChangeDesc.mapPos`: where `pos` goes. `assoc` < 0 keeps it before text
    /// inserted exactly there, > 0 moves it after. With `.trackDel`, nil when
    /// the position was inside replaced text.
    func map(_ pos: Int, assoc: Int, mode: MapMode = .simple) -> Int? {
        var posA = 0
        var posB = 0
        for change in changes {
            // The unchanged stretch before this change.
            if change.from > pos { return posB + (pos - posA) }
            posB += change.from - posA
            posA = change.from
            let length = change.to - change.from
            let inserted = change.insert.count
            let endA = change.to
            if mode == .trackDel && posA < pos && endA > pos { return nil }
            if endA > pos || (endA == pos && assoc < 0 && length == 0) {
                return pos == posA || assoc < 0 ? posB : posB + inserted
            }
            posB += inserted
            posA = endA
        }
        return posB + (pos - posA)
    }

    func mapped(_ pos: Int, assoc: Int) -> Int { map(pos, assoc: assoc) ?? pos }

    /// A selection range mapped the way `SelectionRange.map` does: a caret
    /// with `assoc`, a range with its ends pulled inward (the start after text
    /// inserted there, the end before it), whatever `assoc` says.
    func map(_ range: Range<Int>, assoc: Int) -> Range<Int> {
        if range.isEmpty {
            let p = mapped(range.lowerBound, assoc: assoc)
            return p..<p
        }
        let a = mapped(range.lowerBound, assoc: 1)
        let b = mapped(range.upperBound, assoc: -1)
        return Swift.min(a, b)..<Swift.max(a, b)
    }
}

/// `EditorSelection.create`: sorted, with overlapping ranges merged (an empty
/// range touching the previous one's end merges too).
func lsNormalizedSelection(_ ranges: [Range<Int>]) -> [Range<Int>] {
    guard ranges.count > 1 else { return ranges }
    var sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    var i = 1
    while i < sorted.count {
        let range = sorted[i]
        let prev = sorted[i - 1]
        if range.isEmpty ? range.lowerBound <= prev.upperBound : range.lowerBound < prev.upperBound {
            sorted[i - 1] = prev.lowerBound..<Swift.max(range.upperBound, prev.upperBound)
            sorted.remove(at: i)
        } else {
            i += 1
        }
    }
    return sorted
}

/// Folds a sequence of transactions into one list of changes against the
/// document the first one started from. Each transaction's changes are in
/// the coordinates of the document before it.
func lsCompose(_ start: LSUnits, _ transactions: [LSChangeSet]) -> [LSChange] {
    // A piece table: runs of the original text and inserted text, in order.
    enum Piece {
        case original(Range<Int>)
        case inserted(LSUnits)
        var count: Int {
            switch self {
            case let .original(r): return r.count
            case let .inserted(u): return u.count
            }
        }
    }
    var pieces: [Piece] = [.original(0..<start.count)]

    func split(_ pieces: inout [Piece], at pos: Int) -> Int {
        var offset = 0
        var i = 0
        while i < pieces.count {
            let n = pieces[i].count
            if offset == pos { return i }
            if pos < offset + n {
                let k = pos - offset
                switch pieces[i] {
                case let .original(r):
                    pieces[i] = .original(r.lowerBound..<(r.lowerBound + k))
                    pieces.insert(.original((r.lowerBound + k)..<r.upperBound), at: i + 1)
                case let .inserted(u):
                    pieces[i] = .inserted(Array(u[0..<k]))
                    pieces.insert(.inserted(Array(u[k...])), at: i + 1)
                }
                return i + 1
            }
            offset += n
            i += 1
        }
        return pieces.count
    }

    for set in transactions {
        // Right to left, so each change's positions are still the ones it was written in.
        for change in set.changes.reversed() {
            let lower = split(&pieces, at: change.from)
            let upper = split(&pieces, at: change.to)
            pieces.replaceSubrange(lower..<upper, with: change.insert.isEmpty ? [] : [.inserted(change.insert)])
        }
    }

    var out: [LSChange] = []
    var aPos = 0
    var pending = LSUnits()
    for piece in pieces where piece.count > 0 {
        switch piece {
        case let .original(r):
            if r.lowerBound != aPos || !pending.isEmpty {
                out.append(LSChange(from: aPos, to: r.lowerBound, insert: pending))
                pending = []
            }
            aPos = r.upperBound
        case let .inserted(u):
            pending += u
        }
    }
    if aPos != start.count || !pending.isEmpty {
        out.append(LSChange(from: aPos, to: start.count, insert: pending))
    }
    return out
}

/// The changes as the public API hands them out: each one cut down to what
/// really changes, and never cutting a surrogate pair in half.
///
/// A replacement can put back text it took away — `([^\\])(alpha)` takes the
/// character before the name and writes it again in front of `\alpha`. When
/// that character is the second half of an emoji, the JavaScript plugin
/// replaces half a pair with the same half and nothing is lost; a Swift
/// `String` cannot hold half a pair, so the change would carry U+FFFD instead.
/// Trimming what the text and the replacement share leaves the pair alone,
/// and where a change still starts or ends inside a pair, it takes the whole
/// pair.
func lsPublicChanges(_ changes: [LSChange], in doc: LSUnits) -> [LatexSuite.Change] {
    @inline(__always) func isHigh(_ u: UInt16) -> Bool { u & 0xFC00 == 0xD800 }
    @inline(__always) func isLow(_ u: UInt16) -> Bool { u & 0xFC00 == 0xDC00 }
    return changes.compactMap { change in
        var from = change.from
        var to = change.to
        var insert = change.insert[...]
        while from < to, let first = insert.first, doc[from] == first {
            from += 1
            insert = insert.dropFirst()
        }
        while to > from, let last = insert.last, doc[to - 1] == last {
            to -= 1
            insert = insert.dropLast()
        }
        var units = LSUnits(insert)
        // A pair cut by the start: in the text (the high half stays, the low
        // half is replaced) or in the result (the replacement begins with the
        // low half of the high one in front).
        if from > 0, isHigh(doc[from - 1]), (from < doc.count && isLow(doc[from])) || units.first.map(isLow) == true {
            from -= 1
            units.insert(doc[from], at: 0)
        }
        if to < doc.count, isLow(doc[to]), (to > from && isHigh(doc[to - 1])) || units.last.map(isHigh) == true {
            units.append(doc[to])
            to += 1
        }
        if from == to && units.isEmpty { return nil }
        return LatexSuite.Change(range: NSRange(ls: from, to), text: units.string)
    }
}

// MARK: - Overlapping specs (ChangeSet.of)

/// A `ChangeSet` the way CodeMirror stores it: sections of `[length, inserted]`
/// (`inserted` -1 for text left alone), and the text each change puts in.
/// Only needed for what `ChangeSet.of` does with specs that overlap — two
/// carets inside one trigger — where the answer depends on CodeMirror's own
/// mapping rules, so they are ported as they are (`addSection`,
/// `SectionIter`, `mapSet`).
struct LSSections {
    var sections: [Int] = []
    var inserted: [LSUnits] = []

    mutating func add(_ len: Int, _ ins: Int, join: Bool = false) {
        if len == 0 && ins <= 0 { return }
        let last = sections.count - 2
        if last >= 0 && ins <= 0 && ins == sections[last + 1] {
            sections[last] += len
        } else if last >= 0 && len == 0 && sections[last] == 0 {
            sections[last + 1] += ins
        } else if join && last >= 0 {
            sections[last] += len
            sections[last + 1] += ins
        } else {
            sections += [len, ins]
        }
    }

    mutating func addInsert(_ value: LSUnits) {
        if value.isEmpty { return }
        let index = (sections.count - 2) >> 1
        if index < inserted.count {
            inserted[inserted.count - 1] += value
        } else {
            while inserted.count < index { inserted.append([]) }
            inserted.append(value)
        }
    }

    /// One batch of in-order, non-overlapping changes over a text of `length`.
    init(_ changes: [LSChange], length: Int) {
        var pos = 0
        for change in changes {
            if change.from == change.to && change.insert.isEmpty { continue }
            if change.from > pos { add(change.from - pos, -1) }
            add(change.to - change.from, change.insert.count)
            addInsert(change.insert)
            pos = change.to
        }
        if pos < length { add(length - pos, -1) }
    }

    private init() {}

    /// `iterChanges(…, individual: true)`: the same edit as simultaneous
    /// changes, one per section — not merged, because where a caret maps to
    /// depends on the boundary between two changes that touch.
    var changes: [LSChange] {
        var out: [LSChange] = []
        var posA = 0
        var i = 0
        while i < sections.count {
            let len = sections[i]
            let ins = sections[i + 1]
            let index = i >> 1
            i += 2
            if ins >= 0 {
                let text = ins > 0 && index < inserted.count ? inserted[index] : []
                out.append(LSChange(from: posA, to: posA + len, insert: text))
            }
            posA += len
        }
        return out
    }

    private struct Iter {
        let set: LSSections
        var i = 0
        var len = 0
        var ins = 0
        var off = 0

        init(_ set: LSSections) {
            self.set = set
            next()
        }

        mutating func next() {
            if i < set.sections.count {
                len = set.sections[i]
                ins = set.sections[i + 1]
                i += 2
            } else {
                len = 0
                ins = -2
            }
            off = 0
        }

        var done: Bool { ins == -2 }
        var len2: Int { ins < 0 ? len : ins }
        var text: LSUnits {
            let index = (i - 2) >> 1
            return index >= set.inserted.count ? [] : set.inserted[index]
        }

        func textBit(_ n: Int) -> LSUnits {
            let index = (i - 2) >> 1
            if index >= set.inserted.count { return [] }
            return set.inserted[index].slice(off, off + n)
        }

        mutating func forward(_ n: Int) {
            if n == len { next() } else {
                len -= n
                off += n
            }
        }

        mutating func forward2(_ n: Int) {
            if ins == -1 {
                forward(n)
            } else if n == ins {
                next()
            } else {
                ins -= n
                off += n
            }
        }
    }

    /// `composeSets(this, other, true)`: this set, then `other` on its result.
    /// Nil where CodeMirror would throw.
    func composed(with other: LSSections) -> LSSections? {
        var result = LSSections()
        var a = Iter(self)
        var b = Iter(other)
        var open = false
        while true {
            if a.done && b.done { return result }
            if a.ins == 0 { // a deletion in this set
                result.add(a.len, 0, join: open)
                a.next()
            } else if b.len == 0 && !b.done { // an insertion in the other
                result.add(0, b.ins, join: open)
                result.addInsert(b.text)
                b.next()
            } else if a.done || b.done {
                return nil
            } else {
                let n = Swift.min(a.len2, b.len)
                let before = result.sections.count
                if a.ins == -1 {
                    let insB = b.ins == -1 ? -1 : b.off != 0 ? 0 : b.ins
                    result.add(n, insB, join: open)
                    if insB > 0 { result.addInsert(b.text) }
                } else if b.ins == -1 {
                    result.add(a.off != 0 ? 0 : a.len, n, join: open)
                    result.addInsert(a.textBit(n))
                } else {
                    result.add(a.off != 0 ? 0 : a.len, b.off != 0 ? 0 : b.ins, join: open)
                    if b.off == 0 { result.addInsert(b.text) }
                }
                open = (a.ins > n || (b.ins >= 0 && b.len > n)) && (open || result.sections.count > before)
                a.forward2(n)
                b.forward(n)
            }
        }
    }

    /// `mapSet(this, other, before, true)`: this set, applied after `other`.
    /// Nil where CodeMirror would throw (sets of different lengths).
    func mapped(over other: LSSections, before: Bool = false) -> LSSections? {
        var result = LSSections()
        var a = Iter(self)
        var b = Iter(other)
        var inserted = -1
        while true {
            if (a.done && b.len != 0) || (b.done && a.len != 0) { return nil }
            if a.ins == -1 && b.ins == -1 {
                let n = Swift.min(a.len, b.len)
                result.add(n, -1)
                a.forward(n)
                b.forward(n)
            } else if b.ins >= 0 && (a.ins < 0 || inserted == a.i || (a.off == 0 && (b.len < a.len || (b.len == a.len && !before)))) {
                var n = b.len
                result.add(b.ins, -1)
                while n > 0 {
                    let piece = Swift.min(a.len, n)
                    if a.ins >= 0 && inserted < a.i && a.len <= piece {
                        result.add(0, a.ins)
                        result.addInsert(a.text)
                        inserted = a.i
                    }
                    a.forward(piece)
                    n -= piece
                }
                b.next()
            } else if a.ins >= 0 {
                var n = 0
                var left = a.len
                while left > 0 {
                    if b.ins == -1 {
                        let piece = Swift.min(left, b.len)
                        n += piece
                        left -= piece
                        b.forward(piece)
                    } else if b.ins == 0 && b.len < left {
                        left -= b.len
                        b.next()
                    } else {
                        break
                    }
                }
                result.add(n, inserted < a.i ? a.ins : 0)
                if inserted < a.i { result.addInsert(a.text) }
                inserted = a.i
                a.forward(a.len - left)
            } else if a.done && b.done {
                return result
            } else {
                return nil
            }
        }
    }
}

/// `ChangeSet.of(specs)` for specs in the order Latex Suite queued them. In
/// order and apart, that is just the changes together; a spec that starts
/// before the previous one ended begins a new set, mapped over everything
/// before it and composed on (`total.compose(set.map(total))`).
func lsChangeSetOf(_ specs: [LSChange], in doc: LSUnits) -> LSChangeSet {
    var total: LSSections?
    var batch: [LSChange] = []
    var pos = 0
    func flush() {
        guard !batch.isEmpty else { return }
        let set = LSSections(batch, length: doc.count)
        if let done = total {
            if let mapped = set.mapped(over: done), let composed = done.composed(with: mapped) { total = composed }
        } else {
            total = set
        }
        batch = []
        pos = 0
    }
    for spec in specs {
        if spec.from == spec.to && spec.insert.isEmpty { continue }
        if spec.from < pos { flush() }
        batch.append(spec)
        pos = spec.to
    }
    flush()
    return LSChangeSet(total?.changes ?? [])
}
