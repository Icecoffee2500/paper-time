import Testing
import Bibliography

@Suite("RISImporter")
struct RISImporterTests {
    @Test("A two-record RIS file with a continuation line parses both records")
    func twoRecordsWithContinuationLine() {
        let lines = [
            "TY  - JOUR",
            "AU  - Smith, John",
            "AU  - Doe, Jane",
            "TI  - A Study of",
            "      Something Long",  // continuation line: no "XX  - " prefix
            "PY  - 2021/06/15/",
            "JO  - Journal of Examples",
            "SP  - 10",
            "EP  - 20",
            "DO  - 10.1000/xyz123",
            "ER  - ",
            "",
            "TY  - CONF",
            "AU  - Lee, Kim",
            "TI  - Another Paper",
            "PY  - 2019",
            "ER  - ",
        ]
        let source = lines.joined(separator: "\n")
        let (records, warnings) = RISImporter.records(from: source)

        #expect(records.count == 2)
        #expect(warnings.isEmpty)

        let first = records[0]
        // The continuation line joins onto TI with a single space.
        #expect(first.csl.title == "A Study of Something Long")
        #expect(first.csl.author.count == 2)
        #expect(first.csl.author.first?.family == "Smith")
        #expect(first.csl.issued?.year == 2021)
        #expect(first.csl.issued?.month == 6)
        #expect(first.csl.page == "10-20")
        #expect(first.csl.type == .articleJournal)
        #expect(first.csl.doi == "10.1000/xyz123")

        let second = records[1]
        #expect(second.csl.type == .paperConference)
        #expect(second.csl.title == "Another Paper")
        #expect(second.csl.issued?.year == 2019)
        // firstauthorYEARfirstword, lowercase ASCII only.
        #expect(second.bibKey == "lee2019another")
    }

    @Test("A record with no author falls back to 'risN'")
    func missingAuthorFallsBackToRisKey() {
        let lines = [
            "TY  - RPRT",
            "TI  - No Author Here",
            "PY  - 2020",
            "ER  - ",
        ]
        let (records, _) = RISImporter.records(from: lines.joined(separator: "\n"))
        #expect(records.count == 1)
        #expect(records[0].bibKey == "ris1")
        #expect(records[0].csl.type == .report)
    }

    @Test("A record missing its ER terminator still produces a warning, not a crash")
    func unterminatedRecordWarns() {
        let lines = [
            "TY  - JOUR",
            "TI  - Dangling Record",
            "AU  - Ng, Ray",
        ]
        let (records, warnings) = RISImporter.records(from: lines.joined(separator: "\n"))
        #expect(records.count == 1)
        #expect(!warnings.isEmpty)
    }
}
