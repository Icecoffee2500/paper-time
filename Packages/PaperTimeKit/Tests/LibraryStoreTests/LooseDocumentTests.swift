import CoreGraphics
import Foundation
import Testing
@testable import LibraryStore

/// Choosing a folder that already contains PDFs must produce a library holding
/// those PDFs, not an empty one. The first version made the folder a library
/// root and left its documents sitting outside it.
@Suite("Loose documents")
struct LooseDocumentTests {
    static func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A one-page PDF, so `PDFDocument` can read a page count from it.
    static func writePDF(named name: String, in folder: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: folder.appending(path: name))
    }

    @Test("PDFs already in the chosen folder are reported as loose")
    func findsLooseDocuments() async throws {
        let root = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writePDF(named: "first.pdf", in: root)
        try Self.writePDF(named: "second.pdf", in: root)

        let store = LibraryStore(root: root)
        try await store.bootstrap()

        let loose = await store.looseDocumentURLs()
        #expect(loose.count == 2)
        #expect(loose.map(\.lastPathComponent) == ["first.pdf", "second.pdf"])
    }

    @Test("A PDF that already has a record is no longer offered")
    func searchesSubfoldersOnly() async throws {
        let root = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appending(path: "2024", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.writePDF(named: "nested.pdf", in: nested)
        try Self.writePDF(named: "top.pdf", in: root)

        let store = LibraryStore(root: root)
        try await store.bootstrap()

        // A document already imported lives under papers/ and must not be
        // offered again.
        let outcome = try await store.importDocument(at: root.appending(path: "top.pdf"))
        guard case .imported = outcome else {
            Issue.record("expected the document to import")
            return
        }

        let loose = await store.looseDocumentURLs()
        #expect(loose.map(\.lastPathComponent) == ["nested.pdf"])
    }

    @Test("Adopting a document already in the library leaves the file where it is")
    func adoptingLeavesTheFileAlone() async throws {
        let root = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writePDF(named: "paper.pdf", in: root)
        let original = root.appending(path: "paper.pdf")

        let store = LibraryStore(root: root)
        try await store.bootstrap()
        let outcome = try await store.importDocument(at: original)

        guard case let .imported(paper) = outcome else {
            Issue.record("expected the document to import")
            return
        }
        // The point of the flat layout: the PDF is not filed away anywhere.
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(paper.documentURL.lastPathComponent == "paper.pdf")
        #expect(paper.meta.file.pageCount == 1)

        let loose = await store.looseDocumentURLs()
        #expect(loose.isEmpty)
    }

    @Test("A copied import leaves the original where it was")
    func copyingKeepsTheOriginal() async throws {
        let root = try Self.makeTemporaryFolder()
        let outside = try Self.makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try Self.writePDF(named: "external.pdf", in: outside)
        let source = outside.appending(path: "external.pdf")

        let store = LibraryStore(root: root)
        try await store.bootstrap()
        let outcome = try await store.importDocument(at: source)

        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        // Copied in under its own name, at the top of the library.
        guard case let .imported(paper) = outcome else {
            Issue.record("expected the document to import")
            return
        }
        #expect(paper.documentURL == root.appending(path: "external.pdf"))
    }
}
