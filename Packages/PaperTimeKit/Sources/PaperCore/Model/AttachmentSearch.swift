import Foundation

/// Finding the paper a document should be attached to.
///
/// The submenu that used to do this listed the first thirty papers in title
/// order, which is a fine answer to "which papers are there" and no answer at
/// all to "where is mine" — a library of two hundred hides a hundred and
/// seventy of them behind a boundary nobody can see, and the one the reader
/// wants is a supplement's parent, so it is exactly as likely to be at Z as
/// at A. The list has to be searchable, and the search has to find a paper
/// from any part of its title or its file name, because those are the two
/// names a reader has for it.
public enum AttachmentSearch {
    /// A paper as the picker knows it: what it is called, and what its file is
    /// called. Both, because a reader who downloaded
    /// `Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024.pdf` will type
    /// "karmanov", which appears in no title.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let title: String
        public let fileName: String

        /// Folded when the candidate is made, not when it is compared.
        ///
        /// The picker re-ranks the whole library on every character typed into
        /// it, and folding a title walks its every character. Measured on six
        /// hundred papers, doing it inside the comparison cost 13ms a
        /// keystroke — most of a frame, for an answer that is the same every
        /// time. Now it is 600 foldings when the sheet opens and none after.
        let foldedTitle: String
        let foldedFile: String
        /// Each word of the title, then each word of the file name: the ladder
        /// below asks whether a word of the query begins one of these, and
        /// splitting them here is the same saving again.
        let titleWords: [Substring]
        let fileWords: [Substring]

        public init(id: UUID, title: String, fileName: String) {
            self.id = id
            self.title = title
            self.fileName = fileName
            foldedTitle = TextNormalization.foldedTitle(title)
            foldedFile = TextNormalization.foldedTitle(fileName)
            titleWords = foldedTitle.split(separator: " ")
            fileWords = foldedFile.split(separator: " ")
        }
    }

    /// The candidates that answer a query, best first.
    ///
    /// An empty query answers with everything, in title order — the order the
    /// old submenu had, and the right one for a list nobody has asked a
    /// question of yet.
    public static func ranked(_ candidates: [Candidate], matching query: String) -> [Candidate] {
        let needle = TextNormalization.foldedTitle(query)
        guard !needle.isEmpty else {
            return candidates.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }

        let words = needle.split(separator: " ").map(String.init)
        var scored: [(candidate: Candidate, score: Double)] = []
        for candidate in candidates {
            if let score = score(candidate, needle: needle, words: words) {
                scored.append((candidate, score))
            }
        }

        // Nothing matched a word of it. Rather than an empty list — which
        // reads as "you have no such paper" when the truth is "you spelled it
        // differently" — fall back to whole-title similarity, which survives a
        // typo and a missing subtitle.
        if scored.isEmpty {
            for candidate in candidates {
                // Both names, as the ladder above uses both: a reader who
                // mistypes the author in a file name gets the same help as one
                // who mistypes a word of the title.
                let similarity = max(
                    StringSimilarity.jaroWinkler(needle, candidate.foldedTitle),
                    StringSimilarity.jaroWinkler(needle, candidate.foldedFile)
                )
                if similarity >= 0.7 { scored.append((candidate, similarity - 1)) }
            }
        }

        // Ties broken on the folded title with a plain comparison, not a
        // localized one. `localizedStandardCompare` asks ICU on every pair, and
        // a one-letter query matches most of the library — measured on six
        // hundred papers, that one keystroke spent 15ms almost entirely in
        // here. The folded form is already lower-cased and stripped of
        // punctuation, which is most of what the localized compare was for.
        return scored
            .sorted {
                $0.score == $1.score
                    ? $0.candidate.foldedTitle < $1.candidate.foldedTitle
                    : $0.score > $1.score
            }
            .map(\.candidate)
    }

    /// How well one paper answers a query, or nothing if it does not.
    ///
    /// The ladder is by how much of the query the paper accounts for, and the
    /// title outranks the file name at every rung: a phrase found in a title
    /// is the paper being named, and the same phrase in a file name may be the
    /// conference that published it.
    static func score(_ candidate: Candidate, needle: String, words: [String]) -> Double? {
        let title = candidate.foldedTitle
        let file = candidate.foldedFile

        if title.hasPrefix(needle) { return 1 }
        if title.contains(needle) { return 0.9 }
        if file.hasPrefix(needle) { return 0.8 }
        if file.contains(needle) { return 0.75 }

        // Word by word, and by prefix: "adapt" has to find "adaptation", and
        // Korean attaches its particles to the noun, so "강화학습" has to find
        // "강화학습의".
        let titleWords = candidate.titleWords
        let fileWords = candidate.fileWords
        var inTitle = 0
        var inFile = 0
        for word in words {
            if titleWords.contains(where: { $0.hasPrefix(word) }) { inTitle += 1 }
            else if fileWords.contains(where: { $0.hasPrefix(word) }) { inFile += 1 }
        }
        let found = inTitle + inFile
        guard found > 0 else { return nil }

        let coverage = Double(found) / Double(words.count)
        let fromTitle = Double(inTitle) / Double(found)
        // Every word accounted for is a different answer from most of them:
        // the first is the paper, the second is a paper that shares a word.
        return (coverage == 1 ? 0.6 : 0.5 * coverage) + 0.05 * fromTitle
    }

    /// The paper the picker offers before anything is typed.
    ///
    /// The same judgement the library already makes when it offers to attach a
    /// supplement on import, asked again here so that the picker opens on the
    /// answer when there is one.
    ///
    /// Only for a document that says it is supplementary. Without that gate,
    /// two papers whose titles begin with the same words are a match — asked
    /// for "Scene-Graph ViT: End-to-End Open-Vocabulary Visual Relationship
    /// Detection", it offered "Scene Graph Generation by Iterative Message
    /// Passing", under a heading that says the app thinks it is the one. A
    /// wrong answer stated confidently is worse than no answer, because the
    /// list below it is right either way.
    public static func suggestion(
        for child: Candidate,
        among candidates: [Candidate]
    ) -> UUID? {
        guard SupplementDetector.looksLikeSupplement(
            fileName: child.fileName,
            title: child.title
        ) else { return nil }
        return SupplementDetector.bestParent(
            forFileName: child.fileName,
            title: child.title,
            among: candidates
                .filter { $0.id != child.id }
                .map { (id: $0.id, title: $0.title) }
        )
    }
}
