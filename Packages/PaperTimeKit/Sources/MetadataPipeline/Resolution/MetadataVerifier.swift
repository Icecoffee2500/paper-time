import Foundation
import PaperCore

/// The evidence behind accepting or rejecting a bibliographic match.
///
/// Kept as data rather than a bare Boolean so the review sheet can tell the
/// user *why* a record needs checking, which is the difference between a badge
/// they trust and one they learn to dismiss.
public struct MatchAssessment: Hashable, Sendable {
    public var titleSimilarity: Double
    public var firstAuthorMatches: Bool?
    public var yearDifference: Int?
    public var identifierCameFromDocument: Bool
    public var verdict: MetadataConfidence
    public var explanation: String

    /// Overall confidence in this match.
    ///
    /// The title carries most of the weight deliberately. An earlier version
    /// split it 0.7/0.2/0.1 with author and year, which let a candidate whose
    /// title matched 72% beat one that matched 96% simply because the first
    /// record happened to list an author the other omitted — and the wrong
    /// paper won.
    public var score: Double {
        var value = titleSimilarity * 0.85
        if firstAuthorMatches == true { value += 0.10 }
        if let difference = yearDifference, difference <= 1 { value += 0.05 }
        return min(1, value)
    }
}

/// Decides whether a candidate record is really the paper in front of us.
///
/// The bias is deliberate and one-directional: a wrong record stored silently
/// is worse than a record flagged for a two-second confirmation, because the
/// first one ends up in a submitted manuscript.
public enum MetadataVerifier {
    /// Titles below this are not the same paper.
    public static let titleThreshold = 0.90
    /// An exact-enough title carries a match on its own.
    public static let strongTitleThreshold = 0.98
    /// A DOI printed on the paper only needs the title to be plausible.
    public static let identifierTitleThreshold = 0.80
    /// Below this a search result is not a weaker candidate, it is a different
    /// paper that happened to share some words.
    public static let candidateFloor = 0.80

    public static func assess(
        candidate: CSLItem,
        against header: ExtractedHeader?,
        identifierCameFromDocument: Bool
    ) -> MatchAssessment {
        guard let header else {
            // Nothing to compare against: trust an identifier lifted from the
            // document itself, and nothing else.
            return MatchAssessment(
                titleSimilarity: 0,
                firstAuthorMatches: nil,
                yearDifference: nil,
                identifierCameFromDocument: identifierCameFromDocument,
                verdict: identifierCameFromDocument ? .verified : .needsReview,
                explanation: identifierCameFromDocument
                    ? "Matched by an identifier printed in the document."
                    : "No title could be read from the document to check against."
            )
        }

        let similarity = candidate.fullTitle.map {
            StringSimilarity.titleSimilarity($0, header.title)
        } ?? 0
        let authorMatch = compareFirstAuthor(candidate: candidate, header: header)
        let yearGap = compareYear(candidate: candidate, header: header)

        let verdict = decide(
            similarity: similarity,
            authorMatch: authorMatch,
            yearGap: yearGap,
            identifierCameFromDocument: identifierCameFromDocument
        )

        return MatchAssessment(
            titleSimilarity: similarity,
            firstAuthorMatches: authorMatch,
            yearDifference: yearGap,
            identifierCameFromDocument: identifierCameFromDocument,
            verdict: verdict,
            explanation: explain(
                similarity: similarity,
                authorMatch: authorMatch,
                yearGap: yearGap,
                identifierCameFromDocument: identifierCameFromDocument,
                verdict: verdict
            )
        )
    }

    static func decide(
        similarity: Double,
        authorMatch: Bool?,
        yearGap: Int?,
        identifierCameFromDocument: Bool
    ) -> MetadataConfidence {
        if identifierCameFromDocument {
            // The document names this DOI or arXiv ID. The only failure mode
            // worth guarding is having picked up a reference to another paper,
            // which a wildly different title exposes.
            return similarity >= identifierTitleThreshold || similarity == 0
                ? .verified
                : .needsReview
        }
        if similarity >= strongTitleThreshold { return .verified }
        guard similarity >= titleThreshold else { return .needsReview }
        if authorMatch == true { return .verified }
        if authorMatch == nil, let yearGap, yearGap <= 1 { return .verified }
        return .needsReview
    }

    static func compareFirstAuthor(candidate: CSLItem, header: ExtractedHeader) -> Bool? {
        guard let expected = header.authors.first?.sortingSurname,
              let actual = candidate.author.first?.sortingSurname
        else { return nil }
        let left = TextNormalization.foldedTitle(expected)
        let right = TextNormalization.foldedTitle(actual)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        // Extracted author lines lose accents and split ligatures, so an exact
        // comparison rejects correct matches; the surname still has to be close.
        if left == right { return true }
        if left.contains(right) || right.contains(left) { return true }
        return StringSimilarity.jaroWinkler(left, right) >= 0.92
    }

    static func compareYear(candidate: CSLItem, header: ExtractedHeader) -> Int? {
        guard let expected = header.year, let actual = candidate.year else { return nil }
        // A preprint and its published version legitimately differ by a year.
        return abs(expected - actual)
    }

    static func explain(
        similarity: Double,
        authorMatch: Bool?,
        yearGap: Int?,
        identifierCameFromDocument: Bool,
        verdict: MetadataConfidence
    ) -> String {
        var parts: [String] = []
        if identifierCameFromDocument {
            parts.append("identifier printed in the document")
        }
        parts.append("title match \(Int((similarity * 100).rounded()))%")
        switch authorMatch {
        case true?: parts.append("first author matches")
        case false?: parts.append("first author differs")
        case nil: parts.append("no author to compare")
        }
        if let yearGap {
            parts.append(yearGap == 0 ? "same year" : "year differs by \(yearGap)")
        }
        let reason = parts.joined(separator: ", ")
        return verdict == .verified ? "Confirmed: \(reason)." : "Needs a check: \(reason)."
    }

    /// Picks the best candidate and says whether it clears the bar.
    ///
    /// Ranking is lexicographic rather than by score alone: a candidate that
    /// actually passes verification always outranks one that merely scores
    /// well, and title similarity breaks ties before the blended score does.
    public static func best(
        among candidates: [(item: CSLItem, identifiers: Identifiers, source: Provenance.Source)],
        header: ExtractedHeader?,
        identifierCameFromDocument: Bool
    ) -> (item: CSLItem, identifiers: Identifiers, source: Provenance.Source, assessment: MatchAssessment)? {
        let assessed = candidates.map { candidate in
            (
                item: candidate.item,
                identifiers: candidate.identifiers,
                source: candidate.source,
                assessment: assess(
                    candidate: candidate.item,
                    against: header,
                    identifierCameFromDocument: identifierCameFromDocument
                )
            )
        }
        return assessed.max { lhs, rhs in
            rank(lhs.assessment) < rank(rhs.assessment)
        }
    }

    static func rank(_ assessment: MatchAssessment) -> (Int, Double, Double) {
        (
            assessment.verdict == .verified ? 1 : 0,
            assessment.titleSimilarity,
            assessment.score
        )
    }
}
