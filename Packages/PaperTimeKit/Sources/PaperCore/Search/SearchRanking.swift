import Foundation

/// How Search Everything scores a name against what is being typed.
///
/// A prefix of the whole name beats a prefix of one of its words, which beats
/// the query appearing anywhere in it, which beats a near miss — the ladder is
/// the palette's and has not changed. What has changed is when the folding is
/// done: the palette used to fold every title, every author, every note's
/// first two hundred characters again on every keystroke, and at six hundred
/// papers and a thousand notes that was 796 ms between a key going down and
/// the list answering it. A `Folded` is made once, when the palette opens, and
/// every keystroke after that only compares.
public enum SearchRanking {
    /// How close a near miss has to be before it counts.
    public static let fuzzyThreshold = 0.82

    /// A name folded for comparing, split into its words, and measured the
    /// way the similarity measure measures it (in characters).
    public struct Folded: Sendable, Hashable {
        public let text: String
        public let words: [Substring]
        public let length: Int

        /// Folds `raw` the way the palette folds a query.
        public init(_ raw: String) {
            self.init(folded: TextNormalization.foldedTitle(raw))
        }

        /// Takes text that is already folded.
        public init(folded text: String) {
            self.text = text
            words = text.split(separator: " ")
            length = text.count
        }
    }

    /// Prefix of the whole, then prefix of a word, then anywhere, then a near
    /// miss for a typo.
    ///
    /// The near miss is skipped where it cannot count, which is where one of
    /// the two is more than ten times the length of the other: the most
    /// Jaro–Winkler can then give is 0.8 + 0.2 × (shorter ÷ longer), below
    /// the threshold. That is the case for every note — two hundred
    /// characters against a word — and working it out anyway was most of
    /// what a keystroke cost once the folding had gone.
    public static func score(_ query: Folded, against text: Folded) -> Double? {
        guard !text.text.isEmpty else { return nil }

        if text.text.hasPrefix(query.text) { return 1.0 }
        if text.words.contains(where: { $0.hasPrefix(query.text) }) { return 0.9 }
        if text.text.contains(query.text) { return 0.75 }

        guard couldBeNearMiss(query.length, text.length) else { return nil }
        let similarity = StringSimilarity.jaroWinkler(query.text, text.text)
        return similarity > fuzzyThreshold ? similarity : nil
    }

    /// Whether two strings of these lengths could ever be similar enough.
    ///
    /// Jaro matches no more characters than the shorter string has, so with
    /// `r` the shorter length over the longer, Jaro is at most (2 + r) ÷ 3 and
    /// Jaro–Winkler — which adds at most 0.4 of what is left — at most
    /// 0.8 + 0.2r. At r ≤ 0.09 that is 0.818, under 0.82 with room to spare
    /// for rounding.
    public static func couldBeNearMiss(_ lhs: Int, _ rhs: Int) -> Bool {
        let shorter = min(lhs, rhs)
        let longer = max(lhs, rhs)
        guard longer > 0 else { return true }
        return Double(shorter) / Double(longer) > 0.09
    }
}
