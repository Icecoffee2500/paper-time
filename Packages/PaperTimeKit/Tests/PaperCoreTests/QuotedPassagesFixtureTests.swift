import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/quoted-passages.json` is what this code answers
/// (`Scripts/quoted-passages-fixture.swift`); the Portable build's tests read
/// the same file. A change to `QuotedPassages` that is not written back here
/// fails.
@Suite struct QuotedPassagesFixtureTests {
    struct Passage: Decodable { var url: String; var page: Int; var rect: [Double]; var paper: String?; var link: [Int]; var quote: [Int] }
    struct Body: Decodable { var body: String; var passages: [Passage] }
    struct Note: Decodable { var paper: String?; var body: String }
    struct Paper: Decodable { var paper: String; var passages: [[Entry]] }
    enum Entry: Decodable {
        case index(Int), url(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let index = try? value.decode(Int.self) { self = .index(index) } else { self = .url(try value.decode(String.self)) }
        }
    }
    struct Span: Decodable { var quotation: String; var text: String; var span: [Int]? }
    struct File: Decodable { var bodies: [Body]; var notes: [Note]; var papers: [Paper]; var spans: [Span] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "quoted-passages", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    func span(_ range: NSRange) -> [Int] { [range.location, NSMaxRange(range)] }

    @Test func bodiesReadAsTheFileSays() throws {
        for body in try fixture().bodies {
            let found = QuotedPassages.passages(in: body.body)
            #expect(found.count == body.passages.count, "\(body.body.debugDescription)")
            for (passage, expected) in zip(found, body.passages) {
                #expect(passage.url == expected.url)
                #expect(passage.anchor.pageIndex == expected.page)
                let rect = passage.anchor.rect
                #expect([rect.minX, rect.minY, rect.width, rect.height] == expected.rect.map { CGFloat($0) })
                #expect(passage.anchor.paperID?.uuidString == expected.paper)
                #expect(span(passage.link) == expected.link)
                #expect(span(passage.quote) == expected.quote)
            }
        }
    }

    @Test func aPaperGetsWhatTheFileSays() throws {
        let file = try fixture()
        let notes = file.notes.enumerated().map { index, note in
            Zettel(id: "n\(index)", title: "", body: note.body, paperID: note.paper.flatMap(UUID.init(uuidString:)))
        }
        for paper in file.papers {
            let id = try #require(UUID(uuidString: paper.paper))
            var found: [String] = []
            for (index, note) in notes.enumerated() {
                for passage in QuotedPassages.passages(in: note, of: id) { found.append("\(index) \(passage.url)") }
            }
            let expected = paper.passages.map { entry -> String in
                entry.map { part -> String in
                    switch part { case .index(let index): String(index); case .url(let url): url }
                }.joined(separator: " ")
            }
            #expect(found == expected, "\(paper.paper)")
        }
    }

    @Test func quotationsAreFoundWhereTheFileSays() throws {
        for item in try fixture().spans {
            let span = QuotedPassages.span(of: item.quotation, in: item.text)
            #expect(span.map { [$0.lowerBound, $0.upperBound] } == item.span, "\(item.quotation.debugDescription)")
        }
    }

    /// What the page tints is the passage, and nothing round it: not the
    /// start of a line a quotation began in the middle of, not a slide's
    /// line a quotation took only the end of.
    @Test func theSpanIsThePassage() {
        func words(_ quotation: String, _ text: String) -> String? {
            QuotedPassages.span(of: quotation, in: text).map {
                (text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count))
            }
        }
        #expect(words("> per class [3쪽](papertime://anchor?p=2&x=1&y=1&w=1&h=1)", "few-shot samples per class to create")
            == "per class")
        #expect(words("> (naïve method $O(n)$)", "Sample data: O(ln(n)) (na\u{A8} \u{131}ve method O(n))") == "(na\u{A8} \u{131}ve method O(n))")
        #expect(words("> We minimize $\\mathcal{L}(\\theta)$ over the data.", "Then we minimize L(θ) over the data. Next")
            == "we minimize L(θ) over the data.")
        #expect(words("> $$\\frac{a}{b}$$", "completely different words") == nil)
        #expect(words("> the model is good", "the model the model is good") == "the model is good")
    }

    /// The quotation is the block the link closes, and a passage in a
    /// sentence is its own line.
    @Test func theQuotationIsTheBlockTheLinkCloses() {
        let body = "Thoughts.\n> a\n> b [p. 1](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)\nAfter."
        let found = QuotedPassages.passages(in: body)
        #expect(found.count == 1)
        #expect((body as NSString).substring(with: found[0].quote) == "> a\n> b [p. 1](papertime://anchor?p=0&x=1.00&y=1.00&w=1.00&h=1.00)")
    }
}
