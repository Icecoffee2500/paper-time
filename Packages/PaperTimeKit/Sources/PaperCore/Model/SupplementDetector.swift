import Foundation

/// Recognises a document that is a supplement to another paper rather than a
/// paper in its own right.
///
/// Conference sites hand these out as separate downloads with names like
/// `Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024_supplemental.pdf`, and
/// they arrive in a library as if they were papers, cluttering it with entries
/// that have no citation of their own.
public enum SupplementDetector {
    private static let markers = [
        "supplement", "supplementary", "supplemental",
        "appendix", "appendices",
        "supp material", "supp_material", "supmat",
    ]

    /// Whether the name or title reads as supplementary material.
    public static func looksLikeSupplement(fileName: String, title: String?) -> Bool {
        let haystack = [fileName, title ?? ""]
            .map { TextNormalization.foldedTitle($0) }
            .joined(separator: " ")
        return markers.contains { haystack.contains(TextNormalization.foldedTitle($0)) }
    }

    /// The paper a supplement most likely belongs to.
    ///
    /// Compares against the candidate titles with the supplementary wording
    /// stripped out, since the two documents otherwise share their whole title.
    /// Returns nothing unless one candidate is a clear match, because attaching
    /// a supplement to the wrong paper hides it somewhere it will not be found.
    public static func bestParent(
        forFileName fileName: String,
        title: String?,
        among candidates: [(id: UUID, title: String)]
    ) -> UUID? {
        let stem = (fileName as NSString).deletingPathExtension
        var needle = TextNormalization.foldedTitle([stem, title ?? ""].joined(separator: " "))
        // Longest first. In the order they are written, "supplement" is taken
        // out of "supplementary" and leaves "ary" behind, and that stray
        // syllable is then compared against every title in the library — which
        // is how a supplement that says so in plain English scored below the
        // threshold and was offered no parent at all.
        for marker in markers.sorted(by: { $0.count > $1.count }) {
            needle = needle.replacingOccurrences(of: TextNormalization.foldedTitle(marker), with: " ")
        }
        needle = needle.split(separator: " ").joined(separator: " ")
        guard needle.count >= 10 else { return nil }

        var best: (id: UUID, score: Double)?
        var runnerUp = 0.0
        for candidate in candidates {
            let score = StringSimilarity.jaroWinkler(
                needle,
                TextNormalization.foldedTitle(candidate.title)
            )
            if score > (best?.score ?? 0) {
                runnerUp = best?.score ?? 0
                best = (candidate.id, score)
            } else if score > runnerUp {
                runnerUp = score
            }
        }
        guard let best, best.score >= 0.82, best.score - runnerUp >= 0.04 else { return nil }
        return best.id
    }
}
