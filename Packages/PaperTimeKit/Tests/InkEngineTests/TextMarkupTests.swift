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

    /// A page of ordinary lines with one stretched by a tall glyph, which is
    /// the shape of a paper with inline mathematics in it.
    static func makeMathDocument() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        context.beginPDFPage(nil)
        let body = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let tall = CTFontCreateWithName("Helvetica" as CFString, 40, nil)

        for (offset, text) in [
            "first ordinary line of the paragraph",
            "second ordinary line of the paragraph",
            "third ordinary line of the paragraph",
            "fourth ordinary line of the paragraph",
        ].enumerated() {
            context.textPosition = CGPoint(x: 40, y: 700 - Double(offset) * 16)
            CTLineDraw(
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: body as Any])
                ),
                context
            )
        }

        let line = NSMutableAttributedString(
            string: "the encoder ", attributes: [.font: body as Any]
        )
        line.append(NSAttributedString(string: "(", attributes: [.font: tall as Any]))
        line.append(NSAttributedString(string: " and predictor are parameterized",
                                       attributes: [.font: body as Any]))
        context.textPosition = CGPoint(x: 40, y: 636)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage()
        context.closePDF()

        return try #require(PDFDocument(data: data as Data))
    }

    @Test("A line with a tall glyph is marked at the height of its text")
    func mathLineStaysTight() throws {
        let document = try Self.makeMathDocument()
        let page = try #require(document.page(at: 0))
        let selection = try #require(
            document.findString("and predictor", withOptions: []).first
        )
        let reported = selection.bounds(for: page)

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection, kind: .highlight, color: .yellow, in: document
            ).first
        )
        let marked = try #require(descriptor.rects.first)

        #expect(marked.height < reported.height)
        // Never outside the line it belongs to.
        #expect(marked.minY >= reported.minY)
        #expect(marked.maxY <= reported.maxY)
    }

    @Test("The baseline is found where the text was drawn")
    func baselineFromInk() throws {
        // Drawn with its baseline at exactly y = 700.
        let document = try Self.makeDocument(text: "handwriting sample")
        let page = try #require(document.page(at: 0))
        let line = try #require(
            document.findString("handwriting", withOptions: []).first?
                .selectionsByLine().first
        )
        let rect = line.bounds(for: page)
        let baseline = try #require(TextMarkupWriter.LineMetrics.baseline(of: rect, on: page))
        #expect(abs(baseline - 700) < 1.5)
    }

    @Test("A trimmed line stays on its own line")
    func trimmedLineStaysPut() throws {
        // Two lines, the first stretched by a tall glyph. Trimming used to
        // take its baseline from whatever characters fell inside the tall box,
        // which included the line below — and moved the mark down onto it.
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let body = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let tall = CTFontCreateWithName("Helvetica" as CFString, 34, nil)

        let first = NSMutableAttributedString(
            string: "upper line with ", attributes: [.font: body as Any]
        )
        first.append(NSAttributedString(string: "(", attributes: [.font: tall as Any]))
        first.append(NSAttributedString(string: " a tall glyph in it",
                                        attributes: [.font: body as Any]))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(first), context)

        context.textPosition = CGPoint(x: 40, y: 686)
        CTLineDraw(
            CTLineCreateWithAttributedString(
                NSAttributedString(string: "lower line of plain words",
                                   attributes: [.font: body as Any])
            ),
            context
        )
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        let upper = try #require(document.findString("tall glyph", withOptions: []).first)
        let lower = try #require(document.findString("plain words", withOptions: []).first)
        let lowerBounds = lower.bounds(for: page)

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: upper, kind: .highlight, color: .yellow, in: document
            ).first
        )
        let marked = try #require(descriptor.rects.first)

        // The mark belongs to the upper line: above the lower line's text.
        #expect(marked.minY > lowerBounds.midY)
    }

    @Test("An ordinary line is marked exactly where PDFKit says")
    func ordinaryLineIsUntouched() throws {
        let document = try Self.makeDocument(text: "plain words only here")
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("words only", withOptions: []).first)
        let line = try #require(selection.selectionsByLine().first)
        let reported = line.bounds(for: page)

        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection, kind: .highlight, color: .yellow, in: document
            ).first
        )
        let marked = try #require(descriptor.rects.first)
        #expect(abs(marked.height - reported.height) < 0.01)
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
