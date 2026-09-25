import Foundation
import Testing
@testable import PaperCore
#if canImport(PDFKit)
import PDFKit
#endif

/// The search index's text, held to what the index did before it was made
/// fast: the same folded text, the same way back to the original, the same
/// matches. Every one of these compares against `Reference`, which is the
/// code the index ran until now, copied here unchanged.
@Suite("Folding and scanning the words of a paper")
struct PaperTextTests {
    // MARK: - Small cases

    /// The corners the fold has rules for, and the ones it could get wrong by
    /// taking a shortcut: case, accents, width, hyphens at the end of a line
    /// (with and without spaces, tabs, CR LF, the soft hyphen and U+2010),
    /// runs of whitespace, ligatures, Hangul, emoji, combining marks after a
    /// space, and an Arabic number sign — which glues itself to the space
    /// after it, so that space is not a space of its own.
    static let corners: [String] = [
        "", " ", "  leading and trailing  ", "UN-\nLEARNING", "un-  \nlearning", "un-\t\r\nlearning",
        "soft\u{00AD}\nhyphen", "true\u{2010}\nhyphen", "not-a-break", "ends-", "ends- ", "-\n",
        "Almudévar Pérez naïve Ångström", "ＦＵＬＬ　ｗｉｄｔｈ", "ﬁne ﬂow ﬀ", "학습 방법과 학습-\n이론",
        "e\u{0301}cole", " \u{0301} lone mark", "a\u{0301}\u{0302}b", "😀 emoji 👩‍👩‍👧 family",
        "\u{0600} number sign", "\u{0600}  two spaces", "x\u{0600}\ny", "tab\there\nnew\r\nline\u{2028}sep",
        "\u{00A0}nbsp\u{00A0}", "\u{0000}\u{0001}\u{001F}\u{007F}", "¨ spacing diaeresis ´", "Σίσυφος ΣΟΦΙΑ",
        "İstanbul ıi", "ß straße", "Ǆ ǅ ǆ", "①②③ ⅰⅱ", "x²₃", "\r\n\r\n", "a\r\nb", "A-\r\nB",
    ]

    @Test("Folds the corners exactly as before")
    func corners() {
        for text in Self.corners {
            let reference = Reference.fold(text as NSString)
            #expect(Array(SearchFolding.fold(text).utf16) == Array((reference.text as String).utf16),
                    "\(text.debugDescription)")
            #expect(SearchFolding.map(text) == reference.map, "\(text.debugDescription)")
        }
    }

    @Test("Folds every ASCII character exactly as Foundation does")
    func ascii() {
        for value in 0..<128 {
            let text = "x" + String(UnicodeScalar(UInt8(value))) + "Y"
            #expect(Array(SearchFolding.fold(text).utf16) == Array((Reference.fold(text as NSString).text as String).utf16),
                    "U+\(String(value, radix: 16))")
        }
    }

    @Test("A map asked for only so far is the start of the whole map")
    func partialMaps() {
        for text in Self.corners {
            let whole = Reference.fold(text as NSString).map
            for limit in 0..<whole.count {
                let part = SearchFolding.map(text, through: limit)
                #expect(part.count > limit, "\(text.debugDescription) through \(limit)")
                #expect(Array(part.prefix(limit + 1)) == Array(whole.prefix(limit + 1)))
            }
        }
    }

    @Test("Counts and finds a needle where NSString did")
    func scanning() {
        let pages = ["unlearning un-\nlearning UNLEARNING", "nothing here", "", "learning le le le",
                     "학습 학습", "😀le😀le", "Almudévar almudevar"]
        let text = PaperText(pages: pages, stamp: .zero)
        let folded = pages.map { Reference.fold($0 as NSString).text as String }
        for query in ["unlearning", "le", "학습", "almudevar", "😀le", "zzz", "le le", "ng"] {
            let needle = Reference.fold(query as NSString).text as String
            #expect(text.search(needle) == Reference.search(needle, in: folded), "\(query)")
        }
    }

    @Test("Writes and reads back the same text")
    func roundTrip() throws {
        let pages = Self.corners
        let stamp = PaperText.Stamp(size: 123_456, modified: Date(timeIntervalSinceReferenceDate: 811_492_215.409792),
                                    extent: 120_000, head: 0xDEAD_BEEF, tail: 42)
        let made = PaperText(pages: pages, stamp: stamp)
        let read = try #require(PaperText(encoded: made.encoded()))
        #expect(read.stamp == stamp)
        #expect(read.pages.map { Array($0.utf8) } == pages.map { Array($0.utf8) })
        #expect((0..<pages.count).map { Array(read.foldedPage($0).utf8) }
                == pages.map { Array((Reference.fold($0 as NSString).text as String).utf8) })
        #expect(read.encoded() == made.encoded())
        // Anything else is not this cache's.
        #expect(PaperText(encoded: Data("{\"pages\": []}".utf8)) == nil)
        #expect(PaperText(encoded: made.encoded().dropLast()) == nil)
        let empty = PaperText(pages: [], stamp: stamp)
        #expect(PaperText(encoded: empty.encoded())?.pageCount == 0)
    }

    @Test("Tells a file that grew from one that was rewritten")
    func fingerprints() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "papertext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "paper.pdf")
        var bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: file)
        let before = try #require(PaperText.fingerprint(of: file, extent: Int64(bytes.count)))

        // An incremental save: the old bytes, then more.
        bytes.append(Data("\n1 0 obj << /Type /Annot >> endobj\n%%EOF\n".utf8))
        try bytes.write(to: file)
        let grown = try #require(PaperText.fingerprint(of: file, extent: 200_000))
        #expect(grown == before)

        // A rewrite of the same length with one byte changed near the old end.
        bytes[199_990] ^= 0xFF
        try bytes.write(to: file)
        let rewritten = try #require(PaperText.fingerprint(of: file, extent: 200_000))
        #expect(rewritten != before)

        // Shorter than the extent it is asked about: no answer, not a guess.
        try Data(count: 10).write(to: file)
        #expect(PaperText.fingerprint(of: file, extent: 200_000) == nil)
    }

    // MARK: - The corpus

    /// Every page of the corpus, read the way the index reads it — when the
    /// corpus is on this machine. It lives outside the repository.
    static let corpusFolders = ["Documents/Bookends/Attachments", "Documents/Bookends/vla"]
        .map { FileManager.default.homeDirectoryForCurrentUser.appending(path: $0, directoryHint: .isDirectory) }
    static var corpusIsHere: Bool {
        #if canImport(PDFKit)
        corpusFolders.contains { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        #else
        false
        #endif
    }

    @Test("Folds, maps and scans every page of the corpus exactly as before",
          .enabled(if: PaperTextTests.corpusIsHere))
    func corpus() throws {
        let papers = Self.readCorpus()
        let pages = papers.flatMap { $0 }
        #expect(pages.count > 1000)

        var foldedDiffer = 0
        var mapDiffer = 0
        var partDiffer = 0
        var referenceFolded: [[String]] = []
        for paper in papers {
            var foldedPages: [String] = []
            for page in paper {
                let reference = Reference.fold(page as NSString)
                let folded = SearchFolding.fold(page)
                // By the code unit, not by `==`, which would call two
                // spellings of the same accented letter equal.
                if Array(folded.utf16) != Array((reference.text as String).utf16) { foldedDiffer += 1 }
                if SearchFolding.map(page) != reference.map { mapDiffer += 1 }
                // A few places part of the way in, the way a hit asks.
                for fraction in [0.0, 0.1, 0.5, 0.97] {
                    let limit = Int(Double(reference.map.count - 1) * fraction)
                    if Array(SearchFolding.map(page, through: limit).prefix(limit + 1))
                        != Array(reference.map.prefix(limit + 1)) { partDiffer += 1 }
                }
                foldedPages.append(reference.text as String)
            }
            referenceFolded.append(foldedPages)
        }
        #expect(foldedDiffer == 0, "\(foldedDiffer) of \(pages.count) pages fold differently")
        #expect(mapDiffer == 0, "\(mapDiffer) of \(pages.count) pages map differently")
        #expect(partDiffer == 0, "\(partDiffer) partial maps differ")

        // The queries the evaluation was measured with, and words taken from
        // the text itself so that every paper has something to find.
        var queries = ["unlearning", "catastrophic forgetting", "학습", "unlernaing", "Wasserstein",
                       "forgetting catastrophic", "Almudévar", "le", "sliced wasserstein", "e.g.", "[1]"]
        for paper in referenceFolded.prefix(20) {
            if let page = paper.first(where: { $0.count > 400 }) {
                let start = page.index(page.startIndex, offsetBy: 200)
                queries.append(String(page[start...].prefix(9)))
            }
        }
        var scanned = 0
        let texts = papers.map { PaperText(pages: $0, stamp: .zero) }
        for query in queries {
            let needle = Reference.fold(query as NSString).text as String
            guard needle.utf16.count > 1 else { continue }
            for ((paper, folded), text) in zip(zip(papers, referenceFolded), texts) {
                let found = text.search(needle)
                let expected = Reference.search(needle, in: folded)
                #expect(found == expected, "“\(query)”")
                // And the way back to the page, end to end.
                if let found {
                    let original = paper[found.page] as NSString
                    let whole = Reference.fold(original).map
                    let part = SearchFolding.map(paper[found.page], through: found.location + found.length)
                    #expect(part[found.location] == whole[found.location])
                    #expect(part[found.location + found.length] == whole[found.location + found.length])
                }
                scanned += 1
            }
        }
        #expect(scanned > 100)
        print("corpus: \(papers.count) papers · \(pages.count) pages folded and mapped the same;"
              + " \(queries.count) queries scanned the same in \(scanned) paper searches")
    }

    /// The text of every PDF in the corpus, one `PDFDocument` per file, four
    /// files at a time.
    static func readCorpus() -> [[String]] {
        #if canImport(PDFKit)
        let files = corpusFolders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "pdf" }
        }
        .sorted { $0.path < $1.path }
        let lock = NSLock()
        nonisolated(unsafe) var read = [[String]](repeating: [], count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            autoreleasepool {
                guard let document = PDFDocument(url: files[index]) else { return }
                let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
                lock.lock()
                read[index] = pages
                lock.unlock()
            }
        }
        return read
        #else
        return []
        #endif
    }
}

extension PaperText.Stamp {
    static let zero = PaperText.Stamp(size: 0, modified: .distantPast, extent: 0, head: 0, tail: 0)
}

/// What the index did before, copied from `App/Model/PaperTextIndex.swift`
/// as it stood — the fold with its map, and the page-by-page literal scan.
enum Reference {
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

    /// The old `hit(for:in:)`'s scan: every page, from the start, resumed
    /// past each match.
    static func search(_ needle: String, in foldedPages: [String]) -> PaperText.Match? {
        var count = 0
        var first: (page: Int, range: NSRange)?
        for (index, text) in foldedPages.enumerated() {
            let page = text as NSString
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
        return PaperText.Match(count: count, page: first.page,
                               location: first.range.location, length: first.range.length)
    }
}
