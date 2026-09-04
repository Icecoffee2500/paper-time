import Foundation

/// One possible bibliographic match, kept so the user can pick with one tap
/// instead of retyping a record the pipeline already found but could not prove.
public struct MetadataCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var csl: CSLItem
    public var identifiers: Identifiers
    public var provenance: Provenance
    /// 0...1. How well this candidate matched the text extracted from the PDF.
    public var score: Double
    /// Human-readable reason, shown under the candidate in the review sheet.
    public var matchExplanation: String

    public init(
        id: UUID = UUID(),
        csl: CSLItem,
        identifiers: Identifiers = Identifiers(),
        provenance: Provenance,
        score: Double,
        matchExplanation: String = ""
    ) {
        self.id = id
        self.csl = csl
        self.identifiers = identifiers
        self.provenance = provenance
        self.score = score
        self.matchExplanation = matchExplanation
    }
}
