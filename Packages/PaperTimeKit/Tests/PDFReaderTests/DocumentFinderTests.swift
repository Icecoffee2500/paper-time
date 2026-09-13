import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import PDFReader

/// Pressing Return steps to the next match and must stay there.
///
/// SwiftUI re-commits a text field's value when it is submitted, so the find
/// bar set the same query again on every Return. That started another search,
/// which finished a quarter of a second later and reset the index — the
/// counter walked forward and then snapped back to 1 while the user sat still.
@MainActor
@Suite("Document finder")
struct DocumentFinderTests {
    /// A one-page PDF containing the given words, so `findString` has
    /// something real to match.
    static func makeDocument(text: String) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font as Any]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        return try #require(PDFDocument(data: data as Data))
    }

    @Test("Searching the same text again does not restart at the first match")
    func repeatedSearchKeepsPosition() async throws {
        let document = try Self.makeDocument(text: "alpha beta alpha gamma alpha")
        let finder = DocumentFinder()

        await finder.search("alpha", in: document)
        #expect(finder.matchCount == 3)
        #expect(finder.currentIndex == 0)

        finder.next()
        #expect(finder.currentIndex == 1)

        // What the text field does on submit: hand back the identical string.
        await finder.search("alpha", in: document)
        #expect(finder.currentIndex == 1)
        #expect(finder.summary == "2 of 3")
    }

    @Test("A genuinely new query starts from the first match again")
    func newQueryResets() async throws {
        let document = try Self.makeDocument(text: "alpha beta alpha gamma")
        let finder = DocumentFinder()

        await finder.search("alpha", in: document)
        finder.next()
        #expect(finder.currentIndex == 1)

        await finder.search("beta", in: document)
        #expect(finder.currentIndex == 0)
        #expect(finder.matchCount == 1)
    }

    @Test("Stepping past the last match wraps to the first")
    func navigationWraps() async throws {
        let document = try Self.makeDocument(text: "alpha beta alpha")
        let finder = DocumentFinder()

        await finder.search("alpha", in: document)
        #expect(finder.matchCount == 2)
        finder.next()
        finder.next()
        #expect(finder.currentIndex == 0)
        finder.previous()
        #expect(finder.currentIndex == 1)
    }

    @Test("Clearing the query drops the matches and the remembered search")
    func clearing() async throws {
        let document = try Self.makeDocument(text: "alpha beta alpha")
        let finder = DocumentFinder()

        await finder.search("alpha", in: document)
        #expect(finder.matchCount == 2)

        await finder.search("", in: document)
        #expect(finder.matchCount == 0)
        #expect(finder.summary.isEmpty)

        // The remembered query must be forgotten too, or searching the same
        // word again would be treated as a repeat and find nothing.
        await finder.search("alpha", in: document)
        #expect(finder.matchCount == 2)
    }

    @Test("Navigation is a no-op when nothing matched")
    func noMatches() async throws {
        let document = try Self.makeDocument(text: "alpha beta")
        let finder = DocumentFinder()

        await finder.search("nothinghere", in: document)
        #expect(finder.matchCount == 0)
        #expect(finder.summary == "No results")
        finder.next()
        #expect(finder.currentIndex == 0)
        #expect(finder.currentSelection == nil)
    }
}
