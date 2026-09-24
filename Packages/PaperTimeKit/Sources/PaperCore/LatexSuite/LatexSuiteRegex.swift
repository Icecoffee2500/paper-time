import Foundation

/// What a regex trigger can possibly match, read off its pattern once when the
/// snippets load, so that most triggers are never run on a keystroke and the
/// rest only look at the few characters they can reach.
///
/// Every trigger is anchored at the caret, so a match ends with the key just
/// typed (or, on Tab, the character before the caret). Of the forty-nine
/// default patterns, a typed letter can end at most a handful, and asking ICU
/// about the others cost three microseconds apiece — most of a keystroke.
///
/// How far back a match can start follows from the pattern too. A match is
/// made of characters its bounded parts match — at most `bounded` of them —
/// and characters its `*`, `+` and `{n,}` repeat, which all belong to `reach`.
/// So walking back from the caret, a match cannot start before the
/// (`bounded` + 1)-th character outside `reach`: `\\[A-Za-z]{2,}` looks back
/// over letters and one backslash, not over the whole line. Latex Suite
/// matches against the whole document before the caret; this gives the same
/// answer from a window, without assuming anything about lines.
///
/// This reads the portable dialect `Scripts/latex-suite-data.mjs` writes (see
/// the snippet file's header), not regular expressions in general. Anything it
/// does not recognise it answers conservatively — "could end with anything",
/// "could reach back to the start" — so what it says can only make the engine
/// run a pattern that then fails, never skip one that would have matched.
struct LSPatternShape: Equatable {
    /// A set of UTF-16 code units: exact for ASCII, and beyond it only
    /// "maybe some" — which every use here reads as "yes".
    struct UnitSet: Equatable {
        var low: UInt64 = 0
        var high: UInt64 = 0
        /// Whether anything at or above U+0080 may be in the set.
        var other = false

        static let all = UnitSet(low: .max, high: .max, other: true)

        func contains(_ unit: UInt16) -> Bool {
            if unit < 64 { return low & (1 << UInt64(unit)) != 0 }
            if unit < 128 { return high & (1 << UInt64(unit - 64)) != 0 }
            return other
        }

        mutating func insert(_ unit: UInt16) {
            if unit < 64 { low |= 1 << UInt64(unit) } else if unit < 128 { high |= 1 << UInt64(unit - 64) } else { other = true }
        }

        mutating func insert(_ from: UInt16, through to: UInt16) {
            guard from <= to else { return }
            if to >= 128 { other = true }
            var u = from
            while u <= Swift.min(to, 127) {
                insert(u)
                u += 1
            }
        }

        func union(_ o: UnitSet) -> UnitSet { UnitSet(low: low | o.low, high: high | o.high, other: other || o.other) }
        /// The complement: every ASCII unit not in the set, and (not knowing
        /// which) all of the rest.
        var inverted: UnitSet { UnitSet(low: ~low, high: ~high, other: true) }
    }

    /// The longest match in UTF-16 units, or nil when it is unbounded.
    var maxLength: Int?
    /// The units a match can end with, or nil when the pattern can match the
    /// empty string (then there is nothing to test).
    var last: UnitSet?
    /// At most this many characters of a match lie outside `reach`.
    var bounded: Int
    /// Every character a repeat without an upper bound can take.
    var reach: UnitSet
    /// How many characters in front of the window a lookbehind may read
    /// (`Int.max`: it could read anything).
    var behind: Int

    init(pattern: String) {
        var parser = Parser(units: LS.units(pattern))
        let node = parser.alternation()
        if parser.failed || parser.i != parser.units.count {
            maxLength = nil
            last = .all
            bounded = 0
            reach = .all
            behind = .max
            return
        }
        maxLength = node.maxLength
        last = node.nullable ? nil : node.last
        bounded = node.bounded
        reach = node.reach
        behind = parser.behind
    }

    // MARK: The reading

    private struct Node {
        var nullable: Bool
        var maxLength: Int?
        var last: UnitSet
        /// Every unit this can match anywhere.
        var chars: UnitSet
        var bounded: Int
        var reach: UnitSet

        /// A lookaround: it matches nothing.
        static let empty = Node(nullable: true, maxLength: 0, last: UnitSet(), chars: UnitSet(), bounded: 0, reach: UnitSet())
        static let unknown = Node(nullable: true, maxLength: nil, last: .all, chars: .all, bounded: 0, reach: .all)
        static func unit(_ set: UnitSet) -> Node {
            Node(nullable: false, maxLength: 1, last: set, chars: set, bounded: 1, reach: UnitSet())
        }
    }

    private struct Parser {
        let units: LSUnits
        var i = 0
        var failed = false
        var behind = 0

        init(units: LSUnits) { self.units = units }

        func peek(_ k: Int = 0) -> UInt16? { i + k < units.count ? units[i + k] : nil }

        mutating func alternation() -> Node {
            var branches = [sequence()]
            while peek() == 124 { // |
                i += 1
                branches.append(sequence())
            }
            guard branches.count > 1 else { return branches[0] }
            return Node(nullable: branches.contains { $0.nullable },
                        maxLength: branches.allSatisfy { $0.maxLength != nil } ? branches.map { $0.maxLength! }.max() : nil,
                        last: branches.reduce(UnitSet()) { $0.union($1.last) },
                        chars: branches.reduce(UnitSet()) { $0.union($1.chars) },
                        bounded: branches.map(\.bounded).max() ?? 0,
                        reach: branches.reduce(UnitSet()) { $0.union($1.reach) })
        }

        mutating func sequence() -> Node {
            var items: [Node] = []
            while let c = peek(), c != 124, c != 41 { // | )
                guard let atom = atom() else { return .unknown }
                items.append(quantified(atom))
                if failed { return .unknown }
            }
            var last = UnitSet()
            for item in items.reversed() {
                last = last.union(item.last)
                if !item.nullable { break }
            }
            var length: Int? = 0
            for item in items {
                if let l = length, let m = item.maxLength { length = l + m } else { length = nil }
            }
            return Node(nullable: items.allSatisfy(\.nullable), maxLength: length, last: last,
                        chars: items.reduce(UnitSet()) { $0.union($1.chars) },
                        bounded: items.reduce(0) { $0 + $1.bounded },
                        reach: items.reduce(UnitSet()) { $0.union($1.reach) })
        }

        mutating func quantified(_ atom: Node) -> Node {
            guard let c = peek() else { return atom }
            var min = 1
            var max: Int? = 1
            switch c {
            case 42: min = 0; max = nil; i += 1 // *
            case 43: min = 1; max = nil; i += 1 // +
            case 63: min = 0; max = 1; i += 1 // ?
            case 123: // {n}, {n,}, {n,m}
                var j = i + 1
                var n = 0
                var digits = 0
                while j < units.count, LS.isDigit(Int(units[j])) { n = n * 10 + Int(units[j]) - 48; j += 1; digits += 1 }
                guard digits > 0 else { failed = true; return atom }
                min = n
                max = n
                if j < units.count, units[j] == 44 { // ,
                    j += 1
                    var m = 0
                    var mDigits = 0
                    while j < units.count, LS.isDigit(Int(units[j])) { m = m * 10 + Int(units[j]) - 48; j += 1; mDigits += 1 }
                    max = mDigits > 0 ? m : nil
                }
                guard j < units.count, units[j] == 125 else { failed = true; return atom }
                i = j + 1
            default:
                return atom
            }
            if peek() == 63 { i += 1 } // lazy
            let nullable = min == 0 || atom.nullable
            guard let max else {
                // Unbounded: whatever it repeats is reach, however often.
                return Node(nullable: nullable, maxLength: atom.maxLength == 0 ? 0 : nil, last: atom.last,
                            chars: atom.chars, bounded: 0, reach: atom.reach.union(atom.chars))
            }
            return Node(nullable: nullable, maxLength: atom.maxLength.map { $0 * max },
                        last: max == 0 ? UnitSet() : atom.last, chars: max == 0 ? UnitSet() : atom.chars,
                        bounded: atom.bounded * max, reach: atom.reach)
        }

        mutating func atom() -> Node? {
            guard let c = peek() else { return nil }
            switch c {
            case 40: // (
                i += 1
                var look = false
                var lookBehind = false
                if peek() == 63 { // ?
                    if peek(1) == 58 { i += 2 } // (?:
                    else if peek(1) == 61 || peek(1) == 33 { i += 2; look = true } // (?= (?!
                    else if peek(1) == 60, peek(2) == 61 || peek(2) == 33 { i += 3; look = true; lookBehind = true } // (?<= (?<!
                    else { failed = true; return nil }
                }
                let inner = alternation()
                guard peek() == 41 else { failed = true; return nil }
                i += 1
                if lookBehind { behind = Swift.max(behind, inner.maxLength ?? .max) }
                return look ? .empty : inner
            case 91: // [
                return .unit(characterClass())
            case 92: // \
                return escape()
            case 46, 94, 36: // . ^ $ do not occur in the dialect
                failed = true
                return nil
            default:
                i += 1
                var set = UnitSet()
                set.insert(c)
                return .unit(set)
            }
        }

        mutating func escape() -> Node {
            i += 1
            guard let c = peek() else { failed = true; return .unknown }
            i += 1
            var set = UnitSet()
            switch c {
            case 110: set.insert(10) // \n
            case 114: set.insert(13) // \r
            case 116: set.insert(9) // \t
            case 117: // \uXXXX
                guard let u = hex4() else { failed = true; return .unknown }
                set.insert(u)
            default:
                // A backreference or a class escape: the dialect has none, and
                // guessing what one spans could skip a pattern that matches.
                if LS.isASCIILetter(Int(c)) || LS.isDigit(Int(c)) {
                    failed = true
                    return .unknown
                }
                set.insert(c)
            }
            return .unit(set)
        }

        mutating func hex4() -> UInt16? {
            guard i + 4 <= units.count, let v = UInt16(units.slice(i, i + 4).string, radix: 16) else { return nil }
            i += 4
            return v
        }

        /// One class member: a unit, or `.some(nil)` for an escape only a
        /// whole class can mean (`\s`, `\S`…); nil at the end of the pattern.
        mutating func classUnit() -> UInt16?? {
            guard let c = peek() else { failed = true; return nil }
            if c != 92 {
                i += 1
                return .some(c)
            }
            i += 1
            guard let e = peek() else { failed = true; return nil }
            i += 1
            switch e {
            case 110: return .some(10)
            case 114: return .some(13)
            case 116: return .some(9)
            case 117: return hex4().map { .some($0) } ?? .some(nil)
            default:
                if LS.isASCIILetter(Int(e)) || LS.isDigit(Int(e)) { return .some(nil) }
                return .some(e)
            }
        }

        mutating func characterClass() -> UnitSet {
            i += 1
            var negated = false
            if peek() == 94 { negated = true; i += 1 }
            var set = UnitSet()
            var unknown = false
            while peek().map({ $0 != 93 }) ?? false {
                guard let first = classUnit() else { return .all }
                if peek() == 45, let next = peek(1), next != 93 { // a-b
                    i += 1
                    guard let second = classUnit() else { return .all }
                    if let a = first, let b = second { set.insert(a, through: b) } else { unknown = true }
                } else if let a = first {
                    set.insert(a)
                } else {
                    unknown = true
                }
            }
            guard peek() == 93 else { failed = true; return .all }
            i += 1
            if unknown { return .all }
            return negated ? set.inverted : set
        }
    }
}

/// The text a regex trigger is matched against. Latex Suite runs each trigger
/// over everything from the start of the document to the caret, plus the key;
/// a trigger can only match at the end of that, so each one is shown just the
/// window its shape says it can reach (`LSPatternShape`), with as many
/// characters in front as its lookbehinds read (one, for the rewritten `^`
/// and `\b`).
///
/// ICU reads UTF-16 by code point, JavaScript without the `u` flag by code
/// unit: `[^\\]` takes a whole emoji in one and half of it in the other, which
/// moves where the match starts — and `(\S\s*)dm` checks the character before
/// that start for a word boundary. So each surrogate is shown to ICU as
/// U+FFFD, a single unit that every class in the dialect treats the way
/// JavaScript treats a lone surrogate; the captures are cut from the real text.
struct LSRegexInput {
    struct Match {
        var index: Int
        var whole: LSUnits
        var groups: [LSUnits?]
        /// The same groups as document ranges.
        var groupRanges: [Range<Int>?]
        var named: [String: LSUnits]
    }

    let doc: LSUnits
    let to: Int
    let key: LSUnits
    /// The length of the text the trigger is matched against.
    var count: Int { to + key.count }

    init(doc: LSUnits, to: Int, key: LSUnits) {
        self.doc = doc
        self.to = to
        self.key = key
    }

    @inline(__always)
    func unit(_ i: Int) -> UInt16 { i < to ? doc[i] : key[i - to] }

    /// Where a match of `shape` can start at the earliest.
    func windowStart(_ shape: LSPatternShape) -> Int {
        if let length = shape.maxLength { return Swift.max(0, count - length) }
        var outside = 0
        var i = count
        while i > 0 {
            let u = unit(i - 1)
            if !shape.reach.contains(u & 0xF800 == 0xD800 ? 0xFFFD : u) {
                outside += 1
                if outside > shape.bounded { break }
            }
            i -= 1
        }
        return i
    }

    func match(_ regex: NSRegularExpression, shape: LSPatternShape, groupNames: [String?]) -> Match? {
        if let last = shape.last {
            guard count > 0 else { return nil }
            let unit = unit(count - 1)
            guard last.contains(unit & 0xF800 == 0xD800 ? 0xFFFD : unit) else { return nil }
        }
        let start = windowStart(shape)
        let base = shape.behind == .max ? 0 : Swift.max(0, start - shape.behind)
        var units = LSUnits()
        units.reserveCapacity(count - base)
        for i in base..<count { units.append(unit(i)) }
        var shown = units
        for k in shown.indices where shown[k] & 0xF800 == 0xD800 { shown[k] = 0xFFFD }
        let string = shown.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) }
        guard let m = regex.firstMatch(in: string as String, options: [.withTransparentBounds],
                                       range: NSRange(location: start - base, length: count - start)) else { return nil }
        var groups: [LSUnits?] = []
        var ranges: [Range<Int>?] = []
        var named: [String: LSUnits] = [:]
        if m.numberOfRanges > 1 {
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                let found = r.location != NSNotFound
                let value: LSUnits? = found ? units.slice(r.location, r.location + r.length) : nil
                groups.append(value)
                ranges.append(found ? (base + r.location)..<(base + r.location + r.length) : nil)
                if i - 1 < groupNames.count, let name = groupNames[i - 1] { named[name] = value ?? [] }
            }
        }
        return Match(index: base + m.range.location,
                     whole: units.slice(m.range.location, m.range.location + m.range.length),
                     groups: groups, groupRanges: ranges, named: named)
    }
}
