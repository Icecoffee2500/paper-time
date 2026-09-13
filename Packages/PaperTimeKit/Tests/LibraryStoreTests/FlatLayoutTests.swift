import CoreGraphics
import Foundation
import PaperCore
import Testing
@testable import LibraryStore

/// The library folder should look like a folder of PDFs, because that is what
/// it is. Everything the app adds lives in one hidden directory beside them.
@Suite("Flat layout")
struct FlatLayoutTests {
    static func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "papertime-flat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    @Test("An imported PDF keeps its own name at the top of the library")
    func keepsOriginalName() async throws {
        let root = try Self.makeRoot()
        let outside = try Self.makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try Self.writePDF(named: "OpenVLA; An Open-Source Model.pdf", in: outside)
        let store = LibraryStore(root: root)
        try await store.bootstrap()

        let outcome = try await store.importDocument(
            at: outside.appending(path: "OpenVLA; An Open-Source Model.pdf")
        )
        guard case let .imported(paper) = outcome else {
            Issue.record("expected an import")
            return
        }
        #expect(paper.documentURL.lastPathComponent == "OpenVLA; An Open-Source Model.pdf")
        #expect(paper.meta.file.relativePath == "OpenVLA; An Open-Source Model.pdf")

        // Nothing but the PDF and the hidden folder at the top level.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains("OpenVLA; An Open-Source Model.pdf"))
        #expect(names.contains(".papertime"))
        #expect(!names.contains("papers"))
    }

    @Test("Two PDFs with the same name both survive, Finder-style")
    func namesCollide() async throws {
        let root = try Self.makeRoot()
        let outside = try Self.makeRoot()
        let other = try Self.makeRoot()
        defer {
            for url in [root, outside, other] { try? FileManager.default.removeItem(at: url) }
        }

        try Self.writePDF(named: "paper.pdf", in: outside)
        // Different bytes, same name, so it is not treated as a duplicate.
        try Self.writePDF(named: "paper.pdf", in: other)
        try Data("difference".utf8).write(
            to: other.appending(path: "marker.txt")
        )

        let store = LibraryStore(root: root)
        try await store.bootstrap()
        _ = try await store.importDocument(at: outside.appending(path: "paper.pdf"))

        // Force different content for the second file.
        let secondSource = other.appending(path: "paper.pdf")
        var bytes = try Data(contentsOf: secondSource)
        bytes.append(contentsOf: [0x0A])
        try bytes.write(to: secondSource)

        let outcome = try await store.importDocument(at: secondSource)
        guard case let .imported(second) = outcome else {
            Issue.record("expected a second import")
            return
        }
        #expect(second.documentURL.lastPathComponent == "paper 2.pdf")
    }

    @Test("A record finds its PDF again after the file is renamed outside the app")
    func recoversAfterRename() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writePDF(named: "before.pdf", in: root)
        let store = LibraryStore(root: root)
        try await store.bootstrap()
        _ = try await store.importDocument(at: root.appending(path: "before.pdf"))

        try FileManager.default.moveItem(
            at: root.appending(path: "before.pdf"),
            to: root.appending(path: "after.pdf")
        )

        let loaded = try await store.loadAll()
        #expect(loaded.papers.count == 1)
        let paper = try #require(loaded.papers.first)
        #expect(paper.documentURL.lastPathComponent == "after.pdf")
        #expect(paper.meta.file.relativePath == "after.pdf")
    }

    @Test("A library in the old folder-per-paper shape is migrated on open")
    func migratesOldLayout() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Build the shape the first version wrote.
        let id = UUID()
        let old = root.appending(
            path: "papers/4F3A1C08-attention", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Self.writePDF(named: "attention.pdf", in: old)

        var meta = PaperMeta(id: id)
        meta.csl.title = "Attention Is All You Need"
        meta.file = PaperMeta.FileInfo(
            relativePath: "attention.pdf",
            originalName: "Attention Is All You Need.pdf"
        )
        try FileOperations.encodeAndWrite(meta, to: old.appending(path: "meta.json"))
        try FileOperations.encodeAndWrite(PaperState(), to: old.appending(path: "state.json"))
        try FileOperations.encodeAndWrite(
            LibraryManifest(), to: root.appending(path: "library.json")
        )

        let store = LibraryStore(root: root)
        try await store.bootstrap()

        // The PDF has come up to the top under the name it was imported with.
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Attention Is All You Need.pdf")
                    .path(percentEncoded: false)
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "papers").path(percentEncoded: false)
            )
        )

        let loaded = try await store.loadAll()
        #expect(loaded.papers.count == 1)
        let paper = try #require(loaded.papers.first)
        #expect(paper.meta.csl.title == "Attention Is All You Need")
        #expect(paper.documentURL.lastPathComponent == "Attention Is All You Need.pdf")
    }

    @Test("Trashing a paper moves the PDF aside rather than deleting it")
    func trashing() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writePDF(named: "unwanted.pdf", in: root)
        let store = LibraryStore(root: root)
        try await store.bootstrap()
        let outcome = try await store.importDocument(at: root.appending(path: "unwanted.pdf"))
        guard case let .imported(paper) = outcome else {
            Issue.record("expected an import")
            return
        }

        let moved = try await store.moveToTrash(paper)
        #expect(FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))
        #expect(moved.path(percentEncoded: false).contains("/Trash/"))
        #expect(try await store.loadAll().papers.isEmpty)
    }
}

/// Collections are the user's own filing. They live in the library folder, so
/// reinstalling the app cannot lose them — and neither can upgrading it.
@Suite("Collections survive a layout change")
struct CollectionMigrationTests {
    @Test("A collection written at the top level is adopted, papers or not")
    func adoptsTopLevelCollections() async throws {
        let root = try FlatLayoutTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var set = CollectionSet()
        set.collections = [Collection(name: "비전", sortIndex: 0)]
        try FileOperations.encodeAndWrite(set, to: root.appending(path: "collections.json"))
        try FileOperations.encodeAndWrite(
            LibraryManifest(displayName: "vla"), to: root.appending(path: "library.json")
        )

        let store = LibraryStore(root: root)
        try await store.bootstrap()

        let loaded = try await store.loadCollections()
        #expect(loaded.collections.map(\.name) == ["비전"])
        #expect(try await store.loadManifest().displayName == "vla")
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "collections.json").path(percentEncoded: false)
            )
        )
    }
}
