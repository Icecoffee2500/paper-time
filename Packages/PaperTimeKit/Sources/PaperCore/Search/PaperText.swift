import Foundation

/// The words of one paper, kept the way a search reads them.
///
/// Two copies of every page sit side by side: the text as `PDFPage.string`
/// gave it, which is what a selection is made from and what a result quotes,
/// and the same text *folded* — one case, no accents, no line breaks, no
/// hyphen where a word was broken across two lines — which is what a query is
/// matched against. Both are kept as UTF-8 in one buffer.
///
/// The folded copy used to be worked out afresh in every session, the first
/// time anybody searched, for every page of the library: 2.4 seconds for
/// sixty-three papers before the first answer, every launch, for a result that
/// never changes while the file does not. Now it is worked out once, when the
/// text is read, and kept with it.
///
/// Foundation and nothing else, so the index can still be compiled on its own
/// and run over the corpus from a terminal (`Scripts/search-probe.swift`).
public struct PaperText: Sendable {
    /// What the text was read from, so it can be told whether it still
    /// describes the file.
    public var stamp: Stamp

    /// Every page, original then folded, back to back.
    let storage: Data
    /// Where page `i` starts and ends in `storage`, for each copy.
    let original: [Range<Int>]
    let folded: [Range<Int>]

    public var pageCount: Int { original.count }

    /// Builds the text of a paper from its pages as they were read.
    public init(pages: [String], stamp: Stamp) {
        self.init(pages: pages, folded: pages.map(SearchFolding.fold), stamp: stamp)
    }

    init(pages: [String], folded foldedPages: [String], stamp: Stamp) {
        var bytes = Data()
        var original: [Range<Int>] = []
        var folded: [Range<Int>] = []
        original.reserveCapacity(pages.count)
        folded.reserveCapacity(pages.count)
        for page in pages {
            let start = bytes.count
            bytes.append(contentsOf: page.utf8)
            original.append(start..<bytes.count)
        }
        for page in foldedPages {
            let start = bytes.count
            bytes.append(contentsOf: page.utf8)
            folded.append(start..<bytes.count)
        }
        self.storage = bytes
        self.original = original
        self.folded = folded
        self.stamp = stamp
    }

    private init(storage: Data, original: [Range<Int>], folded: [Range<Int>], stamp: Stamp) {
        self.storage = storage
        self.original = original
        self.folded = folded
        self.stamp = stamp
    }

    /// A page as `PDFPage.string` gave it.
    public func page(_ index: Int) -> String {
        guard original.indices.contains(index) else { return "" }
        return storage.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[original[index]]), as: UTF8.self)
        }
    }

    /// Every page as `PDFPage.string` gave it.
    public var pages: [String] { (0..<pageCount).map(page) }

    /// A page as it is searched.
    public func foldedPage(_ index: Int) -> String {
        guard folded.indices.contains(index) else { return "" }
        return storage.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[folded[index]]), as: UTF8.self)
        }
    }

    /// How the text was measured against the file it came from.
    public struct Stamp: Sendable, Equatable {
        /// The size and modification date the file had when it was last
        /// known to hold this text.
        public var size: Int64
        public var modified: Date
        /// How long the file was when the text was read, and a fingerprint of
        /// its first and last 64 KB then. A file that has only grown since —
        /// an incremental save appends and leaves every earlier byte where it
        /// was — still starts with exactly those bytes.
        public var extent: Int64
        public var head: UInt64
        public var tail: UInt64

        public init(size: Int64, modified: Date, extent: Int64, head: UInt64, tail: UInt64) {
            self.size = size
            self.modified = modified
            self.extent = extent
            self.head = head
            self.tail = tail
        }

        /// Whether the file still has the size and date it had — the old
        /// rule, which is all a rewrite leaves to go on.
        public func matches(size: Int64, modified: Date) -> Bool {
            self.size == size && abs(self.modified.timeIntervalSince(modified)) < 1
        }
    }

    // MARK: - Searching

    /// Where a folded needle first falls in the folded text, and how many
    /// times it falls there in all.
    public struct Match: Sendable, Equatable {
        public var count: Int
        public var page: Int
        /// In UTF-16 units into the folded page, which is the unit the map
        /// back to the original is kept in.
        public var location: Int
        public var length: Int
    }

    /// Counts the needle across every page and says where it first appears.
    ///
    /// The same answer `NSString.range(of:options: .literal)` gave, walked
    /// page by page from the start and resumed just past each match — but
    /// over UTF-8 with `memmem`, which was the difference between 31–44 ms
    /// and 4–6 ms for the corpus. A valid UTF-8 needle can only match at the
    /// start of a character, as a UTF-16 one can, so the matches are the
    /// same matches.
    public func search(_ needle: String) -> Match? {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return nil }
        let length = needle.utf16.count
        return storage.withUnsafeBytes { raw -> Match? in
            guard let base = raw.baseAddress else { return nil }
            return pattern.withUnsafeBytes { needleBytes -> Match? in
                guard let needleBase = needleBytes.baseAddress else { return nil }
                var count = 0
                var first: (page: Int, byte: Int)?
                for (index, range) in folded.enumerated() {
                    var from = range.lowerBound
                    while range.upperBound - from >= pattern.count {
                        guard let found = memmem(base + from, range.upperBound - from,
                                                 needleBase, pattern.count)
                        else { break }
                        let at = base.distance(to: UnsafeRawPointer(found))
                        count += 1
                        if first == nil { first = (index, at - range.lowerBound) }
                        from = at + pattern.count
                    }
                }
                guard let first else { return nil }
                let start = folded[first.page].lowerBound
                return Match(
                    count: count,
                    page: first.page,
                    location: Self.utf16Count(of: UnsafeRawBufferPointer(
                        rebasing: raw[start..<(start + first.byte)])),
                    length: length
                )
            }
        }
    }

    /// How many UTF-16 units a run of UTF-8 takes: one for every character
    /// that starts in it, and one more for each that needs four bytes.
    static func utf16Count(of bytes: UnsafeRawBufferPointer) -> Int {
        var units = 0
        for byte in bytes where byte & 0xC0 != 0x80 {
            units += byte >= 0xF0 ? 2 : 1
        }
        return units
    }

    // MARK: - On disk

    /// The file format, which is nobody's but this cache's: a header, the
    /// length of every page in each copy, then the bytes.
    ///
    /// Binary rather than JSON because a JSON decoder turns ten megabytes of
    /// text into strings before anybody has asked for one of them, and this
    /// is read at the moment somebody is waiting for their first result. As
    /// it is, reading a paper's text back is reading a file.
    private static let magic: UInt32 = 0x5854_5450 // "PTTX", little-endian
    private static let version: UInt32 = 1

    public func encoded() -> Data {
        var out = Data()
        out.reserveCapacity(64 + 8 * pageCount + storage.count)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        put(Self.magic)
        put(Self.version)
        put(stamp.size)
        put(stamp.modified.timeIntervalSinceReferenceDate.bitPattern)
        put(stamp.extent)
        put(stamp.head)
        put(stamp.tail)
        put(UInt32(pageCount))
        for range in original { put(UInt32(range.count)) }
        for range in folded { put(UInt32(range.count)) }
        if let first = original.first, let last = folded.last {
            out.append(storage[first.lowerBound..<last.upperBound])
        }
        return out
    }

    /// Reads back what `encoded()` wrote, or nil for anything else: a file
    /// from another version, a file cut short. A cache that cannot be read is
    /// a cache that is read again from the paper.
    public init?(encoded data: Data) {
        var cursor = data.startIndex
        func take<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard data.endIndex - cursor >= size else { return nil }
            var value = T.zero
            withUnsafeMutableBytes(of: &value) { target in
                data.copyBytes(to: target.bindMemory(to: UInt8.self), from: cursor..<(cursor + size))
            }
            cursor += size
            return T(littleEndian: value)
        }
        guard take(UInt32.self) == Self.magic, take(UInt32.self) == Self.version,
              let size = take(Int64.self), let modified = take(UInt64.self),
              let extent = take(Int64.self), let head = take(UInt64.self),
              let tail = take(UInt64.self), let pages = take(UInt32.self)
        else { return nil }
        var lengths: [Int] = []
        lengths.reserveCapacity(Int(pages) * 2)
        for _ in 0..<(Int(pages) * 2) {
            guard let length = take(UInt32.self) else { return nil }
            lengths.append(Int(length))
        }
        guard lengths.reduce(0, +) == data.endIndex - cursor else { return nil }
        // The bytes stay where they were read — a mapped file stays mapped,
        // and a page is decoded only when somebody asks for it. The ranges
        // point into the whole file, header and all, so they have to count
        // from its first byte.
        let storage = data.startIndex == 0 ? data : Data(data)
        var original: [Range<Int>] = []
        var folded: [Range<Int>] = []
        var at = cursor - data.startIndex
        for (index, length) in lengths.enumerated() {
            let range = at..<(at + length)
            if index < Int(pages) { original.append(range) } else { folded.append(range) }
            at += length
        }
        self.init(
            storage: storage, original: original, folded: folded,
            stamp: Stamp(size: size, modified: Date(timeIntervalSinceReferenceDate: Double(bitPattern: modified)),
                         extent: extent, head: head, tail: tail)
        )
    }

    // MARK: - Fingerprints

    /// How much of each end of a file its fingerprint reads.
    public static let fingerprintSpan = 64 * 1024

    /// The fingerprint of the first `extent` bytes of a file: a hash of its
    /// first 64 KB and one of the 64 KB that end at `extent`. Two reads,
    /// never the whole file — on a cloud folder every byte read is a byte
    /// fetched.
    public static func fingerprint(of url: URL, extent: Int64) -> (head: UInt64, tail: UInt64)? {
        guard extent >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let span = Int64(fingerprintSpan)
        do {
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: Int(min(span, extent))) ?? Data()
            let tailStart = max(0, extent - span)
            try handle.seek(toOffset: UInt64(tailStart))
            let tail = try handle.read(upToCount: Int(extent - tailStart)) ?? Data()
            guard head.count == Int(min(span, extent)), tail.count == Int(extent - tailStart)
            else { return nil }
            return (hash(head), hash(tail))
        } catch {
            return nil
        }
    }

    /// FNV-1a, 64-bit. Not a defence against anybody: it tells a file that
    /// was appended to from one that was rewritten, and a rewrite that kept
    /// the same bytes at both ends of the old length is not a thing any
    /// writer does by accident.
    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { bytes in
            var value: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 0x0000_0100_0000_01B3
            }
            return value
        }
    }
}

/// Folding text for search, and finding the way back from folded text to the
/// characters it came from.
public enum SearchFolding {
    /// The text as it is searched: one case, no accents, no line breaks, and
    /// no hyphen where a word was broken across two lines.
    ///
    /// That last one is why this exists at all. A paper sets "un-\nlearning"
    /// at the end of a line, and a reader looking for "unlearning" does not
    /// care.
    ///
    /// Character for character the same as the fold this replaced, which
    /// asked Foundation to fold every character on its own — including the
    /// nineteen in twenty that are plain ASCII, where folding is lowering the
    /// case of a letter. Those are done here now, and the rest still go to
    /// Foundation one at a time. Folding a whole page in one call would be
    /// faster again and is not the same: it decides some characters by their
    /// neighbours, and eleven pages of the corpus came out differently.
    public static func fold(_ text: String) -> String {
        var walk = Walk(text: text, limit: nil)
        walk.run()
        return String(decoding: walk.out, as: UTF8.self)
    }

    /// Where each character of the folded text began in the original, in
    /// UTF-16 units: `map[i]` for the i-th unit of the folded text, and one
    /// more at the end for the end of the original.
    ///
    /// Only as far as it is asked for. A match on page nine needs to know
    /// where its first and last characters came from, not where the rest of
    /// the page did, and working out the whole page for every hit was most of
    /// what a search cost once the text itself was quick to scan. Past
    /// `limit` units the walk stops; what it gives up to there is exactly
    /// what the whole walk would have.
    public static func map(_ text: String, through limit: Int? = nil) -> [Int] {
        var walk = Walk(text: text, limit: limit ?? .max)
        walk.run()
        return walk.map
    }

    /// One pass over the characters of a page, with or without the map.
    private struct Walk {
        let characters: [Character]
        let length: Int
        /// When set, the map is kept, and the walk stops once it holds more
        /// than this many entries.
        let limit: Int?
        var out: [UInt8] = []
        var map: [Int] = []

        init(text: String, limit: Int?) {
            characters = Array(text)
            length = text.utf16.count
            self.limit = limit
            out.reserveCapacity(text.utf8.count)
            if let limit { map.reserveCapacity(min(limit, length) + 2) }
        }

        mutating func run() {
            var index = 0
            var origin = 0
            let count = characters.count
            while index < count {
                if let limit, map.count > limit { return }
                let character = characters[index]

                // A hyphen at the end of a line is the printer's, not the
                // author's: it joins rather than separates.
                if character == "-" || character == "\u{00AD}" || character == "\u{2010}" {
                    var ahead = index + 1
                    while ahead < count,
                          characters[ahead] == " " || characters[ahead] == "\t" { ahead += 1 }
                    if ahead < count, characters[ahead].isNewline {
                        for skipped in index...ahead { origin += characters[skipped].utf16.count }
                        index = ahead + 1
                        continue
                    }
                }

                let width = character.utf16.count
                if character.isWhitespace {
                    if !out.isEmpty, !endsInSpace {
                        out.append(0x20)
                        if limit != nil { map.append(origin) }
                    }
                    origin += width
                    index += 1
                    continue
                }

                // What Foundation's fold does to ASCII, without asking it:
                // a capital becomes small, and nothing else changes. After
                // the whitespace above, a character with an ASCII value is a
                // single ASCII scalar — the one exception, CR LF, is
                // whitespace.
                if let ascii = character.asciiValue {
                    out.append(ascii >= 0x41 && ascii <= 0x5A ? ascii + 0x20 : ascii)
                    if limit != nil { map.append(origin) }
                } else {
                    let folded = String(character).folding(
                        options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                        locale: nil
                    )
                    let piece = folded.isEmpty ? String(character) : folded
                    out.append(contentsOf: piece.utf8)
                    if limit != nil {
                        for _ in 0..<piece.utf16.count { map.append(origin) }
                    }
                }
                origin += width
                index += 1
            }
            if limit != nil { map.append(length) }
        }

        /// Whether what has been written so far ends in a space that stands
        /// on its own — which is what `hasSuffix(" ")` on the folded string
        /// answered, character by character.
        ///
        /// A space is its own character unless the scalar before it is one
        /// that prepends itself to whatever follows (an Arabic number sign,
        /// say). Nothing ASCII does, so the question only needs asking of the
        /// rare letter that is not.
        private var endsInSpace: Bool {
            guard out.last == 0x20 else { return false }
            guard out.count > 1 else { return true }
            var start = out.count - 2
            if out[start] < 0x80 { return true }
            while start > 0, out[start] & 0xC0 == 0x80 { start -= 1 }
            let pair = String(decoding: out[start...], as: UTF8.self)
            return pair.count == 2
        }
    }
}
