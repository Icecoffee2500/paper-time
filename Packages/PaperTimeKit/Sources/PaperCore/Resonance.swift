import Foundation

/// Notes that echo a passage — the slip-box speaking first.
///
/// Luhmann called his box a conversation partner, and the conversation only
/// happens if the box sometimes speaks first: a note written months ago,
/// against another paper, is worth nothing while it waits to be searched
/// for, because nobody searches for what they have forgotten they wrote.
/// This asks, for a passage being read, which notes share its words — its
/// *rare* words, weighted by how seldom they appear across the notes and the
/// paper's own pages — and says which words they were, so the echo can be
/// judged rather than trusted.
///
/// Words are lowered, lightly stemmed ("weights" meets "weight", "training"
/// meets "pretrained" through "train") and taken in pairs as well as one by
/// one, because "catastrophic forgetting" is a thing and "forgetting" alone
/// is a mood. Function words and the words every paper uses — model, method,
/// results — are left out; a page and a note that share only those share
/// nothing.
public enum Resonance {
    /// One note that echoes the text, and why.
    public struct Match: Identifiable, Hashable, Sendable {
        public let id: String
        public let score: Double
        /// The words the two share, strongest first, as the text writes them.
        public let shared: [String]
    }

    /// The notes, weighed and ready to be asked.
    public struct Index: Sendable {
        struct Entry: Sendable {
            let id: String
            let terms: [String: Double]
            let length: Double
        }

        private let entries: [Entry]
        private let documentFrequency: [String: Int]
        private let corpusSize: Int

        /// - Parameters:
        ///   - notes: each note's identifier and its text, title and body
        ///     together.
        ///   - background: other texts the words' rarity is judged against —
        ///     the pages of the paper being read, so that a word on every one
        ///     of them counts for little and a word on two of them for much.
        public init(notes: [(id: String, text: String)], background: [String] = []) {
            var frequency: [String: Int] = [:]
            var built: [Entry] = []
            for note in notes {
                let terms = Resonance.terms(in: note.text).counts
                for term in terms.keys { frequency[term, default: 0] += 1 }
                let length = terms.values.reduce(0, +)
                built.append(Entry(id: note.id, terms: terms, length: max(1, length)))
            }
            for text in background {
                for term in Resonance.terms(in: text).counts.keys { frequency[term, default: 0] += 1 }
            }
            entries = built
            documentFrequency = frequency
            corpusSize = notes.count + background.count
        }

        public var isEmpty: Bool { entries.isEmpty }

        /// The notes that echo the text, strongest first.
        ///
        /// A note has to share two words, or one pair, and to score above a
        /// floor and above a third of the strongest — a list padded out with
        /// faint echoes is a list nobody reads.
        public func matches(for text: String, limit: Int = 5, excluding: Set<String> = []) -> [Match] {
            let query = Resonance.terms(in: text)
            guard !query.counts.isEmpty else { return [] }
            var found: [(Match, Int)] = []
            for entry in entries where !excluding.contains(entry.id) {
                var score = 0.0
                var contributions: [(term: String, weight: Double)] = []
                var pairs = 0
                for (term, queryCount) in query.counts {
                    guard let noteCount = entry.terms[term] else { continue }
                    let pairBonus: Double = term.contains(" ") ? 1.3 : 1
                    let evidence: Double = min(queryCount, noteCount).squareRoot()
                    let weight: Double = idf(term) * pairBonus * evidence
                    score += weight
                    contributions.append((term, weight))
                    if term.contains(" ") { pairs += 1 }
                }
                guard contributions.count >= 2 || pairs >= 1 else { continue }
                // Longer notes share more words by chance; a long note has
                // to share more to count — but not proportionally more, or
                // a page of writing could never echo anything. A fragment
                // of a few words is weighed as if it were a short paragraph,
                // or every stray line would outscore every real note.
                score /= 1 + log(max(entry.length, 24))
                // The words, strongest first; a word already inside a shown
                // pair is not shown again on its own.
                var shared: [String] = []
                var covered = Set<String>()
                for contribution in contributions.sorted(by: { $0.weight > $1.weight }) where shared.count < 4 {
                    let term = contribution.term
                    if term.contains(" ") {
                        for part in term.split(separator: " ") { covered.insert(String(part)) }
                    } else if covered.contains(term) {
                        continue
                    }
                    if let written = query.surface[term], !shared.contains(written) { shared.append(written) }
                }
                found.append((Match(id: entry.id, score: score, shared: shared), contributions.count))
            }
            let matches: [Match] = found.map { $0.0 }
            guard let strongest = matches.map(\.score).max(), strongest >= 1.0 else { return [] }
            let floor: Double = max(1.0, strongest * 0.35)
            let kept: [Match] = matches.filter { $0.score >= floor }
            let ordered: [Match] = kept.sorted { lhs, rhs in
                lhs.score == rhs.score ? lhs.id < rhs.id : lhs.score > rhs.score
            }
            return Array(ordered.prefix(limit))
        }

        /// How rare a word is: seldom seen is worth more, and a word seen
        /// in every text is worth next to nothing.
        private func idf(_ term: String) -> Double {
            let seen = Double(documentFrequency[term] ?? 0)
            return log((Double(corpusSize) + 1) / (seen + 0.5)) + 0.3
        }
    }

    // MARK: - Words

    struct Terms {
        /// Each stemmed word and word pair, with how often it occurs.
        var counts: [String: Double] = [:]
        /// The first way each was written, for showing.
        var surface: [String: String] = [:]
    }

    /// The words of a text worth matching on, stemmed, with their pairs.
    static func terms(in text: String) -> Terms {
        var terms = Terms()
        var previous: (stem: String, word: String)?
        for word in words(in: text) {
            let lowered = word.lowercased()
            if stopwords.contains(lowered) { previous = nil; continue }
            let stem = Self.stem(lowered)
            guard stem.count >= 2 else { previous = nil; continue }
            terms.counts[stem, default: 0] += 1
            if terms.surface[stem] == nil { terms.surface[stem] = lowered }
            if let previous {
                let pair = previous.stem + " " + stem
                terms.counts[pair, default: 0] += 1
                if terms.surface[pair] == nil { terms.surface[pair] = previous.word + " " + lowered }
            }
            previous = (stem, lowered)
        }
        // Occurrences are damped: a word written ten times is not ten times
        // the evidence a word written once is.
        for (term, count) in terms.counts { terms.counts[term] = 1 + log(count) }
        return terms
    }

    /// The words, with the notation and the markup taken out first.
    static func words(in text: String) -> [String] {
        var cleaned = text
        for pattern in [
            #"\$\$[\s\S]*?\$\$"#, #"\$[^$\n]*?\$"#, #"```[\s\S]*?```"#, #"`[^`\n]*`"#,
            #"https?://\S+"#, #"!\[[^\]]*\]\([^)\s]*\)"#,
        ] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        cleaned = cleaned
            .replacingOccurrences(of: #"\[\[[^\]|]+\|([^\]]*)\]\]"#, with: " $1 ", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[[^\]]+\]\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]\n]*)\]\([^)\s]*\)"#, with: " $1 ", options: .regularExpression)
            // Hyphenation at a line's end, as a page prints it.
            .replacingOccurrences(of: #"(\p{L})-\n(\p{L})"#, with: "$1$2", options: .regularExpression)
        var result: [String] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            let letters = current.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            // A number on its own, a lone letter, a variable name: not words.
            guard letters >= 1 else { return }
            let isCJK = current.unicodeScalars.contains { $0.value >= 0x2E80 }
            guard current.count >= (isCJK ? 2 : 3) || (letters >= 2 && current.count >= 3) else { return }
            result.append(current)
        }
        for scalar in cleaned.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" && !current.isEmpty {
                current.unicodeScalars.append(scalar)
            } else {
                if current.hasSuffix("-") { current.removeLast() }
                flush()
            }
        }
        if current.hasSuffix("-") { current.removeLast() }
        flush()
        return result
    }

    /// A light stemming: enough for the plural and the participle to meet
    /// the noun, not enough to be a dictionary.
    static func stem(_ word: String) -> String {
        guard word.count >= 5, word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return word }
        var stemmed = word
        if stemmed.hasSuffix("ies") { return String(stemmed.dropLast(3)) + "y" }
        for suffix in ["ing", "ed", "es", "s", "ly"] where stemmed.hasSuffix(suffix) && stemmed.count - suffix.count >= 4 {
            stemmed = String(stemmed.dropLast(suffix.count))
            break
        }
        // "forgett" → "forget", "runn" → "run": a doubled last letter left by
        // a stripped suffix.
        if stemmed.count >= 5, let last = stemmed.last, stemmed.dropLast().last == last, !"lsz".contains(last) {
            stemmed.removeLast()
        }
        return stemmed
    }

    /// Function words, and the words every paper uses.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
        "boy", "did", "its", "let", "put", "say", "she", "too", "use", "with", "from", "this", "that", "these",
        "those", "there", "their", "they", "them", "then", "than", "into", "over", "such", "only", "more", "most",
        "very", "when", "where", "while", "been", "being", "have", "will", "would", "could", "may", "might",
        "should", "shall", "which", "what", "also", "each", "both", "some", "other", "others", "first", "second",
        "third", "used", "using", "based", "via", "per", "however", "thus", "hence", "therefore", "because",
        "between", "within", "without", "about", "after", "before", "under", "above", "through", "during",
        "here", "were", "does", "done", "doing", "made", "make", "makes", "many", "much", "well", "like", "same",
        "since", "still", "even", "just", "given", "either", "neither", "whether", "along", "among", "across",
        "around", "toward", "towards", "upon", "onto", "though", "although", "yet", "rather", "instead",
        "often", "always", "never", "further", "less", "least", "several", "various", "particular", "particularly",
        "respectively", "e.g", "i.e", "etc", "et", "al", "figure", "fig", "figs", "table", "tables", "section",
        "sections", "equation", "eq", "eqs", "appendix", "paper", "papers", "work", "works", "method", "methods",
        "approach", "approaches", "result", "results", "show", "shows", "shown", "propose", "proposed", "present",
        "presented", "presents", "consider", "considered", "note", "notes", "example", "examples", "case", "cases",
        "arxiv", "ieee", "acm", "vol", "pp", "http", "https", "www", "doi", "org", "com", "model", "models",
        "data", "dataset", "datasets", "task", "tasks", "performance", "state", "art", "experiment",
        "experiments", "experimental", "evaluation", "evaluate", "baseline", "baselines", "problem", "problems",
        "different", "large", "small", "high", "low", "number", "numbers", "set", "sets", "based", "learning",
        "trained", "training", "train", "test", "compare", "compared", "comparison", "previous", "prior",
        "related", "following", "follow", "general", "specific", "simple", "single", "multiple", "including",
        "include", "includes", "important", "significant", "significantly", "better", "best", "good",
        "possible", "able", "allows", "allow", "require", "requires", "required", "need", "needs", "order",
        "terms", "term", "value", "values", "function", "functions", "time", "times", "step", "steps", "way",
        "ways", "thing", "things", "point", "points", "part", "parts", "end", "ends", "level", "levels",
        "이", "그", "저", "것", "수", "등", "및", "또는", "그리고", "하지만", "그러나", "있다", "없다", "한다", "된다",
        "이다", "하는", "있는", "없는", "위해", "대한", "통해", "경우", "때문", "대해", "에서", "으로", "부터", "까지",
    ]
}

private extension [String] {
    /// Keeps the first of each, in order.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
