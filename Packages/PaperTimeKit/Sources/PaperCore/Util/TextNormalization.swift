import Foundation

/// Text handling shared by metadata matching and citation-key generation.
public enum TextNormalization {
    /// Folds a title down to the form used for comparing two records.
    ///
    /// Accents, case, punctuation and spacing all differ between a PDF's text
    /// layer and a registrar's record for the same paper, so comparing raw
    /// strings reports a mismatch on papers that are plainly identical.
    public static func foldedTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Collapses the line breaks and repeated spaces that PDF text extraction
    /// and the arXiv API both introduce inside titles.
    public static func collapsingWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Rejoins words broken across lines by a hyphen ("infor-\nmation").
    ///
    /// Only applied when the following line starts lowercase, so genuine
    /// compounds ("state-of-the-art") survive.
    public static func repairingHyphenation(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "-" {
                var lookahead = raw.index(after: index)
                var sawNewline = false
                while lookahead < raw.endIndex, raw[lookahead].isWhitespace {
                    if raw[lookahead].isNewline { sawNewline = true }
                    lookahead = raw.index(after: lookahead)
                }
                if sawNewline, lookahead < raw.endIndex, raw[lookahead].isLowercase {
                    index = lookahead
                    continue
                }
            }
            result.append(character)
            index = raw.index(after: index)
        }
        return result
    }

    /// The first word of a title that is meaningful enough for a citation key.
    public static func firstSignificantWord(of title: String) -> String? {
        let stopWords: Set<String> = [
            "a", "an", "the", "on", "of", "in", "for", "to", "and", "or", "with",
            "at", "by", "from", "into", "is", "are", "how", "what", "why", "when",
            "can", "do", "does", "toward", "towards", "via", "using", "learning",
        ]
        let words = foldedTitle(title).split(separator: " ").map(String.init)
        // "learning" is a stop word only because half of a machine-learning
        // library would otherwise share the same key.
        if let word = words.first(where: { !stopWords.contains($0) && $0.count > 2 }) {
            return word
        }
        return words.first
    }
}

/// String similarity used to decide whether an API result is the same paper.
public enum StringSimilarity {
    /// Jaro-Winkler, in 0...1.
    ///
    /// Chosen over edit distance because it rewards a shared prefix, and the
    /// difference between a real match and a wrong one is almost always in the
    /// tail of the title (a subtitle, a trailing venue name).
    public static func jaroWinkler(_ lhs: String, _ rhs: String) -> Double {
        let jaro = self.jaro(lhs, rhs)
        guard jaro > 0.7 else { return jaro }

        let left = Array(lhs)
        let right = Array(rhs)
        var prefix = 0
        for index in 0..<min(4, min(left.count, right.count)) {
            if left[index] == right[index] { prefix += 1 } else { break }
        }
        return jaro + (Double(prefix) * 0.1 * (1 - jaro))
    }

    public static func jaro(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty && right.isEmpty { return 1 }
        if left.isEmpty || right.isEmpty { return 0 }

        let window = max(left.count, right.count) / 2 - 1
        guard window >= 0 else { return left == right ? 1 : 0 }

        var leftMatches = [Bool](repeating: false, count: left.count)
        var rightMatches = [Bool](repeating: false, count: right.count)
        var matches = 0

        for index in left.indices {
            let start = max(0, index - window)
            let end = min(index + window + 1, right.count)
            guard start < end else { continue }
            for candidate in start..<end where !rightMatches[candidate] {
                if left[index] == right[candidate] {
                    leftMatches[index] = true
                    rightMatches[candidate] = true
                    matches += 1
                    break
                }
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var rightIndex = 0
        for index in left.indices where leftMatches[index] {
            while !rightMatches[rightIndex] { rightIndex += 1 }
            if left[index] != right[rightIndex] { transpositions += 1 }
            rightIndex += 1
        }

        let matched = Double(matches)
        return (matched / Double(left.count)
            + matched / Double(right.count)
            + (matched - Double(transpositions / 2)) / matched) / 3
    }

    /// Title comparison after folding. The threshold used by the verifier is
    /// 0.90, chosen so that a missing subtitle still matches but a different
    /// paper by the same group does not.
    public static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        jaroWinkler(TextNormalization.foldedTitle(lhs), TextNormalization.foldedTitle(rhs))
    }
}
