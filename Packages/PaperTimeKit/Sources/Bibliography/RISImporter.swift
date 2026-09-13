import Foundation
import PaperCore

/// Parses RIS (`.ris`) files - the line-based tag format EndNote, Zotero,
/// PubMed and most reference managers can export - into the same
/// `BibTeXImporter.ImportedRecord` shape the BibTeX path produces, so
/// downstream code doesn't need to know which format a file came from.
public enum RISImporter {
    private typealias Tag = (tag: String, value: String)

    public static func records(from source: String) -> (records: [BibTeXImporter.ImportedRecord], warnings: [String]) {
        var warnings: [String] = []
        var results: [BibTeXImporter.ImportedRecord] = []

        // RIS is line-oriented; normalize CRLF up front so the tag matcher
        // only ever has to look at one line ending convention.
        let lines = source.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        let n = lines.count
        var i = 0
        var fallbackIndex = 0

        while i < n {
            // Free text before/between records (blank separator lines, a
            // banner some exporters prepend) is skipped, same as BibTeX's
            // header text.
            while i < n, parseTagLine(lines[i])?.tag != "TY" { i += 1 }
            guard i < n, let startTag = parseTagLine(lines[i]) else { break }

            var pairs: [Tag] = [("TY", startTag.value)]
            i += 1
            var closed = false

            while i < n {
                if let parsed = parseTagLine(lines[i]) {
                    i += 1
                    if parsed.tag == "ER" {
                        closed = true
                        break
                    }
                    pairs.append(parsed)
                } else {
                    // A line with no `XX  - ` prefix continues the previous
                    // tag's value - RIS wraps long abstracts/titles this way.
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, let last = pairs.popLast() {
                        let joined = last.value.isEmpty ? trimmed : "\(last.value) \(trimmed)"
                        pairs.append((last.tag, joined))
                    }
                    i += 1
                }
            }

            if !closed {
                warnings.append("RIS record for '\(pairs.first(where: { $0.tag == "TI" || $0.tag == "T1" })?.value ?? "?")' was never closed with 'ER  - '; kept anyway")
            }

            let (record, recordFallbackUsed) = buildRecord(from: pairs, fallbackIndex: fallbackIndex + 1)
            if recordFallbackUsed { fallbackIndex += 1 }
            results.append(record)
        }

        return (results, warnings)
    }

    /// Matches one `TAG  - value` line. Real files vary the exact spacing
    /// (one space, two spaces, a tab), so this only requires the two-letter
    /// tag, optional whitespace, a literal `-`, and an optional single space
    /// before the value - not the canonical `TAG␣␣-␣` exactly.
    private static func parseTagLine(_ line: String) -> Tag? {
        guard line.count >= 2 else { return nil }
        let chars = Array(line)
        guard chars[0].isUppercase || chars[0].isNumber,
              chars[1].isUppercase || chars[1].isNumber else { return nil }
        let tag = String(chars[0...1])

        var j = 2
        while j < chars.count, chars[j] == " " { j += 1 }
        guard j < chars.count, chars[j] == "-" else { return nil }
        j += 1
        if j < chars.count, chars[j] == " " { j += 1 }
        let value = String(chars[j...]).trimmingCharacters(in: .whitespaces)
        return (tag, value)
    }

    /// Builds one `ImportedRecord` from a record's ordered tag/value pairs.
    /// Returns whether the `ris<N>` fallback bibKey had to be used, so the
    /// caller only advances its counter for records that actually needed it.
    private static func buildRecord(from pairs: [Tag], fallbackIndex: Int) -> (BibTeXImporter.ImportedRecord, Bool) {
        func firstValue(_ tag: String) -> String? {
            guard let value = pairs.first(where: { $0.tag == tag })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        func allValues(_ tag: String) -> [String] {
            pairs.filter { $0.tag == tag }
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        // AU/A1/A3 are all "author" in the tag sets different exporters use;
        // A2 is conventionally the editor (e.g. of a book a chapter is in).
        // Order follows the file, not the tag, since a record can interleave them.
        var authors: [CSLName] = []
        var editors: [CSLName] = []
        for pair in pairs {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch pair.tag {
            case "AU", "A1", "A3": authors.append(CSLName.parse(value))
            case "A2": editors.append(CSLName.parse(value))
            default: break
            }
        }

        var csl = CSLItem()
        csl.type = cslType(fromTY: firstValue("TY"))
        csl.title = firstValue("TI") ?? firstValue("T1")
        csl.author = authors
        csl.editor = editors
        csl.issued = issuedDate(firstValue: firstValue)
        csl.containerTitle = firstValue("T2") ?? firstValue("JO") ?? firstValue("JF") ?? firstValue("J2")
        csl.page = pages(firstValue: firstValue)
        csl.volume = firstValue("VL")
        csl.issue = firstValue("IS")
        csl.publisher = firstValue("PB")
        csl.publisherPlace = firstValue("CY")
        csl.url = firstValue("UR")
        csl.abstract = firstValue("AB")
        csl.edition = firstValue("ET")
        csl.language = firstValue("LA")
        // M3 ("type of work") has no dedicated slot in CSLItem; genre is the
        // closest existing field ("type of medium").
        csl.genre = firstValue("M3")

        // CSLItem has no keywords field, so KW is folded into the note
        // alongside N1 rather than silently dropped.
        var noteParts: [String] = []
        if let n1 = firstValue("N1") { noteParts.append(n1) }
        let keywords = allValues("KW")
        if !keywords.isEmpty { noteParts.append("Keywords: " + keywords.joined(separator: "; ")) }
        csl.note = noteParts.isEmpty ? nil : noteParts.joined(separator: "\n")

        var issn: String?
        var isbn: String?
        if let sn = firstValue("SN") { (issn, isbn) = classifySN(sn) }
        csl.issn = issn

        let identifiers = Identifiers(doi: firstValue("DO"), pmid: nil, isbn: isbn)
        csl.doi = identifiers.doi
        csl.isbn = identifiers.isbn

        let (bibKey, usedFallback) = generateBibKey(
            authorSurname: authors.first?.sortingSurname,
            year: csl.year,
            title: csl.title,
            fallbackIndex: fallbackIndex
        )
        csl.id = bibKey

        let record = BibTeXImporter.ImportedRecord(csl: csl, identifiers: identifiers, bibKey: bibKey, fileHints: [])
        return (record, usedFallback)
    }

    private static func cslType(fromTY ty: String?) -> CSLType {
        switch (ty ?? "").uppercased() {
        case "JOUR": return .articleJournal
        case "CONF", "CPAPER": return .paperConference
        case "BOOK": return .book
        case "CHAP": return .chapter
        case "THES": return .thesis
        case "RPRT": return .report
        case "UNPB", "MANSCPT": return .manuscript
        case "ELEC": return .webpage
        default: return .other
        }
    }

    private static func pages(firstValue: (String) -> String?) -> String? {
        switch (firstValue("SP"), firstValue("EP")) {
        case let (sp?, ep?): return "\(sp)-\(ep)"
        case let (sp?, nil): return sp
        case let (nil, ep?): return ep
        default: return nil
        }
    }

    /// `PY`/`Y1` (publication date) takes precedence over `DA` (a secondary
    /// date field some formats use for e.g. an access or revision date).
    private static func issuedDate(firstValue: (String) -> String?) -> CSLDate? {
        for tag in ["PY", "Y1", "DA"] {
            guard let raw = firstValue(tag) else { continue }
            let (year, month, day) = parseRISDate(raw)
            if let year { return CSLDate(year: year, month: month, day: day) }
        }
        return nil
    }

    /// RIS dates are `YYYY`, `YYYY/MM`, or `YYYY/MM/DD/` (the trailing
    /// fourth "other info" slot, when present, is ignored).
    private static func parseRISDate(_ raw: String) -> (year: Int?, month: Int?, day: Int?) {
        let comps = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var year: Int?
        var month: Int?
        var day: Int?
        if comps.count > 0, let y = Int(comps[0]), (1500...2200).contains(y) { year = y }
        if comps.count > 1, let m = Int(comps[1]), (1...12).contains(m) { month = m }
        if comps.count > 2, let d = Int(comps[2]), (1...31).contains(d) { day = d }
        return (year, month, day)
    }

    /// `SN` carries either an ISSN (8 digits, `NNNN-NNNN`) or an ISBN (10 or
    /// 13 digits, hyphenation varies) with no tag to tell them apart -
    /// distinguished here purely by digit count once punctuation is stripped.
    private static func classifySN(_ raw: String) -> (issn: String?, isbn: String?) {
        let stripped = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        switch stripped.count {
        case 8: return (raw, nil)
        case 10, 13: return (nil, raw)
        default: return (nil, nil)
        }
    }

    /// `firstauthorYEARfirstword`, lowercase ASCII only. Falls back to
    /// `ris1`, `ris2`, ... when there's no author to key off of (or the
    /// author's name has no ASCII letters to build a key from at all).
    private static func generateBibKey(
        authorSurname: String?,
        year: Int?,
        title: String?,
        fallbackIndex: Int
    ) -> (key: String, usedFallback: Bool) {
        let familyPart = authorSurname.map(asciiAlnumLower) ?? ""
        guard !familyPart.isEmpty else {
            return ("ris\(fallbackIndex)", true)
        }
        let yearPart = year.map(String.init) ?? ""
        let firstWord = title?.split(separator: " ").first.map(String.init) ?? ""
        let titlePart = asciiAlnumLower(firstWord)
        return (familyPart + yearPart + titlePart, false)
    }

    private static func asciiAlnumLower(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars where scalar.isASCII {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                result += ch.lowercased()
            }
        }
        return result
    }
}
