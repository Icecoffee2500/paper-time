import Foundation
import PaperCore

/// Maps parsed `.bib` entries onto Paper Time's canonical CSL-JSON model.
public enum BibTeXImporter {
    public struct ImportedRecord: Sendable {
        public var csl: CSLItem
        public var identifiers: Identifiers
        public var bibKey: String
        /// Value of the `file` field, if the source reference manager wrote one.
        public var fileHints: [String]

        public init(csl: CSLItem, identifiers: Identifiers, bibKey: String, fileHints: [String] = []) {
            self.csl = csl
            self.identifiers = identifiers
            self.bibKey = bibKey
            self.fileHints = fileHints
        }
    }

    public static func records(from source: String) -> (records: [ImportedRecord], warnings: [String]) {
        let parsed = BibTeXParser.parse(source)
        return (parsed.entries.map(record(from:)), parsed.warnings)
    }

    public static func record(from entry: BibTeXEntry) -> ImportedRecord {
        // Every field goes through LaTeXEscaping.unescape before it's stored,
        // except the raw author/editor strings - see `names(from:)` below for
        // why those need to stay LaTeX-escaped a little longer.
        func field(_ name: String) -> String? {
            guard let raw = entry[name] else { return nil }
            let value = LaTeXEscaping.unescape(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func rawField(_ name: String) -> String? {
            guard let raw = entry[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }

        let arxiv = arxivID(entry: entry, field: field)
        let identifiers = Identifiers(
            doi: field("doi"),
            arxiv: arxiv,
            pmid: field("pmid"),
            isbn: field("isbn")
        )

        var csl = CSLItem()
        csl.id = entry.key
        csl.type = cslType(for: entry.type, hasArxiv: identifiers.arxiv != nil)

        csl.title = field("title")
        csl.subtitle = field("subtitle")

        csl.author = names(from: rawField("author"))
        csl.editor = names(from: rawField("editor"))

        csl.issued = issuedDate(field: field)

        switch entry.type {
        case .inproceedings, .incollection:
            csl.containerTitle = field("booktitle")
        case .article:
            csl.containerTitle = field("journal") ?? field("journaltitle")
        default:
            csl.containerTitle = nil
        }
        csl.collectionTitle = field("series")

        csl.publisher = field("publisher") ?? field("institution") ?? field("school") ?? field("organization")
        csl.publisherPlace = field("address")

        csl.volume = field("volume")
        if let number = field("number") {
            if entry.type == .article {
                csl.issue = number
            } else {
                csl.number = number
            }
        }

        csl.page = normalizedPages(field("pages"))
        csl.edition = field("edition")
        csl.language = field("language")

        csl.doi = identifiers.doi
        csl.url = field("url")
        csl.issn = field("issn")
        csl.isbn = identifiers.isbn
        csl.pmid = identifiers.pmid

        csl.abstract = field("abstract")
        csl.note = field("note")

        return ImportedRecord(
            csl: csl,
            identifiers: identifiers,
            bibKey: entry.key,
            fileHints: extractFileHints(field("file"))
        )
    }

    // MARK: - Entry type

    private static func cslType(for type: BibTeXEntry.EntryType, hasArxiv: Bool) -> CSLType {
        switch type {
        case .article: return .articleJournal
        case .inproceedings: return .paperConference
        case .incollection, .inbook: return .chapter
        case .book: return .book
        case .phdthesis, .mastersthesis: return .thesis
        case .techreport: return .report
        case .misc, .unpublished: return hasArxiv ? .manuscript : .other
        case .online: return .webpage
        }
    }

    // MARK: - Names

    /// Splits an `author`/`editor` field into individual name strings.
    ///
    /// This has to run on the *raw*, still brace-protected field value and
    /// split only where " and " appears at brace depth zero - once
    /// `LaTeXEscaping.unescape` has run, protective braces like
    /// `{Barnes and Noble Inc.}` are already gone (unescape strips any brace
    /// pair it doesn't recognize as part of a command), so splitting after
    /// unescaping would tear an institutional name in two. Each piece is
    /// unescaped only after the split has already decided where the name
    /// boundaries are.
    private static func names(from rawValue: String?) -> [CSLName] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return splitOnAndAtDepthZero(rawValue).map { CSLName.parse(LaTeXEscaping.unescape($0)) }
    }

    private static func splitOnAndAtDepthZero(_ raw: String) -> [String] {
        let chars = Array(raw)
        let n = chars.count
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "{" {
                depth += 1
                current.append(c)
                i += 1
                continue
            }
            if c == "}" {
                depth -= 1
                current.append(c)
                i += 1
                continue
            }
            if depth == 0, matchesAndKeyword(chars, at: i) {
                pieces.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                i += 5 // length of " and "
                continue
            }
            current.append(c)
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { pieces.append(last) }
        return pieces.filter { !$0.isEmpty }
    }

    /// Matches the literal `" and "` starting at `chars[i]`, case-insensitive
    /// on the word itself (BibTeX convention is lowercase, but some tools
    /// export "AND").
    private static func matchesAndKeyword(_ chars: [Character], at i: Int) -> Bool {
        let word = Array(" and ")
        guard i + word.count <= chars.count else { return false }
        for offset in 0..<word.count {
            let a = chars[i + offset]
            let b = word[offset]
            if a == b { continue }
            guard a.isLetter, b.isLetter, a.lowercased() == b.lowercased() else { return false }
        }
        return true
    }

    // MARK: - Dates

    /// `date = {2024-05-17}` (biblatex) wins when present and parseable;
    /// otherwise falls back to `year` (+ optional `month`).
    private static func issuedDate(field: (String) -> String?) -> CSLDate? {
        if let dateRaw = field("date") {
            if let parsed = parseBiblatexDate(dateRaw) { return parsed }
        }
        guard let yearRaw = field("year"), let year = firstFourDigitYear(in: yearRaw) else {
            if let dateRaw = field("date") { return CSLDate(raw: dateRaw) }
            return nil
        }
        let month = field("month").flatMap(monthNumber(from:))
        return CSLDate(year: year, month: month)
    }

    /// Parses `YYYY`, `YYYY-MM`, or `YYYY-MM-DD`; a `/`-separated range takes
    /// only its start date, which is what "issued" means for CSL.
    private static func parseBiblatexDate(_ raw: String) -> CSLDate? {
        let start = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        let comps = start.split(separator: "-").map(String.init)
        guard let first = comps.first, let year = Int(first), (1500...2200).contains(year) else { return nil }
        var month: Int?
        var day: Int?
        if comps.count > 1, let m = Int(comps[1]), (1...12).contains(m) { month = m }
        if comps.count > 2, let d = Int(comps[2]), (1...31).contains(d) { day = d }
        return CSLDate(year: year, month: month, day: day)
    }

    private static func firstFourDigitYear(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 {
                    if let value = Int(digits), (1500...2200).contains(value) { return value }
                    digits.removeFirst()
                }
            } else {
                digits = ""
            }
        }
        return nil
    }

    private static let monthNames: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Accepts `jan`...`dec`, full month names (matched by their first three
    /// letters), and numeric `1`...`12`.
    private static func monthNumber(from raw: String) -> Int? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if let n = Int(cleaned), (1...12).contains(n) { return n }
        return monthNames[String(cleaned.prefix(3))]
    }

    // MARK: - Identifiers

    /// `eprint` only counts as an arXiv id when the entry says so - either
    /// `archiveprefix = {arXiv}` (the common biblatex/JabRef spelling) or
    /// `eprinttype = {arxiv}` (some tools omit archiveprefix and use this
    /// instead). Otherwise `eprint` could be pointing at any other preprint
    /// server and shouldn't be guessed at.
    private static func arxivID(entry: BibTeXEntry, field: (String) -> String?) -> String? {
        guard let eprint = field("eprint") else { return nil }
        let archivePrefix = (field("archiveprefix") ?? "").lowercased()
        let eprintType = (field("eprinttype") ?? "").lowercased()
        guard archivePrefix.contains("arxiv") || eprintType.contains("arxiv") else { return nil }
        return eprint
    }

    // MARK: - Pages

    /// `LaTeXEscaping.unescape` has already turned `--` into an en dash and
    /// `---` into an em dash by the time this runs (it applies to every
    /// field, not just prose), so both of those - and a plain `-` a source
    /// already used - normalize to a single ASCII hyphen.
    private static func normalizedPages(_ raw: String?) -> String? {
        guard var s = raw else { return nil }
        s = s.replacingOccurrences(of: "\u{2014}", with: "-")
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s
    }

    // MARK: - File hints

    /// Bookends/Zotero/JabRef write one or more `;`-separated file entries,
    /// each shaped like a bare `path.pdf` or a `description:path:TYPE`
    /// triple (either end optional, e.g. `:path/to/x.pdf:PDF`). The path is
    /// whichever colon-separated piece has a `.` in it, since a bare type
    /// marker ("PDF", "application/pdf") never does.
    private static func extractFileHints(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var hints: [String] = []
        for chunk in raw.split(separator: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: true)
            guard let fallback = parts.last else { continue }
            let path = parts.first(where: { $0.contains(".") }) ?? fallback
            let value = String(path).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { hints.append(value) }
        }
        return hints
    }
}
