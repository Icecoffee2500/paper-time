import Foundation
import PaperCore

// Crossref's `message` field has a different shape depending on the endpoint:
// `/works/{doi}` returns a single work object, `/works?query=...` returns a
// `{ items, total-results }` page. Rather than one polymorphic type, the two
// endpoints get two separate response envelopes — the caller already knows
// which one it hit.

/// Response envelope for `GET https://api.crossref.org/works/{doi}`.
public struct CrossrefWorkResponse: Decodable, Sendable {
    public let message: CrossrefWork
}

/// Response envelope for `GET https://api.crossref.org/works?query=...`.
public struct CrossrefWorkListResponse: Decodable, Sendable {
    public let message: CrossrefWorkListMessage
}

public struct CrossrefWorkListMessage: Decodable, Sendable {
    public let items: [CrossrefWork]?
    public let totalResults: Int?

    private enum CodingKeys: String, CodingKey {
        case items
        case totalResults = "total-results"
    }

    /// Crossref changes the shape of `message` depending on the request: a
    /// normal query returns an object with `items`, but adding `select` makes
    /// it return the array of works directly. Both are accepted here, because
    /// the difference is invisible until decoding silently fails and every
    /// search comes back empty.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            items = try container.decodeIfPresent([CrossrefWork].self, forKey: .items)
            totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults)
            return
        }
        let single = try decoder.singleValueContainer()
        items = try single.decode([CrossrefWork].self)
        totalResults = nil
    }
}

public struct CrossrefAuthor: Decodable, Sendable {
    public let given: String?
    public let family: String?
    /// Set instead of given/family for institutional authors ("The MITRE Corporation").
    public let name: String?
    public let sequence: String?
    public let orcid: String?

    private enum CodingKeys: String, CodingKey {
        case given, family, name, sequence
        case orcid = "ORCID"
    }

    func asCSLName() -> CSLName {
        if family == nil, given == nil, let name, !name.isEmpty {
            return CSLName(literal: name)
        }
        return CSLName(family: family, given: given)
    }
}

/// Crossref's `{ "date-parts": [[y, m, d]] }` shape, shared by `issued`,
/// `published`, `published-print`, and `published-online`.
public struct CrossrefDateParts: Decodable, Sendable {
    public let dateParts: [[Int]]?

    private enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
    }
}

public struct CrossrefEvent: Decodable, Sendable {
    public let name: String?
    public let location: String?
}

public struct CrossrefWork: Decodable, Sendable {
    public let doi: String?
    public let type: String?
    public let title: [String]?
    public let subtitle: [String]?
    public let containerTitle: [String]?
    public let shortContainerTitle: [String]?
    public let author: [CrossrefAuthor]?
    public let editor: [CrossrefAuthor]?
    public let issued: CrossrefDateParts?
    public let published: CrossrefDateParts?
    public let publishedPrint: CrossrefDateParts?
    public let publishedOnline: CrossrefDateParts?
    public let page: String?
    public let volume: String?
    public let issue: String?
    public let publisher: String?
    public let publisherLocation: String?
    public let issn: [String]?
    public let isbn: [String]?
    public let abstract: String?
    public let url: String?
    public let event: CrossrefEvent?
    public let articleNumber: String?
    public let language: String?
    public let score: Double?
    public let isReferencedByCount: Int?

    private enum CodingKeys: String, CodingKey {
        case doi = "DOI"
        case type, title, subtitle
        case containerTitle = "container-title"
        case shortContainerTitle = "short-container-title"
        case author, editor, issued, published
        case publishedPrint = "published-print"
        case publishedOnline = "published-online"
        case page, volume, issue, publisher
        case publisherLocation = "publisher-location"
        case issn = "ISSN"
        case isbn = "ISBN"
        case abstract
        case url = "URL"
        case event
        case articleNumber = "article-number"
        case language, score
        case isReferencedByCount = "is-referenced-by-count"
    }

    // All properties above are Optional, so the synthesized decoder already
    // calls decodeIfPresent for every key — no custom init(from:) is needed
    // to satisfy "never throw on a missing field".

    /// Maps to `CSLItem`. `score` and `is-referenced-by-count` are Crossref's
    /// own search/ranking metadata and have no CSL-JSON equivalent, so they
    /// are decoded (for callers that want relevance ranking) but dropped here.
    public func asCSLItem() -> CSLItem {
        var item = CSLItem()
        item.doi = doi
        item.type = CSLType.fromCrossref(type ?? "")
        item.title = title?.first
        item.subtitle = subtitle?.first
        item.containerTitle = containerTitle?.first
        item.containerTitleShort = shortContainerTitle?.first
        item.author = (author ?? []).map { $0.asCSLName() }
        item.editor = (editor ?? []).map { $0.asCSLName() }
        item.issued = Self.chooseDate(issued, published, publishedPrint, publishedOnline)
        item.page = page
        item.volume = volume
        item.issue = issue
        item.publisher = publisher
        item.publisherPlace = publisherLocation
        item.issn = issn?.first
        item.isbn = isbn?.first
        item.abstract = abstract.map(Self.stripJATS)
        item.url = url
        item.eventTitle = event?.name
        item.eventPlace = event?.location
        item.number = articleNumber
        item.language = language
        return item
    }

    /// Crossref exposes up to four date fields for the same work (the date it
    /// was indexed, its print date, its online-first date, ...). `issued` is
    /// the field Crossref itself recommends citing by, so it wins; the rest
    /// are fallbacks for the (common) case where `issued` is absent.
    private static func chooseDate(_ candidates: CrossrefDateParts?...) -> CSLDate? {
        for candidate in candidates {
            if let parts = candidate?.dateParts, !parts.isEmpty {
                return CSLDate(dateParts: parts)
            }
        }
        return nil
    }

    /// Crossref abstracts are JATS XML (`<jats:p>...</jats:p>`), not plain
    /// text. A full XML parse is overkill for what is effectively one or two
    /// paragraphs, so tags are stripped with a regex and the handful of
    /// entities Crossref actually emits are unescaped by hand.
    private static func stripJATS(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#38;", "&"), ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
