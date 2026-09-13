import Foundation
import Testing
import PaperCore
@testable import MetadataPipeline

/// Decoding tests against real, captured API response fixtures.
///
/// These exist because the DTOs in `MetadataPipeline/Clients` are the seam
/// where a wire format Paper Time doesn't control (Crossref, OpenAlex,
/// CSL-JSON from doi.org) meets the app's own `CSLItem` model. A shape the
/// fixture doesn't actually have is a bug that only shows up in production,
/// against real data — unit tests against hand-rolled JSON don't catch it.
@Suite("DTO decoding against fixtures")
struct DTODecodingTests {
    // MARK: - Fixture loading

    /// `Bundle.module.url(forResource:withExtension:subdirectory:)` is the
    /// documented way to reach a `.copy("Fixtures")` resource, but SwiftPM's
    /// bundle layout has changed shape across toolchains before, so this
    /// falls back to a lookup without the subdirectory rather than assuming
    /// one specific layout.
    private static func fixtureURL(_ name: String, ext: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        Issue.record("Fixture \(name).\(ext) not found in Bundle.module")
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixtureData(_ name: String, ext: String = "json") throws -> Data {
        try Data(contentsOf: try fixtureURL(name, ext: ext))
    }

    // MARK: - 1. Crossref single-work response

    @Test("crossref-work.json decodes into a usable CSLItem")
    func crossrefWorkDecodesToUsableCSLItem() throws {
        let data = try Self.fixtureData("crossref-work")
        let response = try JSONDecoder().decode(CrossrefWorkResponse.self, from: data)

        let item = response.message.asCSLItem()

        let title = try #require(item.title)
        #expect(!title.isEmpty)

        let firstAuthor = try #require(item.author.first)
        #expect((firstAuthor.family?.isEmpty ?? true) == false)

        #expect(item.year != nil)
        #expect((item.doi?.isEmpty ?? true) == false)
    }

    // MARK: - 2. Crossref search response (the important regression test)

    /// Crossref's `/works?query.bibliographic=...&select=...` route can send
    /// back `message` as either `{ items, total-results }` or, when a
    /// request is rejected (e.g. an invalid `select` field), a bare JSON
    /// array of error objects — and `CrossrefWorkListMessage` has custom
    /// decoding to tolerate both shapes rather than throwing. A previous bug
    /// where an app-side `select` parameter was invalid meant every real
    /// search silently decoded to content-less items and search results were
    /// always empty. This fixture is a real, valid search response, and
    /// exists specifically to prove `message.items` comes back non-empty and
    /// mappable to CSL, not just that decoding doesn't crash.
    @Test("crossref-search.json (real API response) decodes non-empty items")
    func crossrefSearchDecodesNonEmptyItems() throws {
        let data = try Self.fixtureData("crossref-search")
        let response = try JSONDecoder().decode(CrossrefWorkListResponse.self, from: data)

        let items = try #require(response.message.items)
        #expect(!items.isEmpty)

        let first = try #require(items.first)
        let cslItem = first.asCSLItem()
        let title = try #require(cslItem.title)
        #expect(!title.isEmpty)
    }

    // MARK: - 3. Crossref search response, object-form message

    /// A plain `query=` search (no `select`) returns `message` as an object
    /// with `items`/`total-results`, rather than the bare array Crossref
    /// sends for a rejected `select`-based request. Both shapes must decode
    /// through the same `CrossrefWorkListResponse` type.
    @Test("Hand-written object-form Crossref message decodes non-empty items")
    func crossrefSearchObjectFormDecodes() throws {
        let json = """
        {
            "message": {
                "items": [
                    {
                        "DOI": "10.1000/example.001",
                        "title": ["An Example Paper"],
                        "author": [{"given": "Ada", "family": "Lovelace"}],
                        "issued": {"date-parts": [[2021]]}
                    }
                ],
                "total-results": 5
            }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let response = try JSONDecoder().decode(CrossrefWorkListResponse.self, from: data)

        let items = try #require(response.message.items)
        #expect(!items.isEmpty)
        #expect(response.message.totalResults == 5)

        let cslItem = try #require(items.first).asCSLItem()
        #expect(cslItem.title == "An Example Paper")
    }

    // MARK: - 4. OpenAlex search response

    @Test("openalex-search.json decodes into usable CSLItems")
    func openAlexSearchDecodesToUsableCSLItems() throws {
        let data = try Self.fixtureData("openalex-search")
        let list = try JSONDecoder().decode(OpenAlexWorkList.self, from: data)

        let results = try #require(list.results)
        #expect(!results.isEmpty)

        let item = try #require(results.first).asCSLItem()
        let title = try #require(item.title)
        #expect(!title.isEmpty)
        #expect(item.year != nil)

        // OpenAlex sends a full "https://doi.org/10.xxxx/..." URL; asCSLItem()
        // must strip that prefix down to the bare DOI.
        let doi = try #require(item.doi)
        #expect(!doi.hasPrefix("https://doi.org/"))
        #expect(doi.hasPrefix("10."))
    }

    // MARK: - 5. CSL-JSON from doi.org content negotiation (arXiv DataCite DOI)

    @Test("csl-arxiv.json decodes directly as CSLItem")
    func cslArxivDecodesDirectly() throws {
        let data = try Self.fixtureData("csl-arxiv")
        let item = try JSONDecoder().decode(CSLItem.self, from: data)

        let title = try #require(item.title)
        #expect(!title.isEmpty)
        #expect(!item.author.isEmpty)
        #expect(item.year != nil)
    }

    // MARK: - 6. Lenient CSLItem decoding: numeric volume, array container-title

    /// Several upstream APIs send `volume` as a JSON number instead of the
    /// CSL-JSON-spec string, and Crossref sends `container-title` as an
    /// array. `CSLItem`'s custom `init(from:)` has to tolerate both without
    /// throwing; this locks that behavior in place.
    @Test("CSLItem tolerates a numeric volume and array container-title")
    func cslItemLenientDecoding() throws {
        let json = """
        {
            "id": "example2021",
            "type": "article-journal",
            "title": "Some Title",
            "volume": 12,
            "container-title": ["Journal One", "Journal One Alternate"]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(CSLItem.self, from: data)

        #expect(item.volume == "12")
        #expect(item.containerTitle == "Journal One")
    }

    // MARK: - 7. Round-trip: kebab-case keys survive encode/decode

    @Test("Encoding a CSLItem produces kebab-case CSL-JSON keys and round-trips")
    func cslItemRoundTripsThroughKebabCaseKeys() throws {
        var item = CSLItem(
            id: "zellers2018neural",
            type: .paperConference,
            title: "Neural Motifs",
            author: [CSLName(family: "Zellers", given: "Rowan")],
            issued: CSLDate(year: 2018)
        )
        item.containerTitle = "CVPR"
        item.doi = "10.1109/cvpr.2018.00611"

        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(item)
        let encodedString = try #require(String(data: encodedData, encoding: .utf8))

        #expect(encodedString.contains("\"container-title\""))
        #expect(encodedString.contains("\"DOI\""))

        let decoded = try JSONDecoder().decode(CSLItem.self, from: encodedData)
        #expect(decoded.containerTitle == "CVPR")
        #expect(decoded.doi == "10.1109/cvpr.2018.00611")
        #expect(decoded.title == "Neural Motifs")
        #expect(decoded.year == 2018)
    }
}

@Suite("Record sanitizing")
struct RecordSanitizerTests {
    @Test("Inline maths delimiters are removed from a title")
    func stripsInlineMath() {
        #expect(
            RecordSanitizer.clean("$\u{03C0}_0$: A Vision-Language-Action Flow Model")
                == "\u{03C0}0: A Vision-Language-Action Flow Model"
        )
    }

    @Test("A lone dollar sign is left alone")
    func keepsCurrency() {
        let title = "Predicting $100 Billion Markets"
        #expect(RecordSanitizer.clean(title) == title)
    }

    @Test("LaTeX accents in a registrar record become plain text")
    func unescapesAccents() {
        #expect(RecordSanitizer.clean("Almud{\\'e}var and Ortega") == "Almudévar and Ortega")
    }

    @Test("Case-protection braces do not survive into the display title")
    func stripsProtectionBraces() {
        #expect(RecordSanitizer.clean("A {BERT} Study") == "A BERT Study")
    }

    @Test("Titles wrapped across lines are collapsed")
    func collapsesWhitespace() {
        #expect(
            RecordSanitizer.clean("Neural Motifs:\n  Scene Graph\tParsing")
                == "Neural Motifs: Scene Graph Parsing"
        )
    }
}
