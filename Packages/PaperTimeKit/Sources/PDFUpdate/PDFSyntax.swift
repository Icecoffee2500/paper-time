import Foundation
import zlib

// A small PDF object model, tokenizer, parser and serializer — just enough to
// read a file's cross-reference chain, page tree and annotations, and to write
// new objects in an incremental update (ISO 32000-1 §7.5.6).
//
// Nothing here is meant to understand a whole PDF. It reads the few objects a
// save touches, reads them the way readers do, and says so whenever it had to
// guess — a writer that guessed wrong would put marks on the wrong page, and
// the one thing this code must never do is make a paper worse.

public enum PDFError: Error, CustomStringConvertible, Sendable {
    case syntax(String, Int)
    case unsupported(String)
    case missing(String)

    public var description: String {
        switch self {
        case let .syntax(what, at): "syntax: \(what) at \(at)"
        case let .unsupported(what): "unsupported: \(what)"
        case let .missing(what): "missing: \(what)"
        }
    }
}

public struct PDFRef: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let num: Int
    public let gen: Int
    public init(_ num: Int, _ gen: Int) { self.num = num; self.gen = gen }
    public static func < (a: PDFRef, b: PDFRef) -> Bool { a.num != b.num ? a.num < b.num : a.gen < b.gen }
    public var description: String { "\(num) \(gen) R" }
}

public indirect enum PDFObj: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    /// A real number — or an integer too big for `Int` — kept as the lexeme
    /// the file used, so a re-serialised object says exactly what the
    /// original said.
    case real(String)
    case string([UInt8], hex: Bool)
    /// A name, `#xx` escapes decoded, bytes held one-to-one as Latin-1.
    case name(String)
    case array([PDFObj])
    case dict(PDFDict)
    case ref(PDFRef)
    /// A stream: its dictionary and its raw (still encoded) bytes.
    case stream(PDFDict, [UInt8])

    public var int: Int? { if case let .int(v) = self { return v }; return nil }
    public var number: Double? {
        switch self {
        case let .int(v): Double(v)
        case let .real(s): Double(s) ?? PDFObj.lenientDouble(s)
        default: nil
        }
    }
    public var name: String? { if case let .name(v) = self { return v }; return nil }
    public var array: [PDFObj]? { if case let .array(v) = self { return v }; return nil }
    public var dict: PDFDict? {
        switch self {
        case let .dict(d): d
        case let .stream(d, _): d
        default: nil
        }
    }
    public var ref: PDFRef? { if case let .ref(r) = self { return r }; return nil }
    public var stringBytes: [UInt8]? { if case let .string(b, _) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Text of a PDF text string: UTF-16BE with BOM, UTF-8 with BOM, or
    /// PDFDocEncoding (approximated as Latin-1).
    public var text: String? {
        guard let b = stringBytes else { return nil }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            return String(bytes: b[2...], encoding: .utf16BigEndian)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(bytes: b[3...], encoding: .utf8)
        }
        return String(bytes: b, encoding: .isoLatin1)
    }

    static func lenientDouble(_ s: String) -> Double {
        // "--5", "5-", "1.2.3": take the longest prefix that parses.
        var t = s
        while !t.isEmpty {
            if let d = Double(t) { return d }
            t.removeLast()
        }
        return 0
    }
}

public struct PDFDict: Sendable {
    public var pairs: [(key: String, value: PDFObj)] = []

    public init(_ pairs: [(key: String, value: PDFObj)] = []) { self.pairs = pairs }

    /// The first value under a key. A dictionary that says a key twice is
    /// read differently by different readers — see `hasDuplicateKeys`.
    public subscript(key: String) -> PDFObj? {
        get { pairs.first { $0.key == key }?.value }
        set {
            if let i = pairs.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    pairs[i].value = newValue
                    // One key, one value, once set on purpose.
                    var j = pairs.count - 1
                    while j > i { if pairs[j].key == key { pairs.remove(at: j) }; j -= 1 }
                } else {
                    pairs.removeAll { $0.key == key }
                }
            } else if let newValue {
                pairs.append((key, newValue))
            }
        }
    }

    public var keys: [String] { pairs.map(\.key) }

    public func count(of key: String) -> Int { pairs.reduce(0) { $0 + ($1.key == key ? 1 : 0) } }
}

// MARK: - Character classes

@inline(__always) func isWhite(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00
}

@inline(__always) func isDelim(_ c: UInt8) -> Bool {
    switch c {
    case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: true
    default: false
    }
}

@inline(__always) func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelim(c) }

@inline(__always) func hexValue(_ c: UInt8) -> Int? {
    switch c {
    case 0x30...0x39: Int(c - 0x30)
    case 0x41...0x46: Int(c - 0x41 + 10)
    case 0x61...0x66: Int(c - 0x61 + 10)
    default: nil
    }
}

// MARK: - Lexer

enum Tok: Equatable {
    case int(Int)
    case real(String)
    case name(String)
    case str([UInt8], Bool)
    case kw(String)
    case aOpen, aClose, dOpen, dClose
    case eof
}

/// Reads tokens straight out of the bytes it is given — the file itself, not
/// a copy of it. A fifty-megabyte book is read where it lies.
struct Lexer {
    let b: UnsafeBufferPointer<UInt8>
    var pos: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, at pos: Int = 0) {
        self.b = bytes
        self.pos = pos
    }

    mutating func skipWhite() {
        while pos < b.count {
            let c = b[pos]
            if isWhite(c) { pos += 1; continue }
            if c == 0x25 { // % comment to end of line
                while pos < b.count, b[pos] != 0x0A, b[pos] != 0x0D { pos += 1 }
                continue
            }
            break
        }
    }

    mutating func next() -> Tok {
        skipWhite()
        guard pos < b.count else { return .eof }
        let c = b[pos]
        switch c {
        case 0x5B: pos += 1; return .aOpen
        case 0x5D: pos += 1; return .aClose
        case 0x3C:
            if pos + 1 < b.count, b[pos + 1] == 0x3C { pos += 2; return .dOpen }
            return hexString()
        case 0x3E:
            if pos + 1 < b.count, b[pos + 1] == 0x3E { pos += 2; return .dClose }
            pos += 1; return .kw(">")
        case 0x28: return literalString()
        case 0x2F: return name()
        case 0x7B, 0x7D: pos += 1; return .kw(String(UnicodeScalar(c)))
        case 0x29: pos += 1; return .kw(")")
        default:
            if c == 0x2B || c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39) {
                return number()
            }
            let start = pos
            while pos < b.count, isRegular(b[pos]) { pos += 1 }
            if pos == start { pos += 1 }
            return .kw(String(decoding: UnsafeBufferPointer(rebasing: b[start..<pos]), as: UTF8.self))
        }
    }

    mutating func number() -> Tok {
        let start = pos
        var dot = false
        while pos < b.count {
            let c = b[pos]
            if c >= 0x30 && c <= 0x39 { pos += 1; continue }
            if c == 0x2E { dot = true; pos += 1; continue }
            if c == 0x2B || c == 0x2D { pos += 1; continue }
            break
        }
        // Something like "12abc" — a keyword that starts with digits.
        if pos < b.count, isRegular(b[pos]) {
            while pos < b.count, isRegular(b[pos]) { pos += 1 }
            return .kw(String(decoding: UnsafeBufferPointer(rebasing: b[start..<pos]), as: UTF8.self))
        }
        let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<pos]), as: UTF8.self)
        if !dot, let v = Int(s) { return .int(v) }
        if !dot {
            // "-", "+", "--3": broken integers, read leniently. One too big for
            // Int (qpdf: "overflow converting ... to 64-bit integer") keeps its
            // lexeme, so it is written back exactly as it was, and never traps.
            let d = PDFObj.lenientDouble(s)
            if d.isFinite, abs(d) < 9.0e18 { return .int(Int(d)) }
            return .real(s)
        }
        return .real(s)
    }

    mutating func name() -> Tok {
        pos += 1 // '/'
        var out: [UInt8] = []
        while pos < b.count, isRegular(b[pos]) {
            let c = b[pos]
            if c == 0x23, pos + 2 < b.count, let h = hexValue(b[pos + 1]), let l = hexValue(b[pos + 2]) {
                out.append(UInt8(h * 16 + l))
                pos += 3
            } else {
                out.append(c)
                pos += 1
            }
        }
        return .name(String(bytes: out, encoding: .isoLatin1) ?? "")
    }

    mutating func hexString() -> Tok {
        pos += 1 // '<'
        var out: [UInt8] = []
        var high: Int?
        while pos < b.count, b[pos] != 0x3E {
            if let v = hexValue(b[pos]) {
                if let h = high { out.append(UInt8(h * 16 + v)); high = nil } else { high = v }
            }
            pos += 1
        }
        if let h = high { out.append(UInt8(h * 16)) }
        if pos < b.count { pos += 1 } // '>'
        return .str(out, true)
    }

    mutating func literalString() -> Tok {
        pos += 1 // '('
        var out: [UInt8] = []
        var depth = 1
        while pos < b.count {
            let c = b[pos]
            if c == 0x5C { // backslash
                pos += 1
                guard pos < b.count else { break }
                let e = b[pos]
                switch e {
                case 0x6E: out.append(0x0A); pos += 1
                case 0x72: out.append(0x0D); pos += 1
                case 0x74: out.append(0x09); pos += 1
                case 0x62: out.append(0x08); pos += 1
                case 0x66: out.append(0x0C); pos += 1
                case 0x28, 0x29, 0x5C: out.append(e); pos += 1
                case 0x0D:
                    pos += 1
                    if pos < b.count, b[pos] == 0x0A { pos += 1 }
                case 0x0A: pos += 1
                case 0x30...0x37:
                    var v = 0
                    var n = 0
                    while n < 3, pos < b.count, b[pos] >= 0x30, b[pos] <= 0x37 {
                        v = v * 8 + Int(b[pos] - 0x30)
                        pos += 1
                        n += 1
                    }
                    out.append(UInt8(v & 0xFF))
                default:
                    out.append(e); pos += 1
                }
                continue
            }
            if c == 0x28 { depth += 1 }
            if c == 0x29 {
                depth -= 1
                if depth == 0 { pos += 1; break }
            }
            if c == 0x0D {
                // An unescaped end of line in a literal reads as a line feed.
                out.append(0x0A)
                pos += 1
                if pos < b.count, b[pos] == 0x0A { pos += 1 }
                continue
            }
            out.append(c)
            pos += 1
        }
        return .str(out, false)
    }
}

// MARK: - Parser

struct Parser {
    var lex: Lexer
    /// What this parser had to overlook: a key said twice in one dictionary,
    /// or something that is not a name where a key belongs. Readers differ
    /// on both, so an object that needed either is never written back from
    /// its parse — see `PDFFile.irregular`.
    var duplicateKeys = 0
    var skippedTokens = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>, at pos: Int = 0) { lex = Lexer(bytes, at: pos) }

    var pos: Int {
        get { lex.pos }
        set { lex.pos = newValue }
    }

    var sawIrregularity: Bool { duplicateKeys > 0 || skippedTokens > 0 }

    mutating func object(depth: Int = 0) throws -> PDFObj {
        guard depth < 200 else { throw PDFError.syntax("nesting too deep", pos) }
        let at = pos
        let t = lex.next()
        return try object(from: t, at: at, depth: depth)
    }

    mutating func object(from t: Tok, at: Int, depth: Int) throws -> PDFObj {
        switch t {
        case let .int(n):
            let save = lex.pos
            if case let .int(g) = lex.next() {
                if case .kw("R") = lex.next() { return .ref(PDFRef(n, g)) }
            }
            lex.pos = save
            return .int(n)
        case let .real(s): return .real(s)
        case let .name(s): return .name(s)
        case let .str(bytes, hex): return .string(bytes, hex: hex)
        case .aOpen:
            var items: [PDFObj] = []
            while true {
                let p = lex.pos
                let t = lex.next()
                if t == .aClose { break }
                if t == .eof { throw PDFError.syntax("unterminated array", at) }
                if case .kw("endobj") = t { lex.pos = p; skippedTokens += 1; break }
                items.append(try object(from: t, at: p, depth: depth + 1))
            }
            return .array(items)
        case .dOpen:
            var d = PDFDict()
            while true {
                let p = lex.pos
                let t = lex.next()
                if t == .dClose { break }
                if t == .eof { throw PDFError.syntax("unterminated dictionary", at) }
                if case .kw("endobj") = t { lex.pos = p; skippedTokens += 1; break }
                guard case let .name(key) = t else {
                    // Garbage where a key belongs: skipped, as readers do —
                    // and noted, because not every reader skips the same way.
                    skippedTokens += 1
                    continue
                }
                let vp = lex.pos
                let vt = lex.next()
                if vt == .dClose { d.pairs.append((key, .null)); skippedTokens += 1; break }
                let value = try object(from: vt, at: vp, depth: depth + 1)
                // Duplicates are kept, so a re-serialised dictionary says
                // exactly what the original said; lookups see the first.
                if d[key] != nil { duplicateKeys += 1 }
                d.pairs.append((key, value))
            }
            return .dict(d)
        case .kw("true"): return .bool(true)
        case .kw("false"): return .bool(false)
        case .kw("null"): return .null
        case .eof: throw PDFError.syntax("unexpected end of file", at)
        case let .kw(k): throw PDFError.syntax("unexpected keyword \(k)", at)
        default: throw PDFError.syntax("unexpected token", at)
        }
    }
}

// MARK: - Where the pieces of an object are

/// The byte ranges of a dictionary's or an array's top-level entries, in the
/// object's own text — so a page can be written back as the file wrote it,
/// with only its /Annots changed, rather than as this parser understood it.
struct Spans {
    struct Pair {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    /// For a dictionary: its keys and values. For an array: its elements,
    /// with an empty key.
    var entries: [Pair]
    /// Where the closing `>>` or `]` starts.
    var close: Int
    /// Where the object's text ends, after the closing delimiter.
    var end: Int

    /// Reads the top level of the dictionary or array starting at `start`.
    /// Anything irregular — garbage where a key belongs, a key without a
    /// value — throws: an object that has to be read leniently is not one to
    /// cut and splice.
    static func of(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) throws -> Spans {
        var p = Parser(bytes, at: start)
        let open = p.lex.next()
        var entries: [Pair] = []
        switch open {
        case .dOpen:
            while true {
                p.lex.skipWhite()
                let keyStart = p.lex.pos
                let t = p.lex.next()
                if t == .dClose { return Spans(entries: entries, close: p.lex.pos - 2, end: p.lex.pos) }
                guard case let .name(key) = t else { throw PDFError.syntax("not a key", keyStart) }
                p.lex.skipWhite()
                let valueStart = p.lex.pos
                let vt = p.lex.next()
                if vt == .dClose || vt == .eof { throw PDFError.syntax("key without a value", keyStart) }
                _ = try p.object(from: vt, at: valueStart, depth: 1)
                entries.append(Pair(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: p.lex.pos))
            }
        case .aOpen:
            while true {
                p.lex.skipWhite()
                let valueStart = p.lex.pos
                let t = p.lex.next()
                if t == .aClose { return Spans(entries: entries, close: p.lex.pos - 1, end: p.lex.pos) }
                if t == .eof { throw PDFError.syntax("unterminated array", valueStart) }
                if case .kw = t { throw PDFError.syntax("keyword in an array", valueStart) }
                _ = try p.object(from: t, at: valueStart, depth: 1)
                entries.append(Pair(key: "", keyStart: valueStart, valueStart: valueStart, valueEnd: p.lex.pos))
            }
        default:
            throw PDFError.syntax("neither a dictionary nor an array", start)
        }
    }
}

// MARK: - Serializer

enum Serializer {
    static func write(_ o: PDFObj, into out: inout [UInt8]) {
        switch o {
        case .null: out += Array("null".utf8)
        case let .bool(v): out += Array((v ? "true" : "false").utf8)
        case let .int(v): out += Array(String(v).utf8)
        case let .real(s): out += Array(s.utf8)
        case let .string(bytes, hex): writeString(bytes, hex: hex, into: &out)
        case let .name(n): writeName(n, into: &out)
        case let .array(items):
            out.append(0x5B)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x20) }
                write(item, into: &out)
            }
            out.append(0x5D)
        case let .dict(d): writeDict(d, into: &out)
        case let .ref(r):
            out += Array("\(r.num) \(r.gen) R".utf8)
        case let .stream(d, data):
            var dd = d
            dd["Length"] = .int(data.count)
            writeDict(dd, into: &out)
            out += Array("\nstream\n".utf8)
            out += data
            out += Array("\nendstream".utf8)
        }
    }

    static func writeDict(_ d: PDFDict, into out: inout [UInt8]) {
        out += Array("<<".utf8)
        for (k, v) in d.pairs {
            out.append(0x20)
            writeName(k, into: &out)
            out.append(0x20)
            write(v, into: &out)
        }
        out += Array(" >>".utf8)
    }

    static func writeName(_ n: String, into out: inout [UInt8]) {
        out.append(0x2F)
        let bytes = n.data(using: .isoLatin1).map { [UInt8]($0) } ?? Array(n.utf8)
        for c in bytes {
            if c < 0x21 || c > 0x7E || c == 0x23 || isDelim(c) {
                out += Array(String(format: "#%02X", c).utf8)
            } else {
                out.append(c)
            }
        }
    }

    static func writeString(_ bytes: [UInt8], hex: Bool, into out: inout [UInt8]) {
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        if hex || !printable {
            out.append(0x3C)
            for c in bytes { out += Array(String(format: "%02X", c).utf8) }
            out.append(0x3E)
            return
        }
        out.append(0x28)
        for c in bytes {
            if c == 0x28 || c == 0x29 || c == 0x5C { out.append(0x5C) }
            out.append(c)
        }
        out.append(0x29)
    }

    static func bytes(_ o: PDFObj) -> [UInt8] {
        var out: [UInt8] = []
        write(o, into: &out)
        return out
    }
}

// MARK: - Filters

enum Filters {
    /// Inflates a zlib stream. Tolerant, like readers are: a stream that is
    /// cut short or carries junk after its end gives what could be decoded.
    static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw PDFError.unsupported("inflateInit failed") }
        defer { inflateEnd(&stream) }
        var output: [UInt8] = []
        output.reserveCapacity(max(input.count * 4, 1024))
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBufferPointer { inp in
            stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
            stream.avail_in = uInt(inp.count)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = chunk - Int(stream.avail_out)
                    output.append(contentsOf: buf[0..<produced])
                    if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                        if output.isEmpty { throw PDFError.syntax("inflate error \(status)", 0) }
                    }
                }
            } while status == Z_OK && (stream.avail_in > 0 || stream.avail_out == 0)
        }
        return output
    }

    static func deflate(_ input: [UInt8]) -> [UInt8] {
        var destLen = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(destLen))
        let status = input.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                compress2(o.baseAddress, &destLen, inp.baseAddress, uLong(inp.count), 9)
            }
        }
        precondition(status == Z_OK)
        return Array(out[0..<Int(destLen)])
    }

    static func unpredict(_ data: [UInt8], parms: PDFDict?) throws -> [UInt8] {
        guard let parms, let predictor = parms["Predictor"]?.int, predictor > 1 else { return data }
        let colors = parms["Colors"]?.int ?? 1
        let bpc = parms["BitsPerComponent"]?.int ?? 8
        let columns = parms["Columns"]?.int ?? 1
        guard colors > 0, colors <= 64, bpc > 0, bpc <= 16, columns > 0, columns <= 1 << 20 else {
            throw PDFError.unsupported("predictor with \(colors) colours, \(bpc) bits, \(columns) columns")
        }
        let bpp = max(1, (colors * bpc + 7) / 8)
        let rowLength = (columns * colors * bpc + 7) / 8
        guard rowLength >= bpp else { throw PDFError.unsupported("predictor with \(columns) columns") }
        if predictor == 2 {
            guard bpc == 8 else { throw PDFError.unsupported("TIFF predictor with bpc \(bpc)") }
            var out = data
            var i = 0
            while i < out.count {
                for j in bpp..<rowLength where i + j < out.count {
                    out[i + j] = out[i + j] &+ out[i + j - bpp]
                }
                i += rowLength
            }
            return out
        }
        // PNG predictors: each row starts with a filter-type byte.
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var previous = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i < data.count {
            let type = data[i]
            i += 1
            var row = [UInt8](repeating: 0, count: rowLength)
            let n = min(rowLength, data.count - i)
            for j in 0..<n { row[j] = data[i + j] }
            i += n
            switch type {
            case 0: break
            case 1: for j in bpp..<rowLength { row[j] = row[j] &+ row[j - bpp] }
            case 2: for j in 0..<rowLength { row[j] = row[j] &+ previous[j] }
            case 3:
                for j in 0..<rowLength {
                    let left = j >= bpp ? Int(row[j - bpp]) : 0
                    row[j] = row[j] &+ UInt8((left + Int(previous[j])) / 2)
                }
            case 4:
                for j in 0..<rowLength {
                    let a = j >= bpp ? Int(row[j - bpp]) : 0
                    let b = Int(previous[j])
                    let c = j >= bpp ? Int(previous[j - bpp]) : 0
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    row[j] = row[j] &+ UInt8(pred)
                }
            default: throw PDFError.unsupported("PNG filter type \(type)")
            }
            out += row
            previous = row
        }
        return out
    }

    /// Decodes a stream's data through its filter chain. Only what cross-
    /// reference and object streams use in practice.
    static func decode(_ dict: PDFDict, _ raw: [UInt8]) throws -> [UInt8] {
        var filters: [String] = []
        var parms: [PDFDict?] = []
        switch dict["Filter"] {
        case let .name(n)?: filters = [n]; parms = [dict["DecodeParms"]?.dict]
        case let .array(a)?:
            filters = a.compactMap(\.name)
            let p = dict["DecodeParms"]?.array ?? []
            parms = filters.indices.map { $0 < p.count ? p[$0].dict : nil }
        default: break
        }
        var data = raw
        for (i, f) in filters.enumerated() {
            switch f {
            case "FlateDecode", "Fl":
                data = try unpredict(try inflate(data), parms: parms[i])
            default:
                throw PDFError.unsupported("filter \(f)")
            }
        }
        return data
    }
}
