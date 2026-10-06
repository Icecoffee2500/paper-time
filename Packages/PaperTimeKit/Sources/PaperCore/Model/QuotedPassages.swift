import Foundation

/// A passage of a paper that a note quotes: where its words are on the page,
/// and where the quotation stands in the note.
///
/// ⌘L writes a passage into a note as a block quote whose page link —
/// `[4쪽](papertime://anchor?p=3&x=…)` — says which page and where on it.
/// That link is the only record there is: nothing goes into the PDF, and
/// nothing beside it. So the way back from the page is found the same way,
/// by reading the notes. A quotation deleted from its note is gone from the
/// page with it, and a note that arrives from another machine brings its
/// passages along.
public struct QuotedPassage: Hashable, Sendable {
    /// The link's address as the note spells it: what the note is searched
    /// for when the quotation is to be found again.
    public var url: String
    public var anchor: NoteAnchor
    /// The `[label](address)` link, in the body's UTF-16 offsets.
    public var link: NSRange
    /// The quotation the link closes: from the first line of its block quote
    /// to the end of the link's line — or the link's own line, for a passage
    /// dropped into a sentence rather than quoted.
    public var quote: NSRange

    public init(url: String, anchor: NoteAnchor, link: NSRange, quote: NSRange) {
        self.url = url
        self.anchor = anchor
        self.link = link
        self.quote = quote
    }
}

public enum QuotedPassages {
    /// `[label](papertime://anchor?…)`. A label may hold escaped brackets —
    /// `escape` writes them so — and brackets in pairs, as the note's own
    /// renderer reads them (`NoteMarkdown.linkPattern`); never a line break.
    static let linkPattern = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\[\]\n]|\[(?:\\.|[^\\\[\]\n])*\])*)\]\((papertime://anchor[^)\s]*)\)"#
    )

    /// Every passage a note's body links to, in the order they are written.
    /// A link inside a fenced block of code is code, not a link; one whose
    /// address does not say a page and a box with some size to it is
    /// nowhere to draw.
    public static func passages(in body: String) -> [QuotedPassage] {
        guard body.contains("papertime://anchor") else { return [] }
        let text = body as NSString
        let code = NoteCode.blocks(in: body).map(\.range)
        var found: [QuotedPassage] = []
        for match in linkPattern.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            let link = match.range
            if code.contains(where: { NSLocationInRange(link.location, $0) }) { continue }
            let written = text.substring(with: match.range(at: 2))
            guard let url = URL(string: written), let anchor = NoteAnchor(url: url), anchor.pageIndex >= 0,
                  [anchor.rect.minX, anchor.rect.minY, anchor.rect.width, anchor.rect.height].allSatisfy(\.isFinite),
                  anchor.rect.width > 0, anchor.rect.height > 0
            else { continue }
            found.append(QuotedPassage(url: written, anchor: anchor, link: link, quote: quote(closedBy: link, in: text)))
        }
        return found
    }

    /// The passages a note quotes from one paper: the links that name it,
    /// and — in a note about that paper — the links that name no paper.
    /// (The Mac's ⌘L names the paper every time; the Portable build's names
    /// it only when the note is about another one.)
    public static func passages(in note: Zettel, of paperID: UUID) -> [QuotedPassage] {
        passages(in: note.body).filter { ($0.anchor.paperID ?? note.paperID) == paperID }
    }

    /// The quotation a link closes. Lines are split at `\n` only, and a
    /// `\r` before it is left out — the Portable build reads lines the same
    /// way, and the two have to agree to the unit.
    static func quote(closedBy link: NSRange, in text: NSString) -> NSRange {
        let line = self.line(at: link.location, in: text)
        guard isQuote(line, in: text) else { return line }
        var start = line.location
        while start > 0 {
            let above = self.line(at: start - 1, in: text)
            // A quote line that carries a page link of its own ends the
            // quotation before this one: two passages quoted back to back
            // run together as one block.
            guard isQuote(above, in: text), !text.substring(with: above).contains("](papertime://anchor") else { break }
            start = above.location
        }
        return NSRange(location: start, length: NSMaxRange(line) - start)
    }

    /// The line holding a character, without its line break.
    static func line(at index: Int, in text: NSString) -> NSRange {
        let newline = unichar(10), carriage = unichar(13)
        var start = min(max(index, 0), text.length)
        while start > 0, text.character(at: start - 1) != newline { start -= 1 }
        var end = min(max(index, 0), text.length)
        while end < text.length, text.character(at: end) != newline { end += 1 }
        if end > start, text.character(at: end - 1) == carriage { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// A block quote's line: up to three spaces, then `>`.
    static func isQuote(_ line: NSRange, in text: NSString) -> Bool {
        var index = line.location
        var spaces = 0
        while index < NSMaxRange(line), text.character(at: index) == 32, spaces < 3 {
            index += 1
            spaces += 1
        }
        return index < NSMaxRange(line) && text.character(at: index) == 62
    }
}
