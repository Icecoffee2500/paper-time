import Foundation

/// How much Paper Time trusts a bibliographic record.
///
/// The app never silently stores a guess: anything below `verified` is shown
/// with a badge and is excluded from BibTeX export unless the user opts in.
/// This is the specific failure of the reference managers this app replaces.
public enum MetadataConfidence: String, Codable, Hashable, Sendable, CaseIterable {
    /// Nothing has been resolved yet; only the file exists.
    case unparsed
    /// Extracted, but no authoritative source confirmed it.
    case needsReview
    /// Confirmed against a registrar (DOI content negotiation, Crossref,
    /// OpenAlex or arXiv) with matching title, first author and year.
    case verified
    /// The user typed or corrected it. Outranks everything, never overwritten.
    case manual

    /// Whether an automatic update may replace a record at this level.
    public var allowsAutomaticOverwrite: Bool {
        switch self {
        case .unparsed, .needsReview: true
        case .verified, .manual: false
        }
    }

    public var sortRank: Int {
        switch self {
        case .unparsed: 0
        case .needsReview: 1
        case .verified: 2
        case .manual: 3
        }
    }
}

/// Where a bibliographic record came from, so a later run can tell whether it
/// is worth re-resolving.
public struct Provenance: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case doiContentNegotiation
        case crossref
        case openAlex
        case arxiv
        case semanticScholar
        case pdfDocumentInfo
        case onDeviceModel
        case heuristic
        case importedBibTeX
        case importedRIS
        case manual
    }

    public var source: Source
    public var fetchedAt: Date
    /// Free-form detail, e.g. the Crossref query that produced the match.
    public var detail: String?

    public init(source: Source, fetchedAt: Date = .now, detail: String? = nil) {
        self.source = source
        self.fetchedAt = fetchedAt
        self.detail = detail
    }
}
