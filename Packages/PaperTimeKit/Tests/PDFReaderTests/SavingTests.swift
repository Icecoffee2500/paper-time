import CoreGraphics
import CoreText
import Foundation
import InkEngine
import PDFKit
import Testing
@testable import PDFReader

/// Saving happens off the main actor, starting from the file rather than from
/// the open document. These are the two things that has to keep true.
@Suite("Saving marks")
struct SavingTests {
    static func makeDocument(text: String) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font as Any])
        )
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-save-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @Test("A mark handed to the writer ends up in the file")
    func writesMarks() async throws {
        let url = try Self.write(try Self.makeDocument(text: "one two three"))
        defer { try? FileManager.default.removeItem(at: url) }

        let descriptor = MarkupDescriptor(
            kind: .highlight,
            pageIndex: 0,
            rects: [CGRect(x: 40, y: 695, width: 60, height: 14)],
            color: .green,
            quotedText: "one"
        )
        let result = DocumentSession.write(
            to: url, additions: [descriptor], removals: [], ink: [:]
        )
        #expect(throws: Never.self) { try result.get() }

        let saved = try #require(PDFDocument(url: url))
        let page = try #require(saved.page(at: 0))
        #expect(page.annotations.contains { $0.type == "Highlight" })
    }

    @Test("A mark made elsewhere survives our save")
    func mergesForeignMarks() async throws {
        let url = try Self.write(try Self.makeDocument(text: "alpha beta gamma"))
        defer { try? FileManager.default.removeItem(at: url) }

        // Somebody else — another device, or Preview — marks the file.
        let theirs = try #require(PDFDocument(url: url))
        let theirPage = try #require(theirs.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 40, y: 695, width: 40, height: 14),
            forType: .underline,
            withProperties: nil
        )
        theirPage.addAnnotation(annotation)
        try #require(theirs.dataRepresentation()).write(to: url)

        // We save a highlight of our own, knowing nothing about theirs.
        let mine = MarkupDescriptor(
            kind: .highlight,
            pageIndex: 0,
            rects: [CGRect(x: 100, y: 695, width: 50, height: 14)],
            color: .pink,
            quotedText: "beta"
        )
        _ = DocumentSession.write(to: url, additions: [mine], removals: [], ink: [:])

        let saved = try #require(PDFDocument(url: url))
        let page = try #require(saved.page(at: 0))
        #expect(page.annotations.contains { $0.type == "Underline" })
        #expect(page.annotations.contains { $0.type == "Highlight" })
    }

    @Test("A removal takes the mark out of the file")
    func removesMarks() async throws {
        let url = try Self.write(try Self.makeDocument(text: "remove me please"))
        defer { try? FileManager.default.removeItem(at: url) }

        let descriptor = MarkupDescriptor(
            kind: .highlight,
            pageIndex: 0,
            rects: [CGRect(x: 40, y: 695, width: 60, height: 14)],
            color: .yellow,
            quotedText: "remove"
        )
        _ = DocumentSession.write(to: url, additions: [descriptor], removals: [], ink: [:])
        _ = DocumentSession.write(to: url, additions: [], removals: [descriptor.id], ink: [:])

        let saved = try #require(PDFDocument(url: url))
        let page = try #require(saved.page(at: 0))
        #expect(!page.annotations.contains { $0.type == "Highlight" })
    }
}
