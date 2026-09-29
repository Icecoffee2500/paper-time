import Foundation
import Testing
@testable import PaperCore

/// `Fixtures/note-math.json` is what this code answers
/// (`Scripts/note-math-fixture.swift`); the Portable build's tests read the
/// same file. A change to `NoteMath` that is not written back here fails.
@Suite struct NoteMathFixtureTests {
    struct Span: Decodable, Equatable { var from: Int; var to: Int; var latex: String; var display: Bool; var isBlock: Bool }
    struct Line: Decodable { var from: Int; var to: Int; var formulas: [Span]; var displays: [[Int]]; var isDisplay: Bool }
    struct Note: Decodable { var text: String; var blocks: [[Int]]; var lines: [Line]; var spans: [Span?] }
    struct File: Decodable { var notes: [Note] }

    func fixture() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "note-math", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    private func span(_ one: NoteMath.Span?) -> Span? {
        one.map { Span(from: $0.range.location, to: $0.range.location + $0.range.length,
                       latex: $0.latex, display: $0.display, isBlock: $0.isBlock) }
    }

    @Test func notesReadAsTheFileSays() throws {
        for note in try fixture().notes {
            let whole = note.text as NSString
            #expect(NoteMath.blocks(in: note.text).map { [$0.location, $0.location + $0.length] } == note.blocks)
            for line in note.lines {
                let text = whole.substring(with: NSRange(location: line.from, length: line.to - line.from)) as NSString
                var found: [Span] = []
                var index = 0
                while index < text.length,
                      let one = NoteMath.firstFormula(in: text, range: NSRange(location: index, length: text.length - index)) {
                    found.append(span(one)!)
                    index = one.range.location + max(one.range.length, 1)
                }
                #expect(found == line.formulas, "\(note.text)")
                #expect(NoteMath.displays(in: text as String).map { [$0.location, $0.location + $0.length] } == line.displays)
                #expect(NoteMath.isDisplay(text as String) == line.isDisplay)
            }
            for (caret, expected) in note.spans.enumerated() {
                #expect(span(NoteMath.span(at: caret, in: note.text)) == expected, "\(note.text) at \(caret)")
            }
        }
    }
}
