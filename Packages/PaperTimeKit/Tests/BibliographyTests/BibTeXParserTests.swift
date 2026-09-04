import Testing
import Bibliography

// These tests only `import Bibliography` (not `PaperCore` directly, since the
// BibliographyTests target doesn't declare that dependency) - member access
// and `==`/`.caseName` comparisons on PaperCore-defined types like `CSLType`
// still work through type inference on values already typed by Bibliography's
// own public API, without spelling the type name ourselves.

@Suite("BibTeXParser")
struct BibTeXParserTests {
    @Test("Nested braces inside a value are preserved")
    func nestedBracesPreserved() {
        let source = "@article{key1, title = {A {BERT} Study}}"
        let result = BibTeXParser.parse(source)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.type == .article)
        #expect(result.entries.first?["title"] == "A {BERT} Study")
        #expect(result.warnings.isEmpty)
    }

    @Test("Quoted values keep embedded braces")
    func quotedValueWithEmbeddedBraces() {
        let source = #"@article{k2, title = "A {Special} Title"}"#
        let result = BibTeXParser.parse(source)
        #expect(result.entries.first?["title"] == "A {Special} Title")
    }

    @Test("@string macros expand as bare values and inside # concatenation")
    func stringExpansionAndConcatenation() {
        let source = [
            "@string{acl = {Association for Computational Linguistics}}",
            "@inproceedings{k3, publisher = \"Proc. \" # acl, organization = acl}",
        ].joined(separator: "\n")
        let result = BibTeXParser.parse(source)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?["publisher"] == "Proc. Association for Computational Linguistics")
        #expect(result.entries.first?["organization"] == "Association for Computational Linguistics")
    }

    @Test("A truncated final entry warns but keeps the entries parsed so far")
    func truncatedFinalEntryKeepsPriorEntries() {
        let source = [
            "@article{good, title = {Complete}}",
            "@article{broken, title = {Never closes",
        ].joined(separator: "\n")
        let result = BibTeXParser.parse(source)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.key == "good")
        #expect(!result.warnings.isEmpty)
    }

    @Test("@comment, @preamble and free header text are skipped")
    func commentPreambleAndFreeTextSkipped() {
        let source = [
            "Some header text exported by a tool.",
            "@comment{this is ignored, even with { braces } inside}",
            "@preamble{\"\\newcommand{\\x}{y}\"}",
            "@misc{m1, title = {Kept}}",
        ].joined(separator: "\n")
        let result = BibTeXParser.parse(source)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.key == "m1")
    }

    @Test("A trailing comma before the closing brace is tolerated")
    func trailingCommaBeforeClosingBrace() {
        let source = "@misc{tc1, title = {T}, year = {2020},}"
        let result = BibTeXParser.parse(source)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?["year"] == "2020")
    }

    @Test("A duplicate field name keeps the first occurrence and warns")
    func duplicateFieldKeepsFirstOccurrence() {
        let source = "@misc{d1, title = {First}, title = {Second}}"
        let result = BibTeXParser.parse(source)
        #expect(result.entries.first?["title"] == "First")
        #expect(result.warnings.contains { $0.contains("Duplicate") })
    }

    @Test("Internal newlines and runs of whitespace collapse to a single space")
    func whitespaceInsideValuesCollapses() {
        let source = "@article{w1, title = {A very\n    long   title\nthat wraps}}"
        let result = BibTeXParser.parse(source)
        #expect(result.entries.first?["title"] == "A very long title that wraps")
    }

    @Test("Bare numeric and macro-shaped values are read without quotes or braces")
    func bareValues() {
        let source = "@article{n1, year = 2024, month = jan}"
        let result = BibTeXParser.parse(source)
        #expect(result.entries.first?["year"] == "2024")
        #expect(result.entries.first?["month"] == "jan")
    }
}

@Suite("BibTeXImporter")
struct BibTeXImporterTests {
    @Test("' and ' only splits authors at brace depth zero")
    func authorSplitPreservesBracedInstitutionalName() {
        let source = #"@misc{inst1, author = {John Smith and {Barnes and Noble Inc.} and Jane Doe}}"#
        let entries = BibTeXParser.parse(source).entries
        let record = BibTeXImporter.record(from: entries[0])
        #expect(record.csl.author.count == 3)
        #expect(record.csl.author[0].family == "Smith")
        // The braced institutional name must survive as one author, not two.
        #expect(record.csl.author[1].family == "Inc.")
        #expect(record.csl.author[1].given == "Barnes and Noble")
        #expect(record.csl.author[2].family == "Doe")
    }

    @Test("Both '--' and '-' page ranges normalize to a single hyphen")
    func pageRangeNormalization() {
        let source = [
            "@article{p1, pages = {120--134}}",
            "@article{p2, pages = {120-134}}",
        ].joined(separator: "\n")
        let entries = BibTeXParser.parse(source).entries
        #expect(BibTeXImporter.record(from: entries[0]).csl.page == "120-134")
        #expect(BibTeXImporter.record(from: entries[1]).csl.page == "120-134")
    }

    @Test("The three real-world 'file' field shapes all yield clean paths")
    func fileFieldShapes() {
        let source = [
            "@misc{f1, file = {:path/to/x.pdf:PDF}}",
            "@misc{f2, file = {path.pdf}}",
            "@misc{f3, file = {:a.pdf:PDF;:b.pdf:PDF}}",
        ].joined(separator: "\n")
        let entries = BibTeXParser.parse(source).entries
        #expect(BibTeXImporter.record(from: entries[0]).fileHints == ["path/to/x.pdf"])
        #expect(BibTeXImporter.record(from: entries[1]).fileHints == ["path.pdf"])
        #expect(BibTeXImporter.record(from: entries[2]).fileHints == ["a.pdf", "b.pdf"])
    }

    @Test("A biblatex 'date' field takes precedence over 'year'")
    func biblatexDateTakesPrecedence() {
        let source = "@article{bd1, date = {2024-05-17}, year = {1999}}"
        let entries = BibTeXParser.parse(source).entries
        let record = BibTeXImporter.record(from: entries[0])
        #expect(record.csl.issued?.year == 2024)
        #expect(record.csl.issued?.month == 5)
    }

    @Test("An arXiv eprint with archiveprefix is recognized")
    func arxivEprintWithArchivePrefix() {
        let source = #"@misc{ax1, title = {Some Preprint}, eprint = {2403.18293}, archiveprefix = {arXiv}}"#
        let entries = BibTeXParser.parse(source).entries
        let record = BibTeXImporter.record(from: entries[0])
        #expect(record.identifiers.arxiv == "2403.18293")
        #expect(record.csl.type == .manuscript)
    }

    @Test("An arXiv eprint via eprinttype (no archiveprefix) is also recognized")
    func arxivEprintViaEprintType() {
        let source = "@unpublished{ax2, eprint = {1706.03762}, eprinttype = {arxiv}}"
        let entries = BibTeXParser.parse(source).entries
        let record = BibTeXImporter.record(from: entries[0])
        #expect(record.identifiers.arxiv == "1706.03762")
        #expect(record.csl.type == .manuscript)
    }

    @Test("A plain eprint with no arXiv marker is left alone")
    func eprintWithoutArxivMarkerIsIgnored() {
        let source = "@misc{ax3, eprint = {some-id-123}}"
        let entries = BibTeXParser.parse(source).entries
        let record = BibTeXImporter.record(from: entries[0])
        #expect(record.identifiers.arxiv == nil)
    }
}
