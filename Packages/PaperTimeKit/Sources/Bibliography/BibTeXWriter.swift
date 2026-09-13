import Foundation
import PaperCore

/// Turns bibliographic records into a `.bib` file.
public enum BibTeXWriter {
    /// The order fields are written in.
    ///
    /// Fixed rather than alphabetical so that re-exporting a library produces a
    /// minimal diff, and so a person reading the file sees the identifying
    /// fields first.
    private static let fieldOrder = [
        "author", "editor", "title", "subtitle", "booktitle", "journal",
        "series", "year", "month", "volume", "number", "pages", "publisher",
        "school", "institution", "organization", "address", "edition",
        "eprint", "archivePrefix", "primaryClass", "doi", "issn", "isbn",
        "url", "urldate", "language", "note", "keywords", "abstract", "file",
    ]

    // MARK: - Entry construction

    public static func entry(
        for item: CSLItem,
        key: String,
        identifiers: Identifiers = Identifiers(),
        options: BibTeXExportOptions = .default,
        fileHint: String? = nil,
        keywords: [String] = []
    ) -> BibTeXEntry {
        let isPreprint = item.type == .manuscript && identifiers.arxiv != nil
        let usesPreprintArticle = isPreprint && options.preprintStyle == .arxivPreprintArticle

        var type = BibTeXEntry.EntryType.forCSL(
            item.type,
            hasContainer: item.containerTitle?.isEmpty == false
        )
        if usesPreprintArticle { type = .article }
        if item.type == .thesis, item.genre?.localizedCaseInsensitiveContains("master") == true {
            type = .mastersthesis
        }

        var fields: [BibTeXEntry.Field] = []
        func put(_ name: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            fields.append(BibTeXEntry.Field(name: name, value: value))
        }

        put("author", nameList(item.author))
        put("editor", nameList(item.editor))
        put("title", titleValue(item.fullTitle, options: options))

        switch type {
        case .inproceedings, .incollection, .inbook:
            put("booktitle", titleValue(containerName(item, options: options), options: options))
        case .article:
            if usesPreprintArticle, let arxiv = identifiers.arxiv {
                put("journal", "arXiv preprint arXiv:\(arxiv)")
            } else {
                put("journal", titleValue(containerName(item, options: options), options: options))
            }
        case .book, .misc, .online, .unpublished, .phdthesis, .mastersthesis, .techreport:
            break
        }
        put("series", titleValue(item.collectionTitle, options: options))

        put("year", item.year.map(String.init))
        put("month", monthName(item.issued?.month))
        put("volume", item.volume)
        // CSL keeps issue and report number apart; BibTeX overloads `number`.
        put("number", type == .article ? item.issue : (item.number ?? item.issue))
        put("pages", pageRange(item.page))

        switch type {
        case .phdthesis, .mastersthesis:
            put("school", escape(item.publisher))
        case .techreport:
            put("institution", escape(item.publisher))
        default:
            put("publisher", escape(item.publisher))
        }
        put("address", escape(item.publisherPlace))
        put("edition", item.edition)

        if isPreprint, options.preprintStyle == .eprint, let arxiv = identifiers.arxiv {
            put("eprint", arxiv)
            put("archivePrefix", "arXiv")
            put("primaryClass", primaryClass(from: item.note))
        }

        put("doi", identifiers.doi ?? item.doi)
        put("issn", item.issn)
        put("isbn", item.isbn ?? identifiers.isbn)
        if options.includeURL {
            put("url", item.url ?? identifiers.doi.map { "https://doi.org/\($0)" })
        }
        put("language", item.language)
        put("note", escape(item.note))
        if options.includeKeywords, !keywords.isEmpty {
            put("keywords", escape(keywords.joined(separator: ", ")))
        }
        if options.includeAbstract {
            put("abstract", escape(item.abstract))
        }
        if options.includeFileField, let fileHint {
            put("file", fileHint)
        }

        let ordered = fields.sorted { lhs, rhs in
            let left = fieldOrder.firstIndex(of: lhs.name) ?? fieldOrder.count
            let right = fieldOrder.firstIndex(of: rhs.name) ?? fieldOrder.count
            return left == right ? lhs.name < rhs.name : left < right
        }
        return BibTeXEntry(type: type, key: key, fields: ordered)
    }

    // MARK: - Serialisation

    public static func write(_ entry: BibTeXEntry) -> String {
        guard !entry.fields.isEmpty else { return "@\(entry.type.rawValue){\(entry.key)}\n" }
        let width = entry.fields.map(\.name.count).max() ?? 0
        var lines = ["@\(entry.type.rawValue){\(entry.key),"]
        for (index, field) in entry.fields.enumerated() {
            let padding = String(repeating: " ", count: width - field.name.count)
            let comma = index == entry.fields.count - 1 ? "" : ","
            lines.append("  \(field.name)\(padding) = {\(field.value)}\(comma)")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(
        _ entries: [BibTeXEntry],
        options: BibTeXExportOptions = .default,
        generatedAt: Date = .now
    ) -> String {
        var output = ""
        if options.includeHeader {
            let stamp = generatedAt.formatted(.iso8601.year().month().day())
            output += "% Exported by Paper Time on \(stamp)\n"
            output += "% \(entries.count) reference\(entries.count == 1 ? "" : "s")\n\n"
        }
        output += entries.map(write).joined(separator: "\n")
        return output
    }

    // MARK: - Field helpers

    /// `Last, First and Last, First` — the only form BibTeX parses unambiguously
    /// for names with particles or multi-word surnames.
    static func nameList(_ names: [CSLName]) -> String? {
        let rendered = names.compactMap { name -> String? in
            if let literal = name.literal, !literal.isEmpty {
                // Braces keep an institution from being split into first/last.
                return "{\(LaTeXEscaping.escape(literal))}"
            }
            guard let family = name.sortingSurname, !family.isEmpty else { return nil }
            let escapedFamily = LaTeXEscaping.escape(family)
            guard let given = name.given, !given.isEmpty else { return escapedFamily }
            var result = "\(escapedFamily), \(LaTeXEscaping.escape(given))"
            if let suffix = name.suffix, !suffix.isEmpty {
                result = "\(escapedFamily), \(LaTeXEscaping.escape(suffix)), \(LaTeXEscaping.escape(given))"
            }
            return result
        }
        return rendered.isEmpty ? nil : rendered.joined(separator: " and ")
    }

    static func titleValue(_ raw: String?, options: BibTeXExportOptions) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let escaped = LaTeXEscaping.escape(TextNormalization.collapsingWhitespace(raw))
        return options.protectCase ? CaseProtection.protectTitle(escaped) : escaped
    }

    static func escape(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return LaTeXEscaping.escape(TextNormalization.collapsingWhitespace(raw))
    }

    static func containerName(_ item: CSLItem, options: BibTeXExportOptions) -> String? {
        if options.abbreviateJournals, let short = item.containerTitleShort, !short.isEmpty {
            return short
        }
        return item.containerTitle ?? item.eventTitle
    }

    /// BibTeX wants an en-dash range; sources send hyphens, en-dashes, and the
    /// occasional single page.
    static func pageRange(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalised = raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalised.split(separator: "-", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return normalised }
        return "\(parts[0])--\(parts[parts.count - 1])"
    }

    static func monthName(_ month: Int?) -> String? {
        guard let month, (1...12).contains(month) else { return nil }
        return ["jan", "feb", "mar", "apr", "may", "jun",
                "jul", "aug", "sep", "oct", "nov", "dec"][month - 1]
    }

    /// Recovers "cs.CV" from the note the arXiv mapper writes.
    static func primaryClass(from note: String?) -> String? {
        guard let note,
              let open = note.firstIndex(of: "["),
              let close = note.firstIndex(of: "]"),
              open < close
        else { return nil }
        let value = String(note[note.index(after: open)..<close])
        return value.isEmpty ? nil : value
    }
}
