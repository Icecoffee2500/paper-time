import Testing
import PaperCore
@testable import Bibliography

/// Fixtures shared across the style-by-style tests below.
private enum Fixtures {
    /// A journal article with three authors — the common case for APA-style
    /// "et al." rules (which don't kick in until far more than three).
    static let journalArticle = CSLItem(
        id: "smith2020deep",
        type: .articleJournal,
        title: "Deep Learning for Citation Formatting",
        author: [
            CSLName(family: "Smith", given: "Jane Alice"),
            CSLName(family: "Doe", given: "John Bertrand"),
            CSLName(family: "Nguyen", given: "Van"),
        ],
        issued: CSLDate(year: 2020, month: 6),
        containerTitle: "Journal of Applied Bibliography",
        volume: "12",
        issue: "3",
        page: "120--134",
        doi: "10.1000/xyz123"
    )

    /// A conference paper with eight authors — enough to trigger every
    /// style's "et al." truncation rule (the lowest cutoff here is MLA's
    /// three, the highest is APA's twenty... except this fixture also
    /// covers IEEE's six and Nature's five along the way).
    static let conferencePaper = CSLItem(
        id: "lee2018attention",
        type: .paperConference,
        title: "Attention Mechanisms at Scale",
        author: [
            CSLName(family: "Lee", given: "Kim"),
            CSLName(family: "Zhao", given: "Wei"),
            CSLName(family: "Patel", given: "Raj"),
            CSLName(family: "Garcia", given: "Maria"),
            CSLName(family: "Kim", given: "Soo"),
            CSLName(family: "Müller", given: "Anna"),
            CSLName(family: "Ivanov", given: "Petr"),
            CSLName(family: "Tanaka", given: "Yuki"),
        ],
        issued: CSLDate(year: 2018),
        containerTitle: "Proceedings of the International Conference on Machine Learning",
        eventTitle: "ICML 2018",
        page: "88-97"
    )

    /// An arXiv preprint with two authors, exercising the two-author join
    /// rules (APA's "&", MLA's "and") and the preprint container/DOI path.
    static let arxivPreprint = CSLItem(
        id: "zellers2018swag",
        type: .manuscript,
        title: "SWAG: A Large-Scale Adversarial Dataset",
        author: [
            CSLName(family: "Zellers", given: "Rowan"),
            CSLName(family: "Choi", given: "Yejin"),
        ],
        issued: CSLDate(year: 2018),
        doi: "10.48550/arXiv.1808.05326"
    )

    /// A single-author book, exercising the publisher/place path in place
    /// of a container title.
    static let book = CSLItem(
        id: "turing1950computing",
        type: .book,
        title: "Computing Machinery and Intelligence",
        author: [CSLName(family: "Turing", given: "Alan")],
        issued: CSLDate(year: 1950),
        publisher: "Mind Press",
        publisherPlace: "Oxford"
    )

    /// Almost nothing set: only a title. Every style must still degrade to
    /// something short and clean rather than a wall of stray punctuation.
    static let titleOnly = CSLItem(
        id: "anon-title-only",
        type: .articleJournal,
        title: "Untitled Findings"
    )
}

/// Asserts the structural, cross-style guarantee that a citation never
/// contains dangling punctuation left behind by a missing field.
private func expectNoDanglingPunctuation(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!text.contains(", ,"), "found ', ,' in: \(text)", sourceLocation: sourceLocation)
    #expect(!text.contains(" ."), "found ' .' in: \(text)", sourceLocation: sourceLocation)
    #expect(!text.contains("()"), "found '()' in: \(text)", sourceLocation: sourceLocation)
    #expect(!text.contains("(),"), "found '(),' in: \(text)", sourceLocation: sourceLocation)
    #expect(!text.hasSuffix(", ."), "ends with ', .' in: \(text)", sourceLocation: sourceLocation)
}

@Suite("CitationFormatter")
struct CitationFormatterTests {
    // MARK: - Per-style: first author surname + year present, no dangling punctuation

    @Test("Every style's journal-article rendering carries the first author's surname and year, cleanly", arguments: CitationStyle.allCases)
    func journalArticleContainsAuthorAndYear(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.journalArticle, style: style)
        #expect(text.contains("Smith"))
        #expect(text.contains("2020"))
        expectNoDanglingPunctuation(text)
    }

    @Test("Every style's book rendering carries the author's surname and year, cleanly", arguments: CitationStyle.allCases)
    func bookContainsAuthorAndYear(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.book, style: style)
        #expect(text.contains("Turing"))
        #expect(text.contains("1950"))
        expectNoDanglingPunctuation(text)
    }

    @Test("Every style's preprint rendering carries the first author's surname and year, cleanly", arguments: CitationStyle.allCases)
    func preprintContainsAuthorAndYear(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.arxivPreprint, style: style)
        #expect(text.contains("Zellers"))
        #expect(text.contains("2018"))
        expectNoDanglingPunctuation(text)
    }

    @Test("Every style's conference-paper rendering carries the first author's surname and year, cleanly", arguments: CitationStyle.allCases)
    func conferencePaperContainsAuthorAndYear(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: style)
        #expect(text.contains("Lee"))
        #expect(text.contains("2018"))
        expectNoDanglingPunctuation(text)
    }

    // MARK: - The dangling-punctuation guarantee on a near-empty record

    @Test("A title-only record renders as a short, clean string in every style", arguments: CitationStyle.allCases)
    func titleOnlyRecordIsClean(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.titleOnly, style: style)
        #expect(text.contains("Untitled Findings"))
        expectNoDanglingPunctuation(text)
        // "Clean" also means short: no more than the title plus a small
        // amount of style furniture (quotes, brackets, a trailing period).
        #expect(text.count < 60, "unexpectedly long output for a title-only record: \(text)")
    }

    // MARK: - Book renders publisher, not an empty journal slot

    @Test("APA book cites the publisher, not an empty container")
    func apaBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .apa7)
        #expect(text.contains("Mind Press"))
        #expect(text.contains("Oxford"))
    }

    @Test("IEEE book cites the publisher, not an empty container")
    func ieeeBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .ieee)
        #expect(text.contains("Mind Press"))
    }

    @Test("ACM book cites the publisher, not an empty container")
    func acmBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .acm)
        #expect(text.contains("Mind Press"))
        #expect(!text.contains("In "), "ACM book entries should not carry a leftover 'In <container>' clause")
    }

    @Test("Chicago book cites the publisher, not an empty container")
    func chicagoBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .chicagoAuthorDate)
        #expect(text.contains("Mind Press"))
    }

    @Test("MLA book cites the publisher, not an empty container")
    func mlaBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .mla9)
        #expect(text.contains("Mind Press"))
    }

    @Test("Nature book cites the publisher, not an empty container")
    func natureBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .nature)
        #expect(text.contains("Mind Press"))
    }

    @Test("Vancouver book cites the publisher, not an empty container")
    func vancouverBookUsesPublisher() {
        let text = CitationFormatter.format(Fixtures.book, style: .vancouver)
        #expect(text.contains("Mind Press"))
    }

    // MARK: - Preprint renders as arXiv with the DOI appended

    @Test("Preprint container renders as arXiv across every style", arguments: CitationStyle.allCases)
    func preprintRendersAsArxiv(style: CitationStyle) {
        let text = CitationFormatter.format(Fixtures.arxivPreprint, style: style)
        #expect(text.localizedCaseInsensitiveContains("arxiv") || text.contains("10.48550"))
    }

    // MARK: - The eight-author conference paper triggers each style's "et al." rule

    @Test("APA lists all eight authors (below its 20-author cutoff)")
    func apaDoesNotTruncateEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .apa7)
        #expect(text.contains("Tanaka"))
        #expect(!text.contains("et al."))
    }

    @Test("IEEE truncates eight authors to the first, plus et al.")
    func ieeeTruncatesEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .ieee)
        #expect(text.contains("et al."))
        #expect(!text.contains("Tanaka"))
    }

    @Test("ACM lists all eight authors (ACM has no truncation rule here)")
    func acmDoesNotTruncateEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .acm)
        #expect(text.contains("Tanaka"))
    }

    @Test("Chicago lists all eight authors, first inverted, rest natural order")
    func chicagoDoesNotTruncateEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .chicagoAuthorDate)
        #expect(text.contains("Lee, Kim"))
        #expect(text.contains("Yuki Tanaka"))
    }

    @Test("MLA truncates eight authors to the first, plus et al.")
    func mlaTruncatesEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .mla9)
        #expect(text.contains("et al."))
        #expect(!text.contains("Tanaka"))
    }

    @Test("Nature truncates eight authors (over its five-author cutoff) to the first, plus et al.")
    func natureTruncatesEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .nature)
        #expect(text.contains("et al."))
        #expect(!text.contains("Tanaka"))
    }

    @Test("Vancouver truncates eight authors to the first six, plus et al.")
    func vancouverTruncatesEightAuthors() {
        let text = CitationFormatter.format(Fixtures.conferencePaper, style: .vancouver)
        #expect(text.contains("et al."))
        #expect(text.contains("Müller")) // sixth author still listed
        #expect(!text.contains("Tanaka")) // eighth author is not
    }

    // MARK: - inTextExample shapes

    @Test("APA in-text citation shape by author count")
    func apaInTextShapes() {
        let one = CitationStyle.apa7.inTextExample(for: Fixtures.book, number: 1)
        #expect(one == "(Turing, 1950)")

        let two = CitationStyle.apa7.inTextExample(for: Fixtures.arxivPreprint, number: 1)
        #expect(two == "(Zellers & Choi, 2018)")

        let threePlus = CitationStyle.apa7.inTextExample(for: Fixtures.journalArticle, number: 1)
        #expect(threePlus == "(Smith et al., 2020)")
    }

    @Test("IEEE and ACM in-text citations are bracketed numbers")
    func ieeeAndAcmInTextAreNumbers() {
        #expect(CitationStyle.ieee.inTextExample(for: Fixtures.journalArticle, number: 7) == "[7]")
        #expect(CitationStyle.acm.inTextExample(for: Fixtures.journalArticle, number: 7) == "[7]")
    }

    @Test("Chicago in-text citation is author-year, no comma")
    func chicagoInTextShape() {
        let text = CitationStyle.chicagoAuthorDate.inTextExample(for: Fixtures.journalArticle, number: 1)
        #expect(text == "(Smith 2020)")
    }

    @Test("MLA in-text citation includes the page, or drops to just the author without one")
    func mlaInTextShapes() {
        let withPage = CitationStyle.mla9.inTextExample(for: Fixtures.journalArticle, number: 1)
        #expect(withPage == "(Smith 120-134)")

        let withoutPage = CitationStyle.mla9.inTextExample(for: Fixtures.arxivPreprint, number: 1)
        #expect(withoutPage == "(Zellers)")
    }

    @Test("Nature in-text citation is a bare superscript-ready number")
    func natureInTextShape() {
        #expect(CitationStyle.nature.inTextExample(for: Fixtures.journalArticle, number: 3) == "3")
    }

    @Test("Vancouver in-text citation is a parenthesised number")
    func vancouverInTextShape() {
        #expect(CitationStyle.vancouver.inTextExample(for: Fixtures.journalArticle, number: 3) == "(3)")
    }

    // MARK: - Page-range normalisation

    @Test("A double-hyphen page range normalises to a single hyphen")
    func pageRangeNormalisesDoubleHyphen() {
        #expect(CitationFormatter.normalizedPageRange("120--134") == "120-134")
        #expect(CitationFormatter.normalizedPageRange("120-134") == "120-134")
        #expect(CitationFormatter.normalizedPageRange("120") == "120")
    }

    @Test("IEEE distinguishes a single page (p.) from a range (pp.)")
    func ieeeSingleVsRangePages() {
        var single = Fixtures.journalArticle
        single.page = "42"
        let singleText = CitationFormatter.format(single, style: .ieee)
        #expect(singleText.contains("p. 42"))
        #expect(!singleText.contains("pp. 42"))

        let rangeText = CitationFormatter.format(Fixtures.journalArticle, style: .ieee)
        #expect(rangeText.contains("pp. 120-134"))
    }

    // MARK: - Institutional authors render whole, never initialised

    @Test("An institutional author (literal name) is never split into initials", arguments: CitationStyle.allCases)
    func institutionalAuthorRendersWhole(style: CitationStyle) {
        var item = Fixtures.journalArticle
        item.author = [CSLName(literal: "World Health Organization")]
        let text = CitationFormatter.format(item, style: style)
        #expect(text.contains("World Health Organization"))
        expectNoDanglingPunctuation(text)
    }

    // MARK: - displayName and guidance are non-empty for every style

    @Test("Every style has a non-empty display name and guidance paragraph", arguments: CitationStyle.allCases)
    func displayNameAndGuidanceArePresent(style: CitationStyle) {
        #expect(!style.displayName.isEmpty)
        #expect(style.guidance.count > 20)
    }
}
