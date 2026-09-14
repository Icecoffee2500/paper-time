import Foundation
import PDFKit

/// The words inside the papers, so search can find a sentence and not only a
/// title.
///
/// Spotlight over a library of papers is half a search: you remember that
/// somebody defined the thing, not who, and the title you are being offered
/// does not contain the word you are thinking of — the fourth page does. This
/// keeps the text of every paper so the word can be found in it, and keeps
/// enough of where it was found to walk back to it: the page, and the range of
/// characters on that page, which is all `PDFPage.selection(for:)` needs to
/// hand back the line itself.
///
/// The text is read once and kept in the caches folder, because extracting it
/// is most of a second per paper and the answer never changes while the file
/// does not. Nothing here belongs in the library folder: it is derived, it is
/// rebuildable, and a folder people sync should hold what they wrote, not what
/// we worked out.
///
/// Deliberately free of everything but Foundation and PDFKit, so the whole
/// thing can be compiled on its own and run over the real corpus from a
/// terminal — see `Scripts/search-probe.swift`.
actor PaperTextIndex {
    static let shared = PaperTextIndex()

    /// A paper as the index needs it: something to read, and something to
    /// call it in a result.
    struct Source: Sendable, Hashable {
        var id: UUID
        var url: URL
        var title: String

        init(id: UUID, url: URL, title: String) {
            self.id = id
            self.url = url
            self.title = title
        }
    }

    /// Where a word was found, in the coordinates the reader can act on.
    struct Passage: Sendable, Hashable {
        var paperID: UUID
        var pageIndex: Int
        /// Into `PDFPage.string`, which is what a selection is made from.
        var location: Int
        var length: Int
    }

    /// One paper's answer to a query: where the first match is, what it says,
    /// and how many more there are.
    struct Hit: Sendable, Hashable {
        var passage: Passage
        var title: String
        /// The sentence around the match, whitespace tidied.
        var snippet: String
        var count: Int
    }

    private var pages: [UUID: [String]] = [:]
    /// The same pages, folded for searching. Built once per paper.
    private var folded: [UUID: [NSString]] = [:]

    // MARK: - Searching

    /// Every paper that holds the query, one at a time as they are read.
    ///
    /// A stream rather than an array: the first search of a session has to
    /// open every PDF in the library, and a palette that shows the first
    /// paper after a hundred milliseconds is a different thing from one that
    /// shows nothing for eight seconds. Order the sources by what the reader
    /// touched last and the answer they wanted is usually the first to land.
    nonisolated func hits(for query: String, in sources: [Source]) -> AsyncStream<Hit> {
        AsyncStream { continuation in
            let work = Task {
                let needle = Self.fold(query as NSString).text as String
                guard needle.utf16.count > 1 else {
                    continuation.finish()
                    return
                }
                for source in sources {
                    if Task.isCancelled { break }
                    if let hit = await self.hit(for: needle, in: source) {
                        continuation.yield(hit)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Reads the papers without searching them, so the first query does not
    /// have to wait for the library.
    ///
    /// One paper per call on purpose: an actor doing a whole library inside a
    /// single method is an actor answering nothing else for fifteen seconds,
    /// and the thing it would not be answering is the query the reader is
    /// typing. Between papers a search gets its turn.
    nonisolated func warm(_ sources: [Source]) -> Task<Void, Never> {
        Task {
            for source in sources {
                if Task.isCancelled { return }
                await self.load(source)
            }
        }
    }

    func load(_ source: Source) { _ = text(of: source) }

    func hit(for needle: String, in source: Source) -> Hit? {
        guard needle.utf16.count > 1 else { return nil }
        let pages = text(of: source)
        guard !pages.isEmpty else { return nil }
        let foldedPages = foldedText(of: source, pages: pages)

        var count = 0
        var first: (page: Int, range: NSRange)?
        for (index, page) in foldedPages.enumerated() {
            var from = 0
            while from < page.length {
                let found = page.range(
                    of: needle, options: .literal,
                    range: NSRange(location: from, length: page.length - from)
                )
                guard found.location != NSNotFound else { break }
                count += 1
                if first == nil { first = (index, found) }
                from = found.location + max(found.length, 1)
            }
        }
        guard let first, count > 0 else { return nil }

        // The map is only built for the page that answered: one array of
        // offsets per page of the library would be more memory than the text.
        let original = pages[first.page] as NSString
        let mapped = Self.fold(original)
        let start = first.range.location < mapped.map.count
            ? mapped.map[first.range.location] : 0
        let end = first.range.location + first.range.length < mapped.map.count
            ? mapped.map[first.range.location + first.range.length] : original.length
        let range = NSRange(location: start, length: max(end - start, 1))

        return Hit(
            passage: Passage(paperID: source.id, pageIndex: first.page,
                             location: range.location, length: range.length),
            title: source.title,
            snippet: Self.snippet(around: range, in: original),
            count: count
        )
    }

    /// Where a passage sits on its page, so the reader can be sent there.
    ///
    /// The document is opened again rather than kept: this happens once, when
    /// a result is chosen, and holding sixty PDFs open to save it would be a
    /// poor trade.
    func rect(for passage: Passage, at url: URL) -> CGRect? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: passage.pageIndex),
              let selection = page.selection(
                  for: NSRange(location: passage.location, length: passage.length)
              )
        else { return nil }
        let bounds = selection.bounds(for: page)
        return bounds.isEmpty ? nil : bounds
    }

    // MARK: - The text itself

    private func text(of source: Source) -> [String] {
        if let known = pages[source.id] { return known }
        let stamp = Self.stamp(of: source.url)
        if let cached = Self.readCache(source.id), cached.matches(stamp) {
            pages[source.id] = cached.pages
            return cached.pages
        }
        // Not remembered when it fails: a paper the cloud has not brought
        // down yet is a paper that will read fine in a minute.
        guard let document = PDFDocument(url: source.url) else { return [] }
        var read: [String] = []
        read.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            read.append(document.page(at: index)?.string ?? "")
        }
        pages[source.id] = read
        Self.writeCache(Cached(size: stamp.size, modified: stamp.modified, pages: read),
                        for: source.id)
        return read
    }

    private func foldedText(of source: Source, pages: [String]) -> [NSString] {
        if let known = folded[source.id] { return known }
        let made = pages.map { Self.fold($0 as NSString).text }
        folded[source.id] = made
        return made
    }

    // MARK: - Folding

    /// The text as it is searched: one case, no accents, no line breaks, and
    /// no hyphen where a word was broken across two lines.
    ///
    /// That last one is why this exists at all. A paper sets "un-\nlearning"
    /// at the end of a line, and a reader looking for "unlearning" does not
    /// care. The offsets travel with the text so a match can be pointed back
    /// at the characters it came from: `map[i]` is where the i-th character
    /// of the folded text began in the original.
    static func fold(_ text: NSString) -> (text: NSString, map: [Int]) {
        let characters = Array(text as String)
        var offsets: [Int] = []
        offsets.reserveCapacity(characters.count)
        var offset = 0
        for character in characters {
            offsets.append(offset)
            offset += character.utf16.count
        }

        var out = ""
        out.reserveCapacity(characters.count)
        var map: [Int] = []
        map.reserveCapacity(characters.count)

        func put(_ piece: String, from origin: Int) {
            out += piece
            for _ in 0..<piece.utf16.count { map.append(origin) }
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            // A hyphen at the end of a line is the printer's, not the
            // author's: it joins rather than separates.
            if character == "-" || character == "\u{00AD}" || character == "\u{2010}" {
                var ahead = index + 1
                while ahead < characters.count,
                      characters[ahead] == " " || characters[ahead] == "\t" { ahead += 1 }
                if ahead < characters.count, characters[ahead].isNewline {
                    index = ahead + 1
                    continue
                }
            }

            if character.isWhitespace {
                if !out.isEmpty, !out.hasSuffix(" ") { put(" ", from: offsets[index]) }
                index += 1
                continue
            }

            let piece = String(character).folding(
                options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: nil
            )
            put(piece.isEmpty ? String(character) : piece, from: offsets[index])
            index += 1
        }
        map.append(text.length)
        return (out as NSString, map)
    }

    /// The words around a match, as they are set on the page.
    static func snippet(around range: NSRange, in text: NSString,
                        room: Int = 64) -> String {
        let start = max(range.location - room, 0)
        let end = min(range.location + range.length + room, text.length)
        var piece = text.substring(with: NSRange(location: start, length: end - start))
        piece = piece.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        // Half a word at either end reads as a typo; a leading ellipsis reads
        // as "this goes on".
        if start > 0, let space = piece.firstIndex(of: " "), piece.count > 12 {
            piece = String(piece[piece.index(after: space)...])
        }
        if end < text.length, let space = piece.lastIndex(of: " "), piece.count > 12 {
            piece = String(piece[..<space])
        }
        return (start > 0 ? "…" : "") + piece + (end < text.length ? "…" : "")
    }

    // MARK: - Keeping it

    private struct Cached: Codable {
        var size: Int64
        var modified: Date
        var pages: [String]

        func matches(_ stamp: (size: Int64, modified: Date)) -> Bool {
            size == stamp.size && abs(modified.timeIntervalSince(stamp.modified)) < 1
        }
    }

    private static func stamp(of url: URL) -> (size: Int64, modified: Date) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return base.appending(path: "PaperTime/Text", directoryHint: .isDirectory)
    }

    private static func readCache(_ id: UUID) -> Cached? {
        let url = directory.appending(path: "\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private static func writeCache(_ entry: Cached, for id: UUID) {
        let folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: folder.appending(path: "\(id.uuidString).json"), options: .atomic)
    }
}
