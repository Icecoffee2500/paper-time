import Foundation
import PaperCore

/// A citation style Paper Time can render offline, with no network lookups
/// and no external style repository (unlike CSL processors, which need the
/// actual `.csl` file for the style). Each case hand-encodes the parts of the
/// style that matter for a reference list entry and its in-text form.
public enum CitationStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case apa7
    case ieee
    case acm
    case chicagoAuthorDate
    case mla9
    case nature
    case vancouver

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apa7: "APA 7th"
        case .ieee: "IEEE"
        case .acm: "ACM"
        case .chicagoAuthorDate: "Chicago (author-date)"
        case .mla9: "MLA 9th"
        case .nature: "Nature"
        case .vancouver: "Vancouver"
        }
    }

    /// One short paragraph telling the user when this style is used and the
    /// rule that trips people up.
    public var guidance: String {
        switch self {
        case .apa7:
            return "Used across psychology, education, and most social sciences. " +
                "The trap: only the first word of a title and subtitle (plus proper " +
                "nouns) are capitalized in the reference list, but Paper Time keeps " +
                "your stored title as-is rather than guessing which words are proper " +
                "nouns — check it before submitting."
        case .ieee:
            return "The standard for electrical engineering and computer science " +
                "conferences and journals. Citations are numbered in the order they " +
                "first appear in the text, not alphabetically — renumber if you " +
                "reorder citations."
        case .acm:
            return "Used by ACM conferences and journals (CHI, CCS, TOIT, ...). " +
                "Numbered like IEEE, but the reference list itself is typically " +
                "alphabetical by author, which is easy to mix up with the numbering order."
        case .chicagoAuthorDate:
            return "The author-date variant of Chicago style, common in the natural " +
                "and social sciences. Don't confuse it with Chicago's notes-" +
                "bibliography variant, which uses footnotes instead of parenthetical " +
                "author-year citations."
        case .mla9:
            return "Used in literature, languages, and other humanities disciplines. " +
                "MLA cites by author and page number, not year — if a source has no " +
                "page number (a webpage, for instance), the in-text citation drops to " +
                "just the author's name."
        case .nature:
            return "Used by Nature and many other science journals. References are " +
                "numbered by order of first citation and marked in the text as " +
                "superscript, not in brackets — easy to typeset wrong if you paste in brackets."
        case .vancouver:
            return "Used across biomedical and medical journals, following ICMJE " +
                "recommendations. Author initials carry no periods or spaces " +
                "('Smith AB', not 'Smith, A. B.'), which is the detail people most often get wrong."
        }
    }

    /// The in-text citation form, e.g. "(Zellers et al., 2018)" for APA, "[1]" for IEEE.
    public func inTextExample(for item: CSLItem, number: Int) -> String {
        CitationFormatter.inText(item, style: self, number: number)
    }
}

/// Renders a `CSLItem` as a formatted reference-list entry, entirely offline.
///
/// This is deliberately not a general CSL processor: each style below encodes
/// only the handful of rules Paper Time's supported styles need. The one rule
/// that applies everywhere is structural, not stylistic: every entry is
/// assembled from an array of already-non-empty components and joined, so a
/// record missing half its fields degrades to a shorter citation instead of
/// one full of dangling commas and empty parentheses.
public enum CitationFormatter {
    public static func format(_ item: CSLItem, style: CitationStyle, number: Int = 1) -> String {
        switch style {
        case .apa7: return apa7(item)
        case .ieee: return ieee(item, number: number)
        case .acm: return acm(item, number: number)
        case .chicagoAuthorDate: return chicago(item)
        case .mla9: return mla9(item)
        case .nature: return nature(item)
        case .vancouver: return vancouver(item)
        }
    }

    static func inText(_ item: CSLItem, style: CitationStyle, number: Int) -> String {
        switch style {
        case .apa7: return apaInText(item)
        case .ieee, .acm: return "[\(number)]"
        case .chicagoAuthorDate: return chicagoInText(item)
        case .mla9: return mlaInText(item)
        case .nature: return String(number)
        case .vancouver: return "(\(number))"
        }
    }

    // MARK: - APA 7th

    private static func apa7(_ item: CSLItem) -> String {
        let authors = apaAuthorList(item.author)
        let yearPart = item.year.map { "(\($0))" }
        let title = item.fullTitle
        let container = containerAndVolume(item, style: .apa7)
        let pages = pagesComponent(item.page, style: .apa7)
        let doi = doiOrURL(item)

        switch item.type {
        case .book:
            let publisher = publisherComponent(item)
            return joinSentence([authors, yearPart, title, publisher, doi].compactMap(nonEmpty))
        case .thesis:
            let school = thesisSchool(item)
            return joinSentence([authors, yearPart, title, school, doi].compactMap(nonEmpty))
        default:
            let containerPiece = [container, pages].compactMap(nonEmpty).joined(separator: ", ")
            return joinSentence([authors, yearPart, title, nonEmpty(containerPiece), doi].compactMap(nonEmpty))
        }
    }

    /// APA lists every author up to 20; beyond that it lists the first 19,
    /// an ellipsis, then the final author — a rule specific to the 7th
    /// edition (earlier editions truncated to seven).
    private static func apaAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        let rendered = authors.map { apaName($0) }
        if rendered.count <= 20 {
            return joinWithAmpersand(rendered)
        }
        let head = rendered.prefix(19)
        let tail = rendered[rendered.count - 1]
        return head.joined(separator: ", ") + ", ... " + tail
    }

    private static func apaName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        let initials = initialsWithPeriods(name.given)
        return [family, initials].compactMap(nonEmpty).joined(separator: ", ")
    }

    private static func apaInText(_ item: CSLItem) -> String {
        let year = item.year.map(String.init) ?? "n.d."
        let surnames = item.author.compactMap { $0.sortingSurname }
        guard !surnames.isEmpty else { return "(\(year))" }
        switch surnames.count {
        case 1:
            return "(\(surnames[0]), \(year))"
        case 2:
            return "(\(surnames[0]) & \(surnames[1]), \(year))"
        default:
            return "(\(surnames[0]) et al., \(year))"
        }
    }

    // MARK: - IEEE

    private static func ieee(_ item: CSLItem, number: Int) -> String {
        let authors = ieeeAuthorList(item.author)
        let title = item.fullTitle.map { "\"\($0),\"" }
        let container = ieeeContainer(item)
        let volIssue = volumeIssueComponent(item, style: .ieee)
        let pages = pagesComponent(item.page, style: .ieee)
        let year = item.year.map(String.init)
        let doi = item.type == .manuscript ? doiOrURL(item) : nil

        let tail = [container, volIssue, pages, year, doi].compactMap(nonEmpty).joined(separator: ", ")
        let head = [authors, title].compactMap(nonEmpty).joined(separator: ", ")
        // The comma before "in Container..." is already inside the title's
        // closing quote ("Title,") when a title is present, so joining head
        // and tail with another comma would double it up — space instead.
        let headTailSeparator = title != nil ? " " : ", "
        let body = [nonEmpty(head), nonEmpty(tail)].compactMap(nonEmpty).joined(separator: headTailSeparator)
        return "[\(number)] \(body)."
    }

    /// IEEE truncates at six or more authors to "et al." after the first —
    /// distinct from APA's 20-author cutoff.
    private static func ieeeAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        if authors.count >= 6 {
            return ieeeName(authors[0]) + " et al."
        }
        let rendered = authors.map { ieeeName($0) }
        return joinWithAnd(rendered)
    }

    private static func ieeeName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        let initials = initialsWithPeriods(name.given)
        return [initials, family].compactMap(nonEmpty).joined(separator: " ")
    }

    private static func ieeeContainer(_ item: CSLItem) -> String? {
        switch item.type {
        case .book:
            return item.publisher
        case .thesis:
            return thesisSchool(item)
        case .paperConference:
            return item.containerTitle.map { "in \($0)" } ?? item.eventTitle.map { "in \($0)" }
        case .manuscript:
            return "arXiv"
        default:
            return item.containerTitle
        }
    }

    // MARK: - ACM

    private static func acm(_ item: CSLItem, number: Int) -> String {
        let authors = acmAuthorList(item.author)
        let year = item.year.map(String.init)
        let title = item.fullTitle
        let doi = item.doi.map { "DOI:https://doi.org/\($0)" }

        switch item.type {
        case .book:
            let publisher = publisherComponent(item)
            return joinSentence([authors, year, title, publisher, doi].compactMap(nonEmpty))
        case .thesis:
            let school = thesisSchool(item)
            return joinSentence([authors, year, title, school, doi].compactMap(nonEmpty))
        default:
            let container = acmContainer(item)
            // ACM repeats the year: once after the author list, once again
            // in the "Volume, Issue (Year)" parenthetical — that
            // duplication is the house style, not a bug.
            let volIssueYear: String? = {
                let vi = volumeIssueComponent(item, style: .acm)
                guard let vi, let year else { return vi ?? year }
                return "\(vi) (\(year))"
            }()
            let pages = pagesComponent(item.page, style: .acm)
            let containerPiece: String? = {
                guard let container else { return nil }
                let rest = [volIssueYear, pages].compactMap(nonEmpty).joined(separator: ", ")
                return rest.isEmpty ? "In \(container)" : "In \(container), \(rest)"
            }()
            return joinSentence([authors, year, title, containerPiece, doi].compactMap(nonEmpty))
        }
    }

    private static func acmAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        let rendered = authors.map { acmName($0) }
        return joinWithAnd(rendered)
    }

    private static func acmName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        let given = name.given
        return [given, family].compactMap(nonEmpty).joined(separator: " ")
    }

    private static func acmContainer(_ item: CSLItem) -> String? {
        switch item.type {
        case .book: return nil
        case .thesis: return nil
        case .manuscript: return "arXiv"
        default: return item.containerTitle ?? item.eventTitle
        }
    }

    // MARK: - Chicago (author-date)

    private static func chicago(_ item: CSLItem) -> String {
        let authors = chicagoAuthorList(item.author)
        let year = item.year.map { "\($0)." }
        let title = item.fullTitle.map { "\"\($0).\"" }
        let doi = doiOrURL(item)

        switch item.type {
        case .book:
            let publisher = publisherComponent(item)
            return joinSentence([authors, year, item.fullTitle, publisher, doi].compactMap(nonEmpty))
        case .thesis:
            let school = thesisSchool(item)
            return joinSentence([authors, year, item.fullTitle, school, doi].compactMap(nonEmpty))
        default:
            let container = item.containerTitle ?? (item.type == .manuscript ? "arXiv" : nil)
            let volIssuePages: String? = {
                let vi = volumeIssueComponent(item, style: .chicagoAuthorDate)
                let pages = item.page.map { normalizedPageRange($0) }
                switch (vi, pages) {
                case let (vi?, pages?): return "\(vi): \(pages)"
                case let (vi?, nil): return vi
                case let (nil, pages?): return pages
                default: return nil
                }
            }()
            let containerPiece = [container, volIssuePages].compactMap(nonEmpty).joined(separator: " ")

            // `title` already ends with its own period inside the closing
            // quote ("\"Title.\""), so it's stitched on with a space rather
            // than run back through `joinSentence` — that would add a
            // second period in front of the quote mark.
            let head = joinSentence([authors, year].compactMap(nonEmpty))
            let withTitle = [nonEmpty(head), title].compactMap(nonEmpty).joined(separator: " ")
            let tail = joinSentence([nonEmpty(containerPiece), doi].compactMap(nonEmpty))
            return [nonEmpty(withTitle), nonEmpty(tail)].compactMap(nonEmpty).joined(separator: " ")
        }
    }

    /// Chicago author-date inverts only the first author's name; co-authors
    /// stay in natural order, unlike APA/Vancouver which invert everyone.
    private static func chicagoAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        let first = chicagoInvertedName(authors[0])
        guard authors.count > 1 else { return first.map { "\($0)." } }
        let rest = authors.dropFirst().map { chicagoNaturalName($0) }
        let all = ([first].compactMap { $0 }) + rest
        return joinWithAnd(all).map { "\($0)." }
    }

    private static func chicagoInvertedName(_ name: CSLName) -> String? {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return nil }
        guard let given = nonEmpty(name.given) else { return family }
        return "\(family), \(given)"
    }

    private static func chicagoNaturalName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        guard let given = nonEmpty(name.given) else { return family }
        return "\(given) \(family)"
    }

    private static func chicagoInText(_ item: CSLItem) -> String {
        let year = item.year.map(String.init) ?? "n.d."
        guard let surname = item.author.first?.sortingSurname else { return "(\(year))" }
        return "(\(surname) \(year))"
    }

    // MARK: - MLA 9th

    private static func mla9(_ item: CSLItem) -> String {
        let authors = mlaAuthorList(item.author)
        let title = item.fullTitle.map { "\"\($0).\"" }
        let container = mlaContainer(item)
        let volIssue = volumeIssueComponent(item, style: .mla9)
        let year = item.year.map(String.init)
        let pages = pagesComponent(item.page, style: .mla9)

        switch item.type {
        case .book:
            let publisher = publisherComponent(item)
            return joinSentence([authors.map { "\($0)." }, item.fullTitle, publisher, year].compactMap(nonEmpty))
        case .thesis:
            let school = thesisSchool(item)
            return joinSentence([authors.map { "\($0)." }, item.fullTitle, school, year].compactMap(nonEmpty))
        default:
            // MLA's template has no DOI slot, but a preprint has nothing
            // else identifying where to find it, so one is appended anyway.
            let doi = item.type == .manuscript ? doiOrURL(item) : nil
            let tail = [container, volIssue, year, pages, doi].compactMap(nonEmpty).joined(separator: ", ")
            // Authors and title already carry their own closing punctuation
            // ("Surname, Given, et al." / "\"Title.\""), so they're stitched
            // to the tail with a plain space rather than `joinSentence`,
            // which would add a second period on top of the one already there.
            let head = [authors.map { "\($0)." }, title].compactMap(nonEmpty).joined(separator: " ")
            if tail.isEmpty { return head }
            return head.isEmpty ? "\(tail)." : "\(head) \(tail)."
        }
    }

    /// MLA 9 collapses to "et al." at three or more authors — its own
    /// threshold, lower than IEEE's six and APA's twenty.
    private static func mlaAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        if authors.count >= 3 {
            return mlaInvertedName(authors[0]) + ", et al."
        }
        if authors.count == 2 {
            let first = mlaInvertedName(authors[0])
            let second = mlaNaturalName(authors[1])
            return [first, second].joined(separator: ", and ")
        }
        return mlaInvertedName(authors[0])
    }

    private static func mlaInvertedName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        guard let given = nonEmpty(name.given) else { return family }
        return "\(family), \(given)"
    }

    private static func mlaNaturalName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        guard let given = nonEmpty(name.given) else { return family }
        return "\(given) \(family)"
    }

    private static func mlaContainer(_ item: CSLItem) -> String? {
        switch item.type {
        case .manuscript: return "arXiv"
        default: return item.containerTitle ?? item.eventTitle
        }
    }

    private static func mlaInText(_ item: CSLItem) -> String {
        guard let surname = item.author.first?.sortingSurname else {
            guard let title = item.fullTitle else { return "" }
            return "(\(title))"
        }
        guard let page = nonEmpty(item.page) else { return "(\(surname))" }
        return "(\(surname) \(normalizedPageRange(page)))"
    }

    // MARK: - Nature

    private static func nature(_ item: CSLItem) -> String {
        let authors = natureAuthorList(item.author)
        let title = item.fullTitle
        // The year sits in parentheses glued onto the end of the previous
        // component ("...pages (Year)."), not as its own sentence — folding
        // it into that component up front keeps `joinSentence` from
        // inserting a period in front of the parenthesis.
        let yearParen = item.year.map { "(\($0))" }

        switch item.type {
        case .book:
            let publisherLine = [publisherComponent(item), yearParen]
                .compactMap(nonEmpty).joined(separator: " ")
            return joinSentence([authors, title, nonEmpty(publisherLine)].compactMap(nonEmpty))
        case .thesis:
            let schoolLine = [thesisSchool(item), yearParen]
                .compactMap(nonEmpty).joined(separator: " ")
            return joinSentence([authors, title, nonEmpty(schoolLine)].compactMap(nonEmpty))
        default:
            let container = item.containerTitle ?? (item.type == .manuscript ? "arXiv" : item.eventTitle)
            let volume = item.volume
            let pages = item.page.map { normalizedPageRange($0) }
            let volPages = [volume, pages].compactMap(nonEmpty).joined(separator: ", ")
            let containerLine = [container, nonEmpty(volPages), yearParen]
                .compactMap(nonEmpty).joined(separator: " ")
            // Nature's template has no DOI slot; a preprint needs one anyway
            // since it has no volume/page to locate it by otherwise.
            let doi = item.type == .manuscript ? doiOrURL(item) : nil
            return joinSentence([authors, title, nonEmpty(containerLine), doi].compactMap(nonEmpty))
        }
    }

    /// Nature truncates after five authors — narrower than IEEE's six, which
    /// is easy to misremember since the two styles otherwise look similar.
    private static func natureAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        if authors.count > 5 {
            return natureName(authors[0]) + " et al."
        }
        let rendered = authors.map { natureName($0) }
        guard rendered.count > 1 else { return rendered.first }
        let head = rendered.dropLast().joined(separator: ", ")
        return "\(head) & \(rendered[rendered.count - 1])"
    }

    private static func natureName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        let initials = initialsWithPeriods(name.given)
        return [family, initials].compactMap(nonEmpty).joined(separator: ", ")
    }

    // MARK: - Vancouver

    private static func vancouver(_ item: CSLItem) -> String {
        let authors = vancouverAuthorList(item.author)
        let title = item.fullTitle.map { "\($0)." }

        switch item.type {
        case .book:
            let publisher = publisherComponent(item)
            let year = item.year.map(String.init)
            return joinSentence([authors, title, publisher, year].compactMap(nonEmpty))
        case .thesis:
            let school = thesisSchool(item)
            let year = item.year.map(String.init)
            return joinSentence([authors, title, school, year].compactMap(nonEmpty))
        default:
            let container = item.containerTitle.map { "\($0)." } ?? (item.type == .manuscript ? "arXiv." : nil)
            let yearVolIssuePages: String? = {
                guard let year = item.year else { return nil }
                let volIssue = volumeIssueComponent(item, style: .vancouver)
                let pages = item.page.map { normalizedPageRange($0) }
                var result = "\(year)"
                if let volIssue { result += ";\(volIssue)" }
                if let pages { result += ":\(pages)" }
                return result
            }()
            // Vancouver's template has no DOI slot; a preprint needs one
            // anyway since it has no journal volume/page to locate it by.
            let doi = item.type == .manuscript ? doiOrURL(item) : nil
            return joinSentence(
                [authors, title, container, nonEmpty(yearVolIssuePages), doi].compactMap(nonEmpty)
            )
        }
    }

    /// Vancouver (ICMJE) lists up to six authors and truncates to "et al."
    /// beyond that — the strictest cutoff of the seven styles here.
    private static func vancouverAuthorList(_ authors: [CSLName]) -> String? {
        guard !authors.isEmpty else { return nil }
        if authors.count > 6 {
            let firstSix = authors.prefix(6).map { vancouverName($0) }
            return firstSix.joined(separator: ", ") + ", et al."
        }
        let rendered = authors.map { vancouverName($0) }
        return rendered.joined(separator: ", ")
    }

    private static func vancouverName(_ name: CSLName) -> String {
        if let literal = name.literal, !literal.isEmpty { return literal }
        guard let family = name.sortingSurname, !family.isEmpty else { return "" }
        // No periods, no spaces between initials — the detail most guides get wrong.
        let initials = initialsPlain(name.given)
        return [family, initials].compactMap(nonEmpty).joined(separator: " ")
    }

    // MARK: - Shared component builders

    /// A book uses publisher (and place, when present) in place of a
    /// container title; several styles share this shape.
    private static func publisherComponent(_ item: CSLItem) -> String? {
        let pieces = [item.publisherPlace, item.publisher].compactMap(nonEmpty)
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: ": ")
    }

    /// A thesis substitutes its `genre` ("PhD dissertation") and treats the
    /// publisher field as the granting school, per CSL convention.
    private static func thesisSchool(_ item: CSLItem) -> String? {
        let pieces = [item.genre, item.publisher].compactMap(nonEmpty)
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: ", ")
    }

    private static func containerAndVolume(_ item: CSLItem, style: CitationStyle) -> String? {
        let container = item.containerTitle ?? (item.type == .manuscript ? "arXiv" : item.eventTitle)
        let volIssue = volumeIssueComponent(item, style: style)
        let combined = [container, volIssue].compactMap(nonEmpty).joined(separator: ", ")
        return combined.isEmpty ? nil : combined
    }

    /// "Volume(Issue)" where the style wants issue parenthesised (APA,
    /// Chicago, ACM), or "vol. X, no. Y" for IEEE/MLA's labelled form.
    private static func volumeIssueComponent(_ item: CSLItem, style: CitationStyle) -> String? {
        let volume = nonEmpty(item.volume)
        let issue = nonEmpty(item.issue)
        switch style {
        case .ieee:
            let vol = volume.map { "vol. \($0)" }
            let no = issue.map { "no. \($0)" }
            let joined = [vol, no].compactMap { $0 }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        case .mla9:
            let vol = volume.map { "vol. \($0)" }
            let no = issue.map { "no. \($0)" }
            let joined = [vol, no].compactMap { $0 }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        case .vancouver:
            guard let volume else { return issue.map { "(\($0))" } }
            return issue.map { "\(volume)(\($0))" } ?? volume
        case .acm:
            // ACM writes "Volume, Issue" — a plain comma, not a parenthetical.
            let joined = [volume, issue].compactMap { $0 }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        default: // apa7, chicagoAuthorDate, nature
            guard let volume else { return nil }
            return issue.map { "\(volume)(\($0))" } ?? volume
        }
    }

    private static func pagesComponent(_ raw: String?, style: CitationStyle) -> String? {
        guard let normalised = raw.map({ normalizedPageRange($0) }), !normalised.isEmpty else { return nil }
        let isRange = normalised.contains("-")
        switch style {
        case .ieee, .mla9:
            return (isRange ? "pp. " : "p. ") + normalised
        case .acm:
            return normalised
        default:
            return normalised
        }
    }

    private static func doiOrURL(_ item: CSLItem) -> String? {
        if let doi = nonEmpty(item.doi) { return "https://doi.org/\(doi)" }
        return nonEmpty(item.url)
    }

    // MARK: - Name/text primitives

    /// "John Ronald" -> "J. R." Institutional names never reach this path.
    private static func initialsWithPeriods(_ given: String?) -> String? {
        guard let given, !given.isEmpty else { return nil }
        let letters = given.split(separator: " ").compactMap { $0.first }
        guard !letters.isEmpty else { return nil }
        return letters.map { "\($0)." }.joined(separator: " ")
    }

    /// Vancouver's initials carry no periods or separating spaces: "JR".
    private static func initialsPlain(_ given: String?) -> String? {
        guard let given, !given.isEmpty else { return nil }
        let letters = given.split(separator: " ").compactMap { $0.first }
        guard !letters.isEmpty else { return nil }
        return String(letters)
    }

    /// Normalises "120--134", "120-134", en/em dashes, and a bare "120" to a
    /// single hyphenated form ("120-134" or "120").
    static func normalizedPageRange(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " ", with: "")
        let parts = collapsed.split(separator: "-", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        guard parts.count > 1 else { return String(parts[0]) }
        return "\(parts.first!)-\(parts.last!)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func joinWithAmpersand(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        let head = names.dropLast().joined(separator: ", ")
        return "\(head), & \(names[names.count - 1])"
    }

    private static func joinWithAnd(_ names: [String]) -> String? {
        let filtered = names.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return nil }
        guard filtered.count > 1 else { return filtered[0] }
        if filtered.count == 2 { return "\(filtered[0]) and \(filtered[1])" }
        let head = filtered.dropLast().joined(separator: ", ")
        return "\(head), and \(filtered[filtered.count - 1])"
    }

    /// Joins non-empty sentence-level components with ". " and ensures the
    /// whole citation ends with exactly one period — never zero, never a
    /// component's trailing period doubled up. The one exception: a
    /// citation that ends in a bare DOI/URL (APA, ACM, Chicago all do this)
    /// is left without a trailing period, matching how those styles are
    /// actually written — a period glued to a URL reads as part of it.
    private static func joinSentence(_ parts: [String]) -> String {
        let cleaned = parts.map { part -> String in
            var trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed
        }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        let joined = cleaned.joined(separator: ". ")
        if let last = cleaned.last, last.contains("http") { return joined }
        return joined + "."
    }
}
