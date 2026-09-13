import Foundation
import PaperCore

/// A guess at a paper's title and authors, before any registrar confirms it.
public struct ExtractedHeader: Hashable, Sendable {
    public var title: String
    public var authors: [CSLName]
    public var venueHint: String?
    public var year: Int?
    /// 0...1 confidence in this guess alone, used to order candidates.
    public var strength: Double
    public var source: Provenance.Source

    public init(
        title: String,
        authors: [CSLName] = [],
        venueHint: String? = nil,
        year: Int? = nil,
        strength: Double,
        source: Provenance.Source
    ) {
        self.title = title
        self.authors = authors
        self.venueHint = venueHint
        self.year = year
        self.strength = strength
        self.source = source
    }
}

/// Builds title/author guesses from a PDF's own signals, without a network.
///
/// This runs on every device. The on-device language model is a later, better
/// guess that only some hardware can make, so the heuristics here have to be
/// good enough to stand alone on an iPad.
public enum HeaderExtractor {
    public static func candidates(from signals: DocumentSignals) -> [ExtractedHeader] {
        var results: [ExtractedHeader] = []

        if let embedded = signals.embeddedTitle {
            results.append(
                ExtractedHeader(
                    title: embedded,
                    authors: signals.embeddedAuthors.map(CSLName.parse),
                    venueHint: signals.embeddedSubject,
                    year: yearHint(from: signals),
                    // The strongest offline signal available: a producer that
                    // wrote a real title usually wrote the real authors too.
                    strength: signals.embeddedAuthors.isEmpty ? 0.75 : 0.85,
                    source: .pdfDocumentInfo
                )
            )
        }

        if let largest = signals.largestFontText, largest.count >= 12 {
            let title = TextNormalization.collapsingWhitespace(largest)
            if !results.contains(where: { areEquivalent($0.title, title) }) {
                results.append(
                    ExtractedHeader(
                        title: title,
                        authors: authorsFollowingTitle(title, in: signals.firstPageLines),
                        venueHint: signals.embeddedSubject,
                        year: yearHint(from: signals),
                        strength: 0.6,
                        source: .heuristic
                    )
                )
            }
        }

        if let line = firstMeaningfulLine(signals.firstPageLines) {
            if !results.contains(where: { areEquivalent($0.title, line) }) {
                results.append(
                    ExtractedHeader(
                        title: line,
                        authors: authorsFollowingTitle(line, in: signals.firstPageLines),
                        venueHint: signals.embeddedSubject,
                        year: yearHint(from: signals),
                        strength: 0.4,
                        source: .heuristic
                    )
                )
            }
        }

        return results.sorted { $0.strength > $1.strength }
    }

    static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        StringSimilarity.titleSimilarity(lhs, rhs) > 0.95
    }

    /// The first line that reads like a title rather than a stamp, a page
    /// header, or a conference banner.
    static func firstMeaningfulLine(_ lines: [String]) -> String? {
        var buffer: [String] = []
        for line in lines.prefix(25) {
            if DocumentSignalsExtractor.isStamp(line) { continue }
            if looksLikeBoilerplate(line) { continue }
            if line.count < 4 { continue }

            buffer.append(line)
            let joined = buffer.joined(separator: " ")
            // Titles routinely wrap across two or three lines; stop as soon as
            // the accumulated text is long enough to be a title and the line
            // does not end mid-clause.
            if joined.count >= 25, !endsMidPhrase(line) {
                return TextNormalization.collapsingWhitespace(joined)
            }
            if buffer.count >= 3 { break }
        }
        let joined = buffer.joined(separator: " ")
        return joined.count >= 12 ? TextNormalization.collapsingWhitespace(joined) : nil
    }

    static func endsMidPhrase(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return false }
        if last == "-" || last == ":" || last == "," { return true }
        let lastWord = trimmed.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
        return ["a", "an", "the", "of", "for", "with", "and", "or", "in", "on", "to", "via"]
            .contains(lastWord)
    }

    static func looksLikeBoilerplate(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let markers = [
            "proceedings of", "workshop on", "published as a conference paper",
            "under review as a conference paper", "accepted at", "to appear in",
            "copyright", "all rights reserved", "license", "issn", "isbn",
            "downloaded from", "authorized licensed use", "ieee transactions on",
            "journal of", "volume", "preprint",
        ]
        if markers.contains(where: { lowered.hasPrefix($0) }) { return true }
        // Lines that are mostly digits are page numbers, dates or DOIs.
        let digits = line.filter(\.isNumber).count
        return digits > line.count / 2
    }

    /// Lines just below the title are the author block in almost every template.
    static func authorsFollowingTitle(_ title: String, in lines: [String]) -> [CSLName] {
        let foldedTitle = TextNormalization.foldedTitle(title)
        guard let titleEnd = lines.firstIndex(where: {
            foldedTitle.contains(TextNormalization.foldedTitle($0)) &&
                TextNormalization.foldedTitle($0).count > 8
        }) else { return [] }

        for line in lines.dropFirst(titleEnd + 1).prefix(4) {
            if looksLikeBoilerplate(line) { continue }
            if line.lowercased().hasPrefix("abstract") { break }
            let names = splitAuthorLine(line)
            if names.count >= 1, names.allSatisfy({ $0.sortingSurname != nil }) {
                return names
            }
        }
        return []
    }

    static func splitAuthorLine(_ line: String) -> [CSLName] {
        // Affiliation markers ride along with names in most templates.
        var cleaned = ""
        for character in line where !character.isNumber && !"*†‡§¶∗".contains(character) {
            cleaned.append(character)
        }
        let parts = cleaned
            .replacingOccurrences(of: " and ", with: ", ")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 && $0.contains(" ") }
        guard !parts.isEmpty, parts.count <= 20 else { return [] }
        return parts.map(CSLName.parse)
    }

    static func yearHint(from signals: DocumentSignals) -> Int? {
        if let subject = signals.embeddedSubject, let year = CSLDate.firstYear(in: subject) {
            return year
        }
        let head = signals.firstPageLines.prefix(6).joined(separator: " ")
        return CSLDate.firstYear(in: head)
    }
}
