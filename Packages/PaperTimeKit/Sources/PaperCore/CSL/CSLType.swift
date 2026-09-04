import Foundation

/// The subset of CSL-JSON item types Paper Time produces or consumes.
///
/// Paper Time stores CSL-JSON as the canonical bibliographic record; BibTeX is
/// always derived from it. Unknown types round-trip through `.other`.
public enum CSLType: String, Codable, Hashable, Sendable, CaseIterable {
    case articleJournal = "article-journal"
    case paperConference = "paper-conference"
    case book
    case chapter
    case thesis
    case report
    case dataset
    case software
    case webpage
    case patent
    case speech
    /// CSL's type for unpublished work. Used for preprints (arXiv, bioRxiv).
    case manuscript
    case other = "document"

    /// Best-effort mapping from a Crossref `type` string.
    public static func fromCrossref(_ raw: String) -> CSLType {
        switch raw {
        case "journal-article": .articleJournal
        case "proceedings-article": .paperConference
        case "book", "monograph", "edited-book", "reference-book": .book
        case "book-chapter", "book-section", "book-part": .chapter
        case "dissertation": .thesis
        case "report", "report-component": .report
        case "dataset": .dataset
        case "posted-content": .manuscript
        case "peer-review", "standard", "other": .other
        default: .other
        }
    }
}
