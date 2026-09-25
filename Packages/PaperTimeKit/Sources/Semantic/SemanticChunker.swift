import CryptoKit
import Foundation

/// What a vector is stored under: the first 128 bits of the SHA-256 of the
/// passage's text.
///
/// Keyed by the text and nothing else — not by paper, not by page — so that
/// a page whose text changed re-embeds only the passages that actually
/// changed, and a paper that exists twice in the folder costs one vector per
/// passage, not two. SHA-256 rather than `Hasher` because the key is written
/// to disk and read back in another launch, where `Hasher`'s seed is new.
public struct ChunkKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init(text: String) {
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        var high: UInt64 = 0
        var low: UInt64 = 0
        for index in 0..<8 {
            high = high << 8 | UInt64(digest[index])
            low = low << 8 | UInt64(digest[index + 8])
        }
        self.init(high: high, low: low)
    }

    public var description: String {
        String(format: "%016llx%016llx", high, low)
    }
}

/// A passage of one page: what gets a vector, and where to go when it is
/// chosen.
///
/// `location`/`length` are UTF-16 offsets into that page's text, from the
/// first word's first character to the last word's last — the same units as
/// a literal hit's `NSRange`, so choosing a passage jumps exactly as choosing
/// a literal hit does.
public struct SemanticChunk: Hashable, Sendable, Codable {
    public var paperID: UUID
    public var pageIndex: Int
    public var location: Int
    public var length: Int
    /// The passage's words joined by single spaces. The tokenizer reads any
    /// white space as a word break, so this embeds exactly as the page's own
    /// text would, and the key does not change when a re-extraction moves a
    /// line break.
    public var text: String
    public var key: ChunkKey

    /// A passage put back together from what a manifest kept of it — its
    /// place and its words — so that a vector the store has lost can be made
    /// again without cutting the page afresh.
    public init(paperID: UUID, pageIndex: Int, location: Int, length: Int, text: String, key: ChunkKey) {
        self.paperID = paperID
        self.pageIndex = pageIndex
        self.location = location
        self.length = length
        self.text = text
        self.key = key
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Cuts a page into overlapping windows of words.
///
/// About 100 words with 25 of overlap. The model reads at most 256 tokens and
/// quietly drops the rest: windows of 150 words ran past that 31% of the time,
/// so the end of those passages was never seen by anything. 100 words of
/// English is about 130 tokens, which leaves room for the formulas and URLs
/// that tokenize long. The overlap is so that a sentence cut by one window's
/// edge is whole in the next.
///
/// A word is a run of characters that are not Unicode white space. The last
/// window ends at the page's last word, so the tail of a page is never
/// dropped, and a page with no words has no passages.
public enum SemanticChunker {
    public static let windowWords = 100
    public static let overlapWords = 25

    public static func chunks(
        ofPage text: String,
        paperID: UUID,
        pageIndex: Int,
        windowWords: Int = SemanticChunker.windowWords,
        overlapWords: Int = SemanticChunker.overlapWords
    ) -> [SemanticChunk] {
        windows(of: text, windowWords: windowWords, overlapWords: overlapWords).map {
            SemanticChunk(paperID: paperID, pageIndex: pageIndex, location: $0.location,
                          length: $0.length, text: $0.text, key: $0.key)
        }
    }

    /// A window of words in a text that is not a page: a note.
    ///
    /// The same cut as a page's — the same width, the same overlap, the
    /// same key for the same words — with nowhere to be but an offset into
    /// the text it was cut from.
    public struct Window: Hashable, Sendable {
        /// UTF-16 offsets into the text, first word's first character to
        /// last word's last.
        public var location: Int
        public var length: Int
        public var text: String
        public var key: ChunkKey

        public var range: NSRange { NSRange(location: location, length: length) }
    }

    /// The note's passages. The note is one text, not pages, so the windows
    /// run across headings and paragraphs the way they run across a page's
    /// columns; a note shorter than a window is one passage.
    public static func chunks(ofNote markdown: String) -> [Window] {
        windows(of: NoteText.plain(markdown))
    }

    public static func windows(
        of text: String,
        windowWords: Int = SemanticChunker.windowWords,
        overlapWords: Int = SemanticChunker.overlapWords
    ) -> [Window] {
        let words = self.words(in: text)
        guard !words.isEmpty, windowWords > 0 else { return [] }
        let stride = max(windowWords - max(overlapWords, 0), 1)
        let utf16 = text.utf16
        var windows: [Window] = []
        var start = 0
        while true {
            let end = min(start + windowWords, words.count)
            let pieces = words[start..<end].map { range -> Substring in
                let from = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
                let to = utf16.index(from, offsetBy: range.count)
                return text[from..<to]
            }
            let joined = pieces.joined(separator: " ")
            let location = words[start].lowerBound
            windows.append(Window(
                location: location,
                length: words[end - 1].upperBound - location,
                text: joined,
                key: ChunkKey(text: joined)
            ))
            if end == words.count { break }
            start += stride
        }
        return windows
    }

    /// Each word's UTF-16 range on the page.
    static func words(in text: String) -> [Range<Int>] {
        var words: [Range<Int>] = []
        var offset = 0
        var start: Int?
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if scalar.properties.isWhitespace {
                if let begun = start { words.append(begun..<offset) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let begun = start { words.append(begun..<offset) }
        return words
    }
}
