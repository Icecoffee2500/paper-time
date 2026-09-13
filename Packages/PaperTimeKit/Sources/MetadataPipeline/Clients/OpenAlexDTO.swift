import Foundation
import PaperCore

/// Response envelope for `GET https://api.openalex.org/works?...`.
public struct OpenAlexWorkList: Decodable, Sendable {
    public let results: [OpenAlexWork]?
    public let meta: OpenAlexMeta?
}

public struct OpenAlexMeta: Decodable, Sendable {
    public let count: Int?
}

public struct OpenAlexSource: Decodable, Sendable {
    public let displayName: String?
    public let issnL: String?
    public let issn: [String]?
    public let publisher: String?
    public let type: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case issnL = "issn_l"
        case issn, publisher, type
    }
}

public struct OpenAlexLocation: Decodable, Sendable {
    public let source: OpenAlexSource?
    public let landingPageURL: String?
    public let pdfURL: String?

    private enum CodingKeys: String, CodingKey {
        case source
        case landingPageURL = "landing_page_url"
        case pdfURL = "pdf_url"
    }
}

public struct OpenAlexAuthor: Decodable, Sendable {
    public let displayName: String?
    public let orcid: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case orcid
    }
}

public struct OpenAlexInstitution: Decodable, Sendable {
    public let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

public struct OpenAlexAuthorship: Decodable, Sendable {
    public let author: OpenAlexAuthor?
    public let institutions: [OpenAlexInstitution]?
    public let authorPosition: String?

    private enum CodingKeys: String, CodingKey {
        case author, institutions
        case authorPosition = "author_position"
    }
}

public struct OpenAlexBiblio: Decodable, Sendable {
    public let volume: String?
    public let issue: String?
    public let firstPage: String?
    public let lastPage: String?

    private enum CodingKeys: String, CodingKey {
        case volume, issue
        case firstPage = "first_page"
        case lastPage = "last_page"
    }
}

public struct OpenAlexIDs: Decodable, Sendable {
    public let openalex: String?
    public let doi: String?
    public let pmid: String?
    public let mag: String?
}

public struct OpenAlexWork: Decodable, Sendable {
    public let id: String?
    /// A full `https://doi.org/10.xxxx/...` URL, not a bare DOI.
    public let doi: String?
    public let title: String?
    public let displayName: String?
    public let publicationYear: Int?
    public let publicationDate: String?
    public let type: String?
    public let primaryLocation: OpenAlexLocation?
    public let authorships: [OpenAlexAuthorship]?
    public let biblio: OpenAlexBiblio?
    public let language: String?
    public let ids: OpenAlexIDs?
    public let bestOaLocation: OpenAlexLocation?

    private enum CodingKeys: String, CodingKey {
        case id, doi, title
        case displayName = "display_name"
        case publicationYear = "publication_year"
        case publicationDate = "publication_date"
        case type
        case primaryLocation = "primary_location"
        case authorships, biblio, language, ids
        case bestOaLocation = "best_oa_location"
    }

    // Every property is Optional, so the synthesized decoder already uses
    // decodeIfPresent for each key — no hand-written init(from:) is needed.

    /// Maps to `CSLItem`. `institutions`, `author_position`, and the
    /// secondary OpenAlex/MAG ids have no CSL-JSON equivalent and are dropped.
    public func asCSLItem() -> CSLItem {
        var item = CSLItem()
        item.doi = doi.map(Self.stripDOIPrefix)
        item.title = title ?? displayName
        item.type = Self.cslType(for: type)
        item.containerTitle = primaryLocation?.source?.displayName
        item.issn = primaryLocation?.source?.issnL ?? primaryLocation?.source?.issn?.first
        item.publisher = primaryLocation?.source?.publisher
        item.url = primaryLocation?.landingPageURL ?? bestOaLocation?.landingPageURL
        item.author = (authorships ?? []).compactMap { authorship in
            authorship.author?.displayName.map(CSLName.parse)
        }
        item.volume = biblio?.volume
        item.issue = biblio?.issue
        item.page = Self.pageRange(first: biblio?.firstPage, last: biblio?.lastPage)
        item.language = language
        item.pmid = ids?.pmid.map(Self.stripPMIDPrefix)
        item.issued = Self.chooseDate(publicationDate: publicationDate, publicationYear: publicationYear)
        return item
    }

    private static func stripDOIPrefix(_ raw: String) -> String {
        let prefix = "https://doi.org/"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    private static func stripPMIDPrefix(_ raw: String) -> String {
        let prefix = "https://pubmed.ncbi.nlm.nih.gov/"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    private static func pageRange(first: String?, last: String?) -> String? {
        if let first, let last, !first.isEmpty, !last.isEmpty {
            return "\(first)-\(last)"
        }
        return first
    }

    /// `publication_date` ("YYYY-MM-DD") is more granular than
    /// `publication_year`, so it wins when present; the year alone is still
    /// enough to build a usable (year-only) CSL date.
    private static func chooseDate(publicationDate: String?, publicationYear: Int?) -> CSLDate? {
        if let publicationDate {
            let parts = publicationDate.split(separator: "-").compactMap { Int($0) }
            if !parts.isEmpty {
                return CSLDate(dateParts: [parts])
            }
        }
        if let publicationYear {
            return CSLDate(year: publicationYear)
        }
        return nil
    }

    /// Best-effort mapping from an OpenAlex work `type` string.
    private static func cslType(for raw: String?) -> CSLType {
        switch raw {
        case "article": .articleJournal
        case "preprint": .manuscript
        case "book-chapter": .chapter
        case "book": .book
        case "dissertation": .thesis
        case "dataset": .dataset
        case "report": .report
        case "proceedings-article": .paperConference
        default: .other
        }
    }
}
