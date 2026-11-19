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

    /// The paper a supplement belongs to, when that is certain enough to
    /// attach it without asking (2026-11-16: «supplemental은 논문 목록에서
    /// 보이는게 아니라 본 논문의 "자료"에 등록되어야지»).
    ///
    /// Three witnesses, strongest first, each of which must point at exactly
    /// one paper: the two files are twins — the same name but for
    /// `_supplemental` and `_paper`, the way conference sites hand them out;
    /// the paper's whole title (three words or more) is inside the
    /// supplement's title or file name; or the titles are all but equal.
    /// Anything less is left to the inspector's question — attaching to the
    /// wrong paper hides a document where nobody will look.
    public static func confidentParent(
        forFileName fileName: String,
        title: String?,
        among candidates: [(id: UUID, title: String, fileName: String)]
    ) -> UUID? {
        guard looksLikeSupplement(fileName: fileName, title: title) else { return nil }

        let own = twinStem(fileName)
        if own.count >= 12 {
            let twins = candidates.filter { twinStem($0.fileName) == own }
            if twins.count == 1 { return twins[0].id }
            // The Computer Vision Foundation shortens a supplement's name:
            // «Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024_supplemental»
            // for «…_Adaptation_of_Vision-Language_Models_CVPR_2024_paper» —
            // the same author first, the same venue last, and the words
            // between it keeps in their order.
            let shortened = candidates.filter { isShortening(own, of: twinStem($0.fileName)) }
            if twins.isEmpty, shortened.count == 1 { return shortened[0].id }
        }

        let haystack = TextNormalization.foldedTitle([(fileName as NSString).deletingPathExtension, title ?? ""]
            .joined(separator: " ").replacingOccurrences(of: "_", with: " "))
        let containing = candidates.filter { candidate in
            let folded = TextNormalization.foldedTitle(candidate.title)
            return folded.split(separator: " ").count >= 3 && folded.count >= 20 && haystack.contains(folded)
        }
        if containing.count == 1 { return containing[0].id }

        let pairs = candidates.map { (id: $0.id, title: $0.title) }
        guard let best = bestParent(forFileName: fileName, title: title, among: pairs) else { return nil }
        let needle = strippedNeedle(fileName: fileName, title: title)
        let scores = candidates.map { StringSimilarity.jaroWinkler(needle, TextNormalization.foldedTitle($0.title)) }
            .sorted(by: >)
        guard let top = scores.first, top >= 0.93, top - (scores.dropFirst().first ?? 0) >= 0.08 else { return nil }
        return best
    }

    /// A file name with its role taken off: `…_CVPR_2024_supplemental` and
    /// `…_CVPR_2024_paper` are the same stem.
    /// A file name with its role taken off: `…_CVPR_2024_supplemental` and
    /// `…_CVPR_2024_paper` are the same stem. Numbers at the end go too —
    /// the year, and the « 14.54.16» a second download of the same name
    /// is given.
    static func twinStem(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var words = TextNormalization.foldedTitle(stem.replacingOccurrences(of: "_", with: " "))
            .split(separator: " ").map(String.init)
        let roles: Set<String> = ["paper", "main", "supplement", "supplementary", "supplemental", "supp", "appendix",
                                  "appendices", "material", "materials", "supmat", "sm"]
        while let last = words.last, roles.contains(last) || last.allSatisfy(\.isNumber) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Whether one stem is the other with words left out of its middle: the
    /// same first word and last word, four words or more, the rest in order.
    static func isShortening(_ short: String, of long: String) -> Bool {
        let few = short.split(separator: " "), many = long.split(separator: " ")
        guard few.count >= 4, few.count < many.count, few.first == many.first, few.last == many.last else { return false }
        var index = many.startIndex
        for word in few {
            guard let found = many[index...].firstIndex(of: word) else { return false }
            index = many.index(after: found)
        }
        return true
    }

    private static func strippedNeedle(fileName: String, title: String?) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        var needle = TextNormalization.foldedTitle([stem, title ?? ""].joined(separator: " "))
        for marker in markers.sorted(by: { $0.count > $1.count }) {
            needle = needle.replacingOccurrences(of: TextNormalization.foldedTitle(marker), with: " ")
        }
        return needle.split(separator: " ").joined(separator: " ")
    }
}
