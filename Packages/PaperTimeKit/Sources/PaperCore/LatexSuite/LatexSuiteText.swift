import Foundation

/// UTF-16 code units, the unit every offset in this engine is counted in.
///
/// Latex Suite is JavaScript, where a string *is* its UTF-16 code units, and
/// the note editors on both builds hand out selections as NSRange/UTF-16.
/// Working in anything else would mean converting at every boundary and
/// getting it wrong at the first emoji.
typealias LSUnits = [UInt16]

extension Array where Element == UInt16 {
    var string: String { String(decoding: self, as: UTF16.self) }

    func slice(_ from: Int, _ to: Int) -> LSUnits {
        let lower = Swift.max(0, Swift.min(from, count))
        let n = Swift.max(lower, Swift.min(to, count)) - lower
        guard n > 0 else { return [] }
        // A copy, not `Array(self[range])`: a debug build runs that generic
        // initialiser element by element, and a paragraph is copied per key.
        return withUnsafeBufferPointer { source in
            LSUnits(unsafeUninitializedCapacity: n) { buffer, count in
                buffer.baseAddress!.initialize(from: source.baseAddress! + lower, count: n)
                count = n
            }
        }
    }

    func hasPrefix(_ prefix: LSUnits, at index: Int = 0) -> Bool {
        guard index >= 0, index + prefix.count <= count else { return false }
        for k in 0..<prefix.count where self[index + k] != prefix[k] { return false }
        return true
    }

    /// JavaScript's `indexOf(needle, from)`.
    func index(of needle: LSUnits, from: Int = 0) -> Int? {
        let start = Swift.max(0, from)
        if needle.isEmpty { return Swift.min(start, count) }
        guard needle.count <= count else { return nil }
        var i = start
        while i + needle.count <= count {
            if self[i] == needle[0], hasPrefix(needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// JavaScript's `lastIndexOf(needle, from)`: the last occurrence that
    /// starts at or before `from` (clamped into the string).
    func lastIndex(of needle: LSUnits, from: Int) -> Int? {
        var i = Swift.min(Swift.max(from, 0), count - needle.count)
        while i >= 0 {
            if hasPrefix(needle, at: i) { return i }
            i -= 1
        }
        return nil
    }

    func contains(_ needle: LSUnits) -> Bool { index(of: needle) != nil }

    /// JavaScript's `trimEnd()`.
    func trimmingEnd() -> LSUnits {
        var end = count
        while end > 0, LS.isSpace(self[end - 1]) { end -= 1 }
        return slice(0, end)
    }

    func isAllSpace(_ from: Int = 0, _ to: Int? = nil) -> Bool {
        let upper = Swift.min(to ?? count, count)
        var i = Swift.max(0, from)
        while i < upper {
            if !LS.isSpace(self[i]) { return false }
            i += 1
        }
        return true
    }
}

/// Character classes, spelled the way the JavaScript Latex Suite reads them.
enum LS {
    static let newline: UInt16 = 10
    static let backslash: UInt16 = 92

    /// JavaScript's `\s` and what `trim()` removes (ECMA-262 WhiteSpace and
    /// LineTerminator). Not Foundation's whitespace set: that one has U+0085
    /// and lacks U+FEFF.
    static func isSpace(_ c: UInt16) -> Bool {
        switch c {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func isSpace(_ c: Int) -> Bool { c >= 0 && isSpace(UInt16(c)) }

    /// lezer-markdown's `space()`: the four characters its block and inline
    /// parsers skip.
    static func isMarkdownSpace(_ c: Int) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    static func isASCIILetter(_ c: Int) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isDigit(_ c: Int) -> Bool { c >= 48 && c <= 57 }
    /// JavaScript's `\w` without the `u` flag.
    static func isWord(_ c: Int) -> Bool { isASCIILetter(c) || isDigit(c) || c == 95 }

    static func units(_ s: String) -> LSUnits { Array(s.utf16) }

    static func string(_ buffer: UnsafeBufferPointer<UInt16>, _ from: Int, _ to: Int) -> String {
        let lower = Swift.max(0, Swift.min(from, buffer.count))
        return String(decoding: UnsafeBufferPointer(rebasing: buffer[lower..<Swift.max(lower, Swift.min(to, buffer.count))]),
                      as: UTF16.self)
    }

    /// The same for a whole note, on every keystroke. An editor's text is
    /// usually an `NSString` underneath (NSTextView's storage), and walking a
    /// bridged string's `utf16` view costs a message send per unit: 250 µs
    /// for 20,000 characters, against 9 µs for one `getCharacters` copy.
    static func bulkUnits(_ s: String) -> LSUnits {
        let ns = s as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        return LSUnits(unsafeUninitializedCapacity: length) { buffer, count in
            ns.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: length))
            count = length
        }
    }
}

extension NSRange {
    /// As a range of offsets, whatever an editor hands over: `NSNotFound`
    /// or a negative length must not trap on the way in.
    var lsRange: Range<Int> {
        let from = Swift.max(0, location)
        let length = Swift.max(0, self.length)
        let to = from > Int.max - length ? Int.max : from + length
        return from..<to
    }

    init(ls from: Int, _ to: Int) { self.init(location: from, length: to - from) }
}
