import Foundation
import PaperCore

/// One `<entry>` from an arXiv Atom feed (`export.arxiv.org/api/query`).
public struct ArxivEntry: Sendable {
    /// The `<id>` element — an `https://arxiv.org/abs/...` URL, not a bare id.
    public let id: String
    /// e.g. "2403.18293v1", pulled from the last path component of `id`.
    public let arxivID: String
    public let title: String
    public let summary: String
    public let authors: [String]
    public let published: Date
    public let updated: Date
    public let doi: String?
    public let journalRef: String?
    public let primaryCategory: String?
    public let categories: [String]
    public let comment: String?
    public let pdfURL: String?
}

public enum ArxivFeedParserError: Error {
    /// `XMLParser` failed without a more specific underlying error.
    case malformedFeed
}

public enum ArxivFeedParser {
    /// Parses an arXiv Atom feed into entries. Safe to call from any actor:
    /// the delegate is a plain local value, never stored globally, and
    /// `XMLParser.parse()` runs synchronously on the calling thread.
    public static func parse(_ data: Data) throws -> [ArxivEntry] {
        let delegate = ArxivAtomDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw parser.parserError ?? ArxivFeedParserError.malformedFeed
        }
        return delegate.entries
    }
}

/// Accumulates `<entry>` elements into `ArxivEntry` values. All mutable
/// parsing state lives here, isolated to one synchronous `parse()` call.
private final class ArxivAtomDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [ArxivEntry] = []

    private var inEntry = false
    private var elementText = ""

    private var id = ""
    private var title = ""
    private var summary = ""
    private var authors: [String] = []
    private var publishedRaw = ""
    private var updatedRaw = ""
    private var doi: String?
    private var journalRef: String?
    private var primaryCategory: String?
    private var categories: [String] = []
    private var comment: String?
    private var pdfURL: String?

    // ISO8601DateFormatter is a reference type Foundation does not mark
    // Sendable, so the parse strategies are used instead of shared instances.
    private static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle())
    }

    private func resetEntryState() {
        id = ""
        title = ""
        summary = ""
        authors = []
        publishedRaw = ""
        updatedRaw = ""
        doi = nil
        journalRef = nil
        primaryCategory = nil
        categories = []
        comment = nil
        pdfURL = nil
    }

    private func parseDate(_ raw: String) -> Date {
        Self.parseDate(raw)
            ?? Date(timeIntervalSince1970: 0)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementText = ""

        switch elementName {
        case "entry":
            inEntry = true
            resetEntryState()
        case "link" where inEntry:
            // The Atom feed has multiple <link> elements (alternate, pdf, doi);
            // only the one titled "pdf" is a link we want.
            if attributeDict["title"] == "pdf" {
                pdfURL = attributeDict["href"]
            }
        case "arxiv:primary_category" where inEntry:
            primaryCategory = attributeDict["term"]
        case "category" where inEntry:
            if let term = attributeDict["term"] {
                categories.append(term)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        elementText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inEntry else { return }
        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "id":
            id = text
        case "title":
            title = text
        case "summary":
            summary = text
        case "name":
            // <author><name>...</name></author> — arXiv authors have no
            // structured given/family split, only a display string.
            if !text.isEmpty { authors.append(text) }
        case "published":
            publishedRaw = text
        case "updated":
            updatedRaw = text
        case "arxiv:doi":
            doi = text.isEmpty ? nil : text
        case "arxiv:journal_ref":
            journalRef = text.isEmpty ? nil : text
        case "arxiv:comment":
            comment = text.isEmpty ? nil : text
        case "entry":
            finishEntry()
            inEntry = false
        default:
            break
        }
    }

    private func finishEntry() {
        let arxivID = URL(string: id)?.lastPathComponent ?? id
        entries.append(
            ArxivEntry(
                id: id,
                arxivID: arxivID,
                title: title,
                summary: summary,
                authors: authors,
                published: parseDate(publishedRaw),
                updated: parseDate(updatedRaw),
                doi: doi,
                journalRef: journalRef,
                primaryCategory: primaryCategory,
                categories: categories,
                comment: comment,
                pdfURL: pdfURL
            )
        )
    }
}

extension ArxivEntry {
    /// Maps to `CSLItem`. arXiv only tells you a work was later published
    /// somewhere by way of `journal_ref`/`doi` — absent both, it is still an
    /// unpublished preprint (CSL's `manuscript` type).
    public func asCSLItem() -> CSLItem {
        var item = CSLItem()
        item.doi = doi
        item.type = (doi == nil && journalRef == nil) ? .manuscript : .articleJournal
        item.title = Self.normalizeWhitespace(title)
        item.abstract = summary.isEmpty ? nil : summary
        item.author = authors.map(CSLName.parse)
        item.issued = CSLDate(dateParts: [Self.dateComponents(from: published)])
        item.url = id
        item.containerTitle = journalRef
        item.language = nil
        item.note = Self.note(arxivID: arxivID, primaryCategory: primaryCategory)
        item.version = Self.version(from: arxivID)
        return item
    }

    /// arXiv wraps titles across multiple lines in the Atom XML, leaving
    /// stray newlines and doubled spaces — collapse them for display.
    private static func normalizeWhitespace(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func note(arxivID: String, primaryCategory: String?) -> String {
        guard let primaryCategory, !primaryCategory.isEmpty else { return "arXiv:\(arxivID)" }
        return "arXiv:\(arxivID) [\(primaryCategory)]"
    }

    /// arXiv ids end in a version suffix ("2403.18293v1"); CSL's `version`
    /// wants just the number.
    private static func version(from arxivID: String) -> String? {
        guard let vRange = arxivID.range(of: "v", options: .backwards) else { return nil }
        let suffix = arxivID[vRange.upperBound...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return String(suffix)
    }

    private static func dateComponents(from date: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return [components.year, components.month, components.day].compactMap { $0 }
    }
}
