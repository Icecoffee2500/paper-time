import Foundation

/// The canonical bibliographic record for one paper, in CSL-JSON shape.
///
/// Paper Time treats CSL-JSON as the source of truth because every citation
/// style and every export format (BibTeX included) can be derived from it,
/// while the reverse is lossy.
public struct CSLItem: Codable, Hashable, Sendable {
    /// Citation key. Matches `PaperMeta.bibKey`; kept here so an exported
    /// CSL-JSON file is self-contained.
    public var id: String
    public var type: CSLType

    public var title: String?
    public var subtitle: String?
    public var shortTitle: String?

    public var author: [CSLName]
    public var editor: [CSLName]

    public var issued: CSLDate?
    public var accessed: CSLDate?

    /// Journal name, proceedings title, or the book title for a chapter.
    public var containerTitle: String?
    /// Abbreviated journal name, when the source provides one.
    public var containerTitleShort: String?
    /// Series title ("Lecture Notes in Computer Science").
    public var collectionTitle: String?
    /// Conference name, when distinct from the proceedings title.
    public var eventTitle: String?
    public var eventPlace: String?

    public var publisher: String?
    public var publisherPlace: String?

    public var volume: String?
    public var issue: String?
    public var page: String?
    public var numberOfPages: String?
    /// Report/technical-report number, or article number for journals that use one.
    public var number: String?
    public var edition: String?
    public var version: String?

    public var doi: String?
    public var url: String?
    public var issn: String?
    public var isbn: String?
    public var pmid: String?

    public var abstract: String?
    public var note: String?
    public var language: String?
    public var genre: String?

    public init(
        id: String = "",
        type: CSLType = .other,
        title: String? = nil,
        subtitle: String? = nil,
        shortTitle: String? = nil,
        author: [CSLName] = [],
        editor: [CSLName] = [],
        issued: CSLDate? = nil,
        accessed: CSLDate? = nil,
        containerTitle: String? = nil,
        containerTitleShort: String? = nil,
        collectionTitle: String? = nil,
        eventTitle: String? = nil,
        eventPlace: String? = nil,
        publisher: String? = nil,
        publisherPlace: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        page: String? = nil,
        numberOfPages: String? = nil,
        number: String? = nil,
        edition: String? = nil,
        version: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        issn: String? = nil,
        isbn: String? = nil,
        pmid: String? = nil,
        abstract: String? = nil,
        note: String? = nil,
        language: String? = nil,
        genre: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.shortTitle = shortTitle
        self.author = author
        self.editor = editor
        self.issued = issued
        self.accessed = accessed
        self.containerTitle = containerTitle
        self.containerTitleShort = containerTitleShort
        self.collectionTitle = collectionTitle
        self.eventTitle = eventTitle
        self.eventPlace = eventPlace
        self.publisher = publisher
        self.publisherPlace = publisherPlace
        self.volume = volume
        self.issue = issue
        self.page = page
        self.numberOfPages = numberOfPages
        self.number = number
        self.edition = edition
        self.version = version
        self.doi = doi
        self.url = url
        self.issn = issn
        self.isbn = isbn
        self.pmid = pmid
        self.abstract = abstract
        self.note = note
        self.language = language
        self.genre = genre
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle, author, editor, issued, accessed
        case shortTitle = "title-short"
        case containerTitle = "container-title"
        case containerTitleShort = "container-title-short"
        case collectionTitle = "collection-title"
        case eventTitle = "event-title"
        case eventPlace = "event-place"
        case publisher
        case publisherPlace = "publisher-place"
        case volume, issue, page, edition, version, number
        case numberOfPages = "number-of-pages"
        case doi = "DOI"
        case url = "URL"
        case issn = "ISSN"
        case isbn = "ISBN"
        case pmid = "PMID"
        case abstract, note, language, genre
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        type = (try? container.decode(CSLType.self, forKey: .type)) ?? .other
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        shortTitle = try container.decodeIfPresent(String.self, forKey: .shortTitle)
        author = (try? container.decode([CSLName].self, forKey: .author)) ?? []
        editor = (try? container.decode([CSLName].self, forKey: .editor)) ?? []
        issued = try container.decodeIfPresent(CSLDate.self, forKey: .issued)
        accessed = try container.decodeIfPresent(CSLDate.self, forKey: .accessed)
        // Crossref returns container-title as an array; CSL-JSON uses a string.
        containerTitle = try Self.decodeStringOrFirst(container, .containerTitle)
        containerTitleShort = try Self.decodeStringOrFirst(container, .containerTitleShort)
        collectionTitle = try Self.decodeStringOrFirst(container, .collectionTitle)
        eventTitle = try Self.decodeStringOrFirst(container, .eventTitle)
        eventPlace = try container.decodeIfPresent(String.self, forKey: .eventPlace)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        publisherPlace = try container.decodeIfPresent(String.self, forKey: .publisherPlace)
        volume = try Self.decodeLooseString(container, .volume)
        issue = try Self.decodeLooseString(container, .issue)
        page = try Self.decodeLooseString(container, .page)
        numberOfPages = try Self.decodeLooseString(container, .numberOfPages)
        number = try Self.decodeLooseString(container, .number)
        edition = try Self.decodeLooseString(container, .edition)
        version = try Self.decodeLooseString(container, .version)
        doi = try container.decodeIfPresent(String.self, forKey: .doi)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        issn = try Self.decodeStringOrFirst(container, .issn)
        isbn = try Self.decodeStringOrFirst(container, .isbn)
        pmid = try Self.decodeLooseString(container, .pmid)
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
    }

    private static func decodeStringOrFirst(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String? {
        if let single = try? container.decodeIfPresent(String.self, forKey: key) { return single }
        if let list = try? container.decodeIfPresent([String].self, forKey: key) { return list.first }
        return nil
    }

    /// Accepts numbers where CSL expects strings — several APIs send `volume: 12`.
    private static func decodeLooseString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
        return nil
    }
}

public extension CSLItem {
    /// Title with the subtitle appended, which is how a citation renders it.
    var fullTitle: String? {
        guard let title else { return subtitle }
        guard let subtitle, !subtitle.isEmpty else { return title }
        return title.hasSuffix(":") ? "\(title) \(subtitle)" : "\(title): \(subtitle)"
    }

    var year: Int? { issued?.year }

    /// The record has enough to be worth showing without a "needs review" badge.
    var hasMinimumFields: Bool {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !author.isEmpty && year != nil
    }
}
