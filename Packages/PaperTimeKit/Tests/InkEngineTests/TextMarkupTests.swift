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

    @Test("A mark already in the file is not written into it again")
    func writtenMarksAreLeftAlone() throws {
        let document = try Self.makeDocument(text: "handwriting sample")
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("handwriting", withOptions: []).first)
        let descriptor = try #require(
            TextMarkupWriter.descriptor(
                for: selection, kind: .highlight, color: .yellow, in: document
            ).first
        )

        #expect(!TextMarkupWriter.isAlreadyWritten(descriptor, on: page))
        TextMarkupWriter.apply(descriptor, to: page)
        #expect(TextMarkupWriter.isAlreadyWritten(descriptor, on: page))

        // What the reader can change about a mark it has already made.
        var recoloured = descriptor
        recoloured.color = .green
        #expect(!TextMarkupWriter.isAlreadyWritten(recoloured, on: page))
        var commented = descriptor
        commented.comment = "worth coming back to"
        #expect(!TextMarkupWriter.isAlreadyWritten(commented, on: page))
        var moved = descriptor
        moved.rects = descriptor.rects.map { $0.offsetBy(dx: 0, dy: 4) }
        #expect(!TextMarkupWriter.isAlreadyWritten(moved, on: page))

        // And it survives the trip through a file, where the numbers are kept
        // to fewer decimals than Swift holds them in.
        let written = try #require(document.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: written))
        let reloadedPage = try #require(reloaded.page(at: 0))
        #expect(TextMarkupWriter.isAlreadyWritten(descriptor, on: reloadedPage))
    }

    @Test("A note with words on it is already written once it is in the file")
    func writtenNotesAreLeftAlone() throws {
        let document = try Self.makeDocument(text: "handwriting sample")
        let page = try #require(document.page(at: 0))
        let note = MarkupDescriptor(
            kind: .note, pageIndex: 0, rects: [CGRect(x: 72, y: 700, width: 80, height: 14)],
            color: .blue, comment: "메모 — look again"
        )
        #expect(!TextMarkupWriter.isAlreadyWritten(note, on: page))
        TextMarkupWriter.apply(note, to: page)
        #expect(TextMarkupWriter.isAlreadyWritten(note, on: page))
        var reworded = note
        reworded.comment = "something else"
        #expect(!TextMarkupWriter.isAlreadyWritten(reworded, on: page))

        let written = try #require(document.dataRepresentation())
        let reloadedPage = try #require(PDFDocument(data: written)?.page(at: 0))
        #expect(TextMarkupWriter.isAlreadyWritten(note, on: reloadedPage))
        // What the list shows is still the note's words.
        let back = TextMarkupWriter.descriptors(in: try #require(PDFDocument(data: written)))
        #expect(back.first { $0.id == note.id }?.comment == note.comment)
    }

    @Test("A rectangle with nan in it is not finite, whatever isEmpty says")
    func nanRectangleIsCaught() {
        let bad = CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 316, height: 34)
        #expect(!bad.isEmpty)      // the trap: every comparison with nan is false
        #expect(!bad.isNull)
        #expect(!bad.isFinite)
        #expect(!CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1).isFinite)
        #expect(CGRect(x: 1, y: 2, width: 3, height: 4).isFinite)
        #expect(CGRect.zero.isFinite)
    }

    @Test("The ink is found where the text was drawn")
    func inkExtentFromRendering() throws {
        // Drawn with its baseline at exactly y = 700, 18 point Helvetica, so
        // the ink runs from roughly the baseline to about 13 points above it.
        let document = try Self.makeDocument(text: "handwriting sample")
        let page = try #require(document.page(at: 0))
        let line = try #require(
            document.findString("handwriting", withOptions: []).first?
                .selectionsByLine().first
        )
        let rect = line.bounds(for: page)
        let ink = try #require(TextMarkupWriter.LineMetrics.inkExtent(of: rect, on: page))

        // The descender of "g" reaches a little below the baseline.
        #expect(ink.minY < 700)
        #expect(ink.minY > 690)
        #expect(ink.minY + ink.height > 708)
        #expect(ink.height < rect.height)
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
            string: "upper ", attributes: [.font: body as Any]
        )
        first.append(NSAttributedString(string: "(", attributes: [.font: tall as Any]))
        first.append(NSAttributedString(string: " tall", attributes: [.font: body as Any]))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(first), context)

        // Deliberately longer, so it carries more ink than the line above it:
        // choosing the densest band rather than the nearest one put the mark
        // down here instead.
        context.textPosition = CGPoint(x: 40, y: 686)
        CTLineDraw(
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "lower line of plain words running much further across the page",
                    attributes: [.font: body as Any]
                )
            ),
            context
        )
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(data: data as Data))
        let page = try #require(document.page(at: 0))
        let upper = try #require(document.findString("upper", withOptions: []).first)
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

/// Markups the file already carried when it arrived.
///
/// A paper that has been read in Preview, Zotero or on an iPad comes with
/// highlights and underlines of its own. They are ordinary PDF annotations and
/// nothing in the file forbids changing them — but they carry no identifier of
/// this app's, and for a while that meant the reader could find them and then
/// do nothing at all with them.
@Suite("Markups made elsewhere")
struct ForeignMarkupTests {
    /// A page with a highlight put there by something other than this app: no
    /// `/PTMarkupID`, and its lines given as quadrilaterals.
    static func makeDocument(quads: [CGPoint]? = nil) throws -> PDFDocument {
        let document = try TextMarkupTests.makeDocument(text: "the quick brown fox")
        let page = try #require(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 40, y: 690, width: 200, height: 40),
            forType: .highlight,
            withProperties: nil
        )
        annotation.color = .yellow
        if let quads {
            annotation.quadrilateralPoints = quads.map { NSValue(point: $0) }
        }
        page.addAnnotation(annotation)
        return document
    }

    @Test("A markup made elsewhere is listed with an identifier of its own")
    func foreignMarkupIsIdentified() throws {
        let document = try Self.makeDocument()
        let found = TextMarkupWriter.descriptors(in: document)
        #expect(found.count == 1)
        #expect(found.first?.kind == .highlight)
    }

    @Test("Its identifier is the same every time the file is read")
    func identifierIsStable() throws {
        let document = try Self.makeDocument()
        let first = TextMarkupWriter.descriptors(in: document).first?.id
        let second = TextMarkupWriter.descriptors(in: document).first?.id
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("It can be removed, which is what it could not be before")
    func foreignMarkupCanBeRemoved() throws {
        let document = try Self.makeDocument()
        let page = try #require(document.page(at: 0))
        let id = try #require(TextMarkupWriter.descriptors(in: document).first?.id)

        TextMarkupWriter.remove(id: id, from: page)

        #expect(page.annotations.filter { $0.type == "Highlight" }.isEmpty)
        #expect(TextMarkupWriter.descriptors(in: document).isEmpty)
    }

    @Test("Removing one and putting it back is what undo has to do")
    func removalCanBeUndone() throws {
        let document = try Self.makeDocument(quads: [
            CGPoint(x: 0, y: 40), CGPoint(x: 200, y: 40),
            CGPoint(x: 0, y: 20), CGPoint(x: 200, y: 20),
            CGPoint(x: 0, y: 18), CGPoint(x: 90, y: 18),
            CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0),
        ])
        let page = try #require(document.page(at: 0))
        let before = try #require(TextMarkupWriter.descriptors(in: document).first)

        TextMarkupWriter.remove(id: before.id, from: page)
        #expect(TextMarkupWriter.descriptors(in: document).isEmpty)

        // What undoing a removal does: put the descriptor back on the page.
        _ = TextMarkupWriter.apply(before, to: page)
        let after = try #require(TextMarkupWriter.descriptors(in: document).first)

        #expect(after.id == before.id)
        #expect(after.kind == before.kind)
        #expect(after.rects.count == before.rects.count)
        // And it can be taken off again, which is what redo does.
        TextMarkupWriter.remove(id: after.id, from: page)
        #expect(TextMarkupWriter.descriptors(in: document).isEmpty)
    }

    @Test("Taking one into the app's care leaves the identifier unchanged")
    func adoptionKeepsTheIdentifier() throws {
        let document = try Self.makeDocument()
        let page = try #require(document.page(at: 0))
        let annotation = try #require(page.annotations.first)
        let before = try #require(TextMarkupWriter.identifier(of: annotation))

        let adopted = TextMarkupWriter.adopt(annotation)

        #expect(adopted == before)
        #expect(annotation.value(forAnnotationKey: TextMarkupWriter.idKey) as? String
            == before.uuidString)
        #expect(TextMarkupWriter.identifier(of: annotation) == before)
    }

    @Test("Its lines are read back from the quadrilaterals, not the box round them")
    func linesComeFromTheQuadrilaterals() throws {
        // Two lines, with the second one shorter — the box around them takes
        // in a corner that was never marked.
        let document = try Self.makeDocument(quads: [
            CGPoint(x: 0, y: 40), CGPoint(x: 200, y: 40),
            CGPoint(x: 0, y: 20), CGPoint(x: 200, y: 20),
            CGPoint(x: 0, y: 18), CGPoint(x: 90, y: 18),
            CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0),
        ])
        let descriptor = try #require(TextMarkupWriter.descriptors(in: document).first)

        #expect(descriptor.rects.count == 2)
        #expect(descriptor.rects.first?.width == 200)
        #expect(descriptor.rects.last?.width == 90)
        // On the page, not in the annotation's own corner.
        #expect(descriptor.rects.first?.minX == 40)
    }

    @Test("A markup this app wrote keeps the identifier it was given")
    func ownMarkupKeepsItsIdentifier() throws {
        let document = try TextMarkupTests.makeDocument(text: "the quick brown fox")
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("quick", withOptions: []).first)
        let descriptor = try #require(TextMarkupWriter.descriptor(
            for: selection, kind: .highlight, color: .yellow, in: document
        ).first)
        _ = TextMarkupWriter.apply(descriptor, to: page)

        let found = try #require(TextMarkupWriter.descriptors(in: document).first)
        #expect(found.id == descriptor.id)
    }
}
