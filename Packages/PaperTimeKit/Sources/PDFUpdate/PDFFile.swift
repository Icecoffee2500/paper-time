import Foundation

/// A PDF file, read far enough to find any object by number: the cross-
/// reference chain (tables and streams, /Prev and /XRefStm), object streams,
/// and the page tree.
///
/// Read where it lies: the file's bytes are never copied. And read the way
/// readers read, with one difference — every place where a reader would
/// quietly repair something, this one also writes down that it did. A save
/// that rests on a repair is refused (`IncrementalWriter.Refusal`): if this
/// reader and PDFKit repaired the same file differently, the marks would go
/// onto a page the user was not looking at.
public final class PDFFile {
    public enum Entry: Equatable, Sendable {
        case free(gen: Int)
        case offset(Int, gen: Int)
        case compressed(stream: Int, index: Int)
    }

    public enum SectionKind: String, Sendable { case table, stream }

    public struct Section: Sendable {
        public let kind: SectionKind
        public let offset: Int
        public let trailer: PDFDict
    }

    private let storage: NSData
    let bytes: UnsafeBufferPointer<UInt8>
    public var count: Int { bytes.count }

    public private(set) var entries: [Int: Entry] = [:]
    /// Newest first, as the chain is walked.
    public private(set) var sections: [Section] = []
    public private(set) var startxref: Int = -1
    /// Trailer keys as the newest section that has each one says them.
    public private(set) var trailer = PDFDict()
    /// True when the chain could not be read as written and objects were
    /// found by scanning the file instead.
    public private(set) var repaired = false
    public private(set) var notes: [String] = []

    /// How many times an object was handed out that this reader had to
    /// guess at — found by scanning because its offset was wrong, or its
    /// stream's length repaired. Counted per read, not per object, so a
    /// caller can tell whether *its* reads rested on a guess (`tolerant`).
    public private(set) var guessedReads = 0
    private var guessed: Set<Int> = []
    /// Objects whose parse had to overlook something (a key said twice,
    /// garbage where a key belongs). Never written back from the parse.
    public private(set) var irregular: Set<Int> = []

    private var cache: [Int: PDFObj] = [:]
    /// Where each uncompressed object's value lies in the file.
    private var bodies: [Int: Range<Int>] = [:]

    /// Set for an encrypted file once its key is known: objects read from
    /// then on come back decrypted (the /Encrypt dictionary itself and
    /// cross-reference streams are never encrypted; objects inside an object
    /// stream are decrypted with the stream, not one by one).
    public var security: StandardSecurity? {
        didSet {
            cache.removeAll()
            objectStreams.removeAll()
        }
    }

    private struct ObjectStream {
        var data: [UInt8]
        var objects: [Int: PDFObj]
        var spans: [Int: Range<Int>]
    }
    private var objectStreams: [Int: ObjectStream] = [:]
    private var scanIndex: [Int: (offset: Int, gen: Int)]?

    public init(data: Data) throws {
        // Bridged, not copied: an immutable NSData's bytes stay where they
        // are for as long as it lives, and this object keeps it alive.
        storage = data as NSData
        guard storage.length > 0 else { throw PDFError.missing("bytes") }
        bytes = UnsafeBufferPointer(start: storage.bytes.assumingMemoryBound(to: UInt8.self), count: storage.length)
        try readChain()
    }

    /// Runs `body` and says whether anything it read was a guess — without
    /// counting that against the caller. For the walks a save does on the
    /// side (streams it could share, objects it could free), where a guess
    /// means "don't", not "refuse".
    public func tolerant<T>(_ body: () throws -> T) rethrows -> (T, guessed: Bool) {
        let before = guessedReads
        let result = try body()
        let hit = guessedReads > before
        guessedReads = before
        return (result, hit)
    }

    private func note(_ s: String) { notes.append(s) }

    // MARK: Cross-reference chain

    private func findStartXRef() -> Int? {
        let needle = Array("startxref".utf8)
        // Readers look well past the last kilobyte: files with a megabyte of
        // zeros after %%EOF open everywhere, so they are read here too.
        let window = min(bytes.count, 1 << 20)
        var i = bytes.count - needle.count
        let floor = bytes.count - window
        while i >= max(0, floor) {
            if bytes[i] == needle[0], matches(needle, at: i) {
                var lex = Lexer(bytes, at: i + needle.count)
                if case let .int(v) = lex.next() { return v }
                return nil
            }
            i -= 1
        }
        return nil
    }

    private func matches(_ needle: [UInt8], at i: Int) -> Bool {
        guard i >= 0, i + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count where bytes[i + k] != needle[k] { return false }
        return true
    }

    private func readChain() throws {
        guard let sx = findStartXRef() else {
            note("no startxref")
            try reconstruct()
            return
        }
        startxref = sx
        var next: Int? = sx
        var visited = Set<Int>()
        do {
            while let off = next {
                guard visited.insert(off).inserted else {
                    // A /Prev that points back into the chain: not a file
                    // any two readers are sure to read alike.
                    throw PDFError.syntax("xref loop", off)
                }
                let (section, xrefStm, freedHere) = try readSection(at: off)
                sections.append(section)
                if let s = xrefStm, visited.insert(s).inserted {
                    // Hybrid file: the stream belongs to this section, filling
                    // in what its table left free or unsaid — never what a
                    // newer section already decided.
                    _ = try readSection(at: s, fill: freedHere)
                    note("hybrid XRefStm at \(s)")
                }
                next = section.trailer["Prev"]?.int
            }
        } catch {
            note("chain unreadable: \(error)")
            entries.removeAll()
            sections.removeAll()
            try reconstruct()
            return
        }
        for s in sections.reversed() {
            for (k, v) in s.trailer.pairs where !PDFFile.sectionKeys.contains(k) {
                trailer[k] = v
            }
        }
        guard trailer["Root"]?.ref != nil else {
            note("no /Root in trailer")
            try reconstruct()
            return
        }
    }

    /// Keys of a section that describe the section itself, not the file.
    static let sectionKeys: Set<String> = ["Prev", "XRefStm", "Type", "W", "Index", "Filter", "DecodeParms", "Length", "N", "First"]

    /// Reads the section at an offset. Entries already known (from a newer
    /// section) are kept. Returns the section, its /XRefStm if it has one,
    /// and the numbers this table was the first to call free.
    ///
    /// `fill` is set when reading a hybrid file's stream: it may only fill in
    /// numbers no newer section spoke for, and those its own table left free.
    private func readSection(at off: Int, fill: Set<Int>? = nil) throws -> (Section, Int?, Set<Int>) {
        guard off >= 0, off < bytes.count else { throw PDFError.syntax("xref offset out of range", off) }
        var lex = Lexer(bytes, at: off)
        let t = lex.next()
        var freedHere = Set<Int>()
        if case .kw("xref") = t {
            guard fill == nil else { throw PDFError.syntax("/XRefStm points at a table", off) }
            var p = Parser(bytes, at: lex.pos)
            while true {
                let before = p.pos
                let t1 = p.lex.next()
                if case .kw("trailer") = t1 { break }
                guard case let .int(first0) = t1, case let .int(count) = p.lex.next() else {
                    throw PDFError.syntax("bad xref subsection", before)
                }
                guard count >= 0, first0 >= 0, count <= 10_000_000 else { throw PDFError.syntax("xref subsection \(first0) \(count)", before) }
                var first = first0
                for i in 0..<count {
                    guard case let .int(o) = p.lex.next(), case let .int(g) = p.lex.next(), case let .kw(k) = p.lex.next(),
                          k == "n" || k == "f"
                    else {
                        throw PDFError.syntax("bad xref entry", p.pos)
                    }
                    // The classic off-by-one: a table that starts at 1 but
                    // opens with object 0's free entry.
                    if i == 0, first == 1, k == "f", g == 65535, o == 0 { first = 0 }
                    let num = first + i
                    let entry: Entry = k == "n" ? .offset(o, gen: g) : .free(gen: g)
                    if entries[num] == nil {
                        entries[num] = entry
                        if k == "f" { freedHere.insert(num) }
                    }
                }
            }
            guard case let .dict(trailerDict) = try p.object() else {
                throw PDFError.syntax("trailer is not a dictionary", p.pos)
            }
            return (Section(kind: .table, offset: off, trailer: trailerDict), trailerDict["XRefStm"]?.int, freedHere)
        }
        // A cross-reference stream.
        var p = Parser(bytes, at: off)
        let (_, obj, _) = try parseIndirect(parser: &p, at: off, resolveLength: false, num: nil)
        guard case let .stream(dict, raw) = obj, dict["Type"]?.name == "XRef" else {
            throw PDFError.syntax("startxref points at neither a table nor an xref stream", off)
        }
        let data = try Filters.decode(dict, raw)
        guard let w = dict["W"]?.array?.compactMap(\.int), w.count == 3, w.allSatisfy({ $0 >= 0 && $0 <= 8 }) else {
            throw PDFError.syntax("xref stream without a usable /W", off)
        }
        let size = dict["Size"]?.int ?? 0
        let index = dict["Index"]?.array?.compactMap(\.int) ?? [0, size]
        let rowWidth = w[0] + w[1] + w[2]
        guard rowWidth > 0 else { throw PDFError.syntax("xref stream with /W [0 0 0]", off) }
        var cursor = 0
        func field(_ width: Int, default value: Int) -> Int {
            guard width > 0 else { return value }
            var v = 0
            for _ in 0..<width {
                v = (v << 8) | Int(cursor < data.count ? data[cursor] : 0)
                cursor += 1
            }
            return v
        }
        var pair = 0
        while pair + 1 < index.count {
            let first = index[pair], count = index[pair + 1]
            guard first >= 0, count >= 0, count <= 10_000_000 else { throw PDFError.syntax("/Index \(first) \(count) in xref stream", off) }
            for i in 0..<count {
                guard cursor + rowWidth <= data.count else { break }
                let type = field(w[0], default: 1)
                let f2 = field(w[1], default: 0)
                let f3 = field(w[2], default: 0)
                let num = first + i
                let entry: Entry
                switch type {
                case 0: entry = .free(gen: f3)
                case 1: entry = .offset(f2, gen: f3)
                case 2: entry = .compressed(stream: f2, index: f3)
                default: continue // reserved types are ignored
                }
                if let fill {
                    if entries[num] == nil || fill.contains(num) { entries[num] = entry }
                } else if entries[num] == nil {
                    entries[num] = entry
                    if case .free = entry { freedHere.insert(num) }
                }
            }
            pair += 2
        }
        return (Section(kind: .stream, offset: off, trailer: dict), nil, freedHere)
    }

    /// Reads "num gen obj … endobj" at an offset: the reference, the object,
    /// and where the object's value lies in the file.
    private func parseIndirect(parser p: inout Parser, at off: Int, resolveLength: Bool = true, num expected: Int?) throws -> (PDFRef, PDFObj, Range<Int>) {
        p.pos = off
        guard case let .int(num) = p.lex.next(), case let .int(gen) = p.lex.next(), case .kw("obj") = p.lex.next() else {
            throw PDFError.syntax("no object header", off)
        }
        if let expected, expected != num { throw PDFError.syntax("object \(num) where \(expected) should be", off) }
        p.lex.skipWhite()
        let bodyStart = p.pos
        let obj = try p.object()
        let bodyEnd = p.pos
        if p.sawIrregularity { irregular.insert(num) }
        guard case let .dict(dict) = obj else { return (PDFRef(num, gen), obj, bodyStart..<bodyEnd) }
        let save = p.pos
        guard case .kw("stream") = p.lex.next() else {
            p.pos = save
            return (PDFRef(num, gen), obj, bodyStart..<bodyEnd)
        }
        var start = p.pos
        if start < bytes.count, bytes[start] == 0x0D { start += 1 }
        if start < bytes.count, bytes[start] == 0x0A { start += 1 }
        var length: Int?
        switch dict["Length"] {
        case let .int(v)?: length = v
        case let .ref(r)? where resolveLength: length = (try? object(r.num))?.int
        default: length = nil
        }
        var end: Int?
        if let length, length >= 0, length <= bytes.count - start {
            var lx = Lexer(bytes, at: start + length)
            if case .kw("endstream") = lx.next() { end = start + length }
        }
        if end == nil {
            // /Length is wrong or missing: find endstream, as readers do —
            // and remember that this object was a guess.
            let needle = Array("endstream".utf8)
            var i = start
            while i + needle.count <= bytes.count {
                if bytes[i] == 0x65, matches(needle, at: i) { break }
                i += 1
            }
            var e = min(i, bytes.count)
            if e > start, bytes[e - 1] == 0x0A { e -= 1 }
            if e > start, bytes[e - 1] == 0x0D { e -= 1 }
            end = e
            note("stream \(num) length repaired")
            guessed.insert(num)
        }
        let data = Array(UnsafeBufferPointer(rebasing: bytes[start..<end!]))
        return (PDFRef(num, gen), .stream(dict, data), bodyStart..<bodyEnd)
    }

    // MARK: Repair

    /// Builds an index of every "n g obj" in the file, last one winning —
    /// what readers do with a file whose cross-reference table cannot be
    /// trusted.
    private func buildScanIndex() -> [Int: (offset: Int, gen: Int)] {
        if let scanIndex { return scanIndex }
        var index: [Int: (Int, Int)] = [:]
        let n = bytes.count
        var i = 0
        func integer(_ r: Range<Int>) -> Int? {
            guard r.count > 0, r.count < 19 else { return nil }
            var v = 0
            for k in r { v = v * 10 + Int(bytes[k] - 0x30) }
            return v
        }
        while i < n - 3 {
            // Look for "obj" preceded by "<digits> <digits> ".
            if bytes[i] == 0x6F, bytes[i + 1] == 0x62, bytes[i + 2] == 0x6A,
               i + 3 >= n || !isRegular(bytes[i + 3]) {
                var j = i - 1
                while j >= 0, isWhite(bytes[j]) { j -= 1 }
                let genEnd = j + 1
                while j >= 0, bytes[j] >= 0x30, bytes[j] <= 0x39 { j -= 1 }
                let genStart = j + 1
                if genStart < genEnd {
                    while j >= 0, isWhite(bytes[j]) { j -= 1 }
                    let numEnd = j + 1
                    while j >= 0, bytes[j] >= 0x30, bytes[j] <= 0x39 { j -= 1 }
                    let numStart = j + 1
                    if numStart < numEnd, numEnd < genStart, j < 0 || !isRegular(bytes[j]),
                       let num = integer(numStart..<numEnd), let gen = integer(genStart..<genEnd) {
                        index[num] = (numStart, gen)
                    }
                }
                i += 3
                continue
            }
            i += 1
        }
        let result = index.mapValues { (offset: $0.0, gen: $0.1) }
        scanIndex = result
        return result
    }

    private func reconstruct() throws {
        repaired = true
        let index = buildScanIndex()
        entries = index.mapValues { .offset($0.offset, gen: $0.gen) }
        // The last trailer with a /Root, or failing that a catalog.
        let needle = Array("trailer".utf8)
        var found: PDFDict?
        var i = 0
        while i + needle.count <= bytes.count {
            if bytes[i] == 0x74, matches(needle, at: i) {
                var p = Parser(bytes, at: i + needle.count)
                if case let .dict(d)? = try? p.object(), d["Root"] != nil { found = d }
            }
            i += 1
        }
        if found == nil {
            for num in index.keys.sorted() {
                if let d = (try? object(num))?.dict, d["Type"]?.name == "XRef", d["Root"] != nil { found = d }
            }
        }
        if found == nil {
            for num in index.keys.sorted() {
                if (try? object(num))?.dict?["Type"]?.name == "Catalog", let loc = index[num] {
                    found = PDFDict([("Root", .ref(PDFRef(num, loc.gen)))])
                }
            }
        }
        guard let t = found else { throw PDFError.missing("trailer") }
        for (k, v) in t.pairs where !PDFFile.sectionKeys.contains(k) {
            trailer[k] = v
        }
    }

    // MARK: Objects

    public var size: Int {
        let declared = trailer["Size"]?.int ?? 0
        let highest = (entries.keys.max() ?? 0) + 1
        return max(declared, highest)
    }

    public var isEncrypted: Bool { trailer["Encrypt"] != nil }

    public func entry(_ num: Int) -> Entry? { entries[num] }

    public func generation(of num: Int) -> Int {
        switch entries[num] {
        case let .offset(_, gen)?: gen
        default: 0
        }
    }

    public func isInUse(_ num: Int) -> Bool {
        switch entries[num] {
        case let .offset(off, _)?: off > 0
        case .compressed?: true
        default: false
        }
    }

    public func object(_ num: Int) throws -> PDFObj {
        if let hit = cache[num] {
            if guessed.contains(num) { guessedReads += 1 }
            return hit
        }
        let result: PDFObj
        switch entries[num] {
        case nil, .free?:
            result = .null
        case .offset(0, _)?:
            // Quartz leaves entries "in use at offset 0" for objects it
            // dropped — hundreds of them across ordinary files. Nothing
            // lives at offset 0 but the header; readers take them as null.
            result = .null
        case let .offset(off, gen)?:
            var p = Parser(bytes, at: off)
            var found: PDFObj
            if let (_, obj, body) = try? parseIndirect(parser: &p, at: off, num: num) {
                found = obj
                bodies[num] = body
            } else if let loc = buildScanIndex()[num] {
                var q = Parser(bytes, at: loc.offset)
                let (_, obj, _) = try parseIndirect(parser: &q, at: loc.offset, num: num)
                note("object \(num) found by scan (xref offset \(off) wrong)")
                guessed.insert(num)
                found = obj
            } else {
                throw PDFError.missing("object \(num) at \(off)")
            }
            if let security, num != trailer["Encrypt"]?.ref?.num {
                found = security.decrypting(found, as: PDFRef(num, gen))
            }
            result = found
        case let .compressed(stm, _)?:
            result = try compressedObject(num, in: stm)
        }
        if guessed.contains(num) { guessedReads += 1 }
        cache[num] = result
        return result
    }

    public func resolve(_ o: PDFObj?) throws -> PDFObj {
        guard let o else { return .null }
        if case let .ref(r) = o { return try object(r.num) }
        return o
    }

    private func loadObjectStream(_ stm: Int) throws -> ObjectStream {
        if let loaded = objectStreams[stm] { return loaded }
        guard case let .stream(dict, raw) = try object(stm) else {
            throw PDFError.syntax("object stream \(stm) is not a stream", 0)
        }
        let data = try Filters.decode(dict, raw)
        let n = dict["N"]?.int ?? 0
        let first = dict["First"]?.int ?? 0
        guard n >= 0, n <= 1_000_000, first >= 0, first <= data.count else {
            throw PDFError.syntax("object stream \(stm) with /N \(n) /First \(first)", 0)
        }
        var loaded = ObjectStream(data: data, objects: [:], spans: [:])
        data.withUnsafeBufferPointer { buffer in
            var header = Lexer(buffer)
            var offsets: [(Int, Int)] = []
            for _ in 0..<n {
                guard case let .int(on) = header.next(), case let .int(oo) = header.next(), oo >= 0 else { break }
                offsets.append((on, first + oo))
            }
            for (on, start) in offsets where start < buffer.count {
                var p = Parser(buffer, at: start)
                guard let o = try? p.object() else {
                    // Readers skip an object they cannot parse; so does this
                    // one, but it remembers that it did.
                    guessed.insert(on)
                    continue
                }
                if p.sawIrregularity { irregular.insert(on) }
                loaded.objects[on] = o
                loaded.spans[on] = start..<p.pos
            }
        }
        objectStreams[stm] = loaded
        return loaded
    }

    private func compressedObject(_ num: Int, in stm: Int) throws -> PDFObj {
        try loadObjectStream(stm).objects[num] ?? .null
    }

    /// An object's value exactly as the file writes it, and whether it came
    /// out of an object stream — for writing it back with one entry changed.
    /// Nil when the object could not be read as written. In an encrypted
    /// file the text of an uncompressed object is its ciphertext.
    func rawText(of num: Int) -> (text: [UInt8], inObjectStream: Bool)? {
        _ = try? object(num)
        // An irregular object may still be spliced — its bytes are kept as
        // they were — but one that was a guess may not.
        guard !guessed.contains(num) else { return nil }
        switch entries[num] {
        case .offset?:
            guard let body = bodies[num] else { return nil }
            return (Array(UnsafeBufferPointer(rebasing: bytes[body])), false)
        case let .compressed(stm, _)?:
            guard let loaded = objectStreams[stm], let span = loaded.spans[num] else { return nil }
            return (Array(loaded.data[span]), true)
        default:
            return nil
        }
    }

    // MARK: Page tree

    public struct PageInfo {
        public let ref: PDFRef
        public let dict: PDFDict
    }

    public func pages() throws -> [PageInfo] {
        guard let rootRef = trailer["Root"]?.ref, let catalog = try object(rootRef.num).dict else {
            throw PDFError.missing("catalog")
        }
        guard let pagesRef = catalog["Pages"]?.ref else { throw PDFError.missing("/Pages") }
        var result: [PageInfo] = []
        var visited = Set<Int>()
        func walk(_ ref: PDFRef, depth: Int) throws {
            guard depth < 64, visited.insert(ref.num).inserted else {
                throw PDFError.unsupported("page tree cycle at \(ref)")
            }
            guard let node = try object(ref.num).dict else { return }
            let type = node["Type"]?.name
            if type == "Pages" || (type == nil && node["Kids"] != nil) {
                for kid in try resolve(node["Kids"]).array ?? [] {
                    guard let r = kid.ref else { throw PDFError.unsupported("direct page object in /Kids") }
                    // A reference whose generation is not the one the table
                    // gives: readers disagree about whether that is the page.
                    if case let .offset(_, gen)? = entries[r.num], gen != r.gen {
                        throw PDFError.unsupported("/Kids says \(r), the table says generation \(gen)")
                    }
                    try walk(r, depth: depth + 1)
                }
            } else {
                result.append(PageInfo(ref: ref, dict: node))
            }
        }
        try walk(pagesRef, depth: 0)
        return result
    }
}
