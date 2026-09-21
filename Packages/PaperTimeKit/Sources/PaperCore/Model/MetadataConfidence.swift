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

    private enum CodingKeys: String, CodingKey {
        case source, fetchedAt, detail
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

    /// Reads a record that is missing a field rather than losing the paper
    /// it describes.
    ///
    /// This cost a Windows import its whole library: the other build wrote
    /// `{"source": "heuristic"}` with no `fetchedAt`, `PaperMeta` failed to
    /// decode, and the Mac showed an empty shelf beside a folder full of
    /// PDFs — no error, because a record that will not decode was simply not
    /// a paper. Both builds now write the field, and this reads the ones that
    /// were written before they did. When something is missing here, the
    /// paper is the thing worth keeping; the date is not.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? container.decode(Source.self, forKey: .source)) ?? .heuristic
        fetchedAt = (try? container.decode(Date.self, forKey: .fetchedAt)) ?? Date(timeIntervalSince1970: 0)
        detail = try? container.decode(String.self, forKey: .detail)
    }
}
