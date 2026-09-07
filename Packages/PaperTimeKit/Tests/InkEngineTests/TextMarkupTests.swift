import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import InkEngine

/// Highlighting selected text has to put a real annotation into the real page.
@Suite("Text markup")
struct TextMarkupTests {
    /// A one-page PDF with actual text, so a `PDFSelection` can be obtained the
    /// same way the reader obtains one.
    static func makeDocument(text: String) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font as Any])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        return try #require(PDFDocument(data: data as Data))
    }

    @Test("A highlight over a selection lands in the page as an annotation")
    func highlightIsWritten() throws {
        let document = try Self.makeDocument(text: "the quick brown fox")
        let selection = try #require(document.findString("quick", withOptions: []).first)

        let descriptors = TextMarkupWriter.descriptor(
            for: selection,
            kind: .highlight,
            color: .yellow,
            in: document
        )
        #expect(descriptors.count == 1)
        let descriptor = try #require(descriptors.first)
        #expect(descriptor.pageIndex == 0)
        #expect(!descriptor.rects.isEmpty)
        #expect(descriptor.quotedText.contains("quick"))

        let page = try #require(document.page(at: 0))
        let created = TextMarkupWriter.apply(descriptor, to: page)
        #expect(!created.isEmpty)
        #expect(page.annotations.contains { $0.type == "Highlight" })
    }

    @Test("Underline and strikethrough produce their own annotation subtypes")
    func otherKinds() throws {
        let document = try Self.makeDocument(text: "alpha beta gamma")
        let page = try #require(document.page(at: 0))

        for (kind, expected) in [
            (MarkupDescriptor.Kind.underline, "Underline"),
            (MarkupDescriptor.Kind.strikethrough, "StrikeOut"),
        ] {
            let selection = try #require(document.findString("beta", withOptions: []).first)
            let descriptor = try #require(
                TextMarkupWriter.descriptor(
                    for: selection,
                    kind: kind,
                    color: .green,
                    in: document
                ).first
            )
            TextMarkupWriter.apply(descriptor, to: page)
            #expect(page.annotations.contains { $0.type == expected })
        }
    }

    @Test("A markup survives writing the document out and reading it back")
    func survivesRoundTrip() throws {
        let document = try Self.makeDocument(text: "persistent markup here")
        let selection = try #require(document.findString("markup", withOptions: []).first)
        let page = try #require(document.page(at: 0))

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection,
                kind: .highlight,
                color: .pink,
                in: document
            ).first
        )
        TextMarkupWriter.apply(descriptor, to: page)

        let saved = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: saved))
        let reloadedPage = try #require(reloaded.page(at: 0))
        #expect(reloadedPage.annotations.contains { $0.type == "Highlight" })

        // And it must come back as a descriptor, which is what the notes list
        // and the "remove" action work from.
        let readBack = TextMarkupWriter.descriptors(in: reloaded)
        #expect(readBack.contains { $0.kind == .highlight })
    }

    @Test("A note keeps the user's words apart from the quoted text")
    func commentsRoundTrip() throws {
        let document = try Self.makeDocument(text: "the crucial claim here")
        let selection = try #require(document.findString("crucial claim", withOptions: []).first)
        let page = try #require(document.page(at: 0))

        var descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection,
                kind: .highlight,
                color: .yellow,
                in: document
            ).first
        )
        descriptor.comment = "Check this against Table 2"
        TextMarkupWriter.apply(descriptor, to: page)

        let saved = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: saved))
        let readBack = try #require(TextMarkupWriter.descriptors(in: reloaded).first)
        #expect(readBack.comment == "Check this against Table 2")
        #expect(readBack.quotedText.contains("crucial"))
    }

    @Test("A plain highlight has no comment, whatever it stores in contents")
    func plainHighlightHasNoComment() throws {
        let document = try Self.makeDocument(text: "ordinary sentence here")
        let selection = try #require(document.findString("ordinary", withOptions: []).first)
        let page = try #require(document.page(at: 0))

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection,
                kind: .highlight,
                color: .yellow,
                in: document
            ).first
        )
        TextMarkupWriter.apply(descriptor, to: page)

        let saved = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: saved))
        let readBack = try #require(TextMarkupWriter.descriptors(in: reloaded).first)
        #expect(readBack.comment.isEmpty)
    }

    @Test("Removing a markup takes it out of the page")
    func removal() throws {
        let document = try Self.makeDocument(text: "remove this word")
        let selection = try #require(document.findString("this", withOptions: []).first)
        let page = try #require(document.page(at: 0))

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection,
                kind: .highlight,
                color: .blue,
                in: document
            ).first
        )
        TextMarkupWriter.apply(descriptor, to: page)
        #expect(page.annotations.contains { $0.type == "Highlight" })

        TextMarkupWriter.remove(id: descriptor.id, from: page)
        #expect(!page.annotations.contains { $0.type == "Highlight" })
    }
}
