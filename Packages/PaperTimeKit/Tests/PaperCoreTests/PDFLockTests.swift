import Foundation
import PDFKit
import Testing
@testable import PaperCore

@Suite("PDF locks")
struct PDFLockTests {
    /// A one-page PDF with the given text drawn on it, and nothing else.
    func paper(saying text: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = bounds
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
        ))
        context.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test("A handler's name is only a name until the file cannot be read")
    func namedButReadable() {
        // A paper *about* rights management, with the handler's name in the
        // bytes where a search will find it — the worst case for the search,
        // since a real page's text is usually compressed out of reach. Every
        // word of it is readable, so it opens like any other paper.
        let data = paper(saying: "On rights management and what it protects")
            + Data("\n% MicrosoftIRMServices\n".utf8)
        let document = PDFDocument(data: data)
        #expect(document != nil)
        #expect(PDFLock.rightsHandler(in: data) == "MicrosoftIRMServices")
        #expect(PDFLock.of(document: document, data: data) == nil)
    }

    @Test("An ordinary paper is not locked")
    func ordinary() {
        let data = paper(saying: "An ordinary sentence")
        #expect(PDFLock.of(document: PDFDocument(data: data), data: data) == nil)
    }

    @Test("A file nothing could parse, with a handler in it, is that handler's")
    func unparseable() {
        let data = Data("%PDF-1.7 /Encrypt /Filter /Adobe.PubSec — and then nothing".utf8)
        #expect(PDFLock.of(document: PDFDocument(data: data), data: data) == .rights("Adobe.PubSec"))
    }

    @Test("Handlers are looked for in one order")
    func order() {
        #expect(PDFLock.knownHandlers.first == "MicrosoftIRMServices")
        #expect(PDFLock.rightsHandler(in: Data("nothing here".utf8)) == nil)
    }
}
